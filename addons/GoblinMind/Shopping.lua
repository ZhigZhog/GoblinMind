local _, GM = ...

-- Part 6a: the market window. SHOP mode lists the targeted item's asks
-- (unit price, % of market, seller, own rows dimmed); the sniper feed
-- lives in SniperUI.lua — the SNIPER button here just launches it.
-- Every buy is one protected call
-- per click: items buy via PlaceBid, commodities via the staged
-- quote→CONFIRM flow — the same executor the plan queue uses.

GM.Shopping = { mode = "shop", asks = nil, itemID = nil, expanded = {} }
local S = GM.Shopping
local ui
local ROWS = 13 -- 14 rows ended 4px from the frame bottom and clipped the footer
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

-- ============ window ============

local function BuildRow(parent, i)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(24)
	row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 24)
	row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 24)
	GM.Panel(row, i % 2 == 0 and "contLow" or "contLowest", "contLowest")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("LEFT", 4, 0)
	row.arrow  = GM.MakeFontString(row, GM.FONT_MED, 10, "textDim")
	row.arrow:SetPoint("LEFT", 6, 0)
	row.name   = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.name:SetPoint("LEFT", 26, 0)
	row.name:SetWidth(150)
	row.qty    = GM.MakeFontString(row, GM.FONT, 10, "textDim")
	row.qty:SetPoint("LEFT", 182, 0)
	row.qty:SetWidth(52)
	row.qty:SetJustifyH("LEFT")
	row.qty:SetWordWrap(false)
	row.unit   = GM.MakeFontString(row, GM.FONT_MED, 10, "text")
	row.unit:SetPoint("LEFT", 240, 0)
	row.pct    = GM.MakeFontString(row, GM.FONT_MED, 10, "textDim")
	row.pct:SetPoint("LEFT", 320, 0)
	row.pct:SetWidth(56)
	row.pct:SetJustifyH("LEFT")
	row.pct:SetWordWrap(false)
	row.name:SetWordWrap(false)
	row.seller = GM.MakeFontString(row, GM.FONT, 10, "textDim")
	row.seller:SetPoint("LEFT", 382, 0)
	row.seller:SetWidth(190)
	row.seller:SetJustifyH("LEFT")
	row.seller:SetWordWrap(false)
	row.buy = CreateFrame("Button", nil, row)
	row.buy:SetSize(60, 18)
	row.buy:SetPoint("RIGHT", -6, 0)
	GM.Panel(row.buy, "contHigh")
	row.buy.text = GM.MakeFontString(row.buy, GM.FONT_MED, 9, "textDim")
	row.buy.text:SetAllPoints()
	row.buy:SetScript("OnClick", function() S.BuyRow(row) end)
	row.buy:SetScript("OnEnter", function() GM.Panel(row.buy, "contHighest") end)
	row.buy:SetScript("OnLeave", function() GM.Panel(row.buy, "contHigh") end)
	-- row hover → native item tooltip + our price context; the buy
	-- button forwards it too so coverage is seamless
	row:EnableMouse(true)
	local function ShowTip()
		local d = row.data
		if not d or not d.itemID or not GameTooltip then return end
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(d.itemID)
		local e = GM.ItemEntry(d.itemID)
		local m = GM.Price("dbmarket", d.itemID)
		if m and d.unit then
			local pct = d.unit / m * 100
			GameTooltip:AddLine(format("unit %s · %s of ref %s (%d%%)",
				GM.Money(d.unit), GM.CC(pct <= 100 and "pos" or "err"),
				GM.Money(m), pct), 1, 1, 1)
		end
		if d.own then GameTooltip:AddLine("your auction", 0.5, 0.8, 0.4) end
		if d.mats then
			GameTooltip:AddLine("mats (bags+bank):", 0.9, 0.9, 0.8)
			for _, m in ipairs(d.mats) do
				local have = GM.Crafting.Owned(m.id)
				local p = GM.Crafting.MatPrice(m.id)
				GameTooltip:AddLine(format("  %s ×%d — have %d @ %s",
					(GM.QHex(m.id) or "")
						.. ((GM.ItemName and GM.ItemName(m.id))
							or ("item " .. m.id)) .. "|r",
					m.qty, have, p and GM.Money(p) or "?"),
					have >= m.qty and 0.5 or 1,
					have >= m.qty and 0.9 or 0.6,
					have >= m.qty and 0.5 or 0.5)
			end
			if d.suggest and d.suggest > 0 then
				GameTooltip:AddLine(format("suggested craft ×%d", d.suggest),
					0.5, 0.9, 0.5)
			end
		end
		GameTooltip:Show()
	end
	local function HideTip()
		if GameTooltip then GameTooltip:Hide() end
	end
	row:SetScript("OnEnter", ShowTip)
	row:SetScript("OnLeave", HideTip)
	-- header rows collapse/expand their group on click; child rows
	-- keep mouse free for the buy button and tooltip only
	row:SetScript("OnMouseUp", function()
		local d = row.data
		if IsModifiedClick() then
			if d and d.itemID then GM.Ops.Click(d.itemID) end
			return
		end
		if d and d.header then
			S.expanded[d.itemID] = not d.open
			S.Refresh()
		end
	end)
	row.buy:SetScript("OnEnter", function()
		GM.Panel(row.buy, "contHighest")
		ShowTip()
	end)
	row.buy:SetScript("OnLeave", function()
		GM.Panel(row.buy, "contHigh")
		HideTip()
	end)
	return row
