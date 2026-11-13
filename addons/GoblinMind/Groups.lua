local _, GM = ...

-- GoblinMindGroups SV: groups own items, operations own behavior.
-- Path hierarchy "A/B/C" — op lookup cascades defaults → A → A/B →
-- A/B/C, unset fields inherit (TSM semantics). Price-valued fields are
-- expression strings evaluated by Pricing.lua against the item.

GM.Groups = {}

local OP_DEFAULTS = {
	auctioning = {
		postCap = 0,               -- 0 = no cap
		cancelUndercut = false,
		min = "100% vendorsell",
		normal = "100% dbmarket",
		max = "500% dbmarket",
		undercut = "1c",
		duration = 2,              -- 1=12h 2=24h 3=48h
		stackSize = 0,             -- 0 = whole stack
		bidPercent = 100,
		resetMethod = "none",
	},
	shopping = { maxPrice = "100% dbmarket", belowPct = 10, showAboveMax = false },
	sniper = { belowPrice = "80% dbmarket", belowPct = 20, refreshTime = 60, sound = true },
	crafting = { restock = false, restockQty = 1, minProfit = "1c", craftCost = "100% matprice" },
	mailing = { sendTo = "", keepQty = 0, maxQty = 0, sendAll = false },
	vendoring = { autoBuy = false, autoSell = false, vendorBuyBelow = "50% vendorsell" },
	warehousing = { moveTo = "bags", keepQty = 0, restoreEmpty = false },
	destroying = { threshold = "1g", belowPrice = "50% dbmarket" },
}
GM.Groups.OP_DEFAULTS = OP_DEFAULTS
GM.Groups.OP_TYPES = { "auctioning", "shopping", "sniper", "crafting",
	"mailing", "vendoring", "warehousing", "destroying" }

function GM.Groups.Init()
	GoblinMindGroups = GoblinMindGroups or {}
	GoblinMindGroups.groups = GoblinMindGroups.groups or {}
	GM.Groups.db = GoblinMindGroups
	GM.Groups.Ensure("Base Group")
end

-- create every ancestor in "A/B/C", return the leaf path
function GM.Groups.Ensure(path)
	local g = GM.Groups.db.groups
	local seg
	for part in (path or ""):gmatch("[^/]+") do
		seg = seg and seg .. "/" .. part or part
		if not g[seg] then g[seg] = { items = {}, ops = {} } end
		g[seg].items = g[seg].items or {}
		g[seg].ops = g[seg].ops or {}
	end
	return seg
end

local function GroupFor(itemID)
	for path, g in pairs(GM.Groups.db.groups) do
		if g.items[itemID] then return path end
	end
end
GM.Groups.GroupForItem = GroupFor

function GM.Groups.Assign(itemID, path)
	local target = GM.Groups.Ensure(path)
	if not target then return end
	for _, g in pairs(GM.Groups.db.groups) do g.items[itemID] = nil end
	GM.Groups.db.groups[target].items[itemID] = true
end

function GM.Groups.Unassign(itemID)
	for _, g in pairs(GM.Groups.db.groups) do g.items[itemID] = nil end
end

-- delete a group subtree — member items become ungrouped (TSM semantics)
function GM.Groups.Delete(path)
	if not path or path == "Base Group" then return end
	for p in pairs(GM.Groups.db.groups) do
		if p == path or p:sub(1, #path + 1) == path .. "/" then
			GM.Groups.db.groups[p] = nil
		end
	end
end

-- move a whole subtree to a new path (items + ops travel with it)
function GM.Groups.Rename(old, new)
	if not (old and new) or old == "Base Group" or old == new then return end
	local moves = {}
	for p, g in pairs(GM.Groups.db.groups) do
		if p == old or p:sub(1, #old + 1) == old .. "/" then
			moves[#moves + 1] = { p, g, new .. p:sub(#old + 1) }
		end
	end
	for _, m in ipairs(moves) do
		GM.Groups.db.groups[m[3]] = m[2]
		if m[3] ~= m[1] then GM.Groups.db.groups[m[1]] = nil end
	end
	return new
end

local function ancestors(path)
	local out, seg = {}, nil
	for part in path:gmatch("[^/]+") do
		seg = seg and seg .. "/" .. part or part
		out[#out + 1] = seg
	end
	return out
end

-- cascaded op table: OP_DEFAULTS ← each ancestor ← leaf group
local function Merged(path, opType)
	local out = {}
	for k, v in pairs(OP_DEFAULTS[opType] or {}) do out[k] = v end
	for _, seg in ipairs(ancestors(path or "Base Group")) do
		local ops = GM.Groups.db.groups[seg] and GM.Groups.db.groups[seg].ops
		if ops and ops[opType] then
			for k, v in pairs(ops[opType]) do out[k] = v end
		end
	end
	return out
end

function GM.Groups.GetOps(itemID, opType)
	return Merged(itemID and GroupFor(itemID) or "Base Group", opType)
end

function GM.Groups.GetOpsForPath(path, opType)
	return Merged(path, opType)
end

-- expression-valued field → copper for this item; numerics pass through
function GM.Groups.EvalOp(ops, field, itemID)
	local v = ops[field]
	if type(v) == "string" then return GM.Pricing.Eval(v, itemID) end
	return v
end

function GM.Groups.List()
	local out = {}
	for path, g in pairs(GM.Groups.db.groups) do
		local n = 0
		for _ in pairs(g.items) do n = n + 1 end
		out[#out + 1] = { path = path, n = n }
	end
	table.sort(out, function(a, b) return a.path < b.path end)
	return out
end

function GM.Groups.IterateItems(path)
	local g = GM.Groups.db.groups[path]
	local ids = {}
	if g then for id in pairs(g.items) do ids[#ids + 1] = id end end
	local i = 0
	return function() i = i + 1 return ids[i] end
end
