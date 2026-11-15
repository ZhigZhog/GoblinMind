local addonName, GM = ...
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
		if GM.Ledger then GM.Ledger.Init() end
		if GM.Groups then GM.Groups.Init() end
		if GM.History then GM.History.Init() end
		if GM.Crafting then GM.Crafting.Init() end
		if GM.Budget then GM.Budget.Init() end
		GM.frame:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGIN" then
		if GM.MinimapInit then pcall(GM.MinimapInit) end
		-- pre-build the plan window: its ~100 widgets cost real time,
		-- and paying that at first AH open reads as a multi-second
		-- stall. Build hides the frame — visibility follows the AH.
		if GM.PlanQueue and GM.PlanQueue.Prewarm then pcall(GM.PlanQueue.Prewarm) end
		GM.Print("loaded — /gm for the plan window")
	end
end)

function GM.Print(...)
	print(GM.CC("accent") .. "GoblinMind|r:", ...)
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
		pid = link and tonumber(link:match("item:(%d+)"))
		xpr = strtrim(rest or "")
	else
		local arg
		arg, xpr = sub:match("^(%S+)%s*(.*)$")
		if arg then
			pid = tonumber(arg:match("item:(%d+)"))
				or tonumber(arg:match("i:(%d+)")) or tonumber(arg)
		end
	end
	return pid, strtrim(xpr or "")
end

SLASH_GOBLINMIND1 = "/goblinmind"
SLASH_GOBLINMIND2 = "/goblin"
SLASH_GOBLINMIND3 = "/gm"
SlashCmdList.GOBLINMIND = function(msg)
	msg = strtrim(msg or "")
	if msg == "plan" then
		if not GM.lastTooltipItemID then
			GM.Print("hover an item first, then /gm plan")
			return
		end
		GM.PlanQueue.SetItem(GM.lastTooltipItemID, GM.lastTooltipLink)
		GM.PlanQueue.Show()
		return
	end
	if msg == "minimap" then
		GM.db.minimapHide = not GM.db.minimapHide
		if GM.minimapBtn then GM.minimapBtn:SetShown(not GM.db.minimapHide) end
		GM.Print("minimap button " .. (GM.db.minimapHide and "hidden" or "shown"))
		return
	end
	if msg:sub(1, 6) == "groups" then
		GM.GroupsUI.Toggle()
		return
	end
	if msg:sub(1, 3) == "ops" or msg:sub(1, 10) == "operations" then
		GM.OpsUI.Toggle()
		return
	end
	if msg:sub(1, 6) == "crafts" then
		GM.CraftingUI.Toggle()
		return
	end
	if msg:sub(1, 10) == "craftdebug" then
		GM.Crafting.Debug(strtrim(msg:sub(11)))
		return
	end
	if msg:sub(1, 10) == "craftprobe" then
		GM.Crafting.CraftProbe(strtrim(msg:sub(11)))
		return
	end
	if msg:sub(1, 6) == "market" or msg:sub(1, 4) == "shop" then
		GM.Shopping.Toggle()
		return
	end
	if msg:sub(1, 9) == "warehouse" then
		GM.Banking.WarehousingScan()
		return
	end
	if msg:sub(1, 9) == "bankdebug" then
		GM.Banking.debug = not GM.Banking.debug
		GM.Print("bank debug " .. (GM.Banking.debug and "ON" or "off"))
		return
	end
	if msg:sub(1, 7) == "destroy" then
		GM.DestroyingUI.Toggle()
		return
	end
	if msg:sub(1, 4) == "sett" or msg:sub(1, 7) == "options" then
		GM.Settings.Toggle()
		return
	end
	if msg:sub(1, 6) == "ledger" or msg:sub(1, 8) == "overview" then
		GM.Overview.Toggle()
		return
	end
	if msg == "ah" then
		GM.AHUI.Toggle()
		return
	end
	if msg:sub(1, 8) == "auctions" or msg:sub(1, 10) == "myauctions" then
		GM.MyAuctions.Toggle()
		return
	end
	if msg:sub(1, 4) == "dash" or msg == "home" or msg:sub(1, 6) == "budget" then
		GM.PlanQueue.SetHome(true)
		GM.PlanQueue.Show()
		return
	end
	if msg:sub(1, 6) == "vendor" then
		local sub = strtrim(msg:sub(7))
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
		return
	end
	if msg:sub(1, 4) == "bank" then
		GM.BankUI.Toggle()
		return
	end
	if msg:sub(1, 5) == "gbank" then
		GM.GBankUI.Toggle()
		return
	end
	if msg:sub(1, 4) == "mail" then
		GM.MailUI.Toggle()
		return
	end
	if msg:sub(1, 4) == "snip" then
		GM.SniperUI.Toggle()
		return
	end
	if msg:sub(1, 5) == "tasks" then
		GM.TaskListUI.Toggle()
		return
	end
	if msg:sub(1, 6) == "uidump" then
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
		return
	end
	if msg:sub(1, 6) == "ahdump" then
		local arg = strtrim(msg:sub(7))
		local pid = tonumber(arg) or ParseItemRef(arg)
		GM.AH.DumpRows(pid ~= "" and pid or nil)
		return
	end
	if msg:sub(1, 3) == "inv" then
		local pid = ParseItemRef(strtrim(msg:sub(4)))
		if not pid then
			GM.Print("usage: /goblin inv <item|i:id|[name]|link>")
			return
		end
		GM.Inventory.QueryOwned()
		local c = GM.Inventory.Count(pid)
		GM.Print(format("inv %d — bags %d · bank %d · mail %d · gbank %d · posted %d · total %d",
			pid, c.bags, c.bank, c.mail, c.guild, c.auction, c.total))
		return
	end
	if msg:sub(1, 6) == "ledger" then
		local n = tonumber(msg:sub(7)) or 8
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
		return
	end
	if msg:sub(1, 5) == "price" then
		local sub = strtrim(msg:sub(6))
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
		return
	end
	local id = tonumber(msg:match("item:(%d+)")) or tonumber(msg)
	if id then
		GM.TargetItem(id, msg)
	else
		GM.PlanQueue.Toggle()
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
-- fallback the brain also fills with the primary scope
function GM.ItemEntry(itemID)
	local db = GoblinMindDB
	if not db then return nil end
	local r = db.realms and db.realms[GM.Scope()]
	local t = (r and r.items) or db.items
	return t and t[itemID]
