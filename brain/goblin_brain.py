#!/usr/bin/env python3
"""GoblinMind brain — phase-1 spike (M0+M2).

Reads TradeSkillMaster_AppHelper/AppData.lua (the TSM desktop app's
drop point) and either reports what it contains or emits the generated
GoblinMind_Data addon file.

Usage:
    goblin_brain.py dump <AppData.lua>            tag/scope inventory + decode sanity
    goblin_brain.py emit <AppData.lua> <Data.lua> write GoblinMindDB (atomic)
    goblin_brain.py watch <AppData.lua> <out>...  emit whenever AppData updates

Format notes (verified against the live file):
  each line:  select(2, ...).LoadData("TAG","Scope",[[return {...}]])
  payload:    {downloadTime=N, fields={...}, data={{row},{row}}}
  values:     bare tokens — numeric literals stay ints; letter-bearing
              tokens like 9C / 1JI are base-36 encoded copper (or counts).
"""
import argparse
import glob
import json
import logging
import math
import logging.handlers
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

LOG = logging.getLogger('goblin_brain')


def setup_logging(verbose=False, log_path=None):
    """Console gets timestamped lines; the file gets full timestamps and
    survives the process so a dead window still leaves a post-mortem."""
    LOG.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter('%(asctime)s %(levelname)-5s %(message)s',
                            '%H:%M:%S')
    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(fmt)
    LOG.addHandler(ch)
    if log_path:
        fh = logging.handlers.RotatingFileHandler(
            log_path, maxBytes=2 * 1024 * 1024, backupCount=2,
            encoding='utf-8')
        fh.setFormatter(logging.Formatter(
            '%(asctime)s %(levelname)-5s %(message)s'))
        LOG.addHandler(fh)
        LOG.info('logging to %s', log_path)

CHUNK_RE = re.compile(
    r'select\(2, \.\.\.\)\.LoadData\("([^"]+)","([^"]+)",\[\[(.*)\]\]\)')


# ---------- mini Lua table-literal parser ----------

def _ws(s, i):
    while i < len(s) and s[i] in ' \t\r\n':
        i += 1
    return i


def _atom(s, i):
    m = re.match(r'[^\s,}=\]]+', s[i:])
    tok = m.group(0)
    i += len(tok)
    if tok == 'true':
        return True, i
    if tok == 'false':
        return False, i
    if tok == 'nil':
        return None, i
    # TSM encodes every data field as an UPPERCASE base-32 token —
    # including digit-only ones ('13' is 35 base-32, not thirteen).
    # Hand them all to the field decoder as strings: int() would
    # steal digit tokens as decimal, and float() reads '6E8' as
    # 6e8 scientific notation — that's where the billion-scale
    # tooltip prices came from.
    if re.fullmatch(r'[0-9A-Z]+', tok):
        return tok, i
    try:
        return int(tok), i
    except ValueError:
        pass
    try:
        v = float(tok)
        # nan/inf leak in from the TSM app (division by zero in its
        # aggregates) — they're not data; treat as absent so emit
        # math and the Lua file never see a non-finite float
        if not math.isfinite(v):
            return None, i
        return v, i
    except ValueError:
        pass
    return tok, i  # bare letter-tokens like 1JI land here as strings


def _string(s, i):
    q = s[i]
    out = []
    j = i + 1
    while j < len(s):
        ch = s[j]
        if ch == '\\':
            out.append(s[j + 1])
            j += 2
            continue
        if ch == q:
            return ''.join(out), j + 1
        out.append(ch)
        j += 1
    raise ValueError('unterminated string')


def _table(s, i):
    """Parse {...} starting at s[i]=='{'. Returns ({pos_idx->val} + named)."""
    assert s[i] == '{'
    i = _ws(s, i + 1)
    out = {}
    pos = 1
    while s[i] != '}':
        i = _ws(s, i)
        key = None
        if s[i] == '[':
            j = s.index(']', i)
            key = s[i + 1:j].strip('\'"')
            i = _ws(s, j + 1)
            assert s[i] == '='
            i += 1
        else:
            m = re.match(r'([A-Za-z_][A-Za-z0-9_]*)\s*=', s[i:])
            if m:
                key = m.group(1)
                i += m.end()
        if key is None:
            key = pos
            pos += 1
        i = _ws(s, i)
        if s[i] == '{':
            out[key], i = _table(s, i)
        elif s[i] in '"\'':
            out[key], i = _string(s, i)
        else:
            out[key], i = _atom(s, i)
        i = _ws(s, i)
        if s[i] == ',':
            i = _ws(s, i + 1)
    return out, i + 1


def parse_payload(payload):
    """'return {...}' -> dict"""
    s = payload.strip()
    if s.startswith('return'):
        s = s[6:]
    s = s.strip()
    val, _ = _table(s, 0)
    return val


def b32(v):
    """Base-32 decode for TSM's AppData value encodings — matches
    UnpackData in LibTSMService/AuctionDB.lua verbatim: tonumber(v,32),
    and tokens longer than 6 chars split into hi*2^30 + lo because
    Lua's tonumber can't represent >32-bit base conversions. The old
    base-36 guess mispriced every TSM-derived field ~20-30%."""
    if not isinstance(v, str) or not re.fullmatch(r'[0-9A-Z]+', v):
        return v
    try:
        if len(v) <= 6:
            return int(v, 32)
        return int(v[:-6], 32) * (1 << 30) + int(v[-6:], 32)
    except ValueError:
        return None  # a W-Z token can't be base-32 — corrupt, not data


