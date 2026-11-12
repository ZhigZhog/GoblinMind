local _, GM = ...

-- Part 6a: the market window. SHOP mode lists the targeted item's asks
-- (unit price, % of market, seller, own rows dimmed); SNIPER mode lists
-- Sniper.lua's under-threshold hits. Every buy is one protected call
-- per click: items buy via PlaceBid, commodities via the staged
-- quote→CONFIRM flow — the same executor the plan queue uses.

GM.Shopping = { mode = "shop", asks = nil, itemID = nil }
local S = GM.Shopping
local ui
local ROWS = 14
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

-- ============ window ============

local function BuildRow(parent, i)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(24)
	row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 24)
	row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 24)
	GM.Panel(row, i % 2 == 0 and "contLow" or "contLowest", "contLowest")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("LEFT", 4, 0)
	row.name   = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.name:SetPoint("LEFT", 26, 0)
	row.name:SetWidth(150)
	row.qty    = GM.MakeFontString(row, GM.FONT, 10, "textDim")
	row.qty:SetPoint("LEFT", 182, 0)
	row.unit   = GM.MakeFontString(row, GM.FONT_MED, 10, "text")
	row.unit:SetPoint("LEFT", 240, 0)
	row.pct    = GM.MakeFontString(row, GM.FONT_MED, 10, "textDim")
	row.pct:SetPoint("LEFT", 320, 0)
	row.seller = GM.MakeFontString(row, GM.FONT, 10, "textDim")
	row.seller:SetPoint("LEFT", 382, 0)
	row.seller:SetWidth(84)
	row.buy = CreateFrame("Button", nil, row)
	row.buy:SetSize(60, 18)
	row.buy:SetPoint("RIGHT", -6, 0)
	GM.Panel(row.buy, "contHigh")
	row.buy.text = GM.MakeFontString(row.buy, GM.FONT_MED, 9, "textDim")
	row.buy.text:SetAllPoints()
	row.buy:SetScript("OnClick", function() S.BuyRow(row) end)
	row.buy:SetScript("OnEnter", function() GM.Panel(row.buy, "contHighest") end)
	row.buy:SetScript("OnLeave", function() GM.Panel(row.buy, "contHigh") end)
	return row
end

local function Build()
	if ui then return end
	ui = {}
	local f = CreateFrame("Frame", "GoblinMindMarketUI", UIParent)
	f:SetSize(560, 420)
	f:SetPoint("CENTER", 100, 0)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetScript("OnMouseDown", function(fr)
		if fr.Raise then fr:Raise() elseif RaiseFrame then RaiseFrame(fr) end
	end)
	GM.Panel(f, "contLow", "outlineVar")
	tinsert(UISpecialFrames, "GoblinMindMarketUI")
	f:Hide()
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 14, -10)
	title:SetText("GOBLINMIND MARKET")

	local close = CreateFrame("Button", nil, f)
	close:SetSize(18, 18)
	close:SetPoint("TOPRIGHT", -8, -8)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetAllPoints()
	close.text:SetText("×")
	close:SetScript("OnClick", function() f:Hide() end)

	-- mode + action buttons ride the title row
	local function TitleBtn(label, w, onclick)
		local b = CreateFrame("Button", nil, f)
		b:SetSize(w, 16)
		GM.Panel(b, "contMedium")
		b.text = GM.MakeFontString(b, GM.FONT_MED, 9, "secondary")
		b.text:SetAllPoints()
		b.text:SetText(label)
		b:SetScript("OnClick", onclick)
		return b
	end
	ui.shopBtn = TitleBtn("SHOP", 52, function() S.SetMode("shop") end)
	ui.shopBtn:SetPoint("LEFT", title, "RIGHT", 12, -1)
	ui.snipeBtn = TitleBtn("SNIPER", 60, function() S.SetMode("sniper") end)
	ui.snipeBtn:SetPoint("LEFT", ui.shopBtn, "RIGHT", 6, 0)
	ui.action = TitleBtn("SCAN", 80, function() S.Action() end)
	ui.action:SetPoint("TOPRIGHT", close, "TOPLEFT", -8, 1)

	ui.status = GM.MakeFontString(f, GM.FONT, 10, "textDim")
	ui.status:SetPoint("TOPLEFT", 14, -34)

	local header = CreateFrame("Frame", nil, f)
	header:SetPoint("TOPLEFT", 10, -52)
	header:SetPoint("TOPRIGHT", -10, -52)
	header:SetHeight(18)
	GM.Panel(header, "contHigh")
	for _, h in ipairs({
		{ "ITEM", "LEFT", 8 }, { "QTY", "LEFT", 182 }, { "UNIT", "LEFT", 240 },
		{ "%MKT", "LEFT", 320 }, { "SELLER", "LEFT", 382 },
	}) do
		local fs = GM.MakeFontString(header, GM.FONT_MED, 9, "secondary")
		fs:SetPoint(h[2], h[3], 0)
		fs:SetText(h[1])
	end

	ui.list = CreateFrame("Frame", nil, f)
	ui.list:SetPoint("TOPLEFT", 10, -72)
	ui.list:SetPoint("TOPRIGHT", -10, -72)
	ui.list:SetHeight(ROWS * 24 + 8)
	GM.Panel(ui.list, "contLowest")
	ui.rows = {}
	for i = 1, ROWS do ui.rows[i] = BuildRow(ui.list, i) end

	local foot = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	foot:SetPoint("BOTTOMLEFT", 12, 8)
	foot:SetText("one protected call per click · items = PlaceBid · commodities = quote → CONFIRM")
