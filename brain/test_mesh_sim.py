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


def ltab(c, obj):
    """Recursive dict/list -> real Lua tables. lupa's table_from
    only converts the outer container — nested dicts land as
    userdata proxies that fail the addon's type(x)=='table' guards
    (shopOffers rows, shopTerms entries)."""
    if isinstance(obj, dict):
        return c.lua.table_from(
            {k: ltab(c, v) for k, v in obj.items()})
    if isinstance(obj, (list, tuple)):
        return c.lua.table_from([ltab(c, v) for v in obj])
    return obj


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
        for fn in ('Mesh.lua', 'Orders.lua', 'Writs.lua'):
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

    def W(self):
        return self.g.GM.Writs

    def Mesh(self):
        return self.g.GM.Mesh

    # -- channel membership (v2 two-bus model) --
    def chan_fail(self, chan):
        """JoinChannelByName(chan) will silently fail — like WoW's
        10-custom-channel cap kicking in."""
        self.g._JOIN_FAIL[chan] = True

    def leave_chan(self, chan):
        self.g._JOINED[chan] = None

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
        # 10s covers TryJoin(4s) + margin. The 30s/40s beacon/D
        # tasks stay pending — scenarios seed boards via
        # watcher+reload first, and pump()'s settle pass fires
        # them when the wire goes quiet (real order: addon boot
        # loads the DB long before the beacon timer)
        self.advance(10)

    def advance(self, secs):
        self.g._NOW.t = self.g._NOW.t + secs
        self.g.run_due()

    def next_due(self):
        t = self.g._TASKS
        nxt = None
        for i in range(1, len(t) + 1):
            d = t[i].due
            if d is not None and (nxt is None or d < nxt):
                nxt = d
        return nxt

    # -- the wire --
    def flush_wire(self):
        w = self.g._WIRE
        out = []
        for i in range(1, len(w) + 1):
            out.append({'msg': w[i].msg, 'ctype': w[i].ctype,
                        'to': w[i].to, 'chan': w[i].chan})
        self.lua.execute('_WIRE = {}')
        return out

    def joined(self, chan):
        """Is this client a member of the named channel?"""
        return bool(self.g._JOINED[chan])

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

    _WRIT_KEYS = ('id', 'board', 'state', 'name', 'ref', 'itemID',
                  'qty', 'offer', 'price', 'quote', 'mats', 'deliver',
                  'meet', 'cod', 'mailFrom', 'matsFp', 'fromUUID',
                  'toUUID', 'fromChar', 'toChar', '_pendOp', '_live',
                  '_side', 'updated', 'created', 'expires')

    def writs(self, side=None):
        """GM.Writs.Writs() -> {inb:[], out:[]} rows as plain dicts.
        side=None returns both lists merged."""
        v = self.W().Writs()
        out = []
        for s in ([side] if side else ('inb', 'out')):
            lst = v[s]
            for i in range(1, len(lst) + 1):
                o = lst[i]
                out.append({k: o[k] for k in self._WRIT_KEYS
                            if o[k] is not None})
        return out

    def rosters(self, board):
        rs = self.W().Rosters(board)
        out = []
        for i in range(1, len(rs) + 1):
            r = rs[i]
            offers = r.offers
            out.append({'uuid': r.uuid,
                        'chars': [r.chars[j] for j in
                                  range(1, len(r.chars) + 1)]
                        if r.chars else [],
                        'offers': [
                            {k: offers[j][k] for k in
                             ('ref', 'name', 'prof', 'itemID', 'kind',
                              'price', 'mats', 'note', 'numMade')
                             if offers[j][k] is not None}
                            for j in range(1, len(offers) + 1)]
                        if offers else []})
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
        # every wire message the pump routed — v2 scenarios count
        # by kind/channel to assert bounded responders
        self.wire_log = []

    def client(self, name, tracker='a', boards=('main',),
               items=None, backend=True):
        url = self.url_for(tracker) if backend else None
        c = Client(self, name, url, list(boards), items)
        self.clients[name] = c
        return c

    def url_for(self, tracker):
        """TrackerTag hashes the configured url STRING, not the
        host it resolves to — hostname case permutations all reach
        this server but hash as distinct trackers. 'a'/'b' keep
        their readable forms."""
        if tracker == 'a':
            return self.url_a
        if tracker == 'b':
            return self.url_b
        # stable per key — two installs on one tracker must share
        # the tag; distinct keys get distinct case permutations
        self._turls = getattr(self, '_turls', {})
        if tracker not in self._turls:
            perm = len(self._turls) + 1
            host = ''.join(
                ch.upper() if (perm >> i) & 1 else ch
                for i, ch in enumerate('localhost'))
            self._turls[tracker] = 'http://%s:%d' % (host,
                                                     self.port)
        return self._turls[tracker]

    # -- the channel: route wire records like a chat server --
    def pump(self, ticks=10):
        """Deliver queued comms until quiet. Channel = broadcast
        incl. self-echo (the me-filter handles it); whisper = target
        only. Advances each client's clock past SEND_GAP every round
        so the paced sendQ pump flushes, then loops to cover handler
        replies (Q->N/W/w/Z, R->relayOut chains)."""
        for _ in range(ticks):
            # drain in-flight wire BEFORE advancing clocks — real
            # clients receive queued messages before more time
            # passes; advancing first lets a jittered task overtake
            # a message that would have suppressed it
            moved = False
            for c in list(self.clients.values()):
                for m in c.flush_wire():
                    moved = True
                    if m['msg'].startswith('1|'):
                        self.wire_log.append(
                            {'from': c.name, 'ctype': m['ctype'],
                             'chan': m['chan'],
                             'kind': m['msg'].split('|', 3)[1]})
                    if m['ctype'] == 'CHANNEL':
                        # two buses now — a message on goblinwritx
                        # only reaches clients joined there
                        chan = m['chan']
                        for d in self.clients.values():
                            if chan is None or d.joined(chan):
                                d.deliver(m['msg'], 'CHANNEL',
                                          c.name)
                    elif m['ctype'] == 'WHISPER':
                        t = self.clients.get(m['to'])
                        if t:
                            t.deliver(m['msg'], 'WHISPER', c.name)
            if not moved:
                # settle: wire quiet but tasks may be pending
                # (beacon, D, offer-select). Advance EVERY client
                # to the global earliest due time — wall-clock
                # stays shared across clients like real WoW, so a
                # server's 1.5s offer can't lose to the asker's
                # 2.5s selection window just because the settle
                # jumped the asker first
                best = None
                for c in self.clients.values():
                    d = c.next_due()
                    if d is not None and (best is None or d < best):
                        best = d
                if best is None:
                    return
                now = min(c.g._NOW.t for c in self.clients.values())
                if best - now > 60:   # don't chase the 280s advTick
                    return
                for c in self.clients.values():
                    c.advance(max(0, best - c.g._NOW.t))

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
        gb.process_writs(None, c.root)
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
                         'rosters': {}, 'writs': {},
                         'writResults': {},
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
    x.OR().RefreshBoard('gob'); w.pump(16)  # Q->F offers->P->stream
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
    x.OR().RefreshBoard('gob'); w.pump(16)
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