def rows_of(chunk):
    """Yield dict rows for a parsed chunk payload."""
    if 'fields' not in chunk or 'data' not in chunk:
        return
    fields = [chunk['fields'][i] for i in sorted(chunk['fields'])
              if isinstance(i, int)]
    for ri in sorted(chunk.get('data', {})):
        if not isinstance(ri, int):
            continue
        row = chunk['data'][ri]
        yield {fields[k - 1]: row[k] for k in sorted(row) if isinstance(k, int)
               and k - 1 < len(fields)}


# ---------- chunk collection ----------

def read_chunks(path):
    """-> { (tag, scope): {downloadTime, fields, data} }, newest wins."""
    chunks = {}
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = CHUNK_RE.search(line)
            if not m:
                continue
            tag, scope, payload = m.groups()
            chunk = parse_payload(payload)
            # header fields are decimal, not base-32 — _atom leaves
            # all [0-9A-Z]+ tokens as strings, so coerce explicitly
            if 'downloadTime' in chunk:
                chunk['downloadTime'] = int(chunk['downloadTime'])
            key = (tag, scope)
            if key not in chunks or chunk['downloadTime'] > chunks[key]['downloadTime']:
                chunks[key] = chunk
    return chunks


# ---------- commands ----------

def cmd_dump(path):
    chunks = read_chunks(path)
    print(f'{len(chunks)} chunks')
    for (tag, scope), c in sorted(chunks.items()):
        if 'fields' not in c:
            print(f'\n{tag} [{scope}]  (no fields/data — keys: '
                  f'{[k for k in c if not isinstance(k, int)]})')
            continue
        fields = [c['fields'][i] for i in sorted(c['fields'])
                  if isinstance(i, int)]
        n = sum(1 for k in c.get('data', {}) if isinstance(k, int))
        print(f'\n{tag} [{scope}]  rows={n}  dl={c["downloadTime"]} '
              f'({time.strftime("%H:%M", time.localtime(c["downloadTime"]))})')
        print(f'  fields={fields}')
        for j, row in enumerate(rows_of(c)):
            if j >= 3:
                break
            dec = {k: (v if k == 'itemString' else b32(v))
                   for k, v in row.items()}
            print(f'  {dec}')


def _first(rows, *keys):
    for r in rows:
        for k in keys:
            if k in r:
                return r[k]


def load_vendor_buy(path):
    """TSM ships a static vendor-sell table — items vendors stock with
    their buy cost. vendorbuy isn't a registered TSM custom-price
    source, so we can't query it through TSMAPI_FOUR; parse the Retail
    table (Forever branch) straight out of LibTSMData instead."""
    addons = os.path.dirname(os.path.dirname(path))
    f = os.path.join(addons, 'TradeSkillMaster', 'LibTSMData',
                     'Item', 'VendorSell.lua')
    out = {}
    try:
        src = open(f, encoding='utf-8', errors='replace').read()
    except OSError:
        return out
    m = re.search(r'VendorSell\.Retail\s*=\s*\{(.*?)\n\}', src, re.S)
    if not m:
        return out
    for iid, cost in re.findall(r'\["i:(\d+)"\]\s*=\s*(\d+)', m.group(1)):
        out[int(iid)] = int(cost)
    return out


def tsm_items(chunks, realm=None):
    """Parse AUCTIONDB chunks -> (items_by_scope, data_age, realm_age,
    region_age). Realm chunks land under their own scope
    ('Normal-Alliance'); region rows overlay onto every realm scope
    (region stats are realm-agnostic). realm = configured scope —
    when set, only that scope's realm rows are consumed (cross-realm
    pollution guard); without it every realm scope gets its own
    entry."""
    data_age = realm_age = region_age = 0
    # scope -> iid -> raw decoded record; '_region' holds region rows
    per_scope = {'_region': {}}
    for (tag, scope), c in chunks.items():
        if not tag.startswith('AUCTIONDB'):
            continue
        is_region = scope.endswith('-US') or '_REGION_' in tag
        if realm and not is_region and scope != realm:
            continue
        data_age = max(data_age, c['downloadTime'])
        if is_region:
            region_age = max(region_age, c['downloadTime'])
        else:
            realm_age = max(realm_age, c['downloadTime'])
        bucket = per_scope.setdefault(
            '_region' if is_region else scope, {})
        for row in rows_of(c):
            isr = row.get('itemString')
            if isr is None:
                continue
            item_id = int(isr) if isinstance(isr, int) else \
                int(isr.split(':')[1]) if isinstance(isr, str) and isr.startswith('i:') else \
                int(isr) if isinstance(isr, str) and isr.isdigit() else None
            if item_id is None:
                continue
            rec = bucket.setdefault(item_id, {})
            for k, v in row.items():
                if k == 'itemString':
                    continue
                if is_region:
                    rec.setdefault('region', {})[k] = b32(v)
                else:
                    rec[k] = b32(v)

    # shape each scope: realm rows + region overlay
    items_by_scope = {}
    for scope, bucket in per_scope.items():
        if scope == '_region':
            continue
        items = {}
        for item_id, rec in bucket.items():
            region = dict(per_scope['_region'].get(item_id, {})
                          .get('region', {}))
            region.update(rec.get('region', {}))
            p = rec.get('marketValue') or rec.get('marketValueRecent') \
                or rec.get('minBuyout') or rec.get('historical')
            if not p:
                p = region.get('regionMarketValue') \
                    or region.get('regionHistorical')
            if not p:
                LOG.debug('item %s: no price fields — skipped', item_id)
                continue
            # regionSoldPerDay is a raw count — TSM displays it unscaled in
            # its tooltip (regionSalePercent is the only permille field).
            # regionSale is a PRICE, not a rate — falling back to it
            # emitted copper values as "units/day" (vel=6600 on dead
            # items). Absent rate data stays nil, honestly.
            vel = region.get('regionSoldPerDay')
            out = {
                'p': p,
                'p10': int(p * 0.85),   # placeholder band until the model lands
                'p90': int(p * 1.15),
            }
            # v2: pass every source field through with compact keys — the
            # pricing engine resolves db* names to these (see Pricing.lua)
            for k, v in (
                ('mkt',    rec.get('marketValue')),         # dbmarket
                ('mb',     rec.get('minBuyout')),           # dbminbuyout
                ('hist',   rec.get('historical')),          # dbhistorical
                ('recent', rec.get('marketValueRecent')),
                ('sup',    rec.get('numAuctions')),
                ('rmkt',   region.get('regionMarketValue')),  # dbregionmarketavg
                ('rhist',  region.get('regionHistorical')),   # dbregionhistorical
                ('rsale',  region.get('regionSale')),         # dbregionsale
                ('rsalep', region.get('regionSalePercent')),  # permille — /1000 at read
            ):
                if v:
                    out[k] = v
            if vel:  # dbregionsalerate
                out['vel'] = round(vel) if vel >= 10 else round(vel, 1)
            mb = rec.get('minBuyout')
            if mb and mb < p * 0.85:
                out['reset'] = {
                    'below': mb,
                    'maxN': rec.get('numAuctions') or 10,
                    'ev': int((p * 0.95 - mb) * min(
                        rec.get('numAuctions') or 1, max(vel or 1, 1))),
                }
            items[item_id] = out
        items_by_scope[scope] = items
    return items_by_scope, data_age, realm_age, region_age


