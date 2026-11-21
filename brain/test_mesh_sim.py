#!/usr/bin/env python3
"""Mesh + writ simulator - the driver plays the WoW:Forever server
and the chat channel so the REAL code gets exercised end to end:

  - addon files (Orders.lua, Mesh.lua) run unmodified in a lupa
    LuaJIT runtime per client against sim/wow_stub.lua (WoW API
    shim: wire capture, GM.After scheduler, SV serialization)
  - goblin_server.py runs in-process on an ephemeral port
  - each client owns an api_state/api_book/feeds - its own install
    uuid + token, like a real install's watcher
  - goblin_brain.py consumers run patched to each client's paths:
    process_orders / process_relay / process_board_refresh /
    boards_pull / _patch_boards_emit
  - "reload" = executing the emitted Data.lua in the runtime
  - "the mesh" = routing captured wire records back through each
    client's real CHAT_MSG_ADDON handler

    python brain/test_mesh_sim.py    # exits nonzero on failure
"""
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import goblin_brain as gb
import goblin_server as gs
from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(ROOT, '..', 'addons', 'GoblinMind'))
STUB = os.path.join(ROOT, 'sim', 'wow_stub.lua')

FAILURES = []
CHECKS = [0]


def check(name, cond, detail=''):
    CHECKS[0] += 1
    print(('  ok  ' if cond else 'FAIL  ') + name +
          (f' - {detail}' if not cond else ''))
    if not cond:
        FAILURES.append(name)


# ================================================================
# client - one LuaRuntime = one WoW install + its own watcher state
# ================================================================

class Client:
    def __init__(self, world, name, url, boards, items=None):
        self.world = world
        self.name = name
        self.url = url            # textual url drives TrackerTag
        self.boards = boards      # feeds backend.boards cfg
        base = world.tmp
        self.root = os.path.join(base, 'wow', name)
        self.dir = os.path.join(self.root, 'WTF', 'Account', name,
                                'SavedVariables')
        os.makedirs(self.dir, exist_ok=True)
        self.state_path = os.path.join(base, 'state_%s.json' % name)
        self.book_path = os.path.join(base, 'book_%s.json' % name)
        self.feeds_path = os.path.join(base, 'feeds_%s.json' % name)
        self.out = os.path.join(base, 'out', name + '_Data.lua')
        os.makedirs(os.path.dirname(self.out), exist_ok=True)
        feeds = {'backend': {}}
        if url:
            feeds['backend'] = {'url': url, 'boards': boards,
                                'boards_poll_minutes': 2,
                                'name': name}
        with open(self.feeds_path, 'w') as fh:
            json.dump(feeds, fh)
        self.registered = False
        # lua side
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(open(STUB, encoding='utf-8').read())
        self.g = self.lua.globals()
        self.g._NAME = name
        self.g._NOW.t = int(time.time())
        for fn in ('Mesh.lua', 'Orders.lua'):
            src = open(os.path.join(ADDON, fn), encoding='utf-8').read()
            res = self.g.load(src, '@' + fn)
            if isinstance(res, tuple):
                fn_l, err = res
                if fn_l is None:
                    raise RuntimeError('compile failed: %s — %s'
                                       % (fn, err))
            else:
                fn_l = res
            fn_l('GoblinMind', self.g.GM)
        for iid, nm in (items or {}).items():
            self.g.ITEM_DB[iid] = self.lua.table_from(
                {'name': nm, 'link': nm})

    # -- access helpers --
    def OR(self):
        return self.g.GM.Orders

    def db(self):
        return self.g.GoblinMindSettings

    def feed(self):
        return self.g.GoblinMindDB

    # -- time / events --
    def sync_now(self):
        # monotonic: real time() never rewinds; a backward jump
        # wedges the mesh sendQ (Pump scheduled on the old clock
        # holds 'pumping' until that stale due arrives)
        self.g._NOW.t = max(float(self.g._NOW.t),
                            float(int(time.time())))

    def fire_login(self):
        self.g.fire_event('PLAYER_LOGIN')
        self.advance(45)   # join channel, T beacon, D probe

    def advance(self, secs):
        self.g._NOW.t = self.g._NOW.t + secs
        self.g.run_due()

    # -- the wire --
    def flush_wire(self):
        w = self.g._WIRE
        out = []
        for i in range(1, len(w) + 1):
            out.append({'msg': w[i].msg, 'ctype': w[i].ctype,
                        'to': w[i].to})
        self.lua.execute('_WIRE = {}')
        return out

    def deliver(self, msg, ctype, sender):
        self.g.fire_event('CHAT_MSG_ADDON', 'GoblinMind',
                          msg, ctype, sender)

    # -- the file boundary --
    def sv_write(self):
        """Serialize GoblinMindSettings - what a /reload flush writes
        and the watcher then scans."""
        p = os.path.join(self.dir, 'GoblinMind.lua')
        with open(p, 'w', encoding='utf-8') as fh:
            fh.write(self.g.SerSV())
        return p

    def sv_text(self):
        try:
            with open(os.path.join(self.dir, 'GoblinMind.lua'),
                      encoding='utf-8') as fh:
                return fh.read()
        except OSError:
            return ''

    def reload(self):
        """Execute the emitted Data.lua - the client half of /reload
        for feed data (settings persist; feed refreshes)."""
        if not os.path.exists(self.out):
            return
        with open(self.out, encoding='utf-8') as fh:
            self.lua.execute(fh.read())

    # -- board views --
    def board_names(self):
        out = []
        bs = self.OR().Boards()
        for i in range(1, len(bs) + 1):
            out.append(bs[i])
        return out

    def orders(self, board):
        os_ = self.OR().Orders(board)
        out = []
        for i in range(1, len(os_) + 1):
            o = os_[i]
            out.append({k: o[k] for k in
                        ('id', 'itemID', 'qtyTotal', 'remaining',
                         'pricePerUnit', 'state', '_pendOp',
                         'poster', 'expires') if o[k] is not None})
        return out

    def state(self):
        try:
            with open(self.state_path, encoding='utf-8') as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return {}


