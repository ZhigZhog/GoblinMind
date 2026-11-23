local _, GM = ...

-- Envelope budgeting: named accounts persisted in GoblinMindSettings.
-- "craft"/"ah" accounts hold a copper allocation that spending draws
-- down; "save" accounts reserve a % of current gold and are never
-- spendable. Free gold = gold − save reserves − unspent allocations.
-- Budget violations never block a step — ExecuteNext warns once per
-- step and a second click confirms the override.

GM.Budget = {}
local B = GM.Budget

B.KINDS = { craft = "CRAFT", ah = "AH", save = "SAVE" }
B.KIND_ORDER = { "craft", "ah", "save" }

local function DB()
	if not GM.db.budgets then GM.db.budgets = {} end
	return GM.db.budgets
end

-- "12g50s25c" / "12g 50s" / "1.5g" / "5000" (bare number = copper) →
-- copper or nil. Whitespace- and case-tolerant.
function B.ParseMoney(str)
	if not str then return nil end
	local s = str:lower():gsub("%s", "")
	if s == "" then return nil end
	local total, found = 0, false
	for num, unit in s:gmatch("([%d%.]+)([gsc])") do
		local v = tonumber(num)
		if not v then return nil end
		found = true
		total = total + v * (unit == "g" and 10000 or unit == "s" and 100 or 1)
	end
	if not found then
		local v = tonumber(s)
		if not v or v < 0 then return nil end
		return floor(v)
	end
	-- leftover characters that aren't part of a unit token → reject
	if s:gsub("[%d%.]+[gsc]", "") ~= "" then return nil end
	return floor(total)
end

function B.List() return DB() end

function B.Add(name, kind, alloc)
	if not (name and name ~= "" and B.KINDS[kind]) then return nil end
	local a = { name = name, kind = kind, spent = 0, income = 0 }
	if kind == "save" then
		a.pct = math.max(0, math.min(100, floor(tonumber(alloc) or 0)))
	else
		a.alloc = math.max(0, floor(tonumber(alloc) or 0))
	end
	tinsert(DB(), a)
	B.Sample()
	return a
end

function B.Del(i) tremove(DB(), i) end

-- rename keeps the account record (spent/income/group all survive) —
-- rejects empty names and dupes
function B.Rename(i, name)
	local a = DB()[i]
	name = type(name) == "string" and strtrim(name) or ""
	if not (a and name ~= "") then return nil end
	for j, o in ipairs(DB()) do
		if j ~= i and o.name == name then return nil end
	end
	a.name = name
	return a
end
function B.ResetSpent(i)
	local a = DB()[i]
	if a then a.spent, a.income = 0, 0 B.Sample() end
end

function B.SetKind(i, kind)
	local a = DB()[i]
	if not (a and B.KINDS[kind]) then return end
	a.kind = kind
	-- kind swap reinterprets the allocation field
	if kind == "save" and not a.pct then
		a.pct = 10
		a.alloc = nil
	elseif kind ~= "save" and not a.alloc then
		a.alloc = B.Alloc(a)
		a.pct = nil
	end
	B.Sample()
end

-- binds the account to a group path (reagents, ammo, …): spends and
-- sales of items in that group route here regardless of step kind
function B.SetGroup(i, path)
	local a = DB()[i]
	if a then a.group = (path ~= "" and path) or nil end
end

-- sorted list of assignable group paths for the function picker
function B.GroupPaths()
	local out = {}
	if GM.Groups and GM.Groups.db and GM.Groups.db.groups then
		for path in pairs(GM.Groups.db.groups) do tinsert(out, path) end
	end
	sort(out)
	return out
end

local function Gold() return GetMoney and GetMoney() or 0 end

-- effective reserve/allocation in copper right now
function B.Alloc(a)
	-- the base pool is every copper no other envelope claims — it
	-- reads live gold instead of a stored alloc so it never drifts
	if a.pool then
		local g = Gold()
		for _, o in ipairs(DB()) do
			if o ~= a then g = g - B.Remaining(o) end
		end
		return math.max(0, g)
	end
	if a.pct then return floor(Gold() * a.pct / 100) end
	return a.alloc or 0
end

function B.Remaining(a)
	-- pool/save balances are already live — spent/income would
	-- double-count against a moving alloc (they stay as bookkeeping)
	if a.pool or a.kind == "save" then return B.Alloc(a) end
	return math.max(0, B.Alloc(a) + (a.income or 0) - (a.spent or 0))
end

-- gold with no claim on it: minus save reserves, minus everything
-- still earmarked in spendable accounts
function B.Free()
	local free = Gold()
	for _, a in ipairs(DB()) do
		free = free - B.Remaining(a)
	end
	return math.max(0, free)
end

local function StepTag(step)
	if step.btag and B.KINDS[step.btag] then return step.btag end
	if step.kind == "vendbuy" or step.kind == "buy" then return "ah" end
	return nil
end

-- the specific account a step/item draws on: a group-bound account
-- takes precedence over kind matching (an "ammo" envelope pays for
-- ammo whether the buy is at the AH or a vendor)
local function StepAccount(step)
	if step.itemID and GM.Groups and GM.Groups.GroupForItem then
		local path = GM.Groups.GroupForItem(step.itemID)
		if path then
			for _, a in ipairs(DB()) do
				if a.group == path then return a end
			end
		end
	end
	return nil
end

