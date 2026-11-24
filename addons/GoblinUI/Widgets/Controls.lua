-- ================================================================
-- GoblinUI/Widgets/Controls.lua — interactive controls: Button,
-- EditBox, SegmentedControl, BoolSegment, CycleButton, RangeText,
-- Status, Progress. All are measured leaf nodes; variants change
-- paint, never the footprint.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")
local internal = lib._internal
local ctxMT = internal.ctxMT.__index
local SP = internal.SP

-- ============ Button ============
-- ctx:Button(parent, {text=, variant='accent'|'quiet'|'ghost'|
-- 'danger', onClick=, tooltip=, height=, disabled=}) -> node
local BTN_PAINT = {
	accent = { fill = "accent", text = "onAccent", hover = "accent" },
	quiet  = { fill = "contHigh", text = "text", hover = "contHighest" },
	ghost  = { fill = "contLow", text = "textDim", hover = "contMedium" },
	danger = { fill = "err", text = "text", hover = "err" },
}

function ctxMT:Button(parent, opts)
	opts = opts or {}
	local node = self:Leaf(parent, {})
	node._variant = opts.variant or "accent"
	node._enabled = opts.disabled ~= true
	node._selected = false
	node._busy = false
	node._h = opts.height or internal.CONTROL_H

	local b = CreateFrame("Button", nil, node.frame)
	b:SetAllPoints()
	b:EnableMouse(true)
	node.button = b

	local lbl = b:CreateFontString(nil, "OVERLAY")
	lbl:SetPoint("CENTER", 0, 0)
	lbl:SetFont(self:Font("semibold"), 14 * self.textScale, "")
	lbl:SetText(opts.text or "")
	node.label = lbl

	local function paint(hover)
		local p = BTN_PAINT[node._variant] or BTN_PAINT.accent
		if not node._enabled then
			self:Fill(b, "contMedium")
			lbl:SetTextColor(self:Color("outlineVar"))
		elseif node._busy then
			self:Fill(b, "contHigh")
			lbl:SetTextColor(self:Color("textDim"))
		elseif node._selected then
			self:Fill(b, "accent")
			lbl:SetTextColor(self:Color("onAccent"))
		else
			self:Fill(b, hover and p.hover or p.fill)
			local r, g, bl = self:Color(p.text)
			lbl:SetTextColor(r, g, bl,
				hover and node._variant == "ghost" and 1 or 1)
		end
	end
	node._paint = paint

	b:SetScript("OnEnter", function()
		paint(true)
		if opts.tooltip then
			GameTooltip:SetOwner(b, "ANCHOR_TOP")
			GameTooltip:SetText(opts.tooltip)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function()
		paint(false)
		if opts.tooltip then GameTooltip:Hide() end
	end)
	b:SetScript("OnClick", function()
		if node._enabled and not node._busy and opts.onClick then
			opts.onClick(node)
		end
	end)

	function node:SetText(t)
		lbl:SetText(t)
		self:InvalidateLayout()
	end
	function node:GetText() return lbl:GetText() end
	function node:SetEnabled(e)
		self._enabled = e and true or false
		paint(false)
		b:EnableMouse(e and true or false)
	end
	function node:IsEnabled() return self._enabled end
	function node:SetBusy(bu, busyText)
		self._busy = bu and true or false
		if busyText then lbl:SetText(busyText) end
		paint(false)
	end
	function node:SetSelected(s)
		self._selected = s and true or false
		paint(false)
	end
	function node:IsSelected() return self._selected end

	-- natural width = label + horizontal padding
	function node:measure()
		local w = lbl:GetStringWidth() + SP.xl * 2
		return math.max(internal.CONTROL_H, w), node._h
	end

	paint(false)
	return node
end

