local _, GM = ...

-- Gathering spine — tracks all four gather kinds, models them, and
-- answers "what loop / which zone is worth my time". Herb + mine are
-- POINT resources: cast -> loot gives a fixed node spot, and the
-- solver builds the max-GPM circuit through known spawns. Skinning
-- and cloth are AREA resources: kill time, not travel time, so they
-- model as hunt zones (centroid + radius + kills/min) instead of
-- routes. Passive feature — zero protected calls.
--
-- Design authority: WoWVault/Proposals/gathering-proposal.md.
-- Position/quirk knowledge: MapWise-verified UnitPosition 4-return
-- (north, west, z, continent) + native waypoint stack, all pcall'd.

GM.Gather = {}
local G = GM.Gather

GoblinMindGather = GoblinMindGather or {}
local db = GoblinMindGather

-- ======================== constants ========================

-- cast spellIDs verified on Forever per the proposal (GatherLite);
-- name fallback below because Forever can omit spellID on cast info
local CAST_KIND = { [2383] = "herb", [2580] = "mine", [8613] = "skin" }
local CAST_NAME = {
	herb = "herb gathering", mine = "mining", skin = "skinning",
}

-- hunt = the mob-farm kind — no cast; every non-gather loot window
-- is a kill event. Meat, cloth, greens, quest drops: all yield data
-- lands on the zone so targeting can find producers of anything.
-- (Was cloth-only at first — a camp dropping cloth AND meat split
-- into two overlapping zones until the kind unified.)
G.KIND_COLOR = {
	herb = { 0.2, 0.9, 0.3 }, mine = { 0.95, 0.7, 0.2 },
	skin = { 0.7, 0.45, 0.25 }, hunt = { 0.9, 0.4, 0.2 },
	cloth = { 0.85, 0.85, 0.95 }, -- legacy zone rows
}
G.KINDS = { "herb", "mine", "skin", "hunt", "cloth" }
-- node kinds build routes; area kinds build zones
G.NODE_KINDS = { herb = true, mine = true }
G.AREA_KINDS = { skin = true, hunt = true, cloth = true }

local WINDOW_SEC = 3        -- gather cast -> loot attribution window
local NODE_MERGE_YD = 40    -- same spawn point within this radius
local ZONE_MERGE_YD = 150   -- kills this close join one farm zone
local LINK_YD = 250         -- route-solver component link distance
local DEFAULT_YPU = 1500    -- yards per normalized map unit (fallback)
local GATHER_SEC = 2.5      -- gather cast + loot time per stop
local RESPAWN_PRIOR = 900   -- node respawn prior (learned bound wins)
local ARRIVE_YD = 20        -- waypoint advance radius
local ACTIVE_GAP = 90       -- kills this close = same farm session
local POCKET_YD = 30        -- kills within this = same mob spawn
local MOB_RESPAWN_PRIOR = 180 -- classic open-world respawn guess
local RESPAWN_OBS_MIN = 45  -- rekill gaps under this carry no info
local KILL_RATE_PRIOR = 3   -- kills/min before a zone has data

-- transport modes (yards/sec) — the GPM model's travel cost;
-- db.speedIx picks which the solver assumes
G.SPEEDS = {
	{ key = "run",   name = "on foot",      yps = 7.0 },
	{ key = "mount", name = "mount +60%",   yps = 11.2 },
	{ key = "epic",  name = "mount +100%",  yps = 14.0 },
}

local tinsert = table.insert
local floor, sqrt = math.floor, math.sqrt
local max, min = math.max, math.min

function G.SecondsText(s)
	if not s then return "?" end
	if s < 60 then return format("%ds", floor(s)) end
	return format("%dm%02ds", floor(s / 60), floor(s % 60))
end

-- ======================== position ========================

-- UnitPosition on Forever: (north, west, z, continent) — real yards.
-- Map coords come from the native projection when it exists.
local function PosNow()
	local ok, n, w, z, c = pcall(UnitPosition, "player")
	if not ok or type(n) ~= "number" or n == 0 then return nil end
	local p = { n = n, w = w, z = z or 0, c = c or 0 }
	if C_Map and C_Map.GetBestMapForUnit then
		local okM, mapID = pcall(C_Map.GetBestMapForUnit, "player")
		if okM and mapID then
			p.map = mapID
			if C_Map.GetMapPosFromWorldPos and CreateVector2D then
				local okP, mid, mpos = pcall(
					C_Map.GetMapPosFromWorldPos, c,
					CreateVector2D(n, w), mapID)
				if okP and mpos and mpos.x and mpos.y
					and mpos.x >= 0 and mpos.x <= 1
					and mpos.y >= 0 and mpos.y <= 1 then
					p.x, p.y = mpos.x, mpos.y
				end
			end
		end
	end
	return p
