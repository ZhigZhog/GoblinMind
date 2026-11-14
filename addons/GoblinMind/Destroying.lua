local _, GM = ...

-- Part 10a: the destroy evaluator. "Destroy value" = max(vendorsell,
-- TSM's `destroy` price source — disenchant/mill/prospect expected
-- value from LibTSMData, live while TSM is installed). Candidate
-- items are grouped things whose destroy value beats the market:
-- vendoring beats listing. v1 executes vendor sells at an open
-- merchant (UseContainerItem = right-click sell); disenchant gains
-- surface in the step text but the cast stays manual.

GM.Destroying = {}
local D = GM.Destroying

local function VendorSell(itemID)
	local info = C_Item and C_Item.GetItemInfo or GetItemInfo
	local _, _, _, _, _, _, _, _, _, _, sell = info and info(itemID)
	return sell and sell > 0 and sell or nil
end

-- expected value of destroying one unit, copper
function D.Value(itemID)
	local best = VendorSell(itemID)
	if TSMAPI_FOUR and TSMAPI_FOUR.CustomPrice then
		local ok, v = pcall(TSMAPI_FOUR.CustomPrice.GetValue, "destroy",
			"i:" .. itemID)
		if ok and type(v) == "number" and v > 0 and (not best or v > best) then
			best = v
		end
	end
	return best
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
		local dv = D.Value(id)
		local e = GM.ItemEntry(id)
		local mkt = e and e.p
		if dv and dv >= thresh and (not mkt or dv > mkt) then
			tinsert(rows, { id = id, qty = qty, dv = dv, mkt = mkt,
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
	C_Container.UseContainerItem(s.bag, s.slot)
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
