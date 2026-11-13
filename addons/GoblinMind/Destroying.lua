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
-- ungrouped items.
function D.Scan()
	local steps = {}
	local seen = {}
	for _, s in ipairs(GM.Banking.BagSlots()) do
		local id = s.itemID
		if id and not seen[id] then
			seen[id] = true
			local group = GM.Groups.GroupForItem(id) or "Base Group"
			local ops = GM.Groups.GetOpsForPath(group, "destroying")
			local thresh = GM.Groups.EvalOp(ops, "threshold", id) or 0
			local dv = D.Value(id)
			local e = GM.ItemEntry(id)
			local mkt = e and e.p
			if dv and dv >= thresh and (not mkt or dv > mkt) then
				local gain = mkt and (dv - mkt) or dv
				tinsert(steps, { kind = "destroy", itemID = id,
					qty = s.count,
					name = GM.ItemName(id),
					desc = format("%s > %s (+%s)",
						GM.Money(dv), mkt and GM.Money(mkt) or "no market",
						GM.Money(gain)) })
			end
		end
	end
	table.sort(steps, function(a, b)
		local av = (D.Value(a.itemID) or 0) - ((GM.ItemEntry(a.itemID) or {}).p or 0)
		local bv = (D.Value(b.itemID) or 0) - ((GM.ItemEntry(b.itemID) or {}).p or 0)
		return av > bv
	end)
	if #steps == 0 then
		GM.Print(GM.CC("textDim") .. "destroy: no candidates in bags|r")
		return
	end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "destroying",
		itemCount = #steps })
	GM.PlanQueue.Show()
end

-- sell one stack at the open merchant — UseContainerItem on a bag
-- item while the merchant frame is up is the right-click sell
local function DoDestroy(step)
	if not (MerchantFrame and MerchantFrame:IsShown()) then
		return nil, "open a merchant to vendor"
	end
	local s = GM.Banking.FindStack(step.itemID)
	if not s then return true end -- nothing left → done
	C_Container.UseContainerItem(s.bag, s.slot)
	step.sold = (step.sold or 0) + s.count
	return (step.sold or 0) >= step.qty
end

function D.Execute(step)
	if step.kind == "destroy" then return DoDestroy(step) end
end
