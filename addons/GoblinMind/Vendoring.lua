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
-- the plan executor's vendor gate checks this the same way the
-- AH gate checks GM.AH.open
V.MerchantOpen = MerchantOpen

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
	-- a captured index can drift if the merchant list reloaded since
	-- the scan — verify the slot still holds the item before spending
	if idx and step.itemID and MerchantItemID(idx) ~= step.itemID then
		idx = nil
	end
	if not idx and step.itemID then
		-- plan-emitted steps carry no slot — find it live
		for i = 1, GetMerchantNumItems and GetMerchantNumItems() or 0 do
			if MerchantItemID(i) == step.itemID then
				idx = i break
			end
		end
	end
	if not idx then return "bounce", "vendor doesn't stock it" end
	-- MerchantBuy chunks past the stack cap — a raw call with
	-- step.qty > max fails the whole purchase ("Internal Bag Error")
	GM.MerchantBuy(idx, step.qty)
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

-- ==== universal merchant movement detection ====
-- Every vendor sale lands in the buyback list no matter who made it
-- — our vendoring UI, destroy plans, or a bare Blizzard right-click.
-- Diffing the slots is the single detector for sells: new qty = a
-- sale (vendor leg), vanished qty = a buyback (vendorbuy). Buys get
-- a hooksecurefunc on the global so manual purchases journal too;
-- GM.MerchantBuy's own calls set _hookSkip so they don't double.
local bbSnap = {}

local function ReadBuyback()
	local out = {}
	local n = GetNumBuybackItems and GetNumBuybackItems() or 0
	for i = 1, n do
		local link = GetBuybackItemLink and GetBuybackItemLink(i)
		local _, _, price, qty = GetBuybackItemInfo
			and GetBuybackItemInfo(i)
		local id = GM.LinkID(link)
		if id then
			out[i] = { id = id, qty = qty or 1, price = price or 0 }
		end
	end
	return out
end

local function LastUnit(snap, id)
	for _, e in pairs(snap) do
		if e.id == id and e.qty > 0 and e.price > 0 then
			return e.price / e.qty
		end
	end
end

-- the price authority — ONE place that knows which field answers
-- "what did this cost" per vendor movement. Forever drops merchant
-- and buyback price fields on some items, so every buy-side value
-- is provisional: the real basis is the money outflow ExpectBuy
-- pairs. Sells have no outflow — the sellPrice IS the truth.
V.Price = {
	-- sell: the item's own sellPrice — a merchant pays exactly that
	sell = function(id) return GM.VendorSellPrice(id) end,
	-- buy: the merchant slot's price per purchase unit
	buy = function(idx)
		local ok, price, q = pcall(function()
			local _, _, p, qq = GetMerchantItemInfo(idx)
			return p, qq end)
		if ok and price and price > 0 then return price / (q or 1) end
	end,
	-- buyback: the row's own price, else the sellPrice it paid
	buyback = function(e)
		if e.price and e.price > 0 then return e.price / e.qty end
		return V.Price.sell(e.id)
	end,
}

local function BuybackDiff()
	local now = ReadBuyback()
	local before, after = {}, {}
	for _, e in pairs(bbSnap) do
		before[e.id] = (before[e.id] or 0) + e.qty
	end
	for _, e in pairs(now) do
		after[e.id] = (after[e.id] or 0) + e.qty
	end
	-- buybacks the BuybackItem hook already journaled: the diff must
	-- not count them again. Entries expire — a failed buyback leaves
	-- the stamp around ~5s then it's ignored
	local function Vanished(id, q)
		local j = V._bbJourn and V._bbJourn[id]
		if j and time() - j.t > 5 then
			V._bbJourn[id] = nil j = nil
		end
		if j then
			local c = math.min(j.qty, q)
			j.qty = j.qty - c
			if j.qty <= 0 then V._bbJourn[id] = nil end
			q = q - c
		end
		if q <= 0 then return end
		-- the money outflow is the real basis; the row/sell price
		-- is only the fallback when no delta ever arrives
		GM.Ledger.ExpectBuy(id, q,
			LastUnit(bbSnap, id) or V.Price.sell(id))
	end
	for id, q in pairs(after) do
		local d = q - (before[id] or 0)
		if d > 0 then
			GM.Ledger.Record("vendor", { itemID = id, qty = d,
				unit = LastUnit(now, id) or V.Price.sell(id) })
		elseif d < 0 then
			Vanished(id, -d)
		end
	end
	for id, q in pairs(before) do
		if not after[id] then Vanished(id, q) end
	end
	bbSnap = now
