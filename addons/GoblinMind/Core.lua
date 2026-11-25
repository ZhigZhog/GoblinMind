local addonName, GM = ...
-- expose the namespace for /run and external tooling — without this
-- every file-local GM is invisible to the console
GoblinMind = GM
print("GoblinMind: Core.lua executing")

local DEFAULTS = {
	riskBudget = 0.40,      -- max fraction of gold a plan may commit
	minProfitMargin = 0.10, -- stop buying when (p50*0.95 - ask)/ask < this
	maxDaysToClear = 7,     -- warn past this holding period
	dataMaxAge = 7200,      -- seconds before tooltip flags data stale
	minimapAngle = -0.785,  -- button sits bottom-left of the minimap ring
	minimapHide = false,
}

local function ApplyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then dst[k] = v end
	end
end

GM.frame = CreateFrame("Frame")
pcall(GM.frame.RegisterEvent, GM.frame, "ADDON_LOADED")
pcall(GM.frame.RegisterEvent, GM.frame, "PLAYER_LOGIN")
GM.frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == addonName then
		GoblinMindSettings = GoblinMindSettings or {}
		ApplyDefaults(GoblinMindSettings, DEFAULTS)
		GM.db = GoblinMindSettings
		GoblinMindPrices = GoblinMindPrices or { customSources = {} }
		-- GoblinMindDB freezes at load: its emit age only measures
		-- watcher liveness AT LOGIN — capture it now so the bug
		-- reporter doesn't flag a 2h-old session as "no app running"
		GM.emitAgeAtLogin = GM.EmitAge and GM.EmitAge() or nil
		if GM.Ledger then GM.Ledger.Init() end
		if GM.Groups then GM.Groups.Init() end
		if GM.History then GM.History.Init() end
		if GM.Crafting then GM.Crafting.Init() end
		if GM.Budget then GM.Budget.Init() end
		GM.frame:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGIN" then
		GM.MigrateCharKeys()
		if GM.MinimapInit then pcall(GM.MinimapInit) end
		if GM.TickerInit then pcall(GM.TickerInit) end
		-- pre-build the plan window: its ~100 widgets cost real time,
		-- and paying that at first AH open reads as a multi-second
		-- stall. Build hides the frame — visibility follows the AH.
		if GM.PlanQueue and GM.PlanQueue.Prewarm then pcall(GM.PlanQueue.Prewarm) end
		-- a first-load dead font (FONT_MED blanks until /reload) gets a
		-- second shot after Prewarm once the client is fully up
		if GM.FixupFonts then GM.After(1, GM.FixupFonts) end
		GM.Print("loaded — /goblin for the plan window")
	end
end)

