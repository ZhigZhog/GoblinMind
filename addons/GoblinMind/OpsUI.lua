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
	return W.DirtyEditBox(parent, w, h, OU.Refresh)
end

local Segment = W.Segment
local PaintSeg = W.PaintSeg

local Btn = W.ActionBtn

local Tip = W.Tip

local SetMark = W.SetMark

local function Footer(msg, err) W.Footer(ui.footer, msg, err) end

-- ============ selection state ============

local function SelType() return ui.selType or "auctioning" end
local function SelName() return ui.selName end

local function CurOp()
	local n = SelName()
	return n and GM.Groups.OpFields(SelType(), n)
end

-- ============ field commits ============

-- commit target is two-scoped: named-op mode writes the shared op,
-- group mode writes the group's local override (cascade layer)
local function CommitField(f, value)
	if ui.groupMode then
		if ui.selGroup then
			GM.Groups.OpSetLocal(ui.selGroup, SelType(), f[3], value)
		end
		return
	end
	local op = CurOp()
	if not op then return end
	op[f[3]] = value
end

local function CommitText(eb)
	local f = eb.field
	local v = strtrim(eb:GetText() or "")
	if not ui.groupMode and not CurOp() then eb:ClearFocus() return end
	if v == "" then
		CommitField(f, nil)
		eb.dirty = nil
		SetMark(eb)
		eb:ClearFocus()
		OU.Refresh()
		Footer(f[1] .. (ui.groupMode and " → inherit" or " → default"))
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
	m.btns = m.btns or {}
	local w = 220
	-- unbounded lists blow off the screen (a 194-group import); cap
	-- the window and mousewheel-page through the rest
	local MAX_ROWS = 14
	local vis = math.min(#entries, MAX_ROWS)
	m.off = 0
	local function Paint()
		for _, b in ipairs(m.btns) do b:Hide() end
		for i = 1, vis do
			local e = entries[m.off + i]
			if not e then break end
			local b = m.btns[i]
			if not b then
				b = CreateFrame("Button", nil, m)
				b:SetHeight(18)
				b.text = GM.MakeFontString(b, GM.FONT, 10, "text")
				b.text:SetPoint("LEFT", 6, 0)
				b.text:SetWidth(w - 12)
				b.text:SetWordWrap(false)
				-- RIGHT justify: long paths clip the shared PREFIX
				-- and keep the leaf that tells them apart
				b.text:SetJustifyH("RIGHT")
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
	end
	m:EnableMouseWheel(true)
	m:SetScript("OnMouseWheel", function(_, d)
		m.off = math.min(math.max(0, #entries - vis),
			math.max(0, m.off - d))
		Paint()
	end)
	Paint()
	m:SetSize(w + 4, 4 + vis * 18)
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
	return W.ColPanel(parent, x, w, title, -34)
end

local function ListRow(parent, w, textW)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(w, ROW_H)
	GM.Panel(r, "contLowest")
	W.HoverTint(r)
	r.text = GM.MakeFontString(r, GM.FONT, 10, "text")
	r.text:SetPoint("LEFT", 6, 0)
	r.text:SetJustifyH("LEFT")
	r.sub = GM.MakeFontString(r, GM.FONT_MED, 8, "textDim")
	r.sub:SetPoint("RIGHT", -6, 0)
	r.sub:SetWidth(70)
	r.sub:SetJustifyH("RIGHT")
	r.sub:SetWordWrap(false)
	r.text:SetWidth(textW or (w - 10))
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	return r
end

local function BuildUI()
	if ui then return end
	ui = {}
	local f = GM.Widgets.Window({
		name = "GoblinMindOps", title = "OPERATIONS",
		w = WIN_W, h = WIN_H, tab = "ops",
	})
	ui.frame = f

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

	-- middle: named ops of the selected type. Row 1 is a pinned
	-- pseudo-entry that swaps the fields pane to the per-group
	-- override editor (the merged GROUPS-tab ops surface)
	local opP = Panel(f, 156, 200, "OPERATIONS")
	ui.opPanel = opP
	ui.groupRow = ListRow(opP, 184, 104)
	ui.groupRow:SetPoint("TOPLEFT", 8, -24)
	ui.groupRow.text:SetText("‹group overrides›")
	ui.groupRow:SetScript("OnClick", function()
		ui.groupMode = true
		ui.selGroup = ui.selGroup or "Base Group"
		OU.Refresh()
	end)
	ui.opRows = {}
	for i = 1, OP_ROWS - 1 do
		local r = ListRow(opP, 184, 104)
		r:SetPoint("TOPLEFT", 8, -24 - i * (ROW_H + 2))
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
	ui.fldHeader:SetWidth(300)
	ui.fldHeader:SetJustifyH("LEFT")
	ui.fldHeader:SetWordWrap(false)
	ui.assignedFs:SetWidth(330)
	ui.assignedFs:SetJustifyH("LEFT")
	ui.assignedFs:SetMaxLines(2) -- imported ops can have 100+ users;
	-- uncapped it grew down over every field row

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

	-- group mode's picker fills the ASSIGN slot: which group's local
	-- overrides the fields pane is editing
	ui.grpBtn = Btn(fldP, "GROUP ▾", 76, 16)
	ui.grpBtn:SetPoint("TOPRIGHT", -8, -20)
	ui.grpBtn.text:SetFont(GM.FONT_BOLD, 9, "")
	ui.grpBtn:SetScript("OnClick", function(self)
		local entries = {}
		for _, g in ipairs(GM.Groups.List()) do
			local path = g.path
			entries[#entries + 1] = {
				label = path,
				checked = ui.selGroup == path,
				cb = function() ui.selGroup = path OU.Refresh() end,
			}
		end
		PopupMenu(self, entries)
	end)
	ui.grpBtn:Hide()

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
	ui.footer:SetWidth(520)
	ui.footer:SetJustifyH("LEFT")
	ui.footer:SetWordWrap(false)
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

	-- I/O chip rides the value column's left edge — group mode only:
	-- O = local override (click clears back to inherited), I = the
	-- resolved value comes from the cascade (tooltip names the source)
	row.io = CreateFrame("Button", nil, host)
	row.io:SetSize(16, ROW_H)
	row.io:SetPoint("TOPLEFT", VAL_X - 18, 0)
	GM.Panel(row.io, "contLowest", "outlineVar")
	row.io.text = GM.MakeFontString(row.io, GM.FONT_BOLD, 9, "textDim")
	row.io.text:SetPoint("CENTER")
	row.io:Hide()
	row.io:SetScript("OnClick", function()
		if not (ui.groupMode and ui.selGroup) then return end
		if GM.Groups.OpRawLocal(ui.selGroup, fd[2], fd[3]) == nil then return end
		GM.Groups.OpSetLocal(ui.selGroup, fd[2], fd[3], nil)
		OU.Refresh()
		Footer(fd[1] .. " → inherit")
	end)
	Tip(row.io, function()
		if not (ui.groupMode and ui.selGroup) then return nil end
		local p = ui.selGroup
		if GM.Groups.OpRawLocal(p, fd[2], fd[3]) == nil then
			local _, src = GM.Groups.OpResolve(p, fd[2], fd[3])
			return { "Inherited from " .. tostring(src),
				"Edit the value to override on " .. p }
		end
		local rv, src = GM.Groups.OpResolve(p, fd[2], fd[3], true)
		return { "Local override on " .. p,
			"Click to remove — inherits " .. tostring(rv)
				.. " from " .. tostring(src) }
	end)

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
	local groupMode = ui.groupMode and ui.selGroup
	ui.grpBtn:SetShown(groupMode and true or false)

	if groupMode then
		ui.fldHeader:SetText("FIELDS — " .. ui.selGroup)
		ui.assignedFs:SetText(
			"local overrides — I = inherited · O = local (click to reset)")
		ui.assignedFs:Show()
		ui.renEb:Hide() ui.delBtn:Hide() ui.assignBtn:Hide()
	else
		local prot = op and GM.Groups.OpProtected(n)
		ui.fldHeader:SetText(n and ("FIELDS — " .. n
			.. (prot and "  (protected)" or "")) or "FIELDS — select an op")
		ui.renEb:SetShown(op and not prot)
		ui.delBtn:SetShown(op and not prot)
		ui.assignBtn:SetShown(op ~= nil)
		ui.assignedFs:SetShown(op ~= nil)
		if not op then return end
		if not ui.renEb:HasFocus() then ui.renEb:SetText(n) end

		-- assignment summary — count + a bounded preview, not the full
		-- path dump (a 194-group TSM import overflows the whole panel)
		local paths
		for _, o in ipairs(GM.Groups.Ops(SelType())) do
			if o.name == n then paths = o.userPaths end
		end
		if paths and #paths > 0 then
			local prev = {}
			for i = 1, math.min(#paths, 3) do prev[i] = paths[i] end
			ui.assignedFs:SetText(format(
				"assigned to %d group%s — %s%s", #paths,
				#paths == 1 and "" or "s", table.concat(prev, ", "),
				#paths > 3 and (", +" .. (#paths - 3) .. " more") or ""))
		else
			ui.assignedFs:SetText("assigned to: —")
		end
	end

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
		local eff, owned
		if groupMode then
			eff = GM.Groups.OpResolve(ui.selGroup, fd[2], fd[3])
			r.effRaw = GM.Groups.OpRawLocal(ui.selGroup, fd[2], fd[3])
			owned = r.effRaw ~= nil
			r.io:Show()
			r.io.text:SetText(owned and "O" or "I")
			r.io.text:SetTextColor(GM.RGB(owned and "accent" or "textDim"))
		else
			eff = op[fd[3]]
			if eff == nil then
				local d = GM.Groups.OP_DEFAULTS[fd[2]]
				eff = d and d[fd[3]]
			end
			r.effRaw = op[fd[3]]
			owned = r.effRaw ~= nil
			r.io:Hide()
		end
		if not (r.eb and r.eb.dirty) then
			if r.eb then r.eb:SetText(eff == nil and "" or tostring(eff)) end
		end
		if r.eb then
			r.eb:SetTextColor(GM.RGB(owned and "text" or "textDim"))
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
	-- the pinned pseudo-row reads selected while group mode is up
	ui.groupRow._gmBg:SetColorTexture(GM.RGB(
		ui.groupMode and "contHighest" or "contLowest"))
	ui.groupRow.text:SetTextColor(GM.RGB(
		ui.groupMode and "accent" or "textDim"))
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
			local sel = o.name == ui.selName and not ui.groupMode
			r._gmBg:SetColorTexture(GM.RGB(sel and "contHighest" or "contLowest"))
			r.text:SetText(o.name)
			r.text:SetTextColor(GM.RGB(sel and "accent" or "text"))
			r.sub:SetText((o.users > 0
				and (o.users .. (o.users == 1 and " grp" or " grps")) or "")
				.. (GM.Groups.OpProtected(o.name) and " ·" or ""))
			local name = o.name
			r:SetScript("OnClick", function()
				ui.selName = name
				ui.groupMode = nil -- picking a named op leaves group mode
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

-- deep-link from the GROUPS page: jump straight into a group's
-- local-override editor for one op type (the merged ops surface)
function OU.OpenGroup(path, opType)
	BuildUI()
	ui.selType = opType or ui.selType or "auctioning"
	ui.groupMode = true
	ui.selGroup = path or "Base Group"
	GM.Dashboard.Switch("ops")
end
