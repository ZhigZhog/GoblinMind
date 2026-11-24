local _, GM = ...

-- ================================================================
-- MarketUI.lua — MARKET page inside the AH session window. The
-- item drill-down terminal: price series + supply bars, market
-- depth, full ask book with intel flags, the numbers dump, and the
-- merged planner (PQ engine). AH-context plans route here from
-- PQ.Show; the standalone plan window keeps everything else.
-- ================================================================

local AU = GM.AHUI
local MU = {}
GM.MarketUI = MU

local W = GM.Widgets
local Btn = W.Btn
local Tip = W.Tip
local tinsert, sort = tinsert, table.sort
local floor = math.floor
local format = format
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

local ui, mp -- AHUI's ui table + our page container (set by Build)
local M = {} -- market state: itemID, link, asks, askT, askScroll
MU.M = M

local ROW_H = 24
local ASK_VIS = 5

-- ============ art pool (same primitives as the plan window) ============

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
		M.askScroll = 0
		-- targeted scans feed the same marks + suspect table as the
		-- book pass — intel accumulates without waiting on full scans
		if GM.Intel and GM.Intel.AnalyzeItem then
			GM.Intel.AnalyzeItem(id, M.asks, time())
		end
		-- …and freshen the item's book row: mb/sup/n derive from the
		-- ladder the same way CollectBook derives them, so a page-
		-- scoped autoscan keeps the chips + NUMBERS live too
		if asks[1] then
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
	local changed = M.itemID ~= id
	M.itemID, M.itemLink, M.itemKey = id, link, key
	if changed then
		M.asks, M.askT, M.askTries, M.askWait = nil, nil, nil, nil
		ScanAsks()
	end
	-- the planner target follows the market slot — a change to one
	-- is a change to the other
	if GM.PlanQueue.itemID ~= id then
		GM.PlanQueue.SetItem(id, link)
	end
	if MU.Refresh then MU.Refresh() end
end

-- ============ price chart ============

