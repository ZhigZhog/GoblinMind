#!/usr/bin/env python3
"""Integration tests for goblin_server.py.

Runs the real Handler in-process on an ephemeral port against a temp
DB + temp goblin_server.json, so no live server is touched. Covers:
open + keyed registration, re-key on duplicate names, bearer auth,
payload validation/cleaning, newest-wins merge + lots ownership,
staleness cutoff + GC, the client-t clamp, and the rate limit.

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


def req(base, path, body=None, tok=None):
    url = base + path
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
        method = 'POST'
    else:
        data = None
        method = 'GET'
    if tok:
        headers['Authorization'] = 'Bearer ' + tok
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
    # GC ticks at most hourly (_last_gc clock) — reset it so the next
    # GET exercises the delete path deterministically
    gs._last_gc[0] = 0
    req(base, '/v1/book?scope=' + S)
    conn = sqlite3.connect(gs.DB_PATH)
    n = conn.execute('SELECT COUNT(*) FROM uploads WHERE t=?',
                     (old,)).fetchone()[0]
    conn.close()
    check('stale row GC\'d once the hourly tick fires', n == 0, n)

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

    srv.shutdown()
    print()
    if FAILURES:
        print('%d FAILURE(S): %s' % (len(FAILURES), FAILURES))
        sys.exit(1)
    print('all %d checks passed' % CHECKS[0])


if __name__ == '__main__':
    main()
