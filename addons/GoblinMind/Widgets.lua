local _, GM = ...

-- Shared widget kit — the takeover windows (VendoringUI, AHUI,
-- MailUI, BankUI, GBankUI) and DestroyingUI all grew their own
-- Btn/EditBox/Tip copies with drift. One implementation lives here.
-- Files alias locals: local Btn = GM.Widgets.Btn — keep signatures
-- identical to the old per-file helpers so call sites don't change.

GM.Widgets = {}
local W = GM.Widgets

local HL_R, HL_G, HL_B = nil

-- paneled action button: contHigh base, contHighest+text on hover
function W.Btn(parent, w, label, fn)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, 20)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(w - 8)
	b.text:SetWordWrap(false)
	b.text:SetText(label)
	b:SetScript("OnEnter", function()
		if b._gmBg then b._gmBg:SetColorTexture(GM.RGB("contHighest")) end
		b.text:SetTextColor(GM.RGB("text"))
	end)
	b:SetScript("OnLeave", function()
		if b._gmBg then b._gmBg:SetColorTexture(GM.RGB("contHigh")) end
		b.text:SetTextColor(GM.RGB("textDim"))
	end)
	b:SetScript("OnClick", fn)
	return b
end

-- editbox with hint placeholder, bordered
function W.EditBox(parent, w, hint)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, 18)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(6, 4, 0, 0)
	GM.Panel(eb, "contLowest")
	eb:SetText(hint or "")
	eb:SetTextColor(GM.RGB(hint and "textDim" or "text"))
	eb:SetScript("OnEditFocusGained", function()
		if hint and eb:GetText() == hint then
			eb:SetText("")
			eb:SetTextColor(GM.RGB("text"))
		end
		-- focused fields read as active: brighten the fill
		if eb._gmBg then eb._gmBg:SetColorTexture(GM.RGB("contMedium")) end
	end)
	eb:SetScript("OnEditFocusLost", function()
		if eb._gmBg then eb._gmBg:SetColorTexture(GM.RGB("contLowest")) end
	end)
	eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
	eb:SetScript("OnEnterPressed", function() eb:ClearFocus() end)
	return eb
end

-- hover tooltip: linesFn() returns {title, line, line…} or nil.
-- Renders into an owned frame, NOT GameTooltip — SetText there runs
-- the shared hook chain of every installed addon, and a foreign
-- chain looped into a C stack overflow (Questie/FDJ/EnhanceQoL all
-- hook this tooltip; the trigger was a simple Bronze Tube hint).
-- Hints are static text and don't need the engine's machinery.
local hint
local function HintTip()
	if hint then return hint end
	hint = CreateFrame("Frame", "GoblinMindHint", UIParent)
	GM.Panel(hint, "contHigh")
	hint:SetFrameStrata("TOOLTIP")
	pcall(hint.SetClampedToScreen, hint, true)
	hint.lines = {}
	hint:Hide()
	return hint
end

-- direct show/hide for sites that used to SetOwner+SetText on
-- GameTooltip (same foreign-chain exposure as W.Tip's old path)
function W.HintShow(f, lines)
	if not lines or not lines[1] then return end
	local tip = HintTip()
	local w, n = 0, math.min(#lines, 12)
	for i = 1, n do
		local fs = tip.lines[i]
		if not fs then
			fs = GM.MakeFontString(tip, GM.FONT, 10, "text")
			fs:SetPoint("TOPLEFT", 8, -7 - (i - 1) * 13)
			tip.lines[i] = fs
		end
		fs:SetText(tostring(lines[i]):sub(1, 96))
		fs:SetTextColor(i == 1 and 1 or 0.8,
			i == 1 and 1 or 0.8, i == 1 and 1 or 0.75)
		fs:Show()
		local sw = fs.GetStringWidth and fs:GetStringWidth() or 0
		if sw > w then w = sw end
	end
	for j = n + 1, #tip.lines do tip.lines[j]:Hide() end
	tip:SetSize(w + 16, 10 + n * 13)
	tip:ClearAllPoints()
	tip:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 4)
	tip:Show()
end

function W.HintHide()
	if hint then hint:Hide() end
end

function W.Tip(f, linesFn)
	-- accepts a fn returning lines, a plain string, or nil (no tip)
	if type(linesFn) == "string" then
		local s = linesFn
		linesFn = function() return { s } end
	end
	if type(linesFn) ~= "function" then return end
	f:HookScript("OnEnter", function()
		W.HintShow(f, linesFn())
	end)
	f:HookScript("OnLeave", W.HintHide)
end

-- any modified click = Blizzard's default item action (ctrl+click =
-- dress-up preview, shift+click = chat link / context transfer).
-- For rows with no own OnClick — rows that have one guard inside
-- their handler instead. idFn may be an id or fn() -> id, resolved
-- at click time.
function W.ModifiedClick(f, idFn)
	f:HookScript("OnMouseDown", function(_, btn)
		if btn ~= "LeftButton" or not IsModifiedClick() then return end
		local id = type(idFn) == "function" and idFn() or idFn
		if id then GM.ModifiedItemClick(id) end
	end)
