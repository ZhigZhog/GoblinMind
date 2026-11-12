# GoblinMind — Phase 1 Architecture

*Working name: **GoblinMind** (placeholder — rename freely).*
*Status: draft for design review, 2026-11-11. No code written yet.*

Phase 1 goal: ride on top of TradeSkillMaster's data pipeline and prove
two things in-game — (a) an out-of-game model can produce per-item price
estimates that render in tooltips, and (b) a deterministic solver can
turn a live auction scan into a click-per-step buyout/relist plan.
Nothing in-game is automated; every auction action is a real hardware
click.

Phase 2 (not built here): replace the TSM desktop app with our own
Blizzard-API poller writing the same generated-file format — the in-game
addon and the model do not change. Phase 3: TSM feature parity.

---

## 1. Verified environment (this machine)

| Component | Path / value |
|---|---|
| WoW install | `E:\Battle.net\World of Warcraft\_forever_` |
| Addons dir | `E:\Battle.net\World of Warcraft\_forever_\Interface\AddOns` |
| TSM Desktop App | `C:\Program Files (x86)\TradeSkillMaster Application\app` |
| TSM addon version | v4.15, multi-flavor toc `120105, 50504, 20506, 16001, 11509` |
| Client interface | **`16001`** (1.60.x "Forever" client — corrected 2026-11-11; `NON_COMMODITY` AppData tags confirm `C_AuctionHouse` API is present) |
| Data file | `...\AddOns\TradeSkillMaster_AppHelper\AppData.lua` (~485 KB, rewrites on every app sync) |
| Region scope | `Forever-US` |
| Realm scope | `{Realm}-{Faction}` e.g. `Normal-Alliance` |
| Dev workspace | `D:\WoW Mods` (this repo) |

Dev-loop note: deploy the shim addon by copying or by junction
(`mklink /J`) from `D:\WoW Mods\addons\` into the AddOns dir.

---

## 2. System overview

```
TSM Desktop App ──sync──► AppData.lua  (rewritten in place, NON-ATOMIC)
                               │
                               ▼  watchdog + debounce
                    brain/  (Python service, out-of-game)
                      parse → SQLite snapshots → features → model
                               │
                               ▼  atomic write (tmp + rename)
              AddOns\GoblinMind_Data\Data.lua   (generated Lua)
                               │
                               ▼  loaded at boot / /reload
                    GoblinMind addon (in-game, Lua)
                      tooltip lines + AH plan queue (click-per-step)
```

Key facts that constrain the design:

- **WoW addons have no file or network I/O.** Model inference must happen
  out-of-game; data enters the client only as generated `.lua` files,
  parsed at load time. In-game update = `/reload` (or next login).
- **AppData.lua writes are not atomic.** The app can rewrite the file
  while we read it (observed by the open-source exporter, which retries
  on `LuaSyntaxError`). The watcher must debounce: wait for size+mtime
  stability (~3 s), then parse, retry once on failure.
- **Upstream freshness is ~hourly** (Blizzard AH API cadence), so the
  file changes at roughly that rate; `downloadTime` inside each chunk
  is the authoritative stamp.

---

## 3. The AppData.lua format (verified against the live file)

Every line is an independent chunk:

```lua
select(2, ...).LoadData("AUCTIONDB_REGION_HISTORICAL","Forever-US",[[return {downloadTime=1794386854,fields={"itemString","regionHistorical"},data={{40,71},{43,1JI},...}}]])
```

- **Envelope:** `LoadData(tag, scope, payload)` where payload is a
  long-bracket string containing `return {…}` — a pure Lua table
  literal (nested arrays, no functions). Safe to eval in a sandboxed
  Lua runtime, or parse with a mini recursive-descent parser.
- **`fields[]` is the column schema** — never hardcode columns; build
  rows as `dict(zip(fields, row))`.
- **Values are base-36 encoded strings** for numeric columns
  (`"1JI"` → `int("1JI", 36)` = 1998 copper). `itemString` arrives as a
  plain numeric itemID (`40`, not `"i:40"`).
- **Tags** partition the data by statistic and scope. Observed live:
  `AUCTIONDB_REGION_HISTORICAL`, `AUCTIONDB_NON_COMMODITY_HISTORICAL`.
  Expected full set (verify on next sync): `AUCTIONDB_MARKET_VALUE`,
  `AUCTIONDB_MIN_BUYOUT`, `AUCTIONDB_HISTORICAL`, `AUCTIONDB_NUM_AUCTIONS`,
  `AUCTIONDB_REGION_MARKET_VALUE`, `AUCTIONDB_REGION_HISTORICAL`,
  `AUCTIONDB_REGION_SALE`, `AUCTIONDB_REGION_SALE_PERCENT`,
  `AUCTIONDB_REGION_SOLD_PER_DAY`, `AUCTIONDB_REGION_NUM_AUCTIONS`,
  plus `*_COMMODITY_*` / `*_NON_COMMODITY_*` variants. **M0 must dump the
  actual tag set.**

### Parser contract (`brain/appdata.py`)

```
parse_appdata(path) -> Iterator[Chunk]
Chunk = { tag:str, scope:str, download_time:int,
          rows: list[dict[field->value]] }   # base-36 decoded
