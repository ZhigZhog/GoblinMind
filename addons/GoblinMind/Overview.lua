local _, GM = ...
local W = GM.Widgets

-- The ledger window: TSM-style paged layout — left nav over ACTIVITY /
-- INVENTORY / SALES / RESALE / EXPENSES / FAILED / ACCOUNTS, per-char
-- transaction aggregation (char switcher top-right), and an item-detail
-- page reached by clicking any item row.

GM.Overview = {}
local OV = GM.Overview
local ui

local ROWS = 20
local SERIES_COLORS = { "accent", "pos", "warn", "err", "primary", "secondary" }
local atan2 = atan2 or function(y, x) return math.atan(y, x) end

local PAGES = {
	{ "ACTIVITY", "activity" },
	{ "INVENTORY", "inventory" },
	{ "SALES", "sales" },
	{ "RESALE", "resale" },
	{ "EXPENSES", "expenses" },
	{ "FAILED", "failed" },
	{ "ACCOUNTS", "accounts" },
}

local function Panel(f, x, y, w, h, title)
	local p = CreateFrame("Frame", nil, f)
	p:SetSize(w, h)
	p:SetPoint("TOPLEFT", x, y)
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	return p, t
end

-- rotated-texture line segment (chart series)
local function Line(parent, x1, y1, x2, y2, key)
	local t = parent:CreateTexture(nil, "ARTWORK")
	local dx, dy = x2 - x1, y2 - y1
	local len = math.max(1, sqrt(dx * dx + dy * dy))
	t:SetSize(len, 1.5)
	t:SetPoint("CENTER", parent, "BOTTOMLEFT", (x1 + x2) / 2, (y1 + y2) / 2)
	t:SetRotation(atan2(dy, dx))
	t:SetColorTexture(GM.RGB(key))
	return t
end

-- ============ data ============

-- per-item aggregation over one char's transaction stream — the char
-- switcher re-aggregates; itemStats (account-global) stays for detail
local function TxAgg(ck)
	local agg = {}
	for _, e in ipairs(GM.Ledger.TxFor(ck)) do
		if e.i then
			local a = agg[e.i]
			if not a then a = {} agg[e.i] = a end
			local amt = e.q * (e.u or 0)
			if e.ty == "buy" then
				a.buyQ = (a.buyQ or 0) + e.q
				a.buyT = (a.buyT or 0) + amt
			elseif e.ty == "sell" then
				a.sellQ = (a.sellQ or 0) + e.q
				a.sellT = (a.sellT or 0) + amt
			elseif e.ty == "cancel" then
				a.cancelQ = (a.cancelQ or 0) + e.q
			elseif e.ty == "expire" then
				a.expireQ = (a.expireQ or 0) + e.q
			elseif e.ty == "post" then
				a.postQ = (a.postQ or 0) + e.q
			elseif e.ty == "mail" then
				a.mailQ = (a.mailQ or 0) + e.q
			end
		end
	end
	return agg
end

local function ViewChar()
	if not ui.viewChar then ui.viewChar = GM.Ledger.CharKey() end
	return ui.viewChar
end

-- ============ generic table ============

