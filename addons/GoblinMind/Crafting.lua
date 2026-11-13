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

local function Scan()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetFilteredRecipeIDs) then return end
	local ok, ids = pcall(C_TradeSkillUI.GetFilteredRecipeIDs)
	if not ok or type(ids) ~= "table" then return end
	local prof
	if C_TradeSkillUI.GetBaseProfessionInfo then
		local pi = C_TradeSkillUI.GetBaseProfessionInfo()
		prof = pi and pi.professionName or pi and pi.profession
	end
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
					prof = prof or prev.prof,
					mats = mats,
					numMade = sc.quantityMin or prev.numMade or 1,
					cat = info.categoryID or prev.cat,
				}
				n = n + 1
			end
		end
	end
	if n > 0 then GM.Crafting.dirty = true end
end

function C.Init()
	GoblinMindCrafting = GoblinMindCrafting or {}
	GoblinMindCrafting.recipes = GoblinMindCrafting.recipes or {}
	GoblinMindCrafting.queue = GoblinMindCrafting.queue or {}
	local f = CreateFrame("Frame")
	for _, evt in ipairs({
		"TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
		"TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "PLAYER_LOGIN",
	}) do pcall(f.RegisterEvent, f, evt) end
	f:SetScript("OnEvent", function(_, e)
		if e == "TRADE_SKILL_CLOSE" then return end
		-- data source changes mid-session; rescan whenever the list
		-- updates or a profession opens
		Scan()
	end)
end

-- ============ cost model ============