def cmd_emit(path, out_path, realm=None):
    chunks = read_chunks(path)
    items_by_scope, data_age, realm_age, region_age = \
        tsm_items(chunks, realm)
    # realm-aware emit: scopes mirror cmd_book's shape so the addon's
    # realms[GM.Scope()] lookup works on either feed; flat items is
    # the primary scope for legacy readers
    realms = {s: {'items': items, 'dataAge': realm_age or data_age,
                  'generated': int(time.time())}
              for s, items in items_by_scope.items()}
    primary = realm or max(realms, key=lambda s: len(realms[s]['items']),
                           default=None)
    flat = realms.get(primary, {})

    db = {
        'version': 3,
        'source': 'tsm',
        'filedBugs': [
            {'id': rid, 'url': url} for rid, url in load_filed().items()],
        'generated': int(time.time()),
        'dataAge': data_age,      # newest downloadTime across all chunks
        'realmAge': realm_age,    # realm-scope chunks only (≈ TSM "Realm Data")
        'regionAge': region_age,  # region-scope chunks only (≈ TSM "Region Data")
        'realms': realms,
        'items': flat.get('items', {}),
        'vendorBuy': load_vendor_buy(path),  # TSM VendorSell.Retail → id=cost
    }

    write_db(db, out_path)
    LOG.info('emitted %d scopes %d items -> %s (%d KB)',
             len(realms), sum(len(r['items']) for r in realms.values()),
             out_path, os.path.getsize(out_path) // 1024)
    return sum(len(r['items']) for r in realms.values())


_IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*\Z')


def _enc_key(k):
    # numeric keys index directly; identifier-safe names go bare;
    # anything else ("Realm-Faction" scopes, hyphens, spaces) must
    # be bracket-quoted — a bare CAMWOWUS1Realm5PvE-Alliance= breaks
    # the whole generated file at load
    if isinstance(k, int):
        return f'[{k}]'
    if _IDENT.fullmatch(str(k)):
        return str(k)
    return '["%s"]' % str(k).replace('\\', '\\\\').replace('"', '\\"')


def _enc(v):
    if isinstance(v, dict):
        return '{' + ','.join(
            _enc_key(k) + '=' + _enc(x)
            for k, x in v.items() if x is not None
            and not (isinstance(x, float) and not math.isfinite(x))) + '}'
    # a bare nan/inf would emit 'inf'/'nan' — invalid Lua that
    # breaks the whole generated file at load
    if isinstance(v, float) and not math.isfinite(v):
        return 'nil'
    if isinstance(v, (list, tuple)):
        return '{' + ','.join(_enc(x) for x in v) + '}'
    if isinstance(v, str):
        return '"' + v + '"'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    return repr(v)


def write_db(db, out_path):
    """Atomic GoblinMindDB write — shared by the TSM emit and the
    in-house book feed."""
    text = ('-- generated by goblin_brain.py — do not edit\n'
            'GoblinMindDB = ' + _enc(db) + '\n')
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out_path),
                               suffix='.tmp')
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)
    os.replace(tmp, out_path)


# ---------- in-house feed: book + ledger -> GoblinMindDB ----------
# Replaces TSM's AppData as the data source: the addon's persistent AH
# book (GoblinMindSettings.book) is the current snapshot; the brain
# owns the time series (book_history.json) and computes market value,
# and the ledger's sell transactions give real sale velocity. Same
# GoblinMindDB schema — the addon can't tell the feeds apart.

HIST_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'book_history.json')
HIST_KEEP = 14 * 86400   # days of book snapshots to retain
VEL_DAYS = 7             # ledger window for sales/day


