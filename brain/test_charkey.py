#!/usr/bin/env python3
"""Char-key migration sim — GetRealmName() is intermittently empty on
Forever (not just early login: it can stay empty through PLAYER_LOGOUT
teardown). CharKey()'s name-only fallback let snapshots and ledger
buckets persist under bare "Zhig" while other writes used
"Zhig-CAMWOW US1 Realm 5 PvE". The bare key then read as a DIFFERENT
character — AltTotal counted the player's own bags as an alt's, which
is what made crafting report "alt has N" for items on no alt.

Loads the REAL Core.lua + Ledger.lua + Inventory.lua in a lupa
runtime against sim/wow_stub.lua and drives realm flakiness with
_REALM ("" = unresolved).

    python brain/test_charkey.py    # exits nonzero on failure
"""
import os
import sys

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


def load(lua, fname):
    src = open(os.path.join(ADDON, fname), encoding='utf-8').read()
    res = lua.globals().load(src, '@' + fname)
    if isinstance(res, tuple):
        fn_l, err = res
        if fn_l is None:
            raise RuntimeError('compile failed: %s — %s' % (fname, err))
    else:
        fn_l = res
    fn_l('GoblinMind', lua.globals().GM)


def lt(lua, v):
    """table_from is shallow — convert nested dicts/lists recursively
    so addon code never indexes a Python object from Lua."""
    if isinstance(v, dict):
        return lua.table_from(
            {k: lt(lua, x) for k, x in v.items()})
    if isinstance(v, (list, tuple)):
        return lua.table_from([lt(lua, x) for x in v])
    return v


def realm_keys(tbl):
    """char keys in an inv/owned/byChar-style table"""
    out = []
    for k in tbl.keys():
        out.append(k)
    return sorted(out)


print('== char-key migration: phantom alt fix ==')

# ----------------------------------------------------------------
# Session A: realm resolves mid-session — the exact state from the
# live SV (bare Zhig + qualified Zhig + bare Unstable)
# ----------------------------------------------------------------
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(open(STUB, encoding='utf-8').read())
g = lua.globals()
g._NAME = 'Zhig'
g._NOW.t = 1795289000
REALM = 'CAMWOW US1 Realm 5 PvE'
g._REALM = ''                     # GetRealmName unresolved at load
lua.execute('function GetRealmName() return _REALM end')
lua.execute('SlashCmdList = {}')

# seed the split-key SavedVariables state BEFORE addon files load,
# like a real SV: bare + qualified Zhig inv entries, bare Unstable,
# split owned, and a qualified ledger bucket with old history
sv = g.GoblinMindSettings
sv.inv = lt(lua, {
    'Zhig': {'at': 1795289044,                  # NEWER — logout write
             'bags': {4338: 2, 2841: 10},
             'bank': {3575: 35, 2775: 11}},
    'Zhig-' + REALM: {'at': 1795196600,         # older live-session write
                      'bags': {4338: 9},
                      'bank': {9999: 1}},
    'Unstable': {'at': 1795277210,
                 'bags': {6948: 1, 2589: 1},
                 'bank': {}},
})
sv.owned = lt(lua, {
    'Zhig': {'at': 1795289000, 'bids': {},
             'rows': {'4338:1:100': {'itemID': 4338, 'qty': 1,
                                     'buyout': 100, 'at': 1795289000}}},
    'Zhig-' + REALM: {'at': 1795273275, 'bids': {},
                      'rows': {'9999:1:1': {'itemID': 9999, 'qty': 1,
                                            'buyout': 1,
                                            'at': 1795273275}}},
})
g.GoblinMindLedger = lt(lua, {
    'itemStats': {},
    'byChar': {
        'Zhig-' + REALM: {
            'transactions': [{'t': 100, 'ty': 'buy', 'i': 1, 'q': 2,
                              'u': 50}],
            'gold': [{'t': 90, 'd': 500, 'src': 'init'}],
        },
        'Alt2': {                              # another bare split
            'transactions': [{'t': 80, 'ty': 'sell', 'i': 2, 'q': 1,
                              'u': 9}],
            'gold': [],
        },
    },
})

for fn in ('Core.lua', 'Ledger.lua', 'Inventory.lua'):
    load(lua, fn)

check('files load under unresolved realm', True)

# ADDON_LOADED fires while realm is still "" — Ledger.Init must still
# build a usable live bucket under the bare fallback key
g.fire_event('ADDON_LOADED', 'GoblinMind')
check('ledger init under bare key', g.GM.Ledger._ck == 'Zhig')
check('live bucket created under bare key',
      g.GoblinMindLedger.byChar['Zhig'] is not None)

# session txns accrue under the bare live bucket pre-resolution
g.GM.Ledger.Add('buy', 4338, 5, 40)
check('session txn lands in bare bucket',
      len(g.GoblinMindLedger.byChar['Zhig'].transactions) == 1)

# reads pre-migration: IsSelfCharKey already prevents the phantom —
# Zhig-CAMWOW counts as self (name matches, realm undisprovable)
alt_2589 = g.GM.Inventory.AltTotal(2589)
alt_4338 = g.GM.Inventory.AltTotal(4338)
check('pre-migration: own items not counted as alt', alt_4338 == 0)
check('pre-migration: real alt still counted', alt_2589 == 2 or
      alt_2589 == 1, 'alt=%s' % alt_2589)

