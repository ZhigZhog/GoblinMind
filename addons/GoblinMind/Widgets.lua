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
	eb:SetText(hint)
	eb:SetTextColor(GM.RGB("textDim"))
	eb:SetScript("OnEditFocusGained", function()
		if eb:GetText() == hint then
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

-- hover tooltip: linesFn() returns {title, line, line…} or nil
function W.Tip(f, linesFn)
	-- accepts a fn returning lines, a plain string, or nil (no tip)
	if type(linesFn) == "string" then
		local s = linesFn
		linesFn = function() return { s } end
	end
	if type(linesFn) ~= "function" then return end
	f:HookScript("OnEnter", function()
		local lines = linesFn()
		if not lines then return end
		GameTooltip:SetOwner(f, "ANCHOR_TOP")
		GameTooltip:SetText(lines[1], 1, 1, 1)
		for i = 2, #lines do
			GameTooltip:AddLine(lines[i], 0.75, 0.75, 0.75)
		end
		GameTooltip:Show()
	end)
	f:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- subtle hover tint — attach at row creation; the HIGHLIGHT layer
-- draws itself, no script needed
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
