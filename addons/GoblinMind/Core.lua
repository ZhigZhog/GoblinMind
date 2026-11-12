local addonName, GM = ...
print("GoblinMind: Core.lua executing")

local DEFAULTS = {
	riskBudget = 0.40,      -- max fraction of gold a plan may commit
	minProfitMargin = 0.10, -- stop buying when (p50*0.95 - ask)/ask < this
	maxDaysToClear = 7,     -- warn past this holding period
	dataMaxAge = 7200,      -- seconds before tooltip flags data stale
}

local function ApplyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then dst[k] = v end
	end
end

GM.frame = CreateFrame("Frame")
GM.frame:RegisterEvent("ADDON_LOADED")
GM.frame:RegisterEvent("PLAYER_LOGIN")
GM.frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == addonName then
		GoblinMindSettings = GoblinMindSettings or {}
		ApplyDefaults(GoblinMindSettings, DEFAULTS)
		GM.db = GoblinMindSettings
		GM.frame:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGIN" then
		GM.Print("loaded — /gm for the plan window")
	end
end)

function GM.Print(...)
	print(GM.CC("accent") .. "GoblinMind|r:", ...)
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
	local id = tonumber(msg:match("item:(%d+)")) or tonumber(msg)
	if id then
		GM.TargetItem(id, msg)
	else
		GM.PlanQueue.Toggle()
	end
end

-- Realm key matching AppData scopes, e.g. "Normal-Alliance"
function GM.Scope()
	local realm = GetNormalizedRealmName() or GetRealmName()
	local faction = UnitFactionGroup("player")
	return realm .. "-" .. faction
end

-- Seconds since the newest upstream data the generated file used; nil if none.
function GM.DataAge()
	if GoblinMindDB and GoblinMindDB.dataAge then
		return time() - GoblinMindDB.dataAge
	end
end

function GM.ItemEntry(itemID)
	return GoblinMindDB and GoblinMindDB.items and GoblinMindDB.items[itemID]
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
