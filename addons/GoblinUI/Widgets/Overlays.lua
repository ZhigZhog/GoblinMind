-- ================================================================
-- GoblinUI/Widgets/Overlays.lua — shared hint (full text +
-- glossary), interactive tip, popup menu, and hover tint. One
-- hint frame and one popup frame per context; owned here.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")
local internal = lib._internal
local ctxMT = internal.ctxMT.__index
local SP = internal.SP

-- ============ shared hint frame ============
-- rich hover surface: title + wrapped body + optional glossary
-- section; pins to a target frame, clamps to screen

local function hintFrame(ctx)
	if ctx._hint then return ctx._hint end
	local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	f:SetFrameStrata("TOOLTIP")
	f:SetClampedToScreen(true)
	ctx:Fill(f, "contMedium")
	ctx:Border(f, "outline")
	f:Hide()

	local ttl = f:CreateFontString(nil, "OVERLAY")
	ttl:SetPoint("TOPLEFT", SP.md, -SP.sm)
	ttl:SetFont(ctx:Font("semibold"), 14 * ctx.textScale, "")
	ttl:SetTextColor(ctx:Color("accent"))
	f._ttl = ttl

	local body = f:CreateFontString(nil, "OVERLAY")
	body:SetPoint("TOPLEFT", SP.md, -(SP.sm + 18))
	body:SetFont(ctx:Font("regular"), 14 * ctx.textScale, "")
	body:SetTextColor(ctx:Color("text"))
	body:SetWidth(280)
	body:SetWordWrap(true)
	body:SetJustifyH("LEFT")
	f._body = body
	ctx._hint = f
	return f
end

-- ctx:HintShow(target, content) — content = string, or
-- {title=, body=, glossary={{"code","def"},...}}
function ctxMT:HintShow(target, content)
	local f = hintFrame(self)
	local title, body = "", ""
	local gloss
	if type(content) == "table" then
		title = content.title or ""
		body = content.body or ""
		gloss = content.glossary
	else
		body = content or ""
	end
	f._ttl:SetText(title)
	f._ttl:SetShown(title ~= "")
	local h = SP.sm + (title ~= "" and 18 or 0)
	f._body:SetPoint("TOPLEFT", SP.md, -(h + 2))
	f._body:SetText(body)
	if gloss and #gloss > 0 then
		local parts = { body }
		for _, g in ipairs(gloss) do
			parts[#parts + 1] = ("|cff%s%s|r — %s")
				:format(self:Hex("accent"), g[1], g[2])
		end
		f._body:SetText(table.concat(parts, "\n"))
	end
	f:SetWidth(300)
	f:SetHeight(h + 2 + f._body:GetStringHeight() + SP.sm)
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", target, "BOTTOMLEFT", 0, -4)
	f:Show()
	return f
end

function ctxMT:HintHide()
	if self._hint then self._hint:Hide() end
end

-- ctx:Tip(node, content) — bind hover hints to any node/frame
function ctxMT:Tip(node, content)
	local f = type(node) == "table" and node.frame or node
	if f._guiuTip then
		f._guiuTip = content
		return
	end
	f._guiuTip = content
	local prev = f:GetScript("OnEnter")
	f:SetScript("OnEnter", function(...)
		if prev then prev(...) end
		self:HintShow(f, f._guiuTip)
	end)
	local prevL = f:GetScript("OnLeave")
	f:SetScript("OnLeave", function(...)
		if prevL then prevL(...) end
		self:HintHide()
	end)
	f:SetScript("OnHide", function() self:HintHide() end)
end

-- ============ PopupMenu ============
-- ctx:PopupMenu(anchor, entries, {onPick=fn(entry)}) — entries =
-- {{label=, value=, disabled=}, ...}; one shared frame
function ctxMT:PopupMenu(anchor, entries, opts)
	opts = opts or {}
	if not self._popup then
		local p = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
		p:SetFrameStrata("TOOLTIP")
		p:SetClampedToScreen(true)
		p:EnableMouse(true)
		self:Fill(p, "contMedium")
		self:Border(p, "outline")
		p._items = {}
		p:Hide()
		-- close on outside click
		p:SetScript("OnShow", function()
			p._closeTimer = p._closeTimer
				or CreateFrame("Frame", nil, p)
			p._closeTimer:SetScript("OnUpdate", function()
				if not p:IsMouseOver() and IsMouseButtonDown() then
					p:Hide()
				end
			end)
		end)
		p:SetScript("OnHide", function()
			if p._closeTimer then
				p._closeTimer:SetScript("OnUpdate", nil)
			end
		end)
		self._popup = p
	end
	local p = self._popup
	-- rebuild item rows
	for _, it in ipairs(p._items) do it:Hide() end
	wipe(p._items)
	local y = -SP.xs
	local w = 120
	for i, e in ipairs(entries) do
		local b = CreateFrame("Button", nil, p)
		b:SetPoint("TOPLEFT", SP.xs, y)
		b:SetHeight(internal.ROW_RO_H)
		local lbl = b:CreateFontString(nil, "OVERLAY")
		lbl:SetPoint("LEFT", SP.sm, 0)
		lbl:SetFont(self:Font("regular"), 14 * self.textScale, "")
		lbl:SetText(e.label)
		lbl:SetTextColor(self:Color(e.disabled and "textDim" or "text"))
		w = math.max(w, lbl:GetStringWidth() + SP.lg * 2)
		self:Fill(b, "contMedium")
		b:SetScript("OnEnter", function()
			self:Fill(b, "contHighest")
		end)
		b:SetScript("OnLeave", function()
			self:Fill(b, "contMedium")
		end)
		if not e.disabled then
			b:SetScript("OnClick", function()
				p:Hide()
				if opts.onPick then opts.onPick(e) end
				if e.onClick then e.onClick(e) end
			end)
		end
		y = y - internal.ROW_RO_H
		p._items[i] = b
	end
	for _, it in ipairs(p._items) do it:SetWidth(w - SP.xs * 2) end
	p:SetSize(w, -y + SP.xs)
	p:ClearAllPoints()
	p:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	p:Show()
	return p
end

-- ============ HoverTint ============
-- ctx:HoverTint(node, {r=,g=,b=,a=}) — overlay tint on hover
function ctxMT:HoverTint(node, opts)
	opts = opts or {}
	local f = type(node) == "table" and node.frame or node
	if not f._guiuHoverT then
		local t = f:CreateTexture(nil, "OVERLAY")
		t:SetAllPoints()
		t:Hide()
		f._guiuHoverT = t
		local prev = f:GetScript("OnEnter")
		f:SetScript("OnEnter", function(...)
			if prev then prev(...) end
			f._guiuHoverT:Show()
		end)
		local prevL = f:GetScript("OnLeave")
		f:SetScript("OnLeave", function(...)
			if prevL then prevL(...) end
			f._guiuHoverT:Hide()
		end)
	end
	f._guiuHoverT:SetColorTexture(opts.r or 1, opts.g or 1,
		opts.b or 1, opts.a or 0.08)
	return f._guiuHoverT
end
