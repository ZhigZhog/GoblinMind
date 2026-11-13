local _, GM = ...

-- Part 6a: the market window. SHOP mode lists the targeted item's asks
-- (unit price, % of market, seller, own rows dimmed); SNIPER mode lists
-- Sniper.lua's under-threshold hits. Every buy is one protected call
-- per click: items buy via PlaceBid, commodities via the staged
-- quote→CONFIRM flow — the same executor the plan queue uses.

GM.Shopping = { mode = "shop", asks = nil, itemID = nil, expanded = {} }
local S = GM.Shopping
local ui
local ROWS = 13 -- 14 rows ended 4px from the frame bottom and clipped the footer
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
	row.arrow  = GM.MakeFontString(row, GM.FONT_MED, 10, "textDim")
	row.arrow:SetPoint("LEFT", 6, 0)
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
	row.seller:SetWidth(190)
	row.buy = CreateFrame("Button", nil, row)
	row.buy:SetSize(60, 18)
	row.buy:SetPoint("RIGHT", -6, 0)
	GM.Panel(row.buy, "contHigh")
	row.buy.text = GM.MakeFontString(row.buy, GM.FONT_MED, 9, "textDim")
	row.buy.text:SetAllPoints()
	row.buy:SetScript("OnClick", function() S.BuyRow(row) end)
	row.buy:SetScript("OnEnter", function() GM.Panel(row.buy, "contHighest") end)
	row.buy:SetScript("OnLeave", function() GM.Panel(row.buy, "contHigh") end)
	-- row hover → native item tooltip + our price context; the buy
	-- button forwards it too so coverage is seamless
	row:EnableMouse(true)
	local function ShowTip()
		local d = row.data
		if not d or not d.itemID or not GameTooltip then return end
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(d.itemID)
		local e = GM.ItemEntry(d.itemID)
		local m = e and (e.mkt or e.p) or GM.TSMMarket(d.itemID)
		if m and d.unit then
			local pct = d.unit / m * 100
			GameTooltip:AddLine(format("unit %s · %s of ref %s (%d%%)",
				GM.Money(d.unit), GM.CC(pct <= 100 and "pos" or "err"),
				GM.Money(m), pct), 1, 1, 1)
		end
		if d.own then GameTooltip:AddLine("your auction", 0.5, 0.8, 0.4) end
		if d.mats then
			GameTooltip:AddLine("mats (bags+bank):", 0.9, 0.9, 0.8)
			for _, m in ipairs(d.mats) do
				local have = GM.Crafting.Owned(m.id)
				local p = GM.Crafting.MatPrice(m.id)
				GameTooltip:AddLine(format("  %s ×%d — have %d @ %s",
					(GM.ItemName and GM.ItemName(m.id)) or ("item " .. m.id),
					m.qty, have, p and GM.Money(p) or "?"),
					have >= m.qty and 0.5 or 1,
					have >= m.qty and 0.9 or 0.6,
					have >= m.qty and 0.5 or 0.5)
			end
			if d.suggest and d.suggest > 0 then
				GameTooltip:AddLine(format("suggested craft ×%d", d.suggest),
					0.5, 0.9, 0.5)
			end
		end
		GameTooltip:Show()
	end
	local function HideTip()
		if GameTooltip then GameTooltip:Hide() end
	end
	row:SetScript("OnEnter", ShowTip)
	row:SetScript("OnLeave", HideTip)
	-- header rows collapse/expand their group on click; child rows
	-- keep mouse free for the buy button and tooltip only
	row:SetScript("OnMouseUp", function()
		local d = row.data
		if d and d.header then
			S.expanded[d.itemID] = not d.open
			S.Refresh()
		end
	end)
	row.buy:SetScript("OnEnter", function()
		GM.Panel(row.buy, "contHighest")
		ShowTip()
	end)
	row.buy:SetScript("OnLeave", function()
		GM.Panel(row.buy, "contHigh")
		HideTip()
	end)
	return row
end