# ---- v2 scenarios: channel split, offer/pull, suppression ----

def s26_channel_split(w):
    """Two buses: writ kinds ride goblinwritx only, market kinds
    goblinmindx only. A client that can't join one bus neither
    hears it nor sends on it — and its other bus keeps working."""
    mo = w.client('MarketOnly', tracker='a', boards=['main'])
    wo = w.client('WritOnly', tracker='a', boards=['main'])
    r = w.client('Relay', tracker='b', boards=['gob'])
    mo.chan_fail('goblinwritx')
    wo.chan_fail('goblinmindx')
    mo.fire_login(); wo.fire_login(); r.fire_login()
    w.watcher(r); r.reload()   # boards must exist pre-beacon
    r.advance(40); wo.advance(40); mo.advance(40); w.pump(8)
    # Relay's T beacon rode the writ channel
    tmsgs = [m for m in w.wire_log if m['kind'] == 'T']
    check('T beacons ride goblinwritx',
          tmsgs and all(m['chan'] == 'goblinwritx' for m in tmsgs),
          tmsgs)
    # WritOnly heard it; MarketOnly (not a member) did not
    check('writ member sees peers', 'gob' in
          list(wo.OR().relay.peers.keys()), wo.board_names())
    check('market-only blind to writ bus',
          'gob' not in list(mo.OR().relay.peers.keys()),
          mo.board_names())
    # market kind goes to goblinmindx — MarketOnly ingests,
    # WritOnly (not a member) never sees it
    r.Mesh().Send('M', r.lua.table_from(['2589:2500:500']))
    w.pump()
    check('M record rode goblinmindx',
          any(m['kind'] == 'M' and m['chan'] == 'goblinmindx'
              for m in w.wire_log), w.wire_log[-3:])
    check('market member staged beacon',
          mo.Mesh().LatestMB(2589) is not None, 'no mb')
    check('writ-only blind to market bus',
          wo.Mesh().LatestMB(2589) is None, 'mb leaked')
    # MarketOnly cannot send writ kinds — M.Send drops silently
    before = len(w.wire_log)
    mo.Mesh().Send('T', mo.lua.table_from(['gob:x']))
    w.pump()
    check('unjoined writ send dropped not queued',
          not any(m['from'] == 'MarketOnly' and m['kind'] == 'T'
                  for m in w.wire_log[before:]),
          w.wire_log[before:])
    # but its whisper transport still works (no channel needed)
    mo.Mesh().Whisper('WritOnly', 'R', 'gob;-;-;-;x')
    w.pump()
    check('whisper rides with no channel',
          any(m['from'] == 'MarketOnly' and m['ctype'] == 'WHISPER'
              for m in w.wire_log[before:]), w.wire_log[before:])