end

local bbf = CreateFrame("Frame")
pcall(bbf.RegisterEvent, bbf, "MERCHANT_SHOW")
pcall(bbf.RegisterEvent, bbf, "MERCHANT_UPDATE")
pcall(bbf.RegisterEvent, bbf, "BUYBACK_UPDATE")
bbf:SetScript("OnEvent", function(_, e)
	if e == "MERCHANT_SHOW" then
		bbSnap = ReadBuyback()
	else
		BuybackDiff()
	end
end)

if hooksecurefunc then
	hooksecurefunc("BuyMerchantItem", function(idx, count)
		if V._hookSkip then return end
		-- inside a pcall'd BuyMerchantItem the post-hook's errors
		-- would mark the purchase failed — journal defensively
		pcall(function()
			local link = GetMerchantItemLink
				and GetMerchantItemLink(idx)
			local id = link and GM.LinkID(link)
			if not id then return end
			-- always defer to the money outflow for the real cost;
			-- the merchant price is only the no-delta fallback
			GM.Ledger.ExpectBuy(id, count or 1, V.Price.buy(idx))
		end)
	end)
	-- buyback purchases aren't BuyMerchantItem — BuybackItem is its
	-- own call. The slot's already cleared post-hook, so read the
	-- item out of OUR snapshot and stamp the qty journaled — the
	-- diff subtracts the stamp instead of double-counting, and a
	-- failed buyback just lets the stamp expire
	if type(BuybackItem) == "function" then
		hooksecurefunc("BuybackItem", function(slot)
			if V._hookSkip then return end
			local e = bbSnap and bbSnap[slot]
			if not e then return end
			pcall(function()
				V._bbJourn = V._bbJourn or {}
				local j = V._bbJourn[e.id]
				if j then j.qty = j.qty + e.qty j.t = time()
				else V._bbJourn[e.id] = { qty = e.qty, t = time() } end
				GM.Ledger.ExpectBuy(e.id, e.qty, V.Price.buyback(e))
			end)
		end)
	end
	-- trainer services (learned schematics/recipes) are their own
	-- purchase call — no merchant slot, usually no item. A service
	-- that resolves to an item link journals as a vendorbuy (group
	-- routing still works); a learned spell journals as a "trainer"
	-- expense by name. Cost basis still rides the money outflow.
	if type(BuyTrainerService) == "function" then
		hooksecurefunc("BuyTrainerService", function(idx)
			if V._hookSkip then return end
			pcall(function()
				local link = GetTrainerServiceItemLink
					and GetTrainerServiceItemLink(idx)
				local id = link and GM.LinkID(link)
				local unit
				if GetTrainerServiceCost then
					local ok, c = pcall(GetTrainerServiceCost, idx)
					if ok and type(c) == "number" and c > 0 then
						unit = c
					end
				end
				if id then
					GM.Ledger.ExpectBuy(id, 1, unit)
					return
				end
				local nm
				if GetTrainerServiceInfo then
					local ok, n = pcall(function()
						return (GetTrainerServiceInfo(idx)) end)
					if ok and type(n) == "string" and n ~= "" then
						nm = n
					end
				end
				GM.Ledger.ExpectBuy(nil, 1, unit,
					{ kind = "trainer", nm = nm or "service" })
			end)
		end)
	end
end