end

-- yards between two recorded positions; world coords win, else map
-- distance scaled by a zone-size fallback (honest approximation —
-- terrain detours aren't modeled)
local function DistYd(a, b)
	if a.n and b.n and a.c == b.c then
		local dn, dw = a.n - b.n, a.w - b.w
		return sqrt(dn * dn + dw * dw)
	end
	if a.x and b.x and a.map == b.map then
		local dx, dy = a.x - b.x, a.y - b.y
		return sqrt(dx * dx + dy * dy) * DEFAULT_YPU
	end
end

-- ======================== records ========================

local function NodeList(map)
	if not map then return nil end
	db.nodes = db.nodes or {}
	db.nodes[map] = db.nodes[map] or {}
	return db.nodes[map]
end

local function ZoneList(map)
	if not map then return nil end
	db.zones = db.zones or {}
	db.zones[map] = db.zones[map] or {}
	return db.zones[map]
end
G.NodeList = NodeList
G.ZoneList = ZoneList

-- re-gather at a known point = a respawn upper bound; keep the
-- fastest observed per map+kind (contested zones bias it long —
-- honest error, noted in the UI)
local function LearnRespawn(map, kind, sec)
	if sec < 30 or sec > 86400 then return end
	db.resp = db.resp or {}
	db.resp[map] = db.resp[map] or {}
	local cur = db.resp[map][kind]
	if not cur or sec < cur then db.resp[map][kind] = floor(sec) end
end

function G.RespawnSec(map, kind)
	return db.resp and db.resp[map] and db.resp[map][kind]
		or RESPAWN_PRIOR
end

local function MergeNode(p, kind, name, opt)
	local list = NodeList(p.map)
	if not list then return nil end
	local now = time()
	local mergeYd = opt and opt.mergeYd or NODE_MERGE_YD
	-- stamp=false marks imports: they don't touch `last` (respawn
	-- dimming + learn bounds come from real hits only)
	local stamp = not opt or opt.stamp ~= false
	for _, nd in ipairs(list) do
		if nd.kind == kind then
			local d = DistYd(nd, p)
			if d and d <= mergeYd then
				if nd.last and stamp then
					LearnRespawn(p.map, kind, now - nd.last)
				end
				nd.hits = (nd.hits or 0) + 1
				if stamp then nd.last = now end
				if name then nd.name = name end
				return nd
			end
		end
	end
	local nd = {
		map = p.map, x = p.x, y = p.y,
		n = p.n, w = p.w, z = p.z, c = p.c,
		kind = kind, name = name, hits = 1,
	}
	if stamp then nd.last = now end
	tinsert(list, nd)
	return nd
end

-- running total of qty per item + event count, on whatever table
-- gets .items/.cnt (yield record or zone record). The counter is
-- `cnt`, NOT `n` — `n` is already the north-coord field on every
-- position record
local function UpdateYield(rec, items)
	rec.items = rec.items or {}
	rec.hits = rec.hits or {}
	for id, qty in pairs(items) do
		rec.items[id] = (rec.items[id] or 0) + qty
		-- events containing the item (vs qty) — one-off drops get
		-- hits=1 so sustained EV can exclude lottery income
		rec.hits[id] = (rec.hits[id] or 0) + 1
	end
	rec.cnt = (rec.cnt or 0) + 1
end

local function YieldRec(key)
	db.yields = db.yields or {}
	local y = db.yields[key]
	if not y then y = { items = {}, cnt = 0 } db.yields[key] = y end
	return y
end

-- each kill lands in a "pocket" — a cluster ~1 mob spawn. Pocket
-- count caps a camp's sustainable kill rate (can't kill more mobs
-- than exist), and re-killing a pocket after a gap bounds respawn:
-- the mob was back, so respawn <= the observed gap.
local function MergePocket(zn, p)
	if not (p.x or p.n) then return end
	zn.pockets = zn.pockets or {}
	local best, bd
	for _, pk in ipairs(zn.pockets) do
		local d = DistYd(p, pk)
		if d and d <= (bd or POCKET_YD) then best, bd = pk, d end
	end
	if not best then
		best = { map = zn.map,
			x = p.x, y = p.y, n = p.n, w = p.w, c = p.c }
		tinsert(zn.pockets, best)
	end
	local now = GetTime()
	if best.last then
		local gap = now - best.last
		if gap >= RESPAWN_OBS_MIN then
			zn.resp = min(zn.resp or 9e9, gap)
		end
	end
	best.last = now
