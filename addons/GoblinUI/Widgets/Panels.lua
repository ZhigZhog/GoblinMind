-- ================================================================
-- GoblinUI/Widgets/Panels.lua — Panel, Window, and PageTabs plus
-- the shared paint helpers (Fill/Border/Stroke) the widget set
-- builds on. Panels are structured: header = title + actions;
-- body = one managed Column.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")
local internal = lib._internal
local ctxMT = internal.ctxMT.__index
local Space = internal.Space
local SP = internal.SP

-- ============ paint helpers ============
-- solid fill: key = palette role, alpha optional
function ctxMT:Fill(frame, key, alpha)
	if not frame._guiuFill then
		local t = frame:CreateTexture(nil, "BACKGROUND")
		t:SetAllPoints()
		frame._guiuFill = t
	end
	local r, g, b = self:Color(key)
	frame._guiuFill:SetColorTexture(r, g, b, alpha or 1)
	return frame._guiuFill
end

-- 1px stroke, inset to the frame edges
function ctxMT:Border(frame, key, alpha, thickness)
	local th = thickness or internal.STROKE_THIN
	local b = frame._guiuBord
	if not b then
		b = {}
		for i = 1, 4 do
			b[i] = frame:CreateTexture(nil, "BORDER")
		end
		b[1]:SetPoint("TOPLEFT", 0, 0) b[1]:SetPoint("TOPRIGHT", 0, 0)
		b[1]:SetHeight(th)
		b[2]:SetPoint("BOTTOMLEFT", 0, 0)
		b[2]:SetPoint("BOTTOMRIGHT", 0, 0) b[2]:SetHeight(th)
		b[3]:SetPoint("TOPLEFT", 0, 0) b[3]:SetPoint("BOTTOMLEFT", 0, 0)
		b[3]:SetWidth(th)
		b[4]:SetPoint("TOPRIGHT", 0, 0)
		b[4]:SetPoint("BOTTOMRIGHT", 0, 0) b[4]:SetWidth(th)
		frame._guiuBord = b
	end
	local r, g, bl = self:Color(key)
	for i = 1, 4 do
		b[i]:SetColorTexture(r, g, bl, alpha or 1)
	end
	return b
end

function ctxMT:SetBorder(frame, key, alpha)
	if not frame._guiuBord then
		return self:Border(frame, key, alpha)
	end
	local r, g, b = self:Color(key)
	for i = 1, 4 do
		frame._guiuBord[i]:SetColorTexture(r, g, b, alpha or 1)
	end
end

-- ============ Panel ============
-- ctx:Panel(parent, {title=, count=, pad=}) -> leaf node with
-- .body (a managed Column arrange-root inside)
function ctxMT:Panel(parent, opts)
	opts = opts or {}
	local self2 = self
	-- leaf: the panel owns no container children (the body is its
	-- own arrange root), so natural measurement goes through here
	local cont = self:Leaf(parent, {})
	local shell = cont.frame
	self:Fill(shell, opts.fill or "contLow")
	if opts.border ~= false then
		self:Border(shell, "outlineVar")
	end

	local pad = Space(opts.pad ~= nil and opts.pad or "md")
	local headerH = opts.title and internal.HEADER_H or 0

	-- header: title text + optional action frames laid out manually
	-- (fixed geometry inside the panel top strip)
	if opts.title then
		local hdr = CreateFrame("Frame", nil, shell)
		hdr:SetPoint("TOPLEFT", 0, 0)
		hdr:SetPoint("TOPRIGHT", 0, 0)
		hdr:SetHeight(headerH)
		self:Fill(hdr, "contMedium")
		local ttl = hdr:CreateFontString(nil, "OVERLAY")
		ttl:SetPoint("LEFT", pad, 0)
		ttl:SetFont(self:Font("semibold"), 16 * self.textScale, "")
		ttl:SetTextColor(self:Color("text"))
		ttl:SetText(opts.title)
		cont._header = hdr
		cont._titleFS = ttl
		function cont:SetTitle(t) ttl:SetText(t) end
		function cont:SetCount(c)
			ttl:SetFormattedText("%s  |cff%s%s|r", opts.title,
				self2:Hex("textDim"), c or "")
		end
		-- divider under the header
		local dv = hdr:CreateTexture(nil, "BORDER")
		dv:SetPoint("BOTTOMLEFT", 0, 0)
		dv:SetPoint("BOTTOMRIGHT", 0, 0)
		dv:SetHeight(1)
		dv:SetColorTexture(self:Color("outlineVar"))
	end

	-- body: managed column inset by pad under the header
	local body = CreateFrame("Frame", nil, shell)
	body:SetPoint("TOPLEFT", pad, -(headerH + pad))
	body:SetPoint("BOTTOMRIGHT", -pad, pad)
	cont._bodyFrame = body

	-- the managed body is its own arrange root inside the panel
	local inner = self:AttachRoot(body,
		{ direction = "column", gap = opts.gap or "sm" })
	cont.body = inner

	-- natural panel height = header + body content + pads
	function cont:measure(availW)
		local iw = math.max(0, (availW or 0) - pad * 2)
		local _, bh = internal.MeasureNode(inner, iw, math.huge)
		return availW or 0,
			headerH + pad * 2 + bh + (headerH > 0 and pad or 0)
	end

	return cont
