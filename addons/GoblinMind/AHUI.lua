local _, GM = ...

-- Auction-house takeover — the same FramePark model as the crafting
-- and vendor windows: on AUCTION_HOUSE_SHOW the native frame is parked
-- offscreen (never Hide()n — C_AuctionHouse queries/posts/bids all
-- need the session open) and this window opens in its place.
--
-- Pages:
--   SHOP — name search → SendBrowseQuery aggregate results → click a
--          row → ScanItem drill-down into per-listing asks in the right
--          pane. BUY = one protected call per click: PlaceBid(lot) for
--          item auctions; commodities stage a StartCommoditiesPurchase
--          quote, then CONFIRM commits (the plan queue's two-click flow).
--   MINE — owned auctions from Inventory's cache, CANCEL per row.
--
-- Toolbar keeps the plan-queue surfaces one click away: FULL SCAN
-- (ReplicateItems book), POST SCAN, CANCEL SCAN. BLIZZARD UI hands the
-- frame back; GOBLINMIND on the native frame round-trips. ESC/X close
-- the AH session — close means close.

GM.AHUI = {}
local AU = GM.AHUI
local ui

local ROW_H = 24
local VISIBLE = 14
local ASK_VISIBLE = 12
local tinsert, sort = tinsert, table.sort
local format = format

local W = GM.Widgets
local Btn = W.Btn

local EditBox = GM.Widgets.EditBox

local Tip = GM.Widgets.Tip

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

-- browse filters — all client-side post-filtering, so they apply
-- instantly to whatever the shared array holds and never depend on
-- the client's native filter support
local function PassFilters(id, unit)
	local flt = ui.filters
	if not flt then return true end
	if flt.minC and (not unit or unit < flt.minC) then return false end
	if flt.maxC and unit and unit > flt.maxC then return false end
	if flt.rarity or flt.classID or flt.minIlvl or flt.maxIlvl or flt.slot then
		if not GetInfo then return false end
		local _, _, q, ilvl, _, _, _, _, loc, _, _, classID = GetInfo(id)
		if not q then return false end -- uncached: can't verify
		if flt.rarity and q < flt.rarity then return false end
		if flt.classID and classID ~= flt.classID then return false end
		if flt.minIlvl and (not ilvl or ilvl < flt.minIlvl) then return false end
		if flt.maxIlvl and ilvl and ilvl > flt.maxIlvl then return false end
		if flt.slot and not flt.slot[loc] then return false end
	end
	return true
end

local function AHOpen()
	return C_AuctionHouse and GM.AH.open
end

-- true while any scan pipeline is moving: the book collect/browse
-- (GM.AH) or the serialized post/cancel scan queue (GM.Auctioning)
local function ScanBusy()
	return GM.AH.Busy()
		or (GM.Auctioning and GM.Auctioning.Busy
			and GM.Auctioning.Busy()) or nil
end

local SEARCH_SORTS = Enum and Enum.AuctionHouseSortOrder and {
	{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
	{ sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
} or nil

-- One browse query in flight at a time: ui.pendingBrowse holds it
-- until the server answers. SendBrowseQuery is silently DROPPED when
-- the throttled message pipe is busy (a book scan, TSM, rapid
-- re-search) — no results event ever comes, so a bare send leaves the
-- pane on "waiting for results…" forever. Park on
-- IsThrottledMessageSystemReady and let SYSTEM_READY drive the send;
-- a per-send watchdog clears hopeless queries.
local function SendPendingBrowse()
	local p = ui.pendingBrowse
	if not p then return end
	if (p.sends or 0) >= 5 then
		ui.pendingBrowse = nil
		ui.status = "server is busy — try again"
		AU.Refresh()
		return
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady
		and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		ui.status = "waiting for the server…"
		AU.Refresh()
		return
	end
	p.sends = (p.sends or 0) + 1
	p.gen = (p.gen or 0) + 1
	local gen = p.gen
	ui.status = "searching…"
	local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, {
		searchString = p.str, sorts = SEARCH_SORTS,
		filters = {}, itemClassFilters = p.classFilters or {},
	})
	if not ok then
		ui.pendingBrowse = nil
		ui.status = "query error: " .. tostring(err)
	else
		ui.status = "waiting for results…"
		GM.After(8, function()
			if ui.pendingBrowse == p and p.gen == gen then
				ui.pendingBrowse = nil
				ui.status = "query went unanswered — try again"
				AU.Refresh()
			end
		end)
	end
	AU.Refresh()
end

local function QueueBrowse(str, classFilters, label)
	ui.searchedAt = time()
	ui.lastBrowseLabel = label
	ui.browsePaging = nil
	ui.pendingBrowse = { str = str, classFilters = classFilters }
	SendPendingBrowse()
end

-- name search → per-itemKey aggregates {itemKey, minPrice, totalQuantity}
local function DoSearch()
	local q = strtrim(ui.search:GetText() or "")
	if q == "" or q == "search…" then return end
	if not (C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.GetBrowseResults) then
		ui.status = "browse query unavailable on this client"
		AU.Refresh()
		return
	end
	QueueBrowse(q)
end

-- read the shared browse array — but ONLY for our own query. A book
-- build (replicate or the BrowseBook fallback's empty search) floods
-- this same array with every auction on the house; iterating it per
-- repaint was the scroll-storm lag. Suppress during a book pass and
-- after one lands (it clobbered our results), and cap what we build.
local RESULT_CAP = 2000
local function Results()
	local rows = {}
	if GM.AH.wantBook or GM.AH.collecting or GM.AH.browse then
		-- live progress line — the same message the planner shows
		ui.status = ui.scanMsg or "book scan in progress…"
		return rows
	end
	if not ui.searchedAt then
		-- a scan just finished shows its completion line briefly;
		-- anything older falls back to the pane's empty-state text
		ui.status = (ui.scanAt and time() - ui.scanAt < 15)
			and ui.scanMsg or nil
		return rows
	end
	if (GM.AH.bookT or 0) > ui.searchedAt then
		ui.searchedAt = nil
		ui.status = "results cleared by a book scan — search again"
		return rows
	end
	local rs = C_AuctionHouse and C_AuctionHouse.GetBrowseResults
		and C_AuctionHouse.GetBrowseResults() or {}
	local truncated = #rs > RESULT_CAP
	for i = 1, math.min(#rs, RESULT_CAP) do
		local r = rs[i]
		local id = r.itemKey and r.itemKey.itemID
		if id and PassFilters(id, r.minPrice) then
			local e = GM.ItemEntry(id)
			local mkt = GM.Price("dbmarket", id)
			-- itemKey pins the suffix variant — GetItemKeyInfo resolves
			-- "of the Bear" names where the bare id only gives the base
			-- name (fallback while the key info is still uncached)
			local name
			if C_AuctionHouse.GetItemKeyInfo then
				local ok, ki = pcall(C_AuctionHouse.GetItemKeyInfo, r.itemKey, true)
				name = ok and ki and ki.itemName or nil
			end
			rows[#rows + 1] = {
				id = id, key = r.itemKey,
				name = name or GM.ItemName(id) or ("item " .. id),
				qty = r.totalQuantity or 1, unit = r.minPrice,
				mkt = mkt,
				low = mkt and r.minPrice and r.minPrice < mkt * 0.9 or nil,
			}
		end
	end
	sort(rows, function(a, b)
		if a.low ~= b.low then return a.low and true or false end
		return (a.name or "") < (b.name or "")
	end)
	if truncated then
		ui.status = format("%d results — first %d shown, refine the search",
			#rs, RESULT_CAP)
	end
	return rows
end

-- row sources live in Inventory (shared with the MyAuctions window):
-- GM.Inventory.MineRows() = posted lots w/ market ref + undercut flag,
-- GM.Inventory.BidRows() = auctions we're in, outbid first.

-- Blizzard/TSM commodity multi-buy: N units fill cheapest-level-first,
-- capped at the unit price of the level that completes the fill.
-- One StartCommoditiesPurchase per click → CONFIRM commits.
function AU.BuyN()
	if ui.stagedBuy then
		local pc = GM.AH.pendingConfirm
		if pc and ui.sel and pc.itemID == ui.sel.id then
			GM.AH.Execute({ kind = "confirm" })
		else
			ui.status = "staged quote was replaced — stage the buy again"
		end
		ui.stagedBuy = nil
		ui.confirmAsk = nil
		AU.Refresh()
		return
	end
	local n = tonumber(ui.qty:GetText()) or 0
	if not (ui.sel and ui.asks and n > 0) then return end
	local cap, acc
	for _, a in ipairs(ui.asks) do -- asks sort cheapest-first already
		if not a.own then
			acc = (acc or 0) + (a.qty or 0)
			cap = a.unit
			if acc >= n then break end
		end
	end
	if not cap then return end
	local r = GM.AH.Execute({ kind = "buy", commodity = true,
		itemID = ui.sel.id, qty = n, unit = cap })
	if r == "confirm" then ui.stagedBuy = true end
	AU.Refresh()
end

-- drill into a result: per-listing asks land in the right pane
local function ScanAsks(r)
	ui.sel = r
	ui.asks = nil
	ui.stagedBuy = nil
	ui.confirmAsk = nil
	ui.status = "scanning " .. (r.name or "?") .. "…"
	AU.Refresh()
	GM.AH.ScanItem(r.id, r.name, function(asks)
		ui.asks = asks or {}
		ui.status = nil
		AU.Refresh()
	end, r.key)
end

local function BuyAsk(a)
	if a.own then return end
	if a.id then
		-- item auction: PlaceBid with the lot total
		GM.AH.Execute({ kind = "buy", itemID = ui.sel.id, auctionID = a.id,
			qty = a.qty, unit = a.unit, total = a.total })
	else
		-- commodity aggregate: stage the quote, CONFIRM on the next click
		local r = GM.AH.Execute({ kind = "buy", commodity = true,
			itemID = ui.sel.id, qty = a.qty, unit = a.unit })
		if r == "confirm" then ui.confirmAsk = a end
	end
	AU.Refresh()
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { page = "shop", scroll = 0, askScroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindAH", UIParent)
	f:SetSize(800, 470)
	f:SetPoint("CENTER", -40, -10)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:Hide()
	GM.Panel(f, "contLow", "outlineVar")
	tinsert(UISpecialFrames, "GoblinMindAH")
	ui.frame = f

	-- close means close: restore the native frame quietly and end the
	-- AH session — unless the user asked for the Blizzard frame
	f:SetScript("OnHide", function()
		GM.FramePark.Restore(AuctionHouseFrame)
		if not ui.wantDefault then
			pcall(C_AuctionHouse and C_AuctionHouse.CloseAuctionHouse
				or CloseAuctionHouse)
		end
	end)
	-- browse results + owned-auction changes → repaint; throttle events
	-- drive the pending-query pump
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
	pcall(f.RegisterEvent, f, "BAG_UPDATE")
	f:SetScript("OnEvent", function(_, event)
		if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
			-- OUR query answered — results now own the pane; flag it so
			-- ADDED pages keep arriving until the array is complete
			if ui.pendingBrowse then
				ui.pendingBrowse = nil
				ui.browsePaging = true
				ui.status = nil
			end
		elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
			-- results arrive paged for broad queries — pull the next
			-- page like the native UI does. Book builds run their own
			-- pagination; don't double-drive the same array
			if ui.browsePaging and not GM.AH.Busy() then
				if C_AuctionHouse.HasFullBrowseResults
					and C_AuctionHouse.HasFullBrowseResults() then
					ui.browsePaging = nil
				else
					pcall(C_AuctionHouse.RequestMoreBrowseResults)
				end
			end
		elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY"
			or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
			-- a dropped query never produces a results event — resend
			-- once the pipe reports ready (send-side gates + cap)
			if ui.pendingBrowse then SendPendingBrowse() return end
		end
		if not f:IsShown() or ui.evPending then return end
		ui.evPending = true
		GM.After(0.2, function()
			ui.evPending = nil
			AU.Refresh()
		end)
	end)

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("AUCTION HOUSE")
	-- contextual takeover (AH session only) — no dashboard tab strip

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- toolbar: search + page toggles + scan shortcuts
	ui.search = EditBox(f, 170, "search…")
	ui.search:SetPoint("TOPLEFT", 12, -34)
	ui.search:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		ui.scroll = 0
		DoSearch()
	end)
	local x = 190
	local tabHost = CreateFrame("Frame", nil, f)
	tabHost:SetSize(124, 20)
	tabHost:SetPoint("TOPLEFT", x, -34)
	ui.pageTabs = W.PageTabs(tabHost,
		{ { "shop", "SHOP" }, { "mine", "MINE" } },
		function(key)
			ui.page = key
			ui.scroll = 0
			ui.bidScroll = 0
			if key == "mine" then
				GM.Inventory.QueryOwned()
				GM.Inventory.QueryBids()
			end
			AU.Refresh()
		end)
	x = x + 130
	local full = Btn(f, 76, "FULL SCAN", function() GM.AH.FullScan() end)
	full:SetPoint("TOPLEFT", x + 6, -34)
	Tip(full, function()
		return { "Full book scan",
			"ReplicateItems → the shared price book (mb/mbx/sup).",
			"Feeds tooltips, sniper, and every market column." }
	end)
	local post = Btn(f, 84, "POST SCAN", function() GM.Auctioning.PostScan() end)
	post:SetPoint("LEFT", full, "RIGHT", 6, 0)
	local cancel = Btn(f, 90, "CANCEL SCAN", function() GM.Auctioning.CancelScan() end)
	cancel:SetPoint("LEFT", post, "RIGHT", 6, 0)
	local snip = Btn(f, 62, "SNIPER", function() GM.SniperUI.Toggle() end)
	snip:SetPoint("LEFT", cancel, "RIGHT", 6, 0)
	Tip(snip, function()
		return { "Sniper",
			"Opens the deal panel — soon-expiring auctions priced",
			"under the book. Same as /goblin snip." }
	end)
	local blizz = Btn(f, 84, "BLIZZARD UI", function()
		ui.wantDefault = true
		f:Hide() -- OnHide → Restore: native frame returns, session stays
	end)
	blizz:SetPoint("TOPRIGHT", -28, -34)
	Tip(blizz, function()
		return { "Blizzard default UI",
			"Brings the default auction frame back and hides this",
			"window. The GOBLINMIND button on that frame switches back." }
	end)

	-- left pane: results (SHOP) or owned auctions (MINE)
	local lp = CreateFrame("Frame", nil, f)
	lp:SetSize(412, VISIBLE * ROW_H + 30)
	lp:SetPoint("TOPLEFT", 12, -62)
	GM.Panel(lp, "contLowest")
	ui.lp = lp
	ui.lHead = GM.MakeFontString(lp, GM.FONT_BOLD, 9, "secondary")
	ui.lHead:SetPoint("TOPLEFT", 8, -6)
	-- browse labels + the scroll counter must stay left of the
	-- BROWSE/FILTER/SAVED buttons (start ~264)
	ui.lHead:SetWidth(190)
	ui.lHead:SetJustifyH("LEFT")
	ui.lCount = GM.MakeFontString(lp, GM.FONT, 9, "textDim")
	-- follows the header text's right edge — never collides with the
	-- BROWSE/FILTER/SAVED buttons anchored at the pane's top-right
	ui.lCount:SetPoint("LEFT", ui.lHead, "RIGHT", 10, 0)
	-- BROWSE pops the item-class tree — the native UI's category
	-- browse, reissued as itemClassFilters on an empty search
	ui.browseBtn = Btn(lp, 48, "BROWSE", function()
		ui.filterBox:Hide()
		if ui.savedBox then ui.savedBox:Hide() end
		ui.browseBox:SetShown(not ui.browseBox:IsShown())
	end)
	ui.browseBtn:SetSize(48, 14)
	ui.browseBtn:SetPoint("TOPRIGHT", -100, -4)
	ui.fltBtn = Btn(lp, 44, "FILTER", function()
		ui.browseBox:Hide()
		if ui.savedBox then ui.savedBox:Hide() end
		ui.filterBox:SetShown(not ui.filterBox:IsShown())
	end)
	ui.fltBtn:SetSize(44, 14)
	ui.fltBtn:SetPoint("TOPRIGHT", -52, -4)
	ui.saveBtn = Btn(lp, 42, "SAVED", function()
		ui.browseBox:Hide()
		ui.filterBox:Hide()
		BuildSavedBox()
		ui.savedBox:SetShown(not ui.savedBox:IsShown())
	end)
	ui.saveBtn:SetSize(42, 14)
	ui.saveBtn:SetPoint("TOPRIGHT", -6, -4)
	lp:EnableMouseWheel(true)
	lp:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		AU.Refresh()
	end)
	ui.rows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, lp)
		row:SetSize(396, ROW_H - 2)
		row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 26, 0)
		row.name:SetWidth(140)
		row.name:SetJustifyH("LEFT")
		row.c1 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c1:SetPoint("LEFT", 170, 0)
		row.c2 = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.c2:SetPoint("LEFT", 234, 0)
		row.c2:SetWidth(104)
		row.c2:SetJustifyH("LEFT")
		local act = CreateFrame("Button", nil, row)
		act:SetSize(50, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "warn")
		act.text:SetPoint("CENTER")
		row.act = act
		row:SetScript("OnEnter", function(self)
			if self.tipID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.tipID)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.rows[i] = row
	end
	ui.lEmpty = GM.MakeFontString(lp, GM.FONT, 10, "textDim")
	ui.lEmpty:SetPoint("CENTER", 0, -10)

	-- right pane: per-listing asks for the selected SHOP row
	local rp = CreateFrame("Frame", nil, f)
	rp:SetSize(344, ASK_VISIBLE * ROW_H + 30)
	rp:SetPoint("TOPRIGHT", -12, -62)
	GM.Panel(rp, "contLowest")
	ui.rHead = GM.MakeFontString(rp, GM.FONT_BOLD, 9, "secondary")
	ui.rHead:SetPoint("TOPLEFT", 8, -6)
	-- "LISTINGS — <long item name>" must clip before the header's
	-- QTY box / BUY button / scroll counter on the right
	ui.rHead:SetWidth(196)
	ui.rHead:SetJustifyH("LEFT")
	ui.rCount = GM.MakeFontString(rp, GM.FONT, 9, "textDim")
	ui.rCount:SetPoint("TOPRIGHT", -166, -7)
	rp:EnableMouseWheel(true)
	rp:SetScript("OnMouseWheel", function(_, d)
		ui.askScroll = math.max(0, ui.askScroll - d * 3)
		AU.Refresh()
	end)
	ui.rp = rp
	ui.askRows = {}
	for i = 1, ASK_VISIBLE do
		local row = CreateFrame("Button", nil, rp)
		row:SetSize(328, ROW_H - 2)
		row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.c1 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c1:SetPoint("LEFT", 8, 0)
		row.c2 = GM.MakeFontString(row, GM.FONT, 10, "accent")
		row.c2:SetPoint("LEFT", 72, 0)
		row.c3 = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.c3:SetPoint("LEFT", 162, 0)
		row.c3:SetWidth(104)
		row.c3:SetJustifyH("LEFT")
		local act = CreateFrame("Button", nil, row)
		act:SetSize(52, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		row.act = act
		ui.askRows[i] = row
	end
	ui.rEmpty = GM.MakeFontString(rp, GM.FONT, 10, "textDim")
	ui.rEmpty:SetPoint("CENTER", 0, -10)

	-- commodity multi-buy controls in the right-pane header (Blizzard
	-- parity: enter N, buy through the ask levels → quote → CONFIRM)
	ui.qtyLbl = GM.MakeFontString(rp, GM.FONT_BOLD, 9, "secondary")
	ui.qtyLbl:SetPoint("TOPRIGHT", -130, -7)
	ui.qtyLbl:SetText("QTY")
	ui.qty = EditBox(rp, 40, "qty")
	ui.qty:SetPoint("TOPRIGHT", -84, -4)
	-- no SetNumeric — it strips the "qty" hint on this client and the
	-- empty dark box was invisible. tonumber() validates on use.
	GM.Panel(ui.qty, "contMedium")
	ui.qty:SetScript("OnTextChanged", function()
		if ui.frame:IsShown() then AU.Refresh() end
	end)
	ui.buyN = Btn(rp, 76, "BUY", function() AU.BuyN() end)
	ui.buyN:SetPoint("TOPRIGHT", -8, -4)
	ui.buyN.text:SetTextColor(GM.RGB("accent"))

	-- MINE page splits top/bottom: POSTED (owned auctions) on top,
	-- BIDS (auctions we're in) underneath. MINE_VISIBLE rows each.
	local MINE_VISIBLE = 6
	local MINE_PANE_H = 22 + MINE_VISIBLE * ROW_H + 8
	local fp = CreateFrame("Frame", nil, f)
	fp:SetSize(776, MINE_PANE_H)
	fp:SetPoint("TOPLEFT", 12, -62)
	GM.Panel(fp, "contLowest")
	fp:EnableMouseWheel(true)
	fp:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		AU.Refresh()
	end)
	fp:Hide()
	ui.fp = fp
	ui.mHead = {}
	for i, h in ipairs({
		{ "ITEM", 26 }, { "QTY", 218 }, { "UNIT", 260 }, { "LOT", 330 },
		{ "MARKET", 420 }, { "STATUS", 500 }, { "TIME", 640 },
	}) do
		local fs = GM.MakeFontString(fp, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("TOPLEFT", h[2], -6)
		fs:SetText(h[1])
		ui.mHead[i] = fs
	end
	ui.mHead[1]:SetText("POSTED — ITEM")
	ui.mCount = GM.MakeFontString(fp, GM.FONT, 9, "textDim")
	ui.mCount:SetPoint("TOPRIGHT", -8, -7)
	ui.mRows = {}
	for i = 1, MINE_VISIBLE do
		local row = CreateFrame("Button", nil, fp)
		row:SetSize(760, ROW_H - 2)
		row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 26, 0)
		row.name:SetWidth(184)
		row.name:SetJustifyH("LEFT")
		row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.qty:SetPoint("LEFT", 218, 0)
		row.unit = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.unit:SetPoint("LEFT", 260, 0)
		row.lot = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.lot:SetPoint("LEFT", 330, 0)
		row.mkt = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.mkt:SetPoint("LEFT", 420, 0)
		row.stat = GM.MakeFontString(row, GM.FONT_BOLD, 9, "textDim")
		row.stat:SetPoint("LEFT", 500, 0)
		row.stat:SetWidth(136)
		row.stat:SetJustifyH("LEFT")
		row.time = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.time:SetPoint("LEFT", 640, 0)
		local act = CreateFrame("Button", nil, row)
		act:SetSize(56, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "warn")
		act.text:SetPoint("CENTER")
		act.text:SetText("CANCEL")
		row.act = act
		row:SetScript("OnEnter", function(self)
			if self.tipID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.tipID)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.mRows[i] = row
	end
	ui.fEmpty = GM.MakeFontString(fp, GM.FONT, 10, "textDim")
	ui.fEmpty:SetPoint("CENTER", 0, -10)

	-- bottom half: auctions we've bid on — our bid, current bid,
	-- buyout, time left, and winning/outbid status; REBID = +1c
	local bp = CreateFrame("Frame", nil, f)
	bp:SetSize(776, MINE_PANE_H)
	bp:SetPoint("TOPLEFT", fp, "BOTTOMLEFT", 0, -8)
	GM.Panel(bp, "contLowest")
	bp:EnableMouseWheel(true)
	bp:SetScript("OnMouseWheel", function(_, d)
		ui.bidScroll = math.max(0, (ui.bidScroll or 0) - d * 3)
		AU.Refresh()
	end)
	bp:Hide()
	ui.bp = bp
	for i, h in ipairs({
		{ "BIDS — ITEM", 26 }, { "OUR BID", 218 }, { "CURRENT", 300 },
		{ "BUYOUT", 390 }, { "TIME", 480 }, { "STATUS", 560 },
	}) do
		local fs = GM.MakeFontString(bp, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("TOPLEFT", h[2], -6)
		fs:SetText(h[1])
	end
	ui.bCount = GM.MakeFontString(bp, GM.FONT, 9, "textDim")
	ui.bCount:SetPoint("TOPRIGHT", -8, -7)
	ui.bRows = {}
	for i = 1, MINE_VISIBLE do
		local row = CreateFrame("Button", nil, bp)
		row:SetSize(760, ROW_H - 2)
		row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 26, 0)
		row.name:SetWidth(184)
		row.name:SetJustifyH("LEFT")
		row.our = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.our:SetPoint("LEFT", 218, 0)
		row.cur = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.cur:SetPoint("LEFT", 300, 0)
		row.bo = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.bo:SetPoint("LEFT", 390, 0)
		row.time = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.time:SetPoint("LEFT", 480, 0)
		row.stat = GM.MakeFontString(row, GM.FONT_BOLD, 9, "textDim")
		row.stat:SetPoint("LEFT", 560, 0)
		row.stat:SetWidth(130)
		row.stat:SetJustifyH("LEFT")
		local act = CreateFrame("Button", nil, row)
		act:SetSize(56, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		act.text:SetText("REBID")
		row.act = act
		row:SetScript("OnEnter", function(self)
			if self.tipID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.tipID)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.bRows[i] = row
	end
	ui.bEmpty = GM.MakeFontString(bp, GM.FONT, 10, "textDim")
	ui.bEmpty:SetPoint("CENTER", 0, -10)

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
	-- cap the footer so long status lines clip in-window instead of
	-- drawing past the frame edge
	ui.foot:SetWidth(772)
	ui.foot:SetJustifyH("LEFT")

	-- ============ filter popover ============
	-- client-side filters over the shared browse array — changes
	-- re-render instantly, no re-query
	local fb = CreateFrame("Frame", nil, f)
	fb:SetSize(216, 150)
	fb:SetPoint("TOPLEFT", 12, -58)
	fb:SetFrameStrata("DIALOG")
	GM.Panel(fb, "contHigh", "outlineVar")
	fb:Hide()
	ui.filterBox = fb
	ui.filters = ui.filters or {}
	local fltT = GM.MakeFontString(fb, GM.FONT_BOLD, 9, "accent")
	fltT:SetPoint("TOPLEFT", 8, -6)
	fltT:SetText("FILTERS (apply to results)")

	-- dropdown popover — picking an option sets the filter and
	-- repaints (replaces the cycle buttons whose labels never
	-- updated, so the applied value was invisible). Frame level is
	-- bumped hard: siblings created later draw over a child popover,
	-- which was rendering the list with no backing panel
	local db = CreateFrame("Frame", nil, fb)
	db:SetFrameStrata("DIALOG")
	db:SetFrameLevel(fb:GetFrameLevel() + 10)
	GM.Panel(db, "contHigh", "outlineVar")
	db:Hide()
	ui.dropBox = db
	local dbT = GM.MakeFontString(db, GM.FONT_BOLD, 9, "accent")
	dbT:SetPoint("TOPLEFT", 8, -6)
	local dbRows = {}
	for i = 1, 10 do
		local b = Btn(db, 136, "", function() end)
		b:SetSize(136, 17)
		b:SetPoint("TOPLEFT", 8, -24 - (i - 1) * 18)
		b:SetFrameLevel(db:GetFrameLevel() + 1)
		b:Hide()
		dbRows[i] = b
	end
	local function OpenDrop(anchor, title, options, selIx, onPick)
		-- clicking the owning button again closes without changing
		if db:IsShown() and db.anchor == anchor then
			db:Hide()
			db.anchor = nil
			return
		end
		db.anchor = anchor
		dbT:SetText(title)
		for i, b in ipairs(dbRows) do
			local opt = options[i]
			if opt then
				b:Show()
				-- selected option carries a marker — embedded quality
				-- colors would hide a text-color highlight
				b.text:SetText((i == selIx
					and GM.CC("accent") .. "» |r" or "") .. opt)
				b:SetScript("OnClick", function()
					onPick(i)
					db:Hide()
					db.anchor = nil
				end)
			else
				b:Hide()
			end
		end
		db:SetSize(152, 24 + #options * 18 + 8)
		db:ClearAllPoints()
		db:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
		db:Show()
	end

	-- item-quality hexes — embedded in the label so Btn's hover/leave
	-- SetTextColor can't stomp the rarity color
	local QUAL_HEX = { [2] = "1eff00", [3] = "0070dd", [4] = "a335ee" }
	local RARITIES = { "any", "uncommon+", "rare+", "epic+" }
	local RARITY_VAL = { nil, 2, 3, 4 }
	local RAR_OPT = {}
	for i, name in ipairs(RARITIES) do
		local hex = QUAL_HEX[RARITY_VAL[i]]
		RAR_OPT[i] = hex and ("|cff" .. hex .. name .. "|r") or name
	end
	local FCLASSES = { "any", "weapons", "armor", "containers",
		"consumables", "trade goods", "ammo", "recipes",
		"quest", "miscellaneous" }
	local FCLASS_VAL = { nil, 2, 4, 1, 0, 7, 6, 9, 12, 15 }
	-- armor-slot filter — equipLoc sets per slot (chest also covers
	-- robe; back is INVTYPE_CLOAK). Checked client-side in PassFilters
	local SLOTS = { "any", "head", "shoulder", "back", "chest",
		"wrist", "hands", "waist", "legs", "feet" }
	local SLOT_VAL = { nil,
		{ INVTYPE_HEAD = true }, { INVTYPE_SHOULDER = true },
		{ INVTYPE_CLOAK = true },
		{ INVTYPE_CHEST = true, INVTYPE_ROBE = true },
		{ INVTYPE_WRIST = true }, { INVTYPE_HAND = true },
		{ INVTYPE_WAIST = true }, { INVTYPE_LEGS = true },
		{ INVTYPE_FEET = true } }
	ui.rarIx, ui.clsIx, ui.slotIx = 1, 1, 1
	local rar = Btn(fb, 96, "rarity: any", function(self)
		OpenDrop(self, "RARITY", RAR_OPT, ui.rarIx, function(i)
			ui.rarIx = i
			ui.filters.rarity = RARITY_VAL[i]
			self.text:SetText("rarity: " .. RAR_OPT[i])
			AU.Refresh()
		end)
	end)
	rar:SetSize(96, 18)
	rar:SetPoint("TOPLEFT", 8, -24)
	local slot = Btn(fb, 100, "slot: any", function(self)
		OpenDrop(self, "SLOT", SLOTS, ui.slotIx, function(i)
			ui.slotIx = i
			ui.filters.slot = SLOT_VAL[i]
			self.text:SetText("slot: " .. SLOTS[i])
			AU.Refresh()
		end)
	end)
	slot:SetSize(100, 18)
	slot:SetPoint("TOPLEFT", 108, -24)
	local cls = Btn(fb, 108, "class: any", function(self)
		OpenDrop(self, "CLASS", FCLASSES, ui.clsIx, function(i)
			ui.clsIx = i
			ui.filters.classID = FCLASS_VAL[i]
			self.text:SetText("class: " .. FCLASSES[i])
			AU.Refresh()
		end)
	end)
	cls:SetSize(108, 18)
	cls:SetPoint("TOPLEFT", 8, -46)
	ui.fltBtns = { rar, cls, slot }

	local function Lab(txt, y)
		local fs = GM.MakeFontString(fb, GM.FONT, 9, "textDim")
		fs:SetPoint("TOPLEFT", 8, y)
		fs:SetText(txt)
	end
	Lab("ilvl", -70)
	ui.minIlvl = EditBox(fb, 36, "")
	ui.minIlvl:SetPoint("TOPLEFT", 34, -68)
	ui.maxIlvl = EditBox(fb, 36, "")
	ui.maxIlvl:SetPoint("LEFT", ui.minIlvl, "RIGHT", 6, 0)
	Lab("price", -92)
	ui.minC = EditBox(fb, 56, "")
	ui.minC:SetPoint("TOPLEFT", 42, -90)
	ui.maxC = EditBox(fb, 56, "")
	ui.maxC:SetPoint("LEFT", ui.minC, "RIGHT", 6, 0)
	local function ApplyTextFilters()
		ui.filters.minIlvl = tonumber(ui.minIlvl:GetText())
		ui.filters.maxIlvl = tonumber(ui.maxIlvl:GetText())
		ui.filters.minC = GM.Budget
			and GM.Budget.ParseMoney(ui.minC:GetText())
			or tonumber(ui.minC:GetText())
		ui.filters.maxC = GM.Budget
			and GM.Budget.ParseMoney(ui.maxC:GetText())
			or tonumber(ui.maxC:GetText())
		AU.Refresh()
	end
	for _, eb in ipairs({ ui.minIlvl, ui.maxIlvl, ui.minC, ui.maxC }) do
		eb:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			ApplyTextFilters()
		end)
	end
	local clr = Btn(fb, 60, "CLEAR", function()
		ui.filters = {}
		ui.rarIx, ui.clsIx, ui.slotIx = 1, 1, 1
		rar.text:SetText("rarity: any")
		slot.text:SetText("slot: any")
		cls.text:SetText("class: any")
		ui.minIlvl:SetText("") ui.maxIlvl:SetText("")
		ui.minC:SetText("") ui.maxC:SetText("")
		AU.Refresh()
	end)
	clr:SetSize(60, 18)
	clr:SetPoint("BOTTOMRIGHT", -8, 8)

	-- ============ saved searches ============
	-- name prompt — {name, q, f} goes into GM.db.ahSearches
	local nb = CreateFrame("Frame", nil, f)
	nb:SetSize(216, 44)
	-- right of the saved-searches popover (12..228) and well above it
	-- in level — it used to open exactly beneath sb and look dead
	nb:SetPoint("TOPLEFT", 232, -58)
	nb:SetFrameStrata("DIALOG")
	nb:SetFrameLevel(500)
	GM.Panel(nb, "contHigh", "outlineVar")
	nb:Hide()
	ui.nameBox = nb
	local nbT = GM.MakeFontString(nb, GM.FONT_BOLD, 9, "accent")
	nbT:SetPoint("TOPLEFT", 8, -6)
	nbT:SetText("SAVE SEARCH AS")
	nb.eb = EditBox(nb, 140, "name…")
	nb.eb:SetPoint("TOPLEFT", 8, -20)
	nb.ok = Btn(nb, 40, "OK", function()
		local name = strtrim(nb.eb:GetText() or "")
		if name ~= "" and name ~= "name…" then
			GM.db.ahSearches = GM.db.ahSearches or {}
			local flt = {}
			for k, v in pairs(ui.filters or {}) do flt[k] = v end
			tinsert(GM.db.ahSearches, {
				name = name,
				q = strtrim(ui.search:GetText() or ""),
				f = flt,
			})
		end
		nb.eb:SetText("")
		nb:Hide()
		BuildSavedBox()
	end)
	nb.ok:SetSize(40, 16)
	nb.ok:SetPoint("LEFT", nb.eb, "RIGHT", 6, 0)
	nb.eb:SetScript("OnEnterPressed", function()
		nb.ok:GetScript("OnClick")(nb.ok)
		nb.eb:ClearFocus()
	end)

	-- ============ class browse popover ============
	-- the native tree's roots + subclasses — a pick issues an
	-- itemClassFilters query on an empty search string, which is what
	-- Blizzard's own tree clicks send. classID/subClassID = Blizzard's
	-- stable itemClass/itemSubClass enum values (1.60 taxonomy).
	local BROWSE_TREE = {
		{ "All Items" },
		{ "Weapons", 2, {
			{ "1H Axes", 0 }, { "2H Axes", 1 }, { "Bows", 2 },
			{ "Guns", 3 }, { "1H Maces", 4 }, { "2H Maces", 5 },
			{ "Polearms", 6 }, { "1H Swords", 7 }, { "2H Swords", 8 },
			{ "Staves", 10 }, { "Fist", 13 }, { "Daggers", 15 },
			{ "Thrown", 16 }, { "Crossbows", 18 }, { "Wands", 19 },
			{ "Fishing", 20 }, { "Other", 14 } } },
		{ "Armor", 4, {
			{ "Cloth", 1 }, { "Leather", 2 }, { "Mail", 3 },
			{ "Shields", 4 }, { "Librams", 5 }, { "Idols", 6 },
			{ "Totems", 7 }, { "Misc", 0 } } },
		{ "Containers", 1, {
			{ "Bags", 0 }, { "Soul", 1 }, { "Herb", 2 },
			{ "Enchanting", 3 }, { "Engineering", 4 }, { "Gem", 5 },
			{ "Mining", 6 }, { "Leatherworking", 7 } } },
		{ "Consumables", 0, {
			{ "Potions", 1 }, { "Elixirs", 2 }, { "Flasks", 3 },
			{ "Scrolls", 4 }, { "Food & Drink", 5 },
			{ "Item Enhancements", 6 }, { "Bandages", 7 },
			{ "Other", 8 } } },
		{ "Trade Goods", 7, {
			{ "Parts", 1 }, { "Explosives", 2 }, { "Devices", 3 },
			{ "Cloth", 5 }, { "Leather", 6 }, { "Metal & Stone", 7 },
			{ "Meat", 8 }, { "Herbs", 9 }, { "Elemental", 10 },
			{ "Enchanting", 12 }, { "Other", 11 } } },
		{ "Ammo", 6, {
			{ "Arrows", 2 }, { "Bullets", 3 } } },
		{ "Recipes", 9, {
			{ "Books", 0 }, { "Leatherworking", 1 }, { "Tailoring", 2 },
			{ "Engineering", 3 }, { "Blacksmithing", 4 },
			{ "Cooking", 5 }, { "Alchemy", 6 }, { "First Aid", 7 },
			{ "Enchanting", 8 }, { "Fishing", 9 },
			{ "Jewelcrafting", 10 } } },
		{ "Quest Items", 12 },
		{ "Miscellaneous", 15, {
			{ "Junk", 0 }, { "Reagents", 1 }, { "Pets", 2 },
			{ "Holiday", 3 }, { "Mounts", 5 }, { "Other", 4 } } },
	}
	local bb = CreateFrame("Frame", nil, f)
	bb:SetSize(336, 24 + 17 * 18 + 8)
	bb:SetPoint("TOPLEFT", 12, -58)
	bb:SetFrameStrata("DIALOG")
	GM.Panel(bb, "contHigh", "outlineVar")
	bb:Hide()
	ui.browseBox = bb
	local bbT = GM.MakeFontString(bb, GM.FONT_BOLD, 9, "accent")
	bbT:SetPoint("TOPLEFT", 8, -6)
	bbT:SetText("BROWSE")
	local bbSub = GM.MakeFontString(bb, GM.FONT_BOLD, 9, "secondary")
	bbSub:SetPoint("TOPLEFT", 176, -6)
	ui.browseRoots = {}
	ui.browseSubs = {}
	for i, c in ipairs(BROWSE_TREE) do
		local b = Btn(bb, 156, c[1], function()
			ui.browseSel = i
			ui.search:SetText("")
			QueueBrowse("",
				c[2] and { { classID = c[2] } } or nil, c[1])
			AU.BuildBrowseSubs()
			AU.Refresh()
		end)
		b:SetSize(156, 17)
		b:SetPoint("TOPLEFT", 8, -24 - (i - 1) * 18)
		ui.browseRoots[i] = b
	end
	for i = 1, 17 do
		local b = Btn(bb, 156, "", function() end)
		b:SetSize(156, 17)
		b:SetPoint("TOPLEFT", 172, -24 - (i - 1) * 18)
		b:Hide()
		ui.browseSubs[i] = b
	end
	-- right column repaints for the selected root's subclasses
	function AU.BuildBrowseSubs()
		local root = ui.browseSel and BROWSE_TREE[ui.browseSel]
		bbSub:SetText(root and root[3] and strupper(root[1]) or "")
		for i, b in ipairs(ui.browseSubs) do
			local s = root and root[3] and root[3][i]
			if s then
				b:Show()
				b.text:SetText(s[1])
				local cls, sub, label =
					root[2], s[2], root[1] .. " / " .. s[1]
				b:SetScript("OnClick", function()
					ui.search:SetText("")
					QueueBrowse("",
						{ { classID = cls, subClassID = sub } }, label)
					bb:Hide()
				end)
			else
				b:Hide()
			end
		end
		-- selected root highlights; the rest dim
		for i, b in ipairs(ui.browseRoots) do
			b.text:SetTextColor(GM.RGB(
				i == ui.browseSel and "accent" or "text"))
		end
	end
	AU.BuildBrowseSubs()

	-- ============ post dialog ============
	local pd = CreateFrame("Frame", nil, f)
	pd:SetSize(250, 176)
	pd:SetPoint("CENTER", 0, 30)
	pd:SetFrameStrata("FULLSCREEN_DIALOG")
	GM.Panel(pd, "contHigh", "outlineVar")
	pd:Hide()
	ui.postD = pd
	local pdT = GM.MakeFontString(pd, GM.FONT_BOLD, 11, "accent")
	pdT:SetPoint("TOPLEFT", 10, -8)
	pdT:SetText("POST")
	pd.name = GM.MakeFontString(pd, GM.FONT_BOLD, 10, "text")
	pd.name:SetPoint("TOPLEFT", 10, -28)
	pd.name:SetWidth(230)
	pd.name:SetJustifyH("LEFT")
	pd.have = GM.MakeFontString(pd, GM.FONT, 9, "textDim")
	pd.have:SetPoint("TOPLEFT", 10, -44)
	local qtyL = GM.MakeFontString(pd, GM.FONT, 9, "textDim")
	qtyL:SetPoint("TOPLEFT", 10, -66)
	qtyL:SetText("qty")
	pd.qty = EditBox(pd, 48, "")
	pd.qty:SetPoint("TOPLEFT", 34, -64)
	local prL = GM.MakeFontString(pd, GM.FONT, 9, "textDim")
	prL:SetPoint("TOPLEFT", 92, -66)
	prL:SetText("unit price")
	pd.price = EditBox(pd, 90, "")
	pd.price:SetPoint("TOPLEFT", 148, -64)
	local durL = GM.MakeFontString(pd, GM.FONT, 9, "textDim")
	durL:SetPoint("TOPLEFT", 10, -92)
	durL:SetText("duration")
	local DURS = { "12h", "24h", "48h" }
	pd.durIx = 2
	pd.dur = Btn(pd, 56, "24h", function()
		pd.durIx = pd.durIx % 3 + 1
		pd.dur.text:SetText(DURS[pd.durIx])
	end)
	pd.dur:SetSize(56, 18)
	pd.dur:SetPoint("TOPLEFT", 64, -90)
	pd.msg = GM.MakeFontString(pd, GM.FONT, 9, "textDim")
	pd.msg:SetPoint("TOPLEFT", 10, -116)
	pd.msg:SetWidth(230)
	pd.msg:SetJustifyH("LEFT")
	pd.post = Btn(pd, 70, "POST", function()
		local id = pd.itemID
		local qty = tonumber(pd.qty:GetText()) or 1
		local unit = GM.Budget
			and GM.Budget.ParseMoney(pd.price:GetText())
			or tonumber(pd.price:GetText())
		if not (id and unit and unit > 0) then
			pd.msg:SetText(GM.CC("warn") .. "need a valid price|r")
			return
		end
		GM.AH.Execute({ kind = "post", itemID = id, qty = qty,
			unit = unit, duration = pd.durIx })
		GM.After(0.3, function()
			pd.have:SetText(format("%d in bags", GM.BagCount(id) or 0))
			if (GM.BagCount(id) or 0) < 1 then pd:Hide() end
		end)
	end)
	pd.post:SetSize(70, 20)
	pd.post:SetPoint("BOTTOMRIGHT", -10, 10)
	pd.close = Btn(pd, 60, "DONE", function() pd:Hide() end)
	pd.close:SetSize(60, 20)
	pd.close:SetPoint("RIGHT", pd.post, "LEFT", -6, 0)
end

-- open the post dialog for a result item — PreviewPost fills the
-- suggested unit; qty defaults to the first stack in bags
function AU.OpenPost(id)
	Build()
	local pd = ui.postD
	pd.itemID = id
	pd.name:SetText((GM.ItemName and GM.ItemName(id)) or ("item " .. id))
	pd.name:SetTextColor(GM.NameColor(id))
	local loc, stack = GM.AH.FindInBags(id)
	pd.have:SetText(format("%d in bags%s", GM.BagCount(id) or 0,
		not loc and " (none unlocked)" or ""))
	pd.qty:SetText(tostring(stack or 1))
	local unit = GM.Auctioning and GM.Auctioning.PreviewPost
		and GM.Auctioning.PreviewPost(id)
	pd.price:SetText(unit and format("%dg", floor(unit / 10000 + 0.5)) or "")
	pd.msg:SetText(unit and ""
		or GM.CC("warn") .. "no price verdict — set one manually|r")
	pd:Show()
end

-- saved-searches dropdown — rebuilt each open so deletions vanish
function BuildSavedBox()
	if not ui.savedBox then
		local sb = CreateFrame("Frame", nil, ui.frame)
		sb:SetSize(216, 8 + 8 * 18 + 22)
		sb:SetPoint("TOPLEFT", 12, -58)
		sb:SetFrameStrata("DIALOG")
		GM.Panel(sb, "contHigh", "outlineVar")
		sb.rows = {}
		for i = 1, 8 do
			local b = Btn(sb, 168, "", nil)
			b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
			b.text:SetJustifyH("LEFT")
			b.text:SetWidth(160)
			local x = CreateFrame("Button", nil, sb)
			x:SetSize(14, 15)
			x:SetPoint("LEFT", b, "RIGHT", 4, 0)
			x.text = GM.MakeFontString(x, GM.FONT_BOLD, 10, "textDim")
			x.text:SetPoint("CENTER")
			x.text:SetText("x")
			sb.rows[i] = { b = b, x = x }
		end
		local add = Btn(sb, 120, "+ SAVE CURRENT", function()
			ui.nameBox:Show()
		end)
		add:SetSize(120, 16)
		add:SetPoint("BOTTOMLEFT", 6, 6)
		sb.empty = GM.MakeFontString(sb, GM.FONT, 9, "textDim")
		sb.empty:SetPoint("TOPLEFT", 8, -8)
		sb.empty:SetText("no saved searches")
		ui.savedBox = sb
	end
	local sb = ui.savedBox
	local list = (GM.db and GM.db.ahSearches) or {}
	sb.empty:SetShown(#list == 0)
	for i, r in ipairs(sb.rows) do
		local sv = list[i]
		if sv then
			r.b:Show() r.x:Show()
			r.b.text:SetText(sv.name or "?")
			local q, f = sv.q, sv.f
			r.b:SetScript("OnClick", function()
				ui.search:SetText(q or "")
				ui.filters = {}
				for k, v in pairs(f or {}) do ui.filters[k] = v end
				ui.scroll = 0
				sb:Hide()
				DoSearch()
			end)
			local ix = i
			r.x:SetScript("OnClick", function()
				tremove(GM.db.ahSearches, ix)
				BuildSavedBox()
			end)
		else
			r.b:Hide() r.x:Hide()
		end
	end
end

-- ============ refresh ============

function AU.Refresh()
	if not ui then return end
	local open = AHOpen()
	ui.pageTabs.set(ui.page)

	-- pane visibility: SHOP = results + listings panes; MINE = posted
	-- on top + bids underneath
	ui.lp:SetShown(ui.page == "shop")
	ui.rp:SetShown(ui.page == "shop")
	ui.fp:SetShown(ui.page == "mine")
	ui.bp:SetShown(ui.page == "mine")

	if ui.page == "shop" then
		ui.lHead:SetText(ui.lastBrowseLabel
			and strupper(ui.lastBrowseLabel) or "RESULTS")
		local rows = open and Results() or {}
		ui.lEmpty:SetText(not open and "open the auction house"
			or ui.status
			or (#rows == 0 and (ui.searchedAt
				and "no matches" or "search for an item") or ""))
		ui.lEmpty:SetShown(#rows == 0)
		local maxScroll = math.max(0, #rows - VISIBLE)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.lCount, ui.scroll, VISIBLE, #rows)
		for i = 1, VISIBLE do
			local row, r = ui.rows[i], rows[i + ui.scroll]
			if r then
				row:Show()
				row.tipID = r.id
				row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
				row.name:SetText((r.low and GM.CC("pos") .. "▶ |r" or "")
					.. (r.name or "?"))
				row.name:SetTextColor(GM.NameColor(r.id))
				row.c1:SetText(r.unit and GM.Money(r.unit) or "—")
				row.c2:SetText("×" .. (r.qty or 1)
					.. (r.mkt and " · mkt " .. GM.Money(r.mkt) or ""))
				-- POST appears when bags hold the item — opens the
				-- post dialog (qty/price/duration, one call per click)
				if r.id and (GM.BagCount(r.id) or 0) > 0 then
					row.act:Show()
					row.act.text:SetText("POST")
					row.act.text:SetTextColor(GM.RGB("accent"))
					local pid = r.id
					row.act:SetScript("OnClick", function()
						AU.OpenPost(pid)
					end)
				else
					row.act:Hide()
				end
				local sel = r
				row:SetScript("OnClick", function()
					if IsShiftKeyDown() then
						if sel.id then GM.ModifiedItemClick(sel.id) end
						return
					end
					ui.askScroll = 0
					ScanAsks(sel)
				end)
			else
				row:Hide()
			end
		end

		-- right pane: per-listing asks
		local asks = ui.asks or {}
		ui.rHead:SetText(ui.sel and ("LISTINGS — " .. (ui.sel.name or "?"))
			or "LISTINGS")
		-- commodity asks (no auctionID) get the Blizzard-style qty buy
		local isComm = asks[1] and asks[1].id == nil
		ui.qty:SetShown(isComm and true or false)
		ui.qtyLbl:SetShown(isComm and true or false)
		ui.buyN:SetShown(isComm and true or false)
		if isComm then
			local n = tonumber(ui.qty:GetText())
			local pending = ui.stagedBuy or ui.confirmAsk
			local pc = GM.AH.pendingConfirm
			ui.buyN.text:SetText(pending and (pc and pc.quote
				and ("CONFIRM " .. GM.Money(pc.quote)) or "CONFIRM")
				or ("BUY" .. (n and n > 0 and (" ×" .. n) or "")))
			ui.buyN.text:SetTextColor(GM.RGB(pending and "warn" or "accent"))
		else
			ui.stagedBuy = nil
		end
		ui.rEmpty:SetText(not open and ""
			or not ui.sel and "pick a result to list asks"
			or ui.status or (#asks == 0 and "no listings" or ""))
		ui.rEmpty:SetShown(#asks == 0)
		local askMax = math.max(0, #asks - ASK_VISIBLE)
		ui.askScroll = math.min(ui.askScroll or 0, askMax)
		W.ScrollText(ui.rCount, ui.askScroll, ASK_VISIBLE, #asks)
		-- cheapest non-own level gets the pos flag — that's the buy point
		local cheapest
		for _, a in ipairs(asks) do
			if not a.own and a.unit then cheapest = a break end
		end
		for i = 1, ASK_VISIBLE do
			local row, a = ui.askRows[i], asks[i + ui.askScroll]
			if a then
				row:Show()
				row.c1:SetText("×" .. (a.qty or 1))
				-- unit price is the comparator — lot total goes dim beside it
				row.c2:SetText(a.unit and (GM.Money(a.unit) .. "/ea") or "—")
				row.c2:SetTextColor(GM.RGB(a.own and "textDim"
					or a == cheapest and "pos"
					or (ui.sel and ui.sel.mkt and a.unit and a.unit < ui.sel.mkt * 0.9)
						and "pos" or "accent"))
				local lot = a.total or (a.unit or 0) * (a.qty or 1)
				row.c3:SetText((a.id and "lot " or "tot ") .. GM.Money(lot)
					.. (a.own and " · yours"
						or a.seller and (" · " .. a.seller)
						or (a.id and "" or " · comm")))
				row.act:Show()
				local confirming = ui.confirmAsk == a
				row.act.text:SetText(a.own and "OWN"
					or confirming and "CONFIRM" or "BUY")
				row.act.text:SetTextColor(GM.RGB(a.own and "textDim"
					or confirming and "warn" or "accent"))
				local ask = a
				row.act:SetScript("OnClick", function()
					if confirming then
						local pc = GM.AH.pendingConfirm
						if pc and ui.sel and pc.itemID == ui.sel.id then
							GM.AH.Execute({ kind = "confirm" })
						else
							ui.status = "staged quote was replaced — stage the buy again"
						end
						ui.confirmAsk = nil
						AU.Refresh()
					else
						BuyAsk(ask)
					end
				end)
			else
				row:Hide()
			end
		end
		ui.foot:SetText("one protected call per click · item BUY = lot buyout · "
			.. "commodity BUY stages a quote → CONFIRM")
	else
		-- MINE page: posted auctions on top, our bids underneath
		local rows = open and GM.Inventory.MineRows() or {}
		ui.fEmpty:SetText(not open and "open the auction house"
			or (#rows == 0 and "no auctions up" or ""))
		ui.fEmpty:SetShown(#rows == 0)
		local maxScroll = math.max(0, #rows - #ui.mRows)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.mCount, ui.scroll, #ui.mRows, #rows)
		local uc = 0
		for _, r in ipairs(rows) do uc = uc + (r.undercut and 1 or 0) end
		for i = 1, #ui.mRows do
			local row, r = ui.mRows[i], rows[i + ui.scroll]
			if r then
				row:Show()
				row.tipID = r.id
				row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
				row.name:SetText(r.name or "?")
				row.name:SetTextColor(GM.NameColor(r.id))
				row.qty:SetText("×" .. (r.qty or 1))
				row.unit:SetText(r.unit and GM.Money(r.unit) .. "/ea" or "—")
				row.lot:SetText(r.unit and GM.Money(r.unit * (r.qty or 1)) or "—")
				row.mkt:SetText(r.mkt and (GM.Money(r.mkt) .. "/ea") or "no market")
				if r.undercut then
					row.stat:SetText(GM.CC("warn") .. "UNDERCUT|r"
						.. (r.cheap and (" @ " .. GM.Money(r.cheap)) or ""))
				elseif r.cheap == nil then
					row.stat:SetText(GM.CC("textDim") .. "no book data|r")
				else
					row.stat:SetText(GM.CC("pos") .. "lowest|r")
				end
				local tl = r.tLeft
				row.time:SetText(tl and (tl >= 3600
					and format("%dh%02dm", floor(tl / 3600), floor(tl % 3600 / 60))
					or tl >= 60 and format("%dm", floor(tl / 60))
					or "<1m") or "—")
				local aid = r.aid
				row.act:SetScript("OnClick", function()
					GM.AH.Execute({ kind = "cancel", auctionID = aid })
					AU.Refresh()
				end)
				row:SetScript("OnClick", function()
					if not r.id then return end
					if IsShiftKeyDown() then GM.ModifiedItemClick(r.id)
					else GM.TargetItem(r.id) end
				end)
			else
				row:Hide()
			end
		end
		-- bids pane: outbid rows sort first, REBID = current + 1c
		local bids = open and GM.Inventory.BidRows() or {}
		ui.bEmpty:SetText(not open and ""
			or (#bids == 0 and "no bids placed this session" or ""))
		ui.bEmpty:SetShown(#bids == 0)
		local bMax = math.max(0, #bids - #ui.bRows)
		ui.bidScroll = math.min(ui.bidScroll or 0, bMax)
		W.ScrollText(ui.bCount, ui.bidScroll, #ui.bRows, #bids)
		for i = 1, #ui.bRows do
			local row, r = ui.bRows[i], bids[i + ui.bidScroll]
			if r then
				row:Show()
				row.tipID = r.id
				row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
				row.name:SetText(r.name or "?")
				row.name:SetTextColor(GM.NameColor(r.id))
				row.our:SetText(r.ourBid and GM.Money(r.ourBid) or "—")
				row.cur:SetText(r.curBid and GM.Money(r.curBid) or "—")
				row.bo:SetText(r.buyout and GM.Money(r.buyout) or "—")
				local tl = r.remain
				row.time:SetText(tl and tl > 0 and (tl >= 3600
					and format("%dh%02dm", floor(tl / 3600), floor(tl % 3600 / 60))
					or tl >= 60 and format("%dm", floor(tl / 60))
					or "<1m") or "—")
				local st = r.status
				row.stat:SetText(st == "outbid"
					and (GM.CC("warn") .. "OUTBID|r")
					or st == "won" and (GM.CC("pos") .. "won|r")
					or st == "lost" and (GM.CC("textDim") .. "lost|r")
					or (GM.CC("pos") .. "winning|r"))
				local aid, id, cur = r.aid, r.id, r.curBid
				if st == "outbid" and cur then
					row.act:Show()
					row.act:SetScript("OnClick", function()
						GM.AH.Execute({ kind = "bid", itemID = id,
							auctionID = aid, total = cur + 1 })
						GM.After(0.5, AU.Refresh)
					end)
				else
					row.act:Hide()
				end
				row:SetScript("OnClick", function()
					if not r.id then return end
					if IsShiftKeyDown() then GM.ModifiedItemClick(r.id)
					else GM.TargetItem(r.id) end
				end)
			else
				row:Hide()
			end
		end
		ui.foot:SetText(format("%d auction%s%s — cancels are one click each · "
			.. "undercuts sort first (book mbx < your price)",
			#rows, #rows == 1 and "" or "s",
			uc > 0 and format(" · %s%d undercut|r", GM.CC("warn"), uc) or ""))
	end
	-- scan progress mirrors into the footer on both pages — live while
	-- a scan is moving, then the completion line for ~15s (it arrives
	-- after the busy flag drops, so gating on busy alone never shows it)
	if ui.scanMsg and (ScanBusy()
		or (ui.scanAt and time() - ui.scanAt < 15)) then
		ui.foot:SetText(ui.scanMsg)
	end
end

-- progress fan-out: book/post/cancel scans all report through the
-- planner's status line — mirror each message so the AH window's
-- footer (and the empty results pane) shows the same live text
do
	local pqStatus = GM.PlanQueue.ScanStatus
	function GM.PlanQueue.ScanStatus(msg)
		if pqStatus then pqStatus(msg) end
		ui.scanMsg = msg
		ui.scanAt = time()
		-- revert the footer to its hints once the freshness window
		-- lapses — one armed timer per burst, not per message
		if not ui.scanRevert then
			ui.scanRevert = true
			GM.After(15, function()
				ui.scanRevert = nil
				if ui.frame and ui.frame:IsShown() then AU.Refresh() end
			end)
		end
		if ui.frame and ui.frame:IsShown() then AU.Refresh() end
	end
end

-- ============ takeover ============

local function EnsureSwitchBtn()
	if not (AuctionHouseFrame and ui and not ui.switchBtn) then return end
	local b = CreateFrame("Button", nil, AuctionHouseFrame)
	b:SetSize(84, 16)
	b:SetPoint("TOPRIGHT", AuctionHouseFrame, "TOPRIGHT", -40, -8)
	b:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 20)
	GM.Panel(b, "accent")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "contLowest")
	b.text:SetPoint("CENTER")
	b.text:SetText("GOBLINMIND")
	b:SetScript("OnClick", function()
		ui.wantDefault = nil
		AU.OnAHOpen()
	end)
	ui.switchBtn = b
	AuctionHouseFrame:HookScript("OnShow", function()
		if not ui.wantDefault then GM.FramePark.Park(AuctionHouseFrame) end
	end)
end

function AU.OnAHOpen()
	Build()
	EnsureSwitchBtn()
	if ui.wantDefault then return end
	ui.frame:Show()
	GM.Inventory.QueryOwned()
	GM.Inventory.QueryBids()
	AU.Refresh()
	-- the panel manager may still be positioning it; park now + retry
	GM.FramePark.Park(AuctionHouseFrame)
	GM.After(0.3, function() GM.FramePark.Park(AuctionHouseFrame) end)
end

function AU.Show()
	Build()
	ui.frame:Show()
	AU.Refresh()
end

function AU.Hide()
	if ui then ui.frame:Hide() end
end

function AU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else AU.Show() end
end

-- repaint when item names/icons resolve asynchronously
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then AU.Refresh() end
	end)
end

-- repaint the MINE page as the owned-auction cache updates
local baseRefreshOwned = GM.Inventory.RefreshOwned
function GM.Inventory.RefreshOwned(...)
	baseRefreshOwned(...)
	if ui and ui.frame and ui.frame:IsShown() then AU.Refresh() end
end
-- same for the bids half — RefreshBids runs on timers/events too
local baseRefreshBids = GM.Inventory.RefreshBids
function GM.Inventory.RefreshBids(...)
	baseRefreshBids(...)
	if ui and ui.frame and ui.frame:IsShown() then AU.Refresh() end
end

-- AH session drives the takeover (AH.lua's own frame owns GM.AH.open)
local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "AUCTION_HOUSE_SHOW")
pcall(f.RegisterEvent, f, "AUCTION_HOUSE_CLOSED")
f:SetScript("OnEvent", function(_, e)
	if e == "AUCTION_HOUSE_SHOW" then
		AU.OnAHOpen()
	elseif ui and ui.frame then
		ui.frame:Hide()
	end
end)

-- shift-click an item with our AH window open → fill the search box
-- and run it (Blizzard/TSM behavior). Same two hooks TSM's
-- Item.HookLink uses — bag/button clicks go through
-- HandleModifiedItemClick, chat links through ChatEdit_InsertLink.
-- Runs AFTER the originals: a focused chat editbox keeps its
-- insert-link priority; if TSM consumed the click for its own UI it
-- wins too. Returns true to consume only when we actually searched.
local function LinkHook(link)
	if not (ui and ui.frame and ui.frame:IsShown()) then return false end
	if not IsShiftKeyDown() then return false end
	local id = link and tonumber(link:match("item:(%d+)"))
	if not id then return false end
	local name = GM.ItemName(id) or link:match("%[(.-)%]")
	if not name then return false end
	ui.page = "shop"
	ui.search:SetText(name)
	ui.search:SetTextColor(GM.RGB("text"))
	ui.scroll = 0
	DoSearch()
	return true -- consumed — don't drop the link into chat
end

if type(HandleModifiedItemClick) == "function" then
	local orig = HandleModifiedItemClick
	HandleModifiedItemClick = function(link, ...)
		return orig(link, ...) or LinkHook(link)
	end
end
if type(ChatEdit_InsertLink) == "function" then
	local orig = ChatEdit_InsertLink
	ChatEdit_InsertLink = function(link, ...)
		return orig(link, ...) or LinkHook(link)
	end
end