end

-- paneled action button, larger variant (contHigh + FONT_BOLD 10
-- accent, centered). No handlers wired — callers SetScript their own
-- OnClick; CraftingUI's secure OPEN overlay needs a bare button to
-- cover. Was an identical Btn triple in CraftingUI/GroupsUI/OpsUI.
function W.ActionBtn(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h or 20)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 10, "accent")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(w - 8)
	b.text:SetWordWrap(false)
	b.text:SetText(label)
	return b
end

-- status line setter — the ui.footer pattern in the takeover windows
function W.Footer(fs, msg, err)
	fs:SetText(msg)
	fs:SetTextColor(GM.RGB(err and "err" or "secondary"))
end

-- marked editbox: 2px edge mark goes accent when the user edits
-- (eb.dirty set), Escape drops dirty + clears focus. onEscape fires
-- after ClearFocus — pass the module's Refresh so the row repaints.
-- Was an identical pair in GroupsUI/OpsUI (GroupsUI layers its own
-- OnEditFocusGained capture on top via SetScript).
function W.DirtyEditBox(parent, w, h, onEscape)
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
		if onEscape then onEscape() end
	end)
	eb:SetScript("OnTextChanged", function(self, user)
		if user then
			self.dirty = true
			self.mark:SetColorTexture(GM.RGB("accent"))
		end
	end)
	return eb
end

-- dirty-mark paint for W.DirtyEditBox: the 2px edge strip reads
-- accent while typed-dirty; callers repaint it on validate/commit.
function W.SetMark(eb, state)
	eb.mark:SetColorTexture(GM.RGB(
		state == "err" and "err" or state == "ok" and "pos"
			or state == "dirty" and "accent" or "outlineVar"))
end

-- text segment button (toggle-strip member) + selected-state paint.
-- Was an identical Segment/PaintSeg pair in GroupsUI/OpsUI.
function W.Segment(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h or 18)
	GM.Panel(b, "contLowest")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(w - 8)
	b.text:SetWordWrap(false)
	b.text:SetText(label)
	return b
end

function W.PaintSeg(b, selected)
	b._gmBg:SetColorTexture(GM.RGB(selected and "contHighest" or "contLowest"))
	b.text:SetTextColor(GM.RGB(selected and "accent" or "textDim"))
end

-- full-height column panel with title (+count fs at top right). topY
-- positions under the toolbar row — CraftingUI uses -52, OpsUI -34.
-- Was two near-identical Panel()s; p.titleFs and p.count are both set
-- so either consumer's field name resolves.
function W.ColPanel(parent, x, w, title, topY)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOPLEFT", x, topY or -52)
	p:SetPoint("BOTTOM", 0, 30)
	p:SetWidth(w)
	GM.Panel(p, "contLowest")
	p:SetClipsChildren(true)
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	p.titleFs = t
	p.count = GM.MakeFontString(p, GM.FONT, 9, "textDim")
	p.count:SetPoint("TOPRIGHT", -8, -7)
	t:SetWordWrap(false)
	return p
end

-- GOBLINMIND switch button on a Blizzard frame — the takeover
-- windows' shared "go back / come back" affordance. Was six copies
-- (AHUI/BankUI/GBankUI/MailUI/VendoringUI/CraftingUI). onClick fires
-- when the user wants OUR window back; onShow hooks the native
-- frame's show so the caller can re-park it. Returns nil if the
-- native frame doesn't exist yet.
-- a standalone framed box with a bold title — callers position it.
-- Returns (panel, titleFS) — the title fs lets callers recolor/wrap.
function W.TitledPanel(f, title)
	local p = CreateFrame("Frame", nil, f)
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetWordWrap(false)
	t:SetText(title)
	return p, t