end

local function Build()
	if ui then return end
	ui = { mode = S.mode } -- nil → shop labels over craft rows
	local f, title = GM.Widgets.Window({
		name = "GoblinMindMarketUI", title = "GOBLINMIND MARKET",
		w = 680, h = 436, x = 100, tab = "market",
	})
	ui.frame = f

	-- mode + action buttons ride the title row
	local function TitleBtn(label, w, onclick)
		local b = CreateFrame("Button", nil, f)
		b:SetSize(w, 16)
		GM.Panel(b, "contMedium")
		b.text = GM.MakeFontString(b, GM.FONT_MED, 9, "secondary")
		b.text:SetAllPoints()
		b.text:SetText(label)
		b:SetScript("OnClick", onclick)
		return b
	end
	-- mode buttons ride a second row under the title (like the main
	-- window's action strip) — the title row is title + module tabs
	ui.shopBtn = TitleBtn("SHOP", 52, function() S.SetMode("shop") end)
	ui.snipeBtn = TitleBtn("SNIPER", 60, function()
		GM.View.Toggle("sniper")
	end)
	ui.craftBtn = TitleBtn("CRAFT", 52, function() S.SetMode("craft") end)
	-- primary action lives at the bottom-right — the title row is
	-- title + mode buttons + module tabs, no room for it up there
	ui.action = TitleBtn("SCAN", 80, function() S.Action() end)

	ui.status = GM.MakeFontString(f, GM.FONT, 10, "textDim")

	local header = CreateFrame("Frame", nil, f)
	GM.Panel(header, "contHigh")
	ui.hdrFs = {}
	for _, h in ipairs({
		{ "ITEM", "LEFT", 8 }, { "QTY", "LEFT", 182 }, { "UNIT", "LEFT", 240 },
		{ "%MKT", "LEFT", 320 }, { "SELLER", "LEFT", 382 },
	}) do
		local fs = GM.MakeFontString(header, GM.FONT_MED, 10, "primary")
		fs:SetPoint(h[2], h[3], 0)
		fs:SetText(h[1])
		ui.hdrFs[#ui.hdrFs + 1] = fs
	end

	ui.list = CreateFrame("Frame", nil, f)
	GM.Panel(ui.list, "contLowest")
	ui.rows = {}
	for i = 1, ROWS do ui.rows[i] = BuildRow(ui.list, i) end

	local foot = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	foot:SetText("one protected call per click · items = PlaceBid · commodities = quote → CONFIRM")

	-- ============ layout wiring ============
	-- mode buttons / status / column header / row list / foot, with
	-- the SCAN action parked bottom-right; title + module tabs stay
	-- W.Window chrome
	local u = GM.ui
	local root = u:AttachRoot(f, {
		direction = "column", gap = "sm",
		pad = { top = 32, right = 10, bottom = 4, left = 10 },
	})
	local modes = u:Row(root, { gap = "sm" })
	root:Add(modes, { height = 18 })
	local function ModeBtn(b, w)
		modes:Add(u:Adopt(b, { width = w, height = 16 }),
			{ width = w, height = 16 })
	end
	ModeBtn(ui.shopBtn, 52) ModeBtn(ui.snipeBtn, 60)
	ModeBtn(ui.craftBtn, 52)
	root:Add(u:Adopt(ui.status, { width = 640, height = 14 }),
		{ height = 14 })
	root:Add(u:Adopt(header, { width = 660, height = 18 }),
		{ height = 18 })
	root:Add(u:Adopt(ui.list, { width = 660, height = ROWS * 24 + 8 }),
		{ height = "fill" })
	local footRow = u:Row(root, {})
	root:Add(footRow, { height = 18 })
	footRow:Add(u:Adopt(foot, { width = 560, height = 12 }),
		{ width = "fill", height = 12, align = "center" })
	footRow:Add(u:Adopt(ui.action, { width = 80, height = 16 }),
		{ width = 80, height = 16, align = "center" })
end

-- names/icons resolve asynchronously — re-render rows when item data
-- finishes loading into the cache
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then S.Refresh() end
	end)
end

-- ============ public surface ============

function S.Toggle()
	Build()
	ui.frame:SetShown(not ui.frame:IsShown())
	S.Refresh()
end

function S.Show()
	Build()
	ui.frame:Show()
	S.Refresh()
end

function S.Status(text)
	if ui then ui.status:SetText(text) end
end

function S.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function S.SetMode(mode)
	ui.mode = mode
	S.Refresh()
end

-- QUEUE on a recipe row → plan steps (buy missing mats, manual craft)
function S.QueueRow(row)
	local d = row.data
	if d and d.recipeID then
		GM.Crafting.Queue(d.recipeID, d.suggest or 1)
		GM.PlanQueue.Show()
	end
end

function S.Action()
	S.ShopScan()
end

-- ============ shop scan ============

function S.ShopScan()
	-- the plan window targets items two ways: SetItem puts it on
	-- PQ.itemID, SetScanPlan (post/cancel/craft plans) carries it on
	-- plan.itemID — accept either or the scan looks dead
	local id = GM.PlanQueue.itemID
		or (GM.PlanQueue.plan and GM.PlanQueue.plan.itemID)
	if not id then
		S.Status(GM.CC("warn") .. "target an item first — /goblin [item]|r")
		return
	end
	if not GM.AH.open then
		S.Status(GM.CC("warn") .. "auction house is not open|r")
		return
	end
	S.itemID = id
	S.Status(GM.CC("textDim") .. "scanning " .. (GetInfo(id) or id) .. "…|r")
	GM.Auctioning.QueueScan(id, function(asks)
		for _, a in ipairs(asks) do a.itemID = id end
		S.asks = asks
		S.Status("")
		S.Refresh()
	end)
end

-- ============ buying (one protected call per click) ============

function S.BuyRow(row)
	local d = row.data
	if not d or d.header then return end
	if d.recipeID then S.QueueRow(row) return end
	-- a staged quote for this item is live → this click is the
	-- confirm — but only once the quote actually landed; firing
	-- ConfirmCommoditiesPurchase at nothing gets refused
	local pc = GM.AH.pendingConfirm
	if pc and pc.itemID == d.itemID then
		if pc.quote then GM.AH.Execute({ kind = "confirm" })
		else GM.Print(GM.CC("textDim") .. "quote still in flight…|r") end
		return
	end
	if d.id then
		GM.AH.Execute({ kind = "buy", itemID = d.itemID, qty = d.qty,
			unit = d.unit, total = d.total, auctionID = d.id })
	else
		GM.AH.Execute({ kind = "buy", itemID = d.itemID, qty = d.qty,
			unit = d.unit, commodity = true })
	end
end

-- sniper hit: click 1 re-queries the item's book; click 2 buys the
-- matching listing — the two clicks keep purchases hardware-driven
function S.BuyHit(h)
	if not GM.AH.open then
		GM.Print(GM.CC("warn") .. "sniper needs the auction house open|r")
		return
	end
	-- commodity hits stage a quote — the next click confirms it, but
	-- only once a quote actually LANDED. Confirming a pendingConfirm
	-- with no quote fires ConfirmCommoditiesPurchase at a staged
	-- purchase that doesn't exist server-side — the client refuses
	-- and the row looked "bought" on a failed purchase
	if h.state == "staged" then
		local pc = GM.AH.pendingConfirm
		if pc and pc.itemID == h.itemID and pc.quote then
			GM.AH.Execute({ kind = "confirm" })
			-- done when the server confirms — PURCHASE_FAILED and
			-- PRICE_UNAVAILABLE revive the row via QuoteDied
			h.done = true
		elseif pc and pc.itemID == h.itemID then
			GM.Print(GM.CC("textDim") .. "quote still in flight…|r")
		else
			h.state = nil -- quote died or was replaced — rescan
		end
		S.Refresh()
		return
	end
	if h.state == "ready" and h.live then
		if h.live.id then
			GM.AH.Execute({ kind = "buy", itemID = h.itemID, qty = h.live.qty,
				unit = h.live.unit, total = h.live.total, auctionID = h.live.id })
			h.done = true
			h.state = nil
		elseif h.quoteDead then
			-- the quote API already refused this itemID once — the
			-- aggregate buy path is dead on this client, don't stage
			-- another quote that can never land
			GM.Print(GM.CC("warn") .. format(
				"sniper: %s is aggregate-only — no buy API here, "
				.. "grab it in the BLIZZARD UI|r", h.name or h.itemID))
			h.done = true
			h.state = nil
		else
			local r = GM.AH.Execute({ kind = "buy", itemID = h.itemID, qty = h.qty,
				unit = h.live.unit, commodity = true })
			-- "confirm" = quote staged, NOT purchased — mark staged so
			-- the next click fires ConfirmCommoditiesPurchase
			if r == "confirm" then
				h.state = "staged"
			else
				h.done = true
				h.state = nil
			end
		end
		S.Refresh()
		return
	end
	if h.state then return end -- already scanning
	h.state = "scanning"
	S.Refresh()
	-- the hit's link carries the variant — without it a suffixed item
	-- re-queries the suffix-0 base and comes back "gone"
	GM.Auctioning.QueueScan(h.itemID, function(asks)
		h.state = nil
		local cheapest
		for _, a in ipairs(asks) do
			if not a.own then cheapest = a break end
		end
		if cheapest and cheapest.unit <= ceil(h.unit * 1.02) then
			h.live = { id = cheapest.id, qty = cheapest.qty,
				unit = cheapest.unit, total = cheapest.total or cheapest.unit * cheapest.qty,
				bid = cheapest.bid, minBid = cheapest.minBid,
				tl = cheapest.tl }
			h.state = "ready"
		else
			GM.Print(format("sniper: %s gone — cheapest now %s",
				h.name, GM.Money(cheapest and cheapest.unit or 0)))
			h.done = true
		end
		S.Refresh()
	end, GM.AH.ItemKeyFromLink(h.link))
end

-- sniper bid: double-click places a +1c bid over the current bid (or
-- the listing's minimum when nobody's bid yet). auctionID needs the
-- live re-query — without h.live the first double-click arms the row
-- and scans; the next click fires PlaceBid (protected calls stay on
-- hardware clicks).
function S.BidHit(h)
	if not GM.AH.open then
		GM.Print(GM.CC("warn") .. "sniper needs the auction house open|r")
		return
	end
	-- a staged commodity quote keeps its confirm path — a double-click
	-- here confirms, it doesn't arm a bid that could never fire
	if h.state == "staged" then S.BuyHit(h) return end
	if h.state == "ready" and h.live and h.live.id then
		local a = h.live
		-- +1c above the current lot bid; no bids yet → the server's
		-- required minimum. Below it the call is rejected anyway.
		local amt = (a.bid and a.bid > 0 and a.bid + 1) or a.minBid
		if not (amt and amt > 0) then
			GM.Print(GM.CC("warn") .. "no bid price on this listing|r")
			return
		end
		GM.AH.Execute({ kind = "bid", itemID = h.itemID,
			auctionID = a.id, total = amt })
		h.done = true
		h.state = nil
		h.wantBid = nil
		S.Refresh()
		return
	end
	-- a scanned hit with no auctionID is an aggregate row — there is
	-- no bid endpoint for it. An armed wantBid would dead-end every
	-- click from here: drop the intent and take the buyout path.
	if h.state == "ready" and h.live and not h.live.id then
		h.wantBid = nil
		S.BuyHit(h)
		return
	end
	-- arm the bid intent even while a BuyHit scan is in flight — its
	-- completion lands h.live and the next click bids
	h.wantBid = true
	if h.state then return end
	h.state = "scanning"
	S.Refresh()
	GM.Auctioning.QueueScan(h.itemID, function(asks)
		h.state = nil
		local cheapest
		for _, a in ipairs(asks) do
			if not a.own then cheapest = a break end
		end
		if cheapest then
			h.live = { id = cheapest.id, qty = cheapest.qty,
				unit = cheapest.unit, total = cheapest.total or cheapest.unit * cheapest.qty,
				bid = cheapest.bid, minBid = cheapest.minBid,
				tl = cheapest.tl }
			h.state = "ready"
			if cheapest.id then
				GM.Print(GM.CC("textDim") .. "bid armed — click the row to place +1c|r")
			else
				-- aggregate rows have no bid endpoint — don't arm a
				-- +1c that can never fire
				h.wantBid = nil
				GM.Print(GM.CC("textDim") .. "aggregate row — no bid path, click buys out|r")
			end
		else
			GM.Print(format("sniper: %s gone", h.name or h.itemID))
			h.done = true
			h.wantBid = nil
		end
		S.Refresh()
	end, GM.AH.ItemKeyFromLink(h.link))
end

-- staged-quote death (COMMODITY_PRICE_UNAVAILABLE / quote timeout):
-- un-stage matching hits so they can't sit on CONFIRM forever, and
-- flag the itemID — a repeat click then says so instead of staging
-- another quote that can never land
function S.QuoteDied(itemID, alive)
	local hits = GM.Sniper and GM.Sniper.hits
	if not hits then return end
	for _, h in ipairs(hits) do
		if h.state == "staged" and (not itemID or h.itemID == itemID) then
			h.state = nil
			-- the confirm click marked it bought before the server
			-- answered — a refused purchase means put the row back
			h.done = nil
			-- alive = drifted quote, not a dead API — keep the buy
			-- path open for the next click
			if not alive then h.quoteDead = true end
		end
	end
end

-- ============ refresh ============

-- header labels follow the mode — craft rows carry cost/profit/prof,
-- not qty/unit/%mkt/seller, and shared labels made them read as shifted
local HDR_LABELS = {
	shop = { "ITEM", "QTY", "UNIT", "%MKT", "SELLER" },
	craft = { "ITEM", "CAN", "COST", "PROFIT", "PROF" },
}

-- view-model for the registry's Data() pass — the grouped display
-- list (asks grouped into item headers + children, or flat craft
-- rows). S.asks/S.expanded are view state the vm reads; per-row
-- icon/name enrichment stays in the painter (per-visible-row only)
local function Data()
	-- entries: { header=true, itemID, count, totalQty, cheapest, ownCount,
	--            name, m, cap } or { child=true, d = ask-or-hit }
	local display = {}
	local function PushGroup(list, getID)
		if #list == 0 then return end
		local order, groups = {}, {}
		for _, e in ipairs(list) do
			local id = getID(e)
			local g = groups[id]
			if not g then
				g = { itemID = id, items = {}, totalQty = 0, count = 0,
					cheapest = math.huge, ownCount = 0 }
				groups[id] = g
				tinsert(order, g)
			end
			tinsert(g.items, e)
			g.count = g.count + 1
			g.totalQty = g.totalQty + (e.qty or 1)
			g.cheapest = math.min(g.cheapest, e.unit or math.huge)
			if e.own then g.ownCount = g.ownCount + 1 end
		end
		for _, g in ipairs(order) do
			local open = S.expanded[g.itemID]
			if open == nil then open = true end -- groups start expanded
			tinsert(display, { header = true, g = g, open = open })
			if open then
				for _, e in ipairs(g.items) do
					tinsert(display, { child = true, d = e })
				end
			end
		end
	end

	if ui.mode == "shop" then
		local asks = S.asks or {}
		PushGroup(asks, function(a) return a.itemID end)
		return {
			display = display, mode = "shop",
			empty = #asks == 0 and (S.itemID and "no asks listed"
				or "SHOP — SCAN the targeted item's book|r"),
		}
	end
	-- CRAFT mode: flat recipe rows sorted by profit
	local recs = GM.Crafting and GM.Crafting.List() or {}
	for _, r in ipairs(recs) do tinsert(display, { craft = r }) end
	return {
		display = display, mode = "craft",
		empty = #recs == 0
			and "CRAFT — open a profession to capture its recipes",
	}
