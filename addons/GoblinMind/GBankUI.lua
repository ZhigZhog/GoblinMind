local _, GM = ...

-- Guild-bank takeover — same FramePark model as the rest: on
-- GUILDBANKFRAME_OPENED the native frame parks offscreen (kept alive —
-- gbank reads and moves need the session) and this window opens.
--
-- Left pane BAGS → deposits a stack into the current gbank tab
-- (pickup + PickupGuildBankItem on a merge/empty slot — the same
-- swap mechanic as Banking.MoveStack). Right pane = the current gbank
-- tab, ← withdraws a stack into bags. Tab buttons run along the top of
-- the gbank pane; tab permissions (view/deposit/withdraw + remaining
-- withdrawals) gate the arrows.
--
-- BLIZZARD UI hands the frame back; GOBLINMIND round-trips. ESC/X
-- close the session — close means close.

GM.GBankUI = {}
local GU = GM.GBankUI
local ui

local ROW_H = 24
local VISIBLE = 14
local PickupItem = C_Container and C_Container.PickupContainerItem
	or PickupContainerItem
local tinsert, sort = tinsert, table.sort
local format = format

local W = GM.Widgets
local Btn = W.Btn

local Tip = GM.Widgets.Tip

local function GBankOpen()
	return GuildBankFrame and GuildBankFrame:IsShown()
end

local function CurTab()
	return GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 1
end

-- canView, canDeposit, canWithdraw, remainingWithdrawals
local function TabPerms(tab)
	if not GetGuildBankTabPermissions then
		return true, true, true, nil
	end
	return GetGuildBankTabPermissions(tab)
end

local function BagRows()
	local rows = {}
	for _, s in ipairs(GM.Banking.BagSlots()) do
		if s.itemID then
			rows[#rows + 1] = {
				bag = s.bag, slot = s.slot, id = s.itemID,
				qty = s.count,
				name = GM.ItemName(s.itemID) or ("item " .. s.itemID),
			}
		end
	end
	sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)
	return rows
end

local function GBankRows(tab)
	local rows = {}
	local n = GetNumGuildBankSlots and GetNumGuildBankSlots(tab) or 98
	for slot = 1, n do
		local link = GetGuildBankItemLink and GetGuildBankItemLink(tab, slot)
		if link then
			local id = tonumber(link:match("item:(%d+)"))
			local _, count = GetGuildBankItemInfo(tab, slot)
			if id then
				rows[#rows + 1] = {
					slot = slot, id = id, qty = count or 1,
					name = GM.ItemName(id) or ("item " .. id),
				}
			end
		end
	end
	return rows
end

-- find the drop slot in the gbank tab for an item — merge onto a
-- partial first, then the first empty slot
local function GDstSlot(tab, itemID)
	local n = GetNumGuildBankSlots and GetNumGuildBankSlots(tab) or 98
	local max = itemID and select(8,
		(C_Item and C_Item.GetItemInfo or GetItemInfo)(itemID))
	for slot = 1, n do
		local link = GetGuildBankItemLink(tab, slot)
		local id = link and tonumber(link:match("item:(%d+)"))
		if id == itemID then
			local _, count = GetGuildBankItemInfo(tab, slot)
			if max and (count or 0) < max then return slot end
		end
	end
	for slot = 1, n do
		if not GetGuildBankItemLink(tab, slot) then return slot end
	end
end

-- deposit one bag stack into the current tab
local function Deposit(r, tab)
	local dst = GDstSlot(tab, r.id)
	if not dst then
		GM.Print(GM.CC("warn") .. "[gbank] tab full|r")
		return
	end
	PickupItem(r.bag, r.slot)
	PickupGuildBankItem(tab, dst)
	if GetCursorInfo and GetCursorInfo() then ClearCursor() end
	GM.After(0.3, GU.Refresh)
end

-- withdraw one gbank stack into bags — merge onto a bag partial first
local function Withdraw(r, tab)
	local max = select(8, (C_Item and C_Item.GetItemInfo or GetItemInfo)(r.id))
	local dst
	for _, s in ipairs(GM.Banking.BagSlots()) do
		if s.itemID == r.id and max and s.count < max then dst = s break end
	end
	if not dst then
		for _, s in ipairs(GM.Banking.BagSlots()) do
			if not s.itemID then dst = s break end
		end
	end
	if not dst then
		GM.Print(GM.CC("warn") .. "[gbank] bags full|r")
		return
	end
	PickupGuildBankItem(tab, r.slot)
	PickupItem(dst.bag, dst.slot)
	if GetCursorInfo and GetCursorInfo() then ClearCursor() end
	GM.After(0.3, GU.Refresh)