# ================================================================
# world - the server + the shared channel
# ================================================================

class World:
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix='gm-sim-')
        gs.DB_PATH = os.path.join(self.tmp, 'backend.db')
        gs.CFG_PATH = os.path.join(self.tmp, 'goblin_server.json')
        with open(gs.CFG_PATH, 'w') as fh:
            json.dump({'admin_key': 'sim-key'}, fh)
        gs.init_db()
        gs.Handler.log_message = lambda *a, **k: None
        self.srv = ThreadingHTTPServer(('127.0.0.1', 0), gs.Handler)
        threading.Thread(target=self.srv.serve_forever,
                         daemon=True).start()
        self.port = self.srv.server_address[1]
        self.url_a = 'http://127.0.0.1:%d' % self.port
        self.url_b = 'http://localhost:%d' % self.port  # 2nd tracker
        self.clients = {}

    def client(self, name, tracker='a', boards=('main',),
               items=None, backend=True):
        url = {'a': self.url_a, 'b': self.url_b}[tracker] \
            if backend else None
        c = Client(self, name, url, list(boards), items)
        self.clients[name] = c
        return c

    # -- the channel: route wire records like a chat server --
    def pump(self, ticks=10):
        """Deliver queued comms until quiet. Channel = broadcast
        incl. self-echo (the me-filter handles it); whisper = target
        only. Advances each client's clock past SEND_GAP every round
        so the paced sendQ pump flushes, then loops to cover handler
        replies (Q->N/W/w/Z, R->relayOut chains)."""
        for _ in range(ticks):
            for c in list(self.clients.values()):
                c.advance(0.5)
            moved = False
            for c in list(self.clients.values()):
                for m in c.flush_wire():
                    moved = True
                    if m['ctype'] == 'CHANNEL':
                        for d in self.clients.values():
                            d.deliver(m['msg'], 'CHANNEL', c.name)
                    elif m['ctype'] == 'WHISPER':
                        t = self.clients.get(m['to'])
                        if t:
                            t.deliver(m['msg'], 'WHISPER', c.name)
            if not moved:
                return

    # -- a client's watcher pass: consume its SV, hit the server,
    #    pull boards, emit - exactly the live 5s loop, compressed --
    def watcher(self, c):
        gb.API_STATE_PATH = c.state_path
        gb.API_BOOK_PATH = c.book_path
        gb.FEEDS_PATH = c.feeds_path
        c.sync_now()
        c.sv_write()
        if c.url and not c.registered:
            gb._install_uuid()
            gb._backend_register(gb._backend_cfg())
            c.registered = True
        else:
            gb._install_uuid()
        ops = gb.process_orders(None, c.root)
        gb.process_relay(None, c.root)
        gb.process_board_reqs(None, c.root)
        br = gb.process_board_refresh(None, c.root)
        if c.url:
            gb.boards_pull()
        self.emit(c)
        return ops or br

    def emit(self, c):
        """write_db once for the emitted shape, patch emit every
        pass after - same split as the live loop."""
        if not os.path.exists(c.out):
            gb.write_db({'generated': int(time.time()),
                         'feed': 'sim', 'backend': {},
                         'boards': {}, 'orderResults': {},
                         'relayResults': {}, 'items': {},
                         'realms': {}}, c.out)
        gb._patch_boards_emit([c.out])

    # -- server state --
    def db(self):
        return sqlite3.connect(gs.DB_PATH)

    def order_rows(self, board='main'):
        c = self.db()
        try:
            return list(c.execute(
                'select id,item_id,qty_total,qty_filled,'
                'price_per_unit,state,poster_uuid,expires,'
                'qty_held from orders where board=?', (board,)))
        finally:
            c.close()

    def admin(self, path, body=None):
        req = urllib.request.Request(
            self.url_a + path,
            data=json.dumps(body).encode() if body is not None
            else None,
            headers={'X-Admin-Key': 'sim-key',
                     'Content-Type': 'application/json'},
            method='POST' if body is not None else 'GET')
        return json.load(urllib.request.urlopen(req, timeout=10))

    def install_id(self, c):
        return c.state().get('backend_install_id')

    def stats(self, install_id):
        c = self.db()
        try:
            r = c.execute('select * from install_stats where '
                          'install_id=?', (install_id,)).fetchone()
            cols = [d[1] for d in c.execute(
                'pragma table_info(install_stats)')]
            return dict(zip(cols, r)) if r else {}
        finally:
            c.close()

    def expire_commit(self, cid, secs_ago=10):
        c = self.db()
        c.execute('update commits set expires=? where id=?',
                  (int(time.time()) - secs_ago, cid))
        c.commit(); c.close()

    def commit_rows(self):
        c = self.db()
        try:
            return list(c.execute(
                'select id,order_id,units,units_filled,state,'
                'accepted,crafter_uuid from commits'))
        finally:
            c.close()


