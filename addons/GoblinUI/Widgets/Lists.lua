-- ================================================================
-- GoblinUI/Widgets/Lists.lua — List: pooled fixed-height rows in a
-- scroll viewport. The pool grows to the visible count; scrolling
-- rebinds, never creates. Rows are managed Column children so row
-- internals stay inside the box model.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")
local internal = lib._internal
local ctxMT = internal.ctxMT.__index
local SP = internal.SP

-- ctx:List(parent, {rowHeight=, bindRow=fn(row,item,idx),
-- makeRow=fn(row)->children?, keyFn=fn(item), onRowClick=}) -> node
--
-- row = {frame=ScrollChild-index row frame, item=current item,
-- index=, extra=user data}. bindRow is REQUIRED — it paints.
function ctxMT:List(parent, opts)
	opts = opts or {}
	local rowH = opts.rowHeight or internal.ROW_RO_H
	assert(opts.bindRow,
		"GoblinUI: List requires bindRow(row, item, index)")

	local node = self:Leaf(parent, {})
	local f = node.frame
	f:SetClipsChildren(true)

	-- scroll machinery: native ScrollFrame owns the viewport;
	-- rows are plain frames inside the scroll child
	local sf = CreateFrame("ScrollFrame", nil, f)
	sf:SetAllPoints()
	local child = CreateFrame("Frame", nil, sf)
	sf:SetScrollChild(child)
	node._sf = sf
	node._child = child

	node._items = {}
	node._pool = {}
	node._selKey = nil
	node._offset = 0

	sf:SetScript("OnMouseWheel", function(_, d)
		node:SetOffset(node._offset - d * rowH * 3)
	end)

	local function makeRow(i)
		local r = CreateFrame("Button", nil, child)
		r:SetHeight(rowH)
		r:RegisterForClicks("LeftButtonUp")
		local row = { frame = r, item = nil, index = 0, extra = {} }
		if opts.makeRow then opts.makeRow(row, self) end
		r:SetScript("OnClick", function()
			if opts.onRowClick and row.item then
				opts.onRowClick(row.item, row)
			end
		end)
		return row
	end

	function node:SetOffset(o)
		local maxO = math.max(0,
			#self._items * rowH - sf:GetHeight())
		self._offset = math.max(0, math.min(maxO, o))
		sf:SetVerticalScroll(self._offset)
		self:Rebind()
	end

	-- rebind visible rows to items (pool rebinding, no churn)
	function node:Rebind()
		local h = f:GetHeight()
		if h <= 0 then return end
		local first = math.floor(self._offset / rowH) + 1
		local visN = math.ceil(h / rowH) + 1
		while #self._pool < visN do
			self._pool[#self._pool + 1] = makeRow(#self._pool + 1)
		end
		for i, row in ipairs(self._pool) do
			local idx = first + i - 1
			local item = self._items[idx]
			row.index = idx
			row.item = item
			if item then
				row.frame:ClearAllPoints()
				row.frame:SetPoint("TOPLEFT", 0,
					-(idx - 1) * rowH + self._offset)
				row.frame:SetWidth(f:GetWidth())
				row.frame:Show()
				opts.bindRow(row, item, idx)
				-- selection paint after user bind
				if self._selKey ~= nil and opts.keyFn then
					row.frame._guiuSel = opts.keyFn(item) == self._selKey
				end
			else
				row.frame:Hide()
			end
		end
		-- hide surplus pool rows
		for i = visN + 1, #self._pool do
			self._pool[i].frame:Hide()
		end
	end

	function node:SetItems(items)
		self._items = items or {}
		child:SetSize(math.max(1, f:GetWidth()),
			math.max(1, #self._items * rowH))
		self._offset = math.min(self._offset,
			math.max(0, #self._items * rowH - f:GetHeight()))
		self:Rebind()
	end
	function node:GetItems() return self._items end
	function node:GetCount() return #self._items end

	function node:SetSelection(key)
		self._selKey = key
		self:Rebind()
	end
	function node:GetSelection() return self._selKey end

	function node:ScrollToKey(key)
		if not opts.keyFn then return false end
		for i, item in ipairs(self._items) do
			if opts.keyFn(item) == key then
				self:SetOffset((i - 1) * rowH)
				return true
			end
		end
		return false
	end

	function node:onArrange(w, h)
		child:SetWidth(w)
		self:Rebind()
	end
	function node:measure() return 0, 0 end -- pure fill

	return node
end
