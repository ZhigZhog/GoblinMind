local _, GM = ...
local W = GM.Widgets

-- The ledger window: TSM-style paged layout — left nav over ACTIVITY /
-- INVENTORY / SALES / RESALE / EXPENSES / FAILED / ACCOUNTS, per-char
-- transaction aggregation (char switcher top-right), and an item-detail
-- page reached by clicking any item row.

GM.Overview = {}
local OV = GM.Overview
local ui

local ROWS = 20
local atan2 = atan2 or function(y, x) return math.atan(y, x) end

local PAGES = {
	{ "ACTIVITY", "activity" },
	{ "INVENTORY", "inventory" },
	{ "SALES", "sales" },
	{ "RESALE", "resale" },
	{ "EXPENSES", "expenses" },
	{ "FAILED", "failed" },
	{ "ACCOUNTS", "accounts" },
}

local function Panel(f, x, y, w, h, title)
	local p, t = W.TitledPanel(f, title)
	p:SetSize(w, h)
	p:SetPoint("TOPLEFT", x, y)
	return p, t
end

-- rotated-texture line segment (chart series / pie spokes) —
-- key = theme color name or an {r,g,b} triple (per-char wealth
-- series ride the char's own color, not the theme accent)
local function Line(parent, x1, y1, x2, y2, key, thick)
	local t = parent:CreateTexture(nil, "ARTWORK")
	local dx, dy = x2 - x1, y2 - y1
	local len = math.max(1, sqrt(dx * dx + dy * dy))
	t:SetSize(len, thick or 1.5)
	t:SetPoint("CENTER", parent, "BOTTOMLEFT", (x1 + x2) / 2, (y1 + y2) / 2)
	-- WoW's atan2/math.atan return DEGREES; SetRotation takes radians —
	-- a raw pass tilts every non-horizontal segment (90° input landed
	-- at 90 rad ≈ 117° — the giant "X" artifacts on steep jumps)
	t:SetRotation(math.rad(atan2(dy, dx)))
	if type(key) == "table" then
		t:SetColorTexture(key[1], key[2], key[3])
	else
		t:SetColorTexture(GM.RGB(key))
	end
	return t
end

-- ============ data ============

-- per-item aggregation over one char's transaction stream — the char
-- switcher re-aggregates; itemStats (account-global) stays for detail
local function TxAgg(ck)
	local agg = {}
	for _, e in ipairs(GM.Ledger.TxFor(ck)) do
		if e.i then
			local a = agg[e.i]
			if not a then a = {} agg[e.i] = a end
			local amt = e.q * (e.u or 0)
			if e.ty == "buy" then
				a.buyQ = (a.buyQ or 0) + e.q
				a.buyT = (a.buyT or 0) + amt
			elseif e.ty == "sell" then
				a.sellQ = (a.sellQ or 0) + e.q
				a.sellT = (a.sellT or 0) + amt
			elseif e.ty == "cancel" then
				a.cancelQ = (a.cancelQ or 0) + e.q
			elseif e.ty == "expire" then
				a.expireQ = (a.expireQ or 0) + e.q
			elseif e.ty == "post" then
				a.postQ = (a.postQ or 0) + e.q
			elseif e.ty == "mail" then
				a.mailQ = (a.mailQ or 0) + e.q
			end
		end
	end
	return agg
end

local function ViewChar()
	-- a viewChar captured while the realm was still empty goes stale
	-- once MigrateCharKeys folds the bare key into Name-Realm — fall
	-- back to the live key whenever the stored one isn't a real bucket
	if ui.viewChar then
		for _, ck in ipairs(GM.Ledger.Chars()) do
			if ck == ui.viewChar then return ui.viewChar end
		end
	end
	ui.viewChar = GM.Ledger.CharKey()
	return ui.viewChar
end

-- ============ generic table ============

-- Columned item table: pooled rows {icon,name,c1..cN}, wheel scroll,
-- row click drills to the item page.
local function MakeTable(parent, cols, onClick)
	local t = { off = 0, rows = {}, list = {} }
	local head = CreateFrame("Frame", nil, parent)
	head:SetPoint("TOPLEFT", 6, -16)
	head:SetPoint("TOPRIGHT", -6, -16)
	head:SetHeight(16)
	for _, c in ipairs(cols) do
		local fs = GM.MakeFontString(head, GM.FONT_MED, 9, "primary")
		fs:SetPoint("LEFT", c[2], 0)
		fs:SetText(c[1])
		fs:SetWordWrap(false)
	end
	t.count = GM.MakeFontString(head, GM.FONT, 9, "textDim")
	t.count:SetPoint("RIGHT", 0, 0)
	local body = CreateFrame("Frame", nil, parent)
	body:SetPoint("TOPLEFT", 6, -34)
	body:SetPoint("BOTTOMRIGHT", -6, 24)
	if body.SetClipsChildren then body:SetClipsChildren(true) end
	body:EnableMouseWheel(true)
	body:SetScript("OnMouseWheel", function(_, d)
		t.off = math.max(0, math.min(
			math.max(0, #t.list - ROWS), t.off - d * 2))
		t.paint()
	end)
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, body)
		W.HoverTint(row)
		row:SetHeight(22)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * 23)
		row:SetPoint("TOPRIGHT", 0, -(i - 1) * 23)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 2, 0)
		row.cells = {}
		for j, c in ipairs(cols) do
			local fs = GM.MakeFontString(row, j == 1 and GM.FONT or GM.FONT_MED,
				j == 1 and 10 or 9, j == 1 and "text" or "textDim")
			fs:SetPoint("LEFT", c[2], 0)
			if c[3] then fs:SetWidth(c[3]) end
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			row.cells[j] = fs
		end
		row:SetScript("OnEnter", function()
			if row.id then
				if GameTooltip.SetItemByID then
					GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
					GameTooltip:SetItemByID(row.id)
					GameTooltip:Show()
				else
					GM.Widgets.HintShow(row,
						{ row.cells[1]:GetText() or "" })
				end
			end
		end)
		row:SetScript("OnLeave", function()
			GameTooltip:Hide() GM.Widgets.HintHide()
		end)
		row:SetScript("OnClick", function()
			if IsModifiedClick() then
				if row.id then GM.Ops.Click(row.id) end
			elseif row.id and onClick then
				onClick(row.id)
			end
		end)
		t.rows[i] = row
	end
	t.paint = function()
		W.ScrollText(t.count, t.off, ROWS, #t.list)
		for i, row in ipairs(t.rows) do
			local e = t.list[i + t.off]
			if e then
				row:Show()
				row.id = e.id
				row.icon:SetTexture(e.id and GM.ItemIcon
					and GM.ItemIcon(e.id) or
					"Interface\\Icons\\INV_Misc_QuestionMark")
				for j, fs in ipairs(row.cells) do
					fs:SetText(e.cells[j] or "")
					fs:SetTextColor(GM.RGB(e.colors and e.colors[j]
						or (j == 1 and "text" or "textDim")))
				end
			else
				row:Hide()
				row.id = nil
			end
		end
	end
	t.footer = GM.MakeFontString(parent, GM.FONT, 9, "secondary")
	t.footer:SetPoint("BOTTOMLEFT", 10, 6)
	return t
end

-- ============ pages: content builders ============

local ItemName = GM.ItemNameOr
local function QName(id)
	return (GM.QHex(id) or "") .. ItemName(id) .. "|r"
end

-- display name for a tx: the recorded nm carries the suffix variant
-- ("Banded Girdle of the Bear") — the bare itemID can only give the
-- base name
local function TxName(e)
	if e.ty == "transfer" then
		return format("%s → %s", e.x and e.x.from or "?",
			e.x and e.x.to or "?")
	end
	return (e.x and e.x.nm)
		and ((GM.QHex(e.i) or "") .. e.x.nm .. "|r")
		or QName(e.i)
end

-- INVENTORY: owned items by value
local function BuildInventory()
	local out, total = {}, 0
	for id in pairs(GM.Inventory.Owned()) do
		local c = GM.Inventory.Count(id)
		local e = GM.ItemEntry(id)
		local p = GM.Price("dbmarket", id)
		local v = p and p * c.total or 0
		total = total + v
		tinsert(out, { id = id, v = v, cells = {
			QName(id),
			c.bags + c.bank > 0 and ("×" .. (c.bags + c.bank)) or "",
			(c.mail + c.guild + c.auction) > 0
				and ("+" .. (c.mail + c.guild + c.auction)) or "",
			p and GM.Money(p) or "—",
			v > 0 and GM.Money(v) or "—",
		} })
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildSales(agg)
	local out, total = {}, 0
	for id, a in pairs(agg) do
		if a.sellQ and a.sellQ > 0 then
			total = total + a.sellT
			tinsert(out, { id = id, v = a.sellT, cells = {
				QName(id), "×" .. a.sellQ,
				GM.Money(a.sellT / a.sellQ), GM.Money(a.sellT),
			} })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildResale(agg)
	local out, total = {}, 0
	for id, a in pairs(agg) do
		if a.sellQ and a.sellQ > 0 and a.buyQ and a.buyQ > 0 then
			local avgB, avgS = a.buyT / a.buyQ, a.sellT / a.sellQ
			local profit = a.sellT - avgB * a.sellQ
			total = total + profit
			tinsert(out, { id = id, v = profit, cells = {
				QName(id), "×" .. a.sellQ, GM.Money(avgB),
				GM.Money(avgS), GM.Money(profit),
			}, colors = { nil, nil, nil, nil,
				profit >= 0 and "pos" or "err" } })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildExpenses(agg)
	local out, total = {}, 0
	for id, a in pairs(agg) do
		if a.buyQ and a.buyQ > 0 then
			total = total + a.buyT
			tinsert(out, { id = id, v = a.buyT, cells = {
				QName(id), "×" .. a.buyQ,
				GM.Money(a.buyT / a.buyQ), GM.Money(a.buyT),
			} })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out, total
end

local function BuildFailed(agg)
	local out = {}
	for id, a in pairs(agg) do
		local f = (a.cancelQ or 0) + (a.expireQ or 0)
		if f > 0 then
			local rate = f / (f + (a.sellQ or 0)) * 100
			tinsert(out, { id = id, v = f, cells = {
				QName(id),
				a.expireQ and a.expireQ > 0 and tostring(a.expireQ) or "—",
				a.cancelQ and a.cancelQ > 0 and tostring(a.cancelQ) or "—",
				format("%.0f%%", rate),
			} })
		end
	end
	sort(out, function(a, b) return a.v > b.v end)
	return out
end

-- ============ activity log ============

local TX_LABEL = {
	buy = "Purchased", sell = "Sold", post = "Posted",
	cancel = "Cancelled", expire = "Expired", mail = "Mail in",
	vendor = "Vendored", vendorbuy = "Vendor buy",
	mailout = "Mail out", destroy = "Destroyed",
	craftout = "Craft in", craftin = "Crafted",
	loot = "Looted", bid = "Bid", bidwon = "Bid won",
	transfer = "Transfer",
	tradein = "Trade in", tradeout = "Trade out",
	trainer = "Trained",
}

local function DisplayList(ck)
	local tx = GM.Ledger.TxFor(ck)
	local out, lastDay = {}, nil
	local today, yest = date("%x"), date("%x", time() - 86400)
	for i = #tx, 1, -1 do
		local e = tx[i]
		local day = date("%x", e.t)
		if day ~= lastDay then
			out[#out + 1] = { head = day == today and "TODAY"
				or day == yest and "YESTERDAY" or date("%b %d", e.t) }
			lastDay = day
		end
		out[#out + 1] = e
	end
	return out
end

function OV.RefreshLog(vm)
	if not ui then return end
	local list = (vm and vm.list) or DisplayList(ViewChar())
	local maxOff = math.max(0, #list - ROWS)
	if ui.scroll > maxOff then ui.scroll = maxOff end
	for i, fs in ipairs(ui.logRows) do
		local e = list[i + ui.scroll]
		if not e then
			fs:SetText("")
		elseif e.head then
			fs:SetText(GM.CC("accent") .. e.head .. "|r")
		else
			local money = e.u and e.u * e.q
			-- the journal detail that makes a row answer "what was
			-- the deposit" — dep estimate carried on the owned entry
			local dep = e.x and e.x.dep
			local depTxt = dep and dep > 0
				and (" · dep " .. GM.Money(dep)
					.. (e.ty == "sell" and " back"
						or (e.ty == "cancel" or e.ty == "expire")
							and " lost" or ""))
				or ""
			fs:SetText(format("%s  %s %s · %s%s%s%s",
				date("%H:%M", e.t),
				e.ty == "sell" and GM.CC("pos") or
					e.ty == "buy" and GM.CC("warn") or GM.CC("textDim"),
				TX_LABEL[e.ty] or e.ty,
				TxName(e),
				e.ty == "transfer" and (" " .. GM.Money(e.q))
					or (" ×" .. e.q),
				money and (" · " .. GM.Money(money)) or "", depTxt))
		end
	end
end

-- ============ wealth chart ============

-- one line, one honest answer: "am I getting richer, and how fast".
-- W(t) = gold + pending-AH buyout is wealth-neutral across buys
-- (gold becomes listings ~1:1), so its step line and least-squares
-- slope measure realized P&L + revaluation — fitting the slope to
-- raw gold-on-hand reads a buy spree as "losing money" (the old
-- "-1087g/d" scare line). Posted value draws as a shaded band under
-- the line instead of a second series: same information, no
-- crossings, no legend row. Design: WoWVault/Proposals/
-- ledger-accounts-proposal.md

local WIN_SECS = { ["24H"] = 86400, ["7D"] = 604800 }

function OV.RefreshChart()
	if not ui then return end
	for _, a in ipairs(ui.art) do a:Hide() end
	wipe(ui.art)
	local chart = ui.chart
	-- window filter hoisted above the plot inset: the account series
	-- count decides how much right gutter their end labels need
	local cutoff = WIN_SECS[ui.chartWin or "ALL"]
	cutoff = cutoff and (time() - cutoff) or -math.huge

	-- per-account signed-balance series in darker shades of the char
	-- color. Shade index bi runs a bit-reversed (van der Corput)
	-- fraction — bisecting the shade band each new account keeps any
	-- count evenly spread: ½, ¼, ¾, ⅛, ⅝, ⅜, ⅞… Point lists are
	-- built at draw time — they need the wealth axis' tMin/tMax
	local accts, bi = {}, 0
	local vk = ViewChar()
	for _, a in ipairs(GM.Budget and GM.Budget.List() or {}) do
		local ok = GM.Budget.OwnerKey and GM.Budget.OwnerKey(a)
		if a.hist and #a.hist > 0
			and (ok == vk or (ok or ""):gsub("%-.*$", "")
				== (vk or ""):gsub("%-.*$", "")) then
			bi = bi + 1
			local j, f, p = bi, 0, 0.5
			while j > 0 do
				if j % 2 == 1 then f = f + p end
				p = p / 2
				j = floor(j / 2)
			end
			accts[#accts + 1] = { a = a, shade = 0.30 + f * 0.55 }
		end
	end

	-- plot inset: left gutter for money labels, top clears the KPI
	-- strip, bottom holds time labels + the flow footer, right holds
	-- the account series' end labels
	local gx, gy, gt = 56, 20, 56
	local rg = #accts > 0 and 96 or 14
	local w = chart:GetWidth() - gx - rg
	local h = chart:GetHeight() - gt - gy

	-- ---- KPI strip: live numbers, independent of sample history ----
	local gold = GetMoney and GetMoney() or 0
	local posted = GM.Inventory and GM.Inventory.PostedValue
		and GM.Inventory.PostedValue() or 0
	local held = GM.Inventory and GM.Inventory.HeldValue
		and GM.Inventory.HeldValue() or 0
	local rcbl = GM.Ledger and GM.Ledger.Accounts
		and (GM.Ledger.Accounts().rcbl or 0) or 0
	local now = gold + posted + held + rcbl
	ui.kpiTotal:SetText("TOTAL " .. GM.Money(now))
	local split = "on hand " .. GM.MoneyShort(gold)
	if held > 0 then
		split = split .. " + stock " .. GM.MoneyShort(held)
	end
	if rcbl > 0 then
		split = split .. " + incoming " .. GM.MoneyShort(rcbl)
	end
	if posted > 0 then
		split = split .. " + posted " .. GM.MoneyShort(posted)
		local at = GM.Inventory.OwnedAt and GM.Inventory.OwnedAt()
		if at and time() - at > 1800 then
			split = split .. " · " .. GM.FmtAge(time() - at) .. " ago"
		end
	end
	ui.kpiSplit:SetText(split)

	-- window-filtered samples + stats pass (cutoff computed above)
	local hist, tMin, tMax, vMin, vMax =
		{}, math.huge, 0, math.huge, 0
	local vals = {}
	local n, st, sv, stt, stv = 0, 0, 0, 0, 0
	for _, p in ipairs(GM.Model.WealthHist()) do
		-- untagged legacy samples (no c) still count; tagged ones
		-- only count when they're THIS char — IsSelfCharKey matches
		-- bare-name tags too (realm never resolves on this client).
		-- Zero-total samples never draw: pre-tag alts and init races
		-- wrote them into the shared pool as giant fake dips
		if p.t >= cutoff
			and (p.g or 0) + (p.a or 0) + (p.h or 0) + (p.r or 0) > 0
			and (not p.c or GM.IsSelfCharKey(p.c)) then
			hist[#hist + 1] = p
			if p.t < tMin then tMin = p.t end
			if p.t > tMax then tMax = p.t end
			local wv = (p.g or 0) + (p.a or 0) + (p.h or 0) + (p.r or 0)
			vals[#vals + 1] = wv
			if wv > vMax then vMax = wv end
			if wv < vMin then vMin = wv end
			n = n + 1; st = st + p.t; sv = sv + wv
			stt = stt + p.t * p.t; stv = stv + p.t * wv
		end
	end

	-- today's delta vs the first sample at/after local midnight;
	-- falls back to the oldest buffered sample when the day is young
	local d = date("*t")
	local midnight = time() - (d.hour * 3600 + d.min * 60 + d.sec)
	local dayBase
	for _, p in ipairs(GM.Model.WealthHist()) do
		if p.t >= midnight
			and (p.g or 0) + (p.a or 0) + (p.h or 0) + (p.r or 0) > 0 then
			dayBase = p
			break
		end
	end
	dayBase = dayBase or GM.Model.WealthHist()[1]
	local deltaTxt = ""
	if dayBase then
		local dv = now - (dayBase.g or 0) - (dayBase.a or 0)
			- (dayBase.h or 0)
		deltaTxt = GM.Signed(dv) .. GM.CC("textDim") .. " "
			.. (dayBase.t >= midnight and "today"
				or "since " .. date("%H:%M", dayBase.t)) .. "|r"
	end

	-- least-squares slope on W — suppressed when the window is too
	-- thin to fit honestly (a 3-point hour is noise, not a rate)
	local span = tMax - tMin
	local slope, mt, mv
	if n >= 2 then
		mt, mv = st / n, sv / n
		local var = stt - n * mt * mt
		slope = var ~= 0 and (stv - n * mt * mv) / var or 0
	end
	local slopeOK = slope ~= nil and n >= 3 and span >= 3600
	if slopeOK then
		deltaTxt = deltaTxt .. "    " .. GM.Signed(slope * 86400)
			.. GM.CC("textDim") .. "/day|r"
	end
	ui.kpiDelta:SetText(deltaTxt)

	-- realized vs revaluation footer: wealth slope conflates AH
	-- trading P&L with listing-value drift — split it with the
	-- ledger cashflow over the same window (needs half a day of
	-- span before the per-day figures mean anything)
	ui.kpiFlow:SetText("")
	if slopeOK and span >= 43200 then
		local sell, buy = 0, 0
		for _, e in ipairs(GM.Ledger.db and GM.Ledger.db.transactions
			or {}) do
			if e.t >= tMin and e.t <= tMax then
				local tot = (e.u or 0) * (e.q or 0)
				if e.ty == "sell" then sell = sell + tot
				elseif e.ty == "buy" then buy = buy + tot end
			end
		end
		if sell > 0 or buy > 0 then
			local realized = (sell - buy) * 86400 / span
			ui.kpiFlow:SetText(GM.CC("textDim") .. "realized |r"
				.. GM.Signed(realized) .. GM.CC("textDim")
				.. "/d · reval |r" .. GM.Signed(slope * 86400 - realized)
				.. GM.CC("textDim") .. "/d|r")
		end
	end

	-- journal replay: where the money actually sits — AH escrow,
	-- deposits outstanding, lifetime realized P&L (−pnl: credit
	-- account, negative balance = profit)
	if ui.kpiLedger then
		local bal = GM.Ledger.Accounts and GM.Ledger.Accounts(ViewChar())
		if bal then
			local parts = {}
			if bal.posted > 0 then
				parts[#parts + 1] = "posted " .. GM.MoneyShort(bal.posted)
			end
			if bal.dep > 0 then
				parts[#parts + 1] = "dep " .. GM.MoneyShort(bal.dep) .. " out"
			end
			if bal.rcbl > 0 then
				parts[#parts + 1] = "incoming " .. GM.MoneyShort(bal.rcbl)
			end
			if bal.pnl ~= 0 then
				parts[#parts + 1] = "realized " .. GM.Signed(-bal.pnl)
			end
			ui.kpiLedger:SetText(GM.CC("textDim") .. "ledger |r"
				.. table.concat(parts, " · "))
		end
	end

	if vMax <= 0 or tMax <= tMin then
		ui.chartMsg:SetText(
			"wealth history builds as you play — samples every 5 min")
		return
	end
	ui.chartMsg:SetText("")
	tMax = math.max(tMax, tMin + 600)

	-- normalize the Y range to the sample band + padding: a
	-- 0-pinned axis compresses the line into a ceiling sliver once
	-- wealth sits well above zero. Robust edges — Tukey fences at
	-- 1.5×IQR — so a handful of real dips (a big spend, a char the
	-- filter missed) clip at the chart edge instead of owning the
	-- whole range; wy clamps so outliers flatten at the rim, not
	-- into the gutter.
	local loD, hiD = vMin, vMax
	if n >= 8 then
		table.sort(vals)
		local q1 = vals[math.max(1, math.floor(n * 0.25))]
		local q3 = vals[math.max(1, math.ceil(n * 0.75))]
		local iqr = q3 - q1
		if iqr > 0 then
			loD = math.max(vMin, q1 - 1.5 * iqr)
			hiD = math.min(vMax, q3 + 1.5 * iqr)
		end
	end
	local pad = math.max((hiD - loD) * 0.08, vMax * 0.02, 100)
	local lo = math.max(0, loD - pad)
	local hi = hiD + pad
	local vspan = hi - lo
	local function wy(v)
		local c = math.max(lo, math.min(hi, v))
		return gy + (c - lo) / vspan * h
	end

	-- gridlines at ¼-steps with right-justified money labels in the
	-- gutter — the only scale anchor the plot needs
	local function AxisLabel(txt, x, y, anchor)
		local fs = GM.MakeFontString(chart, GM.FONT, 8, "secondary")
		fs:SetPoint(anchor or "BOTTOMLEFT", chart, "BOTTOMLEFT", x, y)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		fs:SetText(txt)
		tinsert(ui.art, fs)
	end
	for i = 0, 4 do
		local y = gy + h * i / 4
		tinsert(ui.art, Line(chart, gx, y, gx + w, y,
			i == 0 and "outlineVar" or "outline", 1))
		AxisLabel(GM.Money(lo + vspan * i / 4),
			gx - 4, y - 4, "BOTTOMRIGHT")
	end
	AxisLabel(date("%H:%M", tMin), gx, 4)
	AxisLabel(date("%H:%M", tMax), gx + w, 4, "BOTTOMRIGHT")

	-- pending-AH band + wealth line ride the VIEWED char's ledger
	-- color (class default or custom pick) — the series belongs to
	-- that char, so it wears their color the way the account rows
	-- and the gold strip already do
	-- `X and CharRGB() or RGB()` collapses the RGB triple to one
	-- return — branch explicitly so cg/cb survive
	local cr, cg, cb
	if GM.Budget.CharRGB then
		cr, cg, cb = GM.Budget.CharRGB(ViewChar())
	else
		cr, cg, cb = GM.RGB("accent")
	end
	local cc = { cr, cg, cb }
	local ar, ag, ab = cr * 0.22, cg * 0.22, cb * 0.22
	local px, pgy, pwv
	for _, p in ipairs(hist) do
		local x = gx + (p.t - tMin) / (tMax - tMin) * w
		local yg = math.max(gy, wy(p.g or 0))
		local yw = math.min(gy + h, wy((p.g or 0) + (p.a or 0)))
		if px and pwv > pgy then
			local band = chart:CreateTexture(nil, "BACKGROUND")
			band:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", px, pgy)
			band:SetPoint("TOPRIGHT", chart, "BOTTOMLEFT", x, pwv)
			band:SetColorTexture(ar, ag, ab)
			tinsert(ui.art, band)
		end
		px, pgy, pwv = x, yg, yw
	end
	-- account series beneath the wealth line: each envelope's signed
	-- balance normalized to its own window range — magnitudes differ
	-- too far for the shared axis (a −8s hole next to 52g); the
	-- right-edge labels key which shade is which account
	for _, s in ipairs(accts) do
		-- points are clipped to the drawn axis: every sample older
		-- than tMin collapses into one entry point at the left edge —
		-- an account born inside the window starts where its data
		-- starts instead of flat-carrying a value it never had
		local pts, pre = {}, nil
		for _, p in ipairs(s.a.hist) do
			if p.t >= tMin then pts[#pts + 1] = p
			else pre = p end
		end
		if pre then tinsert(pts, 1, { t = tMin, v = pre.v }) end
		local bal = GM.Budget.Balance(s.a)
		if #pts == 0 or pts[#pts].v ~= bal then
			pts[#pts + 1] = { t = tMax, v = bal }
		end
		if #pts == 1 then pts[2] = { t = tMax, v = pts[1].v } end
		local loA, hiA = math.huge, -math.huge
		for _, p in ipairs(pts) do
			if p.v < loA then loA = p.v end
			if p.v > hiA then hiA = p.v end
		end
		local spanA = hiA - loA
		local function ay(v)
			if spanA <= 0 then return gy + h * 0.5 end
			local cv = math.max(loA, math.min(hiA, v))
			return gy + h * 0.04 + (cv - loA) / spanA * h * 0.92
		end
		s.cc = { cr * s.shade, cg * s.shade, cb * s.shade }
		local ax, ayv
		for _, p in ipairs(pts) do
			local x = gx + (p.t - tMin) / (tMax - tMin) * w
			local y = ay(p.v)
			if ax then
				tinsert(ui.art, Line(chart, ax, ayv, x, ayv, s.cc, 1))
				if y ~= ayv then
					tinsert(ui.art,
						Line(chart, x, ayv, x, y, s.cc, 1))
				end
			end
			ax, ayv = x, y
		end
		s.endY = ayv
	end
	-- the wealth line: step-interpolated W(t) — flat runs + vertical
	-- jumps, honest to the samples
	px, pwv = nil, nil
	for _, p in ipairs(hist) do
		local x = gx + (p.t - tMin) / (tMax - tMin) * w
		local yw = wy((p.g or 0) + (p.a or 0))
		if px then
			tinsert(ui.art, Line(chart, px, pwv, x, pwv, cc))
			if yw ~= pwv then
				tinsert(ui.art, Line(chart, x, pwv, x, yw, cc))
			end
		end
		px, pwv = x, yw
	end
	-- dashed trendline on W — same slope the KPI strip prints, so
	-- the line and the number can never disagree
	if slopeOK then
		local function vy(t)
			return math.max(lo,
				math.min(hi, mv + slope * (t - mt)))
		end
		local ya = wy(vy(tMin))
		local yb = wy(vy(tMax))
		for i = 0, 12, 2 do -- dashed: every other seventh
			local xa = gx + w * i / 14
			local xb = gx + w * (i + 1) / 14
			tinsert(ui.art, Line(chart, xa, ya + (yb - ya) * i / 14,
				xb, ya + (yb - ya) * (i + 1) / 14, "secondary", 1))
		end
	end
	-- right-gutter end labels: a dash in the series shade keys the
	-- line, the name + live balance carry the identity and the
	-- magnitude the per-series normalization drops. Sorted by
	-- endpoint, pushed down to a 9px minimum gap
	table.sort(accts, function(a, b) return a.endY > b.endY end)
	local nextTop = math.huge
	for _, s in ipairs(accts) do
		local y = math.max(4,
			math.min((s.endY or gy + h * 0.5) - 4, nextTop - 9))
		local fs = GM.MakeFontString(chart, GM.FONT, 8, "secondary")
		fs:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT",
			gx + w + 5, y)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		fs:SetText(format("|cff%02x%02x%02x—|r %s %s",
			floor(s.cc[1] * 255 + 0.5), floor(s.cc[2] * 255 + 0.5),
			floor(s.cc[3] * 255 + 0.5), s.a.name or "?",
			GM.MoneyShort(GM.Budget.Balance(s.a))))
		tinsert(ui.art, fs)
		nextTop = y
	end
end

-- ============ accounts ============

-- journal legs render in canonical account order, positive delta =
-- debit (money/value arriving), negative = credit
local JE_ORDER = { "cash", "stock", "posted", "dep", "rcbl",
	"wip", "pnl", "ext" }
local JE_SET = {}
for _, a in ipairs(JE_ORDER) do JE_SET[a] = true end

local function PaintJournalRow(r, e)
	local money = e.u and e.u * e.q
	r[1]:SetText(date("%H:%M", e.t))
	r[2]:SetText((e.ty == "sell" and GM.CC("pos") or
		e.ty == "buy" and GM.CC("warn") or GM.CC("textDim"))
		.. (TX_LABEL[e.ty] or e.ty) .. "|r")
	if e.ty == "transfer" then
		r[3]:SetText(format("%s · %s", TxName(e), GM.Money(e.q)))
	else
		r[3]:SetText(format("%s ×%d%s", TxName(e), e.q,
			money and (" · " .. GM.Money(money)) or ""))
	end
	if e.je then
		local dr, cr, extra = {}, {}, {}
		for _, a in ipairs(JE_ORDER) do
			local d = e.je[a]
			if d and d ~= 0 then
				tinsert(d > 0 and dr or cr,
					a .. " " .. GM.MoneyShort(math.abs(d)))
			end
		end
		-- memo legs (transfer's acct:* keys) render after the real
		-- accounts — they net to zero inside the tx
		for a, d in pairs(e.je) do
			if not JE_SET[a] and d ~= 0 then tinsert(extra, a) end
		end
		sort(extra)
		for _, a in ipairs(extra) do
			local d = e.je[a]
			tinsert(d > 0 and dr or cr,
				a .. " " .. GM.MoneyShort(math.abs(d)))
		end
		r[4]:SetText(table.concat(dr, " · "))
		r[5]:SetText(table.concat(cr, " · "))
	else
		r[4]:SetText("")
		r[5]:SetText("")
	end
end

local function RefreshAccounts()
	if not ui then return end
	local journal = ui.acctView == "journal"
	if ui.acctTitle then
		ui.acctTitle:SetText(journal and "JOURNAL"
			or "ACCOUNTS · FUNCTION")
	end
	-- journal chrome
	ui.journalBal:SetShown(journal)
	for _, fs in ipairs(ui.journalCols) do fs:SetShown(journal) end
	for _, r in ipairs(ui.journalRows) do
		for _, fs in ipairs(r) do fs:SetShown(journal) end
	end
	ui.acctGold:SetShown(not journal)
	ui.acctAdd:SetShown(not journal)
	ui.acctHint:SetShown(not journal)
	if journal then
		for _, row in ipairs(ui.acctRows) do row:Hide() end
		ui.acctOnboard:Hide()
		local bal = GM.Ledger.Accounts
			and GM.Ledger.Accounts(ViewChar()) or {}
		local parts = { "cash " .. GM.MoneyShort(bal.cash or 0) }
		if (bal.stock or 0) > 0 then
			parts[#parts + 1] = "stock " .. GM.MoneyShort(bal.stock)
		end
		if (bal.posted or 0) > 0 then
			parts[#parts + 1] = "posted " .. GM.MoneyShort(bal.posted)
		end
		if (bal.dep or 0) > 0 then
			parts[#parts + 1] = "dep " .. GM.MoneyShort(bal.dep) .. " out"
		end
		if (bal.rcbl or 0) > 0 then
			parts[#parts + 1] = "incoming " .. GM.MoneyShort(bal.rcbl)
		end
		if (bal.pnl or 0) ~= 0 then
			-- pnl is a credit account: negative balance = profit,
			-- so display flips the sign to read as P&L
			parts[#parts + 1] = "realized " .. GM.Signed(-bal.pnl)
		end
		if (bal.ext or 0) ~= 0 then
			parts[#parts + 1] = "ext " .. GM.Signed(bal.ext)
		end
		ui.journalBal:SetText(table.concat(parts, "   "))
		local tx = GM.Ledger.TxFor(ViewChar())
		local maxOff = math.max(0, #tx - #ui.journalRows)
		if ui.jScroll > maxOff then ui.jScroll = maxOff end
		for i, r in ipairs(ui.journalRows) do
			local e = tx[#tx - (i - 1 + ui.jScroll)]
			if e then
				PaintJournalRow(r, e)
			elseif i == 1 and #tx == 0 then
				r[1]:SetText("")
				r[2]:SetText("")
				r[3]:SetText("no transactions yet — the journal "
					.. "fills as you trade")
				r[4]:SetText("")
				r[5]:SetText("")
			else
				for _, fs in ipairs(r) do fs:SetText("") end
			end
		end
		return
	end
	-- combined-gold legend: every known char's purse in its own
	-- color — the strip doubles as the color-mode legend
	local total, parts = 0, {}
	for _, ck in ipairs(GM.Budget.CharsOrdered()) do
		local ch = GM.Budget.CharInfo(ck)
		if ch and (ch.g or 0) > 0 then
			total = total + ch.g
			parts[#parts + 1] = GM.Budget.Crest(ck)
				.. GM.Budget.CharCC(ck) .. GM.Budget.CharName(ck)
				.. "|r " .. GM.MoneyShort(ch.g)
		end
	end
	ui.acctGold:SetText(GM.MoneyShort(total) .. "  "
		.. GM.CC("textDim") .. "across|r   "
		.. table.concat(parts, "   "))
	local list = GM.Budget.List()
	local order = GM.Budget.Order()
	-- nest accounts under their owner's pool: the pool row is the
	-- foldable header, named accounts indent beneath it. Fold state
	-- is session-local — default open, nothing hides unless asked
	local fold = ui.acctFold or {}
	ui.acctFold = fold
	local ckSeen, ckOrder = {}, {}
	for _, idx in ipairs(order) do
		local ck = GM.Budget.OwnerKey(list[idx])
		if not ckSeen[ck] then
			ckSeen[ck] = true
			ckOrder[#ckOrder + 1] = ck
		end
	end
	local disp = {}
	for _, ck in ipairs(ckOrder) do
		local hdr, kids = nil, {}
		for _, idx in ipairs(order) do
			local a = list[idx]
			if GM.Budget.OwnerKey(a) == ck then
				if a.pool then hdr = { a = a, idx = idx }
				else kids[#kids + 1] = { a = a, idx = idx } end
			end
		end
		if hdr then
			disp[#disp + 1] = { e = hdr, ck = ck,
				fold = #kids > 0
					and (fold[ck] and "closed" or "open") or nil }
			if not fold[ck] then
				for _, k in ipairs(kids) do
					disp[#disp + 1] = { e = k, indent = 1 }
				end
			end
		else
			-- no pool row for this owner — render flat
			for _, k in ipairs(kids) do
				disp[#disp + 1] = { e = k }
			end
		end
	end
	local maxOff = math.max(0, #disp - #ui.acctRows)
	if (ui.aScroll or 0) > maxOff then ui.aScroll = maxOff end
	for i, row in ipairs(ui.acctRows) do
		local d = disp[i + (ui.aScroll or 0)]
		if d then
			row:Show()
			local ck = d.ck
			W.PaintAcctRow(row, d.e.a, d.e.idx, {
				indent = d.indent,
				fold = d.fold,
				onFold = d.fold and function()
					fold[ck] = not fold[ck]
					RefreshAccounts()
				end or nil,
			})
		else
			row:Hide()
		end
	end
	-- nudge toward the first real account while this char's seeded
	-- pool is the whole self-owned list
	local selfAccts = {}
	for _, a in ipairs(list) do
		if GM.IsSelfCharKey(GM.Budget.OwnerKey(a)) then
			selfAccts[#selfAccts + 1] = a
		end
	end
	ui.acctOnboard:SetShown(#selfAccts == 1
		and selfAccts[1].pool ~= nil)
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { scroll = 0, art = {}, page = "activity", tables = {} }
	local f, title = GM.Widgets.Window({
		name = "GoblinMindOverview", title = "LEDGER",
		w = 860, h = 560, x = 60, y = 20, tab = "overview",
	})
	ui.frame = f
	title:SetWidth(400)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)

	-- char switcher: cycles the char whose tx stream drives the views.
	-- Shows the name part only — full Name-Realm-Region keys are
	-- long enough to blow past the button edge
	local char = CreateFrame("Button", nil, f)
	char:SetSize(150, 16)
	char:SetPoint("TOPRIGHT", close, "TOPLEFT", -8, -1)
	GM.Panel(char, "contMedium")
	char.text = GM.MakeFontString(char, GM.FONT_MED, 9, "secondary")
	char.text:SetPoint("CENTER")
	char.text:SetWidth(140)
	char:SetScript("OnClick", function()
		local chars = GM.Ledger.Chars()
		if #chars < 2 then return end
		for i, ck in ipairs(chars) do
			if ck == ViewChar() then
				ui.viewChar = chars[i % #chars + 1]
				break
			end
		end
		ui.scroll = 0
		OV.Refresh()
	end)
	ui.charBtn = char

	-- ===== left nav =====
	local nav = Panel(f, 10, -34, 110, 516, "PAGES")
	ui.navBtns = {}
	for i, p in ipairs(PAGES) do
		local b = CreateFrame("Button", nil, nav)
		b:SetSize(96, 20)
		b:SetPoint("TOPLEFT", 7, -22 - (i - 1) * 24)
		b.text = GM.MakeFontString(b, GM.FONT_BOLD, 10, "textDim")
		b.text:SetPoint("LEFT", 8, 0)
		b.text:SetText(p[1])
		local key = p[2]
		b:SetScript("OnClick", function()
			ui.page = key
			OV.Refresh()
		end)
		ui.navBtns[i] = { btn = b, key = key }
	end

	-- ===== content host =====
	local host = CreateFrame("Frame", nil, f)
	host:SetPoint("TOPLEFT", 126, -34)
	host:SetPoint("BOTTOMRIGHT", -10, 10)
	ui.host = host

	-- ============ GoblinUI managed layout ============
	-- the chrome was two hand-anchored rects: nav (10,-34, 110×516)
	-- and the content host filling 126,-34 .. -10,10. As one root
	-- row the same rects come out exactly (gap 6 reproduces the
	-- x=126 offset); page surfaces inside host keep their 0,0 rects
	-- and their own Show/Hide toggling.
	local u = GM.ui
	if u then
		local root = u:AttachRoot(f, { direction = "row", gap = 6,
			pad = { top = 34, left = 10, right = 10, bottom = 10 } })
		root:Add(u:Adopt(nav), { width = 110, height = "fill" })
		root:Add(u:Adopt(host), { width = "fill", height = "fill" })
	end

	-- ---- page: activity ----
	local actP = Panel(host, 0, 0, 724, 516, "ACTIVITY LOG")
	actP:EnableMouseWheel(true)
	actP:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		OV.RefreshLog()
	end)
	ui.pageActivity = actP
	ui.logRows = {}
	for i = 1, ROWS do
		local fs = GM.MakeFontString(actP, GM.FONT, 10, "text")
		fs:SetPoint("TOPLEFT", 10, -22 - (i - 1) * 23)
		fs:SetWidth(700)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		ui.logRows[i] = fs
	end

	-- ---- page: inventory ----
	local invP = Panel(host, 0, 0, 724, 516, "INVENTORY — STOCK BY VALUE")
	ui.pageInventory = invP
	ui.tInventory = MakeTable(invP, {
		{ "ITEM", 24, 240 }, { "BAGS+BANK", 270, 70 },
		{ "ELSEWHERE", 344, 80 }, { "PRICE", 430, 110 }, { "VALUE", 560, 120 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: sales ----
	local salP = Panel(host, 0, 0, 724, 516, "REVENUE — SALES")
	ui.pageSales = salP
	ui.tSales = MakeTable(salP, {
		{ "ITEM", 24, 240 }, { "SOLD", 270, 70 },
		{ "AVG PRICE", 350, 110 }, { "REVENUE", 480, 130 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: resale ----
	local resP = Panel(host, 0, 0, 724, 516, "REVENUE — RESALE (BUY→SELL MARGIN)")
	ui.pageResale = resP
	ui.tResale = MakeTable(resP, {
		{ "ITEM", 24, 220 }, { "SOLD", 250, 60 },
		{ "AVG BUY", 320, 110 }, { "AVG SELL", 440, 110 },
		{ "PROFIT", 570, 110 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: expenses ----
	local expP = Panel(host, 0, 0, 724, 516, "EXPENSES — PURCHASES")
	ui.pageExpenses = expP
	ui.tExpenses = MakeTable(expP, {
		{ "ITEM", 24, 240 }, { "BOUGHT", 270, 80 },
		{ "AVG PRICE", 360, 110 }, { "SPENT", 490, 130 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: failed ----
	local failP = Panel(host, 0, 0, 724, 516, "FAILED AUCTIONS")
	ui.pageFailed = failP
	ui.tFailed = MakeTable(failP, {
		{ "ITEM", 24, 240 }, { "EXPIRED", 280, 80 },
		{ "CANCELLED", 380, 90 }, { "FAIL RATE", 490, 90 },
	}, function(id) OV.ShowItem(id) end)

	-- ---- page: accounts (wealth + function controls) ----
	local acctP = Panel(host, 0, 0, 724, 516, "ACCOUNTS")
	ui.pageAccounts = acctP
	local chart = Panel(acctP, 6, -20, 712, 212, "WEALTH")
	if chart.SetClipsChildren then chart:SetClipsChildren(true) end
	ui.chart = chart
	ui.chartMsg = GM.MakeFontString(chart, GM.FONT, 10, "textDim")
	ui.chartMsg:SetPoint("CENTER", 0, -14)
	-- KPI strip: the <2s read — total wealth and its split, today's
	-- delta, the trend rate; the chart below is the drill-in
	ui.kpiTotal = GM.MakeFontString(chart, GM.FONT_BOLD, 13, "text")
	ui.kpiTotal:SetPoint("TOPLEFT", 10, -20)
	ui.kpiTotal:SetWordWrap(false)
	ui.kpiSplit = GM.MakeFontString(chart, GM.FONT, 9, "textDim")
	ui.kpiSplit:SetPoint("LEFT", ui.kpiTotal, "RIGHT", 10, -3)
	ui.kpiSplit:SetWordWrap(false)
	ui.kpiDelta = GM.MakeFontString(chart, GM.FONT, 9, "textDim")
	ui.kpiDelta:SetPoint("TOPLEFT", 10, -40)
	ui.kpiDelta:SetWordWrap(false)
	ui.kpiFlow = GM.MakeFontString(chart, GM.FONT, 8, "textDim")
	ui.kpiFlow:SetPoint("BOTTOM", chart, "BOTTOM", 0, 6)
	ui.kpiFlow:SetWordWrap(false)
	ui.kpiLedger = GM.MakeFontString(chart, GM.FONT, 8, "textDim")
	ui.kpiLedger:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 8, 6)
	ui.kpiLedger:SetWordWrap(false)
	-- window segments: filter the sampled window (ALL = whole buffer)
	ui.chartWin = "ALL"
	ui.winSegs = {}
	local L = GM.L or function(s) return s end
	-- L() at the literal site — a table of labels feeding Segment()
	-- is invisible to the locale extractor
	local wins = { L("24H"), L("7D"), L("ALL") }
	for i, lab in ipairs(wins) do
		local seg = W.Segment(chart, lab, 34, 16)
		seg:SetPoint("TOPRIGHT", -10 - (#wins - i) * 38, -20)
		seg:SetScript("OnClick", function()
			ui.chartWin = lab
			for j, s in ipairs(ui.winSegs) do
				W.PaintSeg(s, wins[j] == lab)
			end
			OV.RefreshChart()
		end)
		ui.winSegs[i] = seg
		W.PaintSeg(seg, lab == "ALL")
	end
	local accts, acctT = Panel(acctP, 6, -240, 712, 270,
		"ACCOUNTS · FUNCTION")
	ui.acctTitle = acctT
	-- view toggle: budget accounts vs the double-entry journal —
	-- one panel, same char filter; journal rows carry each tx's
	-- debit/credit legs so the books read back
	ui.acctView = "accounts"
	ui.jScroll = 0
	ui.acctSegs = {}
	local avs = { L("ACCOUNTS"), L("JOURNAL") }
	for i, lab in ipairs(avs) do
		local seg = W.Segment(accts, lab, 72, 16)
		-- in the title band, not the row area — at -20 they sat ON
		-- the first account row's in/out column
		seg:SetPoint("TOPRIGHT", -10 - (#avs - i) * 76, -4)
		local idx = i
		seg:SetScript("OnClick", function()
			ui.acctView = idx == 2 and "journal" or "accounts"
			for j, s in ipairs(ui.acctSegs) do
				W.PaintSeg(s, j == idx)
			end
			RefreshAccounts()
		end)
		ui.acctSegs[i] = seg
		W.PaintSeg(seg, i == 1)
	end
	-- accounts-mode strip: combined gold across every registered
	-- char — the journal's balance line lives in the same slot
	ui.acctGold = GM.MakeFontString(accts, GM.FONT, 9, "secondary")
	ui.acctGold:SetPoint("TOPLEFT", 8, -20)
	ui.acctGold:SetWordWrap(false)
	ui.journalBal = GM.MakeFontString(accts, GM.FONT, 9, "secondary")
	ui.journalBal:SetPoint("TOPLEFT", 8, -20)
	ui.journalBal:SetWordWrap(false)
	-- column geometry shared by the header and every row
	-- L() at the literal site — variable-fed L(c[1]) registers
	-- nothing for the extractor
	local JC = {
		{ L("TIME"), 8, 44 }, { L("TX"), 56, 62 },
		{ L("ITEM"), 122, 192 },
		{ L("DR"), 316, 190 }, { L("CR"), 508, 188 },
	}
	ui.journalCols = {}
	for _, c in ipairs(JC) do
		local fs = GM.MakeFontString(accts, GM.FONT_BOLD, 8, "secondary")
		fs:SetPoint("TOPLEFT", c[2], -38)
		fs:SetWidth(c[3])
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		fs:SetText(c[1])
		ui.journalCols[#ui.journalCols + 1] = fs
	end
	ui.journalRows = {}
	for i = 1, 9 do
		local r, y = {}, -54 - (i - 1) * 22
		for j, c in ipairs(JC) do
			local fs = GM.MakeFontString(accts, GM.FONT, 9, "textDim")
			fs:SetPoint("TOPLEFT", c[2], y)
			fs:SetWidth(c[3])
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			r[j] = fs
		end
		ui.journalRows[i] = r
	end
	-- wheel scrubs: back through the journal in journal view, down
	-- the combined account list in accounts view
	accts:EnableMouseWheel(true)
	accts:SetScript("OnMouseWheel", function(_, d)
		if ui.acctView == "journal" then
			ui.jScroll = math.max(0, ui.jScroll - d * 3)
			RefreshAccounts()
		else
			ui.aScroll = math.max(0, (ui.aScroll or 0) - d * 2)
			RefreshAccounts()
		end
	end)
	-- add-row rides the strip right under the gold line — anchored
	-- to the panel top so the create affordance can never sit below
	-- a clipped or crowded fold
	ui.acctAdd = W.AcctAdd(accts)
	ui.acctAdd:SetPoint("TOPLEFT", 8, -36)
	ui.acctRows = {}
	local ACCT_ROWS = 7
	for i = 1, ACCT_ROWS do
		local row = W.AcctRow(accts, i, false)
		row:SetPoint("TOPLEFT", 8, -64 - (i - 1) * 26)
		row:SetWidth(696)
		ui.acctRows[i] = row
	end
	-- onboarding line: shows only while the auto-seeded pool is the
	-- whole list — it sits in the empty row slot under the pool
	ui.acctOnboard = GM.MakeFontString(accts, GM.FONT, 9, "secondary")
	ui.acctOnboard:SetPoint("TOPLEFT", 8, -94)
	ui.acctOnboard:SetWordWrap(false)
	ui.acctOnboard:SetText("create an account above to earmark gold — "
		.. "e.g. a 10% SAVE or an AH float")
	ui.acctHint = GM.MakeFontString(accts, GM.FONT, 9, "secondary")
	ui.acctHint:SetPoint("BOTTOMLEFT", 10, 6)
	ui.acctHint:SetText(
		"kind: spend pool / reserve · group: items route to this account · "
		.. "right column: 7-day in/out")

	-- ---- page: item detail (drill-in) ----
	local itP = Panel(host, 0, 0, 724, 516, "ITEM")
	ui.pageItem = itP
	itP.icon = itP:CreateTexture(nil, "ARTWORK")
	itP.icon:SetSize(32, 32)
	itP.icon:SetPoint("TOPLEFT", 12, -26)
	-- icon cover: hover = item tooltip, modified click = Blizzard's
	-- item action (ctrl+click dress-up, shift+click chat link)
	itP.iconBtn = CreateFrame("Button", nil, itP)
	itP.iconBtn:SetAllPoints(itP.icon)
	itP.iconBtn:SetScript("OnEnter", function(self)
		if not ui.itemID then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(ui.itemID)
		else
			GameTooltip:SetHyperlink("item:" .. ui.itemID)
		end
		GameTooltip:Show()
	end)
	itP.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	itP.iconBtn:SetScript("OnClick", function()
		if IsModifiedClick() and ui.itemID then
			GM.Ops.Click(ui.itemID)
		end
	end)
	itP.name = GM.MakeFontString(itP, GM.FONT_BOLD, 13, "text")
	itP.name:SetPoint("LEFT", itP.icon, "RIGHT", 10, 10)
	itP.name:SetWidth(560)
	itP.name:SetJustifyH("LEFT")
	itP.name:SetWordWrap(false)
	itP.mkt = GM.MakeFontString(itP, GM.FONT, 10, "textDim")
	itP.mkt:SetPoint("TOPLEFT", itP.name, "BOTTOMLEFT", 0, -6)
	itP.mkt:SetWidth(560)
	itP.mkt:SetJustifyH("LEFT")
	itP.mkt:SetWordWrap(false)
	itP.back = CreateFrame("Button", nil, itP)
	itP.back:SetSize(56, 18)
	itP.back:SetPoint("TOPRIGHT", -10, -22)
	GM.Panel(itP.back, "contHigh")
	itP.back.text = GM.MakeFontString(itP.back, GM.FONT_MED, 9, "textDim")
	itP.back.text:SetPoint("CENTER")
	itP.back.text:SetText("« BACK")
	itP.back:SetScript("OnClick", function()
		ui.page = ui.prevPage or "activity"
		OV.Refresh()
	end)
	itP.target = CreateFrame("Button", nil, itP)
	itP.target:SetSize(70, 18)
	itP.target:SetPoint("RIGHT", itP.back, "LEFT", -6, 0)
	GM.Panel(itP.target, "contHigh")
	itP.target.text = GM.MakeFontString(itP.target, GM.FONT_MED, 9, "textDim")
	itP.target.text:SetPoint("CENTER")
	itP.target.text:SetText("TARGET")
	itP.target:SetScript("OnClick", function()
		if ui.itemID then
			GM.PlanQueue.SetItem(ui.itemID)
			GM.PlanQueue.Show()
		end
	end)
	itP.stats = GM.MakeFontString(itP, GM.FONT, 10, "text")
	itP.stats:SetPoint("TOPLEFT", 12, -74)
	itP.stats:SetWidth(330)
	itP.stats:SetJustifyH("LEFT")
	itP.stats:SetSpacing(4)
	itP.txTitle = GM.MakeFontString(itP, GM.FONT_BOLD, 9, "secondary")
	itP.txTitle:SetPoint("TOPLEFT", 360, -74)
	itP.txTitle:SetText("RECENT TRANSACTIONS")
	itP.txRows = {}
	for i = 1, 18 do
		local fs = GM.MakeFontString(itP, GM.FONT, 9, "textDim")
		fs:SetPoint("TOPLEFT", 360, -90 - (i - 1) * 21)
		fs:SetWidth(350)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		itP.txRows[i] = fs
	end
end

-- ============ item detail ============

function OV.ShowItem(id)
	ui.itemID = id
	ui.prevPage = ui.page ~= "item" and ui.page or ui.prevPage
	ui.page = "item"
	OV.Refresh()
end

local function RefreshItem()
	local itP, id = ui.pageItem, ui.itemID
	if not id then return end
	itP.icon:SetTexture(GM.ItemIcon and GM.ItemIcon(id)
		or "Interface\\Icons\\INV_Misc_QuestionMark")
	itP.name:SetText(ItemName(id))
	itP.name:SetTextColor(GM.NameColor(id))
	local e = GM.ItemEntry(id)
	local m = GM.Price("dbmarket", id)
	itP.mkt:SetText(m and ("market " .. GM.Money(m)) or "no market data")

	-- account-global aggregates (itemStats is shared by design)
	local s = GM.Ledger.Stats(id)
	local c = GM.Inventory.Count(id)
	local lines = {
		format("on hand: %d  (bags %d · bank %d · mail %d · gbank %d · ah %d)",
			c.total, c.bags, c.bank, c.mail, c.guild, c.auction),
	}
	if s then
		if s.buyQ > 0 then
			lines[#lines + 1] = format("bought ×%d @ %s avg  (%s – %s)",
				s.buyQ, GM.Money(s.buyAvg or 0),
				GM.Money(s.buyMin or 0), GM.Money(s.buyMax or 0))
		end
		if s.sellQ > 0 then
			lines[#lines + 1] = format("sold ×%d @ %s avg  (%s – %s)",
				s.sellQ, GM.Money(s.sellAvg or 0),
				GM.Money(s.sellMin or 0), GM.Money(s.sellMax or 0))
		end
		local paid = GM.Ledger.Avg(id, "paid")
		if paid then
			lines[#lines + 1] = "stock cost basis " .. GM.Money(paid)
		end
		if s.saleRate then
			lines[#lines + 1] = format("sale rate %.0f%% · cancels %d · expires %d",
				s.saleRate * 100, s.cancelSinceSell, s.expireSinceSell)
		end
	else
		lines[#lines + 1] = "no ledger history"
	end
	itP.stats:SetText(table.concat(lines, "\n"))

	-- this char's recent txs for the item, newest first
	local n = 0
	local tx = GM.Ledger.TxFor(ViewChar())
	for i = #tx, 1, -1 do
		local e = tx[i]
		if e.i == id then
			n = n + 1
			if n <= #itP.txRows then
				itP.txRows[n]:SetText(format("%s  %s%s ×%d%s",
					date("%b %d %H:%M", e.t),
					e.ty == "sell" and GM.CC("pos") or
						e.ty == "buy" and GM.CC("warn") or GM.CC("textDim"),
					TX_LABEL[e.ty] or e.ty, e.q,
					e.u and (" @ " .. GM.Money(e.u)) or ""))
			end
		end
	end
	for i = n + 1, #itP.txRows do itP.txRows[i]:SetText("") end
end

-- ============ refresh ============

-- view-model for the registry's Data() pass — the viewed char plus
-- only the ACTIVE page's row set (each Build* scans the ledger —
-- computing all six every refresh pays 5 dead scans)
local function Data()
	local vm = { char = ViewChar() }
	local p = ui.page
	if p == "inventory" then
		vm.list, vm.total = BuildInventory()
	elseif p == "sales" then
		vm.list, vm.total = BuildSales(TxAgg(vm.char))
	elseif p == "resale" then
		vm.list, vm.total = BuildResale(TxAgg(vm.char))
	elseif p == "expenses" then
		vm.list, vm.total = BuildExpenses(TxAgg(vm.char))
	elseif p == "failed" then
		vm.list = BuildFailed(TxAgg(vm.char))
	elseif p == "activity" then
		vm.list = DisplayList(vm.char)
	end
	return vm
end

function OV.Refresh(vm)
	if not ui then return end
	vm = vm or Data()
	ui.charBtn.text:SetText(
		(vm.char or "?"):match("^[^-]+") or vm.char or "?")
	for _, nb in ipairs(ui.navBtns) do
		nb.btn.text:SetTextColor(GM.RGB(
			nb.key == ui.page and "accent" or "textDim"))
	end
	ui.pageActivity:SetShown(ui.page == "activity")
	ui.pageInventory:SetShown(ui.page == "inventory")
	ui.pageSales:SetShown(ui.page == "sales")
	ui.pageResale:SetShown(ui.page == "resale")
	ui.pageExpenses:SetShown(ui.page == "expenses")
	ui.pageFailed:SetShown(ui.page == "failed")
	ui.pageAccounts:SetShown(ui.page == "accounts")
	ui.pageItem:SetShown(ui.page == "item")

	if ui.page == "activity" then
		OV.RefreshLog(vm)
	elseif ui.page == "inventory" then
		ui.tInventory.list, ui.tInventory.total = vm.list, vm.total
		ui.tInventory.footer:SetText(
			format("%d items · stock value %s%s", #ui.tInventory.list,
				GM.Money(ui.tInventory.total),
				(BankFrame and BankFrame:IsShown()) and ""
					or " · bank counts while open only"))
		ui.tInventory.paint()
	elseif ui.page == "sales" then
		ui.tSales.list, ui.tSales.total = vm.list, vm.total
		ui.tSales.footer:SetText(format("%d items · revenue %s",
			#ui.tSales.list, GM.Money(ui.tSales.total)))
		ui.tSales.paint()
	elseif ui.page == "resale" then
		ui.tResale.list, ui.tResale.total = vm.list, vm.total
		ui.tResale.footer:SetText(format("%d items · profit %s",
			#ui.tResale.list, GM.Money(ui.tResale.total)))
		ui.tResale.paint()
	elseif ui.page == "expenses" then
		ui.tExpenses.list, ui.tExpenses.total = vm.list, vm.total
		ui.tExpenses.footer:SetText(format("%d items · spent %s",
			#ui.tExpenses.list, GM.Money(ui.tExpenses.total)))
		ui.tExpenses.paint()
	elseif ui.page == "failed" then
		ui.tFailed.list = vm.list
		ui.tFailed.footer:SetText(format("%d items with failed auctions",
			#ui.tFailed.list))
		ui.tFailed.paint()
	elseif ui.page == "accounts" then
		OV.RefreshChart()
		RefreshAccounts()
	elseif ui.page == "item" then
		RefreshItem()
	end
end

function OV.Show()
	Build()
	ui.frame:Show()
	OV.Refresh()
	-- live refresh while open — ledger txs and budget samples land
	-- asynchronously (mail sales, timer sampler)
	local function tick()
		if ui.frame:IsShown() then
			OV.Refresh()
			GM.Time.After(5, tick)
		end
	end
	GM.Time.After(5, tick)
end

function OV.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function OV.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else OV.Show() end
end

GM.View.Register("overview", {
	Show = OV.Show, Hide = OV.Hide, Toggle = OV.Toggle,
	Data = Data,
	Refresh = OV.Refresh,
	IsShown = function() return ui and ui.frame and ui.frame:IsShown() end })
