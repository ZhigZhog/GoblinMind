local _, GM = ...

-- Part 13 (frontend parity): the My Auctions surface — TSM's AuctionUI
-- tab 4. POSTED is a persistent LOG: posted auctions on top, our bids
-- underneath — the snapshot persists to SavedVariables (Inventory
-- SaveOwned/LoadOwned) and refreshes whenever the AH is open; no
-- cancel/rebid surface here, actions live in the AH window's MINE
-- tab. BAGS is the post picker.
--
-- Owned-auction buyout is PER-ITEM on Forever (same convention the
-- item-search results proved: qty=147 buyout=200 = 2s/bag). The unit
-- column shows it raw; lot is unit*qty.

GM.MyAuctions = {}
local MA = GM.MyAuctions
local ui

local ROW_H = 26
local VISIBLE = 14 -- BAGS page rows
local MINE_VISIBLE = 6 -- rows per POSTED pane (matches AHUI MINE)

local W = GM.Widgets
local Btn = W.Btn

-- ============ window ============

local function Build()
	if ui then return end
	ui = { scroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindMyAuctions", UIParent)
	f:SetSize(800, 500)
	f:SetPoint("CENTER", 60, 10)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	GM.Panel(f, "contLow", "outlineVar")
	tinsert(UISpecialFrames, "GoblinMindMyAuctions")
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("MY AUCTIONS")
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, title, "auctions")
	end

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- page segs: POSTED (owned auctions) | BAGS (post picker)
	ui.page = "posted"
	ui.segs = {}
	for i, p in ipairs({ { "POSTED", "posted" }, { "BAGS", "bags" } }) do
		local b = CreateFrame("Button", nil, f)
		b:SetSize(58, 16)
		b:SetPoint("TOPLEFT", 12 + (i - 1) * 62, -34)
		GM.Panel(b, "contLowest")
		b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
		b.text:SetPoint("CENTER")
		b.text:SetText(p[1])
		b.key = p[2]
		b:SetScript("OnClick", function()
			ui.page = p[2]
			ui.scroll, ui.bidScroll, ui.bagScroll = 0, 0, 0
			MA.Refresh()
		end)
		ui.segs[i] = b
	end

	-- toolbar
	local refresh = Btn(f, 66, "REFRESH", function()
		GM.Inventory.QueryOwned()
		GM.After(0.5, MA.Refresh)
	end)
	refresh:SetPoint("TOPLEFT", 136, -32)
	local post = Btn(f, 78, "POST SCAN", function()
		if ui.page == "bags" then
			GM.Auctioning.PostScan(ui.include)
		else
			GM.Auctioning.PostScan()
		end
	end)
	post:SetPoint("LEFT", refresh, "RIGHT", 6, 0)
	ui.summary = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.summary:SetPoint("LEFT", post, "RIGHT", 12, 0)
	ui.summary:SetJustifyH("LEFT")

	-- column header + scroll host (BAGS page only — POSTED builds its
	-- own headers into the two panes below)
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(776, 16)
	hdr:SetPoint("TOPLEFT", 12, -60)
	ui.summary:SetWidth(320)
	ui.summary:SetJustifyH("LEFT")
	ui.summary:SetWordWrap(false)
	ui.hdr = hdr
	ui.hdrFs = {}
	for i = 1, 6 do
		local fs = GM.MakeFontString(hdr, GM.FONT_BOLD, 9, "secondary")
		ui.hdrFs[i] = fs
	end
	ui.count = GM.MakeFontString(hdr, GM.FONT, 9, "textDim")
	ui.count:SetPoint("RIGHT", -2, 0)

	local host = CreateFrame("Frame", nil, f)
	host:SetSize(776, VISIBLE * ROW_H + 4)
	host:SetPoint("TOPLEFT", 12, -78)
	if host.SetClipsChildren then host:SetClipsChildren(true) end
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, d)
		ui.bagScroll = math.max(0, (ui.bagScroll or 0) - d * 3)
		MA.Refresh()
	end)
	ui.host = host

	-- POSTED page mirrors the AH window's MINE tab columns but is a
	-- read-only log — no row action buttons; posted auctions on top,
	-- our bids underneath (776 wide, 6 rows per pane)
	local PANE_H = 22 + MINE_VISIBLE * ROW_H + 8
	local fp = CreateFrame("Frame", nil, f)
	fp:SetSize(776, PANE_H)
	fp:SetPoint("TOPLEFT", 12, -62)
	GM.Panel(fp, "contLowest")
	fp:EnableMouseWheel(true)
	fp:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, (ui.scroll or 0) - d * 3)
		MA.Refresh()
	end)
	ui.fp = fp
	for i, h in ipairs({
		{ "POSTED — ITEM", 26 }, { "QTY", 218 }, { "UNIT", 260 },
		{ "LOT", 330 }, { "MARKET", 420 }, { "STATUS", 500 },
		{ "TIME", 640 },
	}) do
		local fs = GM.MakeFontString(fp, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("TOPLEFT", h[2], -6)
		fs:SetText(h[1])
	end
	ui.mCount = GM.MakeFontString(fp, GM.FONT, 9, "textDim")
	ui.mCount:SetPoint("TOPRIGHT", -8, -7)
	ui.mRows = {}
	for i = 1, MINE_VISIBLE do
		local row = CreateFrame("Button", nil, fp)
		row:SetSize(760, ROW_H - 2)
		row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 26, 0)
		row.name:SetWidth(184)
		row.name:SetJustifyH("LEFT")
		row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.qty:SetPoint("LEFT", 218, 0)
		row.qty:SetWidth(36)
		row.qty:SetJustifyH("LEFT")
		row.qty:SetWordWrap(false)
		row.unit = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.unit:SetPoint("LEFT", 260, 0)
		row.unit:SetWidth(64)
		row.unit:SetJustifyH("LEFT")
		row.unit:SetWordWrap(false)
		row.lot = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.lot:SetPoint("LEFT", 330, 0)
		row.name:SetWordWrap(false)
		row.mkt = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.mkt:SetPoint("LEFT", 420, 0)
		row.mkt:SetWidth(74)
		row.mkt:SetJustifyH("LEFT")
		row.mkt:SetWordWrap(false)
		row.stat = GM.MakeFontString(row, GM.FONT_BOLD, 9, "textDim")
		row.stat:SetPoint("LEFT", 500, 0)
		row.stat:SetWidth(136)
		row.stat:SetJustifyH("LEFT")
		row.stat:SetWidth(134)
		row.stat:SetJustifyH("LEFT")
		row.stat:SetWordWrap(false)
		row.time = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.time:SetPoint("LEFT", 640, 0)
		row:SetScript("OnEnter", function(self)
			if self.tipID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.tipID)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.mRows[i] = row
	end
	ui.fEmpty = GM.MakeFontString(fp, GM.FONT, 10, "textDim")
	ui.fEmpty:SetPoint("CENTER", 0, -10)

	local bp = CreateFrame("Frame", nil, f)
	bp:SetSize(776, PANE_H)
	bp:SetPoint("TOPLEFT", fp, "BOTTOMLEFT", 0, -8)
	GM.Panel(bp, "contLowest")
	bp:EnableMouseWheel(true)
	bp:SetScript("OnMouseWheel", function(_, d)
		ui.bidScroll = math.max(0, (ui.bidScroll or 0) - d * 3)
		MA.Refresh()
	end)
	ui.bp = bp
	for i, h in ipairs({
		{ "BIDS — ITEM", 26 }, { "OUR BID", 218 }, { "CURRENT", 300 },
		{ "BUYOUT", 390 }, { "TIME", 480 }, { "STATUS", 560 },
	}) do
		local fs = GM.MakeFontString(bp, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("TOPLEFT", h[2], -6)
		fs:SetText(h[1])
	end
	ui.bCount = GM.MakeFontString(bp, GM.FONT, 9, "textDim")
	ui.bCount:SetPoint("TOPRIGHT", -8, -7)
	ui.bRows = {}
	for i = 1, MINE_VISIBLE do
		local row = CreateFrame("Button", nil, bp)
		row:SetSize(760, ROW_H - 2)
		row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 4, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 26, 0)
		row.name:SetWidth(184)
		row.name:SetJustifyH("LEFT")
		row.our = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.our:SetPoint("LEFT", 218, 0)
		row.cur = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.cur:SetPoint("LEFT", 300, 0)
		row.bo = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.bo:SetPoint("LEFT", 390, 0)
		row.name:SetWordWrap(false)
		row.time = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.time:SetPoint("LEFT", 480, 0)
		row.stat = GM.MakeFontString(row, GM.FONT_BOLD, 9, "textDim")
		row.stat:SetPoint("LEFT", 560, 0)
		row.stat:SetWidth(130)
		row.stat:SetJustifyH("LEFT")
		row.stat:SetWidth(40)
		row.stat:SetJustifyH("LEFT")
		row.stat:SetWordWrap(false)
		local act = CreateFrame("Button", nil, row)
		act:SetSize(56, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "accent")
		act.text:SetPoint("CENTER")
		act.text:SetText("REBID")
		row.act = act
		row:SetScript("OnEnter", function(self)
			if self.tipID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.tipID)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ui.bRows[i] = row
	end
	ui.bEmpty = GM.MakeFontString(bp, GM.FONT, 10, "textDim")
	ui.bEmpty:SetPoint("CENTER", 0, -10)

	-- BAGS page rows: include toggle + name/qty/group/suggested/verdict
	ui.excl = {}
	ui.bagRows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, host)
		row:SetSize(768, ROW_H - 2)
		row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
		W.HoverTint(row)
		row.chk = CreateFrame("Button", nil, row)
		row.chk:SetSize(14, 14)
		row.chk:SetPoint("LEFT", 4, 0)
		GM.Panel(row.chk, "contLowest", "outlineVar")
		row.chk.text = GM.MakeFontString(row.chk, GM.FONT_BOLD, 10, "accent")
		row.chk.text:SetPoint("CENTER")
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 24, 0)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 48, 0)
		row.name:SetWidth(180)
		row.name:SetJustifyH("LEFT")
		row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.qty:SetPoint("LEFT", 232, 0)
		row.qty:SetWidth(206)
		row.qty:SetJustifyH("LEFT")
		row.qty:SetWordWrap(false)
		row.group = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.group:SetPoint("LEFT", 290, 0)
		row.group:SetWidth(150)
		row.group:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row.unit = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.unit:SetPoint("LEFT", 444, 0)
		row.unit:SetWidth(70)
		row.unit:SetJustifyH("LEFT")
		row.unit:SetWordWrap(false)
		row.verdict = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.verdict:SetPoint("LEFT", 520, 0)
		row.verdict:SetWidth(84)
		row.verdict:SetJustifyH("LEFT")
		row:Hide()
		ui.bagRows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")
	ui.empty:SetText("no auctions posted — POST SCAN lists bags by group ops")

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
	ui.foot:SetWidth(400)
	ui.foot:SetJustifyH("LEFT")
	ui.foot:SetWordWrap(false)
	ui.foot:SetText("log view — snapshot refreshes at the AH")
