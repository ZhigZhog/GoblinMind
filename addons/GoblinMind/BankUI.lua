local _, GM = ...

-- Bank takeover — same FramePark model: on BANKFRAME_OPENED the native
-- BankFrame is parked offscreen (kept alive; container APIs need the
-- bank session open to reach bank slots) and this window opens.
--
-- Two panes:
--   BAGS — every bag stack, → deposits that stack (merge-first into
--          matching partials, then the first family-legal empty slot —
--          Banking.MoveStack, the same path plan moves use).
--   BANK — every bank stack, ← withdraws it to bags.
-- Rows tagged `keep N` when a warehousing op governs the item — the
-- hint that tells you what the scan wants, without moving anything.
-- WAREHOUSING SCAN pushes the op-driven moves into the plan queue.
--
-- BLIZZARD UI hands the frame back; GOBLINMIND on the native frame
-- round-trips. ESC/X close the bank session — close means close.

GM.BankUI = {}
local BU = GM.BankUI
local ui

local ROW_H = 24
local VISIBLE = 14
local tinsert, sort = tinsert, table.sort
local format = format

local W = GM.Widgets
local Btn = W.Btn

local Tip = GM.Widgets.Tip

-- Forever's bank is a custom frame ("Zhig Zhog's Bank") — the
-- native BankFrame never shows even though BANKFRAME_OPENED
-- fired. The event-driven flag is the authority; IsShown is the
-- fallback for clients where the native frame does back the bank
local function BankOpen()
	return GM.bankOpen or (BankFrame and BankFrame:IsShown())
		or nil
end

-- warehousing op hint for a row: "keep N in bags" / "→ bank"
local function WhHint(id)
	local ops = GM.Groups and GM.Groups.GetOps
		and GM.Groups.GetOps(id, "warehousing")
	if not ops then return nil end
	local keep = tonumber(ops.keepQty) or 0
	if keep > 0 then
		return (ops.moveTo == "bank" and "keep " or "hold ")
			.. keep
	end
	return nil
end

local function StackRows(slots)
	local rows = {}
	for _, s in ipairs(slots) do
		if s.itemID then
			rows[#rows + 1] = {
				bag = s.bag, slot = s.slot, id = s.itemID,
				qty = s.count,
				name = GM.ItemName(s.itemID) or ("item " .. s.itemID),
				wh = WhHint(s.itemID),
			}
		end
	end
	sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)
	return rows
end

local function MakeRow(parent, i, arrow)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(304, ROW_H - 2)
	row:SetPoint("TOPLEFT", 8, -22 - ((i - 1) * ROW_H))
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(GM.RGB(i % 2 == 0 and "contMedium" or "contLowest"))
	W.HoverTint(row)
	W.ModifiedClick(row, function() return row.tipID end)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 4, 0)
	row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.name:SetPoint("LEFT", 26, 0)
	row.name:SetWidth(148)
	row.name:SetJustifyH("LEFT")
	row.qty = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.qty:SetPoint("LEFT", 178, 0)
	row.qty:SetWidth(32) -- 4-digit counts must not touch wh
	row.qty:SetJustifyH("LEFT")
	row.qty:SetWordWrap(false)
	row.wh = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.wh:SetPoint("LEFT", 212, 0)
	row.name:SetWordWrap(false)
	local act = CreateFrame("Button", nil, row)
	act:SetSize(36, 16)
	act:SetPoint("RIGHT", -4, 0)
	GM.Panel(act, "contHigh")
	act.text = GM.MakeFontString(act, GM.FONT_BOLD, 10, "accent")
	act.text:SetPoint("CENTER")
	act.text:SetText(arrow)
	row.act = act
	row:SetScript("OnEnter", function(self)
		if self.tipID then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.tipID)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return row
end

local function MakePane(f, w, title)
	local p = CreateFrame("Frame", nil, f)
	p:SetSize(w, VISIBLE * ROW_H + 30)
	GM.Panel(p, "contLowest")
	p.head = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	p.head:SetPoint("TOPLEFT", 8, -6)
	p.head:SetText(title)
	p.count = GM.MakeFontString(p, GM.FONT, 9, "textDim")
	p.count:SetPoint("TOPRIGHT", -8, -7)
	p:EnableMouseWheel(true)
	p.empty = GM.MakeFontString(p, GM.FONT, 10, "textDim")
	p.empty:SetPoint("CENTER", 0, -10)
	p.rows = {}
	return p
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = { lScroll = 0, rScroll = 0 }
	-- close means close: restore the native frame quietly and end the
	-- bank session — unless the user asked for the Blizzard frame.
	-- Contextual takeover (bank session only) — no tab strip.
	local f = GM.Widgets.Window({
		name = "GoblinMindBank", title = "BANK",
		w = 680, h = 430, x = -60, y = -20,
		onHide = function()
			GM.FramePark.Restore(BankFrame)
			if not ui.wantDefault and CloseBankFrame then
				pcall(CloseBankFrame)
			end
		end,
	})
	ui.frame = f

	-- toolbar
	local scan = Btn(f, 120, "WAREHOUSING SCAN", function()
		GM.Banking.WarehousingScan()
	end)
	Tip(scan, function()
		return { "Warehousing scan",
			"Compares bag/bank counts against group warehousing ops",
			"and pushes the moves into the plan queue." }
	end)

	-- panes
	ui.lp = MakePane(f, 320, "BAGS → deposit")
	ui.lp:SetScript("OnMouseWheel", function(_, d)
		ui.lScroll = math.max(0, ui.lScroll - d * 3)
		BU.Refresh()
	end)
	ui.lrows = {}
	for i = 1, VISIBLE do ui.lrows[i] = MakeRow(ui.lp, i, "→") end

	ui.rp = MakePane(f, 320, "BANK → withdraw")
	ui.rp:SetScript("OnMouseWheel", function(_, d)
		ui.rScroll = math.max(0, ui.rScroll - d * 3)
		BU.Refresh()
	end)
	ui.rrows = {}
	for i = 1, VISIBLE do ui.rrows[i] = MakeRow(ui.rp, i, "←") end

	ui.foot = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	ui.foot:SetPoint("BOTTOMLEFT", 14, 10)
	ui.foot:SetText("one stack per click · moves merge onto matching "
		.. "partials first · keep N = warehousing op hint")

	-- ============ layout wiring ============
	-- scan button + fill status over two side-by-side panes that
	-- split the window width; footer stays anchored below
	local u = GM.ui
	local root = u:AttachRoot(f, {
		direction = "column", gap = "xs",
		pad = { top = 34, right = 12, bottom = 30, left = 12 },
	})
	local bar = u:Row(root, { gap = 6 })
	root:Add(bar, { height = 22 })
	bar:Add(u:Adopt(scan, { width = 120, height = 20 }),
		{ width = 120, height = 20, align = "center" })
	ui.summary = u:Text(bar, { style = "caption", wrap = false })
	bar:Add(ui.summary, { width = "fill", align = "center" })
	local panes = u:Row(root, { gap = "sm" })
	root:Add(panes, { height = "fill" })
	panes:Add(u:Adopt(ui.lp, { width = 320,
		height = VISIBLE * ROW_H + 30 }),
		{ width = 320, height = "fill" })
	panes:Add(u:Adopt(ui.rp, { width = 320,
		height = VISIBLE * ROW_H + 30 }),
		{ width = "fill", height = "fill" })
