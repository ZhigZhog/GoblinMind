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

local function AHOpen()
	return C_AuctionHouse and GM.AH.open
end

local SEARCH_SORTS = Enum and Enum.AuctionHouseSortOrder and {
	{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
	{ sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
} or nil

-- name search → per-itemKey aggregates {itemKey, minPrice, totalQuantity}
local function DoSearch()
	local q = strtrim(ui.search:GetText() or "")
	if q == "" or q == "search…" then return end
	if not (C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.GetBrowseResults) then
		ui.status = "browse query unavailable on this client"
		AU.Refresh()
		return
	end
	ui.results = nil
	ui.searchedAt = time()
	ui.status = "searching…"
	local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, {
		searchString = q, sorts = SEARCH_SORTS,
		filters = {}, itemClassFilters = {},
	})
	ui.status = ok and "waiting for results…" or ("query error: " .. tostring(err))
	AU.Refresh()
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
		ui.status = "book scan in progress…"
		return rows
	end
	if not ui.searchedAt then return rows end
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
		if id then
			local e = GM.ItemEntry(id)
			local mkt = (e and e.p) or GM.TSMMarket and GM.TSMMarket(id)
			rows[#rows + 1] = {
				id = id, name = GM.ItemName(id) or ("item " .. id),
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

-- owned auctions with the full rundown: lot total, market ref, time
-- left, and the undercut flag CancelScan uses (book mbx < our unit).
-- Undercut rows sort to the top — they're the ones to cancel.
local function MineRows()
	local rows = {}
	for aid, a in pairs(GM.Inventory.auctions or {}) do
		if a.itemID then
			local e = GM.ItemEntry(a.itemID)
			local mkt = (e and e.p) or GM.TSMMarket and GM.TSMMarket(a.itemID)
			local cheap = GM.AH.BookCheapest
				and GM.AH.BookCheapest(a.itemID)
			local undercut = cheap and a.buyout and cheap < a.buyout or nil
			rows[#rows + 1] = {
				aid = aid, id = a.itemID, qty = a.qty or 1,
				unit = a.buyout, tLeft = a.tLeft,
				mkt = mkt, cheap = cheap, undercut = undercut,
				name = GM.ItemName(a.itemID) or ("item " .. a.itemID),
			}
		end
	end
	sort(rows, function(a, b)
		if a.undercut ~= b.undercut then return a.undercut and true or false end
		return (a.name or "") < (b.name or "")
	end)
	return rows
end

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
	end)
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
	f:SetSize(720, 470)
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
	-- browse results + owned-auction changes → repaint
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
	pcall(f.RegisterEvent, f, "BAG_UPDATE")
	f:SetScript("OnEvent", function()
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
	lp:SetSize(336, VISIBLE * ROW_H + 30)
	lp:SetPoint("TOPLEFT", 12, -62)
	GM.Panel(lp, "contLowest")
	ui.lp = lp
	ui.lHead = GM.MakeFontString(lp, GM.FONT_BOLD, 9, "secondary")
	ui.lHead:SetPoint("TOPLEFT", 8, -6)
	ui.lCount = GM.MakeFontString(lp, GM.FONT, 9, "textDim")
	ui.lCount:SetPoint("TOPRIGHT", -8, -7)
	lp:EnableMouseWheel(true)
	lp:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		AU.Refresh()
	end)
	ui.rows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, lp)
		row:SetSize(320, ROW_H - 2)
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
		row.c2:SetPoint("LEFT", 230, 0)
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

	-- full-width MINE pane: the owned-auctions rundown spans the whole
	-- window — the narrow SHOP columns couldn't carry the full row
	local fp = CreateFrame("Frame", nil, f)
	fp:SetSize(696, VISIBLE * ROW_H + 30)
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
		{ "MARKET", 420 }, { "STATUS", 500 }, { "TIME", 590 },
	}) do
		local fs = GM.MakeFontString(fp, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("TOPLEFT", h[2], -6)
		fs:SetText(h[1])
		ui.mHead[i] = fs
	end
	ui.mCount = GM.MakeFontString(fp, GM.FONT, 9, "textDim")
	ui.mCount:SetPoint("TOPRIGHT", -8, -7)
	ui.mRows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, fp)
		row:SetSize(680, ROW_H - 2)
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
		row.time = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.time:SetPoint("LEFT", 590, 0)
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

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
end

-- ============ refresh ============

function AU.Refresh()
	if not ui then return end
	local open = AHOpen()
	ui.pageTabs.set(ui.page)

	-- pane visibility: SHOP = results + listings panes; MINE = the
	-- full-width rundown
	ui.lp:SetShown(ui.page == "shop")
	ui.rp:SetShown(ui.page == "shop")
	ui.fp:SetShown(ui.page == "mine")

	if ui.page == "shop" then
		ui.lHead:SetText("RESULTS — click to list asks")
		local rows = open and Results() or {}
		ui.lEmpty:SetText(not open and "open the auction house"
			or ui.status or (#rows == 0 and "search for an item" or ""))
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
				row.name:SetText((r.low and GM.CC("pos") .. "▸ |r" or "")
					.. (r.name or "?"))
				row.c1:SetText(r.unit and GM.Money(r.unit) or "—")
				row.c2:SetText("×" .. (r.qty or 1)
					.. (r.mkt and " · mkt " .. GM.Money(r.mkt) or ""))
				row.act:Hide()
				local sel = r
				row:SetScript("OnClick", function()
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
		-- MINE page: full-width owned-auction rundown, cancel per row
		local rows = open and MineRows() or {}
		ui.fEmpty:SetText(not open and "open the auction house"
			or (#rows == 0 and "no auctions up" or ""))
		ui.fEmpty:SetShown(#rows == 0)
		local maxScroll = math.max(0, #rows - VISIBLE)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.mCount, ui.scroll, VISIBLE, #rows)
		local uc = 0
		for _, r in ipairs(rows) do uc = uc + (r.undercut and 1 or 0) end
		for i = 1, VISIBLE do
			local row, r = ui.mRows[i], rows[i + ui.scroll]
			if r then
				row:Show()
				row.tipID = r.id
				row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
				row.name:SetText(r.name or "?")
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
					if r.id then GM.TargetItem(r.id) end
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