-- ============ EditBox ============
-- ctx:EditBox(parent, {placeholder=, text=, width=,
-- onChange=fn(text), onCommit=fn(text)}) -> node. Dirty tracking:
-- SetText marks pristine; user typing marks dirty until commit.
function ctxMT:EditBox(parent, opts)
	opts = opts or {}
	local node = self:Leaf(parent, {})
	node._h = internal.CONTROL_H
	node._dirty = false

	local bg = self:Fill(node.frame, "contLowest")
	self:Border(node.frame, "outlineVar")

	local eb = CreateFrame("EditBox", nil, node.frame)
	eb:SetPoint("TOPLEFT", SP.sm, 0)
	eb:SetPoint("BOTTOMRIGHT", -SP.sm, 0)
	eb:SetFont(self:Font("regular"), 14 * self.textScale, "")
	eb:SetTextColor(self:Color("text"))
	eb:SetAutoFocus(false)
	eb:SetTextInsets(0, 0, 0, 0)
	node.editBox = eb

	local ph = node.frame:CreateFontString(nil, "OVERLAY")
	ph:SetPoint("LEFT", SP.sm, 0)
	ph:SetFont(self:Font("regular"), 14 * self.textScale, "")
	ph:SetTextColor(self:Color("textDim"))
	ph:SetText(opts.placeholder or "")
	node.placeholder = ph

	local function syncPh()
		ph:SetShown((eb:GetText() or "") == "" and not eb:HasFocus())
	end
	eb:SetScript("OnTextChanged", function(_, user)
		if user then
			node._dirty = true
			syncPh()
			if opts.onChange then opts.onChange(eb:GetText(), node) end
		end
	end)
	eb:SetScript("OnEnterPressed", function()
		node._dirty = false
		eb:ClearFocus()
		if opts.onCommit then opts.onCommit(eb:GetText(), node) end
	end)
	eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
	eb:SetScript("OnEditFocusGained", syncPh)
	eb:SetScript("OnEditFocusLost", function()
		node._dirty = false
		syncPh()
	end)

	function node:SetText(t) eb:SetText(t or "") self._dirty = false syncPh() end
	function node:GetText() return eb:GetText() end
	function node:IsDirty() return self._dirty end
	function node:SetError(err)
		self:SetBorder(node.frame, err and "err" or "outlineVar")
	end
	function node:SetFocus() eb:SetFocus() end
	function node:measure() return opts.width or 160, node._h end

	syncPh()
	return node
end

-- ============ SegmentedControl ============
-- ctx:SegmentedControl(parent, {options={labels}, value=idx,
-- onChange=fn(idx)}) -> node
function ctxMT:SegmentedControl(parent, opts)
	opts = opts or {}
	local node = self:Leaf(parent, {})
	local segs = {}
	node._value = opts.value or 1

	local n = #opts.options
	for i, label in ipairs(opts.options) do
		local b = CreateFrame("Button", nil, node.frame)
		b:SetPoint("TOPLEFT", (i - 1) * 0, 0) -- positioned on arrange
		b:SetHeight(node._h or internal.CONTROL_H)
		local lbl = b:CreateFontString(nil, "OVERLAY")
		lbl:SetPoint("CENTER", 0, 0)
		lbl:SetFont(self:Font("medium"), 14 * self.textScale, "")
		lbl:SetText(label)
		b._lbl = lbl
		b:SetScript("OnClick", function()
			node:SetValue(i)
			if opts.onChange then opts.onChange(i) end
		end)
		segs[i] = b
	end
	node._segs = segs
	node._h = opts.height or internal.CONTROL_H

	local function paint()
		for i, b in ipairs(segs) do
			local sel = i == node._value
			self:Fill(b, sel and "accent" or "contHigh")
			b._lbl:SetTextColor(self:Color(sel and "onAccent" or "textDim"))
		end
	end
	node._paint = paint

	function node:onArrange(w, h)
		local segW = w / n
		for i, b in ipairs(segs) do
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", (i - 1) * segW, 0)
			b:SetSize(segW, h)
		end
		paint()
	end
	function node:SetValue(i)
		self._value = i
		paint()
	end
	function node:GetValue() return self._value end
	function node:measure()
		local w = 0
		for _, b in ipairs(segs) do
			w = w + b._lbl:GetStringWidth() + SP.lg * 2
		end
		return math.max(w, n * internal.CONTROL_H), node._h
	end

	paint()
	return node
end

-- ============ BoolSegment ============
-- ctx:BoolSegment(parent, {value=bool, onChange=fn(b)}) -> node
function ctxMT:BoolSegment(parent, opts)
	opts = opts or {}
	local node = self:SegmentedControl(parent, {
		options = { self:L("On"), self:L("Off") },
		value = opts.value and 1 or 2,
		onChange = function(i)
			if opts.onChange then opts.onChange(i == 1) end
		end,
	})
	function node:SetBool(b) self:SetValue(b and 1 or 2) end
	function node:GetBool() return self:GetValue() == 1 end
	return node
end

-- ============ CycleButton ============
-- ctx:CycleButton(parent, {options={labels}, value=idx,
-- onChange=fn(idx)}) -> Button node cycling on click
function ctxMT:CycleButton(parent, opts)
	opts = opts or {}
	local node = self:Button(parent, {
		variant = "quiet",
		text = opts.options[opts.value or 1] or "",
		onClick = function()
			local v = (node._v or opts.value or 1) % #opts.options + 1
			node._v = v
			node:SetText(opts.options[v])
			if opts.onChange then opts.onChange(v) end
		end,
	})
	node._v = opts.value or 1
	function node:SetValue(i)
		node._v = i
		node:SetText(opts.options[i])
	end
	function node:GetValue() return node._v end
	return node
