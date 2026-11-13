local _, GM = ...

-- Groups/ops editor (/goblin groups). Typed controls per the
-- goblinmind-groups-controls proposal: every row shows an I/O
-- ownership button (I=inherited, O=local override — click O to reset),
-- bools/enums are segment toggles, six quantity fields get steppers,
-- expr fields keep text + a 7-source picker, mailTo gets a target
-- capture helper. Editing a displayed inherited value writes a local
-- override; empty+Enter or clicking O deletes the local key.

GM.GroupsUI = {}
local GU = GM.GroupsUI
local ui

local EXPR_SOURCES = { "dbmarket", "vendorsell", "crafting", "matprice",
	"dbminbuyout", "dbhistorical", "dbregionmarketavg" }

-- { label, opType, field, kind, widget, extra }
-- widget: bool | seg{opts} | stepper{min} | num{min,max,minWarn} | expr | recip
local OP_FIELDS = {
	{ "Min price",       "auctioning", "min",            "expr", "expr" },
	{ "Normal price",    "auctioning", "normal",         "expr", "expr" },
	{ "Max price",       "auctioning", "max",            "expr", "expr" },
	{ "Undercut",        "auctioning", "undercut",       "expr", "expr" },
	{ "Post cap",        "auctioning", "postCap",        "num",  "stepper", { min = 0, tip = "0 = no cap" } },
	{ "Stack size",      "auctioning", "stackSize",      "num",  "stepper", { min = 0, tip = "0 = available stack" } },
	{ "Duration",        "auctioning", "duration",       "num",  "seg", { opts = { { "12h", 1 }, { "24h", 2 }, { "48h", 3 } } } },
	{ "Bid %",           "auctioning", "bidPercent",     "num",  "num", { min = 0, max = 100 } },
	{ "Cancel under",    "auctioning", "cancelUndercut", "bool", "bool" },
	{ "Buy margin %",    "shopping",   "belowPct",       "num",  "num", { min = 0, max = 100 } },
	{ "Buy max",         "shopping",   "maxPrice",       "expr", "expr" },
	{ "Snipe max",       "sniper",     "belowPrice",     "expr", "expr" },
	{ "Snipe off %",     "sniper",     "belowPct",       "num",  "num", { min = 0, max = 100,
		tip = "fallback discount if price expr doesn't resolve" } },
	{ "Refresh sec",     "sniper",     "refreshTime",    "num",  "num", { min = 120,
		tip = "runtime minimum 120s; scheduler reads Base Group" } },
	{ "Snipe sound",     "sniper",     "sound",          "bool", "bool" },
	{ "Craft cost",      "crafting",   "craftCost",      "expr", "expr" },
	{ "Min profit",      "crafting",   "minProfit",      "expr", "expr" },
	{ "Restock",         "crafting",   "restock",        "bool", "bool" },
	{ "Restock qty",     "crafting",   "restockQty",     "num",  "stepper", { min = 0 } },
	{ "Mail to",         "mailing",    "sendTo",         "text", "recip" },
	{ "Mail keep",       "mailing",    "keepQty",        "num",  "stepper", { min = 0 } },
	{ "Mail max",        "mailing",    "maxQty",         "num",  "stepper", { min = 0, tip = "0 = unlimited" } },
	{ "Mail all",        "mailing",    "sendAll",        "bool", "bool" },
	{ "Move to",         "warehousing","moveTo",         "text", "seg", { opts = { { "Bags", "bags" }, { "Bank", "bank" } } } },
	{ "Bank keep",       "warehousing","keepQty",        "num",  "stepper", { min = 0 } },
	{ "Restore empty",   "warehousing","restoreEmpty",   "bool", "bool" },
	{ "Vendor buy",      "vendoring",  "vendorBuyBelow", "expr", "expr" },
	{ "Auto buy",        "vendoring",  "autoBuy",        "bool", "bool", { tip = "config flag — execution stays one click per action" } },
	{ "Auto sell",       "vendoring",  "autoSell",       "bool", "bool", { tip = "config flag — execution stays one click per action" } },
	{ "Destroy min",     "destroying", "threshold",      "expr", "expr" },
	{ "Destroy max",     "destroying", "belowPrice",     "expr", "expr" },
}

