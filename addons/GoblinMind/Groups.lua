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
	{ "Duration",        "auctioning", "duration",       "num",  "seg", { opts = { { "12h", 1 }, { "24h", 2 }, { "48h", 3 } } } },
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
