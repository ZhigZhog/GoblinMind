# GoblinMind — code notes (v0.1 alpha)

Complete functional map of the addon as of the first alpha. Architecture
and rationale live in `phase-1-architecture.md`; this file is the
mechanical reference — what each file does, what data moves between
layers, and the exact client API surface we depend on.

## Layers

```
TSM AppHelper AppData.lua ──► brain/goblin_brain.py ──► GoblinMind_Data/Data.lua
                                                              │
                                                    GoblinMindDB (global table)
                                                              │
bags/bank counts ──┐                                          ▼
live AH book ──────┼──► GoblinMind addon (Lua) ──► plan steps ──► C_AuctionHouse
                   │        Solver / PlanQueue / AH               (1 call/click)
                   └──► Tooltip side-window + minimap button
```

## File map — `addons/GoblinMind/`

Load order from `GoblinMind.toc` (Interface 16001; deps
`TradeSkillMaster, GoblinMind_Data`; SavedVariable `GoblinMindSettings`).

| File | Role |
|---|---|
| `Theme.lua` | TSM palette (`GM.C` hex tokens), Montserrat font paths from TSM's Media dir, `GM.RGB`/`GM.CC`/`GM.Money`/`GM.Signed`/`GM.Panel` (fill + 1px edge textures — **no SetBackdrop** on this client), `GM.MakeFontString`, `GM.After` (C_Timer shim) |
| `Core.lua` | SavedVariables defaults + apply, `ADDON_LOADED`/`PLAYER_LOGIN` boot, slash commands, `GM.Print`, `GM.Scope` (realm-faction key), `GM.DataAge`, `GM.ItemEntry` (GoblinMindDB lookup), `GM.TSMMarket` (TSMAPI_FOUR dbmarket fallback), `GM.BagCount` (bags 0–5), `GM.BankCount` (bank frame open only, bags −1, 6–11) |
| `Solver.lua` | Pure functions, no WoW API — `Plan(asks, p50, p90, gold, vel, opts)` → steps + `Verdict(plan, opts)` |
| `AH.lua` | All `C_AuctionHouse` interaction: scan, bag lookup, deposit cost, executors; every mutation is one call per hardware click |
| `PlanQueue.lua` | The plan window: item header/drop target, price·volume chart, grouped stats column, step table, summary strip, RESCAN/SKIP/EXECUTE |
| `ItemInput.lua` | `GM.TargetItem` entry point + alt-click capture (bags, chat links, equipped slots) |
| `Tooltip.lua` | `GoblinMindSideTip` — GameTooltip-template side window anchored to the native tooltip's top-right |
| `Minimap.lua` | Hand-rolled minimap ring button (drag to reposition, angle persisted) |

## SavedVariables — `GoblinMindSettings` (`GM.db`)

`riskBudget=0.40` (max gold fraction a plan may commit) ·
`minProfitMargin=0.10` · `maxDaysToClear=7` · `dataMaxAge=7200` ·
`minimapAngle=-0.785` · `minimapHide=false`.
`ApplyDefaults` fills missing keys, so new settings are safe to add.

## Generated data — `GoblinMindDB` (GoblinMind_Data/Data.lua)

```
GoblinMindDB = { version, generated, dataAge, items = { [itemID] = rec } }
rec = {
  p      -- point estimate (copper): marketValue > marketValueRecent
         --          > minBuyout > historical > region fallbacks
  p10/p90-- placeholder band: p ±15% until the real model lands
  vel    -- regionSoldPerDay (raw count, NOT permille — regionSalePercent
         --   is the only scaled field; verified against TSM tooltip)
  sup    -- numAuctions currently listed (realm)
  hist   -- realm historical price
  recent -- marketValueRecent (latest scan)
  reset  -- {below, maxN, ev} when minBuyout < 0.85·p — reset opportunity
}
```