end

-- names/icons resolve asynchronously — re-render rows when item data
-- finishes loading into the cache
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then S.Refresh() end
	end)
end

-- ============ public surface ============

function S.Toggle()
	Build()
	ui.frame:SetShown(not ui.frame:IsShown())
	S.Refresh()
end

function S.Show()
	Build()
	ui.frame:Show()
	S.Refresh()
end

function S.Status(text)
	if ui then ui.status:SetText(text) end
end

function S.SniperOpen()
	return ui and ui.mode == "sniper" and ui.frame:IsShown()
end

function S.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function S.SetMode(mode)
	ui.mode = mode
	if mode == "sniper" then GM.Sniper.StartAuto() end
	S.Refresh()
end

function S.Action()
	if ui.mode == "sniper" then
		GM.Sniper.Scan()
	else
		S.ShopScan()
	end
end

-- ============ shop scan ============

function S.ShopScan()
	local id = GM.PlanQueue.itemID
	if not id then
		S.Status(GM.CC("warn") .. "target an item first — /goblin [item]|r")
		return
	end
	if not GM.AH.open then
		S.Status(GM.CC("warn") .. "auction house is not open|r")
		return
	end
	S.itemID = id
	S.Status(GM.CC("textDim") .. "scanning " .. (GetInfo(id) or id) .. "…|r")
	GM.Auctioning.QueueScan(id, function(asks)
		for _, a in ipairs(asks) do a.itemID = id end
		S.asks = asks
		S.Status("")
		S.Refresh()
	end)
end

-- ============ buying (one protected call per click) ============

function S.BuyRow(row)
	local d = row.data
	if not d then return end
	-- a staged quote for this item is live → this click is the confirm
	local pc = GM.AH.pendingConfirm
	if pc and pc.itemID == d.itemID then
		GM.AH.Execute({ kind = "confirm" })
		return
	end
	if d.hit then
		S.BuyHit(d)
		return
	end
	if d.id then
		GM.AH.Execute({ kind = "buy", itemID = d.itemID, qty = d.qty,
			unit = d.unit, total = d.total, auctionID = d.id })
	else
		GM.AH.Execute({ kind = "buy", itemID = d.itemID, qty = d.qty,
			unit = d.unit, commodity = true })
	end
end

-- sniper hit: click 1 re-queries the item's book; click 2 buys the
-- matching listing — the two clicks keep purchases hardware-driven
function S.BuyHit(h)
	if h.state == "ready" and h.live then
		if h.live.id then
			GM.AH.Execute({ kind = "buy", itemID = h.itemID, qty = h.live.qty,
				unit = h.live.unit, total = h.live.total, auctionID = h.live.id })
		else
			GM.AH.Execute({ kind = "buy", itemID = h.itemID, qty = h.qty,
				unit = h.live.unit, commodity = true })
		end
		h.done = true
		h.state = nil
		S.Refresh()
		return
	end
	if h.state then return end -- already scanning
	h.state = "scanning"
	S.Refresh()
	GM.Auctioning.QueueScan(h.itemID, function(asks)
		h.state = nil
		local cheapest
		for _, a in ipairs(asks) do
			if not a.own then cheapest = a break end
		end
		if cheapest and cheapest.unit <= ceil(h.unit * 1.02) then
			h.live = { id = cheapest.id, qty = cheapest.qty,
				unit = cheapest.unit, total = cheapest.total or cheapest.unit * cheapest.qty }
			h.state = "ready"
		else
			GM.Print(format("sniper: %s gone — cheapest now %s",
				h.name, GM.Money(cheapest and cheapest.unit or 0)))
			h.done = true
		end
		S.Refresh()
	end)
