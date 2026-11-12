local _, GM = ...

-- TSM-compatible custom price expressions: "min(dbmarket, 120% crafting)",
-- "10g + 50% dbmarket", "check(avgsell, 1g, dbmarket)". Pure evaluator —
-- nils propagate, bad input returns nil+err, never throws through UI paths.
-- Custom sources live in GoblinMindPrices.customSources (SavedVariable).

GM.Pricing = {}

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

-- ============ GM.Price(key, itemID) — db* source facade ============

local KEYMAP = {
	dbmarket = "mkt", marketvalue = "mkt", p = "p",
	dbminbuyout = "mb", minbuyout = "mb",
	dbhistorical = "hist", historical = "hist",
	dbrecent = "recent", marketvaluerecent = "recent",
	dbregionmarketavg = "rmkt", dbregionhistorical = "rhist",
	dbregionsale = "rsale", dbregionsalerate = "vel",
	numauctions = "sup", sup = "sup",
}

function GM.Price(key, itemID)
	if not itemID then return nil end
	key = strlower(tostring(key or ""))
	local entry = GM.ItemEntry(itemID)
	if key == "dbregionsalepercent" then
		return entry and entry.rsalep and entry.rsalep / 1000 or nil
	end
	local field = KEYMAP[key]
	local v = entry and field and entry[field]
	if v == nil and (key == "dbmarket" or key == "marketvalue") then
		-- p derives from marketValue → marketValueRecent → fallbacks
		v = entry and entry.p or GM.TSMMarket(itemID)
	end
	return v
end

-- ============ sources: name -> fn(itemID) -> copper|nil ============

local function ef(itemID, k)
	local e = GM.ItemEntry(itemID)
	return e and e[k]
end

local SRC = {
	dbmarket            = function(id) return GM.Price("dbmarket", id) end,
	marketvalue         = function(id) return GM.Price("dbmarket", id) end,
	dbminbuyout         = function(id) return ef(id, "mb") end,
	minbuyout           = function(id) return ef(id, "mb") end,
	dbhistorical        = function(id) return ef(id, "hist") end,
	historical          = function(id) return ef(id, "hist") end,
	dbrecent            = function(id) return ef(id, "recent") end,
	marketvaluerecent   = function(id) return ef(id, "recent") end,
	dbregionmarketavg   = function(id) return ef(id, "rmkt") end,
	dbregionhistorical  = function(id) return ef(id, "rhist") end,
	dbregionsale        = function(id) return ef(id, "rsale") end,
	dbregionsalerate    = function(id) return ef(id, "vel") end,
	dbregionsalepercent = function(id) return GM.Price("dbregionsalepercent", id) end,
	numauctions         = function(id) return ef(id, "sup") end,
	vendorsell          = function(id) return GetInfo and select(11, GetInfo(id)) or nil end,
	vendorbuy           = function() return nil end, -- no reliable source on Forever
	numinventory        = function(id) return GM.BagCount(id) + GM.BankCount(id) end,
	-- accounting-derived — real values arrive with the ledger (M1.B)
	avgbuy              = function(id) return GM.Ledger and GM.Ledger.Avg(id, "buy") end,
	smartavgbuy         = function(id) return GM.Ledger and GM.Ledger.Avg(id, "buy") end,
	avgsell             = function(id) return GM.Ledger and GM.Ledger.Avg(id, "sell") end,
	avgpaid             = function(id) return GM.Ledger and GM.Ledger.Avg(id, "paid") end,
	avgminbuyout        = function(id) return GM.Ledger and GM.Ledger.Avg(id, "minbuy") end,
	-- crafting/destroy — real values arrive with Parts 7/10
	crafting            = function() return nil end,
	matprice            = function() return nil end,
	disenchant          = function() return nil end,
	destroy             = function() return nil end,
	gather              = function() return nil end,
}

-- ============ tokenizer ============

local function Tokenize(s)
	local toks, i = {}, 1
	while i <= #s do
		local c = s:sub(i, i)
		if c:match("%s") then
			i = i + 1
		elseif c == "i" and s:sub(i + 1, i + 1) == ":" then
			local id = s:match("^i:(%d+)", i)
			if not id then return nil, "bad item ref at " .. i end
			tinsert(toks, { t = "item", v = tonumber(id) })
			i = i + 2 + #id
		elseif c:match("[%d%.]") then
			local num, unit = s:match("^(%d*%.?%d+)([gsc]?)", i)
			if not num then return nil, "bad number at " .. i end
			tinsert(toks, { t = "num", v = tonumber(num), u = unit ~= "" and unit or nil })
			i = i + #num + (unit ~= "" and 1 or 0)
		elseif c:match("[%a_]") then
			local w = s:match("^([%a_][%w_]*)", i)
			tinsert(toks, { t = "id", v = w })
			i = i + #w
		elseif c:match("[%+%-%*/%%%(%)%,]") then
			tinsert(toks, { t = "op", v = c })
			i = i + 1
		else
			return nil, 'unexpected char "' .. c .. '"'
		end
	end
	return toks
end

-- ============ recursive-descent evaluator ============

local parseExpr -- forward decl

local MUL = { ["*"] = 1, ["/"] = 1 }
local MONEY = { g = 10000, s = 100, c = 1 }

