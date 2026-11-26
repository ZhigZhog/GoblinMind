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
	{ key = "gather", label = "GATHER", short = "GTHR" },
	{ key = "auctions", label = "AUCTIONS", short = "AUCT" },
	{ key = "destroy", label = "DESTROY", short = "DSTR" },
	{ key = "settings", label = "SETTINGS", short = "SET" },
}

-- window classes live on each view's GM.View registration now
-- (exclusive/peer/contextual/mode — see ViewMgr.lua). DB.Switch is
-- kept as the tab-strip call shape; the registry decides who a
-- switch disturbs. The planner itself never registers a window
-- def, so nothing can hide it — tabbing never closes it.
function DB.Switch(key)
	GM.View.Switch(key)
end

-- the planner's two tab keys are modes on one window, registered
-- here where the tab strip lives
GM.View.Register("dash", { class = "mode", Show = function()
	GM.PlanQueue.SetHome(true)
	GM.PlanQueue.Show()
end })
GM.View.Register("plan", { class = "mode", Show = function()
	GM.PlanQueue.SetHome(false)
	GM.PlanQueue.Show()
end })

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
	-- step down through label/spacing modes when it would overrun
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
	-- the strip's right bound is the close button's LEFT edge, not
	-- the frame edge — measuring the frame lets the last tab slide
	-- under the X (the report that prompted this)
	local function StripBound()
		return frame.closeBtn and frame.closeBtn.GetLeft
			and frame.closeBtn:GetLeft()
	end
	local bound = StripBound()
	local frameL = frame.GetLeft and frame:GetLeft()
	local avail = (bound and frameL)
		and ((bound - frameL) - titleW - 24)
		or ((frame:GetWidth() or 640) - titleW - 48)
	local total = 0
	for _, t in ipairs(TABS) do
		meas:SetText(t.label)
		total = total + (meas:GetStringWidth() or 40) + 15
	end
	local function build(mode)
		-- 0 = full labels · 1 = short labels · 2 = short + tight gaps
		for _, b in ipairs(frame._gmTabs) do
			b:Hide()
			b:SetParent(nil)
		end
		wipe(frame._gmTabs)
		local gap = mode >= 2 and 2 or 5
		local pad = mode >= 2 and 6 or 10
		local anchor = titleFs
		for _, t in ipairs(TABS) do
			local b = CreateFrame("Button", nil, frame)
			if anchor == titleFs then
				b:SetPoint("LEFT", titleFs, "LEFT", titleW + 8, 0)
			else
				b:SetPoint("LEFT", anchor, "RIGHT", gap, 0)
			end
			b:SetHeight(14)
			local cur = t.key == currentKey
			b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9,
				cur and "accent" or "textDim")
			b.text:SetPoint("CENTER")
			b.text:SetText(mode >= 1 and t.short or t.label)
			-- auto-width from the label — fixed px widths clip the
			-- longer tab names into their neighbours
			b:SetWidth((b.text.GetStringWidth
				and b.text:GetStringWidth() or 40) + pad)
			-- the current destination stays visible and selected — a
			-- disappearing tab shifts every following target under the
			-- cursor
			if cur then
				b.line = b:CreateTexture(nil, "ARTWORK")
				b.line:SetSize(b:GetWidth() - pad, 2)
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
		return mode
	end
	local mode = build(total > avail and 1 or 0)
	-- GetStringWidth under-measures this client's Montserrat bold —
	-- the pre-check can pass while the rendered strip still overruns
	-- the close button. Verify real extents post-layout and step
	-- down a mode until the last tab clears the X (or modes run out)
	local function VerifyFit(mode, retries)
		local last = frame._gmTabs[#frame._gmTabs]
		local lr = last and last.GetRight and last:GetRight()
		local b = StripBound()
		if lr and b then
			if lr > b - 2 and mode < 2 then
				GM.Time.After(0, function() VerifyFit(build(mode + 1), retries) end)
			end
		elseif retries > 0 and GM.Time then
			GM.Time.After(0.2, function() VerifyFit(mode, retries - 1) end)
		end
	end
	if GM.Time then GM.Time.After(0, function() VerifyFit(mode, 2) end) end
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
		GM.View.Show("overview")
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
			local order = GM.Budget.Order and GM.Budget.Order()
			for i, row in ipairs(bRows) do
				local idx = order and order[i] or i
				local a = list[idx]
				if a then
					row:Show()
					row.rst:Show()
					row.del:Show()
					row.kind:Show()
					row.grp:Show()
					row.xfr:Show()
					row.warn:Show()
					Wd.PaintAcctRow(row, a, idx)
				else
					row:Hide()
				end
			end
			if #list == 0 then
				bRows[1]:Show()
				for _, k in ipairs({ "rst", "del", "kind", "grp", "xfr", "warn" }) do
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
