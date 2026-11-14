local _, GM = ...
local W = GM.Widgets

-- Operations manager (/goblin ops). TSM-parity named-operation editor:
-- ops are shared objects (GM.Groups.operations[opType][name]) assigned
-- to groups via g.opNames; a group's anonymous ops table still wins at
-- its own cascade level. Left = op types · middle = ops of the type +
-- create/dup/del · right = typed field editor + group assignment.

GM.OpsUI = {}
local OU = GM.OpsUI
local ui

local EXPR_SOURCES = { "dbmarket", "vendorsell", "crafting", "matprice",
	"dbminbuyout", "dbhistorical", "dbregionmarketavg" }

-- ============ widget helpers (compact copies from GroupsUI) ============

local ROW_H = 18

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
		OU.Refresh()
	end)
	eb:SetScript("OnTextChanged", function(self, user)
		if user then
			self.dirty = true
			self.mark:SetColorTexture(GM.RGB("accent"))
		end
	end)
	return eb
end

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

-- ============ selection state ============

local function SelType() return ui.selType or "auctioning" end
local function SelName() return ui.selName end

local function CurOp()
	local n = SelName()
	return n and GM.Groups.OpFields(SelType(), n)
end

-- ============ field commits ============

local function CommitField(f, value)
	local op = CurOp()
	if not op then return end
	op[f[3]] = value
end

local function CommitText(eb)
	local f = eb.field
	local v = strtrim(eb:GetText() or "")
	if not CurOp() then eb:ClearFocus() return end
	if v == "" then
		CommitField(f, nil)
		eb.dirty = nil
		SetMark(eb)
		eb:ClearFocus()
		OU.Refresh()
		Footer(f[1] .. " → default")
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
		CommitField(f, n)
	elseif f[4] == "expr" then
		local _, err = GM.Pricing.Eval(v, nil)
		if err then
			SetMark(eb, "err")
			Footer(f[1] .. ": " .. err, true)
			return
		end
		CommitField(f, v)
	else
		CommitField(f, v)
	end
	eb.dirty = nil
	SetMark(eb, "ok")
	eb:ClearFocus()
	OU.Refresh()
end

local function CommitDiscrete(f, value)
	CommitField(f, value)
	OU.Refresh()
end

-- ============ menus ============