local function parseAtom(t, i, ctx)
	local tok = t[i]
	if not tok then return nil, i end
	if tok.t == "num" then
		if tok.u then -- money literal: consecutive g/s/c parts sum
			local sum, j = 0, i
			while t[j] and t[j].t == "num" and MONEY[t[j].u] do
				sum = sum + t[j].v * MONEY[t[j].u]
				j = j + 1
			end
			return sum, j
		end
		return tok.v, i + 1
	elseif tok.t == "item" then
		return GM.Price("dbmarket", tok.v), i + 1
	elseif tok.t == "id" then
		local name = strlower(tok.v)
		if t[i + 1] and t[i + 1].t == "op" and t[i + 1].v == "(" then
			local args, j = {}, i + 2
			while true do
				local v
				v, j = parseExpr(t, j, ctx)
				tinsert(args, v)
				local sep = t[j]
				if sep and sep.t == "op" and sep.v == "," then
					j = j + 1
				elseif sep and sep.t == "op" and sep.v == ")" then
					j = j + 1
					break
				else
					return nil, j -- unterminated arg list
				end
			end
			return ctx.callFunc(name, args, ctx), j
		end
		return ctx.sourceValue(name, ctx.itemID, ctx), i + 1
	elseif tok.t == "op" and tok.v == "(" then
		local v, j = parseExpr(t, i + 1, ctx)
		if not (t[j] and t[j].t == "op" and t[j].v == ")") then
			return nil, j
		end
		return v, j + 1
	end
	return nil, i
end

local function parseFactor(t, i, ctx)
	local tok = t[i]
	if tok and tok.t == "op" and tok.v == "-" then
		local v, j = parseFactor(t, i + 1, ctx)
		return v and -v or nil, j
	end
	-- "120% crafting": percentage binds tighter than * or /
	if tok and tok.t == "num" and not tok.u
		and t[i + 1] and t[i + 1].t == "op" and t[i + 1].v == "%" then
		local v, j = parseFactor(t, i + 2, ctx)
		return v and v * tok.v / 100 or nil, j
	end
	return parseAtom(t, i, ctx)
end

local function parseTerm(t, i, ctx)
	local lhs, j = parseFactor(t, i, ctx)
	while t[j] and t[j].t == "op" and MUL[t[j].v] do
		local op = t[j].v
		local rhs
		rhs, j = parseFactor(t, j + 1, ctx)
		if lhs and rhs then
			lhs = op == "*" and lhs * rhs or (rhs ~= 0 and lhs / rhs or nil)
		else
			lhs = nil
		end
	end
	return lhs, j
end

parseExpr = function(t, i, ctx)
	local lhs, j = parseTerm(t, i, ctx)
	while t[j] and t[j].t == "op" and (t[j].v == "+" or t[j].v == "-") do
		local op = t[j].v
		local rhs
		rhs, j = parseTerm(t, j + 1, ctx)
		if lhs and rhs then
			lhs = op == "+" and lhs + rhs or lhs - rhs
		else
			lhs = nil
		end
	end
	return lhs, j
end

-- ============ functions ============

local function pickNonNil(args)
	for _, v in ipairs(args) do if v ~= nil then return v end end
end

local FUNCS = {
	min = function(a)
		local r
		for _, v in ipairs(a) do
			if v and (r == nil or v < r) then r = v end
		end
		return r
	end,
	max = function(a)
		local r
		for _, v in ipairs(a) do
			if v and (r == nil or v > r) then r = v end
		end
		return r
	end,
	first = pickNonNil,
	check = function(a)
		local p, lo, hi = a[1], a[2], a[3]
		return (p and lo and hi and p >= lo and p <= hi) and p or nil
	end,
	ifgt  = function(a) if a[1] == nil or a[2] == nil then return a[4] end
		return a[1] > a[2] and a[3] or a[4] end,
	ifgte = function(a) if a[1] == nil or a[2] == nil then return a[4] end
		return a[1] >= a[2] and a[3] or a[4] end,
	iflt  = function(a) if a[1] == nil or a[2] == nil then return a[4] end
		return a[1] < a[2] and a[3] or a[4] end,
	iflte = function(a) if a[1] == nil or a[2] == nil then return a[4] end
		return a[1] <= a[2] and a[3] or a[4] end,
	ifeq  = function(a) if a[1] == nil or a[2] == nil then return a[4] end
		return a[1] == a[2] and a[3] or a[4] end,
	ifle  = function(a) if a[1] == nil or a[2] == nil then return a[4] end
		return a[1] ~= a[2] and a[3] or a[4] end,
	round      = function(a) local n = a[2] or 1
		return a[1] and floor(a[1] / n + 0.5) * n end,
	rounddown  = function(a) return a[1] and floor(a[1]) end,
	roundup    = function(a) return a[1] and ceil(a[1]) end,
	abs        = function(a) return a[1] and abs(a[1]) end,
	convert    = function(a) return a[1] end, -- identity: source already evaluated
	numinventory = function(a, ctx) return SRC.numinventory(ctx.itemID) end,
}

local function callFunc(name, args, ctx)
	local f = FUNCS[name]
	if not f then return nil end
	return f(args, ctx)
end

local function sourceValue(name, itemID, ctx)
	local f = SRC[name]
	if f then return f(itemID) end
	local cs = GoblinMindPrices and GoblinMindPrices.customSources
	local expr = cs and cs[name]
	if not expr then return nil end
	if ctx.visited[name] then return nil end -- cycle
	ctx.visited[name] = true
	local v = ctx.eval(expr, itemID, ctx)
	ctx.visited[name] = nil
	return v
end

-- ============ entry point ============

local function Eval(expr, itemID, ctx)
	if type(expr) ~= "string" or expr == "" then return nil, "empty" end
	local toks, err = Tokenize(expr)
	if not toks then return nil, err end
	ctx = ctx or {}
	ctx.itemID = ctx.itemID or itemID
	ctx.visited = ctx.visited or {}
	ctx.eval = Eval
	ctx.callFunc = callFunc
	ctx.sourceValue = sourceValue
	local v, j = parseExpr(toks, 1, ctx)
	if j <= #toks then return nil, "trailing input" end
	return v
end

function GM.Pricing.Eval(expr, itemID)
	return Eval(expr, itemID, { visited = {} })
end
