local _, GM = ...

-- Part 5: post + cancel scans — the daily driver. Scans every bagged
-- item's book serially (ScanItem holds one pending query at a time),
-- derives a post decision per item from its group's auctioning ops,
-- and emits click-per-step rows into the shared plan queue. Cancel
-- scan flags owned auctions undercut by the current book.

GM.Auctioning = {}

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local A = GM.Auctioning

-- ============ serial book scans ============
-- GM.AH.ScanItem stores a single pending scan; a second call would
-- overwrite its callback. Jobs queue here and pump one at a time.

local scanQ = {}
local scanning = nil

local function Pump()
	if scanning then return end
	local job = tremove(scanQ, 1)
	if not job then return end
	scanning = job
	GM.AH.ScanItem(job.itemID, job.name, function(asks)
		if scanning ~= job then return end -- stale callback
		scanning = nil
		job.done(asks)
		Pump()
	end)
	-- no response within 5s: treat as an empty book and keep moving
	GM.After(5, function()
		if scanning == job then
			scanning = nil
			job.done({})
			Pump()
		end
	end)
end

local function ScanQueued(itemID, done)
	tinsert(scanQ, { itemID = itemID, name = GetInfo and GetInfo(itemID), done = done })
	Pump()
end

function A.Busy()
	return scanning ~= nil or #scanQ > 0
end

-- public entry into the serial queue — shopping/sniper scan one item
-- at a time too, and a second ScanItem would clobber the pending one
function A.QueueScan(itemID, done)
	ScanQueued(itemID, done)
end

-- ============ pure decision (harness-testable) ============

-- Lowest ask that isn't ours. Own auctions can't be undercut — posting
-- below your own listing is just losing money to yourself.
function A.Cheapest(asks)
	for _, a in ipairs(asks) do
		if not a.own then return a.unit end
	end
end

-- TSM post price: normal, pulled down to cheapest - undercut when the
-- market sits below normal. nil,reason when the market is under min
-- ("when below min: don't post").
function A.PriceFor(aOps, itemID, normal, cheapest)
	local minP = GM.Groups.EvalOp(aOps, "min", itemID)
	local maxP = GM.Groups.EvalOp(aOps, "max", itemID)
	local undercut = tonumber(GM.Groups.EvalOp(aOps, "undercut", itemID)) or 0
	if not normal then return nil, "no price" end
	if minP and normal < minP then normal = minP end
	if maxP and normal > maxP then normal = maxP end
	local unit = normal
	if cheapest and cheapest - undercut < normal then
		unit = cheapest - undercut
	end
	if minP and unit < minP then
		return nil, "market below min"
	end
	if maxP and unit > maxP then unit = maxP end
	return unit
end

-- ============ bag enumeration ============

local CNumSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
local CItemInfo = C_Container and C_Container.GetContainerItemInfo

-- { itemID -> { total, stacks = {n, ...}, bound } } over unlocked slots.
function A.BagItems()
	local out = {}
	if not CNumSlots then return out end
	for bag = 0, 5 do
		for slot = 1, CNumSlots(bag) do
			local id, n, locked, bound
			if CItemInfo then
				local info = CItemInfo(bag, slot)
				if info then
					id, n = info.itemID, info.stackCount or 1
					locked, bound = info.isLocked, info.isBound
				end
			else
				local _, cnt, lkd, _, _, _, link, _, _, _, isB = GetContainerItemInfo(bag, slot)
				id = link and tonumber(link:match("item:(%d+)"))
				n, locked, bound = cnt or 1, lkd, isB
			end
			if id and not locked then
				local e = out[id] or { total = 0, stacks = {}, bound = bound }
				e.total = e.total + n
				tinsert(e.stacks, n)
				e.bound = e.bound or bound
				out[id] = e
			end
		end
	end
	return out
end

-- ============ post scan ============

local function ShortName(id)
	local n = GetInfo and GetInfo(id)
	return n or ("item " .. id)
end

local function ItemLink(id)
	return select(2, GetInfo(id)) or nil
end

