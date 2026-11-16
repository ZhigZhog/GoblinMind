local _, GM = ...
local W = GM.Widgets

-- Crafting queue manager (/goblin crafts). TSM-parity crafting window:
-- left = professions browser · middle = recipe table (profit, can-
-- craft, queue controls) · right = the persistent queue (per-recipe
-- qty, est. profit, missing-mat rollup) + EMIT PLAN / CLEAR.
-- Queue persists in GoblinMindCrafting.queue; EMIT builds one
-- aggregated plan (mat buys + craft notes) into the plan window.

GM.CraftingUI = {}
local CU = GM.CraftingUI
local ui
local unpack = unpack or table.unpack

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

local WIN_W, WIN_H = 970, 560
local PROF_W, REC_W = 140, 440
local PROF_ROWS, LIST_ROWS = 16, 22

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
	p.count = GM.MakeFontString(p, GM.FONT, 9, "textDim")
	p.count:SetPoint("TOPRIGHT", -8, -7)
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
	W.HoverTint(r)
	r.text = GM.MakeFontString(r, GM.FONT, 10, "text")
	r.text:SetPoint("LEFT", 6, 0)
	r.text:SetJustifyH("LEFT")
	return r
end

-- shared name prompt for category create/assign flows — the existing
-- categories list under the editbox doubles as the dropdown: click
-- one to reuse it, or type a new name + OK
local function CatPrompt(title, cb)
	if not ui.catBox then
		local p = CreateFrame("Frame", nil, ui.frame)
		p:SetSize(260, 64)
		p:SetPoint("BOTTOMLEFT", 10, 30)
		p:SetFrameStrata("DIALOG")
		GM.Panel(p, "contHigh")
		p.title = GM.MakeFontString(p, GM.FONT_BOLD, 9, "accent")
		p.title:SetPoint("TOPLEFT", 8, -6)
		p.eb = EditBox(p, 176, "category name…")
		p.eb:SetPoint("TOPLEFT", 10, -22)
		local ok = Btn(p, "OK", 44, 16)
		ok:SetPoint("LEFT", p.eb, "RIGHT", 6, 0)
		local function finish(name)
			if name and name ~= "" and name ~= "category name…" and p.cb then
				p.cb(name)
			end
			p.eb:SetText("")
			p.eb:ClearFocus()
			p:Hide()
		end
		ok:SetScript("OnClick", function() finish(p.eb:GetText()) end)
		p.eb:SetScript("OnEnterPressed", function() ok:Click() end)
		-- existing categories — dropdown rows under the input
		p.catBtns = {}
		for i = 1, 8 do
			local b = Btn(p, "", 240, 15)
			b:SetPoint("TOPLEFT", 8, -42 - (i - 1) * 16)
			b.text:SetJustifyH("LEFT")
			b:Hide()
			p.catBtns[i] = b
		end
		ui.catBox = p
	end
	local p = ui.catBox
	p.title:SetText(title)
	p.cb = cb
	local cats = GM.Crafting.CatList()
	p:SetHeight(46 + min(#cats, 8) * 16)
	for i, b in ipairs(p.catBtns) do
		local c = cats[i]
		if c then
			b:Show()
			b.text:SetText(c.name .. "  ×" .. c.n)
			local name = c.name
			b:SetScript("OnClick", function()
				if p.cb then p.cb(name) end
				p.eb:SetText("")
				p.eb:ClearFocus()
				p:Hide()
			end)
		else
			b:Hide()
		end
	end
	p:Show()
	p.eb:SetFocus()
end

-- CraftRecipe only acts on the open tradeskill line, and opening the
-- line is a protected spell cast — when a craft's line isn't open,
-- C.GateButton covers the button with a secure OPEN overlay that casts
-- the profession spell (Crafting.lua — shared with the plan window's
-- exec button). One click: spell cast → TRADE_SKILL_SHOW →
-- C.pendingOpenCraft re-fires the craft.
local function GateCraft(btn, recipeID, qty, allow)
	return GM.Crafting.GateButton
		and GM.Crafting.GateButton(btn, recipeID, qty, allow)
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
	f:SetScript("OnEvent", function(_, e)
		if not f:IsShown() or ui.bagPending then return end
		ui.bagPending = true
		GM.After(0.3, function()
			ui.bagPending = nil
			CU.Refresh()
		end)
	end)
	-- closing our window: if the user asked for the Blizzard frame it
	-- gets its spot back. CloseTradeSkill fires ONLY on a deliberate
	-- close (ui.closing set by the X button / toggle-off) — every other
	-- hide (tab swap via Dashboard, the UISpecialFrames ESC sweep, any
	-- programmatic hide) must keep the session alive: killing it was
	-- the "open sound, close sound, frozen OPEN" bug — the window hid
	-- right after the spell opened the line and took the line with it.
	f:SetScript("OnHide", function()
		CU.RestoreDefault()
		if ui.closing and not ui.wantDefault
			and C_TradeSkillUI and C_TradeSkillUI.CloseTradeSkill then
			pcall(C_TradeSkillUI.CloseTradeSkill)
		end
		ui.closing = nil
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
	close:SetScript("OnClick", function()
		ui.closing = true -- deliberate close → OnHide ends the session
		f:Hide()
	end)

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
	local blizz = Btn(f, "BLIZZARD UI", 84, 16)
	blizz:SetPoint("LEFT", matsOnly, "RIGHT", 8, 0)
	blizz.text:SetTextColor(GM.RGB("secondary"))
	Tip(blizz, function()
		return { "Blizzard default UI",
			"Brings the default professions frame back and hides this",
			"window. The GOBLINMIND button on that frame switches back." }
	end)
	blizz:SetScript("OnClick", function()
		ui.wantDefault = true
		ui.frame:Hide() -- OnHide → RestoreDefault parks it back on-screen
	end)

	-- left: professions (+ user categories)
	local profP = Panel(f, 10, PROF_W, "PROFESSIONS")
	ui.profP = profP
	ui.profRows = {}
	for i = 1, PROF_ROWS do
		local r = ListRow(profP, PROF_W - 16)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		r.sub = GM.MakeFontString(r, GM.FONT_MED, 8, "textDim")
		r.sub:SetPoint("RIGHT", -6, 0)
		r:Hide()
		ui.profRows[i] = r
	end
	profP:EnableMouseWheel(true)
	profP:SetScript("OnMouseWheel", function(_, d)
		ui.profOff = math.max(0, (ui.profOff or 0) - d * 4)
		CU.Refresh()
	end)
	local addCat = Btn(profP, "+ CATEGORY", 92, 16)
	addCat:SetPoint("BOTTOMLEFT", 8, 6)
	addCat.text:SetTextColor(GM.RGB("secondary"))
	addCat:SetScript("OnClick", function()
		CatPrompt("new category", function(name)
			GM.Crafting.CatCreate(name)
			ui.selCat, ui.selProf, ui.recOff = name, nil, 0
			CU.Refresh()
			Footer("category '" .. name .. "' created — CAT+ on a recipe adds it")
		end)
	end)

	-- middle: recipes of the selected profession
	local recP = Panel(f, 10 + PROF_W + 6, REC_W, "RECIPES")
	ui.recP = recP
	ui.recRows = {}
	for i = 1, LIST_ROWS do
		local r = CreateFrame("Button", nil, recP)
		r:SetSize(REC_W - 16, ROW_H)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		GM.Panel(r, "contLowest")
		r.skill = GM.MakeFontString(r, GM.FONT_BOLD, 9, "pos")
		r.skill:SetPoint("LEFT", 6, 0)
		r.skill:SetText("▲")
		r.skill:Hide()
		r.name = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.name:SetPoint("LEFT", 18, 0)
		r.name:SetWidth(168)
		r.name:SetJustifyH("LEFT")
		r.profit = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.profit:SetPoint("LEFT", 190, 0)
		r.profit:SetWidth(68)
		r.profit:SetJustifyH("LEFT")
		r.sale = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.sale:SetPoint("LEFT", 262, 0)
		r.sale:SetWidth(44) -- "999/d" fits; clips before `can`
		r.sale:SetJustifyH("LEFT")
		r.can = GM.MakeFontString(r, GM.FONT_MED, 9, "textDim")
		r.can:SetPoint("LEFT", 310, 0)
		r.can:SetWidth(58) -- clipped so "bags 99 +99" can't reach qbtn
		r.can:SetJustifyH("LEFT")
		r.can:SetWordWrap(false)
		r.qbtn = CreateFrame("Button", nil, r)
		r.qbtn:SetSize(40, ROW_H - 2)
		r.qbtn:SetPoint("RIGHT", -2, 0)
		GM.Panel(r.qbtn, "contHigh")
		r.qbtn.text = GM.MakeFontString(r.qbtn, GM.FONT_BOLD, 9, "accent")
		r.qbtn.text:SetPoint("CENTER")
		r:Hide()
		ui.recRows[i] = r
	end
	-- paging buttons in the panel header + mouse-wheel scrolling —
	-- the bottom pair overlapped the list's last row. Left of the
	-- count zone (TOPRIGHT owns ~100px) so the count can't sit
	-- under the buttons.
	local recUp = Btn(recP, "▲", 22, 14)
	recUp:SetPoint("TOPRIGHT", -124, -4)
	local recDn = Btn(recP, "▼", 22, 14)
	recDn:SetPoint("TOPRIGHT", -100, -4)
	recUp:SetScript("OnClick", function()
		ui.recOff = math.max(0, (ui.recOff or 0) - LIST_ROWS)
		CU.Refresh()
	end)
	recDn:SetScript("OnClick", function()
		ui.recOff = (ui.recOff or 0) + LIST_ROWS
		CU.Refresh()
	end)
	recP:EnableMouseWheel(true)
	recP:SetScript("OnMouseWheel", function(_, d)
		ui.recOff = math.max(0, (ui.recOff or 0) - d * 4)
		CU.Refresh()
	end)
	ui.recEmpty = GM.MakeFontString(recP, GM.FONT, 10, "textDim")
	ui.recEmpty:SetPoint("TOPLEFT", 10, -30)
	ui.recEmpty:SetText("no recipes — open a profession\ntradeskill window once to capture")

	-- right: the queue
	local qP = Panel(f, 10 + PROF_W + 6 + REC_W + 6,
		WIN_W - PROF_W - REC_W - 38, "QUEUE")
	ui.qP = qP
	ui.qRows = {}
	local qw = WIN_W - PROF_W - REC_W - 38 - 16
	for i = 1, 11 do
		local r = CreateFrame("Button", nil, qP)
		r:SetSize(qw, ROW_H)
		r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * (ROW_H + 2))
		GM.Panel(r, "contLowest")
		W.HoverTint(r)
		r.name = GM.MakeFontString(r, GM.FONT, 10, "text")
		r.name:SetPoint("LEFT", 6, 0)
		r.name:SetWidth(130)
		r.name:SetJustifyH("LEFT")
		r.qty = CreateFrame("EditBox", nil, r)
		r.qty:SetSize(32, ROW_H - 4)
		r.qty:SetPoint("LEFT", 138, 0)
		r.qty:SetAutoFocus(false)
		r.qty:SetFont(GM.FONT_BOLD, 10, "")
		r.qty:SetTextColor(GM.RGB("accent"))
		r.qty:SetJustifyH("RIGHT")
		r.qty:SetScript("OnEnterPressed", function(self)
			local n = tonumber((self:GetText():gsub("%D", "")))
			if n and self._id then
				GM.Crafting.QueueSet(self._id, n)
			end
			self:ClearFocus()
			CU.Refresh()
		end)
		r.qty:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
		end)
		r.qty:SetScript("OnEditFocusLost", function(self)
			if self._q then self:SetText("×" .. self._q) end
		end)
		W.Tip(r.qty, function()
			return { "queued quantity",
				"type a number · Enter commits · Esc reverts",
				"+/- still fine-adjust by one" }
		end)
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
	qP:EnableMouseWheel(true)
	qP:SetScript("OnMouseWheel", function(_, d)
		ui.qOff = math.max(0, (ui.qOff or 0) - d * 3)
		CU.Refresh()
	end)

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
	-- hover → the real item tooltip (textures can't take scripts)
	ui.detIconBtn = CreateFrame("Button", nil, det)
	ui.detIconBtn:SetAllPoints(ui.detIcon)
	ui.detIconBtn:SetScript("OnEnter", function(self)
		if not self.itemID then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(self.itemID)
		else
			GameTooltip:SetHyperlink("item:" .. self.itemID)
		end
		GameTooltip:Show()
	end)
	ui.detIconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
		-- invisible hover region for the location tooltip — anchored
		-- top+height, NOT top+bottom-right: the latter stretches each
		-- box to the pane's lower edge and swallows clicks meant for
		-- the buttons below
		m.hit = CreateFrame("Button", nil, det)
		m.hit:SetPoint("TOPLEFT", det, "TOPLEFT", 6, -52 - (i - 1) * 15)
		m.hit:SetPoint("RIGHT", det, "RIGHT", -6, 0)
		m.hit:SetHeight(14)
		ui.detMats[i] = m
	end
	-- CRAFT ×N: Blizzard's multicraft call — one click, one protected
	-- call, N casts. If Forever doesn't honor count>1 the watchdog
	-- falls back to single casts automatically.
	ui.craft1 = Btn(det, "CRAFT", 66)
	ui.craft1:SetPoint("BOTTOMLEFT", 8, 8)
	ui.craftHint = GM.MakeFontString(det, GM.FONT, 8, "textDim")
	ui.craftHint:SetPoint("LEFT", ui.craft1, "RIGHT", 8, 0)
	ui.craftHint:SetWidth(200)
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
	ui.catBtn = Btn(det, "+CAT", 44)
	ui.catBtn:SetPoint("BOTTOMRIGHT", -8, 8)
	Tip(ui.catBtn, function()
		return { "Add to category",
			"File this recipe under a custom category (created if new).",
			"Categories list at the bottom of the professions panel —",
			"right-click a category to delete it." }
	end)
	ui.catBtn:SetScript("OnClick", function()
		if not ui.sel then return end
		local id = ui.sel
		CatPrompt("category for " .. (GoblinMindCrafting.recipes[id]
			and GoblinMindCrafting.recipes[id].name or "recipe"), function(name)
			GM.Crafting.CatAssign(name, id)
			ui.selCat, ui.selProf, ui.recOff = name, nil, 0
			CU.Refresh()
			Footer("added to '" .. name .. "'")
		end)
	end)

	local emit = Btn(qP, "EMIT PLAN", 90)
	emit:SetPoint("BOTTOMRIGHT", -8, 6)
	GM.Panel(emit, "accent")
	emit.text:SetTextColor(GM.RGB("contLowest"))
	emit:SetScript("OnClick", function()
		-- pcall: a math/UI error in the emit path must surface in the
		-- footer, not die silently inside the click handler — and the
		-- plan window opens before Refresh so a refresh fault can't
		-- hide an emitted plan
		local ok, res, err = pcall(GM.Crafting.QueueEmit)
		if not ok then
			Footer("emit error: " .. tostring(res), true)
		elseif res then
			GM.PlanQueue.SetHome(false)
			GM.PlanQueue.Show()
			Footer("plan emitted — plan window has the steps")
		else
			Footer(err or "queue is empty", true)
		end
		CU.Refresh()
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
	ui.footer:SetText("▲ = grants skill-ups (orange optimal · yellow medium · green easy · N = multi) · +N queues suggested")

	if GM.OnItemInfoLoaded then
		GM.OnItemInfoLoaded(function()
			if ui and ui.frame:IsShown() then CU.Refresh() end
		end)
	end
end

-- ============ refresh ============

-- professions THIS character knows — the recipe DB is account-wide
-- so an alt's tradeskills otherwise masquerade as local. nil when
-- the client can't answer (Forever API gaps) → show all as local.
local function MyProfs()
	if not (GetProfessions and GetProfessionInfo) then return nil end
	local set = {}
	for _, idx in ipairs({ GetProfessions() }) do
		local name = GetProfessionInfo(idx)
		if type(name) == "string" and name ~= "" then
			set[name] = true
		end
	end
	return set
end

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
	local mine = MyProfs()
	local out = { { prof = nil, label = "ALL", n = total } }
	for p, n in pairs(counts) do
		-- alt-profession recipes stay browsable (account planning)
		-- but sorted after the char's own and marked
		local alt = mine and not mine[p]
		tinsert(out, { prof = p, n = n, alt = alt,
			label = p .. (alt and
				(GM.CC("textDim") .. " · alt|r") or "") })
	end
	sort(out, function(a, b)
		if a.prof == nil then return true end
		if b.prof == nil then return false end
		if (a.alt or false) ~= (b.alt or false) then return not a.alt end
		return a.label < b.label
	end)
	-- user categories ride under the professions, TSM-group style
	local cats = GM.Crafting.CatList and GM.Crafting.CatList() or {}
	if #cats > 0 then
		tinsert(out, { hdr = true, label = "CATEGORIES" })
		for _, c in ipairs(cats) do
			tinsert(out, { cat = c.name, label = c.name, n = c.n })
		end
	end
	return out
end

local function RecipeRows()
	local out = {}
	local queue = GoblinMindCrafting.queue or {}
	local q = ui.search and ui.search:GetText() or ""
	q = (q == "filter recipes…") and "" or q:lower()
	for _, row in ipairs(GM.Crafting.List()) do
		local inSel = ui.selCat and GM.Crafting.CatHas(ui.selCat, row.recipeID)
			or (not ui.selCat and (not ui.selProf
				or GM.Crafting.Prof(row.recipeID) == ui.selProf))
		if inSel
			and (not ui.matsOnly or (row.craftable or 0) > 0)
			and (q == "" or (row.name or ""):lower():find(q, 1, true)) then
			row.queued = queue[row.recipeID] or 0
			out[#out + 1] = row
		end
	end
	return out
end

local DIFF_NAMES = { "optimal", "medium", "easy", "trivial" }

function CU.Refresh()
	if not ui then return end

	-- professions + categories (scrolled)
	local profs = ProfList()
	ui.profOff = math.min(ui.profOff or 0,
		math.max(0, #profs - PROF_ROWS))
	W.ScrollText(ui.profP.count, ui.profOff, PROF_ROWS, #profs)
	for i, r in ipairs(ui.profRows) do
		local p = profs[(ui.profOff or 0) + i]
		if p and p.hdr then
			r:Show()
			r._gmBg:SetColorTexture(GM.RGB("contLowest"))
			r.text:SetText(p.label)
			r.text:SetTextColor(GM.RGB("textDim"))
			r.sub:SetText("")
			r:SetScript("OnClick", nil)
		elseif p then
			r:Show()
			local sel = p.cat and ui.selCat == p.cat
				or (not p.cat and not ui.selCat
					and (p.prof or false) == (ui.selProf or false))
			r._gmBg:SetColorTexture(GM.RGB(sel and "contHighest" or "contLowest"))
			r.text:SetText(p.label)
			r.text:SetTextColor(GM.RGB(p.cat
				and (sel and "accent" or "warn")
				or (p.alt and not sel and "textDim")
				or (sel and "accent" or "text")))
			r.sub:SetText(p.n)
			local key, cat = p.prof, p.cat
			r:SetScript("OnClick", function(_, btn)
				if cat and btn == "RightButton" then
					GM.Crafting.CatDelete(cat)
					if ui.selCat == cat then ui.selCat = nil end
					Footer("category '" .. cat .. "' deleted")
				elseif cat then
					ui.selCat, ui.selProf = cat, nil
				else
					ui.selProf, ui.selCat = key, nil
				end
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
	W.ScrollText(ui.recP.count, ui.recOff, LIST_ROWS, #rows)
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
			-- skill-ups: TradeskillRelativeDifficulty 0-2 grants
			-- (optimal/medium/easy), 3 = trivial is grayed out;
			-- optimal recipes may award >1 (numSkillUps)
			if row.diff and row.diff < 3 then
				r.skill:SetText("▲" .. ((row.nup or 1) > 1
					and row.nup or ""))
				r.skill:Show()
				r.skill:SetTextColor(GM.RGB(
					row.diff == 0 and "warn"
					or row.diff == 1 and "accent" or "pos"))
			else
				r.skill:Hide()
			end
			-- verdict color: can-craft accent, profitable green, loss red —
			-- on EFFECTIVE profit (mats you already own don't count as cost)
			local ep = row.effProfit or row.profit
			local nc = ep and (ep > 0
				and ((row.craftable or 0) > 0 and "accent" or "pos") or "err")
				or "textDim"
			r.name:SetTextColor(GM.NameColor(row.itemID, nc))
			r.profit:SetText(ep and
				(ep > 0 and "+" or "") .. GM.Money(ep) or "—")
			r.profit:SetTextColor(GM.RGB(
				ep and (ep > 0 and "pos" or "err") or "textDim"))
			-- sale volume: ledger feed's units/day for the product
			local vel = row.itemID
				and GM.Price("dbregionsalerate", row.itemID)
			r.sale:SetText(vel and vel > 0 and
				(format("%g", vel) .. "/d") or "—")
			-- on-hand vs raid-everything: bags 2 +5 = 2 craftable now,
			-- +5 more's worth fetchable from bank/alts
			local extra = (row.craftableAll or 0) - (row.craftable or 0)
			r.can:SetText("bags " .. (row.craftable or 0)
				.. (extra > 0 and " +" .. extra or ""))
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
			r:SetScript("OnClick", function(_, btn)
				-- right-click in a category view pulls the recipe out
				if IsShiftKeyDown() and row.itemID then
					GM.ModifiedItemClick(row.itemID)
				elseif btn == "RightButton" and ui.selCat then
					GM.Crafting.CatUnassign(ui.selCat, id)
					Footer("removed from '" .. ui.selCat .. "'")
				else
					ui.sel = id
				end
				CU.Refresh()
			end)
			Tip(r, function()
				local lines = { row.name or "recipe",
					row.prof or "" }
				tinsert(lines, format("cost %s → price %s · profit %s",
					row.cost and GM.Money(row.cost) or "?",
					row.price and GM.Money(row.price) or "?",
					row.profit and GM.Money(row.profit) or "?"))
				if row.effProfit ~= row.profit then
					tinsert(lines, format("with owned mats: cost %s · profit %s (%d%% covered)",
						row.effCost and GM.Money(row.effCost) or "?",
						row.effProfit and GM.Money(row.effProfit) or "?",
						floor((row.coverage or 0) * 100)))
				end
				for _, m in ipairs(row.mats or {}) do
					local have = GM.Crafting.Available(m.id)
					tinsert(lines, format("  %s ×%d  have %d  @%s",
						(GM.QHex(m.id) or "")
							.. (GM.ItemName(m.id) or ("item " .. m.id))
							.. "|r", m.qty, have,
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
	ui.qOff = math.min(ui.qOff or 0, math.max(0, #qs - #ui.qRows))
	W.ScrollText(ui.qP.count, ui.qOff, #ui.qRows, #qs)
	for i, r in ipairs(ui.qRows) do
		local q = qs[(ui.qOff or 0) + i]
		if q then
			r:Show()
			r.name:SetText((q.name or "?") )
			r.name:SetTextColor(GM.NameColor(q.itemID))
			r.qty._id, r.qty._q = q.recipeID, q.qty
			if not r.qty:HasFocus() then r.qty:SetText("×" .. q.qty) end
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
			-- multicraft path; watchdog drops to 1/click if unsupported.
			-- closed line → the secure OPEN overlay takes the click
			-- (only when there's something to make — missing mats
			-- should still reach the footer)
			GateCraft(r.craft, id, q.qty, (q.craftable or 0) > 0)
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
				if IsShiftKeyDown() and q.itemID then
					GM.ModifiedItemClick(q.itemID)
				else
					ui.sel = id
				end
				CU.Refresh()
			end)
			local short = q.qty - (q.craftable or 0)
			Tip(r, function()
				local extra = (q.craftableAll or 0) - (q.craftable or 0)
				local lines = { q.name or "recipe",
					format("queue ×%d · can craft %d on hand%s%s", q.qty,
						q.craftable or 0,
						extra > 0 and format(" · +%d with bank/alts", extra) or "",
						short > 0 and format(" (%d short)", short) or "") }
				for _, m in ipairs(GM.Crafting.MatSources(id, q.qty)) do
					local nm = GM.ItemName(m.id) or ("item " .. m.id)
					if m.fetch > 0 then
						tinsert(lines, format("  fetch %s ×%d (bank/mail/gbank)", nm, m.fetch))
					end
					if m.alt > 0 then
						tinsert(lines, format("  alt has %s ×%d", nm, m.alt))
					end
					if m.buy > 0 then
						tinsert(lines, format("  buy %s ×%d", nm, m.buy))
					end
				end
				if #lines == 2 then tinsert(lines, "all mats on hand") end
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
		ui.detIconBtn.itemID = dr.itemID
		ui.detName:SetText(GM.ItemName(dr.itemID) or dr.name or "?")
		ui.detName:SetTextColor(GM.NameColor(dr.itemID))
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
		local vel = dr.itemID
			and GM.Price("dbregionsalerate", dr.itemID)
		if vel and vel > 0 then
			tinsert(sub, "sells ~" .. format("%g", vel) .. "/day")
		end
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
				local all = GM.Crafting.Available
					and GM.Crafting.Available(mat.id) or have
				m.have:Show()
				m.have:SetText(have .. " / " .. mat.qty
					.. (all > have and " +" .. (all - have) or ""))
				m.have:SetTextColor(GM.RGB(have >= mat.qty and "pos" or "err"))
				m.name:SetTextColor(GM.NameColor(
					have >= mat.qty and mat.id,
					have >= mat.qty and "text" or "warn"))
				Tip(m.hit, function()
					return { GM.ItemName(mat.id) or ("item " .. mat.id),
						format("bags+bank %d · mail/gbank/ah/alts %d · total %d",
							have, all - have, all) }
				end)
			else
				m.icon:Hide()
				m.name:Hide()
				m.have:Hide()
			end
		end
		ui.craft1._gmBg:SetColorTexture(GM.RGB(
			craftable > 0 and "accent" or "contHigh"))
		local opening = GateCraft(ui.craft1, ui.sel, craftable,
			craftable > 0)
		local prof = GM.Crafting.Prof and GM.Crafting.Prof(ui.sel)
		ui.craft1.text:SetText(opening
			and ("OPEN " .. (prof and prof:upper() or "TRADESKILL"))
			or (craftable > 0 and ("CRAFT ×" .. craftable) or "CRAFT"))
		ui.craft1.text:SetTextColor(GM.RGB(
			craftable > 0 and "contLowest" or "textDim"))
		local allCraftable = GM.Crafting.CraftableAll
			and GM.Crafting.CraftableAll(ui.sel) or craftable
		ui.craftHint:SetText(opening
			and "opens the tradeskill · the craft fires when it's live"
			or (craftable > 0
				and ("tradeskill must be open · one click crafts the batch"
					.. (allCraftable > craftable
						and format(" · +%d w/ bank+alts", allCraftable - craftable) or ""))
				or (allCraftable > 0
					and format("0 on hand — %d possible with bank/alts", allCraftable)
					or "missing materials")))
	else
		ui.det:Hide()
	end
end

-- ============ default-frame takeover (TSM parity) ============
-- TRADE_SKILL_SHOW opens OUR window and parks the Blizzard
-- ProfessionsFrame offscreen. Never Hide() it — its OnHide closes the
-- tradeskill session CraftRecipe needs. TSM's Move approach: collapse
-- the UIPanel footprint + pin at 100000,100000 + a SetPoint hook that
-- re-parks it whenever Blizzard's panel manager repositions it.
-- ProfessionsFrame is combat-locked on Forever → lockdown defers to
-- PLAYER_REGEN_ENABLED.

local function DefaultFrame()
	return ProfessionsFrame or TradeSkillFrame
end

-- parking mechanics live in FramePark.lua — shared with VendoringUI's
-- MerchantFrame takeover (offscreen pin, SetPoint re-park hook,
-- UIPanelWindows/UISpecialFrames strip, combat-lockdown deferral)
function CU.ParkDefault()
	GM.FramePark.Park(DefaultFrame())
end

-- installed at load, not lazily on first tradeskill open: K's
-- professions OVERVIEW fires no TRADE_SKILL_SHOW, so the event path
-- never sees it — the native frame's own OnShow is the only signal.
-- The frame may be load-on-demand, so poll until it exists.
local hookedPF
function CU.HookDefault()
	if hookedPF then return end
	local pf = DefaultFrame()
	if not pf then
		CU._hookTries = (CU._hookTries or 0) + 1
		if CU._hookTries < 30 and GM.After then
			GM.After(1, CU.HookDefault)
		end
		return
	end
	hookedPF = pf
	pf:HookScript("OnShow", function()
		if ui and ui.wantDefault then return end
		CU.ParkDefault()
		BuildUI()
		ui.selProf = nil -- overview carries no profession context
		ui.frame:Show()
		CU.Refresh()
		Footer("tradeskill open — BLIZZARD UI gives the "
			.. "default frame back")
	end)
	-- the mirror half of the takeover (TSM parity): K's second press
	-- hides the native frame — ours must follow or there's no way to
	-- tell the session visually ended. The hide itself is enough;
	-- TRADE_SKILL_CLOSE handles the bookkeeping.
	pf:HookScript("OnHide", function()
		if ui and ui.wantDefault then return end
		if ui and ui.frame and ui.frame:IsShown() then
			ui.frame:Hide()
		end
	end)
end

function CU.RestoreDefault()
	GM.FramePark.Restore(DefaultFrame())
end

-- GOBLINMIND button ON the Blizzard frame — the round-trip back once
-- the user has switched to default (TSM's defaultUISwitchBtn)
local function EnsureSwitchBtn()
	local pf = DefaultFrame()
	if not (pf and ui and not ui.switchBtn) then return end
	local b = CreateFrame("Button", nil, pf)
	b:SetSize(84, 16)
	b:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -40, -8)
	b:SetFrameLevel(pf:GetFrameLevel() + 20)
	GM.Panel(b, "accent")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "contLowest")
	b.text:SetPoint("CENTER")
	b.text:SetText("GOBLINMIND")
	b:SetScript("OnClick", function()
		ui.wantDefault = nil
		CU.OnTradeSkillOpen()
	end)
	ui.switchBtn = b
	pf:HookScript("OnShow", function()
		if not ui.wantDefault then CU.ParkDefault() end
	end)
end

-- TRADE_SKILL_CLOSE entry — the session ended, so our window goes
-- with it (TSM parity: their frame closes on the same action). Our
-- OnHide restores the parked frame; CloseTradeSkill stays gated on
-- ui.closing because the client already ended the session itself.
function CU.OnTradeSkillClose()
	if ui and ui.frame and ui.frame:IsShown() then
		ui.frame:Hide()
	end
end

-- TRADE_SKILL_SHOW entry — called from Crafting.lua's event frame
function CU.OnTradeSkillOpen()
	BuildUI()
	EnsureSwitchBtn()
	if ui.wantDefault then return end
	ui.selProf = nil -- scan selects the opened profession (C.lastProf)
	ui.frame:Show()
	CU.Refresh()
	-- say who owns the open — otherwise a user who pressed the default
	-- professions button sees our window appear with no explanation and
	-- no visible route back to the Blizzard frame
	local prof
	if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLine then
		local ok, v = pcall(C_TradeSkillUI.GetTradeSkillLine)
		if ok and type(v) == "string" and v ~= "" then prof = v end
	end
	Footer((prof or "tradeskill")
		.. " open — BLIZZARD UI gives the default frame back")
	-- the frame may not be shown at event time; park now and retry
	CU.ParkDefault()
	GM.After(0.3, CU.ParkDefault)
end

function CU.SelectProf(name)
	if not ui then return end
	if ui.selProf == name then return end
	ui.selProf = name
	ui.recOff = 0
	CU.Refresh()
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
	if ui.frame:IsShown() then
		ui.closing = true -- toggle-off is a deliberate close
		ui.frame:Hide()
	else CU.Show() end
end