end

function W.SwitchBtn(native, onClick, onShow)
	if not native then return nil end
	local b = CreateFrame("Button", nil, native)
	b:SetSize(84, 16)
	b:SetPoint("TOPRIGHT", native, "TOPRIGHT", -40, -8)
	b:SetFrameLevel(native:GetFrameLevel() + 20)
	GM.Panel(b, "accent")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "contLowest")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(76)
	b.text:SetWordWrap(false)
	b.text:SetText("GOBLINMIND")
	b:SetScript("OnClick", onClick)
	if onShow then native:HookScript("OnShow", onShow) end
	return b
end

-- subtle hover tint — attach at row creation; the HIGHLIGHT layer
-- draws itself, no script needed
-- create ui.switchBtn once on a native Blizzard frame: click
-- re-opens our window over it; the frame reparks itself when we
-- didn't explicitly take over (wantDefault stays nil → park).
-- Shared by every *UI module that overlays a Blizzard window —
-- the six per-file copies differed only in frame + reopen fn.
-- onPark: custom "back to default" repark (CraftingUI parks its
-- tradeskill scaffold, not the stock FramePark path).
function W.EnsureSwitchBtn(ui, frame, onOpen, onPark)
	if not (frame and ui and not ui.switchBtn) then return end
	ui.switchBtn = W.SwitchBtn(frame, function()
		ui.wantDefault = nil
		onOpen()
	end, function()
		if not ui.wantDefault then
			if onPark then onPark() else GM.FramePark.Park(frame) end
		end
	end)
end

function W.HoverTint(row)
	if not HL_R then HL_R, HL_G, HL_B = GM.RGB("contHighest") end
	row.hl = row:CreateTexture(nil, "HIGHLIGHT")
	row.hl:SetAllPoints()
	row.hl:SetColorTexture(HL_R, HL_G, HL_B, 0.35)
end

-- page toggle strip: text tabs with an accent underline under the
-- active one (reads as tabs, not action buttons). defs = {{key,label}}
-- onPick(key) fires on click. Returns {btns={key=btn}, set=fn}.
function W.PageTabs(parent, defs, onPick)
	local strip = {}
	strip.btns = {}
	local x = 0
	for _, d in ipairs(defs) do
		local key, label = d[1], d[2]
		local b = CreateFrame("Button", nil, parent)
		b:SetSize(56, 20)
		b:SetPoint("TOPLEFT", x, 0)
		b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
		b.text:SetPoint("CENTER", 0, 2)
		b.text:SetWidth(52)
		b.text:SetWordWrap(false)
		b.text:SetText(label)
		b.line = b:CreateTexture(nil, "ARTWORK")
		b.line:SetSize(44, 2)
		b.line:SetPoint("BOTTOM", 0, 1)
		b.line:SetColorTexture(GM.RGB("accent"))
		b.line:Hide()
		b:SetScript("OnEnter", function()
			if not b.active then b.text:SetTextColor(GM.RGB("text")) end
		end)
		b:SetScript("OnLeave", function()
			if not b.active then b.text:SetTextColor(GM.RGB("textDim")) end
		end)
		b:SetScript("OnClick", function() onPick(key) end)
		strip.btns[key] = b
		x = x + 62
	end
	function strip.set(key)
		for k, b in pairs(strip.btns) do
			b.active = (k == key) or nil
			b.line:SetShown(k == key)
			b.text:SetTextColor(GM.RGB(k == key and "accent" or "textDim"))
		end
	end
	return strip
end

-- scroll range readout for pane headers — "1–14 of 47" or "" when the
-- list fits. Anchor fs at the pane header's RIGHT edge.
function W.ScrollText(fs, off, visible, total)
	if not fs then return end
	off = off or 0
	if (total or 0) <= visible then
		fs:SetText("")
	else
		fs:SetText(GM.CC("textDim") ..
			string.format("%d–%d of %d", off + 1,
				math.min(off + visible, total), total) .. "|r")
	end
end

-- standard frame furniture: title + close X, shared offsets so every
-- window's chrome sits identically
function W.Chrome(f, name, titleText)
	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(titleText)
	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)
	W.Tip(close, function() return { "Close", "ESC also closes" } end)
	return title
