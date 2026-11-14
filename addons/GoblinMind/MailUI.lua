local _, GM = ...

-- Mail takeover — same FramePark model as the professions, vendor,
-- and AH windows: on MAIL_SHOW the native MailFrame is parked
-- offscreen (never Hide()n — inbox reads, takes, and sends all need
-- the mail session alive) and this window opens in its place.
--
-- Pages:
--   INBOX — one row per mail: sender, subject, attachments, money /
--           COD, days left. OPEN = AutoLootMailItem — one call per
--           click per mail. COD mail is flagged, never auto-looted
--           (looting pays the charge — that's a pay decision, not a
--           collection). Empty mails get an armed DELETE.
--   SEND  — recipient + money fields, bag list, ATTACH moves a stack
--           into the outgoing mail (PickUp + ClickSendMailItemButton,
--           TSM's path), SEND fires SendMail — one click each.
--
-- MAIL SCAN pushes the existing collect/send plan into the planner.
-- BLIZZARD UI hands the frame back; GOBLINMIND on the native frame
-- round-trips. ESC/X close the mail session — close means close.

GM.MailUI = {}
local MU = GM.MailUI
local ui

local ROW_H = 24
local VISIBLE = 14
local tinsert, sort = tinsert, table.sort
local format = format

local W = GM.Widgets
local Btn = W.Btn

local EditBox = GM.Widgets.EditBox

local Tip = GM.Widgets.Tip

local function MailOpen()
	return MailFrame and MailFrame:IsShown()
end

local function CommandPending()
	return C_Mail and C_Mail.IsCommandPending and C_Mail.IsCommandPending()
end

-- ============ data ============

-- one row per mail: GetInboxHeaderInfo tuple mapped like TSM's
-- Inbox.GetHeaderInfo (sender/subject/money/cod/daysLeft/numItems)
local function InboxRows()
	local rows = {}
	local n = GetInboxNumItems and GetInboxNumItems() or 0
	for i = 1, n do
		local _, tex, sender, subject, money, cod, daysLeft, numItems =
			GetInboxHeaderInfo(i)
		rows[#rows + 1] = {
			index = i, sender = sender or "?",
			subject = (subject and subject ~= "") and subject or "(no subject)",
			money = money or 0, cod = cod or 0,
			items = numItems or 0, days = daysLeft, tex = tex,
		}
	end
	return rows
end

-- bag list for the send page — every stack is attachable in principle;
-- soulbound/quest items are refused by the mail box itself
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

local function PendingAttachments()
	local n = 0
	if GetSendMailItem then
		for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
			local name = GetSendMailItem(i)
			if name then n = n + 1 end
		end
	end
	return n
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { page = "inbox", scroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindMail", UIParent)
	f:SetSize(560, 430)
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
	tinsert(UISpecialFrames, "GoblinMindMail")
	ui.frame = f

	-- close means close: restore the native frame quietly and end the
	-- mail session — unless the user asked for the Blizzard frame
	f:SetScript("OnHide", function()
		GM.FramePark.Restore(MailFrame)
		if not ui.wantDefault and CloseMail then pcall(CloseMail) end
	end)
	-- inbox/bag changes → repaint (debounced)
	pcall(f.RegisterEvent, f, "MAIL_INBOX_UPDATE")
	pcall(f.RegisterEvent, f, "MAIL_SEND_INFO_UPDATE")
	pcall(f.RegisterEvent, f, "MAIL_SEND_SUCCESS")
	pcall(f.RegisterEvent, f, "MAIL_FAILED")
	pcall(f.RegisterEvent, f, "BAG_UPDATE")
	f:SetScript("OnEvent", function()
		if not f:IsShown() or ui.evPending then return end
		ui.evPending = true
		GM.After(0.2, function()
			ui.evPending = nil
			MU.Refresh()
		end)
	end)

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("MAIL")
	-- contextual takeover (mail session only) — no dashboard tab strip

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
	tabHost:SetSize(124, 20)
	tabHost:SetPoint("TOPLEFT", x, -34)
	ui.pageTabs = W.PageTabs(tabHost,
		{ { "inbox", "INBOX" }, { "send", "SEND" } },
		function(key)
			ui.page = key
			ui.scroll = 0
			MU.Refresh()
		end)
	x = x + 130
	local scan = Btn(f, 88, "MAIL SCAN", function()
		GM.Banking.MailingScan()
	end)
	scan:SetPoint("TOPLEFT", x + 6, -34)
	ui.openAllBtn = Btn(f, 76, "OPEN ALL", function() MU.OpenAll() end)
	-- inbox-page slot: shares the sendBar's anchor zone (never co-shown)
	ui.openAllBtn:SetPoint("LEFT", scan, "RIGHT", 8, 0)
	Tip(ui.openAllBtn, function()
		return { "Open all mail",
			"Loots every non-COD mail, one per ~0.5s — COD mail is",
			"skipped (looting pays the charge). Click again to stop." }
	end)
	Tip(scan, function()
		return { "Mailing scan",
			"Pushes collect/send steps into the plan queue —",
			"click-per-step as always." }
	end)
	ui.sendBar = CreateFrame("Frame", nil, f)
	ui.sendBar:SetSize(300, 20)
	ui.sendBar:SetPoint("LEFT", scan, "RIGHT", 8, 0)
	ui.to = EditBox(ui.sendBar, 110, "recipient")
	ui.to:SetPoint("LEFT")
	ui.money = EditBox(ui.sendBar, 60, "copper")
	ui.money:SetPoint("LEFT", ui.to, "RIGHT", 6, 0)
	ui.send = Btn(ui.sendBar, 52, "SEND", function() MU.Send() end)
	ui.send:SetPoint("LEFT", ui.money, "RIGHT", 6, 0)
	ui.send.text:SetTextColor(GM.RGB("accent"))
	local clear = Btn(ui.sendBar, 52, "CLEAR", function()
		pcall(ClearSendMail)
		MU.Refresh()
	end)
	clear:SetPoint("LEFT", ui.send, "RIGHT", 6, 0)

	local blizz = Btn(f, 84, "BLIZZARD UI", function()
		ui.wantDefault = true
		f:Hide() -- OnHide → Restore: native frame returns, session stays
	end)
	-- title row: the toolbar's send controls run to the right edge, so
	-- the switch button lives beside the close X instead
	blizz:SetPoint("TOPRIGHT", -26, -9)
	Tip(blizz, function()
		return { "Blizzard default UI",
			"Brings the default mailbox back and hides this",
			"window. The GOBLINMIND button on that frame switches back." }
	end)

	-- column header (labels swap per page)
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(536, 16)
	hdr:SetPoint("TOPLEFT", 12, -60)
	ui.head = {}
	for i, hx in ipairs({ 8, 150, 330, 395, 450 }) do
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
		MU.Refresh()
	end)
	ui.host = host

	ui.rows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, host)
		row:SetSize(528, ROW_H - 2)
		row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.c1 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c1:SetPoint("LEFT", 8, 0)
		row.c1:SetWidth(134)
		row.c1:SetJustifyH("LEFT")
		row.c2 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c2:SetPoint("LEFT", 150, 0)
		row.c2:SetWidth(172)
		row.c2:SetJustifyH("LEFT")
		row.c3 = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.c3:SetPoint("LEFT", 330, 0)
		row.c4 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c4:SetPoint("LEFT", 395, 0)
		row.c5 = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.c5:SetPoint("LEFT", 450, 0)
		row.c5:SetWidth(24) -- keep clear of the row action button
		local act = CreateFrame("Button", nil, row)
		act:SetSize(46, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		row.act = act
		ui.rows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
end

-- ============ actions ============

-- one click per mail: take everything. COD mail is never auto-looted —
-- looting pays the charge, and that's a pay decision.
local function OpenMail(r)
	if CommandPending() then return end
	pcall(AutoLootMailItem, r.index)
	MU.Refresh()
end

-- Blizzard's Open All, our way: a click-initiated pass that loots the
-- next non-COD mail every ~0.5s (server-command throttle respected via
-- IsCommandPending). COD mail is skipped — looting pays the charge.
-- Mail takes aren't protected calls, so one click starting the chain
-- is the same thing Blizzard's own Open All button does. Click again
-- (or close) to stop.
function MU.OpenAll()
	if ui.openingAll then
		ui.openingAll = nil
		ui.openAllBtn.text:SetText("OPEN ALL")
		return
	end
	ui.openingAll = true
	local step
	step = function()
		if not (ui.openingAll and ui.frame:IsShown() and MailOpen()) then
			ui.openingAll = nil
			MU.Refresh()
			return
		end
		-- next lootable mail, rescanning each pass — indexes shift as
		-- collected mails get deleted by the server
		local next_i
		for _, r in ipairs(InboxRows()) do
			if (r.money > 0 or r.items > 0) and r.cod <= 0 then
				next_i = r.index
				break
			end
		end
		if not next_i then
			ui.openingAll = nil
			ui.openAllBtn.text:SetText("OPEN ALL")
			MU.Refresh()
			return
		end
		if CommandPending() then
			GM.After(0.4, step) -- server busy — retry shortly
			return
		end
		pcall(AutoLootMailItem, next_i)
		ui.openAllBtn.text:SetText("OPENING…")
		GM.After(0.45, step)
	end
	step()
end

local function Attach(r)
	-- TSM's Inbox.AddItemToMail path: pick the stack up, click the
	-- parked frame's send-item button. If the box refuses it (soulbound,
	-- full), the stack stays on the cursor — ClearCursor puts it back.
	local pickup = C_Container and C_Container.PickupContainerItem
	if not (pickup and ClickSendMailItemButton) then return end
	pickup(r.bag, r.slot)
	ClickSendMailItemButton()
	if GetCursorInfo and GetCursorInfo() then ClearCursor() end
	MU.Refresh()