`brain/goblin_brain.py` (stdlib-only): `dump` prints the chunk inventory;
`emit <AppData.lua> <out>` parses line-per-chunk `LoadData(tag, scope,
[[return {...}]])` blocks, decodes **base-36** values (bare tokens — a
token matching `^[0-9A-Z]+$` with a letter is base-36, pure digits are
literal), splits realm vs region rows by tag/scope, and emits one compact
Lua table (~520 KB, ~6.7k items). `dataAge` = newest `downloadTime` —
the addon shows "data Nm old" from it.

## Runtime flows

### Targeting (`ItemInput.lua` / `Core.lua`)

All paths funnel to `GM.TargetItem(itemID, link)` → `PlanQueue.SetItem`
→ `Show` → auto-`Rescan` if the AH is open:
- `/goblinmind`, `/goblin` — toggle window; `/goblin 1206`,
  `/goblin [item link]` — target by ID or link; `/gm` is shadowed (dead).
- Drag-and-drop onto the header strip (`OnReceiveDrag` + click-with-cursor).
- Alt-click hooks: `ContainerFrameItemButton_OnModifiedClick`,
  `SetItemRef`, `PaperDollItemSlotButton_OnModifiedClick` — **claimed by
  TSM**, may double-fire; accepted for phase 1 (§10.6).
- Tooltip tracking: `TooltipDataProcessor.AddTooltipPostCall(Item)`,
  filtered to `GameTooltip`/`ItemRefTooltip` only — compare/shopping
  tooltips carry equipped gear and clobbered the tracked item.

### Side tooltip (`Tooltip.lua`)

A second `GameTooltipTemplate` frame anchored `TOPLEFT→tooltip.TOPRIGHT`
(flush top edge — `ANCHOR_RIGHT` centers oddly). Shows est/band/vs TSM/
hist/recent/sells·day/supply/reset/itemID with semantic colors (deltas
green/red, est gold, reset amber). Hidden for items with no data; excluded
from post-call tracking to avoid recursion. Stale-data warning past
`dataMaxAge`. Legacy fallback: `OnTooltipSetItem` hook.

### Scan → solve → plan (`PlanQueue.Rescan`/`Solve`)

1. `GM.AH.ScanItem` builds an **ItemKey** via `MakeItemKey(itemID,0,0,nil)`
   and calls `SendSearchQuery(key, {}, true)` — the only search form this
   client accepts; stackables included.
2. `ITEM_SEARCH_RESULTS_UPDATED` (and `COMMODITY_…_UPDATED` defensively)
   → `CollectItemAsks` reads `GetItemSearchResultInfo` fields
   `{auctionID, buyoutAmount|buyout|minBid|minPrice, quantity|totalQuantity}`
   → sorted ask list `{id, qty, unit, total}`.
3. `Solver.Plan` with `p50`=entry.p (or TSM dbmarket), `p90`, `gold`,
   `vel`, `owned`=BagCount, `commodity`=IsCommodity (maxStack>1).
4. `plan.deposit` = `AH.DepositCost` → `plan.ev -= deposit`;
   `plan.bank` = BankCount for display.

### Solver contract (`Solver.Plan`)

- `resale = floor(p50·0.95)` (5% AH cut); `guard = min(p50, p90)` = post price.
- Walk asks ascending: buy while `(resale−unit)/unit ≥ minMargin` and
  `spend + lot ≤ gold·riskBudget`. Steps `{kind="buy", qty, unit, total, auctionID}`.
- Commodity → steps collapsed to one aggregate buy; the per-lot list is
  kept in `plan.buyLots` for the fallback path.
- `POST` step = bought + owned at `guard`. `ev = resale·posted − spend`.
- Explicit failure reasons: empty book + nothing owned · cheapest ask above
  the profit ceiling · risk budget can't cover the cheapest lot.

### Execution (`PlanQueue.ExecuteNext` / `AH.Execute`)

One protected call per click:

| Step | Call |
|---|---|
| buy (commodity) | `StartCommoditiesPurchase(itemID, qty, expUnit)` → staged quote → next click `ConfirmCommoditiesPurchase(itemID, qty)` |
| buy (item) | `PlaceBid(auctionID, lotTotal)` — lot total avoids copper drift |
| post (commodity) | `PostCommodity(itemLoc, 2, qty, unitPrice)` |
| post (item) | `PostItem(itemLoc, 2, stackQty, nil, buyout)` — qty clamps to the found stack |

