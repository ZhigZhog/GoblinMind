local _, GM = ...

-- Addon settings import — reads other addons' SavedVariables (globals
-- that only exist while the source addon is loaded) and maps them
-- into our own stores. Detection is per-importable-item: each row
-- knows what it reads, what it writes, and runs once (the UI marks
-- it imported). Sources we detect but can't consume yet surface as
-- "detected — nothing to import" so the screen explains itself.

GM.Import = {}
local I = GM.Import

local tinsert = table.insert
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber

-- ============ TSM SavedVariables reader ============

local function TsmDb()
	return type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB
end

-- profile-scoped leaves live at "p@<Profile>@userData@<leaf>" — find
-- the first TABLE-valued match (the p@userData@<leaf> = n companions
-- are packed sizes, not data). Prefer "Default" when several exist.
local function TsmProfile(db, leaf)
	local found
	for k, v in pairs(db) do
		if type(v) == "table" then
			local prof, l = k:match("^p@(.-)@userData@(.+)$")
			if l == leaf then
				if prof == "Default" then return v end
				found = found or v
			end
		end
	end
	return found
end

-- global leaves: "g@ @userData@<leaf>" (space is the empty scope)
local function TsmGlobal(db, leaf)
	return db["g@ @userData@" .. leaf] or db["g@userData@" .. leaf]
end

-- TSM backtick paths -> our slash paths (shared with Groups' own
-- import/export; `` is an escaped comma, "" is the Base Group).
local function TsmToGmPath(p)
	return GM.Groups.TsmToGmPath(p)
end

-- TSM module name -> our op type
local MOD = {
	Auctioning = "auctioning", Shopping = "shopping",
	Sniper = "sniper", Crafting = "crafting",
	Mailing = "mailing", Vendoring = "vendoring",
	Warehousing = "warehousing", Destroying = "destroying",
}

-- TSM op field -> our field; numeric fields come over as strings
-- in the SV ("50" not 50) so they get a tonumber pass. Expression
-- fields stay strings verbatim — our evaluator already speaks
-- TSM's vocabulary (incl. the postfix % fold).
local FIELD = {
	auctioning = {
		normalPrice = "normal", minPrice = "min", maxPrice = "max",
		undercut = "undercut", priceReset = "resetMethod",
		cancelUndercut = "cancelUndercut",
		postCap = "num", duration = "num", stackSize = "num",
		bidPercent = "num",
	},
	shopping = { maxPrice = "maxPrice" },
	sniper = { belowPrice = "belowPrice" },
	crafting = { minProfit = "minProfit", restock = "restock" },
	mailing = {
		target = "sendTo",
		keepQty = "num", maxQty = "num",
	},
	warehousing = { keepBagQuantity = "keepQty" },
	vendoring = {},
	destroying = {},
}
local NUMF = {
	postCap = "postCap", duration = "duration", stackSize = "stackSize",
	bidPercent = "bidPercent", keepQty = "keepQty", maxQty = "maxQty",
}
-- TSM bidPercent is a fraction (1 = 100%); ours is a percent number
local function MapField(opType, tsmName, v, out)
	local f = FIELD[opType] and FIELD[opType][tsmName]
	if not f then return end
	if f == "num" then
		local n = tonumber(v)
		if not n then return end
		if tsmName == "bidPercent" and n <= 1 then n = n * 100 end
		out[NUMF[tsmName]] = n
	else
		out[f] = v
	end
end

-- ============ import steps ============

local function ImportTsmOps()
	local db = TsmDb()
	local ops = db and TsmProfile(db, "operations")
	if not ops then return nil, "no operations found" end
	local store = GM.Groups.db.operations
	local n, skipped = 0, 0
	for mod, byName in pairs(ops) do
		local opType = MOD[mod]
		if opType and type(byName) == "table" then
			for name, fields in pairs(byName) do
				if type(fields) == "table" then
					local op = {}
					for tsmField, v in pairs(fields) do
						MapField(opType, tsmField, v, op)
					end
					local target = name == "#Default" and "Default" or name
					if store[opType] and store[opType][target] then
						target = "TSM " .. target
						while store[opType][target] do
							target = "TSM " .. target
						end
					end
					store[opType] = store[opType] or {}
					store[opType][target] = op
					n = n + 1
				end
			end
		else
			skipped = skipped + 1
		end
	end
	return format("%d ops across %d types%s", n, 8 - skipped,
		skipped > 0 and format(" (%d TSM modules unmapped)", skipped) or "")
