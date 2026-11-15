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
		GM.Print("C_TSUI.GetTradeSkillLine: " .. tostring(C_TradeSkillUI.GetTradeSkillLine))
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
		-- concentration) — matches LibTSMWoW TradeSkill.Craft verbatim
		local ok, r1, r2 = pcall(C_TradeSkillUI.CraftRecipe,
			id, 1, nil, nil, nil, nil)
		GM.Print("CraftRecipe(1) pcall=" .. tostring(ok)
			.. " r1=" .. tostring(r1) .. " r2=" .. tostring(r2))
	end
end

local function Scan()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetFilteredRecipeIDs) then return end
	local ok, ids = pcall(C_TradeSkillUI.GetFilteredRecipeIDs)
	if not ok or type(ids) ~= "table" then return end
	-- GetBaseProfessionInfo LAGS the recipe list — at event time it
	-- still names the previously open profession (off-by-one tagging).
	-- GetTradeSkillLine reflects the list actually showing.
	local prof
	if C_TradeSkillUI.GetTradeSkillLine then
		local name = C_TradeSkillUI.GetTradeSkillLine()
		if type(name) == "string" and name ~= "" then prof = name end
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
		end
	end
	if n > 0 then GM.Crafting.dirty = true end
end

-- craft bookkeeping: UNIT_SPELLCAST_* events are the truth. Each
-- completed craft cast (spellID == recipeID) decrements the queue by
-- one and ticks the active plan step — so queue counts always match
-- what actually got made, whether the call batched or not.
local function OnCastComplete(unit, _, spellID)
	if unit ~= "player" or not spellID then return end
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
end

