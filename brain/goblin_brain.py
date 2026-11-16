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
import base64
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
import urllib.parse
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


VENDOR_BUY_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'vendor_buy.json')


def load_vendor_buy(path):
    """vendor-sell table — a frozen artifact (`vendor_buy.json`, tracked
    in the repo and regenerated on each content release — see the
    api-feed proposal §6) is the production source. The live scrape of
    TSM's LibTSMData remains only as a dev-side fallback while TSM is
    still installed; a TSM-less install always has the artifact."""
    try:
        with open(VENDOR_BUY_PATH, encoding='utf-8') as fh:
            return {int(k): int(v)
                    for k, v in json.load(fh).items()}
    except (OSError, ValueError):
        pass
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


# ---------- Blizzard Game Data API feed (TSM-free pipeline) ----------
# Pulls the same raw snapshot TSM's app consumes — the connected-realm
# auction dump — and normalizes it into the in-game book's shape so
# cmd_book's merge/history machinery computes mkt/hist/recent from it.
# Credentials live in feeds.json under "api" (machine-local, never
# shipped); state lands next to the script like the other brain files.

API_STATE_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'api_state.json')
API_BOOK_PATH = os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'api_book.json')
API_HOST = '{region}.api.blizzard.com'
API_TOKEN_URL = 'https://oauth.battle.net/token'


def _api_cfg():
    """feeds.json 'api' block — {} when absent. Shape:
    {namespace, client_id, client_secret, realm(s), poll_minutes,
     region}. `realm`/`realms` accept our scope names
    ('Normal-Alliance') or realm names; each maps to a connected-realm
    ID once resolved."""
    return (load_feeds() or {}).get('api') or {}


