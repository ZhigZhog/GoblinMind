local _, GM = ...

local Now = debugprofilestop or function() return GetTime() * 1000 end

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

local function RefreshUIs()
	GM.PlanQueue.Refresh()
	if GM.Shopping and GM.Shopping.Refresh then GM.Shopping.Refresh() end
end

local f = CreateFrame("Frame")
-- pcall each: an unknown event name would error and skip the rest
for _, evt in ipairs({
	"AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "PLAYER_LOGIN",
	"COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
	"COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
	"COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
	"AUCTION_HOUSE_POST_ERROR", "AUCTION_MULTISELL_FAILURE",
	"AUCTION_HOUSE_AUCTION_CREATED", "REPLICATE_ITEM_LIST_UPDATE",
	-- this client may deliver replicate results under the legacy name
	"AUCTION_ITEM_LIST_UPDATE",
	-- browse-all is the fallback book source when replicate is silent
	"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
	-- buy-result signals: silent rejections surface here
	"BIDS_UPDATED", "AUCTION_CANCELED", "UI_ERROR_MESSAGE", "CHAT_MSG_SYSTEM",
	"CHAT_MSG_MONEY",
}) do
	pcall(f.RegisterEvent, f, evt)
end
f:SetScript("OnEvent", function(_, event, ...)
	if event == "AUCTION_HOUSE_SHOW" then
		GM.AH.open = true
		-- follow the Blizzard AH window like a normal panel
		GM.PlanQueue.Show()
		-- auto-scan only when no book exists or it's a day old — full
		-- scans are expensive (they stall window open); manual FULL SCAN
		-- covers everything in between. Delayed so it doesn't stack on
		-- top of TSM's own AH-open work
		if GM.AH.BookAge() > 86400 then
			GM.After(3, function()
				if GM.AH.open and GM.AH.BookAge() > 86400 then GM.AH.FullScan() end
			end)
		end
	elseif event == "PLAYER_LOGIN" then
		GM.AH.RestoreBook()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		GM.AH.open = false
		GM.AH.asks = nil
		GM.AH.pendingConfirm = nil
		-- peers stay open and degrade to their AH-closed states —
		-- only the session takeover (AHUI) closes with the frame
	elseif event == "REPLICATE_ITEM_LIST_UPDATE" or event == "AUCTION_ITEM_LIST_UPDATE" then
		if GM.AH.dbgEvents then GM.AH.dbgEvents[event] = true end
		-- either name may carry the replicate result on this client, but
		-- AUCTION_ITEM_LIST_UPDATE also fires for ordinary list updates —
		-- only collect while a full scan is actually outstanding
		if GM.AH.wantBook and not GM.AH.bookPending and not GM.AH.collecting then
			GM.AH.bookPending = true
			-- data can lag the event — retry the read while the buffer
			-- is still empty instead of giving up on the first try
			local tries = 0
			local function TryCollect()
				GM.AH.bookPending = nil
				if not (GM.AH.wantBook and not GM.AH.collecting) then return end
				tries = tries + 1
				local n = C_AuctionHouse.GetNumReplicateItems() or 0
				if n > 0 then
					GM.AH.CollectBook()
				elseif tries < 8 then
					GM.AH.bookPending = true
					GM.After(0.5, TryCollect)
				end
			end
			GM.After(0.5, TryCollect)
		end
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
		or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
		if GM.AH.dbgEvents then GM.AH.dbgEvents[event] = true end
		-- these fire for every browse — ours and TSM's; only consume
		-- while a browse book build is active
		if GM.AH.browse then GM.AH.OnBrowseResults() end
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		if itemID == GM.AH.scanItemID then
			-- item-search rows are authoritative when they exist; the
			-- commodity endpoint can return polluted data (2c "lots"
			-- of a 1-slot bag). Give item results a beat to land, then
			-- only consume commodity rows if the item query was empty.
			GM.After(0.5, function()
				if GM.AH.scanItemID ~= itemID then return end
				local n = (GM.AH.scanItemKey
					and C_AuctionHouse.GetNumItemSearchResults
					and C_AuctionHouse.GetNumItemSearchResults(GM.AH.scanItemKey)) or 0
				if n == 0 then GM.AH.CollectCommodityAsks(itemID) end
			end)
		end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		if GM.AH.scanItemKey then GM.AH.CollectItemAsks() end
	elseif event == "COMMODITY_PRICE_UPDATED" then
		-- arg is the quoted total for the staged quantity
		local totalPrice = select(2, ...)
		if GM.AH.pendingConfirm then
			GM.AH.pendingConfirm.quote = totalPrice
			GM.Print("quote ready — total " .. GM.Money(totalPrice or 0) .. " — click CONFIRM")
			RefreshUIs()
		end
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		GM.AH.pendingConfirm = nil
		GM.Print(GM.CC("warn") .. "no commodity quote — falling back to per-lot buyouts|r")
		if GM.PlanQueue.CommodityFallback then GM.PlanQueue.CommodityFallback() end
		RefreshUIs()
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		GM.AH.pendingConfirm = nil
		GM.Print(GM.CC("err") .. "commodity purchase failed|r")
		RefreshUIs()
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		local pc = GM.AH.pendingConfirm
		if pc then
			GM.Ledger.Add("buy", pc.itemID, pc.qty,
				pc.quote and math.floor(pc.quote / pc.qty) or nil)
		end
		GM.AH.pendingConfirm = nil
		GM.Print("purchase complete")
		RefreshUIs()
	elseif event == "BIDS_UPDATED" then
		local pb = GM.AH.pendingBuy
		if pb then
			GM.AH.pendingBuy = nil
			GM.Ledger.Add("buy", pb.itemID, pb.qty, math.floor(pb.total / pb.qty))
			GM.Print(GM.CC("pos") .. "buyout confirmed|r")
		end
	elseif event == "AUCTION_CANCELED" then
		if GM.AH.open then
			GM.Print(GM.CC("textDim") .. "auction canceled|r")
		end
	elseif event == "UI_ERROR_MESSAGE" then
		-- only surface errors at the AH — combat/gameplay errors like
		-- "target too close" aren't ours to echo
		local msg = select(2, ...) or ...
		if msg and GM.AH.open then
			GM.Print(GM.CC("err") .. tostring(msg) .. "|r")
		end
	elseif event == "CHAT_MSG_SYSTEM" then
		local msg = ...
		if msg and GM.AH.open and (msg:find("auction") or msg:find("bid")) then
			GM.Print(GM.CC("textDim") .. tostring(msg) .. "|r")
		end
	elseif event == "CHAT_MSG_MONEY" then
		-- loose parse: sum g/s/c quantities anywhere in the message
		local msg = ...
		local copper = 0
		for v, u in tostring(msg or ""):gmatch("(%d+)%s*([gsc])") do
			copper = copper + v * ({ g = 10000, s = 100, c = 1 })[u]
		end
		if copper > 0 then GM.Ledger.Gold(copper, "chat") end
	elseif event == "AUCTION_HOUSE_POST_ERROR" or event == "AUCTION_MULTISELL_FAILURE" then
		GM.Print(GM.CC("err") .. "post failed — check the item/stack and try again|r")
		RefreshUIs()
	elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
		-- the owned-auction reconcile writes the post row — it attributes
		-- posts from ANY ui, not just our executor
		GM.Inventory.QueryOwned()
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
			tinsert(asks, { qty = r.quantity, unit = r.unitPrice,
				own = (r.containsOwnerItem or r.isOwned) or nil })
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
				local seller = (r.owners and r.owners[1]) or r.owner or r.ownerName
				-- Forever returns buyoutAmount PER ITEM, not the lot
				-- total (verified: qty=147 buyout=200 = 2s/bag lot 2g94s).
				-- unit is the price directly; total is the lot cost.
				tinsert(asks, { id = r.auctionID, qty = qty, unit = price, total = price * qty,
					own = (r.containsOwnerItem or r.isOwned) or nil,
					seller = seller })
			end
		end
	end
	table.sort(asks, function(a, b) return a.unit < b.unit end)
	GM.AH.asks = asks
	if GM.AH.onScanDone then GM.AH.onScanDone(asks) end
end

-- === Shared book: one ReplicateItems pass feeds everything ===
-- book[itemID] = { mb = cheapest unit incl. ours, mbx = cheapest unit
-- excluding ours, sup = units listed, n = auctions }. Subscribers get
-- the raw per-listing rows too (sniper diffs those).

GM.AH.book = nil
GM.AH.bookT = 0
GM.AH.bookSubs = {}

-- The aggregate book persists in SavedVariables across sessions so a
-- login doesn't force a fresh full scan. Per-auction rows are
-- session-only — the sniper diff wants live listings anyway.
-- math.huge (the "no non-own listing" sentinel) can't survive
-- serialization, so it round-trips through -1.
function GM.AH.SaveBook()
	if not (GM.db and GM.AH.book) then return end
	local items = {}
	for id, e in pairs(GM.AH.book) do
		items[id] = { mb = e.mb,
			mbx = e.mbx == math.huge and -1 or e.mbx,
			sup = e.sup, n = e.n }
	end
	-- books are keyed by realm-faction scope — a char on another
	-- realm must not clobber this realm's AH picture
	GM.db.books = GM.db.books or {}
	local scope = GM.Scope()
	GM.db.books[scope] = { t = GM.AH.bookT,
		kind = GM.AH.bookKind, scope = scope, items = items }
	-- migrate legacy flat book once, then drop it
	GM.db.book = nil
end

function GM.AH.RestoreBook()
	local s = GM.db and (
		(GM.db.books and GM.db.books[GM.Scope()])
		or GM.db.book) -- legacy flat book: no scope = accept once
	if not (s and s.items) then return end
	local book = {}
	for id, e in pairs(s.items) do
		book[tonumber(id) or id] = { mb = e.mb,
			mbx = e.mbx == -1 and math.huge or e.mbx,
			sup = e.sup, n = e.n }
	end
	GM.AH.book, GM.AH.bookT, GM.AH.bookKind = book, s.t or time(), s.kind
end

function GM.AH.FullScan()
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return
	end
	if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then return end
	-- never stack a second replicate pass on an in-flight collect —
	-- a parallel Poll chain doubles the frame work the loop below does
	if GM.AH.wantBook or GM.AH.collecting then
		GM.PlanQueue.ScanStatus(GM.CC("textDim")
			.. "book collect already running|r")
		return
	end
	-- ReplicateItems is heavy: this client enforces a script execution
	-- limit AND TSM hook-processes every replicate scan too — 30s floor
	if GM.AH.BookAge() < 30 then
		GM.Print(GM.CC("textDim") .. "book scanned recently — give it a moment|r")
		return
	end
	local msg = GM.CC("textDim") .. "replicating full book…|r"
	GM.PlanQueue.ScanStatus(msg)
	if GM.Shopping and GM.Shopping.Status then GM.Shopping.Status(msg) end
	local prevT = GM.AH.bookT
	GM.AH.wantBook = true
	local ok, err = pcall(C_AuctionHouse.ReplicateItems)
	if not ok then
		GM.AH.wantBook = nil
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "ReplicateItems error: " .. tostring(err) .. "|r")
		GM.PlanQueue.Refresh()
		return
	end
	-- this client fires no completion event for replicate scans (neither
	-- REPLICATE_ITEM_LIST_UPDATE nor the legacy name) — poll the buffer
	-- instead: when the row count is nonzero and stable, data has landed
	local polls, lastN, stable = 0, -1, 0
	local eventsSeen = {}
	GM.AH.dbgEvents = eventsSeen
	local function Poll()
		if not GM.AH.wantBook then return end -- collect ran or gave up
		polls = polls + 1
		local n = C_AuctionHouse.GetNumReplicateItems() or 0
		if n > 0 then
			if n == lastN then
				stable = stable + 1
				if stable >= 2 then GM.AH.CollectBook(); return end
			else
				lastN, stable = n, 0
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					format("book streaming — %d auctions…|r", n))
			end
		else
			-- replicate is being silently dropped (server throttle) —
			-- after ~5s fall back to a browse-all book build in parallel
			if polls == 10 and not GM.AH.browse then
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					"replicate silent — browsing book instead…|r")
				GM.AH.BrowseBook()
			end
			-- debug surface: poll count, buffer size, which events fired
			local ev = ""
			for k in pairs(eventsSeen) do ev = ev .. " " .. k end
			GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
				format("replicating… poll %d · buffer %d%s|r", polls, n, ev))
		end
		if polls < 40 then
			GM.After(0.5, Poll)
		else
			GM.AH.wantBook = nil
			if GM.AH.bookT == prevT and GM.AH.open and not GM.AH.browse then
				local ev = ""
				for k in pairs(eventsSeen) do ev = ev .. " " .. k end
				local warn = GM.CC("warn") ..
					format("no book response — buffer stayed 0 · events:%s|r",
						ev ~= "" and ev or " none")
				GM.PlanQueue.ScanStatus(warn)
				if GM.Shopping and GM.Shopping.Status then GM.Shopping.Status(warn) end
				GM.PlanQueue.Progress(nil)
			end
			GM.PlanQueue.Refresh()
		end
	end
	GM.After(0.5, Poll)
	GM.PlanQueue.Refresh()
