local _, GM = ...

-- Part 10a: the destroy evaluator. "Destroy value" = max(vendorsell,
-- disenchant EV — our own vanilla ilvl-bracket table priced from
-- dbmarket; TSM's per-item `destroy` source still wins when it's
-- installed and higher). Candidate
-- items are grouped things whose destroy value beats the market:
-- vendoring beats listing. v1 executes vendor sells at an open
-- merchant (UseContainerItem = right-click sell); disenchant gains
-- surface in the step text but the cast stays manual.

GM.Destroying = {}
local D = GM.Destroying

local UseItem = C_Container and C_Container.UseContainerItem
	or UseContainerItem

local function VendorSell(itemID)
	local info = C_Item and C_Item.GetItemInfo or GetItemInfo
	local _, _, _, _, _, _, _, _, _, _, sell = info and info(itemID)
	return sell and sell > 0 and sell or nil
end

-- ============ disenchant EV ============
-- Vanilla-era disenchant outcomes by ilvl bracket, inline like
-- Gathering's node tables. {maxIlvl, dust, dustLo, dustHi, essence,
-- essLo, essHi, greenShard, blueShard} — green shards only proc ~5%
-- of the time, blues always shard (their own column).
local DE = {
	{ 15,  10940, 1, 2, 10938, 1, 2, 10978, 10978 }, -- Strange/L.Magic/Sm.Glim
	{ 20,  10940, 2, 3, 10939, 1, 2, 10978, 10978 }, -- Strange/G.Magic/Sm.Glim
	{ 25,  11083, 1, 2, 10998, 1, 2, 10978, 10978 }, -- Soul/L.Astral/Sm.Glim
	{ 30,  11083, 2, 3, 11082, 1, 2, 11084, 11084 }, -- Soul/G.Astral/Lg.Glim
	{ 35,  11137, 1, 2, 11134, 1, 2, 11138, 11138 }, -- Vision/L.Mystic/Sm.Glow
	{ 40,  11137, 2, 3, 11135, 1, 2, 11138, 11139 }, -- Vision/G.Mystic
	{ 45,  11176, 1, 2, 11174, 1, 2, 11139, 11177 }, -- Dream/L.Nether
	{ 50,  11176, 2, 3, 11175, 1, 2, 11139, 11178 }, -- Dream/G.Nether
	{ 55,  16204, 1, 2, 16202, 1, 2, 14344, 14343 }, -- Illusion/L.Eternal
	{ 999, 16204, 2, 3, 16203, 1, 2, 14344, 14344 }, -- Illusion/G.Eternal
}
local NEXUS = 20725 -- epic ilvl ≥56 → 1-2 Nexus Crystals

-- the item's disenchant outcomes: { {id, lo, hi, pct}, ... } —
-- armor procs dust, weapons proc essence (75/20/5 splits), blues
-- always shard, epics ≥56 nexus. nil when the item can't disenchant
-- InventoryType indexes that DE as weapons (essence-heavy): 1H, bow/
-- gun, 2H, MH, OH, thrown, wand — shields/holdables proc like armor
local WEAPON_INV = { [13]=true, [15]=true, [17]=true, [21]=true, [22]=true, [25]=true, [26]=true }
local WEAPON_LOC = {
	INVTYPE_WEAPON=true, INVTYPE_2HWEAPON=true, INVTYPE_WEAPONMAINHAND=true,
	INVTYPE_WEAPONOFFHAND=true, INVTYPE_RANGED=true, INVTYPE_RANGEDRIGHT=true,
	INVTYPE_THROWN=true,
}
function D.DisenchantDrops(itemID)
	-- Forever quirk: GetItemInfo truncates to a name-only tuple while
	-- the item is uncached and GetItemInfoInstant is absent entirely —
	-- the dedicated q/ilvl/invType APIs resolve from static data, with
	-- GetItemInfo only as a last resort
	local qfn = C_Item and C_Item.GetItemQualityByID
	local lfn = C_Item and C_Item.GetDetailedItemLevelInfo
	local tfn = C_Item and C_Item.GetItemInventoryTypeByID
	local quality = qfn and qfn(itemID)
	local ilvl = lfn and lfn(itemID)
	local invType = tfn and tfn(itemID)
	local equipLoc, classID
	if not (quality and ilvl and invType) then
		local info = C_Item and C_Item.GetItemInfo or GetItemInfo
		local _, _, q, il, _, _, _, _, eq, _, _, cid = info and info(itemID)
		quality, ilvl, equipLoc, classID =
			quality or q, ilvl or il, eq, cid
	end
	if not quality or quality < 2 or quality > 4 then return end
	local isWeapon
	if invType and invType > 0 then
		isWeapon = WEAPON_INV[invType] == true
	elseif equipLoc and equipLoc ~= "" then
		isWeapon = WEAPON_LOC[equipLoc] == true
	elseif classID then
		isWeapon = classID == 2
	elseif _G.IsEquippableItem and IsEquippableItem(itemID) then
		isWeapon = false
	else
		return
	end
	local r = DE[1]
	for _, row in ipairs(DE) do
		if (ilvl or 0) <= row[1] then r = row break end
	end
	if quality == 4 then
		if (ilvl or 0) >= 56 then
			return { { id = NEXUS, lo = 1, hi = 2, pct = 100 } }
		end
		return { { id = r[9], lo = 1, hi = 1, pct = 100 } }
	end
	if quality == 3 then
		return { { id = r[9], lo = 1, hi = 1, pct = 100 } }
	end
	local dustP, essP = 75, 20
	if isWeapon then dustP, essP = essP, dustP end -- weapons proc essence
	return {
		{ id = r[2], lo = r[3], hi = r[4], pct = dustP },
		{ id = r[5], lo = r[6], hi = r[7], pct = essP },
		{ id = r[8], lo = 1, hi = 1, pct = 5 },
	}