def _load_api_state():
    try:
        with open(API_STATE_PATH, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save_api_state(st):
    tmp = API_STATE_PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(st, fh)
    os.replace(tmp, API_STATE_PATH)


def _api_token(cfg):
    """client-credentials bearer, cached in api_state.json until ~1min
    before expiry. ~1 token request/day at normal poll cadence."""
    st = _load_api_state()
    tok = st.get('token') or {}
    if tok.get('access_token') and tok.get('exp', 0) > time.time() + 60:
        return tok['access_token']
    cred = base64.b64encode(('%s:%s' % (
        cfg['client_id'], cfg['client_secret'])).encode()).decode()
    req = urllib.request.Request(
        API_TOKEN_URL + '?grant_type=client_credentials',
        data=b'', method='POST')
    req.add_header('Authorization', 'Basic ' + cred)
    resp = json.load(urllib.request.urlopen(req, timeout=30))
    st['token'] = {'access_token': resp['access_token'],
                   'exp': time.time() + resp.get('expires_in', 86400)}
    _save_api_state(st)
    return resp['access_token']


def _api_get(cfg, path, params=None):
    """GET {region}.api.blizzard.com<path>?<params> with the bearer.
    One 401 retry (a cached token may be revoked mid-day)."""
    url = 'https://%s%s?%s' % (
        API_HOST.format(region=cfg.get('region', 'us')), path,
        urllib.parse.urlencode(params or {}))
    for attempt in (1, 2):
        req = urllib.request.Request(url)
        req.add_header('Authorization', 'Bearer ' + _api_token(cfg))
        try:
            return json.load(urllib.request.urlopen(req, timeout=120))
        except urllib.error.HTTPError as e:
            if e.code == 401 and attempt == 1:
                st = _load_api_state()
                st.pop('token', None)
                _save_api_state(st)   # force re-auth on retry
                continue
            raise


def _api_realm_names(cfg):
    """scope list from cfg['realms'] (dict keys = our scope names) or
    cfg['realm'] — strings like 'Normal-Alliance' (scope) or 'Normal'
    (bare realm name)."""
    realms = cfg.get('realms')
    if isinstance(realms, dict):
        return [k for k in realms if k and not str(k).startswith('_')]
    if isinstance(realms, list):
        return [r for r in realms if r]
    if cfg.get('realm'):
        return [cfg['realm']]
    return []


def api_resolve_realms(cfg):
    """scope name -> connected-realm ID. One realm/index request lists
    every realm with its connected_realm href inline; the ID is the
    trailing path segment. Cached in api_state.json — realm structure
    changes only on Blizzard-side merges."""
    names = _api_realm_names(cfg)
    if not names:
        return {}
    st = _load_api_state()
    known = st.get('realm_ids') or {}
    # a realms dict may pin IDs by hand — honor nonzero values and
    # resolve only the unpinned ones
    pinned = {k: int(v) for k, v in (cfg.get('realms') or {}).items()
              if isinstance(v, int) and v > 0}
    known.update({k.lower(): v for k, v in pinned.items()})
    want = {n.lower(): n for n in names}
    if all(n.lower() in known for n in names):
        return {n: known[n.lower()] for n in names}
    idx = _api_get(cfg, '/data/wow/realm/index',
                   {'namespace': cfg.get('namespace', 'dynamic-us'),
                    'locale': 'en_US'})
    for r in idx.get('realms', []):
        rname = str(r.get('name') or '').lower()
        rslug = str(r.get('slug') or '').lower()
        href = str((r.get('connected_realm') or {}).get('href') or '')
        m = re.search(r'/connected-realm/(\d+)', href)
        if not m:
            continue
        crid = int(m.group(1))
        for w in want:
            wl = w.lower()
            # our scope is 'Realm-Faction'; match on the realm part or
            # the slug — 'Normal-Alliance' hits realm 'Normal'
            realm_part = wl.split('-', 1)[0].replace(' ', '')
            if rname == wl or rname == realm_part or rslug == realm_part:
                known[wl] = crid
    st['realm_ids'] = known
    _save_api_state(st)
    missing = [n for n in names if n.lower() not in known]
    if missing:
        LOG.warning('api: realms not found in %s index: %s',
                    cfg.get('namespace'), ', '.join(missing))
    return {n: known[n.lower()] for n in names if n.lower() in known}


def api_poll(cfg=None):
    """Pull each configured connected-realm auction dump and store the
    newest snapshot in api_book.json. Emits nothing itself — cmd_book
    folds the stored book into the next emit. Returns scopes pulled."""
    cfg = cfg or _api_cfg()
    if not cfg.get('client_id'):
        return {}
    realm_map = api_resolve_realms(cfg)
    if not realm_map:
        return {}
    now = int(time.time())
    books = {}
    for scope, crid in realm_map.items():
        data = _api_get(cfg, '/data/wow/connected-realm/%d/auctions' % crid,
                        {'namespace': cfg.get('namespace', 'dynamic-us'),
                         'locale': 'en_US'})
        items, lots = {}, {}
        for a in data.get('auctions', []):
            iid = (a.get('item') or {}).get('id')
            qty = int(a.get('quantity') or 1)
            unit = a.get('unit_price')
            if unit is None:
                bo = a.get('buyout')
                unit = bo / qty if bo and qty else None
            if iid is None or not unit:
                continue
            u = int(round(unit))
            e = items.setdefault(iid, {'mb': None, 'mbx': 0,
                                       'sup': 0, 'n': 0})
            e['mb'] = u if e['mb'] is None else min(e['mb'], u)
            e['mbx'] = max(e['mbx'], u)
            e['sup'] = (e['sup'] or 0) + qty
            e['n'] = (e['n'] or 0) + 1
            # lot fingerprint for the §4 delta engine (same shape as
            # Inventory.lua's itemID:qty:buyout)
            fp = '%s:%s:%s' % (iid, qty, u)
            lots[fp] = lots.get(fp, 0) + 1
        books[scope] = {'t': now, 'items': items, 'lots': lots,
                        'remote': True}
        LOG.info('api poll %s: %d lots, %d items', scope,
                 sum(lots.values()), len(items))
    tmp = API_BOOK_PATH + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump({'t': now, 'books': books}, fh)
    os.replace(tmp, API_BOOK_PATH)
    return books


def api_books():
    """Stored remote snapshot as book-shaped entries for cmd_book's
    books_by_scope merge — {scope: {t, items, lots, remote}}."""
    try:
        with open(API_BOOK_PATH, encoding='utf-8') as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {s: b for s, b in (data.get('books') or {}).items()
            if b and b.get('items')}


# ---------- GoblinMind backend feed (crowdsourced, replaces TSM) ----------
# Forever isn't in Blizzard's public API (verified — see the api-feed
# proposal §2), so the always-on feed is our own service: installs
# upload their newest book per scope, the server merges newest-wins,
# clients pull the merged book back into api_book.json. All statistics
# still compute client-side — the merged book feeds book_history like
# any other book.

def _backend_cfg():
    """feeds.json 'backend' block — {url, scopes[], poll_minutes,
    upload, name}. The bearer auto-registers into api_state.json on
    first use."""
    return (load_feeds() or {}).get('backend') or {}


def _backend_token(cfg):
    st = _load_api_state()
    tok = st.get('backend_token')
    if tok:
        return tok
    body = {'name': cfg.get('name') or 'goblinmind'}
    if cfg.get('key'):
        body['key'] = cfg['key']  # shared install secret (server-gated)
    req = urllib.request.Request(
        cfg['url'].rstrip('/') + '/v1/register',
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}, method='POST')
    resp = json.load(urllib.request.urlopen(req, timeout=30))
    st['backend_token'] = resp['token']
    _save_api_state(st)
    return resp['token']


