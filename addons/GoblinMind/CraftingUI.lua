local _, GM = ...

-- Crafting queue manager (/goblin crafts). TSM-parity crafting window:
-- left = professions browser · middle = recipe table (profit, can-
-- craft, queue controls) · right = the persistent queue (per-recipe
-- qty, est. profit, missing-mat rollup) + EMIT PLAN / CLEAR.
-- Queue persists in GoblinMindCrafting.queue; EMIT builds one
-- aggregated plan (mat buys + craft notes) into the plan window.

GM.CraftingUI = {}
local CU = GM.CraftingUI
local ui

local ROW_H = 18

local function Btn(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h or 20)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 10, "accent")
	b.text:SetPoint("CENTER")
	b.text:SetText(label)
	return b
end

local function Tip(btn, fn)
	btn:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btn, "ANCHOR_TOP")
		local lines = fn()
		GameTooltip:SetText(lines[1])
		for i = 2, #lines do GameTooltip:AddLine(lines[i], 0.8, 0.8, 0.75, true) end
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Footer(msg, err)
	ui.footer:SetText(msg)
	ui.footer:SetTextColor(GM.RGB(err and "err" or "secondary"))
end

-- ============ window ============

local WIN_W, WIN_H = 860, 560
local PROF_W, REC_W = 140, 330
local PROF_ROWS, LIST_ROWS = 12, 22

local function Panel(parent, x, w, title)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOPLEFT", x, -34)
	p:SetPoint("BOTTOM", 0, 30)
	p:SetWidth(w)
	GM.Panel(p, "contLowest")
	p:SetClipsChildren(true)
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	return p
end

local function ListRow(parent, w)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(w, ROW_H)
	GM.Panel(r, "contLowest")
	r.text = GM.MakeFontString(r, GM.FONT, 10, "text")
	r.text:SetPoint("LEFT", 6, 0)
	r.text:SetJustifyH("LEFT")
	return r
end