function C.Init()
	GoblinMindCrafting = GoblinMindCrafting or {}
	GoblinMindCrafting.recipes = GoblinMindCrafting.recipes or {}
	GoblinMindCrafting.queue = GoblinMindCrafting.queue or {}
	local f = CreateFrame("Frame")
	for _, evt in ipairs({
		"TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
		"TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "PLAYER_LOGIN",
		"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START",
		"UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_STOP",
	}) do pcall(f.RegisterEvent, f, evt) end
	f:SetScript("OnEvent", function(_, e, ...)
		if e == "UNIT_SPELLCAST_START"
			or e == "UNIT_SPELLCAST_CHANNEL_START" then
			local unit = ...
			-- any player cast starting inside the watch window means
			-- the call landed — don't filter on spellID: if the cast
			-- spell ever differs from recipeID we'd false-positive
			-- into the no-batch fallback while crafts actually work
			if unit == "player" and C.pendingCast then
				C.pendingCast = nil
			end
			return
		end
		if e == "UNIT_SPELLCAST_SUCCEEDED"
			or e == "UNIT_SPELLCAST_CHANNEL_STOP" then
			OnCastComplete(...)
			return
		end
		if e == "TRADE_SKILL_SHOW" then
			-- TSM parity: opening a tradeskill IS opening our crafting
			-- window (linked/NPC sessions excluded — not ours to drive)
			local linked = C_TradeSkillUI
				and C_TradeSkillUI.IsTradeSkillLinked
				and C_TradeSkillUI.IsTradeSkillLinked()
			local npc = C_TradeSkillUI and C_TradeSkillUI.IsNPCCrafting
				and C_TradeSkillUI.IsNPCCrafting()
			if not (linked or npc)
				and GM.CraftingUI and GM.CraftingUI.OnTradeSkillOpen then
				GM.CraftingUI.OnTradeSkillOpen()
			end
		elseif e == "TRADE_SKILL_CLOSE" then
			return -- no scan on close
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
	return GM.Price("dbmarket", itemID)
		or (GetInfo and select(11, GetInfo(itemID)))
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
	for _, m in ipairs(r.mats) do
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
		if r.itemID == itemID then return id, r end
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
	for _, m in ipairs(r.mats) do
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
	for _, m in ipairs(r.mats) do
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
-- true shortfall. Fetch/alt are plain note steps — the click
-- acknowledges, no protected call.
local function MatSteps(steps, s)
	local nm = (GM.ItemName and GM.ItemName(s.id)) or ("item " .. s.id)
	if s.fetch > 0 then
		tinsert(steps, { kind = "note", verb = "FETCH", itemID = s.id,
			qty = s.fetch, name = nm,
			desc = "from bank/mail/gbank" })
	end
	if s.alt > 0 then
		tinsert(steps, { kind = "note", verb = "ALT", itemID = s.id,
			qty = s.alt, name = nm,
			desc = "mail over from an alt" })
	end
	if s.buy > 0 then
		tinsert(steps, { kind = "buy", itemID = s.id, qty = s.buy,
			name = nm, unit = C.MatPrice(s.id) or 0,
			commodity = true, btag = "craft" })
	end
end

-- Emit a plan: fetch/alt/buy missing mats, then a craft step.
function C.Queue(recipeID, qty)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return end
	qty = max(1, qty or 1)
	local steps = {}
	for _, s in ipairs(C.MatSources(recipeID, qty)) do
		MatSteps(steps, s)
	end
	local nm = (GM.ItemName and GM.ItemName(r.itemID)) or r.name or "item"
	tinsert(steps, { kind = "note", verb = "CRAFT", itemID = r.itemID,
		qty = qty, recipeID = recipeID, name = nm,
		desc = r.prof or "tradeskill" })
	GM.PlanQueue.SetScanPlan({ steps = steps, itemID = r.itemID,
		mode = "craft", source = "craft:" .. recipeID })
end

-- list for the market window CRAFT mode
function C.List()
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
			nup = r.nup,
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
	return out
end

function C.Craftable(recipeID)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return 0 end
	local n = math.huge
	for _, m in ipairs(r.mats) do
		n = min(n, floor(C.Owned(m.id) / m.qty))
	end
	return n == math.huge and 0 or n
end

-- how many IF every tracked location is raided — bags + bank + mail +
-- gbank + auctions + alts. The "+N" beside can: means "fetchable stock".
function C.CraftableAll(recipeID)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return 0 end
	local n = math.huge
	for _, m in ipairs(r.mats) do
		n = min(n, floor(C.Available(m.id) / m.qty))
	end
	return n == math.huge and 0 or n
end

-- execute a craft — the same protected call Blizzard's Create buttons
-- make (verified: CraftRecipe(id,1) produces the item). count>1 is
-- Blizzard's own multicraft path — one call, N casts. If Forever
-- doesn't honor it the call produces no cast at all, so a watchdog
-- watches for UNIT_SPELLCAST_START: nothing within 0.6s → the batch
-- path is dead and every future call this session falls back to 1.
-- Queue decrements happen in OnCastComplete, not here — counts track
-- casts that actually finished, not casts we asked for.
function C.Craft(recipeID, qty)
	local r = GoblinMindCrafting.recipes and GoblinMindCrafting.recipes[recipeID]
	if not r then return nil, "unknown recipe" end
	if not (C_TradeSkillUI and C_TradeSkillUI.CraftRecipe) then
		return nil, "no craft API on this client"
	end
	local n = C.noBatch and 1 or max(1, floor(qty or 1))
	C.pendingCast = { id = recipeID }
	local ok, err = pcall(C_TradeSkillUI.CraftRecipe, recipeID, n)
	if not ok then
		C.pendingCast = nil
		return nil, tostring(err)
	end
	GM.After(0.6, function()
		if not (C.pendingCast and C.pendingCast.id == recipeID) then return end
		C.pendingCast = nil
		if n > 1 then
			C.noBatch = true
			GM.Print(GM.CC("warn") .. "multi-cast not honored on this client — "
				.. "falling back to one cast per click|r")
		else
			GM.Print(GM.CC("warn") .. "craft didn't start — "
				.. "open the tradeskill window|r")
		end
	end)
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
	if not GoblinMindCrafting.recipes[recipeID] then return end
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

-- aggregated missing mats across the whole queue: itemID → qty short
function C.QueueMissing()
	local need = {}
	for id, qty in pairs(GoblinMindCrafting.queue) do
		for _, m in ipairs(C.Missing(id, qty)) do
			need[m.id] = (need[m.id] or 0) + m.qty
		end
	end
	return need
end

-- emit one plan for the whole queue: aggregated fetch/alt/buy mat
-- steps (buys priciest first) then a craft step per recipe
function C.QueueEmit()
	local steps = {}
	local ql = C.QueueList()
	-- aggregate the coverage split across every queued recipe
	local agg = {}
	for _, q in ipairs(ql) do
		for _, s in ipairs(C.MatSources(q.recipeID, q.qty)) do
			local a = agg[s.id] or { id = s.id, fetch = 0, alt = 0, buy = 0 }
			a.fetch = a.fetch + s.fetch
			a.alt = a.alt + s.alt
			a.buy = a.buy + s.buy
			agg[s.id] = a
		end
	end
	local ids = {}
	for id in pairs(agg) do ids[#ids + 1] = id end
	-- plan order: all fetches first (bank trip), then buys (AH trip)
	for _, id in ipairs(ids) do
		MatSteps(steps, { id = id, fetch = agg[id].fetch,
			alt = agg[id].alt, buy = 0 })
	end
	sort(ids, function(a, b)
		return ((C.MatPrice(a) or 0) * agg[a].buy)
			> ((C.MatPrice(b) or 0) * agg[b].buy)
	end)
	for _, id in ipairs(ids) do
		local s = agg[id]
		if s.buy > 0 then
			tinsert(steps, { kind = "buy", itemID = id, qty = s.buy,
				name = (GM.ItemName and GM.ItemName(id)) or ("item " .. id),
				unit = C.MatPrice(id) or 0, commodity = true,
				btag = "craft" })
		end
	end
	for _, q in ipairs(ql) do
		local nm = (GM.ItemName and GM.ItemName(q.itemID)) or q.name or "item"
		tinsert(steps, { kind = "note", verb = "CRAFT", itemID = q.itemID,
			qty = q.qty, recipeID = q.recipeID, name = nm,
			desc = q.prof or "tradeskill" })
	end
	if #steps == 0 then return nil, "queue is empty" end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "craft",
		source = "craft:queue" })
	return true
end
