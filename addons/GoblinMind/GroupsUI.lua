local _, GM = ...
local W = GM.Widgets

-- Groups window (/goblin groups). ITEMS page = group tree · members ·
-- searchable catalogue; OPS page = a per-type SUMMARY (which named op
-- applies, how many local overrides) that deep-links into the main
-- OPS tab — OpsUI is the one field editor now (the cascade helpers
-- live on GM.Groups: OpResolve/OpRawLocal/OpSetLocal/OpForPath).

GM.GroupsUI = {}
local GU = GM.GroupsUI
local ui

local function editPath()
	return ui.editPath or "Base Group"
end

-- ============ widget helpers ============

local function EditBox(parent, w, h)
	return W.DirtyEditBox(parent, w, h, GU.Refresh)
end

local Btn = W.ActionBtn
local Tip = W.Tip

local function Footer(msg, err) W.Footer(ui.footer, msg, err) end

local FOOTER_DEFAULT = "drag items to assign · Enter saves · Esc discards"

-- ============ window ============
-- TSM-parity groups page: ITEMS page = group tree · members ·
-- searchable catalogue (click assigns to the selected group, drop
-- items anywhere to add); OPS page = the typed operation editor.

local WIN_W, WIN_H = 860, 640
local TREE_ROWS, LIST_ROWS = 22, 20

-- placeholder text the compare sites need identical — one localized
-- constant, not five driftable literals
local NEWG_LBL = (GM.L or function(s) return s end)("new group path…")

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