local function MatchingAccounts(step)
	local bound = StepAccount(step)
	if bound then return { bound }, true end
	local tag = StepTag(step)
	local out = {}
	if tag then
		for _, a in ipairs(DB()) do
			if a.kind == tag then tinsert(out, a) end
		end
	end
	-- nothing kind-matched: the base pool is the catch-all — every
	-- spend draws gold, so every spend may draw the pool down
	if #out == 0 then
		for _, a in ipairs(DB()) do
			if a.pool then tinsert(out, a) end
		end
	end
	return out, false
end

-- over, spendable, deficit — over=false always when no budget accounts
-- exist, so the system stays silent until the player opts in
function B.Check(step, cost)
	if not cost or cost <= 0 then return false end
	if not next(DB()) then return false end
	local tag = StepTag(step)
	if not tag and not StepAccount(step) then return false end
	local matching = MatchingAccounts(step)
	local spendable = B.Free()
	for _, a in ipairs(matching) do
		spendable = spendable + B.Remaining(a)
	end
	if cost > spendable then
		return true, spendable, cost - spendable
	end
	return false, spendable, 0
end

-- draw the cost down against matching accounts in order
function B.Record(step, cost)
	if not cost or cost <= 0 then return end
	local matching = MatchingAccounts(step)
	if #matching == 0 then return end
	local owed = cost
	for _, a in ipairs(matching) do
		if a.kind ~= "save" and owed > 0 then
			local take = math.min(B.Remaining(a), owed)
			a.spent = (a.spent or 0) + take
			owed = owed - take
		end
	end
	-- overspend lands on the first matching account so the row shows
	-- the hole rather than silently dropping it
	if owed > 0 then
		for _, a in ipairs(matching) do
			if a.kind ~= "save" then
				a.spent = (a.spent or 0) + owed
				break
			end
		end
	end
	B.Sample()
end

-- sale proceeds top the envelope back up (trading float): bound
-- account for the item's group, else the first AH account
function B.CreditSale(itemID, amount)
	if not amount or amount <= 0 then return end
	local target
	if itemID and GM.Groups and GM.Groups.GroupForItem then
		local path = GM.Groups.GroupForItem(itemID)
		if path then
			for _, a in ipairs(DB()) do
				if a.group == path then target = a break end
			end
		end
	end
	if not target then
		for _, a in ipairs(DB()) do
			if a.kind == "ah" then target = a break end
		end
	end
	if target then
		target.income = (target.income or 0) + amount
		B.Sample()
	end
end

-- trend sampling: remaining-balance history per account plus a
-- free-gold series — capped rolling buffers in the SV
local HIST_CAP = 200
function B.Sample()
	local t = time()
	for _, a in ipairs(DB()) do
		a.hist = a.hist or {}
		local h = a.hist
		local n = #h
		-- collapse same-value adjacent samples so a flat week doesn't
		-- push real movement out of the window
		if n == 0 or h[n].v ~= B.Remaining(a) or t - h[n].t > 3600 then
			h[n + 1] = { t = t, v = B.Remaining(a),
				inc = a.income or 0, out = a.spent or 0 }
			if #h > HIST_CAP then tremove(h, 1) end
		end
	end
	local f = GM.db.budgetFree
	if not f then f = {} GM.db.budgetFree = f end
	local free = B.Free()
	if #f == 0 or f[#f].v ~= free or t - f[#f].t > 3600 then
		f[#f + 1] = { t = t, v = free }
		if #f > HIST_CAP then tremove(f, 1) end
	end
	-- wealth series for the account chart: real gold on hand + the
	-- posted-buyout snapshot, so the plot shows what you'd be worth
	-- if every listing sold at asking
	local w = GM.db.wealthHist
	if not w then w = {} GM.db.wealthHist = w end
	local gold = GetMoney and GetMoney() or 0
	local posted = GM.Inventory and GM.Inventory.PostedValue
		and GM.Inventory.PostedValue() or 0
	if #w == 0 or w[#w].g ~= gold or w[#w].a ~= posted
		or t - w[#w].t > 3600 then
		-- c: the sampler char — wealth is per-char by nature and
		-- untagged mixing drew alt logins as giant fake dips
		w[#w + 1] = { t = t, g = gold, a = posted,
			c = GM.CharKeyQualified() }
		if #w > HIST_CAP then tremove(w, 1) end
	end
end

-- windowed income/spend: cumulative-counter delta since the sample
-- at or before `days` ago (earliest carrying fields when the buffer
-- is younger). A mid-window reset can only under-report; samples
-- that predate the inc/out fields yield nils so the UI shows "—"
-- rather than a padded number
function B.Flow(a, days)
	local h = a.hist
	if not h or #h == 0 then return nil, nil end
	local cutoff = time() - (days or 7) * 86400
	local base, oldest
	for _, p in ipairs(h) do
		if p.inc then
			oldest = oldest or p
			if p.t <= cutoff then base = p end
		end
	end
	base = base or oldest
	if not base then return nil, nil end
	return math.max(0, (a.income or 0) - base.inc),
	       math.max(0, (a.spent or 0) - base.out)
end

function B.Init()
	DB()
	-- fresh installs start with one account: the base pool — a live
	-- envelope over all unearmarked gold so the ledger's spend math
	-- has a home before the player creates their own budgets
	if not next(DB()) then
		tinsert(DB(), { name = "Base Pool", kind = "ah", pool = true,
			spent = 0, income = 0 })
	end
	B.Sample()
	-- background sampler keeps the trend lines honest while idle
	local function tick()
		B.Sample()
		GM.After(300, tick)
	end
	GM.After(300, tick)
end

-- display helper: "5g" for budgets, "30%" for saves
function B.AllocText(a)
	if a.pool then return GM.Money(B.Alloc(a)) end
	if a.kind == "save" then return a.pct .. "%" end
	return GM.Money(a.alloc or 0)
end