def _lua_ws(s, i):
    while i < len(s) and s[i] in ' \t\r\n':
        i += 1
    return i


def _lua_value(s, i):
    """Parse one Lua literal at i. Returns (value, next_i)."""
    i = _lua_ws(s, i)
    if i >= len(s):
        return None, i
    ch = s[i]
    if ch == '{':
        return _lua_table(s, i + 1)
    if ch in '"\'':
        j, out = i + 1, []
        while j < len(s) and s[j] != ch:
            if s[j] == '\\' and j + 1 < len(s):
                out.append(s[j + 1]); j += 2
            else:
                out.append(s[j]); j += 1
        return ''.join(out), j + 1
    if s.startswith('[[', i):
        j = s.find(']]', i + 2)
        return s[i + 2:j], j + 2
    m = re.match(r'-?\d+\.?\d*([eE][+-]?\d+)?', s[i:])
    if m:
        txt = m.group(0)
        try:
            return (float(txt) if any(c in txt for c in '.eE')
                    else int(txt)), i + m.end()
        except ValueError:
            pass
    m = re.match(r'[A-Za-z_]\w*', s[i:])
    if m:
        w = m.group(0)
        v = {'true': True, 'false': False, 'nil': None}.get(w, w)
        return v, i + m.end()
    return None, i + 1


def _lua_table(s, i):
    """Parse a Lua table ctor body (i is just past '{'). Keyed and
    positional entries both land in a dict."""
    t, pos = {}, 0
    while True:
        i = _lua_ws(s, i)
        while i < len(s) and s[i] in ',;':
            i = _lua_ws(s, i + 1)
        if i >= len(s) or s[i] == '}':
            return t, i + 1
        if s[i] == '[':
            k, j = _lua_value(s, i + 1)
            j = _lua_ws(s, j)
            if j < len(s) and s[j] == ']':
                j = _lua_ws(s, j + 1)
                if j < len(s) and s[j] == '=':
                    v, i = _lua_value(s, j + 1)
                    t[k] = v
                    continue
            i = j
        m = re.match(r'[A-Za-z_]\w*\s*=', s[i:])
        if m:
            v, i = _lua_value(s, i + m.end())
            t[m.group(0)[:-1].strip()] = v
        else:
            v, i = _lua_value(s, i)
            pos += 1
            t[pos] = v


def load_sv_tables(path, names):
    """Pull top-level NAME = {...} assignments out of a SavedVariables
    file. Only the subset of Lua SV files use is supported."""
    try:
        src = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return {}
    out = {}
    for name in names:
        m = re.search(r'(?m)^' + re.escape(name) + r'\s*=\s*\{', src)
        if m:
            t, _ = _lua_table(src, m.end())
            out[name] = t
    return out


