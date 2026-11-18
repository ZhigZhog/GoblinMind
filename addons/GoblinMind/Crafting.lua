local _, GM = ...

-- Part 7: recipe capture + mat-cost/profit model + craft queue.
-- Forever exposes the retail C_TradeSkillUI surface (verified against
-- TSM's LibTSMWoW TradeSkill wrapper — IsForever takes the retail path).
-- Recipes are captured when a tradeskill frame loads (the API only
-- returns data for the open profession) and persist in the SV, so the
-- recipe list grows as the player opens each profession.
--
-- Boundaries: CraftRecipe stays a manual action in the profession UI —
-- queue emits "note" steps for the craft itself, real buy steps for
-- the reagents. One protected call per click, unchanged.

GM.Crafting = {}
local C = GM.Crafting

-- /goblin crafttrace toggles C.trace — every gate/cast decision and
-- event logs a [craft] line so a stuck OPEN button shows its branch
-- instead of its symptom
local function Tr(...)
	if not C.trace then return end
	local parts = {}
	for i = 1, select("#", ...) do
		-- tostring() on a secret value returns the secret itself, not
		-- a string — concat then throws "invalid value (secret)"
		local v = select(i, ...)
		parts[i] = (issecretvalue and issecretvalue(v))
			and "<secret>" or tostring(v)
	end
	GM.Print(GM.CC("textDim") .. "[craft] "
		.. table.concat(parts, " ") .. "|r")
end
C.Tr = Tr

-- per-recipe profession: a recipe's category tree roots at the
-- profession ("Engineering", "Mining"). Scan-time APIs like
-- GetBaseProfessionInfo report the PREVIOUSLY open tradeskill — the
-- category walk never lags. Works on Forever (TSM uses the same
-- GetCategoryInfo signature: out-param table).
local catProfCache = {}
local function ProfFromCat(cat)
	if not (cat and C_TradeSkillUI and C_TradeSkillUI.GetCategoryInfo) then return end
	local cached = catProfCache[cat]
	if cached ~= nil then return cached or nil end
	local info, cur, guard = {}, cat, 0
	while cur and guard < 10 do
		guard = guard + 1
		wipe(info)
		local ok, res = pcall(C_TradeSkillUI.GetCategoryInfo, cur, info)
		if not ok then break end
		if type(res) == "table" then info = res end
		local parent = info and info.parentCategoryID
		if not parent or parent == cur then break end
		cur = parent
	end
	local name = info and info.name
	local p = (type(name) == "string" and name ~= "") and name or nil
	catProfCache[cat] = p or false
	return p
end

-- authoritative per-recipe profession: GetTradeSkillLineForRecipe
-- exists on Forever (TSM marks it retail-only and never calls it here)
-- and returns (skillLineID, displayName, rootSkillLine) — the name is
-- return 2. No profession needs to be open; this also heals stored
-- mistags on read.
local function ProfForRecipe(recipeID)
	if not (C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLineForRecipe) then
		return nil
	end
	local ok, _, name = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe,
		recipeID)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
end

function C.Prof(recipeID)
	local r = GoblinMindCrafting and GoblinMindCrafting.recipes
		and GoblinMindCrafting.recipes[recipeID]
	if not r then return "?" end
	local p = ProfForRecipe(recipeID) or ProfFromCat(r.cat)
	if p then
		if r.prof ~= p then r.prof = p end
		return p
	end
	if type(r.prof) == "string" and r.prof ~= "" then return r.prof end
	return "?"
end

