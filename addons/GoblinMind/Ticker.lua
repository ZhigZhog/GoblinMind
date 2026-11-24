local _, GM = ...

-- ================================================================
-- Ticker.lua — the detached market tape. One screen-edge bar lists
-- the player's watchlist with live mb and the % move vs the model
-- price — the convention a real tape uses (green = trading above
-- the mark, red = below). The marquee scrolls when the list
-- outgrows the bar and pauses under the cursor, like the real
-- thing. Watchlist + bar position persist in
-- GoblinMindSettings.ticker.
--
--   /goblin ticker            — show/hide the bar
--   /goblin ticker add [link] — add an item (or drop one on the bar)
--   /goblin ticker del [link] — remove it (or right-click its cell)
--   /goblin ticker clear      — empty the tape
--   /goblin ticker reset      — re-dock the bar to the top edge
--
-- Cells are buttons: left-click targets the item (routes into the
-- MARKET page when the AH is open), hover shows the real tooltip,
-- the marquee pauses so you can actually click a moving symbol.
-- ================================================================

GM.Ticker = {}
local T = GM.Ticker

local W = GM.Widgets
local tinsert, tremove, wipe = tinsert, tremove, wipe
local floor, ceil = math.floor, math.ceil
local strtrim, strlower = strtrim, strlower

local SPEED     = 36   -- px/s marquee rate
local GAP       = 30   -- px between cells
local REFRESH   = 20   -- s between price repaints
local MAX_ITEMS = 24
local DEF_W     = 500  -- default strip size
local DEF_H     = 20
local DEF_FS    = 9    -- default cell font
-- settings window reads these to show the EFFECTIVE value —
-- a stored nil means "auto", not "no setting"
T.DEF_W, T.DEF_H, T.DEF_FS = DEF_W, DEF_H, DEF_FS

local bar, sf, child
local cells = {}
local off, lastPaint, dirty = 0, 0, true
local oneW = 0 -- width of one watchlist pass — the wrap distance

local function Store()
	-- GM.db is the SavedVariable root — adds landing anywhere else
	-- would render fine all session and never flush to disk, which
	-- is exactly the failure mode "items don't persist" describes;
	-- fail loudly instead of writing an orphan table
	if not GM.db then
		GM.Print("ticker: settings not loaded yet")
		return { items = {} }
	end
	local st = GM.db.ticker
	if not st then st = {} GM.db.ticker = st end
	if type(st.items) ~= "table" then st.items = {} end
	if st.alpha == nil then st.alpha = 70 end   -- resting dim, % opacity
	if st.hover == nil then st.hover = 100 end  -- lit under the cursor
	return st
end
local function Items() return Store().items end
local function BH() return Store().h or DEF_H end
local function FS() return Store().fs or DEF_FS end

-- ============ cells ============

local function CellText(id)
	local e = GM.ItemEntry and GM.ItemEntry(id)
	local name = (GM.ItemNameOr(id) or ("item " .. id))
		:gsub("[%[%]]", "")
	local mb = e and e.mb
	local price = mb and GM.MoneyShort(mb)
		or GM.CC("textDim") .. "—|r"
	local move = ""
	if mb and e and e.p and e.p > 0 then
		local pct = floor((mb - e.p) / e.p * 100 + 0.5)
		if pct ~= 0 then
			move = " " .. GM.CC(pct > 0 and "pos" or "err")
				.. (pct > 0 and "+" or "") .. pct .. "%|r"
		end
	end
	return GM.CC("textDim") .. name .. "|r " .. price .. move
end

local function PaintCells()
	for _, cell in ipairs(cells) do
		cell.fs:SetText(CellText(cell.id))
	end
	lastPaint = GetTime()
end

