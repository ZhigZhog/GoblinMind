local _, GM = ...

-- Part 6b: sniper feed. ReplicateItems dumps the entire book (read
-- query, safe on a timer — TSM does the same). Results carry link +
-- stackSize + buyout but NO auctionID, so hits only DETECT: a row
-- click re-queries the item's book and buys the matching listing —
-- detection and purchase stay separate hardware clicks.

GM.Sniper = { hits = {}, snapshot = nil, lastT = 0 }
local N = GM.Sniper

-- shared filter state — SniperUI toggles these, task surfaces read
-- them through PendingCount so "N sniper hits" always means the
-- actionable feed, not the raw row dump. SOON defaults on: sniping
-- targets listings expiring inside 2h, not the whole book.
N.filters = { soon = true }

-- cheapest actionable price for a hit: a +1c bid when the listing
-- carries bid data, else the lot buyout
local function ActionCost(h)
	local live = h.live or {}
	local bid = (live.bid and live.bid > 0 and live.bid + 1)
		or live.minBid
		or (h.bid and h.bid > 0 and h.bid + 1)
	local lot = live.total or ((h.unit or math.huge) * (h.qty or 1))
	return math.min(bid or math.huge, lot or math.huge)
end

function N.PassFilters(h)
	local f = N.filters
	if not f then return true end
	-- biddable = the listing has a bid path: live data confirmed an
	-- auctionID, or the snapshot carried a bid field at all
	if f.bid and not ((h.live and h.live.id) or h.bid ~= nil
			or (h.live and h.live.minBid)) then
		return false
	end
	if f.gold then
		local money = GetMoney and GetMoney() or 0
		if ActionCost(h) > money then return false end
	end
	-- soon = expiring inside 2h. Estimates count (transition-pinned
	-- or midpoint); a 0 tl means "field unpopulated" — not
	-- "expires now" — and nil means no data (commodities) — both
	-- can never be "expiring", so they hide.
	if f.soon then
		local tl = (h.live and h.live.tl and h.live.tl > 0 and h.live.tl)
			or (h.tlex and h.tlex > GetTime() and (h.tlex - GetTime()))
			or (h.tl and h.tl > 0 and h.tl)
		if not tl or tl > 7200 then return false end
	end
	return true
end

function N.PendingCount()
	local n = 0
	for _, h in ipairs(N.hits) do
		if not h.done and N.PassFilters(h) then n = n + 1 end
	end
	return n
end

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local Now = debugprofilestop or function() return GetTime() * 1000 end
local CAP = 50

-- ============ replicate scan ============

function N.Scan()
	GM.AH.FullScan() -- shared book pass; subscribers get the raw rows
end

GM.AH.bookSubs[#GM.AH.bookSubs + 1] = function(rows) N.Collect(rows) end

-- price cap for a hit: sniper.belowPrice expr, else belowPct of market
local function PriceCap(itemID, ops, bk)
	local cap = GM.Groups.EvalOp(ops, "belowPrice", itemID)
	-- corrupted market data can explode the expression into
	-- e+45-scale caps — a cap above ~1M gold flags every listing as
	-- a hit, so treat it as no usable cap
	if cap and cap > 1e10 then return nil end
	if cap then return cap end
	local e = GM.ItemEntry(itemID, bk)
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
				itemID = r.id, bk = r.bk, qty = r.qty, unit = r.unit,
				key = r.key, bid = r.bid, tl = r.tl, tlex = r.tlex,
				link = r.link, -- carries name+quality when the item
				-- DB can't resolve the id (Forever customs)
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
	local caps, i, lastReport, bad = {}, 0, 0, 0
	-- one bad row must not kill the chain — an error inside the
	-- slice means GM.After never reschedules and the last
	-- "evaluating" line freezes forever (bid-only rows carry nil
	-- unit: the `c.unit <= cap` compare throws). pcall each row
	-- and count the skips for the completion line
	local function EvalRow(c)
		-- cap cache keys by book key — variants of one item get
		-- their own cap (a cheap "of the Owl" lot must not undercut-
		-- flag against the base item's market)
		local ck = c.bk or c.itemID
		local cap = caps[ck]
		if cap == nil then
			cap = PriceCap(c.itemID, GM.Groups.GetOps(c.itemID, "sniper"), c.bk) or false
			caps[ck] = cap
		end
		if cap and c.unit and c.unit <= cap then
			local e = GM.ItemEntry(c.itemID, c.bk)
			local m = GM.Price("dbmarket", c.itemID)
			c.cap = cap
			c.pct = m and m > 0 and (c.unit / m * 100) or nil
			-- don't freeze "item N" here — SniperUI re-resolves
			-- live once the async item data lands. The link's own
			-- [name] is the fallback for ids the client DB can't
			-- resolve at all ("" counts as unresolved on Forever)
			local ok, nm = pcall(function()
				return GetInfo and GetInfo(c.itemID) end)
			nm = ok and nm or nil
			c.name = (type(nm) == "string" and nm ~= "" and nm)
				or GM.LinkName(c.link)
			c.hit = true
			N.hits[#N.hits + 1] = c
		end
	end
	local function ChunkEval()
		if gen ~= collectGen then return end
		-- 5ms slices with an inter-slice breather — back-to-back 8ms
		-- chunks held ~half of every frame through a full-book eval
		local t0 = Now()
		while i < #fresh and Now() - t0 < 5 do
			i = i + 1
			if not pcall(EvalRow, fresh[i]) then bad = bad + 1 end
		end
		if i < #fresh then
			if Now() - lastReport > 400 then
				lastReport = Now()
				GM.PlanQueue.Progress(i / #fresh)
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					format("sniper: evaluating %d/%d listings|r", i, #fresh))
			end
			GM.Time.After(0.03, ChunkEval)
		else
			GM.PlanQueue.Progress(nil)
			N.FinishCollect(now, hadSnapshot, #rows, #fresh, bad)
		end
	end
	ChunkEval()
end

function N.FinishCollect(now, hadSnapshot, nRows, nFresh, bad)

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
	if bad and bad > 0 then
		msg = msg .. format(" · %d skipped", bad)
	end
	GM.Shopping.Status(GM.CC("textDim") .. msg .. "|r")
	-- progress reported through ScanStatus, so completion has to go
	-- through it too — otherwise the last "evaluating" line stays
	-- frozen in the AH footer / planner summary
	GM.PlanQueue.ScanStatus(GM.CC("textDim") .. msg .. "|r")
	GM.View.Refresh("market")
	GM.View.Refresh("sniper")
end

-- ============ auto-refresh while the sniper pane is open ============

local autoOn = false
function N.AutoRunning() return autoOn end

-- the auto loop lives while the sniper feed window is open
local function AnySniperUI()
	return GM.View.IsShown("sniper")
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
		GM.Time.After(math.max(rt, 300), loop)
	end
	loop()
end
