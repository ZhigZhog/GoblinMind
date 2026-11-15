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
	ui = { scroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindSniper", UIParent)
	f:SetSize(560, 400)
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
	ui.status = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.status:SetPoint("LEFT", ui.clear, "RIGHT", 10, 0)
	ui.status:SetJustifyH("LEFT")

	-- column header
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(536, 16)
	hdr:SetPoint("TOPLEFT", 12, -60)
	for _, h in ipairs({
		{ "ITEM", 8 }, { "QTY", 224 }, { "UNIT", 268 },
		{ "CAP", 346 }, { "%MKT", 402 },
	}) do
		local fs = GM.MakeFontString(hdr, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("LEFT", h[2], 0)
		fs:SetText(h[1])
	end
	ui.count = GM.MakeFontString(hdr, GM.FONT, 9, "textDim")
	ui.count:SetPoint("RIGHT", -2, 0)

	-- feed
	local host = CreateFrame("Frame", nil, f)
	host:SetSize(536, VISIBLE * ROW_H + 4)
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
		row:SetSize(528, ROW_H - 2)
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
		row.name:SetWidth(190)
		row.name:SetJustifyH("LEFT")
		row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.qty:SetPoint("LEFT", 224, 0)
		row.unit = GM.MakeFontString(row, GM.FONT, 10, "accent")
		row.unit:SetPoint("LEFT", 268, 0)
		row.unit:SetWidth(72)
		row.unit:SetMaxLines(1)
		row.cap = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.cap:SetPoint("LEFT", 346, 0)
		row.cap:SetWidth(50)
		row.cap:SetMaxLines(1)
		row.pct = GM.MakeFontString(row, GM.FONT_BOLD, 10, "pos")
		row.pct:SetPoint("LEFT", 402, 0)
		row.pct:SetWidth(44)
		row.pct:SetMaxLines(1)
		-- action: SCAN → … → BUY (item auction) or CONFIRM (commodity
		-- quote) — every protected call is its own click
		local act = CreateFrame("Button", nil, row)
		act:SetSize(56, 16)
		act:SetPoint("RIGHT", -20, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		row.act = act
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
	ui.foot:SetText("click row = scan/buy · shift-click = plan · x dismisses · "
		.. "deepest discount sorts first")
end

-- ============ refresh ============

function SU.Refresh()
	if not ui then return end
	local open = AHOpen()
	ui.snap:SetEnabled(open)
	local autoLive = GM.Sniper.AutoRunning and GM.Sniper.AutoRunning()
	ui.autoOn = ui.autoOn and autoLive
	ui.auto.text:SetText((ui.autoOn or autoLive) and "AUTO ✓" or "AUTO")
	ui.auto.text:SetTextColor(GM.RGB(
		(ui.autoOn or autoLive) and "accent" or "textDim"))

	-- collapse same-item listings into one row — hits are sorted
	-- cheapest-first, so the first per itemID is the representative;
	-- siblings count toward the ×N badge and resurface after it clears
	local hits, seen = {}, {}
	for _, h in ipairs(GM.Sniper.hits or {}) do
		if not h.done then
			local id = h.itemID or h.name
			if seen[id] then
				seen[id]._n = (seen[id]._n or 1) + 1
			else
				seen[id] = h
				hits[#hits + 1] = h
			end
		end
	end
	local last = GM.Sniper.lastT
	ui.status:SetText(format("%d hit%s%s%s", #hits, #hits == 1 and "" or "s",
		last and last > 0 and format(" · snapshot %ds ago",
			math.max(0, GetTime() - last)) or "",
		not open and " · AH closed" or ""))

	ui.empty:SetText(open
		and "no hits — SNAPSHOT diffs the book for under-priced listings"
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
			row.name:SetText((h.name or GM.ItemName(h.itemID) or "?")
				.. (h._n and h._n > 1
					and GM.CC("textDim") .. " ×" .. h._n .. "|r" or ""))
			row.qty:SetText("×" .. (h.qty or 1))
			row.unit:SetText(SM(h.unit or 0))
			row.cap:SetText(SM(h.cap))
			row.pct:SetText(h.pct and format("%.0f%%", h.pct) or "—")
			row.pct:SetTextColor(GM.RGB(
				h.pct and h.pct <= 50 and "pos" or "text"))
			row.act:Show()
			row.act.text:SetText(h.state == "scanning" and "…"
				or h.state == "staged" and "CONFIRM"
				or h.state == "ready" and "BUY" or "SCAN")
			row.act.text:SetTextColor(GM.RGB(h.state == "staged" and "warn"
				or h.state == "ready" and "accent"
				or h.state == "scanning" and "textDim" or "accent"))
			row.act:SetEnabled(open and h.state ~= "scanning")
			local hit = h
			row.act:SetScript("OnClick", function()
				GM.Shopping.BuyHit(hit)
				SU.Refresh()
			end)
			row.x:SetScript("OnClick", function()
				hit.done = true
				SU.Refresh()
			end)
			row:SetScript("OnClick", function(_, btn)
				-- plain click runs the snipe flow — the hit exists to
				-- be bought. Shift/right-click targets the planner.
				if btn == "RightButton" or IsShiftKeyDown() then
					if h.itemID then GM.TargetItem(h.itemID) end
				else
					GM.Shopping.BuyHit(hit)
					SU.Refresh()
				end
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
