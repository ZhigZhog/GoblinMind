local _, GM = ...

-- TSM-styled plan window: item header, verbose stats column, trend
-- region, and the click-per-step queue. Every protected auction call is
-- still one hardware click — this file only arranges information.

GM.PlanQueue = { plan = nil, stepIndex = 1, itemID = nil, item = nil }

local PQ = GM.PlanQueue
local ROWS = 6
local ui = { art = {} }
-- forward declarations: Build's OnUpdate tick and Refresh both call
-- these, but the definitions sit below Build in source order
local PlanFrac, ApplyProg, protD
PQ.protectedOk = PQ.protectedOk or {}
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

-- justify anchors LEFT/RIGHT edges at x; default centers on x
local function Label(parent, x, y, str, colorKey, size, justify)
	local fs = GM.MakeFontString(parent, GM.FONT, size or 9, colorKey or "textDim")
	tinsert(ui.art, fs)
	fs:SetPoint(justify == "LEFT" and "BOTTOMLEFT"
		or justify == "RIGHT" and "BOTTOMRIGHT" or "CENTER",
		parent, "BOTTOMLEFT", x, y)
	fs:SetJustifyH(justify or "CENTER")
	fs:SetText(str)
	return fs
end

local function BuildRow(parent, i)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(22)
	row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
	row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 22)
	GM.Panel(row, i % 2 == 0 and "contLow" or "contLowest", "contLowest")
	row.edge = row:CreateTexture(nil, "ARTWORK")
	row.edge:SetPoint("TOPLEFT")
	row.edge:SetPoint("BOTTOMLEFT")
	row.edge:SetWidth(3)
	row.edge:SetColorTexture(GM.RGB("accent"))
	row.edge:Hide()
	row.num   = GM.MakeFontString(row, GM.FONT_MED, 11, "textDim")
	row.num:SetPoint("LEFT", 10, 0)
	row.num:SetWidth(18)
	row.num:SetJustifyH("LEFT")
	row.num:SetWordWrap(false)
	row.act   = GM.MakeFontString(row, GM.FONT_MED, 11, "text")
	row.act:SetPoint("LEFT", 34, 0)
	row.act:SetWidth(100)
	row.act:SetJustifyH("LEFT")
	row.act:SetWordWrap(false)
	row.qty   = GM.MakeFontString(row, GM.FONT, 11, "textDim")
	row.qty:SetPoint("LEFT", 140, 0)
	-- both text columns get hard bounds: a long name clips right,
	-- a long desc clips left instead of sliding under the name
	row.qty:SetPoint("RIGHT", -176, 0)
	row.qty:SetWordWrap(false)
	row.price = GM.MakeFontString(row, GM.FONT_MED, 11, "text")
	row.price:SetPoint("RIGHT", -10, 0)
	row.price:SetPoint("LEFT", 288, 0)
	row.price:SetWordWrap(false)
	row.price:SetJustifyH("RIGHT")
	return row
end

-- grouped label/value rows for the stats column. Labels are dynamic
-- where the source varies (live book vs DB snapshot) — ui.statLabel.
local STAT_SECTIONS = {
	{ "VALUE",   { "ref price", "ref ±15%" } },
	{ "TREND",   { "hist", "recent" } },
	{ "MARKET",  { "min buy", "region/day", "units" } },
	{ "SIGNAL",  { "reset" } },
	{ "ACCOUNT", { "gold", "budget cap", "margin" } },
}
local function BuildStats(parent)
	ui.statText = {}
	ui.statLabel = {}
	local y, rowH = -28, 18
	for _, sec in ipairs(STAT_SECTIONS) do
		local h = GM.MakeFontString(parent, GM.FONT_MED, 10, "primary")
		h:SetPoint("TOPLEFT", 8, y)
		h:SetText(sec[1])
		y = y - 15
		for i, key in ipairs(sec[2]) do
			if i % 2 == 1 then
				local bg = parent:CreateTexture(nil, "BACKGROUND")
				bg:SetPoint("TOPLEFT", 4, y)
				bg:SetPoint("TOPRIGHT", -4, y)
				h:SetWordWrap(false)
				bg:SetHeight(rowH)
				bg:SetColorTexture(GM.RGB("contLowest"))
			end
			local lab = GM.MakeFontString(parent, GM.FONT, 11, "textDim")
			lab:SetPoint("TOPLEFT", 10, y - 4)
			lab:SetText(key)
			ui.statLabel[key] = lab
			local val = GM.MakeFontString(parent, GM.FONT_MED, 11, "text")
			val:SetPoint("TOPRIGHT", -10, y - 4)
			val:SetJustifyH("RIGHT")
			ui.statText[key] = val
			y = y - rowH
		end
		y = y - 9
	end
	local hint = GM.MakeFontString(parent, GM.FONT, 10, "textDim")
	hint:SetPoint("BOTTOMLEFT", 10, 8)
	hint:SetText("drop · shift-click · /goblin [link]")
end

local PAD, GAP = 10, 8
local WIN_W = 768
local LEFT_W = 464

-- step-table column labels per plan kind — mode'd plans put the item
-- name in col 3 and step.desc/source detail in col 4, so the headers
-- say what the function actually shows instead of always "QTY/PRICE"
local HEAD_COLS = {
	postscan     = { "ITEM", "POST @" },
	cancelscan   = { "ITEM", "UNDER @" },
	shopscan     = { "ITEM", "BUY @" },
	craft        = { "ITEM", "SOURCE" },
	vendoring    = { "ITEM", "VENDOR" },
	warehousing  = { "ITEM", "WHERE" },
	mailing      = { "ITEM", "TO" },
	destroying   = { "ITEM", "VALUE" },
}