# ================================================================
# scenarios
# ================================================================

def s01_post_confirm(w):
    """Baseline: post stages, watcher POSTs, result acks, pull +
    emit confirm, overlay drops the pend flag on reload."""
    a = w.client('Alpha', items={5518: 'Iron Ore'})
    a.fire_login(); w.pump()
    w.watcher(a); a.reload()      # settled client: installID in feed
    a.OR().Post('main', 5518, 10, 500, 86400)
    st_q = a.db().orderQueue
    check('post staged an ord- record', len(st_q) == 1
          and tostring_check(st_q[1], 'ord-'), st_q[1])
    pend = [o for o in a.orders('main') if o.get('_pendOp')]
    check('overlay shows pend post pre-confirm', len(pend) == 1,
          pend)
    w.watcher(a)
    rows = w.order_rows()
    check('post applied server-side', len(rows) == 1
          and rows[0][1] == 5518 and rows[0][2] == 10, rows)
    res = a.state().get('order_results', {})
    check('order_results recorded ok',
          any(r.get('ok') for r in res.values()), res)
    a.reload()
    got = a.orders('main')
    check('order visible post-reload', len(got) == 1
          and got[0].get('state') == 'open', got)
    pend = [o for o in got if o.get('_pendOp')]
    check('pend flag cleared by confirm', not pend, pend)