end

-- ============ Window ============
-- ctx:Window(name, {title=, width=, height=, strata=,
-- onClose=, movable=true}) -> node-ish object with .frame and
-- .body (managed Column arrange-root). The window frame anchors
-- absolutely — it's a root, not a managed child.
function ctxMT:Window(name, opts)
	opts = opts or {}
	local f = CreateFrame("Frame", name or ("GoblinUIWin" ..
		(self._winN and self._winN + 1 or 1)), UIParent,
		"BackdropTemplate")
	self._winN = (self._winN or 0) + 1
	f:SetSize(opts.width or 640, opts.height or 480)
	f:SetPoint(opts.point or "CENTER", UIParent, opts.point
		or "CENTER", opts.x or 0, opts.y or 0)
	f:SetFrameStrata(opts.strata or "DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	if f.SetResizeBounds then
		f:SetResizeBounds(opts.minWidth or 320,
			opts.minHeight or 240)
	end
	f:Hide()
	self:Fill(f, "surface")
	self:Border(f, "outlineVar")

	-- title bar
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetPoint("TOPLEFT", 0, 0)
	hdr:SetPoint("TOPRIGHT", 0, 0)
	hdr:SetHeight(internal.WIN_HEADER_H)
	self:Fill(hdr, "contMedium")
	local dv = hdr:CreateTexture(nil, "BORDER")
	dv:SetPoint("BOTTOMLEFT", 0, 0)
	dv:SetPoint("BOTTOMRIGHT", 0, 0)
	dv:SetHeight(1)
	dv:SetColorTexture(self:Color("outlineVar"))
	local ttl = hdr:CreateFontString(nil, "OVERLAY")
	ttl:SetPoint("LEFT", SP.lg, 0)
	ttl:SetFont(self:Font("semibold"), 16 * self.textScale, "")
	ttl:SetTextColor(self:Color("accent"))
	ttl:SetText(opts.title or "")

	-- close button — small native control in the header corner
	local close = CreateFrame("Button", nil, hdr)
	close:SetSize(internal.CONTROL_H, internal.WIN_HEADER_H)
	close:SetPoint("TOPRIGHT", 0, 0)
	local cx = close:CreateFontString(nil, "OVERLAY")
	cx:SetPoint("CENTER", 0, 0)
	cx:SetFont(self:Font("semibold"), 16 * self.textScale, "")
	cx:SetTextColor(self:Color("textDim"))
	cx:SetText("×")
	close:SetScript("OnEnter", function()
		cx:SetTextColor(self:Color("text"))
	end)
	close:SetScript("OnLeave", function()
		cx:SetTextColor(self:Color("textDim"))
	end)
	close:SetScript("OnClick", function()
		if opts.onClose then opts.onClose(f) else f:Hide() end
	end)

	-- movable via the header
	if opts.movable ~= false then
		f:SetMovable(true)
		hdr:EnableMouse(true)
		hdr:RegisterForDrag("LeftButton")
		hdr:SetScript("OnDragStart", function() f:StartMoving() end)
		hdr:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
	end

	-- body = managed Column filling under the header
	local body = CreateFrame("Frame", nil, f)
	body:SetPoint("TOPLEFT", SP.lg, -(internal.WIN_HEADER_H + SP.md))
	body:SetPoint("BOTTOMRIGHT", -SP.lg, SP.lg)
	local win = {
		frame = f, header = hdr, titleFS = ttl,
		body = self:AttachRoot(body,
			{ direction = "column", gap = opts.gap or "sm" }),
		ctx = self,
	}
	function win:SetTitle(t) ttl:SetText(t) end
	function win:Show() f:Show() end
	function win:Hide() f:Hide() end
	function win:IsShown() return f:IsShown() end
	function win:Toggle() f:SetShown(not f:IsShown()) end
	return win
end

-- ============ PageTabs ============
-- ctx:PageTabs(parent, {tabs={labels}, onChange=fn(idx)}) ->
-- leaf node, underline-selected row of tabs
function ctxMT:PageTabs(parent, opts)
	opts = opts or {}
	local tabs = opts.tabs or {}
	local node = self:Leaf(parent, {})
	local f = node.frame
	local row = self:AttachRoot(f,
		{ direction = "row", gap = "xs", align = "center" })
	node._selected = 1
	node._btns = {}

	for i, label in ipairs(tabs) do
		local b = self:Button(node, {
			text = label,
			variant = "ghost",
			onClick = function()
				node:SetPage(i)
				if opts.onChange then opts.onChange(i) end
			end,
		})
		row:Add(b, { height = "fill" })
		node._btns[i] = b
	end

	function node:measure() return 0, internal.CONTROL_H end
	function node:SetPage(i)
		self._selected = i
		for j, b in ipairs(self._btns) do
			b:SetSelected(j == i)
		end
	end
	function node:GetPage() return self._selected end
	node:SetPage(1)
	return node
end