end

-- TSM fallback price (copper) — the shim's honest baseline before the model lands.
function GM.TSMMarket(itemID)
	if not TSMAPI_FOUR or not TSMAPI_FOUR.CustomPrice then return end
	local ok, value = pcall(TSMAPI_FOUR.CustomPrice.GetValue, "dbmarket", "i:" .. itemID)
	if ok and type(value) == "number" and value > 0 then
		return value
	end
end

-- Stack count for itemID across carried bags (0-4) and the reagent bag (5).
function GM.BagCount(itemID)
	if not (itemID and C_Container and C_Container.GetContainerItemInfo) then return 0 end
	local total = 0
	for bag = 0, 5 do
		for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID == itemID then
				total = total + (info.stackCount or 1)
			end
		end
	end
	return total
end

-- Set of itemIDs in carried bags — one pass for catalogue-style filters.
function GM.BagItems()
	local set = {}
	if not (C_Container and C_Container.GetContainerItemInfo) then return set end
	for bag = 0, 5 do
		for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then set[info.itemID] = true end
		end
	end
	return set
end

-- Bank contents are only readable while the bank frame is open.
function GM.BankCount(itemID)
	if not (itemID and BankFrame and BankFrame:IsShown()) then return 0 end
	if not (C_Container and C_Container.GetContainerItemInfo) then return 0 end
	local total = 0
	for _, bag in ipairs({ -1, 6, 7, 8, 9, 10, 11 }) do
		for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID == itemID then
				total = total + (info.stackCount or 1)
			end
		end
	end
	return total
end

-- Item name/icon resolution: GetItemInfo returns nil for uncached
-- items — request the load and re-run listeners when the data lands.
-- Listeners register via GM.OnItemInfoLoaded(fn); each event burst
-- coalesces into one refresh pass.
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local GetIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
local ReqLoad = C_Item and C_Item.RequestLoadItemDataByID

GM.itemWatch = { cbs = {} }

function GM.ItemName(id)
	if not id then return end
	local n = GetInfo and GetInfo(id)
	if not n and ReqLoad then pcall(ReqLoad, id) end
	return n
end

function GM.ItemIcon(id)
	if not id then return end
	local icon = GetIcon and GetIcon(id)
	if not icon and ReqLoad then pcall(ReqLoad, id) end
	return icon
end

function GM.ItemNameOr(id)
	return GM.ItemName(id) or ("item " .. id)
end

function GM.ItemLink(id)
	if not id then return end
	return select(2, GetInfo(id)) or nil
end

function GM.OnItemInfoLoaded(fn) tinsert(GM.itemWatch.cbs, fn) end

local iw = CreateFrame("Frame")
pcall(iw.RegisterEvent, iw, "GET_ITEM_INFO_RECEIVED")
iw:SetScript("OnEvent", function()
	if GM.itemWatch.sched then return end
	GM.itemWatch.sched = true
	GM.After(0.25, function()
		GM.itemWatch.sched = nil
		for _, fn in ipairs(GM.itemWatch.cbs) do pcall(fn) end
	end)
end)
