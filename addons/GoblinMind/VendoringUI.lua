local _, GM = ...

-- Part 13 #7: the vendor window — takes over MerchantFrame the same
-- way CraftingUI takes over ProfessionsFrame. On MERCHANT_SHOW the
-- native frame is parked offscreen (FramePark.lua — never Hide()n:
-- merchant buy/sell/buyback calls need the session alive) and this
-- window opens in its place.
--
-- Pages:
--   BUY     — merchant stock, market-vs-vendor check, flips first.
--             Row BUY purchases the vendor stack (BuyMerchantItem).
--   SELL    — quality-0 bag items. Row SELL moves ONE stack to the
--             merchant per click (UseContainerItem) — click-per-step.
--   BUYBACK — sold-item recovery (GetBuybackItemInfo/BuybackItem).
--
-- Every page renders as a collapsible tree grouped by item class
-- (itemType, e.g. Reagent / Tradeskill / Junk) with a name filter;
-- BUY adds a FLIPS-ONLY toggle on top of the 85%-of-market gate.
--
-- BLIZZARD UI hands the frame back; the GOBLINMIND button stamped on
-- the native frame round-trips. ESC/X close the merchant session —
-- close means close, nothing left parked with a live session.

GM.VendoringUI = {}
local VU = GM.VendoringUI
local ui
local EditBox = GM.Widgets.EditBox

local ROW_H = 26
local VISIBLE = 13
local UseItem = C_Container and C_Container.UseContainerItem
	or UseContainerItem
local tinsert, tremove, sort = tinsert, tremove, table.sort
local format = format

local W = GM.Widgets
local Btn = W.Btn

local Tip = GM.Widgets.Tip

local function MerchantOpen()
	return MerchantFrame and MerchantFrame:IsShown()
end

-- ============ data ============

-- item class for tree grouping — names resolve asynchronously, so an
-- uncached item lands in Miscellaneous and re-groups when
-- GET_ITEM_INFO_RECEIVED repaints (VU.Refresh is subscribed below)
local ItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local function ItemClass(id)
	local t = id and ItemInfo and (select(6, ItemInfo(id)))
	return (type(t) == "string" and t ~= "") and t or "Miscellaneous"
end

-- merchant stock: one row per slot; vendor flips (price < 85% of our
-- market value, same gate as Vendoring.BuyScan) sort first
local function BuyData()
	local rows = {}
	local n = GetMerchantNumItems and GetMerchantNumItems() or 0
	for i = 1, n do
		local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo
			and C_MerchantFrame.GetItemInfo(i)
		if info then
			local link = GetMerchantItemLink and GetMerchantItemLink(i)
			local id = GM.LinkID(link)
			local qty = (info.stackCount and info.stackCount > 0)
				and info.stackCount or 1
			local unit = info.price and info.price > 0
				and info.price / qty or nil
			local e = id and GM.ItemEntry(id)
			local mkt = (e and e.p) or (id and GM.TSMMarket and GM.TSMMarket(id))
			local flip = unit and mkt and not info.hasExtendedCost
				and info.numAvailable ~= -1 and info.numAvailable ~= 0
				and unit < mkt * 0.85
			-- extended cost: alternative currencies/token items —
			-- GM.MerchantAltCost decodes icon+qty+owned per component;
			-- render those instead of the "alt cost" shrug.
			local alt = info.hasExtendedCost
				and GM.MerchantAltCost
				and GM.MerchantAltCost(i) or nil
			rows[#rows + 1] = {
				index = i, id = id, cls = ItemClass(id),
				name = (id and GM.ItemName(id)) or (link and link:match("%[(.-)%]"))
					or ("slot " .. i),
				qty = qty, cost = info.price, mkt = mkt and mkt * qty,
				flip = flip or nil, ext = info.hasExtendedCost or nil,
				alt = alt,
				out = info.numAvailable == 0,
				avail = info.numAvailable,
			}
		end
	end
	sort(rows, function(a, b)
		if a.out ~= b.out then return b.out end
		if a.flip ~= b.flip then return a.flip and true or false end
		return (a.name or "") < (b.name or "")
	end)
	return rows
end