def _backend_req(cfg, path, body=None):
    headers = {'Authorization': 'Bearer ' + _backend_token(cfg)}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(cfg['url'].rstrip('/') + path,
                                 data=data, headers=headers,
                                 method='POST' if data else 'GET')
    return json.load(urllib.request.urlopen(req, timeout=120))


def backend_pull(cfg=None):
    """GET /v1/book per configured scope → remote-flagged entries in
    the shared remote-book store (api_book.json)."""
    cfg = cfg or _backend_cfg()
    if not cfg.get('url'):
        return {}
    scopes = cfg.get('scopes') or []
    if isinstance(scopes, str):
        scopes = [scopes]
    books = {}
    for scope in scopes:
        try:
            d = _backend_req(cfg, '/v1/book?' + urllib.parse.urlencode(
                {'scope': scope}))
        except Exception:
            _backend_health('pull', False)
            raise
        if d.get('items'):
            books[scope] = {'t': int(d.get('t') or time.time()),
                            'items': d['items'],
                            'lots': d.get('lots') or {},
                            'remote': True}
            LOG.info('backend pull %s: %d items', scope,
                     len(d['items']))
    if scopes:
        _backend_health('pull', True, len(books))
    # how many installs share this backend — /goblin status shows it
    try:
        h = _backend_req(cfg, '/v1/health')
        st = _load_api_state()
        st.setdefault('backend', {})['peers'] = len(
            h.get('installs') or [])
        _save_api_state(st)
    except Exception:
        pass  # health detail is optional — never fail the pull on it
    if books:
        try:
            with open(API_BOOK_PATH, encoding='utf-8') as fh:
                cur = json.load(fh)
        except (OSError, ValueError):
            cur = {}
        cur.setdefault('books', {}).update(books)
        tmp = API_BOOK_PATH + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as fh:
            json.dump(cur, fh)
        os.replace(tmp, API_BOOK_PATH)
        delta_record(books)
    return books


def _backend_health(kind, ok, n=0):
    """last-attempt status per direction, surfaced in the emitted DB
    so /goblin status can report backend health."""
    st = _load_api_state()
    st.setdefault('backend', {})[kind] = {
        't': int(time.time()), 'n': n, 'ok': ok}
    _save_api_state(st)


