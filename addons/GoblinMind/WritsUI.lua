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
	-- shell so crafterTag/search/sort work unchanged. Each |H..|h
	-- capsule in the bark becomes a sub-line under the yeller —
	-- "Player / | Offer" — _gs keeps the group contiguous in the
	-- sort, _gi keeps capsule order.
	-- q-match predicate on a raw entry — the search runs per-entry
	-- BEFORE folder rows exist so a filtered list can't orphan a
	-- child under a folder that didn't survive
	local function qhit(e)
		if not (q and q ~= "") then return true end
		local ql = q:lower()
		local nm = (e.offer.name or ""):lower()
		local ch = (e.roster.chars
			and table.concat(e.roster.chars, " ") or ""):lower()
		return nm:find(ql, 1, true) or ch:find(ql, 1, true)
			or (e.offer.toon or ""):lower():find(ql, 1, true)
			or (e.offer.prof or ""):lower():find(ql, 1, true)
	end
	if q and q ~= "" then
		local hit = {}
		for _, e in ipairs(out) do
			if qhit(e) then hit[#hit + 1] = e end
		end
		out = hit
	end
	-- yell pseudo-offers fold in as ONE section: a master YELLS
	-- fold tab with BUY / SELL subfolders by bark intent, untagged
	-- barks under OTHER. GS_YELL shares one sort group so the whole
	-- section anchors the unpriced tail; _gi is just insert order
	-- inside each bucket (header + expanded lines + capsules
	-- already append consecutively per bark)
	local buckets = { buy = {}, sell = {}, other = {} }
	for _, y in ipairs(W.YellOffers and W.YellOffers() or {}) do
		local ros = { chars = { y.char }, stats = {}, _yell = true }
		local bk = y.intent == "buy" and buckets.buy
			or y.intent == "sell" and buckets.sell
			or buckets.other
		-- the prof filter reaches barks too — header tests y.prof,
		-- each capsule sub-row tests its own (a trade link's prof
		-- can differ from the bark's keyword guess)
		if not prof or y.prof == prof then
			local hdr = { yell = y, offer = {
				name = "yell: " .. y.text,
				prof = y.prof, itemID = y.itemID, ref = y.ref,
				_yell = true },
				roster = ros }
			if qhit(hdr) then bk[#bk + 1] = hdr end
			-- unfolded bark: the full message wraps into a bounded
			-- 500px window — markup stripped to visible text, greedy
			-- word-wrap at ~95 chars (Montserrat under-measurement
			-- makes pixel math unreliable), ONE SUB-ROW PER LINE so
			-- each gets its own 21px vertical clearance
			if y._expanded then
				local plain = y.text
					:gsub("|c%x%x%x%x%x%x%x%x", "")
					:gsub("|H[^|]*|h", "")
					:gsub("|h", "")
					:gsub("|r", "")
				local lines, cur = {}, nil
				for w in plain:gmatch("%S+") do
					if not cur then cur = w
					elseif #cur + 1 + #w <= 95 then
						cur = cur .. " " .. w
					else
						lines[#lines + 1] = cur
						cur = w
					end
				end
				if cur then lines[#lines + 1] = cur end
				for li, ln in ipairs(lines) do
					local e = { yell = y,
						offer = { name = "| " .. ln,
							prof = y.prof, _yell = true,
							_barkText = true },
						roster = ros }
					if qhit(e) then bk[#bk + 1] = e end
				end
			end
		end
		for si, lnk in ipairs(y.links or {}) do
			-- bark intent tags the row: buying (WTB/lf) vs selling
			-- (WTS/lfw) — read the tag before the capsule, the writ
			-- direction depends on it
			local lprof = (lnk.kind == "trade" and lnk.prof)
				or y.prof
			if not prof or lprof == prof then
				local itag = y.intent == "buy"
						and (GM.CC("secondary") .. "buy|r ")
					or y.intent == "sell"
						and (GM.CC("good") .. "sell|r ")
					or ""
				local e = { yell = y, offer = {
						-- disp = the printable capsule (color +
						-- brackets, no |H payload); raw link stays in
						-- _link for hover + click
						name = "| " .. itag
							.. (lnk.disp or lnk.link or lnk.name),
						prof = lprof,
						itemID = lnk.kind == "item" and lnk.id
							or nil,
						_yell = true, _link = lnk },
					roster = ros }
				if qhit(e) then bk[#bk + 1] = e end
			end
		end
	end
	-- folder injection: the master YELLS tab counts every visible
	-- bark; BUY / SELL / OTHER subfolders only emit when their
	-- bucket has rows, and a closed folder keeps just its tab row.
	-- ui.yellF holds the fold state (nil = open)
	-- \255 sorts above every single-byte name start and any UTF-8
	-- lead byte — the section always anchors the unpriced tail
	local GS_YELL = { name = "\255" }
	local F = ui.yellF or {}
	local nb = #buckets.buy + #buckets.sell + #buckets.other
	if nb > 0 then
		local yRos = { chars = {}, stats = {}, _yell = true }
		out[#out + 1] = { _gs = GS_YELL, _gi = -10,
			offer = { name = (F.yells and "+ " or "- ")
				.. "YELLS  ·  " .. nb, _folder = "yells" },
			roster = yRos }
		if not F.yells then
			for _, s in ipairs({
				{ "buy", "BUY", 0, buckets.buy },
				{ "sell", "SELL", 50000, buckets.sell },
				{ "other", "OTHER", 90000, buckets.other },
			}) do
				local key, label, base, L =
					s[1], s[2], s[3], s[4]
				if #L > 0 then
					out[#out + 1] = { _gs = GS_YELL, _gi = base,
						offer = { name = (F[key] and "+ " or "- ")
							.. label .. "  ·  " .. #L,
							_folder = key },
						roster = yRos }
					if not F[key] then
						for i, e in ipairs(L) do
							e._gs, e._gi = GS_YELL, base + i
							out[#out + 1] = e
						end
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		-- _gs groups (yeller header + capsule subs) sort as one
		-- entry: the head carries the group's price/name position,
		-- _gi orders members inside it
		local ha, hb = a._gs or a.offer, b._gs or b.offer
		local pa, pb = ha.price, hb.price
		if (pa ~= nil) ~= (pb ~= nil) then return pa ~= nil end
		if pa and pb and pa ~= pb then return pa < pb end
		local na, nb = tostring(ha.name), tostring(hb.name)
		if na ~= nb then return na < nb end
		if (a._gi or 0) ~= (b._gi or 0) then
			return (a._gi or 0) < (b._gi or 0)
		end
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
	for _, w in ipairs(v.mailOut or {}) do out[#out + 1] = w end
	for _, w in ipairs(v.mailIn or {}) do out[#out + 1] = w end
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
		-- letter-channeled eStore: seller confirms (accept/quote/
		-- decline), buyer confirms a quote or declines, seller
		-- ships COD on the agreed deal — two signatures each side
		local st = w.state or "mailed"
		if w._side == "out" then
			if st == "mailed" then return { "WITHDRAW" } end
			if st == "quoted" then return { "CONFIRM", "DECLINE" } end
			return {}
		end
		if st == "received" then return { "ACCEPT", "DECLINE" } end
		if st == "quoted" then return { "DECLINE" } end
		if st == "agreed" then return { "SHIP", "DECLINE" } end
		return {}
	end
	local st, side = w.state, w._side
	-- 'wpost' is the OTHER party's request still reconciling — the
	-- writ is real and quotable/declinable right now; only OUR
	-- staged ops should block re-acting
	if w._pendOp and w._pendOp ~= "wpost" then return {} end
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
		-- starts right of the price badge; surnames run long so the
		-- cell claims all the space the REQUEST button leaves
		r.who:SetPoint("LEFT", 398, 0)
		r.who:SetWidth(148)
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
			-- capsule rows carry the raw link (enchants, spell and
			-- trade capsules all tooltip through SetHyperlink);
			-- plain offers fall back to the item id
			local lnk, id = s.offerLink, s.offerID
			if not (lnk or id) then return end
			GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
			if lnk and lnk:match("|Htrade:") then
				-- SetHyperlink on a trade link OPENS the linked
				-- session on this client — the window was popping
				-- up on hover like a tooltip. Text-only here; the
				-- row click still opens it properly
				GameTooltip:AddLine(lnk)
				GameTooltip:AddLine("click to open their professions",
					0.6, 0.6, 0.6)
			elseif lnk then
				GameTooltip:SetHyperlink(lnk)
			elseif GameTooltip.SetItemByID then
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
	-- SEND. The offer's own mats term rides along — the listing is
	-- take-it-or-leave-it, not a negotiation form. Anchored under
	-- the clicked row.
	local pop = CreateFrame("Frame", nil, sp)
	pop:SetSize(300, 66)
	GM.Panel(pop, "contHigh")
	pop:SetFrameLevel(sp:GetFrameLevel() + 10)
	ui.reqPop = pop
	pop.title = GM.MakeFontString(pop, GM.FONT_BOLD, 9, "secondary")
	pop.title:SetPoint("TOPLEFT", 8, -5)
	pop.qty = MkEdit(pop, 44, "qty", true)
	pop.qty:SetPoint("TOPLEFT", 8, -24)
	pop.gold = GM.Widgets.GoldEdit(pop, 110)
	pop.gold:SetPoint("LEFT", pop.qty, "RIGHT", 6, 0)
	pop.send = MkBtn(pop, "SEND", 56, 15)
	pop.send:SetPoint("LEFT", pop.gold, "RIGHT", 8, 0)
	pop.hint = GM.MakeFontString(pop, GM.FONT, 9, "textDim")
	pop.hint:SetPoint("TOPLEFT", 8, -46)
	pop.hint:SetWidth(284)
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
	ui.wClear = MkBtn(wp, "CLEAR", 58, 13)
	ui.wClear:SetPoint("TOPRIGHT", -8, -14)
	ui.wClear:SetScript("OnClick", function()
		local n = W.ClearDone()
		ui.wMsg:SetText(n > 0 and (n .. " cleared")
			or "nothing to clear")
		WU.Paint("writs")
	end)
	ui.wClear:Hide()

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
		-- the "per unit" tag parks on that trailing edge — writ
		-- prices are per-unit, totals only appear computed
		r.cunit = GM.MakeFontString(r, GM.FONT, 8, "textDim")
		r.cunit:SetPoint("LEFT", 486, -1)
		r.cunit:SetText("per unit")
		r.cedit = MkEdit(r, 128, "")
		r.cedit:SetPoint("LEFT", 550, -1)
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
	-- capsule/unfold leftovers aren't in the position table — a
	-- browse-mode link chip or bark OnClick survives a mode switch
	-- and bleeds through the next mode's rows
	if r.chip then r.chip:Hide() end
	if r.tail then r.tail:Hide() end
	r:SetScript("OnClick", nil)
	r.offerLink = nil
	r.name:SetWidth(mode == "myshop" and 116 or 204)
	r.prof:SetWidth(mode == "myshop" and 52 or 74)
	r.who:SetWidth(mode == "myshop" and 108 or 148)
	r.note:SetWidth(mode == "myshop" and 82 or 104)
end

local function offerIcon(o)
	if o.itemID then return GM.ItemIcon(o.itemID) end
	-- enchant/spell capsules icon through the spell API
	local l = o._link
	if l and l.id and l.kind ~= "item" and GetSpellInfo then
		local ok, tex = pcall(function()
			return select(3, GetSpellInfo(l.id)) end)
		if ok and tex then return tex end
	end
	return nil
end

-- identity for repaint survival — marketRows rebuilds entries
-- every paint, so match on the offer's stable fields; ShopsPaint
-- re-anchors the popover to wherever this entry landed
local function reqKey(e)
	local o = e and e.offer
	if not o then return nil end
	if e.yell then
		return "y|" .. tostring(e.yell.id) .. "|" .. tostring(e._gi)
	end
	return "o|" .. tostring(e.roster and e.roster.uuid)
		.. "|" .. tostring(o.ref or o.name)
		.. "|" .. tostring(o.toon)
end

-- REQUEST popover state: which roster+offer is being ordered
local function openRequest(row, e)
	local pop = ui.reqPop
	ui.req = e
	local o = e.offer
	pop.e = e
	pop._reqKey = reqKey(e)
	pop.title:SetText("REQUEST — " .. (o.name or "?") .. "  ·  "
		.. ((GM.NameColored and GM.NameColored(
			o.toon or (e.roster.chars and e.roster.chars[1]) or "?"))
			or "?"))
	pop.qty:SetText(tostring(o.numMade or 1))
	local sug = W.Suggest(o.ref, o.numMade or 1)
	local perUnit = sug and sug.price
		and math.floor(sug.price / math.max(1, o.numMade or 1))
		or nil
	pop.gold:SetCopper(o.price or perUnit)
	pop.sug = sug
	pop.hint:SetText(sug and string.format(
		"suggest %s/ea (%s for x%d · mats %s + market %s)",
		perUnit and GoldText(perUnit) or "—",
		sug.price and GoldText(sug.price) or "—",
		o.numMade or 1,
		sug.mats and GoldText(sug.mats) or "—",
		sug.market and GoldText(sug.market) or "—")
		or "no market data — set a price or send OFFER")
	pop.send:SetScript("OnClick", function()
		local qty = math.max(1, math.floor(
			tonumber(pop.qty:GetText()) or 1))
		local price = pop.gold:GetCopper()
		W.Request(ui.board, e.roster.uuid,
			o.toon or (e.roster.chars and e.roster.chars[1]) or nil, {
				ref = o.ref, name = o.name, itemID = o.itemID,
				qty = qty, offer = price or 0,
				mats = o.mats or "buyer",
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
		r._ent = e
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
			r.offerLink = o._link and o._link.link or nil
			if r.chip then r.chip:Hide() end
			if r.tail then r.tail:Hide() end
			r:SetScript("OnClick", nil)
			local ic = offerIcon(o)
			if ic then r.icon:SetTexture(ic) r.icon:Show()
			else r.icon:Hide() end
			-- terms ride the name cell: prepaid | ·buyer (you supply
			-- mats) | ·crafter (provided, priced in). Unset policy
			-- defaults to buyer — the writ contract's own default.
			local nm = o.name or o.ref or "?"
			if not o._yell and not o._folder then
				nm = nm .. GM.CC("textDim") .. " ·"
					.. (o.mats or "buyer") .. "|r"
			end
			r.name:SetText(nm)
			r.name:SetTextColor(GM.RGB("text"))
			r.prof:SetText(o.prof or "")
			if o._folder then
				-- fold tab: the whole row is the toggle — dim
				-- label, no price/crafter/actions of its own
				r.name:SetText(GM.CC("accent") .. o.name .. "|r")
				r.prof:SetText("")
				r.price:SetText("")
				r.who:SetText("")
				r.act:Hide()
				r.act2:Hide()
				local fk = o._folder
				r:SetScript("OnClick", function()
					ui.yellF = ui.yellF or {}
					ui.yellF[fk] = not ui.yellF[fk] or nil
					WU.Paint("shops")
				end)
			elseif o._yell then
				local y = e.yell
				if o._barkText then
					-- unfolded bark line: pre-wrapped text across
					-- the offer+prof+price span — the name cell
					-- would clip at 204 so widen it for this row
					r.name:SetWidth(500)
					r.name:SetText(GM.CC("textDim")
						.. o.name .. "|r")
					r.prof:SetText("")
					r.price:SetText("")
					r.who:SetText("")
					r.act:Hide()
					r.act2:Hide()
				elseif o._link then
					-- capsule sub-offer: suggested price where the
					-- DB can derive one, hover gives the real
					-- tooltip, "+" mails a writ for THIS item
					local l = o._link
					local sug = W.CapsulePrice and W.CapsulePrice(l)
					r.price:SetText(sug and GoldText(sug) or "—")
					r.price:SetTextColor(GM.RGB(
						sug and "text" or "textDim"))
					r.who:SetText("")
					-- the capsule IS the advert: prof/who cells stay
					-- empty so the chip gets the whole left span
					r.prof:SetText("")
					r.name:SetText("")
					r.chip = r.chip
						or GM.Widgets.LinkChip(r, 286, 13)
					r.chip:ClearAllPoints()
					r.chip:SetPoint("LEFT", 40, 0)
					r.chip._pre = function()
						-- the yeller IS the owner — pre-stamp so
						-- attribution never needs the chat ring
						GM.LinkFrom = { char = y.char,
							t = time(), kind = "trade" }
					end
					r.chip:SetCapsule(l.link, o.name)
					r.act.text:SetText("+")
					r.act.text:SetTextColor(GM.RGB("accent"))
					r.act:Show()
					r.act:SetScript("OnClick", function()
						local wid = W.MailRequest(y.char, {
							name = l.name,
							ref = l.id and l.kind ~= "item"
								and ("s:" .. l.id) or nil,
							itemID = l.kind == "item" and l.id or nil,
							qty = 1, offer = sug,
							mats = "buyer", deliver = "trade",
							note = "saw your yell — "
								.. y.text:sub(1, 60) })
						ui.shopMsg:SetText(wid
							and ("mail-writ sent to " .. y.char
								.. " — watch MY WRITS")
							or "mail send failed")
					end)
					r.act2:Hide()
				else
				-- bark row: no price claim — badge + whisper/mail
				-- actions instead of a server writ request. The
				-- +/- marker is the unfold affordance — clicking
				-- the row splices in a full-text sub-row
				r.price:SetText(GM.CC("textDim")
					.. (y._expanded and "- " or "+ ")
					.. "·yell "
					.. GM.FmtAge(time() - (y.t or time()))
					.. ((y.n or 1) > 1 and (" ×" .. y.n) or "")
					.. (y.intent == "buy"
							and (GM.CC("secondary") .. " ·buy")
						or y.intent == "sell"
							and (GM.CC("good") .. " ·sell")
						or "")
					.. "|r")
				GM.Widgets.NameTag(r.who, y.char, "textDim")
				-- the bark's capsule stays INLINE in the name cell —
				-- it renders colored + bracketed like chat. The
				-- interactive copy lives in the sub-row chips;
				-- splicing a chip mid-text needs pixel widths and
				-- GetStringWidth under-measures Montserrat on this
				-- client, which painted text on text
				r:SetScript("OnClick", function()
					y._expanded = not y._expanded
					WU.Paint("shops")
				end)
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
				end
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
	-- the REQUEST popover survives repaints — re-anchor to wherever
	-- its entry landed; the entry leaving the painted set (sold
	-- out, filtered, scrolled off) is what actually closes it
	local pop, keep = ui.reqPop, nil
	if pop:IsShown() and pop._reqKey then
		for i = 1, ROWS do
			local r = ui.sRows[i]
			if r:IsShown() and r._ent
					and reqKey(r._ent) == pop._reqKey then
				keep = r break
			end
		end
	end
	if keep then
		pop:ClearAllPoints()
		pop:SetPoint("TOPLEFT", keep, "BOTTOMLEFT", 60, -2)
	else
		pop:Hide()
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
	r.cunit:Hide()
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
	-- prices are per-unit everywhere — /ea on the stored fields,
	-- the derived total spelled out so nobody multiplies in head
	if w.offer then
		bits[#bits + 1] = "offer " .. GoldText(w.offer) .. "/ea"
	end
	if w.quote and w.quote ~= w.offer then
		bits[#bits + 1] = "quote " .. GoldText(w.quote) .. "/ea"
	end
	local unit = W.UnitPrice(w)
	if unit > 0 and (w.qty or 1) > 1 then
		bits[#bits + 1] = "total " .. GoldText(unit * w.qty)
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
	elseif st == "agreed" then
		-- meet terms are delivery logistics — they matter once the
		-- deal is agreed, not during quote negotiation
		mode = "meet"
	end
	r.cgold:SetShown(showGold)
	r.cunit:SetShown(showGold)
	r.cedit:SetShown(mode ~= nil)
	r.ceditMode = mode
	if showGold and r.cgold.ref ~= w.id then
		local u = W.UnitPrice(w)
		r.cgold:SetCopper(u > 0 and u
			or (w.cod and math.floor(w.cod / (w.qty or 1))) or nil)
		r.cgold.ref = w.id
	end
	if mode and r.cedit.ref ~= w.id .. mode then
		r.cedit.ref = w.id .. mode
		r.cedit:SetText(mode == "meet" and (w.meet or "")
			or (w.mailFrom or ""))
		r.cedit.hint:SetText(mode == "meet" and "meet place…"
			or "mail from…")
	end
	-- counter-quote rides the detail row: the header only has two
	-- buttons (ACCEPT/DECLINE), so a price counter lives here with
	-- the gold field it reads
	if w._mail and w._side == "inb"
			and (st == "received" or st == "quoted") then
		r.a1.text:SetText("SEND QUOTE")
		r.a1.text:SetTextColor(GM.RGB("warn"))
		r.a1:Show()
		r.a1:SetScript("OnClick", function()
			WU.Act(w, "SEND QUOTE")
		end)
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
		if w._mail then
			local ok = W.MailAccept(w)
			msg(ok and "accepted — confirmation mailed to the buyer"
				or "accept failed — mailbox needed")
		else
			W.Act("waccept", w, {})
			msg("accept staged")
		end
	elseif lbl == "CONFIRM" then
		-- buyer countersigns the quote — GMW1A back to the seller
		local ok = W.MailConfirmOut(w)
		msg(ok and "quote confirmed — expect a COD shipment"
			or "confirm failed — mailbox needed")
	elseif lbl == "DECLINE" then
		if w._mail then
			local ok = w._side == "inb" and W.MailDecline(w)
				or W.MailDeclineOut(w)
			msg(ok and "decline mailed" or "decline failed")
		else
			W.Act("wdecline", w, {})
			msg("decline staged")
		end
	elseif lbl == "SEND QUOTE" or lbl == "REPLY" then
		local p = goldIn() or w.offer
		if w._mail then
			local ok = p and W.MailReply(w, p)
			msg(ok and "quote mailed" or "quote failed — mailbox needed")
		else
			if not p or p <= 0 then
				msg("enter a quote price in the detail field first")
				return
			end
			W.Act("wquote", w, { price = p })
			msg("quote staged (flush to apply)")
		end
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
		if w._mail then
			-- attach the goods in the send slots at a mailbox —
			-- SendMail carries the letter + COD + GMW1S wire
			local ok = W.MailShip(w)
			msg(ok and "COD shipment sent — writ marked shipped"
				or "ship failed — attach the item at a mailbox")
		elseif w.deliver == "cod" then
			-- attach the goods at a mailbox — the COD letter is
			-- the delivery receipt; wship stages on send success
			local ok = W.MeshShip(w, goldIn(), textIn("mailFrom"))
			msg(ok and "COD shipment sent — writ marked shipped"
				or "ship failed — attach the item at a mailbox")
		else
			W.Act("wship", w, {})
			msg("ship staged — customer confirms on receipt")
		end
	elseif lbl == "RECEIVED" then
		W.Act("wrecv", w, {})
		msg("received staged — marks the writ done")
	elseif lbl == "MAIL MATS" then
		local ok = W.MailMats(w)
		msg(ok and "mats mailed — fingerprint staged on the writ"
			or "mats send failed — attach items at a mailbox")
	elseif lbl == "WITHDRAW" then
		W.MailWithdraw(w)
		msg("mailed writ withdrawn")
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
	do
		local any = false
		for _, w in ipairs(rows) do
			if W.Terminal(w.state) then any = true break end
		end
		ui.wClear:SetShown(any)
	end
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