def s27_offer_pull(w):
    """One asker, two servers on foreign trackers serving 'gob'.
    Q produces tiny F offers, the asker picks ONE (P), and exactly
    one N/W/w/Z stream lands — the second server never streams."""
    x = w.client('Xavier', tracker='a', boards=['main'])
    r1 = w.client('Relay1', tracker='b', boards=['gob'])
    r2 = w.client('Relay2', tracker='c', boards=['gob'])
    r1.fire_login(); r2.fire_login(); w.pump()
    r1.OR().Post('gob', 5518, 9, 700, 86400)
    r2.OR().Post('gob', 5520, 4, 300, 86400)
    w.watcher(r1); r1.reload()
    w.watcher(r2); r2.reload()
    x.fire_login(); w.watcher(x); x.reload()
    x.advance(40); r1.advance(40); r2.advance(40); w.pump()
    before = len(w.wire_log)
    x.OR().RefreshBoard('gob'); w.pump(16)
    seg = w.wire_log[before:]
    qs = [m for m in seg if m['kind'] == 'Q']
    fs = [m for m in seg if m['kind'] == 'F']
    ps = [m for m in seg if m['kind'] == 'P']
    ns = [m for m in seg if m['kind'] == 'N']
    check('Q went out with nonce', len(qs) == 1, qs)
    check('at least one F offer', len(fs) >= 1, fs)
    check('exactly one P selection', len(ps) == 1, ps)
    check('exactly one stream announced', len(ns) == 1, ns)
    ws_ = [m for m in seg if m['kind'] in ('W', 'w', 'Z')]
    check('stream rows from the selected sender only',
          ws_ and all(m['from'] == ns[0]['from']
                      for m in ws_), ws_[:4])
    gobs = x.OR().Board('gob')
    # one sim server = one 'gob' board — both posters' orders are
    # legitimate board state, all carried by the single winner's
    # stream; the pin is consumed when Z lands
    check('snapshot landed via v2 flow',
          gobs and len(gobs.orders or {}) == 2,
          gobs and len(gobs.orders or {}))
    check('stream pin consumed on Z',
          x.OR().relay.src['gob'] is None,
          dict(x.OR().relay.src))