end

local function ImportTsmGroups()
	local db = TsmDb()
	local items = db and TsmProfile(db, "items")
	if not items then return nil, "no group items found" end
	local groupOps = db and TsmProfile(db, "groups")
	local ni, ng = 0, 0
	local created = {}
	for itemStr, tsmPath in pairs(items) do
		local id = tonumber(itemStr:match("i:(%d+)"))
		if id then
			local path = TsmToGmPath(tsmPath)
			if not GM.Groups.db.groups[path] then
				created[path] = true
			end
			GM.Groups.Assign(id, path)
			ni = ni + 1
		end
	end
	for _ in pairs(created) do ng = ng + 1 end
	-- attach the TSM op assignment for each imported group: TSM's
	-- groups[path][Module] = {opNames} lists names (or "#Default").
	if type(groupOps) == "table" then
		-- op assignments only resolve if the named ops exist — run the
		-- ops step first if the user hasn't (the done flag makes its
		-- own row report "already imported" afterwards)
		I.Run({ key = "tsmOps", run = ImportTsmOps })
		for tsmPath, mods in pairs(groupOps) do
			local path = TsmToGmPath(tsmPath)
			local g = GM.Groups.db.groups[path]
			if g and type(mods) == "table" then
				for mod, opList in pairs(mods) do
					local opType = MOD[mod]
					local first = type(opList) == "table" and opList[1]
					if opType and first then
						-- named op first, its "TSM "-prefixed collision
						-- copy second, our Default last
						local name = first == "#Default" and "Default" or first
						if not GM.Groups.AssignOp(path, opType, name) then
							GM.Groups.AssignOp(path, opType, "TSM " .. name)
						end
					end
				end
			end
		end
	end
	return format("%d items into %d groups (%d new)", ni, ng > 0 and
		ng or 1, ng)
end

local function ImportTsmCustomSources()
	local db = TsmDb()
	local cs = db and TsmGlobal(db, "customPriceSources")
	if not cs or type(cs) ~= "table" then return nil, "none found" end
	GoblinMindPrices = GoblinMindPrices or { customSources = {} }
	GoblinMindPrices.customSources = GoblinMindPrices.customSources or {}
	local n = 0
	for name, expr in pairs(cs) do
		if type(expr) == "string" and expr ~= "" then
			GoblinMindPrices.customSources[tostring(name):lower()] = expr
			n = n + 1
		end
	end
	return format("%d price sources", n)
end

local function ImportTsmSearches()
	local db = TsmDb()
	local s = db and TsmGlobal(db, "savedShoppingSearches")
	if not (s and type(s.filters) == "table") then
		return nil, "none found"
	end
	GM.db.ahSearches = GM.db.ahSearches or {}
	local names = type(s.name) == "table" and s.name or {}
	local n = 0
	for i, f in ipairs(s.filters) do
		if type(f) == "string" and f ~= "" then
			tinsert(GM.db.ahSearches,
				{ name = names[i] or f, q = f })
			n = n + 1
		end
	end
	return format("%d saved searches", n)
end

-- ============ detection ============