local WEEK = 7 * 86400
local function DrawPrice(entry)
	local ch = mp.price
	ch.msg:SetText("")
	ch.tipLines = nil
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
	ch.title:SetText(seriesMode and "PRICE · SUPPLY — 7D"
		or "PRICE REFERENCES")
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
	if hi == lo then hi = lo + 1 end
	local pad = (hi - lo) * 0.08
	lo = lo - pad hi = hi + pad
	local padX, gutter = 8, 60
	local cw = ch:GetWidth() - padX - gutter
	local top, base = ch:GetHeight() - 14, 22
	local volTop = 18 -- supply bars live under the line
	local function px(x) return padX + x * cw end
	local function py(v) return base + (v - lo) / (hi - lo) * (top - base) end
	-- mkt / mb horizontals (under the candles)
	if entry and entry.p and entry.p >= lo and entry.p <= hi then
		local y = py(entry.p)
		Bar(ch, padX, y, cw, 1, "secondary", 0.6)
		Label(ch, ch:GetWidth() - 4, y + 2, "mkt", "secondary", 8, "RIGHT")
	end
	if entry and entry.mb and entry.mb >= lo and entry.mb <= hi then
		local y = py(entry.mb)
		Bar(ch, padX, y, cw, 1, "warn", 0.5)
		Label(ch, ch:GetWidth() - 4, y + 2, "mb", "warn", 8, "RIGHT")
	end
	if seriesMode then
		-- OHLC candles — the real tape: each time bucket's open/close
		-- are its first/last samples, the wick carries the bucket's
		-- extremes; body green when the period closed up, red down
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
			Bar(ch, cx - 0.5, py(c.l), 1,
				math.max(1, py(c.h) - py(c.l)), key, 0.7, "ARTWORK")
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
		Label(ch, ch:GetWidth() - 4, py(cs[lastB].c) - 5,
			GM.Money(cs[lastB].c), "text", 10, "RIGHT")
	else
		for i = 2, #pts do
			Segment(ch, px(pts[i - 1].x), py(pts[i - 1].v),
				px(pts[i].x), py(pts[i].v))
		end
		local last = pts[#pts]
		Dot(ch, px(last.x), py(last.v), 5, "accent")
		Label(ch, ch:GetWidth() - 4, py(last.v) - 5, GM.Money(last.v),
			"text", 10, "RIGHT")
	end
	Label(ch, ch:GetWidth() - 4, top + 1, GM.Money(hi), "textDim", 9, "RIGHT")
	Label(ch, ch:GetWidth() - 4, base + 2, GM.Money(lo), "textDim", 9, "RIGHT")
	if seriesMode then
		Label(ch, padX, 4, window >= WEEK and "7d ago"
			or GM.FmtAge(window) .. " ago", "textDim", 8, "LEFT")
		Label(ch, padX + cw, 4, "now", "textDim", 8, "RIGHT")
	end
end

-- ============ depth chart ============

local function DrawDepth()
	local ch = mp.depth
	ch.msg:SetText("")
	local asks = M.asks
	if not (asks and #asks > 0) then
		ch.title:SetText("DEPTH")
		ch.msg:SetText(M.itemID and (M.askWait and BusyText()
			or M.asks and "no asks listed" or "scanning asks…")
			or "no item targeted")
		return
	end
	ch.title:SetText("DEPTH — cumulative")
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
	mp.name:SetTextColor(GM.NameColor(id))
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

local function RefreshAskBook()
	local asks = M.asks or {}
	-- rows arrive flagged by AnalyzeItem at scan time; suspect state
	-- can shift between scans (a book scan lands mid-session) — the
	-- solver flag alone is cheap to keep current on each repaint
	for _, a in ipairs(asks) do
		a.solver = a.seller and GM.Intel
			and GM.Intel.IsSuspect(a.seller) or nil
	end
	mp.abHead:SetText("ASK BOOK")
	local maxScroll = math.max(0, #asks - ASK_VIS)
	M.askScroll = math.min(M.askScroll or 0, maxScroll)
	W.ScrollText(mp.abCount, M.askScroll, ASK_VIS, #asks)
	mp.abEmpty:SetText(M.itemID and (M.askWait and BusyText()
		or (not M.asks and "scanning…") or "no asks")
		or "")
	mp.abEmpty:SetShown(#asks == 0)
	for i = 1, ASK_VIS do
		local row, a = mp.askRows[i], asks[i + (M.askScroll or 0)]
		if a then
			row:Show()
			row.c1:SetText((a.bait and GM.CC("err") or a.wall and GM.CC("warn")
				or GM.CC("text")) .. GM.Money(a.unit) .. "|r")
			row.c2:SetText("×" .. a.qty)
			local flags = {}
			if a.own then tinsert(flags, GM.CC("accent") .. "MINE|r") end
			if a.wall then tinsert(flags, GM.CC("warn") .. "WALL|r") end
			if a.bait then tinsert(flags, GM.CC("err") .. "BAIT|r") end
			if a.step then tinsert(flags, GM.CC("warn") .. "STEP|r") end
			if a.solver then tinsert(flags, GM.CC("err") .. "⚠|r") end
			-- no seller name (commodity API returns none) — the
			-- owner count is the honest fallback display
			local seller = a.seller
				or (a.nOwners and a.nOwners > 0
					and (a.nOwners .. (a.nOwners == 1 and " seller" or " sellers")))
				or "?"
			row.c3:SetText(seller .. (#flags > 0 and "  " .. table.concat(flags, " ") or ""))
			row.c4:SetText(a.tl and GM.FmtAge(a.tl) or "")
			row.a = a
			if a.own then row.act:Hide()
			else
				row.act:Show()
				row.act.text:SetText("BUY")
				row.act:SetScript("OnClick", function()
					local x = a
					if x.id then
						GM.AH.Execute({ kind = "buy", itemID = M.itemID,
							auctionID = x.id, qty = x.qty, unit = x.unit,
							total = x.total })
					else
						GM.AH.Execute({ kind = "buy", commodity = true,
							itemID = M.itemID, qty = x.qty, unit = x.unit })
					end
					MU.Refresh()
				end)
			end
		else
			row:Hide()
		end
	end
end

local NUM_FIELDS = {
	{ "mb", function(e) return e.mb and GM.Money(e.mb) end },
	{ "mbx", function(e) return e.mbx and e.mbx ~= math.huge
		and GM.Money(e.mbx) or "—" end },
	{ "mkt", function(e) return e.p and GM.Money(e.p)
		or e.mkt and GM.Money(e.mkt) end },
	{ "sup", function(e) return e.sup end },
	{ "lots", function(e) return e.n end },
	{ "vel", function(e) return e.vel and
		(GM.VelRate and GM.VelRate(e.vel) or e.vel) .. "/d" end },
	{ "hist", function(e) return e.hist and GM.Money(e.hist) end },
	{ "recent", function(e) return e.recent and GM.Money(e.recent) end },
	{ "rmkt", function(e) return e.rmkt and GM.Money(e.rmkt) end },
	{ "src", function(e) return e._src or "emit" end },
}
local function RefreshNumbers()
	local entry = M.itemID and GM.ItemEntry(M.itemID)
	for i, f in ipairs(NUM_FIELDS) do
		local r = mp.numRows[i]
		local lab, val = r[1], r[2]
		lab:SetText(f[1])
		local v = entry and f[2](entry)
		val:SetText(v ~= nil and tostring(v) or "—")
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
	local key = AutoItemOn() and "pos" or "textDim"
	-- GM.RGB is a triple return — pass it straight through so all
	-- three channels reach SetTextColor (a captured var keeps r only)
	if mp.autoBtn then mp.autoBtn.text:SetTextColor(GM.RGB(key)) end
	if mp.auto then mp.auto.t:SetTextColor(GM.RGB(key)) end
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
	end
end)

local function RefreshIntel()
	local lines = {}
	local id = M.itemID
	local marks = id and GM.Intel and GM.Intel.marks[id]
	if marks and marks.bait then
		tinsert(lines, GM.CC("err") .. "bait lot live — cheapest ask is a drag|r")
	end
	if marks and marks.steps and marks.steps > 0 then
		tinsert(lines, GM.CC("warn") .. format("%d step-chain asks — "
			.. "algorithmic repricing|r", marks.steps))
	end
	if marks and marks.walls then
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
	for i = 1, 6 do
		mp.intelRows[i]:SetText(lines[i] or "")
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
	if plan and plan.mode and plan.mode ~= "postscan"
		and plan.mode ~= "cancelscan" and plan.mode ~= "shopscan" then
		mp.pHead:SetText("PLAN — " .. plan.mode)
		mp.pArmed:SetText(GM.CC("textDim")
			.. "runs in the standalone plan window|r")
		mp.pNext:SetText("")
		mp.pMore:SetText("")
		mp.exec:Hide() mp.skip:Hide() mp.rescan:Hide()
		mp.prog:Hide()
		return
	end
	if not plan or total == 0 or not armed then
		mp.pHead:SetText("PLAN")
		mp.pArmed:SetText(GM.CC("textDim") ..
			"no plan — POST/CANCEL/SHOP scans and targeted items route here|r")
		mp.pNext:SetText("")
		mp.pMore:SetText("")
		mp.exec:Hide() mp.skip:Hide() mp.rescan:Hide()
		mp.prog:Hide()
		return
	end
	mp.pHead:SetText(format("PLAN — step %d/%d%s", idx, total,
		plan.mode and (" · " .. plan.mode) or ""))
	mp.pArmed:SetText(GM.CC("accent") .. "▶ " .. StepLabel(armed) .. "|r")
	mp.pNext:SetText(idx + 1 <= total and GM.CC("textDim")
		.. "  " .. StepLabel(steps[idx + 1]) .. "|r" or "")
	mp.pMore:SetText(idx + 2 <= total and GM.CC("textDim")
		.. format("  …+%d more", total - idx - 1) .. "|r" or "")
	mp.exec:Show()
	mp.exec.text:SetText(GM.AH.pendingConfirm and "CONFIRM"
		or GM.PlanQueue.lossConfirm and "CONFIRM" or "EXECUTE")
	mp.skip:Show() mp.rescan:Show()
	mp.prog:Show()
	local w = (mp.pPane:GetWidth() - 16) * (idx - 1) / math.max(1, total)
	mp.prog:SetWidth(math.max(2, w))
end

function MU.Refresh()
	if not (mp and mp:IsShown()) then return end
	-- planner retargets follow into the page too (plan window /
	-- /goblin [link] / scan-plan step items) — one direction check,
	-- no loop: SetItem only re-syncs PQ when the ids differ
	local tid = GM.PlanQueue.itemID
	if tid and tid ~= M.itemID then
		MU.SetItem(tid, GM.PlanQueue.item)
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

-- forward refs for Build — locals the click handlers close over
function MU.Build(f, ahui)
	if mp then return mp end
	ui = ahui
	mp = CreateFrame("Frame", nil, f)
	mp:SetPoint("TOPLEFT", 12, -62)
	mp:SetSize(776, 366)
	mp:Hide()

	-- ===== header (bare, not a pane) =====
	mp.icon = mp:CreateTexture(nil, "ARTWORK")
	mp.icon:SetSize(18, 18)
	mp.icon:SetPoint("TOPLEFT", 8, -2)
	mp.name = GM.MakeFontString(mp, GM.FONT_BOLD, 13, "text")
	mp.name:SetPoint("TOPLEFT", 32, -2)
	mp.name:SetWidth(280)
	mp.name:SetJustifyH("LEFT")
	mp.name:SetWordWrap(false)
	mp.chips = GM.MakeFontString(mp, GM.FONT, 10, "text")
	mp.chips:SetPoint("TOPLEFT", 32, -19)
	mp.chips:SetWidth(368)
	mp.chips:SetJustifyH("LEFT")
	mp.chips:SetWordWrap(false)
	mp.slot = W.ItemSlot(mp, {
		icon = 18, w = 300, h = 26, nameSize = 10, subSize = 8,
		hint = "target — drop · shift-click · [link]",
		onItem = function(id, link) MU.SetItem(id, link) end,
	})
	mp.slot:SetPoint("TOPRIGHT", -8, -2)
	-- AUTO: item-scoped ask refresh for this page — same preference
	-- as the intel-pane tag; text goes green when lit
	mp.autoBtn = Btn(mp, 56, "AUTO", function()
		if GM.db then
			GM.db.mktAutoscan = not GM.db.mktAutoscan or nil
			PaintAuto()
		end
	end)
	mp.autoBtn:SetPoint("TOPRIGHT", mp.slot, "TOPLEFT", -6, -3)
	mp.autoBtn:SetScript("OnLeave", function()
		if mp.autoBtn._gmBg then
			mp.autoBtn._gmBg:SetColorTexture(GM.RGB("contHigh"))
		end
		PaintAuto()
	end)

	-- ===== PRICE pane =====
	local ch = CreateFrame("Frame", nil, mp)
	ch:SetSize(776, 100)
	ch:SetPoint("TOPLEFT", 0, -34)
	GM.Panel(ch, "contLowest")
	ch.title = GM.MakeFontString(ch, GM.FONT_BOLD, 10, "secondary")
	ch.title:SetPoint("TOPLEFT", 8, -4)
	ch.title:SetText("PRICE")
	ch.msg = GM.MakeFontString(ch, GM.FONT, 9, "textDim")
	ch.msg:SetPoint("CENTER", 0, -4)
	if ch.SetClipsChildren then ch:SetClipsChildren(true) end
	mp.price = ch

	-- ===== DEPTH pane =====
	local dp = CreateFrame("Frame", nil, mp)
	dp:SetSize(366, 144)
	dp:SetPoint("TOPLEFT", 0, -140)
	GM.Panel(dp, "contLowest")
	dp.title = GM.MakeFontString(dp, GM.FONT_BOLD, 10, "secondary")
	dp.title:SetPoint("TOPLEFT", 8, -4)
	dp.title:SetText("DEPTH")
	dp.msg = GM.MakeFontString(dp, GM.FONT, 9, "textDim")
	dp.msg:SetPoint("CENTER", 0, -4)
	if dp.SetClipsChildren then dp:SetClipsChildren(true) end
	mp.depth = dp

	-- ===== ASK BOOK pane =====
	local ab = CreateFrame("Frame", nil, mp)
	ab:SetSize(402, 144)
	ab:SetPoint("TOPLEFT", 374, -140)
	GM.Panel(ab, "contLowest")
	mp.abHead = GM.MakeFontString(ab, GM.FONT_BOLD, 10, "secondary")
	mp.abHead:SetPoint("TOPLEFT", 8, -5)
	mp.abHead:SetText("ASK BOOK")
	mp.abCount = GM.MakeFontString(ab, GM.FONT, 10, "textDim")
	mp.abCount:SetPoint("TOPRIGHT", -8, -6)
	ab:EnableMouseWheel(true)
	ab:SetScript("OnMouseWheel", function(_, d)
		M.askScroll = math.max(0, (M.askScroll or 0) - d * 2)
		MU.Refresh()
	end)
	mp.askRows = {}
	for i = 1, ASK_VIS do
		local row = CreateFrame("Button", nil, ab)
		row:SetSize(378, ROW_H - 2)
		row:SetPoint("TOPLEFT", 8, -22 - (i - 1) * ROW_H)
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.c1 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c1:SetPoint("LEFT", 6, 0) row.c1:SetWidth(66)
		row.c1:SetJustifyH("LEFT") row.c1:SetWordWrap(false)
		row.c2 = GM.MakeFontString(row, GM.FONT, 10, "accent")
		row.c2:SetPoint("LEFT", 76, 0) row.c2:SetWidth(34)
		row.c2:SetJustifyH("LEFT") row.c2:SetWordWrap(false)
		row.c3 = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.c3:SetPoint("LEFT", 112, 0) row.c3:SetWidth(196)
		row.c3:SetJustifyH("LEFT") row.c3:SetWordWrap(false)
		row.c4 = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.c4:SetPoint("LEFT", 310, 0) row.c4:SetWidth(46)
		row.c4:SetJustifyH("LEFT") row.c4:SetWordWrap(false)
		local act = CreateFrame("Button", nil, row)
		act:SetSize(44, 16)
		act:SetPoint("RIGHT", -2, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		row.act = act
		mp.askRows[i] = row
	end
	mp.abEmpty = GM.MakeFontString(ab, GM.FONT, 10, "textDim")
	mp.abEmpty:SetPoint("CENTER", 0, -8)

	-- ===== PLAN pane =====
	local pp = CreateFrame("Frame", nil, mp)
	pp:SetSize(366, 96)
	pp:SetPoint("TOPLEFT", 0, -290)
	GM.Panel(pp, "contLowest")
	mp.pPane = pp
	mp.pHead = GM.MakeFontString(pp, GM.FONT_BOLD, 10, "secondary")
	mp.pHead:SetPoint("TOPLEFT", 8, -5)
	mp.pHead:SetText("PLAN")
	mp.exec = Btn(pp, 70, "EXECUTE", function() GM.PlanQueue.ExecuteNext() end)
	mp.exec:SetPoint("TOPRIGHT", -6, -4)
	mp.exec.text:SetTextColor(GM.RGB("accent"))
	mp.skip = Btn(pp, 40, "SKIP", function() GM.PlanQueue.SkipStep() end)
	mp.skip:SetPoint("TOPRIGHT", mp.exec, "TOPLEFT", -4, 0)
	mp.rescan = Btn(pp, 52, "RESCAN", function() GM.PlanQueue.Rescan() end)
	mp.rescan:SetPoint("TOPRIGHT", mp.skip, "TOPLEFT", -4, 0)
	mp.pArmed = GM.MakeFontString(pp, GM.FONT, 10, "text")
	mp.pArmed:SetPoint("TOPLEFT", 8, -24)
	mp.pArmed:SetWidth(348)
	mp.pArmed:SetJustifyH("LEFT") mp.pArmed:SetWordWrap(false)
	mp.pNext = GM.MakeFontString(pp, GM.FONT, 10, "textDim")
	mp.pNext:SetPoint("TOPLEFT", 8, -42)
	mp.pNext:SetWidth(348)
	mp.pNext:SetJustifyH("LEFT") mp.pNext:SetWordWrap(false)
	mp.pMore = GM.MakeFontString(pp, GM.FONT, 10, "textDim")
	mp.pMore:SetPoint("TOPLEFT", 8, -58)
	mp.pMore:SetJustifyH("LEFT")
	mp.prog = pp:CreateTexture(nil, "ARTWORK")
	mp.prog:SetColorTexture(GM.RGB("accent"))
	mp.prog:SetHeight(3)
	mp.prog:SetPoint("BOTTOMLEFT", 8, 8)

	-- ===== NUMBERS pane =====
	local np = CreateFrame("Frame", nil, mp)
	np:SetSize(197, 96)
	np:SetPoint("TOPLEFT", 374, -290)
	GM.Panel(np, "contLowest")
	local nh = GM.MakeFontString(np, GM.FONT_BOLD, 10, "secondary")
	nh:SetPoint("TOPLEFT", 8, -5) nh:SetText("NUMBERS")
	-- two columns of five — a single font-9 column can't hold ten
	-- fields plus a header in 96px (the rows landed on the foot)
	mp.numRows = {}
	for i = 1, #NUM_FIELDS do
		local col = i <= 5 and 0 or 1
		local row = (i - 1) % 5
		local lab = GM.MakeFontString(np, GM.FONT, 9, "textDim")
		lab:SetPoint("TOPLEFT", 8 + col * 96, -17 - row * 11)
		lab:SetJustifyH("LEFT")
		local val = GM.MakeFontString(np, GM.FONT, 9, "text")
		val:SetPoint("TOPRIGHT", col == 0 and -104 or -8, -17 - row * 11)
		val:SetJustifyH("RIGHT")
		mp.numRows[i] = { lab, val }
	end
	mp.numFoot = GM.MakeFontString(np, GM.FONT, 8, "textDim")
	mp.numFoot:SetPoint("BOTTOMLEFT", 8, 2)
	mp.numFoot:SetJustifyH("LEFT")

	-- ===== INTEL pane =====
	local ip = CreateFrame("Frame", nil, mp)
	ip:SetSize(197, 96)
	ip:SetPoint("TOPLEFT", 579, -290)
	GM.Panel(ip, "contLowest")
	local ih = GM.MakeFontString(ip, GM.FONT_BOLD, 10, "secondary")
	ih:SetPoint("TOPLEFT", 8, -5) ih:SetText("INTEL")
	-- AUTO: the book-refresh cadence that feeds this pane — green lit
	mp.auto = CreateFrame("Button", nil, ip)
	mp.auto:SetSize(42, 12)
	mp.auto:SetPoint("TOPRIGHT", -5, -3)
	mp.auto.t = GM.MakeFontString(mp.auto, GM.FONT_BOLD, 8, "textDim")
	mp.auto.t:SetPoint("CENTER")
	mp.auto.t:SetText("AUTO")
	mp.auto:SetScript("OnClick", function()
		if GM.db then
			GM.db.mktAutoscan = not GM.db.mktAutoscan or nil
			PaintAuto()
		end
	end)
	mp.auto:SetScript("OnEnter", function()
		mp.auto.t:SetTextColor(GM.RGB("text"))
	end)
	mp.auto:SetScript("OnLeave", function() MU.Refresh() end)
	mp.intelRows = {}
	for i = 1, 6 do
		local fs = GM.MakeFontString(ip, GM.FONT, 9, "text")
		fs:SetPoint("TOPLEFT", 8, -16 - (i - 1) * 13)
		fs:SetWidth(180)
		fs:SetJustifyH("LEFT") fs:SetWordWrap(false)
		mp.intelRows[i] = fs
	end

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