def s28_coverage_suppression(w):
    """Trickle-lite: 6 beaconers on 'gob' — once each hears >=K_REP
    fresh peers, its next beacon suppresses. A newcomer's D probe
    gets zero re-beacons from a covered swarm."""
    srvs = [w.client('Srv%d' % i, tracker='t%d' % i,
                     boards=['gob']) for i in range(6)]
    for c in srvs:
        c.fire_login()
    for c in srvs:
        w.watcher(c); c.reload()
    w.pump(20)
    # wave 1: clients beacon before coverage forms
    first = [m for m in w.wire_log if m['kind'] == 'T']
    n0 = len(first)
    check('initial beacons bounded', 0 < n0 <= 6, n0)
    # suppressed swarm breathes: once every heard beacon AND
    # selfAdv cross the 600s TTL the board is dark again — the
    # swarm re-beacons exactly once (liveness: dead coverage
    # self-heals), then the NEXT tick is silent because the
    # burst re-established coverage
    mark = len(w.wire_log)
    for c in srvs:
        c.advance(300)
    w.pump(20)
    second = [m for m in w.wire_log[mark:] if m['kind'] == 'T']
    check('stale coverage bursts once not per-tick',
          len(second) <= 6, len(second))
    mark = len(w.wire_log)
    for c in srvs:
        c.advance(300)
    w.pump(20)
    third = [m for m in w.wire_log[mark:] if m['kind'] == 'T']
    check('post-burst tick silent again', len(third) <= 1,
          len(third))
    # newcomer with an unserved board probes; servers covered for
    # 'gob' must not re-beacon at it
    x = w.client('Newb', tracker='tg', boards=['newb'])
    x.fire_login(); w.pump(10)
    x.advance(50)
    mark = len(w.wire_log)
    w.pump(12)
    ds = [m for m in w.wire_log if m['kind'] == 'D'
          and m['from'] == 'Newb']
    check('newcomer probed the dark board', len(ds) >= 1, ds)
    ts = [m for m in w.wire_log[mark:] if m['kind'] == 'T']
    check('D drew zero re-beacons from covered swarm',
          len(ts) == 0, len(ts))


def s29_offer_suppression(w):
    """A server whose dom already holds an equal-or-fresher F for
    the nonce never transmits its own — mDNS duplicate-answer
    suppression. (Offers colliding inside one sendQ gap are an
    accepted bounded residual — s27's single-stream invariant is
    what actually bounds the heavy traffic.)"""
    s1 = w.client('Srv1', tracker='b', boards=['gob'])
    s2 = w.client('Srv2', tracker='c', boards=['gob'])
    s1.fire_login(); s2.fire_login(); w.pump()
    s1.OR().Post('gob', 5518, 9, 700, 86400)
    s2.OR().Post('gob', 5518, 9, 700, 86400)
    w.watcher(s1); s1.reload()
    w.watcher(s2); s2.reload()
    s1.g.GoblinMindDB.boards.gob.t = 1000
    s2.g.GoblinMindDB.boards.gob.t = 1000
    # Srv2 already heard an equal offer for this nonce — its
    # deferred check must suppress; Srv1 heard nothing and sends
    s2.OR().MeshOffer('gob;42;1000;1;tag', 'Early')
    s1.OR().MeshQuery('gob;42;-;0', 'Asker')
    s2.OR().MeshQuery('gob;42;-;0', 'Asker')
    w.pump(12)
    fs = [m for m in w.wire_log if m['kind'] == 'F']
    check('dominated offer never sent', len(fs) == 1
          and fs[0]['from'] == 'Srv1', fs)


def s30_item_suppression(w):
    """i answers: once K_I responses for a nonce are on the wire
    the next server's deferred reply dies. Without answers heard,
    the reply goes out."""
    s = w.client('Srv', tracker='b', boards=['gob'])
    s.fire_login(); w.pump()
    s.OR().Post('gob', 5518, 9, 700, 86400)
    w.watcher(s); s.reload()
    # prime: 4 answers already heard for nonce 77
    for i in range(4):
        s.OR().ItemIngest(s.lua.table_from(
            ['77', '5518', 'gob', 'o%d' % i, '9', '9', '700',
             '0', '-', '0']), 'Peer%d' % i)
    s.OR().MeshItemQuery('5518;77;-', 'Asker')
    s.advance(5); w.pump()
    check('saturated nonce -> no reply',
          not any(m['kind'] == 'i' for m in w.wire_log),
          [m for m in w.wire_log if m['kind'] == 'i'])
    # fresh nonce: reply goes out
    s.OR().MeshItemQuery('5518;88;-', 'Asker')
    s.advance(5); w.pump()
    check('fresh nonce -> reply goes out',
          any(m['kind'] == 'i' and m['from'] == 'Srv'
              for m in w.wire_log),
          [m for m in w.wire_log if m['kind'] == 'i'])


