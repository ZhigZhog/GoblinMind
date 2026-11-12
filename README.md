# GoblinMind

An auction-house intelligence addon for **World of Warcraft: Forever**
(client flavor `WOW_PROJECT_CAMELOT`, interface `16001`), currently riding on
TradeSkillMaster's data feed while it grows toward full TSM replacement.

**v0.1** — phase 1: TSM AppData → generated price DB → in-game plan UI
with a click-per-step buyout/relist executor.

## What it does

- **Price estimates in a side tooltip** — a Blizzard-styled tooltip anchors
  beside the native item tooltip with the model estimate, p10–p90 band,
  deltas vs TSM market value, historical trend, sells/day, supply, and
  reset-opportunity signals.
- **Plan window** (`/goblinmind`, `/goblin`) — item header with icon, a
  price/volume chart, a verbose grouped stats column, and a step table.
- **Deterministic solver** — reads the live auction book plus your bag and
  bank contents, then emits a plan: buy the cheap asks, post everything you
  own at the target price. Deposit fees, the AH cut, your risk budget, and
  expected sell velocity are all priced in. If no profitable path exists the
  summary says *why* (empty book, cheapest ask above the ceiling, or the
  risk budget can't cover the cheapest lot).
- **Click-per-step execution** — every protected `C_AuctionHouse` call is
  bound to a hardware click: EXECUTE performs one step, RESCAN re-reads the
  book and re-solves. Nothing is automated.

## Repository layout

```
addons/GoblinMind/        the in-game addon (Lua)
addons/GoblinMind_Data/   generated price database addon (Data.lua is emitted)
brain/goblin_brain.py     AppData parser + emitter (stdlib-only Python)
scripts/                  deploy helpers (sync-addons.bat copies into AddOns)
WoWVault/                 design notes — phase-1 architecture, Forever API
                        surface, TSM theme palette
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
- `/goblin [item link]` or `/goblin 1206` — target an item by link or ID
- **Drag-and-drop** an item onto the header strip, or **Alt-click** an item
  (Alt is currently claimed by TSM — re-test at the replacement milestone)
- **RESCAN** reads the live book; **EXECUTE NEXT STEP** performs one action.

## Deploy

`scripts\sync-addons.bat` — robocopies `addons\*` into the Forever client's
`Interface\AddOns`. Junctions/symlinks are **not** honored for Lua loading —
always copy.

## Roadmap

- **M1** — snapshot/watch pipeline → real time-series charts + volume history
- **M2** — LightGBM quantile baseline model (currently TSM market anchors)
- **M3** — replace the TSM desktop/data pipeline with an in-house feed
- **Later** — full TSM feature parity

## Hard rules

- One protected auction mutation per hardware click — Blizzard ToS boundary.
- Never guess retail API signatures; the Forever client's `C_AuctionHouse`
  surface differs (`WoWVault/forever-auction-api.md` is the verified map).
