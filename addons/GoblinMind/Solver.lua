local _, GM = ...

-- Pure functions only — no WoW API calls. Unit-testable outside the client.

GM.Solver = {}

-- asks: array of { id?, qty, unit } sorted ascending by unit price (copper).
--   own-flagged rows are stripped from buys; opts.ownAsks hands them
--   back for the cancel-merge (see below).
-- opts.cancelUndercut + opts.ownAsks: cancel own off-target listings
--   and fold their units into the relist pool.
-- p50/p90: model estimate, copper. gold: player copper. vel: expected units/day.
-- Returns { steps = { {kind, qty, unit, auctionID?}, ... }, spend, ev, postPrice, daysToClear }
function GM.Solver.Plan(asks, p50, p90, gold, vel, opts)
	opts = opts or {}
	-- our own auctions aren't buyable supply — buying your own
	-- listing just burns the AH cut and reports fake volume. The
	-- right verb for an underpriced own listing is cancel+repost,
	-- which the undercut flow owns (not this plan).
	local ownOnly = false
	local filtered = {}
	for _, a in ipairs(asks or {}) do
		if a.own then ownOnly = true else tinsert(filtered, a) end
	end
	asks = filtered
	local riskBudget   = opts.riskBudget or 0.40
	local minMargin    = opts.minProfitMargin or 0.10
	local ahCut        = opts.ahCut or 0.05
	local owned        = opts.owned or 0     -- units already in bags join the relist
	local postCap      = opts.postCap and opts.postCap > 0 and opts.postCap or math.huge
	-- group op override: auctioning.normal replaces the model post target,
	-- clamped to [min, max] — resale basis and buy ceiling derive from it
	local postTarget   = opts.normal or p50
	if opts.minP then postTarget = math.max(postTarget, opts.minP) end
	if opts.maxP then postTarget = math.min(postTarget, opts.maxP) end
	local resale       = floor(postTarget * (1 - ahCut))
	local guard        = opts.normal and postTarget
		or (p90 and math.min(p50, p90) or p50)
	-- drag-lot live: undercut the honest ask, period. Posting inside
	-- the bait→wall gap or below the bait is dominated — the gap is
	-- the same queue position at a worse price, and below-bait
	-- engages the drag on its terms (it re-drags under you, or its
	-- sniper collects the discount). Wall-undercut sits behind the
	-- bait at near-market and sells the moment it clears
	local wall, baitUnit = GM.Auctioning.Cheapest(asks)
	if baitUnit then
		local ref = wall or baitUnit -- all-bait book: the drag itself
		-- is the only reference left
		if guard < ref then
			guard = ref - (opts.undercut or 0)
			if opts.maxP then guard = math.min(guard, opts.maxP) end
		end
	end
	local buyCap       = math.max(0, postCap - owned)
	local spend, qty   = 0, 0
	local steps        = {}

	local lots = {}  -- whole-lot mirror for the per-lot buyout fallback
	for _, ask in ipairs(asks) do
		-- postCap granularity: items buy whole lots only; commodities
		-- take a partial slice (the staged purchase buys exact qty)
		local take = ask.qty
		if qty + take > buyCap then
			if not opts.commodity then break end
			take = buyCap - qty
		end
		if take <= 0 then break end
		local lotCost = ask.unit * take
		local margin = (resale - ask.unit) / ask.unit
		if margin < minMargin then break end
		if spend + lotCost > gold * riskBudget then break end
		tinsert(steps, {
			kind = "buy",
			qty = take,
			unit = ask.unit,
			total = lotCost,
			auctionID = ask.id,
		})
		tinsert(lots, {
			kind = "buy",
			qty = ask.qty,
			unit = ask.unit,
			total = ask.total,
			auctionID = ask.id,
		})
		spend = spend + lotCost
		qty = qty + take
	end

	-- own listings priced off the plan's post target aren't bought —
	-- they're canceled and their units join the relist pool. Any
	-- mismatch counts: below target = repost higher, above target =
	-- the plan's posts would undercut our own listing. Gated on the
	-- auctioning cancelUndercut op; each cancel is still its own
	-- hardware click.
	local relisted = 0
	if opts.cancelUndercut then
		for _, o in ipairs(opts.ownAsks or {}) do
			if o.id and o.unit and o.qty and o.qty > 0
				and o.unit ~= guard then
				tinsert(steps, {
					kind = "cancel",
					auctionID = o.id,
					qty = o.qty,
					unit = o.unit,
				})
				relisted = relisted + o.qty
			end
		end
	end

	if qty == 0 and owned == 0 and relisted == 0 then
		if #asks == 0 then
			return nil, ownOnly
				and "only listings up are yours — nothing to buy"
				or "no asks listed and nothing in bags to post"
		end
		local first = asks[1]
		if (resale - first.unit) / first.unit < minMargin then
			return nil, format("no buy path — cheapest %s > ceiling %s",
				GM.Money(first.unit), GM.Money(floor(resale / (1 + minMargin))))
		end
		return nil, format("no buy path — risk budget can't cover cheapest lot (%s)",
			GM.Money(first.unit * first.qty))
	end

	-- commodities buy in one aggregated call, not per ask lot — but keep
	-- the per-lot list so the UI can fall back to PlaceBid if the staged
	-- quote flow produces nothing on this client
	local buyLots
	if qty > 0 and opts.commodity then
		buyLots = lots  -- real lot totals for PlaceBid fallback
		-- the aggregate replaces per-lot buys but keeps non-buy
		-- steps (own-listing cancels) already emitted
		local keep = {}
		for _, s in ipairs(steps) do
			if s.kind ~= "buy" then tinsert(keep, s) end
		end
		steps = { { kind = "buy", qty = qty, unit = ceil(spend / qty), commodity = true } }
		for _, s in ipairs(keep) do tinsert(steps, s) end
	end

	-- relisted units post outside the cap — they were already listed,
	-- so cancel+repost is net-zero against the posted-count budget
	local postQty = math.min(qty + owned, postCap) + relisted
	-- stackSize splits the post leg into per-stack clicks (items only —
	-- commodities post in one call regardless)
	local stack = opts.stackSize and opts.stackSize > 0 and opts.stackSize
	if stack and not opts.commodity then
		local rem = postQty
		while rem > 0 do
			local n = math.min(rem, stack)
			tinsert(steps, { kind = "post", qty = n, unit = guard })
			rem = rem - n
		end
	elseif postQty > 0 then
		tinsert(steps, { kind = "post", qty = postQty, unit = guard })
	end

	local ev = resale * postQty - spend
	local daysToClear = vel and vel > 0 and (postQty / vel) or nil
	return {
		steps = steps,
		buyLots = buyLots,
		spend = spend,
		ev = floor(ev),
		resale = resale,
		postPrice = guard,
		qty = qty,
		owned = owned,
		relisted = relisted,
		daysToClear = daysToClear,
	}
end

-- A plan is only honest if the market can absorb it before prices decay.
function GM.Solver.Verdict(plan, opts)
	opts = opts or {}
	local maxDays = opts.maxDaysToClear or 7
	if not plan then return "none", "no plan" end
	if plan.ev <= 0 then return "bad", "expected loss" end
	if plan.daysToClear and plan.daysToClear > maxDays then
		return "slow", format("~%.1f days to clear", plan.daysToClear)
	end
	return "good", format("expected %s profit", GM.Money(plan.ev))
end