end

-- expected disenchant value of one unit, copper — Σ pct × avgQty ×
-- dbmarket over DisenchantDrops. nil when no mat has a price:
-- honest-nil beats a fabricated floor
function D.DisenchantEV(itemID)
	local drops = D.DisenchantDrops(itemID)
	if not drops then return end
	local ev, any = 0, false
	for _, d in ipairs(drops) do
		local p = GM.Price and GM.Price("dbmarket", d.id)
		if p then
			ev = ev + (d.pct / 100) * ((d.lo + d.hi) / 2) * p
			any = true
		end
	end
	return any and ev or nil
end

-- vendor price vs alternative-processing EV, kept separate: the
-- merchant pays `vendor` per unit — the proc estimate only lands if
-- the operator disenchants/mills it themselves. Our bracket EV is the
-- base; TSM's per-item table wins when it's installed and higher
function D.Split(itemID)
	local vendor = VendorSell(itemID)
	local proc = D.DisenchantEV(itemID)
	if TSMAPI_FOUR and TSMAPI_FOUR.CustomPrice then
		local ok, v = pcall(TSMAPI_FOUR.CustomPrice.GetValue, "destroy",
			"i:" .. itemID)
		if ok and type(v) == "number" and v > 0 and (not proc or v > proc)
		then proc = v end
	end
	return vendor, proc
end

-- expected value of destroying one unit, copper
function D.Value(itemID)
	local vendor, proc = D.Split(itemID)
	if proc and (not vendor or proc > vendor) then return proc end
	return vendor
end

-- scan ALL bag stacks (not just grouped items — TSM's destroying
-- window surfaces everything disenchantable/vendorable). Threshold
-- comes from the item's own group's destroying op, Base Group for
-- ungrouped items. Rows carry full context for the results window
-- AND the plan emitter — sorted by gain over market, desc.
function D.Candidates()
	local totals = {}
	for _, s in ipairs(GM.Banking.BagSlots()) do
		if s.itemID then
			totals[s.itemID] = (totals[s.itemID] or 0) + s.count
		end
	end
	local rows = {}
	for id, qty in pairs(totals) do
		local group = GM.Groups.GroupForItem(id) or "Base Group"
		local ops = GM.Groups.GetOpsForPath(group, "destroying")
		local thresh = GM.Groups.EvalOp(ops, "threshold", id) or 0
		local vendor, proc = D.Split(id)
		local dv = (proc and (not vendor or proc > vendor)) and proc or vendor
		local e = GM.ItemEntry(id)
		local mkt = e and e.p
		if dv and dv >= thresh and (not mkt or dv > mkt) then
			tinsert(rows, { id = id, qty = qty, dv = dv, mkt = mkt,
				vendor = vendor, proc = proc,
				gain = mkt and (dv - mkt) or dv,
				group = group, name = GM.ItemName(id) })
		end
	end
	table.sort(rows, function(a, b) return (a.gain or 0) > (b.gain or 0) end)
	return rows
end

function D.Scan()
	local rows = D.Candidates()
	if #rows == 0 then
		GM.Print(GM.CC("textDim") .. "destroy: no candidates in bags|r")
		return
	end
	local steps = {}
	for _, r in ipairs(rows) do
		tinsert(steps, { kind = "destroy", itemID = r.id,
			qty = r.qty, name = r.name,
			desc = format("%s > %s (+%s)",
				GM.Money(r.dv), r.mkt and GM.Money(r.mkt) or "no market",
				GM.Money(r.gain)) })
	end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "destroying",
		itemCount = #steps })
	GM.PlanQueue.Show()
end

-- sell one stack of itemID at the open merchant — UseContainerItem on
-- a bag item while the merchant frame is up is the right-click sell.
-- Returns the stack size sold, false if the merchant isn't open, or
-- true when nothing is left (stack exhausted).
function D.SellOne(itemID)
	if not (MerchantFrame and MerchantFrame:IsShown()) then
		GM.Print(GM.CC("warn") .. "open a merchant to vendor|r")
		return false
	end
	local s = GM.Banking.FindStack(itemID)
	if not s then return true end -- nothing left → done
	UseItem(s.bag, s.slot)
	return s.count
end

local function DoDestroy(step)
	local sold = D.SellOne(step.itemID)
	if sold == false then return nil, "open a merchant to vendor" end
	if sold == true then return true end -- nothing left → done
	step.sold = (step.sold or 0) + sold
	return (step.sold or 0) >= step.qty
end

function D.Execute(step)
	if step.kind == "destroy" then return DoDestroy(step) end
end