def s02_claim_accept_fill(w):
    """Full lifecycle: crafter claims 4 of 10, poster accepts,
    fill lands - partial fill math + commit state."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 10, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 4)
    w.watcher(cr)
    cc = w.commit_rows()
    check('commit row = 4 units active', len(cc) == 1
          and cc[0][2] == 4 and cc[0][4] == 'active', cc)
    cid = cc[0][0]
    check('crafter attributed correctly',
          cc[0][6] == cr.state().get('install_uuid'), cc[0][6])
    a.OR().Accept('main', oid, cid)
    w.watcher(a)
    cc = w.commit_rows()
    check('commit accepted', cc[0][5] == 1, cc)
    a.OR().Fill('main', oid, 4, cid)
    w.watcher(a)
    rows = w.order_rows()
    check('fill: 4/10 filled, still open', rows[0][3] == 4
          and rows[0][5] == 'open', rows)


def s03_cancel(w):
    a = w.client('Alpha')
    a.fire_login(); w.pump()
    a.OR().Post('main', 5518, 5, 100, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    a.OR().Cancel('main', oid, None)
    w.watcher(a)
    rows = w.order_rows()
    check('cancel leaves open state', not rows
          or rows[0][5] != 'open', rows)
    a.reload()
    check('cancelled order drops from view', not a.orders('main'),
          a.orders('main'))


def s04_remote_relay(w):
    """Two trackers, one channel: Xavier (tracker A) ops on 'gob'
    served by Relay (tracker B). Full tunnel: discover via T,
    register via R->watcher->Y, op via R->watcher->server B."""
    x = w.client('Xavier', tracker='a', boards=['main'])
    r = w.client('Relay', tracker='b', boards=['gob'])
    # seed gob on tracker B so Relay has a snapshot to serve
    r.fire_login(); w.pump()
    r.OR().Post('gob', 5518, 9, 700, 86400)
    w.watcher(r); r.reload()
    x.fire_login()
    w.watcher(x); x.reload()   # mesh-only still runs a watcher -
    # its emit carries install_uuid even with no backend cfg
    x.advance(40); r.advance(40); w.pump()   # T beacons both ways
    check('Xavier sees remote board via T', 'gob' in x.board_names(),
          x.board_names())
    # refresh pulls Relay's snapshot -> rboards entry
    x.OR().RefreshBoard('gob'); w.pump()
    check('remote snapshot landed', x.OR().IsRemote('gob')
          and 'gob' in x.board_names(), x.board_names())
    gobs = x.OR().Board('gob')
    check('snapshot carries the order', gobs and len(gobs.orders)
          == 1 and gobs.orders[1].itemID == 5518, gobs and
          gobs.orders and len(gobs.orders))
    # op defers behind register: R(register) -> relayOut -> server
    x.OR().Op('post', 'gob', x.lua.table_from(
            {'itemID': 5520, 'qtyTotal': 3, 'pricePerUnit': 200,
             'claimTTL': 3600, 'poster': 'Xavier', 'backed': True}))
    w.pump()                    # R register whisper -> Relay stages
    r.sv_write()
    gb.API_STATE_PATH = r.state_path
    gb.API_BOOK_PATH = r.book_path
    gb.FEEDS_PATH = r.feeds_path
    gb.process_relay(None, r.root)     # Relay's watcher POSTs reg
    w.emit(r); r.reload(); r.advance(16); w.pump()  # Y creds back
    w.pump()                    # deferred op flushes as R envelope
    r.sv_write()
    gb.process_relay(None, r.root)     # Relay's watcher POSTs op
    gb.boards_pull(); w.emit(r); r.reload()
    rows = w.order_rows('gob')
    check('relayed order applied on tracker B',
          any(o[1] == 5520 for o in rows), rows)
    hits = [o for o in rows if o[1] == 5520]
    xu = x.state().get('install_uuid')
    check('applied under ASKER uuid not relay',
          hits and hits[0][6] == xu, (hits, xu))


def s05_tag_poison(w):
    """A foreign tracker's same-named stream must not overwrite a
    local board."""
    a = w.client('Alpha')
    f = w.client('Foreign')
    a.fire_login(); f.fire_login(); w.pump()
    a.OR().Post('main', 5518, 7, 300, 86400)
    w.watcher(a); a.reload()
    f.g.GM.Mesh.Send('N', f.lua.table_from(['main;9;deadbeef']))
    f.g.GM.Mesh.Send('W', f.lua.table_from(
            ['main;9;1:evil-1;5518;99;0;99;1;3600;Eve;u-eve;'
             '999999;open;1;-']))
    f.g.GM.Mesh.Send('Z', f.lua.table_from(['main;9']))
    w.pump()
    got = a.orders('main')
    check('foreign stream rejected - board intact',
          len(got) == 1 and got[0].get('qtyTotal') == 7, got)
    check('no remote entry for local board',
          not (a.db().rboards and a.db().rboards.main),
          a.db().rboards)


def s06_item_search(w):
    """Distributed item search: Alpha's listing answers Xavier's I."""
    a = w.client('Alpha')
    x = w.client('Xavier')
    a.fire_login(); x.fire_login(); w.pump()
    a.OR().Post('main', 5518, 8, 150, 86400)
    w.watcher(a); a.reload(); x.reload(); w.pump()
    x.OR().SearchItem(5518)
    w.pump()
    rows, iid, age = x.OR().SearchRows()
    n, srcs = 0, []
    for k, r in rows.items() if rows else []:
        n += 1
        srcs.append((r.board, r.oid))
    check('search found the listing', n >= 1, srcs)


def s07_solo_refresh(w):
    """No peers answer: RefreshBoard -> 8s -> br- staged + ReloadUI;
    watcher pulls + emits; second reload sees fresh boards."""
    a = w.client('Alpha')
    a.fire_login(); w.pump()
    a.OR().Post('main', 5518, 4, 90, 86400)
    w.watcher(a); a.reload()
    a.g._RELOADS = 0
    a.OR().RefreshBoard('main')
    a.advance(9)                       # solo fallback fires
    check('refresh staged a br- request',
          bool(a.db().boardReqs and len(a.db().boardReqs) == 1),
          a.db().boardReqs and a.db().boardReqs[1])
    check('reload was requested', a.g._RELOADS >= 1, a.g._RELOADS)
    w.watcher(a)                       # sees br-, pulls, emits
    st = a.state().get('board_refresh', {})
    check('watcher consumed the br-', len(st) == 1, st)


def s08_malformed(w):
    """Garbage records on every kind must not crash handlers."""
    a = w.client('Alpha')
    f = w.client('Foreign')
    a.fire_login(); f.fire_login(); w.pump()
    for kind, body in [('T', ';;,,:'), ('Q', 'x'),
                       ('N', ';;;'), ('W', ';;;;;'),
                       ('i', 'zzz'), ('I', ';;'),
                       ('Z', 'a'), ('O', ':::'), ('D', 'x')]:
        f.g.GM.Mesh.Send(kind, f.lua.table_from([body]))
    try:
        w.pump()
        check('malformed records tolerated', True)
    except Exception as e:
        check('malformed records tolerated', False, repr(e))


def s09_dup_nonce(w):
    """Same staged op consumed twice -> one order (api_state dedup
    + server nonce dedup)."""
    a = w.client('Alpha')
    a.fire_login(); w.pump()
    a.OR().Post('main', 5518, 2, 50, 3600)
    w.watcher(a)
    gb.API_STATE_PATH = a.state_path   # second pass, same SV text
    gb.FEEDS_PATH = a.feeds_path
    gb.process_orders(None, a.root)
    check('re-scan produces no second order',
          len(w.order_rows()) == 1, w.order_rows())


def s10_phantom_reg(w):
    """Regression: stray W rows with no N pin must not persist
    phantom rboards entries."""
    a = w.client('Alpha')
    f = w.client('Foreign')
    a.fire_login(); f.fire_login(); w.pump()
    for b in ('0', '5', '7'):
        f.g.GM.Mesh.Send('W', f.lua.table_from(
                [b + ';1;x;1;1;1;1;1;1;p;u;1;open;1;-']))
    w.pump()
    check('no phantom boards in Boards()',
          not any(b in a.board_names() for b in ('0', '5', '7')),
          a.board_names())
    check('no phantom entries in rboards',
          not (a.db().rboards and any(
              b in a.db().rboards for b in ('0', '5', '7'))),
          a.db().rboards)


def s11_reject_release(w):
    """COD rejection: filled units return to the order pool."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 6, 400, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 6)
    w.watcher(cr)
    cid = w.commit_rows()[0][0]
    a.OR().Accept('main', oid, cid)
    w.watcher(a)
    a.OR().Reject('main', oid, cid)
    w.watcher(a)
    rows = w.order_rows()
    check('reject returns units - remaining restored',
          rows[0][2] - rows[0][3] == 6, rows)
    cc = w.commit_rows()
    check('commit terminal after reject',
          cc[0][4] != 'active', cc)