def load_book_hist():
    try:
        with open(HIST_PATH, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_book_hist(hist):
    tmp = HIST_PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(hist, fh)
    os.replace(tmp, HIST_PATH)


def _median(vals):
    vals = sorted(vals)
    n = len(vals)
    if not n:
        return None
    mid = n // 2
    return int((vals[mid] if n % 2 else (vals[mid - 1] + vals[mid]) / 2))


def _market_value(samples, now):
    """Weighted trimmed mean of min-buyout samples [(ts, price), ...].

    Model: drop samples outside [med/3, 3*med] (manipulation spikes
    and dump listings), weight the survivors by recency (half-life
    ~4 days), then take a weighted mean trimmed 10% off each end of
    the price distribution. TSM's dbmarket is the same family —
    recency-weighted, trimmed — so `mkt` stays meaningfully comparable
    across the cutover. Returns int or None."""
    vals = [p for _, p in samples if p and p > 0]
    if not vals:
        return None
    med = _median(vals)
    kept = [(t, p) for t, p in samples
            if p and med / 3 <= p <= med * 3]
    if not kept:
        kept = [(t, p) for t, p in samples if p and p > 0]
    w = sorted(
        ((2.0 ** (-(now - t) / (4.0 * 86400)), p) for t, p in kept),
        key=lambda x: x[1])
    total = sum(x[0] for x in w)
    if total <= 0:
        return None
    cum, lo, hi = 0.0, 0, len(w)
    for i, (x, _) in enumerate(w):
        cum += x
        if cum <= total * 0.1:
            lo = i + 1
    cum = 0.0
    for i in range(len(w) - 1, -1, -1):
        cum += w[i][0]
        if cum <= total * 0.1:
            hi = i
    mid = w[lo:hi] or w
    return int(sum(x * p for x, p in mid) / sum(x for x, _ in mid))


def _sv_root(path, root=None):
    """WoW install root: feeds.json `root` if given, else derived —
    3 ups from an AppData.lua path, 4 from a SavedVariables file."""
    if root:
        return os.path.normpath(root)
    n = 4 if os.path.basename(path).lower() == 'goblinmind.lua' else 3
    return os.path.normpath(os.path.join(
        os.path.dirname(path), *(['..'] * n)))


def _existing_db_has_items(path):
    """True when the current output DB already prices items — the
    emitted format writes `items={` then `[` for the first entry, so
    `items={}` marks an empty table. Lets the clobber guard protect a
    shipped DB on a fresh history too."""
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            head = fh.read(262144)
    except OSError:
        return False
    m = re.search(r'items\s*=\s*\{', head)
    return bool(m) and head[m.end():m.end() + 1] == '['


def cmd_book(sv_arg, out_paths, root=None, feed=None, realm=None):
    """Emit GoblinMindDB from our own feeds. Merges every
    GoblinMind.lua on the account: newest book snapshot wins per
    item, all snapshots feed the history, and ledger sells sum
    across characters. Missing data stays nil — honest absence,
    never fabricated."""
    if os.path.basename(sv_arg).lower() == 'goblinmind.lua':
        paths = [sv_arg]
    else:  # AppData path / feed root — glob SVs
        paths = sv_paths(sv_arg, root)
    # scope = addon's "Realm-Faction" — books merge only within the
    # same scope; legacy flat books land under 'default'
    books_by_scope, ledger_bychar = {}, {}
    for p in paths:
        sv = load_sv_tables(p,
                            ['GoblinMindSettings', 'GoblinMindLedger'])
        gms = sv.get('GoblinMindSettings') or {}
        for scope, b in (gms.get('books') or {}).items():
            if b and b.get('items'):
                books_by_scope.setdefault(
                    str(scope), []).append(b)
        b = gms.get('book')
        if b and b.get('items'):
            books_by_scope.setdefault(
                str(b.get('scope') or 'default'), []).append(b)
        ledger_bychar.update(
            (sv.get('GoblinMindLedger') or {}).get('byChar') or {})
    now = time.time()

    hist = load_book_hist()  # {scope: {iid: [[ts,mb,sup,n],...]}}
    # migrate pre-scope history into 'default'
    if hist and not any(isinstance(v, dict) for v in hist.values()):
        hist = {'default': hist}
    for scope, books in books_by_scope.items():
        sh = hist.setdefault(scope, {})
        for b in books:
            snap_t = int(b.get('t') or now)
            for iid, e in (b.get('items') or {}).items():
                rec = sh.setdefault(str(int(iid)), [])
                # idempotent — a re-run on the same flush must not
                # double-count the snapshot
                if not any(r and r[0] == snap_t for r in rec):
                    rec.append([snap_t, e.get('mb'), e.get('sup'),
                                e.get('n')])
                sh[str(int(iid))] = [
                    r for r in rec
                    if r and r[0] and now - r[0] < HIST_KEEP]
    save_book_hist(hist)

    def _norm(s):
        return re.sub(r'[^a-z0-9]', '', s.lower())

    # velocity per scope — a char's sells attribute to the scope whose
    # realm matches their char key ("Name-Realm" display form)
    vel = {}
    for ck, char in ledger_bychar.items():
        crealm = ck.rsplit('-', 1)[-1] if '-' in ck else ''
        for tx in (char.get('transactions') or {}).values():
            if (tx.get('ty') != 'sell'
                    or now - (tx.get('t') or 0) >= VEL_DAYS * 86400):
                continue
            targets = [s for s in books_by_scope
                       if _norm(s.rsplit('-', 1)[0])
                       == _norm(crealm)] or list(books_by_scope)
            for s in targets:
                v = vel.setdefault(s, {})
                iid = int(tx['i'])
                v[iid] = v.get(iid, 0) + int(tx.get('q') or 1)

    # clobber guard: a parse that found no books means the SV was
    # read mid-write, the addon migrated formats, or the player just
    # hasn't scanned yet — refuse to overwrite a populated DB
    # (shipped or previously emitted) with an empty one.
    if not books_by_scope and (
            any(hist.get(s) for s in hist)
            or any(_existing_db_has_items(o) for o in out_paths)):
        LOG.warning('book emit skipped — no books parsed but a '
                    'populated DB/history exists (mid-write SV, format '
                    'migration, or no scans yet); keeping last good DB')
        return

    # TSM backend: parse AppData realm+region chunks for the
    # configured realm — the shared feed TSM pulls from. It's the
    # source of truth where most current; a fresher full scan wins.
    # Scope names match (both are "Realm-Faction"), so TSM items map
    # straight onto book scopes.
    tsm_by_scope = {}
    tsm_realm_age = tsm_region_age = 0
    if os.path.basename(sv_arg).lower() != 'goblinmind.lua' \
            and os.path.exists(sv_arg):
        tsm_by_scope, _, tsm_realm_age, tsm_region_age = \
            tsm_items(read_chunks(sv_arg), realm)

    # TSM scope names differ from the addon's GM.Scope() names —
    # TSM normalizes realms its own way ('Normal-Alliance' vs
    # 'CAMWOWUS1Realm5PvE-Alliance'). Fold the configured TSM realm
    # scope into every book scope sharing its faction suffix.
    tsm_main = tsm_by_scope.get(realm) if realm else {}
    tsm_faction = realm.rsplit('-', 1)[-1] if realm else None
    tsm_consumed = set()

    realms = {}
    for scope, books in books_by_scope.items():
        # newest book per item defines the current listing picture
        latest, latest_t = {}, 0
        for b in sorted(books, key=lambda x: x.get('t') or 0):
            latest_t = int(b.get('t') or latest_t)
            for iid, e in (b.get('items') or {}).items():
                latest[int(iid)] = e
        items = {}
        for iid, e in latest.items():
            samples = [(r[0], r[1])
                       for r in hist.get(scope, {}).get(str(iid), [])
                       if len(r) > 1 and r[0] and r[1]]
            p = _market_value(samples, now)
            items[iid] = {
                'mb': e.get('mb'),
                'mbx': None if e.get('mbx') == -1 else e.get('mbx'),
                'sup': e.get('sup'),
                'n': e.get('n'),
                'p': p, 'mkt': p,
                'vel': vel.get(scope, {}).get(iid),
            }
        # merge over the TSM backend for this scope: TSM-only fields
        # (hist/recent/region stats/reset) always come from TSM; the
        # book's live listing fields win when the scan is fresher than
        # the feed (per-item rule is scope-level: one snapshot time
        # vs one downloadTime)
        same_faction = tsm_faction and \
            scope.rsplit('-', 1)[-1] == tsm_faction
        tsm_scope_items = tsm_main if same_faction else {}
        if tsm_scope_items:
            tsm_consumed.add(realm)
        book_fresh = latest_t >= tsm_realm_age or not tsm_scope_items
        merged = dict(tsm_scope_items)
        for iid, e in items.items():
            m = merged.get(iid) or {}
            # cross-source sanity: our weighted mean diverging >25x
            # from TSM's own marketValue/historical is a data bug
            # (poisoned sample, stale emit), never a real market —
            # keep TSM's number for the price fields
            p_sane = True
            anchor = m.get('mkt') or m.get('hist')
            if e.get('p') and anchor and (
                    e['p'] > anchor * 25 or e['p'] < anchor / 25):
                p_sane = False
            for k in ('mbx', 'n'):
                if e.get(k) is not None:
                    m[k] = e[k]
            if book_fresh:
                for k in ('mb', 'sup', 'p', 'mkt', 'vel'):
                    if e.get(k) is not None and (
                            k not in ('p', 'mkt') or p_sane):
                        m[k] = e[k]
            else:
                # backend newer — book listing fields still fill gaps
                # where the feed has nothing for this item
                for k in ('mb', 'sup', 'p', 'mkt', 'vel'):
                    if m.get(k) is None and e.get(k) is not None:
                        m[k] = e[k]
            merged[iid] = m
        realms[scope] = {
            'items': merged,
            'dataAge': max(latest_t,
                           tsm_realm_age if tsm_scope_items else 0)
            or None,
            'generated': int(now),
        }
    # a TSM realm with no same-faction book scope still emits under
    # its own name — reachable via the flat top-level mirror
    for scope, tsm_scope_items in tsm_by_scope.items():
        if scope not in tsm_consumed and scope not in realms:
            realms[scope] = {
                'items': tsm_scope_items,
                'dataAge': tsm_realm_age or None,
                'generated': int(now),
            }

    # flat top-level mirror of the primary scope — keeps pre-realm
    # consumers working (largest scope wins)
    primary = max(realms, key=lambda s: len(realms[s]['items']),
                  default=None)
    flat = realms[primary] if primary else {}

    db = {
        'version': 3,
        'source': 'bookfeed',
        'filedBugs': [{'id': rid, 'url': url}
                      for rid, url in load_filed().items()],
        'generated': int(now),
        # client computes time() - dataAge — must be the snapshot
        # TIMESTAMP (like the TSM emit's newest downloadTime), not
        # an age duration
        'dataAge': flat.get('dataAge'),
        # TSM backend clocks — the addon's RealmAge/RegionAge read
        # these; None when AppData wasn't parsed (SV-path invocation)
        'realmAge': tsm_realm_age or None,
        'regionAge': tsm_region_age or None,
        'feed': feed,
        'realms': realms,
        'items': flat.get('items', {}),
        # vendorBuy is static data scraped from TSM's own addon files —
        # resolve under the feed's WoW root (feeds.json `root`, or the
        # root derived from whichever path located the feed)
        'vendorBuy': load_vendor_buy(os.path.join(
            _sv_root(sv_arg, root), 'Interface', 'AddOns',
            'TradeSkillMaster_AppHelper', 'AppData.lua')),
    }
    for out in out_paths:
        write_db(db, out)
        LOG.info('book emit %d scopes %d items (%d sv) -> %s',
                 len(realms), sum(len(r['items'])
                                for r in realms.values()),
                 len(paths), out)


# ---------- in-game bug reports -> GitHub ----------
# The addon stages reports in the GoblinMindSettings SavedVariable as
# "id|hex" strings (SV only flushes on /reload or logout). We regex
# them out of the SV file, file each to GitHub via REST using the git
# credential manager's token, and echo filed ids back to the addon
# through the emitted GoblinMindDB.filedBugs so it clears them.

REPO = os.environ.get('GOBLINMIND_REPO', 'ZhigZhog/GoblinMind')
REPORT_RE = re.compile(r'"(gm-[^"|]+)\|([0-9a-fA-F]+)"')
FILED_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'filed_bugs.json')