end

-- ============ data ============

local BAGS_COLS = { { "", 4 }, { "ITEM", 24 }, { "QTY", 232 },
	{ "GROUP", 290 }, { "UNIT", 444 }, { "VERDICT", 520 } }

function MA.Refresh()
	if not ui then return end
	for _, b in ipairs(ui.segs) do
		local sel = b.key == ui.page
		b._gmBg:SetColorTexture(GM.RGB(sel and "contHighest" or "contLowest"))
		b.text:SetTextColor(GM.RGB(sel and "accent" or "textDim"))
	end
	local posted = ui.page == "posted"
	-- POSTED's two fixed panes end ~442px down; BAGS' scroll host
	-- needs ~446 — size the frame to the page so neither sits on a
	-- dead band of empty chrome
	ui.frame:SetHeight(posted and 456 or 462)
	ui.fp:SetShown(posted)
	ui.bp:SetShown(posted)
	ui.host:SetShown(not posted)
	ui.hdr:SetShown(not posted)
	if not posted then
		for i, fs in ipairs(ui.hdrFs) do
			local c = BAGS_COLS[i]
			if c then
				fs:ClearAllPoints()
				fs:SetPoint("LEFT", c[2], 0)
				fs:SetText(c[1])
				fs:Show()
			else
				fs:Hide()
			end
		end
	end
	-- hide the inactive page's pool; the active refresh re-shows its own
	for _, r in ipairs(ui.bagRows) do r:SetShown(false) end
	if posted then MA.RefreshPosted() else MA.RefreshBags() end
