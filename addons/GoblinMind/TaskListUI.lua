local _, GM = ...

-- TaskList float (/goblin tasks). A compact peer window listing open
-- work: undercut auctions, pending sniper hits, the active plan,
-- waiting mail, queued/profitable crafts. Each row carries a GO
-- button that jumps to the surface that handles it. Purely a
-- launcher — scans/actions still live in their own modules.

GM.TaskListUI = {}
local TU = GM.TaskListUI
local ui
local W = GM.Widgets
local Btn, Tip = W.Btn, W.Tip

local function AHOpen() return GM.AH.open == true end

-- structured task list — same inputs as Dashboard's TaskLines but
-- each entry carries an action
local function Tasks()
	local t = {}
	-- owned auctions / undercuts
	local posted, under = 0, 0
	for _, a in pairs(GM.Inventory.auctions or {}) do
		posted = posted + 1
		local e = GM.ItemEntry(a.itemID)
		if e and e.mb and a.buyout and a.buyout > e.mb then
			under = under + 1
		end
	end
	if under > 0 then
		t[#t + 1] = {
			text = format("%d of %d posted auctions undercut",
				under, posted),
			key = "warn",
			go = AHOpen() and "CANCEL SCAN" or "open AH",
			fn = function()
				if AHOpen() then GM.Auctioning.CancelScan()
				elseif GM.AHUI and GM.AHUI.Toggle then GM.AHUI.Toggle() end
			end,
		}
	elseif posted > 0 then
		t[#t + 1] = {
			text = format("%d auctions posted · all priced best", posted),
			key = "pos",
		}
	end
	-- sniper hits awaiting action
	local hits = 0
	for _, h in ipairs(GM.Sniper.hits or {}) do
		if not h.done then hits = hits + 1 end
	end
	if hits > 0 then
		t[#t + 1] = {
			text = format("%d sniper hit%s pending", hits,
				hits == 1 and "" or "s"),
			key = "pos",
			go = "SNIPER",
			fn = function() GM.SniperUI.Toggle() end,
		}
	end
	-- active plan
	local PQ = GM.PlanQueue
	if PQ.plan and PQ.plan.steps and PQ.stepIndex <= #PQ.plan.steps then
		local st = PQ.plan.steps[PQ.stepIndex]
		t[#t + 1] = {
			text = format("plan: step %d/%d — %s", PQ.stepIndex,
				#PQ.plan.steps, (st and st.desc) or "…"),
			key = "accent",
			go = "PLAN",
			fn = function() PQ.Show() end,
		}
	end
	-- mail waiting
	local mail = GetInboxNumItems and GetInboxNumItems() or 0
	if mail > 0 then
		t[#t + 1] = {
			text = format("%d mail message%s waiting", mail,
				mail == 1 and "" or "s"),
			key = "text",
			go = "MAIL",
			fn = function() GM.MailUI.Toggle() end,
		}
	end
	-- craft queue
	local queued = 0
	if GM.Crafting.QueueList then
		queued = #GM.Crafting.QueueList()
	end
	if queued > 0 then
		t[#t + 1] = {
			text = format("%d recipe%s in craft queue", queued,
				queued == 1 and "" or "s"),
			key = "text",
			go = "CRAFTS",
			fn = function() GM.CraftingUI.Toggle() end,
		}
	end
	-- profitable craftable recipes
	local crafts = 0
	for _, r in ipairs(GM.Crafting.List()) do
		if r.effProfit and r.effProfit > 0 and r.craftable and r.craftable > 0 then
			crafts = crafts + 1
		end
	end
	if crafts > 0 then
		t[#t + 1] = {
			text = format("%d profitable recipe%s craftable", crafts,
				crafts == 1 and "" or "s"),
			key = "pos",
			go = "MARKET",
			fn = function()
				GM.Shopping.Show()
				GM.Shopping.SetMode("craft")
			end,
		}
	end
	return t
end

-- ============ window ============

local function Build()
	if ui then return end
	ui = {}
	local f = CreateFrame("Frame", "GoblinMindTaskList", UIParent)
	f:SetSize(320, 160)
	f:SetPoint("CENTER", -260, 0)
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
	tinsert(UISpecialFrames, "GoblinMindTaskList")
	ui.frame = f

	local hdr = GM.MakeFontString(f, GM.FONT, 14, "accent")
	hdr:SetPoint("TOPLEFT", 10, -8)
	hdr:SetText("TASKS")

	local x = Btn(f, 18, "x", function() f:Hide() end)
	x:SetPoint("TOPRIGHT", -8, -8)
	Tip(x, "close")

	ui.rows = {}
	ui.body = f
	local pollT = 0
	f:SetScript("OnUpdate", function(_, e)
		pollT = pollT + e
		if pollT >= 1 then pollT = 0; TU.Refresh() end
	end)
	f:SetScript("OnShow", function() TU.Refresh() end)
end

function TU.Refresh()
	if not (ui and ui.frame:IsShown()) then return end
	local tasks = Tasks()
	for i, row in ipairs(ui.rows) do
		if i > #tasks then row:Hide() end
	end
	local y = -28
	for i, task in ipairs(tasks) do
		local row = ui.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, ui.body)
			row:SetSize(300, 22)
			row.txt = GM.MakeFontString(row, GM.FONT, 11, "text")
			row.txt:SetPoint("LEFT", 8, 0)
			row.txt:SetWidth(210)
			row.txt:SetMaxLines(1)
			row.go = Btn(row, 76, "", function() end)
			row.go:SetPoint("RIGHT", -6, 0)
			ui.rows[i] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, y)
		row.txt:SetText(GM.CC(task.key or "text") .. task.text .. "|r")
		if task.go then
			row.go.text:SetText(task.go)
			row.go:SetScript("OnClick", task.fn)
			row.go:Show()
			row.txt:SetWidth(210)
		else
			row.go:Hide()
			row.txt:SetWidth(290)
		end
		row:Show()
		y = y - 24
	end
	local h = math.max(64, 34 + #tasks * 24)
	ui.frame:SetHeight(h)
	if #tasks == 0 then
		local row = ui.rows[1]
		if not row then
			row = CreateFrame("Frame", nil, ui.body)
			row:SetSize(300, 22)
			row.txt = GM.MakeFontString(row, GM.FONT, 11, "textDim")
			row.txt:SetPoint("LEFT", 8, 0)
			row.go = Btn(row, 76, "", function() end)
			row.go:Hide()
			ui.rows[1] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, -28)
		row.txt:SetText(GM.CC("textDim") ..
			"nothing open — scans generate work here|r")
		row.go:Hide()
		row:Show()
	end
end

function TU.IsOpen() return ui and ui.frame:IsShown() end

function TU.Show()
	Build()
	ui.frame:Show()
	TU.Refresh()
end

function TU.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else TU.Show() end
end
