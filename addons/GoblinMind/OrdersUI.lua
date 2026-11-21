local _, GM = ...

-- Writ board window — orders + commits + inbound CODs. All writes
-- stage through GM.Orders into the SV queue (watcher POSTs them);
-- the visible board merges the pulled GoblinMindDB.boards snapshot
-- with the volatile mesh overlay (GM.Orders.live), so peers' posts
-- and claims show in real time and the next pull reconciles them.

GM.OrdersUI = {}
local OU = GM.OrdersUI
local OR = GM.Orders
local ui

local ROWS = 14
local BROWSEROWS = 12
local BROWSE_MAX = 600

local function Panel(parent, x, y, w, h, title)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOPLEFT", x, y)
	p:SetSize(w, h)
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -5)
	t:SetText(title)
	p.title = t
	p.count = GM.MakeFontString(p, GM.FONT, 9, "textDim")
	p.count:SetPoint("TOPRIGHT", -8, -5)
	return p
end

local function MkBtn(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w or 60, h or 18)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "accent")
	b.text:SetPoint("CENTER")
	b.text:SetText(label)
	return b
end

local function MkEdit(parent, w, hint, numeric)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetSize(w, 18)
	e:SetAutoFocus(false)
	e:SetFont(GM.FONT, 10, "")
	GM.Panel(e, "contLowest")
	e.hint = GM.MakeFontString(e, GM.FONT, 9, "textDim")
	e.hint:SetPoint("LEFT", 4, 0)
	e.hint:SetText(hint)
	e:SetScript("OnTextChanged", function(s)
		s.hint:SetShown(s:GetText() == "")
	end)
	e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
	e:SetTextInsets(4, 4, 0, 0)
	return e
end

local GoldText = GM.MoneyShort

local function has(t, v)
	for _, x in ipairs(t) do if x == v then return true end end
	return false
end