def s12_underfunded(w):
    """Reserve math: posts reserve gold through OR.Post itself
    (any caller), second post beyond purse reads backed=false."""
    a = w.client('Alpha')
    a.fire_login(); w.pump()
    a.db()._money = 1000
    a.OR().Post('main', 5518, 1, 700, 86400)   # reserves 700
    a.OR().Post('main', 5519, 1, 600, 86400)   # purse-left 300 < 600
    st = a.db().orderQueue
    bodies = []
    for i in range(1, len(st) + 1):
        bodies.append(json.loads(
            bytes.fromhex(st[i].split('|')[1]).decode()))
    check('first post backed', bodies[0].get('backed') is True,
          bodies[0].get('backed'))
    check('underfunded post backed=false',
          bodies[1].get('backed') is False, bodies[1].get('backed'))
    check('advisory reserve tracked',
          a.OR().ReserveTotal() == 1300, a.OR().ReserveTotal())


def s13_expiry(w):
    """Expired order leaves the pull."""
    a = w.client('Alpha')
    a.fire_login(); w.pump()
    a.OR().Post('main', 5518, 5, 100, 86400)
    w.watcher(a)
    c = w.db()
    c.execute("update orders set expires=? where board='main'",
              (int(time.time()) - 10,))
    c.commit(); c.close()
    w.watcher(a); a.reload()
    got = a.orders('main')
    check('expired order not open in view',
          not got or all(o.get('state') != 'open' for o in got), got)


