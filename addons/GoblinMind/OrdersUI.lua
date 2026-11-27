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

-- list views: orders (board list / MY BUY ORDERS) -> find (item
-- browser for posting) -> search (distributed mesh item query)
local VIEW_NEXT = { orders = "find", find = "search",
	search = "orders" }
local VIEW_LBL = { orders = "FIND ITEM", find = "SEARCH",
	search = "« BOARD" }

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

	-- live board refresh — the file copy only moves at /reload;
	-- this asks a peer on the same tracker for its newest pull.
	-- Fixed anchor: ui.hint's left edge slides with text length.
	ui.refreshBtn = MkBtn(f, "REFRESH", 66, 15)
	ui.refreshBtn:SetPoint("TOPRIGHT", -12, -30)
	ui.refreshBtn:SetScript("OnClick", function()
		ui.hint:SetText(OR.RefreshBoard(ui.board))
	end)

	-- hint line: flush cadence + reserve warning (right of REFRESH)
	ui.hint = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.hint:SetPoint("RIGHT", ui.refreshBtn, "LEFT", -8, 0)

	-- craft tabs: SHOPS / MY WRITS are WritsUI panes covering the
	-- orders content rect; ORDERS is this window's original content
	ui.tabHost = CreateFrame("Frame", nil, f)
	ui.tabHost:SetSize(3 * 62, 20)
	ui.craftTabs = GM.Widgets.PageTabs(ui.tabHost, {
		{ "shops", "SHOPS" }, { "writs", "MY WRITS" },
		{ "orders", "ORDERS" } }, function(key)
		OU.SetTab(key)
	end)
	ui.tab = GM.db.craftTab or "auto"
	ui.ordNodes = {}

	-- ===== POST bar: item strip on top, inputs below =====
	local post = Panel(f, 10, -76, 700, 84, "POST BUY ORDER")
	ui.post = post

	-- shared slot widget — drop retargets the shared item channel
	-- (planner stats show the market price) and this order
	local strip = GM.Widgets.ItemSlot(post, {
		w = 684, h = 36, icon = 32,
		nameSize = 11, subSize = 9,
		hint = "drop an item — or FIND ITEM below to browse",
		onItem = function(id, link)
			GM.PlanQueue.SetItem(id, link)
			OU.SetItem(id)
		end,
	})
	strip:SetPoint("TOPLEFT", 8, -14)
	-- the paint path in OU.SetItem writes these fields directly
	ui.icon, ui.iconBtn = strip.icon, strip.iconBtn
	ui.itemName, ui.itemSub = strip.name, strip.sub

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
	local list = Panel(f, 10, -166, 700, 216, "BOARD")
	ui.listP = list
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, d)
		if ui.view ~= "orders" then
			ui.browseScroll = math.max(0,
				(ui.browseScroll or 0) - d * 3)
		else
			ui.scroll = math.max(0, (ui.scroll or 0) - d * 3)
		end
		OU.Refresh()
	end)
	ui.scroll = 0
	ui.browseScroll = 0
	ui.view = "orders"
	ui.mineOnly = true
	ui.searchItem = nil
	-- view toggle rides the panel header row — cycles
	-- MY ORDERS -> FIND ITEM -> SEARCH -> back. Count folds into
	-- the title text so the corner is free for it
	ui.modeBtn = MkBtn(list, "FIND ITEM", 66, 13)
	ui.modeBtn:SetPoint("TOPRIGHT", -4, -2)
	ui.modeBtn:SetScript("OnClick", function()
		ui.view = VIEW_NEXT[ui.view] or "orders"
		ui.browseScroll = 0
		if ui.view ~= "search" then ui.searchItem = nil end
		OU.Refresh()
	end)
	-- MINE filter — the MY BUY ORDERS view: only my postings,
	-- aggregated across every board. Default on — the window's
	-- primary job is your orders, the full board is one click away
	ui.mineBtn = MkBtn(list, "MINE", 34, 13)
	ui.mineBtn:SetPoint("TOPRIGHT", ui.modeBtn, "TOPLEFT", -3, -1)
	ui.mineBtn:SetScript("OnClick", function()
		ui.mineOnly = not ui.mineOnly
		ui.scroll = 0
		OU.Refresh()
	end)
	-- claim-units box lives in the header next to the mode toggle —
	-- it feeds the CLAIM buttons in the rows, so it sits where the
	-- action's affordances are instead of floating at the corner
	ui.claimQty = MkEdit(list, 40, "units")
	ui.claimQty:SetPoint("TOPRIGHT", ui.mineBtn, "TOPLEFT", -4, -1)
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
	-- browser search box + rows (hidden in the orders view)
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
	-- back-to-picker in search results — bottom edge, clear of the
	-- column headers and the search box that share the top row
	ui.searchBack = MkBtn(list, "« ITEMS", 52, 13)
	ui.searchBack:SetPoint("BOTTOMLEFT", 6, 3)
	ui.searchBack:SetScript("OnClick", function()
		ui.searchItem = nil
		ui.browseScroll = 0
		OU.Refresh()
	end)
	ui.searchBack:Hide()
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
				GM.Ops.Click(s.itemID)
				return
			end
			if ui.view == "search" then
				-- mesh search: pick the item, broadcast the query,
				-- results list takes over the rows
				ui.searchItem = s.itemID
				OR.SearchItem(s.itemID)
				ui.browseScroll = 0
				OU.Refresh()
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
	local mine = Panel(f, 10, -388, 342, 146, "MY COMMITS")
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

	local inc = Panel(f, 362, -388, 348, 146, "INBOUND CODs")
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

	-- WritsUI builds its two panes into the same content rect —
	-- hand anchors below cover the post+list+pair union; under the
	-- managed layout they're sibling fill nodes shown instead of
	-- the orders nodes
	if GM.WritsUI then
		ui.shopsP, ui.writsP = GM.WritsUI.Build(f)
	end

	-- ============ GoblinUI managed layout ============
	-- the window was a hand-laid column: header strip (board label +
	-- dynamic board btns + REFRESH), POST panel, BOARD list, then a
	-- bottom pair. The header strip moves into a managed host frame
	-- (its pieces re-anchor to the host, dynamic btns anchor off it),
	-- the panels adopt as column leaves — the BOARD list fills slack,
	-- the bottom pair rows COMMITS fixed / INBOUND fill. Craft tabs
	-- add a strip row under the header and toggle node visibility:
	-- orders nodes collapse, the active writs pane fills the slack.
	local u = GM.ui
	if u then
		local head = CreateFrame("Frame", nil, f)
		ui.headHost = head
		ui.boardBar:ClearAllPoints()
		ui.boardBar:SetPoint("TOPLEFT", head, "TOPLEFT", 2, -4)
		ui.refreshBtn:ClearAllPoints()
		ui.refreshBtn:SetPoint("TOPRIGHT", head, "TOPRIGHT", -2, -3)
		ui.hint:ClearAllPoints()
		ui.hint:SetPoint("RIGHT", ui.refreshBtn, "LEFT", -8, 0)
		local root = u:AttachRoot(f, { direction = "column", gap = 6,
			pad = { top = 26, left = 10, right = 10, bottom = 8 } })
		root:Add(u:Adopt(head), { width = "fill", height = 20 })
		root:Add(u:Adopt(ui.tabHost), { width = "fill", height = 18 })
		local postN = u:Adopt(post)
		root:Add(postN, { width = 700, height = 84 })
		local listN = u:Adopt(list)
		root:Add(listN, { width = "fill", height = "fill" })
		local pair = u:Row(root, { gap = 6 })
		root:Add(pair, { width = "fill", height = 146 })
		pair:Add(u:Adopt(mine), { width = 342, height = "fill" })
		pair:Add(u:Adopt(inc), { width = "fill", height = "fill" })
		ui.ordNodes = { postN, listN, pair }
		if ui.shopsP then
			local sp = u:Adopt(ui.shopsP)
			root:Add(sp, { width = "fill", height = "fill" })
			ui.shopsN = sp
		end
		if ui.writsP then
			local wp = u:Adopt(ui.writsP)
			root:Add(wp, { width = "fill", height = "fill" })
			ui.writsN = wp
		end
	else
		-- hand-laid fallback: tab strip under the header, writs
		-- panes sit on the same rect the panels already occupy
		ui.tabHost:SetPoint("TOPLEFT", 12, -50)
		ui.ordPanels = { post, list, mine, inc }
	end
	-- panes adopt into the managed tree as hidden siblings; SetTab
	-- resolves which one shows
	ui.tab = ui.tab or "auto"
	if GM.WritsUI and GM.WritsUI.Bind then
		GM.WritsUI.Bind(ui)
	end
