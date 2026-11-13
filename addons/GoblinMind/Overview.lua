local _, GM = ...

-- The ledger overview: a large window pairing the activity log (the
-- ledger's transaction stream, day-grouped and wheel-scrolled) with
-- per-account trend lines from Budget sampling, plus the account
-- function controls (kind + group binding) in one place.

GM.Overview = {}
local OV = GM.Overview
local ui

local LOG_ROWS = 20
local ACCT_ROWS = 7
local SERIES_COLORS = { "accent", "pos", "warn", "err", "primary", "secondary" }
local atan2 = atan2 or function(y, x) return math.atan(y, x) end

local function Panel(f, x, y, w, h, title)
	local p = CreateFrame("Frame", nil, f)
	p:SetSize(w, h)
	p:SetPoint("TOPLEFT", x, y)
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	return p
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

-- ============ window ============

local function Build()
	if ui then return end
	ui = { scroll = 0, art = {} }
	local f = CreateFrame("Frame", "GoblinMindOverview", UIParent)
	f:SetSize(740, 540)
	f:SetPoint("CENTER", 80, 20)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
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

	-- ===== left: activity log =====
	local log = Panel(f, 10, -34, 290, 496, "ACTIVITY LOG")
	log:EnableMouseWheel(true)
	log:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		OV.RefreshLog()
	end)
	ui.logRows = {}
	for i = 1, LOG_ROWS do
		local fs = GM.MakeFontString(log, GM.FONT, 10, "text")
		fs:SetPoint("TOPLEFT", 10, -22 - (i - 1) * 23)
		fs:SetWidth(270)
		fs:SetJustifyH("LEFT")
		ui.logRows[i] = fs
	end
	ui.logHint = GM.MakeFontString(log, GM.FONT, 9, "secondary")
	ui.logHint:SetPoint("BOTTOMLEFT", 10, 4)
	ui.logHint:SetText("scroll: wheel")

	-- ===== right top: account trends =====
	local chart = Panel(f, 310, -34, 420, 220, "ACCOUNT TRENDS")
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

	-- ===== right bottom: accounts + functions =====
	local accts = Panel(f, 310, -264, 420, 266, "ACCOUNTS · FUNCTION")
	ui.acctRows = {}
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
end

-- ============ activity log ============

local TX_LABEL = {
	buy = "Purchased", sell = "Sold", post = "Posted",
	cancel = "Cancelled", expire = "Expired", mail = "Mail in",
}

local function DisplayList()
	-- newest-first tx stream with day headers spliced in
	local tx = GM.Ledger.db and GM.Ledger.db.transactions or {}
	local out = {}
	local lastDay, today = nil, date("%x")
	for i = #tx, 1, -1 do
		local e = tx[i]
		local day = date("%x", e.t)
		if day ~= lastDay then
			out[#out + 1] = { head = day == today and "TODAY"
				or day == date("%x", time() - 86400) and "YESTERDAY"
				or date("%b %d", e.t) }
			lastDay = day
		end
		out[#out + 1] = e
	end
	return out
end

function OV.RefreshLog()
	if not ui then return end
	local list = DisplayList()
	local maxOff = math.max(0, #list - LOG_ROWS)
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
				GM.ItemName(e.i) or ("item " .. (e.i or "?")), e.q,
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
	-- free gold first so envelopes draw over it
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
	-- zero line
	local zeroY = 30
	local zero = Line(chart, 0, zeroY, w, zeroY, "outlineVar")
	tinsert(ui.art, zero)
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
	-- hi label at top edge
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

function OV.Refresh()
	OV.RefreshLog()
	OV.RefreshChart()
	RefreshAccounts()
end

function OV.Show()
	Build()
	OV.Refresh()
	ui.frame:Show()
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