local function BuildUI()
	if ui then return end
	ui = {}
	local f = CreateFrame("Frame", "GoblinMindCrafts", UIParent)
	f:SetSize(WIN_W, WIN_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	tinsert(UISpecialFrames, "GoblinMindCrafts")
	GM.Panel(f, "contLow", "outlineVar")
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 12, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("CRAFTING")
	GM.Dashboard.AddTabs(f, title, "crafting")

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -8, -8)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 10, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- left: professions
	local profP = Panel(f, 10, PROF_W, "PROFESSIONS")
	ui.profRows = {}
	for i = 1, PROF_ROWS do
		local r = ListRow(profP, PROF_W - 16)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		r.sub = GM.MakeFontString(r, GM.FONT_MED, 8, "textDim")
		r.sub:SetPoint("RIGHT", -6, 0)
		r:Hide()
		ui.profRows[i] = r
	end

	-- middle: recipes of the selected profession
	local recP = Panel(f, 10 + PROF_W + 6, REC_W, "RECIPES")
	ui.recRows = {}
	for i = 1, LIST_ROWS do
		local r = CreateFrame("Button", nil, recP)
		r:SetSize(REC_W - 16, ROW_H)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		GM.Panel(r, "contLowest")
		r.name = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.name:SetPoint("LEFT", 6, 0)
		r.name:SetWidth(168)
		r.name:SetJustifyH("LEFT")
		r.profit = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.profit:SetPoint("LEFT", 178, 0)
		r.profit:SetWidth(66)
		r.profit:SetJustifyH("LEFT")
		r.can = GM.MakeFontString(r, GM.FONT_MED, 9, "textDim")
		r.can:SetPoint("LEFT", 246, 0)
		r.qbtn = CreateFrame("Button", nil, r)
		r.qbtn:SetSize(40, ROW_H - 2)
		r.qbtn:SetPoint("RIGHT", -2, 0)
		GM.Panel(r.qbtn, "contHigh")
		r.qbtn.text = GM.MakeFontString(r.qbtn, GM.FONT_BOLD, 9, "accent")
		r.qbtn.text:SetPoint("CENTER")
		r:Hide()
		ui.recRows[i] = r
	end
	-- recipe scroll offset buttons (list is short; page with up/down)
	local recUp = Btn(recP, "▲", 30, 16)
	recUp:SetPoint("BOTTOMRIGHT", -42, 6)
	local recDn = Btn(recP, "▼", 30, 16)
	recDn:SetPoint("BOTTOMRIGHT", -8, 6)
	recUp:SetScript("OnClick", function()
		ui.recOff = math.max(0, (ui.recOff or 0) - LIST_ROWS)
		CU.Refresh()
	end)
	recDn:SetScript("OnClick", function()
		ui.recOff = (ui.recOff or 0) + LIST_ROWS
		CU.Refresh()
	end)
	ui.recEmpty = GM.MakeFontString(recP, GM.FONT, 10, "textDim")
	ui.recEmpty:SetPoint("TOPLEFT", 10, -30)
	ui.recEmpty:SetText("no recipes — open a profession\ntradeskill window once to capture")

	-- right: the queue
	local qP = Panel(f, 10 + PROF_W + 6 + REC_W + 6,
		WIN_W - PROF_W - REC_W - 38, "QUEUE")
	ui.qRows = {}
	local qw = WIN_W - PROF_W - REC_W - 38 - 16
	for i = 1, 18 do
		local r = CreateFrame("Button", nil, qP)
		r:SetSize(qw, ROW_H)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		GM.Panel(r, "contLowest")
		r.name = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.name:SetPoint("LEFT", 6, 0)
		r.name:SetWidth(130)
		r.name:SetJustifyH("LEFT")
		r.qty = GM.MakeFontString(r, GM.FONT_BOLD, 10, "accent")
		r.qty:SetPoint("LEFT", 140, 0)
		r.profit = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.profit:SetPoint("LEFT", 172, 0)
		r.profit:SetWidth(70)
		r.profit:SetJustifyH("LEFT")
		local function StepBtn(dx, label)
			local b = CreateFrame("Button", nil, r)
			b:SetSize(16, ROW_H - 2)
			b:SetPoint("RIGHT", dx, 0)
			GM.Panel(b, "contHigh")
			b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
			b.text:SetPoint("CENTER")
			b.text:SetText(label)
			return b
		end
		r.del = StepBtn(-2, "x")
		r.plus = StepBtn(-20, "+")
		r.minus = StepBtn(-38, "-")
		r:Hide()
		ui.qRows[i] = r
	end

	local emit = Btn(qP, "EMIT PLAN", 90)
	emit:SetPoint("BOTTOMRIGHT", -8, 6)
	GM.Panel(emit, "accent")
	emit.text:SetTextColor(GM.RGB("contLowest"))
	emit:SetScript("OnClick", function()
		local ok, err = GM.Crafting.QueueEmit()
		CU.Refresh()
		if ok then
			Footer("plan emitted — plan window has the steps")
		else
			Footer(err, true)
		end
	end)
	local clear = Btn(qP, "CLEAR", 60)
	clear:SetPoint("RIGHT", emit, "LEFT", -6, 0)
	clear:SetScript("OnClick", function()
		GM.Crafting.QueueClear()
		CU.Refresh()
		Footer("queue cleared")
	end)
	ui.qTotals = GM.MakeFontString(qP, GM.FONT, 9, "secondary")
	ui.qTotals:SetPoint("BOTTOMLEFT", 8, 10)
	ui.qTotals:SetWidth(qw - 160)
	ui.qTotals:SetJustifyH("LEFT")

	ui.footer = GM.MakeFontString(f, GM.FONT, 9, "secondary")
	ui.footer:SetPoint("BOTTOMLEFT", 10, 8)
	ui.footer:SetText("+N on a recipe queues its suggested amount · EMIT builds the mat-buy plan")

	if GM.OnItemInfoLoaded then
		GM.OnItemInfoLoaded(function()
			if ui and ui.frame:IsShown() then CU.Refresh() end
		end)
	end
end

-- ============ refresh ============

local function ProfList()
	-- distinct professions with recipe counts, "ALL" first
	local counts, total = {}, 0
	for _, r in pairs(GoblinMindCrafting and GoblinMindCrafting.recipes or {}) do
		local p = r.prof or "?"
		counts[p] = (counts[p] or 0) + 1
		total = total + 1
	end
	local out = { { prof = nil, label = "ALL", n = total } }
	for p, n in pairs(counts) do
		tinsert(out, { prof = p, label = p, n = n })
	end
	sort(out, function(a, b)
		if a.prof == nil then return true end
		if b.prof == nil then return false end
		return a.label < b.label
	end)
	return out
end