def backend_upload_books(books_by_scope, cfg=None):
    """POST each scope's newest LOCAL book (remote-flagged entries are
    pulled, not ours). Runs inside cmd_book so uploads piggyback every
    emit but only fire when a scope's book is genuinely newer — or
    when the scope hasn't uploaded in upload_heartbeat_minutes
    (default 60), a same-t re-push that keeps the install live on the
    backend while scans/mesh are idle. The re-push sends the book's
    real t — bumping it would fake freshness and game the server's
    7-day staleness cutoff."""
    cfg = cfg or _backend_cfg()
    if not cfg.get('url') or cfg.get('upload') is False:
        return
    st = _load_api_state()
    last_up = st.get('backend_up') or {}
    last_at = st.get('backend_up_at') or {}
    heartbeat = float(cfg.get('upload_heartbeat_minutes', 60)) * 60
    now = time.time()
    for scope, books in books_by_scope.items():
        local = [b for b in books
                 if not b.get('remote') and b.get('t')]
        if not local:
            continue
        newest = max(local, key=lambda b: b['t'])
        fresh = newest['t'] > last_up.get(scope, 0)
        if not fresh and now - last_at.get(scope, 0) < heartbeat:
            continue
        try:
            r = _backend_req(cfg, '/v1/upload', {
                'scope': scope, 't': newest['t'],
                'items': newest['items'],
                'lots': newest.get('lots') or {}})
            last_up[scope] = newest['t']
            last_at[scope] = now
            _backend_health('up', True, r.get('items', 0))
            LOG.info('backend upload %s: %d items%s', scope,
                     r.get('items', 0),
                     '' if fresh else ' (hourly re-push)')
        except Exception:
            _backend_health('up', False)
            LOG.exception('backend upload failed: %s', scope)
    # _backend_health wrote 'up' to state inside the loop — reload so
    # the stale st loaded above doesn't clobber it on save
    st = _load_api_state()
    st['backend_up'] = last_up
    st['backend_up_at'] = last_at
    _save_api_state(st)


# ---------- sale delta engine (proposal §4) ----------
# Any book carrying a `lots` fingerprint multiset — local scans or
# pulled remote books — diffs against the previous snapshot for its
# scope. Disappeared lots are candidate sales. Honest limit: delisting
# and expiry look identical to selling at this resolution; accuracy
# rises with poll cadence and shrinks when relisting is common.

# raw replicate tl bucket (field 4 of the fingerprint) -> lower bound
# on seconds remaining. A lot gone while elapsed < its lower bound
# provably still had time left = confident sale; anything else is
# inconclusive (expiry/cancel/relist all fit).
TL_LOWER = {0: 0, 1: 1800, 2: 7200, 3: 43200, 4: 172800}


def _fp_pref(fp):
    """iid:qty:unit identity of a fingerprint — the tl bucket rides as
    an optional 4th field and must NOT be part of the diff identity
    (a surviving lot drops buckets between scans)."""
    return fp.rsplit(':', 1)[0] if fp.count(':') >= 3 else fp


def delta_record(books):
    """books = {scope: book}. Diffs each book's `lots` against the last
    snapshot for that scope and appends sale events to api_state.json.
    Events: [t, units, unit_price, lots_gone, prev_lots, cls] where
    cls: 's' confident sale, 'i' inconclusive (expiry/cancel fit too),
    'u' no tl data (legacy 3-field fps — counted like 's')."""
    st = _load_api_state()
    prev = st.get('lots') or {}
    prev_t = st.get('lotsT') or {}
    sales = st.get('sales') or {}
    now = int(time.time())
    for scope, b in books.items():
        new_lots = b.get('lots')
        if not new_lots:
            continue
        old = prev.get(scope) or {}
        book_t = int(b.get('t') or now)
        elapsed = max(0, book_t - int(prev_t.get(scope) or 0))
        new_pref = {}
        for fp, n in new_lots.items():
            p = _fp_pref(fp)
            new_pref[p] = new_pref.get(p, 0) + n
        old_pref, old_tlbs = {}, {}
        for fp, on in old.items():
            p = _fp_pref(fp)
            old_pref[p] = old_pref.get(p, 0) + on
            old_tlbs.setdefault(p, []).append(
                fp.rsplit(':', 1)[1] if fp.count(':') >= 3 else 'x')
        scope_sales = sales.setdefault(scope, {})
        for p, on in old_pref.items():
            gone = on - new_pref.get(p, 0)
            if gone <= 0:
                continue
            try:
                iid_s, qty_s, unit_s = p.split(':', 2)
                iid, qty, unit = int(iid_s), int(qty_s), int(unit_s)
            except ValueError:
                continue
            tlbs = [int(t) for t in old_tlbs.get(p) or []
                    if t != 'x' and t.isdigit() and int(t) in TL_LOWER]
            if not tlbs:
                cls = 'u'  # no tl data — pre-refinement semantics
            elif elapsed < min(TL_LOWER[t] for t in tlbs):
                cls = 's'  # every variant had provable time left
            else:
                cls = 'i'  # could equally be expiry/cancel/relist
            scope_sales.setdefault(str(iid), []).append(
                [now, qty * gone, unit, gone, on, cls])
        for iid_s, ev in scope_sales.items():
            scope_sales[iid_s] = [
                e for e in ev if now - e[0] < HIST_KEEP]
        prev[scope] = new_lots
        prev_t[scope] = book_t
    st['lots'] = prev
    st['lotsT'] = prev_t
    st['sales'] = sales
    _save_api_state(st)