FEEDS_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'feeds.json')


def load_feeds():
    """Named feed registry — one entry per WoW install/feed:
    {"forever": {"name": "WoW Forever", "appdata": ".../AppData.lua",
    "root": ".../_forever_", "out": ["...Data.lua", "...Data.lua"]}}
    Porting to another client = add an entry, no code change."""
    try:
        with open(FEEDS_PATH, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def self_feed():
    """Zero-config feed for packaged releases: when the script lives
    inside a WoW install (Interface/AddOns/<addon>/brain/), root and
    out derive from __file__ — no feeds.json needed. Returns None
    when run from a dev tree or anywhere else."""
    here = os.path.dirname(os.path.abspath(__file__))      # .../brain
    addon_dir = os.path.dirname(here)                      # .../GoblinMind
    addons_dir = os.path.dirname(addon_dir)                # .../AddOns
    interface = os.path.dirname(addons_dir)                # .../Interface
    root = os.path.dirname(interface)                      # .../_forever_
    if os.path.basename(interface).lower() != 'interface':
        return None
    if not os.path.isdir(os.path.join(root, 'WTF')):
        return None
    # When TSM's app data exists, watch IT: the desktop app's periodic
    # pushes then drive emits (the ~hourly cadence) AND cmd_book's TSM
    # merge reads real chunks instead of the script. Without TSM the
    # book feed has no AppData — watch the script itself so the stat
    # path stays valid and quiet.
    tsm_appdata = os.path.join(
        addons_dir, 'TradeSkillMaster_AppHelper', 'AppData.lua')
    watch = (tsm_appdata if os.path.isfile(tsm_appdata)
             else os.path.abspath(__file__))
    return {'appdata': watch,
            'root': root,
            'out': [os.path.join(addons_dir, 'GoblinMind_Data',
                                 'Data.lua')]}


def resolve_feed(arg, outs):
    """arg is a feed name (feeds.json), an AppData.lua path, or a
    GoblinMind.lua SV path. Returns (appdata, outs, feed_name, root,
    realm). Config outs are used when the CLI gives none; `realm`
    scopes TSM chunk selection to one "Realm-Faction" scope."""
    if arg == 'self':
        f = self_feed()
        if not f:
            raise SystemExit(
                "'self' feed: script is not inside a WoW install "
                "(expected .../Interface/AddOns/<addon>/brain/)")
        return (f['appdata'], list(outs) or f['out'], 'self',
                f['root'], f.get('realm'))
    f = load_feeds().get(arg)
    if f:
        return (f['appdata'], list(outs) or f.get('out', []), arg,
                f.get('root'), f.get('realm'))
    return arg, outs, None, None, None


def sv_paths(appdata, root=None):
    """All GoblinMind.lua SavedVariables under the feed's
    WTF/Account tree. root defaults to the path derived from the
    AppData location; feeds.json may pin it explicitly."""
    if not root:
        root = os.path.normpath(os.path.join(
            os.path.dirname(appdata), '..', '..', '..'))
    return sorted(glob.glob(os.path.join(
        root, 'WTF', 'Account', '*', 'SavedVariables',
        'GoblinMind.lua')))


def load_filed():
    try:
        with open(FILED_PATH, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_filed(filed):
    tmp = FILED_PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(filed, fh, indent=1)
    os.replace(tmp, FILED_PATH)


def gh_token():
    """Pull the github.com token git already has (credential manager
    / .git-credentials) — no secret stored in the repo."""
    p = subprocess.run(
        ['git', 'credential', 'fill'],
        input='protocol=https\nhost=github.com\n\n',
        capture_output=True, text=True,
        timeout=15)
    for line in p.stdout.splitlines():
        if line.startswith('password='):
            return line.split('=', 1)[1].strip()
    return None


def file_issue(token, title, body):
    req = urllib.request.Request(
        f'https://api.github.com/repos/{REPO}/issues',
        data=json.dumps({'title': title, 'body': body}).encode(),
        method='POST',
        headers={
            'Authorization': f'Bearer {token}',
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'goblinmind-brain',
            'Content-Type': 'application/json',
        })
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())['html_url']


def process_bugs(appdata, root=None):
    """Scan the SV file(s) for staged reports, file anything new.
    Returns [(id, url)] newly filed this pass."""
    newly = []
    filed = load_filed()
    reports = []
    for sv in sv_paths(appdata, root):
        try:
            with open(sv, encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        for rid, hexbody in REPORT_RE.findall(text):
            if rid not in filed:
                reports.append((rid, hexbody))
    if not reports:
        return newly
    token = gh_token()
    if not token:
        LOG.warning('bug reports staged but no github.com credential '
                    'in git — reports held for next pass')
        return newly
    for rid, hexbody in reports:
        try:
            payload = bytes.fromhex(hexbody).decode('utf-8')
            title, _, body = payload.partition('\n')
            title = ('[in-game] ' + (title or 'bug report'))[:120]
            url = file_issue(token, title, body or title)
            filed[rid] = url
            newly.append((rid, url))
            LOG.info('filed %s -> %s', rid, url)
        except Exception:
            LOG.exception('filing %s failed — will retry', rid)
    if newly:
        save_filed(filed)
    return newly


def cmd_bugs(appdata, outs, realm=None):
    """One-shot: file staged reports, then emit so filedBugs reaches
    the addon on its next load."""
    n = process_bugs(appdata)
    LOG.info('bug pass: %d filed', len(n))
    for out in outs:
        cmd_emit(appdata, out, realm)


HEARTBEAT = 300  # verbose "still alive" line every 5 min
EMIT_PERIOD = 3600  # book-mode cadence floor — a quiet install (no
                    # TSM pushes, no SV flush) still re-merges hourly
                    # so the DB's generated stamp stays honest


def cmd_watch(appdata, outs, interval=5, settle=20, feed='tsm',
              root=None, feedname=None, realm=None):
    """Poll AppData mtime; emit after the file goes quiet. The TSM
    desktop app rewrites chunks non-atomically, so a fresh mtime is
    only trusted once it stops moving for `settle` seconds. Book mode
    emits on BOTH settled AppData (TSM backend refresh merges in) and
    SavedVariables flushes (our own scans/ledger)."""
    last_mtime = 0
    quiet_since = None
    last_beat = time.time()
    last_emit = time.time()  # the startup settle always emits once;
                             # the floor clock starts there
    sv_mtimes = {}
    LOG.info('watching %s', appdata)
    LOG.info('outputs: %s', ' ; '.join(outs))
    LOG.info('poll=%ss settle=%ss', interval, settle)

    def emit_book(why):
        nonlocal last_emit
        try:
            t0 = time.time()
            cmd_book(appdata, outs, root, feedname, realm)
            LOG.debug('  book emit (%s) done in %.1fs', why,
                      time.time() - t0)
        except Exception:  # never die on a mid-write file
            LOG.exception('book emit failed')
        last_emit = time.time()

    while True:
        try:
            st = os.stat(appdata)
            mtime, size = st.st_mtime, st.st_size
        except OSError as e:
            mtime, size = 0, -1
            LOG.debug('stat failed: %s', e)
        now = time.time()
        if mtime != last_mtime:
            LOG.info('AppData touched (mtime=%s size=%s) — settling',
                     time.strftime('%H:%M:%S', time.localtime(mtime))
                     if mtime else '-', size)
            last_mtime = mtime
            quiet_since = now
        elif quiet_since and now - quiet_since >= settle:
            quiet_since = None
            LOG.info('AppData settled — emitting')
            if feed == 'book':
                # a settled AppData means the TSM app pushed fresh
                # realm data — cmd_book folds it into the merge
                emit_book('appdata')
            else:
                for out in outs:
                    t0 = time.time()
                    try:
                        cmd_emit(appdata, out, realm)
                        LOG.debug('  %s done in %.1fs', out,
                                  time.time() - t0)
                    except Exception:  # never die on a mid-write file
                        LOG.exception('emit %s failed', out)
        # staged bug reports ride the SavedVariables file — it only
        # flushes on /reload or logout, so check its mtime each poll
        for sv in sv_paths(appdata, root):
            try:
                m = os.stat(sv).st_mtime
            except OSError:
                continue
            if sv_mtimes.get(sv) != m:
                sv_mtimes[sv] = m
                try:
                    newly = process_bugs(appdata, root)
                    if feed == 'book':
                        # a flush means the session wrote fresh book +
                        # ledger data — re-emit merged across every
                        # character's SV
                        emit_book('sv flush')
                    elif newly:
                        LOG.info('re-emitting with filedBugs')
                        for out in outs:
                            try:
                                cmd_emit(appdata, out, realm)
                            except Exception:
                                LOG.exception('emit %s failed', out)
                except Exception:
                    LOG.exception('bug pass failed')
        # cadence floor: book mode re-merges at least once an hour —
        # keeps `generated` moving through quiet stretches so the
        # addon's staleness flag means what it says
        if feed == 'book' and now - last_emit >= EMIT_PERIOD:
            LOG.info('periodic emit — last emit %dm ago',
                     int((now - last_emit) / 60))
            emit_book('periodic')
        if now - last_beat >= HEARTBEAT:
            last_beat = now
            LOG.debug('heartbeat — watching, last mtime=%s',
                      time.strftime('%H:%M:%S', time.localtime(last_mtime))
                      if last_mtime else 'none yet')
        time.sleep(interval)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['dump', 'emit', 'watch', 'bugs',
                                    'book', 'feeds'])
    ap.add_argument('appdata', nargs='?',
                    help='feed name from feeds.json, an AppData.lua '
                         'path, or a GoblinMind.lua SV path')
    ap.add_argument('out', nargs='*')
    ap.add_argument('--interval', type=float, default=5)
    ap.add_argument('--settle', type=float, default=20)
    ap.add_argument('--feed', choices=['tsm', 'book'], default='tsm',
                    help='watch: data source — tsm AppData or the '
                         'in-house book feed')
    ap.add_argument('--verbose', '-v', action='store_true',
                    help='debug-level logging (heartbeats, skip reasons)')
    ap.add_argument('--log', metavar='PATH',
                    default=os.path.join(os.path.dirname(
                        os.path.abspath(__file__)), 'brain.log'),
                    help='log file (default: brain.log next to the script; '
                         'empty string disables)')
    a = ap.parse_args()
    setup_logging(a.verbose, a.log or None)
    if a.cmd == 'feeds':
        feeds = load_feeds()
        if not feeds:
            LOG.info('no feeds configured — create %s', FEEDS_PATH)
        for name, f in feeds.items():
            LOG.info('%s: %s', name, f.get('name', ''))
            LOG.info('  appdata: %s', f.get('appdata'))
            LOG.info('  root:    %s', f.get('root'))
            for out in f.get('out', []):
                LOG.info('  out:     %s', out)
        return
    if not a.appdata:
        ap.error('%s needs a feed name or path' % a.cmd)
    appdata, outs, feedname, root, realm = \
        resolve_feed(a.appdata, a.out)
    if a.cmd == 'dump':
        cmd_dump(appdata)
    elif a.cmd == 'watch':
        if not outs:
            ap.error('watch needs output paths (CLI or feeds.json)')
        # anything escaping the loop is a real crash — log the full
        # traceback, then come back up instead of dying silently
        while True:
            try:
                cmd_watch(appdata, outs, a.interval, a.settle,
                          feed=a.feed, root=root, feedname=feedname,
                          realm=realm)
            except KeyboardInterrupt:
                LOG.info('stopped by user')
                return
            except Exception:
                LOG.exception('watcher crashed — restarting in 10s')
                time.sleep(10)
    elif a.cmd == 'bugs':
        if not outs:
            ap.error('bugs needs output paths (CLI or feeds.json)')
        cmd_bugs(appdata, outs, realm)
    elif a.cmd == 'book':
        if not outs:
            ap.error('book needs output paths (CLI or feeds.json)')
        cmd_book(appdata, outs, root, feedname, realm)
    else:
        if not outs:
            ap.error('emit needs an output path (CLI or feeds.json)')
        cmd_emit(appdata, outs[0], realm)


if __name__ == '__main__':
    main()
