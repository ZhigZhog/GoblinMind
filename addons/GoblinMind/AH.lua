local _, GM = ...

-- Every C_AuctionHouse mutation is invoked exclusively from a hardware
-- click routed through PlanQueue. Nothing here self-drives.
--
-- API surface verified against TSM v4.15 on the _forever_ (1.60.x) client
-- — see WoWVault/forever-auction-api.md. Notably: item searches are
-- ItemKey-based via MakeItemKey, results come from Get{Num,}*SearchResult*
-- (no GetNumBrowseResults), and purchase confirm is
-- ConfirmCommoditiesPurchase, not ConfirmPurchase.

GM.AH = {
	open = false,
	scanItemID = nil,
	scanItemKey = nil,
	asks = nil,
	onScanDone = nil,
	pendingConfirm = nil, -- { itemID } awaiting ConfirmCommoditiesPurchase
}

local EMPTY_SORTS = {}

local f = CreateFrame("Frame")
-- pcall each: an unknown event name would error and skip the rest
for _, evt in ipairs({
	"AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
	"COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
	"COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
	"COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
	"AUCTION_HOUSE_POST_ERROR", "AUCTION_MULTISELL_FAILURE",
	"AUCTION_HOUSE_AUCTION_CREATED",
	-- buy-result signals: silent rejections surface here
	"BIDS_UPDATED", "AUCTION_CANCELED", "UI_ERROR_MESSAGE", "CHAT_MSG_SYSTEM",
}) do
	pcall(f.RegisterEvent, f, evt)
end
f:SetScript("OnEvent", function(_, event, ...)
	if event == "AUCTION_HOUSE_SHOW" then
		GM.AH.open = true
	elseif event == "AUCTION_HOUSE_CLOSED" then
		GM.AH.open = false
		GM.AH.asks = nil
		GM.AH.pendingConfirm = nil
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		if itemID == GM.AH.scanItemID then GM.AH.CollectCommodityAsks(itemID) end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		if GM.AH.scanItemKey then GM.AH.CollectItemAsks() end
	elseif event == "COMMODITY_PRICE_UPDATED" then
		-- arg is the quoted total for the staged quantity
		local totalPrice = select(2, ...)
		if GM.AH.pendingConfirm then
			GM.AH.pendingConfirm.quote = totalPrice
			GM.Print("quote ready — total " .. GM.Money(totalPrice or 0) .. " — click CONFIRM")
			GM.PlanQueue.Refresh()
		end
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		GM.AH.pendingConfirm = nil
		GM.Print(GM.CC("warn") .. "no commodity quote — falling back to per-lot buyouts|r")
		if GM.PlanQueue.CommodityFallback then GM.PlanQueue.CommodityFallback() end
		GM.PlanQueue.Refresh()
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		GM.AH.pendingConfirm = nil
		GM.Print(GM.CC("err") .. "commodity purchase failed|r")
		GM.PlanQueue.Refresh()
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		GM.AH.pendingConfirm = nil
		GM.Print("purchase complete")
		GM.PlanQueue.Refresh()
	elseif event == "BIDS_UPDATED" or event == "AUCTION_CANCELED" then
		GM.Print(GM.CC("pos") .. "buyout confirmed|r")
	elseif event == "UI_ERROR_MESSAGE" then
		local msg = select(2, ...) or ...
		if msg then GM.Print(GM.CC("err") .. tostring(msg) .. "|r") end
	elseif event == "CHAT_MSG_SYSTEM" then
		local msg = ...
		if msg and (msg:find("auction") or msg:find("bid")) then
			GM.Print(GM.CC("textDim") .. tostring(msg) .. "|r")
		end
	elseif event == "AUCTION_HOUSE_POST_ERROR" or event == "AUCTION_MULTISELL_FAILURE" then
		GM.Print(GM.CC("err") .. "post failed — check the item/stack and try again|r")
		GM.PlanQueue.Refresh()
	elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
		GM.Print("auction posted")
	end
end)

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

-- TSM semantics on Forever: commodity == stackable (maxStack > 1).
-- C_AuctionHouse.GetItemCommodityStatus needs a real ItemLocation, not an
-- Item mixin, so it can't classify an arbitrary itemID.
function GM.AH.IsCommodity(itemID)
	if not (itemID and GetInfo) then return false end
	local _, _, _, _, _, _, _, maxStack = GetInfo(itemID)
	return (maxStack or 1) > 1
end

-- === Scans (read-only; safe to call from UI, no protection on queries) ===

function GM.AH.ScanItem(itemID, itemName, done)
	if not C_AuctionHouse then return done({}) end
	-- Forever's SendSearchQuery only accepts an ItemKey — no bare itemID
	-- path; stackables are searched the same way.
	GM.AH.scanItemID = itemID
	GM.AH.scanItemKey = C_AuctionHouse.MakeItemKey(itemID, 0, 0, nil)
	GM.AH.onScanDone = done
	GM.AH.asks = nil
	C_AuctionHouse.SendSearchQuery(GM.AH.scanItemKey, EMPTY_SORTS, true)
end

function GM.AH.CollectCommodityAsks(itemID)
	local asks = {}
	for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
		local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if r and r.unitPrice and r.quantity and r.quantity > 0 then
			tinsert(asks, { qty = r.quantity, unit = r.unitPrice })
		end
	end
	table.sort(asks, function(a, b) return a.unit < b.unit end)
	GM.AH.asks = asks
	if GM.AH.onScanDone then GM.AH.onScanDone(asks) end
end