-- ============ raw vs merged state ============

local function editPath()
	return ui.editPath or "Base Group"
end

local function ancestors(path)
	local out, seg = {}, nil
	for part in (path or ""):gmatch("[^/]+") do
		seg = seg and seg .. "/" .. part or part
		out[#out + 1] = seg
	end
	return out
end

local function RawLocal(path, opType, field)
	local g = GM.Groups.db.groups[path]
	if not (g and g.ops and g.ops[opType]) then return nil end
	return g.ops[opType][field]
end

-- effective value + where it comes from: "local", an ancestor path, or
-- "Defaults". excludeLeaf=true answers "what would reset restore".
local function ResolveField(path, opType, field, excludeLeaf)
	local chain = ancestors(path)
	for i = excludeLeaf and (#chain - 1) or #chain, 1, -1 do
		local v = RawLocal(chain[i], opType, field)
		if v ~= nil then
			return v, (chain[i] == path and not excludeLeaf) and "local" or chain[i]
		end
	end
	local d = GM.Groups.OP_DEFAULTS[opType]
	return d and d[field], "Defaults"
end

local function groupOps(path, opType)
	GM.Groups.Ensure(path)
	local g = GM.Groups.db.groups[path]
	g.ops[opType] = g.ops[opType] or {}
	return g.ops[opType]
end

-- ============ widget helpers ============

local function EditBox(parent, w, h)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, h or 20)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(5, 4, 0, 0)
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(GM.RGB("contLowest"))
	local mark = eb:CreateTexture(nil, "ARTWORK")
	mark:SetSize(2, (h or 20) - 2)
	mark:SetPoint("TOPLEFT", eb, "TOPLEFT", 0, -1)
	mark:SetColorTexture(GM.RGB("outlineVar"))
	eb.mark = mark
	eb:SetScript("OnEscapePressed", function(self)
		self.dirty = nil
		self:ClearFocus()
		GU.Refresh()
	end)
	eb:SetScript("OnTextChanged", function(self, user)
		if user then
			self.dirty = true
			self.mark:SetColorTexture(GM.RGB("accent"))
		end
	end)
	eb:SetScript("OnEditFocusGained", function(self)
		self.capPath = editPath()
		self.capText = self:GetText()
	end)
	return eb
end

local function Btn(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h or 20)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 10, "accent")
	b.text:SetPoint("CENTER")
	b.text:SetText(label)
	return b
end

local function Tip(btn, fn)
	btn:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		local lines = fn()
		GameTooltip:SetText(lines[1])
		for i = 2, #lines do GameTooltip:AddLine(lines[i], 0.8, 0.8, 0.75, true) end
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function SetMark(eb, state)
	eb.mark:SetColorTexture(GM.RGB(
		state == "err" and "err" or state == "ok" and "pos"
		or state == "dirty" and "accent" or "outlineVar"))
end

local function Footer(msg, err)
	ui.footer:SetText(msg)
	ui.footer:SetTextColor(GM.RGB(err and "err" or "secondary"))
end

local FOOTER_DEFAULT = "I = inherited · O = local (click to reset) · Enter saves · Esc discards"

-- discard any unfocused draft edits (group switch, discrete commit)
local function DiscardDrafts()
	for _, r in ipairs(ui.opRows) do
		if r.eb and r.eb.dirty then
			r.eb.dirty = nil
			SetMark(r.eb)
			Footer("Unsaved field edit discarded")
		end
	end
end

-- ============ commit ============

local function CommitRaw(path, opType, field, value)
	if path ~= editPath() then return nil, "group changed" end
	groupOps(path, opType)[field] = value
	return true
end

