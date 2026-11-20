#!/usr/bin/env python3
"""GoblinMind backend service — the crowdsourced feed.

Deliberately dumb: it stores per-install book snapshots, merges them
newest-wins per item, and serves the merged book. All price math
(mkt/hist/recent/sales) stays client-side in goblin_brain.py — pulled
books feed each install's book_history like any other book, so stats
evolve from the merged feed without the server knowing statistics.

Endpoints (all JSON):
  POST /v1/register  {name}                      -> {install_id, token}
  POST /v1/upload    Authorization: Bearer tok   {scope, t, items, lots?}
  GET  /v1/book?scope=S                          -> {scope, t, items, lots}
  GET  /v1/health                                -> {ok, scopes}

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


class Handler(BaseHTTPRequestHandler):
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
        row = conn.execute('SELECT id FROM installs WHERE token=?',
                           (h[7:],)).fetchone()
        return row[0] if row else None

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (self.address_string(),
                                      fmt % args))

    def do_GET(self):
        if not _allowed_ip(self.client_address[0]):
            self._send(403, {'error': 'ip'})
            return
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        conn = db()
        try:
            if u.path == '/v1/health':
                scopes = [r[0] for r in conn.execute(
                    'SELECT DISTINCT scope FROM uploads')]
                installs = [{'name': name, 'uuid': uid,
                             'scopes': (scs or '').split(',')
                             if scs else [],
                             'uploads': n, 'last': last, 'seen': seen}
                            for name, uid, scs, n, last, seen in
                            conn.execute(
                        'SELECT i.name, i.uuid, '
                        'GROUP_CONCAT(DISTINCT u.scope), '
                        'COUNT(u.id), MAX(u.t), i.last_seen '
                        'FROM installs i '
                        'LEFT JOIN uploads u ON u.install_id=i.id '
                        'GROUP BY i.id ORDER BY i.name')]
                self._send(200, {'ok': True, 'scopes': scopes,
                                 'installs': installs})
            elif u.path == '/v1/scopes':
                # open like health — lets installers offer real scope
                # choices instead of asking the user to type one
                scopes = [r[0] for r in conn.execute(
                    'SELECT DISTINCT scope FROM uploads')]
                self._send(200, {'scopes': scopes})
            elif u.path == '/v1/book':
                scope = (q.get('scope') or [''])[0]
                if not SCOPE_RE.match(scope):
                    self._send(400, {'error': 'bad scope'})
                    return
                self._send_raw(200, book_json(conn, scope))
            else:
                self._send(404, {'error': 'not found'})
        finally:
            conn.close()

    def do_POST(self):
        if not _allowed_ip(self.client_address[0]):
            self._send(403, {'error': 'ip'})
            return
        u = urllib.parse.urlparse(self.path)
        conn = db()
        try:
            if u.path == '/v1/register':
                body = self._body() or {}
                secret = _server_cfg().get('install_secret')
                if secret and not secrets.compare_digest(
                        str(body.get('key') or ''), secret):
                    self._send(403, {'error': 'key'})
                    return
                name = str(body.get('name') or 'install')[:64]
                # client-supplied stable id — 'who is who' without
                # handmade accounts; COALESCE keeps a stored uuid
                # when a re-register doesn't send one
                uid = str(body.get('uuid') or '')[:64] or None
                row = conn.execute(
                    'SELECT id FROM installs WHERE name=?',
                    (name,)).fetchone()
                tok = secrets.token_urlsafe(24)
                if row:
                    # re-register = re-key the existing install (lost
                    # api_state / reinstall) — no zombie rows per name
                    conn.execute(
                        'UPDATE installs SET token=?, '
                        'uuid=COALESCE(?, uuid) WHERE id=?',
                        (tok, uid, row[0]))
                    conn.commit()
                    self._send(200, {'install_id': row[0],
                                     'token': tok,
                                     'uuid': uid or _install_uuid(
                                         conn, row[0])})
                    return
                cur = conn.execute(
                    'INSERT INTO installs(name, token, uuid, created) '
                    'VALUES(?,?,?,?)',
                    (name, tok, uid, time.time()))
                conn.commit()
                self._send(200, {'install_id': cur.lastrowid,
                                 'token': tok, 'uuid': uid})
                return
            install = self._auth(conn)
            if install is None:
                self._send(401, {'error': 'auth'})
                return
            if u.path != '/v1/upload':
                self._send(404, {'error': 'not found'})
                return
            # 10 uploads / 10 minutes per install
            bucket = time.time() // 600
            conn.execute(
                'INSERT INTO rate(install_id,bucket,n) VALUES(?,?,1) '
                'ON CONFLICT(install_id,bucket) DO UPDATE SET n=n+1',
                (install, bucket))
            if (conn.execute('SELECT n FROM rate WHERE install_id=? '
                             'AND bucket=?', (install, bucket))
                    .fetchone()[0]) > 10:
                conn.commit()
                self._send(429, {'error': 'rate'})
                return
            body = self._body()
            if not isinstance(body, dict):
                self._send(400, {'error': 'body'})
                return
            scope = str(body.get('scope') or '')
            t = body.get('t')
            items = clean_items(body.get('items'))
            lots = body.get('lots') or {}
            if not SCOPE_RE.match(scope) or not isinstance(
                    t, (int, float)) or not items or \
                    len(items) > MAX_ITEMS:
                self._send(400, {'error': 'payload'})
                conn.commit()
                return
            lots = {str(k): int(v) for k, v in lots.items()
                    if isinstance(v, (int, float))}
            # t is client-claimed and drives newest-wins, the staleness
            # cutoff, and GC — a book can't be newer than now, so cap
            # future dates. Past values pass through: an old scan
            # uploaded late is legitimately old data.
            t = min(float(t), time.time())
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
                         (time.time(), install))
            conn.commit()
            _book_invalidate(scope)
            self._send(200, {'ok': True, 'items': len(items)})
        finally:
            conn.close()


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
