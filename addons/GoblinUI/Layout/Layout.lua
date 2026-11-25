-- ================================================================
-- GoblinUI/Layout/Layout.lua — the flow/box engine. Containers own
-- child geometry: sibling slots can never intersect by construction.
-- Absolute coordinates are legal only at roots, inside Canvas, and
-- in native-frame adapters. Spec contract: goblin-ui-design-system
-- .md §3.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")
local internal = lib._internal
local ctxMT = internal.ctxMT.__index
local Space = internal.Space

local nodeMT = { __index = {} }
local NodeIdx = nodeMT.__index
local ZEROPAD = { top = 0, right = 0, bottom = 0, left = 0 }

local function newNode(ctx, kind, frame)
	return setmetatable({
		ctx = ctx, kind = kind, frame = frame,
		children = {}, constraints = {},
		visible = true,
	}, nodeMT)
end

-- managed-geometry guard: in diagnostics contexts the outer frame's
-- native geometry calls report once — the engine alone may place it
local function guard(ctx, frame)
	if not ctx.diagnostics then return end
	local s, ss, cp = frame.SetPoint, frame.SetSize, frame.ClearAllPoints
	frame.SetPoint = function(f, ...)
		if not f._guiu_layout then
			internal.report(ctx, "extSetPoint",
				"external SetPoint on a managed frame — use layout constraints")
		end
		return s(f, ...)
	end
	frame.SetSize = function(f, ...)
		if not f._guiu_layout then
			internal.report(ctx, "extSetSize",
				"external SetSize on a managed frame — use layout constraints")
		end
		return ss(f, ...)
	end
	frame.ClearAllPoints = function(f, ...)
		if not f._guiu_layout then
			internal.report(ctx, "extClearAllPoints",
				"external ClearAllPoints on a managed frame")
		end
		return cp(f, ...)
	end
end

-- the engine's own placement path — never reports
local function place(node, parent, x, y, w, h)
	local f = node.frame
	f._guiu_layout = true
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
	f:SetSize(math.max(0, w), math.max(0, h))
	f._guiu_layout = nil
end
internal.Place = place

-- ============ constraints ============

local ALIGNS = { start = true, center = true, ["end"] = true, stretch = true }
local JUSTIFIES = { start = true, center = true, ["end"] = true }

local function normConstraints(c)
	c = c or {}
	local out = {
		width = c.width, height = c.height,
		grow = c.grow or 1,
		minWidth = c.minWidth or 0, minHeight = c.minHeight or 0,
		maxWidth = c.maxWidth, maxHeight = c.maxHeight,
		align = c.align,
	}
	for _, d in ipairs({ "width", "height" }) do
		local v = out[d]
		if v == nil then
			out[d] = "auto"
		elseif v ~= "auto" and v ~= "fill"
			and type(v) ~= "number" then
			error("GoblinUI: " .. d .. " must be a number, 'auto', or 'fill'")
		end
	end
	if out.align and not ALIGNS[out.align] then
		error("GoblinUI: unknown align '" .. tostring(out.align) .. "'")
	end
	return out
end

local function normPad(p)
	if p == nil then return { top = 0, right = 0, bottom = 0, left = 0 } end
	if type(p) == "table" then
		return { top = Space(p.top or 0), right = Space(p.right or 0),
			bottom = Space(p.bottom or 0), left = Space(p.left or 0) }
	end
	local v = Space(p)
	return { top = v, right = v, bottom = v, left = v }
end

-- ============ nodes ============

function NodeIdx:GetFrame() return self.frame end

function NodeIdx:SetLayout(c)
	assert(self.parent, "GoblinUI: SetLayout needs a registered parent")
	self.constraints = normConstraints(c)
	self:InvalidateLayout()
end

function NodeIdx:SetVisible(b)
	b = b and true or false
	if b == self.visible then return end
	self.visible = b
	self.frame:SetShown(b)
	self:InvalidateLayout()
end

function NodeIdx:IsVisible() return self.visible end

function NodeIdx:InvalidateLayout()
	local n = self
	while n.parent do n = n.parent end
	if n.isRoot then internal.MarkDirty(self.ctx, n) end
end

-- ============ containers ============

local function newContainer(ctx, parent, kind, opts)
	opts = opts or {}
	local f = CreateFrame("Frame", nil,
		type(parent) == "table" and parent.frame or parent)
	local n = newNode(ctx, kind, f)
	n.gap = Space(opts.gap ~= nil and opts.gap
		or (kind == "column" and "md" or "sm"))
	n.pad = normPad(opts.pad)
	n.justify = opts.justify or "start"
	n.overflow = opts.overflow or "clip"
	assert(JUSTIFIES[n.justify],
		"GoblinUI: unknown justify '" .. tostring(n.justify) .. "'")
	guard(ctx, f)
	return n