-- text commit: empty = delete local key; otherwise validate by kind
local function CommitText(eb)
	local f = eb.field
	local v = strtrim(eb:GetText() or "")
	if eb.capPath and eb.capPath ~= editPath() then
		Footer("Unsaved field edit discarded", true)
		eb.dirty = nil
		eb:ClearFocus()
		GU.Refresh()
		return
	end
	if v == "" then
		CommitRaw(editPath(), f[2], f[3], nil)
		eb.dirty = nil
		SetMark(eb)
		eb:ClearFocus()
		Footer(f[1] .. " → inherit")
		GU.Refresh()
		return
	end
	if f[4] == "num" then
		local n = tonumber(v)
		local lo, hi = f[6] and f[6].min, f[6] and f[6].max
		if not (n and n == n and n ~= math.huge and n ~= -math.huge) then
			SetMark(eb, "err") Footer("not a number", true) return
		end
		if f[5] == "stepper" and n % 1 ~= 0 then
			SetMark(eb, "err") Footer("must be a whole number", true) return
		end
		if lo and n < lo then
			SetMark(eb, "err") Footer("minimum " .. lo, true) return
		end
		if hi and n > hi then
			SetMark(eb, "err") Footer("maximum " .. hi, true) return
		end
		CommitRaw(editPath(), f[2], f[3], n)
	elseif f[4] == "expr" then
		local val, err = GM.Pricing.Eval(v, GM.PlanQueue.itemID)
		if err then
			SetMark(eb, "err")
			Footer(f[1] .. ": " .. err, true)
			return
		end
		CommitRaw(editPath(), f[2], f[3], v)
		if not val then
			Footer(f[1] .. " saved; no resolved price for this item")
		end
	else -- text
		CommitRaw(editPath(), f[2], f[3], v)
	end
	eb.dirty = nil
	SetMark(eb, "ok")
	eb:ClearFocus()
	GU.Refresh()
end

-- discrete commit (toggle/segment/stepper): discard other drafts first
local function CommitDiscrete(f, value)
	DiscardDrafts()
	CommitRaw(editPath(), f[2], f[3], value)
	GU.Refresh()
end

-- ============ row construction ============

local ROW_Y0, ROW_PITCH, ROW_H = -280, 19, 18
local COL_X = { 10, 256 }
local COL_W, LABEL_W, IO_X, VAL_X, VAL_W = 234, 76, 80, 100, 134

local function Segment(parent, label, w)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, ROW_H)
	GM.Panel(b, "contLowest")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
	b.text:SetPoint("CENTER")
	b.text:SetText(label)
	return b
end

local function PaintSeg(b, selected)
	b._gmBg:SetColorTexture(GM.RGB(selected and "contHighest" or "contLowest"))
	b.text:SetTextColor(GM.RGB(selected and "accent" or "textDim"))
end