end

function GM.AH.BookAge()
	return GM.AH.bookT > 0 and (time() - GM.AH.bookT) or math.huge
end

-- a full scan of either kind is in flight — used to disable the button
function GM.AH.Busy()
	return GM.AH.wantBook or GM.AH.collecting or GM.AH.browse or nil
end

-- cheapest unit excluding our own listings (decisions use this)
function GM.AH.BookCheapest(itemID)
	local e = GM.AH.book and GM.AH.book[itemID]
	return e and e.mbx ~= math.huge and e.mbx or nil
end

-- cheapest unit including ours (display)
function GM.AH.BookMin(itemID)
	local e = GM.AH.book and GM.AH.book[itemID]
	return e and e.mb
end

function GM.AH.BookSupply(itemID)
	local e = GM.AH.book and GM.AH.book[itemID]
	return e and e.sup
end

local collectGen = 0

-- Diagnostic: dump raw ask/book data so field meanings can be verified
-- against the client's actual API contract. Three sources:
--   item-search asks  — named-field tables (the plan's ask list)
--   replicate rows    — positional tuples (the full-scan book)
--   book aggregate    — what we actually stored
local function DumpReplicate(itemID, maxRows)
	local n = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
	GM.Print(format("replicate rows: %d%s", n, itemID and (" — dumping id " .. itemID) or ""))
	local shown = 0
	for i = 0, n - 1 do
		local link = C_AuctionHouse.GetReplicateItemLink(i)
		local id = link and tonumber(link:match("item:(%d+)"))
		if not itemID or id == itemID then
			local t = { C_AuctionHouse.GetReplicateItemInfo(i) }
			local o = {}
			for j = 1, math.min(#t, 20) do o[j] = tostring(t[j]) end
			GM.Print(format("row %d · linkid=%s · %s", i, tostring(id),
				link and (link:match("%[(.-)%]") or "?") or "no-link"))
			GM.Print("  fields(" .. #t .. "): " .. table.concat(o, " | "))
			shown = shown + 1
			if shown >= (maxRows or 10) then break end
		end
	end
	if itemID and shown == 0 then
		GM.Print("no matching rows — item not in this snapshot")
	end
	return n
end

function GM.AH.DumpRows(itemID, maxRows)
	maxRows = maxRows or 10
	-- part 1: live item-search asks — the same call the plan consumes.
	-- fire a real query so results are guaranteed fresh, then dump the
	-- raw named-field tables the API hands back.
	if itemID and C_AuctionHouse.MakeItemKey and C_AuctionHouse.GetItemSearchResultInfo
		and C_AuctionHouse.SendSearchQuery then
		local key = C_AuctionHouse.MakeItemKey(itemID, 0, 0, nil)
		GM.AH.scanItemKey = key
		GM.AH.onScanDone = function()
			local n = C_AuctionHouse.GetNumItemSearchResults(key) or 0
			GM.Print(format("item-search results: %d", n))
			for i = 1, math.min(n, 2) do
				local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
				if r then
					local o = {}
					for k, v in pairs(r) do
						if type(v) == "table" then v = "n=" .. #v end
						o[#o + 1] = k .. "=" .. tostring(v)
					end
					table.sort(o)
					GM.Print("  ask[" .. i .. "] " .. table.concat(o, " · "))
				end
			end
			-- compact sweep of every row — the buyout/qty relationship
			-- is what we're verifying (per-item vs lot total)
			for i = 1, n do
				local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
				if r then
					GM.Print(format("  [%d] qty=%s buyout=%s bid=%s minBid=%s",
						i, tostring(r.quantity), tostring(r.buyoutAmount),
						tostring(r.bidAmount), tostring(r.minBid)))
				end
			end
			GM.AH.onScanDone = nil
			GM.AH.scanItemKey = nil
		end
		C_AuctionHouse.SendSearchQuery(key, EMPTY_SORTS, true)
		-- commodity side of the same item — what CollectCommodityAsks
		-- would have consumed if the event fired
		if C_AuctionHouse.GetCommoditySearchResultInfo then
			GM.After(1.5, function()
				local n = C_AuctionHouse.GetNumCommoditySearchResults
					and C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
				GM.Print(format("commodity-search results: %d (maxStack check: %s)",
					n, tostring(GM.AH.IsCommodity(itemID))))
				for i = 1, math.min(n, maxRows) do
					local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
					if r then
						local o = {}
						for k, v in pairs(r) do
							if type(v) == "table" then v = "n=" .. #v end
							o[#o + 1] = k .. "=" .. tostring(v)
						end
						table.sort(o)
						GM.Print("  cask[" .. i .. "] " .. table.concat(o, " · "))
					end
				end
			end)
		end
	end
	-- part 2: replicate snapshot; if empty, kick ReplicateItems and retry
	if not (C_AuctionHouse and C_AuctionHouse.GetReplicateItemInfo) then
		GM.Print("replicate API unavailable")
	else
		local n = C_AuctionHouse.GetNumReplicateItems() or 0
		if n == 0 and GM.AH.open and C_AuctionHouse.ReplicateItems then
			GM.Print("snapshot empty — calling ReplicateItems, retrying in 4s…")
			pcall(C_AuctionHouse.ReplicateItems)
			GM.After(4, function() DumpReplicate(itemID, maxRows) end)
		else
			DumpReplicate(itemID, maxRows)
		end
	end
	-- part 3: what we actually stored
	if itemID and GM.AH.book and GM.AH.book[itemID] then
		local e = GM.AH.book[itemID]
		GM.Print(format("book[%d]: mb=%s mbx=%s sup=%d n=%d", itemID,
			GM.Money(e.mb), e.mbx == math.huge and "—" or GM.Money(e.mbx), e.sup, e.n))
	end
end

function GM.AH.CollectBook()
	if not (C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems) then return end
	local n = C_AuctionHouse.GetNumReplicateItems() or 0
	if n == 0 then return end
	-- same snapshot size as the book we just built — a duplicate update,
	-- not new data
	if n == GM.AH.lastBookN and GM.AH.BookAge() < 30 then return end
	GM.AH.collecting = true
	GM.AH.browse = nil -- replicate data wins over an in-flight browse build
	collectGen = collectGen + 1
	local gen = collectGen
	-- own-listing keys so "cheapest" never counts ourselves
	local ownSet = {}
	for _, a in pairs(GM.Inventory.auctions or {}) do
		if a.itemID and a.qty and a.buyout then
			ownSet[a.itemID .. ":" .. a.qty .. ":" .. a.buyout] = true
		end
	end
	local rows, book = {}, {}
	local i = 0
	local lastReport = 0
	local buyIdx -- field position of buyoutPrice; detected once below
	local function Finish()
		GM.AH.collecting = nil
		GM.AH.wantBook = nil
		GM.AH.lastBookN = n
		GM.AH.bookKind = "replicate"
		GM.AH.book, GM.AH.bookT = book, time()
		pcall(GM.AH.SaveBook) -- persistence failure must not kill completion
		local items = 0
		for _ in pairs(book) do items = items + 1 end
		GM.PlanQueue.Progress(nil)
		GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("book: %d auctions · %d items|r", n, items))
		GM.Print(GM.CC("textDim") .. format("book: %d auctions · %d items|r", n, items))
		for _, cb in ipairs(GM.AH.bookSubs) do pcall(cb, rows, book) end
		GM.PlanQueue.Refresh()
	end
	local function ProcessRow(idx)
		local link = C_AuctionHouse.GetReplicateItemLink(idx)
		-- one API call per row — the tuple serves stackSize, buyout
		-- AND the field-map detection (was 3 calls/row before)
		local t = { C_AuctionHouse.GetReplicateItemInfo(idx) }
		local stackSize = t[3]
		if link and not buyIdx then
			-- Forever's tuple carries an extra field early on, so
			-- buyout sits one slot past the retail map (11 vs 10).
			-- Instead of hardcoding, find the itemID field — it is
			-- always buyoutIndex + 7 in both layouts.
			local id = tonumber(link:match("item:(%d+)"))
			for j = #t, 11, -1 do
				if id and t[j] == id then buyIdx = j - 7 break end
			end
			buyIdx = buyIdx or 10
			GM.Print(GM.CC("textDim") ..
				format("book field map: buyout at index %d|r", buyIdx))
		end
		local buyout = buyIdx and t[buyIdx] or nil
		if link and stackSize and stackSize > 0 and buyout and buyout > 0 then
			local id = tonumber(link:match("item:(%d+)"))
			-- Forever convention is per-item buyout everywhere
			-- (verified in item-search: qty=147 buyout=200 = 2s/bag);
			-- replicate follows the same server store — do NOT
			-- divide by stackSize or multi-stack items underprice
			local unit = buyout
			local own = id and ownSet[id .. ":" .. stackSize .. ":" .. buyout] or false
			rows[#rows + 1] = { id = id, link = link, qty = stackSize, unit = unit,
				buyout = buyout, key = link .. ":" .. stackSize .. ":" .. buyout, own = own }
			if id then
				local e = book[id]
				if not e then
					book[id] = { mb = unit, mbx = own and math.huge or unit, sup = stackSize, n = 1 }
				else
					if unit < e.mb then e.mb = unit end
					if not own and unit < e.mbx then e.mbx = unit end
					e.sup = e.sup + stackSize
					e.n = e.n + 1
				end
			end
		end
	end
	local lastI, stalled = 0, 0
	local function Chunk()
		if gen ~= collectGen then return end -- superseded by a newer collect
		-- time-budgeted, not row-budgeted: a fixed chunk either froze
		-- frames on fat books or crawled on thin ones. 5ms of Lua per
		-- tick with an inter-slice breather — After(0) chained the
		-- slices back-to-back and held ~half of every frame for tens
		-- of seconds under AUTO.
		local t0 = Now()
		while i < n and Now() - t0 < 5 do
			-- a throwing row (bad index, transient buffer state) must
			-- not kill the chain — the next chunk only schedules at
			-- the bottom of this function
			pcall(ProcessRow, i)
			i = i + 1
		end
		if i < n then
			-- status text is font work — ~2 updates/sec, not per chunk
			if Now() - lastReport > 400 then
				lastReport = Now()
				GM.PlanQueue.Progress(i / n)
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					format("collecting book — %d/%d auctions|r", i, n))
			end
			GM.After(0.03, Chunk)
		else
			Finish()
		end
	end
	Chunk()
	-- watchdog: if the chunk chain died silently (i stops advancing),
	-- restart it rather than leaving collect stuck forever
	GM.After(3, function()
		if gen ~= collectGen or not GM.AH.collecting then return end
		local function Dog()
			if gen ~= collectGen or not GM.AH.collecting then return end
			if i == lastI then
				stalled = stalled + 1
				if stalled == 2 then
					-- 10s no progress — revive the chain where it stopped
					stalled = 0
					GM.Print(GM.CC("warn") ..
						format("book collect stalled at %d/%d — resuming|r", i, n))
					Chunk()
					return
				end
			else
				lastI, stalled = i, 0
			end
			GM.After(5, Dog)
		end
		lastI = i
		GM.After(5, Dog)
	end)
end

-- Browse-all book build — the fallback when ReplicateItems is silently
-- dropped (server throttle, no completion event on this client).
-- SendBrowseQuery returns per-itemKey aggregates — {itemKey, minPrice,
-- totalQuantity} — so this book has mb/sup but no per-auction rows and
-- no own-listing exclusion (mbx ≈ mb).
local BROWSE_SORTS = Enum and Enum.AuctionHouseSortOrder and {
	{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
	{ sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
} or nil

function GM.AH.BrowseBook()
	if not (C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.GetBrowseResults) then
		return false
	end
	local b = { seen = 0, book = {}, rows = {}, tries = 0 }
	GM.AH.browse = b
	local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, {
		searchString = "", sorts = BROWSE_SORTS,
		filters = {}, itemClassFilters = {},
	})
	if not ok then
		GM.AH.browse = nil
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "SendBrowseQuery error: " .. tostring(err) .. "|r")
		GM.PlanQueue.Refresh()
		return false
	end
	-- stall watchdog: browse events should arrive promptly
	GM.After(6, function()
		if GM.AH.browse == b and b.seen == 0 then
			GM.AH.browse = nil
			GM.PlanQueue.ScanStatus(GM.CC("warn") .. "browse returned no results either|r")
			GM.PlanQueue.Refresh()
		end
	end)
	GM.PlanQueue.Refresh()
	return true
end

local function FinishBrowse(b)
	GM.AH.browse = nil
	-- a fresh replicate book beats aggregate data — don't clobber it
	if GM.AH.BookAge() < 60 and GM.AH.bookKind == "replicate" then return end
	GM.AH.bookKind = "browse"
	GM.AH.book, GM.AH.bookT = b.book, time()
	pcall(GM.AH.SaveBook) -- persistence failure must not kill completion
	local items = 0
	for _ in pairs(b.book) do items = items + 1 end
	GM.PlanQueue.Progress(nil)
	local msg = GM.CC("textDim") .. format("book: %d items (browse — no per-auction rows)|r", items)
	GM.PlanQueue.ScanStatus(msg)
	GM.Print(msg)
	for _, cb in ipairs(GM.AH.bookSubs) do pcall(cb, b.rows, b.book) end
	GM.PlanQueue.Refresh()
end

function GM.AH.OnBrowseResults()
	local b = GM.AH.browse
	if not b then return end
	local results = C_AuctionHouse.GetBrowseResults() or {}
	-- the array resets when someone (TSM) sends a new browse query —
	-- rebuild rather than trust stale indexes
	if #results < b.seen then
		b.seen, b.book, b.rows = 0, {}, {}
	end
	for i = b.seen + 1, #results do
		local r = results[i]
		local id = r.itemKey and r.itemKey.itemID
		if id and r.minPrice and r.minPrice > 0 then
			local e = b.book[id]
			if not e then
				b.book[id] = { mb = r.minPrice, mbx = r.minPrice,
					sup = r.totalQuantity or 0, n = 1 }
			else
				if r.minPrice < e.mb then e.mb, e.mbx = r.minPrice, r.minPrice end
				e.sup = e.sup + (r.totalQuantity or 0)
				e.n = e.n + 1
			end
			-- key carries the price so a later min-price drop re-flags
			-- for the sniper diff
			b.rows[#b.rows + 1] = { id = id, qty = r.totalQuantity or 1,
				unit = r.minPrice, buyout = r.minPrice,
				key = "b:" .. id .. ":" .. r.minPrice }
		end
		b.seen = i
	end
	GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
		format("browsing book — %d items…|r", b.seen))
	if C_AuctionHouse.HasFullBrowseResults and C_AuctionHouse.HasFullBrowseResults() then
		FinishBrowse(b)
	else
		-- request the next page; the ADDED event drives the next pass.
		-- retry once after 4s if the event never comes
		pcall(C_AuctionHouse.RequestMoreBrowseResults)
		local mySeen = b.seen
		GM.After(4, function()
			if GM.AH.browse == b and b.seen == mySeen then
				b.tries = b.tries + 1
				if b.tries <= 3 then
					pcall(C_AuctionHouse.RequestMoreBrowseResults)
				else
					GM.PlanQueue.ScanStatus(GM.CC("warn") ..
						format("browse stalled at %d items|r", mySeen))
					GM.AH.browse = nil
					GM.PlanQueue.Refresh()
				end
			end
		end)
	end
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
				RefreshUIs()
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
		GM.AH.pendingBuy = { itemID = step.itemID, qty = step.qty, total = total }
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
		-- bid below buyout only — a bid equal to buyout is rejected
		local bid = step.bid and step.bid < step.unit and step.bid or nil
		if isComm then
			C_AuctionHouse.PostCommodity(loc, step.duration or 2, qty, step.unit)
		else
			-- PostItem's qty is this auction's stack size — can't exceed the stack.
			-- bid/buyout are LOT prices (TSM: itemBid*stackSize — verified in
			-- LibTSMWoW AuctionHouseWrapper) — step.unit/bid are per-item, so
			-- scale by the posted stack or a multi-stack lists at 1 item's price
			local postQty = math.min(qty, stackCount or qty)
			C_AuctionHouse.PostItem(loc, step.duration or 2, postQty,
				bid and bid * postQty or nil, step.unit * postQty)
		end
		return true
	elseif step.kind == "cancel" then
		GM.Inventory.recentCancels[step.auctionID] = time()
		local a = GM.Inventory.auctions and GM.Inventory.auctions[step.auctionID]
		if a then GM.Ledger.Add("cancel", a.itemID, a.qty, a.buyout) end
		C_AuctionHouse.CancelAuction(step.auctionID)
		GM.After(2, GM.Inventory.QueryOwned)
		return true
	end
end