- `pendingConfirm` holds the staged quote; a **4s timeout** with no
  `COMMODITY_PRICE_UPDATED` auto-splices `plan.buyLots` into per-lot
  `PlaceBid` steps (`PQ.CommodityFallback`). `COMMODITY_PRICE_UNAVAILABLE`
  does the same. `pendingConfirm.quote` stores the quoted total.
- Post clamps to `GM.BagCount` — bought lots sit in the mailbox until
  fetched; partial posts print `posting X of Y`.
- After a successful step: `stepIndex++` and a delayed `Rescan` re-solves.
- **SKIP** clears `pendingConfirm`, shrinks the post leg by the skipped
  lot, reprices posts to `min(model, cheapest ask)`, re-derives
  spend/EV/daysToClear, advances. Skipping a post step just advances.
- `Solve` clears `pendingConfirm` — a rescan invalidates staged quotes.
- Every event surfaces in chat: quote status, `BIDS_UPDATED`,
  `AUCTION_CANCELED`, `UI_ERROR_MESSAGE`, `CHAT_MSG_SYSTEM` (bid/auction
  lines), post errors/success.

### Window (`PlanQueue.lua`, 700×512)

Uniform 10px padding / 8px gutters. Left column (456): item header
(bordered icon slot, name+book state, type/id/sells·day/supply subline,
drop target), `PRICE·VOLUME` chart (3-anchor dot-plot `hist→recent→est`
+ p10/p90 guides + gold-denominated vol/day and listed bars; drawn as
interpolated dots — no SetRotation, clipped via `SetClipsChildren`),
step table (accent left-edge on active step), summary strip (verdict-
colored left bar), SKIP/RESCAN/EXECUTE buttons. Right column: GOBLINMIND
INFO grouped sections VALUE/TREND/MARKET/SIGNAL/ACCOUNT (gold, risk,
margin, data age) with zebra rows.

### Minimap (`Minimap.lua`)

31px button on the ring (radius 80), `INV_Misc_Coin_02` icon +
`MiniMap-TrackingBorder` chrome. Drag repositions via cursor-angle math;
`LeftButton` toggles the window; `/goblin minimap` toggles visibility.
Angle/hide persist in settings.

## Events (`AH.lua`, all `pcall`-registered)

`AUCTION_HOUSE_SHOW/CLOSED` · `COMMODITY|ITEM_SEARCH_RESULTS_UPDATED` ·
`COMMODITY_PRICE_UPDATED/UNAVAILABLE` · `COMMODITY_PURCHASE_SUCCEEDED/
FAILED` · `AUCTION_HOUSE_POST_ERROR` · `AUCTION_MULTISELL_FAILURE` ·
`AUCTION_HOUSE_AUCTION_CREATED` · `BIDS_UPDATED` · `AUCTION_CANCELED` ·
`UI_ERROR_MESSAGE` · `CHAT_MSG_SYSTEM`

## Known limitations / open items (alpha)

- Buyouts for stackables go through the staged-quote flow first; if the
  client never issues a quote the plan auto-converts to per-lot
  `PlaceBid` — which is verified-shaped but unverified live.
- Bought items land in the **mailbox**; they can't post until fetched
  (post clamps + warns; consider an explicit mail state later).
- `hist`/`recent`/`est` is a 3-point pseudo-trend; real series needs the
  snapshot pipeline (M1).
- `vel` is region-daily-sales — huge for common items (region-wide);
  a realm-local velocity will come from snapshots.
- Non-commodity `DepositCost` for items not in bags is a vendor-value
  estimate (~30% MSV for 24h) — verify against real values.
- Alt+Click is claimed by TSM (§10.6) — re-test at replacement.
- `regionSalePercent` is permille-scaled; `regionSoldPerDay` is raw.
