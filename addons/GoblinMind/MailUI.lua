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
local VISIBLE = 15
local VISIBLE_SEND = 10 -- SEND page gives the rest to the compose strip
local SUBJ_HINT = "subject — default: first attached item"
local BODY_HINT = "message (optional)"
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

-- ============ recipient autocomplete ============
-- TSM-style inline complete: the first prefix-match fills the box
-- with the remainder highlighted — keep typing to refine or move on.
-- Candidates ordered most-likely-first: recent sends, account alts,
-- friends, guild roster.
local REALM = GetRealmName and (GetRealmName():gsub("%s", "")) or ""
local function ShortName(n)
	if not n then return end
	if Ambiguate then return Ambiguate(n, "mail") end
	local base, r = n:match("^([^%-]+)%-(.+)$")
	if r and r:gsub("%s", "") == REALM then return base end
	return n
end

local function RecipientNames()
	local names, seen = {}, {}
	local me = UnitName and UnitName("player") or ""
	local function add(n)
		n = n and strtrim(ShortName(n) or "")
		if not n or n == "" or n == me then return end
		local k = n:lower()
		if not seen[k] then seen[k] = true names[#names + 1] = n end
	end
	for _, r in ipairs(GM.db and GM.db.mailRecent or {}) do add(r) end
	for _, ck in ipairs(GM.Ledger and GM.Ledger.Chars() or {}) do add(ck) end
	local nf = C_FriendList and C_FriendList.GetNumFriends
		and C_FriendList.GetNumFriends() or 0
	for i = 1, nf do
		local info = C_FriendList.GetFriendInfoByIndex(i)
		add(info and info.name)
	end
	if IsInGuild and IsInGuild() and GetNumGuildMembers then
		for i = 1, GetNumGuildMembers() do
			add((GetGuildRosterInfo(i)))
		end
	end
	return names
end

local acList -- rebuilt each time the recipient box takes focus
local function ACOnChar(eb)
	if IsControlKeyDown() then return end
	local text = eb:GetText() or ""
	if text == "" or text == "recipient" then return end
	local lt = text:lower()
	for _, k in ipairs(acList or {}) do
		if #k > #text and k:lower():sub(1, #lt) == lt then
			eb:SetText(k)
			eb:HighlightText(#text, #k)
			break
		end
	end
end

-- remember a recipient after a successful send (dedup, cap 10)
local function PushRecent(to)
	if not GM.db then return end
	local rec = GM.db.mailRecent
	if not rec then rec = {} GM.db.mailRecent = rec end
	for i, r in ipairs(rec) do
		if r:lower() == to:lower() then tremove(rec, i) break end
	end
	tinsert(rec, 1, to)
	while #rec > 10 do tremove(rec) end
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

-- outgoing-mail attachments: {sendIdx, name, qty} per filled send
-- slot. Return 1 is the item name (used by PendingAttachments before);
-- the stack count is the LAST return in the (name, id, tex, count)
-- signature — grab it position-agnostically.
local function AttachedList()
	local list = {}
	if GetSendMailItem then
		for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
			local ret = { GetSendMailItem(i) }
			local name = ret[1]
			if name then
				list[#list + 1] = {
					sendIdx = i, name = name,
					qty = tonumber(ret[#ret]) or 0,
				}
			end
		end
	end
	return list
end

-- send-page rows: bag stacks + attached items. Exactly one row is
-- marked per filled send slot — locked stacks claim their name's
-- attachments first; when the client doesn't report locks, the first
-- same-name bag row claims instead (which stack is the attached one
-- is unknowable, but the count is honest and DETACH still works —
-- it operates on the send slot, not the bag slot). Attachments that
-- left the bag entirely show as their own row at the top.
local function SendRows()
	local attached = AttachedList()
	local attByName = {} -- name → queue of attachment entries
	for _, a in ipairs(attached) do
		local q = attByName[a.name] or {}
		q[#q + 1] = a
		attByName[a.name] = q
	end
	local rows, lockedByName = {}, {}
	for _, s in ipairs(GM.Banking.BagSlots()) do
		if s.itemID then
			local name = GM.ItemName(s.itemID) or ("item " .. s.itemID)
			if s.locked then lockedByName[name] = (lockedByName[name] or 0) + 1 end
			rows[#rows + 1] = {
				bag = s.bag, slot = s.slot, id = s.itemID,
				qty = s.count, name = name, locked = s.locked,
			}
		end
	end
	local function Claim(r)
		local q = attByName[r.name]
		if q and #q > 0 then
			local a = tremove(q, 1)
			r.attached = a.sendIdx
			r.qty = a.qty > 0 and a.qty or r.qty
			a.claimed = true
		end
	end
	for _, r in ipairs(rows) do
		if r.locked then Claim(r) end
	end
	for _, r in ipairs(rows) do
		if not r.attached and (lockedByName[r.name] or 0) == 0 then Claim(r) end
	end
	for _, list in pairs(attByName) do
		for _, a in ipairs(list) do
			if not a.claimed then
				rows[#rows + 1] = {
					qty = a.qty, name = a.name, attached = a.sendIdx,
				}
			end
		end
	end
	sort(rows, function(a, b)
		if (a.attached ~= nil) ~= (b.attached ~= nil) then
			return a.attached ~= nil
		end
		return (a.name or "") < (b.name or "")
	end)
	return rows, #attached
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { page = "inbox", scroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindMail", UIParent)
	f:SetSize(560, 480)
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

	-- toolbar: page toggles + actions — PageTabs strides 62px per tab,
	-- so host width and the button offset both follow the defs count
	local x = 12
	local tabDefs = {
		{ "inbox", "INBOX" }, { "send", "SEND" }, { "groups", "GROUPS" },
	}
	local tabHost = CreateFrame("Frame", nil, f)
	tabHost:SetSize(#tabDefs * 62, 20)
	tabHost:SetPoint("TOPLEFT", x, -34)
	ui.pageTabs = W.PageTabs(tabHost, tabDefs, function(key)
		ui.page = key
		ui.scroll = 0
		MU.Refresh()
	end)
	x = x + #tabDefs * 62
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
	ui.to:SetScript("OnChar", ACOnChar)
	ui.to:HookScript("OnEditFocusGained", function()
		acList = RecipientNames()
	end)
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
	ui.hdr = hdr

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
		row.c2:SetWordWrap(false)
		row.c3 = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.c3:SetPoint("LEFT", 330, 0)
		row.c1:SetWordWrap(false)
		row.c4 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c4:SetPoint("LEFT", 395, 0)
		row.c4:SetWidth(52) -- "COD Xg Xs Xc" must not reach c5
		row.c4:SetJustifyH("LEFT")
		row.c4:SetWordWrap(false)
		row.c5 = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.c5:SetPoint("LEFT", 450, 0)
		row.c3:SetWidth(60)
		row.c3:SetJustifyH("LEFT")
		row.c3:SetWordWrap(false)
		row.c5:SetWidth(24) -- keep clear of the row action button
		row.c5:SetWordWrap(false)
		local act = CreateFrame("Button", nil, row)
		act:SetSize(46, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		row.act = act
		W.ModifiedClick(row, function() return row.tipID end)
		ui.rows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")

	-- compose strip (send page only): subject + multiline body sit
	-- above the list; Refresh slides the header/host down to make room
	local comp = CreateFrame("Frame", nil, f)
	comp:SetSize(536, 112)
	comp:SetPoint("TOPLEFT", 12, -60)
	GM.Panel(comp, "contLowest", "outlineVar")
	ui.subject = EditBox(comp, 524, SUBJ_HINT)
	ui.subject:SetPoint("TOPLEFT", 6, -6)
	ui.subject:SetTextInsets(8, 8, 0, 0)
	ui.body = EditBox(comp, 524, BODY_HINT)
	ui.body:SetPoint("TOPLEFT", 6, -28)
	ui.body:SetPoint("BOTTOMRIGHT", -6, 8) -- fills the strip's remainder
	ui.body:SetMultiLine(true)
	ui.body:SetTextInsets(8, 8, 6, 6)
	-- multiline Enter is a newline, not "accept"
	ui.body:SetScript("OnEnterPressed", function() end)
	ui.body:SetMaxLetters(500)
	ui.compose = comp
	comp:Hide()
	-- tab hops through the compose fields
	ui.to:SetScript("OnTabPressed", function() ui.subject:SetFocus() end)
	ui.subject:SetScript("OnTabPressed", function() ui.body:SetFocus() end)
	ui.body:SetScript("OnTabPressed", function() ui.body:ClearFocus() end)

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
end

-- ============ actions ============

-- HasNewMail()/the inbox snapshot only move when the server pushes
-- fresh headers. After our loots (and on open, while pending mail is
-- still in flight) the mail icon lags seconds behind the truth.
-- CheckInbox fetches headers now instead of waiting for the lazy
-- refresh — one pull in flight is enough, headers are a snapshot.
local PullInbox = GM.PullInbox

-- one click per mail: take everything. COD mail is never auto-looted —
-- looting pays the charge, and that's a pay decision.
local function OpenMail(r)
	if CommandPending() then return end
	pcall(AutoLootMailItem, r.index)
	PullInbox()
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
	ui.openedCount = 0
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
			if ui.openedCount and ui.openedCount > 0 then
				GM.Print(format("open all: %d mail collected", ui.openedCount))
			end
			PullInbox() -- final state: flag drops as the last headers land
			MU.Refresh()
			return
		end
		if CommandPending() then
			GM.After(0.4, step) -- server busy — retry shortly
			return
		end
		pcall(AutoLootMailItem, next_i)
		PullInbox()
		ui.openedCount = (ui.openedCount or 0) + 1
		ui.openAllBtn.text:SetText("OPENING · " .. ui.openedCount)
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

local function Detach(r)
	-- clicking a filled send slot lifts the stack to the cursor; drop
	-- it into the first free bag slot (ClearCursor as fallback)
	local pickup = C_Container and C_Container.PickupContainerItem
	if not (r.attached and ClickSendMailItemButton) then return end
	ClickSendMailItemButton(r.attached)
	if GetCursorInfo and GetCursorInfo() then
		if pickup then
			for _, s in ipairs(GM.Banking.BagSlots()) do
				if not s.itemID then
					pickup(s.bag, s.slot)
					break
				end
			end
		end
		if GetCursorInfo() then ClearCursor() end
	end
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
	-- hint strings survive unfocused boxes — treat them as empty
	local subj = strtrim(ui.subject and ui.subject:GetText() or "")
	if subj == "" or subj == SUBJ_HINT then
		subj = (name and name ~= "") and name or "GoblinMind"
	end
	local body = strtrim(ui.body and ui.body:GetText() or "")
	if body == BODY_HINT then body = "" end
	local ok, err = pcall(SendMail, to, subj, body)
	if ok then
		PushRecent(to)
	else
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
	-- layout swap: the compose strip pushes the list down on SEND
	ui.compose:SetShown(ui.page == "send")
	local vis = VISIBLE
	ui.hdr:ClearAllPoints()
	ui.host:ClearAllPoints()
	if ui.page == "send" then
		vis = VISIBLE_SEND
		ui.hdr:SetPoint("TOPLEFT", 12, -180)
		ui.host:SetPoint("TOPLEFT", 12, -198)
	else
		ui.hdr:SetPoint("TOPLEFT", 12, -60)
		ui.host:SetPoint("TOPLEFT", 12, -78)
	end
	ui.host:SetHeight(vis * ROW_H + 4)

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
		local maxScroll = math.max(0, #rows - vis)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.count, ui.scroll, vis, #rows)
		for i = 1, VISIBLE do
			local row = ui.rows[i]
			local r = i <= vis and rows[i + ui.scroll] or nil
			if r then
				row:Show()
				row.tipID = nil -- a mail row is a mail, not an item
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
					local lines
					for j = 1, mail.items do
						local link = GetInboxItemLink
							and GetInboxItemLink(mail.index, j)
						if link then
							lines = lines or { mail.subject }
							tinsert(lines, link)
						end
					end
					if mail.money > 0 then
						lines = lines or { mail.subject }
						tinsert(lines, "money: " .. GM.Money(mail.money))
					end
					if mail.cod > 0 then
						lines = lines or { mail.subject }
						tinsert(lines, "COD due: " .. GM.Money(mail.cod))
					end
					if lines then GM.Widgets.HintShow(self, lines) end
				end)
				row:SetScript("OnLeave", GM.Widgets.HintHide)
			else
				row:Hide()
			end
		end
	elseif ui.page == "groups" then
		-- GROUPS page: one row per group with a mailing op — the rule
		-- it resolves and what's pending above keepQty; SCAN pushes
		-- just that group's sends into the plan queue
		for i, t in ipairs({ "GROUP", "RECIPIENT", "RULE", "PENDING", "ITEMS" }) do
			ui.head[i]:SetText(t)
		end
		local rows = GM.Banking.MailableGroups and GM.Banking.MailableGroups()
			or {}
		ui.empty:SetText(not open and "open the mailbox"
			or (#rows == 0 and "no mailing ops — set sendTo on a group" or ""))
		ui.empty:SetShown(#rows == 0)
		ui.foot:SetText("mailing ops live on groups (OpsUI) — SCAN sends "
			.. "only that group's pending units · MAIL SCAN does all")
		local maxScroll = math.max(0, #rows - vis)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.count, ui.scroll, vis, #rows)
		for i = 1, VISIBLE do
			local row = ui.rows[i]
			local r = i <= vis and rows[i + ui.scroll] or nil
			if r then
				row:Show()
				row.tipID = nil
				row.c1:SetText(r.name)
				row.c2:SetText("→ " .. r.to)
				row.c3:SetText(format("keep %d%s", r.keep,
					r.maxQ > 0 and (" · cap " .. r.maxQ) or ""))
				row.c4:SetText(r.pend > 0 and ("×" .. r.pend) or "")
				row.c4:SetTextColor(GM.RGB(r.pend > 0 and "accent" or "textDim"))
				row.c5:SetText(r.n .. " it")
				row.act.text:SetText("SCAN")
				row.act.text:SetTextColor(GM.RGB(r.pend > 0 and "accent" or "textDim"))
				local path = r.path
				row.act:SetScript("OnClick", function()
					GM.Banking.MailingScan(path)
				end)
				row:SetScript("OnEnter", function(self)
					GM.Widgets.HintShow(self, { r.path,
						format("%d pending unit%s across %d item%s — "
							.. "SCAN pushes send steps to the plan queue",
							r.pend, r.pend == 1 and "" or "s",
							r.n, r.n == 1 and "" or "s") })
				end)
				row:SetScript("OnLeave", GM.Widgets.HintHide)
			else
				row:Hide()
			end
		end
	else
		-- SEND page: bag stacks, ATTACH per row
		for i, t in ipairs({ "ITEM", "", "QTY", "", "" }) do
			ui.head[i]:SetText(t)
		end
		local rows, pend = {}, 0
		if open then rows, pend = SendRows() end
		ui.head[2]:SetText(format("%d attached", pend))
		-- subject defaults to the first attached item — write it for
		-- real while the box is untouched (empty/hint/our last auto
		-- value); user-typed subjects are left alone
		local defSubj = AttachedList()[1]
			and AttachedList()[1].name or "GoblinMind"
		local cur = strtrim(ui.subject:GetText() or "")
		if not ui.subject:HasFocus()
			and (cur == "" or cur == SUBJ_HINT or cur == ui.autoSubj) then
			ui.autoSubj = defSubj
			ui.subject:SetText(defSubj)
			ui.subject:SetTextColor(GM.RGB("text"))
		end
		ui.empty:SetText(not open and "open the mailbox"
			or (#rows == 0 and "bags empty" or ""))
		ui.empty:SetShown(#rows == 0)
		ui.foot:SetText("ATTACH moves a stack into the outgoing mail · "
			.. "DETACH pulls it back · copper field sends gold")
		local maxScroll = math.max(0, #rows - vis)
		ui.scroll = math.min(ui.scroll or 0, maxScroll)
		W.ScrollText(ui.count, ui.scroll, vis, #rows)
		for i = 1, VISIBLE do
			local row = ui.rows[i]
			local r = i <= vis and rows[i + ui.scroll] or nil
			if r then
				row:Show()
				row.c1:SetText(r.attached and (GM.CC("accent") .. r.name .. "|r")
					or r.name)
				row.c2:SetText(r.attached
					and (GM.CC("warn") .. "in mail|r") or "")
				row.c3:SetText(r.qty > 0 and ("×" .. r.qty) or "")
				row.c4:SetText("")
				row.c5:SetText("")
				row.act.text:SetText(r.attached and "DETACH" or "ATTACH")
				row.act.text:SetTextColor(GM.RGB(r.attached and "warn" or "accent"))
				local item = r
				row.tipID = item.id
				row.act:SetScript("OnClick", function()
					if item.attached then Detach(item) else Attach(item) end
				end)
				row:SetScript("OnEnter", function(self)
					if not item.id then return end
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
	W.EnsureSwitchBtn(ui, MailFrame, MU.OnMailOpen)
end

function MU.OnMailOpen()
	Build()
	EnsureSwitchBtn()
	if ui.wantDefault then return end
	ui.frame:Show()
	pcall(CheckInbox)
	PullInbox() -- pending mail often lands a beat after MAIL_SHOW
	GM.After(2.0, function() pcall(CheckInbox) end)
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
pcall(f.RegisterEvent, f, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
pcall(f.RegisterEvent, f, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
f:SetScript("OnEvent", function(_, e)
	if e == "MAIL_SHOW" then
		MU.OnMailOpen()
	elseif e == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
		if MailFrame and MailFrame:IsShown() then MU.OnMailOpen() end
	elseif ui and ui.frame then
		ui.frame:Hide()
	end
end)
-- poller: MAIL_CLOSED may not fire on this client (the gbank had the
-- same gap) — when the native frame leaves, ours goes with it; and a
-- shown native frame + hidden ours means take over regardless of
-- which event path opened it
local pollT = 0
f:SetScript("OnUpdate", function(_, e)
	pollT = pollT + e
	if pollT < 0.5 then return end
	pollT = 0
	if MailFrame and MailFrame:IsShown() then
		if not (ui and ui.frame and ui.frame:IsShown())
			and not (ui and ui.wantDefault) then
			MU.OnMailOpen()
		end
	elseif ui and ui.frame and ui.frame:IsShown() then
		ui.frame:Hide()
	end
end)

-- /goblin codprobe — the writ escrow go/no-go: does this client let
-- us set COD on outgoing mail? Enumerates every mail-shaped global +
-- C_Mail members, live-calls SetSendMailCOD if present (declared-but-
-- dead globals exist — craftdebug found those in the tradeskill API),
-- and dumps a real inbox header tuple when mail is readable (reveals
-- the COD field position for reject detection later).
function MU.CodProbe()
	GM.dbgCap = {}
	-- xpcall the whole body: a mid-run error still reaches the
	-- dbgDump flush — the capture IS the point of the probe
	local ok, err = xpcall(function()
		GM.Print("— mail COD probe —")
		for _, n in ipairs({
			"SetSendMailCOD", "SendMail", "SetSendMailMoney",
			"ClearSendMail", "ClickSendMailItemButton",
			"GetSendMailItem", "GetSendMailItemInfo",
			"GetSendMailPrice",
			"GetInboxNumItems", "GetInboxHeaderInfo", "GetInboxItem",
			"GetInboxText", "TakeInboxItem", "TakeInboxMoney",
			"ReturnInboxItem", "DeleteInboxItem",
			"AutoLootMailItem",
			"CheckInbox", "MailFrame", "SendMailFrame",
			"SendMailCODButton", "SendMailMoneyButton",
		}) do
			GM.Print(format("%-26s %s", n,
				_G[n] == nil and "nil" or tostring(_G[n])))
		end
		if C_Mail then
			local names = {}
			for k in pairs(C_Mail) do
				names[#names + 1] = tostring(k)
			end
			sort(names)
			GM.Print("C_Mail: " .. table.concat(names, ", "))
		else
			GM.Print("C_Mail: nil")
		end
		if SetSendMailCOD then
			local ok2, err2 = pcall(SetSendMailCOD, 100)
			GM.Print("SetSendMailCOD(100) → " .. tostring(ok2)
				.. " " .. tostring(err2))
			if ClearSendMail then pcall(ClearSendMail) end
		end
		if GetInboxNumItems and GetInboxHeaderInfo then
			local n = tonumber((GetInboxNumItems())) or 0
			GM.Print("inbox items: " .. n)
			if n > 0 then
				local ok3, t = pcall(function()
					return { GetInboxHeaderInfo(1) }
				end)
				if ok3 then
					for i, v in ipairs(t) do
						GM.Print(format("  header[%d] = %s",
							i, tostring(v)))
					end
				else
					GM.Print("  GetInboxHeaderInfo err: "
						.. tostring(t))
				end
			end
		end
		local named = {}
		for k, v in pairs(_G) do
			if type(k) == "string" and type(v) == "function"
				and (k:find("COD") or k:find("SendMail")
				     or k:find("Inbox")) then
				named[#named + 1] = k
			end
		end
		sort(named)
		GM.Print("mail-ish globals: "
			.. table.concat(named, ", "))
	end, function(e) return e end)
	if not ok then
		GM.Print("probe error (partial dump follows): "
			.. tostring(err))
	end
	if GM.db then
		GM.db.dbgDump = table.concat(GM.dbgCap, "\n")
	end
	GM.dbgCap = nil
	GM.Print("captured — /reload flushes to SavedVariables (dbgDump)")
end
