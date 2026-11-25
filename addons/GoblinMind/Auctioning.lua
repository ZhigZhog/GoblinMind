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
	-- SendSearchQuery can throw synchronously on Forever — pcall so the
	-- watchdog below still fires and the queue doesn't jam on scanning
	local ok, err = pcall(GM.AH.ScanItem, job.itemID, job.name,
		function(asks)
			if scanning ~= job then return end -- stale callback
			scanning = nil
			-- intel marks before the consumer reads rows — bait/step
			-- flags feed A.Cheapest's drag-lot skip. Suffixed scans
			-- stay out: marks are itemID-wide and a variant ladder
			-- would poison them
			if GM.Intel and GM.Intel.AnalyzeItem
				and not (job.key and job.key.itemSuffix
					and job.key.itemSuffix ~= 0) then
				pcall(GM.Intel.AnalyzeItem, job.itemID, asks)
			end
			local ok, err = pcall(job.done, asks)
			if not ok then
				GM.Print(GM.CC("warn") .. "scan callback failed: "
					.. tostring(err) .. "|r")
			end
			Pump()
		end, job.key)
	-- no response (or a thrown call) within 5s: empty book, keep moving
	GM.After(5, function()
		if scanning == job then
			scanning = nil
			job.done({})
			Pump()
		end
	end)
	if not ok then
		GM.Print(GM.CC("warn") .. "scan query failed: "
			.. tostring(err) .. "|r")
	end
end

local function ScanQueued(itemID, done, key)
	tinsert(scanQ, { itemID = itemID, key = key,
		name = GetInfo and GetInfo(itemID), done = done })
	Pump()
end

function A.Busy()
	return scanning ~= nil or #scanQ > 0
end

-- abort the serial queue — pending jobs never pump, the in-flight
-- job's `scanning ~= job` guard drops its callback. User clicks
-- (result drill-down, item re-solve) outrank a running group scan:
-- without this the interrupted queue kept pumping, stomped the
-- click's onScanDone slot, and its finish landed OVER the new plan.
function A.StopScan()
	scanQ = {}
	scanning = nil
end

-- public entry into the serial queue — shopping/sniper scan one item
-- at a time too, and a second ScanItem would clobber the pending one
function A.QueueScan(itemID, done, key)
	ScanQueued(itemID, done, key)
end

-- ============ pure decision (harness-testable) ============

-- Lowest ask that isn't ours and isn't bait-flagged. Own auctions
-- can't be undercut — posting below your own listing is just losing
-- money to yourself — and a drag lot posted under the real market
-- exists to pull our reference down with it, not to be undercut.
-- Second return: the first flagged bait lot's price — PriceFor needs
-- it to keep normal-priced posts out of the bait→wall trap gap.
function A.Cheapest(asks)
	local bait
	for _, a in ipairs(asks) do
		if not a.own then
			if a.bait then
				bait = bait or a.unit
			else
				return a.unit, bait
			end
		end
	end
	return nil, bait
end

-- TSM post price: normal, pulled down to cheapest - undercut when the
-- market sits below normal. nil,reason when the market is under min
-- ("when below min: don't post").
function A.PriceFor(aOps, itemID, normal, cheapest, baitUnit)
	local minP = GM.Groups.EvalOp(aOps, "min", itemID)
	local maxP = GM.Groups.EvalOp(aOps, "max", itemID)
	local undercut = tonumber(GM.Groups.EvalOp(aOps, "undercut", itemID)) or 0
	if not normal then return nil, "no price" end
	if minP and normal < minP then normal = minP end
	if maxP and normal > maxP then normal = maxP end
	local unit = normal
	-- undercut the first honest ask — with a drag lot live that's
	-- EVERYTHING below the wall: gap posts and below-bait posts are
	-- both dominated positions that feed the trap
	if cheapest and (cheapest - undercut < normal
		or (baitUnit and normal < cheapest)) then
		unit = cheapest - undercut
	elseif baitUnit and not cheapest and normal < baitUnit then
		-- all-bait book: the drag itself is the only reference —
		-- take its queue slot by the op amount, no deeper
		unit = baitUnit - undercut
	end
	if minP and unit < minP then
		return nil, "market below min"
	end
	if maxP and unit > maxP then unit = maxP end
	return unit
end

-- ============ bag enumeration ============

-- { itemID -> { total, stacks = {n, ...}, bound } } over unlocked slots.
function A.BagItems()
	local out = {}
	GM.EachBagSlot(GM.CarriedContainerList(),
		function(_, _, id, n, locked, bound)
			if not locked then
				local e = out[id] or { total = 0, stacks = {}, bound = bound }
				e.total = e.total + n
				tinsert(e.stacks, n)
				e.bound = e.bound or bound
				out[id] = e
			end
		end)
	return out