def s31_peer_cap(w):
    """peers[board] is bounded — 70 distinct T beacons leave at
    most PEER_CAP senders remembered."""
    c = w.client('Cap', tracker='a', boards=['main'])
    c.fire_login(); w.pump()
    for i in range(70):
        c.OR().RelayPeer('gob:tag', 'Srv%d' % i)
    # count via lua (python len() on lupa map counts array part)
    n = int(c.lua.eval(
        '(function() local n=0 '
        'for _ in pairs(GM.Orders.relay.peers.gob) do n=n+1 end '
        'return n end)()'))
    check('peers bounded at PEER_CAP', 0 < n <= 64, n)


def s32_queue_bounded(w):
    """A dead writ bus (join fails — WoW's 10-channel cap) must
    not wedge the queue: writ sends drop at the M.Send gate,
    market bursts still transmit, whispers still flow."""
    c = w.client('Lose', tracker='a', boards=['main'])
    o = w.client('Other', tracker='b', boards=['gob'])
    c.chan_fail('goblinwritx')
    c.fire_login(); o.fire_login(); w.pump()
    sent0 = int(c.Mesh().stats.sent)
    # a market burst: several records queue + drain on CH_A
    for i in range(6):
        c.Mesh().Send('M', c.lua.table_from(
            ['%d:%d:0' % (2589 + i, 100 + i)]))
    # writ sends drop at the gate — never reach sendQ
    c.Mesh().Send('T', c.lua.table_from(['gob:x']))
    c.Mesh().Send('Q', c.lua.table_from(['gob;1;-;0']))
    w.pump(12)
    msent = [m for m in w.wire_log if m['from'] == 'Lose'
             and m['kind'] == 'M']
    check('market burst flowed on live bus',
          len(msent) >= 1, len(msent))
    check('dead-bus sends never queued',
          not any(m['from'] == 'Lose' and m['kind'] in
                  ('T', 'Q') for m in w.wire_log),
          [m['kind'] for m in w.wire_log if m['from'] == 'Lose'])
    check('queue fully drained (no wedge)',
          int(c.Mesh().stats.sent) - sent0 >= len(msent),
          int(c.Mesh().stats.sent) - sent0)
    c.Mesh().Whisper('Other', 'R', 'gob;-;-;-;x')
    w.pump()
    check('whisper rides with writ bus dead',
          any(m['from'] == 'Lose' and m['ctype'] == 'WHISPER'
              for m in w.wire_log), w.wire_log[-2:])


