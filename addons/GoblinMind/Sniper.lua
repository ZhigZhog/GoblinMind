local _, GM = ...

-- Part 6b: sniper feed. ReplicateItems dumps the entire book (read
-- query, safe on a timer — TSM does the same). Results carry link +
-- stackSize + buyout but NO auctionID, so hits only DETECT: a row
-- click re-queries the item's book and buys the matching listing —
-- detection and purchase stay separate hardware clicks.

GM.Sniper = { hits = {}, snapshot = nil, lastT = 0 }
local N = GM.Sniper

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local Now = debugprofilestop or function() return GetTime() * 1000 end
local CAP = 50

-- ============ replicate scan ============

function N.Scan()
	GM.AH.FullScan() -- shared book pass; subscribers get the raw rows
end

GM.AH.bookSubs[#GM.AH.bookSubs + 1] = function(rows) N.Collect(rows) end

-- price cap for a hit: sniper.belowPrice expr, else belowPct of market
local function PriceCap(itemID, ops)
	local cap = GM.Groups.EvalOp(ops, "belowPrice", itemID)
	-- corrupted market data can explode the expression into
	-- e+45-scale caps — a cap above ~1M gold flags every listing as
	-- a hit, so treat it as no usable cap
	if cap and cap > 1e10 then return nil end
	if cap then return cap end
	local e = GM.ItemEntry(itemID)
	local m = GM.Price("dbmarket", itemID)
	local pct = tonumber(ops.belowPct) or 20
	return m and floor(m * (1 - pct / 100)) or nil
end

local collectGen = 0

function N.Collect(rows)
	local now, fresh = {}, {}
	for _, r in ipairs(rows) do
		now[r.key] = true
		if r.id and not r.own and (not N.snapshot or not N.snapshot[r.key]) then
			fresh[#fresh + 1] = {
				itemID = r.id, qty = r.qty, unit = r.unit, key = r.key,
			}
		end
	end
	local hadSnapshot = N.snapshot ~= nil
	N.snapshot = now
	N.lastT = time()

	-- hit eval is heavy (GetOps+EvalOp per row) — cache the cap per
	-- itemID and spread the work across frames
	collectGen = collectGen + 1
	local gen = collectGen
	local caps, i, lastReport = {}, 0, 0
	local function ChunkEval()
		if gen ~= collectGen then return end
		-- 5ms slices with an inter-slice breather — back-to-back 8ms
		-- chunks held ~half of every frame through a full-book eval
		local t0 = Now()
		while i < #fresh and Now() - t0 < 5 do
			i = i + 1
			local c = fresh[i]
			local cap = caps[c.itemID]
			if cap == nil then
				cap = PriceCap(c.itemID, GM.Groups.GetOps(c.itemID, "sniper")) or false
				caps[c.itemID] = cap
			end
			if cap and c.unit <= cap then
				local e = GM.ItemEntry(c.itemID)
				local m = GM.Price("dbmarket", c.itemID)
				c.cap = cap
				c.pct = m and m > 0 and (c.unit / m * 100) or nil
				-- don't freeze "item N" here — SniperUI re-resolves
				-- live once the async item data lands
				c.name = GetInfo and GetInfo(c.itemID)
				c.hit = true
				N.hits[#N.hits + 1] = c
			end
		end
		if i < #fresh then
			if Now() - lastReport > 400 then
				lastReport = Now()
				GM.PlanQueue.Progress(i / #fresh)
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					format("sniper: evaluating %d/%d listings|r", i, #fresh))
			end
			GM.After(0.03, ChunkEval)
		else
			GM.PlanQueue.Progress(nil)
			N.FinishCollect(now, hadSnapshot, #rows, #fresh)
		end
	end
	ChunkEval()
end

function N.FinishCollect(now, hadSnapshot, nRows, nFresh)

	-- drop hits whose listing vanished between snapshots (sold/expired)
	if hadSnapshot then
		for i = #N.hits, 1, -1 do
			local h = N.hits[i]
			if not h.done and not now[h.key] then
				tremove(N.hits, i)
			end
		end
	end
	-- dedupe + cap by discount depth, deepest first
	local seen = {}
	for i = #N.hits, 1, -1 do
		local h = N.hits[i]
		if h.done or seen[h.key] then
			tremove(N.hits, i)
		else
			seen[h.key] = true
		end
	end
	table.sort(N.hits, function(a, b) return (a.pct or 999) < (b.pct or 999) end)
	while #N.hits > CAP do tremove(N.hits) end

	local msg = hadSnapshot
		and format("sniper: %d new listings, %d hits", nFresh, #N.hits)
		or format("sniper: book primed — %d auctions, %d hits", nRows, #N.hits)
	GM.Shopping.Status(GM.CC("textDim") .. msg .. "|r")
	if GM.Shopping.Refresh then GM.Shopping.Refresh() end
	if GM.SniperUI and GM.SniperUI.Refresh then GM.SniperUI.Refresh() end
end

-- ============ auto-refresh while the sniper pane is open ============

local autoOn = false
function N.AutoRunning() return autoOn end

-- the auto loop lives while the sniper feed window is open
local function AnySniperUI()
	return GM.SniperUI and GM.SniperUI.IsOpen and GM.SniperUI.IsOpen()
end

function N.StartAuto()
	if autoOn then return end
	autoOn = true
	local function loop()
		if not AnySniperUI() then
			autoOn = false
			return
		end
		if GM.AH.open then N.Scan() end
		local rt = tonumber(GM.Groups.GetOps(nil, "sniper").refreshTime) or 60
		-- replicate scans are the heaviest thing we do — 5 min floor
		GM.After(math.max(rt, 300), loop)
	end
	loop()
end