function A.PostScan()
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return
	end
	if A.Busy() then
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "scan already running|r")
		return
	end
	local bags = A.BagItems()
	local items, skipped = {}, {}
	for id, e in pairs(bags) do
		if e.bound then
			skipped[id] = "soulbound"
		elseif not (GM.ItemEntry(id) or GM.TSMMarket(id)) then
			skipped[id] = "no price"
		else
			tinsert(items, { id = id, qty = e.total, stacks = e.stacks })
		end
	end
	table.sort(items, function(a, b) return a.id < b.id end)
	if #items == 0 then
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "nothing postable — bags empty or no price data|r")
		return
	end

	-- shared per-item decision → post steps appended to `steps`
	local function ProcessItem(steps, it, cheapest)
		local aOps = GM.Groups.GetOps(it.id, "auctioning")
		local entry = GM.ItemEntry(it.id)
		local normal = GM.Groups.EvalOp(aOps, "normal", it.id)
			or (entry and entry.p) or GM.TSMMarket(it.id)
		local unit, why = A.PriceFor(aOps, it.id, normal, cheapest)
		if not unit then return nil, why or "?" end
		local isComm = GM.AH.IsCommodity(it.id)
		local cap = tonumber(aOps.postCap)
		local qty = (cap and cap > 0) and math.min(it.qty, cap) or it.qty
		local bidPct = tonumber(aOps.bidPercent) or 100
		local bid = math.floor(unit * bidPct / 100)
		local dur = tonumber(aOps.duration) or 2
		if isComm then
			tinsert(steps, { kind = "post", itemID = it.id, item = ItemLink(it.id),
				name = ShortName(it.id), qty = qty, unit = unit,
				bid = bid, duration = dur, cheapest = cheapest })
		else
			local stackSize = tonumber(aOps.stackSize)
			local left = qty
			for _, st in ipairs(it.stacks) do
				local n = math.min(st, left)
				while n > 0 do
					local c = (stackSize and stackSize > 0)
						and math.min(stackSize, n) or n
					tinsert(steps, { kind = "post", itemID = it.id,
						item = ItemLink(it.id), name = ShortName(it.id),
						qty = c, unit = unit, bid = bid, duration = dur,
						cheapest = cheapest })
					n = n - c
				end
				left = left - math.min(st, left)
				if left <= 0 then break end
			end
		end
		return true
	end

	local steps, postedItems = {}, 0
	-- a fresh shared book makes the whole scan synchronous
	if GM.AH.BookAge() < 300 then
		for _, it in ipairs(items) do
			local ok, why = ProcessItem(steps, it, GM.AH.BookCheapest(it.id))
			if ok then postedItems = postedItems + 1 else skipped[it.id] = why end
		end
		A.FinishPostScan(steps, skipped, postedItems)
		return
	end

	local remaining = #items
	GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("post scan — 0/%d items|r", #items))
	for pos, it in ipairs(items) do
		ScanQueued(it.id, function(asks)
			local ok, why = ProcessItem(steps, it, A.Cheapest(asks))
			if ok then postedItems = postedItems + 1 else skipped[it.id] = why end
			remaining = remaining - 1
			GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("post scan — %d/%d items|r",
				#items - remaining, #items))
			if remaining == 0 then
				A.FinishPostScan(steps, skipped, postedItems)
			end
		end)
	end
end

function A.FinishPostScan(steps, skipped, itemCount)
	if #steps == 0 then
		local reasons = {}
		for id, why in pairs(skipped) do
			tinsert(reasons, ShortName(id) .. " (" .. why .. ")")
		end
		GM.PlanQueue.ClearPlan()
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "post scan: nothing to post — "
			.. table.concat(reasons, ", ") .. "|r")
		return
	end
	local ev, deposit = 0, 0
	for _, s in ipairs(steps) do
		ev = ev + math.floor(s.unit * 0.95) * s.qty
		deposit = deposit + (GM.AH.DepositCost(s.itemID, s.qty) or 0)
	end
	GM.PlanQueue.SetScanPlan({
		mode = "postscan",
		steps = steps,
		spend = 0,
		ev = ev - deposit,
		deposit = deposit,
		itemCount = itemCount,
		skipCount = 0,
	})
	for id, why in pairs(skipped) do
		GM.Print(GM.CC("textDim") .. "skipped " .. ShortName(id) .. " — " .. why .. "|r")
	end
end

-- ============ cancel scan ============

function A.CancelScan()
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return
	end
	if A.Busy() then
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "scan already running|r")
		return
	end
	-- decide off a fresh owned-auction snapshot; fall back to whatever
	-- the cache holds if the event never lands
	GM.PlanQueue.ScanStatus(GM.CC("textDim") .. "refreshing owned auctions…|r")
	GM.Inventory.onOwned = function() A.CancelScanNow() end
	GM.Inventory.QueryOwned()
	GM.After(1.5, function()
		if GM.Inventory.onOwned then
			GM.Inventory.onOwned = nil
			A.CancelScanNow()
		end
	end)