-- item row: the shared W.ItemRow (icon, rarity name, tooltip,
-- modified clicks) + this panel's sub-line, right text, remove
-- button, and drag-to-move pickup
local function ItemRow(parent, w)
	local row = W.ItemRow(parent, { h = 22, w = w, icon = 16,
		auto = false })
	-- two-line variant: name moves up, sub sits under it; the
	-- widget's free right slot carries the dim right text
	row.name:ClearAllPoints()
	row.name:SetPoint("TOPLEFT", 22, -3)
	row.name:SetPoint("RIGHT", row.vel, "LEFT", -8, 0)
	row.sub = GM.MakeFontString(row, GM.FONT, 8, "secondary")
	row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
	row.sub:SetPoint("RIGHT", row.vel, "LEFT", -8, 0)
	row.sub:SetJustifyH("LEFT")
	-- right text lives in the vel slot — shift it clear of the x
	row.vel:ClearAllPoints()
	row.vel:SetPoint("RIGHT", -18, 0)
	row.x = CreateFrame("Button", nil, row)
	row.x:SetSize(14, 14)
	row.x:SetPoint("RIGHT", -2, 0)
	row.x.text = GM.MakeFontString(row.x, GM.FONT_BOLD, 9, "textDim")
	row.x.text:SetPoint("CENTER")
	row.x.text:SetText("x")
	row:SetScript("OnMouseDown", function(self, btn)
		if btn == "LeftButton" and self.id
			and not IsModifiedClick() then
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
	row:SetItem({ id = id, name = id and RowName(id) or nil })
	row.sub:SetText(sub or "")
	row.vel:SetText(right or "")
end

local function BuildUI()
	if ui then return end
	ui = { catOff = 0, memOff = 0, treeOff = 0, page = "items",
		nameCache = {}, collapsed = {} }
	local f = GM.Widgets.Window({
		name = "GoblinMindGroupsUI", title = "GROUPS",
		w = WIN_W, h = WIN_H, x = -40, y = 20, level = 100,
		tab = "groups",
		onHide = function() ui.pending, ui.drag = nil, nil end,
	})
	ui.frame = f

	-- page segments: ITEMS | OPS
	ui.pageSegs = {}
	for i, p in ipairs({ { "ITEMS", "items" }, { "OPS", "ops" } }) do
		local b = CreateFrame("Button", nil, f)
		b:SetSize(50, 18)
		b:SetPoint("TOPRIGHT", -30 - (2 - i) * 54, -8)
		GM.Panel(b, "contHigh")
		b.text = GM.MakeFontString(b, GM.FONT_MED, 9, "textDim")
		b.text:SetPoint("CENTER")
		b.text:SetWidth(130)
		b.text:SetWordWrap(false)
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
		-- real expander (was a decorative ▼ in the row text — it
		-- collapsed nothing and its clicks fell through to the
		-- move-drag handler → "Base Group can't be moved")
		row.collapse = CreateFrame("Button", nil, row)
		row.collapse:SetSize(14, 18)
		row.collapse:SetPoint("LEFT", 0, 0)
		row.collapse:SetFrameLevel(row:GetFrameLevel() + 1)
		row.collapse.text = GM.MakeFontString(row.collapse, GM.FONT,
			10, "secondary")
		row.collapse.text:SetPoint("CENTER", 0, 0)
		row.collapse:SetScript("OnClick", function(self)
			local p = self:GetParent().path
			if not p then return end
			ui.collapsed[p] = not ui.collapsed[p] or nil
			GU.RefreshTree()
		end)
		row.collapse:Hide()
		row.text = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.text:SetPoint("LEFT", 2, 0)
		row.text:SetWidth(168)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row:SetScript("OnClick", function(self)
			-- a drop resolving on this row shouldn't also select it —
			-- ui.drag is still set when the release's OnClick fires
			if ui.drag
				or (ui.lastDrop and GetTime() - ui.lastDrop < 0.3) then
				return
			end
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
			GM.Widgets.HintShow(self, {
				self.path,
				"drag to nest · drop items to assign",
			})
		end)
		row:SetScript("OnLeave", GM.Widgets.HintHide)
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
	ui.newBox:SetText(NEWG_LBL)
	ui.newBox:SetTextColor(GM.RGB("textDim"))
	ui.newBox:SetScript("OnEditFocusGained", function(self)
		if self:GetText() == NEWG_LBL then
			self:SetText("")
			self:SetTextColor(GM.RGB("text"))
		end
	end)
	local addG = Btn(treeP, "+", 18, 18)
	addG:SetPoint("BOTTOMLEFT", 6, 8)
	addG:SetScript("OnClick", function()
		local v = strtrim(ui.newBox:GetText() or "")
		if v == "" or v == NEWG_LBL then return end
		local leaf = GM.Groups.Ensure(v)
		ui.editPath = leaf
		ui.newBox:SetText("")
		GU.Refresh()
	end)
	local renG = Btn(treeP, "REN", 28, 18)
	renG:SetPoint("LEFT", addG, "RIGHT", 2, 0)
	renG:SetScript("OnClick", function()
		local v = strtrim(ui.newBox:GetText() or "")
		if v == "" or v == NEWG_LBL or not ui.editPath then return end
		GM.Groups.Rename(ui.editPath, v)
		ui.editPath = v
		ui.newBox:SetText("")
		GU.Refresh()
	end)
	local delG = Btn(treeP, "DEL", 28, 18)
	delG:SetPoint("LEFT", renG, "RIGHT", 2, 0)
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
	local protG = Btn(treeP, "PROT", 32, 18)
	protG:SetPoint("LEFT", delG, "RIGHT", 2, 0)
	protG:SetScript("OnClick", function()
		if not ui.editPath then return end
		local g = GM.Groups.db.groups[ui.editPath]
		if not g then return end
		GM.Groups.SetProtected(ui.editPath, not g.protected)
		GU.RefreshTree()
	end)
	Tip(protG, function() return { "Protect group",
		"Items in this group (or a subgroup) are excluded",
		"from post scans — things that shouldn't be on the",
		"AH. A manual sell/post step still asks once." } end)
	ui.protBtn = protG

	-- col B: members of selected group — also a drop target
	local memP, memT, memRows = ListPanel(items, 194, 320, "ITEMS IN GROUP",
		function(_, d)
			ui.memOff = math.max(0, ui.memOff - d * 2)
			GU.RefreshMembers()
		end)
	ui.memPanel, ui.memTitle, ui.memRows = memP, memT, memRows
	memT:SetWidth(200) -- clip before it can reach the TOPRIGHT count
	memT:SetWordWrap(false)
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
	-- header row is a search row: the count owns TOPRIGHT and the
	-- shown/ungrouped stats live on the bottom hint line — a title
	-- string here collides with both
	catT:SetText("")
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
	ui.catHint = GM.MakeFontString(catP, GM.FONT, 8, "secondary")
	ui.catHint:SetPoint("BOTTOMLEFT", 8, 4)
	ui.catHint:SetText("click adds to selected group")
	-- OWNED toggle: bags-only view vs the full DB catalogue
	local own = CreateFrame("Button", nil, catP)
	own:SetSize(54, 14)
	own:SetPoint("BOTTOMRIGHT", -6, 4)
	ui.catHint:SetWidth(220)
	ui.catHint:SetJustifyH("LEFT")
	ui.catHint:SetWordWrap(false)
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
			d.status:SetWidth(200)
			d.status:SetJustifyH("LEFT")
			d.status:SetWordWrap(false)
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

	local impG = Btn(treeP, "IMP", 28, 18)
	impG:SetPoint("LEFT", protG, "RIGHT", 2, 0)
	impG:SetScript("OnClick", function() ShowXfer("import") end)
	Tip(impG, function() return { "Import groups",
		"TSM exports, group: lists, or bare item ids",
		"paste → IMPORT" } end)
	local expG = Btn(treeP, "EXP", 28, 18)
	expG:SetPoint("LEFT", impG, "RIGHT", 2, 0)
	expG:SetScript("OnClick", function() ShowXfer("export") end)
	Tip(expG, function() return { "Export groups",
		"TSM-compatible format — paste straight into TSM",
		"Base Group items export ungrouped" } end)

	-- ============ OPS page ============
	-- per-type summary + deep-link into the unified OpsUI editor —
	-- no second field grid (the one editor lives in the OPS tab)
	local ops = CreateFrame("Frame", nil, f)
	ops:SetPoint("TOPLEFT", 10, -34)
	ops:SetPoint("BOTTOMRIGHT", -10, 30)
	ui.pageOps = ops
	ui.opsHeader = GM.MakeFontString(ops, GM.FONT, 9, "secondary")
	ui.opsHeader:SetPoint("TOPLEFT", 6, -6)
	ui.opsHeader:SetWidth(700)
	ui.opsHeader:SetWordWrap(false)

	ui.opRows = {}
	for i, opType in ipairs(GM.Groups.OP_TYPES) do
		local row = CreateFrame("Frame", nil, ops)
		row:SetSize(560, 22)
		row:SetPoint("TOPLEFT", 6, -30 - (i - 1) * 26)
		GM.Panel(row, "contLowest")
		row.opType = opType

		row.lab = GM.MakeFontString(row, GM.FONT_BOLD, 10, "textDim")
		row.lab:SetPoint("LEFT", 8, 0)
		row.lab:SetWidth(96)
		row.lab:SetJustifyH("LEFT")
		row.lab:SetText(opType)

		row.op = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.op:SetPoint("LEFT", 110, 0)
		row.op:SetWidth(180)
		row.op:SetJustifyH("LEFT")
		row.op:SetWordWrap(false)

		row.sub = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.sub:SetPoint("LEFT", 296, 0)
		row.sub:SetWidth(190)
		row.sub:SetJustifyH("LEFT")
		row.sub:SetWordWrap(false)

		row.edit = Btn(row, "EDIT", 44, 16)
		row.edit:SetPoint("RIGHT", -6, 0)
		row.edit:SetScript("OnClick", function()
			GM.OpsUI.OpenGroup(editPath(), opType)
		end)
		Tip(row.edit, function()
			return { "Edit in the OPS tab",
				"Named ops + " .. editPath() .. "'s local overrides" }
		end)
		ui.opRows[i] = row
	end

	ui.footer = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	ui.footer:SetPoint("BOTTOMLEFT", 10, 8)
	ui.footer:SetText(FOOTER_DEFAULT)

	-- ============ GoblinUI managed layout ============
	-- the window was three hand-anchored layers: page segs TOPRIGHT,
	-- the two page surfaces spanning -34..30, footer BOTTOMLEFT.
	-- Same three layers in a column: segs right-packed in the header
	-- row, page hosts as fill nodes (SetVisible collapses the hidden
	-- page out of layout — no fill-split with its sibling), footer
	-- pins the bottom edge. Pane innards keep their anchors.
	local u = GM.ui
	if u then
		local root = u:AttachRoot(f, { direction = "column", gap = 4,
			pad = { top = 6, left = 10, right = 10, bottom = 8 } })
		local head = u:Row(root, { gap = 4, justify = "end" })
		root:Add(head, { width = "fill", height = 18 })
		for _, b in ipairs(ui.pageSegs) do
			head:Add(u:Adopt(b), { width = 50, height = 18 })
		end
		ui.itemsNode = u:Adopt(items)
		root:Add(ui.itemsNode, { width = "fill", height = "fill" })
		ui.opsNode = u:Adopt(ops)
		root:Add(ui.opsNode, { width = "fill", height = "fill" })
		root:Add(u:Adopt(ui.footer), { width = "fill", height = 12 })
	end

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

-- ============ refresh: tree ============

local function TreeList()
	-- flat path sort renders children ABOVE their parent whenever
	-- the parent's name sorts later ("Adventuring Supplies" over
	-- "Base Group") — the tree needs depth-first order: each parent
	-- immediately followed by its alphabetically-sorted subtree
	local counts = {}
	for _, g in ipairs(GM.Groups.List()) do counts[g.path] = g.n end
	local all = GM.Groups.db.groups
	local kidsOf = {}
	for path in pairs(all) do
		local parent = path:match("^(.*)/[^/]+$") or "Base Group"
		if parent ~= path then
			kidsOf[parent] = kidsOf[parent] or {}
			tinsert(kidsOf[parent], path)
		end
	end
	for _, arr in pairs(kidsOf) do table.sort(arr) end
	local out, seen = {}, {}
	local function Visit(path, depth)
		if seen[path] or not all[path] then return end
		seen[path] = true
		out[#out + 1] = { path = path, n = counts[path] or 0,
			depth = depth, leaf = path:match("[^/]+$") or path,
			kids = kidsOf[path] ~= nil }
		for _, c in ipairs(kidsOf[path] or {}) do
			Visit(c, depth + 1)
		end
	end
	Visit("Base Group", 1)
	-- orphan paths (a parent deleted out from under them) surface
	-- as root rows rather than vanishing from the tree entirely
	for _, g in ipairs(GM.Groups.List()) do
		if not seen[g.path] then Visit(g.path, 1) end
	end
	-- collapsed ancestor hides the whole subtree; Base Group's own
	-- row always survives (it's the root even when shut)
	local collapsed = ui and ui.collapsed or {}
	for i = #out, 1, -1 do
		local p = out[i].path
		local hide = p ~= "Base Group" and collapsed["Base Group"]
		local j = p:find("/", 1, true)
		while j and not hide do
			hide = collapsed[p:sub(1, j - 1)] or false
			j = p:find("/", j + 1, true)
		end
		if hide then tremove(out, i) end
	end
	return out
end

-- depth ramp: parents bright, deeper levels progressively dimmer —
-- the indentation + fade is what makes nesting readable at a glance
local TREE_DEPTH_COLOR = { "text", "text", "textDim", "secondary" }

function GU.RefreshTree()
	-- PROT toggle mirrors the selected group's protected flag —
	-- accent when the subtree shields its items from sell/post
	if ui.protBtn then
		local g = ui.editPath and GM.Groups.db.groups[ui.editPath]
		local on = g and g.protected
		ui.protBtn.text:SetText(on and "ON" or "PROT")
		ui.protBtn.text:SetTextColor(GM.RGB(on and "accent" or "textDim"))
	end
	local groups = TreeList()
	local maxOff = math.max(0, #groups - TREE_ROWS)
	if ui.treeOff > maxOff then ui.treeOff = maxOff end
	W.ScrollText(ui.treePanel.count, ui.treeOff, TREE_ROWS, #groups)
	for i, row in ipairs(ui.treeRows) do
		local g = groups[i + ui.treeOff]
		if g then
			row:Show()
			row.path = g.path
			local indent = (g.depth - 1) * 14
			row.collapse:ClearAllPoints()
			row.collapse:SetPoint("LEFT", indent, 0)
			row.collapse:SetShown(g.kids and true or false)
			row.collapse.text:SetText(
				ui.collapsed[g.path] and "▶" or "▼")
			row.text:ClearAllPoints()
			row.text:SetPoint("LEFT", indent + 14, 0)
			local marker = g.depth > 1
				and (GM.CC("secondary") .. "· |r") or ""
			row.text:SetText(marker .. g.leaf
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
	local ids, path, explicit = {}, editPath(), {}
	for id in GM.Groups.IterateItems(path) do
		ids[#ids + 1] = id
		explicit[id] = true
	end
	-- Base Group holds every ungrouped item implicitly (TSM root
	-- semantics): shown here but NOT written to the SV — moving one
	-- out means assigning it somewhere via the catalogue, not unassign
	if path == "Base Group" then
		for _, id in ipairs(GM.Groups.UngroupedIds()) do
			if not explicit[id] then ids[#ids + 1] = id end
		end
	end
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
			-- Base Group members are the ungrouped set — an x there
			-- can't remove them, so it's hidden; catalogue click is
			-- the move path
			local implicit = editPath() == "Base Group"
				and not GM.Groups.GroupForItem(id)
			if implicit then
				row.x:Hide()
			else
				row.x:Show()
				row.x:SetScript("OnClick", function()
					GM.Groups.Unassign(id)
					ui.catDirty = true
					GU.Refresh()
				end)
			end
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
	if q == NEWG_LBL then q = "" end
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
	ui.catHint:SetText(format("%d shown · %d ungrouped · click adds",
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
			row.name:SetTextColor(GM.NameColor(
				not e.grp and e.id, "textDim"))
			row:SetScript("OnClick", function()
				if ui.drag
					or (ui.lastDrop and GetTime() - ui.lastDrop < 0.3) then
					return
				end
				-- modified click already handled by FillItemRow's
				-- ModifiedClick hook on mousedown — just swallow the
				-- assign click
				if IsModifiedClick() then return end
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
	local p = editPath()
	ui.opsHeader:SetText("OPS — " .. p
		.. "  ·  EDIT opens this group's overrides in the OPS tab")
	for _, r in ipairs(ui.opRows) do
		local t = r.opType
		local own = GM.Groups.OpAssigned(p, t)
		local name = GM.Groups.OpForPath(p, t)
		local n = GM.Groups.OpLocalCount(p, t)
		r.op:SetText(name or "—")
		r.op:SetTextColor(GM.RGB(own and "accent" or "textDim"))
		local sub = n > 0
			and (n .. " local override" .. (n ~= 1 and "s" or "")) or "—"
		if name and not own then
			sub = sub .. " · op inherited"
		end
		r.sub:SetText(sub)
	end
end

-- ============ refresh orchestrator ============

function GU.Refresh()
	if not ui then return end
	if ui.itemsNode then
		ui.itemsNode:SetVisible(ui.page == "items")
		ui.opsNode:SetVisible(ui.page == "ops")
	else
		ui.pageItems:SetShown(ui.page == "items")
		ui.pageOps:SetShown(ui.page == "ops")
	end
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
	if ui then ui.editPath = nil end
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

