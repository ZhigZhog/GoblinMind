#!/usr/bin/env python3
"""Integration tests for goblin_server.py.

Runs the real Handler in-process on an ephemeral port against a temp
DB + temp goblin_server.json, so no live server is touched. Covers:
open + keyed registration, re-key on duplicate names, bearer auth,
payload validation/cleaning, newest-wins merge + lots ownership,
staleness cutoff + direct GC, the client-t clamp, install uuid
persistence + last_seen, crowd drop aggregation, and the rate limit.

    python brain/test_server.py        # exits nonzero on any failure
"""
import json
import os
import sqlite3
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import goblin_server as gs

FAILURES = []
CHECKS = [0]


def check(name, cond, detail=''):
    CHECKS[0] += 1
    print(('  ok  ' if cond else 'FAIL  ') + name +
          (f' — {detail}' if not cond else ''))
    if not cond:
        FAILURES.append(name)


def req(base, path, body=None, tok=None, key=None, method=None):
    url = base + path
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    else:
        data = None
    method = method or ('POST' if body is not None else 'GET')
    if tok:
        headers['Authorization'] = 'Bearer ' + tok
    if key:
        headers['X-Admin-Key'] = key
    try:
        r = urllib.request.urlopen(
            urllib.request.Request(url, data=data, headers=headers,
                                   method=method), timeout=10)
        return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')


def item(mb=100):
    return {'mb': mb, 'mbx': mb, 'sup': 2, 'n': 1}


