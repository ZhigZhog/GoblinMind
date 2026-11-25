local _, GM = ...

-- ================================================================
-- MarketUI.lua — MARKET page inside the AH session window. The
-- item drill-down terminal: price series + supply bars, market
-- depth, full ask book with intel flags, the numbers dump, and the
-- merged planner (PQ engine). AH-context plans route here from
-- PQ.Show; the standalone plan window keeps everything else.
--
-- FIRST GoblinUI-converted page (the pilot): the whole pane is a
-- Column/Row tree — containers own child geometry, no pane can
-- overlap another. Charts draw inside Canvas nodes; dense panes
-- carry List/Scroll children.
-- ================================================================

local AU = GM.AHUI
local MU = {}
GM.MarketUI = MU

local W = GM.Widgets
local tinsert, sort = tinsert, table.sort
local floor = math.floor
local format = format
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

local ui, mp -- AHUI's ui table + our page container (set by Build)
local M = {} -- market state: itemID, link, asks, askT
MU.M = M

local ASK_ROW_H = 20

-- ============ art pool (canvas primitives — absolute coords are
-- legal inside a Canvas node's content frame only) ============

local art = {}
local function FreeArt()
	for _, a in ipairs(art) do a:Hide() end
	wipe(art)
end
local function Dot(parent, x, y, size, key, layer)
	local t = parent:CreateTexture(nil, layer or "OVERLAY")
	tinsert(art, t)
	local r, g, b = GM.RGB(key or "text")
	t:SetColorTexture(r, g, b, 1)
	t:SetSize(size, size)
	t:SetPoint("CENTER", parent, "BOTTOMLEFT", x, y)
	return t
end
local function Segment(parent, x1, y1, x2, y2, key, layer)
	local dx, dy = x2 - x1, y2 - y1
	local steps = math.max(1, floor(sqrt(dx * dx + dy * dy) / 2))
	for i = 0, steps do
		Dot(parent, x1 + dx * i / steps, y1 + dy * i / steps, 2, key or "accent", layer)
	end
end
local function Label(parent, x, y, str, key, size, justify)
	local fs = GM.MakeFontString(parent, GM.FONT, size or 9, key or "textDim")
	tinsert(art, fs)
	fs:SetPoint(justify == "LEFT" and "BOTTOMLEFT"
		or justify == "RIGHT" and "BOTTOMRIGHT" or "CENTER",
		parent, "BOTTOMLEFT", x, y)
	fs:SetJustifyH(justify or "CENTER")
	fs:SetText(str)
	return fs
end
local function Bar(parent, x, y, w, h, key, alpha, layer)
	local t = parent:CreateTexture(nil, layer or "BACKGROUND")
	tinsert(art, t)
	local r, g, b = GM.RGB(key)
	t:SetColorTexture(r, g, b, alpha or 0.5)
	t:SetSize(math.max(1, w), math.max(1, h))
	t:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x, y)
	return t
end

-- ============ asks + intel flags ============

-- per-lot flags are computed at scan time by GM.Intel.AnalyzeItem —
-- the same ladder analysis the book pass runs, so targeted scans
-- feed marks, wall history, and the suspect table too

-- which book flag is holding the query — visible in the busy text
-- so a permanently stuck latch reports itself instead of a dead pane
local function BusyText()
	local f = GM.AH.wantBook and "replicate"
		or GM.AH.collecting and "collect"
		or GM.AH.browse and "browse"
	return f and ("book " .. f .. " in flight…") or "scan busy…"
end

local function ScanAsks()
	if not M.itemID then return end
	-- askWait is a TIMESTAMP, not a bool: past 90s the busy flags
	-- themselves are suspect (a dead collect chain leaves
	-- 'collecting' set forever) — try the query anyway; a refused
	-- SendSearchQuery costs nothing vs a permanently dead pane
	local stale = M.askWait and GetTime() - M.askWait > 90
	if GM.AH.Busy and GM.AH.Busy() and not stale then
		if not M.askWait then
			M.askWait = GetTime()
			local id = M.itemID
			local function retry()
				if not M.askWait or M.itemID ~= id or not GM.AH.open then
					return
				end
				if GM.AH.Busy and GM.AH.Busy()
					and GetTime() - M.askWait < 90 then
					GM.After(2, retry)
				else ScanAsks() end
			end
			GM.After(2, retry)
		end
		return
	end
	M.askWait = nil
	local id, name = M.itemID, GM.ItemName(M.itemID)
	-- throttle-dropped searches answer nothing — retry once before
	-- declaring the book empty so a lost query doesn't read as "no asks"
	M.askTries = (M.askTries or 0) + 1
	GM.After(6, function()
		if M.itemID == id and not M.asks and (M.askTries or 0) < 3 then
			ScanAsks()
		end
	end)
	GM.AH.ScanItem(id, name, function(asks)
		if M.itemID ~= id then return end -- retargeted mid-scan
		M.asks = asks or {}
		M.askT = GetTime()
		-- targeted scans feed the same marks + suspect table as the
		-- book pass — intel accumulates without waiting on full scans.
		-- A variant-scoped ladder describes one suffix's market, not
		-- the item's — feeding it would mint bait/wall claims off a
		-- handful of lots the same way it would corrupt the book row
		if not (M.itemKey and (M.itemKey.itemSuffix or 0) ~= 0) then
			if GM.Intel and GM.Intel.AnalyzeItem then
				GM.Intel.AnalyzeItem(id, M.asks, time())
			end
		end
		-- …and freshen the item's book row: mb/sup/n derive from the
		-- ladder the same way CollectBook derives them, so a page-
		-- scoped autoscan keeps the chips + NUMBERS live too.
		-- SUFFIXED scans describe one variant only — writing them into
		-- the itemID-wide row would shrink a 38-lot market to 1 and
		-- lie about mb/sup until the per-key book exists (roadmap)
		local suffixed = M.itemKey and (M.itemKey.itemSuffix or 0) ~= 0
		if asks[1] and not suffixed then
			GM.AH.book = GM.AH.book or {}
			local e = GM.AH.book[id]
			if not e then e = {} GM.AH.book[id] = e end
			e.mb, e.sup, e.n = asks[1].unit, 0, #asks
			e.mbx = math.huge
			for _, a in ipairs(asks) do
				e.sup = e.sup + a.qty
				if not a.own and a.unit < e.mbx then e.mbx = a.unit end
			end
		end
		MU.Refresh()
	end, M.itemKey)
