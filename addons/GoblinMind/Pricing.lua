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
	if key == "vendorbuy" then
		-- lives on the DB, not per-item — emitted from TSM's
		-- VendorSell.Retail table
		local vb = GoblinMindDB and GoblinMindDB.vendorBuy
		return vb and vb[itemID] or nil
	end
	local field = KEYMAP[key]
	local v = entry and field and entry[field]
	if v == nil and (key == "dbmarket" or key == "marketvalue") then
		-- p derives from marketValue → marketValueRecent → fallbacks
		v = entry and entry.p or GM.TSMMarket(itemID)
	end
	return v
end

-- THE one vendor-sell-price read — GetItemInfo field 11, copper or
-- nil when unreadable/unsellable. Every "what a merchant pays for
-- this item" lookup routes here (tooltip lines, vendor floors,
-- ledger sell provisionals); never open-code select(11, GetInfo).
function GM.VendorSellPrice(id)
	local v = GetInfo and select(11, GetInfo(id))
	return v and v > 0 and v or nil
end

-- what one unit is worth to a farmer, the GoldScout way: grays are
-- vendor trash — sell price only, never an auction quote. Everything
-- else takes the LOWER of min-buyout and market floored at vendor
-- sell — a fantasy listing can never beat the guaranteed price a
-- vendor always pays. THE one farm-value policy — ctx.value, zone
-- records, and farm-EV math all read this.
function GM.FarmValue(id)
	local quality, sell = GM.ItemQuality(id), GM.VendorSellPrice(id)
	-- index 11 is sellPrice on standard clients — on Forever it
	-- sometimes returns an unrelated field (appearance/spell ids
	-- land in the millions). Nothing a farm mob drops legitimately
	-- vendors above 5g, so the floor caps there — a garbage field
	-- can never price a drop again
	if sell and sell > 50000 then sell = nil end
	if quality == 0 then return sell end
	local a = GM.Price("dbminbuyout", id)
	local b = GM.Price("dbmarket", id)
	-- a lone min-buyout with NO market history is an asking price,
	-- not a price — one dreamer listing a custom item at 3000g is
	-- not a farm value. Corroborated quotes use the lower bound;
	-- unvalidated mb caps at 50g
	local best
	if a and b then best = min(a, b)
	elseif a then best = min(a, 500000)
	else best = b end
	if sell and sell > (best or 0) then return sell end
	return best or sell
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
	vendorsell          = function(id) return GM.VendorSellPrice(id) end,
	vendorbuy           = function(id)
		-- emitted by the brain from TSM's VendorSell.Retail table —
		-- the TSM4 custom-price API doesn't register 'vendorbuy'
		local vb = GoblinMindDB and GoblinMindDB.vendorBuy
		return vb and vb[id] or nil
	end,
	numinventory        = function(id) return GM.Inventory.Count(id).total end,
	-- accounting-derived — real values arrive with the ledger (M1.B)
	avgbuy              = function(id) return GM.Ledger and GM.Ledger.Avg(id, "buy") end,
	smartavgbuy         = function(id) return GM.Ledger and GM.Ledger.Avg(id, "buy") end,
	avgsell             = function(id) return GM.Ledger and GM.Ledger.Avg(id, "sell") end,
	avgpaid             = function(id) return GM.Ledger and GM.Ledger.Avg(id, "paid") end,
	avgminbuyout        = function(id) return GM.Ledger and GM.Ledger.Avg(id, "minbuy") end,
	-- crafting — Part 7: recipe capture feeds these via Crafting.lua
	crafting            = function(id)
		local rid = GM.Crafting and GM.Crafting.RecipeForItem and GM.Crafting.RecipeForItem(id)
		return rid and GM.Crafting.MatCost(rid) or nil
	end,
	matprice            = function(id)
		return GM.Crafting and GM.Crafting.MatPrice and GM.Crafting.MatPrice(id)
			or nil
	end,
	-- disenchant EV is ours now — Destroying.DisenchantEV runs the
	-- vanilla ilvl-bracket table (dust/essence/shard/nexus) priced
	-- from dbmarket; TSM's per-item destroy table still wins when
	-- installed and higher
	disenchant          = function(id)
		return GM.Destroying and GM.Destroying.DisenchantEV
			and GM.Destroying.DisenchantEV(id) or nil
	end,
	destroy             = function(id)
		local best = GM.VendorSellPrice(id)
		local de = GM.Destroying and GM.Destroying.DisenchantEV
			and GM.Destroying.DisenchantEV(id)
		if de and (not best or de > best) then best = de end
		-- TSM's per-item destroy covers mill/prospect/transform too —
		-- none exist on Forever, so only trust it where the item is
		-- actually disenchantable (else herbs flicker mill-EV in)
		if TSMAPI_FOUR and TSMAPI_FOUR.CustomPrice
			and GM.Destroying and GM.Destroying.DisenchantDrops
			and GM.Destroying.DisenchantDrops(id) then
			local ok, v = pcall(TSMAPI_FOUR.CustomPrice.GetValue,
				"destroy", "i:" .. id)
			if ok and type(v) == "number" and v > 0 and (not best or v > best) then
				best = v
			end
		end
		return best
	end,
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
			-- TSM postfix percent: "120% X" means 1.2 * X — fold to a
			-- literal + explicit multiply (bare % is not an operator
			-- here; modulo has no TSM meaning). Money-unit literals
			-- ("1g50%") are left alone — nonsense either way.
			if unit == "" and s:sub(i, i) == "%" then
				toks[#toks].v = toks[#toks].v / 100
				tinsert(toks, { t = "op", v = "*" })
				i = i + 1
			end
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