-- generic dropdown: rows of {label, checked, cb}; anchored under btn
local function PopupMenu(btn, entries)
	if ui.menu and ui.menu:IsShown() and ui.menu.btn == btn then
		ui.menu:Hide() ui.catcher:Hide() return
	end
	local m = ui.menu
	if not m then
		local catcher = CreateFrame("Button", nil, ui.frame)
		catcher:SetAllPoints(UIParent)
		catcher:SetFrameLevel(ui.frame:GetFrameLevel() + 19)
		catcher:SetScript("OnClick", function()
			ui.menu:Hide() catcher:Hide()
		end)
		m = CreateFrame("Frame", nil, ui.frame)
		m:SetFrameLevel(ui.frame:GetFrameLevel() + 20)
		GM.Panel(m, "contLow", "outline")
		ui.menu, ui.catcher = m, catcher
	end
	for _, b in ipairs(m.btns or {}) do b:Hide() end
	m.btns = m.btns or {}
	local w = 180
	for i, e in ipairs(entries) do
		local b = m.btns[i]
		if not b then
			b = CreateFrame("Button", nil, m)
			b:SetHeight(18)
			b.text = GM.MakeFontString(b, GM.FONT, 10, "text")
			b.text:SetPoint("LEFT", 6, 0)
			b.text:SetJustifyH("LEFT")
			local hov = b:CreateTexture(nil, "ARTWORK")
			hov:SetAllPoints()
			hov:SetColorTexture(GM.RGB("contHigh"))
			hov:Hide()
			b:SetScript("OnEnter", function() hov:Show() end)
			b:SetScript("OnLeave", function() hov:Hide() end)
			m.btns[i] = b
		end
		b:SetWidth(w)
		b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
		b.text:SetText(e.label)
		b.text:SetTextColor(GM.RGB(e.checked and "accent" or "text"))
		b:SetScript("OnClick", function()
			ui.menu:Hide() ui.catcher:Hide()
			e.cb()
		end)
		b:Show()
	end
	m:SetSize(w + 4, 4 + #entries * 18)
	m:ClearAllPoints()
	m:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
	m.btn = btn
	m:Show()
	ui.catcher:Show()
end

-- ============ window ============

local WIN_W, WIN_H = 860, 560
local TYPE_ROWS, OP_ROWS = 9, 18

local function Panel(parent, x, w, title)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOPLEFT", x, -34)
	p:SetPoint("BOTTOM", -0, 30)
	p:SetWidth(w)
	GM.Panel(p, "contLowest")
	p:SetClipsChildren(true)
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	p.titleFs = t
	return p
end

local function ListRow(parent, w)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(w, ROW_H)
	GM.Panel(r, "contLowest")
	W.HoverTint(r)
	r.text = GM.MakeFontString(r, GM.FONT, 10, "text")
	r.text:SetPoint("LEFT", 6, 0)
	r.text:SetJustifyH("LEFT")
	r.sub = GM.MakeFontString(r, GM.FONT_MED, 8, "textDim")
	r.sub:SetPoint("RIGHT", -6, 0)
	return r
end

local function BuildUI()
	if ui then return end
	ui = {}
	local f = CreateFrame("Frame", "GoblinMindOps", UIParent)
	f:SetSize(WIN_W, WIN_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:EnableMouse(true)
	f:Hide()
	tinsert(UISpecialFrames, "GoblinMindOps")
	GM.Panel(f, "contLow", "outlineVar")
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 12, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("OPERATIONS")
	GM.Dashboard.AddTabs(f, title, "ops")

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -8, -8)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 10, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- left: op types
	local typeP = Panel(f, 10, 140, "TYPE")
	ui.typeRows = {}
	for i, ot in ipairs(GM.Groups.OP_TYPES) do
		local r = ListRow(typeP, 124)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		r.text:SetText(ot)
		r.key = ot
		r:SetScript("OnClick", function()
			ui.selType = ot
			ui.selName = nil
			OU.Refresh()
		end)
		ui.typeRows[i] = r
	end

	-- middle: named ops of the selected type
	local opP = Panel(f, 156, 200, "OPERATIONS")
	ui.opPanel = opP
	ui.opRows = {}
	for i = 1, OP_ROWS do
		local r = ListRow(opP, 184)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		r:Hide()
		ui.opRows[i] = r
	end

	local newEb = EditBox(opP, 130)
	newEb:SetPoint("BOTTOMLEFT", 8, 8)
	newEb:SetText("new operation…")
	newEb:SetTextColor(GM.RGB("textDim"))
	newEb:SetScript("OnEditFocusGained", function()
		if newEb:GetText() == "new operation…" then
			newEb:SetText("")
			newEb:SetTextColor(GM.RGB("text"))
		end
	end)
	local newBtn = Btn(opP, "+", 24)
	newBtn:SetPoint("LEFT", newEb, "RIGHT", 4, 0)
	newBtn:SetScript("OnClick", function()
		local name = newEb:GetText()
		if name == "new operation…" then name = "" end
		local ok, err = GM.Groups.CreateOp(SelType(), name)
		if ok then
			ui.selName = strtrim(name)
			newEb:SetText("new operation…")
			newEb:SetTextColor(GM.RGB("textDim"))
			newEb:ClearFocus()
			OU.Refresh()
			Footer("created " .. ui.selName)
		else
			OU.Refresh()
			Footer(err, true)
		end
	end)

	-- right: fields for the selected op
	local fldP = Panel(f, 362, WIN_W - 372, "FIELDS")
	ui.fldPanel = fldP
	ui.fldHeader = GM.MakeFontString(fldP, GM.FONT_BOLD, 10, "accent")
	ui.fldHeader:SetPoint("TOPLEFT", 8, -20)
	ui.assignedFs = GM.MakeFontString(fldP, GM.FONT, 9, "secondary")
	ui.assignedFs:SetPoint("TOPLEFT", ui.fldHeader, "BOTTOMLEFT", 0, -4)
	ui.assignedFs:SetWidth(330)
	ui.assignedFs:SetJustifyH("LEFT")

	local assignBtn = Btn(fldP, "ASSIGN", 54, 16)
	assignBtn:SetPoint("TOPRIGHT", -8, -20)
	assignBtn.text:SetFont(GM.FONT_BOLD, 9, "")
	assignBtn:SetScript("OnClick", function(self)
		if not CurOp() then return end
		local entries = {}
		for _, g in ipairs(GM.Groups.List()) do
			local path = g.path
			entries[#entries + 1] = {
				label = path,
				checked = GM.Groups.OpAssigned(path, SelType()) == SelName(),
				cb = function()
					local cur = GM.Groups.OpAssigned(path, SelType())
					GM.Groups.AssignOp(path, SelType(),
						cur == SelName() and nil or SelName())
					OU.Refresh()
				end,
			}
		end
		PopupMenu(self, entries)
	end)
	Tip(assignBtn, function()
		return { "Assign to groups",
			"Toggles the group list — one op per type per group" }
	end)
	ui.assignBtn = assignBtn

	-- field rows: built lazily per type on first paint
	ui.fieldRows = {}
	ui.fieldHost = fldP

	-- op actions: rename / duplicate / delete under the fields panel
	local renEb = EditBox(fldP, 150)
	renEb:SetPoint("BOTTOMLEFT", 8, 8)
	ui.renEb = renEb
	renEb:SetScript("OnEnterPressed", function(self)
		local new = strtrim(self:GetText() or "")
		local ok, err = GM.Groups.RenameOp(SelType(), SelName(), new)
		if ok then ui.selName = new end
		OU.Refresh()
		Footer(ok and ("renamed → " .. new) or err, not ok and true or nil)
		self:ClearFocus()
	end)
	local dupBtn = Btn(fldP, "DUP", 44)
	dupBtn:SetPoint("LEFT", renEb, "RIGHT", 6, 0)
	dupBtn:SetScript("OnClick", function()
		local ok, new = GM.Groups.DuplicateOp(SelType(), SelName())
		if ok then ui.selName = new end
		OU.Refresh()
		Footer(ok and ("duplicated → " .. new) or (new or "no op selected"),
			not ok and true or nil)
	end)
	local delBtn = Btn(fldP, "DEL", 44)
	delBtn:SetPoint("LEFT", dupBtn, "RIGHT", 6, 0)
	delBtn.text:SetTextColor(GM.RGB("err"))
	delBtn:SetScript("OnClick", function(self)
		if not self.armed then
			self.armed = true
			self.text:SetText("?")
			return
		end
		local name = SelName()
		local ok, err = GM.Groups.DeleteOp(SelType(), name)
		self.armed = nil
		ui.selName = nil
		OU.Refresh()
		if ok then Footer("deleted " .. name) else Footer(err, true) end
	end)
	Tip(delBtn, function()
		return { "Delete operation",
			"Two clicks — groups using it fall back to inherited values" }
	end)
	ui.renEb, ui.delBtn = renEb, delBtn

	ui.footer = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	ui.footer:SetPoint("BOTTOMLEFT", 10, 8)
	ui.footer:SetText("named ops are shared — assign via ASSIGN or the group's op slot")

	-- scroll for the field host (ops have ≤9 fields — fixed layout ok)
end

-- ============ field rows ============

local VAL_X, VAL_W, LABEL_W = 120, 140, 110

local function BuildFieldRow(fldP, fd, idx)
	local host = CreateFrame("Frame", nil, fldP)
	host:SetSize(fldP:GetWidth() - 16, ROW_H)
	host:SetPoint("TOPLEFT", 8, -52 - (idx - 1) * (ROW_H + 3))
	local row = { def = fd, host = host }

	row.lab = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	row.lab:SetSize(LABEL_W, ROW_H)
	row.lab:SetPoint("TOPLEFT", 0, 0)
	row.lab:SetText(fd[1])
	row.lab:SetJustifyH("LEFT")
	if fd[6] and fd[6].tip then
		local lb = CreateFrame("Button", nil, host)
		lb:SetSize(LABEL_W, ROW_H)
		lb:SetPoint("TOPLEFT", 0, 0)
		Tip(lb, function() return { fd[1], fd[6].tip } end)
	end

	local w = fd[5]
	if w == "bool" then
		row.on  = Segment(host, "On", 68);  row.on:SetPoint("TOPLEFT", VAL_X, 0)
		row.off = Segment(host, "Off", 68); row.off:SetPoint("TOPLEFT", VAL_X + 70, 0)
		row.on:SetScript("OnClick", function() CommitDiscrete(fd, true) end)
		row.off:SetScript("OnClick", function() CommitDiscrete(fd, false) end)
	elseif w == "seg" then
		row.segs = {}
		local widths = #fd[6].opts == 3 and { 45, 45, 46 } or { 68, 68 }
		local x = VAL_X
		for i, opt in ipairs(fd[6].opts) do
			local b = Segment(host, opt[1], widths[i])
			b:SetPoint("TOPLEFT", x, 0)
			b:SetScript("OnClick", function() CommitDiscrete(fd, opt[2]) end)
			b.optValue = opt[2]
			row.segs[i] = b
			x = x + widths[i] + 2
		end
	elseif w == "stepper" then
		row.minus = Segment(host, "-", 18); row.minus:SetPoint("TOPLEFT", VAL_X, 0)
		row.plus  = Segment(host, "+", 18); row.plus:SetPoint("TOPLEFT", VAL_X + VAL_W - 18, 0)
		row.eb = EditBox(host, VAL_W - 40, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X + 20, 0)
		row.minus:SetScript("OnClick", function()
			local cur = tonumber(row.eb:GetText()) or 0
			CommitDiscrete(fd, math.max((fd[6] and fd[6].min) or 0, cur - 1))
		end)
		row.plus:SetScript("OnClick", function()
			local cur = tonumber(row.eb:GetText()) or 0
			CommitDiscrete(fd, cur + 1)
		end)
	elseif w == "num" then
		row.eb = EditBox(host, VAL_W, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X, 0)
	elseif w == "expr" then
		row.eb = EditBox(host, VAL_W - 22, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X, 0)
		row.aux = Segment(host, "v", 18)
		row.aux:SetPoint("TOPLEFT", VAL_X + VAL_W - 20, 0)
		row.aux:SetScript("OnClick", function(self)
			local entries = {}
			for _, src in ipairs(EXPR_SOURCES) do
				entries[#entries + 1] = { label = "100% " .. src, cb = function()
					row.eb:SetText("100% " .. src)
					row.eb.dirty = true
					SetMark(row.eb, "dirty")
					row.eb:SetFocus()
				end }
			end
			PopupMenu(self, entries)
		end)
		Tip(row.aux, function()
			return { "Insert a price source",
				"Replaces the draft — press Enter to save" }
		end)
	elseif w == "recip" then
		row.eb = EditBox(host, VAL_W - 22, ROW_H)
		row.eb:SetPoint("TOPLEFT", VAL_X, 0)
		row.aux = Segment(host, "T", 18)
		row.aux:SetPoint("TOPLEFT", VAL_X + VAL_W - 20, 0)
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
		row.eb.field = fd
		row.eb:SetScript("OnEnterPressed", function(self) CommitText(self) end)
	end
	return row
end

local function RefreshFields()
	-- hide all existing rows, build/refresh rows for the selected type
	for _, r in ipairs(ui.fieldRows) do r.host:Hide() end
	local op = CurOp()
	local n = SelName()
	local prot = op and GM.Groups.OpProtected(n)
	ui.fldHeader:SetText(n and ("FIELDS — " .. n
		.. (prot and "  (protected)" or "")) or "FIELDS — select an op")
	ui.renEb:SetShown(op and not prot)
	ui.delBtn:SetShown(op and not prot)
	ui.assignBtn:SetShown(op ~= nil)
	ui.assignedFs:SetShown(op ~= nil)
	if not op then return end
	if not ui.renEb:HasFocus() then ui.renEb:SetText(n) end

	-- assignment summary
	local users
	for _, o in ipairs(GM.Groups.Ops(SelType())) do
		if o.name == n then users = o.groups end
	end
	ui.assignedFs:SetText("assigned to: " .. (users or "—"))

	-- rows for this type's fields
	local defs = {}
	for _, fd in ipairs(GM.Groups.OP_FIELDS) do
		if fd[2] == SelType() then defs[#defs + 1] = fd end
	end
	local idx = 0
	for _, fd in ipairs(defs) do
		idx = idx + 1
		local r = ui.fieldRows[idx]
		if not r or r.def ~= fd then
			if r then r.host:Hide() end
			r = BuildFieldRow(ui.fldPanel, fd, idx)
			ui.fieldRows[idx] = r
		end
		r.host:Show()
		local eff = op[fd[3]]
		if eff == nil then
			local d = GM.Groups.OP_DEFAULTS[fd[2]]
			eff = d and d[fd[3]]
		end
		r.effRaw = op[fd[3]]
		if not (r.eb and r.eb.dirty) then
			if r.eb then r.eb:SetText(eff == nil and "" or tostring(eff)) end
		end
		if r.eb then
			r.eb:SetTextColor(GM.RGB(r.effRaw ~= nil and "text" or "textDim"))
		end
		if fd[5] == "bool" then
			PaintSeg(r.on, eff == true)
			PaintSeg(r.off, eff == false)
		elseif fd[5] == "seg" then
			for _, b in ipairs(r.segs) do PaintSeg(b, eff == b.optValue) end
		end
	end
end

-- ============ refresh ============

function OU.Refresh()
	if not ui then return end
	for _, r in ipairs(ui.typeRows) do
		local sel = r.key == SelType()
		r._gmBg:SetColorTexture(GM.RGB(sel and "contHighest" or "contLowest"))
		r.text:SetTextColor(GM.RGB(sel and "accent" or "text"))
	end
	-- default selection: first op of the type
	local ops = GM.Groups.Ops(SelType())
	if not ui.selName and ops[1] then ui.selName = ops[1].name end
	if ui.selName and not GM.Groups.OpFields(SelType(), ui.selName) then
		ui.selName = ops[1] and ops[1].name or nil
	end
	for i, r in ipairs(ui.opRows) do
		local o = ops[i]
		if o then
			r:Show()
			local sel = o.name == ui.selName
			r._gmBg:SetColorTexture(GM.RGB(sel and "contHighest" or "contLowest"))
			r.text:SetText(o.name)
			r.text:SetTextColor(GM.RGB(sel and "accent" or "text"))
			r.sub:SetText((o.users > 0
				and (o.users .. (o.users == 1 and " grp" or " grps")) or "")
				.. (GM.Groups.OpProtected(o.name) and " ·" or ""))
			local name = o.name
			r:SetScript("OnClick", function()
				ui.selName = name
				OU.Refresh()
			end)
		else
			r:Hide()
		end
	end
	ui.delBtn.armed = nil
	ui.delBtn.text:SetText("DEL")
	RefreshFields()
end

function OU.Show()
	BuildUI()
	ui.frame:Show()
	OU.Refresh()
end

function OU.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function OU.Toggle()
	BuildUI()
	if ui.frame:IsShown() then ui.frame:Hide() else OU.Show() end
end