def s33_writ_lifecycle(w):
    """Writs P0-P1: 'V' hint round-trip + full lifecycle.
    roster publish -> request -> quote -> meet -> accept -> ship ->
    recv -> done. 'V' records must paint shadow writs on the peer
    before any pull lands; pulls then confirm them out."""
    a = w.client('Alpha')
    c = w.client('Crafty')
    a.fire_login(); c.fire_login(); w.pump()
    w.watcher(c); c.reload()
    w.watcher(a); a.reload()
    cu = c.state().get('install_uuid')
    check('crafter uuid registered', bool(cu), cu)
    # roster publish: hand-entered offer flipped on via shopTerms
    c.db().shopOffers = ltab(c,
        [{'ref': 'k:1', 'name': 'Lockpick', 'prof': 'Rogue'}])
    c.db().shopTerms = ltab(c, {'k:1': {'on': True}})
    c.W().Publish('main')
    q = c.db().writQueue
    check('roster publish staged wrt-', len(q) == 1
          and tostring_check(q[1], 'wrt-'), q[1])
    w.watcher(c)
    conn = w.db()
    ros = list(conn.execute(
        'select board,uuid,chars,offers from rosters'))
    conn.close()
    check('roster row landed server-side', len(ros) == 1
          and ros[0][0] == 'main' and ros[0][1] == cu, ros)
    check('roster carries offer+toon',
          'k:1' in (ros[0][3] or '') and 'Crafty' in (ros[0][2] or ''),
          ros)
    # customer browses rosters via pull
    w.watcher(a); a.reload()
    rs = a.rosters('main')
    check('customer sees roster via pull', len(rs) == 1
          and rs[0]['uuid'] == cu, rs)
    check('roster offer visible', rs and len(rs[0]['offers']) == 1
          and rs[0]['offers'][0].get('ref') == 'k:1', rs)
    # request -> 'V' record paints shadows BEFORE any watcher pass
    a.W().Request('main', cu, 'Crafty', a.lua.table_from(
        {'ref': 'k:1', 'name': 'Lockpick', 'qty': 1, 'offer': 500,
         'deliver': 'trade'}))
    w.pump()
    c_in = c.writs('inb')
    check("'V' hint paints crafter inbox shadow",
          len(c_in) == 1 and c_in[0].get('_live')
          and c_in[0].get('_pendOp') == 'wpost'
          and c_in[0].get('state') == 'open', c_in)
    check('hint carries request fields',
          c_in and c_in[0].get('qty') == 1
          and c_in[0].get('offer') == 500
          and c_in[0].get('deliver') == 'trade', c_in)
    a_out = a.writs('out')
    check('own overlay shows outgoing writ', len(a_out) == 1
          and a_out[0].get('_pendOp') == 'wpost', a_out)
    wid = a_out[0]['id']
    # watcher POSTs; server applies open writ addressed to crafter
    w.watcher(a)
    wrows = list(w.db().execute(
        'select id,state,qty,offer,to_uuid,from_uuid,deliver '
        'from writs'))
    check('writ applied server-side open', len(wrows) == 1
          and wrows[0][1] == 'open' and wrows[0][2] == 1
          and wrows[0][3] == 500, wrows)
    check('writ id matches overlay wid',
          wrows and wrows[0][0] == wid, (wrows, wid))
    check('writ parties = customer->crafter',
          wrows and wrows[0][4] == cu
          and wrows[0][5] == a.state().get('install_uuid'), wrows)
    # crafter pull: shadow confirmed -> pend flag dropped
    w.watcher(c); c.reload()
    got = c.writs('inb')
    check('crafter pull confirms writ', len(got) == 1
          and got[0].get('state') == 'open'
          and not got[0].get('_pendOp'), got)
    # quote: 'V' hint paints quoted state on customer side first
    c.W().Act('wquote', wid, c.lua.table_from({'price': 800}))
    w.pump()
    a_out = a.writs('out')
    check("'V' quote paints quoted on customer", len(a_out) == 1
          and a_out[0].get('state') == 'quoted'
          and a_out[0].get('price') == 800, a_out)
    w.watcher(c)
    st = list(w.db().execute('select state,quote from writs'))
    check('quote landed server-side',
          st and st[0] == ('quoted', 800), st)
    # meet proposal (handshake verb) then accept -> agreed
    a.W().Act('wmeet', wid, a.lua.table_from({'meet': 'SW bank'}))
    w.watcher(a)
    st = list(w.db().execute('select state,meet from writs'))
    check('meet note landed, still quoted',
          st and st[0] == ('quoted', 'SW bank'), st)
    a.W().Act('waccept', wid, None)
    w.watcher(a)
    st = list(w.db().execute('select state from writs'))
    check('accept -> agreed', st and st[0][0] == 'agreed', st)
    # crafter ships, customer receives -> done (+ writs_done credit)
    c.W().Act('wship', wid, None)
    w.watcher(c)
    st = list(w.db().execute('select state from writs'))
    check('ship -> shipped', st and st[0][0] == 'shipped', st)
    a.W().Act('wrecv', wid, None)
    w.watcher(a)
    st = list(w.db().execute('select state from writs'))
    check('recv -> done', st and st[0][0] == 'done', st)
    inst = w.stats(w.db().execute(
        'select id from installs where uuid=?',
        (cu,)).fetchone()[0])
    check('crafter writs_done credited',
          inst.get('writs_done') == 1, inst)
    # terminal pull: server keeps done writs for 24h — the view must
    # show the pulled 'done', not the stale 'shipped' ev shadow
    w.watcher(c); c.reload(); w.watcher(a); a.reload()
    got = c.writs('inb')
    check('done pull clears wship shadow', len(got) == 1
          and got[0].get('state') == 'done'
          and not got[0].get('_pendOp'), got)