end

-- same paint as the AH window's MINE tab — shared row sources live in
-- Inventory so both surfaces read identical data
function MA.RefreshPosted()
	local rows = GM.Inventory.MineRows()
	ui.fEmpty:SetText(#rows == 0 and "no auctions up" or "")
	ui.fEmpty:SetShown(#rows == 0)
	local maxScroll = math.max(0, #rows - #ui.mRows)
	ui.scroll = math.min(ui.scroll or 0, maxScroll)
	W.ScrollText(ui.mCount, ui.scroll, #ui.mRows, #rows)
	local uc, totalVal = 0, 0
	for _, r in ipairs(rows) do
		uc = uc + (r.undercut and 1 or 0)
		totalVal = totalVal + (r.unit or 0) * (r.qty or 1)
	end
	-- log semantics: away from the AH the snapshot is historical —
	-- say how old it is
	local snapAt = GM.Inventory.OwnedAt and GM.Inventory.OwnedAt()
	local age = snapAt and (time() - snapAt)
	local stale = age and not GM.AH.open and (age > 90
		and format(" · snapshot %s ago", age >= 3600
			and format("%dh%02dm", floor(age / 3600), floor(age % 3600 / 60))
			or format("%dm", floor(age / 60) + 1))
		or " · live")
	ui.summary:SetText(format("%d auctions · %s listed%s",
		#rows, GM.Money(totalVal), stale or ""))
	for i = 1, #ui.mRows do
		local row, r = ui.mRows[i], rows[i + ui.scroll]
		if r then
			row:Show()
			row.tipID = r.id
			row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
			row.name:SetText(r.name or "?")
			row.name:SetTextColor(GM.NameColor(r.id))
			row.qty:SetText("×" .. (r.qty or 1))
			row.unit:SetText(r.unit and GM.Money(r.unit) .. "/ea" or "—")
			row.lot:SetText(r.unit and GM.Money(r.unit * (r.qty or 1)) or "—")
			row.mkt:SetText(r.mkt and (GM.Money(r.mkt) .. "/ea") or "no market")
			if r.undercut then
				row.stat:SetText(GM.CC("warn") .. "UNDERCUT|r"
					.. (r.cheap and (" @ " .. GM.Money(r.cheap)) or ""))
			elseif r.cheap == nil then
				row.stat:SetText(GM.CC("textDim") .. "no book data|r")
			else
				row.stat:SetText(GM.CC("pos") .. "lowest|r")
			end
			local tl = r.tLeft
			row.time:SetText(tl and (tl >= 3600
				and format("%dh%02dm", floor(tl / 3600), floor(tl % 3600 / 60))
				or tl >= 60 and format("%dm", floor(tl / 60))
				or "<1m") or "—")
			row:SetScript("OnClick", function()
				if not r.id then return end
				if IsShiftKeyDown() then GM.ModifiedItemClick(r.id)
				else GM.TargetItem(r.id) end
			end)
		else
			row:Hide()
		end
	end
	-- bids pane: outbid rows sort first, REBID = current + 1c
	local bids = GM.Inventory.BidRows()
	ui.bEmpty:SetText(#bids == 0 and "no bids placed this session" or "")
	ui.bEmpty:SetShown(#bids == 0)
	local bMax = math.max(0, #bids - #ui.bRows)
	ui.bidScroll = math.min(ui.bidScroll or 0, bMax)
	W.ScrollText(ui.bCount, ui.bidScroll, #ui.bRows, #bids)
	for i = 1, #ui.bRows do
		local row, r = ui.bRows[i], bids[i + ui.bidScroll]
		if r then
			row:Show()
			row.tipID = r.id
			row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
			row.name:SetText(r.name or "?")
			row.name:SetTextColor(GM.NameColor(r.id))
			row.our:SetText(r.ourBid and GM.Money(r.ourBid) or "—")
			row.cur:SetText(r.curBid and GM.Money(r.curBid) or "—")
			row.bo:SetText(r.buyout and GM.Money(r.buyout) or "—")
			local tl = r.remain
			row.time:SetText(tl and tl > 0 and (tl >= 3600
				and format("%dh%02dm", floor(tl / 3600), floor(tl % 3600 / 60))
				or tl >= 60 and format("%dm", floor(tl / 60))
				or "<1m") or "—")
			local st = r.status
			row.stat:SetText(st == "outbid"
				and (GM.CC("warn") .. "OUTBID|r")
				or st == "won" and (GM.CC("pos") .. "won|r")
				or st == "lost" and (GM.CC("textDim") .. "lost|r")
				or (GM.CC("pos") .. "winning|r"))
			local aid, id, cur = r.aid, r.id, r.curBid
			-- a log, not an action surface: REBID only arms while the
			-- AH is open (PlaceBid needs the session anyway)
			if st == "outbid" and cur and GM.AH.open then
				row.act:Show()
				row.act:SetScript("OnClick", function()
					GM.AH.Execute({ kind = "bid", itemID = id,
						auctionID = aid, total = cur + 1 })
					GM.After(0.5, MA.Refresh)
				end)
			else
				row.act:Hide()
			end
			row:SetScript("OnClick", function()
				if not r.id then return end
				if IsShiftKeyDown() then GM.ModifiedItemClick(r.id)
				else GM.TargetItem(r.id) end
			end)
		else
			row:Hide()
		end
	end
	ui.foot:SetText(format("%d auction%s%s — undercuts sort first "
		.. "(book mbx < your price) · snapshot refreshes at the AH",
		#rows, #rows == 1 and "" or "s",
		uc > 0 and format(" · %s%d undercut|r", GM.CC("warn"), uc) or ""))
end

-- BAGS page: every bag item with its live post decision (book-driven,
-- no scan) — check toggles include; POST SCAN takes only checked rows.
function MA.RefreshBags()
	local bags = GM.Auctioning.BagItems()
	local bookFresh = GM.AH.BookLive()
	local rows, nPost, nChk = {}, 0, 0
	for id, e in pairs(bags) do
		local unit, why = GM.Auctioning.PreviewPost(id)
		local verdict
		if e.bound then verdict = "soulbound"
		elseif unit then verdict = "post"
		else verdict = why or "skip" end
		-- a bound item can still price — postable means POSTABLE,
		-- otherwise it checks on, gets included, then the scan drops
		-- it as "soulbound" and the row looks skipped for no reason
		local postable = unit ~= nil and not e.bound
		if postable then nPost = nPost + 1 end
		-- default: postable rows checked; ui.excl remembers user unchecks
		local checked = postable and not ui.excl[id]
		if checked then nChk = nChk + 1 end
		rows[#rows + 1] = {
			id = id, total = e.total, stacks = #e.stacks,
			group = GM.Groups.GroupForItem(id) or "Base Group",
			unit = unit, verdict = verdict,
			postable = postable, checked = checked,
		}
	end
	table.sort(rows, function(a, b)
		if a.postable ~= b.postable then return a.postable end
		if a.checked ~= b.checked then return a.checked end
		return (GM.ItemName(a.id) or "") < (GM.ItemName(b.id) or "")
	end)
	ui.include = {}
	for _, r in ipairs(rows) do
		if r.checked then ui.include[r.id] = true end
	end
	ui.summary:SetText(format("%d items · %d postable · %d checked%s",
		#rows, nPost, nChk,
		bookFresh and "" or GM.CC("warn") .. " · book stale|r"))
	ui.empty:SetText("no bag items — PostScan needs something auctionable")
	ui.empty:SetShown(#rows == 0)
	ui.foot:SetText("checks include in POST SCAN · verdicts use the shared book when <5m old")
	local maxScroll = math.max(0, #rows - VISIBLE)
	ui.bagScroll = math.min(ui.bagScroll or 0, maxScroll)
	W.ScrollText(ui.count, ui.bagScroll, VISIBLE, #rows)
	for i = 1, VISIBLE do
		local row = ui.bagRows[i]
		local r = rows[i + ui.bagScroll]
		if r then
			row:Show()
			local dim = not r.postable
			row.icon:SetTexture(GM.ItemIcon(r.id) or 134400)
			row.icon:SetDesaturated(dim)
			row.name:SetText(GM.ItemName(r.id) or ("item " .. r.id))
			row.name:SetTextColor(GM.NameColor(
				not dim and r.id, dim and "textDim" or "text"))
			row.qty:SetText("×" .. r.total .. (r.stacks > 1 and ("·" .. r.stacks .. "st") or ""))
			row.group:SetText(r.group)
			row.unit:SetText(r.unit and GM.Money(r.unit) or "—")
			row.unit:SetTextColor(GM.RGB(r.unit and "accent" or "textDim"))
			local vc = r.verdict == "post" and "pos"
				or r.verdict == "soulbound" and "textDim" or "warn"
			row.verdict:SetText(r.verdict)
			row.verdict:SetTextColor(GM.RGB(vc))
			row.chk.text:SetText(r.checked and "×" or "")
			local id = r.id
			row.chk:SetScript("OnClick", function()
				ui.excl[id] = not ui.excl[id] and true or nil
				MA.Refresh()
			end)
			row:SetScript("OnClick", function()
				if not r.id then return end
				if IsShiftKeyDown() then GM.ModifiedItemClick(r.id)
				else GM.TargetItem(r.id) end
			end)
		else
			row:Hide()
		end
	end
end

function MA.Show()
	Build()
	GM.Inventory.QueryOwned()
	GM.Inventory.QueryBids()
	ui.frame:Show()
	MA.Refresh()
	GM.After(0.5, MA.Refresh)
end

function MA.Hide()
	if ui then ui.frame:Hide() end
end

function MA.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else MA.Show() end
end

-- repaint when the owned-auction snapshot refreshes
local baseRefreshOwned = GM.Inventory.RefreshOwned
function GM.Inventory.RefreshOwned(...)
	baseRefreshOwned(...)
	if ui and ui.frame:IsShown() then MA.Refresh() end
end
-- same for the bids half — RefreshBids runs on timers/events too
local baseRefreshBids = GM.Inventory.RefreshBids
function GM.Inventory.RefreshBids(...)
	baseRefreshBids(...)
	if ui and ui.frame:IsShown() then MA.Refresh() end
end