end

local function MergeZone(p, kind, items)
	local list = ZoneList(p.map)
	if not list then return nil end
	local now = GetTime()
	for _, zn in ipairs(list) do
		if zn.kind == kind then
			local d = DistYd(zn, p)
			if d and d <= max(ZONE_MERGE_YD, (zn.r or 0)) then
				-- kills < ACTIVE_GAP apart = one farming session —
				-- the zone's rate is kills per active second, so
				-- breaks don't dilute it
				if zn.lastGT and now - zn.lastGT < ACTIVE_GAP then
					zn.activeT = (zn.activeT or 0)
						+ (now - zn.lastGT)
				end
				zn.lastGT = now
				zn.kills = (zn.kills or 0) + 1
				UpdateYield(zn, items)
				MergePocket(zn, p)
				if d > (zn.r or 0) then zn.r = floor(d + 25) end
				return zn
			end
		end
	end
	local zn = {
		map = p.map, x = p.x, y = p.y,
		n = p.n, w = p.w, z = p.z, c = p.c,
		kind = kind, r = 60, kills = 1,
		activeT = 0, lastGT = now, items = {}, cnt = 0,
		pockets = {},
	}
	UpdateYield(zn, items)
	MergePocket(zn, p)
	tinsert(list, zn)
	return zn
end

-- ======================== EV model ========================

local function Price(id)
	return GM.Price and GM.Price("dbmarket", id)
end

-- EV of one event from a running-mean record: total qty seen over
-- events counted. Unpriced items contribute zero — never a guess.
local function ItemsEV(rec, common)
	if not rec or not rec.items or not rec.cnt or rec.cnt == 0 then
		return nil
	end
	local ev = 0
	for id, qty in pairs(rec.items) do
		-- common = repeatable income: seen in 2+ kill events (or
		-- qty>=2 on records that predate per-item hit tracking)
		local h = rec.hits and rec.hits[id]
		if not common or (h and h >= 2) or (not h and qty >= 2) then
			ev = ev + (Price(id) or 0) * (qty / rec.cnt)
		end
	end
	return ev
end

