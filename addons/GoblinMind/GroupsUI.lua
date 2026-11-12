local _, GM = ...

-- Minimal groups/ops pane (/goblin groups). First pass: assign the
-- targeted item to a group path, see the group list, edit the main
-- auctioning/shopping op fields as expression strings validated by
-- Pricing. Full tree UI is polish for later.

GM.GroupsUI = {}
local GU = GM.GroupsUI
local ui

local OP_FIELDS = {
	{ "min",            "auctioning", "min",            "expr" },
	{ "normal",         "auctioning", "normal",         "expr" },
	{ "max",            "auctioning", "max",            "expr" },
	{ "undercut",       "auctioning", "undercut",       "expr" },
	{ "postCap",        "auctioning", "postCap",        "num"  },
	{ "stackSize",      "auctioning", "stackSize",      "num"  },
	{ "duration",       "auctioning", "duration",       "num"  },
	{ "bidPercent %",   "auctioning", "bidPercent",     "num"  },
	{ "cancelUndercut", "auctioning", "cancelUndercut", "bool" },
	{ "belowPct %",     "shopping",   "belowPct",       "num"  },
	{ "maxPrice",       "shopping",   "maxPrice",       "expr" },
}

local function EditBox(parent, w)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, 20)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(5, 4, 0, 0)
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(GM.RGB("contLowest"))
	local mark = eb:CreateTexture(nil, "ARTWORK")
	mark:SetSize(2, 18)
	mark:SetPoint("TOPLEFT", eb, "TOPLEFT", 0, -1)
	mark:SetColorTexture(GM.RGB("outlineVar"))
	eb.mark = mark
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	return eb
end

local function Btn(parent, label, w)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, 20)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 10, "accent")
	b.text:SetPoint("CENTER")
	b.text:SetText(label)
	return b
end

local function SetMark(eb, ok)
	eb.mark:SetColorTexture(GM.RGB(ok and "pos" or "err"))
end

local function editPath()
	return ui.editPath or "Base Group"
end

local function groupOps(path, opType)
	local g = GM.Groups.Ensure(path) and GM.Groups.db.groups[path]
	g.ops[opType] = g.ops[opType] or {}
	return g.ops[opType]
end

local function BuildUI()
	if ui then return end
	ui = {}
	local f = CreateFrame("Frame", "GoblinMindGroupsUI", UIParent)
	f:SetSize(380, 534)
	f:SetPoint("CENTER", -280, 20)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetScript("OnMouseDown", function(f)
		if f.Raise then f:Raise() elseif RaiseFrame then RaiseFrame(f) end
	end)
	f:SetFrameLevel(100) -- above the plan window so children can't interleave
	tinsert(UISpecialFrames, "GoblinMindGroupsUI") -- ESC closes it
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	GM.Panel(f, "contLow", "outlineVar")
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText("GROUPS · OPS")

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
		row:SetSize(360, 18)
		row:SetPoint("TOPLEFT", 10, -104 - (i - 1) * 20)
		row.text = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.text:SetPoint("LEFT", 4, 0)
		row:SetScript("OnClick", function(self)
			ui.editPath = self.path
			ui.pathBox:SetText(self.path)
			GU.Refresh()
		end)
		ui.groupRows[i] = row
	end

	local oLabel = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	oLabel:SetPoint("TOPLEFT", 10, -274)
	ui.opsHeader = oLabel
	ui.opRows = {}
	for i, r in ipairs(OP_FIELDS) do
		local lab = GM.MakeFontString(f, GM.FONT, 10, "textDim")
		lab:SetSize(90, 20)
		lab:SetPoint("TOPLEFT", 10, -286 - (i - 1) * 20)
		lab:SetText(r[1])
		lab:SetJustifyH("LEFT")
		local eb = EditBox(f, 240)
		eb:SetPoint("LEFT", lab, "RIGHT", 8, 0)
		eb.field = r
		eb:SetScript("OnEnterPressed", function(self) GU.SaveOp(self) end)
		ui.opRows[i] = { label = lab, box = eb, def = r }
	end

	local hint = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	hint:SetPoint("BOTTOMLEFT", 10, 8)
	hint:SetText("empty field = inherit · bool: true/false · expr validated against current item")
end

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

function GU.SaveOp(eb)
	local r = eb.field
	local v = strtrim(eb:GetText() or "")
	local ops = groupOps(editPath(), r[2])
	local id = GM.PlanQueue.itemID
	if v == "" then
		ops[r[3]] = nil -- unset → inherit from parent/defaults
		SetMark(eb, true)
	elseif r[4] == "num" then
		local n = tonumber(v)
		if n then ops[r[3]] = n SetMark(eb, true)
		else SetMark(eb, false) return end
	elseif r[4] == "bool" then
		local b = v:lower()
		if b == "true" or b == "1" or b == "on" or b == "yes" then
			ops[r[3]] = true SetMark(eb, true)
		elseif b == "false" or b == "0" or b == "off" or b == "no" then
			ops[r[3]] = false SetMark(eb, true)
		else SetMark(eb, false) return end
	else
		local _, err = GM.Pricing.Eval(v, id)
		if err == nil then ops[r[3]] = v SetMark(eb, true)
		else SetMark(eb, false) return end
	end
	eb:ClearFocus()
	GM.Print(format("%s.%s saved on %s", r[2], r[3], editPath()))
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
	for _, r in ipairs(ui.opRows) do
		local ops = GM.Groups.GetOpsForPath(editPath(), r.def[2])
		local v = ops[r.def[3]]
		r.box:SetText(v == nil and "" or tostring(v))
		r.box.mark:SetColorTexture(GM.RGB("outlineVar"))
	end
end

-- item retargeted elsewhere — ops should follow the new item's group
function GU.Retarget()
	if ui then ui.editPath = nil end
	GU.Refresh()
end

function GU.Toggle()
	BuildUI()
	if ui.frame:IsShown() then
		ui.frame:Hide()
	else
		ui.editPath = nil -- re-follow the current item's group
		ui.frame:Show()
		GU.Refresh()
	end
end