end

-- tab switch: user picks persist, "auto" resolves at refresh —
-- shops when the board has rosters, orders otherwise
function OU.SetTab(key)
	ui.tab = key
	GM.db.craftTab = key
	OU.Refresh()
end

local function ResolvedTab(vm)
	if ui.tab ~= "auto" then return ui.tab end
	if GM.Writs and vm and vm.board then
		local ok, ros = pcall(GM.Writs.Rosters, vm.board)
		if ok and ros and next(ros) then return "shops" end
	end
	return "orders"
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
local function idxSort(a, b)
	if (a.name ~= nil) ~= (b.name ~= nil) then
		return a.name ~= nil
	end
	if a.name and b.name and a.name ~= b.name then
		return a.name < b.name
	end
	return a.id < b.id
end

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
	table.sort(idx, idxSort)
	ui.idx, ui.idxGen = idx, gen
	return idx
end

-- names land async — the index snapshot freezes lname at build
-- time, so without this fill a fresh session's text search could
-- only ever match the client cache's warm subset (the "1 of 7441
-- match" bug). Walk only unresolved entries on each burst; resort
-- when any fill so named items float above the unnamed tail.
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if not (ui and ui.idx) then return end
		local filled = false
		for _, e in ipairs(ui.idx) do
			if e.lname == "" then
				local n = GM.ItemName(e.id)
				if n then
					e.name, e.lname = n, n:lower()
					filled = true
				end
			end
		end
		if not filled then return end
		table.sort(ui.idx, idxSort)
		if ui.frame and ui.frame:IsShown() then OU.Refresh() end
	end)
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