end

function MU.Send()
	local to = strtrim(ui.to:GetText() or "")
	if to == "" or to == "recipient" then
		GM.Print(GM.CC("warn") .. "recipient first|r")
		return
	end
	local copper = tonumber(ui.money:GetText()) or 0
	if copper < 0 then copper = 0 end
	local name = GetSendMailItem and GetSendMailItem(1)
	if copper > 0 then
		pcall(SetSendMailMoney, copper)
	end
	local ok, err = pcall(SendMail, to,
		(name and name ~= "") and name or "GoblinMind", "")
	if not ok then
		GM.Print(GM.CC("err") .. "SendMail: " .. tostring(err) .. "|r")
	end
	MU.Refresh()
end

-- ============ refresh ============

function MU.Refresh()
	if not ui then return end
	local open = MailOpen()
	ui.pageTabs.set(ui.page)
	ui.sendBar:SetShown(ui.page == "send")
	ui.openAllBtn:SetShown(ui.page == "inbox")

	if ui.page == "inbox" then
		for i, t in ipairs({ "SENDER", "SUBJECT", "ITEMS", "GOLD", "DAYS" }) do
			ui.head[i]:SetText(t)
		end
		local rows = open and InboxRows() or {}
		ui.empty:SetText(not open and "open the mailbox"
			or (#rows == 0 and "inbox empty" or ""))
		ui.empty:SetShown(#rows == 0)
		ui.foot:SetText("OPEN = one mail per click · COD is flagged, never "
			.. "auto-looted · DELETE arms on empty mail")
		local maxScroll = math.max(0, #rows - VISIBLE)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.count, ui.scroll, VISIBLE, #rows)
		for i = 1, VISIBLE do
			local row, r = ui.rows[i], rows[i + ui.scroll]
			if r then
				row:Show()
				row.c1:SetText(r.sender)
				row.c2:SetText(r.subject)
				row.c3:SetText(r.items > 0 and ("×" .. r.items .. " item"
					.. (r.items == 1 and "" or "s")) or "")
				if r.cod > 0 then
					row.c4:SetText(GM.CC("warn") .. "COD " .. GM.Money(r.cod) .. "|r")
				else
					row.c4:SetText(r.money > 0 and GM.Money(r.money) or "")
				end
				row.c5:SetText(r.days and format("%.0fd", r.days) or "")
				row.act.text:SetText(r.cod > 0 and "COD"
					or ((r.money > 0 or r.items > 0) and "OPEN" or "DEL"))
				row.act.text:SetTextColor(GM.RGB(r.cod > 0 and "warn"
					or (r.money > 0 or r.items > 0) and "accent" or "err"))
				local mail = r
				row.act:SetScript("OnClick", function(act)
					if mail.cod > 0 then return end
					if mail.money > 0 or mail.items > 0 then
						OpenMail(mail)
					elseif not act.armed then
						act.armed = true
						act.text:SetText("SURE?")
					else
						pcall(DeleteInboxItem, mail.index)
						MU.Refresh()
					end
				end)
				-- attachments in the hover tip
				row:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					local shown
					for j = 1, mail.items do
						local link = GetInboxItemLink
							and GetInboxItemLink(mail.index, j)
						if link then
							if not shown then GameTooltip:AddLine(mail.subject, 1, 1, 1) shown = true end
							GameTooltip:AddLine(link)
						end
					end
					if mail.money > 0 then
						if not shown then GameTooltip:AddLine(mail.subject, 1, 1, 1) shown = true end
						GameTooltip:AddLine("money: " .. GM.Money(mail.money), 0.8, 0.8, 0.2)
					end
					if mail.cod > 0 then
						if not shown then GameTooltip:AddLine(mail.subject, 1, 1, 1) shown = true end
						GameTooltip:AddLine("COD due: " .. GM.Money(mail.cod), 1, 0.4, 0.4)
					end
					if shown then GameTooltip:Show() end
				end)
				row:SetScript("OnLeave", function() GameTooltip:Hide() end)
			else
				row:Hide()
			end
		end
	else
		-- SEND page: bag stacks, ATTACH per row
		for i, t in ipairs({ "ITEM", "", "QTY", "", "" }) do
			ui.head[i]:SetText(t)
		end
		local pend = PendingAttachments()
		ui.head[2]:SetText(format("%d attached", pend))
		local rows = open and BagRows() or {}
		ui.empty:SetText(not open and "open the mailbox"
			or (#rows == 0 and "bags empty" or ""))
		ui.empty:SetShown(#rows == 0)
		ui.foot:SetText("ATTACH moves a stack into the outgoing mail · "
			.. "copper field sends gold · SEND is one click")
		local maxScroll = math.max(0, #rows - VISIBLE)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.count, ui.scroll, VISIBLE, #rows)
		for i = 1, VISIBLE do
			local row, r = ui.rows[i], rows[i + ui.scroll]
			if r then
				row:Show()
				row.c1:SetText(r.name)
				row.c2:SetText("")
				row.c3:SetText("×" .. r.qty)
				row.c4:SetText("")
				row.c5:SetText("")
				row.act.text:SetText("ATTACH")
				row.act.text:SetTextColor(GM.RGB("accent"))
				local item = r
				row.act:SetScript("OnClick", function() Attach(item) end)
				row:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					GameTooltip:SetItemByID(item.id)
					GameTooltip:Show()
				end)
				row:SetScript("OnLeave", function() GameTooltip:Hide() end)
			else
				row:Hide()
			end
		end
	end
end

-- ============ takeover ============

local function EnsureSwitchBtn()
	if not (MailFrame and ui and not ui.switchBtn) then return end
	local b = CreateFrame("Button", nil, MailFrame)
	b:SetSize(84, 16)
	b:SetPoint("TOPRIGHT", MailFrame, "TOPRIGHT", -40, -8)
	b:SetFrameLevel(MailFrame:GetFrameLevel() + 20)
	GM.Panel(b, "accent")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "contLowest")
	b.text:SetPoint("CENTER")
	b.text:SetText("GOBLINMIND")
	b:SetScript("OnClick", function()
		ui.wantDefault = nil
		MU.OnMailOpen()
	end)
	ui.switchBtn = b
	MailFrame:HookScript("OnShow", function()
		if not ui.wantDefault then GM.FramePark.Park(MailFrame) end
	end)
end

function MU.OnMailOpen()
	Build()
	EnsureSwitchBtn()
	if ui.wantDefault then return end
	ui.frame:Show()
	pcall(CheckInbox)
	MU.Refresh()
	-- the panel manager may still be positioning it; park now + retry
	GM.FramePark.Park(MailFrame)
	GM.After(0.3, function() GM.FramePark.Park(MailFrame) end)
end

function MU.Show()
	Build()
	ui.frame:Show()
	MU.Refresh()
end

function MU.Hide()
	if ui then ui.frame:Hide() end
end

function MU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else MU.Show() end
end

-- repaint when item names resolve asynchronously
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then MU.Refresh() end
	end)
end

-- mail session drives the takeover
local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "MAIL_SHOW")
pcall(f.RegisterEvent, f, "MAIL_CLOSED")
f:SetScript("OnEvent", function(_, e)
	if e == "MAIL_SHOW" then
		MU.OnMailOpen()
	elseif ui and ui.frame then
		ui.frame:Hide()
	end
end)
