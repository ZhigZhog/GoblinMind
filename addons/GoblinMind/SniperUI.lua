local _, GM = ...

-- coin-colored short money — the shared formatter
local SM = GM.MoneyShort
local W = GM.Widgets

local function TlStr(s)
	if not s or s <= 0 then return "—" end
	if s >= 86400 then
		local rem = s % 86400
		return rem >= 3600 and format("%dd%dh", s / 86400, rem / 3600)
			or format("%dd", s / 86400)
	end
	if s >= 3600 then return format("%dh%dm", s / 3600, (s % 3600) / 60) end
	if s >= 60 then return format("%dm", s / 60) end
	return s .. "s"
end

-- Sniper feed window (/goblin snipe). GM.Sniper diffs the shared AH
-- book for under-priced listings; this window is the feed surface —
-- hits stream in on every snapshot (manual or the auto loop) and each
-- row runs the detection→live-check→buy flow from Shopping.BuyHit:
-- click 1 re-queries the item's book, click 2 buys the matching
-- listing. Commodity hits stage a quote → a third CONFIRM click.
-- All buys stay one protected call per hardware event.

GM.SniperUI = {}
local SU = GM.SniperUI
local ui

local ROW_H = 24
local VISIBLE = 13

local Btn = W.Btn
local Tip = W.Tip

local function AHOpen() return GM.AH.open == true end

-- ============ window ============

local function Build()
	if ui then return end
	-- filters live on GM.Sniper (Sniper.lua loads first) so the task
	-- surfaces count the same actionable feed this window shows
	ui = { scroll = 0, filters = GM.Sniper.filters }
	local f = GM.Widgets.Window({
		name = "GoblinMindSniper", title = "SNIPER",
		w = 680, h = 400, x = 120,
	})
	ui.frame = f

	-- hit state changes come from Sniper's book-diff passes
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_SHOW")
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_CLOSED")
	f:SetScript("OnEvent", SU.Refresh)

	-- toolbar: scan controls + feed management
	ui.snap = Btn(f, 88, "SNAPSHOT", function()
		GM.Sniper.Scan()
		SU.Refresh()
	end)
	Tip(ui.snap, function()
		return { "Book snapshot",
			"ReplicateItems dumps the full auction book and diffs",
			"it against the last snapshot — new listings priced under",
			"the sniper op threshold become hits." }
	end)
	ui.auto = Btn(f, 52, "AUTO", function()
		ui.autoOn = not ui.autoOn
		if ui.autoOn then GM.Sniper.StartAuto() end
		SU.Refresh()
	end)
	Tip(ui.auto, function()
		return { "Auto snapshots",
			"Repeats the snapshot on the sniper op's refreshTime",
			"(5-minute floor) while this window is open." }
	end)
	ui.clear = Btn(f, 92, "CLEAR DONE", function()
		local hits = GM.Sniper.hits
		for i = #hits, 1, -1 do
			if hits[i].done then tremove(hits, i) end
		end
		SU.Refresh()
	end)
	-- feed filters: GOLD = only what we can pay for (bid or buyout),
	-- BID = only listings that accept bids (non-commodity item rows)
	ui.gold = Btn(f, 56, "GOLD", function()
		ui.filters.gold = not ui.filters.gold or nil
		SU.Refresh()
	end)
	Tip(ui.gold, function()
		return { "Affordable only",
			"Hides hits where both the buyout and the bid price",
			"exceed the gold on this character." }
	end)
	ui.bid = Btn(f, 52, "BID", function()
		ui.filters.bid = not ui.filters.bid or nil
		SU.Refresh()
	end)
	Tip(ui.bid, function()
		return { "Biddable only",
			"Hides listings with no bid path — commodities and",
			"buy-out-only rows can't take the +1c bid flow." }
	end)
	ui.soon = Btn(f, 52, "SOON", function()
		ui.filters.soon = not ui.filters.soon or nil
		SU.Refresh()
	end)
	Tip(ui.soon, function()
		return { "Expiring soon only",
			"Hides listings with more than 2h left — sniping is",
			"about grabbing underpriced lots before they expire,",
			"not watching 48h walls. Toggle off for the raw feed." }
	end)

	-- column header
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(656, 16)
	for _, h in ipairs({
		{ "ITEM", 8 }, { "QTY", 252 }, { "BID", 296 },
		{ "UNIT", 364 }, { "TIME", 432 }, { "CAP", 474 },
		{ "%MKT", 540 },
	}) do
		local fs = GM.MakeFontString(hdr, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("LEFT", h[2], 0)
		fs:SetText(h[1])
	end
	ui.count = GM.MakeFontString(hdr, GM.FONT, 9, "textDim")
	ui.count:SetPoint("RIGHT", -2, 0)

	-- feed
	local host = CreateFrame("Frame", nil, f)
	if host.SetClipsChildren then host:SetClipsChildren(true) end
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		SU.Refresh()
	end)
	ui.host = host

	ui.rows = {}
	for i = 1, VISIBLE do
		local row = W.ColumnRow(host, {
			h = ROW_H - 2, w = 648, icon = 18, nameW = 214,
			cols = {
				{ key = "qty", x = 252, w = 38 },
				{ key = "bid", x = 296, w = 64, maxLines = 1 },
				{ key = "unit", x = 364, w = 64, color = "accent",
					maxLines = 1 },
				{ key = "tl", x = 432, w = 36, size = 9,
					color = "textDim", maxLines = 1 },
				{ key = "cap", x = 474, w = 60, size = 9,
					color = "textDim", maxLines = 1 },
				{ key = "pct", x = 540, w = 44, font = GM.FONT_BOLD,
					color = "pos", maxLines = 1 },
				-- flow state marker (… · CONFIRM · BUY/BID)
				{ key = "state", right = true, x = -22, size = 8,
					font = GM.FONT_BOLD, color = "accent" },
			},
		})
		row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
		row:SetZebra(i)
		-- the +1c bid gesture lives on the bid cell: PlaceBid is a
		-- protected call and a double-click's timer defer isn't a
		-- hardware event, so the upgrade moved off the row click
		local bidBtn = CreateFrame("Button", nil, row)
		bidBtn:SetPoint("LEFT", 296, 0)
		bidBtn:SetSize(64, ROW_H - 2)
		W.HoverTint(bidBtn) -- the only visible affordance the cell has
		row.bidBtn = bidBtn
		-- dismiss: drop the hit without buying
		local x = W.XBtn(row)
		x:SetPoint("RIGHT", -3, 0)
		row.x = x
		ui.rows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
	ui.foot:SetText("click = buy flow · BID cell = bid +1c · "
		.. "shift-click = plan · x dismisses · deepest discount sorts first")

	-- ============ layout wiring ============
	-- toolbar row over the column header over the fill-size feed;
	-- the footer stays hand-anchored below the managed region
	local u = GM.ui
	local root = u:AttachRoot(f, {
		direction = "column", gap = "xs",
		pad = { top = 34, right = 12, bottom = 4, left = 12 },
	})
	local bar = u:Row(root, { gap = 6 })
	root:Add(bar, { height = 22 })
	local function BarBtn(fr, w)
		bar:Add(u:Adopt(fr, { width = w, height = 20 }),
			{ width = w, height = 20, align = "center" })
	end
	BarBtn(ui.snap, 88) BarBtn(ui.auto, 52) BarBtn(ui.clear, 92)
	BarBtn(ui.gold, 56) BarBtn(ui.bid, 52) BarBtn(ui.soon, 52)
	ui.status = u:Text(bar, { style = "caption", wrap = false })
	bar:Add(ui.status, { width = "fill", align = "center" })
	root:Add(u:Adopt(hdr, { width = 656, height = 16 }),
		{ height = 16 })
	root:Add(u:Adopt(host, { width = 656, height = VISIBLE * ROW_H + 4 }),
		{ width = "fill", height = "fill" })