-- EV of one visit to a node: observed yields beat the static loot
-- table (Gathering.lua's NODES), which beats zero.
local function NodeEV(nd)
	local key = nd.name or nd.kind
	local y = db.yields and db.yields[key]
	local ev = ItemsEV(y)
	if ev then return ev end
	local stat = GM.Gathering and GM.Gathering.nodes
		and GM.Gathering.nodes[key]
	if stat then
		local t = 0
		for _, d in ipairs(stat) do
			t = t + (Price(d.id) or 0) * (d.lo + d.hi) / 2
				* d.pct / 100
		end
		return t
	end
	return 0
end

-- EV per kill at a zone
local function ZoneEV(zn)
	return ItemsEV(zn) or 0
end

-- kills/min a zone sustains: measured active rate when observed,
-- else the kill+loot+walk prior
local function ZoneRate(zn)
	if zn.activeT and zn.activeT > 30 and zn.kills > 3 then
		return zn.kills / (zn.activeT / 60)
	end
	return KILL_RATE_PRIOR
end

-- the camp's physical ceiling: pockets / respawn. nil until we've
-- seen multiple spawn pockets (can't cap a rate we can't bound)
function G.ZoneCapacity(zn)
	local np = #(zn.pockets or {})
	if np < 2 then return nil end
	return np * 60 / (zn.resp or MOB_RESPAWN_PRIOR)
end

-- what a farmer actually sustains here: grinding rate capped by
-- spawn capacity, then derated for competition
function G.ZoneSusRate(zn)
	local rate = ZoneRate(zn)
	local cap = G.ZoneCapacity(zn)
	if cap then rate = min(rate, cap) end
	return rate * G.ContF()
end

G.ZoneRate = ZoneRate
G.ZoneEV = ZoneEV
-- repeatable per-kill EV — drops the one-shot lottery items
function G.ZoneSusEV(zn)
	return ItemsEV(zn, true) or 0
end

-- display item for a node/zone: the most valuable thing it drops.
-- itemIDs picked for guaranteed presence on this client
local KIND_ICON_ITEM = {
	herb = 765, mine = 2770, skin = 2318, cloth = 2589,
}
local function BestYieldItem(items)
	local best, bv
	for id, qty in pairs(items or {}) do
		local v = (Price(id) or 0) * qty
		if not bv or v > bv then best, bv = id, v end
	end
	return best
end
function G.NodeIconID(nd)
	local y = db.yields and db.yields[nd.name or nd.kind]
	return (y and BestYieldItem(y.items))
		or KIND_ICON_ITEM[nd.kind]
end
function G.ZoneIconID(zn)
	return BestYieldItem(zn.items) or KIND_ICON_ITEM[zn.kind]
end

-- ======================== target ========================
-- one farmable at a time: an itemID the player is after (raptor
-- flesh, copper, linen). Producers stay bright, everything else
-- dims — pane + leaderboard both read this.
function G.SetTarget(id)
	db.target = id
end
function G.TargetID()
	return db.target
end

local function Produces(items, id)
	return id and items and (items[id] or 0) > 0
end

-- does this node yield the target? observed yields first, then the
-- static loot table (Gathering.lua) as the never-farmed fallback
function G.NodeTargets(nd, id)
	id = id or db.target
	if not id then return true end
	local y = db.yields and db.yields[nd.name or nd.kind]
	if Produces(y and y.items, id) then return true end
	local stat = GM.Gathering and GM.Gathering.nodes
		and GM.Gathering.nodes[nd.name or nd.kind]
	if stat then
		for _, d in ipairs(stat) do
			if d.id == id then return true end
		end
	end
	return false
end

function G.ZoneTargets(zn, id)
	id = id or db.target
	if not id then return true end
	return Produces(zn.items, id)
end

-- does a leaderboard row produce the target? rows carry either
-- .stops (routes — any stop counts) or .zone (hunt zones)
function G.RowTargets(r, id)
	id = id or db.target
	if not id then return true end
	if r.area then return G.ZoneTargets(r.zone, id) end
	for _, s in ipairs(r.stops or {}) do
		if G.NodeTargets(s, id) then return true end
	end
	return false
end

-- ======================== GatherLite import ========================

local GL_KIND = { mining = "mine", herbalism = "herb" }
local GL_MERGE_YD = 8   -- import dedup: tighter than live-merge so
                        -- legit adjacent spawn points stay separate

-- display name for an imported node: object->locale name via
-- GatherLite's own tables (matches our static loot keys), else the
-- first observed loot item's name, else the kind
local function GLNodeName(e)
	if GatherLite and e.object then
		local ok, obj = pcall(
			GatherLite.GetNodeObject, GatherLite, e.object)
		if ok and obj and obj.name
			and GatherLite.translate then
			local okT, nm = pcall(GatherLite.translate,
				GatherLite, "node." .. obj.name)
			if okT and nm and nm ~= "node." .. obj.name then
				return nm
			end
		end
	end
	local l = e.loot and e.loot[1]
	return l and l.name
end

local function GLImportOne(e, kind)
	if type(e) ~= "table" or not e.mapID or not e.posX
		or not e.posY or e.posX < 0 or e.posX > 1 then
		return "skip"
	end
	-- map coords only — GatherLite's worldX/Y come from a different
	-- frame than our UnitPosition n,w; mixing them corrupts DistYd
	local before = #(db.nodes[e.mapID] or {})
	local nd = MergeNode({ map = e.mapID, x = e.posX, y = e.posY },
		kind, GLNodeName(e), { mergeYd = GL_MERGE_YD, stamp = false })
	if not nd then return "skip" end
	nd.src = nd.src or "gl"
	-- observed loot seeds the yield record under the node's name
	local items
	for _, l in ipairs(e.loot or {}) do
		local id = l.link and tonumber((l.link or ""):match("item:(%d+)"))
		if id then
			items = items or {}
			items[id] = (items[id] or 0) + (l.count or 1)
		end
	end
	if items then UpdateYield(YieldRec(nd.name or kind), items) end
	return #(db.nodes[e.mapID] or {}) > before and "new" or "merged"
end

-- personal history from GatherLiteSettings (SV — survives even if
-- GatherLite is off) + whatever it has loaded at runtime (the
-- predefined spawn DB when its tracking enables it). Previous
-- imports are stripped first so re-running picks up DB changes;
-- src="gl" is the marker. Returns counts for reporting.
function G.ImportGatherLite()
	local stats = { new = 0, merged = 0, skipped = 0, wiped = 0 }
	local sv = GatherLiteSettings
		and GatherLiteSettings.global
		and GatherLiteSettings.global.nodes
	local rt = GatherLite and GatherLite.GetNodes
	if not sv and not rt then
		return nil, "no GatherLite data found"
	end
	-- strip prior imports (hits>1 nodes keep their learned data —
	-- they get re-merged anyway on repeat import)
	for map, list in pairs(db.nodes or {}) do
		for i = #list, 1, -1 do
			if list[i].src == "gl" and (list[i].hits or 0) <= 1 then
				tremove(list, i)
				stats.wiped = stats.wiped + 1
			end
		end
	end
	if sv then
		for cat, list in pairs(sv) do
			local kind = GL_KIND[cat]
			if kind and type(list) == "table" then
				for _, e in ipairs(list) do
					local r = GLImportOne(e, kind)
					if r == "new" then stats.new = stats.new + 1
					elseif r == "merged" then stats.merged = stats.merged + 1
					else stats.skipped = stats.skipped + 1 end
				end
			end
		end
	end
	if rt then
		local ok, list = pcall(GatherLite.GetNodes, GatherLite)
		if ok and type(list) == "table" then
			for _, e in ipairs(list) do
				local kind = GL_KIND[e.type]
				if kind then
					local r = GLImportOne(e, kind)
					if r == "new" then stats.new = stats.new + 1
					elseif r == "merged" then stats.merged = stats.merged + 1
					else stats.skipped = stats.skipped + 1 end
				end
			end
		end
	end
	if GM.GatherMap then GM.GatherMap.Refresh() end
	return stats
end

function G.ZoneName(map)
	if C_Map and C_Map.GetMapInfo then
		local ok, info = pcall(C_Map.GetMapInfo, map)
		if ok and info and info.name then return info.name end
	end
	return "map " .. tostring(map)
end

-- the map the player is standing in (solver + UI context)
function G.CurrentMap()
	local p = PosNow()
	return p and p.map or nil
end

-- transport-mode index the solver assumes (cycled in the UI)
function G.SpeedIx()
	return db.speedIx or 2
end

-- contention: the share of a camp's spawns you actually get when
-- other players farm the same ground. Manual — the client can't
-- see other farmers' kills — and it derates every GPM uniformly
G.CONTS = {
	{ name = "solo", f = 1.0 },
	{ name = "shared", f = 0.6 },
	{ name = "contested", f = 0.4 },
	{ name = "packed", f = 0.25 },
}
function G.ContIx()
	return db.contIx or 1
end
function G.ContF()
	return G.CONTS[G.ContIx()].f
end

-- ======================== route solver ========================

-- loop stats under the respawn-saturation model: when a lap runs
-- faster than nodes come back, only the elapsed fraction of stops
-- is expected to be up again — steady-state availability is
-- min(1, lapSec/respawn). This is what lets a tight circuit of
-- rich spawns beat a whole-zone traverse.
local function RouteStats(order, pts, evs, ctx)
	local travel = 0
	for i = 1, #order do
		travel = travel + DistYd(pts[order[i]],
			pts[order[i % #order + 1]])
	end
	local lapSec = travel / ctx.speed + GATHER_SEC * #order
	local ev = 0
	for _, i in ipairs(order) do ev = ev + evs[i] end
	local avail = min(1, lapSec / ctx.respawn)
	local gpm = ev * avail * 60 / lapSec
	return gpm, lapSec, travel, ev * avail
end

local function TwoOpt(order, pts)
	local n = #order
	local function leg(i, j)
		return DistYd(pts[order[i]], pts[order[j]]) or 1e9
	end
	local improved = true
	local passes = 0
	while improved and passes < 10 do
		improved, passes = false, passes + 1
		for i = 1, n - 2 do
			for j = i + 2, n do
				if not (i == 1 and j == n) then
					local d0 = leg(i, i + 1) + leg(j, j % n + 1)
					local d1 = leg(i, j) + leg(i + 1, j % n + 1)
					if d1 < d0 - 0.01 then
						local lo, hi = i + 1, j
						while lo < hi do
							order[lo], order[hi] =
								order[hi], order[lo]
							lo, hi = lo + 1, hi - 1
						end
						improved = true
					end
				end
			end
		end
	end
end

-- nearest-neighbor seed then 2-opt polish; returns a scored route
local function BuildLoop(set, pts, evs, ctx)
	if #set < 2 then return nil end
	local order = { set[1] }
	local used = { [set[1]] = true }
	local cur = set[1]
	for _ = 2, #set do
		local best, bd
		for _, i in ipairs(set) do
			if not used[i] then
				local d = DistYd(pts[cur], pts[i]) or 1e9
				if not bd or d < bd then best, bd = i, d end
			end
		end
		tinsert(order, best)
		used[best] = true
		cur = best
	end
	TwoOpt(order, pts)
	local gpm, lapSec, yards, evEff = RouteStats(order, pts, evs, ctx)
	return {
		order = order, gpm = gpm, lapSec = lapSec,
		yards = yards, evLoop = evEff,
	}
end

-- union-find components under LINK_YD so detached spawn pockets
-- score as their own candidate loops
local function Components(pts)
	local parent = {}
	local function find(i)
		while parent[i] ~= i do
			parent[i] = parent[parent[i]] i = parent[i]
		end
		return i
	end
	for i = 1, #pts do parent[i] = i end
	for i = 1, #pts do
		for j = i + 1, #pts do
			local d = DistYd(pts[i], pts[j])
			if d and d <= LINK_YD then
				local ra, rb = find(i), find(j)
				if ra ~= rb then parent[ra] = rb end
			end
		end
	end
	local comps = {}
	for i = 1, #pts do
		local r = find(i)
		local c = comps[r]
		if not c then c = {} comps[r] = c end
		tinsert(c, i)
	end
	local out = {}
	for _, c in pairs(comps) do tinsert(out, c) end
	return out
end

-- pick the loop (possibly a sub-pocket of the zone) with the best
-- steady-state GPM under the given transport speed + learned
-- respawn. Stops in the result are node record refs — they survive
-- a later Solve without index remapping.
function G.SolveRoute(map, kind)
	local list = NodeList(map)
	if not list then return nil end
	local pts, evs = {}, {}
	for _, nd in ipairs(list) do
		if nd.kind == kind and nd.n then
			pts[#pts + 1] = nd
			evs[#evs + 1] = NodeEV(nd)
		end
	end
	if #pts < 3 then return nil end

	local ctx = {
		speed = G.SPEEDS[db.speedIx or 2].yps,
		respawn = G.RespawnSec(map, kind),
	}

	-- candidate sets: every component alone, greedy merges while
	-- union GPM improves, and the whole zone. Sub-pockets can win
	-- outright — that's the point of the saturation model.
	local comps = Components(pts)
	table.sort(comps, function(a, b) return #a > #b end)
	local best, merged
	for _, c in ipairs(comps) do
		local r = BuildLoop(c, pts, evs, ctx)
		if r and (not best or r.gpm > best.gpm) then
			best, merged = r, c
		end
	end
	if merged then
		local inM = {}
		for _, i in ipairs(merged) do inM[i] = true end
		for _, c in ipairs(comps) do
			if c ~= merged then
				local union = {}
				for i in pairs(inM) do tinsert(union, i) end
				for _, i in ipairs(c) do tinsert(union, i) end
				local r = BuildLoop(union, pts, evs, ctx)
				if r and r.gpm > best.gpm then
					best = r
					for _, i in ipairs(c) do inM[i] = true end
				end
			end
		end
	end
	local all = {}
	for i = 1, #pts do tinsert(all, i) end
	local r = BuildLoop(all, pts, evs, ctx)
	if r and (not best or r.gpm > best.gpm) then best = r end
	if not best then return nil end

	-- translate order indices into node refs — the route keeps
	-- working if more nodes get recorded after the solve
	best.stops = {}
	for _, i in ipairs(best.order) do tinsert(best.stops, pts[i]) end
	best.order = nil
	best.kind = kind
	best.map = map
	best.speed = ctx.speed
	best.respawn = ctx.respawn
	-- contention derates every route the same — ordering unaffected
	best.gpm = best.gpm * G.ContF()
	return best
end

-- ======================== leaderboard model ========================

-- every scoreable row: node loops AND hunt zones, one shape the UI
-- sorts by gpm
function G.Leaderboard()
	local rows = {}
	for map, list in pairs(db.nodes or {}) do
		for _, kind in ipairs({ "herb", "mine" }) do
			local r = G.SolveRoute(map, kind)
			if r then
				r.zoneName = G.ZoneName(map)
				tinsert(rows, r)
			end
		end
	end
	for map, list in pairs(db.zones or {}) do
		for _, zn in ipairs(list) do
			local rate = ZoneRate(zn)
			local ev = ZoneEV(zn)
			local sus = G.ZoneSusRate(zn)
			local evSus = G.ZoneSusEV(zn)
			tinsert(rows, {
				area = true, map = map, zone = zn,
				kind = zn.kind, zoneName = G.ZoneName(map),
				-- headline = sustained; raw = what the session
				-- actually produced (lottery drops + full rate)
				gpm = evSus * sus,
				gpmRaw = ev * rate,
				evLoop = evSus, evRaw = ev,
				lapSec = rate > 0 and (60 / rate) or 0,
				kills = zn.kills,
				spawns = #(zn.pockets or {}),
			})
		end
	end
	table.sort(rows, function(a, b) return a.gpm > b.gpm end)
	return rows
end

-- ======================== navigation ========================

-- the client owns one user-waypoint slot. Snapshot before stealing,
-- restore on release only if nothing else touched it — the MapWise
-- etiquette the proposal prescribes.
local nav = {}
function G.NavTo(map, x, y)
	if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint) then
		return nil, "no waypoint api"
	end
	if C_Map.CanSetUserWaypointOnMap then
		local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, map)
		if ok and can == false then
			return nil, "waypoints disabled"
		end
	end
	if not nav.savedSet and C_Map.GetUserWaypoint then
		local ok, prev = pcall(C_Map.GetUserWaypoint)
		if ok then
			nav.saved = prev
			nav.savedSet = true
		end
	end
	local okP, pt = pcall(UiMapPoint.CreateFromCoordinates, map, x, y)
	if not okP or not pt then return nil, "bad point" end
	local okS, err = pcall(C_Map.SetUserWaypoint, pt)
	if not okS then return nil, tostring(err) end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end
	nav.ours = true
	return true
end

local function NavRelease()
	if not nav.ours then return end
	nav.ours = nil
	if C_Map and C_Map.ClearUserWaypoint then
		local ok, cur = pcall(C_Map.GetUserWaypoint)
		if ok and cur then pcall(C_Map.ClearUserWaypoint) end
	end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false)
	end
	if nav.savedSet and nav.saved and C_Map.SetUserWaypoint then
		pcall(C_Map.SetUserWaypoint, nav.saved)
	end
	nav.saved, nav.savedSet = nil, nil
end

-- point the native waypoint at a recorded position (map coords);
-- falls back to a chat hint when the API isn't there
function G.PointAt(p)
	if p.x and p.y and p.map then
		local ok, err = G.NavTo(p.map, p.x, p.y)
		if ok then return true end
		GM.Print(GM.CC("textDim") .. "waypoint: "
			.. tostring(err) .. "|r")
		return nil
	end
	return nil
end

-- ======================== route running ========================

-- active loop: stop refs (survive later solves), index, arrival
-- stamps for lap timing. A full observed lap beats the model —
-- folded into lapObs so the next GPM is measured, not guessed.
local run

function G.StartRoute(r)
	if not r or not r.stops or #r.stops < 2 then return end
	run = { route = r, stops = r.stops, idx = 1 }
	r.running = true
	tick:Show()
	G.PointAt(r.stops[1])
	GM.Print(GM.CC("accent") .. "route started|r — " .. #r.stops
		.. " stops, est " .. G.SecondsText(r.lapSec) .. "/lap")
end

function G.StopRoute()
	if not run then return end
	if run.laps and run.laps > 0 then
		local r = run.route
		local obs = run.lapSum / run.laps
		r.lapObs = r.lapObs and (r.lapObs * 0.7 + obs * 0.3) or obs
		r.lapN = (r.lapN or 0) + run.laps
	end
	run.route.running = nil
	run = nil
	NavRelease()
	if GM.GatherMap then GM.GatherMap.Refresh() end
end

function G.Route()
	return run
end

-- arrival check + lap timing, 4x/sec while a route runs
local tick = CreateFrame("Frame")
tick:Hide()
tick.acc = 0
tick:SetScript("OnUpdate", function(_, dt)
	tick.acc = tick.acc + dt
	if tick.acc < 0.25 then return end
	tick.acc = 0
	if not run then tick:Hide() return end
	local p = PosNow()
	if not p then return end
	local stop = run.stops[run.idx]
	local d = DistYd(p, stop)
	if d and d <= ARRIVE_YD then
		local now = GetTime()
		if run.idx == 1 then
			-- arriving back at stop 1 closes a lap
			if run.lapStart then
				run.lapSum = (run.lapSum or 0)
					+ (now - run.lapStart)
				run.laps = (run.laps or 0) + 1
			end
			run.lapStart = now
		end
		run.idx = run.idx % #run.stops + 1
		G.PointAt(run.stops[run.idx])
	end
end)

-- ======================== loot capture ========================

local arm -- { kind, pos, until_ }

local function ArmWindow(kind)
	arm = {
		kind = kind, pos = PosNow(),
		until_ = GetTime() + WINDOW_SEC,
	}
end

local function ItemOfLink(link)
	if type(link) ~= "string" then return nil end
	local id = link:match("|Hitem:(%d+)")
	return id and tonumber(id) or nil
end

-- loot window -> itemID->qty. Same client shape Drops.lua uses:
-- slot 2 is the item NAME, GetLootSlotLink gives the link.
local function LootItems()
	if not (GetNumLootItems and GetLootSlotInfo) then return nil end
	local n = GetNumLootItems()
	if not n or n < 1 then return nil end
	local items, first
	for i = 1, n do
		local _, lName, lQty, _, _, _, isQuest = GetLootSlotInfo(i)
		local link = GetLootSlotLink and GetLootSlotLink(i) or lName
		local id = ItemOfLink(link) or ItemOfLink(lName)
		if id and not isQuest then
			items = items or {}
			items[id] = (items[id] or 0) + (tonumber(lQty) or 1)
			first = first or id
		end
	end
	return items, first
end

local lastLootSig, lastLootT

local function OnLoot()
	if not (GetNumLootItems and GetLootSlotInfo) then return end
	local items, first = LootItems()
	if not items then return end
	local t = GetTime()
	local sig = tostring(first) .. ":" .. tostring(GetNumLootItems())
	if lastLootSig == sig and t - (lastLootT or 0) < 0.5 then
		return
	end
	lastLootSig, lastLootT = sig, t

	-- loot source name — the loot window's target, same surface
	-- Drops.lua uses
	local srcName
	for _, unit in ipairs({ "target", "mouseover" }) do
		local nm = UnitName and UnitName(unit)
		if nm then srcName = nm break end
	end

	if arm and t <= arm.until_ then
		-- inside a gather-cast window: this loot IS the gather
		local kind, pos = arm.kind, arm.pos or PosNow()
		arm = nil
		if not pos then return end
		if G.NODE_KINDS[kind] then
			MergeNode(pos, kind, srcName)
			UpdateYield(YieldRec(srcName or kind), items)
		else
			-- skinning: a skinned corpse is a kill event — zone it,
			-- and record yields under both the generic key and the
			-- mob name
			MergeZone(pos, "skin", items)
			UpdateYield(YieldRec("skin"), items)
			if srcName then
				UpdateYield(YieldRec("skin:" .. srcName), items)
			end
		end
		if GM.GatherMap then GM.GatherMap.Refresh() end
		return
	end

	-- no gather window: a kill loot = a hunt kill. Any item at all
	-- seeds the zone — the per-item yield map is what lets target
	-- mode answer "where does raptor flesh drop" for drops we never
	-- modeled. Money-only windows (empty items) don't count.
	if next(items) then
		local pos = PosNow()
		if pos then
			MergeZone(pos, "hunt", items)
			UpdateYield(YieldRec("hunt"), items)
			-- per-mob drop table: "hunt:Ravasaur" -> flesh/leather —
			-- the seed of a real mob-drop model
			if srcName then
				UpdateYield(YieldRec("hunt:" .. srcName), items)
			end
		end
		if GM.GatherMap then GM.GatherMap.Refresh() end
	end
	return
end

-- ======================== events ========================

local evf = CreateFrame("Frame")
for _, e in ipairs({
	"UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
	"UNIT_SPELLCAST_INTERRUPTED",
	"LOOT_OPENED", "LOOT_READY",
	"PLAYER_LOGIN", "ZONE_CHANGED_NEW_AREA",
}) do pcall(evf.RegisterEvent, evf, e) end

evf:SetScript("OnEvent", function(_, e, ...)
	if e == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit ~= "player" then return end
		local kind = CAST_KIND[spellID]
		if not kind and spellID then
			-- Forever can omit spellID / ship alternates — fall
			-- back to the spell's name before giving up
			local ok, nm = pcall(GetSpellInfo, spellID)
			if ok and type(nm) == "string" then
				local l = nm:lower()
				for k, pat in pairs(CAST_NAME) do
					if l:find(pat, 1, true) then kind = k break end
				end
			end
		end
		if kind then ArmWindow(kind) end
		return
	end
	if e == "UNIT_SPELLCAST_FAILED"
		or e == "UNIT_SPELLCAST_INTERRUPTED" then
		local unit = ...
		if unit == "player" then arm = nil end
		return
	end
	if e == "LOOT_OPENED" or e == "LOOT_READY" then
		local ok, err = pcall(OnLoot)
		if not ok then
			GM.Print(GM.CC("err") .. "gather capture: "
				.. tostring(err):sub(1, 80) .. "|r")
		end
		return
	end
	if e == "PLAYER_LOGIN" or e == "ZONE_CHANGED_NEW_AREA" then
		db = GoblinMindGather
		if GM.GatherMap then GM.GatherMap.Refresh() end
		return
	end
end)
