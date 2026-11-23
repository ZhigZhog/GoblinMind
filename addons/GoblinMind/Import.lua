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
	-- GatherLite: real import — herb/mine spawn history seeds the
	-- gather route solver with exact positions
	local glData = GatherLiteDB or GatherLiteSettings or GatherLiteNodes
		or (GatherLite and GatherLite.GetNodes)
	if AddonState("GatherLite") == "loaded" or glData then
		rows[#rows + 1] = {
			key = "gatherlite", addon = "GatherLite",
			title = "Gathered nodes",
			detail = "herb/mine/fishing spawn history -> gather routes",
			run = function()
				local st, err = GM.Gather.ImportGatherLite()
				if not st then return nil, err end
				return st.new .. " new nodes, " .. st.merged
					.. " merged" .. (st.skipped > 0
						and (", " .. st.skipped .. " skipped") or "")
			end,
		}
		-- GatherLite also records containers — a kind we don't
		-- track (fishing imports as the fish kind). Say so
		-- instead of looking like the import covers everything
		local nodes = GatherLiteSettings
			and GatherLiteSettings.global
			and GatherLiteSettings.global.nodes
		if type(nodes) == "table" and nodes.containers then
			extras[#extras + 1] = "GatherLite containers - "
				.. "detected, not importable yet"
		end
	else
		Detected(glData, "GatherLite", "GatherLite")
	end
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

-- ============ shared import UI ============
-- ONE row-list implementation mounted by both surfaces that need it:
-- onboarding page 3 and the standalone importer window the settings
-- panel opens. Detection/running already lives here, so the widget
-- does too — a second copy anywhere would be a second failure point.
-- Returns a refresh fn; callers own their own nav buttons.
function I.Mount(parent)
	local W = GM.Widgets
	local status = GM.MakeFontString(parent, GM.FONT, 9, "textDim")
	status:SetPoint("TOPLEFT", 12, -28)
	status:SetWordWrap(false)
	local body = GM.MakeFontString(parent, GM.FONT, 10, "text")
	body:SetPoint("TOPLEFT", 14, -44)
	body:SetWidth(432)
	body:SetJustifyH("LEFT")
	body:SetSpacing(3)
	body:SetText("Found settings in other addons. Importing adds "
		.. "to GoblinMind — it never deletes anything you already made.")
	local status2 = GM.MakeFontString(parent, GM.FONT, 9, "textDim")
	status2:SetPoint("BOTTOMLEFT", 12, 36)
	status2:SetWidth(436)
	status2:SetJustifyH("LEFT")

	local rows = {}
	local function MakeRow(ix)
		local r = CreateFrame("Frame", nil, parent)
		r:SetSize(436, 46)
		r:SetPoint("TOPLEFT", 12, -64 - (ix - 1) * 50)
		GM.Panel(r, "contLowest")
		r.addon = GM.MakeFontString(r, GM.FONT, 8, "textDim")
		r.addon:SetPoint("TOPLEFT", 8, -4)
		r.title = GM.MakeFontString(r, GM.FONT_BOLD, 10, "text")
		r.title:SetPoint("TOPLEFT", 8, -15)
		r.title:SetWidth(340)
		r.title:SetJustifyH("LEFT")
		r.detail = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.detail:SetPoint("TOPLEFT", 8, -29)
		r.detail:SetWidth(340)
		r.detail:SetJustifyH("LEFT")
		r.btn = W.Btn(r, 70, "IMPORT", function()
			local summary, err = I.Run(r.data)
			if summary then
				r.btn.text:SetText("DONE")
				r.btn.text:SetTextColor(GM.RGB("pos"))
				r.result:SetText(GM.CC("pos") .. summary .. "|r")
			else
				r.result:SetText(GM.CC("warn")
					.. tostring(err or "nothing") .. "|r")
			end
		end)
		r.btn:SetPoint("RIGHT", -8, 0)
		r.result = GM.MakeFontString(r, GM.FONT, 8, "textDim")
		r.result:SetPoint("TOPRIGHT", r.btn, "BOTTOMRIGHT", 0, -2)
		r.result:SetWidth(240)
		r.result:SetJustifyH("RIGHT")
		r.result:SetWordWrap(false)
		r:Hide()
		return r
	end

	return function()
		local items, extras = I.Detect()
		for i, item in ipairs(items) do
			local r = rows[i] or MakeRow(i)
			rows[i] = r
			r.data = item
			r.addon:SetText(item.addon:upper())
			r.title:SetText(item.title)
			r.detail:SetText(item.detail)
			r.result:SetText("")
			r.btn.text:SetText(item.done and "DONE" or "IMPORT")
			r.btn.text:SetTextColor(GM.RGB(
				item.done and "pos" or "textDim"))
			r:Show()
		end
		for i = #items + 1, #rows do rows[i]:Hide() end
		local note = extras and #extras > 0
			and table.concat(extras, "\n") or nil
		if #items == 0 then
			status:SetText(GM.CC("warn")
				.. "no compatible addon data found|r")
		else
			status:SetText(format("%d importable item%s detected",
				#items, #items == 1 and "" or "s"))
		end
		status2:SetText(note or "")
	end
end

-- ============ standalone window ============
-- settings opens this; the onboarding page mounts the same list.
local win
local function BuildWindow()
	if win then return end
	local f = CreateFrame("Frame", "GoblinMindImportFrame", UIParent)
	f:SetSize(460, 380)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	GM.Panel(f, "contLow")
	tinsert(UISpecialFrames, "GoblinMindImportFrame")
	win = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("IMPORT FROM OTHER ADDONS")

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	f.refresh = I.Mount(f)

	local rescan = GM.Widgets.Btn(f, 90, "RESCAN", function()
		f.refresh()
	end)
	rescan:SetPoint("BOTTOMLEFT", 12, 10)
	local done = GM.Widgets.Btn(f, 90, "CLOSE", function() f:Hide() end)
	done:SetPoint("BOTTOMRIGHT", -12, 10)
end

function I.Show()
	BuildWindow()
	win.refresh()
	win:Show()
end
