#!/usr/bin/env python3
"""GoblinMind backend service — the crowdsourced feed.

Deliberately dumb: it stores per-install book snapshots, merges them
newest-wins per item, and serves the merged book. All price math
(mkt/hist/recent/sales) stays client-side in goblin_brain.py — pulled
books feed each install's book_history like any other book, so stats
evolve from the merged feed without the server knowing statistics.

Endpoints (all JSON):
  POST /v1/register  {name, uuid?, key?}         -> {install_id, token, uuid}
  POST /v1/upload    Authorization: Bearer tok   {scope, t, items, lots?}
  GET  /v1/book?scope=S                          -> {scope, t, items, lots}
  GET  /v1/health                                -> {ok, scopes, installs}
  GET  /v1/scopes                                -> {scopes}

Writ board (bearer-authed writes, open reads):
  POST /v1/boards/{b}/orders                     create buy order
  GET  /v1/boards/{b}/orders[?all=1]             list (open; all adds <24h terminal)
  POST /v1/boards/{b}/orders/{id}/claim          {units, crafter, op?}
  POST /v1/boards/{b}/orders/{id}/fill           {units, commit?, op?} (poster)
  POST /v1/boards/{b}/orders/{id}/reject         {commit?, mailFrom?, op?} (poster)
  POST /v1/boards/{b}/orders/{id}/cancel         {units?, op?} (poster)
  POST /v1/boards/{b}/commits/{id}/release       {op?} (crafter)
  POST /v1/boards/{b}/ban                        {uuid, on} (board owner)
  POST /v1/boards/{b}/roster                     publish my shop roster
  GET  /v1/boards/{b}/rosters                    browse live rosters
  POST /v1/writs                                 address a work request
  GET  /v1/writs                                 private inbox/outbox (auth)
  POST /v1/writs/{id}/{verb}                     quote|accept|decline|ship|recv|cancel
  POST /v1/ignore                                {uuid, on}
  GET  /v1/boards                                board names + open counts

Host admin (loopback + X-Admin-Key header, key in goblin_server.json):
  GET    /v1/admin/installs                      all installs + banned flags
  POST   /v1/admin/installs/{id}                 {banned} — ban also purges
  GET    /v1/admin/boards                        explicit board rows
  POST   /v1/admin/boards                        {name, owner?} create
  POST   /v1/admin/boards/{name}                 {acl, members, closed, owner}
  DELETE /v1/admin/orders/{id}                   force-delete an order

Usage: goblin_server.py [port]          (default 8765)
State: goblin_backend.db (sqlite) next to the script.
"""
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'goblin_backend.db')
CFG_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'goblin_server.json')
SCOPE_RE = re.compile(r'^[\w \'\-()]{1,64}$')
MAX_ITEMS = 400000        # sanity cap — a realm AH won't exceed this
MAX_PRICE = 10 ** 12      # copper; rejects poisoned/bugged payloads
KEEP_PER_INSTALL = 200    # uploads retained per (install, scope)
MERGE_MAX_AGE = 7 * 86400  # uploads older than the stat window are
                           # corpse data — a dead install's week-old
                           # book merged under a fresh scope t looks
                           # current. Age it out of both merge and db.


def _install_uuid(conn, install_id):
    """Echo helper for register responses — the install's stored
    uuid when the request didn't carry a new one."""
    row = conn.execute('SELECT uuid FROM installs WHERE id=?',
                       (install_id,)).fetchone()
    return row[0] if row else None