local function BuildValueControl(row, f, host)
	local w = f[5]
	if w == "bool" then
		row.on  = Segment(host, "On", 66);  row.on:SetPoint("TOPLEFT", VAL_X, 0)
		row.off = Segment(host, "Off", 66); row.off:SetPoint("TOPLEFT", VAL_X + 68, 0)
		row.on:SetScript("OnClick", function() CommitDiscrete(f, true) end)
		row.off:SetScript("OnClick", function() CommitDiscrete(f, false) end)
	elseif w == "seg" then
		row.segs = {}
		local widths = #f[6].opts == 3 and { 43, 43, 44 } or { 66, 66 }
		local x = VAL_X
		for i, opt in ipairs(f[6].opts) do
			local b = Segment(host, opt[1], widths[i])
			b:SetPoint("TOPLEFT", x, 0)
			b:SetScript("OnClick", function() CommitDiscrete(f, opt[2]) end)
			b.optValue = opt[2]
			row.segs[i] = b
			x = x + widths[i] + 2
		end
	elseif w == "stepper" then
		row.minus = Segment(host, "-", 18); row.minus:SetPoint("TOPLEFT", VAL_X, 0)
		row.plus  = Segment(host, "+", 18); row.plus:SetPoint("TOPLEFT", VAL_X + 116, 0)
		row.eb = EditBox(host, 94, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X + 20, 0)
		row.eb:SetNumeric(false)
		row.minus:SetScript("OnClick", function()
			local cur = tonumber(row.eb:GetText())
			if row.eb.dirty and not cur then
				Footer("invalid draft — fix before stepping", true) return
			end
			cur = cur or tonumber(row.effective) or 0
			CommitDiscrete(f, math.max((f[6] and f[6].min) or 0, cur - 1))
		end)
		row.plus:SetScript("OnClick", function()
			local cur = tonumber(row.eb:GetText())
			if row.eb.dirty and not cur then
				Footer("invalid draft — fix before stepping", true) return
			end
			cur = cur or tonumber(row.effective) or 0
			CommitDiscrete(f, cur + 1)
		end)
	elseif w == "num" then
		row.eb = EditBox(host, VAL_W, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X, 0)
	elseif w == "expr" then
		row.eb = EditBox(host, 114, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X, 0)
		row.aux = Segment(host, "v", 18)
		row.aux:SetPoint("TOPLEFT", VAL_X + 116, 0)
		row.aux.eb = row.eb
		row.aux:SetScript("OnClick", function(self) GU.ToggleSourceMenu(self) end)
		Tip(row.aux, function()
			return { "Insert a price source",
				"Replaces the draft — press Enter to save" }
		end)
	elseif w == "recip" then
		row.eb = EditBox(host, 114, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X, 0)
		row.aux = Segment(host, "T", 18)
		row.aux:SetPoint("TOPLEFT", VAL_X + 116, 0)
		row.aux.eb = row.eb
		row.aux:SetScript("OnClick", function()
			if not (UnitIsPlayer("target") and UnitName("target")) then return end
			local name, realm = UnitName("target")
			row.eb:SetText((realm and #realm > 0) and (name .. "-" .. realm) or name)
			row.eb.dirty = true
			SetMark(row.eb, "dirty")
			row.eb:SetFocus()
		end)
		Tip(row.aux, function()
			return { "Use target name",
				"Captures current player target (does not send mail)" }
		end)
	end
	if row.eb then
		row.eb.field = f
		row.eb:SetScript("OnEnterPressed", function(self) CommitText(self) end)
	end
end

local function BuildUI()
	if ui then return end
	ui = {}
	local f = CreateFrame("Frame", "GoblinMindGroupsUI", UIParent)
	f:SetSize(500, 630)
	f:SetPoint("CENTER", -280, 20)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetScript("OnMouseDown", function(f)
		if f.Raise then f:Raise() elseif RaiseFrame then RaiseFrame(f) end
	end)
	f:SetFrameLevel(100)
	tinsert(UISpecialFrames, "GoblinMindGroupsUI")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	GM.Panel(f, "contLow", "outlineVar")
	f:SetScript("OnHide", function()
		DiscardDrafts()
		if ui.srcMenu then ui.srcMenu:Hide() ui.srcCatcher:Hide() end
	end)
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText("GROUPS · OPS")
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, title, "groups")
	end

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	ui.itemLine = GM.MakeFontString(f, GM.FONT_MED, 10, "text")
	ui.itemLine:SetPoint("TOPLEFT", 10, -30)

	local pathLabel = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	pathLabel:SetPoint("TOPLEFT", 10, -50)
	pathLabel:SetText("ASSIGN ITEM TO PATH (use / for nesting)")
	ui.pathBox = EditBox(f, 256)
	ui.pathBox:SetPoint("TOPLEFT", 10, -62)
	local assign = Btn(f, "ASSIGN", 66)
	assign:SetPoint("LEFT", ui.pathBox, "RIGHT", 8, 0)
	assign:SetScript("OnClick", function() GU.Assign() end)

	local gLabel = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	gLabel:SetPoint("TOPLEFT", 10, -92)
	gLabel:SetText("GROUPS — click to edit")
	ui.groupRows = {}
	for i = 1, 8 do
		local row = CreateFrame("Button", nil, f)
		row:SetSize(478, 18)
		row:SetPoint("TOPLEFT", 10, -104 - (i - 1) * 20)
		row.text = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.text:SetPoint("LEFT", 4, 0)
		row:SetScript("OnClick", function(self)
			DiscardDrafts()
			ui.editPath = self.path
			ui.pathBox:SetText(self.path)
			GU.Refresh()
		end)
		ui.groupRows[i] = row
	end

	ui.opsHeader = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	ui.opsHeader:SetPoint("TOPLEFT", 10, -265)

	ui.opRows = {}
	for i, fd in ipairs(OP_FIELDS) do
		local col = i <= 15 and 1 or 2
		local rowN = col == 1 and i or i - 15
		local host = CreateFrame("Frame", nil, f)
		host:SetSize(COL_W, ROW_H)
		host:SetPoint("TOPLEFT", COL_X[col], ROW_Y0 - (rowN - 1) * ROW_PITCH)
		local row = { def = fd, host = host }

		row.lab = GM.MakeFontString(host, GM.FONT, 10, "textDim")
		row.lab:SetSize(LABEL_W, ROW_H)
		row.lab:SetPoint("TOPLEFT", 0, 0)
		row.lab:SetText(fd[1])
		row.lab:SetJustifyH("LEFT")

		row.io = CreateFrame("Button", nil, host)
		row.io:SetSize(16, ROW_H)
		row.io:SetPoint("TOPLEFT", IO_X, 0)
		GM.Panel(row.io, "contLowest", "outlineVar")
		row.io.text = GM.MakeFontString(row.io, GM.FONT_BOLD, 9, "textDim")
		row.io.text:SetPoint("CENTER")
		row.io.row = row
		row.io:SetScript("OnClick", function(self)
			-- O → delete local key → inherit
			if RawLocal(editPath(), fd[2], fd[3]) == nil then return end
			groupOps(editPath(), fd[2])[fd[3]] = nil
			Footer(fd[1] .. " → inherit")
			GU.Refresh()
		end)
		Tip(row.io, function()
			local localV = RawLocal(editPath(), fd[2], fd[3])
			if localV == nil then
				local _, src = ResolveField(editPath(), fd[2], fd[3])
				return { "Inherited from " .. src,
					"Edit the value to override on " .. editPath() }
			end
			local rv, src = ResolveField(editPath(), fd[2], fd[3], true)
			return { "Local override on " .. editPath(),
				"Click to remove — inherits " .. tostring(rv)
					.. " from " .. src }
		end)

		BuildValueControl(row, fd, host)
		ui.opRows[i] = row
	end

	ui.footer = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	ui.footer:SetPoint("BOTTOMLEFT", 10, 8)
	ui.footer:SetText(FOOTER_DEFAULT)
end

-- ============ source picker menu ============

local function BuildSourceMenu()
	if ui.srcMenu then return end
	local catcher = CreateFrame("Button", nil, ui.frame)
	catcher:SetAllPoints(UIParent)
	catcher:SetFrameLevel(ui.frame:GetFrameLevel() + 19)
	catcher:SetScript("OnClick", function()
		ui.srcMenu:Hide() catcher:Hide()
	end)
	catcher:Hide()
	local m = CreateFrame("Frame", nil, ui.frame)
	m:SetSize(218, 4 + 7 * 20 + 4)
	m:SetFrameLevel(ui.frame:GetFrameLevel() + 20)
	GM.Panel(m, "contLow", "outline")
	m:Hide()
	m.btns = {}
	for i, src in ipairs(EXPR_SOURCES) do
		local b = CreateFrame("Button", nil, m)
		b:SetSize(210, 20)
		b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
		b:SetFrameLevel(m:GetFrameLevel() + 1)
		b.text = GM.MakeFontString(b, GM.FONT, 10, "text")
		b.text:SetPoint("LEFT", 6, 0)
		b.text:SetText("100% " .. src)
		local hov = b:CreateTexture(nil, "ARTWORK")
		hov:SetAllPoints()
		hov:SetColorTexture(GM.RGB("contHigh"))
		hov:Hide()
		b:SetScript("OnEnter", function() hov:Show() end)
		b:SetScript("OnLeave", function() hov:Hide() end)
		b:SetScript("OnClick", function()
			local eb = m.eb
			if eb then
				eb:SetText("100% " .. src)
				eb.dirty = true
				SetMark(eb, "dirty")
				eb:SetFocus()
			end
			m:Hide() ui.srcCatcher:Hide()
		end)
		m.btns[i] = b
	end
	ui.srcMenu, ui.srcCatcher = m, catcher
end

function GU.ToggleSourceMenu(btn)
	BuildSourceMenu()
	local m = ui.srcMenu
	if m:IsShown() and m.eb == btn.eb then
		m:Hide() ui.srcCatcher:Hide() return
	end
	m.eb = btn.eb
	m:ClearAllPoints()
	m:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
	m:Show()
	ui.srcCatcher:Show()
end

-- ============ assign / refresh ============

function GU.Assign()
	local id = GM.PlanQueue.itemID
	if not id then
		GM.Print("no item targeted — /goblin [item] first")
		return
	end
	local path = strtrim(ui.pathBox:GetText() or "")
	if path == "" then path = "Base Group" end
	local leaf = GM.Groups.Ensure(path)
	GM.Groups.Assign(id, leaf)
	ui.editPath = leaf
	GM.Print(format("item %d → %s", id, leaf))
	GU.Refresh()
end

function GU.Refresh()
	if not ui then return end
	local id = GM.PlanQueue.itemID
	local group = (id and GM.Groups.GroupForItem(id)) or "Base Group"
	ui.editPath = ui.editPath or group
	ui.itemLine:SetText(id
		and format("item %d · group %s", id, group)
		or "no item targeted — /goblin [item] first")
	if id and ui.pathBox:GetText() == "" then ui.pathBox:SetText(group) end

	local groups = GM.Groups.List()
	for i, row in ipairs(ui.groupRows) do
		local g = groups[i]
		if g then
			row:Show()
			row.path = g.path
			row.text:SetText(format("%s  (%d)", g.path, g.n))
			row.text:SetTextColor(GM.RGB(g.path == ui.editPath and "accent" or "text"))
		else
			row:Hide()
		end
	end

	ui.opsHeader:SetText("OPS — " .. editPath())
	local showPath = editPath()
	for _, r in ipairs(ui.opRows) do
		local fd = r.def
		local localV = RawLocal(showPath, fd[2], fd[3])
		local owned = localV ~= nil
		local eff = GM.Groups.GetOpsForPath(showPath, fd[2])[fd[3]]
		r.effective = eff

		-- I/O chip
		r.io.text:SetText(owned and "O" or "I")
		r.io.text:SetTextColor(GM.RGB(owned and "accent" or "textDim"))

		-- value control
		if not (r.eb and r.eb.dirty) then
			if r.eb then r.eb:SetText(eff == nil and "" or tostring(eff)) end
		end
		if fd[5] == "bool" then
			PaintSeg(r.on, eff == true)
			PaintSeg(r.off, eff == false)
		elseif fd[5] == "seg" then
			for _, b in ipairs(r.segs) do PaintSeg(b, eff == b.optValue) end
		end
	end
	ui.footer:SetText(FOOTER_DEFAULT)
end

function GU.Retarget()
	if ui then DiscardDrafts() ui.editPath = nil end
	GU.Refresh()
end

function GU.Show()
	BuildUI()
	ui.editPath = nil
	ui.frame:Show()
	GU.Refresh()
end

function GU.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function GU.Toggle()
	BuildUI()
	if ui.frame:IsShown() then ui.frame:Hide() else GU.Show() end
end
