local _, GM = ...

-- Part 13 (frontend parity): the My Auctions surface — TSM's AuctionUI
-- tab 4. One scroll table of our posted auctions: per-item price,
-- undercut flag vs the shared book (mbx excludes our own listings),
-- time remaining, per-row cancel. CancelAuction stays one click per
-- call, armed to a confirm like the group-delete button — a misclick
-- costs a deposit.
--
-- Owned-auction buyout is PER-ITEM on Forever (same convention the
-- item-search results proved: qty=147 buyout=200 = 2s/bag). The unit
-- column shows it raw; total is unit*qty.

GM.MyAuctions = {}
local MA = GM.MyAuctions
local ui

local ROW_H = 26
local VISIBLE = 15

local function FmtLeft(sec)
	if not sec or sec <= 0 then return "—" end
	if sec >= 3600 then return format("%dh", ceil(sec / 3600)) end
	if sec >= 60 then return format("%dm", ceil(sec / 60)) end
	return "<1m"
end

local W = GM.Widgets
local Btn = W.Btn

-- ============ window ============

local function Build()
	if ui then return end
	ui = { scroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindMyAuctions", UIParent)
	f:SetSize(640, 480)
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
			ui.scroll = 0
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
	local cancel = Btn(f, 88, "CANCEL SCAN", function()
		GM.Auctioning.CancelScan()
	end)
	cancel:SetPoint("LEFT", post, "RIGHT", 6, 0)
	ui.summary = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.summary:SetPoint("LEFT", cancel, "RIGHT", 12, 0)
	ui.summary:SetJustifyH("LEFT")

	-- column header — text/positions set per page in Refresh
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(616, 16)
	hdr:SetPoint("TOPLEFT", 12, -60)
	ui.hdrFs = {}
	for i = 1, 6 do
		local fs = GM.MakeFontString(hdr, GM.FONT_BOLD, 9, "secondary")
		ui.hdrFs[i] = fs
	end
	ui.count = GM.MakeFontString(hdr, GM.FONT, 9, "textDim")
	ui.count:SetPoint("RIGHT", -2, 0)

	-- scroll host
	local host = CreateFrame("Frame", nil, f)
	host:SetSize(616, VISIBLE * ROW_H + 4)
	host:SetPoint("TOPLEFT", 12, -78)
	if host.SetClipsChildren then host:SetClipsChildren(true) end
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		MA.Refresh()
	end)
	ui.host = host

	ui.rows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, host)
		row:SetSize(608, ROW_H - 2)
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
		row.name:SetWidth(200)
		row.name:SetJustifyH("LEFT")
		row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.qty:SetPoint("LEFT", 236, 0)
		row.unit = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.unit:SetPoint("LEFT", 288, 0)
		row.total = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.total:SetPoint("LEFT", 366, 0)
		row.left = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.left:SetPoint("LEFT", 444, 0)
		row.status = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.status:SetPoint("LEFT", 500, 0)
		row.status:SetWidth(74)
		row.status:SetJustifyH("LEFT")
		local x = CreateFrame("Button", nil, row)
		x:SetSize(16, 16)
		x:SetPoint("RIGHT", -4, 0)
		x.text = GM.MakeFontString(x, GM.FONT_BOLD, 10, "textDim")
		x.text:SetPoint("CENTER")
		x.text:SetText("x")
		x:SetScript("OnEnter", function() x.text:SetTextColor(GM.RGB("err")) end)
		x:SetScript("OnLeave", function()
			x.text:SetTextColor(GM.RGB(x.armed and "warn" or "textDim"))
		end)
		row.x = x
		ui.rows[i] = row
	end

	-- BAGS page rows: include toggle + name/qty/group/suggested/verdict
	ui.excl = {}
	ui.bagRows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, host)
		row:SetSize(608, ROW_H - 2)
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
		row.group = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.group:SetPoint("LEFT", 290, 0)
		row.group:SetWidth(150)
		row.group:SetJustifyH("LEFT")
		row.unit = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.unit:SetPoint("LEFT", 444, 0)
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
	ui.foot:SetText("x = cancel auction (click to arm, click again to confirm)")
end

-- ============ data ============

local POSTED_COLS = { { "ITEM", 28 }, { "QTY", 236 }, { "UNIT", 288 },
	{ "TOTAL", 366 }, { "LEFT", 444 }, { "STATUS", 500 } }
local BAGS_COLS = { { "", 4 }, { "ITEM", 24 }, { "QTY", 232 },
	{ "GROUP", 290 }, { "UNIT", 444 }, { "VERDICT", 520 } }

function MA.Refresh()
	if not ui then return end
	for _, b in ipairs(ui.segs) do
		local sel = b.key == ui.page
		b._gmBg:SetColorTexture(GM.RGB(sel and "contHighest" or "contLowest"))
		b.text:SetTextColor(GM.RGB(sel and "accent" or "textDim"))
	end
	local cols = ui.page == "bags" and BAGS_COLS or POSTED_COLS
	for i, fs in ipairs(ui.hdrFs) do
		local c = cols[i]
		if c then
			fs:ClearAllPoints()
			fs:SetPoint("LEFT", c[2], 0)
			fs:SetText(c[1])
			fs:Show()
		else
			fs:Hide()
		end
	end
	-- hide the inactive page's pool; the active refresh re-shows its own
	for _, r in ipairs(ui.rows) do r:SetShown(ui.page == "posted") end
	for _, r in ipairs(ui.bagRows) do r:SetShown(false) end
	if ui.page == "bags" then MA.RefreshBags() else MA.RefreshPosted() end