def _server_cfg():
    """Machine-local server config (never shipped): {"install_secret":
    "...", "bind": "0.0.0.0", "allow": ["cidr", ...]}. Read lazily so
    edits need no restart. Missing or empty secret = open
    registration; missing allow = no IP restriction."""
    try:
        with open(CFG_PATH, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _bind_addr(cli=None):
    """Listen address. Explicit config 'bind' (or a CLI arg) wins; a
    config file present without bind means a deliberately --host'd
    server -> all interfaces; NO config file means an auto-spawned
    personal backend -> loopback only, so a solo install's backend
    can never be joined over the network."""
    if cli:
        return cli
    cfg = _server_cfg()
    if cfg.get('bind'):
        return str(cfg['bind'])
    return '0.0.0.0' if os.path.exists(CFG_PATH) else '127.0.0.1'


def _allowed_ip(ip):
    """Optional CIDR fence: goblin_server.json 'allow' lists the only
    networks that may talk to this server at all — belt and suspenders
    on top of install_secret for LAN-exposed guild hosts."""
    nets = _server_cfg().get('allow')
    if not nets:
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    for n in nets:
        try:
            if addr in ipaddress.ip_network(str(n), strict=False):
                return True
        except ValueError:
            continue
    return False


def db():
    """Per-request connection — WAL (set once in init_db) lets
    readers overlap the writer; busy_timeout absorbs concurrent
    uploads instead of hard-failing on SQLITE_BUSY."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute('PRAGMA busy_timeout=5000')
    conn.execute('PRAGMA synchronous=NORMAL')
    return conn


def init_db():
    """One-time DDL + file-level pragmas at startup — keeps
    CREATE-TABLE churn off the per-request path. Also the migration
    point for idempotent column adds."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('''CREATE TABLE IF NOT EXISTS installs(
        id INTEGER PRIMARY KEY, name TEXT, token TEXT UNIQUE,
        created REAL)''')
    # idempotent column adds — older dbs migrate in place
    cols = {r[1] for r in conn.execute('PRAGMA table_info(installs)')}
    if 'uuid' not in cols:
        conn.execute('ALTER TABLE installs ADD COLUMN uuid TEXT')
    if 'last_seen' not in cols:
        conn.execute('ALTER TABLE installs ADD COLUMN last_seen REAL')
    conn.execute('''CREATE TABLE IF NOT EXISTS uploads(
        id INTEGER PRIMARY KEY, install_id INTEGER, scope TEXT,
        t REAL, items TEXT, lots TEXT,
        UNIQUE(install_id, scope, t))''')
    conn.execute('''CREATE INDEX IF NOT EXISTS up_scope_t
        ON uploads(scope, t)''')
    conn.execute('''CREATE TABLE IF NOT EXISTS rate(
        install_id INTEGER, bucket REAL, n INTEGER,
        PRIMARY KEY(install_id, bucket))''')
    # crowdsourced drop stats — per-install cumulative snapshots,
    # REPLACE'd on each upload; the aggregate sums across installs
    conn.execute('''CREATE TABLE IF NOT EXISTS drop_n(
        install_id INTEGER, scope TEXT, src TEXT, n INTEGER,
        t REAL, PRIMARY KEY(install_id, scope, src))''')
    conn.execute('''CREATE TABLE IF NOT EXISTS drop_k(
        install_id INTEGER, scope TEXT, item_id INTEGER, src TEXT,
        k INTEGER, q INTEGER, t REAL,
        PRIMARY KEY(install_id, scope, item_id, src))''')
    conn.execute('''CREATE TABLE IF NOT EXISTS drop_name(
        install_id INTEGER, scope TEXT, src TEXT, name TEXT,
        PRIMARY KEY(install_id, scope, src))''')
    # --- writ board (craft-orders-proposal 2026-11-20) ---
    if 'banned' not in cols:
        conn.execute('ALTER TABLE installs ADD COLUMN banned '
                     'INTEGER DEFAULT 0')
    if 'relay_token' not in cols:
        conn.execute('ALTER TABLE installs ADD COLUMN relay_token '
                     'TEXT')
    conn.execute('''CREATE TABLE IF NOT EXISTS boards(
        name TEXT PRIMARY KEY, owner_install INTEGER,
        post_acl TEXT DEFAULT 'open', members TEXT DEFAULT '[]',
        closed INTEGER DEFAULT 0, created REAL)''')
    conn.execute('''CREATE TABLE IF NOT EXISTS orders(
        id TEXT PRIMARY KEY, board TEXT, install_id INTEGER,
        item_id INTEGER, qty_total INTEGER,
        qty_filled INTEGER DEFAULT 0, qty_held INTEGER DEFAULT 0,
        price_per_unit INTEGER, claim_ttl REAL,
        poster TEXT, poster_uuid TEXT,
        backed INTEGER DEFAULT 1,
        created REAL, expires REAL,
        state TEXT DEFAULT 'open')''')
    conn.execute('''CREATE INDEX IF NOT EXISTS ord_board
        ON orders(board, state, expires)''')
    conn.execute('''CREATE TABLE IF NOT EXISTS commits(
        id TEXT PRIMARY KEY, order_id TEXT, board TEXT,
        install_id INTEGER, crafter TEXT, crafter_uuid TEXT,
        units INTEGER, units_filled INTEGER DEFAULT 0,
        unit_price INTEGER, created REAL, expires REAL,
        state TEXT DEFAULT 'active')''')
    conn.execute('''CREATE INDEX IF NOT EXISTS cmt_order
        ON commits(order_id, state, expires)''')
    if 'accepted' not in {
            r[1] for r in conn.execute('PRAGMA table_info(commits)')}:
        conn.execute('ALTER TABLE commits ADD COLUMN accepted '
                     'INTEGER DEFAULT 0')
    conn.execute('''CREATE TABLE IF NOT EXISTS ignores(
        install_id INTEGER, target_uuid TEXT,
        PRIMARY KEY(install_id, target_uuid))''')
    conn.execute('''CREATE TABLE IF NOT EXISTS board_bans(
        board TEXT, uuid TEXT, PRIMARY KEY(board, uuid))''')
    conn.execute('''CREATE TABLE IF NOT EXISTS install_stats(
        install_id INTEGER PRIMARY KEY,
        commits_filled INTEGER DEFAULT 0,
        commits_expired INTEGER DEFAULT 0,
        fills_rejected INTEGER DEFAULT 0,
        orders_posted INTEGER DEFAULT 0,
        orders_filled INTEGER DEFAULT 0,
        orders_cancelled INTEGER DEFAULT 0,
        commits_forced INTEGER DEFAULT 0)''')
    if 'commits_forced' not in {
            r[1] for r in conn.execute(
                'PRAGMA table_info(install_stats)')}:
        conn.execute('ALTER TABLE install_stats ADD COLUMN '
                     'commits_forced INTEGER DEFAULT 0')
    for col in ('writs_done', 'writs_declined', 'writs_expired'):
        if col not in {
                r[1] for r in conn.execute(
                    'PRAGMA table_info(install_stats)')}:
            conn.execute('ALTER TABLE install_stats ADD COLUMN '
                         '%s INTEGER DEFAULT 0' % col)
    # ---- crafting writs v2 (open shop) ----
    # A crafter's published shop — one row per (board, install),
    # replaced wholesale on each publish. chars = json toon list so a
    # customer can mail the right name; offers = json [{ref, name,
    # prof, itemID?, kind, price?, mats?, note?, numMade?}]. kind is
    # 'craft' (makes an item) or 'service' (enchant/lockpick — the
    # work is the item-less transaction classic players yell about).
    conn.execute('''CREATE TABLE IF NOT EXISTS rosters(
        board TEXT, install_id INTEGER, uuid TEXT,
        chars TEXT DEFAULT '[]', offers TEXT DEFAULT '[]',
        t REAL, PRIMARY KEY(board, install_id))''')
    # Point-to-point work request — customer->crafter by install
    # uuid (the same anchor that keys orders). Lifecycle:
    # open -> quoted -> agreed -> shipped -> done
    #   \\-> declined (either)  \\-> cancelled (customer)  \\-> expired
    conn.execute('''CREATE TABLE IF NOT EXISTS writs(
        id TEXT PRIMARY KEY, board TEXT,
        from_install INTEGER, from_uuid TEXT, from_char TEXT,
        to_install INTEGER, to_uuid TEXT, to_char TEXT,
        ref TEXT, name TEXT, item_id INTEGER, qty INTEGER,
        offer INTEGER, mats TEXT, deliver TEXT, note TEXT,
        quote INTEGER, cod INTEGER, mail_from TEXT,
        created REAL, updated REAL, expires REAL,
        state TEXT DEFAULT 'open',
        meet TEXT, mats_fp TEXT)''')
    conn.execute('''CREATE INDEX IF NOT EXISTS wri_to
        ON writs(to_install, state)''')
    conn.execute('''CREATE INDEX IF NOT EXISTS wri_from
        ON writs(from_install, state)''')
    # v2.1 columns — meet = the arranged meet-place (trade-settle
    # handshake), mats_fp = the prepaid-mats shipment fingerprint
    # the crafter's client matches inbound mail against
    wcols = {r[1] for r in conn.execute('PRAGMA table_info(writs)')}
    for col in ('meet', 'mats_fp'):
        if col not in wcols:
            conn.execute(
                'ALTER TABLE writs ADD COLUMN %s TEXT' % col)
    # staged-op dedup — SV replays POST the same op id; first result
    # is replayed verbatim instead of re-applying the mutation
    conn.execute('''CREATE TABLE IF NOT EXISTS order_ops(
        install_id INTEGER, op TEXT, result TEXT, t REAL,
        PRIMARY KEY(install_id, op))''')
    conn.execute('''CREATE TABLE IF NOT EXISTS orate(
        install_id INTEGER, bucket REAL, n INTEGER,
        PRIMARY KEY(install_id, bucket))''')
    conn.commit()
    conn.close()


def clean_entry(e):
    """Whitelisted int-coerced item entry — strips anything malformed
    before it can reach the merged book."""
    if not isinstance(e, dict):
        return None
    out = {}
    for k in ('mb', 'mbx', 'sup', 'n'):
        v = e.get(k)
        if v is None:
            out[k] = None
            continue
        try:
            v = int(v)
        except (TypeError, ValueError):
            return None
        if v < 0 or v > MAX_PRICE:
            return None
        out[k] = v
    return out


def clean_items(items):
    out = {}
    for iid, e in (items or {}).items():
        try:
            iid = int(iid)
        except (TypeError, ValueError):
            continue
        ce = clean_entry(e)
        if ce:
            out[iid] = ce
    return out


_last_gc = [0.0]
_last_vacuum = [0.0]

SRC_RE = re.compile(r'^[coin].{0,63}$')
DROP_SRC_CAP = 500        # src keys per upload
DROP_PAIR_CAP = 2000      # (item,src) pairs per upload
DROP_COUNT_CAP = 10 ** 7  # k/q/n sanity bound


def store_drops(conn, install, scope, drops):
    """Wholesale replace of an install's cumulative drop snapshot for
    a scope — deleting first also purges sources the client pruned.
    Uploads are cumulative counters, never additive."""
    if not isinstance(drops, dict):
        return
    now = time.time()
    nmap = drops.get('n') or {}
    dmap = drops.get('d') or {}
    names = drops.get('names') or {}
    conn.execute('DELETE FROM drop_n WHERE install_id=? AND scope=?',
                 (install, scope))
    conn.execute('DELETE FROM drop_k WHERE install_id=? AND scope=?',
                 (install, scope))
    conn.execute('DELETE FROM drop_name WHERE install_id=? AND scope=?',
                 (install, scope))
    conn.executemany(
        'INSERT INTO drop_n VALUES(?,?,?,?,?)',
        [(install, scope, str(src), int(n), now)
         for src, n in list(nmap.items())[:DROP_SRC_CAP]
         if SRC_RE.match(str(src))
         and isinstance(n, (int, float)) and 0 < n <= DROP_COUNT_CAP])
    rows = []
    for iid, srcs in dmap.items():
        if len(rows) >= DROP_PAIR_CAP:
            break
        try:
            iid = int(iid)
        except (TypeError, ValueError):
            continue
        for src, st in (srcs or {}).items():
            if len(rows) >= DROP_PAIR_CAP:
                break
            src = str(src)
            if not SRC_RE.match(src) or not isinstance(st, dict):
                continue
            k, q = st.get('k'), st.get('q')
            if not (isinstance(k, (int, float))
                    and 0 <= k <= DROP_COUNT_CAP
                    and isinstance(q, (int, float))
                    and 0 <= q <= DROP_COUNT_CAP):
                continue
            rows.append((install, scope, iid, src,
                         int(k), int(q), now))
    conn.executemany('INSERT INTO drop_k VALUES(?,?,?,?,?,?,?)', rows)
    conn.executemany(
        'INSERT INTO drop_name VALUES(?,?,?,?)',
        [(install, scope, str(src), name[:64])
         for src, name in list(names.items())[:DROP_SRC_CAP]
         if SRC_RE.match(str(src))
         and isinstance(name, str) and name])


def merged_drops(conn, scope):
    """Crowdsourced drop stats — SUM counts across installs; each
    install's rows are its latest cumulative snapshot. Mirrors the
    addon's GM.db.drops/dropsN/dropsName shape."""
    n = {r[0]: int(r[1]) for r in conn.execute(
        'SELECT src, SUM(n) FROM drop_n WHERE scope=? GROUP BY src',
        (scope,))}
    d = {}
    for iid, src, k, q in conn.execute(
            'SELECT item_id, src, SUM(k), SUM(q) FROM drop_k '
            'WHERE scope=? GROUP BY item_id, src', (scope,)):
        d[str(iid)] = d.get(str(iid)) or {}
        d[str(iid)][src] = {'k': int(k), 'q': int(q)}
    names = {r[0]: r[1] for r in conn.execute(
        'SELECT src, MAX(name) FROM drop_name WHERE scope=? '
        'GROUP BY src', (scope,))}
    if not (n or d):
        return {}
    return {'n': n, 'd': d, 'names': names}


_BOOK_CACHE = {}
_BOOK_LOCK = threading.Lock()


def _book_invalidate(scope=None):
    """Drop cached merged books — on upload (one scope) or GC
    (anything may have aged out)."""
    with _BOOK_LOCK:
        if scope is None:
            _BOOK_CACHE.clear()
        else:
            _BOOK_CACHE.pop(scope, None)


def _gc(conn, force=False):
    """Purge uploads/drop rows past the merge window + stale rate
    buckets — keeps the store bounded for installs that go silent
    (KEEP_PER_INSTALL only bounds live ones). Runs hourly off the
    request path from _gc_loop; force=True in tests. Invalidates the
    whole book cache when it deletes anything."""
    now = time.time()
    if not force and now - _last_gc[0] < 3600:
        return
    _last_gc[0] = now
    cutoff = now - MERGE_MAX_AGE
    purged = conn.execute(
        'DELETE FROM uploads WHERE t < ?', (cutoff,)).rowcount
    purged += conn.execute(
        'DELETE FROM drop_n WHERE t < ?', (cutoff,)).rowcount
    purged += conn.execute(
        'DELETE FROM drop_k WHERE t < ?', (cutoff,)).rowcount
    conn.execute('DELETE FROM drop_name WHERE NOT EXISTS ('
                 'SELECT 1 FROM drop_n WHERE '
                 'drop_n.install_id=drop_name.install_id AND '
                 'drop_n.scope=drop_name.scope AND '
                 'drop_name.src=drop_name.src)')
    conn.execute('DELETE FROM rate WHERE bucket < ?',
                 (now // 600 - 144,))
    conn.execute('DELETE FROM orate WHERE bucket < ?',
                 (now // 600 - 144,))
    # writ GC: TTL-dead commits release their units back to the
    # order pools (lazy per-order sweep covers the hot path; this
    # is the backstop for boards nobody reads)
    exp = conn.execute(
        "SELECT id, install_id, order_id FROM commits WHERE "
        "state='active' AND expires<?", (now,)).fetchall()
    for cid, inst, oid in exp:
        conn.execute("UPDATE commits SET state='released' WHERE id=?",
                     (cid,))
        _stat(conn, inst, 'commits_expired')
    for oid in {r[2] for r in exp}:
        _pool_refresh(conn, oid)
    # open orders past their expires die; their live commits void
    dead = [r[0] for r in conn.execute(
        "SELECT id FROM orders WHERE state='open' AND expires<?",
        (now,))]
    for oid in dead:
        conn.execute(
            "UPDATE commits SET state='void' WHERE order_id=? AND "
            "state='active'", (oid,))
        conn.execute("UPDATE orders SET state='expired' WHERE id=?",
                     (oid,))
    # terminal orders + their commits persist a day for MY ORDERS
    # history, then go
    conn.execute(
        "DELETE FROM commits WHERE order_id IN (SELECT id FROM "
        "orders WHERE state!='open' AND expires<?-86400)", (now,))
    conn.execute(
        "DELETE FROM orders WHERE state!='open' AND "
        "expires<?-86400", (now,))
    conn.execute('DELETE FROM order_ops WHERE t<?',
                 (now - MERGE_MAX_AGE,))
    # crafting-writ GC: live requests past expires die (agreed-expired
    # counts against the crafter); terminal rows keep a day of inbox
    # history; silent rosters leave the shop after ROSTER_MAX_AGE
    wexp = conn.execute(
        "SELECT id,to_install,state FROM writs WHERE state IN "
        "('open','quoted','agreed') AND expires<?", (now,)).fetchall()
    for wid, ti, wstate in wexp:
        conn.execute("UPDATE writs SET state='expired',updated=? "
                     "WHERE id=?", (now, wid))
        if wstate == 'agreed':
            _stat(conn, ti, 'writs_expired')
    conn.execute(
        "DELETE FROM writs WHERE state IN ('done','declined',"
        "'cancelled','expired') AND updated<?-86400", (now,))
    conn.execute('DELETE FROM rosters WHERE t<?',
                 (now - ROSTER_MAX_AGE,))
    conn.commit()
    if purged:
        _book_invalidate()
    # weekly VACUUM reclaims the file space deleted rows leave —
    # sqlite doesn't shrink on DELETE alone; it fails under lock so
    # it retries next window rather than killing the request
    if now - _last_vacuum[0] > 7 * 86400:
        _last_vacuum[0] = now
        try:
            conn.execute('VACUUM')
        except sqlite3.OperationalError:
            pass


def _gc_loop():
    """Hourly purge in a daemon thread — a big DELETE or the weekly
    VACUUM must never stall a book pull."""
    while True:
        time.sleep(3600)
        try:
            conn = db()
            try:
                _gc(conn, force=True)
            finally:
                conn.close()
        except Exception:
            pass


_BOOK_CACHE_MAX = 64  # /v1/book is unauthenticated — cap cached
                      # scopes so arbitrary scope probes can't grow
                      # the dict forever (real meshes have <10)


def book_json(conn, scope):
    """The hot read path: serialized merged book per scope. Books
    only change on upload or GC, so the json.loads-per-row merge
    runs exactly then instead of on every pull."""
    with _BOOK_LOCK:
        hit = _BOOK_CACHE.get(scope)
    if hit is not None:
        return hit
    body = json.dumps(merged_book(conn, scope)).encode()
    with _BOOK_LOCK:
        if len(_BOOK_CACHE) >= _BOOK_CACHE_MAX:
            _BOOK_CACHE.pop(next(iter(_BOOK_CACHE)))  # oldest first
        _BOOK_CACHE[scope] = body
    return body


def merged_book(conn, scope):
    """Newest-upload-wins per item across all contributors, plus the
    lots map from the upload that provided each item."""
    rows = conn.execute(
        'SELECT t, items, lots FROM uploads WHERE scope=? AND t>? '
        'ORDER BY t ASC, id ASC',
        (scope, time.time() - MERGE_MAX_AGE)).fetchall()
    items, newest = {}, 0
    lots_by_iid = {}   # iid -> {fp: n} from the newest upload owning it
    for t, items_j, lots_j in rows:
        its = json.loads(items_j)
        lts = json.loads(lots_j or '{}')
        newest = max(newest, t)
        up_by_iid = {}
        for f, n in lts.items():
            up_by_iid.setdefault(f.split(':', 1)[0], {})[f] = n
        for iid in its:
            items[iid] = its[iid]          # later rows overwrite
            lots_by_iid[iid] = up_by_iid.get(iid, {})
    lots = {f: n for grp in lots_by_iid.values()
            for f, n in grp.items()}
    return {'scope': scope, 't': int(newest) if newest else None,
            'items': items, 'lots': lots,
            'drops': merged_drops(conn, scope)}


# ---- writ board (craft-orders-proposal 2026-11-20) ----
#
# Model: standing buy orders (pricePerUnit × qtyTotal); crafters
# hold slices via 'commits' whose TTL the POSTER set on the order.
# The pool is qty_total - qty_filled - qty_held; every mutation
# recomputes qty_held from live commit rows so drift can't creep.

ORDER_MAX_QTY = 10000
ORDER_OPEN_CAP = 20          # per install per board
CLAIM_TTL_MIN = 3600         # poster-set bounds: 1h..72h, default 24h
CLAIM_TTL_MAX = 259200
CLAIM_TTL_DEF = 86400
ORDER_MAX_AGE = 7 * 86400    # same window as book merges
ORDER_RATE = 60              # board ops per 600s bucket per install
STAT_COLS = ('commits_filled', 'commits_expired', 'fills_rejected',
             'orders_posted', 'orders_filled', 'orders_cancelled',
             'commits_forced', 'writs_done', 'writs_declined',
             'writs_expired')

# ---- crafting writs v2: open shops + point-to-point requests ----
# Roster = a crafter's published skill list on a board. Writ = a
# customer's request addressed to that roster's install uuid.
ROSTER_OFFER_CAP = 80
ROSTER_MAX_AGE = 7 * 86400     # silent crafters drop out of the shops
WRIT_MAX_QTY = 9999
WRIT_OPEN_CAP = 24             # per direction (in and out) per install
WRIT_TTL_MIN = 3600
WRIT_TTL_DEF = 259200          # 72h — requests stay while parties sleep
WRIT_TTL_MAX = 7 * 86400
MATS_KINDS = ('buyer', 'crafter', 'prepaid')
DELIVER_KINDS = ('cod', 'mail', 'trade')


def _pool_refresh(conn, oid):
    """qty_held = live commit remainder — single source of truth."""
    conn.execute(
        'UPDATE orders SET qty_held=(SELECT COALESCE('
        'SUM(units-units_filled),0) FROM commits '
        'WHERE order_id=orders.id AND state=\'active\') WHERE id=?',
        (oid,))


def _expire_order(conn, oid, now):
    """Lazy commit-TTL sweep for one order — a claim/fill/read sees
    the true pool without waiting for the hourly GC."""
    rel = conn.execute(
        'SELECT id, install_id FROM commits WHERE order_id=? AND '
        'state=\'active\' AND expires<?', (oid, now)).fetchall()
    for cid, inst in rel:
        conn.execute("UPDATE commits SET state='released' WHERE id=?",
                     (cid,))
        _stat(conn, inst, 'commits_expired')
    if rel:
        _pool_refresh(conn, oid)
    # the order itself: 'open' past expires dies like GC's pass —
    # without this a claim can land on a dead order between expiry
    # and the hourly sweep, and pulls serve it as open
    if conn.execute(
            "UPDATE orders SET state='expired' WHERE id=? AND "
            "state='open' AND expires<?", (oid, now)).rowcount:
        conn.execute("UPDATE commits SET state='void' WHERE "
                     "order_id=? AND state='active'", (oid,))
        return True
    return False


def _stat(conn, install_id, col):
    conn.execute(
        'INSERT INTO install_stats(install_id,%s) VALUES(?,1) '
        'ON CONFLICT(install_id) DO UPDATE SET %s=%s+1'
        % (col, col, col), (install_id,))


def _stats_bulk(conn, iids):
    """One stats read for a whole board pull — every poster and
    crafter at once instead of a query per lookup."""
    out = {i: {c: 0 for c in STAT_COLS} for i in iids}
    if iids:
        q = ('SELECT install_id,%s FROM install_stats WHERE '
             'install_id IN (%s)' % (
                 ','.join(STAT_COLS), ','.join('?' * len(iids))))
        for row in conn.execute(q, tuple(iids)):
            out[row[0]] = dict(zip(STAT_COLS, row[1:]))
    return out


def _order_row(conn, oid):
    """15-col row: the 14 order_dict fields + install_id."""
    return conn.execute(
        'SELECT id,board,item_id,qty_total,qty_filled,qty_held,'
        'price_per_unit,claim_ttl,poster,poster_uuid,backed,'
        'created,expires,state,install_id FROM orders WHERE id=?',
        (oid,)).fetchone()


def _order_dicts(conn, rows):
    """Serialize 15-col order rows with commits + stats — the batch
    path: 2 queries for the whole list (commits IN, stats IN)
    instead of a commits query per order and a stats query per
    order+commit. A 200-order pull was ~600 queries."""
    oids = [r[0] for r in rows]
    cms = {o: [] for o in oids}
    iids = {r[14] for r in rows}
    if oids:
        q = ('SELECT order_id,id,units,units_filled,crafter,'
             'crafter_uuid,expires,state,install_id,accepted '
             'FROM commits WHERE order_id IN (%s) ORDER BY created'
             % ','.join('?' * len(oids)))
        for c in conn.execute(q, oids):
            cms[c[0]].append(c)
            iids.add(c[8])
    stats = _stats_bulk(conn, iids)
    out = []
    for r in rows:
        (oid, board, iid, qty, filled, held, ppu, ttl, poster,
         puuid, backed, created, expires, state) = r[:14]
        out.append({
            'id': oid, 'board': board, 'itemID': iid,
            'qtyTotal': qty, 'qtyFilled': filled,
            'remaining': qty - filled - held,
            'pricePerUnit': ppu, 'claimTTL': int(ttl),
            'poster': poster, 'posterUUID': puuid,
            'backed': bool(backed),
            'created': int(created), 'expires': int(expires),
            'state': state,
            'posterStats': stats[r[14]],
            'commits': [
                {'id': c[1], 'units': c[2],
                 'unitsFilled': c[3], 'crafter': c[4],
                 'crafterUUID': c[5], 'expires': int(c[6]),
                 'state': c[7], 'accepted': bool(c[9]),
                 'crafterStats': stats[c[8]]}
                for c in cms[oid]]})
    return out


def _order_json(conn, oid):
    """Single-order serialize — same payload as the board list."""
    row = _order_row(conn, oid)
    return _order_dicts(conn, [row])[0] if row else None


def _commit_of(conn, board, cid):
    r = conn.execute(
        'SELECT id,order_id,units,units_filled,crafter,'
        'crafter_uuid,unit_price,expires,state,install_id '
        'FROM commits WHERE board=? AND id=?',
        (board, cid)).fetchone()
    return {'id': r[0], 'orderID': r[1], 'units': r[2],
            'unitsFilled': r[3], 'crafter': r[4],
            'crafterUUID': r[5], 'unitPrice': r[6],
            'expires': int(r[7]), 'state': r[8]}


def _commit_pick(conn, oid, body):
    """Which active commit does a fill/reject land on? Explicit
    'commit' id wins, else oldest with unfilled units matching
    the mail sender's name (alt-mismatch → unmatched COD stays
    client-side)."""
    cid = body.get('commit')
    if cid:
        return conn.execute(
            "SELECT id,install_id,units,units_filled FROM commits "
            "WHERE id=? AND order_id=? AND state='active'",
            (str(cid)[:64], oid)).fetchone()
    mail = str(body.get('mailFrom') or '')[:24]
    q = "SELECT id,install_id,units,units_filled FROM commits " \
        "WHERE order_id=? AND state='active' AND " \
        "units_filled<units %s ORDER BY created"
    if mail:
        return conn.execute(q % 'AND crafter=?',
                            (oid, mail)).fetchone()
    return conn.execute(q % '', (oid,)).fetchone()


def _board_row(conn, name):
    return conn.execute(
        'SELECT name, owner_install, post_acl, members, closed '
        'FROM boards WHERE name=?', (name,)).fetchone()


def _board_write_ok(conn, board, uid):
    """Explicit-board gates for post/claim: closed + members ACL +
    board_bans. Returns an error string or None."""
    row = _board_row(conn, board)
    if row:
        if row[4]:
            return 'closed'
        if row[2] == 'members' and uid not in (
                json.loads(row[3] or '[]')):
            return 'members'
    if conn.execute('SELECT 1 FROM board_bans WHERE board=? '
                    'AND uuid=?', (board, uid)).fetchone():
        return 'board_ban'
    return None


def _op_seen(conn, install, op):
    """Idempotent replay for staged ops — returns the stored result
    dict (callers add 'dup': True) or None."""
    if not op:
        return None
    row = conn.execute('SELECT result FROM order_ops WHERE '
                       'install_id=? AND op=?', (install, str(op)[:64])
                       ).fetchone()
    return json.loads(row[0]) if row else None


def _op_store(conn, install, op, result):
    if op:
        conn.execute('INSERT OR REPLACE INTO order_ops VALUES(?,?,?,?)',
                     (install, str(op)[:64], json.dumps(result),
                      time.time()))


def _uuid_of(conn, install_id):
    row = conn.execute('SELECT uuid FROM installs WHERE id=?',
                       (install_id,)).fetchone()
    return row[0] if row else None


def _orate(conn, install):
    """Order-op token bucket — 60/10min, separate from the
    upload bucket so board chatter can't starve book uploads.
    Same wart as uploads by design: counts before validation."""
    bucket = time.time() // 600
    conn.execute(
        'INSERT INTO orate(install_id,bucket,n) VALUES(?,?,1) '
        'ON CONFLICT(install_id,bucket) DO UPDATE SET n=n+1',
        (install, bucket))
    n = conn.execute('SELECT n FROM orate WHERE install_id=? '
                     'AND bucket=?', (install, bucket)).fetchone()[0]
    conn.commit()
    return n > ORDER_RATE


# ============ route table ============
# One registry for every endpoint — @route declares method, path
# pattern ({x} captures one segment, trailing /* = prefix match),
# and flags beside the handler it dispatches to. do_GET/POST/DELETE
# all funnel through the single _handle dispatch — no parallel
# if-chains per method.
#
# flags: OPEN = no bearer required; AUTH = Bearer install token;
#        ORDOP = AUTH + orate bucket + op-nonce dedup wrapper;
#        ADMIN = loopback + X-Admin-Key, gated in _handle.
OPEN, AUTH, ORDOP, ADMIN = 1, 2, 4, 8
ROUTES = []


def _compile(pattern):
    segs = pattern.split('/')
    prefix = segs[-1] == '*'
    if prefix:
        segs = segs[:-1]

    def match(p):
        ps = p.split('/')
        if prefix:
            if len(ps) <= len(segs) or ps[:len(segs)] != segs:
                return None
            return {}
        if len(ps) != len(segs):
            return None
        caps = {}
        for want, got in zip(segs, ps):
            if want[:1] == '{' and want[-1:] == '}':
                caps[want[1:-1]] = got
            elif want != got:
                return None
        return caps
    return match


def _route(method, pattern, flags):
    def deco(fn):
        ROUTES.append((method, _compile(pattern), fn, flags))
        return fn
    return deco


def _route_match(method, path):
    for m, match, fn, flags in ROUTES:
        if m == '*' or m == method:
            caps = match(path)
            if caps is not None:
                return fn, flags, caps
    return None


# ============ handlers (conn, ctx) ============
# ctx carries everything a route needs: 'm'ethod, 'p'ath, 'q'uery,
# 'body' (POST JSON or None), 'now', 'send' (bound _send),
# 'is_admin' (bound checker), 'install' (authed id or None), plus
# captured path segments. One signature for the whole surface.


@_route('GET', '/v1/health', OPEN)
def h_health(conn, ctx):
    scopes = [r[0] for r in conn.execute(
        'SELECT DISTINCT scope FROM uploads')]
    installs = [{'name': name, 'uuid': uid,
                 'scopes': (scs or '').split(',') if scs else [],
                 'uploads': n, 'last': last, 'seen': seen}
                for name, uid, scs, n, last, seen in conn.execute(
            'SELECT i.name, i.uuid, '
            'GROUP_CONCAT(DISTINCT u.scope), '
            'COUNT(u.id), MAX(u.t), i.last_seen '
            'FROM installs i '
            'LEFT JOIN uploads u ON u.install_id=i.id '
            'GROUP BY i.id ORDER BY i.name')]
    ctx['send'](200, {'ok': True, 'scopes': scopes,
                      'installs': installs})


@_route('GET', '/v1/scopes', OPEN)
def h_scopes(conn, ctx):
    # open like health — lets installers offer real scope choices
    # instead of asking the user to type one
    ctx['send'](200, {'scopes': [r[0] for r in conn.execute(
        'SELECT DISTINCT scope FROM uploads')]})


@_route('GET', '/v1/book', 0)
def h_book(conn, ctx):
    scope = (ctx['q'].get('scope') or [''])[0]
    if not SCOPE_RE.match(scope):
        ctx['send'](400, {'error': 'bad scope'})
        return
    ctx['send_raw'](200, book_json(conn, scope))


@_route('GET', '/v1/boards', 0)
def h_boards(conn, ctx):
    # open read — boards = explicit rows ∪ names seen on orders;
    # implicit boards report open order counts
    open_ct = dict(conn.execute(
        "SELECT board, COUNT(*) FROM orders WHERE "
        "state='open' GROUP BY board"))
    rows = {r[0]: (r[1], r[2], r[3], r[4]) for r in conn.execute(
        'SELECT name, owner_install, post_acl, members, closed '
        'FROM boards')}
    names = sorted(set(open_ct) | set(rows))
    ctx['send'](200, {'boards': [
        {'name': n, 'open': open_ct.get(n, 0),
         'acl': rows[n][1] if n in rows else 'open',
         'members': json.loads(rows[n][2]) if n in rows else [],
         'closed': bool(rows[n][3]) if n in rows else False}
        for n in names]})


@_route('GET', '/v1/boards/{b}/orders', 0)
def h_orders(conn, ctx):
    board = ctx['b']
    if not SCOPE_RE.match(board):
        ctx['send'](400, {'error': 'bad board'})
        return
    now = ctx['now']
    # lazy commit-TTL sweep, batched for the board — one probe
    # covers every open order instead of a query each
    exp = conn.execute(
        "SELECT id, install_id, order_id FROM commits WHERE "
        "state='active' AND expires<? AND order_id IN (SELECT id "
        "FROM orders WHERE board=? AND state='open')",
        (now, board)).fetchall()
    for cid, inst, oid in exp:
        conn.execute("UPDATE commits SET state='released' WHERE id=?",
                     (cid,))
        _stat(conn, inst, 'commits_expired')
    for oid in {r[2] for r in exp}:
        _pool_refresh(conn, oid)
    # and the orders themselves — 'open' past expires must not
    # serve as open for the GC window (up to an hour)
    for oid, in conn.execute(
            "SELECT id FROM orders WHERE board=? AND state='open' "
            "AND expires<?", (board, now)):
        conn.execute("UPDATE commits SET state='void' WHERE "
                     "order_id=? AND state='active'", (oid,))
        conn.execute("UPDATE orders SET state='expired' WHERE id=?",
                     (oid,))
    conn.commit()
    rows = conn.execute(
        'SELECT id,board,item_id,qty_total,qty_filled,qty_held,'
        'price_per_unit,claim_ttl,poster,poster_uuid,backed,'
        'created,expires,state,install_id FROM orders WHERE '
        "board=? AND (state='open' OR (? AND expires>?-86400)) "
        'ORDER BY created DESC LIMIT 200',
        (board, bool(ctx['q'].get('all') == ['1']), now)).fetchall()
    ctx['send'](200, {'orders': _order_dicts(conn, rows)})


@_route('POST', '/v1/register', OPEN)
def h_register(conn, ctx):
    body = ctx['body'] or {}
    cfg = _server_cfg()
    # register_mode: 'open' | 'secret' (key required) |
    # 'whitelist' (uuid in cfg.whitelist). Absent mode =
    # legacy: secret required iff install_secret set.
    mode = cfg.get('register_mode') or (
        'secret' if cfg.get('install_secret') else 'open')
    if mode == 'secret' and not secrets.compare_digest(
            str(body.get('key') or ''),
            str(cfg.get('install_secret') or '')):
        ctx['send'](403, {'error': 'key'})
        return
    uid = str(body.get('uuid') or '')[:64] or None
    if mode == 'whitelist' and uid not in (
            cfg.get('whitelist') or []):
        ctx['send'](403, {'error': 'whitelist'})
        return
    name = str(body.get('name') or 'install')[:64]
    # client-supplied stable id — 'who is who' without
    # handmade accounts; COALESCE keeps a stored uuid
    # when a re-register doesn't send one.
    # relay:true = a mesh peer registering a tunneled install (its
    # only route is the chat channel). The response carries
    # relay_token — op-scoped creds for the uuid+rtoken body auth —
    # and NO bearer, which would be a dead secret anyway.
    relay = bool(body.get('relay'))
    tok = None if relay else secrets.token_urlsafe(24)
    row = conn.execute(
        'SELECT id FROM installs WHERE name=?', (name,)).fetchone()
    if row:
        # re-register = re-key the existing install (lost
        # api_state / reinstall) — no zombie rows per name
        conn.execute(
            'UPDATE installs SET token=COALESCE(?, token), '
            'uuid=COALESCE(?, uuid), '
            'relay_token=COALESCE(relay_token, ?) WHERE id=?',
            (tok, uid, secrets.token_urlsafe(16), row[0]))
        conn.commit()
        out = {'install_id': row[0],
               'uuid': uid or _install_uuid(conn, row[0]),
               'relay_token': _rtok_of(conn, row[0])}
        if not relay:
            out['token'] = tok
        ctx['send'](200, out)
        return
    rtok = secrets.token_urlsafe(16)
    cur = conn.execute(
        'INSERT INTO installs(name, token, uuid, relay_token, '
         'created) VALUES(?,?,?,?,?)',
        (name, tok, uid, rtok, ctx['now']))
    conn.commit()
    out = {'install_id': cur.lastrowid, 'uuid': uid,
           'relay_token': rtok}
    if not relay:
        out['token'] = tok
    ctx['send'](200, out)


def _rtok_of(conn, install_id):
    row = conn.execute('SELECT relay_token FROM installs WHERE id=?',
                       (install_id,)).fetchone()
    return row[0] if row else None


@_route('POST', '/v1/upload', AUTH)
def h_upload(conn, ctx):
    install = ctx['install']
    # 10 uploads / 10 minutes per install
    bucket = ctx['now'] // 600
    conn.execute(
        'INSERT INTO rate(install_id,bucket,n) VALUES(?,?,1) '
        'ON CONFLICT(install_id,bucket) DO UPDATE SET n=n+1',
        (install, bucket))
    if (conn.execute('SELECT n FROM rate WHERE install_id=? '
                     'AND bucket=?', (install, bucket))
            .fetchone()[0]) > 10:
        conn.commit()
        ctx['send'](429, {'error': 'rate'})
        return
    body = ctx['body']
    if not isinstance(body, dict):
        ctx['send'](400, {'error': 'body'})
        return
    scope = str(body.get('scope') or '')
    t = body.get('t')
    items = clean_items(body.get('items'))
    lots = body.get('lots') or {}
    if not SCOPE_RE.match(scope) or not isinstance(
            t, (int, float)) or not items or \
            len(items) > MAX_ITEMS:
        ctx['send'](400, {'error': 'payload'})
        conn.commit()
        return
    lots = {str(k): int(v) for k, v in lots.items()
            if isinstance(v, (int, float))}
    # t is client-claimed and drives newest-wins, the staleness
    # cutoff, and GC — a book can't be newer than now, so cap
    # future dates. Past values pass through: an old scan
    # uploaded late is legitimately old data.
    t = min(float(t), ctx['now'])
    conn.execute(
        'INSERT OR REPLACE INTO '
        'uploads(install_id,scope,t,items,lots) '
        'VALUES(?,?,?,?,?)',
        (install, scope, t, json.dumps(items),
         json.dumps(lots)))
    # retention: keep newest KEEP_PER_INSTALL per install+scope
    conn.execute(
        'DELETE FROM uploads WHERE install_id=? AND scope=? '
        'AND id NOT IN (SELECT id FROM uploads WHERE '
        'install_id=? AND scope=? ORDER BY t DESC LIMIT ?)',
        (install, scope, install, scope, KEEP_PER_INSTALL))
    store_drops(conn, install, scope, body.get('drops'))
    conn.execute('UPDATE installs SET last_seen=? WHERE id=?',
                 (ctx['now'], install))
    conn.commit()
    _book_invalidate(scope)
    ctx['send'](200, {'ok': True, 'items': len(items)})


# ---- writ ops (ORDOP wrapper: orate -> body -> dedup -> run) ----


def _ordop(conn, ctx, fn):
    """Authed board mutation — every mutating op is idempotent via
    its 'op' nonce (order_ops) or its own row id. The ONE wrapper
    for every write route: body -> auth -> rate limit -> replay ->
    run -> store -> respond. Handlers return the result dict to
    store+send, or None after sending their own error (validation
    failures are NOT deduped — a retried op re-evaluates).

    Install resolution: Bearer first; when absent, the body's
    uuid+rtoken pair — the envelope a mesh peer POSTs on behalf of
    a tunneled install (the chat channel is its only route to the
    tracker). The op still applies under the AUTHOR's install."""
    body = ctx['body']
    if not isinstance(body, dict):
        ctx['send'](400, {'error': 'body'})
        return
    if ctx['install'] is None:
        row = conn.execute(
            'SELECT id FROM installs WHERE uuid=? AND '
            'relay_token=? AND COALESCE(banned,0)=0',
            (str(body.get('uuid') or '')[:64],
             str(body.get('rtoken') or '')[:64])).fetchone()
        if not row:
            ctx['send'](401, {'error': 'auth'})
            return
        ctx['install'] = row[0]
    if _orate(conn, ctx['install']):
        ctx['send'](429, {'error': 'rate'})
        return
    if 'b' in ctx and not SCOPE_RE.match(ctx['b']):
        ctx['send'](400, {'error': 'bad board'})
        return
    op = str(body.get('op') or '')[:64]
    seen = _op_seen(conn, ctx['install'], op)
    if seen is not None:
        seen['dup'] = True
        ctx['send'](200, seen)
        return
    ctx['uid'] = _uuid_of(conn, ctx['install']) or ''
    res = fn(conn, ctx)
    if res is None:
        return
    _op_store(conn, ctx['install'], op, res)
    conn.commit()
    ctx['send'](200, res)


@_route('POST', '/v1/ignore', ORDOP)
def o_ignore(conn, ctx):
    tgt = str(ctx['body'].get('uuid') or '')[:64]
    if not tgt:
        ctx['send'](400, {'error': 'uuid'})
        return None
    if ctx['body'].get('on'):
        conn.execute('INSERT OR IGNORE INTO ignores VALUES(?,?)',
                     (ctx['install'], tgt))
    else:
        conn.execute('DELETE FROM ignores WHERE install_id=? AND '
                     'target_uuid=?', (ctx['install'], tgt))
    conn.commit()
    return {'ok': True}


@_route('POST', '/v1/boards/{b}/ban', ORDOP)
def o_ban(conn, ctx):
    brow = _board_row(conn, ctx['b'])
    if not brow or brow[1] != ctx['install']:
        ctx['send'](403, {'error': 'owner'})
        return None
    tgt = str(ctx['body'].get('uuid') or '')[:64]
    if not tgt:
        ctx['send'](400, {'error': 'uuid'})
        return None
    if ctx['body'].get('on'):
        conn.execute('INSERT OR REPLACE INTO board_bans VALUES(?,?)',
                     (ctx['b'], tgt))
    else:
        conn.execute('DELETE FROM board_bans WHERE board=? AND '
                     'uuid=?', (ctx['b'], tgt))
    conn.commit()
    return {'ok': True}


@_route('POST', '/v1/boards/{b}/orders', ORDOP)
def o_post(conn, ctx):
    """Create a standing buy order. id = install:op so a staged-
    op replay hits INSERT-IGNORE and returns the same row."""
    board, body, install = ctx['b'], ctx['body'], ctx['install']
    now, op, uid = ctx['now'], ctx['body'].get('op'), ctx['uid']
    gate = _board_write_ok(conn, board, uid)
    if gate:
        ctx['send'](403, {'error': gate})
        return None
    try:
        iid = int(body.get('itemID'))
        qty = int(body.get('qtyTotal'))
        ppu = int(body.get('pricePerUnit'))
    except (TypeError, ValueError):
        ctx['send'](400, {'error': 'payload'})
        return None
    if not (1 <= qty <= ORDER_MAX_QTY and 1 <= ppu <= MAX_PRICE):
        ctx['send'](400, {'error': 'payload'})
        return None
    ttl = body.get('claimTTL')
    ttl = min(max(int(ttl), CLAIM_TTL_MIN), CLAIM_TTL_MAX) \
        if isinstance(ttl, (int, float)) else CLAIM_TTL_DEF
    exp = body.get('expires')
    exp = min(float(exp), now + ORDER_MAX_AGE) \
        if isinstance(exp, (int, float)) and exp > now + 600 \
        else now + ORDER_MAX_AGE
    n = conn.execute(
        "SELECT COUNT(*) FROM orders WHERE install_id=? AND "
        "board=? AND state='open'", (install, board)).fetchone()[0]
    if n >= ORDER_OPEN_CAP:
        ctx['send'](429, {'error': 'cap'})
        return None
    oid = '%s:%s' % (install, op or secrets.token_hex(6))
    poster = str(body.get('poster') or '')[:24]
    conn.execute(
        'INSERT OR IGNORE INTO orders(id,board,install_id,'
        'item_id,qty_total,qty_filled,qty_held,price_per_unit,'
        'claim_ttl,poster,poster_uuid,backed,created,expires,'
        'state) VALUES(?,?,?,?,?,0,0,?,?,?,?,?,?,?,"open")',
        (oid, board, install, iid, qty, ppu, ttl, poster, uid,
         1 if body.get('backed', True) else 0, now, exp))
    row = _order_row(conn, oid)
    if not row or row[14] != install:
        ctx['send'](403, {'error': 'id'})
        return None
    _stat(conn, install, 'orders_posted')
    conn.commit()
    return {'ok': True, 'order': _order_dicts(conn, [row])[0]}


@_route('POST', '/v1/boards/{b}/orders/{oid}/{verb}', ORDOP)
def o_verb(conn, ctx):
    spec = ORDER_VERBS.get(ctx['verb'])
    if spec is None:
        ctx['send'](404, {'error': 'not found'})
        return None
    row = _order_row(conn, ctx['oid'])
    if not row or row[1] != ctx['b'] or row[13] != 'open':
        ctx['send'](404, {'error': 'order'})
        return None
    if _expire_order(conn, ctx['oid'], ctx['now']):
        # expired under us — ops on dead orders must not apply
        # (was a live claim/fill window between expires and GC)
        ctx['send'](404, {'error': 'order'})
        return None
    if spec[0] == 'poster' and row[14] != ctx['install']:
        ctx['send'](403, {'error': 'poster'})
        return None
    return spec[1](conn, ctx, row, *spec[2:])


def _op_claim(conn, ctx, row):
    oid, body = row[0], ctx['body']
    gate = _board_write_ok(conn, ctx['b'], ctx['uid'])
    if gate:
        ctx['send'](403, {'error': gate})
        return None
    if conn.execute('SELECT 1 FROM ignores WHERE install_id=? '
                    'AND target_uuid=?',
                    (row[14], ctx['uid'])).fetchone():
        ctx['send'](403, {'error': 'ignored'})
        return None
    try:
        units = int(body.get('units'))
    except (TypeError, ValueError):
        units = 0
    if not 1 <= units <= ORDER_MAX_QTY:
        ctx['send'](400, {'error': 'units'})
        return None
    crafter = str(body.get('crafter') or '')[:24]
    cid = '%s:%s' % (ctx['install'],
                     ctx['body'].get('op') or secrets.token_hex(6))
    cur = conn.execute(
        'INSERT OR IGNORE INTO commits(id,order_id,board,'
        'install_id,crafter,crafter_uuid,units,units_filled,'
        'unit_price,created,expires,state) '
        'VALUES(?,?,?,?,?,?,?,0,?,?,?,"active")',
        (cid, oid, ctx['b'], ctx['install'], crafter, ctx['uid'],
         units, row[6], ctx['now'], min(ctx['now'] + row[7], row[12])))
    if not cur.rowcount:                # replay — same commit id
        return {'ok': True, 'commit': _commit_of(conn, ctx['b'], cid)}
    held = conn.execute(
        "UPDATE orders SET qty_held=qty_held+? WHERE id=? AND "
        "state='open' AND qty_total-qty_filled-qty_held>=?",
        (units, oid, units)).rowcount
    if not held:
        conn.execute("UPDATE commits SET state='void' WHERE id=?",
                     (cid,))
        conn.commit()
        rem = row[3] - row[4] - conn.execute(
            'SELECT qty_held FROM orders WHERE id=?',
            (oid,)).fetchone()[0]
        ctx['send'](409, {'error': 'units', 'remaining': rem})
        return None
    conn.commit()
    return {'ok': True, 'commit': _commit_of(conn, ctx['b'], cid)}


def _op_fill(conn, ctx, row):
    """Poster looted a COD — credit units to the matching commit
    and the order. Unmatched fills (no active commit) still
    count: the goods arrived, the order needs fewer units."""
    oid, body = row[0], ctx['body']
    try:
        units = int(body.get('units'))
    except (TypeError, ValueError):
        units = 0
    if not 1 <= units <= ORDER_MAX_QTY:
        ctx['send'](400, {'error': 'units'})
        return None
    c = _commit_pick(conn, oid, body)
    applied = min(units, row[3] - row[4])   # cap at order need
    if applied <= 0:
        ctx['send'](400, {'error': 'units'})
        return None
    if c:
        left = c[2] - c[3]
        take = min(applied, left)
        conn.execute(
            'UPDATE commits SET units_filled=units_filled+? '
            'WHERE id=?', (take, c[0]))
        if take >= left:
            conn.execute(
                "UPDATE commits SET state='filled' WHERE id=?",
                (c[0],))
            _stat(conn, c[1], 'commits_filled')
    conn.execute(
        'UPDATE orders SET qty_filled=qty_filled+? WHERE id=?',
        (applied, oid))
    conn.execute(
        "UPDATE orders SET state='filled' WHERE id=? AND "
        "qty_filled>=qty_total", (oid,))
    _pool_refresh(conn, oid)
    if conn.execute("SELECT state FROM orders WHERE id=?",
                    (oid,)).fetchone()[0] == 'filled':
        _stat(conn, ctx['install'], 'orders_filled')
    conn.commit()
    return {'ok': True, 'order': _order_json(conn, oid)}


def _op_reject(conn, ctx, row):
    """Poster returned a COD — the commit's unfilled units go
    back to the pool; poster's fills_rejected climbs (the stat
    crafters see)."""
    oid = row[0]
    c = _commit_pick(conn, oid, ctx['body'])
    if c:
        conn.execute(
            "UPDATE commits SET state='rejected' WHERE id=?",
            (c[0],))
        _pool_refresh(conn, oid)
    _stat(conn, ctx['install'], 'fills_rejected')
    conn.commit()
    return {'ok': True, 'order': _order_json(conn, oid)}


def _op_accept(conn, ctx, row):
    """Poster green-lights a claim — commits gain an 'accepted'
    flag the crafter sees as go-ahead signal. No state change:
    the pool stays committed either way."""
    oid = row[0]
    cid = str(ctx['body'].get('commit') or '')[:64]
    c = conn.execute(
        "SELECT id FROM commits WHERE id=? AND order_id=? AND "
        "state='active'", (cid, oid)).fetchone()
    if not c:
        ctx['send'](404, {'error': 'commit'})
        return None
    conn.execute('UPDATE commits SET accepted=1 WHERE id=?',
                 (cid,))
    conn.commit()
    return {'ok': True, 'order': _order_json(conn, oid)}


def _op_commit_end(conn, ctx, row, how):
    """Poster ends a claim before delivery. 'deny' is a polite
    refusal — units return to the pool, NO stat (the design is
    explicit: deny carries no penalty). 'force' frees the units
    of a claim that isn't delivering and books
    commits_forced against the vendor — the rating denominator."""
    oid = row[0]
    cid = str(ctx['body'].get('commit') or '')[:64]
    c = conn.execute(
        'SELECT id, install_id FROM commits WHERE id=? AND '
        "order_id=? AND state='active'", (cid, oid)).fetchone()
    if not c:
        ctx['send'](404, {'error': 'commit'})
        return None
    conn.execute("UPDATE commits SET state='released' "
                 "WHERE id=?", (cid,))
    _pool_refresh(conn, oid)
    if how == 'force':
        _stat(conn, c[1], 'commits_forced')
    conn.commit()
    return {'ok': True, 'order': _order_json(conn, oid)}


def _op_cancel(conn, ctx, row):
    """units absent/≥uncommitted pool → whole cancel (commits
    void). Fewer → pool shrinks by that much, commits keep."""
    oid = row[0]
    uncommitted = row[3] - row[4] - row[5]
    try:
        units = ctx['body'].get('units')
        units = int(units) if units is not None else None
    except (TypeError, ValueError):
        units = None
    if units is None or units >= uncommitted:
        conn.execute(
            "UPDATE commits SET state='void' WHERE order_id=? "
            "AND state='active'", (oid,))
        conn.execute(
            "UPDATE orders SET state='cancelled' WHERE id=?",
            (oid,))
        _stat(conn, row[14], 'orders_cancelled')
    else:
        if units < 1:
            ctx['send'](400, {'error': 'units'})
            return None
        conn.execute(
            'UPDATE orders SET qty_total=qty_total-? WHERE id=?',
            (units, oid))
    _pool_refresh(conn, oid)
    conn.commit()
    return {'ok': True, 'order': _order_json(conn, oid)}


# order verbs — 'poster' ops 403 unless the caller owns the order;
# 'any' ops only need the order open (claim = crafter side).
# The 'how' tail feeds the shared commit-end handler. Defined
# after the _op_* functions so the entries are real references.
ORDER_VERBS = {
    'claim':  ('any',    _op_claim),
    'fill':   ('poster', _op_fill),
    'reject': ('poster', _op_reject),
    'cancel': ('poster', _op_cancel),
    'accept': ('poster', _op_accept),
    'deny':   ('poster', _op_commit_end, 'deny'),
    'force':  ('poster', _op_commit_end, 'force'),
}


@_route('POST', '/v1/boards/{b}/commits/{cid}/release', ORDOP)
def o_release(conn, ctx):
    """Crafter gives up a hold — unfilled units return to the
    pool. Stat-free: voluntary abandon ≠ TTL flake."""
    r = conn.execute(
        "SELECT order_id, install_id, state FROM commits WHERE "
        "board=? AND id=?", (ctx['b'], ctx['cid'])).fetchone()
    if not r or r[2] != 'active':
        ctx['send'](404, {'error': 'commit'})
        return None
    if r[1] != ctx['install']:
        ctx['send'](403, {'error': 'crafter'})
        return None
    conn.execute("UPDATE commits SET state='released' WHERE id=?",
                 (ctx['cid'],))
    _pool_refresh(conn, r[0])
    conn.commit()
    return {'ok': True}


# ---- crafting writs v2: rosters + point-to-point requests ----
#
# Where buy orders are pools, writs are contracts between two install
# uuids: a customer addresses a roster owner on a shared board and the
# two negotiate inside the row itself (offer -> quote -> agreed). The
# server never moves gold or items; it is the shared source of truth
# for who promised what, with the same idempotent staged-op pipeline.

def _writ_row(conn, wid):
    return conn.execute(
        'SELECT id,board,from_install,from_uuid,from_char,'
        'to_install,to_uuid,to_char,ref,name,item_id,qty,offer,mats,'
        'deliver,note,quote,cod,mail_from,created,updated,expires,state,'
        'meet,mats_fp '
        'FROM writs WHERE id=?', (wid,)).fetchone()


def _writ_dict(r):
    (wid, board, fi, fu, fc, ti, tu, tc, ref, name, iid, qty, offer,
     mats, deliver, note, quote, cod, mail_from, created, updated,
     expires, state, meet, mats_fp) = r
    return {'id': wid, 'board': board,
            'fromUUID': fu, 'fromChar': fc,
            'toUUID': tu, 'toChar': tc,
            'ref': ref, 'name': name, 'itemID': iid, 'qty': qty,
            'offer': offer, 'mats': mats, 'deliver': deliver,
            'note': note, 'quote': quote, 'cod': cod,
            'mailFrom': mail_from, 'meet': meet, 'matsFp': mats_fp,
            'created': int(created), 'updated': int(updated),
            'expires': int(expires), 'state': state,
            # price currently on the table: the latest quote, else the
            # customer's opening offer — the UI shows ONE number
            'price': quote if quote is not None else offer}


def _expire_writ(conn, r, now):
    """Lazy expiry for live requests. An 'agreed' writ dying means the
    crafter took the job and never shipped — that lands on their
    public stats; open/quoted requests simply lapse."""
    if r[22] not in ('open', 'quoted', 'agreed') or now < r[21]:
        return r
    conn.execute("UPDATE writs SET state='expired',updated=? WHERE "
                 "id=?", (now, r[0]))
    if r[22] == 'agreed':
        _stat(conn, r[5], 'writs_expired')
    return _writ_row(conn, r[0])


def _clean_offers(raw):
    """Whitelist the packed roster payload — it arrives as a JSON
    string inside the flat staged op (the addon's OpJSON is flat)."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except (ValueError, TypeError):
            return []
    if not isinstance(raw, list):
        return []
    out = []
    for o in raw[:ROSTER_OFFER_CAP]:
        if not isinstance(o, dict) or not o.get('name'):
            continue
        price = o.get('price')
        row = {
            'ref': str(o.get('ref') or '')[:40],
            'name': str(o['name'])[:72],
            'prof': str(o.get('prof') or '')[:24],
            'kind': 'service' if o.get('kind') == 'service' else 'craft',
            'price': min(max(int(price), 0), MAX_PRICE)
                     if isinstance(price, (int, float)) else None,
            'mats': str(o.get('mats'))[:12]
                    if o.get('mats') in MATS_KINDS else None,
            'note': str(o.get('note') or '')[:96],
        }
        if o.get('itemID'):
            try:
                row['itemID'] = int(o['itemID'])
            except (TypeError, ValueError):
                pass
        try:
            row['numMade'] = max(1, min(int(o.get('numMade') or 1), 60))
        except (TypeError, ValueError):
            pass
        out.append(row)
    return out


def _clean_chars(raw):
    if isinstance(raw, str):
        raw = raw.split(',')
    if not isinstance(raw, list):
        return []
    return [str(c)[:24] for c in raw[:8] if str(c).strip()]


@_route('POST', '/v1/boards/{b}/roster', ORDOP)
def o_roster(conn, ctx):
    """Publish/replace this install's roster on a board — newest wins,
    idempotent like every staged op (same rid = same publish)."""
    gate = _board_write_ok(conn, ctx['b'], ctx['uid'])
    if gate:
        ctx['send'](403, {'error': gate})
        return None
    chars = _clean_chars(ctx['body'].get('chars'))
    offers = _clean_offers(ctx['body'].get('offers'))
    if not chars and not offers:
        ctx['send'](400, {'error': 'empty'})
        return None
    conn.execute(
        'INSERT INTO rosters(board,install_id,uuid,chars,offers,t) '
        'VALUES(?,?,?,?,?,?) ON CONFLICT(board,install_id) DO UPDATE '
        'SET chars=excluded.chars,offers=excluded.offers,t=excluded.t',
        (ctx['b'], ctx['install'], ctx['uid'],
         json.dumps(chars), json.dumps(offers), ctx['now']))
    conn.commit()
    return {'ok': True, 'offers': len(offers)}


@_route('GET', '/v1/boards/{b}/rosters', 0)
def h_rosters(conn, ctx):
    board = ctx['b']
    if not SCOPE_RE.match(board):
        ctx['send'](400, {'error': 'bad board'})
        return
    now = ctx['now']
    rows = conn.execute(
        'SELECT install_id,uuid,chars,offers,t FROM rosters WHERE '
        'board=? AND t>? ORDER BY t DESC LIMIT 64',
        (board, now - ROSTER_MAX_AGE)).fetchall()
    stats = _stats_bulk(conn, [r[0] for r in rows])
    ctx['send'](200, {'rosters': [
        {'uuid': r[1], 'chars': json.loads(r[2] or '[]'),
         'offers': json.loads(r[3] or '[]'), 't': int(r[4]),
         'stats': stats[r[0]]} for r in rows]})


def _writ_open_count(conn, install, col):
    return conn.execute(
        "SELECT COUNT(*) FROM writs WHERE %s=? AND state IN "
        "('open','quoted','agreed','shipped')" % col,
        (install,)).fetchone()[0]


@_route('POST', '/v1/writs', ORDOP)
def o_wpost(conn, ctx):
    """Address a work request to a roster owner's install uuid."""
    body, board = ctx['body'], str(ctx['body'].get('b') or '')[:48]
    if not SCOPE_RE.match(board):
        ctx['send'](400, {'error': 'bad board'})
        return None
    gate = _board_write_ok(conn, board, ctx['uid'])
    if gate:
        ctx['send'](403, {'error': gate})
        return None
    to_uuid = str(body.get('to') or '')[:64]
    if not to_uuid:
        ctx['send'](400, {'error': 'to'})
        return None
    if to_uuid == ctx['uid']:
        ctx['send'](400, {'error': 'self'})
        return None
    trow = conn.execute(
        'SELECT id FROM installs WHERE uuid=? AND COALESCE(banned,0)=0',
        (to_uuid,)).fetchone()
    if not trow:
        ctx['send'](404, {'error': 'crafter'})
        return None
    to_install = trow[0]
    if conn.execute('SELECT 1 FROM ignores WHERE install_id=? AND '
                    'target_uuid=?', (to_install, ctx['uid'])).fetchone():
        ctx['send'](403, {'error': 'ignored'})
        return None
    try:
        qty = int(body.get('qty'))
        offer = int(body.get('offer'))
    except (TypeError, ValueError):
        ctx['send'](400, {'error': 'payload'})
        return None
    if not (1 <= qty <= WRIT_MAX_QTY and 0 <= offer <= MAX_PRICE):
        ctx['send'](400, {'error': 'payload'})
        return None
    if (_writ_open_count(conn, ctx['install'], 'from_install')
            >= WRIT_OPEN_CAP or
            _writ_open_count(conn, to_install, 'to_install')
            >= WRIT_OPEN_CAP):
        ctx['send'](429, {'error': 'cap'})
        return None
    now, op = ctx['now'], ctx['body'].get('op')
    exp = body.get('expires')
    exp = min(max(float(exp), now + WRIT_TTL_MIN), now + WRIT_TTL_MAX) \
        if isinstance(exp, (int, float)) else now + WRIT_TTL_DEF
    try:
        iid = int(body.get('itemID')) if body.get('itemID') else None
    except (TypeError, ValueError):
        iid = None
    wid = '%s:%s' % (ctx['install'], op or secrets.token_hex(6))
    mats = str(body.get('mats') or 'buyer')
    mats = mats if mats in MATS_KINDS else 'buyer'
    deliver = str(body.get('deliver') or 'cod')
    deliver = deliver if deliver in DELIVER_KINDS else 'cod'
    conn.execute(
        'INSERT OR IGNORE INTO writs(id,board,from_install,from_uuid,'
        'from_char,to_install,to_uuid,to_char,ref,name,item_id,qty,'
        'offer,mats,deliver,note,created,updated,expires,state,'
        'meet,mats_fp) '
        'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,"open",?,?)',
        (wid, board, ctx['install'], ctx['uid'],
         str(body.get('fromChar') or '')[:24], to_install, to_uuid,
         str(body.get('toChar') or '')[:24],
         str(body.get('ref') or '')[:40],
         str(body.get('name') or 'Work request')[:72], iid, qty,
         offer, mats, deliver, str(body.get('note') or '')[:200],
         now, now, exp,
         str(body.get('meet') or '')[:80] or None,
         str(body.get('matsFp') or '')[:80] or None))
    conn.commit()
    return {'ok': True, 'writ': _writ_dict(_writ_row(conn, wid))}


@_route('GET', '/v1/writs', AUTH)
def h_writs(conn, ctx):
    """Private inbox/outbox — AUTH keeps point-to-point writs from
    being public read data like the open boards."""
    now = ctx['now']
    def fetch(col):
        rows = conn.execute(
            'SELECT * FROM writs WHERE %s=? AND (state NOT IN '
            "('done','declined','cancelled','expired') OR updated>?-86400)"
            ' ORDER BY updated DESC LIMIT 48' % col,
            (ctx['install'], now)).fetchall()
        return [_writ_dict(_expire_writ(conn, r, now)) for r in rows]
    out = {'in': fetch('to_install'), 'out': fetch('from_install')}
    conn.commit()
    ctx['send'](200, out)


@_route('POST', '/v1/writs/{wid}/{verb}', ORDOP)
def o_wverb(conn, ctx):
    spec = WRIT_VERBS.get(ctx['verb'])
    if not spec:
        ctx['send'](404, {'error': 'verb'})
        return None
    row = _writ_row(conn, ctx['wid'])
    if not row:
        ctx['send'](404, {'error': 'writ'})
        return None
    row = _expire_writ(conn, row, ctx['now'])
    if row[22] not in spec[1]:
        ctx['send'](409, {'error': 'state', 'state': row[22]})
        return None
    role = spec[0]
    inst = ctx['install']
    if role == 'from' and inst != row[2]:
        ctx['send'](403, {'error': 'customer'})
        return None
    if role == 'to' and inst != row[5]:
        ctx['send'](403, {'error': 'crafter'})
        return None
    if role == 'either' and inst not in (row[2], row[5]):
        ctx['send'](403, {'error': 'party'})
        return None
    res = spec[2](conn, ctx, row)
    conn.commit()
    return res


def _w_set(conn, ctx, row, state):
    conn.execute('UPDATE writs SET state=?,updated=? WHERE id=?',
                 (state, ctx['now'], row[0]))
    return {'ok': True, 'writ': _writ_dict(_writ_row(conn, row[0]))}


def _w_quote(conn, ctx, row):
    try:
        price = int(ctx['body'].get('price'))
    except (TypeError, ValueError):
        ctx['send'](400, {'error': 'price'})
        return None
    if not 0 <= price <= MAX_PRICE:
        ctx['send'](400, {'error': 'price'})
        return None
    conn.execute("UPDATE writs SET quote=?,state='quoted',updated=? "
                 'WHERE id=?', (price, ctx['now'], row[0]))
    return {'ok': True, 'writ': _writ_dict(_writ_row(conn, row[0]))}


def _w_accept(conn, ctx, row):
    # the confirming party can lock the meet-place in the same op —
    # the propose->confirm handshake then completes in ONE round
    # trip instead of two
    body = ctx['body']
    meet, mfp = body.get('meet'), body.get('matsFp')
    if meet is not None or mfp is not None:
        conn.execute(
            'UPDATE writs SET meet=COALESCE(?,meet),'
            'mats_fp=COALESCE(?,mats_fp) WHERE id=?',
            (str(meet)[:80] if meet else None,
             str(mfp)[:80] if mfp else None, row[0]))
    return _w_set(conn, ctx, row, 'agreed')


def _w_meet(conn, ctx, row):
    # arrangement updates during negotiation — propose a meet-place
    # and/or link the prepaid-mats mail fingerprint. Either field may
    # ride alone; the other party's next inbox pull IS the reply
    body = ctx['body']
    meet, mfp = body.get('meet'), body.get('matsFp')
    if meet is None and mfp is None:
        ctx['send'](400, {'error': 'payload'})
        return None
    conn.execute(
        'UPDATE writs SET meet=COALESCE(?,meet),'
        'mats_fp=COALESCE(?,mats_fp),updated=? WHERE id=?',
        (str(meet)[:80] if meet is not None else None,
         str(mfp)[:80] if mfp is not None else None,
         ctx['now'], row[0]))
    return {'ok': True, 'writ': _writ_dict(_writ_row(conn, row[0]))}


def _w_decline(conn, ctx, row):
    # a crafter declining is the only public penalty — refusing work
    # at the door is the honest negative signal for browsers
    if ctx['install'] == row[5]:
        _stat(conn, row[5], 'writs_declined')
    return _w_set(conn, ctx, row, 'declined')


def _w_ship(conn, ctx, row):
    cod = ctx['body'].get('cod')
    try:
        cod = int(cod) if cod is not None else None
        if cod is not None and not 0 <= cod <= MAX_PRICE:
            cod = None
    except (TypeError, ValueError):
        cod = None
    conn.execute(
        'UPDATE writs SET state=\'shipped\',updated=?,cod=?,'
        'mail_from=? WHERE id=?',
        (ctx['now'], cod, str(ctx['body'].get('mailFrom') or '')[:24],
         row[0]))
    return {'ok': True, 'writ': _writ_dict(_writ_row(conn, row[0]))}


def _w_recv(conn, ctx, row):
    _stat(conn, row[5], 'writs_done')
    return _w_set(conn, ctx, row, 'done')


def _w_cancel(conn, ctx, row):
    return _w_set(conn, ctx, row, 'cancelled')


# (required role, allowed source states, handler)
WRIT_VERBS = {
    'wquote':   ('to',     ('open', 'quoted'), _w_quote),
    'waccept':  ('either', ('open', 'quoted'), _w_accept),
    'wdecline': ('either', ('open', 'quoted', 'agreed'), _w_decline),
    'wship':    ('to',     ('agreed',), _w_ship),
    'wrecv':    ('from',   ('shipped',), _w_recv),
    'wcancel':  ('from',   ('open', 'quoted'), _w_cancel),
    'wmeet':    ('either', ('open', 'quoted', 'agreed'), _w_meet),
}


# ---- host admin (loopback + X-Admin-Key) ----


# ============ admin surface ============
# Same registry, different flag — loopback+key gate lives in _handle
# next to AUTH/ORDOP instead of a wildcard route with a hand-rolled
# method/path chain inside.

@_route('GET', '/v1/admin/installs', ADMIN)
def a_installs(conn, ctx):
    ctx['send'](200, {'installs': [
        {'id': r[0], 'name': r[1], 'uuid': r[2],
         'seen': r[3], 'banned': bool(r[4])}
        for r in conn.execute(
            'SELECT id,name,uuid,last_seen,banned FROM '
            'installs ORDER BY id')]})


@_route('GET', '/v1/admin/boards', ADMIN)
def a_boards(conn, ctx):
    ctx['send'](200, {'boards': [
        {'name': r[0], 'owner': r[1], 'acl': r[2],
         'members': json.loads(r[3] or '[]'),
         'closed': bool(r[4])}
        for r in conn.execute(
            'SELECT name,owner_install,post_acl,members,'
            'closed FROM boards ORDER BY name')]})


@_route('POST', '/v1/admin/boards', ADMIN)
def a_board_new(conn, ctx):
    body = ctx['body'] or {}
    name = str(body.get('name') or '')[:64]
    if not SCOPE_RE.match(name):
        ctx['send'](400, {'error': 'name'})
        return
    owner = body.get('owner')
    conn.execute(
        'INSERT OR IGNORE INTO boards(name,owner_install,'
        'post_acl,members,closed,created) VALUES(?,?,?,?,0,?)',
        (name, int(owner) if owner else None, 'open', '[]',
         ctx['now']))
    conn.commit()
    ctx['send'](200, {'ok': True})


@_route('POST', '/v1/admin/boards/{b}', ADMIN)
def a_board_set(conn, ctx):
    body = ctx['body'] or {}
    brow = _board_row(conn, ctx['b'])
    if not brow:
        ctx['send'](404, {'error': 'board'})
        return
    sets, vals = [], []
    if 'acl' in body and body['acl'] in ('open', 'members'):
        sets.append('post_acl=?')
        vals.append(body['acl'])
    if 'members' in body and isinstance(body['members'], list):
        sets.append('members=?')
        vals.append(json.dumps(
            [str(m)[:64] for m in body['members']][:200]))
    if 'closed' in body:
        sets.append('closed=?')
        vals.append(1 if body['closed'] else 0)
    if 'owner' in body:
        sets.append('owner_install=?')
        vals.append(int(body['owner'])
                    if body['owner'] else None)
    if sets:
        conn.execute('UPDATE boards SET %s WHERE name=?'
                     % ','.join(sets), vals + [ctx['b']])
        conn.commit()
    ctx['send'](200, {'ok': True})


@_route('POST', '/v1/admin/installs/{iid}', ADMIN)
def a_install_set(conn, ctx):
    body = ctx['body'] or {}
    try:
        iid = int(ctx['iid'])
    except ValueError:
        ctx['send'](400, {'error': 'id'})
        return
    if body.get('banned'):
        conn.execute('UPDATE installs SET banned=1 WHERE id=?',
                     (iid,))
        _purge_install(conn, iid)
    elif 'banned' in body:
        conn.execute('UPDATE installs SET banned=0 WHERE id=?',
                     (iid,))
    conn.commit()
    ctx['send'](200, {'ok': True})


@_route('DELETE', '/v1/admin/orders/{oid}', ADMIN)
def a_order_del(conn, ctx):
    conn.execute(
        "UPDATE commits SET state='void' WHERE order_id=? "
        "AND state='active'", (ctx['oid'],))
    conn.execute('DELETE FROM orders WHERE id=?', (ctx['oid'],))
    conn.commit()
    ctx['send'](200, {'ok': True})


def _purge_install(conn, iid):
    """Ban-side purge: the install's own orders and uploads die,
    its live commits on OTHERS' orders void (units return to
    those pools), its bookkeeping rows go."""
    oids = [r[0] for r in conn.execute(
        "SELECT DISTINCT order_id FROM commits WHERE "
        "install_id=? AND state='active'", (iid,))]
    conn.execute("UPDATE commits SET state='void' WHERE "
                 "install_id=? AND state='active'", (iid,))
    for oid in oids:
        _pool_refresh(conn, oid)
    conn.execute(
        "UPDATE commits SET state='void' WHERE state='active' "
        "AND order_id IN (SELECT id FROM orders WHERE "
        "install_id=?)", (iid,))
    conn.execute('DELETE FROM orders WHERE install_id=?', (iid,))
    for t in ('uploads', 'drop_n', 'drop_k', 'drop_name', 'rate',
              'orate', 'order_ops', 'ignores', 'install_stats'):
        conn.execute('DELETE FROM %s WHERE install_id=?' % t,
                     (iid,))
    _book_invalidate()


class Handler(BaseHTTPRequestHandler):
    """Pure plumbing: send/body/auth + the single _handle dispatch.
    Routing lives in ROUTES, op semantics in the handlers above —
    no per-method if-chains down here."""
    protocol_version = 'HTTP/1.1'

    def _send_raw(self, code, body):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send(self, code, obj):
        self._send_raw(code, json.dumps(obj).encode())

    def _body(self):
        try:
            n = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            return None
        if n <= 0 or n > 64 * 1024 * 1024:
            return None
        try:
            return json.loads(self.rfile.read(n))
        except ValueError:
            return None

    def _auth(self, conn):
        h = self.headers.get('Authorization') or ''
        if not h.startswith('Bearer '):
            return None
        row = conn.execute(
            'SELECT id FROM installs WHERE token=? '
            'AND COALESCE(banned,0)=0', (h[7:],)).fetchone()
        return row[0] if row else None

    def _admin(self):
        """Host-local administration: loopback + X-Admin-Key, both
        required — a leaked key can't be used remotely, a stolen
        cookie can't be used without the key."""
        if self.client_address[0] not in ('127.0.0.1', '::1'):
            return False
        key = _server_cfg().get('admin_key')
        if not key:
            return False
        return secrets.compare_digest(
            self.headers.get('X-Admin-Key') or '', key)

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (self.address_string(),
                                      fmt % args))

    def _handle(self, method):
        if not _allowed_ip(self.client_address[0]):
            self._send(403, {'error': 'ip'})
            return
        u = urllib.parse.urlparse(self.path)
        hit = _route_match(method, u.path)
        if hit is None:
            self._send(404, {'error': 'not found'})
            return
        fn, flags, caps = hit
        if flags & ADMIN and not self._admin():
            self._send(403, {'error': 'admin'})
            return
        conn = db()
        try:
            ctx = {'m': method, 'p': u.path,
                   'q': urllib.parse.parse_qs(u.query),
                   'send': self._send, 'send_raw': self._send_raw,
                   'is_admin': self._admin,
                   'body': self._body() if method == 'POST' else None,
                   'now': time.time(), 'install': None}
            ctx.update(caps)
            if flags & (AUTH | ORDOP):
                ctx['install'] = self._auth(conn)
                # ORDOP defers the 401 — the body may carry the
                # tunneled author's uuid+rtoken instead of a Bearer
                if ctx['install'] is None and not flags & ORDOP:
                    self._send(401, {'error': 'auth'})
                    return
            if flags & ORDOP:
                _ordop(conn, ctx, fn)
            else:
                fn(conn, ctx)
        finally:
            conn.close()

    def do_GET(self):
        self._handle('GET')

    def do_POST(self):
        self._handle('POST')

    def do_DELETE(self):
        self._handle('DELETE')


def _self_restart():
    """Same trap the watcher had: a copied-over goblin_server.py never
    reloads in a live process. Poll own mtime; on change spawn the
    replacement and exit (Popen handles spaced paths on Windows)."""
    import subprocess
    own = os.path.abspath(__file__)
    mtime = os.path.getmtime(own)
    while True:
        time.sleep(30)
        try:
            if os.path.getmtime(own) != mtime:
                subprocess.Popen([sys.executable] + sys.argv,
                                 cwd=os.getcwd())
                os._exit(0)
        except OSError:
            pass


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    bind = _bind_addr(sys.argv[2] if len(sys.argv) > 2 else None)
    init_db()
    srv = ThreadingHTTPServer((bind, port), Handler)
    threading.Thread(target=_self_restart, daemon=True).start()
    threading.Thread(target=_gc_loop, daemon=True).start()
    print('goblin backend on %s:%d -> %s' % (bind, port, DB_PATH))
    srv.serve_forever()