end

function S.Refresh(vm)
	if not ui then return end
	vm = vm or Data()
	local labels = HDR_LABELS[ui.mode] or HDR_LABELS.shop
	for i, fs in ipairs(ui.hdrFs or {}) do fs:SetText(labels[i] or "") end
	GM.Panel(ui.shopBtn, ui.mode == "shop" and "accent" or "contMedium")
	GM.Panel(ui.snipeBtn,
		GM.View.IsShown("sniper")
		and "accent" or "contMedium")
	GM.Panel(ui.craftBtn, ui.mode == "craft" and "accent" or "contMedium")
	ui.action.text:SetText("SCAN")
	ui.action:SetEnabled(GM.AH.open and ui.mode ~= "craft")

	local pc = GM.AH.pendingConfirm
	-- ============ tree display from the vm ============
	local display = vm.display
	if vm.empty then
		S.Status(GM.CC("textDim") .. vm.empty .. "|r")
	end

	for i = 1, ROWS do
		local row, e = ui.rows[i], display[i]
		if not e then
			row:Hide()
		elseif e.craft then
			local r = e.craft
			row:Show()
			row.data = { recipeID = r.recipeID, itemID = r.itemID,
				mats = r.mats, suggest = r.suggest }
			local ic = GM.ItemIcon and GM.ItemIcon(r.itemID)
			if ic then row.icon:SetTexture(ic); row.icon:Show() else row.icon:Hide() end
			row.arrow:SetText("")
			row.name:SetPoint("LEFT", 26, 0)
			row.name:SetText(((GM.ItemName and GM.ItemName(r.itemID)) or r.name or "?"))
			-- profitable + mats on hand = the actionable rows
			local ep = r.effProfit or r.profit
			row.name:SetTextColor(GM.NameColor(r.itemID,
				ep and ep > 0 and "text" or "textDim"))
			row.qty:SetText(r.craftable and r.craftable > 0 and ("×" .. r.craftable) or "")
			row.qty:SetTextColor(GM.RGB(r.craftable and r.craftable > 0 and "accent" or "textDim"))
			-- effective cost: only the mats you'd still buy
			row.unit:SetText((r.effCost or r.cost) and
				GM.Money(r.effCost or r.cost) or "—")
			row.pct:SetText(ep and format("%s %s%d%%|r",
				GM.Money(ep), GM.CC("textDim"),
				r.price and r.price > 0 and floor(ep / r.price * 100 + 0.5) or 0) or "—")
			row.pct:SetTextColor(GM.RGB(ep and (ep >= 0 and "pos" or "err") or "textDim"))
			row.seller:SetText(r.prof or "")
			row.buy:Show()
			row.buy.text:SetText(r.suggest and r.suggest > 0
				and ("QUEUE ×" .. r.suggest) or "QUEUE")
			row.buy:SetEnabled(true)
		elseif e.header then
			local g = e.g
			row:Show()
			row.data = { header = true, itemID = g.itemID, open = e.open }
			local ic = GM.ItemIcon and GM.ItemIcon(g.itemID)
			if ic then row.icon:SetTexture(ic); row.icon:Show() else row.icon:Hide() end
			row.arrow:SetText(e.open and "▼" or "▶")
			row.name:SetPoint("LEFT", 26, 0)
			local nm = (GM.ItemName and GM.ItemName(g.itemID)) or ("item " .. g.itemID)
			row.name:SetText((GM.QHex(g.itemID) or GM.CC("text"))
				.. nm .. "|r" .. GM.CC("textDim")
				.. "  · " .. g.count .. (g.count == 1 and " listing" or " listings") .. "|r")
			row.qty:SetText("×" .. g.totalQty)
			row.unit:SetText(g.cheapest < math.huge and GM.Money(g.cheapest) or "—")
			row.pct:SetText("")
			row.seller:SetText(g.ownCount > 0
				and (GM.CC("accent") .. g.ownCount .. " own|r") or "")
			row.buy:Hide()
		else
			local d = e.d
			row:Show()
			row.data = d
			row.arrow:SetText("")
			row.icon:Hide()
			row.name:SetPoint("LEFT", 42, 0)
			row.buy:Show()
			local m = S.itemID and GM.Price("dbmarket", S.itemID)
			local cap = S.itemID and GM.Groups.EvalOp(
				GM.Groups.GetOps(S.itemID, "shopping"), "maxPrice", S.itemID)
			row.name:SetText("")
			row.qty:SetText("×" .. d.qty)
			row.unit:SetText(GM.Money(d.unit))
			row.pct:SetText(m and format("%.0f%%", d.unit / m * 100) or "—")
			row.pct:SetTextColor(GM.RGB(cap and d.unit <= cap and "pos" or "textDim"))
			row.seller:SetText(d.own and (GM.CC("accent") .. "OWN|r") or (d.seller or "—"))
			row.buy.text:SetText(pc and pc.itemID == d.itemID and "CONFIRM" or "BUY")
			row.buy:SetEnabled(GM.AH.open and not d.own)
		end
	end
end

GM.View.Register("market", {
	Show = S.Show, Hide = S.Hide, Toggle = S.Toggle,
	Data = Data,
	Refresh = S.Refresh,
	IsShown = function() return ui and ui.frame and ui.frame:IsShown() end })
