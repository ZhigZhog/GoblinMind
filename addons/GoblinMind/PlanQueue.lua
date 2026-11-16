local _, GM = ...

-- TSM-styled plan window: item header, verbose stats column, trend
-- region, and the click-per-step queue. Every protected auction call is
-- still one hardware click — this file only arranges information.

GM.PlanQueue = { plan = nil, stepIndex = 1, itemID = nil, item = nil }

local PQ = GM.PlanQueue
local ROWS = 6
local ui = { art = {} }
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
	row.act   = GM.MakeFontString(row, GM.FONT_MED, 11, "text")
	row.act:SetPoint("LEFT", 34, 0)
	row.qty   = GM.MakeFontString(row, GM.FONT, 11, "textDim")
	row.qty:SetPoint("LEFT", 140, 0)
	row.price = GM.MakeFontString(row, GM.FONT_MED, 11, "text")
	row.price:SetPoint("RIGHT", -10, 0)
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
	craft        = { "ITEM", "SOURCE" },
	vendoring    = { "ITEM", "VENDOR" },
	warehousing  = { "ITEM", "WHERE" },
	mailing      = { "ITEM", "TO" },
	destroying   = { "ITEM", "VALUE" },
}

local function Build()
	if ui.frame then return end

	local frame = CreateFrame("Frame", "GoblinMindPlanFrame", UIParent)
	frame:SetSize(WIN_W, 542)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
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
	ui.titleFs = title
	-- module tab strip rides the title row like every other window —
	-- dash↔plan is a mode of this window, so the strip rebuilds on
	-- Refresh when the current key flips
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(frame, title,
			PQ.homeMode and "dash" or "plan")
	end
	-- drag on the frame title zone (RegisterForDrag on the frame itself
	-- — no chrome overlay any more)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

	-- scan buttons ride the title strip — subtle button rects so they
	-- read as actions, not navigation tabs
	local function TitleBtn(label, w, onclick, tip)
		local b = CreateFrame("Button", nil, frame)
		b:SetSize(w, 22)
		GM.Panel(b, "contHigh", "outlineVar")
		b.text = GM.MakeFontString(b, GM.FONT_MED, 11, "text")
		b.text:SetAllPoints()
		b.text:SetText(label)
		b:SetScript("OnClick", onclick)
		b:SetScript("OnEnter", function()
			GM.Panel(b, "contHighest", "outlineVar")
			b.text:SetTextColor(GM.RGB("accent"))
			if tip and GameTooltip then
				GameTooltip:SetOwner(b, "ANCHOR_BOTTOM")
				GameTooltip:SetText(tip, 1, 1, 1)
				GameTooltip:Show()
			end
		end)
		b:SetScript("OnLeave", function()
			GM.Panel(b, "contHigh", "outlineVar")
			b.text:SetTextColor(GM.RGB("text"))
			if GameTooltip then GameTooltip:Hide() end
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

	local close = CreateFrame("Button", nil, frame)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -PAD, -26)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetAllPoints()
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

	-- Item header: bordered icon slot + name + meta
	ui.item = CreateFrame("Button", nil, frame)
	ui.item:SetPoint("TOPLEFT", PAD, -64)
	ui.item:SetWidth(LEFT_W)
	ui.item:SetHeight(56)
	GM.Panel(ui.item, "contMedium")
	if GM.ChromePanel then GM.ChromePanel(ui.item) end
	ui.item:SetScript("OnEnter", function() GM.Panel(ui.item, "contHigh") end)
	ui.item:SetScript("OnLeave", function() GM.Panel(ui.item, "contMedium") end)

	local iconBox = CreateFrame("Frame", nil, ui.item)
	iconBox:SetSize(44, 44)
	iconBox:SetPoint("LEFT", 6, 0)
	GM.Panel(iconBox, "contHighest", "outlineVar")
	if GM.ChromePanel then GM.ChromePanel(iconBox) end
	ui.icon = iconBox:CreateTexture(nil, "ARTWORK")
	ui.icon:SetSize(40, 40)
	ui.icon:SetPoint("CENTER")
	-- hover → real item tooltip (textures can't take scripts)
	ui.iconBtn = CreateFrame("Button", nil, iconBox)
	ui.iconBtn:SetAllPoints()
	ui.iconBtn:SetScript("OnEnter", function(self)
		if not self.itemID then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(self.itemID)
		else
			GameTooltip:SetHyperlink("item:" .. self.itemID)
		end
		GameTooltip:Show()
	end)
	ui.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	ui.item.name = GM.MakeFontString(ui.item, GM.FONT_MED, 12, "text")
	ui.item.name:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 10, -4)
	ui.item.name:SetPoint("RIGHT", ui.item, "RIGHT", -8, 0)
	ui.item.name:SetJustifyH("LEFT")
	ui.item.sub = GM.MakeFontString(ui.item, GM.FONT, 10, "textDim")
	ui.item.sub:SetPoint("TOPLEFT", ui.item.name, "BOTTOMLEFT", 0, -5)
	ui.item.sub:SetPoint("RIGHT", ui.item, "RIGHT", -8, 0)
	ui.item.sub:SetJustifyH("LEFT")

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
		if IsShiftKeyDown() then
			GM.ModifiedItemClick(ui.iconBtn and ui.iconBtn.itemID)
		elseif CursorHasItem() then
			DropItem()
		end
	end)

	-- Trend chart region
	ui.chart = CreateFrame("Frame", nil, frame)
	ui.chart:SetPoint("TOPLEFT", PAD, -128)
	ui.chart:SetWidth(LEFT_W)
	ui.chart:SetHeight(150)
	GM.Panel(ui.chart, "contLowest")
	if GM.ChromePanel then GM.ChromePanel(ui.chart) end
	ui.chart.title = GM.MakeFontString(ui.chart, GM.FONT_MED, 9, "secondary")
	ui.chart.title:SetPoint("TOPLEFT", 8, -5)
	ui.chart.title:SetText("PRICE · VOLUME")
	ui.chart.msg = GM.MakeFontString(ui.chart, GM.FONT, 10, "textDim")
	ui.chart.msg:SetPoint("CENTER", 0, -8)
	-- nothing drawn may escape the chart region
	if ui.chart.SetClipsChildren then ui.chart:SetClipsChildren(true) end

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
	-- thin progress bar along the bottom edge of the summary strip
	ui.prog = ui.sumBar:CreateTexture(nil, "ARTWORK")
	ui.prog:SetPoint("BOTTOMLEFT", 0, 0)
	ui.prog:SetHeight(2)
	ui.prog:SetColorTexture(GM.RGB("accent"))
	ui.prog:Hide()

	-- buttons align under the left column (the plan table's edge)
	ui.exec = CreateFrame("Button", nil, frame)
	ui.exec:SetSize(190, 30)
	ui.exec:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", PAD + LEFT_W, 8)
	GM.Panel(ui.exec, "accent")
	ui.exec.text = GM.MakeFontString(ui.exec, GM.FONT_BOLD, 12, "contLowest")
	ui.exec.text:SetAllPoints()
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
	ui.clear.text:SetAllPoints()
	ui.clear.text:SetText("CLEAR")
	ui.clear:SetScript("OnClick", function() PQ.ClearPlan() end)
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
	-- (/goblin 4238) flip to real names without a rescan
	GM.OnItemInfoLoaded(function() PQ.Refresh() end)
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

-- scan progress bar: frac in (0,1) shows it, anything else hides it
function PQ.Progress(frac)
	Build()
	if not ui.prog then return end
	if frac and frac > 0 and frac < 1 then
		ui.prog:SetWidth(LEFT_W * frac)
		ui.prog:Show()
	else
		ui.prog:Hide()
	end
end

-- a scan that produced no steps drops the stale plan so the window
-- isn't left showing rows/buttons for something already finished
function PQ.ClearPlan()
	PQ.plan = nil
	PQ.stepIndex = 1
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
	PQ.stepIndex = 1
	PQ.homeMode = false
	PQ.budgetConfirm = nil
	PQ.budgetWarn = nil
	PQ.lossConfirm = nil
	PQ.protectedOk = {}
	PQ.Refresh()
end

function PQ.SetItem(itemID, itemLink)
	Build()
	PQ.homeMode = false
	PQ.itemID = itemID
	PQ.item = itemLink
	PQ.scan = nil
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
	if PQ.plan and PQ.plan.mode == "postscan" then GM.Auctioning.PostScan() return end
	if PQ.plan and PQ.plan.mode == "cancelscan" then GM.Auctioning.CancelScan() return end
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
	local plan, err = GM.Solver.Plan(asks, p50, entry and entry.p90, gold, vel, {
		riskBudget = GM.db.riskBudget,
		minProfitMargin = (tonumber(sOps.belowPct) or 10) / 100,
		commodity = isCommodity,
		owned = GM.BagCount(workID),
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
	plan.deposit = GM.AH.DepositCost(workID, plan.qty + (plan.owned or 0)) or 0
	plan.ev = plan.ev - plan.deposit
	PQ.plan = plan
	PQ.stepIndex = 1
	PQ.lossConfirm = nil
	PQ.protectedOk = {}
	PQ.Refresh()
end

-- protected-group confirm: a small modal warning that this plan step
-- would sell or post an item the user flagged protected via its group.
-- One confirm per item per plan — HOLD leaves the step armed.
local protD
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
				PQ.stepIndex = PQ.stepIndex + 1
				GM.After(1.0, function() PQ.Rescan() end)
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
	local result = (step.kind == "move" or step.kind == "mail"
			or step.kind == "mailcollect")
		and GM.Banking.Execute(step)
		or step.kind == "destroy" and GM.Destroying.Execute(step)
		or (step.kind == "vendbuy" or step.kind == "vendsell")
			and GM.Vendoring.Execute(step)
		or GM.AH.Execute(step)
	if result == "confirm" then
		PQ.Refresh()
		return
	end
	if result then
		if (step.kind == "buy" or step.kind == "vendbuy") and GM.Budget then
			GM.Budget.Record(step, step.cost
				or (step.unit or 0) * (step.qty or 1))
		end
		PQ.budgetConfirm = nil
		PQ.budgetWarn = nil
		PQ.submitFlash = GetTime()
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
	-- day-boundary gridlines across the 7-day window
	if weekMode then
		for d = 1, 6 do
			local gx = pad + d / 7 * W
			Segment(ui.chart, gx, volBase, gx, priceTop, "outlineVar")
		end
	end
	-- hi/lo scale labels right-aligned inside the gutter
	local gR = ui.chart:GetWidth() - 6
	Label(ui.chart, gR, priceTop + 2, GM.Money(hi), "textDim", 9, "RIGHT")
	Label(ui.chart, gR, priceBase - 6, GM.Money(lo), "textDim", 9, "RIGHT")

	for i = 2, #pts do
		Segment(ui.chart, pts[i - 1].px, pts[i - 1].py, pts[i].px, pts[i].py)
	end
	for i, p in ipairs(pts) do
		local endpoint = i == 1 or i == #pts
		local hot = (weekMode and i == #pts) or p.tag == "est"
		if not weekMode or endpoint then
			Dot(ui.chart, p.px, p.py, hot and 5 or 4, hot and "accent" or "textDim")
			-- only the latest point earns an in-plot label; the rest
			-- read from the gutter scale
			if hot then
				local ly = p.py + 9
				if ly > priceTop - 6 then ly = p.py - 16 end
				-- latest sits at the plot's right edge — end the label
				-- just left of the dot so it can't bleed into the gutter
				Label(ui.chart, p.px - 6, ly, GM.Money(p.v), "accent", nil, "RIGHT")
			end
		end
	end
	for _, v in ipairs({ entry.p10, entry.p90 }) do
		if v and v >= lo and v <= hi then
			HRule(py(v), 0.8)
		end
	end
	-- time axis markers at the plot's true edges
	if weekMode then
		Label(ui.chart, pad, 4, "7d ago", "textDim", 9, "LEFT")
		Label(ui.chart, pad + W, 4, "now", "textDim", 9, "RIGHT")
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
	end
end

function PQ.SetHome(on)
	PQ.homeMode = on and true or false
	PQ.Refresh()
end

function PQ.Refresh()
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
	local bookFresh = bAge and bAge < 600
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
		tinsert(sub, "region sales ~" .. (entry.vel >= 1000
			and format("%.0fk", entry.vel / 1000) or entry.vel) .. "/day")
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
	local minBuy = (bookFresh and GM.AH.BookMin(dispID))
		or (scanMode and curStep.cheapest)
		or (PQ.scan and PQ.scan.cheapest)
	set("min buy", minBuy and GM.Money(minBuy))
	-- velocity is regional volume, not realm-local sell-time certainty
	set("region/day", entry and entry.vel and (entry.vel >= 1000
		and format("%.0fk", entry.vel / 1000) or tostring(entry.vel)))
	local liveSup = bookFresh and GM.AH.BookSupply(dispID)
	ui.statLabel["units"]:SetText(liveSup and "live units" or "DB auctions")
	set("units", (liveSup or (entry and entry.sup)) and tostring(liveSup or entry.sup))
	set("reset", entry and entry.reset and (GM.Money(entry.reset.below) .. " · ev " .. GM.Money(entry.reset.ev)))
	set("gold", GM.Money(GetMoney()))
	-- the cap is a fraction of gold, not a currency amount
	set("budget cap", GM.db and format("%.0f%%", (GM.db.riskBudget or 0) * 100))
	set("margin", GM.db and format("%.0f%%", (GM.db.minProfitMargin or 0) * 100))

	DrawChart(entry, dispID)

	-- plan rows — a window into steps. The active step recenters to
	-- row 3 (two finished steps of context above) whenever it changes;
	-- mousewheel scrolls manually until the next step advance
	local nSteps = PQ.plan and #PQ.plan.steps or 0
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
				local nm = step.name
					or (step.itemID and GM.ItemName and GM.ItemName(step.itemID))
					or ""
				if #nm > 16 then nm = nm:sub(1, 15) .. "…" end
				row.qty:SetText((GM.QHex(step.itemID) or "")
					.. nm .. "|r ×" .. step.qty)
			else
				row.qty:SetText(step.qty .. (step.kind == "post" and " (relist)" or ""))
			end
			row.price:SetText(step.desc or step.text
				or (GM.Money(step.unit) .. (step.kind == "post" and "" or " /ea")))
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
				or "fetch/alt mats first, then buy the shortfall")
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
			local verb = PQ.stepIndex > #PQ.plan.steps and "PLAN DONE"
				or kind == "cancel" and "CANCEL NEXT"
				or kind == "post" and "POST NEXT"
				or kind == "skip" and "NEXT"
				or kind == "note" and (curStep.recipeID
					and format("CRAFT · %d/%d", curStep.crafted or 0,
						curStep.qty or 1)
					or "DONE")
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