end

function A.CancelScanNow()
	local owned = GM.Inventory.auctions or {}
	local byItem = {}
	for aid, a in pairs(owned) do
		local e = byItem[a.itemID] or { aids = {}, minUnit = math.huge }
		local unit = a.buyout and a.qty > 0 and (a.buyout / a.qty) or nil
		tinsert(e.aids, { aid = aid, qty = a.qty, unit = unit })
		if unit and unit < e.minUnit then e.minUnit = unit end
		byItem[a.itemID] = e
	end
	local items = {}
	for id in pairs(byItem) do tinsert(items, id) end
	table.sort(items)
	if #items == 0 then
		GM.PlanQueue.ScanStatus(GM.CC("textDim") .. "no owned auctions to check|r")
		return
	end

	local steps, undercutItems = {}, 0
	-- fresh shared book → synchronous pass, same as the post scan
	if GM.AH.BookAge() < 300 then
		for _, id in ipairs(items) do
			local e = byItem[id]
			local cheapest = GM.AH.BookCheapest(id)
			local aOps = GM.Groups.GetOps(id, "auctioning")
			for _, own in ipairs(e.aids) do
				if cheapest and own.unit and cheapest < own.unit and aOps.cancelUndercut then
					tinsert(steps, { kind = "cancel", auctionID = own.aid,
						itemID = id, item = ItemLink(id), name = ShortName(id),
						qty = own.qty, unit = own.unit })
				end
			end
			if cheapest and cheapest < e.minUnit then undercutItems = undercutItems + 1 end
		end
		A.FinishCancelScan(steps, undercutItems)
		return
	end
	local remaining = #items
	GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("cancel scan — 0/%d items|r", #items))
	for _, id in ipairs(items) do
		ScanQueued(id, function(asks)
			local e = byItem[id]
			local cheapest = A.Cheapest(asks)
			local aOps = GM.Groups.GetOps(id, "auctioning")
			for _, own in ipairs(e.aids) do
				local undercut = cheapest and own.unit and cheapest < own.unit
				if undercut and aOps.cancelUndercut then
					tinsert(steps, { kind = "cancel", auctionID = own.aid,
						itemID = id, item = ItemLink(id), name = ShortName(id),
						qty = own.qty, unit = own.unit })
				end
			end
			if cheapest and cheapest < e.minUnit then undercutItems = undercutItems + 1 end
			remaining = remaining - 1
			GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("cancel scan — %d/%d items|r",
				#items - remaining, #items))
			if remaining == 0 then
				A.FinishCancelScan(steps, undercutItems)
			end
		end)
	end
end

function A.FinishCancelScan(steps, undercutItems)
	if #steps == 0 then
		GM.PlanQueue.ClearPlan()
		GM.PlanQueue.ScanStatus(GM.CC("textDim") .. (undercutItems == 0
			and "cancel scan: no undercut auctions|r"
			or format("cancel scan: %d undercut item%s — set cancelUndercut=true in the group's auctioning ops|r",
				undercutItems, undercutItems == 1 and "" or "s")))
		return
	end
	GM.PlanQueue.SetScanPlan({
		mode = "cancelscan",
		steps = steps,
		spend = 0,
		ev = 0,
		itemCount = #steps,
	})
end
