local _, GM = ...

-- Part 11: the shell + home. The dashboard is a HOME VIEW mounted
-- inside the main plan window (PQ.SetHome), not its own frame — the
-- minimap button opens the main window in home mode. A shared tab
-- strip on the market/groups windows navigates the module set (each
-- window hides the others and shows the target).

GM.Dashboard = {}
local DB = GM.Dashboard

local TABS = {
	{ key = "dash",   label = "HOME" },
	{ key = "plan",   label = "PLAN" },
	{ key = "market", label = "MARKET" },
	{ key = "groups", label = "GROUPS" },
	{ key = "ops",    label = "OPS" },
	{ key = "crafting", label = "CRAFT" },
	{ key = "overview", label = "LEDGER" },
	{ key = "auctions", label = "AUCTIONS" },
	{ key = "destroy", label = "DESTROY" },
	{ key = "settings", label = "SETTINGS" },
}

-- window classes: the planner + auctions + crafting + destroy are
-- peers — opening one never hides another. The rest swap one-for-one.
-- (vendor is a contextual takeover window, not a tab — it hides with
-- the exclusive set in the block below.)
local PEERS = { auctions = true, crafting = true, destroy = true }

function DB.Switch(key)
	-- HOME/PLAN is a mode toggle on the planner itself — it must not
	-- disturb any other window
	if key == "dash" or key == "plan" then
		GM.PlanQueue.SetHome(key == "dash")
		GM.PlanQueue.Show()
		return
	end
	-- peers keep the planner and each other open; everything exclusive
	-- still goes away
	if not PEERS[key] then
		GM.PlanQueue.Hide()
		if GM.MyAuctions then GM.MyAuctions.Hide() end
		if GM.CraftingUI then GM.CraftingUI.Hide() end
		if GM.DestroyingUI then GM.DestroyingUI.Hide() end
		if GM.VendoringUI then GM.VendoringUI.Hide() end
	end
	GM.Shopping.Hide()
	GM.GroupsUI.Hide()
	if GM.OpsUI then GM.OpsUI.Hide() end
	if GM.Overview then GM.Overview.Hide() end
	if GM.Settings then GM.Settings.Hide() end
	if key == "market" then
		GM.Shopping.Show()
	elseif key == "groups" then
		GM.GroupsUI.Show()
	elseif key == "ops" then
		if GM.OpsUI then GM.OpsUI.Show() end
	elseif key == "crafting" then
		if GM.CraftingUI then GM.CraftingUI.Show() end
	elseif key == "overview" then
		if GM.Overview then GM.Overview.Show() end
	elseif key == "auctions" then
		if GM.MyAuctions then GM.MyAuctions.Show() end
	elseif key == "destroy" then
		if GM.DestroyingUI then GM.DestroyingUI.Show() end
	elseif key == "vendor" then
		if GM.VendoringUI then GM.VendoringUI.Show() end
	elseif key == "settings" then
		if GM.Settings then GM.Settings.Show() end
	end
end

