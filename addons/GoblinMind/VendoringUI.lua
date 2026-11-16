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
			local id = link and tonumber(link:match("item:(%d+)"))
			local qty = (info.stackCount and info.stackCount > 0)
				and info.stackCount or 1
			local unit = info.price and info.price > 0
				and info.price / qty or nil
			local e = id and GM.ItemEntry(id)
			local mkt = (e and e.p) or (id and GM.TSMMarket and GM.TSMMarket(id))
			local flip = unit and mkt and not info.hasExtendedCost
				and info.numAvailable ~= -1 and info.numAvailable ~= 0
				and unit < mkt * 0.85
			rows[#rows + 1] = {
				index = i, id = id,
				name = (id and GM.ItemName(id)) or (link and link:match("%[(.-)%]"))
					or ("slot " .. i),
				qty = qty, cost = info.price, mkt = mkt and mkt * qty,
				flip = flip or nil, ext = info.hasExtendedCost or nil,
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
		local id = link and tonumber(link:match("item:(%d+)"))
		rows[#rows + 1] = {
			index = i, id = id, qty = qty or 1, price = price,
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

-- ============ window ============

local function Build()
	if ui then return end
	ui = { page = "buy", scroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindVendor", UIParent)
	f:SetSize(560, 450)
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

	-- column header (labels swap per page)
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(536, 16)
	hdr:SetPoint("TOPLEFT", 12, -60)
	ui.head = {}
	for i, hx in ipairs({ 28, 240, 300, 380 }) do
		local fs = GM.MakeFontString(hdr, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("LEFT", hx, 0)
		ui.head[i] = fs
	end
	ui.count = GM.MakeFontString(hdr, GM.FONT, 9, "textDim")
	ui.count:SetPoint("RIGHT", -2, 0)

	-- scroll host
	local host = CreateFrame("Frame", nil, f)
	host:SetSize(536, VISIBLE * ROW_H + 4)
	host:SetPoint("TOPLEFT", 12, -78)
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
		row.c2 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c2:SetPoint("LEFT", 300, 0)
		row.c3 = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.c3:SetPoint("LEFT", 380, 0)
		row.c3:SetWidth(96)
		row.c3:SetJustifyH("LEFT")
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

	local rows = open and page.data() or {}
	ui.empty:SetText(not open
		and "open a merchant to trade"
		or ui.page == "buy" and "merchant has no stock listed"
		or ui.page == "sell" and "no junk in bags"
		or "nothing to buy back")
	ui.empty:SetShown(#rows == 0)
	ui.foot:SetText(ui.page == "buy"
		and "flips sort first — vendor price < 85% of market · "
			.. "BUY = one stack · shift-click = pick qty"
		or ui.page == "sell" and "one stack per SELL click · right-click row = blacklist"
		or "sold items can be bought back until you log out")

	local maxScroll = math.max(0, #rows - VISIBLE)
	ui.scroll = math.min(ui.scroll or 0, maxScroll)
	W.ScrollText(ui.count, ui.scroll, VISIBLE, #rows)
	for i = 1, VISIBLE do
		local row = ui.rows[i]
		local r = rows[i + ui.scroll]
		if r then
			row:Show()
			row.tip, row.tipIdx, row.tipID = nil, nil, nil
			row.act:Show()
			row.qtyBox:Hide()
			row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
			row.name:SetText(r.name or "?")
			row.name:SetTextColor(GM.NameColor(r.id))
			row.c1:SetText("×" .. (r.qty or 1))
			if ui.page == "buy" then
				row.c2:SetText(r.ext and "alt cost"
					or (r.cost and GM.Money(r.cost) or "—"))
				row.c2:SetTextColor(GM.RGB(r.ext and "warn" or "text"))
				row.c3:SetText(r.mkt and GM.Money(r.mkt) or "no market")
				row.act.text:SetText(r.out and "OUT" or "BUY")
				row.act.text:SetTextColor(GM.RGB(r.out and "textDim"
					or r.flip and "pos" or "accent"))
				row.tip, row.tipIdx = "buy", r.index
				local idx = r.index
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
					pcall(BuyMerchantItem, idx, r.qty or 1)
					VU.Refresh()
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
					if MerchantOpen() and UseItem then
						pcall(UseItem, bag, slot)
						VU.Refresh()
					end
				end)
				row:SetScript("OnClick", function(_, btn)
					if btn == "RightButton" then
						GM.Vendoring.BlacklistToggle(r.id)
						VU.Refresh()
					elseif IsShiftKeyDown() and r.id then
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
					pcall(BuybackItem, idx)
					VU.Refresh()
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
	if not (MerchantFrame and ui and not ui.switchBtn) then return end
	ui.switchBtn = W.SwitchBtn(MerchantFrame, function()
		ui.wantDefault = nil
		VU.OnMerchantOpen()
	end, function()
		if not ui.wantDefault then GM.FramePark.Park(MerchantFrame) end
	end)
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