local function Build()
	for _, c in ipairs(cells) do c:Hide() c:SetParent(nil) end
	wipe(cells)
	local ids = Items()
	if #ids == 0 then
		child:SetSize(1, BH())
		if not child.hint then
			child.hint = GM.MakeFontString(child, GM.FONT, FS(), "textDim")
			child.hint:SetPoint("LEFT", 4, 0)
		end
		child.hint:SetText("drop items on the tape"
			.. " — or /goblin ticker add [link]")
		child.hint:Show()
		oneW = 0
		return
	end
	if child.hint then child.hint:Hide() end
	local view = sf:GetWidth()
	local totalW = 0
	-- one pass measures the tape; repeat it until a full loop always
	-- covers the viewport so the wrap seam never shows a bare stretch
	for pass = 1, 60 do
		for _, id in ipairs(ids) do
			local cell = CreateFrame("Button", nil, child)
			cell.id = id
			local fs = GM.MakeFontString(cell, GM.FONT, FS(), "text")
			fs:SetPoint("LEFT", 5, 0)
			fs:SetJustifyV("MIDDLE")
			fs:SetWordWrap(false)
			fs:SetText(CellText(id))
			cell.fs = fs
			cell:SetSize(ceil(fs:GetStringWidth()) + 10, BH())
			cell:SetPoint("LEFT", totalW, 0)
			totalW = totalW + cell:GetWidth() + GAP
			cell:EnableMouse(not Store().click)
			cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			cell:SetScript("OnClick", function(_, btn)
				if btn == "RightButton" then
					T.Del(id)
				else
					GM.TargetItem(id)
				end
			end)
			cell:SetScript("OnEnter", function(s)
				bar._hover = true
				GameTooltip:SetOwner(s, "ANCHOR_TOP")
				if GameTooltip.SetItemByID then
					GameTooltip:SetItemByID(id)
				else
					GameTooltip:SetHyperlink("item:" .. id)
				end
				GameTooltip:Show()
			end)
			cell:SetScript("OnLeave", function()
				bar._hover = nil
				GameTooltip:Hide()
			end)
			cell:SetScript("OnReceiveDrag", function()
				local t, did = GetCursorInfo()
				if t == "item" then ClearCursor() T.Add(did) end
			end)
			cells[#cells + 1] = cell
		end
		if pass == 1 then oneW = totalW end
		if pass >= 2 and totalW >= oneW + view then break end
	end
	child:SetSize(math.max(totalW, 1), BH())
	off = 0
	sf:SetHorizontalScroll(0)
end

function T.Paint()
	if not bar then return end
	PaintCells()
end

local function RebuildSoon()
	dirty = true
end

-- ============ watchlist ============

local function Has(id)
	for _, v in ipairs(Items()) do
		if v == id then return true end
	end
end

function T.Add(id, silent)
	if not id or Has(id) then return end
	local it = Items()
	if #it >= MAX_ITEMS then
		GM.Print("ticker full (" .. MAX_ITEMS .. ")"
			.. " — /goblin ticker del [link]")
		return
	end
	it[#it + 1] = id
	RebuildSoon()
	if not silent then
		GM.Print(GM.ItemNameOr(id) .. " on the tape")
	end
end

function T.Del(id)
	local it = Items()
	for i, v in ipairs(it) do
		if v == id then
			tremove(it, i)
			RebuildSoon()
			GM.Print(GM.ItemNameOr(id) .. " off the tape")
			return true
		end
	end
end

-- ============ the bar ============

local function SavePos()
	local p, _, rp, x, y = bar:GetPoint(1)
	Store().pos = { p = p, rp = rp, x = x, y = y }
end

local function Restore()
	local st = Store()
	bar:ClearAllPoints()
	if st.pos then
		local pos = st.pos
		bar:SetSize(st.w or bar:GetWidth(), BH())
		bar:SetPoint(pos.p, UIParent, pos.rp, pos.x, pos.y)
	else
		-- docked: centered strip stacked just under the stock bars
		bar:SetPoint("TOP", UIParent, "TOP", 0, -20)
	end
end

local function ApplyLook()
	if not bar then return end
	local st = Store()
	-- click-through kills every mouse channel on the tape —
	-- hover detection too, so it rests at its idle dim
	local mouse = not st.click
	bar:EnableMouse(mouse)
	sf:EnableMouse(mouse)
	bar._brand:EnableMouse(mouse)
	for _, c in ipairs(cells) do c:EnableMouse(mouse) end
	if st.click then bar:SetAlpha(st.alpha / 100) end
	bar:SetShown(st.on)
end

local function BuildBar()
	bar = CreateFrame("Frame", "GoblinMindTicker", UIParent)
	bar:SetFrameStrata("HIGH") -- above the HUD like an xp-bar strip
	-- one strip among the stock xp/rep bars: centered, ~2/3 screen
	local st = Store()
	bar:SetSize(st.w or DEF_W, BH())
	GM.Panel(bar, "contMedium")
	if GM.ChromePanel then GM.ChromePanel(bar) end
	bar:SetMovable(true)
	bar:SetClampedToScreen(true)
	bar:EnableMouse(true)
	bar:SetScript("OnEnter", function() bar._hover = true end)
	bar:SetScript("OnLeave", function() bar._hover = nil end)
	bar:SetScript("OnReceiveDrag", function()
		local t, id = GetCursorInfo()
		if t == "item" then ClearCursor() T.Add(id) end
	end)

	-- the TICKER tag is the drag handle + usage hint; drag it to
	-- undock the bar anywhere, like a Titan panel pulled off its edge
	local brand = CreateFrame("Button", nil, bar)
	brand:SetSize(40, BH())
	brand:SetPoint("LEFT", 0, 0)
	local bf = GM.MakeFontString(brand, GM.FONT_BOLD, 7, "accent")
	bf:SetPoint("CENTER")
	bf:SetText("TICKER")
	bar._brand = brand
	brand:RegisterForDrag("LeftButton")
	brand:SetScript("OnDragStart", function()
		if Store().locked then return end
		-- collapse the edge-docked two-point anchor to one so the
		-- bar can move freely without a width fight
		local w, l, t = bar:GetWidth(), bar:GetLeft(), bar:GetTop()
		bar:ClearAllPoints()
		bar:SetSize(w, bar:GetHeight()) -- keep configured height
		bar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
			l or 0, t or 0)
		bar:StartMoving()
	end)
	brand:SetScript("OnDragStop", function()
		bar:StopMovingOrSizing()
		SavePos()
	end)
	brand:SetScript("OnReceiveDrag", function()
		local t, id = GetCursorInfo()
		if t == "item" then ClearCursor() T.Add(id) end
	end)
	W.Tip(brand, function()
		return {
			GM.CC("accent") .. "market tape|r",
			"drop items to add · right-click removes",
			"left-click targets · hover pauses the scroll",
			"drag this tag to move · /goblin ticker lock",
			"dim <idle> [hover] · mouse = click-through",
		}
	end)

	sf = CreateFrame("ScrollFrame", nil, bar)
	sf:SetPoint("TOPLEFT", brand, "TOPRIGHT", 2, 0)
	sf:SetPoint("BOTTOMRIGHT", -2, 0)
	sf:EnableMouse(true)
	sf:SetScript("OnReceiveDrag", function()
		local t, id = GetCursorInfo()
		if t == "item" then ClearCursor() T.Add(id) end
	end)
	child = CreateFrame("Frame", nil, sf)
	child:SetSize(1, BH())
	sf:SetScrollChild(child)

	sf:SetScript("OnUpdate", function(_, dt)
		if dirty then dirty = nil Build() end
		if GetTime() - lastPaint > REFRESH then PaintCells() end
		local st = Store()
		local over = not st.click and bar:IsMouseOver()
		-- tape scrolls whenever it has items — Build guarantees
		-- enough passes to cover oneW+view, so the wrap is seamless
		if oneW > 0 and not over then
			off = (off + SPEED * dt) % oneW
			sf:SetHorizontalScroll(off)
		end
		-- ease toward the target dim — resting alpha vs hover alpha
		local want = (over and st.hover or st.alpha) / 100
		local a = bar:GetAlpha()
		if a ~= want then
			bar:SetAlpha(a + (want - a) * math.min(1, dt * 12))
		end
	end)
end

function GM.TickerInit()
	if bar then return end
	BuildBar()
	Restore()
	local st = Store()
	bar:SetAlpha(st.alpha / 100)
	ApplyLook()
end

function T.Apply() ApplyLook() end

-- settings-window surface: raw store for reads, SetDims for the
-- width/height boxes (nil keeps the current value)
function T.Opts() return Store() end

function T.SetDims(w, h)
	local st = Store()
	if w ~= nil then st.w = w > 0 and w or nil end
	if h ~= nil then st.h = h > 0 and h or nil end
	if not bar then return end
	h = st.h or BH()
	bar:SetHeight(h)
	bar._brand:SetHeight(h)
	child:SetHeight(h)
	for _, c in ipairs(cells) do c:SetHeight(h) end
	bar:SetWidth(st.w or DEF_W)
end

-- font size changes cell text metrics — repaint fonts now and
-- flag a rebuild so widths re-measure on the next tick
function T.SetFontSize(n)
	local st = Store()
	st.fs = (n and n > 0) and floor(n) or nil
	if not bar then return end
	for _, c in ipairs(cells) do
		c.fs:SetFont(GM.FONT, FS(), "")
	end
	if child.hint then child.hint:SetFont(GM.FONT, FS(), "") end
	RebuildSoon()
end

-- ============ book repaint + slash ============

GM.AH.bookSubs[#GM.AH.bookSubs + 1] = function() T.Paint() end

GM.Cmd({ "ticker", "tape" }, function(arg, msg)
	arg = strtrim(arg or "")
	local verb = strlower(arg:match("^(%S*)") or "")
	if verb == "" or verb == "on" or verb == "off"
		or verb == "toggle" then
		local st = Store()
		st.on = (verb == "on") or (verb ~= "off" and not st.on)
		T.Apply()
		GM.Print("ticker " .. (st.on and "on" or "off"))
	elseif verb == "add" or verb == "del" or verb == "remove" then
		local id = GM.LinkID(msg) or tonumber(arg:match("(%d+)"))
		if not id then
			GM.Print("ticker " .. verb .. " needs an item"
				.. " — [link] or id")
			return
		end
		if verb == "add" then T.Add(id)
		elseif not T.Del(id) then GM.Print("not on the tape") end
	elseif verb == "lock" or verb == "unlock" then
		local st = Store()
		st.locked = verb == "lock" and not st.locked
		GM.Print("ticker " .. (st.locked and "locked" or "unlocked"))
	elseif verb == "dim" then
		local st = Store()
		local a, b = arg:match("^%S+%s+(%d+)%s*(%d*)")
		if not a then
			GM.Print("ticker dim <idle 0-100> [hover 0-100]"
				.. " — now " .. st.alpha .. "/" .. st.hover)
			return
		end
		st.alpha = math.min(100, tonumber(a))
		if b ~= "" then st.hover = math.min(100, tonumber(b)) end
		GM.Print("ticker dim " .. st.alpha
			.. "% · hover " .. st.hover .. "%")
	elseif verb == "mouse" or verb == "click"
		or verb == "passthrough" then
		local st = Store()
		st.click = not st.click
		ApplyLook()
		GM.Print("ticker " .. (st.click
			and "click-through — the tape ignores the mouse"
			or "interactive"))
	elseif verb == "clear" then
		wipe(Items())
		RebuildSoon()
		GM.Print("tape cleared")
	elseif verb == "reset" or verb == "dock" then
		Store().pos = nil
		if bar then Restore() end
		GM.Print("ticker docked")
	elseif verb == "list" then
		for i, id in ipairs(Items()) do
			GM.Print(i .. ". " .. GM.ItemNameOr(id))
		end
		if #Items() == 0 then GM.Print("tape is empty") end
	else
		GM.Print("ticker — on/off · add/del [link] · lock · dim ·"
			.. " mouse · clear · reset · list")
	end
end, { prefix = true,
	help = "market tape — add/del · lock · dim · mouse · reset" })