-- per-unit mat price: market first, vendor-sell as the floor (matches
-- TSM's default matPrice fallback chain minus sources we lack)
function C.MatPrice(itemID)
	return GM.Price("dbmarket", itemID)
		or (GetItemInfo and select(11, GetItemInfo(itemID)))
end

-- cost to craft ONE output item (÷ numMade); nil if unknown recipe
function C.MatCost(recipeID)
	local r = GoblinMindCrafting and GoblinMindCrafting.recipes
		and GoblinMindCrafting.recipes[recipeID]
	if not r or not r.mats then return nil end
	local total = 0
	for _, m in ipairs(r.mats) do
		local p = C.MatPrice(m.id)
		if not p then return nil end -- unknown mat price → honest nil
		total = total + p * m.qty
	end
	return floor(total / (r.numMade or 1))
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
	local cost = C.MatCost(recipeID)
	local p = GM.Price("dbmarket", r.itemID)
	if cost and p then return p - cost, p, cost end
end

-- inventory a crafter can actually use: bags + bank (mail/gbank/AH
-- stock isn't reachable from the profession window)
function C.Owned(itemID)
	local c = GM.Inventory.Count(itemID)
	return (c.bags or 0) + (c.bank or 0)
end

-- mats still needed to craft qty× (inventory-aware)
function C.Missing(recipeID, qty)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return {} end
	local out = {}
	for _, m in ipairs(r.mats) do
		local need = m.qty * qty - C.Owned(m.id)
		if need > 0 then tinsert(out, { id = m.id, qty = need }) end
	end
	return out
end

-- ============ queue ============

-- Emit a plan: buy missing mats, then a manual craft note. Follows the
-- plan-queue step shape (kind/qty/unit/itemID).
function C.Queue(recipeID, qty)
	local r = GoblinMindCrafting.recipes[recipeID]
	if not r then return end
	qty = max(1, qty or 1)
	local steps = {}
	for _, m in ipairs(C.Missing(recipeID, qty)) do
		local unit = C.MatPrice(m.id)
		tinsert(steps, { kind = "buy", itemID = m.id, qty = m.qty,
			unit = unit or 0, commodity = true, btag = "craft" })
	end
	tinsert(steps, { kind = "note", itemID = r.itemID, qty = qty,
		text = format("craft %d× %s (%s)", qty,
			(GM.ItemName and GM.ItemName(r.itemID)) or r.name or "item",
			r.prof or "tradeskill") })
	GM.PlanQueue.SetScanPlan({ steps = steps, itemID = r.itemID,
		mode = "craft", source = "craft:" .. recipeID })
end

-- list for the market window CRAFT mode
function C.List()
	local out = {}
	for id, r in pairs(GoblinMindCrafting and GoblinMindCrafting.recipes or {}) do
		local profit, p, cost = C.Profit(id)
		local craftable = C.Craftable(id)
		-- suggested queue qty: restock ops target a stock level; otherwise
		-- profitable recipes queue what inventory covers (floor 1 — mats
		-- can be bought, the queue emits the buy steps)
		local suggest = 0
		if profit and profit > 0 then
			local ops = GM.Groups.GetOps and GM.Groups.GetOps(r.itemID, "crafting") or {}
			if ops.restock and (ops.restockQty or 0) > 0 then
				suggest = max(0, ops.restockQty - C.Owned(r.itemID))
			else
				suggest = max(craftable, 1)
			end
		end
		tinsert(out, {
			recipeID = id, itemID = r.itemID, name = r.name,
			prof = r.prof, mats = r.mats,
			cost = cost, price = p, profit = profit,
			craftable = craftable, suggest = suggest,
		})
	end
	sort(out, function(a, b)
		if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
		if a.profit and b.profit and a.profit ~= b.profit then return a.profit > b.profit end
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

-- ============ persistent queue ============
-- GoblinMindCrafting.queue[recipeID] = qty — survives reload, drives
-- the queue manager window and the aggregated emit plan.

function C.QueueSet(recipeID, qty)
	if not GoblinMindCrafting.recipes[recipeID] then return end
	if qty and qty > 0 then
		GoblinMindCrafting.queue[recipeID] = floor(qty)
	else
		GoblinMindCrafting.queue[recipeID] = nil
	end
end

function C.QueueAdd(recipeID, delta)
	local cur = GoblinMindCrafting.queue[recipeID] or 0
	C.QueueSet(recipeID, cur + (delta or 0))
end

function C.QueueClear()
	wipe(GoblinMindCrafting.queue)
end

function C.QueueCount()
	local n = 0
	for _ in pairs(GoblinMindCrafting.queue) do n = n + 1 end
	return n
end

-- queued recipes with the same computed fields as List()
function C.QueueList()
	local out = {}
	for id, qty in pairs(GoblinMindCrafting.queue) do
		local r = GoblinMindCrafting.recipes[id]
		if r then
			local profit, p, cost = C.Profit(id)
			tinsert(out, {
				recipeID = id, qty = qty, itemID = r.itemID,
				name = r.name, prof = r.prof, mats = r.mats,
				cost = cost, price = p, profit = profit,
				craftable = C.Craftable(id),
			})
		end
	end
	sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
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

-- emit one plan for the whole queue: aggregated mat buys (priciest
-- first) then a manual-craft note per recipe
function C.QueueEmit()
	local steps, need = {}, C.QueueMissing()
	local ids = {}
	for id in pairs(need) do ids[#ids + 1] = id end
	sort(ids, function(a, b)
		return ((C.MatPrice(a) or 0) * need[a]) > ((C.MatPrice(b) or 0) * need[b])
	end)
	for _, id in ipairs(ids) do
		tinsert(steps, { kind = "buy", itemID = id, qty = need[id],
			unit = C.MatPrice(id) or 0, commodity = true, btag = "craft" })
	end
	for _, q in ipairs(C.QueueList()) do
		tinsert(steps, { kind = "note", itemID = q.itemID, qty = q.qty,
			text = format("craft %d× %s (%s)", q.qty,
				(GM.ItemName and GM.ItemName(q.itemID)) or q.name or "item",
				q.prof or "tradeskill") })
	end
	if #steps == 0 then return nil, "queue is empty" end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "craft",
		source = "craft:queue" })
	return true
end
