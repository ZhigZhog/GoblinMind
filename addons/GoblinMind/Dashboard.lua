local _, GM = ...

-- Part 11: the shell + home. The dashboard is a HOME VIEW mounted
-- inside the main plan window (PQ.SetHome), not its own frame — the
-- minimap button opens the main window in home mode. A shared tab
-- strip on the market/groups windows navigates the module set (each
-- window hides the others and shows the target).

GM.Dashboard = {}
local DB = GM.Dashboard
local W = GM.Widgets

local TABS = {
	{ key = "dash",   label = "HOME",    short = "HOME" },
	{ key = "plan",   label = "PLAN",    short = "PLAN" },
	{ key = "market", label = "MARKET",  short = "MKT" },
	{ key = "groups", label = "GROUPS",  short = "GRPS" },
	{ key = "ops",    label = "OPS",     short = "OPS" },
	{ key = "crafting", label = "CRAFT", short = "CRFT" },
	{ key = "overview", label = "LEDGER", short = "LDGR" },
	{ key = "orders", label = "WRITS",  short = "WRIT" },
	{ key = "auctions", label = "AUCTIONS", short = "AUCT" },
	{ key = "destroy", label = "DESTROY", short = "DSTR" },
	{ key = "settings", label = "SETTINGS", short = "SET" },
}

-- window classes: the planner is a peer of every window — tabbing
-- never closes it. auctions/crafting/destroy also keep each other
-- open; the rest swap one-for-one. (vendor is a contextual takeover
-- window, not a tab — it hides with the exclusive set below.)
local PEERS = { auctions = true, crafting = true, destroy = true }