def delta_stats(scope):
    """7d sale-derived stats per item: vel (units/day, market-wide),
    rsale (median disappeared unit price), rsalep (permille — lots
    disappeared / lots previously listed)."""
    st = _load_api_state()
    events = (st.get('sales') or {}).get(scope) or {}
    now = time.time()
    out = {}
    for iid_s, ev in events.items():
        # 'i' (inconclusive) events stay out of sale stats — they could
        # be expiries. Legacy 5-field events and 'u' count as before.
        win = [e for e in ev if now - e[0] < VEL_DAYS * 86400
               and (len(e) < 6 or e[5] != 'i')]
        if not win:
            continue
        units = sum(e[1] for e in win)
        gone = sum(e[3] for e in win)
        prev = sum(e[4] for e in win)
        prices = sorted(e[2] for e in win)
        # units/day over the observed span (earliest event -> now),
        # not the full 7d window — and floored at 1 day so a hot
        # first diff doesn't extrapolate to absurd rates
        span_d = max(now - min(e[0] for e in win), 86400) / 86400
        try:
            iid = int(iid_s)
        except ValueError:
            continue
        out[iid] = {
            'vel': round(units / span_d, 4),
            'rsale': prices[len(prices) // 2] if prices else None,
            'rsalep': min(1000, int(gone * 1000 / prev)) if prev else None,
        }
    return out


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
    mesh_ev, mesh_mb, mesh_seq = [], [], 0
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
        # mesh staging — wire records the addon parked in the SV;
        # meshAck (emitted below) is the purge handshake. Lua arrays
        # parse as int-keyed dicts — take .values() for the records
        mesh = gms.get('mesh') or {}
        for key in ('ev', 'mb'):
            recs = mesh.get(key)
            if isinstance(recs, dict):
                recs = list(recs.values())
            for e in recs or []:
                (mesh_ev if key == 'ev' else mesh_mb).append(e)
                if isinstance(e, dict):
                    mesh_seq = max(mesh_seq, e.get('q') or 0)
    # the API feed's stored snapshot rides in as another book per scope —
    # newest book wins per item in the merge below, so a fresh dump
    # beats a stale scan and vice versa
    for scope, b in api_books().items():
        books_by_scope.setdefault(scope, []).append(b)
    # mesh beacons -> remote books (skip upload, ride merge+history);
    # mesh events -> sales with prev=0 so they never pad the rsalep
    # denominator. Dedupe by sig — the SV may be re-read before the
    # ack round-trips and purges the stage
    for e in mesh_mb:
        s, iid = e.get('s'), e.get('i')
        if not s or not iid:
            continue
        books_by_scope.setdefault(str(s), []).append({
            't': e.get('t') or time.time(),
            'items': {str(int(iid)): {'mb': e.get('m'),
                                      'mbx': e.get('m'),
                                      'sup': e.get('q') or 0, 'n': 1}},
            'remote': True})
    if mesh_ev:
        st = _load_api_state()
        sales = st.get('sales') or {}
        added = 0
        for e in mesh_ev:
            s, iid = e.get('s'), e.get('i')
            if not s or not iid:
                continue
            sig = (e.get('t') or 0, e.get('u') or 0,
                   e.get('p') or 0, e.get('l') or 1)
            lst = sales.setdefault(str(s), {}).setdefault(
                str(int(iid)), [])
            if any((x[0], x[1], x[2], x[3]) == sig for x in lst):
                continue
            lst.append([int(e.get('t') or time.time()),
                        e.get('u') or 0, e.get('p') or 0,
                        e.get('l') or 1, 0, e.get('c') or 'u'])
            added += 1
        if added:
            st['sales'] = sales
            _save_api_state(st)
            LOG.info('mesh: %d wire events folded into sales', added)
    # push each scope's newest local book upstream — remote-flagged
    # (pulled) entries skip themselves inside
    backend_upload_books(books_by_scope)
    # sale deltas: newest lots-carrying book per scope diffs against
    # the previous snapshot (local scans and pulled books both count)
    delta_record({s: max((b for b in bs if b.get('lots')),
                         key=lambda x: x.get('t') or 0, default=None)
                  for s, bs in books_by_scope.items()
                  if any(b.get('lots') for b in bs)})
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
        dstats = delta_stats(scope)
        for iid, e in latest.items():
            samples = [(r[0], r[1])
                       for r in hist.get(scope, {}).get(str(iid), [])
                       if len(r) > 1 and r[0] and r[1]]
            p = _market_value(samples, now)
            # our own TSM-analog fields — no fallback: recent = the
            # same weighted model over the last 3d, hist = unweighted
            # median over the whole retained window (long-run anchor)
            recent = _market_value(
                [(t, pr) for t, pr in samples
                 if now - t <= 3 * 86400], now)
            hist_p = _median([pr for _, pr in samples if pr])
            ds = dstats.get(iid) or {}
            items[iid] = {
                'mb': e.get('mb'),
                'mbx': None if e.get('mbx') == -1 else e.get('mbx'),
                'sup': e.get('sup'),
                'n': e.get('n'),
                'p': p, 'mkt': p,
                'hist': hist_p,
                'recent': recent,
                'rsale': ds.get('rsale'),
                'rsalep': ds.get('rsalep'),
                # market-wide delta velocity wins; personal ledger
                # rate remains when the delta engine has no window yet
                'vel': ds.get('vel') or vel.get(scope, {}).get(iid),
                # reset signal: listed at <= half the computed market
                # value — someone's dumping below the model
                'reset': 1 if (e.get('mb') and p
                               and e['mb'] <= p * 0.5) else None,
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
            # our self-computed fields (hist/recent/rsale/rsalep/reset)
            # follow the same freshness rule as the shared fields —
            # fresher book wins outright, fresher feed keeps its own
            own = ('hist', 'recent', 'rsale', 'rsalep', 'reset')
            if book_fresh:
                for k in ('mb', 'sup', 'p', 'mkt', 'vel') + own:
                    if e.get(k) is not None and (
                            k not in ('p', 'mkt') or p_sane):
                        m[k] = e[k]
            else:
                # backend newer — book listing fields still fill gaps
                # where the feed has nothing for this item
                for k in ('mb', 'sup', 'p', 'mkt', 'vel') + own:
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

    # region aggregate — pooled across realm scopes, supply-weighted
    # (proposal §5). One polled realm → its own stats honestly stand
    # in for the region; nothing borrowed from TSM.
    region_items = {}
    for scope, rd in realms.items():
        for iid, it in rd['items'].items():
            r = region_items.setdefault(iid, {'w': 0, 'm': 0, 'h': []})
            w = it.get('sup') or 1
            if it.get('mkt'):
                r['m'] += it['mkt'] * w
                r['w'] += w
            if it.get('hist'):
                r['h'].append(it['hist'])
    for scope, rd in realms.items():
        for iid, it in rd['items'].items():
            r = region_items.get(iid)
            if not r:
                continue
            if r['w']:
                it['rmkt'] = int(r['m'] / r['w'])
            if r['h']:
                it['rhist'] = _median(r['h'])

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
        'meshAck': mesh_seq,
        # last-attempt backend health for /goblin status
        'backend': _load_api_state().get('backend') or {},
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
    # self-restart on deploy: a copied-over goblin_brain.py never
    # reloads in a live process — a stale watcher once kept emitting
    # with the pre-fix code for a whole day. Re-exec same argv.
    own_mtime = os.path.getmtime(os.path.abspath(__file__))
    api_cfg_raw = _api_cfg() if feed == 'book' else {}
    api_poll_secs = float(api_cfg_raw.get('poll_minutes', 30)) * 60
    last_api_poll = time.time()  # first poll after one full interval
    backend_cfg_raw = _backend_cfg() if feed == 'book' else {}
    backend_poll_secs = float(
        backend_cfg_raw.get('poll_minutes', 15)) * 60
    last_backend_poll = time.time()
    LOG.info('watching %s', appdata)
    LOG.info('outputs: %s', ' ; '.join(outs))
    LOG.info('poll=%ss settle=%ss', interval, settle)
    if api_cfg_raw:
        LOG.info('api feed: realm=%s poll=%dm',
                 _api_realm_names(api_cfg_raw), api_poll_secs / 60)

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
        # api poll: pull the connected-realm dump on its own cadence,
        # then re-emit so the merge picks the fresh book up
        if feed == 'book' and api_cfg_raw and \
                now - last_api_poll >= api_poll_secs:
            last_api_poll = now
            try:
                api_poll(api_cfg_raw)
                emit_book('api poll')
            except Exception:  # network hiccups must not kill the loop
                LOG.exception('api poll failed')
        # backend pull: our crowdsourced merged book on its own cadence
        if feed == 'book' and backend_cfg_raw.get('url') and \
                now - last_backend_poll >= backend_poll_secs:
            last_backend_poll = now
            try:
                backend_pull(backend_cfg_raw)
                emit_book('backend pull')
            except Exception:
                LOG.exception('backend pull failed')
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
        try:
            if os.path.getmtime(os.path.abspath(__file__)) != own_mtime:
                LOG.info('goblin_brain.py changed on disk — restarting')
                subprocess.Popen([sys.executable] + sys.argv,
                                 cwd=os.getcwd())
                os._exit(0)
        except OSError:
            pass
        time.sleep(interval)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['dump', 'emit', 'watch', 'bugs',
                                    'book', 'feeds', 'api'])
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
    if a.cmd == 'api':
        # api realms — resolve configured scope names to connected-realm
        # IDs (the §2 verification probe); api poll — one-shot dump pull
        api_action = a.appdata or 'realms'
        cfg = _api_cfg()
        if not cfg:
            LOG.info('no "api" block in %s — see feeds.example.json',
                     FEEDS_PATH)
            return
        if api_action == 'realms':
            realm_map = api_resolve_realms(cfg)
            for scope, crid in realm_map.items():
                LOG.info('%s -> connected-realm %d', scope, crid)
            if not realm_map:
                LOG.info('no realms resolved — check namespace/realm '
                         'names in the api block')
        elif api_action == 'realm-index':
            # discovery: dump every realm + its connected-realm ID under
            # the configured namespace — find Forever's real API name
            idx = _api_get(cfg, '/data/wow/realm/index',
                           {'namespace': cfg.get('namespace',
                                                 'dynamic-us'),
                            'locale': 'en_US'})
            realms = idx.get('realms', [])
            LOG.info('%d realms under namespace %s',
                     len(realms), cfg.get('namespace'))
            for r in sorted(realms,
                            key=lambda r: str(r.get('name') or '')):
                href = str((r.get('connected_realm') or {})
                           .get('href') or '')
                m = re.search(r'/connected-realm/(\d+)', href)
                LOG.info('  %-28s slug=%-28s cr=%s',
                         r.get('name'), r.get('slug'),
                         m.group(1) if m else '?')
        elif api_action == 'poll':
            books = api_poll(cfg)
            for scope, b in books.items():
                LOG.info('%s: %d items, %d lots @ %s', scope,
                         len(b['items']), sum(b['lots'].values()),
                         time.strftime('%H:%M:%S',
                                       time.localtime(b['t'])))
            LOG.info('snapshot -> %s', API_BOOK_PATH)
        else:
            ap.error('api takes "realms" or "poll"')
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
