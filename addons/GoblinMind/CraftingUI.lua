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
	p:SetPoint("TOPLEFT", x, -52) -- toolbar row sits at -32..-48
	p:SetPoint("BOTTOM", 0, 30)
	p:SetWidth(w)
	GM.Panel(p, "contLowest")
	p:SetClipsChildren(true)
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	return p
end

local function EditBox(parent, w, hint)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, 16)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(5, 4, 0, 0)
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(GM.RGB("contLowest"))
	eb:SetText(hint)
	eb:SetTextColor(GM.RGB("textDim"))
	eb:SetScript("OnEditFocusGained", function()
		if eb:GetText() == hint then
			eb:SetText("")
			eb:SetTextColor(GM.RGB("text"))
		end
	end)
	eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
	eb:SetScript("OnEnterPressed", function() eb:ClearFocus() end)
	return eb
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
	-- craftable counts move with the bags — debounced repaint
	pcall(f.RegisterEvent, f, "BAG_UPDATE")
	f:SetScript("OnEvent", function()
		if not f:IsShown() or ui.bagPending then return end
		ui.bagPending = true
		GM.After(0.3, function()
			ui.bagPending = nil
			CU.Refresh()
		end)
	end)

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

	-- toolbar: name filter + craftable-only (Blizzard frame parity)
	ui.search = EditBox(f, 150, "filter recipes…")
	ui.search:SetPoint("TOPLEFT", 12, -32)
	ui.search:SetScript("OnTextChanged", function()
		ui.recOff = 0
		CU.Refresh()
	end)
	local matsOnly = Btn(f, "CRAFTABLE ONLY", 104, 16)
	matsOnly:SetPoint("LEFT", ui.search, "RIGHT", 8, 0)
	matsOnly.text:SetTextColor(GM.RGB("textDim"))
	matsOnly:SetScript("OnClick", function()
		ui.matsOnly = not ui.matsOnly or nil
		matsOnly.text:SetTextColor(GM.RGB(ui.matsOnly and "accent" or "textDim"))
		ui.recOff = 0
		CU.Refresh()
	end)

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
	for i = 1, 11 do
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
		r.craft = StepBtn(-56, "»")
		r:Hide()
		ui.qRows[i] = r
	end

	-- detail pane: the selected recipe — Blizzard's right pane
	-- equivalent (output, reagents with have/need, craft actions)
	local det = CreateFrame("Frame", nil, qP)
	det:SetPoint("TOPLEFT", 8, -252)
	det:SetSize(qw + 8, 192)
	GM.Panel(det, "contLow")
	ui.det = det
	ui.detIcon = det:CreateTexture(nil, "ARTWORK")
	ui.detIcon:SetSize(22, 22)
	ui.detIcon:SetPoint("TOPLEFT", 10, -8)
	ui.detName = GM.MakeFontString(det, GM.FONT_BOLD, 10, "text")
	ui.detName:SetPoint("LEFT", ui.detIcon, "RIGHT", 8, 0)
	ui.detName:SetWidth(280)
	ui.detName:SetJustifyH("LEFT")
	ui.detSub = GM.MakeFontString(det, GM.FONT, 9, "textDim")
	ui.detSub:SetPoint("TOPLEFT", ui.detName, "BOTTOMLEFT", 0, -4)
	ui.detSub:SetWidth(320)
	ui.detSub:SetJustifyH("LEFT")
	ui.detMats = {}
	for i = 1, 6 do
		local m = {}
		m.icon = det:CreateTexture(nil, "ARTWORK")
		m.icon:SetSize(12, 12)
		m.icon:SetPoint("TOPLEFT", 10, -54 - (i - 1) * 15)
		m.name = GM.MakeFontString(det, GM.FONT, 9, "text")
		m.name:SetPoint("LEFT", m.icon, "RIGHT", 6, 0)
		m.name:SetWidth(200)
		m.name:SetJustifyH("LEFT")
		m.have = GM.MakeFontString(det, GM.FONT_MED, 9, "textDim")
		m.have:SetPoint("TOPRIGHT", det, "TOPRIGHT", -10, -54 - (i - 1) * 15)
		ui.detMats[i] = m
	end
	-- CRAFT ×N: Blizzard's multicraft call — one click, one protected
	-- call, N casts. If Forever doesn't honor count>1 the watchdog
	-- falls back to single casts automatically.
	ui.craft1 = Btn(det, "CRAFT", 66)
	ui.craft1:SetPoint("BOTTOMLEFT", 8, 8)
	ui.craftHint = GM.MakeFontString(det, GM.FONT, 8, "textDim")
	ui.craftHint:SetPoint("LEFT", ui.craft1, "RIGHT", 8, 0)
	ui.craftHint:SetWidth(240)
	ui.craftHint:SetJustifyH("LEFT")
	ui.craft1:SetScript("OnClick", function()
		if not ui.sel then return end
		local n = GM.Crafting.Craftable(ui.sel)
		if n < 1 then
			Footer("no materials on hand", true)
			return
		end
		local ok, err = GM.Crafting.Craft(ui.sel, n)
		if not ok then Footer(err, true) end
		CU.Refresh()
	end)

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
	-- distinct professions with recipe counts, "ALL" first — C.Prof
	-- resolves via the recipe's category root, which also heals stored
	-- mistags as it reads
	local counts, total = {}, 0
	for id in pairs(GoblinMindCrafting and GoblinMindCrafting.recipes or {}) do
		local p = GM.Crafting.Prof(id)
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
	local q = ui.search and ui.search:GetText() or ""
	q = (q == "filter recipes…") and "" or q:lower()
	for _, row in ipairs(GM.Crafting.List()) do
		if (not ui.selProf or GM.Crafting.Prof(row.recipeID) == ui.selProf)
			and (not ui.matsOnly or (row.craftable or 0) > 0)
			and (q == "" or (row.name or ""):lower():find(q, 1, true)) then
			row.queued = queue[row.recipeID] or 0
			out[#out + 1] = row
		end
	end
	return out
end

local DIFF_NAMES = { "trivial", "easy", "optimal", "difficult" }

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
	-- keep a live selection — the detail pane needs one
	if not (ui.sel and GoblinMindCrafting.recipes[ui.sel]) then
		ui.sel = rows[1] and rows[1].recipeID or nil
	end
	for i, r in ipairs(ui.recRows) do
		local row = rows[ui.recOff + i]
		if row then
			r:Show()
			local isSel = row.recipeID == ui.sel
			r._gmBg:SetColorTexture(GM.RGB(isSel and "contHigh" or "contLowest"))
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
			r:SetScript("OnClick", function()
				ui.sel = id
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
			-- » = craft the queued amount in one call — Blizzard's
			-- multicraft path; watchdog drops to 1/click if unsupported
			r.craft.text:SetTextColor(GM.RGB(
				(q.craftable or 0) > 0 and "accent" or "textDim"))
			r.craft:SetScript("OnClick", function()
				if (q.craftable or 0) < 1 then
					Footer("no materials on hand", true)
					return
				end
				local ok, err = GM.Crafting.Craft(id, q.qty)
				if not ok then Footer(err, true) end
				CU.Refresh()
			end)
			r:SetScript("OnClick", function()
				ui.sel = id
				CU.Refresh()
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

	-- selected-recipe detail — Blizzard's right pane
	local dr = ui.sel and GoblinMindCrafting.recipes
		and GoblinMindCrafting.recipes[ui.sel]
	if dr then
		ui.det:Show()
		ui.detIcon:SetTexture(GM.ItemIcon(dr.itemID) or 134400)
		ui.detName:SetText(GM.ItemName(dr.itemID) or dr.name or "?")
		local profit, price, cost = GM.Crafting.Profit(ui.sel)
		local sub = {}
		if (dr.numMade or 1) > 1 then tinsert(sub, "makes ×" .. dr.numMade) end
		if dr.diff then
			tinsert(sub, DIFF_NAMES[(dr.diff or 0) + 1] or tostring(dr.diff))
		end
		if dr.cd and dr.cd > 0 then
			tinsert(sub, format("cd %ds", dr.cd))
		end
		tinsert(sub, format("cost %s → %s (%s)",
			cost and GM.Money(cost) or "?",
			price and GM.Money(price) or "?",
			profit and (profit > 0 and "+" or "") .. GM.Money(profit) or "?"))
		ui.detSub:SetText(table.concat(sub, " · "))
		local craftable = GM.Crafting.Craftable(ui.sel)
		for i, m in ipairs(ui.detMats) do
			local mat = dr.mats and dr.mats[i]
			if mat then
				m.icon:Show()
				m.icon:SetTexture(GM.ItemIcon(mat.id) or 134400)
				m.name:Show()
				m.name:SetText(GM.ItemName(mat.id) or ("item " .. mat.id))
				local have = GM.Crafting.Owned(mat.id)
				m.have:Show()
				m.have:SetText(have .. " / " .. mat.qty)
				m.have:SetTextColor(GM.RGB(have >= mat.qty and "pos" or "err"))
				m.name:SetTextColor(GM.RGB(have >= mat.qty and "text" or "warn"))
			else
				m.icon:Hide()
				m.name:Hide()
				m.have:Hide()
			end
		end
		ui.craft1._gmBg:SetColorTexture(GM.RGB(
			craftable > 0 and "accent" or "contHigh"))
		ui.craft1.text:SetText(craftable > 0
			and ("CRAFT ×" .. craftable) or "CRAFT")
		ui.craft1.text:SetTextColor(GM.RGB(
			craftable > 0 and "contLowest" or "textDim"))
		ui.craftHint:SetText(craftable > 0
			and "tradeskill must be open · one click crafts the batch"
			or "missing materials")
	else
		ui.det:Hide()
	end
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