local function Build()
	if ui then return end
	ui = { expanded = {} }   -- order-id → nested-claims open
	local f = GM.Widgets.Window({
		name = "GoblinMindOrders", title = "WRITS",
		w = 720, h = 540, tab = "orders",
	})
	ui.frame = f

	-- board switcher
	ui.boardBar = GM.MakeFontString(f, GM.FONT_BOLD, 10, "secondary")
	ui.boardBar:SetPoint("TOPLEFT", 12, -30)
	ui.boardBtns = {}
	ui.board = nil

	-- hint line: flush cadence + reserve warning
	ui.hint = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.hint:SetPoint("TOPRIGHT", -12, -32)

	-- ===== POST bar: item strip on top, inputs below =====
	local post = Panel(f, 10, -54, 700, 84, "POST BUY ORDER")
	ui.post = post

	-- the planner's item-target strip — drop retargets the shared
	-- item channel (planner stats show the market price)
	local strip = CreateFrame("Button", nil, post)
	strip:SetPoint("TOPLEFT", 8, -14)
	strip:SetSize(684, 36)
	GM.Panel(strip, "contHigh")
	local iconBox = CreateFrame("Frame", nil, strip)
	iconBox:SetPoint("LEFT", 4, 0)
	iconBox:SetSize(32, 32)
	GM.Panel(iconBox, "contLowest")
	ui.icon = iconBox:CreateTexture(nil, "ARTWORK")
	ui.icon:SetSize(30, 30)
	ui.icon:SetPoint("CENTER")
	ui.iconBtn = CreateFrame("Button", nil, iconBox)
	ui.iconBtn:SetAllPoints()
	ui.iconBtn:SetScript("OnEnter", function(s)
		if not s.itemID then return end
		GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(s.itemID)
		else
			GameTooltip:SetHyperlink("item:" .. s.itemID)
		end
		GameTooltip:Show()
	end)
	ui.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	ui.itemName = GM.MakeFontString(strip, GM.FONT_MED, 11, "text")
	ui.itemName:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 8, -3)
	ui.itemName:SetWidth(400)
	ui.itemName:SetWordWrap(false)
	ui.itemName:SetJustifyH("LEFT")
	ui.itemSub = GM.MakeFontString(strip, GM.FONT, 9, "textDim")
	ui.itemSub:SetPoint("TOPLEFT", ui.itemName, "BOTTOMLEFT", 0, -3)
	ui.itemSub:SetJustifyH("LEFT")
	local function DropItem()
		local infoType, itemID, link = GetCursorInfo()
		if infoType ~= "item" then return end
		ClearCursor()
		-- shared target channel — planner stays in sync (its stats
		-- pane shows the market price) but isn't force-popped over us
		GM.PlanQueue.SetItem(itemID, link)
		OU.SetItem(itemID)
	end
	strip:EnableMouse(true)
	strip:SetScript("OnReceiveDrag", DropItem)
	strip:SetScript("OnClick", function()
		if IsModifiedClick() then
			GM.ModifiedItemClick(ui.iconBtn.itemID)
		elseif CursorHasItem() then
			DropItem()
		end
	end)
	ui.iconBtn:SetScript("OnReceiveDrag", DropItem)
	ui.iconBtn:SetScript("OnClick", function()
		if IsModifiedClick() then
			GM.ModifiedItemClick(ui.iconBtn.itemID)
		elseif CursorHasItem() then
			DropItem()
		end
	end)

	-- input row below the strip
	ui.qtyE = MkEdit(post, 60, "qty")
	ui.qtyE:SetPoint("BOTTOMLEFT", 10, 8)
	ui.priceE = GM.Widgets.GoldEdit(post, 118)
	ui.priceE:SetPoint("LEFT", ui.qtyE, "RIGHT", 6, 0)
	ui.ttlE = MkEdit(post, 50, "hrs")
	ui.ttlE:SetPoint("LEFT", ui.priceE, "RIGHT", 6, 0)
	ui.postBtn = MkBtn(post, "POST", 56)
	ui.postBtn:SetPoint("LEFT", ui.ttlE, "RIGHT", 8, 0)
	ui.postMsg = GM.MakeFontString(post, GM.FONT, 9, "textDim")
	ui.postMsg:SetPoint("LEFT", ui.postBtn, "RIGHT", 8, 0)
	ui.postMsg:SetPoint("RIGHT", post, "RIGHT", -8, 0)
	ui.postMsg:SetJustifyH("LEFT")
	ui.postMsg:SetWordWrap(false)
	ui.postBtn:SetScript("OnClick", function() OU.Post() end)
	OU.SetItem(nil)

	-- ===== orders list / item browser (same rect, mode toggles) =====
	-- column grid: [fold 0-16][icon 18][item 36][qty 190][price 258]
	-- [poster 348][status 452][action right] — headers label the
	-- same x's so the eye learns the grid once
	local list = Panel(f, 10, -144, 700, 240, "BOARD")
	ui.listP = list
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, d)
		if ui.browseMode then
			ui.browseScroll = math.max(0,
				(ui.browseScroll or 0) - d * 3)
		else
			ui.scroll = math.max(0, (ui.scroll or 0) - d * 3)
		end
		OU.Refresh()
	end)
	ui.scroll = 0
	ui.browseScroll = 0
	-- mode toggle rides the panel header row — count folds into the
	-- title text so the corner is free for it
	ui.modeBtn = MkBtn(list, "FIND ITEM", 66, 13)
	ui.modeBtn:SetPoint("TOPRIGHT", -4, -2)
	ui.modeBtn:SetScript("OnClick", function()
		ui.browseMode = not ui.browseMode
		ui.browseScroll = 0
		OU.Refresh()
	end)
	-- claim-units box lives in the header next to the mode toggle —
	-- it feeds the CLAIM buttons in the rows, so it sits where the
	-- action's affordances are instead of floating at the corner
	ui.claimQty = MkEdit(list, 40, "units")
	ui.claimQty:SetPoint("TOPRIGHT", ui.modeBtn, "TOPLEFT", -4, -1)
	ui.claimQty:SetText("1")
	ui.claimLbl = GM.MakeFontString(list, GM.FONT, 9, "textDim")
	ui.claimLbl:SetPoint("RIGHT", ui.claimQty, "LEFT", -4, -1)
	ui.claimLbl:SetText("claim")
	-- board titles can outgrow the header — clip, don't collide
	ui.listP.title:SetWidth(340)
	ui.listP.title:SetWordWrap(false)
	-- column headers (board mode only)
	ui.colHeads = {}
	local heads = { { 36, "ITEM" }, { 190, "QTY" }, { 258, "PRICE" },
		{ 348, "POSTER" }, { 452, "STATUS" } }
	for i, h in ipairs(heads) do
		local fs = GM.MakeFontString(list, GM.FONT_BOLD, 8, "secondary")
		fs:SetPoint("TOPLEFT", 8 + h[1], -16)
		fs:SetText(h[2])
		ui.colHeads[i] = fs
	end
	-- browser search box + rows (hidden unless browseMode)
	ui.search = MkEdit(list, 220, "filter by name or item id")
	ui.search:SetPoint("TOPLEFT", 8, -16)
	-- SetScript replaces MkEdit's own handler — keep the hint
	-- toggle or it draws under the typed text
	ui.search:SetScript("OnTextChanged", function(s)
		s.hint:SetShown(s:GetText() == "")
		ui.browseScroll = 0
		OU.Refresh()
	end)
	ui.search:Hide()
	ui.browseRows = {}
	for i = 1, BROWSEROWS do
		local r = CreateFrame("Button", nil, list)
		r:SetSize(684, 15)
		r:SetPoint("TOPLEFT", 8, -40 - (i - 1) * 15)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(13, 13)
		r.icon:SetPoint("LEFT", 0, 0)
		r.name = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.name:SetPoint("LEFT", 18, 0)
		r.name:SetWidth(330)
		r.name:SetWordWrap(false)
		r.name:SetJustifyH("LEFT")
		r.price = GM.MakeFontString(r, GM.FONT, 10, "textDim")
		r.price:SetPoint("LEFT", 356, 0)
		r.price:SetWidth(110)
		r.price:SetJustifyH("LEFT")
		r.idfs = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.idfs:SetPoint("RIGHT", -4, 0)
		r:SetScript("OnEnter", function(s)
			if not s.itemID then return end
			GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
			if GameTooltip.SetItemByID then
				GameTooltip:SetItemByID(s.itemID)
			else
				GameTooltip:SetHyperlink("item:" .. s.itemID)
			end
			GameTooltip:Show()
		end)
		r:SetScript("OnLeave", function() GameTooltip:Hide() end)
		r:SetScript("OnClick", function(s)
			if not s.itemID then return end
			if IsModifiedClick() then
				GM.ModifiedItemClick(s.itemID)
				return
			end
			-- shared target channel — planner retargets too — then
			-- the strip shows the same pick
			local _, link = GetItemInfo and GetItemInfo(s.itemID)
			GM.PlanQueue.SetItem(s.itemID, link)
			OU.SetItem(s.itemID)
		end)
		r:Hide()
		ui.browseRows[i] = r
	end
	ui.rows = {}
	for i = 1, ROWS do
		local r = CreateFrame("Frame", nil, list)
		r:SetSize(684, 15)
		r:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 15)
		-- nested-commit tint: subtle lift off the contLowest list so
		-- expanded claims read as a sub-block, not sibling orders
		r.cbg = r:CreateTexture(nil, "BACKGROUND")
		r.cbg:SetPoint("TOPLEFT", 16, 0)
		r.cbg:SetPoint("BOTTOMRIGHT", 0, 0)
		r.cbg:SetColorTexture(GM.RGB("contLow"))
		r.cbg:Hide()
		r.fold = MkBtn(r, "+", 14, 13)
		r.fold:SetPoint("LEFT", 0, 0)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(13, 13)
		r.icon:SetPoint("LEFT", 18, 0)
		r.item = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.item:SetPoint("LEFT", 36, 0)
		r.item:SetWidth(148)
		r.item:SetWordWrap(false)
		r.qty = GM.MakeFontString(r, GM.FONT, 10, "textDim")
		r.qty:SetPoint("LEFT", 190, 0)
		r.qty:SetWidth(62)
		r.price = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.price:SetPoint("LEFT", 258, 0)
		r.price:SetWidth(84)
		r.poster = GM.MakeFontString(r, GM.FONT, 10, "textDim")
		r.poster:SetPoint("LEFT", 348, 0)
		r.poster:SetWidth(98)
		r.poster:SetWordWrap(false)
		r.status = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.status:SetPoint("LEFT", 452, 0)
		r.status:SetWidth(170)
		r.status:SetWordWrap(false)
		r.claim = MkBtn(r, "CLAIM", 48, 13)
		r.claim:SetPoint("RIGHT", -4, 0)
		-- nested-commit paint elements (hidden unless the row
		-- renders a claim under an expanded order)
		r.ctxt = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.ctxt:SetPoint("LEFT", 36, 0)
		r.ctxt:SetWidth(390)
		r.ctxt:SetWordWrap(false)
		r.ctxt:SetJustifyH("LEFT")
		r.cforce = MkBtn(r, "FORCE", 46, 13)
		r.cforce:SetPoint("RIGHT", -2, 0)
		r.cdeny = MkBtn(r, "DENY", 42, 13)
		r.cdeny:SetPoint("RIGHT", -50, 0)
		r.cacc = MkBtn(r, "ACC", 34, 13)
		r.cacc:SetPoint("RIGHT", -94, 0)
		ui.rows[i] = r
	end

	-- ===== my commits + inbound COD =====
	local mine = Panel(f, 10, -390, 342, 146, "MY COMMITS")
	ui.mineP = mine
	mine.hint = GM.MakeFontString(mine, GM.FONT, 9, "textDim")
	mine.hint:SetPoint("LEFT", mine.title, "RIGHT", 6, 0)
	mine.hint:SetText("— items you owe, mail COD")
	ui.mineEmpty = GM.MakeFontString(mine, GM.FONT, 9, "textDim")
	ui.mineEmpty:SetPoint("CENTER", 0, -6)
	ui.mineEmpty:SetText("no open commits — claim an order above")
	ui.mineEmpty:Hide()
	ui.mineRows = {}
	for i = 1, 6 do
		local r = CreateFrame("Frame", nil, mine)
		r:SetSize(326, 20)
		r:SetPoint("TOPLEFT", 8, -18 - (i - 1) * 21)
		r.txt = GM.MakeFontString(r, GM.FONT, 9, "text")
		r.txt:SetPoint("LEFT", 0, 0)
		r.txt:SetWidth(240)
		r.txt:SetWordWrap(false)
		r.send = MkBtn(r, "SEND COD", 66)
		r.send:SetPoint("RIGHT", 0, 0)
		ui.mineRows[i] = r
	end

	local inc = Panel(f, 362, -390, 348, 146, "INBOUND CODs")
	ui.incP = inc
	inc.hint = GM.MakeFontString(inc, GM.FONT, 9, "textDim")
	inc.hint:SetPoint("LEFT", inc.title, "RIGHT", 6, 0)
	inc.hint:SetText("— payment due on delivery")
	ui.incEmpty = GM.MakeFontString(inc, GM.FONT, 9, "textDim")
	ui.incEmpty:SetPoint("CENTER", 0, -6)
	ui.incEmpty:SetText("nothing inbound")
	ui.incEmpty:Hide()
	ui.incRows = {}
	for i = 1, 6 do
		local r = CreateFrame("Frame", nil, inc)
		r:SetSize(332, 20)
		r:SetPoint("TOPLEFT", 8, -18 - (i - 1) * 21)
		r.txt = GM.MakeFontString(r, GM.FONT, 9, "text")
		r.txt:SetPoint("LEFT", 0, 0)
		r.txt:SetWidth(196)
		r.txt:SetWordWrap(false)
		r.acc = MkBtn(r, "PAY", 40)
		r.acc:SetPoint("RIGHT", -46, 0)
		r.rej = MkBtn(r, "REJ", 40)
		r.rej:SetPoint("RIGHT", 0, 0)
		ui.incRows[i] = r
	end
