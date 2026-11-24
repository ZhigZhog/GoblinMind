-- ================================================================
-- GoblinUI/Text/Text.lua — semantic text styles and the measured
-- Text node. Text is a frame containing its FontString: wrap by
-- default, auto height; single-line variants truncate with an
-- ellipsis and carry the full string as a hint.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")
local internal = lib._internal
local ctxMT = internal.ctxMT.__index

-- style lookup: theme styles × context textScale
function ctxMT:TextStyle(name)
	local t = internal.themes[self.themeId]
	local s = t and t.styles and t.styles[name]
		or (t and t.styles and t.styles.body)
	return s
end

-- apply a semantic style to a fontstring
function ctxMT:ApplyStyle(fs, name)
	local s = self:TextStyle(name)
	local size = math.floor(s.size * self.textScale + 0.5)
	fs:SetFont(self:Font(s.font), size, "")
	fs:SetTextColor(self:Color(s.color))
	return s
end

-- measurement cache: font×size×width×text -> height. Invalidated
-- per text set (key includes the string) and on theme change.
local measureFS
local function measureHeight(ctx, fs, text, width)
	measureFS = measureFS or UIParent:CreateFontString(nil, "OVERLAY")
	local s = ctx:ApplyStyle(measureFS, fs._guiuStyle or "body")
	measureFS:SetWidth(math.max(1, width))
	measureFS:SetText(text)
	return measureFS:GetStringHeight()
end
internal.MeasureHeight = measureHeight

-- ui:Text(parent, options) -> node
-- options: text, style, wrap (default true), maxLines,
-- overflow='ellipsis', align ('LEFT'|'CENTER'|'RIGHT'), richText
function ctxMT:Text(parent, opts)
	opts = opts or {}
	local wrap = opts.wrap ~= false
	local node = self:Leaf(parent, {})
	node._text = opts.text or ""
	node._style = opts.style or "body"
	node._wrap = wrap
	node._align = opts.align or "LEFT"

	local fs = node.frame:CreateFontString(nil, "OVERLAY")
	fs._guiuStyle = node._style
	fs:SetPoint("TOPLEFT", 0, 0)
	fs:SetJustifyH(node._align)
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(wrap)
	if opts.spacing then fs:SetSpacing(opts.spacing) end
	node.fontString = fs

	function node:ApplyText()
		fs._guiuStyle = self._style
		self.ctx:ApplyStyle(fs, self._style)
		fs:SetText(self._text)
		-- width binds at arrange time; fontstring tracks the slot
		fs:SetWidth(self.frame:GetWidth() > 0 and self.frame:GetWidth() or 1)
		-- enforce min line box so a one-line label always reserves it
		local s = self.ctx:TextStyle(self._style)
		local line = s.line * self.ctx.textScale
		local h = fs:GetStringHeight()
		self._measuredH = math.max(line, h)
	end

	function node:measure(availW)
		if not wrap then
			-- single line: min line box height, natural width
			local s = self.ctx:TextStyle(self._style)
			fs._guiuStyle = self._style
			self.ctx:ApplyStyle(fs, self._style)
			fs:SetText(self._text)
			fs:SetWidth(10000)
			local w = fs:GetStringWidth()
			return w, s.line * self.ctx.textScale
		end
		fs._guiuStyle = self._style
		self.ctx:ApplyStyle(fs, self._style)
		fs:SetWidth(math.max(1, availW or 1))
		fs:SetText(self._text)
		local s = self.ctx:TextStyle(self._style)
		local h = math.max(s.line * self.ctx.textScale,
			fs:GetStringHeight())
		return availW or 0, h
	end

	function node:onArrange(w, h)
		fs:SetWidth(math.max(1, w))
		if not wrap then
			-- ellipsis: let the fontstring clip, then hint carries
			-- the full string (SetWordWrap(false) + width = clip)
			fs:SetWordWrap(false)
		end
		self:ApplyText()
	end

	-- semantic setters — callers never touch the fontstring
	function node:SetText(t)
		self._text = t or ""
		self:ApplyText()
		self:InvalidateLayout()
	end
	function node:GetText() return self._text end
	function node:SetStyle(name)
		self._style = name
		fs._guiuStyle = name
		self:ApplyText()
		self:InvalidateLayout()
	end

	node.ApplyText(node)
	return node
end