end

function MU.SetItem(id, link, key)
	if not id then return end
	-- same id under a different suffix is a different market — the
	-- cached ladder belongs to the old variant's key
	local changed = M.itemID ~= id
		or (M.itemKey and M.itemKey.itemSuffix or 0)
			~= (key and key.itemSuffix or 0)
	M.itemID, M.itemLink, M.itemKey = id, link, key
	if changed then
		M.asks, M.askT, M.askTries, M.askWait = nil, nil, nil, nil
		ScanAsks()
	end
	-- the planner target follows the market slot — a change to one
	-- is a change to the other (itemKey passes too: suffixed variants
	-- scan nothing under the suffix-0 base key; same id + different
	-- suffix is still a retarget)
	local pk = GM.PlanQueue.itemKey
	if GM.PlanQueue.itemID ~= id
		or (pk and pk.itemSuffix or 0) ~= (key and key.itemSuffix or 0) then
		GM.PlanQueue.SetItem(id, link, key)
	end
	if MU.Refresh then MU.Refresh() end
end

-- ============ price chart ============

local WEEK = 7 * 86400
local function DrawPrice(entry)
	local ch = mp.priceContent
	ch.msg:SetText("")
	local pts, seriesMode, window = {}, false, WEEK
	if M.itemID and GM.History then
		local s = GM.History.Points(M.itemID, WEEK)
		if #s >= 2 then
			seriesMode = true
			local span = s[#s].t - s[1].t
			if span < 0.85 * WEEK then window = math.max(span * 1.25, 3600) end
			local t0 = time() - window
			for _, p in ipairs(s) do
				local x = (p.t - t0) / window
				x = x < 0 and 0 or x > 1 and 1 or x
				tinsert(pts, { x = x, v = p.p, s = p.s })
			end
			if entry and entry.p then
				tinsert(pts, { x = 1.0, v = entry.p, hot = true })
			end
		end
	end
	if not seriesMode and entry then
		if entry.hist then tinsert(pts, { x = 0.05, v = entry.hist }) end
		if entry.recent and entry.recent ~= (entry.hist or 0) then
			tinsert(pts, { x = 0.5, v = entry.recent })
		end
		if entry.p then tinsert(pts, { x = 0.95, v = entry.p, hot = true }) end
	end
	mp.pricePanel:SetTitle(seriesMode and "Price · Supply — 7d"
		or "Price References")
	if #pts < 2 then
		ch.msg:SetText(M.itemID
			and "trend chart — building a 7-day series"
			or "target an item — drop one in the slot above")
		return
	end
	local lo, hi = math.huge, 0
	for _, p in ipairs(pts) do
		lo = math.min(lo, p.v) hi = math.max(hi, p.v)
	end
	-- the live min ask belongs in the scale — below the series floor
	-- it rendered off-chart (no mb line, its label hanging under the
	-- axis) instead of marking the bottom of the book
	if entry and entry.mb then
		lo = math.min(lo, entry.mb) hi = math.max(hi, entry.mb)
	end
	if hi == lo then hi = lo + 1 end
	local pad = (hi - lo) * 0.08
	lo = lo - pad hi = hi + pad
	local padX, gutter = 8, 60
	local cw = ch:GetWidth() - padX - gutter
	local top, base = ch:GetHeight() - 14, 22
	local volTop = 18 -- supply bars live under the line
	local function px(x) return padX + x * cw end
	local function py(v) return base + (v - lo) / (hi - lo) * (top - base) end
	-- right-gutter labels all justify to the same edge — mb/mkt/
	-- hi/lo/last pile up when prices are close, so collect them and
	-- push colliding entries apart instead of overdrawing
	local axis = {}
	local function axisLabel(y, str, key, size)
		axis[#axis + 1] = { y = y, str = str, key = key, size = size or 9 }
	end
	-- mkt / mb horizontals (under the candles)
	if entry and entry.p and entry.p >= lo and entry.p <= hi then
		local y = py(entry.p)
		Bar(ch, padX, y, cw, 1, "secondary", 0.6)
		axisLabel(y + 2, "mkt", "secondary", 8)
	end
	if entry and entry.mb and entry.mb >= lo and entry.mb <= hi then
		local y = py(entry.mb)
		Bar(ch, padX, y, cw, 1, "warn", 0.5)
		axisLabel(y + 2, "mb", "warn", 8)
	end
	if seriesMode then
		-- OHLC candles — the real tape: each time bucket's open/close
		-- are its first/last samples, the I-beam stem+caps carry the
		-- bucket's extremes; body green when the period closed up, red down
		local NB = math.max(8, math.min(30, floor(cw / 26)))
		local cs, occ = {}, {}
		for _, p in ipairs(pts) do
			local b = math.min(NB, math.max(1, floor(p.x * NB) + 1))
			local c = cs[b]
			if not c then
				c = { o = p.v, h = p.v, l = p.v, c = p.v, s = 0, sn = 0 }
				cs[b] = c
				occ[#occ + 1] = b
			end
			c.h = math.max(c.h, p.v) c.l = math.min(c.l, p.v) c.c = p.v
			if p.s then c.s = c.s + p.s c.sn = c.sn + 1 end
		end
		local step = cw / NB
		local bw = math.max(3, math.min(14, step * 0.55))
		local smax = 0
		for _, b in ipairs(occ) do
			local c = cs[b]
			if c.sn > 0 then smax = math.max(smax, c.s / c.sn) end
		end
		for _, b in ipairs(occ) do
			local c = cs[b]
			local cx = padX + (b - 0.5) * step
			if c.sn > 0 and smax > 0 then
				Bar(ch, cx - bw / 2, 4, bw, c.s / c.sn / smax * volTop,
					"contHigh", 0.9, "BACKGROUND")
			end
			local key = c.c >= c.o and "pos" or "err"
			-- I-beam candle: stem + caps straddling the extremes, with
			-- a minimum glyph height so a flat candle still draws an
			-- I instead of collapsing into the MA line
			local sl, sh = py(c.l), py(c.h)
			if sh - sl < 5 then
				local grow = (5 - (sh - sl)) / 2
				sl, sh = sl - grow, sh + grow
			end
			Bar(ch, cx - 0.5, sl, 1, math.max(1, sh - sl), key, 0.7, "ARTWORK")
			Bar(ch, cx - bw / 2, sh - 0.5, bw, 1, key, 0.9, "ARTWORK")
			Bar(ch, cx - bw / 2, sl - 0.5, bw, 1, key, 0.9, "ARTWORK")
			Bar(ch, cx - bw / 2, py(math.min(c.o, c.c)), bw,
				math.max(1, py(math.max(c.o, c.c)) - py(math.min(c.o, c.c))),
				key, 0.9, "ARTWORK")
		end
		-- moving average over candle closes — the overlay real
		-- terminals carry instead of a raw regression line
		local PER, prev = 5, nil
		for i, b in ipairs(occ) do
			local s, n = 0, 0
			for j = math.max(1, i - PER + 1), i do
				s = s + cs[occ[j]].c n = n + 1
			end
			local ma, x = s / n, (b - 0.5) / NB
			if prev then
				Segment(ch, px(prev[1]), py(prev[2]), px(x), py(ma), "textDim")
			end
			prev = { x, ma }
		end
		local lastB = occ[#occ]
		Dot(ch, px((lastB - 0.5) / NB), py(cs[lastB].c), 5, "accent")
		axisLabel(py(cs[lastB].c) - 5, GM.Money(cs[lastB].c), "text", 10)
	else
		for i = 2, #pts do
			Segment(ch, px(pts[i - 1].x), py(pts[i - 1].v),
				px(pts[i].x), py(pts[i].v))
		end
		local last = pts[#pts]
		Dot(ch, px(last.x), py(last.v), 5, "accent")
		axisLabel(py(last.v) - 5, GM.Money(last.v), "text", 10)
	end
	axisLabel(top + 1, GM.Money(hi), "textDim", 9)
	axisLabel(base + 2, GM.Money(lo), "textDim", 9)
	-- de-collide: sort by ideal y, then walk down enforcing a 10px
	-- minimum gap so close prices get stacked labels, not a blob
	sort(axis, function(a, b) return a.y > b.y end) -- y is bottom-up
	for i = 2, #axis do
		if axis[i].y > axis[i - 1].y - 10 then
			axis[i].y = axis[i - 1].y - 10
		end
	end
	for _, a in ipairs(axis) do
		Label(ch, ch:GetWidth() - 4, a.y, a.str, a.key, a.size, "RIGHT")
	end
	if seriesMode then
		Label(ch, padX, 4, window >= WEEK and "7d ago"
			or GM.FmtAge(window) .. " ago", "textDim", 8, "LEFT")
		Label(ch, padX + cw, 4, "now", "textDim", 8, "RIGHT")
	end
end

-- ============ depth chart ============

local function DrawDepth()
	local ch = mp.depthContent
	ch.msg:SetText("")
	local asks = M.asks
	if not (asks and #asks > 0) then
		mp.depthPanel:SetTitle("Depth")
		ch.msg:SetText(M.itemID and (M.askWait and BusyText()
			or M.asks and "no asks listed" or "scanning asks…")
			or "no item targeted")
		return
	end
	mp.depthPanel:SetTitle("Depth — Cumulative")
	local pmin, pmax = asks[1].unit, asks[#asks].unit
	if pmax <= pmin then pmax = pmin + 1 end
	local span = pmax - pmin
	pmin = pmin - span * 0.04 pmax = pmax + span * 0.04
	local padX, gutter = 8, 34
	local cw = ch:GetWidth() - padX - gutter
	local top, base = ch:GetHeight() - 14, 14
	local function px(v) return padX + (v - pmin) / (pmax - pmin) * cw end
	local cum, cmax = {}, 0
	for i, a in ipairs(asks) do
		cmax = cmax + a.qty
		cum[i] = cmax
	end
	if cmax == 0 then return end
	-- step fills: each rung paints from its price to the next rung's
	for i, a in ipairs(asks) do
		local x1, x2 = px(a.unit), px(asks[i + 1] and asks[i + 1].unit or pmax)
		local h = cum[i] / cmax * (top - base)
		local key = a.own and "accent" or a.bait and "err"
			or a.wall and "warn" or "contHigh"
		Bar(ch, x1, base, x2 - x1, h, key, a.own and 0.85 or a.bait and 0.7
			or a.wall and 0.65 or 0.5)
		Bar(ch, x1, base + h, x2 - x1, 1,
			a.own and "accent" or a.bait and "err" or a.wall and "warn"
				or "textDim", 0.9, "ARTWORK")
	end
	-- mkt vertical
	local entry = M.itemID and GM.ItemEntry(M.itemID)
	if entry and entry.p and entry.p > pmin and entry.p < pmax then
		local x = px(entry.p)
		Bar(ch, x, base, 1, top - base, "secondary", 0.8, "ARTWORK")
		Label(ch, x, top + 1, "mkt", "secondary", 8)
	end
	Label(ch, padX, 2, GM.Money(pmin), "textDim", 8, "LEFT")
	Label(ch, padX + cw, 2, GM.Money(pmax), "textDim", 8, "RIGHT")
	Label(ch, padX + cw + 30, base + (top - base) / 2 - 4,
		format("%du", cmax), "textDim", 8, "RIGHT")
end

-- ============ pane repaints ============

local function RefreshHeader()
	local id = M.itemID
	mp.icon:SetTexture(id and GM.ItemIcon(id) or 134400)
	mp.name:SetText(id and (GM.ItemName(id) or ("item " .. id))
		or "no item targeted")
	mp.name.fontString:SetTextColor(GM.NameColor(id))
	local entry = id and GM.ItemEntry(id)
	local chips = {}
	if entry then
		if entry.mb then tinsert(chips, "mb " .. GM.Money(entry.mb)) end
		local mkt = entry.p or entry.mkt
		if mkt then tinsert(chips, "mkt " .. GM.Money(mkt)) end
		if entry.mb and mkt and mkt > 0 then
			local d = (entry.mb - mkt) / mkt * 100
			tinsert(chips, format("%s%.0f%%|r",
				GM.CC(d <= -5 and "pos" or d >= 5 and "warn" or "textDim"), d))
		end
		if entry.sup then tinsert(chips, "sup " .. entry.sup) end
		if entry.n then tinsert(chips, entry.n .. " lots") end
		if entry.vel then tinsert(chips, "vel "
			.. (GM.VelRate and GM.VelRate(entry.vel) or entry.vel) .. "/d") end
	end
	if #chips == 0 then chips[1] = GM.CC("textDim")
		.. "drop an item in the slot · shift-click one · /goblin [link]|r" end
	mp.chips:SetText(table.concat(chips, GM.CC("textDim") .. "  ·  |r"))
	-- the slot mirrors the current target so retargeting reads as a
	-- filled field, not an empty input
	mp.slot:SetItem(id, M.itemLink)
end

-- ask-book row paint, called by the List's bindRow on every
-- (re)bind — row frames carry their cells, the scroll pool reuses
-- them; flags re-derive here so suspect state is never stale
local function BindAskRow(row, a, idx)
	-- a.solver is recomputed on bind: a book scan can land between
	-- list updates and flip IsSuspect under a painted row
	a.solver = a.seller and GM.Intel
		and GM.Intel.IsSuspect(a.seller) or nil
	row.bg:SetColorTexture(GM.RGB(idx % 2 == 0
		and "contMedium" or "contLowest"))
	row.c1:SetText((a.bait and GM.CC("err") or a.wall and GM.CC("warn")
		or GM.CC("text")) .. GM.Money(a.unit) .. "|r")
	row.c2:SetText("×" .. a.qty)
	local flags = {}
	if a.own then tinsert(flags, GM.CC("accent") .. "MINE|r") end
	if a.wall then tinsert(flags, GM.CC("warn") .. "WALL|r") end
	if a.bait then tinsert(flags, GM.CC("err") .. "BAIT|r") end
	if a.step then tinsert(flags, GM.CC("warn") .. "STEP|r") end
	if a.solver then tinsert(flags, GM.CC("err") .. "⚠|r") end
	-- no seller name (commodity API returns none) — the owner count
	-- is the honest fallback display
	local seller = a.seller
		or (a.nOwners and a.nOwners > 0
			and (a.nOwners .. (a.nOwners == 1 and " seller" or " sellers")))
		or "?"
	row.c3:SetText(seller .. (#flags > 0 and "  " .. table.concat(flags, " ") or ""))
	row.c4:SetText(a.tl and GM.FmtAge(a.tl) or "")
	if a.own then row.act:Hide()
	else
		row.act:Show()
		row.act.text:SetText("BUY")
		row.act:SetScript("OnClick", function()
			if a.id then
				GM.AH.Execute({ kind = "buy", itemID = M.itemID,
					auctionID = a.id, qty = a.qty, unit = a.unit,
					total = a.total })
			else
				GM.AH.Execute({ kind = "buy", commodity = true,
					itemID = M.itemID, qty = a.qty, unit = a.unit })
			end
			MU.Refresh()
		end)
	end
	row.a = a
end

local function RefreshAskBook()
	local asks = M.asks or {}
	mp.askPanel:SetTitle("Ask Book")
	-- scan age rides the count — AUTO's cycle becomes visible: the
	-- seconds climb to ~60 then reset when the ladder rescans
	local cnt = #asks > 0 and format("%d lots", #asks) or ""
	if #asks > 0 and M.askT then
		cnt = cnt .. "  ·  " .. floor(GetTime() - M.askT) .. "s"
	end
	mp.askPanel:SetCount(cnt)
	mp.abEmpty:SetText(M.itemID and (M.askWait and BusyText()
		or (not M.asks and "scanning…") or "no asks")
		or "")
	mp.abEmpty:SetShown(#asks == 0)
	mp.askList:SetItems(asks)
end

local NUM_FIELDS = {
	{ "mb", "Min buyout", function(e) return e.mb and GM.Money(e.mb) end },
	{ "mbx", "Min excl. mine", function(e)
		return e.mbx and e.mbx ~= math.huge
			and GM.Money(e.mbx) or "—" end },
	{ "mkt", "Market value", function(e)
		return e.p and GM.Money(e.p)
			or e.mkt and GM.Money(e.mkt) end },
	{ "sup", "Supply", function(e) return e.sup end },
	{ "lots", "Lots", function(e) return e.n end },
	{ "vel", "Sales/day", function(e) return e.vel and
		(GM.VelRate and GM.VelRate(e.vel) or e.vel) .. "/d" end },
	{ "hist", "Historic", function(e) return e.hist and GM.Money(e.hist) end },
	{ "recent", "Recent", function(e) return e.recent and GM.Money(e.recent) end },
	{ "rmkt", "Region market", function(e) return e.rmkt and GM.Money(e.rmkt) end },
	{ "src", "Source", function(e) return e._src or "emit" end },
}
local function RefreshNumbers()
	local entry = M.itemID and GM.ItemEntry(M.itemID)
	for i, f in ipairs(NUM_FIELDS) do
		local r = mp.numRows[i]
		r.val:SetText(entry and tostring(f[3](entry) or "—") or "—")
	end
	if entry then
		local bAge = GM.AH.BookAge and GM.AH.BookAge()
		mp.numFoot:SetText(bAge and bAge < math.huge
			and ("book " .. (bAge >= 60 and format("%dm", bAge / 60)
				or format("%ds", bAge)) .. " old")
			or "no book")
	else
		mp.numFoot:SetText("")
	end
end

-- the page's AUTO cadence is item-scoped: while lit and the page is
-- showing, the ask ladder re-scans once it goes stale. The book-wide
-- cadence stays on /goblin autoscan — it feeds sniper/mesh/book
-- marks, not this page
local function AutoItemOn()
	return GM.db and GM.db.mktAutoscan and true or false
end

local function PaintAuto()
	if not mp then return end
	mp.autoBtn:SetSelected(AutoItemOn())
end

-- enable = scan NOW, don't wait out the first minute — the visible
-- "scanning… → ladder" cycle is the feedback that the toggle works
local function ToggleAuto()
	if not GM.db then return end
	GM.db.mktAutoscan = not GM.db.mktAutoscan or nil
	PaintAuto()
	if GM.db.mktAutoscan and M.itemID then
		M.asks = nil
		ScanAsks()
	end
end

local autoAcc = 0
local autoF = CreateFrame("Frame")
autoF:SetScript("OnUpdate", function(_, dt)
	if not AutoItemOn() or not (mp and mp:IsShown())
		or not (M.itemID and GM.AH.open) then
		autoAcc = 0
		return
	end
	autoAcc = autoAcc + dt
	if autoAcc < 10 then return end -- 10s check cadence, cheap
	autoAcc = 0
	if (not M.asks or (M.askT and GetTime() - M.askT > 60))
		and not M.askWait then
		ScanAsks()
	else
		MU.Refresh() -- tick the visible ask age between rescans
	end
end)

local function RefreshIntel()
	local lines = {}
	local id = M.itemID
	local marks = id and GM.Intel and GM.Intel.marks[id]
	-- marks are book-derived — a stale book can't claim a bait lot
	-- is "live" (a dead drag stays flagged long after it's bought)
	local live = GM.AH.BookLive and GM.AH.BookLive()
	if marks and not live then
		tinsert(lines, GM.CC("textDim")
			.. "book stale — marks may be outdated|r")
	end
	if live and marks and marks.bait then
		tinsert(lines, GM.CC("err") .. "bait lot live — cheapest ask is a drag|r")
	end
	if live and marks and marks.steps and marks.steps > 0 then
		tinsert(lines, GM.CC("warn") .. format("%d step-chain asks — "
			.. "algorithmic repricing|r", marks.steps))
	end
	if live and marks and marks.walls then
		for s, n in pairs(marks.walls) do
			local sc = GM.Intel.Score(s)
			local wh = marks.wallHist and marks.wallHist[s]
			local tag = ""
			if wh then
				tag = format(" · %d obs", wh.scans or 1)
				if wh.replenished then tag = tag .. " · repost" end
			end
			tinsert(lines, GM.CC("warn") .. format(
				"wall — %s ×%d%s%s|r", s, n, tag,
				sc >= 4 and (" · suspect " .. sc) or ""))
		end
	end
	-- suspects selling this item right now (from the live asks)
	local seen = {}
	for _, a in ipairs(M.asks or {}) do
		if a.solver and a.seller and not seen[a.seller] then
			seen[a.seller] = true
			tinsert(lines, GM.CC("err") .. format("⚠ %s — suspect score %d|r",
				a.seller, GM.Intel.Score(a.seller)))
		end
	end
	if #lines == 0 then
		lines[1] = GM.CC("textDim") .. (id and "no manipulation signals"
			or "—") .. "|r"
	end
	-- one pooled Text node per signal — the same row pattern the
	-- numbers pane runs; a single wrapped fontstring's lines were
	-- colliding inside the scroll content
	local pool = mp.intelLines
	for i = 1, math.max(#pool, #lines) do
		if not pool[i] then
			pool[i] = GM.ui:Text(mp.intelScroll,
				{ style = "cell", spacing = 3 })
			mp.intelScroll.content:Add(pool[i], { height = "auto" })
		end
		local t = pool[i]
		if lines[i] then
			t:SetText(lines[i])
			t:SetVisible(true)
		else
			t:SetVisible(false)
		end
	end
	PaintAuto()
end

local function StepLabel(s)
	if not s then return "" end
	local nm = s.name or (s.itemID and GM.ItemName(s.itemID)) or "?"
	local tail = (s.qty and s.qty > 0 and (" ×" .. s.qty) or "")
		.. (s.unit and (" @" .. GM.Money(s.unit)) or "")
	return (s.verb or s.kind or "?") .. " " .. nm .. tail
		.. (s.desc and GM.CC("textDim") .. " — " .. s.desc .. "|r" or "")
end

local function RefreshPlan()
	local plan = GM.PlanQueue.plan
	local steps = plan and plan.steps
	local total = steps and #steps or 0
	local idx = plan and GM.PlanQueue.stepIndex or 0
	local armed = steps and idx <= total and steps[idx]
	local showBtns = false
	if plan and plan.mode and plan.mode ~= "postscan"
		and plan.mode ~= "cancelscan" and plan.mode ~= "shopscan" then
		mp.planPanel:SetTitle("Plan — " .. plan.mode)
		mp.pArmed:SetText(GM.CC("textDim")
			.. "runs in the standalone plan window|r")
		mp.pNext:SetText("")
	elseif not plan or total == 0 or not armed then
		mp.planPanel:SetTitle("Plan")
		mp.pArmed:SetText(GM.CC("textDim") ..
			"no plan — POST/CANCEL/SHOP scans and targeted items route here|r")
		mp.pNext:SetText("")
	else
		showBtns = true
		mp.planPanel:SetTitle(format("Plan — Step %d/%d%s", idx, total,
			plan.mode and (" · " .. plan.mode) or ""))
		mp.pArmed:SetText(GM.CC("accent") .. "▶ " .. StepLabel(armed) .. "|r")
		mp.pNext:SetText(idx + 1 <= total and GM.CC("textDim")
			.. "  " .. StepLabel(steps[idx + 1])
			.. (idx + 2 <= total
				and format("  …+%d more", total - idx - 1) or "")
			.. "|r" or "")
		mp.exec:SetText(GM.AH.pendingConfirm and "Confirm"
			or GM.PlanQueue.lossConfirm and "Confirm" or "Execute")
		mp.prog:SetValue(total > 0 and (idx - 1) / total or 0)
	end
	mp.exec:SetVisible(showBtns)
	mp.skip:SetVisible(showBtns)
	mp.rescan:SetVisible(showBtns)
	mp.prog:SetVisible(showBtns)
end

function MU.Refresh()
	if not (mp and mp:IsShown()) then return end
	-- planner retargets follow into the page too (plan window /
	-- /goblin [link] / scan-plan step items) — one direction check,
	-- no loop: SetItem only re-syncs PQ when the ids differ
	local tid = GM.PlanQueue.itemID
	if tid and tid ~= M.itemID then
		MU.SetItem(tid, GM.PlanQueue.item, GM.PlanQueue.itemKey)
		return
	end
	-- asks older than a minute while the page is live deserve a
	-- quiet refresh — the ladder is only useful while it's true
	if M.itemID and M.asks and M.askT
		and GetTime() - M.askT > 60 and not M.askWait then
		M.asks = nil
		ScanAsks()
	end
	-- recovery: a latched askWait whose retry died (AH closed mid-
	-- wait, retarget race) leaves both panes stuck — re-kick when
	-- nothing is actually scanning anymore
	if M.itemID and not M.asks and GM.AH.open
		and not (M.askWait and GM.AH.Busy and GM.AH.Busy()) then
		M.askWait = nil
		ScanAsks()
	end
	FreeArt()
	RefreshHeader()
	DrawPrice()
	DrawDepth()
	RefreshAskBook()
	RefreshNumbers()
	RefreshIntel()
	RefreshPlan()
end

-- ============ build ============

function MU.Build(f, ahui)
	if mp then return mp end
	ui = ahui
	mp = CreateFrame("Frame", nil, f)
	-- no self-anchoring: AHUI adopts mp into the page-fill slot and
	-- the layout owns its bounds
	mp:Hide()

	local u = GM.ui
	local L = GM.L

	-- the whole page is one Column: header / price / mid / bottom.
	-- sibling slots can't overlap — gutters are tokens, not pixels
	local root = u:AttachRoot(mp, { direction = "column", gap = "sm" })

	-- ===== header =====
	local header = u:Row(root, { gap = "sm" })
	root:Add(header, { height = 40 })

	-- item icon — square leaf sized to the name+chips text pair
	-- (value line 20 + cellDim line 14 + hair gap)
	local iconN = u:Leaf(header, { measure = function() return 36, 36 end })
	mp.icon = iconN.frame:CreateTexture(nil, "ARTWORK")
	mp.icon:SetAllPoints()
	header:Add(iconN, { width = 36, height = 36, align = "center" })

	-- name + chips column (fill)
	local nc = u:Column(header, { gap = "hair" })
	header:Add(nc, { width = "fill" })
	mp.name = u:Text(nc, { style = "value", wrap = false })
	nc:Add(mp.name)
	mp.chips = u:Text(nc, { style = "cellDim", wrap = false })
	nc:Add(mp.chips)

	-- AUTO toggle — item-scoped ask cadence, lit when on
	mp.autoBtn = u:Button(header, {
		text = L("Auto"),
		variant = "quiet",
		height = 26,
		tooltip = "re-scan this item's asks about once a minute",
		onClick = function() ToggleAuto() end,
	})
	header:Add(mp.autoBtn, { width = "auto", align = "center" })

	-- item slot — a host widget wrapped as a leaf; its internals
	-- stay host-side during the sweep (spec §4.1 host widgets)
	mp.slot = W.ItemSlot(mp, {
		icon = 18, w = 300, h = 26, nameSize = 10, subSize = 8,
		hint = "target — drop · shift-click · [link]",
		onItem = function(id, link) MU.SetItem(id, link) end,
	})
	local slotN = u:Leaf(header, {
		frame = mp.slot,
		measure = function() return 300, 26 end,
	})
	header:Add(slotN, { width = 300, align = "center" })

	-- ===== price pane =====
	mp.pricePanel = u:Panel(root, { title = L("Price"), slim = true, pad = "xs" })
	root:Add(mp.pricePanel, { height = 96 })
	local pc = u:Canvas(mp.pricePanel, {
		onResize = function()
			if mp:IsShown() then MU.Refresh() end
		end,
	})
	mp.pricePanel.body:Add(pc, { width = "fill", height = "fill" })
	mp.priceContent = pc.content
	mp.priceContent.msg = GM.MakeFontString(pc.content, GM.FONT, 10, "textDim")
	mp.priceContent.msg:SetPoint("CENTER", 0, 0)

	-- ===== middle row: depth | ask book =====
	local mid = u:Row(root, { gap = "sm" })
	root:Add(mid, { height = 118 })

	mp.depthPanel = u:Panel(mid, { title = L("Depth"), slim = true, pad = "xs" })
	mid:Add(mp.depthPanel, { width = 366, height = "fill" })
	local dc = u:Canvas(mp.depthPanel, {
		onResize = function()
			if mp:IsShown() then MU.Refresh() end
		end,
	})
	mp.depthPanel.body:Add(dc, { width = "fill", height = "fill" })
	mp.depthContent = dc.content
	mp.depthContent.msg = GM.MakeFontString(dc.content, GM.FONT, 10, "textDim")
	mp.depthContent.msg:SetPoint("CENTER", 0, 0)

	-- ask book: a real List — pooled rows, scroll owned by the lib
	mp.askPanel = u:Panel(mid, { title = L("Ask Book"), slim = true, pad = "xs" })
	mid:Add(mp.askPanel, { width = "fill", height = "fill" })
	mp.askList = u:List(mp.askPanel, {
		rowHeight = ASK_ROW_H,
		makeRow = function(row)
			local rf = row.frame
			-- bindRow reads row.* off the wrapper table, not the
			-- frame — keep cell handles on `row` itself
			row.bg = rf:CreateTexture(nil, "BACKGROUND")
			row.bg:SetAllPoints()
			row.c1 = GM.MakeFontString(rf, GM.FONT, 10, "text")
			row.c1:SetPoint("LEFT", 6, 0) row.c1:SetWidth(62)
			row.c1:SetJustifyH("LEFT") row.c1:SetWordWrap(false)
			row.c2 = GM.MakeFontString(rf, GM.FONT, 10, "accent")
			row.c2:SetPoint("LEFT", 72, 0) row.c2:SetWidth(34)
			row.c2:SetJustifyH("LEFT") row.c2:SetWordWrap(false)
			row.c3 = GM.MakeFontString(rf, GM.FONT, 10, "text")
			row.c3:SetPoint("LEFT", 108, 0) row.c3:SetWidth(190)
			row.c3:SetJustifyH("LEFT") row.c3:SetWordWrap(false)
			row.c4 = GM.MakeFontString(rf, GM.FONT, 9, "textDim")
			row.c4:SetPoint("LEFT", 300, 0) row.c4:SetWidth(46)
			row.c4:SetJustifyH("LEFT") row.c4:SetWordWrap(false)
			local act = CreateFrame("Button", nil, rf)
			act:SetSize(44, 14)
			act:SetPoint("RIGHT", -2, 0)
			GM.Panel(act, "contHigh")
			act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
			act.text:SetPoint("CENTER")
			row.act = act
			GM.ui:HoverTint(rf, { a = 0.07 })
		end,
		bindRow = function(row, a, idx) BindAskRow(row, a, idx) end,
		keyFn = function(a) return a.id or (a.unit * 1000 + a.qty) end,
	})
	mp.askPanel.body:Add(mp.askList, { width = "fill", height = "fill" })
	mp.abEmpty = GM.MakeFontString(mp.askPanel.frame, GM.FONT, 10, "textDim")
	mp.abEmpty:SetPoint("CENTER", 0, -8)

	-- ===== bottom row: plan | numbers | intel =====
	local bot = u:Row(root, { gap = "sm" })
	root:Add(bot, { height = "fill" })

	mp.planPanel = u:Panel(bot, { title = L("Plan"), slim = true,
		pad = "xs", gap = "xs" })
	bot:Add(mp.planPanel, { width = 366, height = "fill" })
	-- armed step + action buttons share one 24px row — stacking
	-- them vertically pushed the buttons past the pane's bottom
	local pTop = u:Row(mp.planPanel, { gap = "xs" })
	mp.planPanel.body:Add(pTop, { height = 24 })
	mp.pArmed = u:Text(pTop, { style = "cell", wrap = false })
	pTop:Add(mp.pArmed, { width = "fill", align = "center" })
	mp.rescan = u:Button(pTop, {
		text = L("Rescan"), variant = "ghost", height = 24,
		onClick = function() GM.PlanQueue.Rescan() end,
	})
	pTop:Add(mp.rescan, { width = "auto", align = "center" })
	mp.skip = u:Button(pTop, {
		text = L("Skip"), variant = "ghost", height = 24,
		onClick = function() GM.PlanQueue.SkipStep() end,
	})
	pTop:Add(mp.skip, { width = "auto", align = "center" })
	mp.exec = u:Button(pTop, {
		text = L("Execute"), variant = "accent", height = 24,
		onClick = function() GM.PlanQueue.ExecuteNext() end,
	})
	pTop:Add(mp.exec, { width = "auto", align = "center" })
	-- next/more folds into one line — three stacked hint rows was
	-- what overflowed the pane
	mp.pNext = u:Text(mp.planPanel, { style = "cellDim", wrap = false })
	mp.planPanel.body:Add(mp.pNext)
	mp.prog = u:Progress(mp.planPanel, { height = 3 })
	mp.planPanel.body:Add(mp.prog, { width = "fill", height = "auto" })

	-- numbers: ten fields scroll inside the pane — the body column
	-- holds a Scroll whose content lists label/value rows
	mp.numPanel = u:Panel(bot, { title = L("Numbers"), slim = true, pad = "xs" })
	bot:Add(mp.numPanel, { width = 197, height = "fill" })
	local nsc = u:Scroll(mp.numPanel, { gap = "none" })
	mp.numPanel.body:Add(nsc, { width = "fill", height = "fill" })
	mp.numRows = {}
	for i, fdef in ipairs(NUM_FIELDS) do
		local r = u:Row(nsc, { gap = "xs" })
		nsc.content:Add(r, { height = "auto" })
		r.lab = u:Text(r, { style = "cellDim", wrap = false })
		r.lab:SetText(fdef[2])
		r:Add(r.lab, { width = "fill" })
		r.val = u:Text(r, { style = "cell", wrap = false, align = "RIGHT" })
		r:Add(r.val, { width = "auto" })
		mp.numRows[i] = r
	end
	mp.numFoot = u:Text(nsc, { style = "cellDim", wrap = false })
	nsc.content:Add(mp.numFoot)

	-- intel: wrapped text in a Scroll — signals stack past the pane
	mp.intelPanel = u:Panel(bot, { title = L("Intel"), slim = true, pad = "xs" })
	bot:Add(mp.intelPanel, { width = "fill", height = "fill" })
	local isc = u:Scroll(mp.intelPanel, { gap = "none" })
	mp.intelPanel.body:Add(isc, { width = "fill", height = "fill" })
	mp.intelScroll = isc
	mp.intelLines = {} -- pooled per-signal Text nodes (RefreshIntel)

	PaintAuto()
	return mp
end

-- ============ routing API ============

-- open the market page on an item (or as-is); used by PQ.Show's
-- routing and GM.TargetItem when the AH window is up
function GM.AHUI.OpenMarket(id, link, key)
	AU.Show() -- ensures Build + frame shown
	if ui and ui.page ~= "market" then
		ui.page = "market"
		ui.scroll = 0
		ui.bidScroll = 0
	end
	if id then MU.SetItem(id, link, key) end
	AU.Refresh()
end

-- market-page live refresh when the shared book/intel changes
GM.AH.bookSubs[#GM.AH.bookSubs + 1] = function()
	if mp and mp:IsShown() then MU.Refresh() end
end

-- plan state changes paint the market plan pane too (same pattern
-- AHUI uses for ScanStatus — wrap, don't edit, the engine file)
local pqRefresh = GM.PlanQueue.Refresh
function GM.PlanQueue.Refresh(...)
	pqRefresh(...)
	if MU.Refresh then MU.Refresh() end
end
