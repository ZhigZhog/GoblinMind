# `_forever_` client — verified C_AuctionHouse surface

Extracted 2026-11-11 from TradeSkillMaster v4.15 (`LibTSMWoW`), which
runs on this client daily — treat as ground truth over memory of retail
APIs, which differ in naming.

## Queries (read)

| Call | Result event / accessor |
|---|---|
| `SendSearchQuery(itemID_or_itemKey, sorts, separateOwnerItems)` | `COMMODITY_SEARCH_RESULTS_UPDATED`(itemID) or `ITEM_SEARCH_RESULTS_UPDATED`(itemKey) |
| `SendSellSearchQuery(itemKey, sorts, true)` | same |
| `SendBrowseQuery(query)` / `SearchForFavorites` / `SearchForItemKeys` | `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED` → `GetBrowseResults()` array |
| `ReplicateItems()` | `REPLICATE_ITEM_LIST_UPDATE` — full-AH replicate scan exists! |
| `QueryOwnedAuctions()` | `OWNED_AUCTIONS_UPDATED` → `GetNumOwnedAuctions`, `GetOwnedAuctionInfo` |
| `RequestMoreItemSearchResults(key)` / `RequestMoreCommoditySearchResults(id)` / `Refresh{Item,Commodity}SearchResults` | paging |
| `HasFull{Browse,ItemSearch,CommoditySearch}Results` | pagination checks |

## Result accessors

- Commodity: `GetNumCommoditySearchResults(itemID)` →
  `GetCommoditySearchResultInfo(itemID, i)` → `.quantity`, `.unitPrice`, `.owners`
- Item: `GetNumItemSearchResults(itemKey)` →
  `GetItemSearchResultInfo(itemKey, i)` → `.auctionID`, `.quantity`,
  price field is `.buyoutAmount`/`.buyout` (verify at runtime — code defensively)
- Browse rows: `GetBrowseResults()[i]` → `.itemKey`, `.minPrice`, `.totalQuantity`
- `MakeItemKey(itemID, 0, 0, battlePetSpeciesId)` builds ItemKey
- `GetItemCommodityStatus(item)` + `Enum.ItemCommodityStatus.Commodity`
- `GetItemKeyInfo`, `GetExtraBrowseInfo`, `GetNumReplicateItems`,
  `GetReplicateItemInfo`, `GetReplicateItemLink` (0-indexed!)

## Mutations (each needs a hardware click)

| Call | Completion signal |
|---|---|
| `StartCommoditiesPurchase(itemID, qty)` | `COMMODITY_PRICE_UPDATED` / `COMMODITY_PRICE_UNAVAILABLE` |
| `ConfirmCommoditiesPurchase(itemID)` ← **not** `ConfirmPurchase` | `COMMODITY_PURCHASE_SUCCEEDED` / `_FAILED` |
| `PlaceBid(auctionID, amount)` | `BIDS_UPDATED`, `AUCTION_CANCELED`, sys msg |
| `PostItem(itemLoc, duration, qty, bid, buyout)` | `AUCTION_HOUSE_AUCTION_CREATED` / `AUCTION_MULTISELL_*` |
| `PostCommodity(itemLoc, duration, qty, unitPrice)` | `AUCTION_HOUSE_AUCTION_CREATED` |
| `CancelAuction(auctionID)` | `AUCTION_CANCELED` |

Durations: 1 = 12h, 2 = 24h, 3 = 48h.

## Also confirmed present

`GetQuoteDurationRemaining`, `GetCancelCost`, `CalculateItemDeposit`,
`CalculateCommodityDeposit`, `IsSellItemValid`, `CloseAuctionHouse`.

## Not present (retail names that fail here)

`GetNumBrowseResults`, `GetBrowseResultInfo`,
`GetCommoditySearchResultsQuantity`, `ConfirmPurchase`,
`SendCommoditySearchQuery` (use `SendSearchQuery`),
`SendItemSearchQuery` (use `SendSearchQuery` with ItemKey).

## Posting (verified via TSM AuctionHouseWrapper.PostAuction)

- `C_AuctionHouse.PostItem(itemLocation, duration, stackSize, bid, buyout)` — non-commodities; stackSize is one auction's size, multi-stack needs multisell/loops
- `C_AuctionHouse.PostCommodity(itemLocation, duration, quantity, unitPrice)` — stackables
- `C_AuctionHouse.GetItemCommodityStatus(itemLocation)` — takes a REAL ItemLocation (bag slot), NOT an Item mixin; returns Enum.ItemCommodityStatus.{Item,Commodity,Unknown}
- Scan-side classification is `ItemInfo.IsCommodity` = maxStack > 1 (TSM LibTSMService ItemInfo.lua) — use that when no ItemLocation exists
- Events: AUCTION_HOUSE_AUCTION_CREATED (success), AUCTION_HOUSE_POST_ERROR / AUCTION_MULTISELL_FAILURE (failure), AUCTION_MULTISELL_UPDATE (multi-stack progress)
- Client flavor: WOW_PROJECT_CAMELOT → TSM "FOREVER"; TooltipDataProcessor exists, but fires for ALL GameTooltip-template frames including ShoppingTooltips (filter to GameTooltip/ItemRefTooltip)

## SendSearchQuery — verified signature (runtime error)

`C_AuctionHouse.SendSearchQuery(itemKey, sorts, separateOwnerItems [, minLevelFilter, maxLevelFilter])`
— takes ONLY an ItemKey, no bare itemID path. All items incl. stackables are searched via `MakeItemKey(itemID, 0, 0)`.

## Buy mutations — verified signatures (runtime errors + TSM wrapper)

- `StartCommoditiesPurchase(itemID, quantity, expectedUnitPrice)`
- `ConfirmCommoditiesPurchase(itemID, quantity)` — TSM passes a trailing nil too
- `PlaceBid(auctionID, bidBuyout)` — bidBuyout = the lot's TOTAL buyout, not unit price
- `CancelAuction(auctionID)`

## Deposits (TSM AuctionHouseWrapper.GetDepositCost)

- `C_AuctionHouse.CalculateItemDeposit(itemLocation, postTime, stackSize)` — needs real ItemLocation
- `C_AuctionHouse.CalculateCommodityDeposit(itemID, postTime, stackSize)` — itemID suffices
- `postTime` shares PostItem's duration domain (1/2/3); fallback estimate: MSV × ~15% per 12h
