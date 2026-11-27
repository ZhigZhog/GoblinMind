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
local L = GM.L or function(s) return s end
local SUBJ_HINT = L("subject — default: first attached item")
local BODY_HINT = L("message (optional)")
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

local GateSend -- assigned next to MU.Send; Build's hooks capture it

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
		if not n or n == "" then return end
		if GM.SameChar and GM.SameChar(n, me) then return end
		local k = n:lower()
		if not seen[k] then seen[k] = true names[#names + 1] = n end
	end
	for _, r in ipairs(GM.Model.Pref("mailRecent") or {}) do add(r) end
	for _, v in pairs(GM.db and GM.db.fullNames or {}) do add(v) end
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
	local rec = GM.Model.Pref("mailRecent", {})
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
	local n = GM.MailCount()
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
			local ctx = GM.Ctx(s)
			local name = ctx.name or ("item " .. s.itemID)
			if s.locked then lockedByName[name] = (lockedByName[name] or 0) + 1 end
			rows[#rows + 1] = {
				bag = s.bag, slot = s.slot, id = s.itemID,
				qty = s.count, name = name, locked = s.locked,
				ctx = ctx,
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
	-- close means close: restore the native frame quietly and end the
	-- mail session — unless the user asked for the Blizzard frame.
	-- Contextual takeover (mail session only) — no dashboard tabs.
	local f = GM.Widgets.Window({
		name = "GoblinMindMail", title = "MAIL",
		w = 560, h = 480, x = -80, y = -20,
		onHide = function()
			GM.FramePark.Restore(MailFrame)
			if not ui.wantDefault and CloseMail then pcall(CloseMail) end
		end,
	})
	ui.frame = f
	-- inbox/bag changes → repaint (debounced)

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
	ui.to = EditBox(ui.sendBar, 170, "recipient")
	ui.to:SetPoint("LEFT")
	-- Forever surnames live only in Blizzard's completion layer —
	-- borrow its config + handlers (the dropdown knows "Unstable
	-- Haberdasher" where our own candidate pool only sees "Unstable").
	-- Falls back to the inline typeahead when the machinery is absent.
	-- Forever rejects HookScript on some EditBox script types
	-- ("script type not supported") — and a mid-Build error here
	-- left the compose strip unbuilt (ui.compose nil, mail dead).
	-- Attach falls back to a SetScript chain that preserves any
	-- existing handler (W.EditBox installs its own focus scripts).
	local function Attach(obj, h, fn)
		local wrapped = function(...) pcall(fn, ...) end
		if pcall(obj.HookScript, obj, h, wrapped) then return end
		local prev = obj.GetScript and obj:GetScript(h)
		if prev then
			obj:SetScript(h, function(...) prev(...) wrapped(...) end)
		else
			obj:SetScript(h, wrapped)
		end
	end
	local acs = SendMailNameEditBox
	if acs and (acs.autoCompleteSource or acs.autoCompleteParams) then
		ui.to.autoCompleteParams = acs.autoCompleteParams
		ui.to.autoCompleteSource = acs.autoCompleteSource
		if ui.to.SetAutoCompleteSource then
			pcall(ui.to.SetAutoCompleteSource, ui.to,
				acs.autoCompleteSource, acs.GetAutoCompleteParams
				and acs:GetAutoCompleteParams())
		end
		for _, h in ipairs({ "OnChar", "OnTextChanged",
				"OnArrowPressed", "OnEscapePressed",
				"OnEditFocusLost", "OnEditFocusGained",
				"OnEnterPressed" }) do
			local fn
			pcall(function() fn = acs:GetScript(h) end)
			if fn then Attach(ui.to, h, fn) end
		end
	else
		ui.to:SetScript("OnChar", ACOnChar)
	end
	Attach(ui.to, "OnTextChanged", GateSend)
	Attach(ui.to, "OnEditFocusGained", function()
		acList = RecipientNames()
	end)
	ui.money = W.GoldEdit(ui.sendBar, 108)
	ui.money:SetPoint("LEFT", ui.to, "RIGHT", 6, 0)
	-- GoldEdit is a wrapper frame — the coin EditBoxes live on it
	for _, e in ipairs({ ui.money.g, ui.money.s, ui.money.c }) do
		Attach(e, "OnTextChanged", GateSend)
	end
	-- COD toggle: when set the copper box feeds SetSendMailCOD
	-- (payment on delivery) instead of SetSendMailMoney — the writ
	-- board's escrow mechanism
	ui.cod = CreateFrame("CheckButton", nil, ui.sendBar,
		"UICheckButtonTemplate")
	ui.cod:SetSize(18, 18)
	-- GoldEdit paints ~19px past its declared width (the trailing
	-- "c" label) — anchor off the painted edge, not the frame
	ui.cod:SetPoint("LEFT", ui.money, "LEFT",
		(ui.money.effW or 108) + 8, 0)
	ui.cod.text = GM.MakeFontString(ui.cod, GM.FONT, 9, "textDim")
	ui.cod.text:SetPoint("LEFT", ui.cod, "RIGHT", 0, 0)
	ui.cod.text:SetText("COD")
	ui.cod:HookScript("OnClick", GateSend)
	ui.send = Btn(ui.sendBar, 52, "SEND", function() MU.Send() end)
	ui.send:SetPoint("LEFT", ui.cod.text, "RIGHT", 6, 0)
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

	-- ============ GoblinUI managed layout ============
	-- hand-laid: toolbar at -34, hdr at -60, host at -78, and the
	-- compose strip sliding hdr/host down + shrinking the list on
	-- SEND. As a column that's just [toolbar][comp][hdr][host fill]
	-- [foot] — SetVisible on the comp node collapses its space and
	-- the fill host re-sizes itself; no re-anchoring needed. The
	-- sendBar/openAllBtn pair share one slot host (never co-shown).
	local u = GM.ui
	if u then
		local slot = CreateFrame("Frame", nil, f)
		ui.openAllBtn:SetParent(slot)
		ui.openAllBtn:ClearAllPoints()
		ui.openAllBtn:SetPoint("LEFT", slot)
		local root = u:AttachRoot(f, { direction = "column", gap = 4,
			pad = { top = 34, left = 12, right = 12, bottom = 10 } })
		local bar = u:Row(root, { gap = 6 })
		root:Add(bar, { width = "fill", height = 20 })
		bar:Add(u:Adopt(tabHost), { width = 186, height = 20 })
		bar:Add(u:Adopt(scan), { width = 88, height = 20 })
		bar:Add(u:Adopt(slot), { width = "fill", height = 20 })
		-- the send controls never fitted the toolbar strip (~380px of
		-- fields vs ~250px of slot — SEND/CLEAR ran off the window
		-- edge). They get their own send-only row under the toolbar
		ui.sendBarNode = u:Adopt(ui.sendBar)
		root:Add(ui.sendBarNode, { width = "fill", height = 20 })
		ui.compNode = u:Adopt(comp)
		root:Add(ui.compNode, { width = "fill", height = 112 })
		root:Add(u:Adopt(hdr), { width = "fill", height = 16 })
		ui.hostNode = u:Adopt(host)
		root:Add(ui.hostNode, { width = "fill", height = "fill" })
		root:Add(u:Adopt(ui.foot), { width = "fill", height = 12 })
	end
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
			GM.Time.After(0.4, step) -- server busy — retry shortly
			return
		end
		pcall(AutoLootMailItem, next_i)
		PullInbox()
		ui.openedCount = (ui.openedCount or 0) + 1
		ui.openAllBtn.text:SetText("OPENING · " .. ui.openedCount)
		GM.Time.After(0.45, step)
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

-- SEND grays on the same rule O.SendMail's commit runs — the
-- recipient box and attachment slots both feed it, so the button
-- can never light up on a send the spine would refuse
function GateSend()
	if not (ui and ui.send) then return end
	ui.send:SetEnabled(GM.Ops.Can(nil, "sendmail", {
		to = strtrim(ui.to:GetText() or ""),
		cod = ui.cod:GetChecked()
			and (ui.money:GetCopper() or 0) or nil,
		money = not ui.cod:GetChecked()
			and (ui.money:GetCopper() or 0) or nil }))
end

function MU.Send()
	local to = strtrim(ui.to:GetText() or "")
	if to == "" or to == "recipient" then
		GM.Print(GM.CC("warn") .. "recipient first|r")
		return
	end
	-- Forever delivery needs the surname — resolve before send and
	-- echo what actually went out back into the box
	to = (GM.FullName and GM.FullName(to)) or to
	ui.to:SetText(to)
	local copper = ui.money:GetCopper() or 0
	if copper < 0 then copper = 0 end
	local isCod = ui.cod and ui.cod:GetChecked()
	local name = GetSendMailItem and GetSendMailItem(1)
	-- hint strings survive unfocused boxes — treat them as empty
	local subj = strtrim(ui.subject and ui.subject:GetText() or "")
	if subj == "" or subj == SUBJ_HINT then
		subj = (name and name ~= "") and name or "GoblinMind"
	end
	local body = strtrim(ui.body and ui.body:GetText() or "")
	if body == BODY_HINT then body = "" end
	-- the spine owns the send: COD/money hooks, per-item mailout /
	-- codout journal legs, bag-diff verification
	local ok = GM.Ops.SendMail({ to = to, subject = subj, body = body,
		cod = isCod and copper > 0 and copper or nil,
		money = not isCod and copper > 0 and copper or nil })
	if ok then PushRecent(to) end
	MU.Refresh()
end

-- ============ refresh ============

-- view-model for the registry's Data() pass — rows per page plus
-- the send page's attachment state; page is view state the vm
-- carries through
local function Data()
	local open = MailOpen()
	if ui.page == "inbox" then
		return { open = open, rows = open and InboxRows() or {} }
	elseif ui.page == "groups" then
		return { open = open,
			rows = GM.Banking.MailableGroups
				and GM.Banking.MailableGroups() or {} }
	end
	local rows, pend = {}, 0
	if open then rows, pend = SendRows() end
	return { open = open, rows = rows, pend = pend,
		attached = AttachedList() }
end

function MU.Refresh(vm)
	if not ui then return end
	vm = vm or Data()
	local open = vm.open
	ui.pageTabs.set(ui.page)
	GateSend()
	if ui.sendBarNode then
		ui.sendBarNode:SetVisible(ui.page == "send")
	else
		ui.sendBar:SetShown(ui.page == "send")
	end
	ui.openAllBtn:SetShown(ui.page == "inbox")
	-- layout swap: the compose strip pushes the list down on SEND.
	-- Under GoblinUI the comp node collapses and the fill host
	-- re-sizes; the hand anchors are the no-layout fallback.
	if ui.compNode then
		ui.compNode:SetVisible(ui.page == "send")
	else
		ui.compose:SetShown(ui.page == "send")
	end
	local vis = VISIBLE
	if not ui.hostNode then
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
	else
		vis = ui.page == "send" and VISIBLE_SEND or VISIBLE
	end

	if ui.page == "inbox" then
		for i, t in ipairs({ "SENDER", "SUBJECT", "ITEMS", "GOLD", "DAYS" }) do
			ui.head[i]:SetText(t)
		end
		local rows = vm.rows
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
				-- writ surface: GMW1 request / writ COD / writ mats
				local flag = GM.Writs and GM.Writs.RowFlag
					and GM.Writs.RowFlag(r.index)
				GM.Widgets.NameTag(row.c1, r.sender)
				row.c2:SetText(r.subject)
				row.c3:SetText(r.items > 0 and ("×" .. r.items .. " item"
					.. (r.items == 1 and "" or "s")) or "")
				if r.cod > 0 then
					row.c4:SetText(GM.CC("warn") .. "COD " .. GM.Money(r.cod) .. "|r")
				else
					row.c4:SetText(r.money > 0 and GM.Money(r.money) or "")
				end
				row.c5:SetText(r.days and format("%.0fd", r.days) or "")
				if flag == "RECV" then
					row.act.text:SetText("RECV")
					row.act.text:SetTextColor(GM.RGB("warn"))
				elseif flag then
					row.act.text:SetText(flag)
					row.act.text:SetTextColor(GM.RGB("accent"))
				else
					row.act.text:SetText(r.cod > 0 and "COD"
						or ((r.money > 0 or r.items > 0) and "OPEN" or "DEL"))
					row.act.text:SetTextColor(GM.RGB(r.cod > 0 and "warn"
						or (r.money > 0 or r.items > 0) and "accent" or "err"))
				end
				local mail = r
				row.act:SetScript("OnClick", function(act)
					if flag == "RECV" then
						-- matched writ COD: the take pays + stages wrecv
						GM.Writs.AcceptMail(GM.Writs.MailHit(mail.index))
						MU.Refresh()
						return
					elseif flag == "WRIT" then
						local hit = GM.Writs.MailHit(mail.index)
						local rec = hit and hit.rec
						GM.Print(GM.CC("accent") .. "writ request from "
							.. mail.sender .. (rec and rec.qty
								and (" — x" .. rec.qty) or "") .. "|r")
						return
					end
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
		local rows = vm.rows
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
		local rows, pend = vm.rows, vm.pend
		ui.head[2]:SetText(format("%d attached", pend))
		-- subject defaults to the first attached item — write it for
		-- real while the box is untouched (empty/hint/our last auto
		-- value); user-typed subjects are left alone
		local defSubj = vm.attached[1]
			and vm.attached[1].name or "GoblinMind"
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
	GM.Time.After(2.0, function() pcall(CheckInbox) end)
	MU.Refresh()
	-- the panel manager may still be positioning it; park now + retry
	GM.FramePark.Park(MailFrame)
	GM.Time.After(0.3, function() GM.FramePark.Park(MailFrame) end)
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
-- writ fill path: OrdersUI's SEND COD button calls this inside its
-- click — the same hardware click can legally pre-attach the stack.
-- Recipient/subject/COD prefill; the user reviews + hits SEND.
function MU.PrepareWrit(to, itemID, units, unitPrice)
	Build()
	if not MailOpen() then
		GM.Print(GM.CC("warn") ..
			"open a mailbox first — then click SEND COD again|r")
		return
	end
	ui.page = "send"
	if ui.pageTabs and ui.pageTabs.set then
		ui.pageTabs.set("send")
	end
	ui.to:SetText(to or "")
	ui.money:SetCopper(math.floor((unitPrice or 0) * (units or 1)))
	if ui.cod then ui.cod:SetChecked(true) end
	local iname = GetItemInfo and GetItemInfo(itemID) or nil
	if ui.subject then
		ui.subject:SetText("writ: " .. (iname or tostring(itemID)))
	end
	ui.frame:Show()
	-- best-effort attach: first bag stack of the item. Attach()
	-- already runs inside a hardware click and ClearCursor-guards.
	if itemID and GM.Banking and GM.Banking.BagSlots then
		for _, s in ipairs(GM.Banking.BagSlots()) do
			if s.itemID == itemID then
				Attach({ bag = s.bag, slot = s.slot })
				break
			end
		end
	end
	MU.Refresh()
end

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
			local n = GM.MailCount()
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
		GM.Model.SetPref("dbgDump", table.concat(GM.dbgCap, "\n"))
	end
	GM.dbgCap = nil
	GM.Print("captured — /reload flushes to SavedVariables (dbgDump)")
end

GM.View.Register("mail", { class = "contextual",
	events = { "MAIL_INBOX_UPDATE",
		"MAIL_SEND_INFO_UPDATE", "MAIL_SEND_SUCCESS",
		"MAIL_FAILED", "BAG_UPDATE" },
	Show = MU.Show, Hide = MU.Hide, Toggle = MU.Toggle,
	Data = Data,
	Refresh = MU.Refresh,
	IsShown = function() return ui and ui.frame and ui.frame:IsShown() end })
