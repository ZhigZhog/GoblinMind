local _, GM = ...

-- GoblinMindGroups SV: groups own items, operations own behavior.
-- Path hierarchy "A/B/C" — op lookup cascades defaults → A → A/B →
-- A/B/C, unset fields inherit (TSM semantics). Price-valued fields are
-- expression strings evaluated by Pricing.lua against the item.

GM.Groups = {}

local OP_DEFAULTS = {
	auctioning = {
		postCap = 0,               -- 0 = no cap
		cancelUndercut = true,     -- also gates the planner's cancel-merge
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

-- { label, opType, field, kind, widget, extra } — shared by GroupsUI's
-- per-group OPS page and OpsUI's named-operation editor.
-- widget: bool | seg{opts} | stepper{min} | num{min,max} | expr | recip
GM.Groups.OP_FIELDS = {
	{ "Min price",       "auctioning", "min",            "expr", "expr" },
	{ "Normal price",    "auctioning", "normal",         "expr", "expr" },
	{ "Max price",       "auctioning", "max",            "expr", "expr" },
	{ "Undercut",        "auctioning", "undercut",       "expr", "expr" },
	{ "Post cap",        "auctioning", "postCap",        "num",  "stepper", { min = 0, tip = "0 = no cap" } },
	{ "Stack size",      "auctioning", "stackSize",      "num",  "stepper", { min = 0, tip = "0 = available stack" } },
	-- L() at the literal site registers the seg labels — a {"label",
	-- number} opt pair is invisible to the locale extractor, and the
	-- table builds before GM.L exists so the identity fallback is
	-- all that's needed here (LT resolves for real at render)
	{ "Duration",        "auctioning", "duration",       "num",  "seg", { opts = { { L("12h"), 1 }, { L("24h"), 2 }, { L("48h"), 3 } } } },
	{ "Bid %",           "auctioning", "bidPercent",     "num",  "num", { min = 0, max = 100 } },
	{ "Cancel under",    "auctioning", "cancelUndercut", "bool", "bool" },
	{ "Buy margin %",    "shopping",   "belowPct",       "num",  "num", { min = 0, max = 100 } },
	{ "Buy max",         "shopping",   "maxPrice",       "expr", "expr" },
	{ "Snipe max",       "sniper",     "belowPrice",     "expr", "expr" },
	{ "Snipe off %",     "sniper",     "belowPct",       "num",  "num", { min = 0, max = 100,
		tip = "fallback discount if price expr doesn't resolve" } },
	{ "Refresh sec",     "sniper",     "refreshTime",    "num",  "num", { min = 120,
		tip = "runtime minimum 120s; scheduler reads Base Group" } },
	{ "Snipe sound",     "sniper",     "sound",          "bool", "bool" },
	{ "Craft cost",      "crafting",   "craftCost",      "expr", "expr" },
	{ "Min profit",      "crafting",   "minProfit",      "expr", "expr" },
	{ "Restock",         "crafting",   "restock",        "bool", "bool" },
	{ "Restock qty",     "crafting",   "restockQty",     "num",  "stepper", { min = 0 } },
	{ "Mail to",         "mailing",    "sendTo",         "text", "recip" },
	{ "Mail keep",       "mailing",    "keepQty",        "num",  "stepper", { min = 0 } },
	{ "Mail max",        "mailing",    "maxQty",         "num",  "stepper", { min = 0, tip = "0 = unlimited" } },
	{ "Mail all",        "mailing",    "sendAll",        "bool", "bool" },
	{ "Move to",         "warehousing","moveTo",         "text", "seg", { opts = { { "Bags", "bags" }, { "Bank", "bank" } } } },
	{ "Bank keep",       "warehousing","keepQty",        "num",  "stepper", { min = 0 } },
	{ "Restore empty",   "warehousing","restoreEmpty",   "bool", "bool" },
	{ "Vendor buy",      "vendoring",  "vendorBuyBelow", "expr", "expr" },
	{ "Auto buy",        "vendoring",  "autoBuy",        "bool", "bool", { tip = "config flag — execution stays one click per action" } },
	{ "Auto sell",       "vendoring",  "autoSell",       "bool", "bool", { tip = "config flag — execution stays one click per action" } },
	{ "Destroy min",     "destroying", "threshold",      "expr", "expr" },
	{ "Destroy max",     "destroying", "belowPrice",     "expr", "expr" },
}

function GM.Groups.Init()
	GoblinMindGroups = GoblinMindGroups or {}
	GoblinMindGroups.groups = GoblinMindGroups.groups or {}
	GoblinMindGroups.operations = GoblinMindGroups.operations or {}
	GM.Groups.db = GoblinMindGroups
	GM.Groups.Ensure("Base Group")
	-- one-time seed: a "Default" op per type carrying the type defaults,
	-- assigned to Base Group so the whole tree inherits it — TSM's
	-- out-of-box model. Flag-gated so user deletes don't resurrect.
	if not GoblinMindGroups.seeded then
		GoblinMindGroups.seeded = true
		local bg = GM.Groups.db.groups["Base Group"]
		bg.opNames = bg.opNames or {}
		for _, t in ipairs(GM.Groups.OP_TYPES) do
			local ops = {}
			for k, v in pairs(OP_DEFAULTS[t] or {}) do ops[k] = v end
			GoblinMindGroups.operations[t] = GoblinMindGroups.operations[t] or {}
			GoblinMindGroups.operations[t].Default = ops
			bg.opNames[t] = "Default"
		end
	end
	-- shipped protected groups — versioned seed, add-only
	GM.Groups.SeedShipped()
end

-- create every ancestor in "A/B/C", return the leaf path
function GM.Groups.Ensure(path)
	local g = GM.Groups.db.groups
	local seg
	for part in (path or ""):gmatch("[^/]+") do
		seg = seg and seg .. "/" .. part or part
		if not g[seg] then
			g[seg] = { items = {}, ops = {} }
			-- new groups carry the Default ops explicitly — still fully
			-- inheritable, but pinned to Default even if Base Group's
			-- own assignment changes later
			local store = GM.Groups.db.operations
			for _, t in ipairs(GM.Groups.OP_TYPES) do
				if store[t] and store[t].Default then
					g[seg].opNames = g[seg].opNames or {}
					g[seg].opNames[t] = "Default"
				end
			end
		end
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

-- shipped protected groups: tools + vendor-bought supplies that should
-- never hit the AH. Seeded once (versioned), add-only, and only claims
-- ungrouped ids — user edits (delete group, unprotect, unassign) stick.
-- IDs verified against TSM's LibTSMData VendorSell.Classic table and
-- the realm's own MapWise vendor survey; raw mats that vendors happen
-- to sell (strange dust, blasting powder, raw fish) are deliberately
-- excluded — they trade legitimately.
GM.Groups.SHIPPED_VERSION = 2 -- v1 shippedV was persisted by a broken run
local SHIPPED_GROUPS = {
	["Crafting Supplies"] = {
		-- profession tools
		5956,   -- Blacksmith Hammer
		2901,   -- Mining Pick
		7005,   -- Skinning Knife
		6219,   -- Arclight Spanner
		10498,  -- Gyromatic Micro-Adjustor
		5060,   -- Thieves' Tools
		6256,   -- Fishing Pole
		6365,   -- Strong Fishing Pole
		273636, -- Chef's Knife (Forever custom)
		276203, -- Primitive Fishing Rod (Forever custom)
		-- smithing / enchanting supplies
		2880,   -- Weak Flux
		3466,   -- Strong Flux
		18567,  -- Elemental Flux
		3857,   -- Coal
		4289,   -- Salt
		6217,   -- Copper Rod
		11291,  -- Star Wood
		4399,   -- Wooden Stock
		4400,   -- Heavy Stock
		-- tailoring supplies
		2320,   -- Coarse Thread
		2321,   -- Fine Thread
		2324,   -- Bleach
		2325,   -- Black Dye
		2604,   -- Red Dye
		2605,   -- Green Dye
		6260,   -- Blue Dye
		6261,   -- Orange Dye
		4340,   -- Gray Dye
		4341,   -- Yellow Dye
		4342,   -- Purple Dye
		10290,  -- Pink Dye
		4291,   -- Silken Thread
		8343,   -- Heavy Silken Thread
		14341,  -- Rune Thread
		-- alchemy / cooking supplies
		3371,   -- Empty Vial
		3372,   -- Leaded Vial
		8925,   -- Crystal Vial
		18256,  -- Imbued Vial
		2678,   -- Mild Spices
		2692,   -- Hot Spices
		3713,   -- Soothing Spices
		2665,   -- Stormwind Seasoning Herbs
		10284,  -- Simple Flour
		17194,  -- Holiday Spices
		-- engineering supplies
		10647,  -- Engineer's Ink
		10648,  -- Blank Parchment
	},
	["Adventuring Supplies"] = {
		-- campfire + holiday vendor goods
		4470,   -- Simple Wood
		4471,   -- Flint and Tinder
		272941, -- Thick Firewood (Forever custom)
		17202,  -- Snowball
		2596,   -- Skin of Dwarven Stout
		2894,   -- Rhapsody Malt
		17196,  -- Holiday Spirits
		5042,   -- Red Ribboned Wrapping Paper
		-- vendor food
		117,    -- Tough Jerky
		2287,   -- Haunch of Meat
		3770,   -- Mutton Chop
		3771,   -- Wild Hog Shank
		4599,   -- Cured Ham Steak
		8952,   -- Roasted Quail
		4540,   -- Tough Hunk of Bread
		4541,   -- Freshly Baked Bread
		4542,   -- Moist Cornbread
		4544,   -- Mulgore Spice Bread
		4601,   -- Soft Banana Bread
		8950,   -- Homemade Cherry Pie
		4536,   -- Shiny Red Apple
		4537,   -- Tel'Abim Banana
		4538,   -- Snapvine Watermelon
		4539,   -- Goldenbark Apple
		4602,   -- Moon Harvest Pumpkin
		8953,   -- Deep Fried Plantains
		4604,   -- Forest Mushroom Cap
		4605,   -- Red-speckled Mushroom
		4606,   -- Spongy Morel
		4607,   -- Delicious Cave Mold
		4608,   -- Raw Black Truffle
		8948,   -- Dried King Bolete
		414,    -- Dalaran Sharp
		422,    -- Dwarven Mild
		1707,   -- Stormwind Brie
		3927,   -- Fine Aged Cheddar
		8932,   -- Alterac Swiss
		4594,   -- Rockscale Cod
		252026, -- Galeberry Cake (Forever custom)
		252027, -- Galeberry Juice
		252029, -- Hippogryph Flank
		252030, -- Tart Sky Cheddar
		252032, -- Red Delicious Storm Apple
		-- vendor drink
		159,    -- Refreshing Spring Water
		1179,   -- Ice Cold Milk
		1205,   -- Melon Juice
		1645,   -- Moonberry Juice
		1708,   -- Sweet Nectar
		8766,   -- Morning Glory Dew
		-- ammunition — vendor grades only; quest/rep/crafted
		-- ammo (Feathered Arrow, Thorium Headed, Ice Threaded)
		-- trades legitimately and stays out
		2512,   -- Rough Arrow
		2515,   -- Sharp Arrow
		3030,   -- Razor Arrow
		11285,  -- Jagged Arrow
		2516,   -- Light Shot
		2519,   -- Heavy Shot
		3033,   -- Solid Shot
		11284,  -- Accurate Slugs
		-- thrown weapons (vendor)
		2946,   -- Balanced Throwing Dagger
		2947,   -- Small Throwing Knife
		3107,   -- Keen Throwing Knife
		3108,   -- Heavy Throwing Dagger
		3111,   -- Crude Throwing Axe
		3131,   -- Weighted Throwing Axe
		3135,   -- Sharp Throwing Axe
		3137,   -- Deadly Throwing Axe
		15326,  -- Gleaming Throwing Axe
		-- class reagents (vendor)
		17020,  -- Arcane Powder
		17021,  -- Wild Berries
		17026,  -- Wild Thornroot
		17028,  -- Holy Candle
		17029,  -- Sacred Candle
		17030,  -- Ankh
		17031,  -- Rune of Teleportation
		17032,  -- Rune of Portals
		17033,  -- Symbol of Divinity
		21177,  -- Symbol of Kings
		17034,  -- Maple Seed
		17035,  -- Stranglethorn Seed
		17036,  -- Ashwood Seed
		17037,  -- Hornbeam Seed
		17038,  -- Ironwood Seed
		17056,  -- Light Feather
		5565,   -- Infernal Stone
		16583,  -- Demonic Figurine
		-- rogue reagents (vendor)
		5140,   -- Flash Powder
		2928,   -- Dust of Decay
		2930,   -- Essence of Pain
		8923,   -- Essence of Agony
		8924,   -- Dust of Deterioration
		5173,   -- Deathweed
	},
}

-- seed shipped groups once — see SHIPPED_GROUPS for provenance
function GM.Groups.SeedShipped()
	local db = GM.Groups.db
	if (db.shippedV or 0) >= GM.Groups.SHIPPED_VERSION then return end
	for path, ids in pairs(SHIPPED_GROUPS) do
		GM.Groups.Ensure(path)
		local g = db.groups[path]
		g.protected = true
		for _, id in ipairs(ids) do
			if not GroupFor(id) then g.items[id] = true end
		end
	end
	db.shippedV = GM.Groups.SHIPPED_VERSION
end

-- protected groups shield member items from sell/post plan steps —
-- post scan excludes them outright; manual sell/post steps on one
-- still get a single confirm click at execution. Inherited down the
-- tree like ops (a protected ancestor protects every descendant)
function GM.Groups.SetProtected(path, flag)
	local g = GM.Groups.db.groups[path]
	if g then g.protected = flag or nil end
end

function GM.Groups.IsProtected(itemID)
	local path = GroupFor(itemID)
	while path do
		local g = GM.Groups.db.groups[path]
		if g and g.protected then return true end
		path = path:match("^(.*)/[^/]+$")
	end
	return false
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
	-- Base Group is the root — every group inherits its ops (TSM semantics)
	if out[1] ~= "Base Group" then tinsert(out, 1, "Base Group") end
	return out
end

-- cascaded op table: OP_DEFAULTS ← each ancestor's assigned named op
-- then that ancestor's anonymous local overrides ← leaf last (TSM
-- semantics: named ops are shared objects, g.ops = per-group custom)
local function Merged(path, opType)
	local out = {}
	for k, v in pairs(OP_DEFAULTS[opType] or {}) do out[k] = v end
	for _, seg in ipairs(ancestors(path or "Base Group")) do
		local g = GM.Groups.db.groups[seg]
		if g then
			local name = g.opNames and g.opNames[opType]
			local op = name and GM.Groups.db.operations[opType]
				and GM.Groups.db.operations[opType][name]
			if op then for k, v in pairs(op) do out[k] = v end end
			if g.ops and g.ops[opType] then
				for k, v in pairs(g.ops[opType]) do out[k] = v end
			end
		end
	end
	return out
end

-- per-field cascade queries — shared by the ops UIs (the OPS tab's
-- named-op editor AND its per-group override mode). OpResolve also
-- reports WHERE the effective value comes from, for the I/O chips.
function GM.Groups.OpRawLocal(path, opType, field)
	local g = GM.Groups.db.groups[path]
	if not (g and g.ops and g.ops[opType]) then return nil end
	return g.ops[opType][field]
end

-- effective value + source: "local", "op:<name>", an ancestor path,
-- or "Defaults". excludeLeaf=true answers "what would reset inherit".
-- Same precedence as Merged: local overrides beat the assigned named
-- op at each cascade level.
function GM.Groups.OpResolve(path, opType, field, excludeLeaf)
	local chain = ancestors(path)
	for i = excludeLeaf and (#chain - 1) or #chain, 1, -1 do
		local v = GM.Groups.OpRawLocal(chain[i], opType, field)
		if v ~= nil then
			return v, (chain[i] == path and not excludeLeaf)
				and "local" or chain[i]
		end
		local name = GM.Groups.OpAssigned(chain[i], opType)
		local op = name and GM.Groups.OpFields(opType, name)
		if op and op[field] ~= nil then
			return op[field], "op:" .. name
				.. (chain[i] ~= path and (" (" .. chain[i] .. ")") or "")
		end
	end
	local d = GM.Groups.OP_DEFAULTS[opType]
	return d and d[field], "Defaults"
end

-- write a per-group local override; nil clears it back to inherit
function GM.Groups.OpSetLocal(path, opType, field, value)
	GM.Groups.Ensure(path)
	local g = GM.Groups.db.groups[path]
	g.ops[opType] = g.ops[opType] or {}
	g.ops[opType][field] = value
end

-- effective NAMED op for a path: leaf's own assignment, else the
-- nearest ancestor's (same order Merged applies). The groups OPS
-- summary + OpsUI group mode both display "which op applies here".
function GM.Groups.OpForPath(path, opType)
	local name
	for _, seg in ipairs(ancestors(path or "Base Group")) do
		local n = GM.Groups.OpAssigned(seg, opType)
		if n then name = n end
	end
	return name
end

-- how many local overrides a group's own ops[opType] table holds
function GM.Groups.OpLocalCount(path, opType)
	local g = GM.Groups.db.groups[path]
	if not (g and g.ops and g.ops[opType]) then return 0 end
	local n = 0
	for _ in pairs(g.ops[opType]) do n = n + 1 end
	return n
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

-- ids with no explicit group — the Base Group's implicit members.
-- Universe is the DB's item set (realm-scoped, flat fallback like
-- GM.ItemEntry): everything it prices that isn't assigned anywhere.
function GM.Groups.UngroupedIds()
	local out = {}
	local db = GoblinMindDB
	if not db then return out end
	local r = db.realms and db.realms[GM.Scope()]
	local t = (r and r.items) or db.items
	if not t then return out end
	for id in pairs(t) do
		if not GroupFor(id) then out[#out + 1] = id end
	end
	return out
end

function GM.Groups.List()
	local out = {}
	for path, g in pairs(GM.Groups.db.groups) do
		local n = 0
		for _ in pairs(g.items) do n = n + 1 end
		-- Base Group's members are the ungrouped set — count the
		-- implicit side too so the tree badge matches MemberList
		if path == "Base Group" then
			n = n + #GM.Groups.UngroupedIds()
		end
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

-- ============ nesting (drag-drop reparent) ============

-- leaf segment of a path
function GM.Groups.Leaf(path)
	return path and path:match("[^/]+$") or path
end

-- move group `path` under `targetPath` (re-nest). targetPath == "Base Group"
-- flattens to top level. Refuses self/descendant drops and leaf-name
-- collisions so no group is silently overwritten.
function GM.Groups.Nest(path, targetPath)
	if not path or path == "Base Group" then
		return nil, "Base Group can't be moved"
	end
	if not targetPath or targetPath == "Base Group" then
		-- dropping on Base Group means "into the root" — top-level groups
		-- are already there, nested ones flatten to top level
		targetPath = nil
		if not path:find("/") then
			return nil, "already inside Base Group"
		end
	elseif targetPath == path
		or targetPath:sub(1, #path + 1) == path .. "/" then
		return nil, "can't nest a group inside itself"
	end
	local leaf = GM.Groups.Leaf(path)
	local new = targetPath and (targetPath .. "/" .. leaf) or leaf
	if new == path then return nil, "already there" end
	if GM.Groups.db.groups[new] then
		return nil, new .. " already exists"
	end
	GM.Groups.Rename(path, new)
	return new
end

-- ============ named operations ============
-- GoblinMindGroups.operations[opType][name] = { field = value } —
-- reusable op objects assigned to groups via g.opNames[opType].
-- Anonymous g.ops tables remain as per-group custom overrides and
-- win over the assigned op at the same cascade level.

local function OpStore(opType)
	local t = GM.Groups.db.operations[opType]
	if not t then
		t = {}
		GM.Groups.db.operations[opType] = t
	end
	return t
end

-- sorted list: { name, users }
function GM.Groups.Ops(opType)
	local users = {}
	for path, g in pairs(GM.Groups.db.groups) do
		local n = g.opNames and g.opNames[opType]
		if n then
			users[n] = users[n] or {}
			users[n][#users[n] + 1] = path
		end
	end
	local out = {}
	for name in pairs(OpStore(opType)) do
		local u = users[name]
		if u then sort(u) end
		out[#out + 1] = { name = name,
			users = u and #u or 0,
			userPaths = u,
			groups = u and table.concat(u, ", ") }
	end
	sort(out, function(a, b) return a.name < b.name end)
	return out
end

function GM.Groups.OpFields(opType, name)
	local store = OpStore(opType)
	return store[name]
end

function GM.Groups.CreateOp(opType, name)
	name = strtrim(name or "")
	if name == "" then return nil, "need a name" end
	if GM.Groups.OpProtected(name) then
		return nil, name .. " is a reserved name"
	end
	local store = OpStore(opType)
	if store[name] then return nil, name .. " already exists" end
	store[name] = {}
	return true
end

-- seeded ops are protected: renaming would let you rename-then-delete,
-- so both are refused. Duplication stays allowed.
function GM.Groups.OpProtected(name)
	return name == "Default"
end

function GM.Groups.RenameOp(opType, old, new)
	new = strtrim(new or "")
	local store = OpStore(opType)
	if not store[old] then return nil, "no such operation" end
	if GM.Groups.OpProtected(old) then
		return nil, "Default operations can't be renamed"
	end
	if new == "" then return nil, "need a name" end
	if GM.Groups.OpProtected(new) then
		return nil, new .. " is a reserved name"
	end
	if store[new] then return nil, new .. " already exists" end
	store[new] = store[old]
	store[old] = nil
	for _, g in pairs(GM.Groups.db.groups) do
		if g.opNames and g.opNames[opType] == old then
			g.opNames[opType] = new
		end
	end
	return true
end

function GM.Groups.DeleteOp(opType, name)
	local store = OpStore(opType)
	if not store[name] then return nil, "no such operation" end
	if GM.Groups.OpProtected(name) then
		return nil, "Default operations can't be deleted"
	end
	store[name] = nil
	for _, g in pairs(GM.Groups.db.groups) do
		if g.opNames and g.opNames[opType] == name then
			g.opNames[opType] = nil
		end
	end
	return true
end

function GM.Groups.DuplicateOp(opType, src, new)
	local store = OpStore(opType)
	if not store[src] then return nil, "no such operation" end
	new = strtrim(new or "")
	if new == "" then new = src .. " copy" end
	local base, i = new, 2
	while store[new] do new = base .. " " .. i i = i + 1 end
	local copy = {}
	for k, v in pairs(store[src]) do copy[k] = v end
	store[new] = copy
	return true, new
end

-- assign (or clear with nil) a named op on a group path
function GM.Groups.AssignOp(path, opType, name)
	GM.Groups.Ensure(path)
	local g = GM.Groups.db.groups[path]
	g.opNames = g.opNames or {}
	if name and not OpStore(opType)[name] then
		return nil, "no such operation"
	end
	g.opNames[opType] = name
	return true
end

function GM.Groups.OpAssigned(path, opType)
	local g = GM.Groups.db.groups[path]
	return g and g.opNames and g.opNames[opType]
end

-- ============ import / export ============

-- TSM group paths are backtick-separated ("Tailoring`Bags"); `` is an
-- escaped literal comma. Ours use "/".
local function TsmToGmPath(p)
	if not p or p == "" then return "Base Group" end
	p = p:gsub("``", "\1"):gsub("`", "/"):gsub("\1", ",")
	return p
end

GM.Groups.TsmToGmPath = TsmToGmPath

local function GmToTsmPath(p)
	return (p:gsub(",", "``"):gsub("/", "`"))
end

-- TSM-legacy group-list format — the same comma format TSM itself reads,
-- so this string round-trips into both addons:
--   i:2589,group:Tailoring`Bags,i:4238,group:Tailoring,i:2592
function GM.Groups.ExportString()
	local parts = {}
	for id in GM.Groups.IterateItems("Base Group") do
		parts[#parts + 1] = "i:" .. id
	end
	local ids = {}
	for _, g in ipairs(GM.Groups.List()) do
		if g.path ~= "Base Group" then
			parts[#parts + 1] = "group:" .. GmToTsmPath(g.path)
			wipe(ids)
			for id in GM.Groups.IterateItems(g.path) do
				ids[#ids + 1] = id
			end
			sort(ids)
			for _, id in ipairs(ids) do
				parts[#parts + 1] = "i:" .. id
			end
		end
	end
	return table.concat(parts, ",")
end

-- new TSM format: LibSerialize payload → deflate → EncodeForPrint. We
-- ride TSM's embedded libs via LibStub while they're installed.
local function TryTsmBlob(str)
	if not (LibStub and C_EncodingUtil) then return end
	local ok1, deflate = pcall(LibStub, "LibDeflate")
	local ok2, libser = pcall(LibStub, "LibSerialize")
	if not (ok1 and ok2 and deflate and libser) then return end
	local raw = deflate:DecodeForPrint(str)
	if not raw then return end
	local ok, dec = pcall(C_EncodingUtil.DecompressString, raw)
	if not (ok and dec) then return end
	-- Deserialize returns (success, values...) — index past the flag
	local dsok, ok2, magic, ver, groupName, items, groups =
		pcall(libser.Deserialize, libser, dec)
	if not (dsok and ok2 and magic == "TSM_EXPORT"
		and type(items) == "table") then
		return
	end
	local out = {}
	for is, tp in pairs(items) do
		local id = is:match("^i:(%d+)") or is:match("^(%d+)")
		if id then out[tonumber(id)] = TsmToGmPath(tp) end
	end
	return out
end

-- TSM-legacy list + generic fallbacks: "group:Path`Sub" tags, i:1234 /
-- p:/itemstring parts, semicolon-separated lists, bare "1234,5678" ids.
local function ParseLegacy(str)
	if str:match("^[ip0-9%-:;%s]+$") and not str:find(",") then
		str = str:gsub(";", ",")
	end
	if str:match("^[0-9,%s]+$") then
		str = str:gsub("[0-9]+", "i:%1")
	end
	local rel = "Base Group"
	local out = {}
	for raw in str:gmatch("[^,]+") do
		local part = strtrim(raw)
		if part ~= "" then
			local gp = part:match("^group:(.+)$")
			local is = part:match("^[ip]?:?[0-9%-:]+$")
			if gp then
				rel = TsmToGmPath(gp)
			elseif is then
				local id = is:match("(%d+)")
				if id and not is:match("^p:") then
					out[tonumber(id)] = rel
				end
			else
				return nil, "unrecognized part: " .. part
			end
		end
	end
	if not next(out) then return nil, "no items found" end
	return out
end

-- returns true,itemCount or nil,err
function GM.Groups.Import(str)
	str = strtrim(str or "")
	if str == "" then return nil, "nothing to import" end
	local map = TryTsmBlob(str)
	local err
	if not map then map, err = ParseLegacy(str) end
	if not map then return nil, err or "unrecognized format" end
	local n = 0
	for id, path in pairs(map) do
		GM.Groups.Assign(id, GM.Groups.Ensure(path))
		n = n + 1
	end
	return true, n
end