end

-- group scope for scans: the AH window's GROUPS selection is a set
-- of paths; membership covers the whole subtree (picking a parent
-- scans its children). Base Group = the ungrouped item set.
-- nil = nothing selected → scans stay unscoped (all items).
function A.ScanGroupIds()
	local sel = GM.db and GM.db.scanGroups
	if not sel or not next(sel) then return end
	local out, paths = {}, {}
	for p in pairs(sel) do paths[#paths + 1] = p end
	for path, g in pairs(GM.Groups.db.groups) do
		for _, s in ipairs(paths) do
			if path == s or path:sub(1, #s + 1) == s .. "/" then
				for id in pairs(g.items) do out[id] = true end
				break
			end
		end
	end
	if sel["Base Group"] then
		for _, id in ipairs(GM.Groups.UngroupedIds()) do
			out[id] = true
		end
	end
	return out
end

-- per-item post preview without running a scan — the same decision
-- PostScan's ProcessItem makes, driven off the shared book when it's
-- fresh (<300s). Returns unit or nil,reason + the inputs for display.
function A.PreviewPost(id)
	local aOps = GM.Groups.GetOps(id, "auctioning")
	if not GM.Price("dbmarket", id) then return nil, "no price" end
	local normal = GM.Groups.EvalOp(aOps, "normal", id)
		or GM.Price("dbmarket", id)
	-- cheapest non-ours through the resolver: live book when it's the
	-- freshest source, mesh beacon when newer, emitted row otherwise —
	-- never a stale scan over a fresher feed
	local e0 = GM.ItemEntry(id)
	local cheapest = e0 and (e0.mbx ~= math.huge and e0.mbx or e0.mb)
	local unit, why = A.PriceFor(aOps, id, normal, cheapest)
	if not unit then return nil, why or "?", normal, cheapest end
	-- vendor floor: net after 5% cut + deposit must beat vendoring
	local v = GetInfo and select(11, GetInfo(id))
	if v and v > 0 then
		local dep = GM.AH.DepositCost(id, 1) or 0
		if floor(unit * 0.95) - dep < v then
			return nil, "vendor beats", normal, cheapest
		end
	end
	return unit, nil, normal, cheapest
end

-- ============ post scan ============

local ShortName = GM.ItemNameOr
local ItemLink = GM.ItemLink

-- `only` (optional): set of itemIDs to include — the bag-table page
-- uses it to post a checked subset instead of every bag item
function A.PostScan(only)
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return
	end
	if A.Busy() then
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "scan already running|r")
		return
	end
	-- the plan + scan progress live in the main window — surface it
	-- when the scan was launched from the auctions window or a slash
	GM.PlanQueue.Show()
	GM.PlanQueue.ScanStart("postscan")
	-- no explicit subset (bag-table checkboxes) → the AH window's
	-- GROUPS selection scopes the scan; nil = everything
	only = only or A.ScanGroupIds()
	local bags = A.BagItems()
	local items, skipped = {}, {}
	for id, e in pairs(bags) do
		if only and not only[id] then
			-- unchecked on the bag table — not a skip, just excluded
		elseif e.bound then
			skipped[id] = "soulbound"
		elseif GM.Groups and GM.Groups.IsProtected(id) then
			-- protected groups (shipped vendor supplies, user-flagged)
			-- are ignored, not merely confirmed — a post scan should
			-- never plan things that shouldn't be on the AH
			skipped[id] = "protected"
		elseif not GM.Price("dbmarket", id) then
			skipped[id] = "no price"
		else
			tinsert(items, { id = id, qty = e.total, stacks = e.stacks })
		end
	end
	-- same order the bag table shows (name) — the plan should read
	-- like the list the scan was launched from
	table.sort(items, function(a, b)
		return (GM.ItemName(a.id) or "") < (GM.ItemName(b.id) or "")
	end)
	if #items == 0 then
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "nothing to post — bags are empty or prices are missing|r")
		return
	end

	-- vendor floor: a listing whose expected net (5% AH cut, minus the
	-- deposit) loses to the merchant price must never be posted — the
	-- plan carries a vendoring step so the better move is one click.
	local function VendorUnit(id)
		local v = GetInfo and select(11, GetInfo(id))
		return (v and v > 0) and v or nil
	end

	-- shared per-item decision → post steps appended to `steps`
	local function ProcessItem(steps, it, cheapest, baitUnit)
		local aOps = GM.Groups.GetOps(it.id, "auctioning")
		local normal = GM.Groups.EvalOp(aOps, "normal", it.id)
			or GM.Price("dbmarket", it.id)
		local unit, why = A.PriceFor(aOps, it.id, normal, cheapest, baitUnit)
		if not unit then return nil, why or "?" end
		local isComm = GM.AH.IsCommodity(it.id)
		local cap = tonumber(aOps.postCap)
		local qty = (cap and cap > 0) and math.min(it.qty, cap) or it.qty
		local vUnit = VendorUnit(it.id)
		if vUnit then
			local dep = GM.AH.DepositCost(it.id, qty) or 0
			local net = math.floor(unit * 0.95) * qty - dep
			if net < vUnit * qty then
				tinsert(steps, { kind = "vendsell", itemID = it.id,
					item = ItemLink(it.id), name = ShortName(it.id), qty = qty,
					desc = format("vendor %s beats post net %s",
						GM.Money(vUnit * qty), GM.Money(net)) })
				return true
			end
		end
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
	-- a live shared book makes the whole scan synchronous
	if GM.AH.BookLive() then
		for _, it in ipairs(items) do
			local ok, why = ProcessItem(steps, it, GM.AH.BookCheapest(it.id))
			if ok then postedItems = postedItems + 1 else skipped[it.id] = why end
		end
		A.FinishPostScan(steps, skipped, postedItems)
		return
	end

	local remaining = #items
	GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("post scan — checking 0/%d bag items|r", #items))
	for pos, it in ipairs(items) do
		ScanQueued(it.id, function(asks)
			local ok, why = ProcessItem(steps, it, A.Cheapest(asks))
			if ok then postedItems = postedItems + 1 else skipped[it.id] = why end
			remaining = remaining - 1
			GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("post scan — checking %d/%d bag items|r",
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
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "post scan done — nothing to post: "
			.. table.concat(reasons, ", ") .. "|r")
		return
	end
	-- skipped items stay visible at the end of the plan — a checked row
	-- that produced no posts shouldn't vanish silently into chat spam
	local skipN = 0
	for id, why in pairs(skipped) do
		skipN = skipN + 1
		tinsert(steps, { kind = "skip", itemID = id, name = ShortName(id),
			qty = 0, desc = "skipped — " .. why })
	end
	local ev, deposit, vendN = 0, 0, 0
	for _, s in ipairs(steps) do
		if s.kind == "post" then
			ev = ev + math.floor(s.unit * 0.95) * s.qty
			deposit = deposit + (GM.AH.DepositCost(s.itemID, s.qty) or 0)
		elseif s.kind == "vendsell" then
			vendN = vendN + 1
		end
	end
	if vendN > 0 then
		GM.Print(GM.CC("warn") .. format(
			"%d item%s below vendor after cut+deposit — vendored as SELL steps (needs a merchant)|r",
			vendN, vendN == 1 and "" or "s"))
	end
	GM.PlanQueue.SetScanPlan({
		mode = "postscan",
		steps = steps,
		spend = 0,
		ev = ev - deposit,
		deposit = deposit,
		itemCount = itemCount,
		skipCount = skipN,
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
	GM.PlanQueue.Show() -- progress + results live in the main window
	GM.PlanQueue.ScanStart("cancelscan")
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
	-- GROUPS selection scopes which owned listings are checked;
	-- nil = every owned auction
	local sel = A.ScanGroupIds()
	local owned = {}
	for fp, a in pairs(GM.Inventory.auctions or {}) do
		if (not sel) or sel[a.itemID] then owned[fp] = a end
	end
	local byItem = {}
	for fp, a in pairs(owned) do
		local e = byItem[a.itemID] or { aids = {}, seen = {},
			minUnit = math.huge }
		-- owned buyout is per-item on Forever (same convention as
		-- item-search results — see AH.lua note) — no /qty
		local unit = a.buyout and a.qty > 0 and a.buyout or nil
		-- the map key is a listing fingerprint — CancelAuction needs
		-- the snapshot's real auctionID (enum index fallback).
		-- duplicate enum rows share that key — collapse them or the
		-- same real auction gets a cancel step per ghost row.
		-- a.keys holds every row's key for n identical lots — one
		-- cancel step per listing, each with a distinct target
		local akey = a.aid or a.idx or fp
		if not e.seen[akey] then
			e.seen[akey] = true
			for _, k in ipairs(a.keys or { akey }) do
				tinsert(e.aids, { aid = k, qty = a.qty, unit = unit })
			end
		end
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
	-- live shared book → synchronous pass, same as the post scan
	if GM.AH.BookLive() then
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
	GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("cancel scan — checking 0/%d posted items|r", #items))
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
			GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("cancel scan — checking %d/%d posted items|r",
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
			and "cancel scan done — no undercut auctions|r"
			or format("cancel scan done — %d undercut item%s (cancel-undercut is off in group ops)|r",
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

-- ============ shopping scan ============

-- group-scoped buy pass: every item in the GROUPS selection gets
-- queried; listings at/under the group's shopping cap become buy
-- steps (one click each, same as every plan). The cap mirrors the
-- sniper rule: shopping.maxPrice expr, falling back to belowPct%
-- under dbmarket when the expr won't resolve — an unresolvable cap
-- skips the item rather than buying unbounded.
function A.ShoppingScan()
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return
	end
	if A.Busy() then
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "scan already running|r")
		return
	end
	local ids = A.ScanGroupIds()
	if not ids then
		GM.PlanQueue.ScanStatus(GM.CC("warn")
			.. "shopping scan is group-scoped — pick groups first (GROUPS)|r")
		return
	end
	GM.PlanQueue.Show()
	GM.PlanQueue.ScanStart("shopscan")
	local items = {}
	for id in pairs(ids) do items[#items + 1] = id end
	table.sort(items, function(a, b)
		return (GM.ItemName(a) or "") < (GM.ItemName(b) or "")
	end)
	if #items == 0 then
		GM.PlanQueue.ScanStatus(GM.CC("warn") .. "selected groups are empty|r")
		return
	end

	local function Cap(id)
		local sOps = GM.Groups.GetOps(id, "shopping")
		local cap = GM.Groups.EvalOp(sOps, "maxPrice", id)
		-- corrupted market data can explode exprs into e+45 caps that
		-- would buy everything — treat as unusable (sniper's rule)
		if cap and cap > 1e10 then cap = nil end
		if cap then return cap end
		local m = GM.Price("dbmarket", id)
		local pct = tonumber(sOps.belowPct) or 10
		return m and floor(m * (1 - pct / 100)) or nil
	end

	local steps, spend, mktSum, hits = {}, 0, 0, {}
	local shopRows = {} -- per-hit rows for the AH window's results pane
	local remaining = #items
	GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format(
		"shopping scan — checking 0/%d group items|r", #items))
	for _, id in ipairs(items) do
		ScanQueued(id, function(asks)
			local cap = Cap(id)
			local isComm = GM.AH.IsCommodity(id)
			local m = GM.Price("dbmarket", id)
			local pre = #steps
			local cQty, cUnit, cCost = 0, nil, 0
			local row
			for _, a in ipairs(asks) do
				if not a.own and cap and a.unit and a.unit <= cap then
					if not row then
						-- asks sort cheapest-first → first accepted
						-- unit is the floor the list shows
						row = { id = id,
							name = GM.ItemName(id) or ("item " .. id),
							qty = 0, unit = a.unit, mkt = m,
							low = true, asks = asks }
						shopRows[#shopRows + 1] = row
					end
					row.qty = row.qty + a.qty
					if isComm then
						cQty = cQty + a.qty
						cUnit = a.unit
						cCost = cCost + (a.total or a.unit * a.qty)
					else
						local cost = a.total or a.unit * a.qty
						tinsert(steps, { kind = "buy", itemID = id,
							item = ItemLink(id), name = ShortName(id),
							qty = a.qty, unit = a.unit, total = cost,
							auctionID = a.id, btag = "shop",
							bagBase = GM.BagCount(id) })
						spend = spend + cost
						mktSum = mktSum + (m or 0) * a.qty
					end
				end
			end
			if cQty > 0 then
				-- commodities buy via staged quote: one step takes the
				-- whole under-cap depth at the deepest accepted unit
				tinsert(steps, { kind = "buy", itemID = id,
					item = ItemLink(id), name = ShortName(id),
					qty = cQty, unit = cUnit, commodity = true,
					btag = "shop", bagBase = GM.BagCount(id) })
				spend = spend + cCost
				mktSum = mktSum + (m or 0) * cQty
			end
			if #steps > pre then hits[id] = true end
			remaining = remaining - 1
			GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format(
				"shopping scan — checking %d/%d group items|r",
				#items - remaining, #items))
			if remaining == 0 then
				A.FinishShopScan(steps, spend, mktSum, hits, shopRows)
			end
		end)
	end
end

function A.FinishShopScan(steps, spend, mktSum, hits, shopRows)
	if #steps == 0 then
		GM.PlanQueue.ClearPlan()
		GM.PlanQueue.ScanStatus(GM.CC("textDim")
			.. "shopping scan done — nothing at/under the groups' max prices|r")
		return
	end
	table.sort(shopRows, function(a, b)
		return (a.name or "") < (b.name or "")
	end)
	if GM.AHUI and GM.AHUI.PostShopRows then
		GM.AHUI.PostShopRows(shopRows)
	end
	local n = 0
	for _ in pairs(hits) do n = n + 1 end
	GM.PlanQueue.SetScanPlan({
		mode = "shopscan",
		steps = steps,
		spend = spend,
		ev = mktSum,
		itemCount = n,
	})
end