-- /goblin craftdebug — dump every profession API + category walks
function C.Debug(matchName)
	GM.Print("— tradeskill API probe —")
	GM.Print("global GetTradeSkillLine: " .. tostring(
		GetTradeSkillLine and GetTradeSkillLine() or GetTradeSkillLine))
	if C_TradeSkillUI then
		GM.Print("C_TSUI.GetTradeSkillLine() → " .. tostring(
			pcall(C_TradeSkillUI.GetTradeSkillLine)))
		GM.Print("C_TSUI.GetCategoryInfo: " .. tostring(C_TradeSkillUI.GetCategoryInfo))
		GM.Print("C_TSUI.GetTradeSkillLineForRecipe: " .. tostring(C_TradeSkillUI.GetTradeSkillLineForRecipe))
		GM.Print("C_TSUI.GetProfessionName: " .. tostring(C_TradeSkillUI.GetProfessionName))
		GM.Print("global GetProfessions: " .. tostring(GetProfessions))
		GM.Print("global GetProfessionInfo: " .. tostring(GetProfessionInfo))
		if GetProfessions then
			local profs = { GetProfessions() }
			GM.Print("  GetProfessions → " .. table.concat(
				(function() local t = {} for i, v in ipairs(profs) do t[i] = tostring(v) end return t end)(), ", "))
			for _, idx in ipairs(profs) do
				local info = { GetProfessionInfo(idx) }
				GM.Print("  GetProfessionInfo(" .. tostring(idx) .. ") → "
					.. table.concat((function()
						local t = {} for i, v in ipairs(info) do t[i] = tostring(v) end return t end)(), ", "))
			end
		end
		if C_TradeSkillUI.GetBaseProfessionInfo then
			local pi = C_TradeSkillUI.GetBaseProfessionInfo()
			if pi then
				for k, v in pairs(pi) do
					GM.Print("  basePI." .. tostring(k) .. " = " .. tostring(v))
				end
			else
				GM.Print("  basePI = nil")
			end
		end
		if C_TradeSkillUI.GetAllRecipeIDs then
			local ok, res = pcall(C_TradeSkillUI.GetAllRecipeIDs)
			GM.Print("  GetAllRecipeIDs → " .. tostring(
				ok and type(res) == "table" and (#res .. " ids")
				or res))
		end
		if C_TradeSkillUI.GetFilteredRecipeIDs then
			local ok, res = pcall(C_TradeSkillUI.GetFilteredRecipeIDs)
			GM.Print("  GetFilteredRecipeIDs → " .. tostring(
				ok and type(res) == "table" and (#res .. " ids")
				or res))
		end
		-- gate internals for a recipe (arg) or the first queued one
		local rid = tonumber(matchName)
			or next(GoblinMindCrafting.queue or {})
		if rid then
			GM.Print("  lastProf = " .. tostring(C.lastProf))
			local pf = ProfessionsFrame or TradeSkillFrame
			GM.Print("  pf shown = " .. tostring(pf and pf:IsShown()))
			if ProfessionsFrame and ProfessionsFrame.BookPage then
				GM.Print("  bookPage shown = " .. tostring(
					ProfessionsFrame.BookPage:IsShown()))
			end
			GM.Print("  recipe " .. rid .. " prof = " .. tostring(
				C.Prof(rid)))
			GM.Print("  LineOpenFor → " .. tostring(C.LineOpenFor(rid)))
			GM.Print("  LineClosedFor → " .. tostring(
				C.LineClosedFor and C.LineClosedFor(rid)))
		end
	else
		GM.Print("C_TradeSkillUI missing")
	end
	local shown = 0
	for id, r in pairs(GoblinMindCrafting.recipes or {}) do
		if (not matchName or (r.name or ""):lower():find(matchName))
			and shown < 5 then
			shown = shown + 1
			GM.Print(format("recipe %d %q: prof=%s cat=%s",
				id, r.name or "?", tostring(r.prof), tostring(r.cat)))
			if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLineForRecipe then
				local ok, a, b, c = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, id)
				GM.Print("  GetTradeSkillLineForRecipe → "
					.. tostring(ok) .. " " .. tostring(a) .. " "
					.. tostring(b) .. " " .. tostring(c))
			end
			if r.cat and C_TradeSkillUI and C_TradeSkillUI.GetCategoryInfo then
				local info, cur = {}, r.cat
				for hop = 1, 6 do
					wipe(info)
					local ok, res = pcall(C_TradeSkillUI.GetCategoryInfo, cur, info)
					if not ok then
						GM.Print("  GetCategoryInfo error: " .. tostring(info))
						break
					end
					if type(res) == "table" then info = res end
					if not info or not next(info) then
						GM.Print("  cat " .. cur .. " → no info")
						break
					end
					GM.Print(format("  cat %d: name=%q parent=%s indents=%s",
						cur, tostring(info.name),
						tostring(info.parentCategoryID), tostring(info.numIndents)))
					if not info.parentCategoryID
						or info.parentCategoryID == cur then break end
					cur = info.parentCategoryID
				end
			end
		end
	end
	if shown == 0 then GM.Print("no recipes matched") end
end

-- /goblin craftprobe <recipeID|name> — enumerate every craft-shaped
-- API on this client and fire CraftRecipe with full result capture.
-- Run with the tradeskill window open; says exactly what the call did.
function C.CraftProbe(match)
	GM.Print("— craft API probe —")
	-- trailing flag word switches the call under test:
	--   "t" → same cast inside C_Timer.After (is the wall timing or
	--         the missing hardware event? — decides if chains can run)
	--   "n" → numCasts=2 retry        "r" → numCasts=2 + reagent table
	local flag
	local w = match and match:match("%s+(%a+)%s*$")
	if w == "t" or w == "n" or w == "r" then
		flag = w
		match = match:match("^(.-)%s+%a+%s*$")
	end
	if C_TradeSkillUI then
		local names = {}
		for k in pairs(C_TradeSkillUI) do
			if type(C_TradeSkillUI[k]) == "function"
				and k:lower():find("craft") then
				names[#names + 1] = k
			end
		end
		sort(names)
		GM.Print("C_TradeSkillUI craft fns: " .. table.concat(names, ", "))
	else
		GM.Print("C_TradeSkillUI missing!")
	end
	GM.Print("globals: DoTradeSkill=" .. tostring(DoTradeSkill)
		.. " DoCraft=" .. tostring(DoCraft)
		.. " GetCraftInfo=" .. tostring(GetCraftInfo)
		.. " GetTradeSkillInfo=" .. tostring(GetTradeSkillInfo)
		.. " ExpandTradeSkillSubClass=" .. tostring(ExpandTradeSkillSubClass))
	-- resolve the target recipe
	local id
	if tonumber(match) then
		id = tonumber(match)
	else
		match = (match or ""):lower()
		for rid, r in pairs(GoblinMindCrafting.recipes or {}) do
			if (r.name or ""):lower():find(match) then id = rid break end
		end
	end
	if not (id and GoblinMindCrafting.recipes[id]) then
		GM.Print("no stored recipe matched — pass a recipeID")
		return
	end
	GM.Print(format("target: %d %q craftable=%d", id,
		GoblinMindCrafting.recipes[id].name or "?",
		C.Craftable(id)))
	if C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
		-- full TSM arg list (count, optionalMats, level, orderID,
		-- concentration) — matches LibTSMWoW TradeSkill.Craft verbatim.
		-- Every call arms a 4.5s watcher that counts real completed
		-- casts for this recipeID — "pcall=true" means nothing on a
		-- client that squelches silently, the verdict is the truth
		local call = function(n, reag)
			local ok, r1, r2 = pcall(C_TradeSkillUI.CraftRecipe,
				id, n or 1, reag, nil, nil, nil)
			GM.Print(format("CraftRecipe(%s%s) pcall=%s r1=%s r2=%s",
				tostring(n or 1), reag and ",{}" or "",
				tostring(ok), tostring(r1), tostring(r2)))
			if not ok then return end
			C._probe = { id = id, saw = 0 }
			GM.After(4.5, function()
				local p = C._probe
				if p and p.id == id then
					C._probe = nil
					GM.Print(p.saw > 0
						and ("probe verdict: " .. p.saw
							.. " cast(s) landed")
						or "probe verdict: NO cast landed")
				end
			end)
		end
		if flag == "t" then
			GM.Print("timer-context cast in 0.4s")
			C_Timer.After(0.4, function() call() end)
		elseif flag == "n" then
			call(2)
		elseif flag == "r" then
			call(2, {})
		else
			call()
		end
	end
end

-- linked/guild/NPC tradeskill frames show someone ELSE's recipes
-- with learned=true — scanning one poisons the DB with professions
-- nobody on the account has
local function ForeignTradeskill()
	if not C_TradeSkillUI then return false end
	for _, n in ipairs({ "IsTradeSkillLinked", "IsNPCCrafting",
						 "IsTradeSkillGuild" }) do
		local f = C_TradeSkillUI[n]
		if f then
			local ok, v = pcall(f)
			if ok and v then return true end
		end
	end
	return false
end

-- required skill isn't in GetRecipeInfo — it lives on the recipe
-- LINK's tooltip as "Requires Cooking (125)". One hidden probe,
-- parsed once per recipe (prev.req caching in Scan keeps it off
-- repeat TRADE_SKILL_UPDATE events). nil when the client won't say.
local reqProbe
local function ReqSkillFor(recipeID)
	if not C_TradeSkillUI.GetRecipeLink then return end
	local ok, link = pcall(C_TradeSkillUI.GetRecipeLink, recipeID)
	if not ok or type(link) ~= "string" then return end
	if reqProbe == nil then
		local ok2, tt = pcall(CreateFrame, "GameTooltip", "GMReqProbe",
			UIParent, "GameTooltipTemplate")
		reqProbe = (ok2 and tt) or false
	end
	if not reqProbe then return end
	reqProbe:SetOwner(UIParent, "ANCHOR_NONE")
	reqProbe:SetHyperlink(link)
	for i = 1, reqProbe:NumLines() or 0 do
		local fs = _G["GMReqProbeTextLeft" .. i]
		local s = fs and fs:GetText()
		local n = s and s:match("Requires%s+[^%(]*%((%d+)%)")
		if n then
			reqProbe:Hide()
			return tonumber(n)
		end
	end
	reqProbe:Hide()
end

local function Scan()
	C._scans = (C._scans or 0) + 1
	if not C_TradeSkillUI then return end
	if ForeignTradeskill() then return end
	-- GetAllRecipeIDs first: the full line regardless of the Blizzard
	-- filter — filtered enum can hide unlearned rows from capture
	-- entirely when the window's filter drops them
	local ok, ids
	if C_TradeSkillUI.GetAllRecipeIDs then
		ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	end
	if not (ok and type(ids) == "table" and #ids > 0) then
		if not C_TradeSkillUI.GetFilteredRecipeIDs then return end
		ok, ids = pcall(C_TradeSkillUI.GetFilteredRecipeIDs)
	end
	if not ok or type(ids) ~= "table" then return end
	-- GetBaseProfessionInfo LAGS the recipe list — at event time it
	-- still names the previously open profession (off-by-one tagging).
	-- GetTradeSkillLine reflects the list actually showing.
	local prof
	if C_TradeSkillUI.GetTradeSkillLine then
		-- exists but errors when called on Forever (craftdebug probe)
		local ok, name = pcall(C_TradeSkillUI.GetTradeSkillLine)
		if ok and type(name) == "string" and name ~= "" then prof = name end
	end
	if not prof and C_TradeSkillUI.GetBaseProfessionInfo then
		local pi = C_TradeSkillUI.GetBaseProfessionInfo()
		prof = pi and pi.professionName or pi and pi.profession
	end
	-- Forever can hand back "" for some professions — keep nil so
	-- prev.prof survives and consumers can normalize once
	if type(prof) ~= "string" or prof == "" then prof = nil end
	local n = 0
	for _, recipeID in ipairs(ids) do
		local info = C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
		if info and info.learned then
			local sc = C_TradeSkillUI.GetRecipeSchematic
				and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
			if sc and sc.outputItemID then
				local mats = {}
				for _, slot in ipairs(sc.reagentSlotSchematics or {}) do
					-- regular reagent slots only: reagents[1].itemID +
					-- quantityRequired; optional/finishing slots skipped
					local r = slot.reagents and slot.reagents[1]
					if r and r.itemID and slot.quantityRequired then
						tinsert(mats, { id = r.itemID, qty = slot.quantityRequired })
					end
				end
				local prev = GoblinMindCrafting.recipes[recipeID] or {}
				GoblinMindCrafting.recipes[recipeID] = {
					name = info.name or prev.name,
					itemID = sc.outputItemID,
					prof = ProfForRecipe(recipeID) or prof
						or (type(prev.prof) == "string"
							and prev.prof ~= "" and prev.prof or nil),
					mats = mats,
					numMade = sc.quantityMin or prev.numMade or 1,
					cat = info.categoryID or prev.cat,
					-- difficulty/cooldown exist on retail-shaped
					-- GetRecipeInfo; nil-safe, detail pane uses them
					diff = info.relativeDifficulty or info.difficulty or prev.diff,
					nup = info.numSkillUps or prev.nup,
					cd = info.cooldown or prev.cd,
				}
				local p = GoblinMindCrafting.recipes[recipeID].prof
				if p then C.lastProf = p end -- profession this scan saw
				n = n + 1
			end
		elseif info then
			-- unlearned row: flagged, never queued — CraftingUI lists
			-- in-range ones with "where to get it" in the detail pane.
			-- Schematic may still answer (icon + mats) — take what lands.
			local sc = C_TradeSkillUI.GetRecipeSchematic
				and select(2, pcall(C_TradeSkillUI.GetRecipeSchematic,
					recipeID, false))
			local prev = GoblinMindCrafting.recipes[recipeID] or {}
			local mats = prev.mats
			if sc and sc.reagentSlotSchematics then
				mats = {}
				for _, slot in ipairs(sc.reagentSlotSchematics) do
					local r = slot.reagents and slot.reagents[1]
					if r and r.itemID and slot.quantityRequired then
						tinsert(mats, { id = r.itemID, qty = slot.quantityRequired })
					end
				end
			end
			GoblinMindCrafting.recipes[recipeID] = {
				name = info.name or prev.name,
				itemID = sc and sc.outputItemID or prev.itemID,
				unlearned = true,
				prof = ProfForRecipe(recipeID) or prof
					or (type(prev.prof) == "string"
						and prev.prof ~= "" and prev.prof or nil),
				mats = mats,
				numMade = sc and sc.quantityMin or prev.numMade or 1,
				cat = info.categoryID or prev.cat,
				diff = info.relativeDifficulty or info.difficulty or prev.diff,
				req = prev.req or ReqSkillFor(recipeID),
			}
			n = n + 1
		end
	end
	if n > 0 then GM.Crafting.dirty = true end
end

-- drop every recipe tagged with a profession — repair tool for
-- pre-guard captures (linked tradeskills) and abandoned alts
function C.PurgeProf(name)
	if not name or name == "" then return 0 end
	local n = 0
	for id, r in pairs(GoblinMindCrafting.recipes or {}) do
		if type(r.prof) == "string"
			and r.prof:lower() == name:lower() then
			GoblinMindCrafting.recipes[id] = nil
			n = n + 1
		end
	end
	if n > 0 then C.dirty = true end
	return n
end

-- craft bookkeeping: UNIT_SPELLCAST_* events are the truth. Each
-- completed craft cast (spellID == recipeID) decrements the queue by
-- one and ticks the active plan step — so queue counts always match
-- what actually got made, whether the call batched or not.
local function OnCastComplete(unit, castGUID, spellID)
	if unit ~= "player" or not spellID then return end
	-- some paths re-fire completion for one cast — same castGUID
	-- means same cast, count it once
	if castGUID and castGUID == C._lastCastGUID then return end
	C._lastCastGUID = castGUID
	if C._probe and spellID == C._probe.id then
		C._probe.saw = C._probe.saw + 1
	end
	if GoblinMindCrafting.queue and GoblinMindCrafting.queue[spellID] then
		C.QueueAdd(spellID, -1)
		if GM.CraftingUI and GM.CraftingUI.Refresh then GM.CraftingUI.Refresh() end
	end
	local step = GM.PlanQueue and GM.PlanQueue.ActiveStep
		and GM.PlanQueue.ActiveStep()
	if step and step.recipeID == spellID then
		step.crafted = (step.crafted or 0) + 1
		if step.crafted >= (step.qty or 1) then
			GM.PlanQueue.Advance()
		else
			GM.PlanQueue.Refresh()
		end
	end
	-- batch settle: items land cast-time APART (the engine repeats
	-- the cast bar itself) — a fixed debounce settles early after
	-- item #1. Instead poll until the player is genuinely idle,
	-- then credit what bags can prove: the item-count delta is
	-- ground truth under every event model; events alone are the
	-- fallback for outputs bags can't count
	local b = C.batchQty
	if b and b.id == spellID then
		b.got = (b.got or 0) + 1
		b.lastEvent = GetTime()
		if not b.settling then
			b.settling = true
			local function settle()
				local bb = C.batchQty
				if bb ~= b then return end
				local busy = (UnitCastingInfo and UnitCastingInfo("player"))
					or (UnitChannelInfo and UnitChannelInfo("player"))
				if busy or (b.lastEvent
						and GetTime() - b.lastEvent < 1.0) then
					GM.After(0.4, settle)
					return
				end
				C.batchQty = nil
				local made = bb.got or 0
				if bb.itemID and bb.itemCount then
					local d = bb.itemCount(bb.itemID) - (bb.before or 0)
					if d > made then made = d end
				end
				local extra = min(made, bb.n or 1) - (bb.got or 0)
				if extra <= 0 then return end
				Tr("batch settle —", extra, "more for", spellID)
				if GoblinMindCrafting.queue
					and GoblinMindCrafting.queue[spellID] then
					C.QueueAdd(spellID, -extra)
					if GM.CraftingUI and GM.CraftingUI.Refresh then
						GM.CraftingUI.Refresh()
					end
				end
				local st = GM.PlanQueue and GM.PlanQueue.ActiveStep
					and GM.PlanQueue.ActiveStep()
				if st and st.recipeID == spellID then
					st.crafted = (st.crafted or 0) + extra
					if st.crafted >= (st.qty or 1) then
						GM.PlanQueue.Advance()
					else
						GM.PlanQueue.Refresh()
					end
				end
			end
			GM.After(1.0, settle)
		end
	end
end

-- first-login profession pump: recipes only enumerate while a line
-- is OPEN, so a fresh profile (or a profession learned since the
-- last capture) needs one open pass per missing line. The opens land
-- in the normal TRADE_SKILL_SHOW path — C._pumping just suppresses
-- the UI takeover so the window doesn't flash once per line.
local function ProfPump()
	if C._pumping or not (GetProfessions and GetProfessionInfo
		and C_TradeSkillUI and C_TradeSkillUI.OpenTradeSkill) then
		return
	end
	local seen = {}
	for id in pairs(GoblinMindCrafting.recipes) do
		local p = C.Prof(id)
		if p and p ~= "?" then seen[p] = true end
	end
	local missing = {}
	for _, idx in ipairs({ GetProfessions() }) do
		local name, _, lvl, _, _, _, line = GetProfessionInfo(idx)
		if line and (lvl or 0) > 0 and name and not seen[name] then
			tinsert(missing, line)
		end
	end
	if #missing == 0 then return end
	C._pumping = true
	GM.Print("first load — scanning " .. #missing .. " profession"
		.. (#missing == 1 and "" or "s") .. "…")
	local i = 0
	local function step()
		i = i + 1
		local line = missing[i]
		if not line then
			C._pumping = nil
			if C_TradeSkillUI.CloseTradeSkill then
				pcall(C_TradeSkillUI.CloseTradeSkill)
			end
			return
		end
		pcall(C_TradeSkillUI.OpenTradeSkill, line)
		GM.After(1.0, step)
	end
	step()
end

function C.Init()
	GoblinMindCrafting = GoblinMindCrafting or {}
	GoblinMindCrafting.recipes = GoblinMindCrafting.recipes or {}
	GoblinMindCrafting.queue = GoblinMindCrafting.queue or {}
	-- K opens the professions OVERVIEW — no TRADE_SKILL_SHOW fires —
	-- so the takeover hook on the native frame has to exist at load
	Tr("init — hooking default frame")
	if GM.CraftingUI and GM.CraftingUI.HookDefault then
		GM.CraftingUI.HookDefault()
	end
	local f = CreateFrame("Frame")
	for _, evt in ipairs({
		"TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
		"TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "PLAYER_LOGIN",
		"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START",
		"UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_STOP",
		"UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
	}) do pcall(f.RegisterEvent, f, evt) end
	f:SetScript("OnEvent", function(_, e, ...)
		C._ev = C._ev or {}
		C._ev[e] = (C._ev[e] or 0) + 1
		if e == "UNIT_SPELLCAST_START"
			or e == "UNIT_SPELLCAST_CHANNEL_START" then
			local unit, _, spellID = ...
			-- any player cast starting inside the watch window means
			-- the call landed — don't filter on spellID: if the cast
			-- spell ever differs from recipeID we'd false-positive
			-- into the no-batch fallback while crafts actually work
			if unit == "player" then
				Tr("cast start", spellID,
					C.pendingCast and "(watched)" or "")
				C.pendingCast = nil
			end
			return
		end
		if e == "UNIT_SPELLCAST_SUCCEEDED"
			or e == "UNIT_SPELLCAST_CHANNEL_STOP" then
			Tr("cast complete", select(3, ...))
			OnCastComplete(...)
			return
		end
		if e == "UNIT_SPELLCAST_FAILED"
			or e == "UNIT_SPELLCAST_INTERRUPTED" then
			local unit, _, spellID = ...
			if unit == "player" then
				Tr("cast", e)
				C.pendingCast = nil
				-- only the batch's own recipe ending counts — an
				-- unrelated cast failing mid-batch (hearthstone,
				-- combat spell) must not void the settle bookkeeping
				if C.batchQty
					and (not spellID or spellID == C.batchQty.id) then
					C.batchQty = nil
					GM.Print(GM.CC("warn") .. "batch interrupted|r")
				end
			end
			return
		end
		if e == "TRADE_SKILL_SHOW" then
			Tr("TRADE_SKILL_SHOW")
			-- name the open line NOW from the live enum — waiting for
			-- the debounced recipe scan leaves lastProf stale/nil
			-- through the settle window, and stale session state can
			-- arm the OPEN overlay over the line that just opened
			if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
				local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
				if ok and type(ids) == "table" and ids[1] then
					local p = C.Prof(ids[1])
					if p then
						Tr("SHOW line =", p)
						C.lastProf = p
					end
				end
			end
			-- TSM parity: opening a tradeskill IS opening our crafting
			-- window (linked/NPC sessions excluded — not ours to drive)
			local linked = C_TradeSkillUI
				and C_TradeSkillUI.IsTradeSkillLinked
				and C_TradeSkillUI.IsTradeSkillLinked()
			local npc = C_TradeSkillUI and C_TradeSkillUI.IsNPCCrafting
				and C_TradeSkillUI.IsNPCCrafting()
			if not (linked or npc or C._pumping)
				and GM.CraftingUI and GM.CraftingUI.OnTradeSkillOpen then
				GM.CraftingUI.OnTradeSkillOpen()
			end
			-- the plan window's exec gate must re-evaluate on every
			-- line change — a stale armed overlay covers the button
			-- until something re-runs GateButton over it
			if GM.PlanQueue and GM.PlanQueue.Refresh then
				GM.PlanQueue.Refresh()
			end
			-- the OPEN overlay click cast the profession spell — now
			-- that the line is live, fire the craft it was for (the
			-- 0.6s tail lets the line's data land, same as the scan
			-- debounce)
			-- CraftRecipe is hardware-gated on this client — nothing
			-- can auto-fire the pending craft (a timer call no-ops,
			-- verified). The OPEN click's job ends here: the line is
			-- open, the gate clears, and the user's next real click on
			-- CRAFT runs the batch in one call. The pending entry only
			-- survives long enough to prompt that click.
			local p = C.pendingOpenCraft
			C.pendingOpenCraft = nil
			if p then
				Tr("pendingOpenCraft age", string.format(
					"%.2f", GetTime() - (p.t or 0)))
			end
			if p and GetTime() - (p.t or 0) <= 4 then
				local rr = GoblinMindCrafting.recipes
					and GoblinMindCrafting.recipes[p.id]
				GM.Print(GM.CC("secondary")
					.. (C.Prof(p.id) or "line")
					.. " open — click CRAFT for "
					.. (rr and rr.name or "recipe")
					.. " ×" .. (p.qty or 1) .. "|r")
				if GM.CraftingUI and GM.CraftingUI.Refresh then
					GM.CraftingUI.Refresh()
				end
			end
		elseif e == "TRADE_SKILL_CLOSE" then
			Tr("TRADE_SKILL_CLOSE")
			C.lastProf = nil -- session ended; a stale prof would
			-- read as "line open" in LineOpenFor's fallback
			C.batchQty = nil -- a dead line can't finish its batch
			-- close voids open-stamps — but only ones old enough to
			-- be the session that ended: a swap fires CLOSE for the
			-- OLD line, and Forever can deliver it AFTER the new
			-- line's SHOW (pending already consumed → keyed survival
			-- failed). A stamp younger than its own cast's settle
			-- window can't be the line that just closed — keep it.
			if C.recentOpen then
				local now = GetTime()
				for rid, t in pairs(C.recentOpen) do
					if now - t > 8 then C.recentOpen[rid] = nil end
				end
			end
			-- TSM parity: session end = our window end (K toggle-off
			-- and every other native close land here)
			if GM.CraftingUI and GM.CraftingUI.OnTradeSkillClose then
				GM.CraftingUI.OnTradeSkillClose()
			end
			if GM.PlanQueue and GM.PlanQueue.Refresh then
				GM.PlanQueue.Refresh()
			end
			return -- no scan on close
		end
		if e == "PLAYER_LOGIN" then
			-- recipes only enumerate under an open tradeskill line —
			-- a fresh profile captures nothing until each prof has
			-- been opened once, so pump the missing lines ourselves
			-- (delayed: the login event burst races profession data)
			GM.After(6, ProfPump)
			return
		end
		-- trailing debounce: profession context settles sometime during
		-- the event burst — only scan 0.5s after the LAST event, never
		-- the first. DATA_SOURCE_CHANGED can land after LIST_UPDATE.
		C.scanGen = (C.scanGen or 0) + 1
		local gen = C.scanGen
		GM.After(0.5, function()
			if gen ~= C.scanGen then return end
			Scan()
			-- the scan knows which profession just opened — point the
			-- browser at it (no-op if the window isn't up)
			if GM.CraftingUI then
				if C.lastProf and GM.CraftingUI.SelectProf then
					GM.CraftingUI.SelectProf(C.lastProf)
				elseif GM.CraftingUI.Refresh then
					GM.CraftingUI.Refresh()
				end
			end
		end)
	end)
end

-- ============ cost model ============

-- per-unit mat price: market first, vendor-sell as the floor (matches
-- TSM's default matPrice fallback chain minus sources we lack)
function C.MatPrice(itemID)
	local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
	local ah = GM.Price("dbmarket", itemID)
	local vb = GM.Price("vendorbuy", itemID)
	-- vendor mats (flux, stock, thread) price at the vendor when it's
	-- the cheaper source — crafting math stays honest either way
	if vb and vb > 0 and (not ah or vb < ah) then return vb end
	return ah or (GetInfo and select(11, GetInfo(itemID)))
end

-- SINGLE execution path for craft economics — every surface that
-- answers "is this craft worth it" (market rows, craft window,
-- task list, suggest qty) derives from this one calculation, so
-- owned-mat coverage can't drift between windows.
--
-- Two costs per output unit:
--   fullCost — buy EVERY mat (the old MatCost).
--   effCost  — buy only what's missing after bags/bank/mail/gbank/
--              owned auctions/alts (C.Available). With 80% coverage
--              a buy-all loss can still be a real profit.
-- profit/effProfit are per output unit; nil when unpriced (honest
-- "no data", never fabricated).
function C.Economics(recipeID, qty)
	local r = GoblinMindCrafting and GoblinMindCrafting.recipes
		and GoblinMindCrafting.recipes[recipeID]
	if not r or not r.mats then return nil end
	qty = max(1, qty or 1)
	local numMade = r.numMade or 1
	local units = qty * numMade
	local price = GM.Price("dbmarket", r.itemID)
	local priced, full, buy, owned, needT = true, 0, 0, 0, 0
	local mats = {}
	for _, m in ipairs(r.mats or {}) do
		local p = C.MatPrice(m.id)
		local need = (m.qty or 1) * qty
		local have = C.Available(m.id)
		local miss = max(0, need - have)
		if not p then priced = false end
		full = full + (p or 0) * need
		buy = buy + (p or 0) * miss
		owned = owned + min(need, have)
		needT = needT + need
		mats[#mats + 1] = { id = m.id, need = need, have = have,
			miss = miss, price = p }
	end
	local fullU = priced and floor(full / units) or nil
	local effU = priced and floor(buy / units) or nil
	return {
		qty = qty, units = units, mats = mats, priced = priced,
		price = price,
		fullCost = fullU, effCost = effU,
		profit = (priced and price) and price - fullU or nil,
		effProfit = (priced and price) and price - effU or nil,
		coverage = needT > 0 and owned / needT or 0,
	}
end

-- cost to craft ONE output item (÷ numMade); nil if unknown recipe
function C.MatCost(recipeID)
	local e = C.Economics(recipeID, 1)
	return e and e.fullCost
end

function C.RecipeForItem(itemID)
	for id, r in pairs(GoblinMindCrafting and GoblinMindCrafting.recipes or {}) do
		-- unlearned rows still carry itemID when the schematic
		-- answered — they are NOT craft paths
		if r.itemID == itemID and not r.unlearned then return id, r end
	end
end

-- profit per crafted unit vs current price model
function C.Profit(recipeID)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return nil end
	local e = C.Economics(recipeID, 1)
	if e then return e.profit, e.price, e.fullCost end
end

-- mats a crafter can actually use RIGHT NOW: carried bags + live bank.
-- BankCount returns 0 while the bank frame is closed — snapshot stock
-- is counted by C.Available, not here, because closed-bank mats can't
-- feed a cast.
function C.Owned(itemID)
	return (GM.BagCount(itemID) or 0) + (GM.BankCount(itemID) or 0)
end

-- stock the account actually has: bags + bank + mail + gbank + owned
-- auctions + every alt's bags/bank. Plans buy only the true shortfall;
-- craftable counts deliberately stay on C.Owned (reachable mats).
function C.Available(itemID)
	local c = GM.Inventory.Count(itemID)
	return c.allTotal or c.total or 0
end

-- mats still needed to craft qty× — the true BUY shortfall after
-- every tracked location (bank, mail, gbank, owned auctions, alts)
function C.Missing(recipeID, qty)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return {} end
	local out = {}
	for _, m in ipairs(r.mats or {}) do
		local need = m.qty * qty - C.Available(m.id)
		if need > 0 then tinsert(out, { id = m.id, qty = need }) end
	end
	return out
end

-- per-mat coverage for qty× of a recipe — the split a plan needs:
-- what's in bags vs retrievable from this char's bank/mail/gbank/AH
-- vs sitting on an alt vs a genuine buy shortfall. Plans emit
-- fetch → alt → buy steps in that order; craftability itself is bags.
function C.MatSources(recipeID, qty)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return {} end
	local out = {}
	for _, m in ipairs(r.mats or {}) do
		local need = (m.qty or 1) * qty
		local c = GM.Inventory.Count(m.id)
		local short = need - (c.bags or 0)
		if short > 0 then
			local fetch = min(short,
				(c.bank or 0) + (c.mail or 0) + (c.guild or 0)
					+ (c.auction or 0))
			local alt = min(short - fetch, c.alts or 0)
			tinsert(out, { id = m.id, need = need, fetch = fetch,
				alt = alt, buy = short - fetch - alt })
		end
	end
	return out
end

-- ============ custom categories ============
-- user-defined recipe groupings, independent of profession. Stored as
-- GoblinMindCrafting.cats[name][recipeID] = true; the browser lists
-- them under the professions like TSM's groups.

local function Cats()
	GoblinMindCrafting.cats = GoblinMindCrafting.cats or {}
	return GoblinMindCrafting.cats
end

function C.CatList()
	local out = {}
	for name, set in pairs(Cats()) do
		local n = 0
		for _ in pairs(set) do n = n + 1 end
		tinsert(out, { name = name, n = n })
	end
	sort(out, function(a, b) return a.name < b.name end)
	return out
end

function C.CatCreate(name)
	if not (name and name ~= "") then return end
	Cats()[name] = Cats()[name] or {}
	GM.Crafting.dirty = true
end

function C.CatAssign(name, recipeID)
	if not (name and name ~= "") then return end
	Cats()[name] = Cats()[name] or {}
	Cats()[name][recipeID] = true
	GM.Crafting.dirty = true
end

function C.CatUnassign(name, recipeID)
	local c = Cats()[name]
	if c then c[recipeID] = nil GM.Crafting.dirty = true end
end

function C.CatDelete(name)
	if Cats()[name] then Cats()[name] = nil GM.Crafting.dirty = true end
end

function C.CatHas(name, recipeID)
	local c = Cats()[name]
	return c and c[recipeID] and true or false
end

-- ============ queue ============

-- shared step emission for a mat coverage row: fetch from this char's
-- bank/mail/gbank/auctions first, note what an alt has, buy only the
-- true shortfall. Fetch is a real step — the click pulls a stack from
-- the bank (bounces to the plan tail when the bank is unreachable);
-- alt stays a manual note.
local function MatSteps(steps, s)
	local nm = (GM.ItemName and GM.ItemName(s.id)) or ("item " .. s.id)
	if s.fetch > 0 then
		local desc = "from bank/mail/gbank"
		if s.bagged and s.bagged > 0 then
			desc = desc .. " · " .. s.bagged .. " already in bags"
		end
		tinsert(steps, { kind = "fetch", verb = "FETCH", itemID = s.id,
			qty = s.fetch, name = nm, bagBase = GM.BagCount(s.id),
			desc = desc })
	end
	if s.alt > 0 then
		tinsert(steps, { kind = "note", verb = "ALT", itemID = s.id,
			qty = s.alt, name = nm,
			desc = "mail over from an alt" })
	end
	if s.buy > 0 then
		tinsert(steps, { kind = "buy", itemID = s.id, qty = s.buy,
			name = nm, unit = C.MatPrice(s.id) or 0,
			commodity = true, btag = "craft",
			bagBase = GM.BagCount(s.id) })
	end
end

-- shared resolution for a set of {recipeID, qty[, itemID, name,
-- prof]} entries — single-recipe Queue AND whole-queue QueueEmit run
-- the same math: aggregate mat coverage, recurse buy-shortfalls into
-- sub-crafts when crafting beats buying (owned-mat coverage is
-- C.Economics' effCost, the single math path). Returns the aggregated
-- coverage map, craft order (subs before dependents), sub-craft
-- counts, and the queued-entry index.
local function ResolveSources(entries)
	local agg = {}        -- itemID → {fetch,alt,buy} across everything
	local craftOrder = {} -- recipeIDs, subs appended before dependents
	local orderSet = {}
	local subCrafts = {}  -- rid → crafts needed (non-queued recipes)
	local queuedQty = {}  -- rid → entry (queued demand)

	local function AddAgg(id, f, a, b)
		local t = agg[id] or { fetch = 0, alt = 0, buy = 0 }
		t.fetch, t.alt, t.buy = t.fetch + f, t.alt + a, t.buy + b
		agg[id] = t
	end

	-- shared coverage pool: Count() reports the FULL stock per item,
	-- but each unit exists once — two demand rows for the same mat
	-- (queued sub-crafts or a parent resolving its intermediates)
	-- can't each subtract the same bagged stack. Spend bags →
	-- retrievable (bank/mail/gbank/AH) → alts → buy, in that order.
	-- `bagged` records what bags covered so steps can say so.
	local pool = {}
	local function Pool(id)
		local p = pool[id]
		if not p then
			local c = GM.Inventory.Count(id)
			p = { bags = c.bags or 0, bagged = 0,
				retr = (c.bank or 0) + (c.mail or 0)
					+ (c.guild or 0) + (c.auction or 0),
				alts = c.alts or 0 }
			pool[id] = p
		end
		return p
	end

	local ResolveMat, AllocMat
	AllocMat = function(itemID, need, inPath)
		local p = Pool(itemID)
		local spend = min(need, p.bags)
		p.bags, p.bagged = p.bags - spend, p.bagged + spend
		local rem = need - spend
		if rem <= 0 then return end
		local f = min(rem, p.retr); p.retr = p.retr - f
		local a = min(rem - f, p.alts); p.alts = p.alts - a
		AddAgg(itemID, f, a, 0)
		local b = rem - f - a
		if b > 0 then ResolveMat(itemID, b, inPath) end
	end

	-- satisfy `need` units of itemID: craft when cheaper, else buy
	ResolveMat = function(itemID, need, inPath)
		local rid, r = C.RecipeForItem(itemID)
		if rid and not inPath[rid] then
			local crafts = ceil(need / (r.numMade or 1))
			local e = C.Economics(rid, crafts)
			local buyU = C.MatPrice(itemID)
			if e and e.effCost and buyU and e.effCost < buyU then
				inPath[rid] = true -- cycle guard: A→B→A buys the mat
				for _, m2 in ipairs(r.mats or {}) do
					AllocMat(m2.id, (m2.qty or 1) * crafts, inPath)
				end
				inPath[rid] = nil
				subCrafts[rid] = (subCrafts[rid] or 0) + crafts
				if not orderSet[rid] then
					orderSet[rid] = true
					tinsert(craftOrder, rid)
				end
				return
			end
		end
		AddAgg(itemID, 0, 0, need)
	end

	-- queued production credits demand elsewhere in the plan: if the
	-- queue already crafts N of a mat, a parent's mat row must see
	-- those N as covered instead of re-resolving (and re-demanding
	-- the parent's mats) for them. Queued producers also have to run
	-- before queued consumers, so entries allocate in dependency
	-- order — a queued recipe waits for the queued recipe that makes
	-- one of its mats.
	local entryByRid, producedBy = {}, {}
	for _, q in ipairs(entries) do
		entryByRid[q.recipeID] = q
		if q.itemID then producedBy[q.itemID] = q.recipeID end
	end
	local ordered, oset, visiting = {}, {}, {}
	local push
	push = function(q)
		local rid = q.recipeID
		if oset[rid] or visiting[rid] then return end
		visiting[rid] = true
		local r = GoblinMindCrafting.recipes[rid]
		for _, m in ipairs(r and r.mats or {}) do
			local pr = producedBy[m.id]
			if pr and pr ~= rid and entryByRid[pr] then
				push(entryByRid[pr])
			end
		end
		visiting[rid] = nil
		oset[rid] = true
		tinsert(ordered, q)
	end
	for _, q in ipairs(entries) do push(q) end

	for _, q in ipairs(ordered) do
		queuedQty[q.recipeID] = q
		local r = GoblinMindCrafting.recipes[q.recipeID]
		if r and q.itemID then
			local p = Pool(q.itemID)
			p.bags = p.bags + q.qty * (r.numMade or 1)
		end
	end
	for _, q in ipairs(ordered) do
		local inPath = { [q.recipeID] = true }
		local r = GoblinMindCrafting.recipes[q.recipeID]
		for _, m in ipairs(r and r.mats or {}) do
			AllocMat(m.id, (m.qty or 1) * q.qty, inPath)
		end
		if not orderSet[q.recipeID] then
			orderSet[q.recipeID] = true
			tinsert(craftOrder, q.recipeID)
		end
	end
	return agg, craftOrder, subCrafts, queuedQty, pool
end

-- itinerary routing: acquisition steps carry an implicit location —
-- the emitted per-item order interleaved bank, vendor, AH and mailbox
-- trips (the "running all over Stormwind" report). Group them into
-- legs by location rank and walk each leg once. AH buys go first so
-- the mail-delivery clock starts immediately; mailcollect sits last
-- before crafts so winnings have the whole route to arrive; crafts
-- keep their post-order dependency chain inside the final leg. A
-- location that's ALREADY open goes first (adaptive start — the
-- player standing at the bank shouldn't be walked to the AH for
-- step 1). Stable: intra-leg order is emit order.
local LEG_RANK = {
	buy = 10, post = 10, cancel = 10, bid = 10,    -- AH leg
	fetch = 20, move = 20,                       -- bank leg
	vendbuy = 30, vendsell = 30, destroy = 30,   -- vendor leg
	mailcollect = 40, mail = 40,                 -- mailbox leg
	-- notes/skips/crafts = 50, emitted last
}

local function OpenLeg()
	if GM.AH and GM.AH.open then return 10 end
	if BankFrame and BankFrame:IsShown() then return 20 end
	if MerchantFrame and MerchantFrame:IsShown() then return 30 end
	if MailFrame and MailFrame:IsShown() then return 40 end
end

local function RouteSteps(steps)
	-- AH purchases arrive by mail: one targeted collect step per bought
	-- item, ranked into the mailbox leg — without it the plan silently
	-- depended on the player remembering to check the box mid-run
	local seen = {}
	for _, s in ipairs(steps) do
		if s.kind == "buy" and s.itemID and not seen[s.itemID] then
			seen[s.itemID] = true
			tinsert(steps, { kind = "mailcollect", itemID = s.itemID,
				qty = s.qty, name = s.name, bagBase = s.bagBase,
				desc = "collect your winnings" })
		end
	end
	local open = OpenLeg()
	local order = {}
	for i = 1, #steps do order[i] = i end
	table.sort(order, function(a, b)
		local ra = LEG_RANK[steps[a].kind] or 50
		local rb = LEG_RANK[steps[b].kind] or 50
		if ra == open then ra = 0 end
		if rb == open then rb = 0 end
		if ra ~= rb then return ra < rb end
		return a < b
	end)
	local out = {}
	for _, i in ipairs(order) do out[#out + 1] = steps[i] end
	return out
end

local function BuildPlanSteps(entries)
	local steps = {}
	local agg, craftOrder, subCrafts, queuedQty, pool =
		ResolveSources(entries)
	local ids = {}
	for id in pairs(agg) do ids[#ids + 1] = id end
	-- plan order: all fetches first (bank trip), then buys (AH trip)
	for _, id in ipairs(ids) do
		local p = pool and pool[id]
		MatSteps(steps, { id = id, fetch = agg[id].fetch,
			alt = agg[id].alt, buy = 0,
			bagged = p and p.bagged or 0 })
	end
	sort(ids, function(a, b)
		return ((C.MatPrice(a) or 0) * agg[a].buy)
			> ((C.MatPrice(b) or 0) * agg[b].buy)
	end)
	for _, id in ipairs(ids) do
		local s = agg[id]
		if s.buy > 0 then
			local nm = (GM.ItemName and GM.ItemName(id)) or ("item " .. id)
			-- raw AH price — MatPrice already folds in vendorbuy,
			-- which would make the vb<ahU test compare vb to itself
			local ahU = GM.Price("dbmarket", id) or 0
			local vb = GM.Price("vendorbuy", id)
			if vb and vb > 0 and vb < ahU then
				-- vendor stocks it cheaper than the AH — say so on the
				-- step so it doesn't read as "go to the auction house"
				tinsert(steps, { kind = "vendbuy", itemID = id,
					qty = s.buy, unit = vb, name = nm,
					bagBase = GM.BagCount(id),
					desc = format("vendor %s/ea · AH %s",
						GM.Money(vb), GM.Money(ahU)),
					btag = "craft" })
			else
				tinsert(steps, { kind = "buy", itemID = id, qty = s.buy,
					name = nm, unit = ahU, commodity = true,
					bagBase = GM.BagCount(id), btag = "craft" })
			end
		end
	end
	-- craft steps in dependency order — sub-crafts precede their
	-- dependents by construction (post-order append in ResolveMat)
	for _, rid in ipairs(craftOrder) do
		local q = queuedQty[rid]
		local crafts, itemID, nm, prof
		if q then
			-- queued demand + any sub-craft demand other recipes added
			crafts, itemID, nm, prof = q.qty + (subCrafts[rid] or 0),
				q.itemID,
				(GM.ItemName and GM.ItemName(q.itemID)) or q.name or "item",
				q.prof
		else
			local r = GoblinMindCrafting.recipes[rid]
			crafts, itemID = subCrafts[rid] or 1, r and r.itemID
			nm = (GM.ItemName and GM.ItemName(itemID))
				or (r and r.name) or "item"
			prof = (r and r.prof and r.prof .. " · sub-craft")
				or "sub-craft"
		end
		tinsert(steps, { kind = "note", verb = "CRAFT", itemID = itemID,
			qty = crafts, recipeID = rid, name = nm,
			desc = prof or "tradeskill" })
	end
	return RouteSteps(steps)
end


-- Emit a plan: fetch/alt/buy missing mats, then a craft step — with
-- the same sub-craft resolution QueueEmit runs (a short mat that's
-- cheaper to make than buy becomes its own fetch/buy/craft chain).
function C.Queue(recipeID, qty)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return end
	qty = max(1, qty or 1)
	local steps = BuildPlanSteps({ {
		recipeID = recipeID, qty = qty, itemID = r.itemID,
		name = r.name, prof = r.prof } })
	GM.PlanQueue.SetScanPlan({ steps = steps, itemID = r.itemID,
		mode = "craft", source = "craft:" .. recipeID,
		recipeID = recipeID, qty = qty })
end

-- list for the market window CRAFT mode
-- List() prices every recipe's economics + craftability — ~200
-- recipes × ~6 mats of inventory lookups. Dashboard, CraftingUI,
-- TaskListUI and Shopping all call it per render; a 3s TTL collapses
-- the callers into one build (the per-render rebuild was the
-- "insecure scripts exceeded execution limit" kill on window-open)
local listCache = { t = 0, data = nil }
function C.List()
	local now = GetTime()
	if listCache.data and now - listCache.t < 3 then
		return listCache.data
	end
	C._listCalls = (C._listCalls or 0) + 1
	local t0 = GetTime()
	local out = {}
	for id, r in pairs(GoblinMindCrafting and GoblinMindCrafting.recipes or {}) do
		local e = C.Economics(id, 1) or {}
		local craftable = C.Craftable(id)
		-- suggested queue qty: restock ops target a stock level; otherwise
		-- profitable recipes queue what inventory covers (floor 1 — mats
		-- can be bought, the queue emits the buy steps). Effective profit
		-- (owned-mat coverage applied) is the decision number.
		local suggest = 0
		if e.effProfit and e.effProfit > 0 then
			local ops = GM.Groups.GetOps and GM.Groups.GetOps(r.itemID, "crafting") or {}
			if ops.restock and (ops.restockQty or 0) > 0 then
				suggest = max(0, ops.restockQty - C.Owned(r.itemID))
			else
				suggest = max(craftable, 1)
			end
		end
		tinsert(out, {
			recipeID = id, itemID = r.itemID, name = r.name,
			prof = r.prof, mats = r.mats, diff = r.diff,
			nup = r.nup, unlearned = r.unlearned, req = r.req,
			cost = e.fullCost, price = e.price, profit = e.profit,
			effCost = e.effCost, effProfit = e.effProfit,
			coverage = e.coverage, eco = e,
			craftable = craftable, craftableAll = C.CraftableAll(id),
			suggest = suggest,
		})
	end
	sort(out, function(a, b)
		local ap, bp = a.effProfit, b.effProfit
		if (ap ~= nil) ~= (bp ~= nil) then return ap ~= nil end
		if ap and bp and ap ~= bp then return ap > bp end
		return (a.name or "") < (b.name or "")
	end)
	listCache.data, listCache.t = out, now
	C._listMs = (C._listMs or 0) + (GetTime() - t0) * 1000
	return out
end

-- the "bags N" column + CRAFTABLE ONLY filter + the Craft gate all
-- mean "castable right now" — BAGS ONLY. The engine won't take bank
-- mats for a cast even while the frame's open, and our parked-offscreen
-- BankFrame keeps IsShown() true for the whole BankUI session, so
-- C.Owned's live-bank leg would count closed-looking bank stock.
-- Fetchable stock (bank/mail/alts/gbank) is the +N from CraftableAll.
function C.Craftable(recipeID)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return 0 end
	local n = math.huge
	for _, m in ipairs(r.mats or {}) do
		n = min(n, floor((GM.BagCount(m.id) or 0) / m.qty))
	end
	return n == math.huge and 0 or n
end

-- how many IF every tracked location is raided — bags + bank + mail +
-- gbank + auctions + alts. The "+N" beside can: means "fetchable stock".
function C.CraftableAll(recipeID)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return 0 end
	local n = math.huge
	for _, m in ipairs(r.mats or {}) do
		n = min(n, floor(C.Available(m.id) / m.qty))
	end
	return n == math.huge and 0 or n
end

-- ============ tradeskill-line open ============
-- CraftRecipe only acts on the CURRENTLY OPEN tradeskill line — a
-- queued Smelt Iron cast is a no-op while Engineering (or nothing) is
-- open. On Forever the line opens by casting the profession spell,
-- which is a protected call needing a hardware event — the same shape
-- TSM uses (its profession dropdown is a secure spell button). The UI
-- arms a SecureActionButton overlay labeled OPEN; the click casts the
-- spell, TRADE_SKILL_SHOW fires, and C.pendingOpenCraft re-fires the
-- craft the user asked for — one click, one cast.
local function SpellName(id)
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, id)
		if ok and type(n) == "string" and n ~= "" then return n end
	end
	if GetSpellInfo then
		local ok, n = pcall(GetSpellInfo, id)
		if ok and type(n) == "string" and n ~= "" then return n end
	end
end

-- Mining's spellbook entry actually opens Smelting (TSM parity —
-- GetProfessionSpellName maps Mining→Smelting); every other
-- profession's display name IS its spell name
local function ProfSpellName(prof)
	local mine = SpellName(2575)
	if mine and prof == mine then return SpellName(2656) or prof end
	return prof
end

-- spell name the OPEN button casts for this recipe's profession
function C.ProfSpell(recipeID)
	local prof = C.Prof(recipeID)
	if not prof then return nil end
	return ProfSpellName(prof), prof
end

-- is the line that can craft recipeID the currently open one?
function C.LineOpenFor(recipeID)
	if ForeignTradeskill() then return true end -- linked/NPC: they own the line
	if not (C_TradeSkillUI and C_TradeSkillUI.CraftRecipe) then
		return true -- can't tell — let CraftRecipe try
	end
	-- the live recipe list answers exactly what CraftRecipe needs —
	-- "is this recipe in the open line" — and GetTradeSkillLine can't
	-- be trusted on Forever (the function exists but errors on call).
	-- A NON-EMPTY list is authoritative; an EMPTY result is
	-- inconclusive — these APIs are partially stubbed on this client
	-- and an empty table can't tell "line closed" from "enumeration
	-- dead". Treating {} as "closed" was the OPEN-button freeze: the
	-- gate armed while the line was live, and the cast then toggled
	-- that line shut.
	-- we cast this recipe's open spell ourselves and no session-close
	-- has voided the stamp since — the OPEN→CRAFT intermediate step:
	-- treat the line as open without asking the (often stale) enum.
	-- A cast that never produced TRADE_SKILL_SHOW expires with its
	-- pending entry so the gate can re-arm for a real retry.
	local ro = C.recentOpen and C.recentOpen[recipeID]
	if ro then
		local p = C.pendingOpenCraft
		if (p and p.id == recipeID and GetTime() - (p.t or 0) > 6)
			or GetTime() - ro > 12 then
			-- cast produced no SHOW, or the stamp outlived its
			-- settle window — by 12s Scan's lastProf holds the truth
			C.recentOpen[recipeID] = nil
			if p and p.id == recipeID then C.pendingOpenCraft = nil end
			Tr("open? stamp expired")
		else
			Tr("open? yes — open cast issued")
			return true
		end
	end
	-- presence in EITHER enum proves open; only GetAllRecipeIDs can
	-- prove absence — GetFilteredRecipeIDs honors the Blizzard
	-- frame's search filter, so a recipe missing from it can still
	-- belong to the live line (a filtered subset must never be an
	-- absence verdict)
	local sawList
	for _, fn in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
		if C_TradeSkillUI[fn] then
			local ok, res = pcall(C_TradeSkillUI[fn])
			if ok and type(res) == "table" and #res > 0 then
				if fn == "GetAllRecipeIDs" then sawList = true end
				for _, id in ipairs(res) do
					if id == recipeID then
						Tr("open? yes — recipe in", fn)
						return true
					end
				end
			end
		end
	end
	-- tracked session state beats enum absence: Scan records the
	-- profession it actually saw open (TRADE_SKILL_CLOSE clears it),
	-- while the enum lags a line swap and can hold the OLD line's
	-- list — absence in a stale list must not outrank an open we
	-- observed ourselves
	local prof = C.Prof(recipeID)
	if prof and C.lastProf then
		if C.lastProf == prof then
			Tr("open? yes — lastProf", C.lastProf)
			return true
		end
		-- Mining↔Smelting share a line (Mining's spell opens Smelting)
		local mine, smelt = SpellName(2575), SpellName(2656)
		if mine and smelt
			and (C.lastProf == mine or C.lastProf == smelt)
			and (prof == mine or prof == smelt) then
			Tr("open? yes — lastProf alias", C.lastProf)
			return true
		end
	end
	if sawList then
		Tr("open? no — live list lacks recipe")
		return false
	end
	if prof and C.lastProf then
		Tr("open? no — lastProf is", C.lastProf, "≠", prof)
		return false -- a different line is the live one
	end
	-- nothing tracked: the Blizzard tradeskill frame is the last
	-- ground truth — it's never hidden while a line is live (a parked
	-- frame stays SHOWN; the client hides it when the session ends)
	local pf = ProfessionsFrame or TradeSkillFrame
	if pf and not pf:IsShown() then
		Tr("open? no — native frame hidden")
		return false
	end
	-- can't tell — let CraftRecipe try; the pendingCast watchdog
	-- reports a dead call instead of dead-ending here
	Tr("open? unsure → permissive (pf", pf and "shown" or "nil", ")")
	return true
end

-- POSITIVE evidence the recipe's line is closed — this is what arms
-- the OPEN overlay, and the distinction matters: the overlay casts a
-- profession spell, and casting it on an already-open line TOGGLES
-- the session shut (the open-sound/close-sound loop). Arming needs
-- certainty; uncertainty falls to the plain craft button where a
-- wrong guess only costs a watchdog-reported dead call.
function C.LineClosedFor(recipeID)
	if ForeignTradeskill() then return false end
	if not (C_TradeSkillUI and C_TradeSkillUI.CraftRecipe) then
		return false
	end
	-- we cast this recipe's open spell and no session-close has
	-- voided the stamp — the line is ours, don't arm the toggle-cast
	-- (the observed open/close loop). If the cast never produced a
	-- SHOW the stamp expires with its pending entry so a real retry
	-- can arm.
	local ro = C.recentOpen and C.recentOpen[recipeID]
	if ro then
		local p = C.pendingOpenCraft
		if (p and p.id == recipeID and GetTime() - (p.t or 0) > 6)
			or GetTime() - ro > 12 then
			C.recentOpen[recipeID] = nil
			if p and p.id == recipeID then C.pendingOpenCraft = nil end
			Tr("closed? stamp expired")
		else
			Tr("closed? no — open cast issued")
			return false
		end
	end
	-- a live non-empty list that lacks the recipe means a DIFFERENT
	-- line is open — casting our profession's spell is the correct
	-- switch, not a toggle
	-- presence in EITHER enum means not-closed; only GetAllRecipeIDs
	-- can prove absence — GetFilteredRecipeIDs honors the Blizzard
	-- frame's search filter, and a recipe missing from a filtered
	-- subset can still belong to the live line (ambiguous absence
	-- must never arm the toggle-cast)
	local sawList
	for _, fn in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
		if C_TradeSkillUI[fn] then
			local ok, res = pcall(C_TradeSkillUI[fn])
			if ok and type(res) == "table" and #res > 0 then
				if fn == "GetAllRecipeIDs" then sawList = true end
				for _, id in ipairs(res) do
					if id == recipeID then
						Tr("closed? no — recipe in", fn)
						return false
					end
				end
			end
		end
	end
	-- tracked session state beats enum absence here too: Scan saw
	-- lastProf open (TRADE_SKILL_CLOSE clears it), while the enum
	-- can still hold the PREVIOUS line's list mid-swap — absence in
	-- a stale list must not arm the toggle-cast over an open we
	-- observed ourselves
	local prof = C.Prof(recipeID)
	if prof and C.lastProf then
		if C.lastProf == prof then
			Tr("closed? no — lastProf", C.lastProf)
			return false
		end
		-- Mining↔Smelting share a line — lastProf=Mining with a
		-- Smelting recipe is the same session, not a closed one
		local mine, smelt = SpellName(2575), SpellName(2656)
		if mine and smelt
			and (C.lastProf == mine or C.lastProf == smelt)
			and (prof == mine or prof == smelt) then
			Tr("closed? no — lastProf alias", C.lastProf)
			return false
		end
	end
	if sawList then
		Tr("closed? yes — live list lacks recipe")
		return true
	end
	if prof and C.lastProf then
		Tr("closed? yes — lastProf", C.lastProf, "≠", prof)
		return true -- a different line verifiably opened last
	end
	-- the native frame hidden = no session at all
	local pf = ProfessionsFrame or TradeSkillFrame
	if pf and not pf:IsShown() then
		Tr("closed? yes — native frame hidden")
		return true
	end
	Tr("closed? no — can't prove it")
	return false -- can't prove closed — don't arm the toggle-cast
end

-- ============ secure OPEN overlay (shared by CraftingUI + PlanQueue) ============
-- The overlay is a SecureActionButtonTemplate child of the normal
-- button: armed, it covers the button and the click casts the
-- profession spell instead of reaching OnClick. pendingOpenCraft is
-- stashed so TRADE_SKILL_SHOW can prompt the real CRAFT click —
-- CraftRecipe is hardware-gated, nothing may fire it for the user.
local function SecureOpenFor(btn)
	if btn._gmOpen then return btn._gmOpen end
	local ov = CreateFrame("Button", nil, btn,
		"SecureActionButtonTemplate")
	ov:SetAllPoints()
	ov:SetFrameLevel(btn:GetFrameLevel() + 5)
	ov:RegisterForClicks(GetCVarBool
		and GetCVarBool("ActionButtonUseKeyDown")
		and "LeftButtonDown" or "LeftButtonUp")
	ov:SetAttribute("type", "spell")
	ov:HookScript("OnClick", function()
		Tr("OPEN click — casting", ov:GetAttribute("spell"),
			"for recipe", ov._rid)
		C.pendingOpenCraft = { id = ov._rid, qty = ov._qty,
			t = GetTime() }
		-- the gate must not re-arm while this cast's line swap is
		-- still landing — LineClosedFor consults this stamp
		C.recentOpen = C.recentOpen or {}
		if ov._rid then C.recentOpen[ov._rid] = GetTime() end
		-- the arm is consumed on use — leave it up and a second
		-- click re-casts the spell onto the (now open) line before
		-- any refresh can disarm it
		ov:Hide()
		-- a cast that produces no SHOW never ran (dead spell name,
		-- range, whatever) — say so, and clear the stamp so the next
		-- gate eval re-arms honestly instead of sitting on a
		-- phantom "open" for the stamp's full 12s
		local rid = ov._rid
		GM.After(4.5, function()
			local p = C.pendingOpenCraft
			if not (p and p.id == rid) then return end
			C.pendingOpenCraft = nil
			if C.recentOpen then C.recentOpen[rid] = nil end
			Tr("OPEN cast produced no SHOW for", rid)
			GM.Print(GM.CC("warn") .. (C.Prof(rid) or "tradeskill")
				.. " didn't open — click OPEN to retry|r")
			if GM.CraftingUI and GM.CraftingUI.Refresh then
				GM.CraftingUI.Refresh()
			end
			if GM.PlanQueue and GM.PlanQueue.Refresh then
				GM.PlanQueue.Refresh()
			end
		end)
	end)
	ov:Hide()
	btn._gmOpen = ov
	return ov
end

-- returns true when an armed OPEN overlay covers the button (the
-- normal craft click is superseded). `allow` gates arming without
-- skipping the hide — a button that stops qualifying must still shed
-- a stale overlay. Protected-frame attribute and visibility changes
-- are combat-locked, so mid-fight this just leaves the button alone —
-- C.Craft's own guard reports the closed line.
function C.GateButton(btn, recipeID, qty, allow)
	local ov = SecureOpenFor(btn)
	if InCombatLockdown and InCombatLockdown() then return false end
	-- arm only on positive-closed evidence — an unsure "maybe closed"
	-- would let this click toggle a live line shut
	if allow and C.LineClosedFor(recipeID) then
		local spell = C.ProfSpell(recipeID)
		if spell then
			Tr("gate armed — spell:", spell)
			ov._rid, ov._qty = recipeID, qty
			ov:SetAttribute("spell", spell)
			ov:Show()
			return true
		end
		Tr("gate can't arm — no spell for", C.Prof(recipeID))
	else
		Tr("gate clear — allow:", allow)
	end
	ov:Hide()
	return false
end

-- pendingCast watchdog, shared by the first call and every chain
-- link: a call that produces no UNIT_SPELLCAST_START within 0.6s
-- never ran — report it and stop any batch in flight.
function C.WatchCast(recipeID)
	GM.After(0.6, function()
		if not (C.pendingCast and C.pendingCast.id == recipeID) then return end
		C.pendingCast = nil
		Tr("watchdog — no cast started for", recipeID)
		-- a batch that produced no cast gets the louder wording
		local pendingBatch = C.batchQty and C.batchQty.n and C.batchQty.n > 1
		C.batchQty = nil -- dead call; the next click is a fresh run
		if pendingBatch then
			GM.Print(GM.CC("warn") .. "batch stopped — "
				.. "a cast didn't start|r")
		else
			GM.Print(GM.CC("warn") .. "craft didn't start — "
				.. (C.Prof(recipeID) or "tradeskill")
				.. " isn't open — click OPEN|r")
		end
	end)
end

-- execute a craft — the same protected call Blizzard's Create buttons
-- make. On Forever numCasts>1 works ONLY with the full argument list
-- (verified live: (id, n) alone is silently ignored; the six-arg call
-- multicrafts), and ONLY from a hardware event — timer/event calls
-- no-op, so one click = one whole batch via the engine's own
-- auto-repeat. Queue decrements happen in OnCastComplete, not here —
-- counts track casts that actually finished, not casts we asked for.
-- Queue decrements happen in OnCastComplete, not here — counts track
-- casts that actually finished, not casts we asked for.
function C.Craft(recipeID, qty)
	local r = GoblinMindCrafting.recipes and GoblinMindCrafting.recipes[recipeID]
	if not r then return nil, "unknown recipe" end
	if not C.LineOpenFor(recipeID) then
		return nil, (C.Prof(recipeID) or "tradeskill")
			.. " isn't open — click OPEN"
	end
	if not (C_TradeSkillUI and C_TradeSkillUI.CraftRecipe) then
		return nil, "no craft API on this client"
	end
	if C.batchQty then
		return nil, "already crafting — let the cast finish"
	end
	local n = max(1, floor(qty or 1))
	-- whole stack or error: CraftRecipe silently no-ops when the
	-- recipe can't craft (no mats/forge), which the watchdog then
	-- can't tell apart from a protection squelch — gate first.
	-- Only when mats are actually known: a recipe captured without
	-- reagent data reports 0 craftable forever and would dead-end
	-- every click — let CraftRecipe try and let the watchdog say it
	local knowsMats = r.mats and next(r.mats) ~= nil
	local can = knowsMats and C.Craftable and C.Craftable(recipeID) or n
	if can < n then
		Tr("craft blocked —", can, "of", n, "craftable")
		return nil, format("only %d craftable — missing "
			.. "materials or station?", can)
	end
	Tr("craft", recipeID, "qty", n)
	-- TSM parity, verified live: the full arg list in a hardware-
	-- event context is what makes numCasts>1 work — (id, n) alone
	-- is silently ignored. Timer/event callbacks can't craft at
	-- all on this client; a click is required either way.
	C.pendingCast = { id = recipeID }
	local itemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
	C.batchQty = { id = recipeID, n = n,
		itemID = r.itemID, itemCount = itemCount,
		before = (itemCount and r.itemID) and itemCount(r.itemID) or 0 }
	local ok, err = pcall(C_TradeSkillUI.CraftRecipe,
		recipeID, n, nil, nil, nil, nil)
	if not ok then
		Tr("CraftRecipe error:", err)
		C.pendingCast = nil
		C.batchQty = nil
		return nil, tostring(err)
	end
	C.WatchCast(recipeID)
	return true
end

-- ============ persistent queue ============
-- GoblinMindCrafting.queue[recipeID] = qty — survives reload, drives
-- the queue manager window and the aggregated emit plan.

-- queueOrder tracks insertion order — the queue is a hash map, so
-- without it the list renders alphabetically and new recipes land
-- mid-list instead of appending at the bottom
local function OrderIndex(id)
	for i, v in ipairs(GoblinMindCrafting.queueOrder or {}) do
		if v == id then return i end
	end
end

function C.QueueSet(recipeID, qty)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return end
	-- unlearned recipes never queue — they render as info rows and
	-- clicking them shows where-to-get text instead
	if r.unlearned and (qty or 0) > 0 then return end
	if qty and qty > 0 then
		GoblinMindCrafting.queue[recipeID] = floor(qty)
		GoblinMindCrafting.queueOrder = GoblinMindCrafting.queueOrder or {}
		if not OrderIndex(recipeID) then
			tinsert(GoblinMindCrafting.queueOrder, recipeID)
		end
	else
		GoblinMindCrafting.queue[recipeID] = nil
		local i = OrderIndex(recipeID)
		if i then tremove(GoblinMindCrafting.queueOrder, i) end
	end
end

function C.QueueAdd(recipeID, delta)
	local r = GoblinMindCrafting.recipes and GoblinMindCrafting.recipes[recipeID]
	if r and r.unlearned then return end
	local cur = GoblinMindCrafting.queue[recipeID] or 0
	C.QueueSet(recipeID, cur + (delta or 0))
end

function C.QueueClear()
	wipe(GoblinMindCrafting.queue)
	wipe(GoblinMindCrafting.queueOrder or {})
end

function C.QueueCount()
	local n = 0
	for _ in pairs(GoblinMindCrafting.queue) do n = n + 1 end
	return n
end

-- queued recipes with the same computed fields as List()
function C.QueueList()
	local out = {}
	-- insertion order first; legacy entries with no order record go
	-- last, alphabetically so they at least group predictably
	local seen, tail = {}, {}
	local function emit(id, qty)
		local r = GoblinMindCrafting.recipes[id]
		if not r then return end
		local profit, p, cost = C.Profit(id)
		return {
			recipeID = id, qty = qty, itemID = r.itemID,
			name = r.name, prof = r.prof, mats = r.mats,
			cost = cost, price = p, profit = profit,
			craftable = C.Craftable(id),
			craftableAll = C.CraftableAll(id),
		}
	end
	for _, id in ipairs(GoblinMindCrafting.queueOrder or {}) do
		local qty = GoblinMindCrafting.queue[id]
		if qty then
			seen[id] = true
			local row = emit(id, qty)
			if row then tinsert(out, row) end
		end
	end
	for id, qty in pairs(GoblinMindCrafting.queue) do
		if not seen[id] then
			local row = emit(id, qty)
			if row then tinsert(tail, row) end
		end
	end
	sort(tail, function(a, b) return (a.name or "") < (b.name or "") end)
	for _, row in ipairs(tail) do tinsert(out, row) end
	return out
end

-- aggregated missing mats across the whole queue: itemID → qty still
-- needed after every tracked location AND after cheap sub-crafts are
-- resolved (a craftable shortfall counts its OWN buy shortfall, not
-- the finished item). Same ResolveSources math the plan emits.
function C.QueueMissing()
	local need = {}
	local agg = ResolveSources(C.QueueList())
	for id, s in pairs(agg) do
		if s.buy > 0 then need[id] = (need[id] or 0) + s.buy end
	end
	return need
end

-- emit one plan for the whole queue: aggregated fetch/alt/buy mat
-- steps (buys priciest first) then craft steps in dependency order.
-- When a missing mat is itself craftable and crafting it costs less
-- than buying (effective cost — coverage applied, C.Economics is the
-- single math path), the plan recurses into ITS mats and emits a
-- sub-craft step instead of a buy.
function C.QueueEmit()
	local steps = BuildPlanSteps(C.QueueList())
	if #steps == 0 then return nil, "queue is empty" end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "craft",
		source = "craft:queue" })
	return true
end