-- junk in bags: one row per stack, biggest stack value first
local function SellData()
	local rows = {}
	local info = C_Item and C_Item.GetItemInfo or GetItemInfo
	for _, s in ipairs(GM.Banking.BagSlots()) do
		if s.itemID and info then
			local _, _, q, _, _, _, _, _, _, _, sell = info(s.itemID)
			if q == 0 and sell and sell > 0
				and not GM.Vendoring.IsBlacklisted(s.itemID) then
				rows[#rows + 1] = {
					bag = s.bag, slot = s.slot, id = s.itemID,
					cls = ItemClass(s.itemID),
					qty = s.count, val = sell * s.count,
					name = GM.ItemName(s.itemID),
				}
			end
		end
	end
	sort(rows, function(a, b) return a.val > b.val end)
	return rows
end

local function BackData()
	local rows = {}
	local n = GetNumBuybackItems and GetNumBuybackItems() or 0
	for i = 1, n do
		local link = GetBuybackItemLink and GetBuybackItemLink(i)
		local _, _, price, qty = GetBuybackItemInfo
			and GetBuybackItemInfo(i)
		local id = GM.LinkID(link)
		rows[#rows + 1] = {
			index = i, id = id, cls = ItemClass(id), qty = qty or 1,
			price = price,
			name = (id and GM.ItemName(id)) or (link and link:match("%[(.-)%]"))
				or ("slot " .. i),
		}
	end
	return rows
end

local PAGES = {
	{ key = "buy",  label = "BUY",     data = BuyData,
		head = { "ITEM", "QTY", "COST", "MARKET" } },
	{ key = "sell", label = "SELL",    data = SellData,
		head = { "ITEM", "QTY", "VENDOR", "" } },
	{ key = "back", label = "BUYBACK", data = BackData,
		head = { "ITEM", "QTY", "PRICE", "" } },
}