end

-- ============ refresh ============

function S.Refresh()
	if not ui then return end
	GM.Panel(ui.shopBtn, ui.mode == "shop" and "accent" or "contMedium")
	GM.Panel(ui.snipeBtn, ui.mode == "sniper" and "accent" or "contMedium")
	ui.action.text:SetText(ui.mode == "sniper" and "SNAPSHOT" or "SCAN")
	ui.action:SetEnabled(GM.AH.open)

	local pc = GM.AH.pendingConfirm
	if ui.mode == "shop" then
		local e = S.itemID and GM.ItemEntry(S.itemID)
		local m = (e and (e.mkt or e.p)) or (S.itemID and GM.TSMMarket(S.itemID))
		local cap = S.itemID and GM.Groups.EvalOp(
			GM.Groups.GetOps(S.itemID, "shopping"), "maxPrice", S.itemID)
		local asks = S.asks or {}
		if #asks == 0 then
			S.Status(GM.CC("textDim") .. (S.itemID and "book is empty" or
				"SHOP — SCAN the targeted item's book|r"))
		end
		for i = 1, ROWS do
			local row, a = ui.rows[i], asks[i]
			if a then
				row:Show()
				row.data = a
				local ic = GM.ItemIcon and GM.ItemIcon(a.itemID)
				if ic then row.icon:SetTexture(ic); row.icon:Show() else row.icon:Hide() end
				row.name:SetText(((GM.ItemName and GM.ItemName(a.itemID)) or ("item " .. a.itemID)) .. (a.own and " (yours)" or ""))
				row.qty:SetText("×" .. a.qty)
				row.unit:SetText(GM.Money(a.unit))
				row.pct:SetText(a.pct and "" or (m and format("%.0f%%", a.unit / m * 100) or "—"))
				if cap and a.unit <= cap then
					row.pct:SetTextColor(GM.RGB("pos"))
				else
					row.pct:SetTextColor(GM.RGB("textDim"))
				end
				row.seller:SetText(a.own and "you" or (a.seller or "—"))
				row.buy.text:SetText(pc and pc.itemID == a.itemID and "CONFIRM" or "BUY")
				row.buy:SetEnabled(GM.AH.open and not a.own)
			else
				row:Hide()
			end
		end
	else
		local hits = GM.Sniper.hits
		if #hits == 0 then
			S.Status(GM.CC("textDim") .. "SNIPER — SNAPSHOT diffs the full book for under-priced listings|r")
		end
		for i = 1, ROWS do
			local row, h = ui.rows[i], hits[i]
			if h then
				row:Show()
				row.data = h
				local ic = GM.ItemIcon and GM.ItemIcon(h.itemID)
				if ic then row.icon:SetTexture(ic); row.icon:Show() else row.icon:Hide() end
				-- h.name may be the "item N" fallback from collection
				-- time — re-resolve so async-loaded names land too
				local nm = (h.name and not h.name:match("^item %d+$")) and h.name
					or (GM.ItemName and GM.ItemName(h.itemID))
				row.name:SetText(nm or ("item " .. h.itemID))
				row.qty:SetText("×" .. h.qty)
				row.unit:SetText(GM.Money(h.unit))
				row.pct:SetText(h.pct and format("%.0f%%", h.pct) or "—")
				row.pct:SetTextColor(GM.RGB("pos"))
				row.seller:SetText("")
				row.buy.text:SetText(h.state == "scanning" and "…"
					or h.state == "ready" and "BUY" or "SCAN")
				row.buy:SetEnabled(GM.AH.open and h.state ~= "scanning")
			else
				row:Hide()
			end
		end
	end
end