end

-- ============ refresh ============

-- filter predicate lives on GM.Sniper — the Dashboard/TaskList read
-- the same actionable set this window renders
local PassFilters = GM.Sniper.PassFilters

function SU.Refresh()
	if not ui then return end
	local open = AHOpen()
	ui.snap:SetEnabled(open)
	local autoLive = GM.Sniper.AutoRunning and GM.Sniper.AutoRunning()
	ui.autoOn = ui.autoOn and autoLive
	ui.auto.text:SetText((ui.autoOn or autoLive) and "AUTO ON" or "AUTO")
	ui.auto.text:SetTextColor(GM.RGB(
		(ui.autoOn or autoLive) and "accent" or "textDim"))
	ui.gold.text:SetTextColor(GM.RGB(ui.filters.gold and "accent" or "textDim"))
	ui.bid.text:SetTextColor(GM.RGB(ui.filters.bid and "accent" or "textDim"))
	ui.soon.text:SetTextColor(GM.RGB(ui.filters.soon and "accent" or "textDim"))

	-- collapse same-item listings into one row — hits are sorted
	-- cheapest-first, so the first per itemID is the representative;
	-- siblings count toward the ×N badge and resurface after it clears
	local hits, seen, raw = {}, {}, 0
	for _, h in ipairs(GM.Sniper.hits or {}) do
		if not h.done then
			raw = raw + 1
			if PassFilters(h) then
				local id = h.itemID or h.name
				if seen[id] then
					seen[id]._n = (seen[id]._n or 1) + 1
				else
					seen[id] = h
					hits[#hits + 1] = h
				end
			end
		end
	end
	local last = GM.Sniper.lastT
	ui.status:SetText(format("%d hit%s%s%s%s", #hits,
		#hits == 1 and "" or "s",
		raw > #hits and format(" · %d filtered", raw - #hits) or "",
		last and last > 0 and format(" · snapshot %ds ago",
			math.max(0, GetTime() - last)) or "",
		not open and " · AH closed" or ""))

	ui.empty:SetText(open
		and (raw > 0
			and "all hits filtered — toggle SOON/GOLD/BID to widen the feed"
			or "no hits — SNAPSHOT diffs the book for under-priced listings")
		or "open the auction house — sniper scans need the AH session")
	ui.empty:SetShown(#hits == 0)

	local maxScroll = math.max(0, #hits - VISIBLE)
	ui.scroll = math.min(ui.scroll or 0, maxScroll)
	W.ScrollText(ui.count, ui.scroll, VISIBLE, #hits)

	-- one bad hit must never kill the feed — paint each row in a
	-- pcall (the same rule the hit eval uses: a field the client
	-- can't resolve must hide its row, not every row after it)
	local function PaintRow(row, h)
		row:Show()
			row:SetItem({ itemID = h.itemID, name = h.name })
			local flags = GM.Intel and GM.Intel.FlagsFor(h)
			local nm = GM.Ctx(h).name
				or (type(h.name) == "string" and h.name ~= ""
					and h.name)
				or ("item " .. (h.itemID or "?"))
			row.name:SetText(nm
				.. (flags and (" " .. GM.CC("warn") .. flags .. "|r") or "")
				.. (h._n and h._n > 1
					and GM.CC("textDim") .. " ×" .. h._n .. "|r" or ""))
			-- unresolvable ids get no client quality — read it off
			-- the link's cnIQ tag instead of falling back to plain
			local q = GM.ItemQuality(h.itemID)
				or GM.LinkQuality(h.link)
			local qr, qg, qb = GM.QualityColor(q)
			-- `qr or GM.RGB("text")` truncates the RGB triple to
			-- one arg — SetTextColor throws and kills the repaint
			if qr then row.name:SetTextColor(qr, qg, qb)
			else row.name:SetTextColor(GM.RGB("text")) end
			row.qty:SetText("×" .. (h.qty or 1))
			-- live ask data wins once armed; snapshot fields otherwise
			local live = h.live or {}
			row.bid:SetText(live.bid and SM(live.bid)
				or h.bid and h.bid > 0 and SM(h.bid) or "—")
			row.unit:SetText(SM(h.unit or 0))
			-- exact live seconds when armed, else our tracked estimate
			-- (~ = guessed expiry, refines on bucket crossings).
			-- live.tl must be > 0 — a 0 is truthy in Lua but means
			-- "field unpopulated" here, not "expires now"
			local estSec = h.tlex and math.max(0, h.tlex - GetTime())
			row.tl:SetText(
				(live.tl and live.tl > 0 and TlStr(live.tl))
				or (estSec and estSec > 0 and ("~" .. TlStr(estSec)))
				or TlStr(h.tl))
			row.cap:SetText(SM(h.cap))
			row.pct:SetText(h.pct and format("%.0f%%", h.pct) or "—")
			row.pct:SetTextColor(GM.RGB(
				h.pct and h.pct <= 50 and "pos" or "text"))
			row.state:SetText(h.state == "scanning" and "…"
				or h.state == "staged" and "CONFIRM"
				or h.state == "ready" and (h.wantBid and "BID" or "BUY")
				or "")
			row.state:SetTextColor(GM.RGB(h.state == "staged" and "warn"
				or h.state == "ready" and "accent" or "textDim"))
			local hit = h
			row.x:SetScript("OnClick", function()
				hit.done = true
				SU.Refresh()
			end)
			row.bidBtn:SetScript("OnClick", function()
				GM.Shopping.BidHit(hit)
				SU.Refresh()
			end)
			row:SetScript("OnClick", function(_, btn)
				if btn == "RightButton" then
					if h.itemID then GM.TargetItem(h.itemID) end
					return
				end
				-- modified click = Blizzard's item action — the
				-- widget's hook already ran it on mousedown; just
				-- keep it out of the buy path
				if IsModifiedClick() then return end
				-- no defer — this click IS the hardware event the
				-- protected buy call needs
				GM.Shopping.BuyHit(hit)
				SU.Refresh()
			end)
	end

	for i = 1, VISIBLE do
		local row, h = ui.rows[i], hits[i + ui.scroll]
		if h then
			-- a row that throws hides itself — the feed survives
			if not pcall(PaintRow, row, h) then row:Hide() end
		else
			row:Hide()
		end
	end
end

-- ============ open/close ============

function SU.IsOpen()
	return ui and ui.frame:IsShown() or false
end

function SU.Show()
	Build()
	ui.frame:Show()
	SU.Refresh()
end

function SU.Hide()
	if ui then ui.frame:Hide() end
end

function SU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else SU.Show() end
end

-- repaint when async item names/icons land — hits snapshot before
-- the cache warms so rows need a refresh on GET_ITEM_INFO_RECEIVED
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame:IsShown() then SU.Refresh() end
	end)
end

GM.View.Register("sniper", { class = "contextual",
	Show = SU.Show, Hide = SU.Hide, Toggle = SU.Toggle,
	Refresh = SU.Refresh, IsShown = SU.IsOpen })