def main():
    tmp = tempfile.mkdtemp(prefix='goblin-server-test-')
    gs.DB_PATH = os.path.join(tmp, 'test.db')
    gs.CFG_PATH = os.path.join(tmp, 'goblin_server.json')
    gs.init_db()   # the test bypasses gs.main(), which owns startup DDL
    gs.Handler.log_message = lambda *a, **k: None  # quiet access log
    srv = ThreadingHTTPServer(('127.0.0.1', 0), gs.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % srv.server_address[1]
    S = 'Test-Realm-X'

    print('== registration (open mode) ==')
    c, r = req(base, '/v1/register', {'name': 'a'})
    check('register returns token', c == 200 and r.get('token'),
          f'{c} {r}')
    tok_a, id_a = r['token'], r['install_id']
    c, r = req(base, '/v1/register', {'name': 'a'})
    check('re-register re-keys same row',
          c == 200 and r['install_id'] == id_a and
          r['token'] != tok_a, f'{c} {r}')
    tok_a = r['token']
    c, r = req(base, '/v1/register', {'name': 'b'})
    tok_b = r['token']

    print('== auth ==')
    c, _ = req(base, '/v1/upload', {'scope': S, 't': 1, 'items': {'1': item()}})
    check('no token -> 401', c == 401, c)
    c, _ = req(base, '/v1/upload', {'scope': S, 't': 1, 'items': {'1': item()}}, 'bogus')
    check('bad token -> 401', c == 401, c)
    c, _ = req(base, '/v1/book?scope=' + S)
    check('book before data -> items empty',
          c == 200 and not _.get('items'), f'{c} {_}')

    print('== payload validation ==')
    c, _ = req(base, '/v1/upload',
               {'scope': '../etc', 't': 1, 'items': {'1': item()}}, tok_a)
    check('bad scope -> 400', c == 400, c)
    c, _ = req(base, '/v1/upload',
               {'scope': S, 't': 'abc', 'items': {'1': item()}}, tok_a)
    check('non-numeric t -> 400', c == 400, c)
    c, _ = req(base, '/v1/upload',
               {'scope': S, 't': 1, 'items': {}}, tok_a)
    check('empty items -> 400', c == 400, c)
    gs.MAX_ITEMS = 5
    c, _ = req(base, '/v1/upload',
               {'scope': S, 't': 1,
                'items': {str(i): item() for i in range(6)}}, tok_a)
    check('items over MAX_ITEMS -> 400', c == 400, c)
    gs.MAX_ITEMS = 400000

    print('== item cleaning ==')
    now = time.time()
    c, _ = req(base, '/v1/upload', {'scope': S, 't': now, 'items': {
        '1': {'mb': gs.MAX_PRICE + 1},          # over cap -> dropped
        '2': {'sup': -5, 'mb': 10},             # negative -> dropped
        'x': {'mb': 5},                         # non-int id -> dropped
        '3': item(42),                          # clean -> kept
        '4': {'mb': 'not-a-number'},            # uncoercible -> dropped
        '5': {'mb': 7, 'junk': 'x'},            # junk field stripped
    }, 'lots': {'3:2:42:2': 3}}, tok_a)
    check('upload with mixed entries -> 200', c == 200, c)
    c, b = req(base, '/v1/book?scope=' + S)
    check('over-cap item dropped', '1' not in b['items'])
    check('negative-field item dropped', '2' not in b['items'])
    check('non-int id dropped', 'x' not in b['items'])
    check('uncoercible field dropped', '4' not in b['items'])
    check('clean item kept', b['items'].get('3', {}).get('mb') == 42)
    check('junk field stripped', 'junk' not in b['items'].get('5', {}))
    check('kept item lots merged',
          b['lots'].get('3:2:42:2') == 3)

    print('== client-t clamp ==')
    far = time.time() + 10 ** 9
    c, _ = req(base, '/v1/upload',
               {'scope': S, 't': far, 'items': {'9': item(1)}}, tok_a)
    c, b = req(base, '/v1/book?scope=' + S)
    check('future t clamped at now',
          b['t'] <= time.time() + 1, f"book t={b['t']}")

    print('== newest-wins merge + lots ownership ==')
    t1, t2, t3 = now - 300, now - 200, now - 100
    req(base, '/v1/upload',
        {'scope': S, 't': t1, 'items': {'7': item(100)},
         'lots': {'7:5:100:1': 5}}, tok_a)
    c, b = req(base, '/v1/book?scope=' + S)
    check('a owns item', b['items']['7']['mb'] == 100)
    req(base, '/v1/upload',
        {'scope': S, 't': t2, 'items': {'7': item(200)}}, tok_b)
    c, b = req(base, '/v1/book?scope=' + S)
    check('newer upload wins', b['items']['7']['mb'] == 200)
    check("newer owner's empty lots clear old fps",
          '7:5:100:1' not in b['lots'], b['lots'])
    req(base, '/v1/upload',
        {'scope': S, 't': t3, 'items': {'7': item(50)}}, tok_a)
    c, b = req(base, '/v1/book?scope=' + S)
    check('newest upload wins again', b['items']['7']['mb'] == 50)

    print('== staleness cutoff + GC ==')
    c, r = req(base, '/v1/register', {'name': 'stale'})
    tok_s = r['token']
    old = time.time() - 8 * 86400
    req(base, '/v1/upload',
        {'scope': S, 't': old, 'items': {'8': item(1)}}, tok_s)
    c, b = req(base, '/v1/book?scope=' + S)
    check('8-day-old upload aged out of merge', '8' not in b['items'])
    # GC runs on its own daemon thread hourly (_gc_loop) — invoke the
    # same routine directly rather than relying on a request trigger
    conn = sqlite3.connect(gs.DB_PATH)
    gs._gc(conn, force=True)
    n = conn.execute('SELECT COUNT(*) FROM uploads WHERE t=?',
                     (old,)).fetchone()[0]
    conn.close()
    check('stale row GC\'d', n == 0, n)

    print('== install identity (uuid + last_seen) ==')
    c, r = req(base, '/v1/register',
               {'name': 'uid-a', 'uuid': 'uuid-aaa'})
    check('register echoes client uuid',
          c == 200 and r.get('uuid') == 'uuid-aaa', r)
    tok_ua = r['token']
    c, h = req(base, '/v1/health')
    ua = next((i for i in h.get('installs') or []
               if i['name'] == 'uid-a'), None)
    check('health carries uuid',
          ua is not None and ua.get('uuid') == 'uuid-aaa', ua)
    check('seen empty before first upload',
          ua is not None and not ua.get('seen'), ua)
    c, _ = req(base, '/v1/upload',
               {'scope': S, 't': now, 'items': {'1': item()}}, tok_ua)
    check('uuid install can upload', c == 200, c)
    c, h = req(base, '/v1/health')
    ua = next((i for i in h.get('installs') or []
               if i['name'] == 'uid-a'), None)
    check('upload stamps last_seen',
          ua is not None and ua.get('seen'), ua)
    c, r = req(base, '/v1/register', {'name': 'uid-a'})
    check('re-register without uuid keeps stored one',
          c == 200 and r.get('uuid') == 'uuid-aaa', r)

    print('== rate limit ==')
    c, r = req(base, '/v1/register', {'name': 'spammer'})
    tok_r = r['token']
    codes = [req(base, '/v1/upload',
                 {'scope': S, 't': now + i, 'items': {'1': item()}},
                 tok_r)[0] for i in range(11)]
    check('10 uploads pass', codes[:10] == [200] * 10, codes)
    check('11th -> 429', codes[10] == 429, codes)

    print('== health ==')
    c, h = req(base, '/v1/health')
    check('health lists test scope', S in (h.get('scopes') or []), h)

    print('== scopes endpoint ==')
    c, s = req(base, '/v1/scopes')
    check('/v1/scopes lists test scope',
          S in (s.get('scopes') or []), s)

    print('== health installs detail ==')
    names = {i['name'] for i in h.get('installs') or []}
    check('installs listed by name', {'a', 'b'} <= names, names)
    a_i = next((i for i in h['installs'] if i['name'] == 'a'), None)
    check('install a reports uploads + last t',
          a_i is not None and a_i['uploads'] > 0 and a_i['last'], a_i)
    check('install scopes attributed',
          a_i is not None and S in a_i['scopes'], a_i)

    print('== keyed registration ==')
    with open(gs.CFG_PATH, 'w') as fh:
        json.dump({'install_secret': 'sekrit'}, fh)
    c, _ = req(base, '/v1/register', {'name': 'c'})
    check('no key -> 403', c == 403, c)
    c, _ = req(base, '/v1/register', {'name': 'c', 'key': 'wrong'})
    check('wrong key -> 403', c == 403, c)
    c, r = req(base, '/v1/register', {'name': 'c', 'key': 'sekrit'})
    check('right key -> 200 + token', c == 200 and r.get('token'), r)
    c, _ = req(base, '/v1/upload',
               {'scope': S, 't': now, 'items': {'2': item()}}, tok_a)
    check('existing tokens unaffected by gate', c == 200, c)

    print('== crowd drop stats ==')
    # fresh installs — the rate bucket counts before validation, so
    # the main tokens are already near their 10/10min quota
    c, r = req(base, '/v1/register', {'name': 'drop-a', 'key': 'sekrit'})
    tok_da = r['token']
    c, r = req(base, '/v1/register', {'name': 'drop-b', 'key': 'sekrit'})
    tok_db = r['token']

    drops_a = {'n': {'c100': 50, 'nMurloc': 12},
               'd': {'2770': {'c100': {'k': 10, 'q': 25}}},
               'names': {'c100': 'Cave Yeti'}}
    c, _ = req(base, '/v1/upload',
               {'scope': S, 't': now, 'items': {'1': item()},
                'drops': drops_a}, tok_da)
    check('drop upload accepted', c == 200, c)
    c, b = req(base, '/v1/book?scope=' + S)
    dr = b.get('drops') or {}
    check('drop n surfaced', dr.get('n', {}).get('c100') == 50, dr)
    check('drop k/q surfaced',
          dr.get('d', {}).get('2770', {}).get('c100', {}).get('k') == 10)
    check('drop name surfaced',
          dr.get('names', {}).get('c100') == 'Cave Yeti')

    # second install same src -> counts SUM (crowd aggregation)
    req(base, '/v1/upload',
        {'scope': S, 't': now, 'items': {'1': item()},
         'drops': {'n': {'c100': 30},
                   'd': {'2770': {'c100': {'k': 6, 'q': 15}}},
                   'names': {}}}, tok_db)
    c, b = req(base, '/v1/book?scope=' + S)
    dr = b.get('drops') or {}
    check('crowd n sums across installs',
          dr.get('n', {}).get('c100') == 80, dr.get('n'))
    check('crowd k sums across installs',
          dr.get('d', {}).get('2770', {}).get('c100', {}).get('k') == 16)

    # re-upload REPLACEs the install's snapshot — cumulative, never
    # additive (else every re-upload would double-count itself)
    req(base, '/v1/upload',
        {'scope': S, 't': now + 1, 'items': {'1': item()},
         'drops': {'n': {'c100': 60},
                   'd': {'2770': {'c100': {'k': 12, 'q': 30}}},
                   'names': {}}}, tok_da)
    c, b = req(base, '/v1/book?scope=' + S)
    dr = b.get('drops') or {}
    check('re-upload replaces, never adds',
          dr.get('n', {}).get('c100') == 90, dr.get('n'))  # 60+30

    # malformed rows filtered, good rows kept; wholesale replace
    # purges the install's earlier src set for the scope
    req(base, '/v1/upload',
        {'scope': S, 't': now + 2, 'items': {'1': item()},
         'drops': {'n': {'BADKEY': 5, 'c200': 10, 'c201': 10 ** 9},
                   'd': {'2770': {'c200': {'k': -1, 'q': 5},
                                  'zzz': {'k': 1, 'q': 1}},
                         'notanid': {'c200': {'k': 1, 'q': 1}}},
                   'names': {'c200': 'Yeti', 'x': 9}}}, tok_da)
    c, b = req(base, '/v1/book?scope=' + S)
    dr = b.get('drops') or {}
    check('bad src key dropped', 'BADKEY' not in dr.get('n', {}))
    check('over-cap n dropped', dr.get('n', {}).get('c201') is None)
    check('good n kept', dr.get('n', {}).get('c200') == 10)
    check('negative k dropped',
          'c200' not in (dr.get('d', {}).get('2770') or {}))
    check('bad src in d dropped',
          'zzz' not in (dr.get('d', {}).get('2770') or {}))
    check('non-int item dropped', 'notanid' not in dr.get('d', {}))
    check('non-str name dropped', dr.get('names', {}).get('x') is None)
    check('replaced sources drop out',
          dr.get('n', {}).get('c100') == 30, dr.get('n'))

    # ---------- writ board ----------
    print('== writ: order lifecycle ==')
    B = 'writs'
    c, r = req(base, '/v1/register',
               {'name': 'wp', 'uuid': 'uu-p', 'key': 'sekrit'})
    tok_p = r['token']
    c, r = req(base, '/v1/register',
               {'name': 'wc', 'uuid': 'uu-c', 'key': 'sekrit'})
    tok_c = r['token']

    c, _ = req(base, '/v1/boards/%s/orders' % B,
               {'itemID': 12345, 'qtyTotal': 10, 'pricePerUnit': 500,
                'poster': 'Poster', 'op': 'ord1'})
    check('unauthed order post -> 401', c == 401, c)
    c, r = req(base, '/v1/boards/%s/orders' % B,
               {'itemID': 12345, 'qtyTotal': 10, 'pricePerUnit': 500,
                'poster': 'Poster', 'op': 'ord1'}, tok_p)
    check('order posts', c == 200 and r['order']['qtyTotal'] == 10, r)
    oid = r['order']['id']
    check('order id is install:op', oid.endswith(':ord1'), oid)
    check('remaining starts at total', r['order']['remaining'] == 10)
    c, r = req(base, '/v1/boards/%s/orders' % B,
               {'itemID': 999, 'qtyTotal': 1, 'pricePerUnit': 1,
                'poster': 'Poster', 'op': 'ord1'}, tok_p)
    check('post replay returns same order + dup',
          r['order']['id'] == oid and r.get('dup'), r)

    c, r = req(base, '/v1/boards')
    bd = next((b for b in r['boards'] if b['name'] == B), None)
    check('board listed with open count',
          bd is not None and bd['open'] == 1, r)

    print('== writ: claim + pool ==')
    c, r = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid),
               {'units': 4, 'crafter': 'Crafter', 'op': 'cl1'}, tok_c)
    check('claim commits units', c == 200 and r['commit']['units'] == 4,
          r)
    cid = r['commit']['id']
    c, r = req(base, '/v1/boards/%s/orders' % B)
    check('held units leave the pool', r['orders'][0]['remaining'] == 6,
          r['orders'])
    c, r = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid),
               {'units': 7, 'crafter': 'Crafter', 'op': 'cl2'}, tok_c)
    check('over-claim -> 409 + remaining',
          c == 409 and r.get('remaining') == 6, r)
    c, r = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid),
               {'units': 4, 'crafter': 'Crafter', 'op': 'cl1'}, tok_c)
    check('claim replay returns same commit',
          r['commit']['id'] == cid and r.get('dup'), r)

    print('== writ: fill ==')
    c, _ = req(base, '/v1/boards/%s/orders/%s/fill' % (B, oid),
               {'units': 4, 'op': 'f0'}, tok_c)
    check('non-poster fill -> 403', c == 403, c)
    c, r = req(base, '/v1/boards/%s/orders/%s/fill' % (B, oid),
               {'units': 4, 'op': 'f1'}, tok_p)
    check('fill credits order', r['order']['qtyFilled'] == 4, r)
    check('commit closed on full fill',
          r['order']['commits'][0]['state'] == 'filled',
          r['order']['commits'])
    check('crafter stat commits_filled',
          r['order']['commits'][0]['crafterStats']
          ['commits_filled'] == 1)
    c, r = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid),
               {'units': 6, 'crafter': 'Crafter', 'op': 'cl3'}, tok_c)
    cid2 = r['commit']['id']
    c, r = req(base, '/v1/boards/%s/orders/%s/fill' % (B, oid),
               {'units': 6, 'op': 'f2'}, tok_p)
    check('order completes at qtyTotal',
          r['order']['state'] == 'filled', r['order']['state'])
    check('poster stat orders_filled',
          r['order']['posterStats']['orders_filled'] == 1)

    print('== writ: reject ==')
    c, r = req(base, '/v1/boards/%s/orders' % B,
               {'itemID': 222, 'qtyTotal': 5, 'pricePerUnit': 100,
                'poster': 'Poster', 'op': 'ord2'}, tok_p)
    oid2 = r['order']['id']
    req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid2),
        {'units': 5, 'crafter': 'Crafter', 'op': 'cl4'}, tok_c)
    c, r = req(base, '/v1/boards/%s/orders/%s/reject' % (B, oid2),
               {'mailFrom': 'Crafter', 'op': 'rj1'}, tok_p)
    check('reject returns units to pool',
          r['order']['remaining'] == 5, r['order'])
    check('poster stat fills_rejected',
          r['order']['posterStats']['fills_rejected'] == 1)

    print('== writ: release ==')
    c, r = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid2),
               {'units': 2, 'crafter': 'Crafter', 'op': 'cl5'}, tok_c)
    cid3 = r['commit']['id']
    c, _ = req(base, '/v1/boards/%s/commits/%s/release' % (B, cid3),
               {'op': 'rl0'}, tok_p)
    check('non-crafter release -> 403', c == 403, c)
    c, r = req(base, '/v1/boards/%s/commits/%s/release' % (B, cid3),
               {'op': 'rl1'}, tok_c)
    check('crafter release ok', c == 200 and r.get('ok'), r)
    c, r = req(base, '/v1/boards/%s/orders' % B)
    o2 = next(o for o in r['orders'] if o['id'] == oid2)
    check('released units back in pool', o2['remaining'] == 5, o2)

    print('== writ: cancel ==')
    c, r = req(base, '/v1/boards/%s/orders/%s/cancel' % (B, oid2),
               {'units': 2, 'op': 'cx1'}, tok_p)
    check('partial cancel shrinks total',
          r['order']['qtyTotal'] == 3 and r['order']['state'] == 'open',
          r['order'])
    c, r = req(base, '/v1/boards/%s/orders/%s/cancel' % (B, oid2),
               {'units': 2, 'op': 'cx1'}, tok_p)
    check('cancel replay is idempotent',
          r.get('dup') and r['order']['qtyTotal'] == 3, r)
    c, r = req(base, '/v1/boards/%s/orders/%s/cancel' % (B, oid2),
               {'op': 'cx2'}, tok_p)
    check('whole cancel -> cancelled',
          r['order']['state'] == 'cancelled', r['order']['state'])

    print('== writ: commit TTL expiry ==')
    c, r = req(base, '/v1/boards/%s/orders' % B,
               {'itemID': 333, 'qtyTotal': 3, 'pricePerUnit': 50,
                'poster': 'Poster', 'op': 'ord3'}, tok_p)
    oid3 = r['order']['id']
    c, r = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid3),
               {'units': 2, 'crafter': 'Crafter', 'op': 'cl6'}, tok_c)
    cid4 = r['commit']['id']
    conn = sqlite3.connect(gs.DB_PATH)
    conn.execute('UPDATE commits SET expires=0 WHERE id=?', (cid4,))
    conn.commit()
    conn.close()
    c, r = req(base, '/v1/boards/%s/orders' % B)
    o3 = next(o for o in r['orders'] if o['id'] == oid3)
    check('expired commit releases pool', o3['remaining'] == 3, o3)
    cm = next(x for x in o3['commits'] if x['id'] == cid4)
    check('expired commit marked released', cm['state'] == 'released')
    check('crafter stat commits_expired',
          cm['crafterStats']['commits_expired'] == 1, cm['crafterStats'])

    print('== writ: ignore ==')
    c, r = req(base, '/v1/ignore', {'uuid': 'uu-c', 'on': True}, tok_p)
    check('ignore on', c == 200 and r.get('ok'), r)
    c, _ = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid3),
               {'units': 1, 'crafter': 'Crafter', 'op': 'cl7'}, tok_c)
    check('ignored crafter claim -> 403 ignored',
          c == 403 and _.get('error') == 'ignored', _)
    req(base, '/v1/ignore', {'uuid': 'uu-c', 'on': False}, tok_p)
    c, r = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid3),
               {'units': 1, 'crafter': 'Crafter', 'op': 'cl7'}, tok_c)
    check('unignored crafter claims again', c == 200, c)

    print('== writ: board ACL + owner ban ==')
    with open(gs.CFG_PATH, 'w') as fh:
        json.dump({'install_secret': 'sekrit', 'admin_key': 'adk'}, fh)
    c, r = req(base, '/v1/admin/installs', key='adk')
    check('admin lists installs', c == 200 and r.get('installs'), r)
    wp = next(i for i in r['installs'] if i['name'] == 'wp')
    c, _ = req(base, '/v1/admin/installs')
    check('admin without key -> 403', c == 403, c)
    c, r = req(base, '/v1/admin/boards',
               {'name': 'guild', 'owner': wp['id']}, key='adk')
    check('admin creates board', c == 200 and r.get('ok'), r)
    c, r = req(base, '/v1/admin/boards/guild',
               {'acl': 'members', 'members': ['uu-p', 'uu-c']},
               key='adk')
    check('admin sets members ACL', c == 200 and r.get('ok'), r)
    c, r = req(base, '/v1/admin/boards/guild',
               {'acl': 'members', 'members': ['uu-p']}, key='adk')
    check('admin narrows members', c == 200 and r.get('ok'), r)
    c, _ = req(base, '/v1/boards/guild/orders',
               {'itemID': 1, 'qtyTotal': 1, 'pricePerUnit': 1,
                'poster': 'Crafter', 'op': 'og1'}, tok_c)
    check('non-member post -> 403 members',
          c == 403 and _.get('error') == 'members', _)
    c, r = req(base, '/v1/boards/guild/orders',
               {'itemID': 1, 'qtyTotal': 1, 'pricePerUnit': 1,
                'poster': 'Poster', 'op': 'og2'}, tok_p)
    check('member posts', c == 200, c)
    # re-add uu-c as a member, then ban — exercises the board_ban
    # branch specifically (a member turned bad)
    req(base, '/v1/admin/boards/guild',
        {'acl': 'members', 'members': ['uu-p', 'uu-c']}, key='adk')
    c, r = req(base, '/v1/boards/guild/ban',
               {'uuid': 'uu-c', 'on': True}, tok_p)
    check('board owner bans uuid', c == 200 and r.get('ok'), r)
    c, _ = req(base, '/v1/boards/guild/orders',
               {'itemID': 1, 'qtyTotal': 1, 'pricePerUnit': 1,
                'poster': 'Crafter', 'op': 'og3'}, tok_c)
    check('banned post -> 403 board_ban',
          c == 403 and _.get('error') == 'board_ban', _)
    c, _ = req(base, '/v1/boards/guild/ban',
               {'uuid': 'uu-p', 'on': True}, tok_c)
    check('non-owner ban -> 403 owner', c == 403, c)

    print('== writ: host ban = purge ==')
    c, r = req(base, '/v1/admin/installs', key='adk')
    wc = next(i for i in r['installs'] if i['name'] == 'wc')
    # crafter holds 1 unit on oid3 — ban releases it to the pool
    c, r = req(base, '/v1/admin/installs/%d' % wc['id'],
               {'banned': True}, key='adk')
    check('admin ban ok', c == 200 and r.get('ok'), r)
    c, _ = req(base, '/v1/boards/%s/orders/%s/claim' % (B, oid3),
               {'units': 1, 'crafter': 'Crafter', 'op': 'cl8'}, tok_c)
    check('banned token -> 401', c == 401, c)
    c, r = req(base, '/v1/boards/%s/orders' % B)
    o3 = next(o for o in r['orders'] if o['id'] == oid3)
    check('banned crafter hold purged to pool',
          o3['remaining'] == 3, o3)

    print('== writ: order cap + validation ==')
    c, _ = req(base, '/v1/boards/%s/orders' % B,
               {'itemID': 1, 'qtyTotal': 0, 'pricePerUnit': 1,
                'poster': 'Poster', 'op': 'bad1'}, tok_p)
    check('zero qty -> 400', c == 400, c)
    c, _ = req(base, '/v1/boards/%s/orders' % B,
               {'itemID': 1, 'qtyTotal': 1,
                'pricePerUnit': gs.MAX_PRICE + 1,
                'poster': 'Poster', 'op': 'bad2'}, tok_p)
    check('price over cap -> 400', c == 400, c)

    srv.shutdown()
    print()
    if FAILURES:
        print('%d FAILURE(S): %s' % (len(FAILURES), FAILURES))
        sys.exit(1)
    print('all %d checks passed' % CHECKS[0])


if __name__ == '__main__':
    main()