local function Build()
	if ui.frame then return end

	-- strata/raise convention lives in W.Window: HIGH + Toplevel +
	-- manual raise = stack WITH TSM/Ellesmere panels, last-clicked wins
	local frame = GM.Widgets.Window({
		name = "GoblinMindPlanFrame", w = WIN_W, h = 542,
		noChrome = true, -- title strip/close here are bespoke
	})
	-- the bar animates within a step (cast progress) — Refresh is
	-- event-driven so a 4s cast would sit still between events; a
	-- 0.1s tick on the window keeps it moving while a plan is armed
	local tick = 0
	frame:SetScript("OnUpdate", function(_, dt)
		tick = tick + dt
		if tick < 0.1 then return end
		tick = 0
		if ui.scanFrac or not ui.planFrac then return end
		ui.planFrac = PlanFrac()
		ApplyProg()
	end)

	local title = GM.MakeFontString(frame, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 14, -10)
	title:SetText("GOBLINMIND")
	ui.titleFs = title
	-- module tab strip rides the title row like every other window —
	-- dash↔plan is a mode of this window, so the strip rebuilds on
	-- Refresh when the current key flips
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(frame, title,
			PQ.homeMode and "dash" or "plan")
	end
	-- first-show font heal: the window builds HIDDEN at login (Prewarm)
	-- and fontstrings on a hidden frame may never rasterize — the
	-- one-shot login FixupFonts can't reach text that only exists after
	-- that. Re-applying on show covers whatever shape the first-load
	-- failure takes; cheap no-op once fonts are live.
	frame:HookScript("OnShow", function()
		if GM.FixupFonts then GM.FixupFonts() end
	end)

	-- scan buttons ride the title strip — subtle button rects so they
	-- read as actions, not navigation tabs
	local function TitleBtn(label, w, onclick, tip)
		local b = CreateFrame("Button", nil, frame)
		b:SetSize(w, 22)
		GM.Panel(b, "contHigh", "outlineVar")
		b.text = GM.MakeFontString(b, GM.FONT_MED, 11, "text")
		b.text:SetPoint("CENTER")
	b.text:SetWordWrap(false)
		b.text:SetText(label)
		b:SetScript("OnClick", onclick)
		b:SetScript("OnEnter", function()
			GM.Panel(b, "contHighest", "outlineVar")
			b.text:SetTextColor(GM.RGB("accent"))
			if tip then GM.Widgets.HintShow(b, { tip }) end
		end)
		b:SetScript("OnLeave", function()
			GM.Panel(b, "contHigh", "outlineVar")
			b.text:SetTextColor(GM.RGB("text"))
			GM.Widgets.HintHide()
		end)
		return b
	end
	-- action buttons ride a dedicated strip under the title bar —
	-- navigation lives in the shared tab strip; these are the
	-- window-specific actions only
	ui.postScan = TitleBtn("POST SCAN", 84, function() GM.Auctioning.PostScan() end,
		"Scan bag items for posting")
	ui.postScan:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -30)
	ui.cancelScan = TitleBtn("CANCEL SCAN", 104, function() GM.Auctioning.CancelScan() end,
		"Scan own auctions for undercuts")
	ui.cancelScan:SetPoint("LEFT", ui.postScan, "RIGHT", 8, 0)
	ui.fullScan = TitleBtn("FULL SCAN", 84, function() GM.AH.FullScan() end,
		"Refresh the full AH book")
	ui.fullScan:SetPoint("LEFT", ui.cancelScan, "RIGHT", 8, 0)

	ui.age = GM.MakeFontString(frame, GM.FONT, 10, "textDim")
	ui.age:SetWidth(200)
	ui.age:SetJustifyH("LEFT")
	ui.age:SetWordWrap(false)

	local close = CreateFrame("Button", nil, frame)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -PAD, -26)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetWordWrap(false)
	close.text:SetText("×")
	close:SetScript("OnClick", function() frame:Hide() end)
	close:SetScript("OnEnter", function() close.text:SetTextColor(GM.RGB("text")) end)
	close:SetScript("OnLeave", function() close.text:SetTextColor(GM.RGB("textDim")) end)
	-- freshness text lives on the action-strip row's right edge —
	-- the title row is title + module tabs now and a long age string
	-- collides with the last tabs
	ui.age:SetPoint("TOPRIGHT", -40, -33)

	local rule = frame:CreateTexture(nil, "BORDER")
	rule:SetColorTexture(GM.RGB("outlineVar"))
	rule:SetPoint("TOPLEFT", PAD, -56)
	rule:SetPoint("TOPRIGHT", -PAD, -56)
	rule:SetHeight(1)

	-- ===== left column =====

	-- Item header: the shared slot widget — RefreshItemText owns
	-- name/sub content (scan state, step display, soulbound flags)
	ui.item = GM.Widgets.ItemSlot(frame, {
		icon = 44, w = LEFT_W,
		hint = "drop item here · shift-click one · /goblin [link]",
		onItem = function(id, link) GM.TargetItem(id, link) end,
	})
	ui.item:SetPoint("TOPLEFT", PAD, -64)
	ui.icon, ui.iconBtn = ui.item.icon, ui.item.iconBtn

	-- Trend chart region
	ui.chart = CreateFrame("Frame", nil, frame)
	ui.chart:SetPoint("TOPLEFT", PAD, -128)
	ui.chart:SetWidth(LEFT_W)
	ui.chart:SetHeight(150)
	GM.Panel(ui.chart, "contLowest")
	if GM.ChromePanel then GM.ChromePanel(ui.chart) end
	ui.chart.title = GM.MakeFontString(ui.chart, GM.FONT_MED, 10, "primary")
	ui.chart.title:SetPoint("TOPLEFT", 8, -5)
	ui.chart.title:SetText("PRICE · VOLUME")
	ui.chart.msg = GM.MakeFontString(ui.chart, GM.FONT, 10, "textDim")
	ui.chart.msg:SetPoint("CENTER", 0, -8)
	-- nothing drawn may escape the chart region
	if ui.chart.SetClipsChildren then ui.chart:SetClipsChildren(true) end
	-- hover surfaces: the chart explains its coverage; the lower band
	-- explains the derived-metric readouts (armed only when drawn)
	ui.chart:EnableMouse(true)
	GM.Widgets.Tip(ui.chart, function() return ui.chart.tipLines end)
	ui.chart.readsHover = CreateFrame("Frame", nil, ui.chart)
	ui.chart.readsHover:SetPoint("BOTTOMLEFT", 8, 8)
	ui.chart.readsHover:SetPoint("BOTTOMRIGHT", -80, 8)
	ui.chart.readsHover:SetHeight(48)
	ui.chart.readsHover:EnableMouse(false)
	GM.Widgets.Tip(ui.chart.readsHover,
		"Derived at reference price — not realized sales")

	-- Steps header
	ui.header = CreateFrame("Frame", nil, frame)
	local header = ui.header
	header:SetPoint("TOPLEFT", PAD, -286)
	header:SetWidth(LEFT_W)
	header:SetHeight(18)
	GM.Panel(header, "contHigh")
	if GM.ChromePanel then GM.ChromePanel(header, { l = 6, t = 6, r = 6, b = 6 }) end
	ui.headerCols = {}
	for _, h in ipairs({ { "#", "LEFT", 10 }, { "ACTION", "LEFT", 34 }, { "QTY", "LEFT", 140 }, { "UNIT PRICE", "RIGHT", -10 } }) do
		local fs = GM.MakeFontString(header, GM.FONT_MED, 10, "primary")
		fs:SetPoint(h[2], h[3], 0)
		fs:SetText(h[1])
		ui.headerCols[h[1]] = fs
	end

	-- Step rows
	ui.list = CreateFrame("Frame", nil, frame)
	ui.list:SetPoint("TOPLEFT", PAD, -306)
	ui.list:SetWidth(LEFT_W)
	ui.list:SetHeight(ROWS * 22 + 8)
	GM.Panel(ui.list, "contLowest")
	if GM.ChromePanel then GM.ChromePanel(ui.list) end
	ui.list:EnableMouseWheel(true)
	ui.list:SetScript("OnMouseWheel", function(_, d)
		local maxOff = math.max(0,
			(PQ.plan and #PQ.plan.steps or 0) - ROWS)
		ui.manualOff = math.min(math.max(
			(ui.stepOff or 0) - d * 2, 0), maxOff)
		PQ.Refresh()
	end)
	ui.rows = {}
	for i = 1, ROWS do ui.rows[i] = BuildRow(ui.list, i) end

	-- ===== right column: grouped stats, full height =====
	ui.stats = CreateFrame("Frame", nil, frame)
	local stats = ui.stats
	stats:SetPoint("TOPRIGHT", -PAD, -64)
	stats:SetPoint("BOTTOMRIGHT", -PAD, PAD)
	stats:SetWidth(WIN_W - 2 * PAD - GAP - LEFT_W)
	GM.Panel(stats, "contLow")
	if GM.ChromePanel then GM.ChromePanel(stats) end
	local stTitle = GM.MakeFontString(stats, GM.FONT_MED, 10, "primary")
	stTitle:SetPoint("TOPLEFT", 8, -6)
	stTitle:SetText("ITEM & ACCOUNT")
	BuildStats(stats)

	-- Summary strip: verdict-colored left edge + wrapped text
	ui.sumBar = CreateFrame("Frame", nil, frame)
	ui.sumBar:SetPoint("BOTTOMLEFT", PAD, 46)
	ui.sumBar:SetSize(LEFT_W, 42)
	GM.Panel(ui.sumBar, "contLowest")
	if GM.ChromePanel then GM.ChromePanel(ui.sumBar, { l = 6, t = 6, r = 6, b = 6 }) end
	ui.sumEdge = ui.sumBar:CreateTexture(nil, "ARTWORK")
	ui.sumEdge:SetPoint("TOPLEFT")
	ui.sumEdge:SetPoint("BOTTOMLEFT")
	ui.sumEdge:SetWidth(3)
	ui.sumEdge:SetColorTexture(GM.RGB("accent"))
	-- two controlled lines: verdict/status on top, costs/result below
	ui.summary = GM.MakeFontString(ui.sumBar, GM.FONT_MED, 11, "text")
	ui.summary:SetPoint("TOPLEFT", 10, -6)
	ui.summary:SetPoint("TOPRIGHT", -6, -6)
	ui.summary:SetJustifyH("LEFT")
	ui.summary2 = GM.MakeFontString(ui.sumBar, GM.FONT, 10, "textDim")
	ui.summary2:SetPoint("TOPLEFT", ui.summary, "BOTTOMLEFT", 0, -3)
	ui.summary2:SetPoint("TOPRIGHT", ui.summary, "BOTTOMRIGHT", 0, -3)
	ui.summary2:SetJustifyH("LEFT")
	ui.summary:SetWordWrap(false)
	-- thin progress bar along the bottom edge of the summary strip
	ui.prog = ui.sumBar:CreateTexture(nil, "ARTWORK")
	ui.prog:SetPoint("BOTTOMLEFT", 0, 0)
	ui.summary2:SetWordWrap(false)
	ui.prog:SetHeight(2)
	ui.prog:SetColorTexture(GM.RGB("accent"))
	ui.prog:Hide()

	-- buttons align under the left column (the plan table's edge)
	ui.exec = CreateFrame("Button", nil, frame)
	ui.exec:SetSize(190, 30)
	ui.exec:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", PAD + LEFT_W, 8)
	GM.Panel(ui.exec, "accent")
	ui.exec.text = GM.MakeFontString(ui.exec, GM.FONT_BOLD, 12, "contLowest")
	ui.exec.text:SetPoint("CENTER")
	ui.exec.text:SetWordWrap(false)
	ui.exec.text:SetText("EXECUTE NEXT STEP")
	ui.exec:SetScript("OnClick", function() PQ.ExecuteNext() end)
	-- hover lightens only when the action is live — disabled stays muted
	ui.exec:SetScript("OnEnter", function()
		if ui.exec:IsEnabled() then GM.Panel(ui.exec, "contHighest") end
	end)
	ui.exec:SetScript("OnLeave", function()
		GM.Panel(ui.exec, ui.exec:IsEnabled() and "accent" or "contHigh")
	end)

	ui.rescan = CreateFrame("Button", nil, frame)
	ui.rescan:SetSize(104, 30)
	ui.rescan:SetPoint("RIGHT", ui.exec, "LEFT", -GAP, 0)
	GM.Panel(ui.rescan, "contHigh")
	ui.rescan.text = GM.MakeFontString(ui.rescan, GM.FONT_MED, 11, "text")
	ui.rescan.text:SetPoint("CENTER")
	ui.rescan.text:SetWordWrap(false)
	ui.rescan.text:SetText("RESCAN")
	ui.rescan:SetScript("OnClick", function() PQ.Rescan() end)
	ui.rescan:SetScript("OnEnter", function() GM.Panel(ui.rescan, "contHighest") end)
	ui.rescan:SetScript("OnLeave", function() GM.Panel(ui.rescan, "contHigh") end)

	ui.skip = CreateFrame("Button", nil, frame)
	ui.skip:SetSize(80, 30)
	ui.skip:SetPoint("RIGHT", ui.rescan, "LEFT", -GAP, 0)
	GM.Panel(ui.skip, "contMedium")
	ui.skip.text = GM.MakeFontString(ui.skip, GM.FONT_MED, 11, "textDim")
	ui.skip.text:SetPoint("CENTER")
	ui.skip.text:SetWordWrap(false)
	ui.skip.text:SetText("SKIP")
	ui.skip:SetScript("OnClick", function() PQ.SkipStep() end)
	ui.skip:SetScript("OnEnter", function()
		if ui.skip:IsEnabled() then GM.Panel(ui.skip, "contHigh") end
	end)
	ui.skip:SetScript("OnLeave", function()
		GM.Panel(ui.skip, ui.skip:IsEnabled() and "contMedium" or "contLowest")
	end)

	ui.clear = CreateFrame("Button", nil, frame)
	ui.clear:SetSize(64, 30)
	ui.clear:SetPoint("RIGHT", ui.skip, "LEFT", -GAP, 0)
	GM.Panel(ui.clear, "contMedium")
	ui.clear.text = GM.MakeFontString(ui.clear, GM.FONT_MED, 11, "textDim")
	ui.clear.text:SetPoint("CENTER")
	ui.clear.text:SetWordWrap(false)
	ui.clear.text:SetText("CLEAR")
	-- manual CLEAR abandons the scan context too — 0-hit scan
	-- finishes also call ClearPlan but keep scanMode for RESCAN
	ui.clear:SetScript("OnClick", function()
		PQ.scanMode = nil
		PQ.ClearPlan()
	end)
	ui.clear:SetScript("OnEnter", function()
		if ui.clear:IsEnabled() then GM.Panel(ui.clear, "contHigh") end
	end)
	ui.clear:SetScript("OnLeave", function()
		GM.Panel(ui.clear, ui.clear:IsEnabled() and "contMedium" or "contLowest")
	end)

	-- home overlay: the dashboard lives INSIDE this window — covers
	-- the whole content region when home mode is on
	ui.home = CreateFrame("Frame", nil, frame)
	ui.home:SetPoint("TOPLEFT", PAD, -64)
	ui.home:SetPoint("BOTTOMRIGHT", -PAD, 8)
	if GM.Dashboard and GM.Dashboard.MountHome then
		ui.homeRefresh = GM.Dashboard.MountHome(ui.home)
	end
	ui.home:Hide()

	ui.frame = frame
	-- CreateFrame defaults to visible — Build is called from scan
	-- paths (ScanStatus etc.) that must NOT pop the window; visibility
	-- is driven by Toggle/Show and the AH window's lifecycle
	frame:Hide()
	-- repaint when async item names resolve so bare-id targets
	-- (/goblin 4238) flip to real names without a rescan — gated on
	-- visibility like every other subscriber: an unguarded refresh
	-- here re-renders (and re-requests) unresolved ids while hidden,
	-- feeding the same event bursts that triggered it
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then PQ.Refresh() end
	end)
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

function PQ.Hide()
	if ui.frame then ui.frame:Hide() end
end

function PQ.IsShown()
	return ui and ui.frame and ui.frame:IsShown() or false
end

-- build at login so the first AH visit doesn't pay widget-creation
-- cost live
function PQ.Prewarm()
	Build()
end

-- transient scan-progress line (post/cancel scans write here while
-- their serialized book queries work through the queue)
function PQ.ScanStatus(text)
	Build()
	ui.summary:SetText(text)
end

-- live fraction through the armed craft's current cast — fills the
-- bar WHILE the spell is channeling instead of only on completion.
-- spellID (return 9) confirms it's our recipe; clients without it
-- fall back to any tradeskill cast matching the step's name.
local function CastFrac(armed)
	if not (UnitCastingInfo and armed) then return 0 end
	local ok, name, startMS, endMS, tradeSkill, spellID =
		pcall(function()
			local n, _, _, s, e, t, _, _, sp =
				UnitCastingInfo("player")
			return n, s, e, t, sp
		end)
	if not ok or not (startMS and endMS and endMS > startMS) then
		return 0
	end
	if spellID and armed.recipeID and spellID ~= armed.recipeID then
		return 0
	end
	if not spellID and armed.name and name and name ~= armed.name then
		return 0
	end
	return math.min((GetTime() * 1000 - startMS) / (endMS - startMS), 1)
end

-- plan completion: finished steps + the armed step's own progress
-- (craft casts tick crafted + live cast time, fetches tick bag
-- delta, collects tick mails looted) so the bar moves within a
-- long step, not just between steps
PlanFrac = function()
	local plan = PQ.plan
	local total = plan and #plan.steps or 0
	if total == 0 then return nil end
	local done = math.min(PQ.stepIndex - 1, total)
	local part = 0
	local armed = plan.steps[PQ.stepIndex]
	if armed then
		local qty = math.max(armed.qty or 1, 1)
		if armed.kind == "note" and armed.recipeID then
			part = math.min(
				((armed.crafted or 0) + CastFrac(armed)) / qty, 0.98)
		elseif armed.kind == "fetch"
			and GM.Banking and GM.Banking.FetchDone then
			part = math.min(GM.Banking.FetchDone(armed) / qty, 0.98)
		elseif armed.kind == "mailcollect" then
			part = math.min((armed.got or 0) / qty, 0.98)
		end
	end
	return (done + part) / total
end

-- progress bar arbitration: scans write a live frac, an active plan
-- reports step progress through Refresh — a live scan wins. Both
-- render on the same accent strip under the summary panel.
ApplyProg = function()
	if not ui.prog then return end
	local frac = ui.scanFrac or ui.planFrac
	if frac and frac > 0 and frac < 1 then
		ui.prog:SetWidth(LEFT_W * frac)
		ui.prog:Show()
	else
		ui.prog:Hide()
	end
end

-- scan progress bar: frac in (0,1) shows it, anything else hides it
function PQ.Progress(frac)
	Build()
	ui.scanFrac = (frac and frac > 0 and frac < 1) and frac or nil
	ApplyProg()
end

-- a scan that produced no steps drops the stale plan so the window
-- isn't left showing rows/buttons for something already finished
function PQ.ClearPlan()
	PQ.plan = nil
	PQ.stepIndex = 1
	PQ.lossConfirm = nil
	PQ.protectedOk = {}
	PQ.itemFresh = nil
	PQ.Refresh()
end

-- a scan starting invalidates the armed plan — its asks/undercuts
-- predate the query. Clear at START (not at finish) so no stale
-- step stays clickable mid-scan; the new plan lands via SetScanPlan.
-- pendingBuy lives on PQ so the mail-transit dedupe survives, and
-- scanMode records which scan ran so RESCAN still works on the
-- cleared/nil plan (0-hit scans leave nothing to read mode from).
function PQ.ScanStart(mode)
	PQ.scanMode = mode
	PQ.plan = nil
	PQ.stepIndex = 1
	PQ.budgetConfirm = nil
	PQ.budgetWarn = nil
	PQ.lossConfirm = nil
	PQ.protectedOk = {}
	PQ.Refresh()
end

-- the step the executor is sitting on — the craft cast listener ticks
-- progress into it
function PQ.ActiveStep()
	return PQ.plan and PQ.plan.steps[PQ.stepIndex]
end

-- advance without executing — for steps driven by an external event
-- (a completed craft cast) rather than a button click
function PQ.Advance()
	if PQ.plan and PQ.stepIndex <= #PQ.plan.steps then
		PQ.stepIndex = PQ.stepIndex + 1
	end
	PQ.Refresh()
end

-- a multi-item plan from a post/cancel scan — steps carry their own
-- itemID/name, execution goes through the same click-per-step path
function PQ.SetScanPlan(plan)
	Build()
	PQ.plan = plan
	PQ.scanMode = (plan.mode == "postscan" or plan.mode == "cancelscan"
		or plan.mode == "shopscan") and plan.mode or nil
	PQ.itemFresh = nil -- a landing plan supersedes the retarget flag
	PQ.stepIndex = 1
	PQ.homeMode = false
	PQ.budgetConfirm = nil
	PQ.budgetWarn = nil
	PQ.lossConfirm = nil
	PQ.protectedOk = {}
	-- scroll state is per-plan: stepIndex matching the old plan's by
	-- coincidence must not keep the old view offset
	ui.lastStep = nil
	ui.stepOff, ui.manualOff = nil, nil
	-- a landing plan supersedes any live scan fraction — a scan that
	-- never sent its Progress(nil) would mask plan progress forever
	ui.scanFrac = nil
	-- an open protect dialog still points at the replaced plan's step —
	-- its POST ANYWAY would spend the confirm on the new plan's step
	if protD then protD._step = nil protD:Hide() end
	PQ.Refresh()
end

function PQ.SetItem(itemID, itemLink)
	Build()
	PQ.homeMode = false
	PQ.itemID = itemID
	PQ.item = itemLink
	PQ.scan = nil
	PQ.scanMode = nil -- retargeting supersedes "rerun last scan"
	PQ.itemFresh = true -- and outranks the armed plan's mode on rescan
	-- inspecting an item must not erase work: a plan with unfinished
	-- steps survives — the step list keeps running while the stats
	-- pane shows the inspected item. Only a finished/empty plan clears.
	if not (PQ.plan and PQ.stepIndex <= #PQ.plan.steps) then
		PQ.plan = nil
		PQ.lossConfirm = nil
		PQ.protectedOk = {}
	end
	PQ.Refresh()
	if GM.GroupsUI and GM.GroupsUI.Retarget then GM.GroupsUI.Retarget() end
end

function PQ.Rescan()
	-- a retargeted item outranks the armed plan's mode — shift+click
	-- says "look at THIS", so RESCAN re-solves it instead of firing
	-- the shop/post scan the still-armed plan came from
	if PQ.itemFresh and PQ.itemID and GM.AH.open then
		local workID = PQ.itemID
		local name = GetInfo and GetInfo(workID)
		GM.Auctioning.StopScan()
		PQ.ScanStart()
		GM.AH.ScanItem(workID, name, function(asks)
			PQ.Solve(asks, workID)
		end)
		return
	end
	-- craft plans re-emit, not re-solve: fresh inventory + prices
	-- re-evaluate fetch/alt/buy and sub-craft choices — no AH needed
	if PQ.plan and PQ.plan.mode == "craft" then
		if PQ.plan.recipeID then
			GM.Crafting.Queue(PQ.plan.recipeID, PQ.plan.qty)
		else
			local ok, err = GM.Crafting.QueueEmit()
			if not ok then
				ui.summary:SetText(GM.CC("warn") .. (err or "queue is empty") .. "|r")
			end
		end
		return
	end
	if not GM.AH.open then
		ui.summary:SetText(GM.CC("warn") .. "auction house is not open|r")
		return
	end
	local mode = (PQ.plan and PQ.plan.mode) or PQ.scanMode
	if mode == "postscan" then GM.Auctioning.PostScan() return end
	if mode == "cancelscan" then GM.Auctioning.CancelScan() return end
	if mode == "shopscan" then GM.Auctioning.ShoppingScan() return end
	-- rescan always re-solves the DISPLAYED target — a retargeted item
	-- gets its own fresh plan (a live plan only wins by default when
	-- nothing else is targeted)
	local workID = PQ.itemID
		or (PQ.plan and PQ.stepIndex <= #PQ.plan.steps
			and PQ.plan.itemID)
	if not workID then
		ui.summary:SetText(GM.CC("textDim") .. "pick an item first — drop one in the header|r")
		return
	end
	local name = GetInfo and GetInfo(workID)
	-- a targeted solve outranks any group scan still pumping — abort
	-- it or its finish lands over this plan (and it would stomp our
	-- onScanDone slot mid-flight anyway)
	GM.Auctioning.StopScan()
	PQ.ScanStart() -- no stale steps armed while the query is out
	GM.AH.ScanItem(workID, name, function(asks)
		PQ.Solve(asks, workID)
	end)
	ui.summary:SetText(GM.CC("textDim") .. "scanning…|r")
end

function PQ.Solve(asks, workID)
	workID = workID or PQ.itemID
	GM.AH.pendingConfirm = nil -- a rescan invalidates any staged quote
	PQ.scan = { n = #asks, cheapest = asks[1] and asks[1].unit }
	local entry = workID and GM.ItemEntry(workID)
	local p50 = entry and entry.p or (workID and GM.TSMMarket(workID))
	if not p50 then
		ui.summary:SetText(GM.CC("err") .. "no price estimate for this item yet|r")
		PQ.Refresh()
		return
	end
	local gold = GetMoney()
	local vel = entry and entry.vel
	local isCommodity = GM.AH.IsCommodity(workID)
	-- group ops: auctioning drives post price/cap/stack/undercut,
	-- shopping.belowPct is the buy-margin gate (replaces minProfitMargin)
	local aOps = GM.Groups.GetOps(workID, "auctioning")
	local sOps = GM.Groups.GetOps(workID, "shopping")
	local function ev(f) return GM.Groups.EvalOp(aOps, f, workID) end
	-- a just-bought lot sits in mail transit — invisible to BagCount
	-- for the delivery window. PQ.pendingBuy records purchases so
	-- the post-step rescan's re-solve doesn't re-emit the same buys
	-- forever (the "loops from the top" report). It lives on PQ, not
	-- the plan — scans clear/replace plans freely without losing the
	-- ledger. Delivered units rebase into the bag count itself.
	local pend = PQ.pendingBuy and PQ.pendingBuy[workID]
	local pending = 0
	if pend then
		pending = math.max(0, pend.qty
			- math.max(0, GM.BagCount(workID) - pend.base))
		pend.qty, pend.base = pending, GM.BagCount(workID)
	end
	-- the solver strips own asks from buys itself; hand them back
	-- separately so the cancel-merge can repost off-target listings
	local ownAsks
	for _, a in ipairs(asks) do
		if a.own then
			ownAsks = ownAsks or {}
			tinsert(ownAsks, a)
		end
	end
	local plan, err = GM.Solver.Plan(asks, p50, entry and entry.p90, gold, vel, {
		riskBudget = GM.db.riskBudget,
		minProfitMargin = (tonumber(sOps.belowPct) or 10) / 100,
		commodity = isCommodity,
		owned = GM.BagCount(workID) + pending,
		normal = ev("normal"),
		minP = ev("min"),
		maxP = ev("max"),
		postCap = tonumber(aOps.postCap),
		stackSize = tonumber(aOps.stackSize),
		ownAsks = ownAsks,
		cancelUndercut = aOps.cancelUndercut,
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
	-- the work item's own link — PQ.item is the *inspected* link and
	-- can belong to a different item when a plan outlives inspection
	local workLink = select(2, GetInfo and GetInfo(workID)) or PQ.item
	for _, step in ipairs(plan.steps) do
		step.itemID = workID
		step.item = workLink
		step.commodity = isCommodity
	end
	-- buys arrive by mail — insert a collect step before the post leg
	-- so the queue models the buy→mailbox→post gap
	do
		local firstPost
		for i, s in ipairs(plan.steps) do
			if s.kind == "post" and not firstPost then firstPost = i end
		end
		if firstPost and firstPost > 1 then
			tinsert(plan.steps, firstPost,
				{ kind = "mailcollect", itemID = workID, item = workLink,
					qty = 1, name = "collect from mail" })
		end
	end
	for _, lot in ipairs(plan.buyLots or {}) do
		lot.itemID = workID
		lot.item = workLink
	end
	plan.itemID = workID
	plan.bank = GM.BankCount(workID)
	plan.deposit = GM.AH.DepositCost(workID,
		plan.qty + (plan.owned or 0) + (plan.relisted or 0)) or 0
	plan.ev = plan.ev - plan.deposit
	PQ.plan = plan
	PQ.scanMode = nil -- a solved item plan supersedes the last scan
	PQ.itemFresh = nil
	PQ.stepIndex = 1
	PQ.lossConfirm = nil
	PQ.protectedOk = {}
	ui.lastStep = nil
	ui.stepOff, ui.manualOff = nil, nil
	ui.scanFrac = nil
	PQ.Refresh()
end

-- protected-group confirm: a small modal warning that this plan step
-- would sell or post an item the user flagged protected via its group.
-- One confirm per item per plan — HOLD leaves the step armed.
local function BuildProtDialog()
	if protD then return protD end
	local d = CreateFrame("Frame", "GoblinMindProtectDialog", UIParent)
	d:SetSize(360, 170)
	d:SetPoint("CENTER")
	d:SetFrameStrata("FULLSCREEN_DIALOG")
	d:SetToplevel(true)
	d:EnableMouse(true)
	d:SetMovable(true)
	d:RegisterForDrag("LeftButton")
	d:SetScript("OnDragStart", function(self) self:StartMoving() end)
	d:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	d:SetClampedToScreen(true)
	GM.Panel(d, "contLow", "outlineVar")
	table.insert(UISpecialFrames, "GoblinMindProtectDialog")
	d.title = GM.MakeFontString(d, GM.FONT_MED, 11, "warn")
	d.title:SetPoint("TOPLEFT", 14, -12)
	d.title:SetText("PROTECTED ITEM")
	d.item = GM.MakeFontString(d, GM.FONT, 11, "text")
	d.item:SetPoint("TOPLEFT", 14, -34)
	d.item:SetWidth(332)
	d.item:SetJustifyH("LEFT")
	d.warn = GM.MakeFontString(d, GM.FONT, 10, "textDim")
	d.warn:SetPoint("TOPLEFT", 14, -56)
	d.warn:SetWidth(332)
	d.warn:SetJustifyH("LEFT")
	d.item:SetWordWrap(false)
	d.warn:SetText("its group is flagged protected — this plan step would "
		.. "sell it. Confirm posts it anyway (once per plan); hold "
		.. "keeps it in the queue untouched.")
	d.act = GM.Widgets.Btn(d, 130, "POST ANYWAY", function()
		if d._step then
			PQ.protectedOk[d._step.itemID] = true
			d:Hide()
			PQ.ExecuteNext()
		end
	end)
	d.act:SetPoint("BOTTOMRIGHT", -14, 12)
	local hold = GM.Widgets.Btn(d, 70, "HOLD", function() d:Hide() end)
	hold:SetPoint("RIGHT", d.act, "LEFT", -8, 0)
	d:Hide()
	protD = d
	return d
end

function PQ.ProtectedConfirm(step)
	local d = BuildProtDialog()
	d._step = step
	d.item:SetText((GM.ItemNameOr(step.itemID) or "item")
		.. GM.CC("textDim") .. "  (protected group)|r")
	d.item:SetTextColor(GM.NameColor(step.itemID))
	d.act.text:SetText(step.kind == "post" and "POST ANYWAY"
		or step.kind == "vendsell" and "SELL ANYWAY"
		or "VENDOR ANYWAY")
	d:Show()
	d:Raise()
end

function PQ.ExecuteNext()
	-- a staged commodity buy: this click is the ConfirmCommoditiesPurchase
	if GM.AH.pendingConfirm then
		local pc = GM.AH.pendingConfirm
		local cur = PQ.plan and PQ.plan.steps[PQ.stepIndex]
		-- one quote has one owner: only the step that staged it may
		-- confirm. A quote staged from the AH window for a different
		-- item must not be spent under this plan's context
		if cur and cur.itemID == pc.itemID then
			if GM.AH.Execute({ kind = "confirm" }) then
				PQ.submitFlash = GetTime()
				if cur.itemID then
					PQ.pendingBuy = PQ.pendingBuy or {}
					local pb = PQ.pendingBuy[cur.itemID]
						or { qty = 0,
							base = GM.BagCount(cur.itemID) }
					pb.qty = pb.qty + (cur.qty or 1)
					PQ.pendingBuy[cur.itemID] = pb
				end
				PQ.stepIndex = PQ.stepIndex + 1
				-- craft plans re-EMIT on rescan (QueueEmit re-derives
				-- coverage from Inventory.Count) — a just-won item is
				-- still in transit to the mailbox, invisible to the
				-- count, so the re-emit produced the same buy step
				-- again: the duplicate-quote bounce. Scan-mode plans
				-- skip rescan by design; this matches that.
				if not (PQ.plan and PQ.plan.mode) then
					local p = PQ.plan
					GM.After(1.0, function()
						-- a plan loaded in the gap must not eat a rescan
						-- fired under the old one — identity, not presence
						if PQ.plan == p then PQ.Rescan() end
					end)
				end
			end
		else
			ui.summary:SetText(GM.CC("warn")
				.. "a quote is staged for another item — resolve it in the AH window|r")
		end
		PQ.Refresh()
		return
	end
	local step = PQ.plan and PQ.plan.steps[PQ.stepIndex]
	if not step then return end
	-- expected-loss gate: a "bad" verdict holds the plan until one
	-- explicit confirm click. Single-item plans only — scan plans have
	-- their own economics (a cancelscan's ev is 0 by design) and would
	-- flag constantly. One confirm covers the plan; skip/rescan is the
	-- way out of a plan you don't want.
	if not PQ.plan.mode and not PQ.lossConfirm
			and GM.Solver.Verdict(PQ.plan, GM.db) == "bad" then
		PQ.lossConfirm = true
		PQ.Refresh()
		return
	end
	-- envelope check: warn once per step, second click confirms
	if (step.kind == "buy" or step.kind == "vendbuy") and GM.Budget then
		local cost = step.cost or (step.unit or 0) * (step.qty or 1)
		local over, _, deficit = GM.Budget.Check(step, cost)
		if over and PQ.budgetConfirm ~= PQ.stepIndex then
			PQ.budgetConfirm = PQ.stepIndex
			PQ.budgetWarn = deficit
			PQ.Refresh()
			return
		end
	end
	-- protected-group gate: sell/post steps on flagged items need one
	-- explicit confirm per item per session — the step stays armed
	if (step.kind == "post" or step.kind == "vendsell"
			or step.kind == "destroy")
			and step.itemID and GM.Groups
			and GM.Groups.IsProtected(step.itemID)
			and not PQ.protectedOk[step.itemID] then
		PQ.ProtectedConfirm(step)
		return
	end
	if step.kind == "note" and step.recipeID then
		-- a real craft step: fire the remaining count — Blizzard's own
		-- multicraft call, one protected call per click. Completed
		-- casts tick step.crafted via UNIT_SPELLCAST_SUCCEEDED and the
		-- plan advances itself at qty; a dead call (tradeskill closed,
		-- unsupported batch) just stays armed for the next click.
		local left = (step.qty or 1) - (step.crafted or 0)
		local ok, err = GM.Crafting.Craft(step.recipeID, left)
		if not ok then
			GM.Print(GM.CC("err") .. tostring(err) .. "|r")
		end
		PQ.Refresh()
		return
	end
	if step.kind == "note" or step.kind == "skip" then
		-- manual step (fetch mail, …) or scan-skip info row:
		-- the click acknowledges it, no protected call involved
		PQ.stepIndex = PQ.stepIndex + 1
		PQ.Refresh()
		return
	end
	-- "bounce" from any executor = its location is unreachable (bank/
	-- mailbox/merchant closed, item absent). Rotate the step to the
	-- plan tail so the itinerary continues — after 3 bounces it skips
	-- outright (at the tail the bounce would loop forever).
	local result, reason, bagDone
	if (step.kind == "buy" or step.kind == "vendbuy") and step.bagBase
		and GM.BagDelta(step) >= (step.qty or 1) then
		-- bags gained since emit already cover this buy — stock the
		-- player grabbed by hand or another leg. Don't spend again.
		result, bagDone = true, true
	elseif step.kind == "fetch" and GM.Banking and GM.Banking.FetchBank then
		result, reason = GM.Banking.FetchBank(step)
	elseif step.kind == "move" or step.kind == "mail"
			or step.kind == "mailcollect" then
		result, reason = GM.Banking.Execute(step)
	elseif step.kind == "destroy" then
		result, reason = GM.Destroying.Execute(step)
	elseif step.kind == "vendbuy" or step.kind == "vendsell" then
		result, reason = GM.Vendoring.Execute(step)
	else
		result = GM.AH.Execute(step)
	end
	if result == "bounce" then
		step.bounces = (step.bounces or 0) + 1
		if step.bounces >= 3 then
			GM.Print(GM.CC("warn")
				.. tostring(step.verb or step.kind) .. " "
				.. tostring(step.name or step.itemID) .. " — "
				.. tostring(reason) .. " — skipped|r")
			PQ.stepIndex = PQ.stepIndex + 1
		else
			tremove(PQ.plan.steps, PQ.stepIndex)
			tinsert(PQ.plan.steps, step)
			GM.Print(GM.CC("warn")
				.. tostring(step.verb or step.kind) .. " "
				.. tostring(step.name or step.itemID) .. " — "
				.. tostring(reason) .. " — bounced to end of plan|r")
		end
		PQ.Refresh()
		return
	end
	if result == "confirm" then
		PQ.Refresh()
		return
	end
	if result then
		if (step.kind == "buy" or step.kind == "vendbuy")
			and GM.Budget and not bagDone then
			GM.Budget.Record(step, step.cost
				or (step.unit or 0) * (step.qty or 1))
		end
		PQ.budgetConfirm = nil
		PQ.budgetWarn = nil
		PQ.submitFlash = GetTime()
		if step.kind == "buy" and step.itemID then
			PQ.pendingBuy = PQ.pendingBuy or {}
			local pb = PQ.pendingBuy[step.itemID]
				or { qty = 0, base = GM.BagCount(step.itemID) }
			pb.qty = pb.qty + (step.qty or 1)
			PQ.pendingBuy[step.itemID] = pb
		end
		PQ.stepIndex = PQ.stepIndex + 1
		-- single-item plans rescan after each action; scan-mode plans are
		-- independent steps — re-querying the book per click would stall.
		-- The deferral must re-check identity: a plan loaded inside the
		-- 1s gap owns its own lifecycle — a rescan fired under the old
		-- plan would re-emit/re-scan over it and wipe its progress
		if not (PQ.plan and PQ.plan.mode) then
			local p = PQ.plan
			GM.After(1.0, function()
				if PQ.plan == p then PQ.Rescan() end
			end)
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
	PQ.budgetConfirm = nil
	PQ.budgetWarn = nil
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
	ui.chart.tipLines = nil

	-- a real series from GoblinMindHistory once it has ≥2 points; until
	-- then the three data anchors (hist/recent/est) stand in. The x
	-- window fits the OBSERVED span — a fixed 7-day axis under a young
	-- series crams every point into the right edge and implies coverage
	-- that doesn't exist
	local WEEK = 7 * 86400
	local pts, seriesMode, window = {}, false, WEEK
	if entry and itemID and GM.History then
		local series = GM.History.Points(itemID, WEEK)
		if #series >= 2 then
			seriesMode = true
			local span = series[#series].t - series[1].t
			if span < 0.85 * WEEK then
				window = math.max(span * 1.25, 3600)
			end
			local t0 = time() - window
			for _, p in ipairs(series) do
				local x = (p.t - t0) / window
				tinsert(pts, { x = x < 0 and 0 or x > 1 and 1 or x, v = p.p })
			end
			tinsert(pts, { x = 1.0, v = entry.p }) -- live estimate at "now"
			ui.chart.tipLines = {
				format("%d snapshots over %s", #series,
					GM.FmtAge(window)),
				format("first sample %s ago · latest now",
					GM.FmtAge(time() - series[1].t)),
			}
		end
	end
	if not seriesMode and entry then
		if entry.hist then tinsert(pts, { x = 0.05, v = entry.hist, tag = "hist" }) end
		if entry.recent and entry.recent ~= (entry.hist or 0) then
			tinsert(pts, { x = 0.5, v = entry.recent, tag = "recent" })
		end
		tinsert(pts, { x = 0.95, v = entry.p, tag = "est" })
		ui.chart.tipLines = {
			"Price references — not a time series",
			"anchors: hist · recent · live estimate",
		}
	end
	local fullWeek = seriesMode and window >= WEEK
	ui.chart.title:SetText(
		fullWeek and "PRICE · VOLUME · 7D"
		or seriesMode and "Snapshots · " .. GM.FmtAge(window)
		or "PRICE REFERENCES")
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
	-- TradingView split: price line in the top region, metric readouts
	-- below. Right gutter reserved for price labels so they never
	-- collide with the plot.
	local pad, gutter = 10, 72
	local W = ui.chart:GetWidth() - pad - gutter
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
	-- day-boundary gridlines only when the axis really spans a week
	if fullWeek then
		for d = 1, 6 do
			local gx = pad + d / 7 * W
			Segment(ui.chart, gx, volBase, gx, priceTop, "outlineVar")
		end
	end
	-- hi/lo scale labels right-aligned inside the gutter; suppress
	-- whichever collides (<14u) with the latest-price tag that shares
	-- the gutter — never two labels stacked in the same right region
	local gR = ui.chart:GetWidth() - 6
	local tagY = pts[#pts].py - 5
	if math.abs(priceTop + 2 - tagY) >= 14 then
		Label(ui.chart, gR, priceTop + 2, GM.Money(hi), "textDim", 10, "RIGHT")
	end
	if math.abs(priceBase - 6 - tagY) >= 14 then
		Label(ui.chart, gR, priceBase - 6, GM.Money(lo), "textDim", 10, "RIGHT")
	end

	for i = 2, #pts do
		Segment(ui.chart, pts[i - 1].px, pts[i - 1].py, pts[i].px, pts[i].py)
	end
	for i, p in ipairs(pts) do
		local endpoint = i == 1 or i == #pts
		local hot = (seriesMode and i == #pts) or p.tag == "est"
		if not seriesMode or endpoint then
			Dot(ui.chart, p.px, p.py, hot and 5 or 4, hot and "accent" or "textDim")
			-- the latest price anchors in the gutter at its own y —
			-- never centered on the dot, never bleeding the plot
			if hot then
				Label(ui.chart, gR, tagY, GM.Money(p.v), "text", 11, "RIGHT")
			end
		end
	end
	-- time axis markers at the plot's true edges; the left label names
	-- the actual window, not a pretend week
	if seriesMode then
		Label(ui.chart, pad, 4,
			(fullWeek and "7d ago" or GM.FmtAge(window) .. " ago"),
			"textDim", 10, "LEFT")
		Label(ui.chart, pad + W, 4, "now", "textDim", 10, "RIGHT")
	end
	-- derived metrics as labeled readouts — region turnover and DB
	-- listed value are different units, not comparable bar heights
	if entry.p then
		local reads = {}
		if entry.vel and entry.vel > 0 then
			tinsert(reads, "region turnover " .. GM.Money(entry.vel * entry.p) .. "/day*")
		end
		if entry.sup and entry.sup > 0 then
			tinsert(reads, "DB listed " .. GM.Money(entry.sup * entry.p) .. "*")
		end
		if #reads > 0 then
			Label(ui.chart, pad, (volBase + volTop) / 2 - 4,
				table.concat(reads, "  ·  "), "textDim", 9, "LEFT")
		end
		ui.chart.readsHover:EnableMouse(#reads > 0)
	end
end

function PQ.SetHome(on)
	PQ.homeMode = on and true or false
	PQ.Refresh()
end

function PQ.Refresh()
	PQ._refreshes = (PQ._refreshes or 0) + 1
	Build()
	-- home mode: dashboard panels replace the plan inspector
	if ui.home then
		local h = PQ.homeMode
		ui.home:SetShown(h)
		for _, w in ipairs({ ui.item, ui.chart, ui.header, ui.list,
			ui.stats, ui.sumBar, ui.exec, ui.rescan, ui.skip }) do
			if w then w:SetShown(not h) end
		end
		-- dash↔plan flips the current tab — rebuild the strip when it
		-- changes (AddTabs no-ops on an unchanged key)
		if GM.Dashboard and GM.Dashboard.AddTabs and ui.titleFs then
			GM.Dashboard.AddTabs(ui.frame, ui.titleFs,
				h and "dash" or "plan")
		end
		if h then
			if ui.homeRefresh then ui.homeRefresh() end
			return
		end
	end
	-- freshness has three clocks (same split TSM's desktop status shows):
	-- SYNC = our pipeline emit, DB = realm-data snapshot, RGN = region
	-- feed, BOOK = our own live scan. Each warns on its own threshold —
	-- a stale DB is upstream cadence, a stale SYNC means the pipeline died.
	local function AgeTxt(age, warnAt)
		if not age then return nil end
		return (warnAt and age > warnAt and GM.CC("warn") or GM.CC("textDim"))
			.. (age >= 3600 and format("%dh%dm", age / 3600, age % 3600 / 60)
				or age >= 60 and format("%dm", age / 60)
				or format("%ds", age)) .. "|r"
	end
	local sync = AgeTxt(GM.SyncAge and GM.SyncAge(), 2100)
	local realm = AgeTxt(GM.RealmAge and GM.RealmAge(),
		GM.db and GM.db.dataMaxAge or 7200)
	local region = AgeTxt(GM.RegionAge and GM.RegionAge())
	local parts = {}
	if not (sync or realm) then
		tinsert(parts, GM.CC("warn") .. "no data file|r")
	else
		if realm then tinsert(parts, "DB " .. realm) end
		if sync then tinsert(parts, "sync " .. sync) end
		if region then tinsert(parts, "rgn " .. region) end
	end
	local dbTxt = table.concat(parts, " ")
	local bAge = GM.AH.BookAge and GM.AH.BookAge()
	local bookTxt = ""
	if bAge and bAge < math.huge then
		bookTxt = (bAge > 300 and GM.CC("warn") or GM.CC("textDim")) .. " · "
			.. (bAge >= 60 and format("Book %dm", bAge / 60) or format("Book %ds", bAge)) .. "|r"
	end
	ui.age:SetText(dbTxt .. bookTxt)

	-- FULL SCAN locks while any book build (replicate or browse) is live
	if ui.fullScan then
		local busy = GM.AH.Busy() and true or false
		ui.fullScan:SetEnabled(not busy)
		ui.fullScan.text:SetTextColor(GM.RGB(busy and "textDim" or "text"))
	end

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
	-- name gets its own line; book/readout context moves to the sub line.
	-- a proper link already renders the name — bare "4238"-style targets
	-- fall back to the resolved item name (async load → watcher repaints).
	ui.item.name:SetText(
		(dispLink and dispLink:find("%[") and dispLink)
		or (dispID and GM.ItemName(dispID))
		or dispLink
		or (dispID and ("item " .. dispID))
		or "no item")
	ui.item.name:SetTextColor(GM.NameColor(dispID))
	if not dispID then
		ui.item.name:SetText(GM.CC("textDim") .. "drop item here · shift-click one · /goblin [link]|r")
	end
	local icon = dispID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(dispID)
	if not icon and dispID and GetInfo then
		icon = select(10, GetInfo(dispID))
	end
	if icon then ui.icon:SetTexture(icon) ui.icon:Show() else ui.icon:Hide() end
	ui.iconBtn.itemID = dispID
	local sub = {}
	if dispID and GetInfo then
		local _, _, _, _, _, itemType = GetInfo(dispID)
		if itemType then tinsert(sub, itemType) end
	end
	if dispID then tinsert(sub, "id " .. dispID) end
	-- unsellable flag: soulbound by type (BoP/quest), or the bag
	-- stack fails the client's own sell check
	if dispID then
		local flag
		local bind = GetInfo and select(14, GetInfo(dispID))
		if bind == 1 or bind == 4 then flag = "soulbound" end
		local loc = not flag and GM.AH.FindInBags
			and GM.AH.FindInBags(dispID)
		if loc and C_AuctionHouse
			and C_AuctionHouse.IsSellItemValid then
			local ok, valid = pcall(C_AuctionHouse.IsSellItemValid, loc)
			if ok and valid == false then flag = "not sellable" end
		elseif loc and C_Item and C_Item.IsBound then
			local ok, bound = pcall(C_Item.IsBound, loc)
			if ok and bound then flag = "soulbound" end
		end
		if flag then
			tinsert(sub, GM.CC("err")
				.. "NOT AUCTIONABLE — " .. flag .. "|r")
		end
	end
	if entry and entry.vel then
		tinsert(sub, "region sales ~" .. (GM.VelRate(entry.vel)
			or "?") .. "/day")
	end
	if book and #book > 0 then tinsert(sub, strtrim(book:gsub("· ", "", 1))) end
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
	set("ref price", p and GM.Money(p))
	set("ref ±15%", (entry and entry.p10 and entry.p90) and (GM.Money(entry.p10) .. "–" .. GM.Money(entry.p90)))
	set("hist", (entry and entry.hist)
		and (GM.Money(entry.hist) .. " " .. (pct(p, entry.hist) or "")))
	set("recent", entry and pct(entry.recent, p))
	-- in-flight scan result is fresher than any stored source;
	-- entry.mb otherwise (book/mesh overlay already applied by ItemEntry)
	local minBuy = (scanMode and curStep.cheapest)
		or (PQ.scan and PQ.scan.cheapest)
		or (entry and entry.mb)
	set("min buy", minBuy and GM.Money(minBuy))
	-- velocity is regional volume, not realm-local sell-time certainty
	set("region/day", entry and entry.vel and (entry.vel >= 1000
		and format("%.0fk", entry.vel / 1000) or tostring(entry.vel)))
	local obsSrc = entry and entry._src
	ui.statLabel["units"]:SetText(obsSrc == "book" and "live units"
		or obsSrc == "mesh" and "mesh units" or "DB auctions")
	set("units", entry and entry.sup and tostring(entry.sup))
	local rs = entry and entry.reset
	set("reset", type(rs) == "table"
		and (GM.Money(rs.below) .. " · ev " .. GM.Money(rs.ev))
		or type(rs) == "number" and rs > 0
		and GM.Money(rs) or nil)
	set("gold", GM.Money(GetMoney()))
	-- the cap is a fraction of gold, not a currency amount
	set("budget cap", GM.db and format("%.0f%%", (GM.db.riskBudget or 0) * 100))
	set("margin", GM.db and format("%.0f%%", (GM.db.minProfitMargin or 0) * 100))

	DrawChart(entry, dispID)

	-- plan rows — a window into steps. The active step recenters to
	-- row 3 (two finished steps of context above) whenever it changes;
	-- mousewheel scrolls manually until the next step advance
	local nSteps = PQ.plan and #PQ.plan.steps or 0
	ui.planFrac = PlanFrac()
	ApplyProg()
	local maxOff = math.max(0, nSteps - ROWS)
	if ui.lastStep ~= PQ.stepIndex then
		ui.lastStep = PQ.stepIndex
		ui.manualOff = nil
		ui.stepOff = math.min(math.max(PQ.stepIndex - 3, 0), maxOff)
	end
	local off = math.min(ui.manualOff or ui.stepOff or 0, maxOff)
	ui.stepOff = off
	for i = 1, ROWS do
		local row = ui.rows[i]
		local n = i + off
		local step = PQ.plan and PQ.plan.steps[n]
		if step then
			row:Show()
			local active = n == PQ.stepIndex
			row.edge:SetShown(active)
			row.num:SetText(GM.CC("textDim") .. n .. "|r")
			local verb = step.verb
				or (step.kind == "post" and "POST"
				or step.kind == "cancel" and "CANCEL"
				or step.kind == "skip" and "SKIP"
				or step.kind == "note" and (step.recipeID and "CRAFT" or "DONE")
				or step.kind == "fetch" and "FETCH"
				or step.kind == "move" and "MOVE"
				or step.kind == "mail" and "SEND"
				or step.kind == "mailcollect" and "COLLECT"
				or step.kind == "destroy" and "VENDOR"
				or step.kind == "vendsell" and "SELL"
				or step.kind == "vendbuy" and "VENDOR" or "BUY")
			if active then
				row.act:SetText(GM.CC("accent") .. verb .. " ▶|r")
			else
				row.act:SetText(GM.CC(step.kind == "post" and "pos"
					or step.kind == "cancel" and "warn"
					or step.kind == "vendbuy" and "accent"
					or step.kind == "skip" and "textDim" or "text") .. verb .. "|r")
			end
			if PQ.plan.mode then
				-- live lookup FIRST: the emit bakes "item N" into
				-- step.name when the data wasn't loaded yet — preferring
				-- it meant the row never called ItemName, never issued
				-- the load request, and could never resolve. Shopping
				-- rows already order it this way.
				local nm = (step.itemID and GM.ItemName
						and GM.ItemName(step.itemID))
					or step.name or ""
				if #nm > 16 then nm = nm:sub(1, 15) .. "…" end
				row.qty:SetText((GM.QHex(step.itemID) or "")
					.. nm .. "|r ×" .. step.qty)
			else
				row.qty:SetText(step.qty .. (step.kind == "post" and " (relist)" or ""))
			end
			-- a staged commodity quote outranks the book estimate the
			-- row was emitted with — while CONFIRM is armed the row
			-- shows what the click will actually pay
			local pc = GM.AH.pendingConfirm
			local shownUnit = step.unit
			if pc and pc.quote and active
				and step.itemID == pc.itemID and step.qty == pc.qty then
				shownUnit = pc.quote / (step.qty or 1)
			end
			row.price:SetText(step.desc or step.text
				or (GM.Money(shownUnit) .. (step.kind == "post" and "" or " /ea")))
		else
			row:Hide()
		end
	end

	if PQ.plan then
		if ui.headerCols then
			local hc = PQ.plan.mode
				and (HEAD_COLS[PQ.plan.mode] or { "ITEM", "DETAIL" })
				or { "QTY", "UNIT PRICE" }
			ui.headerCols.QTY:SetText(hc[1])
			ui.headerCols["UNIT PRICE"]:SetText(hc[2])
		end
		if PQ.plan.mode == "postscan" then
			ui.sumEdge:SetColorTexture(GM.RGB("accent"))
			local skipN = PQ.plan.skipCount or 0
			ui.summary:SetText(format("POST SCAN · %d posts across %d items%s",
				#PQ.plan.steps - skipN, PQ.plan.itemCount or 0,
				skipN > 0 and format(" · %d skipped", skipN) or ""))
			ui.summary2:SetText(format("est %s · dep %s",
				GM.Money(PQ.plan.ev or 0), GM.Money(PQ.plan.deposit or 0)))
		elseif PQ.plan.mode == "cancelscan" then
			ui.sumEdge:SetColorTexture(GM.RGB("warn"))
			ui.summary:SetText(format("CANCEL SCAN · %d undercut auction%s — one click each",
				#PQ.plan.steps, #PQ.plan.steps == 1 and "" or "s"))
			ui.summary2:SetText("")
		elseif PQ.plan.mode == "shopscan" then
			ui.sumEdge:SetColorTexture(GM.RGB("pos"))
			ui.summary:SetText(format("SHOP SCAN · %d buy%s across %d item%s — one click each",
				#PQ.plan.steps, #PQ.plan.steps == 1 and "" or "s",
				PQ.plan.itemCount or 0,
				(PQ.plan.itemCount or 0) == 1 and "" or "s"))
			ui.summary2:SetText(format("spend %s · worth %s",
				GM.Money(PQ.plan.spend or 0), GM.Money(PQ.plan.ev or 0)))
		elseif PQ.plan.mode == "craft" then
			ui.sumEdge:SetColorTexture(GM.RGB("accent"))
			-- name the products, not just the step count
			local prods, seen = {}, {}
			for _, s in ipairs(PQ.plan.steps) do
				if s.kind == "note" and s.recipeID and s.name and not seen[s.name] then
					seen[s.name] = true
					prods[#prods + 1] = format("%s ×%d", s.name, s.qty or 1)
				end
			end
			ui.summary:SetText(format("CRAFT QUEUE · %d step%s — craft is manual",
				#PQ.plan.steps, #PQ.plan.steps == 1 and "" or "s"))
			ui.summary2:SetText(#prods > 0 and table.concat(prods, " · ")
				or "route: AH → bank → vendor → mail → craft")
		elseif PQ.plan.mode == "warehousing" or PQ.plan.mode == "mailing"
			or PQ.plan.mode == "destroying" or PQ.plan.mode == "vendoring" then
			ui.sumEdge:SetColorTexture(GM.RGB("accent"))
			ui.summary:SetText(format("%s · %d step%s",
				strupper(PQ.plan.mode), #PQ.plan.steps,
				#PQ.plan.steps == 1 and "" or "s"))
			ui.summary2:SetText(PQ.plan.mode == "warehousing"
				and "bank must stay open"
				or PQ.plan.mode == "mailing" and "mailbox must stay open"
				or "merchant must stay open")
		else
		local verdict, note = GM.Solver.Verdict(PQ.plan, GM.db)
		local own = (PQ.plan.owned or 0) > 0 and ("own " .. PQ.plan.owned) or nil
		if (PQ.plan.bank or 0) > 0 then own = (own or "own 0") .. " +" .. PQ.plan.bank .. " bank" end
		-- headline the action, not the absence of alternatives
		local headline = PQ.plan.qty == 0 and (own and "RELIST OWNED STOCK · " .. own
				or "RELIST OWNED STOCK")
			or format("EXECUTE PLAN · %d steps", #PQ.plan.steps)
		ui.sumEdge:SetColorTexture(GM.RGB(verdict == "good" and "pos" or "warn"))
		ui.summary:SetText((verdict == "good" and "" or GM.CC("warn")) .. headline .. "|r")
		local dep = (PQ.plan.deposit or 0) > 0 and (" · dep " .. GM.Money(PQ.plan.deposit)) or ""
		local sub = PQ.submitFlash and (GetTime() - PQ.submitFlash < 3)
			and (GM.CC("textDim") .. " · submitted — verifying|r") or ""
		ui.summary2:SetText(format("spend %s%s · net %s · %s%s",
			GM.Money(PQ.plan.spend), dep, GM.Money(PQ.plan.ev), note, sub))
		end
		ui.exec:Show()
		local pcPending = GM.AH.pendingConfirm
		local pcMatch = pcPending and curStep
			and curStep.itemID == pcPending.itemID
		local badPlan = not PQ.plan.mode and not PQ.lossConfirm
			and GM.Solver.Verdict(PQ.plan, GM.db) == "bad"
		if PQ.budgetWarn then
			ui.exec.text:SetText("OVER BUDGET −" ..
				GM.Money(PQ.budgetWarn) .. " · CONFIRM")
		elseif badPlan then
			ui.exec.text:SetText("EXPECTED LOSS · CONFIRM")
		elseif pcMatch then
			ui.exec.text:SetText(pcPending.quote
				and ("CONFIRM " .. GM.Money(pcPending.quote))
				or "CONFIRM PURCHASE")
		elseif pcPending then
			ui.exec.text:SetText("QUOTE · OTHER ITEM")
		else
			local kind = curStep and curStep.kind
			-- craft step with a closed line → the secure OPEN overlay
			-- takes the click (same gate as the crafting window); the
			-- spell cast opens the line and the gate flips to CRAFT
			local left = kind == "note" and curStep.recipeID
				and ((curStep.qty or 1) - (curStep.crafted or 0))
			local opening = GM.Crafting.GateButton
				and GM.Crafting.GateButton(ui.exec,
					curStep and curStep.recipeID, left or 1,
					kind == "note" and curStep ~= nil
					and curStep.recipeID ~= nil)
			local openProf = opening and GM.Crafting.Prof
				and GM.Crafting.Prof(curStep.recipeID)
			local verb = PQ.stepIndex > #PQ.plan.steps and "PLAN DONE"
				or opening and ("OPEN "
					.. (openProf and openProf:upper() or "TRADESKILL"))
				or kind == "cancel" and "CANCEL NEXT"
				or kind == "post" and "POST NEXT"
				or kind == "skip" and "NEXT"
				or kind == "note" and (curStep.recipeID
					and format("CRAFT · %d/%d", curStep.crafted or 0,
						curStep.qty or 1)
					or "DONE")
				or kind == "fetch" and format("FETCH · %d/%d",
					GM.Banking and GM.Banking.FetchDone
						and GM.Banking.FetchDone(curStep) or 0,
					curStep.qty or 1)
				or kind == "move" and "MOVE NEXT"
				or kind == "mail" and "SEND NEXT"
				or kind == "mailcollect" and "COLLECT NEXT"
				or kind == "destroy" and "VENDOR NEXT"
				or kind == "vendsell" and "SELL NEXT"
				or kind == "vendbuy" and "VENDOR NEXT"
				or kind == "buy" and "BUY NEXT" or "EXECUTE NEXT STEP"
			ui.exec.text:SetText(verb)
		end
		local moveKind = curStep and (curStep.kind == "note"
			or curStep.kind == "fetch"
			or curStep.kind == "move" or curStep.kind == "mail"
			or curStep.kind == "mailcollect" or curStep.kind == "destroy"
			or curStep.kind == "vendbuy" or curStep.kind == "vendsell")
		-- a live quote serializes AH mutations: only its own confirm or
		-- non-transactional steps may run until it resolves
		local canExec = pcMatch
			or moveKind
			or (not pcPending and PQ.stepIndex <= #PQ.plan.steps and GM.AH.open)
		ui.exec:SetEnabled(canExec)
		-- honest disabled state: muted fill + label; blocker on line 1
		GM.Panel(ui.exec, canExec and "accent" or "contHigh")
		ui.exec.text:SetTextColor(GM.RGB(canExec and "contLowest" or "textDim"))
		if pcPending and not pcMatch and not moveKind then
			ui.summary:SetText(GM.CC("warn")
				.. "a quote is staged for another item — resolve it in the AH window|r")
		elseif not canExec and not GM.AH.open then
			ui.summary:SetText(GM.CC("warn") .. "open the auction house to execute|r")
		end
		ui.skip:Show()
		local canSkip = GM.AH.pendingConfirm ~= nil or PQ.stepIndex <= #PQ.plan.steps
		ui.skip:SetEnabled(canSkip)
		GM.Panel(ui.skip, canSkip and "contMedium" or "contLowest")
		ui.clear:Show()
	else
		ui.sumEdge:SetColorTexture(GM.RGB("outlineVar"))
		ui.summary2:SetText("")
		ui.exec:Hide()
		ui.skip:Hide()
		ui.clear:Hide()
	end
end
