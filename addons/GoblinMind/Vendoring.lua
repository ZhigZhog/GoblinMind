local _, GM = ...

-- Part 10b: vendor helpers at merchants. Buy: merchant items priced
-- below market (vendor flips) → one BuyMerchantItem per click. Sell:
-- bag items whose group op says autoSell (poor-quality junk by
-- default) → one UseContainerItem sell per click. Both stay
-- click-per-step; `autoBuy`/`autoSell` are flags on the plan, never
-- unattended actions.

GM.Vendoring = {}
local V = GM.Vendoring

local UseItem = C_Container and C_Container.UseContainerItem
	or UseContainerItem

local function MerchantOpen()
	return MerchantFrame and MerchantFrame:IsShown()
end

local function MerchantItemID(index)
	local link = GetMerchantItemLink and GetMerchantItemLink(index)
	return GM.LinkID(link)
end

-- scan merchant stock: items cheaper than our market value
function V.BuyScan()
	if not MerchantOpen() then
		return nil, "open a merchant first"
	end
	local steps = {}
	local n = GetMerchantNumItems and GetMerchantNumItems() or 0
	for i = 1, n do
		local id = MerchantItemID(i)
		local e = id and GM.ItemEntry(id)
		if id and e and e.p then
			-- Forever: C_MerchantFrame.GetItemInfo → {price, stackCount,
			-- numAvailable, hasExtendedCost}; price = full-stack cost
			local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo
				and C_MerchantFrame.GetItemInfo(i)
			local unit = info and info.stackCount and info.stackCount > 0
				and info.price and info.price / info.stackCount
			if unit and not info.hasExtendedCost
				and info.numAvailable ~= 0 and info.numAvailable ~= -1
				and unit < e.p * 0.85 then
				local qty = info.stackCount
				-- sub-copper units (arrows etc.) floor to 0c — show
				-- stack-vs-stack instead: honest at every price level
				tinsert(steps, { kind = "vendbuy", itemID = id,
					qty = qty or 1, index = i, cost = info.price,
					name = GM.ItemName(id),
					desc = format("%s for %d vs %s market",
						GM.Money(info.price), qty,
						GM.Money(e.p * (qty or 1))) })
			end
		end
	end
	return steps
end

-- user-managed sell blacklist: /goblin vendor blacklist <item>, or
-- right-click a row on the vendor window's SELL tab
function V.IsBlacklisted(itemID)
	local bl = GoblinMindSettings and GoblinMindSettings.vendorBlacklist
	return bl and bl[itemID] or false
end

function V.BlacklistToggle(itemID)
	GoblinMindSettings.vendorBlacklist =
		GoblinMindSettings.vendorBlacklist or {}
	local bl = GoblinMindSettings.vendorBlacklist
	bl[itemID] = not bl[itemID] or nil
	GM.Print((bl[itemID] and "vendor blacklist: +" or "vendor blacklist: -")
		.. GM.ItemName(itemID))
	return bl[itemID]
end

-- scan bags: poor-quality items in groups flagged autoSell
function V.SellScan()
	local steps = {}
	for _, s in ipairs(GM.Banking.BagSlots()) do
		if s.itemID then
			local g = GM.Groups.GroupForItem(s.itemID)
			if g then
				local ops = GM.Groups.GetOpsForPath(g, "vendoring")
				if ops.autoSell then
					local info = C_Item and C_Item.GetItemInfo or GetItemInfo
					local _, _, quality, _, _, _, _, _, _, _, sell =
						info and info(s.itemID)
					if quality == 0 and sell and sell > 0
						and not V.IsBlacklisted(s.itemID) then
						tinsert(steps, { kind = "vendsell",
							itemID = s.itemID, qty = s.count,
							name = GM.ItemName(s.itemID),
							desc = "junk → vendor " .. GM.Money(sell * s.count) })
					end
				end
			end
		end
	end
	return steps
end

function V.Scan()
	if not MerchantOpen() then
		GM.Print(GM.CC("warn") .. "vendoring needs a merchant open|r")
		return
	end
	local steps = V.SellScan()
	local buys = V.BuyScan() or {}
	for _, s in ipairs(buys) do steps[#steps + 1] = s end
	if #steps == 0 then
		GM.Print(GM.CC("textDim") .. "vendoring: nothing flagged|r")
		return
	end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "vendoring",
		itemCount = #steps })
	GM.PlanQueue.Show()
end

local function DoBuy(step)
	if not MerchantOpen() then return "bounce", "merchant closed" end
	local idx = step.index
	if not idx and step.itemID then
		-- plan-emitted steps carry no slot — find it live
		for i = 1, GetMerchantNumItems and GetMerchantNumItems() or 0 do
			local link = GetMerchantItemLink and GetMerchantItemLink(i)
			if GM.LinkID(link) == step.itemID then
				idx = i break
			end
		end
	end
	if not idx then return "bounce", "vendor doesn't stock it" end
	BuyMerchantItem(idx, step.qty)
	return true -- one purchase per click
end

local function DoSell(step)
	if not MerchantOpen() then
		return "bounce", "merchant closed"
	end
	local s = GM.Banking.FindStack(step.itemID)
	if not s then return true end
	UseItem(s.bag, s.slot)
	step.sold = (step.sold or 0) + s.count
	return (step.sold or 0) >= step.qty
end

function V.Execute(step)
	if step.kind == "vendbuy" then return DoBuy(step) end
	if step.kind == "vendsell" then return DoSell(step) end
end