```

Implementation: regex the `LoadData(...)` envelope per line, `lupa`
(LuaJIT) to eval the `return {...}` payload, base-36 decode per field
type. `lupa` on Windows is a wheel install; fallback `slpp`-style
parser if it's a problem (payload is a data-only subset).

---

## 4. `brain/` — the Python service

```
brain/
  pyproject.toml
  goblin_brain/
    watcher.py    # watchdog observer + stability debounce → enqueue parse job
    appdata.py    # chunk parser (contract above)
    store.py      # SQLite, append-only snapshots
    features.py   # per-item feature rows (lags, supply, demand, calendar)
    model.py      # LightGBM quantile (p10/p50/p90); pluggable backend
    emit.py       # → GoblinMind_Data/Data.lua  (atomic tmp+rename)
    cli.py        # `brain watch` | `brain parse-once` | `brain emit` | `brain dump`
  data/snapshots.db
```

Deps: `watchdog`, `lupa`, `pandas`, `lightgbm`, stdlib `sqlite3`.
(Model backend later: `neuralforecast` for LSTM/TFT/N-HiTS.)

**Store schema (v1, SQLite):**

```sql
snapshots(scope TEXT, tag TEXT, item_id INT, download_time INT,
          field TEXT, value REAL,
          PRIMARY KEY(scope, tag, item_id, download_time, field));
```

Append-only; every sync becomes a snapshot tick per (tag, scope). This
double-writes nothing and survives TSM schema drift (fields ride in
rows, not columns).

**Snapshot cadence:** a full parse is cheap (~0.5 MB). Trigger on
debounced file change; skip unchanged chunks by `(tag, downloadTime)`.

---

## 5. Model spec

### What we predict

| Output | Meaning | v1 source |
|---|---|---|
| `p50` (P\*) | predicted fair price, next ~6–24 h | LightGBM quantile regression |
| `p10`, `p90` | confidence band → drives "reset opportunity" + solver margin | LightGBM quantile |
| `vel` | expected sold/day (demand velocity) | **v1: pass through TSM `regionSoldPerDay`** — don't model what TSM already computes well |
| `supIn` | supply inflow, units/hr — the "farm rate" proxy | derived: Δlisted-qty between consecutive snapshots (needs real qty — see Open Questions) |

### Features (per item, per snapshot)

- Lags of `marketValue`, `minBuyout`, `numAuctions`, `historical` (1, 3, 6, 24 ticks)
- `regionMarketAvg`, `regionSoldPerDay`, `regionSalePercent` (region = cross-realm signal, less manipulable)
- Calendar: hour-of-day, day-of-week (weekend AH swings are huge)
- Item class/subclass id (embedding-ish categorical for cross-item learning)
- Patch/era marker when we start collecting (regime breaks)
- Crafted items: reagent cost rollup (`mat price` feature) — v1 via
  `TSMAPI_FOUR.CustomPrice.GetValue("matprice")` offline export, or
  Blizzard recipe API in phase 2. **Deferred past M4.**

### Model choice (the "RNN" answer, honestly)

- **v1: LightGBM quantile.** Hourly, sparse, short series — boosted
  trees are the baseline to beat and need days (not months) of data.
- **v1.5+:** global sequence model via Nixtla `neuralforecast` —
  **TFT** (multi-horizon + calendar covariates + item embeddings) or
  **DeepAR** (probabilistic, matches the quantile output). LSTM/GRU if
  the user insists on RNN lineage — they work, they're just not the
  best known tool here. Vanilla RNN: no.
- Retraining: rolling window, trigger on demand (`brain train`) —
  patch days reset the economy; the model must be cheap to refit.

---

## 6. `GoblinMind_Data` — the generated data addon

A real addon folder whose entire content is machine-written:

```
Interface\AddOns\GoblinMind_Data\
  GoblinMind_Data.toc      ## Interface: 16001
  Data.lua                 -- generated; DO NOT EDIT