end

function MA.RefreshPosted()
	local owned = GM.Inventory.auctions or {}
	local rows, totalVal, n = {}, 0, 0
	for aid, a in pairs(owned) do
		local unit = a.buyout -- per-item convention (verified)
		local cheapest = GM.AH.BookCheapest and GM.AH.BookCheapest(a.itemID)
		local remain = a.tLeft and a.at and (a.at + a.tLeft - time()) or nil
		rows[#rows + 1] = {
			aid = aid, id = a.itemID, qty = a.qty or 1, unit = unit,
			remain = remain, cheapest = cheapest,
			undercut = unit and cheapest and cheapest < unit or false,
		}
		n = n + 1
		totalVal = totalVal + (unit or 0) * (a.qty or 1)
	end
	table.sort(rows, function(a, b)
		if a.undercut ~= b.undercut then return a.undercut end
		return (a.unit or math.huge) < (b.unit or math.huge)
	end)

	ui.summary:SetText(format("%d auctions · %s listed", n, GM.Money(totalVal)))
	ui.empty:SetText("no auctions posted — POST SCAN lists bags by group ops")
	ui.empty:SetShown(#rows == 0)
	ui.foot:SetText("x = cancel auction (click to arm, click again to confirm)")
	local maxScroll = math.max(0, #rows - VISIBLE)
	ui.scroll = math.min(ui.scroll, maxScroll)
	W.ScrollText(ui.count, ui.scroll, VISIBLE, #rows)

	for i = 1, VISIBLE do
		local row = ui.rows[i]
		local r = rows[i + ui.scroll]
		if r then
			row:Show()
			row.aid = r.aid
			row.icon:SetTexture(GM.ItemIcon(r.id) or 134400)
			row.name:SetText(GM.ItemName(r.id) or ("item " .. r.id))
			row.qty:SetText("×" .. r.qty)
			row.unit:SetText(r.unit and GM.Money(r.unit) or "—")
			row.total:SetText(r.unit and GM.Money(r.unit * r.qty) or "—")
			local short = r.remain and r.remain < 300
			row.left:SetText(FmtLeft(r.remain))
			row.left:SetTextColor(GM.RGB(short and "warn" or "text"))
			if r.undercut then
				row.status:SetText(GM.CC("err") .. "UNDERCUT −"
					.. GM.Money(r.unit - r.cheapest) .. "|r")
			elseif r.cheapest then
				row.status:SetText(GM.CC("pos") .. "lowest|r")
			else
				row.status:SetText(GM.CC("textDim") .. "no book|r")
			end
			row.x.armed = nil
			row.x.text:SetText("x")
			row.x.text:SetTextColor(GM.RGB("textDim"))
			row.x:SetScript("OnClick", function(x)
				if not x.armed then
					x.armed = true
					x.text:SetText("?")
					x.text:SetTextColor(GM.RGB("warn"))
					return
				end
				local aid = row.aid
				GM.Inventory.recentCancels[aid] = time()
				local a = GM.Inventory.auctions and GM.Inventory.auctions[aid]
				if a then GM.Ledger.Add("cancel", a.itemID, a.qty, a.buyout) end
				C_AuctionHouse.CancelAuction(aid)
				GM.After(2, GM.Inventory.QueryOwned)
				MA.Refresh()
			end)
			row:SetScript("OnClick", function()
				if r.id then GM.TargetItem(r.id) end
			end)
		else
			row:Hide()
		end
	end
end

-- BAGS page: every bag item with its live post decision (book-driven,
-- no scan) — check toggles include; POST SCAN takes only checked rows.
function MA.RefreshBags()
	local bags = GM.Auctioning.BagItems()
	local bookFresh = GM.AH.BookAge() < 300
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
	ui.scroll = math.min(ui.scroll or 0, maxScroll)
	W.ScrollText(ui.count, ui.scroll, VISIBLE, #rows)
	for i = 1, VISIBLE do
		local row = ui.bagRows[i]
		local r = rows[i + ui.scroll]
		if r then
			row:Show()
			local dim = not r.postable
			row.icon:SetTexture(GM.ItemIcon(r.id) or 134400)
			row.icon:SetDesaturated(dim)
			row.name:SetText(GM.ItemName(r.id) or ("item " .. r.id))
			row.name:SetTextColor(GM.RGB(dim and "textDim" or "text"))
			row.qty:SetText("×" .. r.total .. (r.stacks > 1 and ("·" .. r.stacks .. "st") or ""))
			row.group:SetText(r.group)
			row.unit:SetText(r.unit and GM.Money(r.unit) or "—")
			row.unit:SetTextColor(GM.RGB(r.unit and "accent" or "textDim"))
			local vc = r.verdict == "post" and "pos"
				or r.verdict == "soulbound" and "textDim" or "warn"
			row.verdict:SetText(r.verdict)
			row.verdict:SetTextColor(GM.RGB(vc))
			row.chk.text:SetText(r.checked and "✓" or "")
			local id = r.id
			row.chk:SetScript("OnClick", function()
				ui.excl[id] = not ui.excl[id] and true or nil
				MA.Refresh()
			end)
			row:SetScript("OnClick", function()
				if r.id then GM.TargetItem(r.id) end
			end)
		else
			row:Hide()
		end
	end
end

function MA.Show()
	Build()
	GM.Inventory.QueryOwned()
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