def s15_commit_ttl(w):
    """Commit TTL expiry: an un-mailed claim releases back to the
    pool on the next pull, stat-booked as commits_expired."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 10, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 4)
    w.watcher(cr)
    cid = w.commit_rows()[0][0]
    w.expire_commit(cid)
    w.watcher(a)                    # pull sweeps expired commits
    cc = w.commit_rows()
    check('expired commit released', cc[0][4] == 'released', cc)
    rows = w.order_rows()
    check('units back in pool', rows[0][8] == 0, rows)
    st = w.stats(w.install_id(cr))
    check('commits_expired booked', st.get('commits_expired') == 1,
          st)


def s16_deny(w):
    """Poster politely ends a claim - units return, NO stat (deny
    carries no penalty by design)."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 5, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 3)
    w.watcher(cr)
    cid = w.commit_rows()[0][0]
    a.OR().Deny('main', oid, cid)
    w.watcher(a)
    cc = w.commit_rows()
    check('denied commit released', cc[0][4] == 'released', cc)
    rows = w.order_rows()
    check('deny returns units', rows[0][8] == 0, rows)
    st = w.stats(w.install_id(cr))
    check('deny books no stat', not st.get('commits_forced'), st)


def s17_force(w):
    """Poster force-frees a claim - units return and the crafter
    takes a commits_forced rating hit."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 5, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 3)
    w.watcher(cr)
    cid = w.commit_rows()[0][0]
    a.OR().Force('main', oid, cid)
    w.watcher(a)
    cc = w.commit_rows()
    check('forced commit released', cc[0][4] == 'released', cc)
    st = w.stats(w.install_id(cr))
    check('force books commits_forced',
          st.get('commits_forced') == 1, st)


def s18_release(w):
    """Crafter gives up a hold - unfilled units return, stat-free."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 5, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 3)
    w.watcher(cr)
    cid = w.commit_rows()[0][0]
    cr.OR().Release('main', cid, oid)
    w.watcher(cr)
    cc = w.commit_rows()
    check('released commit terminal', cc[0][4] == 'released', cc)
    rows = w.order_rows()
    check('release returns units', rows[0][8] == 0, rows)


def s19_ignore(w):
    """Personal ignore: a poster-ignored crafter cannot claim."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    w.watcher(cr)                        # Crafty's uuid registered
    cu = cr.state().get('install_uuid')
    a.OR().Ignore(cu, True)
    a.OR().Post('main', 5518, 5, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 2)
    w.watcher(cr)
    res = cr.state().get('order_results', {})
    last = max(res.values(), key=lambda r: r.get('t') or 0) \
        if res else {}
    check('ignored crafter claim 403 ignored',
          last.get('code') == 403 and last.get('error') == 'ignored',
          last)
    check('no commit created', not w.commit_rows(), w.commit_rows())


def s20_board_ban(w):
    """Board-owner ban: a banned uuid cannot write the board."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    w.watcher(a); w.watcher(cr)
    aid = w.install_id(a)
    w.admin('/v1/admin/boards', {'name': 'vip', 'owner': aid})
    cu = cr.state().get('install_uuid')
    a.OR().BoardBan('vip', cu, True)
    w.watcher(a)
    cr.OR().Post('vip', 5518, 2, 100, 3600)
    w.watcher(cr)
    res = cr.state().get('order_results', {})
    last = max(res.values(), key=lambda r: r.get('t') or 0) \
        if res else {}
    check('banned poster gets 403 board_ban',
          last.get('code') == 403
          and last.get('error') == 'board_ban', last)
    check('no order on vip', not w.order_rows('vip'),
          w.order_rows('vip'))