function DB.Switch(key)
	-- HOME/PLAN is a mode toggle on the planner itself — it must not
	-- disturb any other window
	if key == "dash" or key == "plan" then
		GM.PlanQueue.SetHome(key == "dash")
		GM.PlanQueue.Show()
		return
	end
	-- the planner is a peer of everything — tabbing never closes it.
	-- Exclusive/session windows still go away on a non-peer switch.
	if not PEERS[key] then
		if GM.MyAuctions then GM.MyAuctions.Hide() end
		if GM.CraftingUI then GM.CraftingUI.Hide() end
		if GM.DestroyingUI then GM.DestroyingUI.Hide() end
		if GM.VendoringUI then GM.VendoringUI.Hide() end
	end
	GM.Shopping.Hide()
	GM.GroupsUI.Hide()
	if GM.OpsUI then GM.OpsUI.Hide() end
	if GM.Overview then GM.Overview.Hide() end
	if GM.OrdersUI then GM.OrdersUI.Hide() end
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
	elseif key == "orders" then
		if GM.OrdersUI then GM.OrdersUI.Show() end
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
-- title fontstring. The current window's tab renders selected
-- (accent + underline). Rebuilding
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
	-- the strip must fit the window: measure real string widths and
	-- fall back to compact labels when the full set would run off the
	-- frame's right edge
	local meas = frame._gmTabMeas
	if not meas then
		meas = GM.MakeFontString(frame, GM.FONT_BOLD, 9, "textDim")
		meas:SetTextColor(0, 0, 0, 0) -- measure-only, never painted
		frame._gmTabMeas = meas
	end
	-- anchor against the title's TEXT extent, not its region edge —
	-- callers SetWidth the title fontstring to 400+, so anchoring to
	-- its RIGHT pushed the whole strip to mid-window ("right aligned")
	local titleW = titleFs.GetStringWidth
		and titleFs:GetStringWidth() or 120
	local avail = (frame:GetWidth() or 640) - titleW - 48
	local total = 0
	for _, t in ipairs(TABS) do
		meas:SetText(t.label)
		total = total + (meas:GetStringWidth() or 40) + 15
	end
	local function build(compact)
		for _, b in ipairs(frame._gmTabs) do
			b:Hide()
			b:SetParent(nil)
		end
		wipe(frame._gmTabs)
		local anchor = titleFs
		for _, t in ipairs(TABS) do
			local b = CreateFrame("Button", nil, frame)
			if anchor == titleFs then
				b:SetPoint("LEFT", titleFs, "LEFT", titleW + 8, 0)
			else
				b:SetPoint("LEFT", anchor, "RIGHT", 5, 0)
			end
			b:SetHeight(14)
			local cur = t.key == currentKey
			b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9,
				cur and "accent" or "textDim")
			b.text:SetPoint("CENTER")
			b.text:SetText(compact and t.short or t.label)
			-- auto-width from the label — fixed px widths clip the
			-- longer tab names into their neighbours
			b:SetWidth((b.text.GetStringWidth
				and b.text:GetStringWidth() or 40) + 10)
			-- the current destination stays visible and selected — a
			-- disappearing tab shifts every following target under the
			-- cursor
			if cur then
				b.line = b:CreateTexture(nil, "ARTWORK")
				b.line:SetSize(b:GetWidth() - 10, 2)
				b.line:SetPoint("BOTTOM", 0, -1)
				b.line:SetColorTexture(GM.RGB("accent"))
			end
			local key = t.key
			b:SetScript("OnClick", function() DB.Switch(key) end)
			b:SetScript("OnEnter", function() b.text:SetTextColor(GM.RGB("text")) end)
			b:SetScript("OnLeave", function()
				b.text:SetTextColor(GM.RGB(cur and "accent" or "textDim"))
			end)
			anchor = b
			frame._gmTabs[#frame._gmTabs + 1] = b
		end
	end
	build(total > avail)
	-- GetStringWidth under-measures this client's Montserrat bold —
	-- the pre-check can pass while the rendered strip still overruns
	-- the frame edge. Verify real extents post-layout and rebuild
	-- compact if the last tab doesn't fit inside the window.
	local function VerifyFit(retries)
		local last = frame._gmTabs[#frame._gmTabs]
		local lr = last and last.GetRight and last:GetRight()
		local fr = frame.GetRight and frame:GetRight()
		if lr and fr then
			if lr > fr - 30 then build(true) end
		elseif retries > 0 and GM.After then
			GM.After(0.2, function() VerifyFit(retries - 1) end)
		end
	end
	if GM.After then GM.After(0, function() VerifyFit(2) end) end
end

-- ============ home view ============

local function Panel(f, point, w, h, title)
	local p = W.TitledPanel(f, title)
	p:SetSize(w, h)
	p:SetPoint(unpack(point))
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
		-- a.buyout is already per-item (Forever convention) — no /qty
		if cheapest and a.buyout and a.buyout > cheapest then
			under = under + 1
		end
	end
	if posted > 0 then
		out[#out + 1] = format("%d posted · %s", posted,
			under > 0 and GM.CC("warn") .. under .. " undercut|r"
				or GM.CC("pos") .. "all priced best|r")
		out[#out + 1] = "   → CANCEL SCAN for undercuts"
	end
	-- actionable hits only — the sniper feed's own filters (SOON on
	-- by default) decide what counts; the raw row dump stays out
	local raw = #(GM.Sniper.hits or {})
	local hits = (GM.Sniper.PendingCount and GM.Sniper.PendingCount())
		or raw
	if hits > 0 or raw > 0 then
		out[#out + 1] = format("%s%d sniper hit%s%s|r — MARKET",
			hits > 0 and GM.CC("pos") or GM.CC("textDim"), hits,
			hits == 1 and "" or "s",
			raw > hits and GM.CC("textDim") ..
				format(" (%d filtered)", raw - hits) or "")
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
		fs:SetWordWrap(false)
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
	acctSub:SetWordWrap(false)
	acctSub2:SetJustifyV("TOP")
	local acctSub3 = GM.MakeFontString(acct, GM.FONT, 9, "textDim")
	acctSub3:SetPoint("TOPLEFT", acctSub2, "BOTTOMLEFT", 0, -6)
	acctSub3:SetWidth(half - 20)
	acctSub3:SetJustifyH("LEFT")
	acctSub2:SetWordWrap(false)

	-- BUDGETS: envelope accounts — name · kind · alloc · left · reset/del
	local bud = Panel(host, { "TOPLEFT", 0, -178 }, w, 162, "BUDGETS")
	local toLedger = CreateFrame("Button", nil, bud)
	toLedger:SetSize(60, 14)
	toLedger:SetPoint("TOPRIGHT", -6, -5)
	acctSub3:SetWordWrap(false)
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
	-- account rows share the overview's control set — W.AcctRow +
	-- W.AcctAdd keep kind/group/reset/delete identical on both windows
	local Wd = GM.Widgets
	local bRows = {}
	for i = 1, 5 do
		local row = Wd.AcctRow(bud, i)
		row:SetPoint("TOPLEFT", 8, -20 - (i - 1) * 22)
		row:SetWidth(w - 16)
		bRows[i] = row
	end
	local addRow = Wd.AcctAdd(bud)
	addRow:SetPoint("BOTTOMLEFT", 12, 8)

	local recent = Panel(host, { "TOPLEFT", 0, -348 }, w, 118, "RECENT LEDGER")
	local recentRows = {}
	for i = 1, 5 do
		local fs = GM.MakeFontString(recent, GM.FONT, 10, "textDim")
		fs:SetPoint("TOPLEFT", 10, -22 - (i - 1) * 19)
		fs:SetWidth(w - 20)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
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
					row.kind:Show()
					row.grp:Show()
					Wd.PaintAcctRow(row, a)
				else
					row:Hide()
				end
			end
			if #list == 0 then
				bRows[1]:Show()
				for _, k in ipairs({ "rst", "del", "kind", "grp" }) do
					bRows[1][k]:Hide()
				end
				bRows[1].name:SetText("no accounts — add below")
				bRows[1].name:SetTextColor(GM.RGB("textDim"))
				for _, k in ipairs({ "alloc", "left" }) do
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
					r.ty, (GM.QHex(r.i) or "") ..
						(GM.ItemName(r.i) or ("item " .. r.i)) .. "|r", r.q,
					r.u and GM.Money(r.u) .. " /ea" or "—"))
			else
				fs:SetText("")
			end
		end
	end
end
