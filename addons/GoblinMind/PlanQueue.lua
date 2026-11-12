local _, GM = ...

-- TSM-styled plan window: item header, verbose stats column, trend
-- region, and the click-per-step queue. Every protected auction call is
-- still one hardware click — this file only arranges information.

GM.PlanQueue = { plan = nil, stepIndex = 1, itemID = nil, item = nil }

local PQ = GM.PlanQueue
local ROWS = 6
local ui = { art = {} }
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

local sqrt = sqrt or math.sqrt

-- Segments are drawn as interpolated dots — no SetRotation dependency
-- and the plot can never overshoot the chart's bounds.
local function Dot(parent, x, y, size, rgbKey)
	local t = parent:CreateTexture(nil, "OVERLAY")
	tinsert(ui.art, t)
	local r, g, b = GM.RGB(rgbKey or "text")
	t:SetColorTexture(r, g, b, 1)
	t:SetSize(size, size)
	t:SetPoint("CENTER", parent, "BOTTOMLEFT", x, y)
	return t
end

local function Segment(parent, x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local steps = math.max(1, floor(sqrt(dx * dx + dy * dy) / 2))
	for i = 0, steps do
		Dot(parent, x1 + dx * i / steps, y1 + dy * i / steps, 2, "accent")
	end
end

local function Label(parent, x, y, str, colorKey, size)
	local fs = GM.MakeFontString(parent, GM.FONT, size or 9, colorKey or "textDim")
	tinsert(ui.art, fs)
	fs:SetPoint("CENTER", parent, "BOTTOMLEFT", x, y)
	fs:SetText(str)
	return fs
end

local function BuildRow(parent, i)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(24)
	row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 24)
	row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 24)
	GM.Panel(row, i % 2 == 0 and "contLow" or "contLowest", "contLowest")
	row.edge = row:CreateTexture(nil, "ARTWORK")
	row.edge:SetPoint("TOPLEFT")
	row.edge:SetPoint("BOTTOMLEFT")
	row.edge:SetWidth(3)
	row.edge:SetColorTexture(GM.RGB("accent"))
	row.edge:Hide()
	row.num   = GM.MakeFontString(row, GM.FONT_MED, 11, "textDim")
	row.num:SetPoint("LEFT", 10, 0)
	row.act   = GM.MakeFontString(row, GM.FONT_MED, 11, "text")
	row.act:SetPoint("LEFT", 34, 0)
	row.qty   = GM.MakeFontString(row, GM.FONT, 11, "textDim")
	row.qty:SetPoint("LEFT", 140, 0)
	row.price = GM.MakeFontString(row, GM.FONT_MED, 11, "text")
	row.price:SetPoint("RIGHT", -10, 0)
	return row
end

-- grouped label/value rows for the stats column
local STAT_SECTIONS = {
	{ "VALUE",   { "est", "band", "vs TSM" } },
	{ "TREND",   { "hist", "recent" } },
	{ "MARKET",  { "min buy", "sells/day", "supply" } },
	{ "SIGNAL",  { "reset", "itemID" } },
	{ "ACCOUNT", { "gold", "risk", "margin", "data" } },
}
local function BuildStats(parent)
	ui.statText = {}
	local y, rowH = -28, 18
	for _, sec in ipairs(STAT_SECTIONS) do
		local h = GM.MakeFontString(parent, GM.FONT_MED, 9, "secondary")
		h:SetPoint("TOPLEFT", 8, y)
		h:SetText(sec[1])
		y = y - 15
		for i, key in ipairs(sec[2]) do
			if i % 2 == 1 then
				local bg = parent:CreateTexture(nil, "BACKGROUND")
				bg:SetPoint("TOPLEFT", 4, y)
				bg:SetPoint("TOPRIGHT", -4, y)
				bg:SetHeight(rowH)
				bg:SetColorTexture(GM.RGB("contLowest"))
			end
			local lab = GM.MakeFontString(parent, GM.FONT, 10, "textDim")
			lab:SetPoint("TOPLEFT", 10, y - 4)
			lab:SetText(key)
			local val = GM.MakeFontString(parent, GM.FONT_MED, 10, "text")
			val:SetPoint("TOPRIGHT", -10, y - 4)
			val:SetJustifyH("RIGHT")
			ui.statText[key] = val
			y = y - rowH
		end
		y = y - 9
	end
	local hint = GM.MakeFontString(parent, GM.FONT, 9, "secondary")
	hint:SetPoint("BOTTOMLEFT", 10, 8)
	hint:SetText("drop · alt-click · /goblin [link]")