local function Build()
	if ui then return end
	ui = {}
	local f = CreateFrame("Frame", "GoblinMindMarketUI", UIParent)
	f:SetSize(680, 420)
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
	ui.craftBtn = TitleBtn("CRAFT", 52, function() S.SetMode("craft") end)
	ui.craftBtn:SetPoint("LEFT", ui.snipeBtn, "RIGHT", 6, 0)
	-- module tabs ride AFTER the mode buttons — the title's RIGHT edge
	-- is where the mode strip starts, not free space
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, ui.craftBtn, "market")
	end
	-- primary action lives at the bottom-right — the title row is
	-- title + mode buttons + module tabs, no room for it up there
	ui.action = TitleBtn("SCAN", 80, function() S.Action() end)
	ui.action:SetPoint("BOTTOMRIGHT", -10, 6)

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
		local fs = GM.MakeFontString(header, GM.FONT_MED, 10, "primary")
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

-- QUEUE on a recipe row → plan steps (buy missing mats, manual craft)
function S.QueueRow(row)
	local d = row.data
	if d and d.recipeID then
		GM.Crafting.Queue(d.recipeID, d.suggest or 1)
		GM.PlanQueue.Show()
	end
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
	if not d or d.header then return end
	if d.recipeID then S.QueueRow(row) return end
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
	GM.Panel(ui.craftBtn, ui.mode == "craft" and "accent" or "contMedium")
	ui.action.text:SetText(ui.mode == "sniper" and "SNAPSHOT" or "SCAN")
	ui.action:SetEnabled(GM.AH.open and ui.mode ~= "craft")

	local pc = GM.AH.pendingConfirm
	-- ============ tree display: group into item headers + children ============
	-- entries: { header=true, itemID, count, totalQty, cheapest, ownCount,
	--            name, m, cap } or { child=true, d = ask-or-hit }
	local display = {}
	local function PushGroup(list, getID)
		if #list == 0 then return end
		local order, groups = {}, {}
		for _, e in ipairs(list) do
			local id = getID(e)
			local g = groups[id]
			if not g then
				g = { itemID = id, items = {}, totalQty = 0, count = 0,
					cheapest = math.huge, ownCount = 0 }
				groups[id] = g
				tinsert(order, g)
			end
			tinsert(g.items, e)
			g.count = g.count + 1
			g.totalQty = g.totalQty + (e.qty or 1)
			g.cheapest = math.min(g.cheapest, e.unit or math.huge)
			if e.own then g.ownCount = g.ownCount + 1 end
		end
		for _, g in ipairs(order) do
			local open = S.expanded[g.itemID]
			if open == nil then open = true end -- groups start expanded
			tinsert(display, { header = true, g = g, open = open })
			if open then
				for _, e in ipairs(g.items) do
					tinsert(display, { child = true, d = e })
				end
			end
		end
	end

	if ui.mode == "shop" then
		local asks = S.asks or {}
		if #asks == 0 then
			S.Status(GM.CC("textDim") .. (S.itemID and "book is empty" or
				"SHOP — SCAN the targeted item's book|r"))
		end
		PushGroup(asks, function(a) return a.itemID end)
	elseif ui.mode == "sniper" then
		local hits = GM.Sniper.hits
		if #hits == 0 then
			S.Status(GM.CC("textDim") .. "SNIPER — SNAPSHOT diffs the full book for under-priced listings|r")
		end
		PushGroup(hits, function(h) return h.itemID end)
	else
		-- CRAFT mode: flat recipe rows sorted by profit
		local recs = GM.Crafting and GM.Crafting.List() or {}
		if #recs == 0 then
			S.Status(GM.CC("textDim") .. "CRAFT — open a profession to capture its recipes|r")
		end
		for _, r in ipairs(recs) do tinsert(display, { craft = r }) end
	end

	for i = 1, ROWS do
		local row, e = ui.rows[i], display[i]
		if not e then
			row:Hide()
		elseif e.craft then
			local r = e.craft
			row:Show()
			row.data = { recipeID = r.recipeID, itemID = r.itemID,
				mats = r.mats, suggest = r.suggest }
			local ic = GM.ItemIcon and GM.ItemIcon(r.itemID)
			if ic then row.icon:SetTexture(ic); row.icon:Show() else row.icon:Hide() end
			row.arrow:SetText("")
			row.name:SetPoint("LEFT", 26, 0)
			row.name:SetText(((GM.ItemName and GM.ItemName(r.itemID)) or r.name or "?"))
			-- profitable + mats on hand = the actionable rows
			row.name:SetTextColor(GM.RGB(
				r.profit and r.profit > 0 and (r.craftable > 0 and "accent" or "pos")
				or r.profit and "err" or "textDim"))
			row.qty:SetText(r.craftable and r.craftable > 0 and ("×" .. r.craftable) or "")
			row.qty:SetTextColor(GM.RGB(r.craftable and r.craftable > 0 and "accent" or "textDim"))
			row.unit:SetText(r.cost and GM.Money(r.cost) or "—")
			row.pct:SetText(r.profit and format("%s %s%d%%|r",
				GM.Money(r.profit), GM.CC("textDim"),
				r.price and r.price > 0 and floor(r.profit / r.price * 100 + 0.5) or 0) or "—")
			row.pct:SetTextColor(GM.RGB(r.profit and (r.profit >= 0 and "pos" or "err") or "textDim"))
			row.seller:SetText(r.prof or "")
			row.buy:Show()
			row.buy.text:SetText(r.suggest and r.suggest > 0
				and ("QUEUE ×" .. r.suggest) or "QUEUE")
			row.buy:SetEnabled(true)
		elseif e.header then
			local g = e.g
			row:Show()
			row.data = { header = true, itemID = g.itemID, open = e.open }
			local ic = GM.ItemIcon and GM.ItemIcon(g.itemID)
			if ic then row.icon:SetTexture(ic); row.icon:Show() else row.icon:Hide() end
			row.arrow:SetText(e.open and "▼" or "▶")
			row.name:SetPoint("LEFT", 26, 0)
			local nm = (GM.ItemName and GM.ItemName(g.itemID)) or ("item " .. g.itemID)
			row.name:SetText(GM.CC("text") .. nm .. "|r" .. GM.CC("textDim")
				.. "  · " .. g.count .. (g.count == 1 and " listing" or " listings") .. "|r")
			row.qty:SetText("×" .. g.totalQty)
			row.unit:SetText(g.cheapest < math.huge and GM.Money(g.cheapest) or "—")
			row.pct:SetText("")
			row.seller:SetText(g.ownCount > 0
				and (GM.CC("accent") .. g.ownCount .. " own|r") or "")
			row.buy:Hide()
		else
			local d = e.d
			row:Show()
			row.data = d
			row.arrow:SetText("")
			row.icon:Hide()
			row.name:SetPoint("LEFT", 42, 0)
			row.buy:Show()
			if ui.mode == "shop" then
				local m = S.itemID and ((GM.ItemEntry(S.itemID) or {}).mkt
					or (GM.ItemEntry(S.itemID) or {}).p or GM.TSMMarket(S.itemID))
				local cap = S.itemID and GM.Groups.EvalOp(
					GM.Groups.GetOps(S.itemID, "shopping"), "maxPrice", S.itemID)
				row.name:SetText("")
				row.qty:SetText("×" .. d.qty)
				row.unit:SetText(GM.Money(d.unit))
				row.pct:SetText(m and format("%.0f%%", d.unit / m * 100) or "—")
				row.pct:SetTextColor(GM.RGB(cap and d.unit <= cap and "pos" or "textDim"))
				row.seller:SetText(d.own and (GM.CC("accent") .. "OWN|r") or (d.seller or "—"))
				row.buy.text:SetText(pc and pc.itemID == d.itemID and "CONFIRM" or "BUY")
				row.buy:SetEnabled(GM.AH.open and not d.own)
			else
				row.name:SetText("")
				row.qty:SetText("×" .. d.qty)
				row.unit:SetText(GM.Money(d.unit))
				row.pct:SetText(d.pct and format("%.0f%%", d.pct) or "—")
				row.pct:SetTextColor(GM.RGB("pos"))
				row.seller:SetText("")
				row.buy.text:SetText(d.state == "scanning" and "…"
					or d.state == "ready" and "BUY" or "SCAN")
				row.buy:SetEnabled(GM.AH.open and d.state ~= "scanning")
			end
		end
	end
end