def s21_host_ban(w):
    """Host ban: purge kills orders + voids live commits, banned
    install's ops 401, and the ban survives re-register."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 10, 500, 86400)
    cr.OR().Post('main', 5519, 2, 300, 86400)
    w.watcher(a); w.watcher(cr)
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 4)
    w.watcher(cr)
    cid = w.install_id(cr)
    w.admin('/v1/admin/installs/%d' % cid, {'banned': True})
    check('banned installs own orders purged',
          all(r[1] != 5519 for r in w.order_rows()), w.order_rows())
    cc = w.commit_rows()
    check('banned installs commits voided',
          not cc or all(c[4] != 'active' for c in cc), cc)
    rows = w.order_rows()
    check('pool restored on victim order',
          rows[0][8] == 0 and rows[0][5] == 'open', rows)
    rid = cr.OR().Claim('main', oid, 1)
    w.watcher(cr)
    res = cr.state().get('order_results', {})
    check('banned install op rejected',
          res.get(rid) and res[rid].get('code') == 401,
          res.get(rid))
    # ban survives a re-register (same name re-keys, not unbans)
    gb.API_STATE_PATH = cr.state_path
    gb.API_BOOK_PATH = cr.book_path
    gb.FEEDS_PATH = cr.feeds_path
    st = gb._load_api_state()
    st.pop('backend_uuid_sent', None)
    gb._save_api_state(st)
    gb._backend_register(gb._backend_cfg())
    rid = cr.OR().Claim('main', oid, 1)
    w.watcher(cr)
    res = cr.state().get('order_results', {})
    check('ban survives re-register',
          res.get(rid) and res[rid].get('code') == 401,
          res.get(rid))


def s22_contention(w):
    """Two crafters race a 5-unit pool - over-claim 409s with the
    true remaining, second claim fills the last unit."""
    a = w.client('Alpha')
    c1 = w.client('Crafter1')
    c2 = w.client('Crafter2')
    a.fire_login(); c1.fire_login(); c2.fire_login(); w.pump()
    a.OR().Post('main', 5518, 5, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    c1.OR().Claim('main', oid, 4)
    w.watcher(c1)
    rid = c2.OR().Claim('main', oid, 4)
    w.watcher(c2)
    res = c2.state().get('order_results', {})
    check('over-claim 409 with remaining=1',
          res.get(rid) and res[rid].get('code') == 409
          and res[rid].get('remaining') == 1, res.get(rid))
    c2.OR().Claim('main', oid, 1)
    w.watcher(c2)
    cc = [r for r in w.commit_rows() if r[4] == 'active']
    check('two active commits 4+1',
          len(cc) == 2 and sorted(r[2] for r in cc) == [1, 4], cc)
    rows = w.order_rows()
    check('remaining zero',
          rows[0][2] - rows[0][3] - rows[0][8] == 0, rows)
    rid = c1.OR().Claim('main', oid, 1)
    w.watcher(c1)
    res = c1.state().get('order_results', {})
    check('exhausted pool 409 remaining=0',
          res.get(rid) and res[rid].get('code') == 409
          and res[rid].get('remaining') == 0, res.get(rid))


def s23_partial_cancel(w):
    """Partial cancel shrinks qty_total; live commits keep."""
    a = w.client('Alpha')
    cr = w.client('Crafty')
    a.fire_login(); cr.fire_login(); w.pump()
    a.OR().Post('main', 5518, 10, 500, 86400)
    w.watcher(a); a.reload()
    oid = w.order_rows()[0][0]
    cr.OR().Claim('main', oid, 4)
    w.watcher(cr)
    a.OR().Cancel('main', oid, 3)
    w.watcher(a)
    rows = w.order_rows()
    check('qty_total shrank 10->7', rows[0][2] == 7, rows)
    cc = w.commit_rows()
    check('commit survives partial cancel',
          cc[0][4] == 'active' and cc[0][2] == 4, cc)


def s24_join_leave(w):
    """In-game board join: staged bo- req updates feeds.json, the
    pull starts covering the board, the addon stops calling it
    remote."""
    a = w.client('Alpha')
    a.fire_login(); w.pump()
    a.OR().JoinBoard('vip', True)
    st = a.db().boardReqs
    check('join staged a bo- record',
          st is not None and 'bo-' in (st[1] or ''), st and st[1])
    w.watcher(a)
    feeds = json.load(open(a.feeds_path))
    check('feeds.boards gained vip',
          'vip' in feeds['backend'].get('boards', []),
          feeds['backend'])
    a.reload()
    check('vip no longer remote', not a.OR().IsRemote('vip'),
          a.OR().IsRemote('vip'))
    a.OR().JoinBoard('vip', False)
    w.watcher(a)
    feeds = json.load(open(a.feeds_path))
    check('leave drops vip',
          'vip' not in feeds['backend'].get('boards', []),
          feeds['backend'])


def s25_remote_claim(w):
    """A tunneled peer claims through the relay - the commit lands
    on tracker B under the asker's install."""
    x = w.client('Xavier', tracker='a', boards=['main'])
    r = w.client('Relay', tracker='b', boards=['gob'])
    r.fire_login(); w.pump()
    r.OR().Post('gob', 5518, 8, 700, 86400)
    w.watcher(r); r.reload()
    x.fire_login()
    w.watcher(x); x.reload()
    x.advance(40); r.advance(40); w.pump()
    x.OR().RefreshBoard('gob'); w.pump()
    oid = x.OR().Board('gob').orders[1].id
    x.OR().Claim('gob', oid, 3)
    w.pump()                 # R register whisper -> Relay stages
    r.sv_write()
    gb.API_STATE_PATH = r.state_path
    gb.API_BOOK_PATH = r.book_path
    gb.FEEDS_PATH = r.feeds_path
    gb.process_relay(None, r.root)     # Relay POSTs the register
    w.emit(r); r.reload(); r.advance(16); w.pump()  # Y creds back
    w.pump()                 # deferred claim flushes as R envelope
    r.sv_write()
    gb.process_relay(None, r.root)     # Relay POSTs the claim
    gb.boards_pull(); w.emit(r); r.reload()
    cc = w.commit_rows()
    check('remote claim made a commit on tracker B',
          len(cc) == 1 and cc[0][2] == 3, cc)
    check('commit under asker install',
          cc[0][6] == x.state().get('install_uuid'), cc)