```

`Data.lua` format (compact — target < 1.5 MB for ~40k items):

```lua
GoblinMindDB = {
  version = 1,
  generated = 1794389000,            -- epoch
  scope = "Normal-Alliance",         -- realm key this file serves
  dataAge = 1794386854,              -- newest upstream downloadTime used
  items = {
    [40] = {                         -- itemID key (variants: itemString later)
      p = 1998, p10 = 1500, p90 = 2600,   -- copper
      vel = 42, sup = 310, supIn = 18,
      reset = { below = 1700, maxN = 25, ev = 24000 },
    },
  },
}
```

- Written **atomically** (`Data.lua.tmp` → rename) — the addon only ever
  sees complete files.
- `dataAge` powers the tooltip's "data 23m old — /reload" line.
- Scope selection: config in `brain` maps realm → file; only emit the
  realm(s) the user plays (region stats baked into features already).

---

## 7. `GoblinMind` — the shim addon

**Visual language (decided 2026-11-11): look like TSM.** The plan
window reuses TSM's default theme palette — resolved from
`LibTSMApp/Service/ThemeColorSets.lua` OKLCH ramps to concrete sRGB
hexes (see [[tsm-theme-palette]]) — and TSM's own Montserrat fonts,
referenced by path from the installed TSM addon (no copied assets;
TSM is a hard dependency anyway). Flat dark containers, 1px outlines,
gold accent for the primary action, dim secondary controls.

```
Interface\AddOns\GoblinMind\
  GoblinMind.toc     ## Interface: 16001
                   ## Dependencies: TradeSkillMaster, GoblinMind_Data
  Theme.lua        -- TSM palette, money formatter, panel/font helpers
  Core.lua         -- event frame, slash cmds (/gm, /gm plan)
  Solver.lua       -- reset-plan math (pure functions, testable)
  AH.lua           -- C_AuctionHouse scan + click-driven executors
  PlanQueue.lua    -- TSM-styled click-per-step window
  Tooltip.lua      -- tooltip post-call hook
```

### 7.1 Tooltip lines

Modern hook (10.0.2+, definitely valid on this client):

```lua
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    local link = select(2, TooltipUtil.GetDisplayedItem(tooltip))
    local id = link and C_Item.GetItemIDByItemInfo and select(6, C_Item.GetItemInfoInstant(link))
    -- lookup GoblinMindDB.items[id] → add lines:
    --   GoblinMind: est. 19s98c  (15s – 26s)
    --   vs market: -12%   sells ~42/day   supply 310 (+18/hr)
    --   RESET: buy below 17s  est +2g40s  |  data 23m old (/reload)
end)
```

TSM market value for the delta via `TSMAPI_FOUR.CustomPrice.GetValue("dbmarket", "i:"..id)` — keeps the shim honest about where fallback data comes from.

### 7.2 The reset solver (`Solver.lua`, pure)

Inputs: live scan asks (sorted asc), `p50/p90`, `vel`, player gold `G`.
Constants: 5% AH cut, deposit schedule per item.

```
buy = {}
for ask in asks_asc:
    net = ask * 1.00                       -- cost to acquire
    resale = p50 * 0.95                    -- expected net resale
    if resale - net <= minProfit: break    -- stop when margin dies
    if spent + ask > G * riskBudget: break -- can't afford
    buy += ask; spent += ask