end

function OU.SetItem(itemID)
	ui.itemID = itemID
	ui.iconBtn.itemID = itemID
	if not itemID then
		ui.icon:Hide()
		ui.itemName:SetText(GM.CC("textDim")
			.. "drop an item — or FIND ITEM below to browse|r")
		ui.itemSub:SetText("")
		return
	end
	-- planner's icon path: instant icon first, GetItemInfo fallback
	local icon = C_Item and C_Item.GetItemIconByID
		and C_Item.GetItemIconByID(itemID)
	if not icon and GetItemInfo then
		icon = select(10, GetItemInfo(itemID))
	end
	if icon then ui.icon:SetTexture(icon) ui.icon:Show()
	else ui.icon:Hide() end
	ui.itemName:SetText(GM.ItemName(itemID))
	ui.itemName:SetTextColor(GM.NameColor(itemID))
	-- market value from the universal source pipeline — same number
	-- the planner/tooltip show
	local row = GM.ItemEntry and GM.ItemEntry(itemID)
	local mkt = row and (row.mkt or row.mb or row.p)
	ui.itemSub:SetText(mkt
		and ("market " .. GoldText(mkt) .. " ea")
		or "no market data for this item")
end

function OU.Post()
	local board = ui.board
	if not board then
		ui.postMsg:SetText("no board — join one first (/goblin board <name>)")
		return
	end
	local itemID = ui.itemID
	local qty = tonumber(ui.qtyE:GetText())
	local ppu = ui.priceE:GetCopper()
	local hrs = tonumber(ui.ttlE:GetText())
	if not itemID then
		ui.postMsg:SetText("drop an item on the strip first")
		return
	end
	if not (qty and ppu) or qty < 1 or ppu <= 0 then
		ui.postMsg:SetText("qty + price required")
		return
	end
	local ttl = hrs and math.floor(hrs * 3600) or nil
	local rid = OR.Post(board, itemID, math.floor(qty), ppu, ttl)
	OR.ReserveAdd(rid, ppu * math.floor(qty), board)
	if not OR.PurseCovers(0) then
		ui.postMsg:SetText(GM.CC("warn")
			.. "posted — UNDERFUNDED (purse < reserves)|r")
	else
		ui.postMsg:SetText("posted " .. rid .. " — live on mesh + next flush")
	end
	ui.qtyE:SetText(""); ui.priceE:SetCopper(nil)
