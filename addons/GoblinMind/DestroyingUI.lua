local _, GM = ...

-- Part 13 #6: the destroying results window — TSM's Destroying module
-- surface. A browsable table of bag items whose destroy value
-- (max of vendor price and disenchant EV) beats the market:
-- vendoring/disenchanting beats listing. Per-row DESTROY is armed
-- like every irreversible button here — first click arms, second
-- sells ONE stack at an open merchant. The SCAN → PLAN button keeps
-- the whole table as a click-per-step plan instead.
--
-- Row click = target the item in the plan window.

GM.DestroyingUI = {}
local DU = GM.DestroyingUI
local ui

local ROW_H = 26
local VISIBLE = 13

local W = GM.Widgets
local Btn = W.Btn

-- ============ window ============

local function Build()
	if ui then return end
	ui = { scroll = 0 }
	local f = CreateFrame("Frame", "GoblinMindDestroying", UIParent)
	f:SetSize(620, 430)
	f:SetPoint("CENTER", 40, -20)
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
	tinsert(UISpecialFrames, "GoblinMindDestroying")
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("DESTROYING")
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, title, "destroy")
	end

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- toolbar
	local refresh = Btn(f, 66, "REFRESH", DU.Refresh)
	refresh:SetPoint("TOPLEFT", 12, -34)
	local plan = Btn(f, 90, "SCAN → PLAN", function()
		GM.Destroying.Scan()
	end)
	plan:SetPoint("LEFT", refresh, "RIGHT", 6, 0)
	ui.summary = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.summary:SetPoint("LEFT", plan, "RIGHT", 12, 0)
	ui.summary:SetJustifyH("LEFT")

	-- column header
	local hdr = CreateFrame("Frame", nil, f)
	hdr:SetSize(596, 16)
	hdr:SetPoint("TOPLEFT", 12, -60)
	ui.summary:SetWidth(340)
	ui.summary:SetJustifyH("LEFT")
	ui.summary:SetWordWrap(false)
	for _, h in ipairs({
		{ "ITEM", 28 }, { "QTY", 208 }, { "VENDOR", 240 },
		{ "PROC EST", 310 }, { "MKT", 375 }, { "+GAIN", 424 },
		{ "GROUP", 488 },
	}) do
		local fs = GM.MakeFontString(hdr, GM.FONT_BOLD, 9, "secondary")
		fs:SetPoint("LEFT", h[2], 0)
		fs:SetText(h[1])
	end
	ui.count = GM.MakeFontString(hdr, GM.FONT, 9, "textDim")
	ui.count:SetPoint("RIGHT", -2, 0)

	-- scroll host
	local host = CreateFrame("Frame", nil, f)
	host:SetSize(596, VISIBLE * ROW_H + 4)
	host:SetPoint("TOPLEFT", 12, -78)
	if host.SetClipsChildren then host:SetClipsChildren(true) end
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		DU.Refresh()
	end)
	ui.host = host

	ui.rows = {}
	for i = 1, VISIBLE do
		local row = CreateFrame("Button", nil, host)
		row:SetSize(588, ROW_H - 2)
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
		row.name:SetWidth(180)
		row.name:SetJustifyH("LEFT")
		row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.qty:SetPoint("LEFT", 208, 0)
		row.qty:SetWidth(26)
		row.qty:SetJustifyH("LEFT")
		row.qty:SetWordWrap(false)
		row.dv = GM.MakeFontString(row, GM.FONT, 10, "accent")
		row.dv:SetPoint("LEFT", 240, 0)
		row.proc = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.proc:SetPoint("LEFT", 310, 0)
		row.name:SetWordWrap(false)
		row.mkt = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.mkt:SetPoint("LEFT", 375, 0)
		row.gain = GM.MakeFontString(row, GM.FONT, 10, "pos")
		row.gain:SetPoint("LEFT", 424, 0)
		row.gain:SetWidth(58)
		row.gain:SetJustifyH("LEFT")
		row.gain:SetWordWrap(false)
		row.group = GM.MakeFontString(row, GM.FONT, 9, "textDim")
		row.group:SetPoint("LEFT", 488, 0)
		row.group:SetWidth(56)
		row.group:SetJustifyH("LEFT")
		-- armed destroy: click → ? → click sells one stack
		local act = CreateFrame("Button", nil, row)
		act:SetSize(52, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "warn")
		act.text:SetPoint("CENTER")
		act.text:SetText("DESTROY")
		act:SetScript("OnEnter", function()
			GameTooltip:SetOwner(act, "ANCHOR_TOP")
			GameTooltip:SetText("sell one stack to the open merchant", 1, 1, 1)
			GameTooltip:AddLine("click to arm, click again to sell", 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		act:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.act = act
		ui.rows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
	ui.foot:SetText("VENDOR is what SELL pays · PROC EST needs manual "
		.. "disenchant/mill · click row = target item")
end

-- ============ data ============

function DU.Refresh()
	if not ui then return end
	local rows = GM.Destroying.Candidates()
	local totDv, totGain = 0, 0
	for _, r in ipairs(rows) do
		totDv = totDv + r.dv * r.qty
		totGain = totGain + r.gain * r.qty
	end
	local mOpen = MerchantFrame and MerchantFrame:IsShown()
	ui.summary:SetText(format("%d item%s · best destroy %s%s",
		#rows, #rows == 1 and "" or "s", GM.Money(totDv),
		not mOpen and GM.CC("warn") .. " · merchant closed|r" or ""))
	ui.empty:SetText("nothing worth destroying — threshold + market checked")
	ui.empty:SetShown(#rows == 0)
	local maxScroll = math.max(0, #rows - VISIBLE)
	ui.scroll = math.min(ui.scroll or 0, maxScroll)
	W.ScrollText(ui.count, ui.scroll, VISIBLE, #rows)
	for i = 1, VISIBLE do
		local row = ui.rows[i]
		local r = rows[i + ui.scroll]
		if r then
			row:Show()
			row.icon:SetTexture(GM.ItemIcon(r.id) or 134400)
			row.name:SetText(GM.ItemName(r.id) or ("item " .. r.id))
			row.name:SetTextColor(GM.NameColor(r.id))
			row.qty:SetText("×" .. r.qty)
			-- VENDOR = what the SELL button actually pays per unit
			row.dv:SetText(r.vendor and GM.Money(r.vendor) or "—")
			row.proc:SetText(r.proc and GM.Money(r.proc) or "—")
			row.mkt:SetText(r.mkt and GM.Money(r.mkt) or "no market")
			-- +GAIN counts only the executable action: vendor-over-
			-- market. A proc-only edge is labeled est — the button
			-- can't realize it
			if r.vendor and r.mkt and r.vendor > r.mkt then
				row.gain:SetText("+" .. GM.Money(r.vendor - r.mkt) .. "/ea")
				row.gain:SetTextColor(GM.RGB("pos"))
			elseif r.proc and r.mkt and r.proc > r.mkt then
				row.gain:SetText("proc +" .. GM.Money(r.proc - r.mkt))
				row.gain:SetTextColor(GM.RGB("warn"))
			else
				row.gain:SetText("—")
				row.gain:SetTextColor(GM.RGB("textDim"))
			end
			row.group:SetText(r.group)
			row.act.armed = nil
			row.act.text:SetText("SELL")
			row.act.text:SetTextColor(GM.RGB("warn"))
			local id = r.id
			row.act:SetScript("OnClick", function(act)
				if not act.armed then
					local st = GM.Banking.FindStack(id)
					act.armed = true
					-- name the real proceeds: stack qty × vendor price
					act.text:SetText(st and r.vendor
						and format("×%d %s?", st.count,
							GM.Money(st.count * r.vendor))
						or "SELL?")
					return
				end
				act.armed = nil
				if GM.Destroying.SellOne(id) ~= false then
					GM.After(0.3, DU.Refresh)
				end
				DU.Refresh()
			end)
			row:SetScript("OnClick", function()
				if not r.id then return end
				if IsModifiedClick() then GM.ModifiedItemClick(r.id)
				else GM.TargetItem(r.id) end
			end)
		else
			row:Hide()
		end
	end
end

function DU.Show()
	Build()
	ui.frame:Show()
	DU.Refresh()
end

function DU.Hide()
	if ui then ui.frame:Hide() end
end

function DU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else DU.Show() end
end

-- repaint when item names/icons resolve asynchronously
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then DU.Refresh() end
	end)
end