if #buy == 0: return "no plan"
plan = buy[] ++ [post { qty=sum, price=min(p50, p90_guard) }]
ev  = Σ(resale - ask) ;  days_to_clear = sum_qty / vel
```

`days_to_clear` is the honesty check — a reset that takes 9 days to
unload is a bad plan regardless of EV.

### 7.3 Plan queue (the ToS-compliant machine)

At the AH, user picks an item → addon runs a targeted
`C_AuctionHouse.SendBrowseQuery` → solver → **ordered step list**,
each row = one button. Clicking a step executes exactly one protected
call:

| Step kind | Call (each inside a hardware click handler) |
|---|---|
| buy commodity | `C_AuctionHouse.StartCommoditiesPurchase` + `ConfirmPurchase` |
| buy item auction | `C_AuctionHouse.PlaceBid(auctionID, buyoutPrice)` |
| cancel own | `C_AuctionHouse.CancelAuction(auctionID)` |
| post | `C_AuctionHouse.PostCommodity` / `PostItem` |

After each executed step the book is stale → rescan, re-solve, re-render
the queue. The addon **suggests**; the user **executes**. No loops, no
timers driving protected calls, no input broadcasting.

---

## 8. ToS boundary — explicit

Allowed (all of it): out-of-game file watching/parsing/modeling;
generated addon files; in-game scans; math in Lua; UI that queues
suggested actions; **each action triggered by a real click**.

Not allowed (none of it): hardware-event simulation, multi-action
macros per click on protected calls, reading memory/injection, driving
the client from out-of-process input. The design never crosses this —
the Python side physically cannot talk to the running client; it only
writes a file the client reads on reload.

Buying out a market and relisting higher is ordinary gameplay
(Blizzard has never sanctioned "resets"); the constraint is
automation, and there is none here.

---

## 9. Repo layout

```
D:\WoW Mods\
  WoWVault\                      Obsidian vault — ALL notes live here
    phase-1-architecture.md      ← this doc
    tsm-theme-palette.md         ← resolved TSM theme reference
  AGENTS.md
  brain\                         Python service (§4)
  addons\
    GoblinMind\                  hand-written shim addon (§7) — scaffolded
    GoblinMind_Data\             generated addon — emitted by brain (§6)
  scripts\
    link-addons.bat              mklink /J deploy into _forever_\AddOns
```

---

## 10. Open questions (to resolve in M0/M1)

1. **Full tag inventory** — dump every `LoadData` tag in the live
   AppData.lua; confirm which supply fields exist (`numAuctions` vs
   real listed quantity). If quantity is absent, `supIn` degrades to
   auction-count inflow — acceptable for v1, live scan gives true qty.
2. **Base-36 confirm** — decode a few known items and sanity-check
   against in-game tooltips (`{40,"71"}` → 61c? verify against linen-era prices).
3. **itemString variants** — do any rows carry non-numeric itemStrings
   (bonus-id items like `"i:1234:5678"`)? If so the generated file keys
   on itemString, not itemID.
4. **`_forever_` API drift** — 1.60.x client (`## Interface: 16001`);
   `NON_COMMODITY` AppData tags confirm `C_AuctionHouse` exists.
   **Verified 2026-11-11:** `SetBackdrop` absent (texture-based panels
   required); junctions not honored for .lua loads (deploy = copy);
   `TooltipDataProcessor`/`C_Container`/`C_Timer`/`ItemLocation`
   guarded with legacy fallbacks in the shim. Still to verify:
   `TSMAPI_FOUR` presence, `ConfirmPurchase` arity.
5. **Data freshness UX** — tooltip shows data age; whether a
   "new data written" nudge out-of-game (tray toast) is worth it.
6. **Alt+Click is claimed by TSM** — TSM opens its own UI on Alt+Click,
   so GoblinMind's alt-click item capture (bag slots, chat links,
   equipment) may be shadowed or double-fire alongside TSM's handler.
   Accepted for now — **re-test at the TSM replacement milestone**:
   keep alt-click if TSM's claim turns out additive, or remaps to
   Ctrl/Shift+Ctrl if it's exclusive. Watch `ItemInput.lua` hooks.

---

## 11. Milestones

| M | Deliverable | Exit test |
|---|---|---|
| M0 | `brain parse-once` — parse live AppData.lua → decoded CSV dump | fields/tags inventory written back into §3; base-36 verified |
| M1 | `brain watch` + SQLite | two consecutive syncs land as distinct snapshot ticks |
| M2 | emitter + `GoblinMind_Data` + tooltip skeleton | /reload → tooltip shows **dbmarket passthrough** (no model yet) |
| M3 | live scan + solver + plan queue | at the AH: plan renders, each click executes exactly one action |
| M4 | LightGBM P* swap-in | tooltip shows p10/p50/p90 + age; offline eval vs held-out ticks |
| M5 | reset EV/days-to-clear polish, config | usable daily driver on one realm |

M4 is where "the RNN" actually enters — everything before it is
plumbing that the model doesn't care about (and Phase 2 keeps intact
when we swap the data source to Blizzard's API directly).
