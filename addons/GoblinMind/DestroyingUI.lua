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
	local f = GM.Widgets.Window({
		name = "GoblinMindDestroying", title = "DESTROYING",
		w = 620, h = 430, x = 40, y = -20, tab = "destroy",
	})
	ui.frame = f

	-- toolbar (refresh + plan + summary go under flow at the end)
	local refresh = Btn(f, 66, "REFRESH", DU.Refresh)
	local plan = Btn(f, 90, "SCAN → PLAN", function()
		GM.Destroying.Scan()
	end)
	ui.summary = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.summary:SetJustifyH("LEFT")

	-- column header
	local hdr = CreateFrame("Frame", nil, f)
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
	if host.SetClipsChildren then host:SetClipsChildren(true) end
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, d)
		ui.scroll = math.max(0, ui.scroll - d * 3)
		DU.Refresh()
	end)
	ui.host = host

	ui.rows = {}
	for i = 1, VISIBLE do
		local row = W.ColumnRow(host, {
			h = ROW_H - 2, w = 588, icon = 18, nameW = 180,
			cols = {
				{ key = "qty", x = 208, w = 26 },
				{ key = "dv", x = 240, color = "accent" },
				{ key = "proc", x = 310, color = "textDim" },
				{ key = "mkt", x = 375, color = "textDim" },
				{ key = "gain", x = 424, w = 58, color = "pos" },
				{ key = "group", x = 488, w = 56, color = "textDim",
					size = 9 },
			},
		})
		row:SetPoint("TOPLEFT", 0, -((i - 1) * ROW_H))
		row:SetZebra(i)
		-- armed destroy: click → ? → click sells one stack
		local act = CreateFrame("Button", nil, row)
		act:SetSize(52, 16)
		act:SetPoint("RIGHT", -4, 0)
		GM.Panel(act, "contHigh")
		act.text = GM.MakeFontString(act, GM.FONT_BOLD, 8, "warn")
		act.text:SetPoint("CENTER")
		act.text:SetText("DESTROY")
		act:SetScript("OnEnter", function(act)
			GM.Widgets.HintShow(act, act.deRow and {
				"disenchant EV beats vendor + market",
				"cast Disenchant yourself — the cast is protected",
			} or {
				"sell one stack to the open merchant",
				"click to arm, click again to sell",
			})
		end)
		act:SetScript("OnLeave", GM.Widgets.HintHide)
		row.act = act
		ui.rows[i] = row
	end

	ui.empty = GM.MakeFontString(host, GM.FONT, 10, "textDim")
	ui.empty:SetPoint("CENTER")

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetText("DE = disenchant/mill EV beats vendor + market "
		.. "· SELL vendors a stack · click row = target item")

	-- ============ layout wiring ============
	-- toolbar Row / header / scroll host / foot — the title bar
	-- and tab stay W.Window chrome
	local u = GM.ui
	local root = u:AttachRoot(f, {
		direction = "column", gap = "sm",
		pad = { top = 34, right = 12, bottom = 12, left = 12 },
	})
	local bar = u:Row(root, { gap = "sm" })
	root:Add(bar, { height = 20 })
	local function Bar(fr, w, h)
		h = h or 18
		bar:Add(u:Adopt(fr, { width = w, height = h }),
			{ width = w, height = h, align = "center" })
	end
	Bar(refresh, 66) Bar(plan, 90)
	bar:Add(u:Adopt(ui.summary, { width = 340, height = 14 }),
		{ width = "fill", height = 14, align = "center" })
	root:Add(u:Adopt(hdr, { width = 596, height = 16 }), { height = 16 })
	root:Add(u:Adopt(host, { width = 596, height = VISIBLE * ROW_H + 4 }),
		{ height = "fill" })
	root:Add(u:Adopt(ui.foot, { width = 596, height = 12 }),
		{ height = 12 })
end

-- ============ data ============

function DU.Refresh()
	if not ui then return end
	local rows = GM.Destroying.Candidates()
	local totDv, totGain, nDe = 0, 0, 0
	for _, r in ipairs(rows) do
		totDv = totDv + r.dv * r.qty
		totGain = totGain + r.gain * r.qty
		if r.action == "de" then nDe = nDe + 1 end
	end
	local mOpen = MerchantFrame and MerchantFrame:IsShown()
	ui.summary:SetText(format("%d item%s · %d DE / %d sell · best destroy %s%s",
		#rows, #rows == 1 and "" or "s", nDe, #rows - nDe,
		GM.Money(totDv),
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
			row:SetItem(r.id)
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
			row.act.deRow = r.action == "de"
			local id = r.id
			if r.action == "de" then
				row.act.text:SetText("DE")
				row.act.text:SetTextColor(GM.RGB("accent"))
				row.act:SetScript("OnClick", function()
					-- the cast is protected — point at the item and
					-- leave the button press to the player
					GM.TargetItem(id)
					GM.Print(GM.CC("accent") .. "cast Disenchant on "
						.. (r.name or ("item " .. id))
						.. " — protected cast, can't be automated|r")
				end)
			else
				row.act.text:SetText("SELL")
				row.act.text:SetTextColor(GM.RGB("warn"))
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
			end
			row:SetScript("OnClick", function()
				if not r.id then return end
				-- the widget's modified-click hook already ran the
				-- default chain on mousedown — just gate the
				-- targeting click
				if IsModifiedClick() then return end
				GM.TargetItem(r.id)
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