end

-- ============ RangeText ============
-- ctx:RangeText(parent, {min=, max=, step=, value=, fmt=,
-- onChange=fn(v)}) -> node: value text with [-]/[+] steppers
function ctxMT:RangeText(parent, opts)
	opts = opts or {}
	local node = self:Leaf(parent, {})
	node._h = opts.height or internal.CONTROL_H
	node._v = opts.value or opts.min or 0
	local fmt = opts.fmt or "%d"

	local minus = self:Button(node, {
		text = "−", variant = "quiet",
		onClick = function()
			node:SetValue(node._v - (opts.step or 1))
		end })
	local plus = self:Button(node, {
		text = "+", variant = "quiet",
		onClick = function()
			node:SetValue(node._v + (opts.step or 1))
		end })
	-- steppers are managed children only via onArrange — direct
	-- native placement inside the leaf slot
	minus.frame:SetParent(node.frame)
	plus.frame:SetParent(node.frame)

	local val = node.frame:CreateFontString(nil, "OVERLAY")
	val:SetFont(self:Font("medium"), 14 * self.textScale, "")
	val:SetTextColor(self:Color("text"))
	val:SetJustifyH("CENTER")
	node.valueFS = val

	function node:onArrange(w, h)
		local bw = math.min(internal.CONTROL_H, w / 3)
		minus.frame:ClearAllPoints()
		minus.frame:SetPoint("TOPLEFT", 0, 0)
		minus.frame:SetSize(bw, h)
		plus.frame:ClearAllPoints()
		plus.frame:SetPoint("TOPRIGHT", 0, 0)
		plus.frame:SetSize(bw, h)
		val:SetPoint("TOPLEFT", bw, 0)
		val:SetPoint("BOTTOMRIGHT", -bw, 0)
	end
	function node:SetValue(v)
		v = math.max(opts.min or -math.huge,
			math.min(opts.max or math.huge, v))
		self._v = v
		val:SetFormattedText(fmt, v)
		if opts.onChange then opts.onChange(v) end
	end
	function node:GetValue() return self._v end
	function node:measure()
		val:SetFormattedText(fmt, self._v)
		return val:GetStringWidth() + internal.CONTROL_H * 2 + SP.sm * 2,
			node._h
	end

	node:SetValue(node._v)
	return node
end

-- ============ Status ============
-- ctx:Status(parent, {text=, tone='ok'|'warn'|'err'|'dim'}) ->
-- node: small colored status line
local TONES = { ok = "pos", warn = "warn", err = "err", dim = "textDim" }
function ctxMT:Status(parent, opts)
	opts = opts or {}
	local node = self:Leaf(parent, {})
	node._tone = TONES[opts.tone or "dim"] or "textDim"
	node._h = opts.height or 20
	local fs = node.frame:CreateFontString(nil, "OVERLAY")
	fs:SetPoint("LEFT", 0, 0)
	fs:SetFont(self:Font("regular"), 14 * self.textScale, "")
	node.fs = fs
	function node:measure(availW)
		fs:SetWidth(math.max(1, availW or 1))
		fs:SetWordWrap(true)
		fs:SetText(self._text or "")
		return availW or 0,
			math.max(self._h, fs:GetStringHeight())
	end
	function node:onArrange(w)
		fs:SetWidth(math.max(1, w))
	end
	function node:SetText(t, tone)
		self._text = t or ""
		if tone then self._tone = TONES[tone] or "textDim" end
		fs:SetText(self._text)
		fs:SetTextColor(self.ctx:Color(self._tone))
		self:InvalidateLayout()
	end
	node:SetText(opts.text or "", opts.tone)
	return node
end

-- ============ Progress ============
-- ctx:Progress(parent, {value=0..1, height=}) -> node
function ctxMT:Progress(parent, opts)
	opts = opts or {}
	local node = self:Leaf(parent, {})
	node._h = opts.height or SP.sm
	node._v = opts.value or 0
	self:Fill(node.frame, "contLowest")
	local bar = node.frame:CreateTexture(nil, "ARTWORK")
	bar:SetPoint("TOPLEFT", 0, 0)
	bar:SetPoint("BOTTOMLEFT", 0, 0)
	bar:SetColorTexture(self:Color("accent"))
	node.bar = bar
	function node:onArrange(w)
		bar:SetWidth(math.max(1, w * math.min(1, math.max(0, self._v))))
	end
	function node:SetValue(v)
		self._v = v
		local w = self.frame:GetWidth()
		if w > 0 then
			bar:SetWidth(math.max(1, w * math.min(1, math.max(0, v))))
		end
	end
	function node:GetValue() return self._v end
	function node:measure() return 100, node._h end
	return node
end