function GM.AH.CollectItemAsks()
	local key = GM.AH.scanItemKey
	local asks = {}
	for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) do
		local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
		if r and r.auctionID then
			local price = r.buyoutAmount or r.buyout or r.minBid or r.minPrice
			local qty = r.quantity or r.totalQuantity or 1
			if price and qty > 0 then
				tinsert(asks, { id = r.auctionID, qty = qty, unit = ceil(price / qty), total = price })
			end
		end
	end
	table.sort(asks, function(a, b) return a.unit < b.unit end)
	GM.AH.asks = asks
	if GM.AH.onScanDone then GM.AH.onScanDone(asks) end
end

-- Posting needs a real ItemLocation from the bags, not a link.
-- C_Container is the modern namespace; fall back to legacy globals.
local CNumSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
local CItemInfo = C_Container and C_Container.GetContainerItemInfo

function GM.AH.FindInBags(itemID)
	if not (ItemLocation and CNumSlots) then return end
	for bag = 0, 5 do -- 4 bags + reagent bag
		for slot = 1, CNumSlots(bag) do
			if CItemInfo then
				local info = CItemInfo(bag, slot)
				if info and info.itemID == itemID and not info.isLocked then
					return ItemLocation:CreateFromBagAndSlot(bag, slot), info.stackCount or 1
				end
			else
				local _, stackCount, locked, _, _, _, link = GetContainerItemInfo(bag, slot)
				local id = link and tonumber(link:match("item:(%d+)"))
				if id == itemID and not locked then
					return ItemLocation:CreateFromBagAndSlot(bag, slot), stackCount or 1
				end
			end
		end
	end
end

-- Listing fee for posting `qty` of itemID (24h listing, duration=2).
-- Commodities resolve by itemID alone; items need a real bag stack, so a
-- pure flip falls back to a vendor-value estimate.
function GM.AH.DepositCost(itemID, qty)
	if not (itemID and qty and C_AuctionHouse) then return 0 end
	if GM.AH.IsCommodity(itemID) and C_AuctionHouse.CalculateCommodityDeposit then
		local ok, cost = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, 2, qty)
		if ok and cost then return cost end
	end
	local loc = GM.AH.FindInBags(itemID)
	if loc and C_AuctionHouse.CalculateItemDeposit then
		local ok, cost = pcall(C_AuctionHouse.CalculateItemDeposit, loc, 2, qty)
		if ok and cost then return cost end
	end
	local vendor = GetInfo and select(11, GetInfo(itemID))
	if vendor and vendor > 0 then
		return floor(vendor * qty * 0.30) -- ~15% MSV per 12h; verify against client
	end
	return 0
end

-- === Executors: ONE protected call per hardware click, nothing more ===

function GM.AH.Execute(step)
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return false
	end
	if step.kind == "buy" and step.commodity then
		-- StartCommoditiesPurchase(itemID, quantity, expectedUnitPrice)
		GM.Print(format("requesting quote for %d× @ %s ea…", step.qty, GM.Money(step.unit)))
		C_AuctionHouse.StartCommoditiesPurchase(step.itemID, step.qty, step.unit)
		local pc = { itemID = step.itemID, qty = step.qty }
		GM.AH.pendingConfirm = pc
		-- if no quote lands the staged flow is dead on this client —
		-- splice in per-lot buyouts automatically
		GM.After(4, function()
			if GM.AH.pendingConfirm == pc and not pc.quote then
				GM.AH.pendingConfirm = nil
				GM.Print(GM.CC("warn") .. "no commodity quote — falling back to per-lot buyouts|r")
				if GM.PlanQueue.CommodityFallback then GM.PlanQueue.CommodityFallback() end
				GM.PlanQueue.Refresh()
			end
		end)
		return "confirm"
	elseif step.kind == "buy" then
		if not step.auctionID then
			GM.Print(GM.CC("err") .. "missing auction id — hit RESCAN|r")
			return false
		end
		-- bidBuyout is the lot total — the scanned total avoids copper drift
		local total = step.total or step.unit * step.qty
		GM.Print(format("buying %d× for %s…", step.qty, GM.Money(total)))
		C_AuctionHouse.PlaceBid(step.auctionID, total)
		return true
	elseif step.kind == "confirm" then
		if not GM.AH.pendingConfirm then return false end
		GM.Print("confirming purchase…")
		C_AuctionHouse.ConfirmCommoditiesPurchase(GM.AH.pendingConfirm.itemID, GM.AH.pendingConfirm.qty)
		return true
	elseif step.kind == "post" then
		local loc, stackCount = GM.AH.FindInBags(step.itemID)
		if not loc then
			GM.Print("no unlocked stack of that item in bags")
			return false
		end
		-- post only what bags actually hold — bought lots sit in the mailbox
		-- until fetched, and skipped buys shrink the plan
		local have = GM.BagCount(step.itemID)
		local qty = math.min(step.qty, have)
		if qty < 1 then
			GM.Print("nothing in bags to post — collect the mailbox first")
			return false
		end
		if qty < step.qty then
			GM.Print(format("posting %d of %d (rest still in mail/bank)", qty, step.qty))
		end
		-- Ask the client itself: commodity status from the real ItemLocation,
		-- exactly like TSM's PostAuction. Fall back to the maxStack heuristic.
		local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, loc)
		local isComm = (ok and Enum and Enum.ItemCommodityStatus
			and status == Enum.ItemCommodityStatus.Commodity)
			or (not ok and GM.AH.IsCommodity(step.itemID))
		if isComm then
			C_AuctionHouse.PostCommodity(loc, 2, qty, step.unit)
		else
			-- PostItem's qty is this auction's stack size — can't exceed the stack
			C_AuctionHouse.PostItem(loc, 2, math.min(qty, stackCount or qty), nil, step.unit)
		end
		return true
	elseif step.kind == "cancel" then
		C_AuctionHouse.CancelAuction(step.auctionID)
		return true
	end
end