end

local PAD, GAP = 10, 8
local LEFT_W = 456

local function Build()
	if ui.frame then return end

	local frame = CreateFrame("Frame", "GoblinMindPlanFrame", UIParent)
	frame:SetSize(700, 512)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("MEDIUM")
	GM.Panel(frame, "contLow", "outlineVar")
	tinsert(UISpecialFrames, "GoblinMindPlanFrame")

	local title = GM.MakeFontString(frame, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 14, -10)
	title:SetText("GOBLINMIND")

	ui.age = GM.MakeFontString(frame, GM.FONT, 10, "textDim")

	local close = CreateFrame("Button", nil, frame)
	close:SetSize(18, 18)
	close:SetPoint("TOPRIGHT", -8, -8)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetAllPoints()
	close.text:SetText("×")
	close:SetScript("OnClick", function() frame:Hide() end)
	close:SetScript("OnEnter", function() close.text:SetTextColor(GM.RGB("text")) end)
	close:SetScript("OnLeave", function() close.text:SetTextColor(GM.RGB("textDim")) end)
	ui.age:SetPoint("RIGHT", close, "LEFT", -8, -1)

	local rule = frame:CreateTexture(nil, "BORDER")
	rule:SetColorTexture(GM.RGB("outlineVar"))
	rule:SetPoint("TOPLEFT", PAD, -32)
	rule:SetPoint("TOPRIGHT", -PAD, -32)
	rule:SetHeight(1)

	-- ===== left column =====

	-- Item header: bordered icon slot + name + meta
	ui.item = CreateFrame("Button", nil, frame)
	ui.item:SetPoint("TOPLEFT", PAD, -40)
	ui.item:SetWidth(LEFT_W)
	ui.item:SetHeight(56)
	GM.Panel(ui.item, "contMedium")
	ui.item:SetScript("OnEnter", function() GM.Panel(ui.item, "contHigh") end)
	ui.item:SetScript("OnLeave", function() GM.Panel(ui.item, "contMedium") end)

	local iconBox = CreateFrame("Frame", nil, ui.item)
	iconBox:SetSize(44, 44)
	iconBox:SetPoint("LEFT", 6, 0)
	GM.Panel(iconBox, "contHighest", "outlineVar")
	ui.icon = iconBox:CreateTexture(nil, "ARTWORK")
	ui.icon:SetSize(40, 40)
	ui.icon:SetPoint("CENTER")

	ui.item.name = GM.MakeFontString(ui.item, GM.FONT_MED, 12, "text")
	ui.item.name:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 10, -4)
	ui.item.sub = GM.MakeFontString(ui.item, GM.FONT, 10, "textDim")
	ui.item.sub:SetPoint("TOPLEFT", ui.item.name, "BOTTOMLEFT", 0, -5)

	-- item drop target
	ui.item:EnableMouse(true)
	local function DropItem()
		local infoType, itemID, link = GetCursorInfo()
		if infoType ~= "item" then return end
		ClearCursor()
		GM.TargetItem(itemID, link)
	end
	ui.item:SetScript("OnReceiveDrag", DropItem)
	ui.item:SetScript("OnClick", function()
		if CursorHasItem() then DropItem() end
	end)

	-- Trend chart region
	ui.chart = CreateFrame("Frame", nil, frame)
	ui.chart:SetPoint("TOPLEFT", PAD, -104)
	ui.chart:SetWidth(LEFT_W)
	ui.chart:SetHeight(150)
	GM.Panel(ui.chart, "contLowest")
	ui.chart.title = GM.MakeFontString(ui.chart, GM.FONT_MED, 9, "secondary")
	ui.chart.title:SetPoint("TOPLEFT", 8, -5)
	ui.chart.title:SetText("PRICE · VOLUME")
	ui.chart.msg = GM.MakeFontString(ui.chart, GM.FONT, 10, "textDim")
	ui.chart.msg:SetPoint("CENTER", 0, -8)
	-- nothing drawn may escape the chart region
	if ui.chart.SetClipsChildren then ui.chart:SetClipsChildren(true) end

	-- Steps header
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", PAD, -262)
	header:SetWidth(LEFT_W)
	header:SetHeight(18)
	GM.Panel(header, "contHigh")
	for _, h in ipairs({ { "#", "LEFT", 10 }, { "ACTION", "LEFT", 34 }, { "QTY", "LEFT", 140 }, { "PRICE", "RIGHT", -10 } }) do
		local fs = GM.MakeFontString(header, GM.FONT_MED, 9, "secondary")
		fs:SetPoint(h[2], h[3], 0)
		fs:SetText(h[1])
	end

	-- Step rows
	ui.list = CreateFrame("Frame", nil, frame)
	ui.list:SetPoint("TOPLEFT", PAD, -282)
	ui.list:SetWidth(LEFT_W)
	ui.list:SetHeight(ROWS * 24 + 8)
	GM.Panel(ui.list, "contLowest")
	ui.rows = {}
	for i = 1, ROWS do ui.rows[i] = BuildRow(ui.list, i) end

	-- ===== right column: grouped stats, full height =====
	local stats = CreateFrame("Frame", nil, frame)
	stats:SetPoint("TOPRIGHT", -PAD, -40)
	stats:SetPoint("BOTTOMRIGHT", -PAD, PAD)
	stats:SetWidth(700 - 2 * PAD - GAP - LEFT_W)
	GM.Panel(stats, "contLow")
	local stTitle = GM.MakeFontString(stats, GM.FONT_MED, 9, "secondary")
	stTitle:SetPoint("TOPLEFT", 8, -6)
	stTitle:SetText("GOBLINMIND INFO")
	BuildStats(stats)

	-- Summary strip: verdict-colored left edge + wrapped text
	ui.sumBar = CreateFrame("Frame", nil, frame)
	ui.sumBar:SetPoint("BOTTOMLEFT", PAD, 46)
	ui.sumBar:SetSize(LEFT_W, 26)
	GM.Panel(ui.sumBar, "contLowest")
	ui.sumEdge = ui.sumBar:CreateTexture(nil, "ARTWORK")
	ui.sumEdge:SetPoint("TOPLEFT")
	ui.sumEdge:SetPoint("BOTTOMLEFT")
	ui.sumEdge:SetWidth(3)
	ui.sumEdge:SetColorTexture(GM.RGB("accent"))
	ui.summary = GM.MakeFontString(ui.sumBar, GM.FONT, 10, "textDim")
	ui.summary:SetPoint("TOPLEFT", 10, -2)
	ui.summary:SetPoint("TOPRIGHT", -6, -2)
	ui.summary:SetHeight(22)
	ui.summary:SetJustifyH("LEFT")
	ui.summary:SetJustifyV("TOP")
	ui.summary:SetWordWrap(true)

	-- buttons align under the left column (the plan table's edge)
	ui.exec = CreateFrame("Button", nil, frame)
	ui.exec:SetSize(190, 30)
	ui.exec:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", PAD + LEFT_W, 8)
	GM.Panel(ui.exec, "accent")
	ui.exec.text = GM.MakeFontString(ui.exec, GM.FONT_BOLD, 12, "contLowest")
	ui.exec.text:SetAllPoints()
	ui.exec.text:SetText("EXECUTE NEXT STEP")
	ui.exec:SetScript("OnClick", function() PQ.ExecuteNext() end)
	ui.exec:SetScript("OnEnter", function() GM.Panel(ui.exec, "warn") end)
	ui.exec:SetScript("OnLeave", function() GM.Panel(ui.exec, "accent") end)

	ui.rescan = CreateFrame("Button", nil, frame)
	ui.rescan:SetSize(104, 30)
	ui.rescan:SetPoint("RIGHT", ui.exec, "LEFT", -GAP, 0)
	GM.Panel(ui.rescan, "contHigh")
	ui.rescan.text = GM.MakeFontString(ui.rescan, GM.FONT_MED, 11, "text")
	ui.rescan.text:SetAllPoints()
	ui.rescan.text:SetText("RESCAN")
	ui.rescan:SetScript("OnClick", function() PQ.Rescan() end)
	ui.rescan:SetScript("OnEnter", function() GM.Panel(ui.rescan, "contHighest") end)
	ui.rescan:SetScript("OnLeave", function() GM.Panel(ui.rescan, "contHigh") end)

	ui.skip = CreateFrame("Button", nil, frame)
	ui.skip:SetSize(80, 30)
	ui.skip:SetPoint("RIGHT", ui.rescan, "LEFT", -GAP, 0)
	GM.Panel(ui.skip, "contMedium")
	ui.skip.text = GM.MakeFontString(ui.skip, GM.FONT_MED, 11, "textDim")
	ui.skip.text:SetAllPoints()
	ui.skip.text:SetText("SKIP")
	ui.skip:SetScript("OnClick", function() PQ.SkipStep() end)
	ui.skip:SetScript("OnEnter", function() GM.Panel(ui.skip, "contHigh") end)
	ui.skip:SetScript("OnLeave", function() GM.Panel(ui.skip, "contMedium") end)

	ui.frame = frame
end

function PQ.Toggle()
	Build()
	ui.frame:SetShown(not ui.frame:IsShown())
end

function PQ.Show()
	Build()
	ui.frame:Show()
	PQ.Refresh()
end

function PQ.SetItem(itemID, itemLink)
	Build()
	PQ.itemID = itemID
	PQ.item = itemLink
	PQ.scan = nil
	PQ.plan = nil
	PQ.Refresh()
end

function PQ.Rescan()
	if not GM.AH.open then
		ui.summary:SetText(GM.CC("warn") .. "auction house is not open|r")
		return
	end
	if not PQ.itemID then
		ui.summary:SetText(GM.CC("textDim") .. "pick an item first — drop one in the header|r")
		return
	end
	local name = GetInfo and GetInfo(PQ.itemID)
	GM.AH.ScanItem(PQ.itemID, name, function(asks)
		PQ.Solve(asks)
	end)
	ui.summary:SetText(GM.CC("textDim") .. "scanning…|r")
end

function PQ.Solve(asks)
	GM.AH.pendingConfirm = nil -- a rescan invalidates any staged quote
	PQ.scan = { n = #asks, cheapest = asks[1] and asks[1].unit }
	local entry = PQ.itemID and GM.ItemEntry(PQ.itemID)
	local p50 = entry and entry.p or (PQ.itemID and GM.TSMMarket(PQ.itemID))
	if not p50 then
		ui.summary:SetText(GM.CC("err") .. "no price estimate for this item yet|r")
		PQ.Refresh()
		return
	end
	local gold = GetMoney()
	local vel = entry and entry.vel
	local isCommodity = GM.AH.IsCommodity(PQ.itemID)
	local plan, err = GM.Solver.Plan(asks, p50, entry and entry.p90, gold, vel, {
		riskBudget = GM.db.riskBudget,
		minProfitMargin = GM.db.minProfitMargin,
		commodity = isCommodity,
		owned = GM.BagCount(PQ.itemID),
	})
	if not plan then
		ui.summary:SetText(GM.CC("warn") .. err .. "|r")
		PQ.plan = nil
		PQ.Refresh()
		return
	end
	for _, step in ipairs(plan.steps) do
		step.itemID = PQ.itemID
		step.item = PQ.item
		step.commodity = isCommodity
	end
	for _, lot in ipairs(plan.buyLots or {}) do
		lot.itemID = PQ.itemID
		lot.item = PQ.item
	end
	plan.bank = GM.BankCount(PQ.itemID)
	plan.deposit = GM.AH.DepositCost(PQ.itemID, plan.qty + (plan.owned or 0)) or 0
	plan.ev = plan.ev - plan.deposit
	PQ.plan = plan
	PQ.stepIndex = 1
	PQ.Refresh()
end

function PQ.ExecuteNext()
	-- a staged commodity buy: this click is the ConfirmCommoditiesPurchase
	if GM.AH.pendingConfirm then
		if GM.AH.Execute({ kind = "confirm" }) then
			PQ.stepIndex = PQ.stepIndex + 1
			GM.After(1.0, function() PQ.Rescan() end)
		end
		PQ.Refresh()
		return
	end
	local step = PQ.plan and PQ.plan.steps[PQ.stepIndex]
	if not step then return end
	local result = GM.AH.Execute(step)
	if result == "confirm" then
		PQ.Refresh()
		return
	end
	if result then
		PQ.stepIndex = PQ.stepIndex + 1
		-- book changed under us; a rescan keeps the plan honest
		GM.After(1.0, function() PQ.Rescan() end)
	end
	PQ.Refresh()
end

-- Skips the current step — for when the player decides not to do a buyout.
-- Aborts a staged commodity purchase (the quote expires server-side).
-- The staged-quote commodity flow produced nothing — splice the per-lot
-- buyout steps (auctionID'd PlaceBid calls) in place of the aggregate buy.
function PQ.CommodityFallback()
	if not (PQ.plan and PQ.plan.buyLots and #PQ.plan.buyLots > 0) then return end
	local steps = {}
	for _, s in ipairs(PQ.plan.steps) do
		if s.kind == "buy" and s.commodity then
			for _, lot in ipairs(PQ.plan.buyLots) do tinsert(steps, lot) end
		else
			tinsert(steps, s)
		end
	end
	PQ.plan.steps = steps
	PQ.plan.buyLots = nil
end

-- Skips the current step — always advances, never rewrites the plan.
-- A staged commodity purchase is dropped (the quote expires server-side).
function PQ.SkipStep()
	GM.AH.pendingConfirm = nil
	local plan = PQ.plan
	local step = plan and plan.steps[PQ.stepIndex]
	if step and step.kind == "buy" then
		-- declined to buy: the post leg shrinks by this lot, and
		-- spend/EV/days-to-clear get re-derived so the summary stays honest
		plan.qty = math.max(0, (plan.qty or 0) - step.qty)
		plan.spend = math.max(0, (plan.spend or 0) - step.unit * step.qty)
		local cheapest = PQ.scan and PQ.scan.cheapest
		local revenue = 0
		for _, s in ipairs(plan.steps) do
			if s.kind == "post" then
				local old = s.qty
				s.qty = math.max(0, s.qty - step.qty)
				if plan.daysToClear and old > 0 then
					plan.daysToClear = plan.daysToClear * s.qty / old
				end
				-- reprice to the book: don't post above the cheapest ask
				if cheapest and s.unit > cheapest then s.unit = cheapest end
				revenue = revenue + floor(s.unit * 0.95) * s.qty
			end
		end
		plan.ev = floor(revenue - plan.spend - (plan.deposit or 0))
	end
	if plan and PQ.stepIndex <= #plan.steps then
		PQ.stepIndex = PQ.stepIndex + 1
	end
	PQ.Refresh()
end

local function DrawChart(entry)
	for _, a in ipairs(ui.art) do a:Hide() end
	wipe(ui.art)
	ui.chart.msg:SetText("")

	-- the three anchors we actually have: historical, most-recent scan,
	-- current estimate. Real time-series arrives with snapshot storage.
	local pts = {}
	if entry then
		if entry.hist then tinsert(pts, { x = 0.05, v = entry.hist, tag = "hist" }) end
		if entry.recent and entry.recent ~= (entry.hist or 0) then
			tinsert(pts, { x = 0.5, v = entry.recent, tag = "recent" })
		end
		tinsert(pts, { x = 0.95, v = entry.p, tag = "est" })
	end
	if #pts < 2 then
		ui.chart.msg:SetText("trend chart — needs historical + current data")
		return
	end
	local lo, hi = math.huge, 0
	for _, p in ipairs(pts) do
		lo = math.min(lo, p.v)
		hi = math.max(hi, p.v)
	end
	if hi == lo then hi = lo + 1 end
	-- TradingView split: price line in the top region, volume bars below.
	local W = ui.chart:GetWidth() - 20
	local pad = 10
	local priceBase, priceTop = 62, ui.chart:GetHeight() - 18
	local volBase, volTop = 16, 52
	local function py(v) return priceBase + (v - lo) / (hi - lo) * (priceTop - priceBase) end
	for i, p in ipairs(pts) do
		p.px = pad + p.x * W
		p.py = py(p.v)
	end

	local function HRule(y, alpha)
		local t = ui.chart:CreateTexture(nil, "BACKGROUND")
		tinsert(ui.art, t)
		local r, g, b = GM.RGB("outlineVar")
		t:SetColorTexture(r, g, b, alpha or 0.8)
		t:SetSize(W, 1)
		t:SetPoint("LEFT", ui.chart, "BOTTOMLEFT", pad, y)
	end
	-- faint mid-grid + divider between price and volume regions
	HRule((priceBase + priceTop) / 2, 0.35)
	HRule(56)
	-- hi/lo scale labels on the right edge
	Label(ui.chart, pad + W - 28, priceTop + 2, GM.Money(hi), "secondary", 8)
	Label(ui.chart, pad + W - 28, priceBase - 6, GM.Money(lo), "secondary", 8)

	for i = 2, #pts do
		Segment(ui.chart, pts[i - 1].px, pts[i - 1].py, pts[i].px, pts[i].py)
	end
	for _, p in ipairs(pts) do
		local isEst = p.tag == "est"
		Dot(ui.chart, p.px, p.py, isEst and 5 or 4, isEst and "accent" or "textDim")
		Label(ui.chart, p.px, p.py + 9, p.tag .. " " .. GM.Money(p.v), isEst and "accent" or "textDim")
	end
	for _, v in ipairs({ entry.p10, entry.p90 }) do
		if v and v >= lo and v <= hi then
			HRule(py(v), 0.8)
		end
	end
	-- volume panel: gold-denominated daily turnover + listed value
	if entry.p then
		local bars = {}
		if entry.vel and entry.vel > 0 then
			tinsert(bars, { x = 0.28, v = entry.vel * entry.p, tag = "vol/day", col = "accent" })
		end
		if entry.sup and entry.sup > 0 then
			tinsert(bars, { x = 0.72, v = entry.sup * entry.p, tag = "listed", col = "outline" })
		end
		local vmax = 0
		for _, b in ipairs(bars) do vmax = math.max(vmax, b.v) end
		if vmax > 0 then
			for _, b in ipairs(bars) do
				local bh = math.max(2, (b.v / vmax) * (volTop - volBase))
				local bar = ui.chart:CreateTexture(nil, "ARTWORK")
				tinsert(ui.art, bar)
				local r2, g2, b2 = GM.RGB(b.col)
				bar:SetColorTexture(r2, g2, b2, 0.85)
				bar:SetSize(W * 0.18, bh)
				bar:SetPoint("BOTTOM", ui.chart, "BOTTOMLEFT", pad + b.x * W, volBase)
				Label(ui.chart, pad + b.x * W, 5, b.tag .. " " .. GM.Money(b.v))
			end
		end
	end
end

function PQ.Refresh()
	Build()
	local age = GM.DataAge()
	ui.age:SetText(age and format("data %dm old", age / 60) or "no data file")

	-- header: icon, name, type/id, flow
	local entry = PQ.itemID and GM.ItemEntry(PQ.itemID)
	local book = PQ.itemID and (PQ.scan
		and (PQ.scan.n > 0
			and format(" · book: %d asks · cheapest %s", PQ.scan.n, GM.Money(PQ.scan.cheapest))
			or " · book: empty")
		or " · RESCAN to read the book") or ""
	ui.item.name:SetText((PQ.item or (PQ.itemID and ("item " .. PQ.itemID)) or "no item")
		.. GM.CC("textDim") .. book .. "|r")
	if not PQ.itemID then
		ui.item.name:SetText(GM.CC("textDim") .. "no item — drop one here · alt-click one · /goblin [link]|r")
	end
	local icon = PQ.itemID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(PQ.itemID)
	if not icon and PQ.itemID and GetInfo then
		icon = select(10, GetInfo(PQ.itemID))
	end
	if icon then ui.icon:SetTexture(icon) ui.icon:Show() else ui.icon:Hide() end
	local sub = {}
	if PQ.itemID then tinsert(sub, "id " .. PQ.itemID) end
	if PQ.itemID and GetInfo then
		local _, _, _, _, _, itemType = GetInfo(PQ.itemID)
		if itemType then tinsert(sub, 1, itemType) end
	end
	if entry and entry.vel then tinsert(sub, "sells ~" .. entry.vel .. "/day") end
	if entry and entry.sup then tinsert(sub, "supply " .. entry.sup) end
	ui.item.sub:SetText(table.concat(sub, " · "))

	-- stats column
	local market = PQ.itemID and GM.TSMMarket(PQ.itemID)
	local p = (entry and entry.p) or market
	local function set(k, v) ui.statText[k]:SetText(v or "") end
	local function pct(a, b)
		if not (a and b and b > 0) then return nil end
		local d = (a - b) / b * 100
		if d > -0.5 and d < 0.5 then return nil end
		local key = d > 0 and "pos" or "err"
		return GM.CC(key) .. format("%+.0f%%", d) .. "|r"
	end
	set("est", p and GM.Money(p))
	set("band", (entry and entry.p10 and entry.p90) and (GM.Money(entry.p10) .. "–" .. GM.Money(entry.p90)))
	set("vs TSM", entry and pct(entry.p, market))
	set("hist", (entry and entry.hist)
		and (GM.Money(entry.hist) .. " " .. (pct(p, entry.hist) or "")))
	set("recent", entry and pct(entry.recent, p))
	set("min buy", PQ.scan and PQ.scan.cheapest and GM.Money(PQ.scan.cheapest))
	set("sells/day", entry and entry.vel and tostring(entry.vel))
	set("supply", entry and entry.sup and tostring(entry.sup))
	set("reset", entry and entry.reset and (GM.Money(entry.reset.below) .. " · ev " .. GM.Money(entry.reset.ev)))
	set("itemID", PQ.itemID and (GM.CC("textDim") .. tostring(PQ.itemID) .. "|r"))
	set("gold", GM.Money(GetMoney()))
	set("risk", GM.db and GM.Money(GM.db.riskBudget))
	set("margin", GM.db and format("%.0f%%", (GM.db.minProfitMargin or 0) * 100))
	set("data", age and format("%dm old", age / 60) or "none")

	DrawChart(entry)

	-- plan rows
	for i = 1, ROWS do
		local row = ui.rows[i]
		local step = PQ.plan and PQ.plan.steps[i]
		if step then
			row:Show()
			local active = i == PQ.stepIndex
			row.edge:SetShown(active)
			row.num:SetText(GM.CC("textDim") .. i .. "|r")
			local verb = step.kind == "post" and "POST" or "BUY"
			if active then
				row.act:SetText(GM.CC("accent") .. verb .. " ▶|r")
			else
				row.act:SetText(GM.CC(step.kind == "post" and "pos" or "text") .. verb .. "|r")
			end
			row.qty:SetText(step.qty .. (step.kind == "post" and " (relist)" or ""))
			row.price:SetText(GM.Money(step.unit) .. (step.kind == "post" and "" or " /ea"))
		else
			row:Hide()
		end
	end

	if PQ.plan then
		local verdict, note = GM.Solver.Verdict(PQ.plan, GM.db)
		local clear = PQ.plan.daysToClear and format(" · clears ~%.1fd", PQ.plan.daysToClear) or ""
		local own = (PQ.plan.owned or 0) > 0 and (" · own " .. PQ.plan.owned) or ""
		if (PQ.plan.bank or 0) > 0 then own = own .. " +" .. PQ.plan.bank .. " bank" end
		if PQ.plan.qty == 0 then own = own .. GM.CC("warn") .. " · no buy path — relist only" .. GM.CC("textDim") end
		local dep = (PQ.plan.deposit or 0) > 0 and (" · dep " .. GM.Money(PQ.plan.deposit)) or ""
		ui.sumEdge:SetColorTexture(GM.RGB(verdict == "good" and "pos" or "warn"))
		ui.summary:SetText(format("%sspend %s%s%s · ev %s%s · %s|r",
			verdict == "good" and GM.CC("textDim") or GM.CC("warn"),
			GM.Money(PQ.plan.spend), own, dep, GM.Money(PQ.plan.ev), clear, note))
		ui.exec:Show()
		if GM.AH.pendingConfirm then
			ui.exec.text:SetText("CONFIRM PURCHASE")
		else
			ui.exec.text:SetText(PQ.stepIndex > #PQ.plan.steps and "PLAN DONE" or "EXECUTE NEXT STEP")
		end
		ui.exec:SetEnabled(GM.AH.pendingConfirm ~= nil or (PQ.stepIndex <= #PQ.plan.steps and GM.AH.open))
		ui.skip:Show()
		ui.skip:SetEnabled(GM.AH.pendingConfirm ~= nil or PQ.stepIndex <= #PQ.plan.steps)
	else
		ui.sumEdge:SetColorTexture(GM.RGB("outlineVar"))
		ui.exec:Hide()
		ui.skip:Hide()
	end
end