-- SEARCH view: picker state = the same catalog browse but clicks
-- fire the mesh query; results state = matched open buy orders
-- from every tracker in earshot, rendered as order rows (CLAIM
-- works — each row carries its own board)
local function SearchPaint()
	ui.searchBack:SetShown(ui.searchItem ~= nil)
	ui.search:SetShown(ui.searchItem == nil)
	if not ui.searchItem then
		for i = 1, ROWS do ui.rows[i]:Hide() end
		-- same paint as FIND ITEM, different click target
		local q = (ui.search:GetText() or ""):lower()
			:gsub("^%s+", ""):gsub("%s+$", "")
		local qid = tonumber(q)
		local idx = BrowseIndex()
		local hits = {}
		for i = 1, #idx do
			local e = idx[i]
			if q == "" or (e.lname ~= ""
					and e.lname:find(q, 1, true))
				or (qid and tostring(e.id):find(q, 1, true)) then
				hits[#hits + 1] = e
				if #hits >= BROWSE_MAX then break end
			end
		end
		ui.listP.title:SetText("SEARCH — pick an item"
			.. (#hits > 0 and (" · " .. #hits .. " match") or ""))
		ui.listP.count:SetText("")
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
				r.price:SetText(mkt
					and GoldText(mkt) .. " ea" or "—")
				r.idfs:SetText("#" .. e.id)
				r:Show()
			else r:Hide() end
		end
		return
	end
	-- results state
	for i = 1, BROWSEROWS do ui.browseRows[i]:Hide() end
	local rows, _, age = OR.SearchRows()
	local name = GM.ItemNameOr(ui.searchItem)
	ui.listP.title:SetText(("SEARCH — %s · %d listings · %ds")
		:format(name, rows and #rows or 0, age or 0))
	ui.listP.count:SetText("")
	local me = OR.MyUUID()
	for i = 1, ROWS do
		local r = ui.rows[i]
		local e = rows and rows[i + (ui.scroll or 0)]
		if not e then
			r:Hide()
		else
			OrderRow(r, {
				id = e.oid, board = e.board,
				itemID = ui.searchItem, qtyTotal = e.qty or 0,
				qtyFilled = (e.qty or 0) - (e.rem or 0),
				remaining = e.rem or 0,
				pricePerUnit = e.ppu or 0, expires = e.exp,
				poster = e.poster, backed = e.backed,
				commits = {},
			}, me)
			r.item:SetText("[" .. (e.board or "?") .. "] "
				.. r.item:GetText())
		end
	end
end

-- view-model for the registry's Data() pass — boards, the active
-- board's order rows (mine-aggregated when toggled), the expanded
-- flatten, reserve/inbox state. ClearAcked/ReserveSync reconcile
-- the model itself; they run HERE so the vm never reads pre-sync
-- state (the registry computes Data before Refresh)
local function Data()
	OR.ClearAcked()
	OR.ReserveSync()
	local boards = OR.Boards()
	local board = ui.board
	if not board or not has(boards, board) then
		board = boards[1]
	end
	local remote = board and OR.IsRemote(board)
	local orders
	if ui.mineOnly then
		orders = {}
		local me = OR.MyUUID()
		for _, b in ipairs(boards) do
			for _, o in ipairs(OR.Orders(b)) do
				if o.posterUUID == me then orders[#orders + 1] = o end
			end
		end
	else
		orders = board and OR.Orders(board) or {}
	end
	local disp = {}
	for _, o in ipairs(orders) do
		disp[#disp + 1] = o
		if ui.expanded and ui.expanded[o.id] then
			for _, c in ipairs(o.commits or {}) do
				disp[#disp + 1] = { order = o, commit = c }
			end
		end
	end
	return {
		boards = boards, board = board, remote = remote,
		reserve = OR.ReserveTotal(),
		underfunded = OR.Underfunded(),
		orders = orders, disp = disp, me = OR.MyUUID(),
		mine = board and OR.MyCommits(board) or {},
		cods = OR.InboxCODs(),
	}
end

function OU.Refresh(vm)
	if not ui then return end
	vm = vm or Data()

	-- board buttons
	local boards = vm.boards
	ui.board = vm.board
	-- a remote board needs its snapshot asked over the tunnel —
	-- throttled inside RelayAsk (60s per board)
	if vm.remote then OR.RelayAsk(ui.board) end
	for i, b in ipairs(ui.boardBtns) do b:Hide() end
	ui.boardBtns = {}
	ui.boardBar:SetText("boards:")
	local bx = 62
	for i, b in ipairs(boards) do
		local lbl = OR.IsRemote(b) and (b .. "·") or b
		local w = 10 + #lbl * 8
		local btn = MkBtn(ui.frame, lbl, w)
		if ui.headHost then
			btn:SetPoint("TOPLEFT", ui.headHost, "TOPLEFT", bx - 10, -4)
		else
			btn:SetPoint("TOPLEFT", bx, -27)
		end
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
	local res = vm.reserve
	local h = "live via mesh · pull reconciles"
	if res > 0 then
		h = ("reserved %s — "):format(GoldText(res)) .. h
	end
	if vm.underfunded then
		h = GM.CC("warn") .. "UNDERFUNDED RESERVES — " .. h .. "|r"
	end
	ui.hint:SetText(h)

	-- craft tabs: orders nodes vs the WritsUI panes — visibility
	-- only moves on tab change (SetVisible re-lays the tree out)
	ui.shownTab = ResolvedTab(vm)
	if ui.craftTabs then ui.craftTabs.set(ui.shownTab) end
	if ui.shownTab ~= ui.lastShownTab then
		ui.lastShownTab = ui.shownTab
		local isOrd = ui.shownTab == "orders"
		if ui.ordNodes and next(ui.ordNodes) then
			for _, n in ipairs(ui.ordNodes) do
				n:SetVisible(isOrd)
			end
		elseif ui.ordPanels then
			for _, p in ipairs(ui.ordPanels) do
				p:SetShown(isOrd)
			end
		end
		if GM.WritsUI and GM.WritsUI.SetTab then
			GM.WritsUI.SetTab(ui.shownTab)
		end
	end
	if ui.shownTab ~= "orders" then
		if GM.WritsUI and GM.WritsUI.Paint then
			GM.WritsUI.Paint(ui.shownTab, vm)
		end
		return
	end

	-- orders list / item browser / mesh search
	ui.modeBtn.text:SetText(VIEW_LBL[ui.view] or "BOARD")
	ui.search:SetShown(ui.view ~= "orders")
	ui.searchBack:SetShown(ui.view == "search"
		and ui.searchItem ~= nil)
	local showOrders = ui.view == "orders"
	ui.claimQty:SetShown(showOrders or ui.searchItem ~= nil)
	ui.claimLbl:SetShown(showOrders or ui.searchItem ~= nil)
	ui.mineBtn:SetShown(showOrders)
	for i = 1, #ui.colHeads do
		ui.colHeads[i]:SetShown(showOrders
			or ui.searchItem ~= nil)
	end
	if ui.view == "find" then
		BrowsePaint()
	elseif ui.view == "search" then
		SearchPaint()
	else
		for i = 1, BROWSEROWS do ui.browseRows[i]:Hide() end
		local orders = vm.orders
		-- flatten happened in Data() — commits nest under expanded
		-- orders and consume row-pool slots
		local disp = vm.disp
		ui.listP.title:SetText(ui.mineOnly
			and ("MY BUY ORDERS · " .. #orders)
			or ("BOARD — " .. tostring(ui.board or "none")
				.. " · " .. #orders .. " open"))
		ui.listP.count:SetText("")
		local me = vm.me
		for i = 1, ROWS do
			local r = ui.rows[i]
			local e = disp[i + (ui.scroll or 0)]
			if not e then
				r:Hide()
			elseif e.commit then
				CommitRow(r, e.order, e.commit, me)
			else
				OrderRow(r, e, me)
				-- mine aggregates boards — name the board on the row
				if ui.mineOnly then
					r.item:SetText("[" .. (e.board or "?")
						.. "] " .. r.item:GetText())
				end
			end
		end
	end

	-- my commits
	local mine = vm.mine
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
	local hits = vm.cods
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

GM.View.Register("orders", {
	Show = OU.Show, Hide = OU.Hide, Toggle = OU.Toggle,
	Data = Data,
	Refresh = OU.Refresh,
	IsShown = function() return ui and ui.frame and ui.frame:IsShown() end })