-- filters + grouping: name search (all pages) and flips-only (BUY),
-- then one collapsible class header per itemType. Groups sort A-Z;
-- the page's own row order is preserved inside each group (BUY keeps
-- flips-first, SELL keeps value-desc) — the scroll list is this
-- flattened display array, headers included
local function FlatTree(rows)
	local q = (ui.search and ui.search:GetText() or ""):lower()
	if q == "filter…" then q = "" end
	local groups, order = {}, {}
	for _, r in ipairs(rows) do
		local pass = (q == "" or (r.name or ""):lower():find(q, 1, true))
			and not (ui.page == "buy" and ui.flipsOnly and not r.flip)
		if pass then
			local c = r.cls or "Miscellaneous"
			local g = groups[c]
			if not g then
				g = { n = 0 }
				groups[c] = g
				order[#order + 1] = c
			end
			g.n = g.n + 1
			g[#g + 1] = r
		end
	end
	sort(order)
	local disp, nItems = {}, 0
	for _, c in ipairs(order) do
		local g = groups[c]
		disp[#disp + 1] = { hdr = true, cls = c, n = g.n,
			closed = ui.collapsed[c] or nil }
		nItems = nItems + g.n
		if not ui.collapsed[c] then
			for _, r in ipairs(g) do
				disp[#disp + 1] = r
			end
		end
	end
	return disp, nItems, #order
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { page = "buy", scroll = 0, collapsed = {} }
	local f = CreateFrame("Frame", "GoblinMindVendor", UIParent)
	f:SetSize(560, 470)
	f:SetPoint("CENTER", -80, -20)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:Hide()
	GM.Panel(f, "contLow", "outlineVar")
	tinsert(UISpecialFrames, "GoblinMindVendor")
	ui.frame = f

	-- closing our window: BLIZZARD UI hands the frame back with the
	-- session intact; otherwise close means close — unpark quietly and
	-- end the merchant session so nothing invisible stays alive
	f:SetScript("OnHide", function()
		GM.FramePark.Restore(MerchantFrame)
		if not ui.wantDefault then pcall(CloseMerchant) end
	end)
	-- sells/buybacks change bags + stock — debounced repaint
	pcall(f.RegisterEvent, f, "BAG_UPDATE")
	pcall(f.RegisterEvent, f, "MERCHANT_UPDATE")
	pcall(f.RegisterEvent, f, "BUYBACK_UPDATE")
	f:SetScript("OnEvent", function()
		if not f:IsShown() or ui.evPending then return end
		ui.evPending = true
		GM.After(0.2, function()
			ui.evPending = nil
			VU.Refresh()
		end)
	end)

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("VENDOR")
	-- contextual takeover window (merchant session only) — no tab strip

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- toolbar: page toggles + actions
	local x = 12
	local tabHost = CreateFrame("Frame", nil, f)
	tabHost:SetSize(186, 20)
	tabHost:SetPoint("TOPLEFT", x, -34)
	ui.pageTabs = W.PageTabs(tabHost,
		{ { PAGES[1].key, PAGES[1].label }, { PAGES[2].key, PAGES[2].label },
			{ PAGES[3].key, PAGES[3].label } },
		function(key)
			ui.page = key
			ui.scroll = 0
			VU.Refresh()
		end)
	x = x + 192
	local plan = Btn(f, 84, "SCAN → PLAN", function()
		GM.Vendoring.Scan()
	end)
	plan:SetPoint("TOPLEFT", x + 6, -34)
	Tip(plan, function()
		return { "Vendoring scan",
			"Pushes vendor flips + autosell junk into the plan",
			"queue as click-per-step steps." }
	end)
	ui.repair = Btn(f, 70, "REPAIR", function()
		pcall(RepairAllItems, IsShiftKeyDown())
		VU.Refresh()
	end)
	ui.repair:SetPoint("LEFT", plan, "RIGHT", 6, 0)
	Tip(ui.repair, function()
		local cost = GetRepairAllCost and GetRepairAllCost()
		return { "Repair all", cost and ("cost " .. GM.Money(cost)) or "",
			CanGuildBankRepair and CanGuildBankRepair()
				and "shift+click repairs from the guild bank"
				or "personal funds" }
	end)
	local blizz = Btn(f, 84, "BLIZZARD UI", function()
		ui.wantDefault = true
		f:Hide() -- OnHide → Restore: native frame reappears, session stays
	end)
	blizz:SetPoint("TOPRIGHT", -28, -34)
	Tip(blizz, function()
		return { "Blizzard default UI",
			"Brings the default merchant frame back and hides this",
			"window. The GOBLINMIND button on that frame switches back." }
	end)

	-- filter row: name search (all pages) + FLIPS-ONLY (BUY) +
	-- collapse/expand-all for the class tree
	ui.search = EditBox(f, 130, "filter…")
	ui.search:SetPoint("TOPLEFT", 12, -56)
	ui.search:SetScript("OnTextChanged", function()
		ui.scroll = 0
		VU.Refresh()
	end)
	ui.flipsBtn = Btn(f, 76, "FLIPS ONLY", function()
		ui.flipsOnly = not ui.flipsOnly or nil
		ui.flipsBtn.text:SetTextColor(GM.RGB(ui.flipsOnly and "accent"
			or "textDim"))
		ui.scroll = 0
		VU.Refresh()
	end)
	ui.flipsBtn:SetPoint("LEFT", ui.search, "RIGHT", 8, 0)
	ui.flipsBtn.text:SetTextColor(GM.RGB("textDim"))
	-- W.Btn's hover leave resets to textDim — re-assert the ON color
	ui.flipsBtn:HookScript("OnLeave", function()
		ui.flipsBtn.text:SetTextColor(GM.RGB(
			ui.flipsOnly and "accent" or "textDim"))
	end)
	Tip(ui.flipsBtn, "Only vendor stock priced under 85% of market")
	ui.collapseBtn = Btn(f, 100, "COLLAPSE ALL", function()
		-- flip the current majority: anything expanded collapses;
		-- an all-collapsed tree re-expands
		local anyOpen
		local rows = MerchantOpen() and ({ buy = BuyData, sell = SellData,
			back = BackData })[ui.page]() or {}
		for _, r in ipairs(rows) do
			if not ui.collapsed[r.cls or "Miscellaneous"] then
				anyOpen = true
				break
			end
		end
		for _, r in ipairs(rows) do
			ui.collapsed[r.cls or "Miscellaneous"] = anyOpen or nil
		end
		VU.Refresh()
	end)
	ui.collapseBtn:SetPoint("LEFT", ui.flipsBtn, "RIGHT", 6, 0)

	-- column header (labels swap per page)
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(536, 16)
	hdr:SetPoint("TOPLEFT", 12, -78)
	ui.head = {}
	for i, hx in ipairs({ 28, 240, 300, 380 }) do
		local fs = GM.MakeFontString(hdr, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("LEFT", hx, 0)
		fs:SetWidth(200)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		ui.head[i] = fs
	end
	ui.count = GM.MakeFontString(hdr, GM.FONT, 9, "textDim")
	ui.count:SetPoint("RIGHT", -2, 0)

	-- scroll host
	local host = CreateFrame("Frame", nil, f)
	host:SetSize(536, VISIBLE * ROW_H + 4)
	host:SetPoint("TOPLEFT", 12, -96)
	ui.count:SetWidth(200)
	ui.count:SetJustifyH("RIGHT")
	ui.count:SetWordWrap(false)
	if host.SetClipsChildren then host:SetClipsChildren(true) end
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		VU.Refresh()
	end)
	ui.host = host

	ui.rows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, host)
		row:RegisterForClicks("AnyUp")
		row:SetSize(528, ROW_H - 2)
		row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 28, 0)
		row.name:SetWidth(206)
		row.name:SetJustifyH("LEFT")
		row.c1 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c1:SetPoint("LEFT", 240, 0)
		row.c1:SetWidth(54)
		row.c1:SetJustifyH("LEFT")
		row.c1:SetWordWrap(false)
		row.c2 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c2:SetPoint("LEFT", 300, 0)
		row.c3 = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.c3:SetPoint("LEFT", 380, 0)
		row.name:SetWordWrap(false)
		row.c3:SetWidth(96)
		row.c3:SetJustifyH("LEFT")
		row.c3:SetWordWrap(false)
		-- alt-cost icons: currency/token texture + quantity, pooled
		-- per row (2 fit in the cost cell; overflow gets a "+N" note)
		row.alt = {}
		for k = 1, 2 do
			local t = row:CreateTexture(nil, "ARTWORK")
			t:SetSize(12, 12)
			t:Hide()
			local fs = GM.MakeFontString(row, GM.FONT, 9, "textDim")
			fs:SetWidth(200)
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			fs:Hide()
			row.alt[k] = { tex = t, fs = fs }
		end
		-- per-row action (BUY/SELL/BUYBACK) — one call per click
		local act = CreateFrame("Button", nil, row)
		act:SetSize(46, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		row.act = act
		-- shift-click swaps the action button for a qty prompt:
		-- Enter buys N items, Escape / click-away restores the button
		local qb = EditBox(row, 46)
		qb:SetPoint("RIGHT", -4, 0)
		if qb.SetNumeric then qb:SetNumeric(true) end
		qb:Hide()
		qb:SetScript("OnEnterPressed", function(eb)
			local n = math.floor(tonumber(eb:GetText()) or 0)
			local idx = eb.buyIdx
			eb:ClearFocus()
			if idx and n > 0 then
				pcall(BuyMerchantItem, idx, n)
			end
			VU.Refresh()
		end)
		qb:SetScript("OnEscapePressed", function(eb) eb:ClearFocus() end)
		qb:HookScript("OnEditFocusLost", function(eb)
			eb:Hide()
			row.act:Show()
		end)
		row.qtyBox = qb
		-- item tooltips on the row body, not over the action button
		row:SetScript("OnEnter", function(self)
			if self.tip then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				if self.tip == "buy" then
					pcall(GameTooltip.SetMerchantItem, GameTooltip, self.tipIdx)
				elseif self.tip == "back" then
					pcall(GameTooltip.SetBuybackItem, GameTooltip, self.tipIdx)
				elseif self.tipID then
					GameTooltip:SetItemByID(self.tipID)
				end
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.rows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
end

-- ============ refresh ============

function VU.Refresh()
	if not ui then return end
	local open = MerchantOpen()
	ui.pageTabs.set(ui.page)
	-- repair only matters while a repairing merchant is up
	local canRepair = open and CanMerchantRepair and CanMerchantRepair()
	local cost, needs = canRepair and GetRepairAllCost
		and GetRepairAllCost() or nil
	ui.repair:SetShown(canRepair and needs)
	if canRepair and cost then
		ui.repair.text:SetText("REP " .. GM.Money(cost))
	end

	local page
	for _, p in ipairs(PAGES) do
		if p.key == ui.page then page = p end
	end
	for i = 1, 4 do ui.head[i]:SetText(page.head[i]) end

	ui.flipsBtn:SetShown(ui.page == "buy")
	local rows = open and page.data() or {}
	local disp, nItems, nGroups = FlatTree(rows)
	ui.collapseBtn.text:SetText(#rows > nItems and "EXPAND ALL"
		or "COLLAPSE ALL")
	ui.empty:SetText(not open
		and "open a merchant to trade"
		or nItems == 0 and #rows > 0 and "nothing matches the filter"
		or ui.page == "buy" and "merchant has no stock listed"
		or ui.page == "sell" and "no junk in bags"
		or "nothing to buy back")
	ui.empty:SetShown(#disp == 0)
	ui.foot:SetText(ui.page == "buy"
		and "flips sort first — vendor price < 85% of market · "
			.. "BUY = one stack · shift-click = pick qty"
		or ui.page == "sell" and "one stack per SELL click · right-click row = blacklist"
		or "sold items can be bought back until you log out")

	local maxScroll = math.max(0, #disp - VISIBLE)
	ui.scroll = math.min(ui.scroll or 0, maxScroll)
	ui.count:SetText(format("%d items · %d types", nItems, nGroups))
	for i = 1, VISIBLE do
		local row = ui.rows[i]
		local r = disp[i + ui.scroll]
		if r and r.hdr then
			-- class group header — click collapses/expands its items
			row:Show()
			row.tip, row.tipIdx, row.tipID = nil, nil, nil
			row.act:Hide()
			row.qtyBox:Hide()
			row.icon:SetTexture(nil)
			for k = 1, 2 do
				row.alt[k].tex:Hide() row.alt[k].fs:Hide()
			end
			row.bg:SetColorTexture(GM.RGB("contHigh"))
			row.name:ClearAllPoints()
			row.name:SetPoint("LEFT", 8, 0)
			row.name:SetWidth(300)
			row.name:SetText((r.closed and "▶ " or "▼ ") .. r.cls
				.. GM.CC("secondary") .. "  ×" .. r.n .. "|r")
			row.name:SetTextColor(GM.RGB("accent"))
			row.c1:SetText("")
			row.c2:SetText("")
			row.c3:SetText("")
			local cls = r.cls
			row:SetScript("OnClick", function()
				ui.collapsed[cls] = not ui.collapsed[cls] or nil
				VU.Refresh()
			end)
		elseif r then
			row:Show()
			row.tip, row.tipIdx, row.tipID = nil, nil, nil
			row.act:Show()
			row.qtyBox:Hide()
			row.bg:SetColorTexture(GM.RGB(
				i % 2 == 0 and "contMedium" or "contLowest"))
			row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
			for k = 1, 2 do
				row.alt[k].tex:Hide() row.alt[k].fs:Hide()
			end
			row.name:ClearAllPoints()
			row.name:SetPoint("LEFT", 34, 0)
			row.name:SetWidth(200)
			row.name:SetText(r.name or "?")
			row.name:SetTextColor(GM.NameColor(r.id))
			row.c1:SetText("×" .. (r.qty or 1))
			-- rows are recycled — shed a previous header's collapse
			-- handler before the page branch installs its own (sell)
			row:SetScript("OnClick", nil)
			if ui.page == "buy" then
				local shown = 0
				if r.alt then
					for k, comp in ipairs(r.alt) do
						if k > 2 then break end
						local w = row.alt[k]
						w.tex:SetTexture(comp.icon or 134400)
						w.tex:ClearAllPoints()
						w.tex:SetPoint("LEFT", 300 + (k - 1) * 40, 0)
						w.tex:Show()
						w.fs:ClearAllPoints()
						w.fs:SetPoint("LEFT", w.tex, "RIGHT", 2, 0)
						w.fs:SetText("×" .. (comp.qty or 1)
							.. (comp.own ~= nil and " "
								.. GM.CC(comp.own >= (comp.qty or 1)
									and "pos" or "warn")
								.. "(" .. comp.own .. ")|r" or ""))
						w.fs:Show()
						shown = k
					end
				end
				for k = shown + 1, 2 do
					row.alt[k].tex:Hide() row.alt[k].fs:Hide()
				end
				local overflow = r.alt and #r.alt > 2
					and ("+" .. (#r.alt - 2)) or ""
				row.c2:ClearAllPoints()
				row.c2:SetPoint("LEFT", 300 + shown * 40, 0)
				row.c2:SetText(r.alt and
					((r.cost and r.cost > 0 and GM.Money(r.cost) or "") .. overflow)
					or (r.ext and "alt cost")
					or (r.cost and GM.Money(r.cost) or "—"))
				row.c2:SetTextColor(GM.RGB(r.ext and "warn" or "text"))
				row.c3:SetText(r.mkt and GM.Money(r.mkt) or "no market")
				row.act.text:SetText(r.out and "OUT" or "BUY")
				row.act.text:SetTextColor(GM.RGB(r.out and "textDim"
					or r.flip and "pos" or "accent"))
				row.tip, row.tipIdx = "buy", r.index
				local idx = r.index
				-- Blizzard merchant parity: modified clicks on the
				-- row (or its BUY button) preview/link, never buy
				row.act:SetScript("OnClick", function()
					if r.out then return end
					if IsShiftKeyDown() then
						row.act:Hide()
						row.qtyBox:SetText("")
						row.qtyBox.buyIdx = idx
						row.qtyBox:Show()
						row.qtyBox:SetFocus()
						return
					end
					if IsModifiedClick() and r.id then
						GM.ModifiedItemClick(r.id)
						return
					end
					pcall(BuyMerchantItem, idx, r.qty or 1)
					VU.Refresh()
				end)
				row:SetScript("OnClick", function()
					if IsModifiedClick() and r.id then
						GM.ModifiedItemClick(r.id)
					end
				end)
			elseif ui.page == "sell" then
				row.c2:SetText(GM.Money(r.val))
				row.c2:SetTextColor(GM.RGB("text"))
				row.c3:SetText(GM.Money(r.val / (r.qty or 1)) .. "/ea")
				row.act.text:SetText("SELL")
				row.act.text:SetTextColor(GM.RGB("warn"))
				row.tipID = r.id
				local bag, slot = r.bag, r.slot
				row.act:SetScript("OnClick", function()
					if IsModifiedClick() and r.id then
						GM.ModifiedItemClick(r.id)
						return
					end
					if MerchantOpen() and UseItem then
						pcall(UseItem, bag, slot)
						VU.Refresh()
					end
				end)
				row:SetScript("OnClick", function(_, btn)
					if btn == "RightButton" then
						GM.Vendoring.BlacklistToggle(r.id)
						VU.Refresh()
					elseif IsModifiedClick() and r.id then
						GM.ModifiedItemClick(r.id)
					end
				end)
			else
				row.c2:SetText(r.price and GM.Money(r.price) or "—")
				row.c2:SetTextColor(GM.RGB("text"))
				row.c3:SetText("")
				row.act.text:SetText("BACK")
				row.act.text:SetTextColor(GM.RGB("accent"))
				row.tip, row.tipIdx = "back", r.index
				local idx = r.index
				row.act:SetScript("OnClick", function()
					if IsModifiedClick() and r.id then
						GM.ModifiedItemClick(r.id)
						return
					end
					pcall(BuybackItem, idx)
					VU.Refresh()
				end)
				row:SetScript("OnClick", function()
					if IsModifiedClick() and r.id then
						GM.ModifiedItemClick(r.id)
					end
				end)
			end
			if r.flip then
				row.name:SetText(GM.CC("pos") .. "▶ |r" .. (r.name or "?"))
			end
		else
			row:Hide()
		end
	end
end

-- ============ takeover ============

-- GOBLINMIND button ON the Blizzard merchant frame — the round-trip
-- back once the user has switched to default
local function EnsureSwitchBtn()
	W.EnsureSwitchBtn(ui, MerchantFrame, VU.OnMerchantOpen)
end

function VU.OnMerchantOpen()
	Build()
	EnsureSwitchBtn()
	if ui.wantDefault then return end
	ui.frame:Show()
	VU.Refresh()
	-- the frame may not be positioned at event time; park now + retry
	GM.FramePark.Park(MerchantFrame)
	GM.After(0.3, function() GM.FramePark.Park(MerchantFrame) end)
end

function VU.Show()
	Build()
	ui.frame:Show()
	VU.Refresh()
end

function VU.Hide()
	if ui then ui.frame:Hide() end
end

function VU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else VU.Show() end
end

-- repaint when item names/icons resolve asynchronously
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then VU.Refresh() end
	end)
end

-- merchant session drives the takeover
local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "MERCHANT_SHOW")
pcall(f.RegisterEvent, f, "MERCHANT_CLOSED")
f:SetScript("OnEvent", function(_, e)
	if e == "MERCHANT_SHOW" then
		VU.OnMerchantOpen()
	elseif ui and ui.frame then
		-- session ended (walked away, ESC on native frame) — hide ours;
		-- OnHide restores quietly and CloseMerchant is a harmless no-op
		ui.frame:Hide()
	end
end)