local function CountKeys(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

-- rows = { {addon, key, title, detail, run() -> summary|nil,err} }
-- extras = { "Name — detected, nothing to import yet", ... }
-- addon presence: loaded (data readable) vs installed-but-disabled
-- (SV never enters the Lua env — we can explain, not import) vs
-- absent. GetAddOnInfo returns info for disabled addons, nil for
-- uninstalled; IsAddOnLoaded distinguishes the two installed states.
local function AddonState(tocName)
	local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded
			and C_AddOns.IsAddOnLoaded(tocName))
		or (IsAddOnLoaded and IsAddOnLoaded(tocName))
	if loaded then return "loaded" end
	local info = (C_AddOns and C_AddOns.GetAddOnInfo
			and C_AddOns.GetAddOnInfo(tocName))
		or (GetAddOnInfo and GetAddOnInfo(tocName))
	local exists = info or (C_AddOns and C_AddOns.DoesAddOnExist
		and C_AddOns.DoesAddOnExist(tocName))
	return exists and "installed" or "absent"
end

function I.Detect()
	local rows, extras = {}, {}
	local db = TsmDb()
	if db then
		local items = TsmProfile(db, "items")
		local groups = TsmProfile(db, "groups")
		local ops = TsmProfile(db, "operations")
		local cs = TsmGlobal(db, "customPriceSources")
		local ss = TsmGlobal(db, "savedShoppingSearches")
		if type(items) == "table" then
			rows[#rows + 1] = {
				addon = "TradeSkillMaster", key = "tsmGroups",
				title = "Groups + item membership",
				detail = format("%d items - %d group paths",
					CountKeys(items),
					type(groups) == "table" and CountKeys(groups) or 0),
				run = ImportTsmGroups,
			}
		end
		if type(ops) == "table" then
			local n = 0
			for _, byName in pairs(ops) do
				n = n + CountKeys(byName)
			end
			rows[#rows + 1] = {
				addon = "TradeSkillMaster", key = "tsmOps",
				title = "Operations",
				detail = format("%d named ops - auctioning/shopping/"
					.. "sniper/crafting/mailing fields map on", n),
				run = ImportTsmOps,
			}
		end
		if type(cs) == "table" and CountKeys(cs) > 0 then
			rows[#rows + 1] = {
				addon = "TradeSkillMaster", key = "tsmSources",
				title = "Custom price sources",
				detail = format("%d expressions", CountKeys(cs)),
				run = ImportTsmCustomSources,
			}
		end
		if type(ss) == "table" and type(ss.filters) == "table"
			and #ss.filters > 0 then
			rows[#rows + 1] = {
				addon = "TradeSkillMaster", key = "tsmSearches",
				title = "Saved shopping searches",
				detail = format("%d searches -> AH saved list",
					#ss.filters),
				run = ImportTsmSearches,
			}
		end
	end
	if not db then
		-- no SV in env: if TSM is merely disabled we can say so —
		-- its SavedVariables only load for enabled addons
		if AddonState("TradeSkillMaster") == "installed" then
			extras[#extras + 1] = "TradeSkillMaster - installed but "
				.. "disabled; enable it in the addon list and "
				.. "/reload to import its settings"
		end
	end
	-- detected-but-unsupported: addon present, nothing importable yet
	local function Detected(svGlobal, tocName, label)
		local st = AddonState(tocName)
		if st == "loaded" or type(svGlobal) == "table" then
			extras[#extras + 1] = label
				.. " - detected, nothing to import yet"
		elseif st == "installed" then
			extras[#extras + 1] = label .. " - installed but "
				.. "disabled, nothing readable"
		end
	end
	Detected(AUCTIONATOR_PRICE_DATABASE, "Auctionator", "Auctionator")
	Detected(AucStatData or AucScanData, "Auc-Advanced", "Auctioneer")
	Detected(GatherLiteDB or GatherLiteSettings or GatherLiteNodes,
		"GatherLite", "GatherLite")
	return rows, extras
end

-- run an import row exactly once, keyed so a chained run (groups
-- triggering ops first) also locks the real row. Imports merge,
-- never wipe: group assigns reassign, op writes rename on collision.
local doneKeys = {}
function I.Run(row)
	if row.done or doneKeys[row.key] then
		return nil, "already imported"
	end
	local summary, err = row.run()
	if summary then
		row.done = true
		doneKeys[row.key] = true
		return summary
	end
	return nil, err or "nothing imported"
end