# realm resolves — migrate (the path Snapshot/AltTotal/PLAYER_LOGIN take)
g._REALM = REALM
g.GM.MigrateCharKeys()

ik = realm_keys(sv.inv)
check('inv keys canonicalized',
      ik == ['Unstable-' + REALM, 'Zhig-' + REALM], str(ik))
check('inv merge kept newest snapshot (bare)',
      sv.inv['Zhig-' + REALM].bags[2841] == 10)
check('inv merge dropped older snapshot data',
      sv.inv['Zhig-' + REALM].bags[4338] == 2)  # bare's 2, not qual's 9
check('alt re-keyed to current realm',
      sv.inv['Unstable-' + REALM].bags[6948] == 1)

ok_ = realm_keys(sv.owned)
check('owned keys canonicalized', ok_ == ['Zhig-' + REALM], str(ok_))

bk = realm_keys(g.GoblinMindLedger.byChar)
check('byChar keys canonicalized',
      bk == ['Alt2-' + REALM, 'Zhig-' + REALM], str(bk))
# live bucket rekeyed: this session's txn + the old qualified history
# merged in one place, facade refs preserved
tx = g.GoblinMindLedger.byChar['Zhig-' + REALM].transactions
check('live bucket rekeyed + history merged', len(tx) == 2,
      'n=%s' % len(tx))
check('merged txns time-ordered',
      tx[1].t == 100 and tx[2].i == 4338)
check('facade still points at live bucket',
      g.GM.Ledger.db.transactions[1].t == 100)
check('alt2 bucket re-keyed with history',
      g.GoblinMindLedger.byChar['Alt2-' + REALM]
      .transactions[1].ty == 'sell')

# migration is one-shot — a second call must not double-merge
g.GM.MigrateCharKeys()
check('migration idempotent',
      len(g.GoblinMindLedger.byChar['Zhig-' + REALM]
          .transactions) == 2)

# post-migration reads
check('alt total still counts only real alts',
      g.GM.Inventory.AltTotal(2589) == 1)
check('bank stored reads merged self snapshot',
      g.GM.Inventory.BankStored(3575) == 35)
check('owned rehydrated from merged newest snapshot',
      g.GM.Inventory.auctions['4338:1:100'] is not None and
      g.GM.Inventory.auctions['9999:1:1'] is None)
check('ledger chars list for the switcher',
      'Zhig-' + REALM in realm_keys(g.GoblinMindLedger.byChar))

# realm flakes back to empty — new writes must not re-create bare keys
g._REALM = ''
g.fire_event('BAG_UPDATE')
g._NOW.t = g._NOW.t + 1
g.run_due()
check('no bare inv key recreated while realm empty',
      'Zhig' not in realm_keys(sv.inv))

# realm back — bag snapshot lands under the qualified key
g._REALM = REALM
g.fire_event('BAG_UPDATE')
g._NOW.t = g._NOW.t + 1
g.run_due()
check('qualified snapshot written on bag update',
      sv.inv['Zhig-' + REALM] is not None)

# ----------------------------------------------------------------
# Session B: realm NEVER resolves — writes stay frozen rather than
# poisoning; reads still treat the split keys as self (no phantom)
# ----------------------------------------------------------------
lua2 = LuaRuntime(unpack_returned_tuples=True)
lua2.execute(open(STUB, encoding='utf-8').read())
g2 = lua2.globals()
g2._NAME = 'Zhig'
g2._NOW.t = 1795289000
g2._REALM = ''
lua2.execute('function GetRealmName() return _REALM end')
lua2.execute('SlashCmdList = {}')
sv2 = g2.GoblinMindSettings
sv2.inv = lt(lua2, {
    'Zhig': {'at': 100, 'bags': {4338: 2}, 'bank': {}},
    # qualified is the NEWER bank snapshot — BankStored must read
    # across the bare/qualified spelling split
    'Zhig-' + REALM: {'at': 110, 'bags': {4338: 9}, 'bank': {3575: 5}},
    'Unstable': {'at': 95, 'bags': {6948: 1}, 'bank': {}},
})
for fn in ('Core.lua', 'Ledger.lua', 'Inventory.lua'):
    load(lua2, fn)
g2.fire_event('ADDON_LOADED', 'GoblinMind')
g2.fire_event('BAG_UPDATE')
g2._NOW.t = g2._NOW.t + 1
g2.run_due()
check('never-resolve: no new bare writes (inv untouched)',
      sorted(realm_keys(sv2.inv)) ==
      ['Unstable', 'Zhig', 'Zhig-' + REALM],
      str(realm_keys(sv2.inv)))
check('never-resolve: own items still not alt-counted',
      g2.GM.Inventory.AltTotal(4338) == 0)
check('never-resolve: bank reads newest self snapshot',
      g2.GM.Inventory.BankStored(3575) == 5)

print()
if FAILURES:
    print('%d FAILURES' % len(FAILURES))
    sys.exit(1)
print('all %d checks passed' % CHECKS[0])