end

-- ============ refresh ============

local function Fill(rows, vis, scrollKey, toScope)
	local maxScroll = math.max(0, #rows - VISIBLE)
	ui[scrollKey] = math.min(ui[scrollKey] or 0, maxScroll)
	W.ScrollText(vis[1]:GetParent().count, ui[scrollKey], VISIBLE, #rows)
	for i = 1, VISIBLE do
		local row, r = vis[i], rows[i + ui[scrollKey]]
		if r then
			row:Show()
			row.tipID = r.id
			row.icon:SetTexture(r.id and GM.ItemIcon(r.id) or 134400)
			row.name:SetText(r.name or "?")
			row.name:SetTextColor(GM.NameColor(r.id))
			row.qty:SetText("×" .. r.qty)
			row.wh:SetText(r.wh or "")
			local src = { bag = r.bag, slot = r.slot, itemID = r.id, count = r.qty }
			row.act:SetScript("OnClick", function()
				if GM.Banking.MoveTo(src, toScope) then
					GM.Time.After(0.2, BU.Refresh)
				end
			end)
		else
			row:Hide()
		end
	end
end

-- view-model for the registry's Data() pass — pure model reads
local function Data()
	local open = BankOpen()
	return {
		open = open,
		bagRows = StackRows(GM.Banking.BagSlots()),
		bankRows = open and StackRows(GM.Banking.BankSlots()) or {},
	}
end

function BU.Refresh(vm)
	if not ui then return end
	vm = vm or Data()
	local open, bagRows, bankRows = vm.open, vm.bagRows, vm.bankRows
	ui.lp.empty:SetText(#bagRows == 0 and "bags empty" or "")
	ui.lp.empty:SetShown(#bagRows == 0)
	ui.rp.empty:SetText(not open and "open the bank"
		or (#bankRows == 0 and "bank empty" or ""))
	ui.rp.empty:SetShown(#bankRows == 0)
	ui.summary:SetText(format("%d stacks in bags · %d in bank%s",
		#bagRows, #bankRows,
		not open and GM.CC("warn") .. " · bank closed|r" or ""))
	Fill(bagRows, ui.lrows, "lScroll", "bank")
	Fill(bankRows, ui.rrows, "rScroll", "bags")
end

-- ============ takeover ============

local function EnsureSwitchBtn()
	W.EnsureSwitchBtn(ui, BankFrame, BU.OnBankOpen)
end

function BU.OnBankOpen()
	Build()
	EnsureSwitchBtn()
	if ui.wantDefault then return end
	ui.frame:Show()
	BU.Refresh()
	GM.FramePark.Park(BankFrame)
	GM.Time.After(0.3, function() GM.FramePark.Park(BankFrame) end)
end

function BU.Show()
	Build()
	ui.frame:Show()
	BU.Refresh()
end

function BU.Hide()
	if ui then ui.frame:Hide() end
end

function BU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else BU.Show() end
end

-- repaint when item names/icons resolve asynchronously
if GM.OnItemInfoLoaded then
	GM.OnItemInfoLoaded(function()
		if ui and ui.frame and ui.frame:IsShown() then BU.Refresh() end
	end)
end

-- bank session drives the takeover
local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "BANKFRAME_OPENED")
pcall(f.RegisterEvent, f, "BANKFRAME_CLOSED")
f:SetScript("OnEvent", function(_, e)
	if e == "BANKFRAME_OPENED" then
		GM.bankOpen = true
		BU.OnBankOpen()
	else
		GM.bankOpen = nil
		if ui and ui.frame then
			ui.frame:Hide()
		end
	end
end)

GM.View.Register("bank", { class = "contextual",
	events = { "BAG_UPDATE", "PLAYERBANKSLOTS_CHANGED",
		"PLAYERBANKBAGSLOTS_CHANGED",
		"PLAYERREAGENTBANKSLOTS_CHANGED" },
	Show = BU.Show, Hide = BU.Hide, Toggle = BU.Toggle,
	Data = Data,
	Refresh = BU.Refresh,
	IsShown = function() return ui and ui.frame and ui.frame:IsShown() end })
