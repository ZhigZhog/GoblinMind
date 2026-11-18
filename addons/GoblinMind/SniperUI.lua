local _, GM = ...

local function SM(v)
	if not v then return "—" end
	local g = v / 10000
	if g >= 1000 then
		local s = format("%.0fkg", g / 1000)
		return s
	elseif g >= 1 then
		return format("%dg %ds", floor(g), floor(v % 10000 / 100))
	elseif v >= 100 then
		return format("%ds", floor(v / 100))
	end
	return format("%dc", floor(v))
end
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
	local f = CreateFrame("Frame", "GoblinMindSniper", UIParent)
	f:SetSize(680, 400)
	f:SetPoint("CENTER", 120, 0)
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
	tinsert(UISpecialFrames, "GoblinMindSniper")
	ui.frame = f

	-- hit state changes come from Sniper's book-diff passes
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_SHOW")
	pcall(f.RegisterEvent, f, "AUCTION_HOUSE_CLOSED")
	f:SetScript("OnEvent", SU.Refresh)

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("SNIPER")

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- toolbar: scan controls + feed management
	ui.snap = Btn(f, 88, "SNAPSHOT", function()
		GM.Sniper.Scan()
		SU.Refresh()
	end)
	ui.snap:SetPoint("TOPLEFT", 12, -34)
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
	ui.auto:SetPoint("LEFT", ui.snap, "RIGHT", 6, 0)
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
	ui.clear:SetPoint("LEFT", ui.auto, "RIGHT", 6, 0)
	-- feed filters: GOLD = only what we can pay for (bid or buyout),
	-- BID = only listings that accept bids (non-commodity item rows)
	ui.gold = Btn(f, 56, "GOLD", function()
		ui.filters.gold = not ui.filters.gold or nil
		SU.Refresh()
	end)
	ui.gold:SetPoint("LEFT", ui.clear, "RIGHT", 6, 0)
	Tip(ui.gold, function()
		return { "Affordable only",
			"Hides hits where both the buyout and the bid price",
			"exceed the gold on this character." }
	end)
	ui.bid = Btn(f, 52, "BID", function()
		ui.filters.bid = not ui.filters.bid or nil
		SU.Refresh()
	end)
	ui.bid:SetPoint("LEFT", ui.gold, "RIGHT", 6, 0)
	Tip(ui.bid, function()
		return { "Biddable only",
			"Hides listings with no bid path — commodities and",
			"buy-out-only rows can't take the +1c bid flow." }
	end)
	ui.soon = Btn(f, 52, "SOON", function()
		ui.filters.soon = not ui.filters.soon or nil
		SU.Refresh()
	end)
	ui.soon:SetPoint("LEFT", ui.bid, "RIGHT", 6, 0)
	Tip(ui.soon, function()
		return { "Expiring soon only",
			"Hides listings with more than 2h left — sniping is",
			"about grabbing underpriced lots before they expire,",
			"not watching 48h walls. Toggle off for the raw feed." }
	end)
	ui.status = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.status:SetPoint("LEFT", ui.soon, "RIGHT", 10, 0)
	ui.status:SetJustifyH("LEFT")

	-- column header
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(656, 16)
	hdr:SetPoint("TOPLEFT", 12, -60)
	ui.status:SetWidth(320)
	ui.status:SetJustifyH("LEFT")
	ui.status:SetWordWrap(false)
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
	host:SetSize(656, VISIBLE * ROW_H + 4)
	host:SetPoint("TOPLEFT", 12, -78)
	if host.SetClipsChildren then host:SetClipsChildren(true) end
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		SU.Refresh()
	end)
	ui.host = host

	ui.rows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, host)
		row:SetSize(648, ROW_H - 2)
		row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 28, 0)
		row.name:SetWidth(214)
		row.name:SetJustifyH("LEFT")
		row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.qty:SetPoint("LEFT", 252, 0)
		row.qty:SetWidth(38)
		row.qty:SetJustifyH("LEFT")
		row.qty:SetWordWrap(false)
		row.bid = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.bid:SetPoint("LEFT", 296, 0)
		row.bid:SetWidth(64)
		row.name:SetWordWrap(false)
		row.bid:SetMaxLines(1)
		row.unit = GM.MakeFontString(row, GM.FONT, 10, "accent")
		row.unit:SetPoint("LEFT", 364, 0)
		row.unit:SetWidth(64)
		row.unit:SetMaxLines(1)
		row.tl = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.tl:SetPoint("LEFT", 432, 0)
		row.tl:SetWidth(36)
		row.tl:SetMaxLines(1)
		row.cap = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.cap:SetPoint("LEFT", 474, 0)
		row.cap:SetWidth(60)
		row.cap:SetMaxLines(1)
		row.pct = GM.MakeFontString(row, GM.FONT_BOLD, 10, "pos")
		row.pct:SetPoint("LEFT", 540, 0)
		row.pct:SetWidth(44)
		row.pct:SetMaxLines(1)
		-- state marker replaces the old SCAN/BUY button: shows where
		-- the hit sits in the flow (… scanning · BUY armed · BID armed)
		row.state = GM.MakeFontString(row, GM.FONT_BOLD, 8, "accent")
		row.state:SetPoint("RIGHT", -22, 0)
		-- dismiss: drop the hit without buying
		local x = CreateFrame("Button", nil, row)
		x:SetSize(14, 14)
		x:SetPoint("RIGHT", -3, 0)
		x.text = GM.MakeFontString(x, GM.FONT_BOLD, 10, "textDim")
		x.text:SetPoint("CENTER")
		x.text:SetText("x")
		x:SetScript("OnEnter", function() x.text:SetTextColor(GM.RGB("err")) end)
		x:SetScript("OnLeave", function() x.text:SetTextColor(GM.RGB("textDim")) end)
		row.x = x
		row:SetScript("OnEnter", function(self)
			if self.tipID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.tipID)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.rows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
	ui.foot:SetText("click = buy flow · double-click = bid +1c · "
		.. "shift-click = plan · x dismisses · deepest discount sorts first")
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

	for i = 1, VISIBLE do
		local row, h = ui.rows[i], hits[i + ui.scroll]
		if h then
			row:Show()
			row.tipID = h.itemID
			row.icon:SetTexture(h.itemID and GM.ItemIcon(h.itemID) or 134400)
			local flags = GM.Intel and GM.Intel.FlagsFor(h)
			row.name:SetText((GM.ItemName(h.itemID) or h.name
				or ("item " .. (h.itemID or "?")))
				.. (flags and (" " .. GM.CC("warn") .. flags .. "|r") or "")
				.. (h._n and h._n > 1
					and GM.CC("textDim") .. " ×" .. h._n .. "|r" or ""))
			row.name:SetTextColor(GM.NameColor(h.itemID))
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
			row:SetScript("OnClick", function(_, btn)
				-- shift/right-click targets the planner. Clicks defer
				-- ~0.35s so a second tap can upgrade the gesture to a
				-- +1c BID before any protected call fires — on a ready
				-- row the first tap would otherwise buy instantly and
				-- double-click could never reach the bid path.
				if btn == "RightButton" then
					if h.itemID then GM.TargetItem(h.itemID) end
					return
				end
				-- shift+click = Blizzard's modified-click action
				-- (chat link / context transfer), never a buy
				if IsShiftKeyDown() then
					if h.itemID then GM.ModifiedItemClick(h.itemID) end
					return
				end
				local now = GetTime()
				if row.lastClick and now - row.lastClick < 0.4 then
					row.lastClick, row.pend = nil, nil
					GM.Shopping.BidHit(hit)
					SU.Refresh()
					return
				end
				row.lastClick = now
				row.pend = (row.pend or 0) + 1
				local pend = row.pend
				GM.After(0.35, function()
					if row.pend ~= pend then return end -- a 2nd tap took over
					row.pend = nil
					if hit.wantBid then GM.Shopping.BidHit(hit)
					else GM.Shopping.BuyHit(hit) end
					SU.Refresh()
				end)
			end)
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