def s34_writ_relay(w):
    """Tunneled writ op: Xavier (tracker A) addresses a writ to Relay
    (tracker B) on board 'gob'. The R envelope must carry Xavier's
    uuid+rtoken so the server applies it under the ASKER's install."""
    x = w.client('Xavier', tracker='a', boards=['main'])
    r = w.client('Relay', tracker='b', boards=['gob'])
    r.fire_login(); w.pump(); w.watcher(r); r.reload()
    x.fire_login(); w.watcher(x); x.reload()
    x.advance(40); r.advance(40); w.pump()   # T beacons both ways
    check('Xavier sees remote board via T',
          'gob' in x.board_names(), x.board_names())
    x.OR().RefreshBoard('gob'); w.pump(16)
    check('remote snapshot landed', x.OR().IsRemote('gob'),
          x.board_names())
    ru = r.state().get('install_uuid')
    x.W().Request('gob', ru, 'Relay', x.lua.table_from(
        {'ref': 'k:1', 'name': 'Lockpick', 'qty': 2, 'offer': 300,
         'deliver': 'cod'}))
    check('wpost deferred behind register',
          not x.db().writQueue or len(x.db().writQueue) == 0,
          x.db().writQueue)
    w.pump()                    # R register whisper -> Relay stages
    r.sv_write()
    gb.API_STATE_PATH = r.state_path
    gb.API_BOOK_PATH = r.book_path
    gb.FEEDS_PATH = r.feeds_path
    gb.process_relay(None, r.root)     # Relay's watcher POSTs reg
    w.emit(r); r.reload(); r.advance(16); w.pump()  # Y creds back
    w.pump()                    # deferred wpost flushes as R envelope
    r.sv_write()
    gb.process_relay(None, r.root)     # Relay's watcher POSTs op
    gb.boards_pull(); w.emit(r); r.reload()
    xu = x.state().get('install_uuid')
    rows = list(w.db().execute(
        'select id,board,state,from_uuid,to_uuid,qty,offer '
        'from writs'))
    hits = [o for o in rows if o[1] == 'gob']
    check('relayed wpost applied on tracker B', len(hits) == 1
          and hits[0][2] == 'open', rows)
    check('applied under ASKER uuid not relay',
          hits and hits[0][3] == xu and hits[0][4] == ru,
          (hits, xu, ru))
    check('qty/offer survived the tunnel',
          hits and hits[0][5] == 2 and hits[0][6] == 300, hits)
    # tunneled side: the staged overlay paints the outgoing writ
    xo = x.writs('out')
    check('tunnel-side overlay shows outgoing writ',
          any(o.get('toUUID') == ru and o.get('state') == 'open'
              for o in xo), xo)


def s35_roster_stream(w):
    """Roster 'y' stream rows: browsing a remote board streams the
    shop roster over the Q->F->P->stream flow, feeding W.Rosters on
    the remote store — no backend pull on the asker side."""
    x = w.client('Xavier', tracker='a', boards=['main'])
    r = w.client('Relay', tracker='b', boards=['gob'])
    # Relay owns a shop on 'gob'
    r.db().shopOffers = ltab(r,
        [{'ref': 'k:1', 'name': 'Lockpick', 'prof': 'Rogue'}])
    r.db().shopTerms = ltab(r, {'k:1': {'on': True}})
    r.fire_login(); w.pump()
    r.W().Publish('gob')
    w.watcher(r); r.reload()
    conn = w.db()
    ros = list(conn.execute(
        'select board,uuid from rosters where board=?', ('gob',)))
    conn.close()
    check('roster published on gob', len(ros) == 1, ros)
    x.fire_login(); w.watcher(x); x.reload()
    x.advance(40); r.advance(40); w.pump()
    x.OR().RefreshBoard('gob'); w.pump(16)
    rs = x.rosters('gob')
    check('y-stream roster landed on remote client', len(rs) == 1
          and rs[0]['uuid'] == r.state().get('install_uuid'), rs)
    check('streamed roster carries the offer',
          rs and any(o.get('ref') == 'k:1' for o in rs[0]['offers']),
          rs)
    check('streamed roster carries toon names',
          rs and 'Relay' in rs[0]['chars'], rs)


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
    ('v2 channel split', s26_channel_split),
    ('v2 offer -> pull single stream', s27_offer_pull),
    ('v2 coverage suppression', s28_coverage_suppression),
    ('v2 offer suppression', s29_offer_suppression),
    ('v2 item answer bound', s30_item_suppression),
    ('v2 peer cap', s31_peer_cap),
    ('v2 queue bounded on channel loss', s32_queue_bounded),
    ('writs V hint + lifecycle', s33_writ_lifecycle),
    ('writs relayed wpost tunnel', s34_writ_relay),
    ('writs roster y-stream', s35_roster_stream),
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