end

local function OrderRow(r, o, me)
	-- overlay-only ops carry their verb — pending post/cancel/claim/...
	local pend = o._pendOp
	r.cbg:Hide()
	r.ctxt:Hide(); r.cacc:Hide(); r.cdeny:Hide(); r.cforce:Hide()
	local ncm = #(o.commits or {})
	r.fold:SetText(ui.expanded[o.id] and "-" or "+")
	r.fold:SetShown(ncm > 0)
	r.fold:SetScript("OnClick", function()
		ui.expanded[o.id] = not ui.expanded[o.id] or nil
		OU.Refresh()
	end)
	local icon = GM.ItemIcon(o.itemID)
	if icon then
		r.icon:SetTexture(icon)
		r.icon:SetDesaturated(pend and true or false)
		r.icon:SetAlpha(pend and 0.5 or 1)
		r.icon:Show()
	else r.icon:Hide() end
	r.item:SetText(GM.ItemNameOr(o.itemID))
	-- and/or truncates GM.RGB's r,g,b to the first value — keep the
	-- multi-return calls at tail position per branch
	if pend then r.item:SetTextColor(GM.RGB("textDim"))
	else r.item:SetTextColor(GM.NameColor(o.itemID)) end
	r.qty:SetText(string.format("%d/%d (+%d)", o.qtyFilled or 0,
		o.qtyTotal or 0, o.remaining or 0))
	r.price:SetText(GoldText(o.pricePerUnit or 0) .. " ea")
	r.price:SetTextColor(GM.RGB(pend and "textDim" or "text"))
	local tag = o.poster or "?"
	if o.posterUUID == me then tag = tag .. " |cff5fd35f(you)|r" end
	r.poster:SetText(tag)
	-- short flag tokens — the column is narrow and flags used to
	-- collide; pending is informational (dim), underfunded is the
	-- actual warning (warn)
	local flags = {}
	if pend then flags[#flags + 1] = "pend:" .. pend end
	if not o.backed then flags[#flags + 1] = "unfunded" end
	if o.posterStats and (o.posterStats.fills_rejected or 0) > 0 then
		flags[#flags + 1] = "rej:" .. o.posterStats.fills_rejected
	end
	r.status:SetText(table.concat(flags, " "))
	if not o.backed then r.status:SetTextColor(GM.RGB("warn"))
	else r.status:SetTextColor(GM.RGB("textDim")) end
	-- a cancel in flight leaves nothing to act on — re-clicking CANCEL
	-- would stage a second op, CLAIM-ing it is meaningless
	r.claim:SetShown(pend ~= "cancel")
	r.claim:SetScript("OnClick", function()
		if o.posterUUID == me then
			-- CANCEL always cancels the whole order — the units box
			-- belongs to CLAIM; sharing it made every cancel a
			-- PARTIAL cancel of N units and "cancelled" orders kept
			-- coming back on the next pull
			OR.Cancel(o.board, o.id, nil)
			OR.ReserveRelease(o.id)
			ui.postMsg:SetText("cancel staged (flush to apply)")
		else
			local units = math.max(1,
				math.floor(tonumber(ui.claimQty:GetText()) or 1))
			OR.Claim(o.board, o.id, units)
			ui.postMsg:SetText("claim staged (flush to apply)")
		end
		OU.Refresh()
	end)
	r.claim.text:SetText(o.posterUUID == me and "CANCEL" or "CLAIM")
	r:Show()
end

-- a claim nested under its expanded order. Poster of the order
-- gets accept/deny/force on live claims; anyone else sees the
-- claim's state and the vendor's rating.
local function CommitRow(r, o, c, me)
	r.icon:Hide(); r.fold:Hide(); r.claim:Hide()
	r.item:SetText(""); r.qty:SetText(""); r.price:SetText("")
	r.poster:SetText(""); r.status:SetText("")
	-- indented tinted sub-block + "»" leader — reads as nested
	-- under the parent order, not a sibling row
	r.cbg:Show()
	local flag = c._pendOp and ("· pending " .. c._pendOp)
		or (c.accepted and "· accepted") or ""
	local stat = c.crafterStats or {}
	local res = (stat.commits_filled or 0)
		+ (stat.commits_forced or 0)
		+ (stat.commits_expired or 0)
	-- completed-claim % once history exists; denied and voluntary
	-- releases don't count either way — that's the design. Colored
	-- so reliability reads at a glance (pos/warn/err tiers, dim
	-- while the vendor is still unknown)
	local rating, rkey
	if res >= 3 then
		local pct = math.floor(
			(stat.commits_filled or 0) * 100 / res + 0.5)
		rating = pct .. "%"
		rkey = pct >= 80 and "pos" or (pct >= 50 and "warn" or "err")
	else
		rating = "new"
		rkey = "textDim"
	end
	rating = GM.CC(rkey) .. rating .. "|r"
	local left = (c.expires or 0) - time()
	r.ctxt:SetText(string.format("» %s%s  x%d/%d  %s  %s  %s%s",
		c.crafter or "?",
		c.crafterUUID == me and " |cff5fd35f(you)|r" or "",
		c.unitsFilled or 0, c.units or 0,
		rating,
		left > 0 and string.format("%dh left",
			math.ceil(left / 3600)) or "expired",
		c.state ~= "active" and (c.state .. "  ") or "", flag))
	local mine = o.posterUUID == me and c.state == "active"
		and not c._pendOp
	r.cacc:SetShown(mine and not c.accepted)
	r.cdeny:SetShown(mine)
	r.cforce:SetShown(mine)
	r.cacc:SetScript("OnClick", function()
		OR.Accept(o.board, o.id, c.id)
		ui.postMsg:SetText("accept staged (flush to apply)")
		OU.Refresh()
	end)
	r.cdeny:SetScript("OnClick", function()
		OR.Deny(o.board, o.id, c.id)
		ui.postMsg:SetText("deny staged — no stat hit")
		OU.Refresh()
	end)
	r.cforce:SetScript("OnClick", function()
		OR.Force(o.board, o.id, c.id)
		ui.postMsg:SetText("force cancel staged — counts against vendor")
		OU.Refresh()
	end)
	r.ctxt:Show()
	r:Show()
end

-- every item the backend has ever priced, as {id, name, lname}
-- sorted by name (unnamed items sink to the bottom, still
-- reachable via the numeric filter). Rebuilt when the emit
-- changes; names resolve async via ReqOnce and a later refresh
-- picks them up.
local function BrowseIndex()
	local gen = OR.Generated()
	if ui.idxGen == gen and ui.idx then return ui.idx end
	local items = OR.Catalog() or {}
	local idx = {}
	for id in pairs(items) do
		local n = GM.ItemName(id)
		idx[#idx + 1] = { id = id, name = n,
			lname = (n or ""):lower() }
	end
	table.sort(idx, function(a, b)
		if (a.name ~= nil) ~= (b.name ~= nil) then
			return a.name ~= nil
		end
		if a.name and b.name and a.name ~= b.name then
			return a.name < b.name
		end
		return a.id < b.id
	end)
	ui.idx, ui.idxGen = idx, gen
	return idx
end

local function BrowsePaint()
	for i = 1, ROWS do ui.rows[i]:Hide() end
	ui.listP.title:SetText("FIND ITEM")
	ui.listP.count:SetText("")
	local q = (ui.search:GetText() or ""):lower():gsub("^%s+", "")
		:gsub("%s+$", "")
	local qid = tonumber(q)
	local idx = BrowseIndex()
	local hits = {}
	if q == "" then
		hits = idx
	else
		for i = 1, #idx do
			local e = idx[i]
			if (e.lname ~= "" and e.lname:find(q, 1, true))
				or (qid and tostring(e.id):find(q, 1, true)) then
				hits[#hits + 1] = e
				if #hits >= BROWSE_MAX then break end
			end
		end
	end
	local more = #idx - #hits
	ui.listP.title:SetText("FIND ITEM — " .. (q == ""
		and (#idx .. " items")
		or (#hits .. (more > 0 and "+" .. more or "") .. " match")))
	for i = 1, BROWSEROWS do
		local r = ui.browseRows[i]
		local e = hits[i + (ui.browseScroll or 0)]
		if e then
			r.itemID = e.id
			local icon = GM.ItemIcon(e.id)
			if icon then r.icon:SetTexture(icon) r.icon:Show()
			else r.icon:Hide() end
			r.name:SetText(e.name or ("item " .. e.id))
			r.name:SetTextColor(GM.NameColor(e.id))
			local row = GM.ItemEntry and GM.ItemEntry(e.id)
			local mkt = row and (row.mkt or row.mb or row.p)
			r.price:SetText(mkt and GoldText(mkt) .. " ea" or "—")
			r.idfs:SetText("#" .. e.id)
			r:Show()
		else r:Hide() end
	end
end

function OU.Refresh()
	if not ui then return end
	OR.ClearAcked()
	OR.ReserveSync()

	-- board buttons
	local boards = OR.Boards()
	if not ui.board or not has(boards, ui.board) then
		ui.board = boards[1]
	end
	for i, b in ipairs(ui.boardBtns) do b:Hide() end
	ui.boardBtns = {}
	ui.boardBar:SetText("boards:")
	local bx = 62
	for i, b in ipairs(boards) do
		local w = 10 + #b * 8
		local btn = MkBtn(ui.frame, b, w)
		btn:SetPoint("TOPLEFT", bx, -27)
		bx = bx + w + 6
		if b ~= ui.board then
			btn.text:SetTextColor(GM.RGB("textDim"))
		end
		local bn = b
		btn:SetScript("OnClick", function()
			ui.board = bn; ui.scroll = 0; OU.Refresh()
		end)
		ui.boardBtns[i] = btn
	end

	-- hint: reserve state + refresh semantics
	local res = OR.ReserveTotal()
	local h = "live via mesh · pull reconciles"
	if res > 0 then
		h = ("reserved %s — "):format(GoldText(res)) .. h
	end
	if OR.Underfunded() then
		h = GM.CC("warn") .. "UNDERFUNDED RESERVES — " .. h .. "|r"
	end
	ui.hint:SetText(h)

	-- orders list / item browser
	ui.modeBtn.text:SetText(ui.browseMode and "BOARD" or "FIND ITEM")
	ui.search:SetShown(ui.browseMode)
	ui.claimQty:SetShown(not ui.browseMode)
	ui.claimLbl:SetShown(not ui.browseMode)
	for i = 1, #ui.colHeads do
		ui.colHeads[i]:SetShown(not ui.browseMode)
	end
	if ui.browseMode then
		BrowsePaint()
	else
		for i = 1, BROWSEROWS do ui.browseRows[i]:Hide() end
		local orders = ui.board and OR.Orders(ui.board) or {}
		-- flatten: each expanded order's commits nest under it and
		-- consume row-pool slots; scroll just pages the flat list
		local disp = {}
		for _, o in ipairs(orders) do
			disp[#disp + 1] = o
			if ui.expanded and ui.expanded[o.id] then
				for _, c in ipairs(o.commits or {}) do
					disp[#disp + 1] = { order = o, commit = c }
				end
			end
		end
		ui.listP.title:SetText(
			"BOARD — " .. tostring(ui.board or "none")
				.. " · " .. #orders .. " open")
		ui.listP.count:SetText("")
		local me = OR.MyUUID()
		for i = 1, ROWS do
			local r = ui.rows[i]
			local e = disp[i + (ui.scroll or 0)]
			if not e then
				r:Hide()
			elseif e.commit then
				CommitRow(r, e.order, e.commit, me)
			else
				OrderRow(r, e, me)
			end
		end
	end

	-- my commits
	local mine = ui.board and OR.MyCommits(ui.board) or {}
	ui.mineP.count:SetText(tostring(#mine))
	ui.mineEmpty:SetShown(#mine == 0)
	for i = 1, 6 do
		local r = ui.mineRows[i]
		local mc = mine[i]
		if mc then
			local c, o = mc.commit, mc.order
			local left = (c.expires or 0) - time()
			local cpend = c._pendOp or (c._live and "claim")
			local cflag = cpend and (" — pending " .. cpend)
				or (c.accepted and " — accepted" or "")
			r.txt:SetText(string.format("%s x%d -> %s | %s (%s)%s",
				GM.ItemNameOr(o.itemID), c.units or 0, o.poster or "?",
				GoldText((c.unitPrice or 0) * (c.units or 0)),
				left > 0 and string.format("%dh left",
					math.ceil(left / 3600)) or "expired", cflag))
			r.txt:SetTextColor(GM.RGB(cpend and "textDim" or "text"))
			r.send:SetScript("OnClick", function()
				if GM.MailUI and GM.MailUI.PrepareWrit then
					GM.MailUI.PrepareWrit(o.poster, o.itemID,
						(c.units or 1) - (c.unitsFilled or 0),
						c.unitPrice or 0)
				else
					GM.Print("MailUI unavailable")
				end
			end)
			r:Show()
		else r:Hide() end
	end

	-- inbound CODs
	local hits = OR.InboxCODs()
	ui.incP.count:SetText(tostring(#hits))
	ui.incEmpty:SetShown(#hits == 0)
	for i = 1, 6 do
		local r = ui.incRows[i]
		local hit = hits[i]
		if hit then
			r.txt:SetText(string.format("%s: %s | %s",
				hit.sender or "?", hit.subject or "?",
				GoldText(hit.cod or 0)))
			if not hit.order then
				r.txt:SetText(r.txt:GetText() .. " |cffd35f5f(unmatched)|r")
			end
			r.acc:SetScript("OnClick", function()
				if hit.order and OR.AcceptCOD(hit) then
					ui.postMsg:SetText("fill staged (flush to apply)")
					OR.ReserveRetire(hit.order.id, hit.cod)
				end
				OU.Refresh()
			end)
			r.rej:SetScript("OnClick", function()
				if hit.order and OR.RejectCOD(hit) then
					ui.postMsg:SetText("reject staged (flush to apply)")
				end
				OU.Refresh()
			end)
			r:Show()
		else r:Hide() end
	end
end

function OU.Show()
	Build()
	ui.frame:Show()
	OU.Refresh()
end

function OU.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function OU.Toggle()
	if ui and ui.frame and ui.frame:IsShown() then OU.Hide()
	else OU.Show() end
end

-- names/icons resolve async — repaint when a requested item lands
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then OU.Refresh() end
	end)
end