-- shared tab strip: small text tabs anchored after the window's
-- title fontstring. The current window's tab is omitted. Rebuilding
-- is supported (call again when the current key changes — e.g. the
-- main window's dash↔plan mode) — prior tabs are released first.
function DB.AddTabs(frame, titleFs, currentKey)
	if frame._gmTabKey == currentKey then return end
	frame._gmTabKey = currentKey
	if frame._gmTabs then
		for _, b in ipairs(frame._gmTabs) do
			b:Hide()
			b:SetParent(nil)
		end
	end
	frame._gmTabs = {}
	local anchor = titleFs
	for _, t in ipairs(TABS) do
		if t.key ~= currentKey then
			local b = CreateFrame("Button", nil, frame)
			b:SetPoint("LEFT", anchor, "RIGHT", 5, 0)
			b:SetHeight(14)
			b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
			b.text:SetPoint("CENTER")
			b.text:SetText(t.label)
			-- auto-width from the label — fixed px widths clip the
			-- longer tab names into their neighbours
			b:SetWidth((b.text.GetStringWidth
				and b.text:GetStringWidth() or 40) + 10)
			local key = t.key
			b:SetScript("OnClick", function() DB.Switch(key) end)
			b:SetScript("OnEnter", function() b.text:SetTextColor(GM.RGB("text")) end)
			b:SetScript("OnLeave", function() b.text:SetTextColor(GM.RGB("textDim")) end)
			anchor = b
			frame._gmTabs[#frame._gmTabs + 1] = b
		end
	end
end

-- ============ home view ============

local function Panel(f, point, w, h, title)
	local p = CreateFrame("Frame", nil, f)
	p:SetSize(w, h)
	p:SetPoint(unpack(point))
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	return p
end

local function TaskLines()
	local out = {}
	-- owned auctions / undercuts
	local posted, under = 0, 0
	for _, a in pairs(GM.Inventory.auctions or {}) do
		posted = posted + 1
		local e = GM.ItemEntry(a.itemID)
		local cheapest = e and e.mb
		if cheapest and a.buyout and a.qty and a.qty > 0
			and a.buyout / a.qty > cheapest then
			under = under + 1
		end
	end
	if posted > 0 then
		out[#out + 1] = format("%d posted · %s", posted,
			under > 0 and GM.CC("warn") .. under .. " undercut|r"
				or GM.CC("pos") .. "all priced best|r")
		out[#out + 1] = "   → CANCEL SCAN for undercuts"
	end
	local hits = #(GM.Sniper.hits or {})
	if hits > 0 then
		out[#out + 1] = format("%s%d sniper hit%s|r — MARKET",
			GM.CC("pos"), hits, hits == 1 and "" or "s")
	end
	local mail = GetInboxNumItems and GetInboxNumItems() or 0
	if mail > 0 then
		out[#out + 1] = format("%d mail message%s waiting", mail,
			mail == 1 and "" or "s")
	end
	local crafts = 0
	for _, r in ipairs(GM.Crafting.List()) do
		if r.profit and r.profit > 0 and r.craftable and r.craftable > 0 then
			crafts = crafts + 1
		end
	end
	if crafts > 0 then
		out[#out + 1] = format("%d profitable recipe%s craftable — MARKET · CRAFT",
			crafts, crafts == 1 and "" or "s")
	end
	if #out == 0 then
		out[1] = "nothing open — scans generate work here"
	end
	return out
end

local function EditBox(parent, w)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, 20)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(5, 4, 0, 0)
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(GM.RGB("contLowest"))
	eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
	return eb
end

-- Mounts the dashboard panels into a host frame (the plan window's
-- home overlay) and returns a refresh function.
function DB.MountHome(host)
	local w = host:GetWidth() or 680
	if w <= 0 then w = 680 end
	local half = (w - 10) / 2

	local tasks = Panel(host, { "TOPLEFT", 0, 0 }, half, 170, "TASKS")
	local taskRows = {}
	for i = 1, 6 do
		local fs = GM.MakeFontString(tasks, GM.FONT, 10, "text")
		fs:SetPoint("TOPLEFT", 10, -24 - (i - 1) * 22)
		fs:SetWidth(half - 20)
		fs:SetJustifyH("LEFT")
		taskRows[i] = fs
	end

	local acct = Panel(host, { "TOPLEFT", half + 10, 0 }, half, 170, "ACCOUNT")
	local gold = GM.MakeFontString(acct, GM.FONT_BOLD, 14, "accent")
	gold:SetPoint("TOPLEFT", 10, -26)
	local acctSub = GM.MakeFontString(acct, GM.FONT, 9, "secondary")
	acctSub:SetPoint("TOPLEFT", gold, "BOTTOMLEFT", 0, -6)
	acctSub:SetWidth(half - 20)
	acctSub:SetJustifyH("LEFT")
	local acctSub2 = GM.MakeFontString(acct, GM.FONT, 9, "textDim")
	acctSub2:SetPoint("TOPLEFT", acctSub, "BOTTOMLEFT", 0, -6)
	acctSub2:SetWidth(half - 20)
	acctSub2:SetJustifyH("LEFT")
	acctSub2:SetJustifyV("TOP")
	local acctSub3 = GM.MakeFontString(acct, GM.FONT, 9, "textDim")
	acctSub3:SetPoint("TOPLEFT", acctSub2, "BOTTOMLEFT", 0, -6)
	acctSub3:SetWidth(half - 20)
	acctSub3:SetJustifyH("LEFT")

	-- BUDGETS: envelope accounts — name · kind · alloc · left · reset/del
	local bud = Panel(host, { "TOPLEFT", 0, -178 }, w, 162, "BUDGETS")
	local toLedger = CreateFrame("Button", nil, bud)
	toLedger:SetSize(60, 14)
	toLedger:SetPoint("TOPRIGHT", -6, -5)
	toLedger.text = GM.MakeFontString(toLedger, GM.FONT_BOLD, 9, "textDim")
	toLedger.text:SetPoint("CENTER")
	toLedger.text:SetText("LEDGER →")
	toLedger:SetScript("OnClick", function()
		if GM.Overview then GM.Overview.Show() end
	end)
	toLedger:SetScript("OnEnter", function()
		toLedger.text:SetTextColor(GM.RGB("accent"))
	end)
	toLedger:SetScript("OnLeave", function()
		toLedger.text:SetTextColor(GM.RGB("textDim"))
	end)
	local bRows = {}
	for i = 1, 5 do
		local row = CreateFrame("Frame", nil, bud)
		row:SetSize(w - 16, 22)
		row:SetPoint("TOPLEFT", 8, -20 - (i - 1) * 22)
		row.name = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetWidth(170)
		row.name:SetJustifyH("LEFT")
		row.kind = GM.MakeFontString(row, GM.FONT_MED, 9, "secondary")
		row.kind:SetPoint("LEFT", 180, 0)
		row.alloc = GM.MakeFontString(row, GM.FONT, 10, "text")
		row.alloc:SetPoint("LEFT", 240, 0)
		row.left = GM.MakeFontString(row, GM.FONT, 10, "textDim")
		row.left:SetPoint("LEFT", 370, 0)
		row.left:SetWidth(240)
		row.left:SetJustifyH("LEFT")
		local rst = CreateFrame("Button", nil, row)
		rst:SetSize(18, 18)
		rst:SetPoint("RIGHT", -22, 0)
		rst.text = GM.MakeFontString(rst, GM.FONT_BOLD, 9, "textDim")
		rst.text:SetPoint("CENTER")
		rst.text:SetText("r")
		local idx = i
		rst:SetScript("OnClick", function()
			if GM.Budget then GM.Budget.ResetSpent(idx) end
			GM.PlanQueue.Refresh()
		end)
		rst:SetScript("OnEnter", function()
			GameTooltip:SetOwner(rst, "ANCHOR_TOP")
			GameTooltip:SetText("reset spent to zero", 1, 1, 1)
			GameTooltip:Show()
		end)
		rst:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.rst = rst
		local del = CreateFrame("Button", nil, row)
		del:SetSize(18, 18)
		del:SetPoint("RIGHT", -2, 0)
		del.text = GM.MakeFontString(del, GM.FONT_BOLD, 10, "textDim")
		del.text:SetPoint("CENTER")
		del.text:SetText("x")
		del:SetScript("OnClick", function()
			if GM.Budget then GM.Budget.Del(idx) end
			GM.PlanQueue.Refresh()
		end)
		row.del = del
		bRows[i] = row
	end

	-- add row: name · kind toggle · amount · +
	local addName = EditBox(bud, 150)
	addName:SetPoint("BOTTOMLEFT", 12, 8)
	addName:SetText("name")
	addName:SetTextColor(GM.RGB("textDim"))
	addName:SetScript("OnEditFocusGained", function()
		if addName:GetText() == "name" then
			addName:SetText("")
			addName:SetTextColor(GM.RGB("text"))
		end
	end)
	local kindBtn = CreateFrame("Button", nil, bud)
	kindBtn:SetSize(56, 20)
	kindBtn:SetPoint("LEFT", addName, "RIGHT", 8, 0)
	GM.Panel(kindBtn, "contHigh")
	kindBtn.text = GM.MakeFontString(kindBtn, GM.FONT_MED, 9, "secondary")
	kindBtn.text:SetPoint("CENTER")
	local addKind = "craft"
	local function PaintKind()
		kindBtn.text:SetText(GM.Budget.KINDS[addKind])
	end
	PaintKind()
	kindBtn:SetScript("OnClick", function()
		local order = GM.Budget.KIND_ORDER
		for i, k in ipairs(order) do
			if k == addKind then
				addKind = order[i % #order + 1]
				break
			end
		end
		PaintKind()
	end)
	local addAmt = EditBox(bud, 90)
	addAmt:SetPoint("LEFT", kindBtn, "RIGHT", 8, 0)
	addAmt:SetText("0g")
	local addBtn = CreateFrame("Button", nil, bud)
	addBtn:SetSize(26, 20)
	addBtn:SetPoint("LEFT", addAmt, "RIGHT", 8, 0)
	GM.Panel(addBtn, "accent")
	addBtn.text = GM.MakeFontString(addBtn, GM.FONT_BOLD, 11, "contLowest")
	addBtn.text:SetPoint("CENTER")
	addBtn.text:SetText("+")
	local addHint = GM.MakeFontString(bud, GM.FONT, 9, "textDim")
	addHint:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
	addHint:SetJustifyH("LEFT")
	addBtn:SetScript("OnClick", function()
		local name = addName:GetText()
		if name == "name" then name = "" end
		local amt = addAmt:GetText()
		-- bare number = gold for budgets (500 → 500g), % for saves
		local alloc = addKind == "save" and tonumber(amt:gsub("%%", ""))
			or (tonumber(amt) and floor(tonumber(amt) * 10000)
				or GM.Budget.ParseMoney(amt))
		local a = alloc and GM.Budget.Add(name, addKind, alloc)
		GM.PlanQueue.Refresh()
		if a then
			addName:SetText("")
			addAmt:SetText(addKind == "save" and "30" or "0g")
			addHint:SetText("craft/ah: gold (500 or 10g50s) · save: %")
		else
			addHint:SetText(GM.CC("err") ..
				(addKind == "save" and "need a % (0-100)"
					or "bad amount — try 10g, 5s, 2500c") .. "|r")
		end
	end)
	addHint:SetText("craft/ah: gold (500 or 10g50s) · save: %")

	local recent = Panel(host, { "TOPLEFT", 0, -348 }, w, 118, "RECENT LEDGER")
	local recentRows = {}
	for i = 1, 5 do
		local fs = GM.MakeFontString(recent, GM.FONT, 10, "textDim")
		fs:SetPoint("TOPLEFT", 10, -22 - (i - 1) * 19)
		fs:SetWidth(w - 20)
		fs:SetJustifyH("LEFT")
		recentRows[i] = fs
	end

	return function()
		local lines = TaskLines()
		for i, fs in ipairs(taskRows) do
			fs:SetText(lines[i] or "")
		end

		if GM.Budget then
			local list = GM.Budget.List()
			for i, row in ipairs(bRows) do
				local a = list[i]
				if a then
					row:Show()
					row.rst:Show()
					row.del:Show()
					row.name:SetText(a.name ..
						(a.group and (GM.CC("secondary") .. "·" ..
							a.group .. "|r") or ""))
					row.kind:SetText(GM.Budget.KINDS[a.kind])
					row.alloc:SetText(GM.Budget.AllocText(a))
					local rem = GM.Budget.Remaining(a)
					if a.kind == "save" then
						row.left:SetText("reserved " .. GM.Money(rem))
						row.left:SetTextColor(GM.RGB("accent"))
					else
						row.left:SetText("left " .. GM.Money(rem)
							.. " · spent " .. GM.Money(a.spent or 0))
						row.left:SetTextColor(GM.RGB(rem > 0 and "textDim" or "err"))
					end
				else
					row:Hide()
				end
			end
			if #list == 0 then
				bRows[1]:Show()
				bRows[1].rst:Hide()
				bRows[1].del:Hide()
				bRows[1].name:SetText("no accounts — add below")
				bRows[1].name:SetTextColor(GM.RGB("textDim"))
				for _, k in ipairs({ "kind", "alloc", "left" }) do
					bRows[1][k]:SetText("")
				end
			else
				bRows[1].name:SetTextColor(GM.RGB("text"))
			end
		end

		gold:SetText(GM.Money(GetMoney and GetMoney() or 0))
		local age = GM.DataAge()
		local bAge = GM.AH.BookAge and GM.AH.BookAge()
		acctSub:SetText(format("%s · %s · %d ledger records",
			age and (age >= 3600 and format("DB %dh %dm", age / 3600, age % 3600 / 60)
				or format("DB %dm", age / 60)) or "no DB",
			bAge and bAge < math.huge and format("book %dm", bAge / 60) or "no book",
			GM.Ledger.db and #GM.Ledger.db.transactions or 0))
		local spent, earned = 0, 0
		if GM.Ledger.db then
			for _, r in ipairs(GM.Ledger.db.transactions) do
				if r.ty == "buy" then spent = spent + (r.u or 0) * (r.q or 0)
				elseif r.ty == "sell" then earned = earned + (r.u or 0) * (r.q or 0) end
			end
		end
		acctSub2:SetText(format("ledger: %s in · %s out",
			GM.Money(earned), GM.Money(spent)))
		if GM.Budget then
			acctSub3:SetText(format("envelope: %s free · %s earmarked",
				GM.Money(GM.Budget.Free()),
				GM.Money(math.max(0,
					(GetMoney and GetMoney() or 0) - GM.Budget.Free()))))
		end

		local rec = GM.Ledger.Recent(#recentRows)
		for i, fs in ipairs(recentRows) do
			local r = rec[i]
			if r then
				fs:SetText(format("%s  %s  %s ×%d  %s", date("%H:%M", r.t),
					r.ty, GM.ItemName(r.i) or ("item " .. r.i), r.q,
					r.u and GM.Money(r.u) .. " /ea" or "—"))
			else
				fs:SetText("")
			end
		end
	end
end
