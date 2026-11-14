local _, GM = ...
local W = GM.Widgets

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

-- shared op-field definitions live on GM.Groups so OpsUI can build
-- the same controls for named operations
local OP_FIELDS = GM.Groups.OP_FIELDS

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
	-- Base Group is the root — every group inherits its ops
	if out[1] ~= "Base Group" then tinsert(out, 1, "Base Group") end
	return out
end

local function RawLocal(path, opType, field)
	local g = GM.Groups.db.groups[path]
	if not (g and g.ops and g.ops[opType]) then return nil end
	return g.ops[opType][field]
end

-- effective value + where it comes from: "local", "op:<name>", an
-- ancestor path, or "Defaults". excludeLeaf=true answers "what would
-- reset restore". Same precedence as Groups.Merged: local overrides
-- beat the assigned named op at each cascade level.
local function ResolveField(path, opType, field, excludeLeaf)
	local chain = ancestors(path)
	for i = excludeLeaf and (#chain - 1) or #chain, 1, -1 do
		local v = RawLocal(chain[i], opType, field)
		if v ~= nil then
			return v, (chain[i] == path and not excludeLeaf) and "local" or chain[i]
		end
		local name = GM.Groups.OpAssigned(chain[i], opType)
		local op = name and GM.Groups.OpFields(opType, name)
		if op and op[field] ~= nil then
			return op[field], "op:" .. name
				.. (chain[i] ~= path and (" (" .. chain[i] .. ")") or "")
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
		GU.Refresh()
		Footer(f[1] .. " → inherit")
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
	else -- text
		CommitRaw(editPath(), f[2], f[3], v)
	end
	eb.dirty = nil
	SetMark(eb, "ok")
	eb:ClearFocus()
	GU.Refresh()
	if f[4] == "expr" and v ~= "" and not val then
		Footer(f[1] .. " saved; no resolved price for this item")
	end
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

-- ============ window ============
-- TSM-parity groups page: ITEMS page = group tree · members ·
-- searchable catalogue (click assigns to the selected group, drop
-- items anywhere to add); OPS page = the typed operation editor.

local WIN_W, WIN_H = 860, 640
local TREE_ROWS, LIST_ROWS = 22, 20

local function ColPanel(parent, x, w, title)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOPLEFT", x, 0)
	p:SetPoint("BOTTOMLEFT", x, 0)
	p:SetWidth(w)
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_MED, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	p.count = GM.MakeFontString(p, GM.FONT, 9, "textDim")
	p.count:SetPoint("TOPRIGHT", -8, -7)
	if p.SetClipsChildren then p:SetClipsChildren(true) end
	return p, t
end

-- item row: icon + name + dim right-text + optional remove button
local function ItemRow(parent, w)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(w, 22)
	W.HoverTint(row)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 2, 0)
	row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
	row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.name:SetPoint("LEFT", 22, 0)
	row.name:SetWidth(w - 150)
	row.name:SetJustifyH("LEFT")
	row.sub = GM.MakeFontString(row, GM.FONT, 8, "secondary")
	row.sub:SetPoint("LEFT", 22, -9)
	row.sub:SetWidth(w - 150)
	row.sub:SetJustifyH("LEFT")
	row.right = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.right:SetPoint("RIGHT", -18, 0)
	row.right:SetJustifyH("RIGHT")
	row.x = CreateFrame("Button", nil, row)
	row.x:SetSize(14, 14)
	row.x:SetPoint("RIGHT", -2, 0)
	row.x.text = GM.MakeFontString(row.x, GM.FONT_BOLD, 9, "textDim")
	row.x.text:SetPoint("CENTER")
	row.x.text:SetText("x")
	row:SetScript("OnEnter", function(self)
		if not self.id then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(self.id)
		else
			GameTooltip:SetText(self.name:GetText() or "")
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row:SetScript("OnMouseDown", function(self, btn)
		if btn == "LeftButton" and self.id then
			local x, y = GetCursorPosition()
			ui.pending = { kind = "item", id = self.id,
				icon = self.icon:GetTexture(), x = x, y = y }
		end
	end)
	return row
end

local function ListPanel(parent, x, w, title, onWheel)
	local p, t = ColPanel(parent, x, w, title)
	p:EnableMouseWheel(true)
	p:SetScript("OnMouseWheel", onWheel)
	local rows = {}
	for i = 1, LIST_ROWS do
		local row = ItemRow(p, w - 16)
		row:SetPoint("TOPLEFT", 8, -24 - (i - 1) * 23)
		rows[i] = row
	end
	return p, t, rows
end

local RowName -- defined below with the name-cache helpers

local function FillItemRow(row, id, right, sub)
	row.id = id
	row.icon:SetTexture(GM.ItemIcon and GM.ItemIcon(id)
		or "Interface\\Icons\\INV_Misc_QuestionMark")
	row.name:SetText(RowName(id))
	row.sub:SetText(sub or "")
	row.right:SetText(right or "")
end

local function BuildUI()
	if ui then return end
	ui = { catOff = 0, memOff = 0, treeOff = 0, page = "items", nameCache = {} }
	local f = CreateFrame("Frame", "GoblinMindGroupsUI", UIParent)
	f:SetSize(WIN_W, WIN_H)
	f:SetPoint("CENTER", -40, 20)
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
		ui.pending, ui.drag = nil, nil
		if ui.srcMenu then ui.srcMenu:Hide() ui.srcCatcher:Hide() end
	end)
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText("GROUPS")
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

	-- page segments: ITEMS | OPS
	ui.pageSegs = {}
	for i, p in ipairs({ { "ITEMS", "items" }, { "OPS", "ops" } }) do
		local b = CreateFrame("Button", nil, f)
		b:SetSize(50, 18)
		b:SetPoint("TOPRIGHT", -30 - (2 - i) * 54, -8)
		GM.Panel(b, "contHigh")
		b.text = GM.MakeFontString(b, GM.FONT_MED, 9, "textDim")
		b.text:SetPoint("CENTER")
		b.text:SetText(p[1])
		b.key = p[2]
		b:SetScript("OnClick", function() ui.page = p[2] GU.Refresh() end)
		ui.pageSegs[i] = b
	end

	-- ============ ITEMS page ============
	local items = CreateFrame("Frame", nil, f)
	items:SetPoint("TOPLEFT", 10, -34)
	items:SetPoint("BOTTOMRIGHT", -10, 30)
	ui.pageItems = items

	-- col A: group tree + management
	local treeP, treeT = ColPanel(items, 0, 186, "GROUPS")
	ui.treePanel = treeP
	treeP:EnableMouseWheel(true)
	treeP:SetScript("OnMouseWheel", function(_, d)
		ui.treeOff = math.max(0, ui.treeOff - d * 2)
		GU.RefreshTree()
	end)
	ui.treeRows = {}
	for i = 1, TREE_ROWS do
		local row = CreateFrame("Button", nil, treeP)
		row:SetSize(172, 18)
		row:SetPoint("TOPLEFT", 6, -22 - (i - 1) * 20)
		row.gmTreeRow = true
		W.HoverTint(row)
		row.text = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.text:SetPoint("LEFT", 2, 0)
		row.text:SetWidth(168)
		row.text:SetJustifyH("LEFT")
		row:SetScript("OnClick", function(self)
			-- a drop resolving on this row shouldn't also select it —
			-- ui.drag is still set when the release's OnClick fires
			if ui.drag
				or (ui.lastDrop and GetTime() - ui.lastDrop < 0.3) then
				return
			end
			DiscardDrafts()
			ui.editPath = self.path
			GU.Refresh()
		end)
		row:SetScript("OnMouseDown", function(self, btn)
			if btn == "LeftButton" and self.path then
				if self.path == "Base Group" then
					Footer("Base Group can't be moved", true)
					return
				end
				local x, y = GetCursorPosition()
				ui.pending = { kind = "group", path = self.path,
					icon = "Interface\\Icons\\INV_Misc_Gift_02",
					x = x, y = y }
			end
		end)
		row:SetScript("OnEnter", function(self)
			if not self.path then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.path)
			GameTooltip:AddLine("drag to nest · drop items to assign",
				0.7, 0.7, 0.65, true)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		-- drop an item on a group name → assign it there
		row:SetScript("OnReceiveDrag", function(self)
			local ty, id = GetCursorInfo()
			if ty == "item" and id and self.path then
				GM.Groups.Assign(id, GM.Groups.Ensure(self.path))
				ClearCursor()
				GU.Refresh()
			end
		end)
		ui.treeRows[i] = row
	end
	ui.newBox = EditBox(treeP, 172)
	ui.newBox:SetPoint("BOTTOMLEFT", 6, 30)
	ui.newBox:SetText("new group path…")
	ui.newBox:SetTextColor(GM.RGB("textDim"))
	ui.newBox:SetScript("OnEditFocusGained", function(self)
		if self:GetText() == "new group path…" then
			self:SetText("")
			self:SetTextColor(GM.RGB("text"))
		end
	end)
	local addG = Btn(treeP, "+", 18, 18)
	addG:SetPoint("BOTTOMLEFT", 6, 8)
	addG:SetScript("OnClick", function()
		local v = strtrim(ui.newBox:GetText() or "")
		if v == "" or v == "new group path…" then return end
		local leaf = GM.Groups.Ensure(v)
		ui.editPath = leaf
		ui.newBox:SetText("")
		GU.Refresh()
	end)
	local renG = Btn(treeP, "REN", 38, 18)
	renG:SetPoint("LEFT", addG, "RIGHT", 4, 0)
	renG:SetScript("OnClick", function()
		local v = strtrim(ui.newBox:GetText() or "")
		if v == "" or v == "new group path…" or not ui.editPath then return end
		GM.Groups.Rename(ui.editPath, v)
		ui.editPath = v
		ui.newBox:SetText("")
		GU.Refresh()
	end)
	local delG = Btn(treeP, "DEL", 38, 18)
	delG:SetPoint("LEFT", renG, "RIGHT", 4, 0)
	delG:SetScript("OnClick", function(self)
		if not ui.editPath or ui.editPath == "Base Group" then return end
		if not ui.delArm then
			ui.delArm = true
			self.text:SetText("SURE?")
			return
		end
		ui.delArm = nil
		self.text:SetText("DEL")
		GM.Groups.Delete(ui.editPath)
		ui.editPath = "Base Group"
		GU.Refresh()
	end)
	Tip(delG, function() return { "Delete group",
		"Removes the group + subgroups; items become ungrouped",
		"Click twice to confirm" } end)

	-- col B: members of selected group — also a drop target
	local memP, memT, memRows = ListPanel(items, 194, 320, "ITEMS IN GROUP",
		function(_, d)
			ui.memOff = math.max(0, ui.memOff - d * 2)
			GU.RefreshMembers()
		end)
	ui.memPanel, ui.memTitle, ui.memRows = memP, memT, memRows
	memP:SetScript("OnReceiveDrag", function()
		local ty, id = GetCursorInfo()
		if ty == "item" and id then
			GM.Groups.Assign(id, GM.Groups.Ensure(editPath()))
			ClearCursor()
			GU.Refresh()
		end
	end)
	ui.memHint = GM.MakeFontString(memP, GM.FONT, 8, "secondary")
	ui.memHint:SetPoint("BOTTOMLEFT", 8, 4)
	ui.memHint:SetText("drop items here · x removes")

	-- col C: catalogue — search + click to assign
	local catP, catT, catRows = ListPanel(items, 522, 320, "CATALOGUE",
		function(_, d)
			ui.catOff = math.max(0, ui.catOff - d * 2)
			GU.RefreshCatalogue(true)
		end)
	ui.catPanel, ui.catTitle, ui.catRows = catP, catT, catRows
	ui.search = EditBox(catP, 200)
	ui.search:SetPoint("TOPLEFT", 8, -2)
	ui.search:SetHeight(16)
	ui.search:SetScript("OnTextChanged", function(self, user)
		if user then
			self.dirty = true
			ui.catDirty = true
			ui.catOff = 0
			GU.RefreshCatalogue()
		end
	end)
	catT:SetPoint("TOPLEFT", 214, -8)
	ui.catHint = GM.MakeFontString(catP, GM.FONT, 8, "secondary")
	ui.catHint:SetPoint("BOTTOMLEFT", 8, 4)
	ui.catHint:SetText("click adds to selected group")
	-- OWNED toggle: bags-only view vs the full DB catalogue
	local own = CreateFrame("Button", nil, catP)
	own:SetSize(54, 14)
	own:SetPoint("BOTTOMRIGHT", -6, 4)
	own.bg = own:CreateTexture(nil, "BACKGROUND")
	own.bg:SetAllPoints()
	own.text = GM.MakeFontString(own, GM.FONT_BOLD, 9, "textDim")
	own.text:SetPoint("CENTER")
	own.text:SetText("OWNED")
	ui.ownBtn = own
	local function PaintOwn()
		own.bg:SetColorTexture(GM.RGB(ui.ownedOnly and "accentDark" or "contHigh"))
		own.text:SetTextColor(GM.RGB(ui.ownedOnly and "accent" or "textDim"))
	end
	PaintOwn()
	own:SetScript("OnClick", function()
		ui.ownedOnly = not ui.ownedOnly
		ui.catDirty = true
		ui.catOff = 0
		PaintOwn()
		GU.RefreshCatalogue()
	end)

	-- ============ drag & drop ============
	-- Pending → armed after a few px of movement so clicks still work;
	-- release resolves the drop target by hit-testing the pane under the
	-- cursor. Items: drop on tree row/member pane = assign, catalogue =
	-- unassign. Groups: drop on tree row = re-nest, catalogue = flatten.
	local proxy = CreateFrame("Frame", nil, f)
	proxy:SetSize(18, 18)
	proxy:SetFrameStrata("TOOLTIP")
	proxy:EnableMouse(false)
	proxy.tex = proxy:CreateTexture(nil, "ARTWORK")
	proxy.tex:SetAllPoints()
	proxy:Hide()

	-- Hit-test the panes geometrically — the client's focus API is gone
	-- (neither GetMouseFocus nor GetMouseFoci exists), but IsMouseOver
	-- is a bounds check and works regardless. Tree rows first: they sit
	-- inside the tree panel, so test the more specific target first.
	-- "treeroot" = the tree panel's empty space; groups dropped there
	-- (or anywhere off a specific row) flatten to top level.
	local function DropTarget()
		for _, row in ipairs(ui.treeRows) do
			if row:IsShown() and row.path and row:IsMouseOver() then
				return "tree", row
			end
		end
		if ui.treePanel:IsMouseOver() then return "treeroot" end
		if ui.memPanel:IsMouseOver() then return "members" end
		if ui.catPanel:IsMouseOver() then return "catalogue" end
	end

	local function ResolveDrop(d)
		local kind, t = DropTarget()
		if not kind then
			Footer("drop missed — no pane under cursor", true)
			return
		end
		local msg, isErr
		if d.kind == "item" then
			if kind == "tree" then
				GM.Groups.Assign(d.id, GM.Groups.Ensure(t.path))
				msg = RowName(d.id) .. " → " .. t.path
			elseif kind == "members" then
				GM.Groups.Assign(d.id, GM.Groups.Ensure(editPath()))
				msg = RowName(d.id) .. " → " .. editPath()
			elseif kind == "catalogue" or kind == "treeroot" then
				GM.Groups.Unassign(d.id)
				msg = RowName(d.id) .. " ungrouped"
			end
			ui.catDirty = true
		elseif d.kind == "group" then
			if kind == "tree" then
				local new, err = GM.Groups.Nest(d.path, t.path)
				msg, isErr = new and (d.path .. " → " .. new) or err, not new
				if new then ui.editPath = new end
			elseif kind ~= "tree" then
				-- anywhere that isn't a specific group row = move to
				-- top level (TSM's "drop on empty space un-nests")
				local new, err = GM.Groups.Nest(d.path, nil)
				msg, isErr = new and (d.path .. " → " .. new) or err, not new
				if new then ui.editPath = new end
			end
		end
		-- Refresh resets the footer to the default — message must land last
		GU.Refresh()
		if msg then Footer(msg, isErr) end
	end

	ui.dragWatch = CreateFrame("Frame", nil, f)
	ui.dragWatch:SetScript("OnUpdate", function()
		local d = ui.pending
		if d then
			local x, y = GetCursorPosition()
			if math.abs(x - d.x) > 6 or math.abs(y - d.y) > 6 then
				ui.drag = d
				ui.pending = nil
				proxy.tex:SetTexture(d.icon
					or "Interface\\Icons\\INV_Misc_QuestionMark")
				proxy:Show()
				Footer(d.kind == "group"
					and ("dragging " .. d.path
						.. " — drop on a group to nest, catalogue to flatten")
					or ("dragging " .. RowName(d.id)
						.. " — drop on a group, member pane, or catalogue"))
			elseif not IsMouseButtonDown(1) then
				ui.pending = nil
			end
			return
		end
		d = ui.drag
		if not d then return end
		if IsMouseButtonDown(1) then
			local x, y = GetCursorPosition()
			local s = UIParent:GetEffectiveScale()
			proxy:ClearAllPoints()
			proxy:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
				x / s, y / s)
			return
		end
		proxy:Hide()
		ui.drag = nil
		ui.lastDrop = GetTime()
		ResolveDrop(d)
	end)

	-- ============ import / export ============
	local function ShowXfer(mode)
		local d = ui.xfer
		if not d then
			d = CreateFrame("Frame", "GoblinMindXfer", UIParent)
			d:SetSize(560, 420)
			d:SetPoint("CENTER", 0, 40)
			d:SetFrameStrata("FULLSCREEN_DIALOG")
			d:SetToplevel(true)
			d:EnableMouse(true)
			GM.Panel(d, "contLow", "outline")
			d.title = GM.MakeFontString(d, GM.FONT_BOLD, 12, "accent")
			d.title:SetPoint("TOPLEFT", 12, -10)
			local close = CreateFrame("Button", nil, d)
			close:SetSize(16, 16)
			close:SetPoint("TOPRIGHT", -6, -6)
			close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
			close.text:SetPoint("CENTER")
			close.text:SetText("x")
			close:SetScript("OnClick", function() d:Hide() end)
			local scroll = CreateFrame("ScrollFrame", nil, d)
			scroll:SetPoint("TOPLEFT", 10, -30)
			scroll:SetPoint("BOTTOMRIGHT", -10, 40)
			local eb = CreateFrame("EditBox", nil, scroll)
			eb:SetMultiLine(true)
			eb:SetAutoFocus(false)
			eb:SetFont(GM.FONT, 10, "")
			eb:SetTextColor(GM.RGB("text"))
			eb:SetTextInsets(4, 4, 4, 4)
			eb:SetWidth(524)
			eb:SetHeight(340)
			scroll:SetScrollChild(eb)
			d.eb = eb
			d.status = GM.MakeFontString(d, GM.FONT, 9, "secondary")
			d.status:SetPoint("BOTTOMLEFT", 12, 12)
			d.ok = Btn(d, "IMPORT", 90, 20)
			d.ok:SetPoint("BOTTOMRIGHT", -10, 8)
			ui.xfer = d
		end
		d.eb:SetText("")
		d.status:SetText(mode == "import"
			and "paste a TSM export, group: list, or item ids — then IMPORT"
			or "Ctrl+A, Ctrl+C — format is TSM-compatible")
		d.title:SetText(mode == "import" and "IMPORT GROUPS"
			or "EXPORT GROUPS")
		d.ok.text:SetText(mode == "import" and "IMPORT" or "CLOSE")
		d.ok:SetScript("OnClick", function()
			if mode == "export" then d:Hide() return end
			local ok, n = GM.Groups.Import(d.eb:GetText())
			if ok then
				d.status:SetText("imported " .. n .. " items")
				d:Hide()
				ui.catDirty = true
				GU.Refresh()
			else
				d.status:SetText(n or "import failed")
			end
		end)
		if mode == "export" then
			d.eb:SetText(GM.Groups.ExportString())
			d.eb:HighlightText()
		end
		d:Show()
		if mode == "export" then d.eb:SetFocus() d.eb:HighlightText() end
	end

	local impG = Btn(treeP, "IMP", 38, 18)
	impG:SetPoint("LEFT", delG, "RIGHT", 4, 0)
	impG:SetScript("OnClick", function() ShowXfer("import") end)
	Tip(impG, function() return { "Import groups",
		"TSM exports, group: lists, or bare item ids",
		"paste → IMPORT" } end)
	local expG = Btn(treeP, "EXP", 38, 18)
	expG:SetPoint("LEFT", impG, "RIGHT", 4, 0)
	expG:SetScript("OnClick", function() ShowXfer("export") end)
	Tip(expG, function() return { "Export groups",
		"TSM-compatible format — paste straight into TSM",
		"Base Group items export ungrouped" } end)

	-- ============ OPS page ============
	local ops = CreateFrame("Frame", nil, f)
	ops:SetPoint("TOPLEFT", 10, -34)
	ops:SetPoint("BOTTOMRIGHT", -10, 30)
	ui.pageOps = ops
	ui.opsHeader = GM.MakeFontString(ops, GM.FONT, 9, "secondary")
	ui.opsHeader:SetPoint("TOPLEFT", 6, -6)

	ui.opRows = {}
	local OPS_COL_X = { 6, 286, 566 }
	local OPS_COL_W, OPS_Y0, OPS_PITCH = 270, -26, 19
	for i, fd in ipairs(OP_FIELDS) do
		local col = i <= 10 and 1 or i <= 20 and 2 or 3
		local rowN = col == 1 and i or col == 2 and i - 10 or i - 20
		local host = CreateFrame("Frame", nil, ops)
		host:SetSize(OPS_COL_W, ROW_H)
		host:SetPoint("TOPLEFT", OPS_COL_X[col], OPS_Y0 - (rowN - 1) * OPS_PITCH)
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
			if RawLocal(editPath(), fd[2], fd[3]) == nil then return end
			groupOps(editPath(), fd[2])[fd[3]] = nil
			GU.Refresh()
			Footer(fd[1] .. " → inherit")
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

	-- async names resolve → repaint the visible rows only. Rebuilding
	-- the list here would re-request every uncached name and re-sort
	-- 7k rows on every resolve burst (the flicker/lag loop).
	if GM.OnItemInfoLoaded then
		GM.OnItemInfoLoaded(function()
			if ui and ui.frame:IsShown() and ui.page == "items" then
				GU.RefreshMembers()
				GU.RefreshCatalogue(true)
			end
		end)
	end
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