local function RecipeRows()
	local out = {}
	local queue = GoblinMindCrafting.queue or {}
	for _, row in ipairs(GM.Crafting.List()) do
		if not ui.selProf or row.prof == ui.selProf then
			row.queued = queue[row.recipeID] or 0
			out[#out + 1] = row
		end
	end
	return out
end

function CU.Refresh()
	if not ui then return end

	-- professions
	local profs = ProfList()
	for i, r in ipairs(ui.profRows) do
		local p = profs[i]
		if p then
			r:Show()
			local sel = (p.prof or false) == (ui.selProf or false)
			r._gmBg:SetColorTexture(GM.RGB(sel and "contHighest" or "contLowest"))
			r.text:SetText(p.label)
			r.text:SetTextColor(GM.RGB(sel and "accent" or "text"))
			r.sub:SetText(p.n)
			local key = p.prof
			r:SetScript("OnClick", function()
				ui.selProf = key
				ui.recOff = 0
				CU.Refresh()
			end)
		else
			r:Hide()
		end
	end

	-- recipes
	local rows = RecipeRows()
	ui.recOff = math.min(ui.recOff or 0,
		math.max(0, #rows - LIST_ROWS))
	ui.recEmpty:SetShown(#rows == 0)
	for i, r in ipairs(ui.recRows) do
		local row = rows[ui.recOff + i]
		if row then
			r:Show()
			r.name:SetText(row.name or ("recipe " .. row.recipeID))
			-- verdict color: can-craft accent, profitable green, loss red
			local nc = row.profit and (row.profit > 0
				and ((row.craftable or 0) > 0 and "accent" or "pos") or "err")
				or "textDim"
			r.name:SetTextColor(GM.RGB(nc))
			r.profit:SetText(row.profit and
				(row.profit > 0 and "+" or "") .. GM.Money(row.profit) or "—")
			r.profit:SetTextColor(GM.RGB(
				row.profit and (row.profit > 0 and "pos" or "err") or "textDim"))
			r.can:SetText("can:" .. (row.craftable or 0))
			-- +N queues the suggested amount; ×N shows it's queued
			if row.queued > 0 then
				r.qbtn.text:SetText("×" .. row.queued)
				r.qbtn.text:SetTextColor(GM.RGB("warn"))
			else
				r.qbtn.text:SetText("+" .. max(1, row.suggest or 1))
				r.qbtn.text:SetTextColor(GM.RGB("accent"))
			end
			local id, sug = row.recipeID, row.suggest
			r.qbtn:SetScript("OnClick", function()
				GM.Crafting.QueueAdd(id, max(1, sug or 1))
				CU.Refresh()
			end)
			Tip(r, function()
				local lines = { row.name or "recipe",
					row.prof or "" }
				tinsert(lines, format("cost %s → price %s · profit %s",
					row.cost and GM.Money(row.cost) or "?",
					row.price and GM.Money(row.price) or "?",
					row.profit and GM.Money(row.profit) or "?"))
				for _, m in ipairs(row.mats or {}) do
					local have = GM.Crafting.Owned(m.id)
					tinsert(lines, format("  %s ×%d  have %d  @%s",
						GM.ItemName(m.id) or ("item " .. m.id), m.qty, have,
						GM.Money(GM.Crafting.MatPrice(m.id) or 0)))
				end
				return lines
			end)
		else
			r:Hide()
		end
	end

	-- queue
	local qs = GM.Crafting.QueueList()
	local totCost, totProfit, matsN = 0, 0, 0
	for _ in pairs(GM.Crafting.QueueMissing()) do matsN = matsN + 1 end
	for i, r in ipairs(ui.qRows) do
		local q = qs[i]
		if q then
			r:Show()
			r.name:SetText((q.name or "?") )
			r.qty:SetText("×" .. q.qty)
			local p = q.profit and q.profit * q.qty
			r.profit:SetText(p and ((p > 0 and "+" or "") .. GM.Money(p)) or "—")
			r.profit:SetTextColor(GM.RGB(p and (p > 0 and "pos" or "err") or "textDim"))
			if q.cost then totCost = totCost + q.cost * q.qty end
			if p then totProfit = totProfit + p end
			local id = q.recipeID
			r.plus:SetScript("OnClick", function()
				GM.Crafting.QueueAdd(id, 1) CU.Refresh()
			end)
			r.minus:SetScript("OnClick", function()
				GM.Crafting.QueueAdd(id, -1) CU.Refresh()
			end)
			r.del:SetScript("OnClick", function()
				GM.Crafting.QueueSet(id, 0) CU.Refresh()
			end)
			local short = q.qty - (q.craftable or 0)
			Tip(r, function()
				local miss = GM.Crafting.Missing(id, q.qty)
				local lines = { q.name or "recipe",
					format("queue ×%d · can craft %d now%s", q.qty,
						q.craftable or 0,
						short > 0 and format(" (%d short)", short) or "") }
				for _, m in ipairs(miss) do
					tinsert(lines, format("  need %s ×%d",
						GM.ItemName(m.id) or ("item " .. m.id), m.qty))
				end
				if #miss == 0 then tinsert(lines, "all mats on hand") end
				return lines
			end)
		else
			r:Hide()
		end
	end
	ui.qTotals:SetText(#qs > 0 and format(
		"%d recipes · cost %s · est %s · %d mats short",
		#qs, GM.Money(totCost), GM.Money(totProfit), matsN)
		or "queue empty — +N on a recipe adds it")
end

function CU.Show()
	BuildUI()
	ui.frame:Show()
	CU.Refresh()
end

function CU.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function CU.Toggle()
	BuildUI()
	if ui.frame:IsShown() then ui.frame:Hide() else CU.Show() end
end
