local _, GM = ...

-- Pure functions only — no WoW API calls. Unit-testable outside the client.

GM.Solver = {}

-- asks: array of { id?, qty, unit } sorted ascending by unit price (copper).
-- p50/p90: model estimate, copper. gold: player copper. vel: expected units/day.
-- Returns { steps = { {kind, qty, unit, auctionID?}, ... }, spend, ev, postPrice, daysToClear }
function GM.Solver.Plan(asks, p50, p90, gold, vel, opts)
	opts = opts or {}
	local riskBudget   = opts.riskBudget or 0.40
	local minMargin    = opts.minProfitMargin or 0.10
	local ahCut        = opts.ahCut or 0.05
	local owned        = opts.owned or 0     -- units already in bags join the relist
	local resale       = floor(p50 * (1 - ahCut))
	local guard        = p90 and math.min(p50, p90) or p50
	local spend, qty   = 0, 0
	local steps        = {}

	for _, ask in ipairs(asks) do
		local lotCost = ask.unit * ask.qty
		local margin = (resale - ask.unit) / ask.unit
		if margin < minMargin then break end
		if spend + lotCost > gold * riskBudget then break end
		tinsert(steps, {
			kind = "buy",
			qty = ask.qty,
			unit = ask.unit,
			total = ask.total,
			auctionID = ask.id,
		})
		spend = spend + lotCost
		qty = qty + ask.qty
	end

	if qty == 0 and owned == 0 then
		if #asks == 0 then return nil, "book is empty and you own none" end
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
		buyLots = steps
		steps = { { kind = "buy", qty = qty, unit = ceil(spend / qty), commodity = true } }
	end

	local postQty = qty + owned
	tinsert(steps, { kind = "post", qty = postQty, unit = guard })

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