-- ============ refresh: tree ============

local function TreeList()
	local out, paths = {}, {}
	for _, g in ipairs(GM.Groups.List()) do
		paths[g.path] = true
		-- display depth: Base Group is the root row; every other
		-- top-level group renders one level in (TSM's tree shape)
		local depth = g.path == "Base Group" and 1
			or select(2, g.path:gsub("/", "")) + 2
		out[#out + 1] = { path = g.path, n = g.n, depth = depth,
			leaf = g.path:match("[^/]+$") or g.path }
	end
	for _, e in ipairs(out) do
		for p in pairs(paths) do
			-- Base Group parents everything; others need path-prefix kids
			if (e.path == "Base Group" and p ~= "Base Group")
				or p:sub(1, #e.path + 1) == e.path .. "/" then
				e.kids = true
				break
			end
		end
	end
	return out
end

-- depth ramp: parents bright, deeper levels progressively dimmer —
-- the indentation + fade is what makes nesting readable at a glance
local TREE_DEPTH_COLOR = { "text", "text", "textDim", "secondary" }

function GU.RefreshTree()
	local groups = TreeList()
	local maxOff = math.max(0, #groups - TREE_ROWS)
	if ui.treeOff > maxOff then ui.treeOff = maxOff end
	W.ScrollText(ui.treePanel.count, ui.treeOff, TREE_ROWS, #groups)
	for i, row in ipairs(ui.treeRows) do
		local g = groups[i + ui.treeOff]
		if g then
			row:Show()
			row.path = g.path
			local marker = g.depth > 1
				and (GM.CC("secondary") .. "· |r") or ""
			row.text:SetText(strrep("    ", g.depth - 1) .. marker
				.. (g.kids and (GM.CC("secondary") .. "▾ |r") or "")
				.. g.leaf
				.. GM.CC("secondary") .. "  " .. g.n .. "|r")
			row.text:SetTextColor(GM.RGB(
				g.path == ui.editPath and "accent"
					or TREE_DEPTH_COLOR[min(g.depth, #TREE_DEPTH_COLOR)]))
		else
			row:Hide()
		end
	end
end

-- ============ refresh: members ============

-- cached-name lookups. The client item cache evicts under pressure,
-- which let rows flicker back to "item N" after resolving — so every
-- resolved name is pinned into ui.nameCache and never degrades again.
-- CatName never requests a load (the catalogue iterates every DB
-- item — RequestLoad-per-miss would loop forever); RowName may, for
-- the ~15 visible rows.
local CachedInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local function CatName(id)
	local c = ui and ui.nameCache
	local n = c and c[id]
	if not n then
		n = CachedInfo and CachedInfo(id)
		if n and c then c[id] = n end
	end
	return n or ("item " .. id)
end

RowName = function(id)
	local c = ui and ui.nameCache
	local n = c and c[id]
	if not n then
		n = GM.ItemName(id) -- requests load; repaint lands it in cache
		if n and c then c[id] = n end
	end
	return n or ("item " .. id)
end

local function MemberList()
	local ids = {}
	for id in GM.Groups.IterateItems(editPath()) do ids[#ids + 1] = id end
	sort(ids, function(a, b) return CatName(a) < CatName(b) end)
	return ids
end

function GU.RefreshMembers()
	local ids = MemberList()
	ui.memTitle:SetText(format("ITEMS IN %s (%d)", editPath(), #ids))
	local maxOff = math.max(0, #ids - LIST_ROWS)
	if ui.memOff > maxOff then ui.memOff = maxOff end
	W.ScrollText(ui.memPanel.count, ui.memOff, LIST_ROWS, #ids)
	for i, row in ipairs(ui.memRows) do
		local id = ids[i + ui.memOff]
		if id then
			row:Show()
			local e = GM.ItemEntry(id)
			local own = GM.Inventory.Count and GM.Inventory.Count(id).total or 0
			FillItemRow(row, id,
				(e and e.p) and GM.Money(e.p) or "",
				own > 0 and ("own " .. own) or "")
			row.x:Show()
			row.x:SetScript("OnClick", function()
				GM.Groups.Unassign(id)
				ui.catDirty = true
				GU.Refresh()
			end)
			row:SetScript("OnClick", nil)
		else
			row:Hide()
		end
	end
end

-- ============ refresh: catalogue ============

local function CatList()
	if ui.catList and not ui.catDirty then return ui.catList end
	local q = strtrim((ui.search and ui.search:GetText() or "")):lower()
	if q == "new group path…" then q = "" end
	local owned = ui.ownedOnly and GM.BagItems() or nil
	local out = {}
	if GoblinMindDB and GoblinMindDB.items then
		for id in pairs(GoblinMindDB.items) do
			if not owned or owned[id] then
				local grp = GM.Groups.GroupForItem(id)
				local name = CatName(id)
				if q == "" or name:lower():find(q, 1, true)
					or tostring(id):find(q, 1, true) then
					out[#out + 1] = { id = id, name = name, grp = grp }
				end
			end
		end
	end
	sort(out, function(a, b)
		if (a.grp ~= nil) ~= (b.grp ~= nil) then return a.grp == nil end
		return a.name < b.name
	end)
	ui.catList = out
	ui.catDirty = nil
	return out
end

function GU.RefreshCatalogue(skipRebuild)
	local list = skipRebuild and ui.catList or CatList()
	if not list then return end
	local ungrouped = 0
	for _, e in ipairs(list) do if not e.grp then ungrouped = ungrouped + 1 end end
	ui.catTitle:SetText(format("(%d shown · %d ungrouped)",
		#list, ungrouped))
	local maxOff = math.max(0, #list - LIST_ROWS)
	if ui.catOff > maxOff then ui.catOff = maxOff end
	W.ScrollText(ui.catPanel.count, ui.catOff, LIST_ROWS, #list)
	for i, row in ipairs(ui.catRows) do
		local e = list[i + ui.catOff]
		if e then
			row:Show()
			local ent = GM.ItemEntry(e.id)
			FillItemRow(row, e.id,
				(ent and ent.p) and GM.Money(ent.p) or "",
				e.grp and ("· " .. e.grp) or "")
			row.x:Hide()
			row.name:SetTextColor(GM.RGB(e.grp and "textDim" or "text"))
			row:SetScript("OnClick", function()
				if ui.drag
					or (ui.lastDrop and GetTime() - ui.lastDrop < 0.3) then
					return
				end
				GM.Groups.Assign(e.id, GM.Groups.Ensure(editPath()))
				ui.catDirty = true
				GU.Refresh()
			end)
		else
			row:Hide()
		end
	end
end

-- ============ refresh: ops ============

local function RefreshOps()
	ui.opsHeader:SetText("OPS — " .. editPath())
	local showPath = editPath()
	for _, r in ipairs(ui.opRows) do
		local fd = r.def
		local localV = RawLocal(showPath, fd[2], fd[3])
		local owned = localV ~= nil
		local eff = GM.Groups.GetOpsForPath(showPath, fd[2])[fd[3]]
		r.effective = eff

		r.io.text:SetText(owned and "O" or "I")
		r.io.text:SetTextColor(GM.RGB(owned and "accent" or "textDim"))

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
end

-- ============ refresh orchestrator ============

function GU.Refresh()
	if not ui then return end
	ui.pageItems:SetShown(ui.page == "items")
	ui.pageOps:SetShown(ui.page == "ops")
	for _, b in ipairs(ui.pageSegs) do
		b.text:SetTextColor(GM.RGB(b.key == ui.page and "accent" or "textDim"))
		GM.Panel(b, b.key == ui.page and "contHighest" or "contHigh")
	end
	ui.editPath = ui.editPath or "Base Group"
	GU.RefreshTree()
	if ui.page == "items" then
		GU.RefreshMembers()
		GU.RefreshCatalogue()
	else
		RefreshOps()
	end
	ui.footer:SetText(FOOTER_DEFAULT)
end

function GU.Retarget()
	if ui then DiscardDrafts() ui.editPath = nil end
	GU.Refresh()
end

function GU.Show()
	BuildUI()
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