end

local function MakeRow(parent, i, arrow)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(304, ROW_H - 2)
	row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
	W.HoverTint(row)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 4, 0)
	row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.name:SetPoint("LEFT", 26, 0)
	row.name:SetWidth(180)
	row.name:SetJustifyH("LEFT")
	row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.qty:SetPoint("LEFT", 210, 0)
	local act = CreateFrame("Button", nil, row)
	act:SetSize(36, 16)
	act:SetPoint("RIGHT", -4, 0)
	GM.Panel(act, "contHigh")
	act.text = GM.MakeFontString(act, GM.FONT_BOLD, 10, "accent")
	act.text:SetPoint("CENTER")
	act.text:SetText(arrow)
	row.act = act
	-- disabled moves explain themselves on hover — a dead arrow with
	-- no reason reads as a bug
	Tip(act, function()
		return row.actWhy and { row.actWhy } or nil
	end)
	row:SetScript("OnEnter", function(self)
		if self.tipID then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.tipID)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return row
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { lScroll = 0, rScroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindGBank", UIParent)
	f:SetSize(680, 460)
	f:SetPoint("CENTER", -60, -20)
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
	tinsert(UISpecialFrames, "GoblinMindGBank")
	ui.frame = f

	f:SetScript("OnHide", function()
		GM.FramePark.Restore(GuildBankFrame)
		if not ui.wantDefault and CloseGuildBankFrame then
			pcall(CloseGuildBankFrame)
		end
	end)
	pcall(f.RegisterEvent, f, "BAG_UPDATE")
	pcall(f.RegisterEvent, f, "GUILDBANKBAGSLOTS_CHANGED")
	pcall(f.RegisterEvent, f, "GUILDBANKTAB_CHANGED")
	pcall(f.RegisterEvent, f, "GUILDBANK_UPDATE_TABS")
	f:SetScript("OnEvent", function()
		if not f:IsShown() or ui.evPending then return end
		ui.evPending = true
		GM.After(0.2, function()
			ui.evPending = nil
			GU.Refresh()
		end)
	end)

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("GUILD BANK")
	-- contextual takeover (gbank session only) — no dashboard tab strip

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	ui.summary = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.summary:SetPoint("TOPLEFT", 12, -38)
	ui.summary:SetJustifyH("LEFT")

	local blizz = Btn(f, 84, "BLIZZARD UI", function()
		ui.wantDefault = true
		f:Hide() -- OnHide → Restore: native frame returns, session stays
	end)
	blizz:SetPoint("TOPRIGHT", -28, -34)
	Tip(blizz, function()
		return { "Blizzard default UI",
			"Brings the default guild bank back and hides this",
			"window. The GOBLINMIND button on that frame switches back." }
	end)

	-- gbank tab strip (built at refresh — tab count/name arrive async)
	ui.tabs = CreateFrame("Frame", nil, f)
	ui.tabs:SetSize(320, 20)
	ui.tabs:SetPoint("TOPRIGHT", -12, -60)
	ui.tabBtns = {}

	ui.lp = CreateFrame("Frame", nil, f)
	ui.lp:SetSize(320, VISIBLE * ROW_H + 30)
	ui.lp:SetPoint("TOPLEFT", 12, -84)
	GM.Panel(ui.lp, "contLowest")
	local lh = GM.MakeFontString(ui.lp, GM.FONT_BOLD, 9, "secondary")
	lh:SetPoint("TOPLEFT", 8, -6)
	lh:SetText("BAGS → deposit")
	ui.lp.count = GM.MakeFontString(ui.lp, GM.FONT, 9, "textDim")
	ui.lp.count:SetPoint("TOPRIGHT", -8, -7)
	ui.lp:EnableMouseWheel(true)
	ui.lp:SetScript("OnMouseWheel", function(_, d)
		ui.lScroll = math.max(0, ui.lScroll - d * 3)
		GU.Refresh()
	end)
	ui.lEmpty = GM.MakeFontString(ui.lp, GM.FONT, 10, "textDim")
	ui.lEmpty:SetPoint("CENTER", 0, -10)
	ui.lrows = {}
	for i = 1, VISIBLE do ui.lrows[i] = MakeRow(ui.lp, i, "→") end

	ui.rp = CreateFrame("Frame", nil, f)
	ui.rp:SetSize(320, VISIBLE * ROW_H + 30)
	ui.rp:SetPoint("TOPRIGHT", -12, -84)
	GM.Panel(ui.rp, "contLowest")
	ui.rHead = GM.MakeFontString(ui.rp, GM.FONT_BOLD, 9, "secondary")
	ui.rHead:SetPoint("TOPLEFT", 8, -6)
	ui.rp.count = GM.MakeFontString(ui.rp, GM.FONT, 9, "textDim")
	ui.rp.count:SetPoint("TOPRIGHT", -8, -7)
	ui.rp:EnableMouseWheel(true)
	ui.rp:SetScript("OnMouseWheel", function(_, d)
		ui.rScroll = math.max(0, ui.rScroll - d * 3)
		GU.Refresh()
	end)
	ui.rEmpty = GM.MakeFontString(ui.rp, GM.FONT, 10, "textDim")
	ui.rEmpty:SetPoint("CENTER", 0, -10)
	ui.rrows = {}
	for i = 1, VISIBLE do ui.rrows[i] = MakeRow(ui.rp, i, "←") end

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
	ui.foot:SetText("one stack per click · merges onto matching partials "
		.. "first · tab permissions gate the arrows")
end

-- ============ refresh ============

local function FillTabs()
	local n = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
	local cur = CurTab()
	for i, b in ipairs(ui.tabBtns) do b:SetShown(i <= n) end
	for i = 1, n do
		local b = ui.tabBtns[i]
		if not b then
			b = CreateFrame("Button", nil, ui.tabs)
			b:SetSize(46, 18)
			GM.Panel(b, "contHigh")
			b.icon = b:CreateTexture(nil, "ARTWORK")
			b.icon:SetSize(14, 14)
			b.icon:SetPoint("LEFT", 3, 0)
			b.text = GM.MakeFontString(b, GM.FONT_BOLD, 8, "textDim")
			b.text:SetPoint("RIGHT", -4, 0)
			b:SetPoint("TOPLEFT", -((i - 1) * 50), 0)
			local t = i
			b:SetScript("OnClick", function()
				pcall(SetCurrentGuildBankTab, t)
				pcall(QueryGuildBankTab, t)
				GM.After(0.3, GU.Refresh)
			end)
			-- install once and read the live tab name at hover — Tip()
			-- hooks OnEnter, so installing per refresh accumulated
			-- stale closures on every repaint
			Tip(b, function()
				local n = GetGuildBankTabInfo and GetGuildBankTabInfo(t)
				return n and { n } or nil
			end)
			ui.tabBtns[i] = b
		end
		local name, icon = GetGuildBankTabInfo and GetGuildBankTabInfo(i)
		b.text:SetText(tostring(i))
		if icon then b.icon:SetTexture(icon) end
		b.text:SetTextColor(GM.RGB(i == cur and "accent" or "textDim"))
		b.icon:SetDesaturated(i ~= cur)
	end
end

local function Fill(rows, vis, scrollKey, onAct, actEnabled, disabledWhy)
	local maxScroll = math.max(0, #rows - VISIBLE)
	ui[scrollKey] = math.min(ui[scrollKey] or 0, maxScroll)
	W.ScrollText(vis[1]:GetParent().count, ui[scrollKey], VISIBLE, #rows)
	for i = 1, VISIBLE do
		local row, r = vis[i], rows[i + ui[scrollKey]]
		if r then
			row:Show()
			row.tipID = r.id
			row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
			row.name:SetText(r.name or "?")
			row.qty:SetText("×" .. r.qty)
			if actEnabled == false then
				row.act.text:SetTextColor(GM.RGB("textDim"))
				row.act:SetScript("OnClick", nil)
				row.actWhy = disabledWhy
			else
				row.act.text:SetTextColor(GM.RGB("accent"))
				row.actWhy = nil
				local item = r
				row.act:SetScript("OnClick", function() onAct(item) end)
			end
		else
			row:Hide()
		end
	end
end

function GU.Refresh()
	if not ui then return end
	local open = GBankOpen()
	FillTabs()
	local tab = CurTab()
	local canView, canDep, canWd, wdLeft = TabPerms(tab)
	local bagRows = BagRows()
	local gRows = (open and canView) and GBankRows(tab) or {}
	local tabName = GetGuildBankTabInfo and GetGuildBankTabInfo(tab)
	ui.rHead:SetText(format("TAB %d%s → withdraw", tab,
		tabName and (" · " .. tabName) or ""))
	ui.summary:SetText(format("%d stacks in bags%s",
		#bagRows,
		wdLeft and format(" · %d withdrawals left", wdLeft) or ""))
	ui.lEmpty:SetText(#bagRows == 0 and "bags empty" or "")
	ui.lEmpty:SetShown(#bagRows == 0)
	ui.rEmpty:SetText(not open and "open the guild bank"
		or not canView and "no view permission on this tab"
		or (#gRows == 0 and "tab empty" or ""))
	ui.rEmpty:SetShown(#gRows == 0)
	Fill(bagRows, ui.lrows, "lScroll",
		function(r) Deposit(r, tab) end, canDep and open,
		not open and "guild bank closed"
			or not canDep and "no deposit permission on this tab"
			or nil)
	Fill(gRows, ui.rrows, "rScroll",
		function(r) Withdraw(r, tab) end, canWd and open
			and (wdLeft == nil or wdLeft > 0),
		not open and "guild bank closed"
			or not canWd and "no withdraw permission on this tab"
			or (wdLeft ~= nil and wdLeft <= 0)
				and "daily withdrawal limit reached"
			or nil)
end

-- ============ takeover ============

local function EnsureSwitchBtn()
	if not (GuildBankFrame and ui and not ui.switchBtn) then return end
	local b = CreateFrame("Button", nil, GuildBankFrame)
	b:SetSize(84, 16)
	b:SetPoint("TOPRIGHT", GuildBankFrame, "TOPRIGHT", -40, -8)
	b:SetFrameLevel(GuildBankFrame:GetFrameLevel() + 20)
	GM.Panel(b, "accent")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "contLowest")
	b.text:SetPoint("CENTER")
	b.text:SetText("GOBLINMIND")
	b:SetScript("OnClick", function()
		ui.wantDefault = nil
		GU.OnGBankOpen()
	end)
	ui.switchBtn = b
	GuildBankFrame:HookScript("OnShow", function()
		if not ui.wantDefault then GM.FramePark.Park(GuildBankFrame) end
	end)
end

function GU.OnGBankOpen()
	Build()
	EnsureSwitchBtn()
	if ui.wantDefault then return end
	ui.frame:Show()
	-- tab contents arrive async — query the current tab, refresh on land
	pcall(QueryGuildBankTab, CurTab())
	GU.Refresh()
	GM.FramePark.Park(GuildBankFrame)
	GM.After(0.3, function() GM.FramePark.Park(GuildBankFrame) end)
end

function GU.Show()
	Build()
	ui.frame:Show()
	GU.Refresh()
end

function GU.Hide()
	if ui then ui.frame:Hide() end
end

function GU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else GU.Show() end
end

-- repaint when item names/icons resolve asynchronously
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then GU.Refresh() end
	end)
end

-- gbank session drives the takeover — events first, with a poller as
-- backstop: the frame may come up via a path this client doesn't flag
-- with GUILDBANKFRAME_OPENED (the no-tabs state hit exactly that).
local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "GUILDBANKFRAME_OPENED")
pcall(f.RegisterEvent, f, "GUILDBANKFRAME_CLOSED")
pcall(f.RegisterEvent, f, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
pcall(f.RegisterEvent, f, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
f:SetScript("OnEvent", function(_, e, arg1)
	if e == "GUILDBANKFRAME_OPENED" then
		GU.OnGBankOpen()
	elseif e == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
		-- Enum.PlayerInteractionType.GuildBanker — check the frame, not
		-- the enum value (it may differ on this client)
		if GuildBankFrame and GuildBankFrame:IsShown() then GU.OnGBankOpen() end
	elseif e == "GUILDBANKFRAME_CLOSED" then
		if ui and ui.frame then ui.frame:Hide() end
	end
end)
-- poller: shown native frame + hidden ours (and no Blizzard request)
-- means the takeover should run regardless of which event path fired
local pollT = 0
f:SetScript("OnUpdate", function(_, e)
	pollT = pollT + e
	if pollT < 0.5 then return end
	pollT = 0
	if GuildBankFrame and GuildBankFrame:IsShown() then
		if not (ui and ui.frame and ui.frame:IsShown())
			and not (ui and ui.wantDefault) then
			GU.OnGBankOpen()
		end
	elseif ui and ui.frame and ui.frame:IsShown() then
		ui.frame:Hide()
	end
end)