def tostring_check(v, needle):
    return isinstance(v, str) and needle in v


def s14_beacon_no_hijack(w):
    """Regression: a peer T-beacon for our own board name must not
    mark it remote — ops go to OUR backend, not the tunnel."""
    a = w.client('Alpha')
    p = w.client('Peer')
    a.fire_login(); w.pump()
    w.watcher(a); a.reload()
    # peer advertises the same board name (same swarm) -> Alpha's
    # peers map gains 'main' but IsRemote must stay false
    a.deliver('1|T|Sim-Realm-A|main:deadbeef', 'CHANNEL', 'Peer')
    check('peers recorded', a.OR().relay.peers.main is not None)
    check('configured board never remote',
          a.OR().IsRemote('main') is False)
    a.OR().Post('main', 5518, 3, 50, 3600)
    check('op staged locally not relayed',
          a.db().relayPend is None or len(a.db().relayPend) == 0)
    w.watcher(a)
    res = a.state().get('order_results', {})
    check('op hit own backend directly',
          any(r.get('ok') for r in res.values()), res)


SCENARIOS = [
    ('post -> confirm', s01_post_confirm),
    ('claim -> accept -> fill', s02_claim_accept_fill),
    ('cancel', s03_cancel),
    ('remote relay full tunnel', s04_remote_relay),
    ('foreign tag poison', s05_tag_poison),
    ('item search', s06_item_search),
    ('solo refresh', s07_solo_refresh),
    ('malformed records', s08_malformed),
    ('duplicate nonce', s09_dup_nonce),
    ('phantom board regression', s10_phantom_reg),
    ('beacon does not hijack local board', s14_beacon_no_hijack),
    ('commit ttl expiry', s15_commit_ttl),
    ('deny', s16_deny),
    ('force', s17_force),
    ('crafter release', s18_release),
    ('personal ignore', s19_ignore),
    ('board ban', s20_board_ban),
    ('host ban purge', s21_host_ban),
    ('multi-crafter contention', s22_contention),
    ('partial cancel', s23_partial_cancel),
    ('board join/leave', s24_join_leave),
    ('remote claim via tunnel', s25_remote_claim),
    ('reject releases units', s11_reject_release),
    ('underfunded post', s12_underfunded),
    ('order expiry', s13_expiry),
]


def main():
    for name, fn in SCENARIOS:
        print('- ' + name)
        try:
            fn(World())
        except Exception:
            import traceback
            traceback.print_exc()
            check(name + ' ran clean', False, 'exception')
    print()
    if FAILURES:
        print('%d of %d checks FAILED' % (len(FAILURES), CHECKS[0]))
        for f in FAILURES:
            print('  FAIL ' + f)
        sys.exit(1)
    print('all %d checks passed' % CHECKS[0])


if __name__ == '__main__':
    main()
