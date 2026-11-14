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
import logging
import logging.handlers
import os
import re
import sys
import tempfile
import time

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
    try:
        return int(tok), i
    except ValueError:
        pass
    try:
        return float(tok), i
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


def b36(v):
    """Base-36 decode for the letter-bearing encodings; passthrough ints."""
    if isinstance(v, str) and re.fullmatch(r'[0-9A-Z]+', v):
        return int(v, 36)
    return v


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
            dec = {k: b36(v) for k, v in row.items()}
            print(f'  {dec}')


def _first(rows, *keys):
    for r in rows:
        for k in keys:
            if k in r:
                return r[k]


def cmd_emit(path, out_path):
    chunks = read_chunks(path)
    items = {}          # itemID -> record
    data_age = 0
    realm_age = 0       # newest realm-scope downloadTime
    region_age = 0      # newest region-scope downloadTime
    n_adb = n_rows = n_priced = 0

    # realm-scope rows: current stats (DATA), historical, scan stats
    # region-scope rows: REGION_STAT / REGION_SALE give market avg + velocity
    per_item = {}
    for (tag, scope), c in chunks.items():
        if not tag.startswith('AUCTIONDB'):
            continue
        n_adb += 1
        n_rows += sum(1 for k in c.get('data', {}) if isinstance(k, int))
        data_age = max(data_age, c['downloadTime'])
        is_region = scope.endswith('-US') or '_REGION_' in tag
        if is_region:
            region_age = max(region_age, c['downloadTime'])
        else:
            realm_age = max(realm_age, c['downloadTime'])
        for row in rows_of(c):
            isr = row.get('itemString')
            if isr is None:
                continue
            item_id = int(isr) if isinstance(isr, int) else \
                int(isr.split(':')[1]) if isinstance(isr, str) and isr.startswith('i:') else None
            if item_id is None:
                continue
            rec = per_item.setdefault(item_id, {})
            if is_region:
                for k, v in row.items():
                    if k == 'itemString':
                        continue
                    rec.setdefault('region', {})[k] = b36(v)
            else:
                for k, v in row.items():
                    if k == 'itemString':
                        continue
                    rec[k] = b36(v)

    for item_id, rec in per_item.items():
        p = rec.get('marketValue') or rec.get('marketValueRecent') \
            or rec.get('minBuyout') or rec.get('historical')
        region = rec.get('region', {})
        if not p:
            p = region.get('regionMarketValue') or region.get('regionHistorical')
        if not p:
            LOG.debug('item %s: no price fields — skipped', item_id)
            continue
        n_priced += 1
        # regionSoldPerDay is a raw count — TSM displays it unscaled in
        # its tooltip (regionSalePercent is the only permille field).
        raw_vel = region.get('regionSoldPerDay') or region.get('regionSale')
        vel = raw_vel
        out = {
            'p': p,
            'p10': int(p * 0.85),      # placeholder band until the model lands
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
                'ev': int((p * 0.95 - mb) * min(rec.get('numAuctions') or 1,
                                                max(vel or 1, 1))),
            }
        items[item_id] = out

    db = {
        'version': 2,
        'generated': int(time.time()),
        'dataAge': data_age,      # newest downloadTime across all chunks
        'realmAge': realm_age,    # realm-scope chunks only (≈ TSM "Realm Data")
        'regionAge': region_age,  # region-scope chunks only (≈ TSM "Region Data")
        'items': items,
    }

    def enc(v):
        if isinstance(v, dict):
            return '{' + ','.join(
                (f'[{k}]={enc(x)}' if isinstance(k, int) else f'{k}={enc(x)}')
                for k, x in v.items() if x is not None) + '}'
        if isinstance(v, str):
            return '"' + v + '"'
        if v is True:
            return 'true'
        if v is False:
            return 'false'
        return repr(v)

    text = '-- generated by goblin_brain.py — do not edit\nGoblinMindDB = ' + enc(db) + '\n'
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out_path), suffix='.tmp')
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)
    os.replace(tmp, out_path)
    LOG.info('emitted %d items -> %s (%d KB)',
             len(items), out_path, len(text) // 1024)
    LOG.debug('  %d chunks total, %d AUCTIONDB, %d rows, %d priced '
              '(%d skipped no-price)',
              len(chunks), n_adb, n_rows, n_priced,
              len(per_item) - n_priced)
    return len(items)


HEARTBEAT = 300  # verbose "still alive" line every 5 min


def cmd_watch(appdata, outs, interval=5, settle=20):
    """Poll AppData mtime; emit after the file goes quiet. The TSM
    desktop app rewrites chunks non-atomically, so a fresh mtime is
    only trusted once it stops moving for `settle` seconds."""
    last_mtime = 0
    quiet_since = None
    last_beat = time.time()
    LOG.info('watching %s', appdata)
    LOG.info('outputs: %s', ' ; '.join(outs))
    LOG.info('poll=%ss settle=%ss', interval, settle)
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
            for out in outs:
                t0 = time.time()
                try:
                    cmd_emit(appdata, out)
                    LOG.debug('  %s done in %.1fs', out, time.time() - t0)
                except Exception:  # never die on a mid-write file
                    LOG.exception('emit %s failed', out)
        elif now - last_beat >= HEARTBEAT:
            last_beat = now
            LOG.debug('heartbeat — watching, last mtime=%s',
                      time.strftime('%H:%M:%S', time.localtime(last_mtime))
                      if last_mtime else 'none yet')
        time.sleep(interval)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['dump', 'emit', 'watch'])
    ap.add_argument('appdata')
    ap.add_argument('out', nargs='*')
    ap.add_argument('--interval', type=float, default=5)
    ap.add_argument('--settle', type=float, default=20)
    ap.add_argument('--verbose', '-v', action='store_true',
                    help='debug-level logging (heartbeats, skip reasons)')
    ap.add_argument('--log', metavar='PATH',
                    default=os.path.join(os.path.dirname(
                        os.path.abspath(__file__)), 'brain.log'),
                    help='log file (default: brain.log next to the script; '
                         'empty string disables)')
    a = ap.parse_args()
    setup_logging(a.verbose, a.log or None)
    if a.cmd == 'dump':
        cmd_dump(a.appdata)
    elif a.cmd == 'watch':
        if not a.out:
            ap.error('watch needs at least one output path')
        # anything escaping the loop is a real crash — log the full
        # traceback, then come back up instead of dying silently
        while True:
            try:
                cmd_watch(a.appdata, a.out, a.interval, a.settle)
            except KeyboardInterrupt:
                LOG.info('stopped by user')
                return
            except Exception:
                LOG.exception('watcher crashed — restarting in 10s')
                time.sleep(10)
    else:
        if not a.out:
            ap.error('emit needs an output path')
        cmd_emit(a.appdata, a.out[0])


if __name__ == '__main__':
    main()