end

-- ============ budget account controls (shared) ============
-- One row contract for every surface that lists budget accounts —
-- dashboard BUDGETS and overview ACCOUNTS both build rows through
-- W.AcctRow and paint through W.PaintAcctRow, so add/cycle/bind/
-- reset/delete behave identically on either window.

local function AcctRefresh()
	-- repaint every surface that might show this account
	if GM.PlanQueue and GM.PlanQueue.Refresh then
		GM.PlanQueue.Refresh()
	end
	if GM.Overview and GM.Overview.Refresh then
		GM.Overview.Refresh()
	end
end

-- row: name · kind cycle · group bind · alloc · remaining · reset · del
-- compact drops the alloc column so remaining keeps readable width
function W.AcctRow(parent, idx, compact)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(24)
	local nameW = compact and 88 or 104
	local grpW = compact and 100 or 120

	-- name is clickable: swaps to an inline editbox, Enter commits
	-- (B.Rename validates empty/dup), Esc cancels
	local nameBtn = CreateFrame("Button", nil, row)
	nameBtn:SetPoint("LEFT", 2, 0)
	nameBtn:SetSize(nameW, 18)
	row.name = GM.MakeFontString(nameBtn, GM.FONT, 10, "text")
	row.name:SetPoint("LEFT", 0, 0)
	row.name:SetWidth(nameW)
	row.name:SetJustifyH("LEFT")
	local eb = W.EditBox(row, nameW + 6)
	eb:SetPoint("LEFT", 0, 0)
	row.name:SetWordWrap(false)
	eb:SetHeight(18)
	eb:Hide()
	row.nameEdit = eb
	nameBtn:SetScript("OnClick", function()
		local a = GM.Budget.List()[idx]
		if not a then return end
		eb:SetText(a.name)
		eb:SetTextColor(GM.RGB("text"))
		eb:Show()
		eb:SetFocus()
		eb:HighlightText()
	end)
	W.Tip(nameBtn, function() return {
		"Rename account", "click to edit the name" } end)
	eb:SetScript("OnEnterPressed", function(self)
		GM.Budget.Rename(idx, self:GetText())
		self:Hide()
		self:ClearFocus()
		AcctRefresh()
	end)
	eb:SetScript("OnEscapePressed", function(self)
		self:Hide()
		self:ClearFocus()
	end)

	local kind = CreateFrame("Button", nil, row)
	kind:SetSize(50, 20)
	kind:SetPoint("LEFT", nameW + 6, 0)
	GM.Panel(kind, "contHigh")
	kind.text = GM.MakeFontString(kind, GM.FONT_MED, 9, "secondary")
	kind.text:SetPoint("CENTER")
	kind.text:SetWidth(46)
	kind.text:SetWordWrap(false)
	kind:SetScript("OnClick", function()
		local a = GM.Budget.List()[idx]
		if not a then return end
		local order = GM.Budget.KIND_ORDER
		for j, k in ipairs(order) do
			if k == a.kind then
				GM.Budget.SetKind(idx, order[j % #order + 1])
				break
			end
		end
		AcctRefresh()
	end)
	W.Tip(kind, function() return {
		"Account function",
		"craft: mat/craft spends · ah: auction spends",
		"save: reserve that never leaves",
		"click to cycle" } end)
	row.kind = kind

	local grp = CreateFrame("Button", nil, row)
	grp:SetSize(grpW, 20)
	grp:SetPoint("LEFT", kind, "RIGHT", 6, 0)
	GM.Panel(grp, "contMedium")
	grp.text = GM.MakeFontString(grp, GM.FONT, 9, "textDim")
	grp.text:SetPoint("LEFT", 5, 0)
	grp.text:SetPoint("RIGHT", -4, 0)
	grp.text:SetJustifyH("LEFT")
	grp.text:SetWordWrap(false)
	grp:SetScript("OnClick", function()
		local a = GM.Budget.List()[idx]
		if not a then return end
		local paths = GM.Budget.GroupPaths()
		local cur, nextPath = a.group, nil
		if not cur then
			nextPath = paths[1]
		else
			for j, p in ipairs(paths) do
				if p == cur then nextPath = paths[j + 1] break end
			end
		end
		GM.Budget.SetGroup(idx, nextPath)
		AcctRefresh()
	end)
	W.Tip(grp, function() return {
		"Group binding",
		"items in this group route their",
		"spends and sales to this account",
		"click to cycle · wraps to unbound" } end)
	row.grp = grp

	row.alloc = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.alloc:SetPoint("LEFT", grp, "RIGHT", 8, 0)
	row.alloc:SetWidth(90)
	row.alloc:SetJustifyH("LEFT")
	if compact then row.alloc:Hide() end

	row.left = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.left:SetPoint("LEFT",
		compact and grp or row.alloc, "RIGHT", 6, 0)
	row.left:SetJustifyH("LEFT")
	row.left:SetWordWrap(false)

	local del = CreateFrame("Button", nil, row)
	del:SetSize(16, 16)
	del:SetPoint("RIGHT", 0, 0)
	del.text = GM.MakeFontString(del, GM.FONT_BOLD, 10, "textDim")
	del.text:SetPoint("CENTER")
	del.text:SetText("x")
	del:SetScript("OnClick", function()
		GM.Budget.Del(idx)
		AcctRefresh()
	end)
	W.Tip(del, function() return { "Delete account" } end)
	row.del = del

	local rst = CreateFrame("Button", nil, row)
	rst:SetSize(16, 16)
	rst:SetPoint("RIGHT", del, "LEFT", -4, 0)
	rst.text = GM.MakeFontString(rst, GM.FONT_BOLD, 9, "textDim")
	rst.text:SetPoint("CENTER")
	rst.text:SetText("r")
	rst:SetScript("OnClick", function()
		GM.Budget.ResetSpent(idx)
		AcctRefresh()
	end)
	W.Tip(rst, function() return { "Reset spent to zero" } end)
	row.rst = rst

	-- 7d income/spend column: fixed-width right-justified block before
	-- the row buttons; `left` re-anchors to it so nothing overlaps
	row.flow = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.flow:SetPoint("RIGHT", rst, "LEFT", -8, 0)
	row.flow:SetWidth(140)
	row.flow:SetJustifyH("RIGHT")
	row.flow:SetWordWrap(false)

	-- left text stops before the flow column
	row.left:SetPoint("RIGHT", row.flow, "LEFT", -8, 0)
	return row
end

-- unified paint: alloc text per kind, save accounts show "reserved",
-- spend accounts show left + spent (red when overdrawn)
function W.PaintAcctRow(row, a)
	row.name:SetText(a.name)
	row.kind.text:SetText(a.pool and "POOL" or GM.Budget.KINDS[a.kind])
	row.grp.text:SetText(a.group or "—")
	row.grp.text:SetTextColor(GM.RGB(a.group and "accent" or "textDim"))
	row.alloc:SetText(GM.Budget.AllocText(a))
	local rem = GM.Budget.Remaining(a)
	if a.kind == "save" then
		row.left:SetText("reserved " .. GM.MoneyShort(rem))
		row.left:SetTextColor(GM.RGB("accent"))
	else
		row.left:SetText("left " .. GM.MoneyShort(rem)
			.. " · spent " .. GM.MoneyShort(a.spent or 0))
		row.left:SetTextColor(GM.RGB(rem > 0 and "textDim" or "err"))
	end
	local fin, fout = GM.Budget.Flow(a)
	if fin then
		row.flow:SetText(GM.CC("pos") .. "+" .. GM.MoneyShort(fin) .. "|r"
			.. GM.CC("textDim") .. " / |r"
			.. GM.CC("warn") .. "-" .. GM.MoneyShort(fout) .. "|r")
	else
		row.flow:SetText("—")
	end
end

-- add-row: name box · kind cycle · amount box · + button.
-- Returns the container; parent anchors it where it wants.
-- parse: bare number = gold for craft/ah budgets, % for saves.
function W.AcctAdd(parent)
	local f = CreateFrame("Frame", nil, parent)
	f:SetHeight(22)

	local name = W.EditBox(f, 130, "name")
	name:SetPoint("LEFT", 0, 0)

	local addKind = "craft"
	local kindBtn = CreateFrame("Button", nil, f)
	kindBtn:SetSize(56, 20)
	kindBtn:SetPoint("LEFT", name, "RIGHT", 6, 0)
	GM.Panel(kindBtn, "contHigh")
	kindBtn.text = GM.MakeFontString(kindBtn, GM.FONT_MED, 9, "secondary")
	kindBtn.text:SetPoint("CENTER")
	kindBtn.text:SetWidth(52)
	kindBtn.text:SetWordWrap(false)
	local function PaintKind()
		kindBtn.text:SetText(GM.Budget.KINDS[addKind])
	end
	PaintKind()
	kindBtn:SetScript("OnClick", function()
		local order = GM.Budget.KIND_ORDER
		for i, k in ipairs(order) do
			if k == addKind then
				addKind = order[i % #order + 1]
				break
			end
		end
		PaintKind()
	end)
	W.Tip(kindBtn, function() return {
		"New account's function", "click to cycle" } end)

	local amt = W.EditBox(f, 80, "0g")
	amt:SetPoint("LEFT", kindBtn, "RIGHT", 6, 0)

	local btn = CreateFrame("Button", nil, f)
	btn:SetSize(26, 20)
	btn:SetPoint("LEFT", amt, "RIGHT", 6, 0)
	GM.Panel(btn, "accent")
	btn.text = GM.MakeFontString(btn, GM.FONT_BOLD, 11, "contLowest")
	btn.text:SetPoint("CENTER")
	btn.text:SetText("+")

	local hint = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	hint:SetPoint("LEFT", btn, "RIGHT", 8, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("craft/ah: gold (500 or 10g50s) · save: %")

	btn:SetScript("OnClick", function()
		local n = name:GetText()
		if n == "name" then n = "" end
		local a = amt:GetText()
		local alloc = addKind == "save"
			and tonumber((a or ""):gsub("%%", ""))
			or (tonumber(a) and floor(tonumber(a) * 10000)
				or GM.Budget.ParseMoney(a))
		local acct = alloc and GM.Budget.Add(n, addKind, alloc)
		AcctRefresh()
		if acct then
			name:SetText("")
			amt:SetText(addKind == "save" and "30" or "0g")
			hint:SetText("craft/ah: gold (500 or 10g50s) · save: %")
		else
			hint:SetText(GM.CC("err")
				.. (addKind == "save" and "need a % (0-100)"
					or "bad amount — try 10g, 5s, 2500c") .. "|r")
		end
	end)
	f.hint = hint
	return f
end

-- Standard module window chrome — every window was hand-copying the
-- same block (strata/toplevel/movable/drag/clamp/panel/ESC/title/x/
-- dashboard tabs) with drift: OrdersUI/OpsUI/CraftingUI missed ESC
-- and clamping, close buttons wandered between "x"/"×" at -6/-8,
-- titles between 12/13pt at 10/12/14px. One recipe, opts for deltas:
--   name, title, w, h, x, y        -- frame basics (CENTER offset)
--   tab                            -- dashboard tab key (nil = no strip)
--   fill, border                   -- GM.Panel colors
--   strata, level                  -- layering overrides
--   onHide                         -- session-teardown hook
--   onClose                        -- fires on X click before Hide
--     (CraftingUI sets ui.closing — deliberate-close semantics)
--   noChrome                       -- frame+drag+panel+ESC only: no
--     title/close/tabs (PlanQueue's title strip is bespoke)
-- Returns frame, titleFS, closeBtn.
function W.Window(o)
	local f = CreateFrame("Frame", o.name, UIParent)
	f:SetSize(o.w or 640, o.h or 480)
	f:SetPoint("CENTER", o.x or 0, o.y or 0)
	-- "normal" window strata on this client (PlanQueue's note): HIGH +
	-- Toplevel stacks with TSM/Ellesmere panels. Toplevel's auto-raise
	-- is unreliable here, so clicks raise manually — last-clicked wins.
	f:SetFrameStrata(o.strata or "HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	if o.level then f:SetFrameLevel(o.level) end
	f:SetScript("OnMouseDown", function(fr)
		if fr.Raise then fr:Raise()
		elseif RaiseFrame then RaiseFrame(fr) end
	end)
	GM.Panel(f, o.fill or "contLow", o.border or "outlineVar")
	if o.name then tinsert(UISpecialFrames, o.name) end
	f:Hide()
	if o.onHide then f:SetScript("OnHide", o.onHide) end
	if o.noChrome then return f end

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(o.title or "")
	f.titleFs = title

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function()
		if o.onClose then o.onClose() end
		f:Hide()
	end)
	f.closeBtn = close

	if o.tab and GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, title, o.tab)
	end
	return f, title, close
end

-- Blizzard-style coin input: three digit boxes with persistent
-- g/s/c unit labels — the canonical way to enter coin values, one
-- implementation for every field (writ price, mail money, AH price
-- filters + post dialog). :GetCopper() returns copper, or nil when
-- all three boxes are empty so callers can tell "0c" from "blank".
-- :SetCopper splits a copper value back out; nil/<=0 clears.
-- Tab walks g→s→c. Sub-boxes are exposed (.g/.s/.c) for callers
-- that wire Enter/Escape handlers.
function W.GoldEdit(parent, w)
	local h = CreateFrame("Frame", nil, parent)
	w = w or 118
	h:SetSize(w, 18)
	-- gold gets the extra room (the big number); silver/copper are
	-- two-digit by construction like Blizzard's own coin fields
	local gw = math.max(34, math.floor(w * 0.42))
	local sw = math.max(20, math.floor((w - gw - 24) / 2))
	local function mk(ww, maxc)
		local e = CreateFrame("EditBox", nil, h)
		e:SetSize(ww, 18)
		e:SetAutoFocus(false)
		e:SetFont(GM.FONT, 10, "")
		e:SetTextColor(GM.RGB("text"))
		e:SetTextInsets(4, 2, 0, 0)
		e:SetMaxLetters(maxc)
		GM.Panel(e, "contLowest")
		e:SetScript("OnTextChanged", function(s)
			local t = s:GetText():gsub("%D", "")
			if t ~= s:GetText() then s:SetText(t) end
		end)
		e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
		return e
	end
	local function unit(anchor, txt, color)
		local fs = GM.MakeFontString(h, GM.FONT, 9, color)
		fs:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
		fs:SetText(txt)
		return fs
	end
	h.g = mk(gw, 7)
	h.g:SetPoint("LEFT", 0, 0)
	local lg = unit(h.g, "g", "accent")
	h.s = mk(sw, 2)
	h.s:SetPoint("LEFT", lg, "RIGHT", 4, 0)
	local ls = unit(h.s, "s", "textDim")
	h.c = mk(sw, 2)
	h.c:SetPoint("LEFT", ls, "RIGHT", 4, 0)
	unit(h.c, "c", "textDim")
	h.g:SetScript("OnTabPressed", function() h.s:SetFocus() end)
	h.s:SetScript("OnTabPressed", function() h.c:SetFocus() end)
	h.c:SetScript("OnTabPressed", function() h.c:ClearFocus() end)
	local function digits(e) return tonumber(e:GetText()) or 0 end
	function h:GetCopper()
		local t = digits(h.g) * 10000 + digits(h.s) * 100 + digits(h.c)
		if t == 0 and h.g:GetText() == "" and h.s:GetText() == ""
			and h.c:GetText() == "" then
			return nil
		end
		return t
	end
	function h:SetCopper(v)
		if not v or v <= 0 then
			h.g:SetText(""); h.s:SetText(""); h.c:SetText("")
			return
		end
		h.g:SetText(tostring(math.floor(v / 10000)))
		h.s:SetText(tostring(math.floor(v / 100) % 100))
		h.c:SetText(tostring(v % 100))
	end
	function h:SetFocus() h.g:SetFocus() end
	return h
end

-- W.ItemSlot(parent, opts) — the shared item-target strip lifted
-- from the planner header: bordered icon slot (real item tooltip
-- on hover) + name + meta sub-line, accepting drag/drop,
-- click-with-item-on-cursor, and modified-click passthrough.
-- opts: w, h, icon, hint, nameSize, subSize, onItem(id, link).
-- Fields: .icon .iconBtn .name .sub · .itemID .itemLink
-- Methods: :SetItem(id, link) paints it; :Clear() back to hint.
function W.ItemSlot(parent, opts)
	opts = opts or {}
	local h = opts.h or 56
	local iconSz = opts.icon or (h - 12)
	local f = CreateFrame("Button", nil, parent)
	f:SetHeight(h)
	if opts.w then f:SetWidth(opts.w) end
	GM.Panel(f, "contMedium")
	if GM.ChromePanel then GM.ChromePanel(f) end
	f:SetScript("OnEnter", function() GM.Panel(f, "contHigh") end)
	f:SetScript("OnLeave", function() GM.Panel(f, "contMedium") end)

	local iconBox = CreateFrame("Frame", nil, f)
	iconBox:SetSize(iconSz, iconSz)
	iconBox:SetPoint("LEFT", 6, 0)
	GM.Panel(iconBox, "contHighest", "outlineVar")
	if GM.ChromePanel then GM.ChromePanel(iconBox) end
	f.icon = iconBox:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(iconSz - 4, iconSz - 4)
	f.icon:SetPoint("CENTER")
	-- hover → real item tooltip (textures can't take scripts)
	f.iconBtn = CreateFrame("Button", nil, iconBox)
	f.iconBtn:SetAllPoints()
	f.iconBtn:SetScript("OnEnter", function(s)
		if not s.itemID then return end
		GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(s.itemID)
		else
			GameTooltip:SetHyperlink("item:" .. s.itemID)
		end
		GameTooltip:Show()
	end)
	f.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	f.name = GM.MakeFontString(f, GM.FONT_MED,
		opts.nameSize or 12, "text")
	f.name:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 10, -4)
	f.name:SetPoint("RIGHT", f, "RIGHT", -8, 0)
	f.name:SetJustifyH("LEFT")
	f.name:SetWordWrap(false)
	f.sub = GM.MakeFontString(f, GM.FONT, opts.subSize or 10, "textDim")
	f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -4)
	f.sub:SetPoint("RIGHT", f, "RIGHT", -8, 0)
	f.sub:SetJustifyH("LEFT")

	local function Drop()
		local infoType, itemID, link = GetCursorInfo()
		if infoType ~= "item" then return end
		ClearCursor()
		if opts.onItem then opts.onItem(itemID, link) end
	end
	local function Click()
		if IsModifiedClick() then
			GM.ModifiedItemClick(f.iconBtn.itemID)
		elseif CursorHasItem() then
			Drop()
		end
	end
	f:EnableMouse(true)
	f:SetScript("OnReceiveDrag", Drop)
	f:SetScript("OnClick", Click)
	-- the icon button sits on top — mirror handlers or its clicks die
	f.iconBtn:SetScript("OnReceiveDrag", Drop)
	f.iconBtn:SetScript("OnClick", Click)

	function f:SetItem(id, link)
		f.itemID, f.itemLink = id, link
		f.iconBtn.itemID = id
		local name = (link and link:find("%[") and link)
			or (id and GM.ItemName and GM.ItemName(id))
			or (id and ("item " .. id))
		f.name:SetText(name or "")
		if id and GM.NameColor then
			f.name:SetTextColor(GM.NameColor(id))
		end
		local icon = id and ((C_Item and C_Item.GetItemIconByID
			and C_Item.GetItemIconByID(id))
			or (C_Item and C_Item.GetItemInfo
				and select(10, C_Item.GetItemInfo(id))))
		if icon then f.icon:SetTexture(icon) f.icon:Show()
		else f.icon:Hide() end
		f.sub:SetText(id and ("id " .. id) or "")
	end
	function f:Clear()
		f.itemID, f.itemLink = nil, nil
		f.iconBtn.itemID = nil
		f.icon:Hide()
		f.name:SetText(GM.CC("textDim")
			.. (opts.hint or "drop item here · shift-click one")
			.. "|r")
		f.sub:SetText("")
	end
	f:Clear()
	return f
end

-- currency text — a fontstring that formats copper through the
-- coin-colored GM.Money/MoneyShort/Signed formatters, so every
-- money field gets g/s/c metal colors for free. opts.suffix
-- appends after every set ("/min" on rate columns); fs._prefix
-- prepends before the value (a "~" estimate marker).
function W.Money(parent, opts)
	opts = opts or {}
	local fs = GM.MakeFontString(parent, opts.font or GM.FONT,
		opts.size or 10, opts.color or "text")
	fs.SetCopper = function(self, c)
		self:SetText((self._prefix or "") .. GM.Money(c)
			.. (opts.suffix or ""))
	end
	fs.SetCopperShort = function(self, c)
		self:SetText((self._prefix or "") .. GM.MoneyShort(c)
			.. (opts.suffix or ""))
	end
	fs.SetSigned = function(self, c)
		self:SetText((self._prefix or "") .. GM.Signed(c)
			.. (opts.suffix or ""))
	end
	if opts.copper then fs:SetCopper(opts.copper) end
	return fs
end