-- Columned item table: pooled rows {icon,name,c1..cN}, wheel scroll,
-- row click drills to the item page.
local function MakeTable(parent, cols, onClick)
	local t = { off = 0, rows = {}, list = {} }
	local head = CreateFrame("Frame", nil, parent)
	head:SetPoint("TOPLEFT", 6, -16)
	head:SetPoint("TOPRIGHT", -6, -16)
	head:SetHeight(16)
	for _, c in ipairs(cols) do
		local fs = GM.MakeFontString(head, GM.FONT_MED, 9, "primary")
		fs:SetPoint("LEFT", c[2], 0)
		fs:SetText(c[1])
	end
	t.count = GM.MakeFontString(head, GM.FONT, 9, "textDim")
	t.count:SetPoint("RIGHT", 0, 0)
	local body = CreateFrame("Frame", nil, parent)
	body:SetPoint("TOPLEFT", 6, -34)
	body:SetPoint("BOTTOMRIGHT", -6, 24)
	if body.SetClipsChildren then body:SetClipsChildren(true) end
	body:EnableMouseWheel(true)
	body:SetScript("OnMouseWheel", function(_, d)
		t.off = math.max(0, math.min(
			math.max(0, #t.list - ROWS), t.off - d * 2))
		t.paint()
	end)
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, body)
		W.HoverTint(row)
		row:SetHeight(22)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * 23)
		row:SetPoint("TOPRIGHT", 0, -(i - 1) * 23)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 2, 0)
		row.cells = {}
		for j, c in ipairs(cols) do
			local fs = GM.MakeFontString(row, j == 1 and GM.FONT or GM.FONT_MED,
				j == 1 and 10 or 9, j == 1 and "text" or "textDim")
			fs:SetPoint("LEFT", c[2], 0)
			if c[3] then fs:SetWidth(c[3]) end
			fs:SetJustifyH("LEFT")
			row.cells[j] = fs
		end
		row:SetScript("OnEnter", function()
			if row.id then
				GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
				if GameTooltip.SetItemByID then
					GameTooltip:SetItemByID(row.id)
				else
					GameTooltip:SetText(row.cells[1]:GetText() or "")
				end
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row:SetScript("OnClick", function()
			if row.id and onClick then onClick(row.id) end
		end)
		t.rows[i] = row
	end
	t.paint = function()
		W.ScrollText(t.count, t.off, ROWS, #t.list)
		for i, row in ipairs(t.rows) do
			local e = t.list[i + t.off]
			if e then
				row:Show()
				row.id = e.id
				row.icon:SetTexture(e.id and GM.ItemIcon
					and GM.ItemIcon(e.id) or
					"Interface\\Icons\\INV_Misc_QuestionMark")
				for j, fs in ipairs(row.cells) do
					fs:SetText(e.cells[j] or "")
					fs:SetTextColor(GM.RGB(e.colors and e.colors[j]
						or (j == 1 and "text" or "textDim")))
				end
			else
				row:Hide()
				row.id = nil
			end
		end
	end
	t.footer = GM.MakeFontString(parent, GM.FONT, 9, "secondary")
	t.footer:SetPoint("BOTTOMLEFT", 10, 6)
	return t
end

-- ============ pages: content builders ============

local function ItemName(id)
	return (GM.ItemName and GM.ItemName(id)) or ("item " .. id)
end

-- INVENTORY: owned items by value
local function BuildInventory()
	local out, total = {}, 0
	for id in pairs(GM.Inventory.Owned()) do
		local c = GM.Inventory.Count(id)
		local e = GM.ItemEntry(id)
		local p = e and (e.mkt or e.p) or GM.TSMMarket(id)
		local v = p and p * c.total or 0
		total = total + v
		tinsert(out, { id = id, v = v, cells = {
			ItemName(id),
			c.bags + c.bank > 0 and ("×" .. (c.bags + c.bank)) or "",
			(c.mail + c.guild + c.auction) > 0
				and ("+" .. (c.mail + c.guild + c.auction)) or "",
			p and GM.Money(p) or "—",
			v > 0 and GM.Money(v) or "—",
		} })
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildSales(agg)
	local out, total = {}, 0
	for id, a in pairs(agg) do
		if a.sellQ and a.sellQ > 0 then
			total = total + a.sellT
			tinsert(out, { id = id, v = a.sellT, cells = {
				ItemName(id), "×" .. a.sellQ,
				GM.Money(a.sellT / a.sellQ), GM.Money(a.sellT),
			} })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildResale(agg)
	local out, total = {}, 0
	for id, a in pairs(agg) do
		if a.sellQ and a.sellQ > 0 and a.buyQ and a.buyQ > 0 then
			local avgB, avgS = a.buyT / a.buyQ, a.sellT / a.sellQ
			local profit = a.sellT - avgB * a.sellQ
			total = total + profit
			tinsert(out, { id = id, v = profit, cells = {
				ItemName(id), "×" .. a.sellQ, GM.Money(avgB),
				GM.Money(avgS), GM.Money(profit),
			}, colors = { nil, nil, nil, nil,
				profit >= 0 and "pos" or "err" } })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildExpenses(agg)
	local out, total = {}, 0
	for id, a in pairs(agg) do
		if a.buyQ and a.buyQ > 0 then
			total = total + a.buyT
			tinsert(out, { id = id, v = a.buyT, cells = {
				ItemName(id), "×" .. a.buyQ,
				GM.Money(a.buyT / a.buyQ), GM.Money(a.buyT),
			} })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildFailed(agg)
	local out = {}
	for id, a in pairs(agg) do
		local f = (a.cancelQ or 0) + (a.expireQ or 0)
		if f > 0 then
			local rate = f / (f + (a.sellQ or 0)) * 100
			tinsert(out, { id = id, v = f, cells = {
				ItemName(id),
				a.expireQ and a.expireQ > 0 and tostring(a.expireQ) or "—",
				a.cancelQ and a.cancelQ > 0 and tostring(a.cancelQ) or "—",
				format("%.0f%%", rate),
			} })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out
end

-- ============ activity log ============

local TX_LABEL = {
	buy = "Purchased", sell = "Sold", post = "Posted",
	cancel = "Cancelled", expire = "Expired", mail = "Mail in",
}

local function DisplayList(ck)
	local tx = GM.Ledger.TxFor(ck)
	local out, lastDay = {}, nil
	local today, yest = date("%x"), date("%x", time() - 86400)
	for i = #tx, 1, -1 do
		local e = tx[i]
		local day = date("%x", e.t)
		if day ~= lastDay then
			out[#out + 1] = { head = day == today and "TODAY"
				or day == yest and "YESTERDAY" or date("%b %d", e.t) }
			lastDay = day
		end
		out[#out + 1] = e
	end
	return out
end

function OV.RefreshLog()
	if not ui then return end
	local list = DisplayList(ViewChar())
	local maxOff = math.max(0, #list - ROWS)
	if ui.scroll > maxOff then ui.scroll = maxOff end
	for i, fs in ipairs(ui.logRows) do
		local e = list[i + ui.scroll]
		if not e then
			fs:SetText("")
		elseif e.head then
			fs:SetText(GM.CC("accent") .. e.head .. "|r")
		else
			local money = e.u and e.u * e.q
			fs:SetText(format("%s  %s %s · %s ×%d%s",
				date("%H:%M", e.t),
				e.ty == "sell" and GM.CC("pos") or
					e.ty == "buy" and GM.CC("warn") or GM.CC("textDim"),
				TX_LABEL[e.ty] or e.ty,
				ItemName(e.i), e.q,
				money and (" · " .. GM.Money(money)) or ""))
		end
	end
end

-- ============ trend chart ============

function OV.RefreshChart()
	if not ui then return end
	for _, a in ipairs(ui.art) do a:Hide() end
	wipe(ui.art)
	local chart = ui.chart
	local w, h = chart:GetWidth() - 20, chart:GetHeight() - 46
	local series = {}
	series[#series + 1] = { name = "free", color = "textDim",
		hist = GM.db.budgetFree }
	for _, a in ipairs(GM.Budget.List()) do
		series[#series + 1] = { name = a.name, hist = a.hist,
			color = SERIES_COLORS[(#series % #SERIES_COLORS) + 1] }
	end
	local tMin, tMax, vMax = math.huge, 0, 0
	for _, s in ipairs(series) do
		for _, p in ipairs(s.hist or {}) do
			if p.t < tMin then tMin = p.t end
			if p.t > tMax then tMax = p.t end
			if p.v > vMax then vMax = p.v end
		end
	end
	for i, fs in ipairs(ui.legend) do
		local s = series[i]
		if s then
			fs:SetText(s.name:sub(1, 8))
			fs:SetTextColor(GM.RGB(s.color))
		else
			fs:SetText("")
		end
	end
	if vMax <= 0 or tMax <= tMin then
		ui.chartMsg:SetText("samples build as budgets see activity")
		return
	end
	ui.chartMsg:SetText("")
	tMax = math.max(tMax, tMin + 600)
	local zeroY = 30
	tinsert(ui.art, Line(chart, 0, zeroY, w, zeroY, "outlineVar"))
	-- axis labels: value scale on the left, time range underneath
	local function AxisLabel(txt, x, y)
		local fs = GM.MakeFontString(chart, GM.FONT, 8, "secondary")
		fs:SetPoint("BOTTOMLEFT", x, y)
		fs:SetText(txt)
		tinsert(ui.art, fs)
	end
	AxisLabel(GM.Money(vMax), 4, zeroY + h + 2)
	AxisLabel(GM.Money(vMax / 2), 4, zeroY + h / 2 + 2)
	AxisLabel(date("%H:%M", tMin), 4, 2)
	local endTs = GM.MakeFontString(chart, GM.FONT, 8, "secondary")
	endTs:SetPoint("BOTTOMRIGHT", -8, 2)
	endTs:SetText(date("%H:%M", tMax))
	tinsert(ui.art, endTs)
	for _, s in ipairs(series) do
		local hist = s.hist or {}
		for i = 2, #hist do
			local x1 = (hist[i - 1].t - tMin) / (tMax - tMin) * w
			local y1 = zeroY + hist[i - 1].v / vMax * h
			local x2 = (hist[i].t - tMin) / (tMax - tMin) * w
			local y2 = zeroY + hist[i].v / vMax * h
			tinsert(ui.art, Line(chart, x1, y1, x2, y2, s.color))
		end
	end
	local hi = GM.MakeFontString(chart, GM.FONT, 8, "secondary")
	hi:SetPoint("TOPRIGHT", -8, -16)
	hi:SetText(GM.Money(vMax))
	tinsert(ui.art, hi)
end

-- ============ accounts ============

local function RefreshAccounts()
	if not ui then return end
	local list = GM.Budget.List()
	for i, row in ipairs(ui.acctRows) do
		local a = list[i]
		if a then
			row:Show()
			row.name:SetText(a.name)
			row.kind.text:SetText(GM.Budget.KINDS[a.kind])
			row.grp.text:SetText(a.group or "—")
			row.grp.text:SetTextColor(GM.RGB(a.group and "accent" or "textDim"))
			row.left:SetText(GM.Money(GM.Budget.Remaining(a)))
			row.left:SetTextColor(GM.RGB(
				a.kind == "save" and "accent" or "textDim"))
		else
			row:Hide()
		end
	end
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { scroll = 0, art = {}, page = "activity", tables = {} }
	local f = CreateFrame("Frame", "GoblinMindOverview", UIParent)
	f:SetSize(860, 560)
	f:SetPoint("CENTER", 60, 20)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	tinsert(UISpecialFrames, "GoblinMindOverview")
	GM.Panel(f, "contLow", "outlineVar")
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("LEDGER")
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, title, "overview")
	end

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- char switcher: cycles the char whose tx stream drives the views.
	-- Shows the name part only — full Name-Realm-Region keys are
	-- long enough to blow past the button edge
	local char = CreateFrame("Button", nil, f)
	char:SetSize(150, 16)
	char:SetPoint("TOPRIGHT", close, "TOPLEFT", -8, -1)
	GM.Panel(char, "contMedium")
	char.text = GM.MakeFontString(char, GM.FONT_MED, 9, "secondary")
	char.text:SetPoint("CENTER")
	char.text:SetWidth(140)
	char:SetScript("OnClick", function()
		local chars = GM.Ledger.Chars()
		if #chars < 2 then return end
		for i, ck in ipairs(chars) do
			if ck == ViewChar() then
				ui.viewChar = chars[i % #chars + 1]
				break
			end
		end
		ui.scroll = 0
		OV.Refresh()
	end)
	ui.charBtn = char

	-- ===== left nav =====
	local nav = Panel(f, 10, -34, 110, 516, "PAGES")
	ui.navBtns = {}
	for i, p in ipairs(PAGES) do
		local b = CreateFrame("Button", nil, nav)
		b:SetSize(96, 20)
		b:SetPoint("TOPLEFT", 7, -22 - (i - 1) * 24)
		b.text = GM.MakeFontString(b, GM.FONT_BOLD, 10, "textDim")
		b.text:SetPoint("LEFT", 8, 0)
		b.text:SetText(p[1])
		local key = p[2]
		b:SetScript("OnClick", function()
			ui.page = key
			OV.Refresh()
		end)
		ui.navBtns[i] = { btn = b, key = key }
	end

	-- ===== content host =====
	local host = CreateFrame("Frame", nil, f)
	host:SetPoint("TOPLEFT", 126, -34)
	host:SetPoint("BOTTOMRIGHT", -10, 10)
	ui.host = host

	-- ---- page: activity ----
	local actP = Panel(host, 0, 0, 724, 516, "ACTIVITY LOG")
	actP:EnableMouseWheel(true)
	actP:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		OV.RefreshLog()
	end)
	ui.pageActivity = actP
	ui.logRows = {}
	for i = 1, ROWS do
		local fs = GM.MakeFontString(actP, GM.FONT, 10, "text")
		fs:SetPoint("TOPLEFT", 10, -22 - (i - 1) * 23)
		fs:SetWidth(700)
		fs:SetJustifyH("LEFT")
		ui.logRows[i] = fs
	end

	-- ---- page: inventory ----
	local invP = Panel(host, 0, 0, 724, 516, "INVENTORY — STOCK BY VALUE")
	ui.pageInventory = invP
	ui.tInventory = MakeTable(invP, {
		{ "ITEM", 24, 240 }, { "BAGS+BANK", 270, 70 },
		{ "ELSEWHERE", 344, 80 }, { "PRICE", 430, 110 }, { "VALUE", 560, 120 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: sales ----
	local salP = Panel(host, 0, 0, 724, 516, "REVENUE — SALES")
	ui.pageSales = salP
	ui.tSales = MakeTable(salP, {
		{ "ITEM", 24, 240 }, { "SOLD", 270, 70 },
		{ "AVG PRICE", 350, 110 }, { "REVENUE", 480, 130 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: resale ----
	local resP = Panel(host, 0, 0, 724, 516, "REVENUE — RESALE (BUY→SELL MARGIN)")
	ui.pageResale = resP
	ui.tResale = MakeTable(resP, {
		{ "ITEM", 24, 220 }, { "SOLD", 250, 60 },
		{ "AVG BUY", 320, 110 }, { "AVG SELL", 440, 110 },
		{ "PROFIT", 570, 110 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: expenses ----
	local expP = Panel(host, 0, 0, 724, 516, "EXPENSES — PURCHASES")
	ui.pageExpenses = expP
	ui.tExpenses = MakeTable(expP, {
		{ "ITEM", 24, 240 }, { "BOUGHT", 270, 80 },
		{ "AVG PRICE", 360, 110 }, { "SPENT", 490, 130 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: failed ----
	local failP = Panel(host, 0, 0, 724, 516, "FAILED AUCTIONS")
	ui.pageFailed = failP
	ui.tFailed = MakeTable(failP, {
		{ "ITEM", 24, 240 }, { "EXPIRED", 280, 80 },
		{ "CANCELLED", 380, 90 }, { "FAIL RATE", 490, 90 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: accounts (chart + function controls) ----
	local acctP = Panel(host, 0, 0, 724, 516, "ACCOUNTS")
	ui.pageAccounts = acctP
	local chart = Panel(acctP, 6, -20, 712, 226, "ACCOUNT TRENDS")
	if chart.SetClipsChildren then chart:SetClipsChildren(true) end
	ui.chart = chart
	ui.chartMsg = GM.MakeFontString(chart, GM.FONT, 10, "textDim")
	ui.chartMsg:SetPoint("CENTER")
	ui.legend = {}
	for i = 1, 7 do
		local fs = GM.MakeFontString(chart, GM.FONT, 9, "textDim")
		fs:SetPoint("BOTTOMLEFT", 10 + (i - 1) * 58, 6)
		fs:SetJustifyH("LEFT")
		ui.legend[i] = fs
	end
	local accts = Panel(acctP, 6, -254, 712, 256, "ACCOUNTS · FUNCTION")
	ui.acctRows = {}
	local ACCT_ROWS = 7
	for i = 1, ACCT_ROWS do
		local row = CreateFrame("Frame", nil, accts)
		row:SetSize(404, 26)
		row:SetPoint("TOPLEFT", 8, -20 - (i - 1) * 26)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 2, 0)
		row.name:SetWidth(110)
		row.name:SetJustifyH("LEFT")

		local kind = CreateFrame("Button", nil, row)
		kind:SetSize(52, 20)
		kind:SetPoint("LEFT", 114, 0)
		GM.Panel(kind, "contHigh")
		kind.text = GM.MakeFontString(kind, GM.FONT_MED, 9, "secondary")
		kind.text:SetPoint("CENTER")
		local idx = i
		kind:SetScript("OnClick", function()
			local order = GM.Budget.KIND_ORDER
			local a = GM.Budget.List()[idx]
			if not a then return end
			for j, k in ipairs(order) do
				if k == a.kind then
					GM.Budget.SetKind(idx, order[j % #order + 1])
					break
				end
			end
			OV.Refresh()
		end)
		kind:SetScript("OnEnter", function()
			GameTooltip:SetOwner(kind, "ANCHOR_TOP")
			GameTooltip:SetText("account function — click to cycle", 1, 1, 1)
			GameTooltip:Show()
		end)
		kind:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.kind = kind

		local grp = CreateFrame("Button", nil, row)
		grp:SetSize(120, 20)
		grp:SetPoint("LEFT", kind, "RIGHT", 6, 0)
		GM.Panel(grp, "contMedium")
		grp.text = GM.MakeFontString(grp, GM.FONT, 9, "textDim")
		grp.text:SetPoint("LEFT", 5, 0)
		grp.text:SetPoint("RIGHT", -4, 0)
		grp.text:SetJustifyH("LEFT")
		grp:SetScript("OnClick", function()
			local a = GM.Budget.List()[idx]
			if not a then return end
			local paths = GM.Budget.GroupPaths()
			local cur, nextPath = a.group, nil
			if not cur then
				nextPath = paths[1]
			else
				for j, p in ipairs(paths) do
					if p == cur then nextPath = paths[j + 1] break end
				end
			end
			GM.Budget.SetGroup(idx, nextPath)
			OV.Refresh()
		end)
		grp:SetScript("OnEnter", function()
			GameTooltip:SetOwner(grp, "ANCHOR_TOP")
			GameTooltip:SetText(
				"bind to a group — its spends/sales route here", 1, 1, 1)
			GameTooltip:Show()
		end)
		grp:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.grp = grp

		row.left = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.left:SetPoint("LEFT", grp, "RIGHT", 8, 0)
		row.left:SetWidth(100)
		row.left:SetJustifyH("LEFT")
		ui.acctRows[i] = row
	end
	ui.acctHint = GM.MakeFontString(accts, GM.FONT, 9, "secondary")
	ui.acctHint:SetPoint("BOTTOMLEFT", 10, 6)
	ui.acctHint:SetText(
		"kind: spend pool / reserve · group: items route to this account")

	-- ---- page: item detail (drill-in) ----
	local itP = Panel(host, 0, 0, 724, 516, "ITEM")
	ui.pageItem = itP
	itP.icon = itP:CreateTexture(nil, "ARTWORK")
	itP.icon:SetSize(32, 32)
	itP.icon:SetPoint("TOPLEFT", 12, -26)
	itP.name = GM.MakeFontString(itP, GM.FONT_BOLD, 13, "text")
	itP.name:SetPoint("LEFT", itP.icon, "RIGHT", 10, 10)
	itP.mkt = GM.MakeFontString(itP, GM.FONT, 10, "textDim")
	itP.mkt:SetPoint("TOPLEFT", itP.name, "BOTTOMLEFT", 0, -6)
	itP.back = CreateFrame("Button", nil, itP)
	itP.back:SetSize(56, 18)
	itP.back:SetPoint("TOPRIGHT", -10, -22)
	GM.Panel(itP.back, "contHigh")
	itP.back.text = GM.MakeFontString(itP.back, GM.FONT_MED, 9, "textDim")
	itP.back.text:SetPoint("CENTER")
	itP.back.text:SetText("« BACK")
	itP.back:SetScript("OnClick", function()
		ui.page = ui.prevPage or "activity"
		OV.Refresh()
	end)
	itP.target = CreateFrame("Button", nil, itP)
	itP.target:SetSize(70, 18)
	itP.target:SetPoint("RIGHT", itP.back, "LEFT", -6, 0)
	GM.Panel(itP.target, "contHigh")
	itP.target.text = GM.MakeFontString(itP.target, GM.FONT_MED, 9, "textDim")
	itP.target.text:SetPoint("CENTER")
	itP.target.text:SetText("TARGET")
	itP.target:SetScript("OnClick", function()
		if ui.itemID then
			GM.PlanQueue.SetItem(ui.itemID)
			GM.PlanQueue.Show()
		end
	end)
	itP.stats = GM.MakeFontString(itP, GM.FONT, 10, "text")
	itP.stats:SetPoint("TOPLEFT", 12, -74)
	itP.stats:SetWidth(330)
	itP.stats:SetJustifyH("LEFT")
	itP.stats:SetSpacing(4)
	itP.txTitle = GM.MakeFontString(itP, GM.FONT_BOLD, 9, "secondary")
	itP.txTitle:SetPoint("TOPLEFT", 360, -74)
	itP.txTitle:SetText("RECENT TRANSACTIONS")
	itP.txRows = {}
	for i = 1, 18 do
		local fs = GM.MakeFontString(itP, GM.FONT, 9, "textDim")
		fs:SetPoint("TOPLEFT", 360, -90 - (i - 1) * 21)
		fs:SetWidth(350)
		fs:SetJustifyH("LEFT")
		itP.txRows[i] = fs
	end
end

-- ============ item detail ============

function OV.ShowItem(id)
	ui.itemID = id
	ui.prevPage = ui.page ~= "item" and ui.page or ui.prevPage
	ui.page = "item"
	OV.Refresh()
end

local function RefreshItem()
	local itP, id = ui.pageItem, ui.itemID
	if not id then return end
	itP.icon:SetTexture(GM.ItemIcon and GM.ItemIcon(id)
		or "Interface\\Icons\\INV_Misc_QuestionMark")
	itP.name:SetText(ItemName(id))
	local e = GM.ItemEntry(id)
	local m = e and (e.mkt or e.p) or GM.TSMMarket(id)
	itP.mkt:SetText(m and ("market " .. GM.Money(m)) or "no market data")

	-- account-global aggregates (itemStats is shared by design)
	local s = GM.Ledger.Stats(id)
	local c = GM.Inventory.Count(id)
	local lines = {
		format("on hand: %d  (bags %d · bank %d · mail %d · gbank %d · ah %d)",
			c.total, c.bags, c.bank, c.mail, c.guild, c.auction),
	}
	if s then
		if s.buyQ > 0 then
			lines[#lines + 1] = format("bought ×%d @ %s avg  (%s – %s)",
				s.buyQ, GM.Money(s.buyAvg or 0),
				GM.Money(s.buyMin or 0), GM.Money(s.buyMax or 0))
		end
		if s.sellQ > 0 then
			lines[#lines + 1] = format("sold ×%d @ %s avg  (%s – %s)",
				s.sellQ, GM.Money(s.sellAvg or 0),
				GM.Money(s.sellMin or 0), GM.Money(s.sellMax or 0))
		end
		local paid = GM.Ledger.Avg(id, "paid")
		if paid then
			lines[#lines + 1] = "stock cost basis " .. GM.Money(paid)
		end
		if s.saleRate then
			lines[#lines + 1] = format("sale rate %.0f%% · cancels %d · expires %d",
				s.saleRate * 100, s.cancelSinceSell, s.expireSinceSell)
		end
	else
		lines[#lines + 1] = "no ledger history"
	end
	itP.stats:SetText(table.concat(lines, "\n"))

	-- this char's recent txs for the item, newest first
	local n = 0
	local tx = GM.Ledger.TxFor(ViewChar())
	for i = #tx, 1, -1 do
		local e = tx[i]
		if e.i == id then
			n = n + 1
			if n <= #itP.txRows then
				itP.txRows[n]:SetText(format("%s  %s%s ×%d%s",
					date("%b %d %H:%M", e.t),
					e.ty == "sell" and GM.CC("pos") or
						e.ty == "buy" and GM.CC("warn") or GM.CC("textDim"),
					TX_LABEL[e.ty] or e.ty, e.q,
					e.u and (" @ " .. GM.Money(e.u)) or ""))
			end
		end
	end
	for i = n + 1, #itP.txRows do itP.txRows[i]:SetText("") end
end

-- ============ refresh ============

function OV.Refresh()
	if not ui then return end
	ui.charBtn.text:SetText(
		(ViewChar() or "?"):match("^[^-]+") or ViewChar() or "?")
	for _, nb in ipairs(ui.navBtns) do
		nb.btn.text:SetTextColor(GM.RGB(
			nb.key == ui.page and "accent" or "textDim"))
	end
	ui.pageActivity:SetShown(ui.page == "activity")
	ui.pageInventory:SetShown(ui.page == "inventory")
	ui.pageSales:SetShown(ui.page == "sales")
	ui.pageResale:SetShown(ui.page == "resale")
	ui.pageExpenses:SetShown(ui.page == "expenses")
	ui.pageFailed:SetShown(ui.page == "failed")
	ui.pageAccounts:SetShown(ui.page == "accounts")
	ui.pageItem:SetShown(ui.page == "item")

	if ui.page == "activity" then
		OV.RefreshLog()
	elseif ui.page == "inventory" then
		ui.tInventory.list, ui.tInventory.total = BuildInventory()
		ui.tInventory.footer:SetText(
			format("%d items · stock value %s%s", #ui.tInventory.list,
				GM.Money(ui.tInventory.total),
				(BankFrame and BankFrame:IsShown()) and ""
					or " · bank counts while open only"))
		ui.tInventory.paint()
	elseif ui.page == "sales" then
		ui.tSales.list, ui.tSales.total = BuildSales(TxAgg(ViewChar()))
		ui.tSales.footer:SetText(format("%d items · revenue %s",
			#ui.tSales.list, GM.Money(ui.tSales.total)))
		ui.tSales.paint()
	elseif ui.page == "resale" then
		ui.tResale.list, ui.tResale.total = BuildResale(TxAgg(ViewChar()))
		ui.tResale.footer:SetText(format("%d items · profit %s",
			#ui.tResale.list, GM.Money(ui.tResale.total)))
		ui.tResale.paint()
	elseif ui.page == "expenses" then
		ui.tExpenses.list, ui.tExpenses.total = BuildExpenses(TxAgg(ViewChar()))
		ui.tExpenses.footer:SetText(format("%d items · spent %s",
			#ui.tExpenses.list, GM.Money(ui.tExpenses.total)))
		ui.tExpenses.paint()
	elseif ui.page == "failed" then
		ui.tFailed.list = BuildFailed(TxAgg(ViewChar()))
		ui.tFailed.footer:SetText(format("%d items with failed auctions",
			#ui.tFailed.list))
		ui.tFailed.paint()
	elseif ui.page == "accounts" then
		OV.RefreshChart()
		RefreshAccounts()
	elseif ui.page == "item" then
		RefreshItem()
	end
end

function OV.Show()
	Build()
	ui.frame:Show()
	OV.Refresh()
	-- live refresh while open — ledger txs and budget samples land
	-- asynchronously (mail sales, timer sampler)
	local function tick()
		if ui.frame:IsShown() then
			OV.Refresh()
			GM.After(5, tick)
		end
	end
	GM.After(5, tick)
end

function OV.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function OV.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else OV.Show() end
end
