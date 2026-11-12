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

local function Segment(parent, x1, y1, x2, y2, key)
	local dx, dy = x2 - x1, y2 - y1
	local steps = math.max(1, floor(sqrt(dx * dx + dy * dy) / 2))
	for i = 0, steps do
		Dot(parent, x1 + dx * i / steps, y1 + dy * i / steps, 2, key or "accent")
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
	-- convention on this client: "normal" windows live on HIGH — TSM's
	-- ApplicationFrame and EllesmereUI's skinned Blizzard panels both.
	-- SetToplevel gives click-to-raise so we stack WITH them instead of
	-- pinned above (FULLSCREEN_DIALOG) or buried under (MEDIUM).
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	-- manual raise on click: SetToplevel's auto-raise may be a no-op on
	-- this client; Raise() bumps us to top of HIGH — TSM/Blizzard handle
	-- their own clicks, so last-clicked wins like a normal window
	frame:SetScript("OnMouseDown", function(f)
		if f.Raise then f:Raise() elseif RaiseFrame then RaiseFrame(f) end
	end)
	GM.Panel(frame, "contLow", "outlineVar")
	tinsert(UISpecialFrames, "GoblinMindPlanFrame")

	local title = GM.MakeFontString(frame, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 14, -10)
	title:SetText("GOBLINMIND")

	-- scan buttons ride the title row, TSM-tab style
	local function TitleBtn(label, w, onclick)
		local b = CreateFrame("Button", nil, frame)
		b:SetSize(w, 16)
		GM.Panel(b, "contMedium")
		b.text = GM.MakeFontString(b, GM.FONT_MED, 9, "secondary")
		b.text:SetAllPoints()
		b.text:SetText(label)
		b:SetScript("OnClick", onclick)
		b:SetScript("OnEnter", function() GM.Panel(b, "contHigh") end)
		b:SetScript("OnLeave", function() GM.Panel(b, "contMedium") end)
		return b
	end
	ui.postScan = TitleBtn("POST SCAN", 74, function() GM.Auctioning.PostScan() end)
	ui.postScan:SetPoint("LEFT", title, "RIGHT", 12, -1)
	ui.cancelScan = TitleBtn("CANCEL SCAN", 84, function() GM.Auctioning.CancelScan() end)
	ui.cancelScan:SetPoint("LEFT", ui.postScan, "RIGHT", 6, 0)

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

-- transient scan-progress line (post/cancel scans write here while
-- their serialized book queries work through the queue)
function PQ.ScanStatus(text)
	Build()
	ui.summary:SetText(text)
end

-- a scan that produced no steps drops the stale plan so the window
-- isn't left showing rows/buttons for something already finished
function PQ.ClearPlan()
	PQ.plan = nil
	PQ.Refresh()
end

-- a multi-item plan from a post/cancel scan — steps carry their own
-- itemID/name, execution goes through the same click-per-step path
function PQ.SetScanPlan(plan)
	Build()
	PQ.plan = plan
	PQ.stepIndex = 1
	PQ.Refresh()
end

function PQ.SetItem(itemID, itemLink)
	Build()
	PQ.itemID = itemID
	PQ.item = itemLink
	PQ.scan = nil
	PQ.plan = nil
	PQ.Refresh()
	if GM.GroupsUI and GM.GroupsUI.Retarget then GM.GroupsUI.Retarget() end
end

function PQ.Rescan()
	if not GM.AH.open then
		ui.summary:SetText(GM.CC("warn") .. "auction house is not open|r")
		return
	end
	if PQ.plan and PQ.plan.mode == "postscan" then GM.Auctioning.PostScan() return end
	if PQ.plan and PQ.plan.mode == "cancelscan" then GM.Auctioning.CancelScan() return end
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
	-- group ops: auctioning drives post price/cap/stack/undercut,
	-- shopping.belowPct is the buy-margin gate (replaces minProfitMargin)
	local aOps = GM.Groups.GetOps(PQ.itemID, "auctioning")
	local sOps = GM.Groups.GetOps(PQ.itemID, "shopping")
	local function ev(f) return GM.Groups.EvalOp(aOps, f, PQ.itemID) end
	local plan, err = GM.Solver.Plan(asks, p50, entry and entry.p90, gold, vel, {
		riskBudget = GM.db.riskBudget,
		minProfitMargin = (tonumber(sOps.belowPct) or 10) / 100,
		commodity = isCommodity,
		owned = GM.BagCount(PQ.itemID),
		normal = ev("normal"),
		minP = ev("min"),
		maxP = ev("max"),
		postCap = tonumber(aOps.postCap),
		stackSize = tonumber(aOps.stackSize),
	})
	if plan then
		plan.undercut = ev("undercut") or 0
	end
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
		-- single-item plans rescan after each action; scan-mode plans are
		-- independent steps — re-querying the book per click would stall
		if not (PQ.plan and PQ.plan.mode) then
			GM.After(1.0, function() PQ.Rescan() end)
		end
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
				-- reprice to the book, TSM-style: cheapest minus undercut
				local uc = plan.undercut or 0
				if cheapest and s.unit > cheapest - uc then
					s.unit = math.max(1, cheapest - uc)
				end
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

