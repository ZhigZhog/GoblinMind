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
local ASK_VIS = 4

local BAIT_DROP = 0.60 -- matches Intel.lua — lone ask far under the next
local WALL_MIN = 4     -- matches Intel.lua — same-seller lot wall

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

-- per-lot flags recomputed on the ask array: Intel.marks carries
-- cross-scan state; the flags below describe THIS book snapshot
local function FlagAsks(asks)
	local bySeller = {}
	for _, a in ipairs(asks) do
		if a.seller and not a.own then
			bySeller[a.seller] = (bySeller[a.seller] or 0) + 1
		end
	end
	for s, n in pairs(bySeller) do
		if n >= WALL_MIN then
			for _, a in ipairs(asks) do
				if a.seller == s then a.wall = true end
			end
		end
	end
	if #asks >= 2 and asks[2].unit > 0
		and asks[1].unit <= asks[2].unit * BAIT_DROP
		and not asks[1].own then
		asks[1].bait = true
	end
	local run = 1
	local function Close(hi)
		if run >= 3 then
			for j = hi - run + 1, hi do asks[j].step = true end
		end
		run = 1
	end
	for i = 2, #asks do
		if asks[i].unit - asks[i - 1].unit == 1 then run = run + 1
		else Close(i - 1) end
	end
	Close(#asks)
	for _, a in ipairs(asks) do
		if a.seller and GM.Intel and GM.Intel.IsSuspect(a.seller) then
			a.solver = true
		end
	end
	return bySeller
end

local function ScanAsks()
	if not M.itemID then return end
	if GM.AH.Busy and GM.AH.Busy() then
		M.askWait = true
		return
	end
	M.askWait = nil
	local id, name = M.itemID, GM.ItemName(M.itemID)
	GM.AH.ScanItem(id, name, function(asks)
		if M.itemID ~= id then return end -- retargeted mid-scan
		M.asks = asks or {}
		M.askT = GetTime()
		M.askScroll = 0
		MU.Refresh()
	end, M.itemKey)
end

function MU.SetItem(id, link, key)
	if not id then return end
	M.itemID, M.itemLink, M.itemKey = id, link, key
	M.asks, M.askT = nil, nil
	ScanAsks()
	if MU.Refresh then MU.Refresh() end
end

-- ============ price chart ============

local WEEK = 7 * 86400
local function DrawPrice(entry)
	local ch = mp.price
	ch.msg:SetText("")
	ch.tipLines = nil
	local pts, seriesMode, window = {}, false, WEEK
	local sup = {}
	if M.itemID and GM.History then
		local s = GM.History.Points(M.itemID, WEEK)
		if #s >= 2 then
			seriesMode = true
			local span = s[#s].t - s[1].t
			if span < 0.85 * WEEK then window = math.max(span * 1.25, 3600) end
			local t0 = time() - window
			for _, p in ipairs(s) do
				local x = (p.t - t0) / window
				tinsert(pts, { x = x < 0 and 0 or x > 1 and 1 or x, v = p.p })
				if p.s then tinsert(sup, { x = pts[#pts].x, s = p.s }) end
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
	-- supply bars
	local smax = 0
	for _, s in ipairs(sup) do smax = math.max(smax, s.s) end
	if smax > 0 then
		local bw = math.max(1, cw / math.max(8, #sup * 2))
		for _, s in ipairs(sup) do
			Bar(ch, px(s.x) - bw / 2, 4, bw, s.s / smax * volTop,
				"contHigh", 0.9, "BACKGROUND")
		end
	end
	-- mkt / mb horizontals
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
	for i = 2, #pts do
		Segment(ch, px(pts[i - 1].x), py(pts[i - 1].v),
			px(pts[i].x), py(pts[i].v))
	end
	-- trendline over the series itself
	if seriesMode and #pts >= 3 then
		local n, sx, sy, sxx, sxy = #pts, 0, 0, 0, 0
		for _, p in ipairs(pts) do
			sx, sy = sx + p.x, sy + p.v
			sxx, sxy = sxx + p.x * p.x, sxy + p.x * p.v
		end
		local den = n * sxx - sx * sx
		if den ~= 0 then
			local m = (n * sxy - sx * sy) / den
			local b = (sy - m * sx) / n
			Segment(ch, px(0), py(m * 0 + b), px(1), py(m + b), "textDim")
		end
	end
	local last = pts[#pts]
	Dot(ch, px(last.x), py(last.v), 5, "accent")
	Label(ch, ch:GetWidth() - 4, py(last.v) - 5, GM.Money(last.v),
		"text", 10, "RIGHT")
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
		ch.msg:SetText(M.itemID and (M.askWait and "scan busy — waiting"
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
	FlagAsks(asks)
	mp.abHead:SetText("ASK BOOK")
	local maxScroll = math.max(0, #asks - ASK_VIS)
	M.askScroll = math.min(M.askScroll or 0, maxScroll)
	W.ScrollText(mp.abCount, M.askScroll, ASK_VIS, #asks)
	mp.abEmpty:SetText(M.itemID and (M.askWait and "scan busy…"
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
			local seller = a.seller or "?"
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
			tinsert(lines, GM.CC("warn") .. format(
				"wall — %s holds %d lots%s|r", s, n,
				sc >= 4 and (" (suspect " .. sc .. ")") or ""))
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
	local armed = idx <= total and steps[idx]
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
	mp.name = GM.MakeFontString(mp, GM.FONT_BOLD, 12, "text")
	mp.name:SetPoint("TOPLEFT", 32, -2)
	mp.name:SetWidth(280)
	mp.name:SetJustifyH("LEFT")
	mp.name:SetWordWrap(false)
	mp.chips = GM.MakeFontString(mp, GM.FONT, 9, "text")
	mp.chips:SetPoint("TOPLEFT", 32, -18)
	mp.chips:SetWidth(430)
	mp.chips:SetJustifyH("LEFT")
	mp.chips:SetWordWrap(false)
	mp.slot = W.ItemSlot(mp, {
		icon = 18, w = 240, h = 26, nameSize = 10, subSize = 8,
		hint = "target — drop · shift-click · [link]",
		onItem = function(id, link) MU.SetItem(id, link) end,
	})
	mp.slot:SetPoint("TOPRIGHT", -8, -2)

	-- ===== PRICE pane =====
	local ch = CreateFrame("Frame", nil, mp)
	ch:SetSize(776, 96)
	ch:SetPoint("TOPLEFT", 0, -32)
	GM.Panel(ch, "contLowest")
	ch.title = GM.MakeFontString(ch, GM.FONT_BOLD, 9, "secondary")
	ch.title:SetPoint("TOPLEFT", 8, -4)
	ch.title:SetText("PRICE")
	ch.msg = GM.MakeFontString(ch, GM.FONT, 9, "textDim")
	ch.msg:SetPoint("CENTER", 0, -4)
	if ch.SetClipsChildren then ch:SetClipsChildren(true) end
	mp.price = ch

	-- ===== DEPTH pane =====
	local dp = CreateFrame("Frame", nil, mp)
	dp:SetSize(366, 122)
	dp:SetPoint("TOPLEFT", 0, -132)
	GM.Panel(dp, "contLowest")
	dp.title = GM.MakeFontString(dp, GM.FONT_BOLD, 9, "secondary")
	dp.title:SetPoint("TOPLEFT", 8, -4)
	dp.title:SetText("DEPTH")
	dp.msg = GM.MakeFontString(dp, GM.FONT, 9, "textDim")
	dp.msg:SetPoint("CENTER", 0, -4)
	if dp.SetClipsChildren then dp:SetClipsChildren(true) end
	mp.depth = dp

	-- ===== ASK BOOK pane =====
	local ab = CreateFrame("Frame", nil, mp)
	ab:SetSize(394, 122)
	ab:SetPoint("TOPRIGHT", 0, -132)
	GM.Panel(ab, "contLowest")
	mp.abHead = GM.MakeFontString(ab, GM.FONT_BOLD, 9, "secondary")
	mp.abHead:SetPoint("TOPLEFT", 8, -5)
	mp.abHead:SetText("ASK BOOK")
	mp.abCount = GM.MakeFontString(ab, GM.FONT, 9, "textDim")
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
		row.c1:SetPoint("LEFT", 6, 0) row.c1:SetWidth(62)
		row.c1:SetJustifyH("LEFT") row.c1:SetWordWrap(false)
		row.c2 = GM.MakeFontString(row, GM.FONT, 10, "accent")
		row.c2:SetPoint("LEFT", 70, 0) row.c2:SetWidth(32)
		row.c2:SetJustifyH("LEFT") row.c2:SetWordWrap(false)
		row.c3 = GM.MakeFontString(row, GM.FONT, 9, "text")
		row.c3:SetPoint("LEFT", 106, 0) row.c3:SetWidth(196)
		row.c3:SetJustifyH("LEFT") row.c3:SetWordWrap(false)
		row.c4 = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.c4:SetPoint("LEFT", 304, 0) row.c4:SetWidth(46)
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
	mp.abEmpty = GM.MakeFontString(ab, GM.FONT, 9, "textDim")
	mp.abEmpty:SetPoint("CENTER", 0, -8)

	-- ===== PLAN pane =====
	local pp = CreateFrame("Frame", nil, mp)
	pp:SetSize(366, 90)
	pp:SetPoint("TOPLEFT", 0, -258)
	GM.Panel(pp, "contLowest")
	mp.pPane = pp
	mp.pHead = GM.MakeFontString(pp, GM.FONT_BOLD, 9, "secondary")
	mp.pHead:SetPoint("TOPLEFT", 8, -5)
	mp.pHead:SetText("PLAN")
	mp.exec = Btn(pp, 70, "EXECUTE", function() GM.PlanQueue.ExecuteNext() end)
	mp.exec:SetPoint("TOPRIGHT", -6, -4)
	mp.exec.text:SetTextColor(GM.RGB("accent"))
	mp.skip = Btn(pp, 40, "SKIP", function() GM.PlanQueue.SkipStep() end)
	mp.skip:SetPoint("TOPRIGHT", mp.exec, "TOPLEFT", -4, 0)
	mp.rescan = Btn(pp, 52, "RESCAN", function() GM.PlanQueue.Rescan() end)
	mp.rescan:SetPoint("TOPRIGHT", mp.skip, "TOPLEFT", -4, 0)
	mp.pArmed = GM.MakeFontString(pp, GM.FONT, 9, "text")
	mp.pArmed:SetPoint("TOPLEFT", 8, -22)
	mp.pArmed:SetWidth(348)
	mp.pArmed:SetJustifyH("LEFT") mp.pArmed:SetWordWrap(false)
	mp.pNext = GM.MakeFontString(pp, GM.FONT, 9, "textDim")
	mp.pNext:SetPoint("TOPLEFT", 8, -38)
	mp.pNext:SetWidth(348)
	mp.pNext:SetJustifyH("LEFT") mp.pNext:SetWordWrap(false)
	mp.pMore = GM.MakeFontString(pp, GM.FONT, 9, "textDim")
	mp.pMore:SetPoint("TOPLEFT", 8, -52)
	mp.pMore:SetJustifyH("LEFT")
	mp.prog = pp:CreateTexture(nil, "ARTWORK")
	mp.prog:SetColorTexture(GM.RGB("accent"))
	mp.prog:SetHeight(3)
	mp.prog:SetPoint("BOTTOMLEFT", 8, 8)

	-- ===== NUMBERS pane =====
	local np = CreateFrame("Frame", nil, mp)
	np:SetSize(190, 90)
	np:SetPoint("TOPLEFT", 374, -258)
	GM.Panel(np, "contLowest")
	local nh = GM.MakeFontString(np, GM.FONT_BOLD, 9, "secondary")
	nh:SetPoint("TOPLEFT", 8, -5) nh:SetText("NUMBERS")
	mp.numRows = {}
	for i = 1, #NUM_FIELDS do
		local lab = GM.MakeFontString(np, GM.FONT, 8, "textDim")
		lab:SetPoint("TOPLEFT", 8, -14 - (i - 1) * 7.5)
		lab:SetJustifyH("LEFT")
		local val = GM.MakeFontString(np, GM.FONT, 8, "text")
		val:SetPoint("TOPRIGHT", -8, -14 - (i - 1) * 7.5)
		val:SetJustifyH("RIGHT")
		mp.numRows[i] = { lab, val }
	end
	mp.numFoot = GM.MakeFontString(np, GM.FONT, 8, "textDim")
	mp.numFoot:SetPoint("BOTTOMLEFT", 8, 4)
	mp.numFoot:SetJustifyH("LEFT")

	-- ===== INTEL pane =====
	local ip = CreateFrame("Frame", nil, mp)
	ip:SetSize(196, 90)
	ip:SetPoint("TOPRIGHT", 0, -258)
	GM.Panel(ip, "contLowest")
	local ih = GM.MakeFontString(ip, GM.FONT_BOLD, 9, "secondary")
	ih:SetPoint("TOPLEFT", 8, -5) ih:SetText("INTEL")
	mp.intelRows = {}
	for i = 1, 6 do
		local fs = GM.MakeFontString(ip, GM.FONT, 8, "text")
		fs:SetPoint("TOPLEFT", 8, -15 - (i - 1) * 12)
		fs:SetWidth(182)
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
