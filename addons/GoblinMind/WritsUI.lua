local _, GM = ...

-- WritsUI — the SHOPS and MY WRITS panes of the CRAFT window.
-- OrdersUI owns the window + tab strip; this file fills the two
-- non-order tabs:
--   SHOPS   — the open-shop browser: flat offer market across every
--             roster on the board, per-crafter drill, and the MY
--             SHOP curation pane (opt-in offers, price/mats/note
--             terms, PUBLISH to the board).
--   MY WRITS — inbox/outbox of live writs plus the local mail
--             channel, with a state×role action column that mirrors
--             the server's verb gates.

GM.WritsUI = {}
local WU = GM.WritsUI
local W = GM.Writs
local ui

local ROWS = 17
local GoldText = GM.MoneyShort

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

-- Enter commits a GoldEdit — it's a 3-box composite, so each
-- sub-edit gets the handler (the frame itself never sees it)
local function GoldCommit(ge, fn)
	for _, e in ipairs({ ge.g, ge.s, ge.c }) do
		if e then
			e:SetScript("OnEnterPressed", function()
				fn()
				e:ClearFocus()
			end)
		end
	end
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

-- ============ SHOPS data ============
-- flat offer market: one row per offer across every roster on the
-- board. Priced offers sort by tag first, unpriced alpha after —
-- browsers shop by price, not by crafter.

local function crafterTag(r)
	local c = (GM.NameColored and GM.NameColored(
		(r.chars and r.chars[1]) or "?"))
		or ((r.chars and r.chars[1]) or "?")
	local st = r.stats or {}
	local done = st.writs_done or 0
	if done > 0 then
		c = c .. " |cff5fd35f(" .. done .. " done)|r"
	end
	if (st.writs_declined or 0) > 0 then
		c = c .. " |cffd35f5f rej:" .. st.writs_declined .. "|r"
	end
	return c
end