GM.log = {}
function GM.Print(...)
	print(GM.CC("accent") .. "GoblinMind|r:", ...)
	-- color-stripped ring buffer — /goblin bug packs the tail into
	-- the report so a stranger sees what the addon just did
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	local line = table.concat(parts, " ")
		:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	GM.log[#GM.log + 1] = line
	if #GM.log > 40 then table.remove(GM.log, 1) end
	-- debug probes opt into a bigger sink — craftdebug/craftprobe
	-- flush it into SV so /reload writes the full output to disk
	if GM.dbgCap then GM.dbgCap[#GM.dbgCap + 1] = line end
end

-- Item-arg parse shared by price/inv: accepts real chat links
-- (|cnQ|Hitem:…h[Name]|h|r on Forever), typed [names], i:id, bare ids.
-- Returns (itemID|nil, remainder-of-input).
local function ParseItemRef(sub)
	local pid, xpr
	pid = tonumber(sub:match("^|c[^|]*|Hitem:(%d+)"))
		or tonumber(sub:match("^|Hitem:(%d+)"))
	if pid then
		local _, e = sub:find("%b[]")
		xpr = e and strtrim((sub:sub(e + 1):gsub("^|?h?|?r?", ""))) or ""
	elseif sub:sub(1, 1) == "[" then
		local name, rest = sub:match("^%[(.-)%]%s*(.*)$")
		local info = C_Item and C_Item.GetItemInfo or GetItemInfo
		local link = name and info and select(2, info(name))
		pid = GM.LinkID(link)
		xpr = strtrim(rest or "")
	else
		local arg
		arg, xpr = sub:match("^(%S+)%s*(.*)$")
		if arg then
			pid = GM.LinkID(arg)
				or tonumber(arg:match("i:(%d+)")) or tonumber(arg)
		end
	end
	return pid, strtrim(xpr or "")
end

SLASH_GOBLINMIND1 = "/goblinmind"
SLASH_GOBLINMIND2 = "/goblin"
SLASH_GOBLINMIND3 = "/gm"

-- /goblin command registry — every command is one ordered entry;
-- ============ slash command API ============
-- GM.Cmd(names, fn, opts) registers a command — opts.prefix
-- (positional bool still accepted), opts.help. GM.CmdRun(msg) is
-- the single execution path: slash handlers, UI buttons, anything
-- can route through it. Match = longest registered name wins, so
-- declaration order can NEVER shadow ("gather" can't eat
-- "gatherreset", "ledger" can't eat "ledger "). Handlers receive
-- (arg, msg): arg = trimmed text after the command name.
GM.CMDS = {}
function GM.Cmd(names, fn, opts)
	if type(names) ~= "table" then names = { names } end
	if type(opts) ~= "table" then opts = { prefix = opts and true or false } end
	for _, n in ipairs(names) do
		GM.CMDS[#GM.CMDS + 1] = {
			n = n, fn = fn,
			p = opts.prefix, h = opts.help,
		}
	end
end
local Cmd = GM.Cmd

local function CmdMatch(c, low)
	if low == c.n then return true end
	if not c.p or low:sub(1, #c.n) ~= c.n then return end
	-- word boundary required unless the name itself ends in one —
	-- a prefix can't shadow a longer command's first chars either
	local nx = low:sub(#c.n + 1, #c.n + 1)
	return c.n:sub(-1) == " " or nx == "" or nx == " "
end

function GM.CmdRun(msg)
	msg = strtrim(tostring(msg or ""))
	local low = strlower(msg)
	local best
	for _, c in ipairs(GM.CMDS) do
		if CmdMatch(c, low) and (not best or #c.n > #best.n
			or (#c.n == #best.n and best.p and not c.p)) then
			best = c
		end
	end
	if best then
		return best.fn(strtrim(msg:sub(#best.n + 1)), msg)
	end
	-- fallback: an item link / id targets it, else the queue opens
	local id = GM.LinkID(msg) or tonumber(msg)
	if id then
		return GM.TargetItem(id, msg)
	end
	return GM.PlanQueue.Toggle()
end

function GM.CmdList()
	local t = {}
	for _, c in ipairs(GM.CMDS) do
		t[#t + 1] = c.n .. (c.h and (" — " .. c.h) or "")
	end
	return t
end

-- dump the raw GetItemInfo fields DisenchantDrops gates on, plus its
-- result — isolates client return-shape quirks vs table bugs
local function CmdDeprobe(arg)
	local id = tonumber(arg:match("(%d+)"))
	if not id then
		local _, link = GameTooltip and GameTooltip:GetItem()
		id = GM.LinkID(link) or GM.lastTooltipItemID
	end
	if not id then GM.Print("usage: /goblin deprobe [itemID] (or hover an item)") return end
	local info = C_Item and C_Item.GetItemInfo or GetItemInfo
	local n, l, q, il, rl, cl, sc, ms, eq, tx, sp, cid = info and info(id)
	local cnt = info and select('#', info(id)) or 0
	local qfn = C_Item and C_Item.GetItemQualityByID
	local lfn = C_Item and C_Item.GetDetailedItemLevelInfo
	local tfn = C_Item and C_Item.GetItemInventoryTypeByID
	local efn = _G.IsEquippableItem
	GM.Print(format("deprobe %d: name=%s q=%s ilvl=%s equipLoc=%s classID=%s (ret=%d)",
		id, tostring(n), tostring(q), tostring(il), tostring(eq), tostring(cid), cnt))
	GM.Print(format("  alt: qByID=%s dlv=%s invType=%s equippable=%s",
		tostring(qfn and qfn(id)), tostring(lfn and lfn(id)),
		tostring(tfn and tfn(id)), tostring(efn and efn(id))))
	for i = 2, min(6, GameTooltip:NumLines() or 0) do
		local fs = _G["GameTooltipTextLeft" .. i]
		local s = fs and fs:GetText()
		if s and s ~= "" and not s:find("Soldier") then
			GM.Print(format("  tipL%d: %s", i, s:sub(1, 40)))
		end
	end
	local d = GM.Destroying and GM.Destroying.DisenchantDrops
	local drops = d and d(id)
	if drops then
		for _, r in ipairs(drops) do
			GM.Print(format("  %s x%d-%d ~%d%%", GM.ItemNameOr(r.id),
				r.lo, r.hi, r.pct))
		end
	else
		GM.Print("  DisenchantDrops = nil")
	end
end

-- 8s activity sample — every suspect path counters at ~0 means the
-- degradation lives outside our handlers entirely
local function CmdPerf()
	local dur = 8
	local c, iw = GM.Crafting, GM.itemWatch
	local g, inv = GM.Gathering, GM.Inventory
	local t0 = {
		scans = c and c._scans or 0,
		reqs = iw and iw.reqs or 0,
		bursts = iw and iw.bursts or 0,
		ievts = iw and iw.evts or 0,
		ticks = g and g._ticks or 0,
		shown = g and g._shownTicks or 0,
		terrs = g and g._tickErrs or 0,
		cost = g and g._costMs or 0,
		pqr = GM.PlanQueue and GM.PlanQueue._refreshes or 0,
		cur = GM.CraftingUI and GM.CraftingUI._refreshes or 0,
		snaps = inv and inv._snaps or 0,
		inbox = inv and inv._inboxScans or 0,
		gb = inv and inv._gbScans or 0,
		lcalls = c and c._listCalls or 0,
		lms = c and c._listMs or 0,
		after = GM._afterCalls or 0,
		ff = GM._ffRuns or 0,
		ev = c and c._ev and {} or nil,
	}
	if t0.ev then for k, v in pairs(c._ev) do t0.ev[k] = v end end
	GM.Print("perf — sampling " .. dur .. "s…")
	GM.After(dur, function()
		local function rate(n) return format("%.1f/s", (n or 0) / dur) end
		local fps = GetFramerate and GetFramerate() or -1
		local tk = (g._ticks or 0) - t0.ticks
		GM.Print(format(
			"perf fps=%.0f: tt-ticks %s (shown %s · %.1fms/s · errs %s) · scans %s · item-reqs %s · info-bursts %s",
			fps,
			rate(tk),
			rate((g._shownTicks or 0) - t0.shown),
			((g._costMs or 0) - t0.cost) / dur,
			rate((g._tickErrs or 0) - t0.terrs),
			rate((c._scans or 0) - t0.scans),
			rate((iw.reqs or 0) - t0.reqs),
			rate((iw.bursts or 0) - t0.bursts)))
		GM.Print(format(
			"  PQ.refresh %s · CU.refresh %s · snaps %s · inbox %s · gbank %s · after %s · fixup %s · C.List %s (%.0fms/s)",
			rate((GM.PlanQueue._refreshes or 0) - t0.pqr),
			rate((GM.CraftingUI._refreshes or 0) - t0.cur),
			rate((inv._snaps or 0) - t0.snaps),
			rate((inv._inboxScans or 0) - t0.inbox),
			rate((inv._gbScans or 0) - t0.gb),
			rate((GM._afterCalls or 0) - t0.after),
			rate((GM._ffRuns or 0) - t0.ff),
			rate((c._listCalls or 0) - t0.lcalls),
			((c._listMs or 0) - t0.lms) / dur))
		if t0.ev then
			local rows = {}
			for k, v in pairs(c._ev or {}) do
				local d = v - (t0.ev[k] or 0)
				if d > 0 then rows[#rows + 1] = { n = d, k = k } end
			end
			table.sort(rows, function(a, b) return a.n > b.n end)
			for i = 1, math.min(6, #rows) do
				GM.Print(format("  ev %s ×%d (%s)",
					rows[i].k, rows[i].n, rate(rows[i].n)))
			end
		end
		-- frame-tree walk: shown frames carrying an OnUpdate script
		-- are the only per-frame script cost in the game — a stray
		-- shown frame (parked, leaked) shows up by name. Every
		-- per-frame call is pcalled — one oddball frame must not
		-- silence the whole walk
		-- frame-tree walk, breadth-first (no depth cap): count every
		-- live frame, and attribute each SHOWN frame with an OnUpdate
		-- script to its top-level ancestor — anonymous frame leaks
		-- still identify their owner by parent name
		local groups, seen, locked = {}, 0, 0
		local q, qi = { UIParent }, 1
		while qi <= #q and seen < 200000 do
			local fr = q[qi]; qi = qi + 1
			seen = seen + 1
			-- the ENTIRE probe must live inside one pcall: this
			-- client returns SECRET booleans/strings from
			-- IsShown/GetName on protected frames, and testing one
			-- outside the pcall throws in tainted context
			local okP = pcall(function()
				if not fr:IsShown() then return end
				if not fr:GetScript("OnUpdate") then return end
				local top, guard = fr, 0
				while guard < 12 do
					guard = guard + 1
					local p = top:GetParent()
					if not p or p == UIParent then break end
					top = p
				end
				local nm = top:GetName()
				if nm == nil then nm = "?" end
				groups[nm] = (groups[nm] or 0) + 1
			end)
			if not okP then locked = locked + 1 end
			local okK, kids = pcall(function()
				return { fr:GetChildren() } end)
			if okK and kids then
				for _, kid in ipairs(kids) do
					q[#q + 1] = kid
				end
			end
		end
		local rows = {}
		for nm, n in pairs(groups) do
			rows[#rows + 1] = { n = n, k = nm }
		end
		table.sort(rows, function(a, b) return a.n > b.n end)
		local nupd = 0
		for _, r in ipairs(rows) do nupd = nupd + r.n end
		GM.Print(format("  frames=%d  onupdate-shown=%d  locked=%d:",
			seen, nupd, locked))
		for i = 1, math.min(8, #rows) do
			GM.Print(format("    %s ×%d", rows[i].k, rows[i].n))
		end
		-- GameTooltip fontstring pool: each AddLine pools a
		-- GameTooltipTextLeftN fontstring forever — a runaway pool
		-- means the re-inject path has been growing it
		local tln = 0
		while _G["GameTooltipTextLeft" .. (tln + 1)] do
			tln = tln + 1
			if tln > 20000 then break end
		end
		local nl = 0
		pcall(function() nl = GameTooltip:NumLines() end)
		GM.Print(format("  tooltip-lines pooled=%d current=%d",
			tln, nl or -1))
		-- Lua heap + per-addon attribution: GC pressure is the other
		-- silent fps killer, and 727MB doesn't explain itself
		-- without knowing whose it is
		GM.Print(format("  lua-mem %.1fMB",
			(collectgarbage("count") or 0) / 1024))
		if GetNumAddOns and GetAddOnInfo
			and GetAddOnMemoryUsage then
			pcall(function()
				if UpdateAddOnMemoryUsage then
					UpdateAddOnMemoryUsage()
				end
				local am = {}
				for i = 1, GetNumAddOns() do
					local nm, _, _, en = GetAddOnInfo(i)
					if en ~= false then
						local m = GetAddOnMemoryUsage(nm)
							or 0
						if m > 0 then
							am[#am + 1] = { n = m, k = nm }
						end
					end
				end
				table.sort(am, function(a, b)
					return a.n > b.n end)
				for i = 1, math.min(6, #am) do
					GM.Print(format("    mem %s %.1fMB",
						am[i].k, am[i].n / 1024))
				end
			end)
		end
		local pl = GM.FramePark and GM.FramePark.ParkedList
			and GM.FramePark.ParkedList() or {}
		GM.Print("  parked: "
			.. (#pl > 0 and table.concat(pl, ", ") or "none"))
		GM.Print("  tradeskill line: "
			.. tostring(c and c.lastProf or "closed"))
	end)
end

local function CmdUiDump()
	local function FrameFor(v)
		if type(v) == "table" then return v end
		if type(v) ~= "string" then return nil end
		if _G[v] then return _G[v] end
		if GetFrameHandleFrame then
			local ok, r = pcall(GetFrameHandleFrame, v)
			if ok and r then return r end
		end
	end
	local bad = 0
	for i, v in ipairs(UISpecialFrames or {}) do
		local f = FrameFor(v)
		local ok, shown = pcall(function() return f and f:IsShown() end)
		if not (ok and f) then
			bad = bad + 1
			GM.Print(GM.CC("err") .. format("UISpecialFrames[%d] = %s -> %s",
				i, tostring(v), f and "no IsShown" or "NIL") .. "|r")
		end
	end
	for k in pairs(UIPanelWindows or {}) do
		if not FrameFor(k) then
			bad = bad + 1
			GM.Print(GM.CC("err") .. "UIPanelWindows[" .. tostring(k)
				.. "] -> NIL (no frame)" .. "|r")
		end
	end
	GM.Print(format("uidump: %d special, %d panel entries — %d bad",
		#(UISpecialFrames or {}), (function()
			local n = 0 for _ in pairs(UIPanelWindows or {}) do n = n + 1 end
			return n end)(), bad))
	if bad == 0 then GM.Print("no broken entries — GoblinMind's are all resolvable") end
end

-- per-container dump: settles "is there a carried bag past the
-- computed range?" — FOREVER QUIRK: bank containers DO enumerate
-- items while the bank frame is closed (which is exactly why the
-- carried-boundary probe needs equip-slot ids, not item presence).
local function CmdBags()
	if not (C_Container and C_Container.GetContainerNumSlots) then
		GM.Print("C_Container unavailable on this client")
		return
	end
	local max = GM.CarriedBagMax()
	GM.Print(format("carriedMax=%d (learned=%s) bankOpen=%s",
		max, tostring(GoblinMindSettings
			and GoblinMindSettings.carriedMax),
		tostring(BankFrame and BankFrame:IsShown())))
	for bag = -3, max + 8 do
		local n = C_Container.GetContainerNumSlots(bag) or 0
		if n > 0 then
			local items, first = 0
			for slot = 1, n do
				local info = C_Container.GetContainerItemInfo(
					bag, slot)
				if info and info.itemID then
					items = items + 1
					if not first then first = info.itemID end
				end
			end
			local tag = bag <= max and "carried" or "?"
			if bag < 0 or bag > max then tag = "bank?" end
			GM.Print(format("  bag %d: %d slots, %d items%s — %s",
				bag, n, items,
				first and (" first=i:" .. first) or "", tag))
		end
	end
end

Cmd("plan", function()
	if not GM.lastTooltipItemID then
		GM.Print("hover an item first, then /goblin plan")
		return
	end
	GM.PlanQueue.SetItem(GM.lastTooltipItemID, GM.lastTooltipLink)
	GM.PlanQueue.Show()
end)
Cmd("bug", function()
	if GM.BugReport then GM.BugReport.Show() end
end)
Cmd("status", function()
	if GM.Mesh and GM.Mesh.Status then GM.Mesh.Status() end
end)
-- onboarding popup doubles as the reconfigure path — a newer staged
-- request overwrites feeds.json (newest wins)
Cmd("backend", function()
	if GM.Onboard then GM.Onboard.Show() end
end)
-- replay first-run: wipe only the wizard's display flags so the next
-- login hits the pristine `not onboarded` branch — book/ledger/
-- groups/backend state all untouched
Cmd("onboard", function()
	if GM.db then
		GM.db.onboarded = nil
		GM.db.obDone = nil
		GM.db.obDismissed = nil
		GM.db.obDbg = nil
	end
	if GM.Onboard then GM.Onboard.Show() end
	GM.Print("onboarding reset — pops at every login until DONE")
end)
Cmd("import", function()
	if GM.Import then GM.Import.Show() end
end)
-- /goblin fontdump — which font each creation path actually resolves
-- to. Text nodes (theme ApplyStyle) vs MakeFontString (ApplyFont
-- probe) should both report a Montserrat path; STANDARD_TEXT_FONT or
-- a client font means that path fell back
Cmd("fontdump", function()
	local function probe(tag, fs)
		local path, size, flags = fs:GetFont()
		GM.Print(tag .. " -> " .. tostring(path) .. " "
			.. tostring(size) .. " " .. tostring(flags))
	end
	local f = CreateFrame("Frame", nil, UIParent)
	probe("MakeFontString", GM.MakeFontString(f, GM.FONT, 11, "text"))
	if GM.ui then
		local fs = f:CreateFontString(nil, "OVERLAY")
		GM.ui:ApplyStyle(fs, "cell")
		probe("ui:Text(cell)", fs)
		GM.ui:ApplyStyle(fs, "value")
		probe("ui:Text(value)", fs)
	end
end)
Cmd("api", function()
	if GM.Onboard then GM.Onboard.Show("api") end
end)
Cmd("options", function()
	if GM.Onboard then GM.Onboard.Show("options") end
end)
Cmd("minimap", function()
	GM.db.minimapHide = not GM.db.minimapHide
	if GM.minimapBtn then GM.minimapBtn:SetShown(not GM.db.minimapHide) end
	GM.Print("minimap button " .. (GM.db.minimapHide and "hidden" or "shown"))
end)
Cmd("groups", function() GM.GroupsUI.Toggle() end, true)
Cmd({ "ops", "operations" }, function() GM.OpsUI.Toggle() end, true)
Cmd("crafts", function() GM.CraftingUI.Toggle() end, true)
Cmd("craftdebug", function(arg)
	GM.Crafting.Debug(arg)
end, true)
Cmd("craftpurge", function(arg)
	local n = GM.Crafting.PurgeProf(arg)
	GM.Print(n > 0 and ("purged " .. n .. " recipes")
		or "nothing purged — no recipes with that profession")
	if GM.CraftingUI and GM.CraftingUI.Refresh then GM.CraftingUI.Refresh() end
end, true)
Cmd("craftprobe", function(arg)
	GM.Crafting.CraftProbe(arg)
end, true)
Cmd("codprobe", function() GM.MailUI.CodProbe() end, true)
Cmd({ "help", "?" }, function()
	GM.Print(table.concat(GM.CmdList(), "  ·  "))
end, { prefix = true, help = "command list" })
Cmd({ "orders", "writs", "writ" }, function()
	if GM.OrdersUI then GM.OrdersUI.Toggle() end
end)
Cmd("board ", function(arg)
	local name = arg
	if name ~= "" and GM.Orders then
		local rid = GM.Orders.JoinBoard(name, true)
		GM.Print("joining board '" .. name ..
			"' (" .. rid .. ") — applies after next flush")
	else
		GM.Print("usage: /goblin board <name>")
	end
end, true)
Cmd("deprobe", CmdDeprobe, true)
Cmd("perf", CmdPerf)
-- perf probe: force-close the held-open tradeskill session (Crafting
-- keeps the line alive for queue crafting). If fps recovers
-- immediately after this, the engine is burning frames on the open
-- line — not our Lua.
Cmd("tsclose", function()
	if C_TradeSkillUI and C_TradeSkillUI.CloseTradeSkill then
		local ok, err = pcall(C_TradeSkillUI.CloseTradeSkill)
		GM.Print("tsclose: " .. tostring(ok and "closed" or err))
	else
		GM.Print("tsclose: C_TradeSkillUI.CloseTradeSkill missing")
	end
	GM.Print("watch fps now — /goblin perf to re-sample")
end)
Cmd("crafttrace", function()
	GM.Crafting.trace = not GM.Crafting.trace
	GM.Print("craft trace " .. (GM.Crafting.trace and "ON" or "OFF"))
end, true)
Cmd("owndump", function() GM.Inventory.DumpOwned() end, true)
Cmd("cancelprobe", function() GM.Inventory.CancelProbe() end, true)
-- font health probe: a dead file reports zero glyph width — catches
-- the first-run stall that blanked FONT_MED labels
Cmd("fontcheck", function()
	for _, pair in ipairs({
		{ "FONT", GM.FONT }, { "MED", GM.FONT_MED },
		{ "BOLD", GM.FONT_BOLD },
	}) do
		local fs = UIParent:CreateFontString(nil, "OVERLAY")
		local ok = fs:SetFont(pair[2], 11, "")
		fs:SetText("probe")
		local w = fs.GetStringWidth and fs:GetStringWidth() or -1
		GM.Print(format("%s set=%s width=%s",
			pair[1], tostring(ok), tostring(w)))
	end
end, true)
Cmd({ "market", "shop" }, function() GM.Shopping.Toggle() end, true)
Cmd("warehouse", function() GM.Banking.WarehousingScan() end, true)
Cmd("bankdebug", function()
	GM.Banking.debug = not GM.Banking.debug
	GM.Print("bank debug " .. (GM.Banking.debug and "ON" or "off"))
end, true)
Cmd("destroy", function() GM.DestroyingUI.Toggle() end, true)
Cmd("destroydemo", function()
	if GM.Destroying.demo then
		GM.Destroying.demo = nil
		GM.Print("destroy demo data cleared")
		GM.DestroyingUI.Refresh()
	else
		GM.Destroying.SeedDemo()
		GM.Print("destroy demo data seeded — /goblin destroydemo to clear")
		GM.DestroyingUI.Show()
	end
end)
Cmd({ "sett", "options" }, function() GM.Settings.Toggle() end, true)
Cmd({ "ledger", "overview" }, function() GM.Overview.Toggle() end, true)
Cmd("ah", function() GM.AHUI.Toggle() end)
Cmd({ "auctions", "myauctions" }, function() GM.MyAuctions.Toggle() end, true)
Cmd({ "dash", "home", "budget" }, function()
	GM.PlanQueue.SetHome(true)
	GM.PlanQueue.Show()
end, true)
Cmd("vendor", function(arg)
	local sub = arg
	if sub:sub(1, 9) == "blacklist" then
		local arg = strtrim(sub:sub(10))
		if arg == "" then
			local n = 0
			for id in pairs(GoblinMindSettings
				and GoblinMindSettings.vendorBlacklist or {}) do
				n = n + 1
				GM.Print("  " .. GM.ItemName(id))
			end
			if n == 0 then GM.Print("vendor blacklist is empty") end
		else
			local pid = ParseItemRef(arg)
			if pid then GM.Vendoring.BlacklistToggle(pid)
			else GM.Print("usage: /goblin vendor blacklist [item|i:id|link]") end
		end
		return
	end
	GM.VendoringUI.Toggle()
end, true)
Cmd("bank", function() GM.BankUI.Toggle() end, true)
Cmd("gbank", function() GM.GBankUI.Toggle() end, true)
Cmd("mail", function() GM.MailUI.Toggle() end, true)
Cmd("snip", function() GM.SniperUI.Toggle() end, true)
Cmd("intel", function() GM.Intel.Dump() end, true)
Cmd("tasks", function() GM.TaskListUI.Toggle() end, true)
Cmd("uidump", CmdUiDump, true)
Cmd("ahdump", function(arg)
	local pid = tonumber(arg) or ParseItemRef(arg)
	GM.AH.DumpRows(pid ~= "" and pid or nil)
end, true)
Cmd("bags", CmdBags, true)
Cmd("inv", function(arg)
	local pid = ParseItemRef(arg)
	if not pid then
		GM.Print("usage: /goblin inv <item|i:id|[name]|link>")
		return
	end
	GM.Inventory.QueryOwned()
	local c = GM.Inventory.Count(pid)
	GM.Print(format("inv %d — bags %d · bank %d · mail %d · gbank %d · posted %d · total %d",
		pid, c.bags, c.bank, c.mail, c.guild, c.auction, c.total))
end, true)
-- trailing space makes this "ledger <n>" — bare "ledger" opens the
-- Overview window above (the old flat-prefix version was dead code)
Cmd("ledger ", function(arg)
	local n = tonumber(arg) or 8
	if not GM.Ledger.db then
		GM.Print("ledger not initialized")
		return
	end
	local rows = GM.Ledger.Recent(n)
	if #rows == 0 then
		GM.Print("ledger empty — buy/post/cancel actions get recorded")
		return
	end
	for _, r in ipairs(rows) do
		GM.Print(format("%s %s id=%d q=%d u=%s",
			date("%H:%M", r.t), r.ty, r.i, r.q,
			r.u and GM.Money(r.u) or "—"))
	end
end, true)
Cmd("price", function(arg)
	local sub = arg
	local name, expr = sub:match("^set%s+(%S+)%s+(.+)$")
	if name then
		GoblinMindPrices.customSources[strlower(name)] = expr
		GM.Print("custom source '" .. strlower(name) .. "' = " .. expr)
		return
	end
	name = sub:match("^unset%s+(%S+)$")
	if name then
		GoblinMindPrices.customSources[strlower(name)] = nil
		GM.Print("custom source '" .. strlower(name) .. "' removed")
		return
	end
	local pid, xpr = ParseItemRef(sub)
	if not pid or not xpr or xpr == "" then
		GM.Print("usage: /goblin price <item|i:id|[name]|link> <expr>")
		GM.Print("  parsed: id=" .. tostring(pid) .. " expr='" .. tostring(xpr) .. "'")
		GM.Print("  raw: " .. sub:gsub("|", "¦"):sub(1, 80))
		return
	end
	local v, err = GM.Pricing.Eval(xpr, pid)
	if v then
		GM.Print(xpr .. " = " .. GM.Money(v) .. " (" .. floor(v) .. "c)")
	else
		GM.Print(GM.CC("err") .. "no value" .. (err and (" — " .. err) or "") .. "|r")
		GM.Print("  parsed: id=" .. pid .. " expr='" .. xpr .. "'")
		GM.Print("  raw: " .. sub:gsub("|", "¦"):sub(1, 80))
	end
end, true)

SlashCmdList.GOBLINMIND = function(msg) GM.CmdRun(msg) end

-- Debounced inbox re-query after a mail loot — CheckInbox needs a beat
-- for the server to settle the deleted mail. Was an identical pair in
-- Banking/MailUI; the armed flag is shared (same action either way).
local pullArmed
function GM.PullInbox()
	if pullArmed or not CheckInbox then return end
	pullArmed = true
	GM.After(0.7, function()
		pullArmed = nil
		pcall(CheckInbox)
		-- the new-mail flag only re-evaluates on UPDATE_PENDING_MAIL,
		-- which lags minutes behind a bulk clear — once the headers
		-- report an empty inbox, hide the minimap icon ourselves
		-- (harmless if headers lag: it re-arms on the next genuine
		-- pending-mail event)
		GM.After(0.5, function()
			-- the flag follows UNREAD headers, not inbox count — a
			-- text-only mail lingers after looting without relighting
			-- the icon. Resolve the mail frame on either minimap
			-- generation (MiniMapMailFrame is absent on the modern
			-- MinimapCluster layout).
			local unread = HasNewMail and HasNewMail()
			if unread == nil then
				local n = GetInboxNumItems and GetInboxNumItems() or 0
				for i = 1, n do
					local wasRead = select(9, GetInboxHeaderInfo(i))
					if wasRead == false then unread = true break end
				end
			end
			if not unread then
				local mailFrame = MiniMapMailFrame
					or (MinimapCluster and MinimapCluster.IndicatorFrame
						and MinimapCluster.IndicatorFrame.MailFrame)
				if mailFrame then mailFrame:Hide() end
			end
		end)
	end)
end

-- Character key "Name-Realm" — the SV per-char bucket key. Shared by
-- Inventory (alt tracking) and Ledger (byChar txns); realm can come
-- back empty on early calls, so don't concat unconditionally.
function GM.CharKey()
	local name = UnitName("player") or "?"
	local realm = GetRealmName and GetRealmName() or ""
	return realm ~= "" and (name .. "-" .. realm) or name
end

-- nil while GetRealmName answers "" — on Forever that's not just early
-- login: it stays empty mid-session and through PLAYER_LOGOUT teardown.
-- Anything that PERSISTS a char key must use this and skip when nil:
-- a bare-name write ("Zhig") reads as a DIFFERENT character once the
-- realm resolves ("Zhig-CAMWOW US1 Realm 5 PvE"), which is how a char's
-- own bags ended up counted as an alt in crafting.
function GM.CharKeyQualified()
	local realm = GetRealmName and GetRealmName() or ""
	if realm == "" then return nil end
	return GM.CharKey()
end

-- Self test for persisted keys: same character iff the name part
-- matches and the key's realm part, when it has one, can't be
-- disproved (realm unknown this session, or the key has none). Char
-- names can't contain "-", so the first dash splits name from realm.
function GM.IsSelfCharKey(key)
	if key == GM.CharKey() then return true end
	local name = UnitName and UnitName("player")
	if not name or name == "" or name == "Unknown Entity" then
		return false
	end
	local kname, krealm = key:match("^(.-)%-(.*)$")
	if not kname then return key == name end
	if kname ~= name then return false end
	local realm = GetRealmName and GetRealmName() or ""
	return realm == "" or krealm == realm
end

-- Fold bare-name keys (written during the empty-realm window) into
-- "Name-<realm>" form inside a char-keyed SV table. merge(old,
-- existing) picks the value kept under the qualified key. Bare keys
-- are assumed to belong to this client's realm — the empty-realm
-- writer was a session on this client, and stale keys were already
-- miscounted as alts, so re-keying is never a regression. Returns
-- true when anything moved.
function GM.CanonicalizeCharKeys(tbl, merge)
	if not tbl then return false end
	local realm = GetRealmName and GetRealmName() or ""
	if realm == "" then return false end
	local moved, stale = false, {}
	for k in pairs(tbl) do
		if not k:find("-", 1, true) then stale[#stale + 1] = k end
	end
	for _, k in ipairs(stale) do
		local t = k .. "-" .. realm
		tbl[t] = merge(tbl[k], tbl[t])
		tbl[k] = nil
		moved = true
	end
	return moved
end

-- One-shot canonicalization, first call after the realm resolves.
-- Triggered from PLAYER_LOGIN plus opportunistically inside Snapshot
-- / AltTotal so a late-resolving realm still cleans up mid-session.
local charMigrated = false
function GM.MigrateCharKeys()
	if charMigrated then return end
	local realm = GetRealmName and GetRealmName() or ""
	if realm == "" then return end
	charMigrated = true
	if GM.Ledger and GM.Ledger.MigrateKeys then
		pcall(GM.Ledger.MigrateKeys)
	end
	if GM.Inventory and GM.Inventory.MigrateKeys then
		pcall(GM.Inventory.MigrateKeys)
	end
	if GM.Budget and GM.Budget.MigrateKeys then
		pcall(GM.Budget.MigrateKeys)
	end
end

-- Realm key matching AppData scopes, e.g. "Normal-Alliance"
function GM.Scope()
	local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
		or (GetRealmName and GetRealmName()) or "Realm"
	local faction = (UnitFactionGroup
		and UnitFactionGroup("player")) or "?"
	return realm .. "-" .. faction
end

-- Seconds since the newest upstream data the generated file used; nil if none.
function GM.DataAge()
	local db = GoblinMindDB
	if not db then return nil end
	local r = db.realms and db.realms[GM.Scope()]
	local t = (r and r.dataAge) or db.dataAge
	if t then return time() - t end
end

-- Three separate clocks (matches TSM's desktop-status tooltip):
-- SyncAge = when our pipeline last emitted (≈ TSM "App Synced"),
-- RealmAge/RegionAge = upstream feed snapshots (TSM's "Realm/Region Data").
function GM.SyncAge()
	if GoblinMindDB and GoblinMindDB.generated then
		return time() - GoblinMindDB.generated
	end
end

function GM.RealmAge()
	if GoblinMindDB and GoblinMindDB.realmAge then
		return time() - GoblinMindDB.realmAge
	end
	return GM.DataAge() -- pre-split generated files: dataAge already is it
end

function GM.RegionAge()
	if GoblinMindDB and GoblinMindDB.regionAge then
		return time() - GoblinMindDB.regionAge
	end
end

-- realm-scoped items win; flat `items` is the single-realm/legacy
-- fallback the brain also fills with the primary scope.
--
-- Universal source pipeline: the emitted row is the base, but
-- OBSERVATION fields (mb/mbx/sup/n — things the AH reported, not
-- model outputs) get overlaid from fresher local sources: the live
-- book when its snapshot is newer than the emit, then mesh beacons
-- newer than both. Model fields (p/mkt/hist/vel/region stats) stay
-- emitted — pricing is the brain's job. `_src`/`_srcT` tag which
-- observation source won, for honest tooltips.
-- Shared memoization shims — the client enforces a hard per-script
-- CPU budget, so render paths can never scan per call. Both bucket
-- on 250ms of GetTime; cached return values are READ-ONLY shared
-- tables by contract (every caller in a bucket gets the same one).
function GM.BucketCache(buildFn)
	local t, v = nil, nil
	return function()
		local b = math.floor(GetTime() * 4)
		if b ~= t then t, v = b, buildFn() end
		return v
	end
end

function GM.BucketMemo(computeFn)
	local t, cache = nil, nil
	return function(key)
		local b = math.floor(GetTime() * 4)
		if b ~= t then t, cache = b, {} end
		local v = cache[key]
		if v == nil then
			v = computeFn(key) or false
			cache[key] = v
		end
		return v or nil
	end
end

-- render paths ask for the same entry hundreds of times (List
-- economics, tooltip sections, queue rows) — the merge is bucket-
-- memoized like the inventory maps. Book/mesh freshness tolerance
-- is a quarter second; entries are read-only by contract.
local itemEntry = GM.BucketMemo(function(itemID)
	local db = GoblinMindDB
	if not db then return nil end
	local r = db.realms and db.realms[GM.Scope()]
	local t = (r and r.items) or db.items
	local e = t and t[itemID]
	local book = GM.AH and GM.AH.book and GM.AH.book[itemID]
	local bookLive = book and GM.AH.BookLive and GM.AH.BookLive()
	local beacon = GM.Mesh and GM.Mesh.LatestMB and GM.Mesh.LatestMB(itemID)
	if not e and not book and not beacon then return nil end
	local out = {}
	if e then for k, v in pairs(e) do out[k] = v end end
	-- book obs overlay: wins when it's the freshest source (BookLive),
	-- and is still the fallback when the emit has no row for the item
	-- at all (stale data with a provenance tag beats a blank)
	if book and (bookLive or not e) then
		out.mb, out.mbx, out.sup, out.n =
			book.mb, book.mbx, book.sup, book.n
		out._src, out._srcT = "book", GM.AH.bookT
	end
	-- a mesh beacon newer than both the book snapshot and the emit is
	-- the freshest min-buyout known — take it for mb AND mbx (beacons
	-- report market min, never "our own cheapest") and ride supply
	if beacon and beacon.t > (out._srcT or db.generated or 0) then
		out.mb = beacon.m
		out.mbx = beacon.m
		if beacon.sup and beacon.sup > 0 then out.sup = beacon.sup end
		out._src, out._srcT = "mesh", beacon.t
	end
	return out
end)
GM.ItemEntry = itemEntry

-- TSM fallback price (copper) — the shim's honest baseline before the model lands.
function GM.TSMMarket(itemID)
	if not TSMAPI_FOUR or not TSMAPI_FOUR.CustomPrice then return end
	local ok, value = pcall(TSMAPI_FOUR.CustomPrice.GetValue, "dbmarket", "i:" .. itemID)
	if ok and type(value) == "number" and value > 0 then
		return value
	end
end

-- carried-bag container range: 0 .. NUM_BAG_SLOTS + reagent slots.
-- Bank bags live PAST it — a hardcoded 0..5 scanned the first bank
-- bag into "bags" whenever the bank was open (mats looked already
-- carried → the planner skipped fetches it should have emitted).
local NUM_CARRIED = (NUM_BAG_SLOTS or 4)
	+ ((Constants and Constants.InventoryConstants
		and Constants.InventoryConstants.NumReagentBagSlots) or 0)

-- ...but Constants can under-report: a client with a reagent or
-- profession bag may carry a container the constants don't know
-- (NumReagentBagSlots absent → bag index 5 sits past the computed
-- range → every item in it invisible to BagCount). FOREVER QUIRK:
-- bank bag contents enumerate while the bank is CLOSED, so "items
-- past NUM_CARRIED while closed" does NOT prove carried — it taught
-- the probe bank bags 5/6 as carried and BagCount read the bank
-- (bug 2026-11-17). The discriminator that can't lie is the bag's
-- own EQUIP slot: carried bags occupy inventory ids 20+ (reagent
-- 24), bank bags 67+. ContainerIDToInventoryID gives it directly;
-- GetInventoryItemLink over the equipped-bag slots is the fallback.
local function ProbeCarried()
	if BankFrame and BankFrame:IsShown() then return end
	local CID2Inv = (C_Container and C_Container.ContainerIDToInventoryID)
		or ContainerIDToInventoryID
	local hi = 0
	if CID2Inv then
		for bag = NUM_CARRIED + 1, NUM_CARRIED + 8 do
			local inv = CID2Inv(bag)
			if not inv then break end
			if inv >= 20 and inv < 60 then hi = bag end
		end
	elseif GetInventoryItemLink then
		-- equipped bag slots: 20..23 bags, 24 reagent — slot s ↔
		-- container s-19
		for slot = NUM_CARRIED + 20, 27 do
			if not GetInventoryItemLink("player", slot) then break end
			hi = slot - 19
		end
	end
	if GoblinMindSettings
		and (hi > NUM_CARRIED and hi or nil)
			~= GoblinMindSettings.carriedMax then
		GoblinMindSettings.carriedMax = hi > NUM_CARRIED and hi or nil
		GM.Print(GM.CC("textDim")
			.. format("[bags] carried range: containers 0..%d|r",
				GM.CarriedBagMax()))
	end
end

function GM.CarriedBagMax()
	return math.max(NUM_CARRIED,
		(GoblinMindSettings and GoblinMindSettings.carriedMax) or 0)
end

-- bank containers: -1 bank frame, -3 reagent bank, then bank bags
-- starting right after the carried range. One list — BankMap,
-- Inventory snapshots, and Banking slots all share it so a learned
-- carried extra shifts the bank range consistently everywhere.
function GM.BankContainerList()
	local first = GM.CarriedBagMax() + 1
	local n = (Constants and Constants.InventoryConstants
		and Constants.InventoryConstants.NumCharacterBankSlots)
		or NUM_BANKBAGSLOTS or 7
	local out = { -1 }
	for b = first, first + n - 1 do out[#out + 1] = b end
	if C_Container and C_Container.GetContainerNumSlots
		and (C_Container.GetContainerNumSlots(-3) or 0) > 0 then
		out[#out + 1] = -3
	end
	return out
end

-- carried containers as a list (0..CarriedBagMax()) — pairs with
-- GM.BankContainerList for the iterator below.
function GM.CarriedContainerList()
	local out = {}
	for b = 0, GM.CarriedBagMax() do out[#out + 1] = b end
	return out
end

-- Normalized slot enumeration over a bag list — the ONE place that
-- owns the dual API shape (C_Container table vs legacy tuple).
-- fn(bag, slot, itemID, stackCount, isLocked, isBound, link);
-- a truthy return from fn stops iteration early.
-- Action paths that need raw per-slot detail (FindInBags,
-- Auctioning.BagItems) iterate this LIVE — counts go through
-- BagMap/BankMap instead.
function GM.EachBagSlot(bags, fn)
	local info = C_Container and C_Container.GetContainerItemInfo
	local num = C_Container and C_Container.GetContainerNumSlots
		or GetContainerNumSlots
	if not (num and bags) then return end
	for _, bag in ipairs(bags) do
		for slot = 1, num(bag) or 0 do
			local id, n, locked, bound, link
			if info then
				local i = info(bag, slot)
				if i then
					id, n = i.itemID, i.stackCount or 1
					locked, bound = i.isLocked, i.isBound
					link = i.hyperlink
				end
			elseif GetContainerItemInfo then
				local _, c, l, _, _, _, lk, _, _, _, b =
					GetContainerItemInfo(bag, slot)
				id = GM.LinkID(lk)
				n, locked, bound, link = c or 1, l, b, lk
			end
			if id and fn(bag, slot, id, n, locked, bound, link) then
				return
			end
		end
	end
end

-- bags gained since a plan step emitted (bagBase is baked at emit) —
-- a manual bank pull or mail collect satisfies a step the same as an
-- executor move, and a covered buy shouldn't spend again.
function GM.BagDelta(step)
	if not (step and step.bagBase and step.itemID) then return 0 end
	return math.max(0, (GM.BagCount(step.itemID) or 0) - step.bagBase)
end

-- Bag contents as a per-bucket map: callers once iterated every
-- slot per query (~120 API calls × recipes × mats on a render = the
-- "insecure scripts exceeded execution limit" kills). One 250ms
-- bucket rebuild serves every itemID lookup.
local probeAt = 0
local BagMap = GM.BucketCache(function()
	local now = GetTime()
	if now - probeAt > 3 then
		probeAt = now
		ProbeCarried()
	end
	local m = {}
	GM.EachBagSlot(GM.CarriedContainerList(),
		function(_, _, id, n)
			m[id] = (m[id] or 0) + n
		end)
	return m
end)

function GM.BagCount(itemID)
	if not itemID then return 0 end
	return (BagMap())[itemID] or 0
end

-- Set of itemIDs in carried bags — keys of the shared BagMap.
function GM.BagItems()
	local set = {}
	for id in pairs(BagMap()) do set[id] = true end
	return set
end

-- Bank contents are only readable while the bank frame is open.
local BankMap = GM.BucketCache(function()
	local m = {}
	if BankFrame and BankFrame:IsShown() then
		GM.EachBagSlot(GM.BankContainerList(),
			function(_, _, id, n)
				m[id] = (m[id] or 0) + n
			end)
	end
	return m
end)

function GM.BankCount(itemID)
	if not itemID then return 0 end
	return (BankMap())[itemID] or 0
end

-- how much of an extended-cost component we carry — the merchant
-- checks bags for item costs and the currency ledger for currency
-- costs, so "have" means the spendable count, not all tracked stock.
-- link: item: / currency: link or nil; cname: currency name fallback.
function GM.CostOwned(link, cname)
	local id = GM.LinkID(link)
	if id then
		local c = GM.Inventory and GM.Inventory.Count(id)
		return (c and c.bags) or 0
	end
	local cid = link and tonumber(link:match("currency:(%d+)"))
	if cid and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local ci = C_CurrencyInfo.GetCurrencyInfo(cid)
		if ci and ci.quantity then return ci.quantity end
	end
	-- name-only currency (no parsable link): scan the currency list
	if cname and C_CurrencyInfo
		and C_CurrencyInfo.GetCurrencyListSize then
		for i = 1, C_CurrencyInfo.GetCurrencyListSize() do
			local e = C_CurrencyInfo.GetCurrencyListInfo(i)
			if e and e.name == cname and not e.isHeader then
				return e.quantity or 0
			end
		end
	end
end

-- merchant slot's extended (alt-currency) cost, decoded:
-- { {icon, qty, link, name, own}, ... } or nil for plain gold items.
-- item links resolve `own` through bags; currency links/names
-- through the currency ledger — the count the merchant checks.
function GM.MerchantAltCost(index)
	if not (GetMerchantItemCostInfo and GetMerchantItemCostItem) then
		return
	end
	local alt
	for j = 1, GetMerchantItemCostInfo(index) or 0 do
		local tex, val, clink, cname =
			GetMerchantItemCostItem(index, j)
		if tex or cname then
			alt = alt or {}
			alt[#alt + 1] = { icon = tex, qty = val or 1,
				link = clink, name = cname,
				own = GM.CostOwned(clink, cname) }
		end
	end
	return alt
end

-- Item name/icon resolution: GetItemInfo returns nil for uncached
-- items — request the load and re-run listeners when the data lands.
-- Listeners register via GM.OnItemInfoLoaded(fn); each event burst
-- coalesces into one refresh pass.
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local GetIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
local ReqLoad = C_Item and C_Item.RequestLoadItemDataByID

GM.itemWatch = { cbs = {} }

-- request each id at most once per TTL — repeat renders of an id the
-- client can't load must not re-request: every request produces a
-- GET_ITEM_INFO_RECEIVED burst, bursts repaint subscribers, repaints
-- re-render the same unresolved ids → a self-sustaining
-- request/render loop that degrades the client until /reload
local reqSent = {}
local function ReqOnce(id)
	if not ReqLoad then return end
	local t = reqSent[id]
	if t and GetTime() - t < 60 then return end
	reqSent[id] = GetTime()
	GM.itemWatch.reqs = (GM.itemWatch.reqs or 0) + 1
	pcall(ReqLoad, id)
end

function GM.ItemName(id)
	if not id then return end
	-- unresolvable ids can THROW on Forever, not just return nil
	local ok, n = pcall(function() return GetInfo and GetInfo(id) end)
	n = ok and n or nil
	-- only a real name string is a result: "" (truthy, poisons
	-- `or` chains) and tables/numbers (SetText fodder — Forever's
	-- custom ids return whatever shape they like) both fail
	if type(n) ~= "string" or n == "" then n = nil end
	if not n then ReqOnce(id) end
	return n
end

function GM.ItemIcon(id)
	if not id then return end
	local ok, icon = pcall(function()
		return GetIcon and GetIcon(id) end)
	icon = ok and icon or nil
	-- valid answers are a fileID number or a texture path —
	-- everything else (0, "", table) means unresolved
	if type(icon) ~= "number" and type(icon) ~= "string" then
		icon = nil
	elseif icon == "" or icon == 0 then
		icon = nil
	end
	if not icon then ReqOnce(id) end
	return icon
end

function GM.ItemNameOr(id)
	return GM.ItemName(id) or ("item " .. id)
end

function GM.ItemQuality(id)
	if not id then return end
	local ok, q = pcall(function()
		return GetInfo and select(3, GetInfo(id)) end)
	q = ok and q or nil
	if type(q) ~= "number" then q = nil end
	if not q then ReqOnce(id) end
	return q
end

-- BuyMerchantItem fails the whole call when the count crosses the
-- item's stack cap ("Internal Bag Error" — issue #21). Chunk the
-- purchase into stack-sized calls; the max stack comes from the
-- item itself (field 8), the merchant's sale stack as fallback,
-- and a single call as last resort
function GM.MerchantBuy(idx, n)
	if not (idx and n and n > 0 and BuyMerchantItem) then return end
	local max
	local link = GetMerchantItemLink and GetMerchantItemLink(idx)
	local id = link and GM.LinkID(link)
	if id and GetInfo then
		local ok, ms = pcall(function()
			return select(8, GetInfo(id)) end)
		if ok and type(ms) == "number" and ms > 0 then max = ms end
	end
	if not max then
		local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo
			and C_MerchantFrame.GetItemInfo(idx)
		max = info and info.stackCount
			and info.stackCount > 0 and info.stackCount or n
	end
	while n > 0 do
		local c = math.min(n, max)
		if not pcall(BuyMerchantItem, idx, c) then break end
		n = n - c
	end
end

-- quality straight off a link's |cnIQN: prefix — item links carry
-- their own display data, which is all we have for items the
-- client's DB can't resolve (Forever customs like 249425)
function GM.LinkQuality(link)
	local q = link and link:match("|cnIQ(%d+):")
	return q and tonumber(q) or nil
end

-- display name straight off a link — [Name] inside the |h|h brackets
function GM.LinkName(link)
	return link and link:match("%[(.-)%]") or nil
end

-- rarity rgb for a FontString; nil -> caller's fallback
local GetQColor = C_Item and C_Item.GetItemQualityColor
function GM.QualityColor(q)
	if q and GetQColor then
		local ok, r, g, b = pcall(GetQColor, q)
		if ok and r then return r, g, b end
	end
	local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c then return c.r, c.g, c.b end
end

-- name-column color: rarity when known, theme key otherwise.
-- One call returns the full r,g,b triple for SetTextColor.
function GM.NameColor(id, fallbackKey)
	local r, g, b = GM.QualityColor(id and GM.ItemQuality(id))
	if r then return r, g, b end
	return GM.RGB(fallbackKey or "text")
end

-- "|cffrrggbb" embed for quality-colored names inside strings;
-- nil when quality unknown so callers can fall back to GM.CC
function GM.QHex(id)
	local r, g, b = GM.QualityColor(id and GM.ItemQuality(id))
	if not r then return end
	return format("|cff%02x%02x%02x",
		floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- Blizzard's default modified-click chain for an item: whatever
-- binding resolves first (CHATLINK/dressup/compare/questwatch)
-- via HandleModifiedItemClick, then the context transfer — bank
-- deposit, vendor sell, mail attach, gbank deposit — when the
-- matching frame is open and the item is in bags. The context
-- path is gated on a frame being open because bare
-- UseContainerItem would otherwise USE the item. Returns true
-- when something fired.
-- rawHMIC is captured at load, BEFORE AHUI wraps the global for
-- its shop-search hook: this function wants Blizzard's default
-- chain, not every installed hook — calling the wrapped global
-- can recurse (C stack overflow on a mat-row click, 2026-11-19).
local rawHMIC = HandleModifiedItemClick
function GM.ModifiedItemClick(id)
	local link = id and GM.ItemLink(id)
	local h = rawHMIC or HandleModifiedItemClick
	if link and h and h(link) then
		return true
	end
	local open = (BankFrame and BankFrame:IsShown())
		or (MerchantFrame and MerchantFrame:IsShown())
		or (MailFrame and MailFrame:IsShown())
		or (GuildBankFrame and GuildBankFrame:IsShown())
	if not open then return end
	local loc = GM.AH and GM.AH.FindInBags and GM.AH.FindInBags(id)
	if loc and loc.GetBagAndSlot then
		local Use = C_Container and C_Container.UseContainerItem
			or UseContainerItem
		if Use then Use(loc:GetBagAndSlot()) return true end
	end
end

-- item:/currency: link (or hyperlink fragment) -> numeric itemID.
-- The "item:(%d+)" pattern in one place — every call site used to
-- re-inline it.
function GM.LinkID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

function GM.ItemLink(id)
	if not id then return end
	return select(2, GetInfo(id)) or nil
end

function GM.OnItemInfoLoaded(fn) tinsert(GM.itemWatch.cbs, fn) end

local iw = CreateFrame("Frame")
pcall(iw.RegisterEvent, iw, "GET_ITEM_INFO_RECEIVED")
iw:SetScript("OnEvent", function(_, e)
	GM.itemWatch.evts = (GM.itemWatch.evts or 0) + 1
	if GM.itemWatch.sched then return end
	GM.itemWatch.sched = true
	GM.itemWatch.bursts = (GM.itemWatch.bursts or 0) + 1
	GM.After(0.25, function()
		GM.itemWatch.sched = nil
		for _, fn in ipairs(GM.itemWatch.cbs) do pcall(fn) end
	end)
end)

-- ===================== map projection =====================
-- C_Map.GetWorldPosFromMapPos AND C_Map.GetMapPosFromWorldPos
-- both return (uiMapID, position) — the position is the SECOND
-- value. Binding the first and indexing it (v.x on a worldID
-- number) throws; a gather-UI centroid did exactly that and
-- froze the map pane on the previous map's tiles. Coords can
-- also come back protected on some builds, so the field reads
-- stay inside a pcall too. Both helpers return nil on any
-- failure — callers treat nil as "can't project", never as
-- zero, and apply their own bounds checks when needed.

-- world yards (north,west on world `worldID`) -> map coords on
-- mapID. Returns x,y in 0..1 space or nil.
--
-- Two projection paths, affine first: the map->world transform
-- is affine on every WoW map, so two corner reads through
-- GetWorldPosFromMapPos pin the inverse exactly — and the answer
-- is frame-exact by construction because it inverts the SAME
-- function our records' n,w were projected through. Forever's
-- GetMapPosFromWorldPos is unreliable (returns nil for in-map
-- positions), which used to leave world->map dead: records fell
-- back to stored x,y and stale-frame coords drew on the wrong
-- zone. Only successes are cached — map data can be unloaded at
-- early login and the next call should retry.
local mapRectCache = {}
function GM.MapPos(worldID, n, w, mapID)
	if not (C_Map and CreateVector2D and n and w and mapID)
		then return end
	local r = mapRectCache[mapID]
	if r == nil then
		if C_Map.GetWorldPosFromMapPos then
			-- three corners pin the full 2x2 affine — axis
			-- conventions differ by client (sim maps n->x, w->y;
			-- retail maps n->y, w->x) so the transform is solved,
			-- not assumed
			local n00, w00, c0 = GM.WorldPos(mapID, 0, 0)
			local n10, w10 = GM.WorldPos(mapID, 1, 0)
			local n01, w01, c1 = GM.WorldPos(mapID, 0, 1)
			if n00 and n10 and n01 and c0 == c1 then
				local a, b = n10 - n00, n01 - n00
				local c, d = w10 - w00, w01 - w00
				local det = a * d - b * c
				if det ~= 0 then
					r = { c = c0, n0 = n00, w0 = w00,
						a = a, b = b, cc = c, d = d,
						det = det }
					mapRectCache[mapID] = r
				end
			end
		end
	end
	if r and (worldID or 0) == r.c then
		local dn, dw = n - r.n0, w - r.w0
		return (dn * r.d - r.b * dw) / r.det,
			(r.a * dw - r.cc * dn) / r.det
	end
	if not C_Map.GetMapPosFromWorldPos then return end
	local ok, _, p = pcall(C_Map.GetMapPosFromWorldPos,
		worldID or 0, CreateVector2D(n, w), mapID)
	local okV, x, y = pcall(function()
		if p and p.x and p.y then return p.x, p.y end
	end)
	if ok and okV and x then return x, y end
end

-- map coords on mapID -> world yards (north,west). Returns
-- n,w,worldID or nil (the id is third so n,w callers are
-- unaffected — world-marks need it to re-project cross-map)
function GM.WorldPos(mapID, x, y)
	if not (C_Map and C_Map.GetWorldPosFromMapPos
		and CreateVector2D and x and y and mapID) then return end
	local ok, wid, p = pcall(C_Map.GetWorldPosFromMapPos,
		mapID, CreateVector2D(x, y))
	local okV, n, w = pcall(function()
		if p and p.x and p.y then return p.x, p.y end
	end)
	if ok and okV and n then return n, w, wid end
end