end

function ctxMT:Column(parent, opts)
	return newContainer(self, parent, "column", opts)
end

function ctxMT:Row(parent, opts)
	return newContainer(self, parent, "row", opts)
end

local function assertAddable(self, node)
	assert(type(node) == "table" and node.ctx == self.ctx,
		"GoblinUI: node belongs to a foreign context")
	assert(not node.parent,
		"GoblinUI: node already registered — Remove() before re-adding")
	local p = node
	while p do
		assert(p ~= self, "GoblinUI: layout cycle rejected")
		p = p.parent
	end
end

function NodeIdx:Add(node, constraints)
	assertAddable(self, node)
	local cc = normConstraints(constraints)
	-- column children default to width=fill whenever width is
	-- unspecified — an explicit height must not collapse the row
	-- to its measured width and starve fill siblings
	if self.kind == "column"
		and (not constraints or constraints.width == nil) then
		cc.width = "fill"
	end
	node.constraints = cc
	node.parent = self
	node.frame:SetParent(self.frame)
	self.children[#self.children + 1] = node
	if not node.visible then node.frame:Hide() end
	self:InvalidateLayout()
	return node
end

function NodeIdx:Remove(node)
	for i, c in ipairs(self.children) do
		if c == node then
			tremove(self.children, i)
			node.parent = nil
			node.frame:Hide()
			self:InvalidateLayout()
			return node
		end
	end
end

function NodeIdx:Clear()
	for _, c in ipairs(self.children) do
		c.parent = nil
		c.frame:Hide()
	end
	wipe(self.children)
	self:InvalidateLayout()
end

function NodeIdx:SetGap(g) self.gap = Space(g) self:InvalidateLayout() end
function NodeIdx:SetPadding(p) self.pad = normPad(p) self:InvalidateLayout() end

-- ============ measure ============
-- recursive natural-size pass. Leaves report via measure(); a fill
-- child measures at its declared minimum here and gets the real
-- share during arrange.

local function measureNode(node, availW, availH)
	local c = node.constraints or {}
	if node.kind == "leaf" then
		if node.measure then
			-- coerce: a measure that returns a constraint word like
			-- "fill" (e.g. passed through Adopt opts) degrades to 0
			-- instead of crashing math.max downstream
			local mw, mh = node:measure(availW, availH)
			return tonumber(mw) or 0, tonumber(mh) or 0
		end
		return 0, 0
	end
	-- container-ish node (scroll viewports arrive here too — no
	-- pad/gap on them, their content column roots itself)
	local pad = node.pad or ZEROPAD
	local iw = math.max(0, (availW or 0) - pad.left - pad.right)
	local ih = math.max(0, (availH or 0) - pad.top - pad.bottom)
	local main, cross, n = 0, 0, 0
	local gap = node.gap or 0
	local column = node.kind == "column"
	for _, ch in ipairs(node.children) do
		if ch.visible then
			local mw, mh = measureNode(ch, iw, ih)
			local mkey = column and "height" or "width"
			local cval = ch.constraints[mkey]
			local nat = column and mh or mw
			-- numeric constraints are absolute; fill defers to
			-- weight allocation at min size; auto takes the measure
			local m = type(cval) == "number" and cval
				or (cval == "fill"
					and (ch.constraints[column and "minHeight"
						or "minWidth"] or 0) or nat)
			if column then
				main = main + m
				cross = math.max(cross, mw)
			else
				main = main + m
				cross = math.max(cross, mh)
			end
			n = n + 1
		end
	end
	if n > 1 then main = main + (n - 1) * gap end
	local w = column and cross or main
	local h = column and main or cross
	return w + pad.left + pad.right, h + pad.top + pad.bottom
end
internal.MeasureNode = measureNode

-- ============ arrange ============
-- slot allocation: fixed/auto keep measured size; remaining space
-- goes to fill children by weight, freezing at min/max

local function allocFill(children, column, avail)
	-- returns alloc map; avail = free main space after fixed/auto
	local open, weight = {}, 0
	for _, ch in ipairs(children) do
		if ch.visible
			and ch.constraints[column and "height" or "width"] == "fill" then
			open[ch] = true
			weight = weight + ch.constraints.grow
		end
	end
	local alloc = {}
	local guard = 0
	while weight > 0 and avail > 0 and guard < 20 do
		guard = guard + 1
		local share = avail / weight
		local anyFreeze = false
		for ch in pairs(open) do
			local key = column and "height" or "width"
			local minK = column and "minHeight" or "minWidth"
			local maxK = column and "maxHeight" or "maxWidth"
			local want = share * ch.constraints.grow
			local lo = ch.constraints[minK] or 0
			local hi = ch.constraints[maxK]
			local got = math.max(lo, hi and math.min(hi, want) or want)
			if got ~= want then
				-- freeze this child at its bound; redistribute rest
				alloc[ch] = got
				avail = avail - got
				weight = weight - ch.constraints.grow
				open[ch] = nil
				anyFreeze = true
			end
		end
		if not anyFreeze then break end
	end
	if weight > 0 then
		local share = weight > 0 and avail / weight or 0
		for ch in pairs(open) do
			alloc[ch] = math.max(0, share * ch.constraints.grow)
		end
	end
	return alloc
end

local function arrange(node, w, h)
	-- node already has its slot (w×h); lay out children in content box
	if node.kind == "leaf" then
		if node.onArrange then node:onArrange(w, h) end
		return
	end
	local column = node.kind == "column"
	local pad = node.pad or ZEROPAD
	local cw = math.max(0, w - pad.left - pad.right)
	local ch2 = math.max(0, h - pad.top - pad.bottom)
	local mainAvail = column and ch2 or cw
	-- measure pass at the content width
	local measured, fixedSum, visN = {}, 0, 0
	for _, c in ipairs(node.children) do
		if c.visible then
			local mw, mh = measureNode(c, cw, ch2)
			measured[c] = { w = mw, h = mh }
			local key = column and "height" or "width"
			if c.constraints[key] ~= "fill" then
				-- numeric constraints are absolute; auto takes the
				-- measured size
				local m = type(c.constraints[key]) == "number"
					and c.constraints[key] or (column and mh or mw)
				m = math.max(c.constraints[column and "minHeight" or "minWidth"] or 0, m)
				local cap = c.constraints[column and "maxHeight" or "maxWidth"]
				if cap then m = math.min(cap, m) end
				measured[c].main = m
				fixedSum = fixedSum + m
			end
			visN = visN + 1
		end
	end
	local gapSum = visN > 1 and (visN - 1) * (node.gap or 0) or 0
	local free = math.max(0, mainAvail - gapSum - fixedSum)
	local fills = allocFill(node.children, column, free)
	-- extra space after fill caps follows justify
	local fillSum = 0
	for _, a in pairs(fills) do fillSum = fillSum + a end
	local leftover = math.max(0, mainAvail - gapSum - fixedSum - fillSum)
	local origin = column and pad.top or pad.left
	if node.justify == "center" then origin = origin + leftover / 2
	elseif node.justify == "end" then origin = origin + leftover end
	for _, c in ipairs(node.children) do
		if c.visible then
			local m = measured[c]
			local mainSize = fills[c] or m.main or 0
			-- cross size: stretch fills the content box; others
			-- align within it
			local crossAvail = column and cw or ch2
			local cc = c.constraints[column and "width" or "height"]
			local ckey = column and "width" or "height"
			local cmin = c.constraints[column and "minWidth" or "minHeight"] or 0
			local nat = column and m.w or m.h
			local crossSize
			if cc == "fill" then crossSize = math.max(cmin, crossAvail)
			elseif cc == "auto" then crossSize = math.max(cmin, nat)
			else crossSize = math.max(cmin, cc) end
			local cap = c.constraints[column and "maxWidth" or "maxHeight"]
			if cap then crossSize = math.min(cap, crossSize) end
			crossSize = math.min(crossSize, crossAvail)
			local al = c.constraints.align
				or (column and "stretch" or "center")
			local co = 0 -- cross origin within content box
			if al == "center" then co = (crossAvail - crossSize) / 2
			elseif al == "end" then co = crossAvail - crossSize end
			local x = column and pad.left + co or origin
			local y = column and origin or pad.top + co
			place(c, node.frame, x, y,
				column and crossSize or mainSize,
				column and mainSize or crossSize)
			arrange(c, column and crossSize or mainSize,
				column and mainSize or crossSize)
			-- nested arrange-roots (panel bodies, scroll content)
			-- flush in the same pass — no first-show frame lag
			if c._subRoots then
				for _, sr in ipairs(c._subRoots) do
					internal.ArrangeRoot(node.ctx, sr)
				end
			end
			origin = origin + mainSize + (node.gap or 0)
		end
	end
end
internal.arrange = arrange

-- root flush: the scheduler calls this once per dirty frame.
-- _arrangeOverride lets wrappers (Scroll) re-measure instead of
-- re-placing within a stale frame size
function internal.ArrangeRoot(ctx, root)
	if root._arrangeOverride then
		root._arrangeOverride(ctx, root)
		return
	end
	if not root.frame:IsShown() then return end
	local w, h = root.frame:GetSize()
	if w <= 0 or h <= 0 then return end
	arrange(root, w, h)
end

-- ============ roots / leaves / canvas / scroll ============

-- ui:AttachRoot(frame, options) -> container: one bounded managed
-- Column inside an existing host frame; host keeps the frame's
-- screen position, we own everything inside
function ctxMT:AttachRoot(frame, opts)
	opts = opts or {}
	local n = newContainer(self, frame, opts.direction == "row"
		and "row" or "column", opts)
	n.frame:SetAllPoints(frame)
	n.isRoot = true
	n.rootOpts = opts
	-- re-arrange when the host bounds change
	frame:HookScript("OnSizeChanged", function()
		internal.MarkDirty(self, n)
	end)
	frame:HookScript("OnShow", function()
		internal.MarkDirty(self, n)
	end)
	return n
end

function NodeIdx:LayoutNow()
	local n = self
	while n.parent do n = n.parent end
	internal.ArrangeRoot(self.ctx, n)
	return true
end

-- ui:Leaf(parent, {measure=fn, onArrange=fn, width=,height=}) ->
-- node: the primitive every widget wraps — a measured box
function ctxMT:Leaf(parent, opts)
	opts = opts or {}
	local f = opts.frame or CreateFrame("Frame", nil,
		type(parent) == "table" and parent.frame or parent)
	local n = newNode(self, "leaf", f)
	n.measure = opts.measure
	n.onArrange = opts.onArrange
	guard(self, f)
	return n
end

-- ui:Adopt(frame, options) -> node: wraps a foreign frame with an
-- explicit size or measure callback; the adapter keeps ownership
function ctxMT:Adopt(frame, opts)
	opts = opts or {}
	local w, h = opts.width, opts.height
	return self:Leaf(frame:GetParent(), {
		frame = frame,
		measure = opts.measure or function() return w or 0, h or 0 end,
	})
end

-- ui:Canvas(parent, options) -> node: managed outer box; absolute
-- art lives inside canvas.content only
function ctxMT:Canvas(parent, opts)
	opts = opts or {}
	local n = self:Leaf(parent, {
		measure = opts.measure or function()
			return opts.width or 0, opts.height or 0
		end,
		onArrange = function(node, w, h)
			-- only on real change: an unconditional callback into a
			-- repaint that itself invalidates layout is a dirty loop.
			-- (node IS this leaf — 'n' isn't in scope yet here)
			if node.contentWidth ~= w or node.contentHeight ~= h then
				node.contentWidth, node.contentHeight = w, h
				if opts.onResize then opts.onResize(node, w, h) end
			end
		end,
	})
	n.content = CreateFrame("Frame", nil, n.frame)
	n.content:SetAllPoints()
	if n.content.SetClipsChildren then
		n.content:SetClipsChildren(true)
	end
	return n
end

-- ui:Scroll(parent, {axis='vertical'}) -> node: ScrollFrame
-- viewport whose .content is a managed Column measured at the
-- viewport width; scroll offset/range owned here
function ctxMT:Scroll(parent, opts)
	opts = opts or {}
	local sf = CreateFrame("ScrollFrame", nil,
		type(parent) == "table" and parent.frame or parent)
	local n = newNode(self, "scroll", sf)
	guard(self, sf)
	local inner = newContainer(self, sf, "column", opts)
	sf:SetScrollChild(inner.frame)
	inner.isRoot = true -- its own arrange root
	inner._arrangeOverride = function() n:UpdateScrollRange() end
	n._subRoots = { inner }
	n.content = inner
	function n:UpdateScrollRange()
		local w = sf:GetWidth()
		if w <= 0 then return end
		inner.frame:SetWidth(w)
		local _, ch = measureNode(inner, w, math.huge)
		inner.frame:SetHeight(math.max(ch, sf:GetHeight()))
		arrange(inner, w, ch)
		sf:SetVerticalScroll(math.min(sf:GetVerticalScroll(),
			math.max(0, ch - sf:GetHeight())))
	end
	sf:SetScript("OnMouseWheel", function(_, d)
		local max = math.max(0, inner.frame:GetHeight() - sf:GetHeight())
		sf:SetVerticalScroll(math.max(0, math.min(max,
			sf:GetVerticalScroll() - d * 32)))
	end)
	-- viewport resizes re-flow the content column
	sf:HookScript("OnSizeChanged", function()
		n:UpdateScrollRange()
	end)
	function n:InvalidateLayout()
		internal.MarkDirty(self.ctx, inner)
	end
	return n
end