local function DrawChart(entry, itemID)
	for _, a in ipairs(ui.art) do a:Hide() end
	wipe(ui.art)
	ui.chart.msg:SetText("")

	-- a real 1-week series from GoblinMindHistory once it has ≥2 points;
	-- until then the three data anchors (hist/recent/est) stand in
	local pts, weekMode = {}, false
	if entry and itemID and GM.History then
		local series = GM.History.Points(itemID, 7 * 86400)
		if #series >= 2 then
			weekMode = true
			local t0 = time() - 7 * 86400
			for _, p in ipairs(series) do
				local x = (p.t - t0) / (7 * 86400)
				tinsert(pts, { x = x < 0 and 0 or x > 1 and 1 or x, v = p.p })
			end
			tinsert(pts, { x = 1.0, v = entry.p }) -- live estimate at "now"
		end
	end
	if not weekMode and entry then
		if entry.hist then tinsert(pts, { x = 0.05, v = entry.hist, tag = "hist" }) end
		if entry.recent and entry.recent ~= (entry.hist or 0) then
			tinsert(pts, { x = 0.5, v = entry.recent, tag = "recent" })
		end
		tinsert(pts, { x = 0.95, v = entry.p, tag = "est" })
	end
	ui.chart.title:SetText(weekMode and "PRICE · VOLUME · 7D" or "PRICE · VOLUME")
	if #pts < 2 then
		ui.chart.msg:SetText("trend chart — building a 7-day series, check back tomorrow")
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
	-- day-boundary gridlines across the 7-day window
	if weekMode then
		for d = 1, 6 do
			local gx = pad + d / 7 * W
			Segment(ui.chart, gx, volBase, gx, priceTop, "outlineVar")
		end
	end
	-- hi/lo scale labels on the right edge
	Label(ui.chart, pad + W - 28, priceTop + 2, GM.Money(hi), "secondary", 8)
	Label(ui.chart, pad + W - 28, priceBase - 6, GM.Money(lo), "secondary", 8)

	for i = 2, #pts do
		Segment(ui.chart, pts[i - 1].px, pts[i - 1].py, pts[i].px, pts[i].py)
	end
	for i, p in ipairs(pts) do
		local endpoint = i == 1 or i == #pts
		local hot = (weekMode and i == #pts) or p.tag == "est"
		if not weekMode or endpoint then
			Dot(ui.chart, p.px, p.py, hot and 5 or 4, hot and "accent" or "textDim")
			-- labels sit above the point unless that would reach the title
			local ly = p.py + 9
			if ly > priceTop - 6 then ly = p.py - 16 end
			local tag = p.tag and p.tag .. " " or (weekMode and i == #pts and "now " or "")
			Label(ui.chart, p.px, ly, tag .. GM.Money(p.v), hot and "accent" or "textDim")
		end
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

	-- header: icon, name, type/id, flow. For scan plans the display
	-- follows the active step's item; single-item plans keep the target.
	local stepN = PQ.plan and math.min(PQ.stepIndex, #PQ.plan.steps)
	local curStep = PQ.plan and PQ.plan.steps[stepN]
	local scanMode = PQ.plan and PQ.plan.mode and curStep
	local dispID = scanMode and curStep.itemID or PQ.itemID
	local dispLink = scanMode and (curStep.item or curStep.name) or PQ.item
	local entry = dispID and GM.ItemEntry(dispID)
	local book
	if scanMode then
		book = format(" · step %d/%d", stepN, #PQ.plan.steps)
	else
		book = dispID and (PQ.scan
			and (PQ.scan.n > 0
				and format(" · book: %d asks · cheapest %s", PQ.scan.n, GM.Money(PQ.scan.cheapest))
				or " · book: empty")
			or " · RESCAN to read the book") or ""
	end
	ui.item.name:SetText((dispLink or (dispID and ("item " .. dispID)) or "no item")
		.. GM.CC("textDim") .. book .. "|r")
	if not dispID then
		ui.item.name:SetText(GM.CC("textDim") .. "no item — drop one here · alt-click one · /goblin [link]|r")
	end
	local icon = dispID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(dispID)
	if not icon and dispID and GetInfo then
		icon = select(10, GetInfo(dispID))
	end
	if icon then ui.icon:SetTexture(icon) ui.icon:Show() else ui.icon:Hide() end
	local sub = {}
	if dispID then tinsert(sub, "id " .. dispID) end
	if dispID and GetInfo then
		local _, _, _, _, _, itemType = GetInfo(dispID)
		if itemType then tinsert(sub, 1, itemType) end
	end
	if entry and entry.vel then tinsert(sub, "sells ~" .. entry.vel .. "/day") end
	if entry and entry.sup then tinsert(sub, "supply " .. entry.sup) end
	ui.item.sub:SetText(table.concat(sub, " · "))

	-- stats column
	local market = dispID and GM.TSMMarket(dispID)
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
	local minBuy = scanMode and curStep.cheapest or (PQ.scan and PQ.scan.cheapest)
	set("min buy", minBuy and GM.Money(minBuy))
	set("sells/day", entry and entry.vel and tostring(entry.vel))
	set("supply", entry and entry.sup and tostring(entry.sup))
	set("reset", entry and entry.reset and (GM.Money(entry.reset.below) .. " · ev " .. GM.Money(entry.reset.ev)))
	set("itemID", dispID and (GM.CC("textDim") .. tostring(dispID) .. "|r"))
	set("gold", GM.Money(GetMoney()))
	set("risk", GM.db and GM.Money(GM.db.riskBudget))
	set("margin", GM.db and format("%.0f%%", (GM.db.minProfitMargin or 0) * 100))
	set("data", age and format("%dm old", age / 60) or "none")

	DrawChart(entry, dispID)

	-- plan rows — a window into steps that follows the active step
	local off = 0
	if PQ.plan and #PQ.plan.steps > ROWS then
		off = math.min(math.max(PQ.stepIndex - 1, 0), #PQ.plan.steps - ROWS)
	end
	for i = 1, ROWS do
		local row = ui.rows[i]
		local n = i + off
		local step = PQ.plan and PQ.plan.steps[n]
		if step then
			row:Show()
			local active = n == PQ.stepIndex
			row.edge:SetShown(active)
			row.num:SetText(GM.CC("textDim") .. n .. "|r")
			local verb = step.kind == "post" and "POST"
				or step.kind == "cancel" and "CANCEL" or "BUY"
			if active then
				row.act:SetText(GM.CC("accent") .. verb .. " ▶|r")
			else
				row.act:SetText(GM.CC(step.kind == "post" and "pos"
					or step.kind == "cancel" and "warn" or "text") .. verb .. "|r")
			end
			if PQ.plan.mode then
				local nm = step.name or ""
				if #nm > 16 then nm = nm:sub(1, 15) .. "…" end
				row.qty:SetText(nm .. " ×" .. step.qty)
			else
				row.qty:SetText(step.qty .. (step.kind == "post" and " (relist)" or ""))
			end
			row.price:SetText(GM.Money(step.unit) .. (step.kind == "post" and "" or " /ea"))
		else
			row:Hide()
		end
	end

	if PQ.plan then
		if PQ.plan.mode == "postscan" then
			ui.sumEdge:SetColorTexture(GM.RGB("accent"))
			ui.summary:SetText(format("post scan: %d posts across %d items · est %s · dep %s|r",
				#PQ.plan.steps, PQ.plan.itemCount or 0,
				GM.Money(PQ.plan.ev or 0), GM.Money(PQ.plan.deposit or 0)))
		elseif PQ.plan.mode == "cancelscan" then
			ui.sumEdge:SetColorTexture(GM.RGB("warn"))
			ui.summary:SetText(format("cancel scan: %d undercut auction%s — one click each|r",
				#PQ.plan.steps, #PQ.plan.steps == 1 and "" or "s"))
		else
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
		end
		ui.exec:Show()
		if GM.AH.pendingConfirm then
			ui.exec.text:SetText("CONFIRM PURCHASE")
		else
			local verb = PQ.plan.mode == "cancelscan" and "CANCEL NEXT"
				or PQ.plan.mode == "postscan" and "POST NEXT" or "EXECUTE NEXT STEP"
			ui.exec.text:SetText(PQ.stepIndex > #PQ.plan.steps and "PLAN DONE" or verb)
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