local function marketRows(board, q, prof)
	local out = {}
	for _, r in ipairs(W.Rosters(board)) do
		for _, o in ipairs(r.offers or {}) do
			if prof and o.prof ~= prof then
			else
				out[#out + 1] = { offer = o, roster = r }
			end
		end
	end
	-- yell pseudo-offers fold in here — same row shape; the offer
	-- carries the parsed link/ref, the roster is a fake single-char
	-- shell so crafterTag/search/sort work unchanged
	for _, y in ipairs(W.YellOffers and W.YellOffers() or {}) do
		out[#out + 1] = { yell = y, offer = {
			name = y.linkName or ("yell: " .. y.text),
			prof = y.prof, itemID = y.itemID, ref = y.ref,
			_yell = true },
			roster = { chars = { y.char }, stats = {}, _yell = true } }
	end
	if q and q ~= "" then
		local ql = q:lower()
		local hit = {}
		for _, e in ipairs(out) do
			local nm = (e.offer.name or ""):lower()
			local ch = (e.roster.chars
				and table.concat(e.roster.chars, " ") or ""):lower()
			if nm:find(ql, 1, true) or ch:find(ql, 1, true)
					or (e.offer.toon or ""):lower():find(ql, 1, true)
					or (e.offer.prof or ""):lower():find(ql, 1, true) then
				hit[#hit + 1] = e
			end
		end
		out = hit
	end
	table.sort(out, function(a, b)
		local pa, pb = a.offer.price, b.offer.price
		if (pa ~= nil) ~= (pb ~= nil) then return pa ~= nil end
		if pa and pb and pa ~= pb then return pa < pb end
		return tostring(a.offer.name) < tostring(b.offer.name)
	end)
	return out
end

-- profession chip row: the union of profs present in the rosters,
-- capped — a chip toggles the prof filter (nil = all)
local function profChips(rows)
	local seen, list = {}, {}
	for _, e in ipairs(rows) do
		local p = e.offer.prof
		-- yell pseudo-profs (Mage/Warlock) are classes, not
		-- professions — they'd mint meaningless filter chips
		if p and not seen[p] and not (e.yell and e.yell.clsProf) then
			seen[p] = true
			list[#list + 1] = p
		end
	end
	table.sort(list)
	return list
end

-- ============ MY WRITS data ============
-- merged view: server writs (in/out, live overlay applied) + local
-- mail writs + parsed inbound GMW1 letters. Sorted by updated desc.

local function writRows()
	local v = W.Writs()
	local out = {}
	for _, w in ipairs(v.inb) do out[#out + 1] = w end
	for _, w in ipairs(v.out) do out[#out + 1] = w end
	for _, w in ipairs(v.mailOut or {}) do
		w._side, w._mail = "out", true
		out[#out + 1] = w
	end
	for _, w in ipairs(v.mailIn or {}) do
		w._side, w._mail = "inb", true
		out[#out + 1] = w
	end
	table.sort(out, function(a, b)
		return (a.updated or a.t or 0) > (b.updated or b.t or 0)
	end)
	return out
end

local STATE_KEY = {
	open = "accent", quoted = "warn", agreed = "accent",
	shipped = "warn", done = "pos", declined = "err",
	cancelled = "err", expired = "textDim",
	received = "warn", mailed = "textDim", staged = "textDim",
}

local function partyName(w, me)
	local NC = GM.NameColored or function(n) return n end
	if w._side == "inb" then
		return NC(w.fromChar or w.sender or "?")
			.. GM.CC("textDim") .. " → you|r"
	end
	return "you " .. GM.CC("textDim") .. "→|r "
		.. NC(w.toChar or w.sender or "?")
end

-- state×role actions — mirrors the server's verb gates. Returns
-- label pairs; the click handlers live in writRowPaint where the
-- row's edit boxes are reachable.
local function writActions(w, me)
	if w._mail then
		if w._side == "out" then return { "WITHDRAW" } end
		return { "REPLY" }  -- received GMW1 letter
	end
	local st, side = w.state, w._side
	if w._pendOp then return {} end
	if st == "open" then
		if side == "inb" then return { "QUOTE", "DECLINE" } end
		return { "CANCEL" }
	elseif st == "quoted" then
		if side == "out" then return { "ACCEPT", "DECLINE" } end
		return { "REQUOTE", "DECLINE" }
	elseif st == "agreed" then
		if side == "inb" then
			-- cod shipments use the text field for the mail-from
			-- name, so SET MEET only rides the trade flow
			if w.deliver == "cod" then return { "SHIP" } end
			return { "SHIP", "SET MEET" }
		end
		local a = { "SET MEET" }
		if w.mats == "prepaid" then a[#a + 1] = "MAIL MATS" end
		return a
	elseif st == "shipped" then
		if side == "out" then return { "RECEIVED" } end
		return {}
	elseif st == "done" or st == "declined" or st == "cancelled"
			or st == "expired" then
		if side == "out" then return { "RENEW" } end
		return {}
	end
	return {}
end

-- ============ build ============

function WU.Build(f)
	if ui then return ui.shopsP, ui.writsP end
	ui = { mode = "market", scroll = 0, wscroll = 0,
		expanded = {}, prof = nil, drill = nil }

	-- ===== SHOPS pane =====
	local sp = Panel(f, 10, -76, 700, 458, "SHOPS")
	ui.shopsP = sp
	sp:EnableMouseWheel(true)
	sp:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, (ui.scroll or 0) - d * 3)
		WU.Paint("shops")
	end)

	-- mode toggles ride the search row's right edge — the header
	-- corner already belongs to the count fontstring
	ui.modeBtns = {}
	local modes = { { "market", "MARKET" }, { "crafter", "CRAFTERS" },
		{ "myshop", "MY SHOP" } }
	for i, m in ipairs(modes) do
		local b = MkBtn(sp, m[2], 62, 13)
		b:SetPoint("TOPRIGHT", -4 - (3 - i) * 66, -16)
		b:SetScript("OnClick", function()
			ui.mode = m[1]
			ui.scroll = 0
			ui.drill = nil
			ui.shopMsg:SetText("") -- hints don't cross modes
			WU.Paint("shops")
		end)
		ui.modeBtns[m[1]] = b
	end

	ui.search = MkEdit(sp, 190, "name, crafter or prof…")
	ui.search:SetPoint("TOPLEFT", 8, -16)
	ui.search:SetScript("OnTextChanged", function(s)
		s.hint:SetShown(s:GetText() == "")
		ui.scroll = 0
		WU.Paint("shops")
	end)

	-- MY SHOP publish controls (hidden in other modes)
	ui.pubBtn = MkBtn(sp, "PUBLISH", 66, 13)
	ui.pubBtn:SetPoint("TOPLEFT", 206, -16)
	ui.pubBtn:SetScript("OnClick", function()
		local rid = W.Publish(ui.board)
		ui.shopMsg:SetText(rid and ("publish staged " .. rid
			.. " — live on mesh + next flush")
			or "no board — join one first")
		WU.Paint("shops")
	end)
	ui.shopMsg = GM.MakeFontString(sp, GM.FONT, 9, "textDim")
	ui.shopMsg:SetPoint("LEFT", ui.pubBtn, "RIGHT", 8, 0)
	ui.shopMsg:SetWidth(210)
	ui.shopMsg:SetWordWrap(false)
	ui.shopMsg:SetJustifyH("LEFT")

	-- back out of a crafter drill
	ui.drillBack = MkBtn(sp, "« CRAFTERS", 74, 13)
	ui.drillBack:SetPoint("TOPLEFT", 206, -16)
	ui.drillBack:SetScript("OnClick", function()
		ui.drill = nil
		WU.Paint("shops")
	end)
	ui.drillBack:Hide()

	-- prof filter chips — rebuilt per paint, cap 8
	ui.chips = {}
	for i = 1, 8 do
		local b = MkBtn(sp, "", 10, 13)
		b:SetPoint("TOPLEFT", 8 + (i - 1) * 2, -34)
		b.text:SetTextColor(GM.RGB("textDim"))
		ui.chips[i] = b
	end

	-- column heads (market + crafter share the grid)
	ui.sHeads = {}
	for i, h in ipairs({ { 22, "OFFER" }, { 250, "PROF" },
		{ 330, "PRICE" }, { 420, "CRAFTER" } }) do
		local fs = GM.MakeFontString(sp, GM.FONT_BOLD, 8, "secondary")
		fs:SetPoint("TOPLEFT", 8 + h[1], -50)
		fs:SetText(h[2])
		ui.sHeads[i] = fs
	end

	ui.sRows = {}
	for i = 1, ROWS do
		local r = CreateFrame("Button", nil, sp)
		r:SetSize(684, 21)
		r:SetPoint("TOPLEFT", 8, -62 - (i - 1) * 21)
		r.on = MkBtn(r, "", 20, 13)
		r.on:SetPoint("LEFT", 0, 0)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(13, 13)
		r.icon:SetPoint("LEFT", 22, 0)
		r.name = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.name:SetPoint("LEFT", 40, 0)
		r.name:SetWidth(204)
		r.name:SetWordWrap(false)
		r.name:SetJustifyH("LEFT")
		r.prof = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.prof:SetPoint("LEFT", 250, 0)
		r.prof:SetWidth(74)
		r.prof:SetWordWrap(false)
		r.prof:SetJustifyH("LEFT")
		r.price = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.price:SetPoint("LEFT", 330, 0)
		r.price:SetWidth(84)
		r.price:SetJustifyH("LEFT")
		r.who = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.who:SetPoint("LEFT", 420, 0)
		r.who:SetWidth(196)
		r.who:SetWordWrap(false)
		r.who:SetJustifyH("LEFT")
		r.act = MkBtn(r, "REQUEST", 62, 13)
		r.act:SetPoint("RIGHT", -2, 0)
		-- yell rows get a second tail button: "+" converts the bark
		-- into a prefilled GMW1 mail-writ (2a compose path)
		r.act2 = MkBtn(r, "+", 16, 13)
		r.act2:SetPoint("RIGHT", r.act, "LEFT", -4, 0)
		r.act2:Hide()
		-- MY SHOP inline editors (hidden in other modes)
		r.gold = GM.Widgets.GoldEdit(r, 88)
		r.mats = MkBtn(r, "buyer", 62, 13)
		r.note = MkEdit(r, 104, "note…")
		r.gold:Hide(); r.mats:Hide(); r.note:Hide()
		r:SetScript("OnEnter", function(s)
			local id = s.offerID
			if not id then return end
			GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
			if GameTooltip.SetItemByID then
				GameTooltip:SetItemByID(id)
			else
				GameTooltip:SetHyperlink("item:" .. id)
			end
			GameTooltip:Show()
		end)
		r:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.sRows[i] = r
	end

	-- REQUEST popover: qty + price (prefilled offer or W.Suggest) +
	-- mats policy + SEND. Anchored under the clicked row.
	local pop = CreateFrame("Frame", nil, sp)
	pop:SetSize(430, 66)
	GM.Panel(pop, "contHigh")
	pop:SetFrameLevel(sp:GetFrameLevel() + 10)
	ui.reqPop = pop
	pop.title = GM.MakeFontString(pop, GM.FONT_BOLD, 9, "secondary")
	pop.title:SetPoint("TOPLEFT", 8, -5)
	pop.qty = MkEdit(pop, 44, "qty", true)
	pop.qty:SetPoint("TOPLEFT", 8, -24)
	pop.gold = GM.Widgets.GoldEdit(pop, 110)
	pop.gold:SetPoint("LEFT", pop.qty, "RIGHT", 6, 0)
	pop.mats = MkBtn(pop, "buyer", 66, 15)
	pop.mats:SetPoint("LEFT", pop.gold, "RIGHT", 8, 0)
	pop.send = MkBtn(pop, "SEND", 56, 15)
	pop.send:SetPoint("LEFT", pop.mats, "RIGHT", 8, 0)
	pop.hint = GM.MakeFontString(pop, GM.FONT, 9, "textDim")
	pop.hint:SetPoint("TOPLEFT", 8, -46)
	pop.hint:SetWidth(414)
	pop.hint:SetWordWrap(false)
	pop.hint:SetJustifyH("LEFT")
	pop:Hide()

	-- ===== MY WRITS pane =====
	local wp = Panel(f, 10, -76, 700, 458, "MY WRITS")
	ui.writsP = wp
	wp:EnableMouseWheel(true)
	wp:SetScript("OnMouseWheel", function(_, d)
		ui.wscroll = math.max(0, (ui.wscroll or 0) - d * 3)
		WU.Paint("writs")
	end)
	ui.wMsg = GM.MakeFontString(wp, GM.FONT, 9, "textDim")
	ui.wMsg:SetPoint("TOPLEFT", 8, -16)
	ui.wMsg:SetWidth(500)
	ui.wMsg:SetWordWrap(false)
	ui.wMsg:SetJustifyH("LEFT")

	ui.wHeads = {}
	for i, h in ipairs({ { 22, "WRIT" }, { 240, "PARTY" },
		{ 360, "STATE" }, { 440, "AGE" } }) do
		local fs = GM.MakeFontString(wp, GM.FONT_BOLD, 8, "secondary")
		fs:SetPoint("TOPLEFT", 8 + h[1], -32)
		fs:SetText(h[2])
		ui.wHeads[i] = fs
	end

	ui.wRows = {}
	for i = 1, ROWS do
		local r = CreateFrame("Frame", nil, wp)
		r:SetSize(684, 21)
		r:SetPoint("TOPLEFT", 8, -44 - (i - 1) * 21)
		r.dbg = r:CreateTexture(nil, "BACKGROUND")
		r.dbg:SetPoint("TOPLEFT", 16, 0)
		r.dbg:SetPoint("BOTTOMRIGHT", 0, 0)
		r.dbg:SetColorTexture(GM.RGB("contLow"))
		r.dbg:Hide()
		r.fold = MkBtn(r, "+", 14, 13)
		r.fold:SetPoint("LEFT", 0, 0)
		r.name = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.name:SetPoint("LEFT", 36, 0)
		r.name:SetWidth(198)
		r.name:SetWordWrap(false)
		r.name:SetJustifyH("LEFT")
		r.party = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.party:SetPoint("LEFT", 240, 0)
		r.party:SetWidth(114)
		r.party:SetWordWrap(false)
		r.party:SetJustifyH("LEFT")
		r.state = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.state:SetPoint("LEFT", 360, 0)
		r.state:SetWidth(76)
		r.state:SetJustifyH("LEFT")
		r.age = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.age:SetPoint("LEFT", 440, 0)
		r.age:SetWidth(60)
		r.age:SetJustifyH("LEFT")
		r.a1 = MkBtn(r, "", 64, 13)
		r.a1:SetPoint("RIGHT", -2, 0)
		r.a2 = MkBtn(r, "", 64, 13)
		r.a2:SetPoint("RIGHT", r.a1, "LEFT", -4, 0)
		-- detail-row widgets (expanded writ): field text runs the
		-- left half, the two context inputs own the right — no
		-- shared x-range, nothing prints under the edit boxes
		r.ctxt = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.ctxt:SetPoint("LEFT", 36, 0)
		r.ctxt:SetWidth(320)
		r.ctxt:SetWordWrap(false)
		r.ctxt:SetJustifyH("LEFT")
		r.cgold = GM.Widgets.GoldEdit(r, 96)
		r.cgold:SetPoint("LEFT", 364, -1)
		-- GoldEdit paints ~26px past its declared width (unit labels);
		-- cedit must clear the trailing "c", not the frame edge
		r.cedit = MkEdit(r, 160, "")
		r.cedit:SetPoint("LEFT", 494, -1)
		ui.wRows[i] = r
	end

	ui.shopsP:Hide()
	ui.writsP:Hide()
	return ui.shopsP, ui.writsP
end

-- OrdersUI hands its ui table over so the panes can find their
-- managed-layout nodes (nil under the hand-laid fallback)
function WU.Bind(ou)
	ui.ou = ou
end

function WU.SetTab(tab)
	if not ui then return end
	local so, wo = tab == "shops", tab == "writs"
	if ui.ou then
		if ui.ou.shopsN then ui.ou.shopsN:SetVisible(so) end
		if ui.ou.writsN then ui.ou.writsN:SetVisible(wo) end
	end
	if not (ui.ou and ui.ou.shopsN) then
		ui.shopsP:SetShown(so)
	end
	if not (ui.ou and ui.ou.writsN) then
		ui.writsP:SetShown(wo)
	end
end

-- ============ SHOPS paint ============

-- re-anchor the shared row widgets per pane mode: the browse grid
-- (icon|name|prof|price|crafter|act) vs MY SHOP's edit row — the
-- mats policy button rides the on switch up front, SUGGEST tucks
-- right against the gold field at the tail
local function layoutRow(r, mode)
	local pos
	if mode == "myshop" then
		-- GoldEdit's trailing "c" label spills ~10px past its
		-- declared width — leave real air before SUGGEST. `who`
		-- doubles as the toon column: on an account-shared recipe
		-- DB the crafter attribution is per-offer, not per-roster.
		-- `who` carries surnames now — it needs real width; the
		-- note field absorbs the cost (user text clips anyway)
		pos = { on = 0, mats = 24, icon = 92, name = 112,
			prof = 232, who = 288, note = 400, gold = 486,
			act = -2, price = false }
	else
		pos = { icon = 22, name = 40, prof = 250, price = 330,
			who = 420, act = -2, on = false, mats = false,
			gold = false, note = false }
	end
	for _, k in ipairs({ "on", "mats", "icon", "name", "prof",
		"price", "who", "note", "gold", "act", "act2" }) do
		local w, x = r[k], pos[k]
		w:ClearAllPoints()
		if not x then
			w:Hide()
		else
			w:Show()
			if x < 0 then w:SetPoint("RIGHT", x, 0)
			else w:SetPoint("LEFT", x, 0) end
		end
	end
	r.name:SetWidth(mode == "myshop" and 116 or 204)
	r.prof:SetWidth(mode == "myshop" and 52 or 74)
	r.who:SetWidth(mode == "myshop" and 108 or 196)
	r.note:SetWidth(mode == "myshop" and 82 or 104)
end

local function offerIcon(o)
	if o.itemID then return GM.ItemIcon(o.itemID) end
	return nil
end

-- REQUEST popover state: which roster+offer is being ordered
local function openRequest(row, e)
	local pop = ui.reqPop
	ui.req = e
	local o = e.offer
	pop.e = e
	pop.title:SetText("REQUEST — " .. (o.name or "?") .. "  ·  "
		.. ((GM.NameColored and GM.NameColored(
			o.toon or (e.roster.chars and e.roster.chars[1]) or "?"))
			or "?"))
	pop.qty:SetText(tostring(o.numMade or 1))
	local sug = W.Suggest(o.ref, o.numMade or 1)
	pop.gold:SetCopper(o.price or (sug and sug.price) or nil)
	pop.sug = sug
	pop.mats.text:SetText(o.mats or "buyer")
	pop.hint:SetText(sug and string.format(
		"suggest %s (mats %s + market %s)",
		sug.price and GoldText(sug.price) or "—",
		sug.mats and GoldText(sug.mats) or "—",
		sug.market and GoldText(sug.market) or "—")
		or "no market data — set a price or send OFFER")
	-- mats policy cycles the three modes
	pop.mats:SetScript("OnClick", function()
		local next_ = { buyer = "crafter", crafter = "prepaid",
			prepaid = "buyer" }
		pop.mats.text:SetText(next_[pop.mats.text:GetText()] or "buyer")
	end)
	pop.send:SetScript("OnClick", function()
		local qty = math.max(1, math.floor(
			tonumber(pop.qty:GetText()) or 1))
		local price = pop.gold:GetCopper()
		W.Request(ui.board, e.roster.uuid,
			o.toon or (e.roster.chars and e.roster.chars[1]) or nil, {
				ref = o.ref, name = o.name, itemID = o.itemID,
				qty = qty, offer = price or 0,
				mats = pop.mats.text:GetText() or "buyer",
				deliver = (o.kind == "service") and "trade" or "cod",
			})
		pop:Hide()
		ui.shopMsg:SetText("request staged — live on mesh + next flush")
		WU.Paint(ui.tabShown or "shops")
	end)
	pop:ClearAllPoints()
	pop:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 60, -2)
	pop:Show()
end

local function ShopsPaint(vm)
	ui.board = vm and vm.board or ui.board
	local sp = ui.shopsP
	local mode = ui.mode
	ui.reqPop:Hide()
	for i, b in pairs(ui.modeBtns) do
		b.text:SetTextColor(GM.RGB(
			ui.mode == i and "accent" or "textDim"))
	end
	ui.pubBtn:SetShown(mode == "myshop")
	ui.shopMsg:SetShown(mode ~= "crafter")
	ui.drillBack:SetShown(mode == "crafter" and ui.drill ~= nil)
	ui.search:SetShown(mode ~= "myshop")
	local rows
	if mode == "myshop" then
		rows = W.RosterOffers()
		sp.title:SetText("MY SHOP — " .. (ui.board or "no board"))
		local en = 0
		for _, o in ipairs(rows) do
			if o.on then en = en + 1 end
		end
		sp.count:SetText(en .. " listed")
		ui.shopMsg:SetText(ui.shopMsg:GetText() ~= ""
			and ui.shopMsg:GetText()
			or ("ON + terms → PUBLISH · "
				.. en .. "/" .. #rows .. " listed"))
		for i = 1, 8 do ui.chips[i]:Hide() end
		for i = 1, #ui.sHeads do ui.sHeads[i]:Hide() end
	elseif mode == "crafter" and not ui.drill then
		rows = W.Rosters(ui.board)
		sp.title:SetText("CRAFTERS — " .. (ui.board or "no board"))
		sp.count:SetText(#rows .. " shops")
		for i = 1, 8 do ui.chips[i]:Hide() end
		for i = 1, #ui.sHeads do ui.sHeads[i]:Hide() end
	else
		rows = marketRows(ui.board, ui.search:GetText(),
			ui.prof)
		if mode == "crafter" and ui.drill then
			local dr = {}
			for _, e in ipairs(rows) do
				if e.roster == ui.drill then dr[#dr + 1] = e end
			end
			rows = dr
			sp.title:SetText("SHOP — "
				.. ((ui.drill.chars and ui.drill.chars[1]) or "?"))
		else
			sp.title:SetText("SHOPS — " .. (ui.board or "no board"))
		end
		sp.count:SetText(#rows .. " offers")
		-- prof chips
		local profs = profChips(marketRows(ui.board))
		for i = 1, 8 do
			local b = ui.chips[i]
			local p = profs[i]
			if p then
				b:Show()
				b.text:SetText(p:sub(1, 8))
				b:SetWidth(10 + math.min(#p, 8) * 7)
				b:ClearAllPoints()
				local x = 8
				for j = 1, i - 1 do
					x = x + ui.chips[j]:GetWidth() + 4
				end
				b:SetPoint("TOPLEFT", x, -34)
				b.text:SetTextColor(GM.RGB(
					ui.prof == p and "accent" or "textDim"))
				b:SetScript("OnClick", function()
					ui.prof = (ui.prof == p) and nil or p
					ui.scroll = 0
					WU.Paint("shops")
				end)
			else b:Hide() end
		end
		for i = 1, #ui.sHeads do ui.sHeads[i]:Show() end
	end

	for i = 1, ROWS do
		local r = ui.sRows[i]
		local e = rows[i + (ui.scroll or 0)]
		if not e then
			r:Hide()
		elseif mode == "myshop" then
			r:Show()
			layoutRow(r, "myshop")
			r.offerID = e.itemID
			local ic = offerIcon(e)
			if ic then r.icon:SetTexture(ic) r.icon:Show()
			else r.icon:Hide() end
			r.on.text:SetText(e.on and "on" or "—")
			r.on.text:SetTextColor(GM.RGB(e.on and "pos" or "textDim"))
			local ref = e.ref
			r.on:SetScript("OnClick", function()
				W.SetTerms(ref, "on", not e.on)
				WU.Paint("shops")
			end)
			r.name:SetText(e.name or e.ref or "?")
			r.name:SetTextColor(GM.RGB("text"))
			r.prof:SetText(e.prof or "")
			r.price:SetText(e.price and GoldText(e.price) or "")
			GM.Widgets.NameTag(r.who, e.toon or "")
			r.act.text:SetText("SUGGEST")
			r.act.text:SetTextColor(GM.RGB("textDim"))
			r.act:Show()
			r.act:SetScript("OnClick", function()
				local sug = W.Suggest(ref, 1)
				if sug and sug.price then
					r.gold:SetCopper(sug.price)
					W.SetTerms(ref, "price", sug.price)
					ui.shopMsg:SetText(string.format(
						"%s → %s (mats %s + market %s)", e.name or ref,
						GoldText(sug.price),
						sug.mats and GoldText(sug.mats) or "—",
						sug.market and GoldText(sug.market) or "—"))
				else
					ui.shopMsg:SetText("no suggestion — no mat or market data")
				end
				WU.Paint("shops")
			end)
			r.gold:Show()
			r.gold:SetCopper(e.price)
			if r.gold.ref ~= ref then
				r.gold.ref = ref
				GoldCommit(r.gold, function()
					W.SetTerms(ref, "price", r.gold:GetCopper())
				end)
			end
			r.mats:Show()
			r.mats.text:SetText(e.mats or "buyer")
			r.mats:SetScript("OnClick", function()
				local next_ = { buyer = "crafter", crafter = "prepaid",
					prepaid = "buyer" }
				local v = next_[r.mats.text:GetText()] or "buyer"
				r.mats.text:SetText(v)
				W.SetTerms(ref, "mats", v)
			end)
			r.note:Show()
			if r.note.ref ~= ref then
				r.note:SetText(e.note or "")
				r.note.ref = ref
			end
			r.note:SetScript("OnEnterPressed", function(s)
				W.SetTerms(ref, "note", s:GetText())
				s:ClearFocus()
			end)
		elseif mode == "crafter" and not ui.drill then
			r:Show()
			layoutRow(r, "browse")
			r.offerID = nil
			r.icon:Hide()
			local st = e.stats or {}
			local profs, seen = {}, {}
			for _, o in ipairs(e.offers or {}) do
				if o.prof and not seen[o.prof] then
					seen[o.prof] = true
					profs[#profs + 1] = o.prof
				end
			end
			-- dedup + class-color each char — bare/realm/resolved
			-- forms of one toon can arrive as separate entries
			local seenC, parts = {}, {}
			for _, ch in ipairs(e.chars or {}) do
				local k = ch:lower()
				if not seenC[k] then
					seenC[k] = true
					parts[#parts + 1] = GM.NameColored(ch)
				end
			end
			r.name:SetText(#parts > 0 and table.concat(parts, ", ")
				or "?")
			r.name:SetTextColor(GM.RGB("text"))
			r.prof:SetText(table.concat(profs, ","):sub(1, 20))
			r.price:SetText(#(e.offers or {}) .. " offers")
			r.who:SetText(string.format("%d done · %d declined",
				st.writs_done or 0, st.writs_declined or 0))
			r.act.text:SetText("VIEW")
			r.act.text:SetTextColor(GM.RGB("accent"))
			r.act:Show()
			local ros = e
			r.act:SetScript("OnClick", function()
				ui.drill = ros
				ui.scroll = 0
				WU.Paint("shops")
			end)
		else
			-- market row (flat or crafter drill)
			r:Show()
			layoutRow(r, "browse")
			local o, ros = e.offer, e.roster
			r.offerID = o.itemID
			local ic = offerIcon(o)
			if ic then r.icon:SetTexture(ic) r.icon:Show()
			else r.icon:Hide() end
			r.name:SetText(o.name or o.ref or "?")
			r.name:SetTextColor(GM.RGB("text"))
			r.prof:SetText(o.prof or "")
			if o._yell then
				-- bark row: no price claim — badge + whisper/mail
				-- actions instead of a server writ request
				local y = e.yell
				r.price:SetText(GM.CC("textDim") .. "·yell "
					.. GM.FmtAge(time() - (y.t or time())) .. "|r")
				GM.Widgets.NameTag(r.who, y.char, "textDim")
				r.act.text:SetText("WHISPER")
				r.act.text:SetTextColor(GM.RGB("accent"))
				r.act:Show()
				r.act:SetScript("OnClick", function()
					-- SendTell takes the target as a unit arg —
					-- "/w <text>" word-splits and eats surnames
					-- ("Mygiraffe Mage" whispers "Mage" to Mygiraffe)
					if not pcall(ChatFrame_SendTell, y.char) then
						pcall(ChatFrame_OpenChat,
							"/w " .. y.char .. " ")
					end
				end)
				r.act2:Show()
				r.act2:SetScript("OnClick", function()
					local wid = W.MailRequest(y.char, {
						name = y.linkName or y.text:sub(1, 40),
						ref = y.ref, itemID = y.itemID, qty = 1,
						mats = "buyer", deliver = "trade",
						note = "saw your yell — "
							.. y.text:sub(1, 60) })
					ui.shopMsg:SetText(wid
						and ("mail-writ sent to " .. y.char
							.. " — watch MY WRITS")
						or "mail send failed")
				end)
			else
				r.price:SetText(o.price and GoldText(o.price)
					or GM.CC("warn") .. "OFFER|r")
				r.price:SetTextColor(GM.RGB(
					o.price and "text" or "warn"))
				if o.toon then GM.Widgets.NameTag(r.who, o.toon)
				else r.who:SetText(crafterTag(ros)) end
				r.act.text:SetText("REQUEST")
				r.act.text:SetTextColor(GM.RGB("accent"))
				r.act:Show()
				local ent = e
				r.act:SetScript("OnClick", function()
					openRequest(r, ent)
				end)
			end
		end
	end
	-- empty-state text through the count field
	if #rows == 0 then
		sp.count:SetText(mode == "myshop"
			and "no offers — learn recipes or add shopOffers"
			or "no rosters on this board yet")
	end
end

-- ============ MY WRITS paint ============

local function ageText(t)
	t = time() - (t or time())
	if t < 3600 then return math.max(1, math.floor(t / 60)) .. "m" end
	if t < 86400 then return math.floor(t / 3600) .. "h" end
	return math.floor(t / 86400) .. "d"
end

-- one writ header row
local function writRowPaint(r, w, me)
	r.dbg:Hide()
	r.ctxt:Hide(); r.cgold:Hide(); r.cedit:Hide()
	r.fold:Show(); r.name:Show(); r.party:Show()
	r.state:Show(); r.age:Show()
	local pend = w._pendOp
	r.fold:SetText(ui.expanded[w.id or "?"] and "-" or "+")
	r.fold:SetScript("OnClick", function()
		local k = w.id or "?"
		ui.expanded[k] = not ui.expanded[k] or nil
		WU.Paint("writs")
	end)
	local nm = w.name or w.subject or "writ"
	if w._mail then nm = "» " .. nm end
	r.name:SetText(nm)
	r.name:SetTextColor(GM.RGB(pend and "textDim" or "text"))
	r.party:SetText(partyName(w, me))
	local st = w.state or "open"
	if w._mail then st = st .. "·mail" end
	-- staged op rejected server-side or over the tunnel — flash it
	local res = w._rid and W.Results()[w._rid]
	local resErr = res and res.ok == false
	r.state:SetText(st .. (pend and (" ·" .. pend) or "")
		.. (resErr and " ·ERR" or ""))
	r.state:SetTextColor(GM.RGB(
		resErr and "err" or STATE_KEY[st] or "textDim"))
	r.age:SetText(ageText(w.updated or w.created or w.t))
	-- actions
	local acts = writActions(w, me)
	for _, a in ipairs({ r.a1, r.a2 }) do a:Hide() end
	for i, lbl in ipairs(acts) do
		local b = (i == 1) and r.a1 or r.a2
		b:Show()
		b.text:SetText(lbl)
		b.text:SetTextColor(GM.RGB(
			(lbl == "DECLINE" or lbl == "CANCEL" or lbl == "WITHDRAW")
				and "err" or "accent"))
		b:SetScript("OnClick", function()
			WU.Act(w, lbl)
		end)
	end
	r:Show()
end

-- expanded detail row — fields + the inputs actions read from
local function detailRowPaint(r, w, me)
	r.dbg:Show()
	r.fold:Hide(); r.name:Hide(); r.party:Hide()
	r.state:Hide(); r.age:Hide()
	r.a1:Hide(); r.a2:Hide()
	local bits = {}
	if w.ref then bits[#bits + 1] = "ref " .. w.ref end
	if w.qty then bits[#bits + 1] = "x" .. w.qty end
	if w.offer then bits[#bits + 1] = "offer " .. GoldText(w.offer) end
	if w.quote and w.quote ~= w.offer then
		bits[#bits + 1] = "quote " .. GoldText(w.quote)
	end
	if w.mats then bits[#bits + 1] = "mats " .. w.mats end
	if w.deliver then bits[#bits + 1] = "via " .. w.deliver end
	if w.meet then bits[#bits + 1] = "meet: " .. w.meet end
	if w.cod then bits[#bits + 1] = "cod " .. GoldText(w.cod) end
	if w.mailFrom and w.mailFrom ~= "" then
		bits[#bits + 1] = "from " .. w.mailFrom
	end
	local mstat = W.MatsStatus and W.MatsStatus(w)
	if mstat then bits[#bits + 1] = "mats " .. mstat end
	if w.expires then
		local left = w.expires - time()
		bits[#bits + 1] = left > 0
			and (math.ceil(left / 3600) .. "h left") or "expired"
	end
	r.ctxt:SetText("» " .. table.concat(bits, "  ·  "))
	r.ctxt:Show()
	-- context inputs: quote price (gold), meet text or COD sender
	-- (edit) — the single text edit's meaning follows the state:
	-- crafter+agreed+cod needs the mail-from name; every other
	-- negotiable state wants the meet-place note
	local st = w.state
	local showGold = (st == "open" and w._side == "inb")
		or (st == "agreed" and w._side == "inb" and w.deliver == "cod")
		or (w._mail and w._side == "inb")
	local mode
	if w._mail then
	elseif st == "agreed" and w._side == "inb"
			and w.deliver == "cod" then
		mode = "mailFrom"
	elseif st == "open" or st == "quoted" or st == "agreed" then
		mode = "meet"
	end
	r.cgold:SetShown(showGold)
	r.cedit:SetShown(mode ~= nil)
	r.ceditMode = mode
	if showGold and r.cgold.ref ~= w.id then
		r.cgold:SetCopper(w.quote or w.offer or w.cod)
		r.cgold.ref = w.id
	end
	if mode and r.cedit.ref ~= w.id .. mode then
		r.cedit.ref = w.id .. mode
		r.cedit:SetText(mode == "meet" and (w.meet or "")
			or (w.mailFrom or ""))
		r.cedit.hint:SetText(mode == "meet" and "meet place…"
			or "mail from…")
	end
	r:Show()
end

function WU.Act(w, lbl)
	local board = w.board or ui.board
	local function msg(t) ui.wMsg:SetText(t) end
	-- detail rows are pooled — a repainted slot carries another
	-- writ's values; only read inputs stamped with THIS writ's id
	local dr = w._detailRow
	local function goldIn()
		if dr and dr.cgold.ref == w.id then
			return dr.cgold:GetCopper()
		end
	end
	local function textIn(mode)
		if dr and dr.ceditMode == mode
				and dr.cedit.ref == w.id .. mode then
			return dr.cedit:GetText()
		end
	end
	if lbl == "QUOTE" or lbl == "REQUOTE" then
		local p = goldIn()
		if not p or p <= 0 then
			msg("expand the writ and enter a quote price first")
			return
		end
		W.Act("wquote", w, { price = p })
		msg("quote staged (flush to apply)")
	elseif lbl == "ACCEPT" then
		W.Act("waccept", w, {})
		msg("accept staged")
	elseif lbl == "DECLINE" then
		W.Act("wdecline", w, {})
		msg("decline staged")
	elseif lbl == "CANCEL" then
		W.Act("wcancel", w, {})
		msg("cancel staged")
	elseif lbl == "SET MEET" then
		local mt = textIn("meet")
		if mt == nil then
			msg("expand the writ — the text field is the meet note")
			return
		end
		W.Act("wmeet", w, { meet = mt ~= "" and mt or nil })
		msg("meet note staged")
	elseif lbl == "SHIP" then
		local f = {}
		if w.deliver == "cod" then
			f.cod = goldIn()
			f.mailFrom = textIn("mailFrom")
		end
		W.Act("wship", w, f)
		msg("ship staged — customer confirms on receipt")
	elseif lbl == "RECEIVED" then
		W.Act("wrecv", w, {})
		msg("received staged — marks the writ done")
	elseif lbl == "MAIL MATS" then
		local ok = W.MailMats(w)
		msg(ok and "mats mailed — fingerprint staged on the writ"
			or "mats send failed — attach items at a mailbox")
	elseif lbl == "WITHDRAW" then
		if GM.db.writMail then GM.db.writMail[w.id] = nil end
		msg("mailed writ withdrawn")
	elseif lbl == "REPLY" then
		local ok = W.MailReply(w, goldIn() or w.offer or 0)
		msg(ok and "reply letter sent" or "reply failed")
	elseif lbl == "RENEW" then
		W.Request(board, w.toUUID or w.to, w.toChar, {
			ref = w.ref, name = w.name, itemID = w.itemID,
			qty = w.qty or 1, offer = w.offer or 0,
			mats = w.mats or "buyer", deliver = w.deliver or "cod",
		})
		msg("re-request staged")
	end
	WU.Paint("writs")
end

local function WritsPaint(vm)
	ui.board = vm and vm.board or ui.board
	local wp = ui.writsP
	local me = W.MyUUID()
	local rows = writRows()
	-- flatten: expanded writs add a detail sub-row
	local disp = {}
	for _, w in ipairs(rows) do
		disp[#disp + 1] = w
		if ui.expanded[w.id or "?"] then
			disp[#disp + 1] = { _detail = true, w = w }
		end
	end
	wp.title:SetText("MY WRITS — " .. (#rows) .. " threads")
	wp.count:SetText("")
	ui.wMsg:SetText(ui.wMsg:GetText() ~= "" and ui.wMsg:GetText()
		or "expand a writ for meet/quote/cod fields · mail channel "
			.. "requests are local-only (·mail)")
	for i = 1, ROWS do
		local r = ui.wRows[i]
		local e = disp[i + (ui.wscroll or 0)]
		if not e then
			r:Hide()
		elseif e._detail then
			e.w._detailRow = r
			detailRowPaint(r, e.w, me)
		else
			e._detailRow = nil
			writRowPaint(r, e, me)
		end
	end
	if #rows == 0 then
		wp.count:SetText("no writs — SHOPS tab requests work")
	end
end

function WU.Paint(tab, vm)
	if not ui then return end
	ui.tabShown = tab
	if tab == "shops" then
		ShopsPaint(vm)
	elseif tab == "writs" then
		WritsPaint(vm)
	end
end
