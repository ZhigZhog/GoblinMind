# GoblinMind

An auction-house intelligence addon for **World of Warcraft: Forever**
(client flavor `WOW_PROJECT_CAMELOT`, interface `16001`), currently riding
on TradeSkillMaster's data feed while it grows toward full TSM replacement.

**v0.1 (first alpha)** — phase 1: TSM AppData → generated price DB →
plan window + side tooltip + click-per-step buyout/relist executor.

## What it does

- **Minimap button + plan window** — left-click the coin button (or
  `/goblinmind`) to open a TSM-styled window: item header with icon, a
  price/volume chart, a grouped stats column (value, trend, market,
  signal, account), a step table, and a verdict summary strip.
- **Price estimates in a side tooltip** — a Blizzard-styled tooltip
  anchors beside the native item tooltip with the estimate, p10–p90 band,
  deltas vs TSM market, historical trend, sells/day, supply, and
  reset-opportunity signals.
- **Deterministic solver** — reads the live auction book plus your bag
  and bank contents, then emits a plan: buy the cheap asks, post
  everything you own at the target price. Deposit fees, the AH cut, risk
  budget, and sell velocity are all priced in. No profitable path → the
  summary says *why* (empty book, cheapest ask above the ceiling, or the
  risk budget can't cover the cheapest lot).
- **Click-per-step execution** — EXECUTE performs one action, SKIP drops
  a step (shrinking the post leg and repricing it to the AH's cheapest
  ask), RESCAN re-reads the book. Commodity buys go through the staged
  quote flow with an automatic per-lot buyout fallback. Nothing is
  automated — every protected call is a hardware click.

## Repository layout

```
addons/GoblinMind/        the in-game addon (Lua)
addons/GoblinMind_Data/   generated price database addon (Data.lua is emitted)
brain/goblin_brain.py     AppData parser + emitter (stdlib-only Python)
scripts/                  deploy helpers (sync-addons.bat copies into AddOns)
WoWVault/                 design notes — phase-1 architecture, Forever API
                          surface, TSM theme palette, alpha code notes
AGENTS.md                 project conventions + client quirks
```

## Data pipeline

```
TSM AppHelper → AppData.lua (base-36 chunks)
    → python brain/goblin_brain.py emit <AppData.lua> addons/GoblinMind_Data/Data.lua
    → /reload → GoblinMind reads the generated DB
```

## Usage

- `/goblinmind` or `/goblin` — toggle the plan window
- `/goblin minimap` — show/hide the minimap button
- `/goblin 1206` or `/goblin [item link]` — target an item
- **Drag-and-drop** an item onto the header strip, or **Alt-click** one
  (Alt is currently claimed by TSM — re-test at the replacement milestone)
- **RESCAN** reads the live book · **EXECUTE** runs one step ·
  **SKIP** drops a step (post leg shrinks and reprices to the AH)

### Group import / export

`/goblin groups` → ITEMS page → **IMP** / **EXP** (bottom of the GROUPS
column). Import understands:

- **TradeSkillMaster v4 group exports** — both the compressed
  `TSM_EXPORT` string (decoded via TSM's embedded LibDeflate/LibSerialize
  while TSM is installed) and the legacy comma format
  (`group:Tailoring`Bags,i:4238,…`). Backtick path separators and ````
  comma-escapes are converted to GoblinMind `a/b` paths automatically.
- **Generic item lists** — comma/semicolon-separated `i:id` itemstrings
  or bare itemIDs (`4238,2592,…`), the shape most addon and spreadsheet
  exports produce. `p:` battle-pet strings are skipped.

Export always emits the TSM-legacy format — paste it straight into
TSM's group import and it round-trips. Operations are not exchanged
(the TSM op schema doesn't map onto ours); Base Group items export as
ungrouped.

## Deploy

`scripts\sync-addons.bat` — robocopies `addons\*` into the Forever
client's `Interface\AddOns`. Junctions/symlinks are **not** honored for
Lua loading — always copy.

## Roadmap

- **M1** — snapshot/watch pipeline → real time-series charts + volume
- **M2** — LightGBM quantile baseline model (currently TSM market anchors)
- **M3** — replace the TSM desktop/data pipeline with an in-house feed
- **Later** — full TSM feature parity

## Hard rules

- One protected auction mutation per hardware click — Blizzard ToS
  boundary.
- Never guess retail API signatures; the Forever client's
  `C_AuctionHouse` surface differs (`WoWVault/forever-auction-api.md` is
  the verified map).
