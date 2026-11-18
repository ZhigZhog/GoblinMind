#!/usr/bin/env python3
"""Tests for the sale-delta engine in goblin_brain.py.

Stubs api_state in memory and feeds synthetic lot snapshots through
delta_record. Covers: relist suppression (restack + reprice), pool
dedup (one new lot can't explain away two gone ones), confident /
inconclusive / no-tl classification, the ordering guard on stale
snapshots, and delta_stats math (vel floor, rsalep denominator,
veln, 'i' exclusion).

    python brain/test_delta.py        # exits nonzero on any failure
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import goblin_brain as gb

FAILURES = []
CHECKS = [0]


def check(name, cond, detail=''):
    CHECKS[0] += 1
    print(('  ok  ' if cond else 'FAIL  ') + name +
          (f' — {detail}' if not cond else ''))
    if not cond:
        FAILURES.append(name)


# in-memory api_state
STATE = {}
gb._load_api_state = lambda: dict(STATE)
gb._save_api_state = lambda s: STATE.update(s)

NOW = int(time.time())
SCOPE = 'TestScope-Alliance'


def book(lots, t):
    return {'lots': lots, 'lotsT': t, 't': t}


def run(b):
    gb.delta_record({SCOPE: b})


def events(iid):
    return (STATE.get('sales') or {}).get(SCOPE, {}).get(str(iid), [])


def reset():
    STATE.clear()


# --- scenario 1: restack relist is not a sale ---------------------
# old: one 7418-stack at 14836; new: ten 700-stacks at 14836 —
# the units moved shape, they didn't leave the market
reset()
run(book({'8068:7418:14836:2': 1}, NOW - 900))
run(book({'8068:700:14836:2': 10}, NOW))
check('restack relist suppressed', events(8068) == [],
      repr(events(8068)))

# --- scenario 2: reprice relist is not a sale ---------------------
# old: five 5-stacks at 100; new: five 5-stacks at 90 — same stacks,
# moved price
reset()
run(book({'4370:5:100:2': 5}, NOW - 900))
run(book({'4370:5:90:2': 5}, NOW))
check('reprice relist suppressed', events(4370) == [],
      repr(events(4370)))

# --- scenario 3: real sale records 's' ----------------------------
# old: three 1-stacks at 500 in bucket 2 (Long, >=2h left); new:
# nothing. elapsed 15m < 7200s -> provably had time left
reset()
run(book({'100:1:500:2': 3}, NOW - 900))
run(book({'200:1:10:3': 1}, NOW))
ev = events(100)
check('true sale recorded', len(ev) == 1, repr(ev))
check('true sale class s', ev and ev[0][5] == 's', repr(ev))
check('true sale units', ev and ev[0][1] == 3, repr(ev))
check('event carries item-total prev', ev and ev[0][4] == 3, repr(ev))

# --- scenario 4: short-bucket disappearance is inconclusive -------
# bucket 0 lower bound is 0 — elapsed 15m can equally be expiry
reset()
run(book({'101:1:500:0': 2}, NOW - 900))
run(book({'200:1:10:3': 1}, NOW))
ev = events(101)
check('bucket-0 disappearance class i', ev and ev[0][5] == 'i', repr(ev))
check('i event excluded from stats',
      gb.delta_stats(SCOPE).get(101) is None)

# --- scenario 5: partial relist, partial sale ---------------------
# old: two 4-stacks at 1000 (bucket 3); new: one 4-stack at 1000
# appeared at a different fp — wait, same prefix nets to 1 gone.
# Use restack: old two 8-stacks@1000, new one 16-stack@1000 +
# (nothing else): one lot restacked, one lot sold
reset()
run(book({'102:8:1000:3': 2}, NOW - 900))
run(book({'102:16:1000:3': 1}, NOW))
ev = events(102)
check('partial restack leaves one sale', len(ev) == 1 and ev[0][3] == 1,
      repr(ev))
check('partial sale units', ev and ev[0][1] == 8, repr(ev))

# --- scenario 6: one appeared lot can't cancel two gone -----------
# old: one 10-stack + one 20-stack at 500; new: one 30-stack at 500.
# by_unit pool has 1 appeared lot — it cancels ONE gone prefix, the
# other stays a sale
reset()
run(book({'103:10:500:3': 1, '103:20:500:3': 1}, NOW - 900))
run(book({'103:30:500:3': 1}, NOW))
ev = events(103)
check('one new lot cancels only one gone', len(ev) == 1, repr(ev))
check('residual sale recorded', ev and ev[0][3] == 1, repr(ev))

# --- scenario 7: ordering guard -----------------------------------
# a stale snapshot replayed after a newer one must not re-diff
reset()
run(book({'104:1:100:3': 5}, NOW))
run(book({'104:1:100:3': 3}, NOW + 600))   # 2 "sold"
run(book({'104:1:100:3': 4}, NOW + 300))   # stale — must not re-diff
ev = events(104)
check('stale snapshot skipped', len(ev) == 1 and ev[0][3] == 2, repr(ev))

# --- scenario 8: delta_stats math ---------------------------------
# two scans: 4 lots listed (two prefixes), 2 lots of one prefix sell.
# rsalep denominator must be all 4 listed lots, not the 2 that shrank
reset()
run(book({'105:1:100:3': 2, '105:5:200:3': 2}, NOW - 3600))
run(book({'105:5:200:3': 2}, NOW))
ds = gb.delta_stats(SCOPE).get(105) or {}
check('vel = units (day floor)', ds.get('vel') == 2, repr(ds))
check('veln = event count', ds.get('veln') == 1, repr(ds))
check('rsale = disappeared unit price', ds.get('rsale') == 100, repr(ds))
check('rsalep uses item-total lots', ds.get('rsalep') == 500, repr(ds))

# --- scenario 9: no tl data -> 'u', counted -----------------------
reset()
run(book({'106:1:100': 3}, NOW - 900))   # legacy 3-field fp
run(book({'200:1:10:3': 1}, NOW))
ev = events(106)
check('no-tl event class u', ev and ev[0][5] == 'u', repr(ev))
check('u counted in stats', (gb.delta_stats(SCOPE).get(106) or {})
      .get('vel') == 3)

# --- scenario 10: off-market anchor cancel -> 'i' -----------------
# 20 lots at median 100 + one wall at 5000 (50x). The wall
# disappearing is a cancelled anchor, not a purchase; the 5x-median
# lot next to it is still a legit sale
reset()
old_lots = {'108:1:100:3': 20, '108:1:5000:3': 1, '108:1:500:3': 1}
run(book(old_lots, NOW - 900))
run(book({'200:1:10:3': 1}, NOW))
ev = events(108)
check('all three prefixes got events', len(ev) == 3, repr(ev))
anchor = [e for e in ev if e[2] == 5000]
sale = [e for e in ev if e[2] == 500]
check('50x-median disappearance -> i', anchor and anchor[0][5] == 'i',
      repr(ev))
check('5x-median disappearance stays s', sale and sale[0][5] == 's',
      repr(ev))
ds = gb.delta_stats(SCOPE).get(108) or {}
check('anchor excluded from vel', ds.get('vel') == 21, repr(ds))

# --- scenario 11: window without old state -> no events -----------
reset()
run(book({'107:1:100:3': 5}, NOW))
check('first snapshot records no sales', events(107) == [])

print()
if FAILURES:
    print('%d FAILURES' % len(FAILURES))
    sys.exit(1)
print('all %d checks passed' % CHECKS[0])
