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

local tinsert = table.insert
local floor, sqrt = math.floor, math.sqrt
local max, min = math.max, math.min

-- record schema version: zone/yield math changed under early data
-- (pockets, per-item hits, failed-loot counting). Bump = wipe the
-- derived records so pre-change loot doesn't poison the model.
-- Nodes keep — positions are still valid; re-import is one click.
local REC_V = 5
if db.v ~= REC_V then
	db.zones, db.yields, db.resp, db.journal = {}, {}, {}, {}
	db.v = REC_V
end

-- node-record version: pre-v2 records were merged under a 40yd
-- radius — every tap within it folded onto the first sighting's
-- position, so a "node" was a group centroid a route can't
-- actually gather at. Bump = reset only the spatial records;
-- zones/yields/journal keep (kills were never group-merged).
local NODE_V = 2
if (db.nodeV or 0) < NODE_V then
	db.nodes, db.resp = {}, {}
	db.nodeV = NODE_V
end

-- fish nodes recorded before the school/open-water split can't be
-- trusted as pools — a lone moat spot would classify every future
-- open-water catch as a "school hit" forever via the proximity
-- test. Imported pool spawns (src="gl") keep; recorded fish nodes
-- reset once so live catches re-decide under the new classifier
if not db.fishSplitV then
	for _, list in pairs(db.nodes or {}) do
		for i = #list, 1, -1 do
			if list[i].kind == "fish" and list[i].src ~= "gl" then
				tremove(list, i)
			end
		end
	end
	db.fishSplitV = true
end

-- ======================== constants ========================

-- ======================== kind registry ========================
-- one declarative record per gather kind drives every consumer:
-- cast attribution, item-family verdicts, GatherLite imports,
-- node-vs-zone behavior, display colors/labels, layer toggles,
-- route gating. Blizzard (or Forever) adding a gather type =
-- one G.RegisterKind call — the rest of the system never sees it.
--
-- fields:
--   node      — point-spawn kind (routes); false/nil = zone kind
--   area      — zone-record kind (MergeZone families)
--   cats      -- item families (GM.Gathering.ItemCat) that
--               classify a loot window as this kind
--   corpse    -- this family is corpse cargo: it can NEVER
--               classify a window on its own (cloth, flesh, and
--               fish — a dead mob legitimately carries raw fish)
--   tailKill  -- window only counts trailing a recent kill
--               (skinning: a corpse's own window carries leather)
--   keepArm   -- armed cast survives a dead-source window
--               (skin + fish: the gather isn't corpse loot even
--               when a corpse is standing there)
--   armWins   -- the cast names the object type; the item verdict
--               can't override it (a chest of ore is still a chest)
--   castIds   -- UNIT_SPELLCAST_SUCCEEDED spellIDs that arm it
--   castNames -- spell-name substrings when spellID is missing
--   glCats    -- GatherLite SV categories that import as it
local CAST_KIND = {}
local CAST_NAME = {}
local GL_KIND = {}
local CAT_KIND = {}   -- item family -> kind id

G.KindDefs = {}
G.KINDS = {}
G.KIND_COLOR = {}
G.KIND_LABEL = {}
-- node kinds build routes; area kinds build zones
G.NODE_KINDS = {}
G.AREA_KINDS = {}

function G.RegisterKind(def)
	local id = def.id
	G.KindDefs[id] = def
	table.insert(G.KINDS, id)
	G.KIND_COLOR[id] = def.color or { 1, 1, 1 }
	G.KIND_LABEL[id] = def.label or id:upper()
	if def.node then G.NODE_KINDS[id] = true end
	if def.area then G.AREA_KINDS[id] = true end
	for _, s in ipairs(def.castIds or {}) do CAST_KIND[s] = id end
	for _, p in ipairs(def.castNames or {}) do CAST_NAME[id] = p end
	for _, g in ipairs(def.glCats or {}) do GL_KIND[g] = id end
	for _, c in ipairs(def.cats or {}) do CAT_KIND[c] = id end
end

G.RegisterKind{ id = "herb", label = "HERB",
	color = { 0.2, 0.9, 0.3 }, node = true,
	cats = { "herb" }, castIds = { 2383 },
	castNames = { "herb gathering" }, glCats = { "herbalism" } }
G.RegisterKind{ id = "mine", label = "MINE",
	color = { 0.95, 0.7, 0.2 }, node = true,
	cats = { "ore" }, castIds = { 2580 },
	castNames = { "mining" }, glCats = { "mining" } }
G.RegisterKind{ id = "fish", label = "FISH",
	color = { 0.35, 0.65, 0.95 }, node = true,
	cats = { "fish" }, corpse = true, keepArm = true,
	-- fishing is a channel, not a tap: the catch lands ~21s past
	-- cast-succeed — WINDOW_SEC's 3s arm expired before every
	-- splash. armSec covers the channel as a SUCCEEDED fallback;
	-- CHANNEL_START arms to the channel's own endTime instead
	armSec = 24,
	-- a fishing farm IS the one spot: no loop exists to solve.
	-- cycleSec is the cast+loot cadence — the ~21s channel plus
	-- recast latency — so a lone spot still gets an honest gpm
	spot = true, cycleSec = 22,
	castIds = { 7620 }, castNames = { "fishing" },
	glCats = { "fishing" } }
G.RegisterKind{ id = "skin", label = "SKIN",
	color = { 0.7, 0.45, 0.25 }, area = true,
	cats = { "leather" }, tailKill = true, keepArm = true,
	castIds = { 8613 }, castNames = { "skinning" } }
G.RegisterKind{ id = "hunt", label = "HUNT",
	color = { 0.9, 0.4, 0.2 }, area = true }
G.RegisterKind{ id = "cloth", label = "CLOTH",
	color = { 0.85, 0.85, 0.95 }, area = true,
	cats = { "cloth" }, corpse = true }
G.RegisterKind{ id = "cook", label = "COOK",
	color = { 0.95, 0.55, 0.55 },
	cats = { "flesh" }, corpse = true }
G.RegisterKind{ id = "chest", label = "CHEST",
	color = { 0.85, 0.75, 0.45 }, node = true,
	-- object taps: Forever loots most chests instantly with no
	-- SUCCEEDED, so recording rides the no-corpse catch-all below;
	-- the cast IDs arm it when the client reports one. keepArm
	-- because the cast IS the evidence — a dead target standing
	-- beside the chest must not drop it to a hunt kill
	keepArm = true,
	-- the open cast names the object type — a chest holding
	-- ore-family items is still a chest, so the item verdict
	-- can't re-classify the window
	armWins = true,
	castIds = { 3365, 5108, 22810, 22811 },
	castNames = { "opening" } }


-- hunt = the mob-farm kind — no cast; every non-gather loot window
-- is a kill event. Meat, cloth, greens, quest drops: all yield data
-- lands on the zone so targeting can find producers of anything.
-- (Was cloth-only at first — a camp dropping cloth AND meat split
-- into two overlapping zones until the kind unified.)
-- Kind tables themselves are populated by the registry above.

-- shared display surface: UPPERCASE tag + kind color. KindCol
-- checks the settings override (GoblinMindGather.mm.col) first —
-- row tags, map labels, and disc fills all read through it so
-- one color pick applies everywhere
function G.KindLabel(k)
	return G.KIND_LABEL[k] or k
end
function G.KindCol(k)
	local ov = GM.GatherMinimap and GM.GatherMinimap.Color(k)
	return ov or G.KIND_COLOR[k] or { 1, 1, 1 }
end
function G.KindHex(k)
	local c = G.KindCol(k)
	return format("|cff%02x%02x%02x",
		floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255))
end
-- hex-wrapped UPPERCASE label — the tag form every surface uses;
-- callers concatenate after it so it carries its own |r
function G.KindTag(k)
	return G.KindHex(k) .. G.KindLabel(k) .. "|r"
end

local WINDOW_SEC = 3        -- gather cast -> loot attribution window
local NODE_MERGE_YD = 14    -- one record ≈ one spawn point: routes
                            -- need exact stand-spots, not group
                            -- centroids (gather range ≈10yd, so one
                            -- physical node still folds approaches)
local ZONE_MERGE_YD = 150   -- kills this close join one farm zone
local LINK_YD = 250         -- route-solver component link distance
local DEFAULT_YPU = 1500    -- yards per normalized map unit (fallback)
local GATHER_SEC = 2.5      -- gather cast + loot time per stop
local RESPAWN_PRIOR = 900   -- node respawn prior (learned bound wins)
local ARRIVE_YD = 20        -- waypoint advance radius
local ACTIVE_GAP = 90       -- kills this close = same farm session
local SESSION_GAP = 600     -- gaps past this = a break, not dead time
local HIST_MAX = 150        -- per-zone event log bound
local POCKET_YD = 30        -- kills within this = same mob spawn
local MOB_RESPAWN_PRIOR = 180 -- classic open-world respawn guess
local RESPAWN_OBS_MIN = 45  -- rekill gaps under this carry no info
local KILL_RATE_PRIOR = 3   -- kills/min before a zone has data
local COALESCE_S = 4        -- loot windows this close = one kill

-- transport modes (yards/sec) — the GPM model's travel cost;
-- db.speedIx picks which the solver assumes
G.SPEEDS = {
	{ key = "run",   name = "on foot",      yps = 7.0 },
	{ key = "mount", name = "mount +40%",   yps = 9.8 },
	{ key = "epic",  name = "mount +100%",  yps = 14.0 },
}

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
			local x, y = GM.MapPos(c, n, w, mapID)
			if x and x >= 0 and x <= 1
				and y >= 0 and y <= 1 then
				p.x, p.y = x, y
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

-- inside the learned respawn window → the spawn is down, dim it.
-- All dim checks route here: the depletion arithmetic lived in
-- three draw paths once and drifted apart (one guarded respawn,
-- two didn't)
function G.NodeDepleted(nd, map)
	if not nd.last then return false end
	return (time() - nd.last)
		< G.RespawnSec(map, nd.kind) * 0.8
end

-- derived-data epoch: every record mutation bumps it so solved
-- routes and merged-zone caches invalidate without bookkeeping
-- per consumer. Target changes don't bump — no solved row reads
-- db.target (targeted zone rows rebuild fresh every call).
local dataV = 0
local function Bump() dataV = dataV + 1 end

-- ms clock for solver budgets — debugprofilestop where present
local PerfNow = debugprofilestop
	or function() return GetTime() * 1000 end

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
				Bump()
				return nd
			end
		end
	end
	-- mergeOnly = hit-test only: a miss means no KNOWN spawn here
	-- (fishing uses it to split school catches from open water —
	-- open water is an area, not a point)
	if opt and opt.mergeOnly then return nil end
	local nd = {
		map = p.map, x = p.x, y = p.y,
		n = p.n, w = p.w, z = p.z, c = p.c,
		kind = kind, name = name, hits = 1,
	}
	if stamp then nd.last = now end
	tinsert(list, nd)
	Bump()
	return nd
end

-- running total of qty per item + event count, on whatever table
-- gets .items/.cnt (yield record or zone record). The counter is
-- `cnt`, NOT `n` — `n` is already the north-coord field on every
-- position record
local function UpdateYield(rec, items, tail)
	Bump()
	rec.items = rec.items or {}
	rec.hits = rec.hits or {}
	for id, qty in pairs(items) do
		rec.items[id] = (rec.items[id] or 0) + qty
		-- events containing the item (vs qty) — one-off drops get
		-- hits=1 so sustained EV can exclude lottery income.
		-- tail windows skip hits: a second window of the SAME kill
		-- can't be a separate drop occurrence
		if not tail then
			rec.hits[id] = (rec.hits[id] or 0) + 1
		end
	end
	-- tail = folded window of an already-counted kill: its loot is
	-- real, but the event count must stay one-kill-one-event or
	-- drop chances halve
	if not tail then rec.cnt = (rec.cnt or 0) + 1 end
end

local function YieldRec(key)
	db.yields = db.yields or {}
	local y = db.yields[key]
	if not y then y = { items = {}, cnt = 0 } db.yields[key] = y end
	return y
end

-- forward decls — MergeZone records value at loot time, which
-- needs the price fns defined further down
local ItemVal, LootValue
local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

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
		-- the pocket's x,y frame is the KILL's map, not the
		-- zone's — cross-map merging mislabels it otherwise
		best = { map = p.map or zn.map,
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

-- every kill appends {t, v} — value priced at loot time — to a
-- bounded log. The diff between consecutive events IS the cycle:
-- travel, kill time, respawn waits, losing spawns to competition.
-- The 90s activeT mean erases all of it; the log keeps it.
local function ZoneEvent(zn, now, items, money)
	zn.hist = zn.hist or {}
	local hi = zn.hist
	hi[#hi + 1] = { t = now,
		v = (LootValue(items) or 0) + (money or 0) }
	if #hi > HIST_MAX then tremove(hi, 1) end
	zn.vTot = (zn.vTot or 0) + hi[#hi].v
end

-- a burst tail: the kill's event already exists — its timestamp
-- IS the kill time. Fold the tail's value into it so consecutive
-- deltas still mean kill-to-kill, not window-to-window
local function ZoneEventFold(zn, now, items, money)
	local v = (LootValue(items) or 0) + (money or 0)
	local hi = zn.hist
	if hi and #hi > 0 then
		hi[#hi].v = hi[#hi].v + v
	end
	zn.vTot = (zn.vTot or 0) + v
end

-- a kill joins a zone when it lands within merge range of the
-- centroid OR any recorded pocket — a sprawling camp (a murloc
-- beach, a raptor ridge) accumulates pockets in a chain instead
-- of splitting into two "camps" at an arbitrary centroid radius
local function ZoneMergeable(zn, p)
	local d = DistYd(zn, p)
	-- fixed reach only — gating on zn.r snowballs: every absorbed
	-- kill extends r, which extends the next merge's reach, until
	-- one "camp" swallows half the zone (the giant Witherbark disc)
	if d and d <= ZONE_MERGE_YD then
		return true
	end
	for _, pk in ipairs(zn.pockets or {}) do
		local pd = DistYd(pk, p)
		if pd and pd <= ZONE_MERGE_YD then return true end
	end
	return false
end

-- do two zones' farm areas interpenetrate? used by the coalesce
-- pass that heals splits already recorded under centroid merging
local function ZonesNear(a, b)
	local d = DistYd(a, b)
	if d and d <= ZONE_MERGE_YD then return true end
	for _, pk in ipairs(a.pockets or {}) do
		local pd = DistYd(pk, b)
		if pd and pd <= ZONE_MERGE_YD then return true end
		for _, qk in ipairs(b.pockets or {}) do
			local dd = DistYd(pk, qk)
			if dd and dd <= ZONE_MERGE_YD then return true end
		end
	end
	return false
end

-- fold src into dst: counts, loot tables, mob credits, pockets,
-- and the timestamped event log all combine; respawn keeps the
-- tightest learned bound
local function FoldZone(dst, src)
	dst.kills = (dst.kills or 0) + (src.kills or 0)
	dst.activeT = (dst.activeT or 0) + (src.activeT or 0)
	dst.cnt = (dst.cnt or 0) + (src.cnt or 0)
	dst.vTot = (dst.vTot or 0) + (src.vTot or 0)
	dst.lastGT = max(dst.lastGT or 0, src.lastGT or 0)
	dst.resp = min(dst.resp or 9e9, src.resp or 9e9)
	dst.r = floor(max(dst.r or 0, src.r or 0,
		(DistYd(dst, src) or 0) + (src.r or 0)))
	for mob, k in pairs(src.mobs or {}) do
		dst.mobs = dst.mobs or {}
		dst.mobs[mob] = (dst.mobs[mob] or 0) + k
	end
	for t, q in pairs(src.subs or {}) do
		dst.subs = dst.subs or {}
		dst.subs[t] = (dst.subs[t] or 0) + q
	end
	for id, q in pairs(src.items or {}) do
		dst.items[id] = (dst.items[id] or 0) + q
	end
	for id, h in pairs(src.hits or {}) do
		dst.hits[id] = (dst.hits[id] or 0) + h
	end
	for _, pk in ipairs(src.pockets or {}) do
		local dup
		for _, dpk in ipairs(dst.pockets or {}) do
			local d = DistYd(dpk, pk)
			if d and d <= POCKET_YD then
				-- keep the older 'last' — a longer gap can only
				-- under-tighten the respawn bound, never inflate it
				if pk.last and (not dpk.last or pk.last < dpk.last)
					then dpk.last = pk.last end
				dup = true break
			end
		end
		if not dup then tinsert(dst.pockets, pk) end
	end
	if src.hist then
		dst.hist = dst.hist or {}
		for _, e in ipairs(src.hist) do tinsert(dst.hist, e) end
		table.sort(dst.hist, function(a, b) return a.t < b.t end)
		while #dst.hist > HIST_MAX do tremove(dst.hist, 1) end
	end
end

-- heal split camps: fold same-map same-kind zones whose recorded
-- areas interpenetrate. Idempotent — converges over repeated calls
-- global pass: the same physical camp can be recorded under
-- different mapIDs when the client's map resolution jitters, so
-- candidates come from every map's list; the continent frame is
-- what makes ZonesNear distance real
local function CoalesceZones()
	if not db.zones then return end
	local flat = {}
	for _, list in pairs(db.zones) do
		for _, zn in ipairs(list) do
			flat[#flat + 1] = zn
		end
	end
	local again = true
	while again do
		again = false
		for i = #flat, 1, -1 do
			for j = i - 1, 1, -1 do
				if flat[i].kind == flat[j].kind
					and ZonesNear(flat[j], flat[i]) then
					FoldZone(flat[j], flat[i])
					local dead = tremove(flat, i)
					for _, list in pairs(db.zones) do
						for k = #list, 1, -1 do
							if list[k] == dead then
								tremove(list, k)
								break
							end
						end
					end
					again = true
					Bump()
					break
				end
			end
			if again then break end
		end
	end
end

-- the subzone the player is standing in ("Witherbark Village") —
-- the landmark name a camp's disc should carry. Empty off named
-- ground; GetMinimapZoneText is the fallback on clients where
-- GetSubZoneText stays blank
local function SubZone()
	local fn = GetSubZoneText or GetMinimapZoneText
	if not fn then return nil end
	local ok, t = pcall(fn)
	if ok and t and t ~= "" then return t end
end

-- tally the kill's subzone so a camp labels itself by the landmark
-- its kills actually cluster on, not just the zone text
local function NoteSub(zn)
	local st = SubZone()
	if st then
		zn.subs = zn.subs or {}
		zn.subs[st] = (zn.subs[st] or 0) + 1
	end
end

-- dominant recorded landmark for a camp — falls back to the zone
-- text, then the generic map name
function G.ZonePlace(zn)
	local best, bq
	for t, q in pairs(zn.subs or {}) do
		if q > (bq or 0) then best, bq = t, q end
	end
	return best or zn.area
end

local function MergeZone(p, kind, items, mob, mobMoney)
	local list = ZoneList(p.map)
	if not list then return nil end
	local now = GetTime()
	-- a farm is a PLACE, not a map file: Forever resolves the same
	-- spot to different mapIDs (a Riverglades beach reporting as
	-- Tanaris), so merge candidates come from EVERY map's list —
	-- the shared continent world frame is what makes distance real
	for _, zl in pairs(db.zones) do
		for _, zn in ipairs(zl) do
		if zn.kind == kind and zn.c == p.c
			and ZoneMergeable(zn, p) then
			-- one kill fires SEVERAL loot windows (the item window,
			-- the money tail, a re-open while the corpse is still
			-- targeted). Fold a burst into the last event — same or
			-- unresolvable mob within COALESCE_S is that kill's
			-- tail, not a new kill. A DIFFERENT named mob this fast
			-- is a real second kill.
			local last = zn.hist and zn.hist[#zn.hist]
			if last and (now - last.t) <= COALESCE_S
				and (not mob or not zn.lastMob or mob == zn.lastMob) then
				UpdateYield(zn, items, true)
				ZoneEventFold(zn, now, items, mobMoney)
				MergePocket(zn, p)
				return zn, true
			end
			-- kills < ACTIVE_GAP apart = one farming session —
			-- the zone's rate is kills per active second, so
			-- breaks don't dilute it
			if zn.lastGT and now - zn.lastGT < ACTIVE_GAP then
				zn.activeT = (zn.activeT or 0) + (now - zn.lastGT)
			end
			zn.lastGT = now
			zn.kills = (zn.kills or 0) + 1
			if mob then
				zn.mobs = zn.mobs or {}
				zn.mobs[mob] = (zn.mobs[mob] or 0) + 1
				zn.lastMob = mob
			end
			UpdateYield(zn, items)
			ZoneEvent(zn, now, items, mobMoney)
			MergePocket(zn, p)
			NoteSub(zn)
			local d = DistYd(zn, p)
			if d and d > (zn.r or 0) then zn.r = floor(d + 25) end
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
		-- the area name the PLAYER sees (Riverglades) — map names
		-- can lie on custom-zone clients that reuse classic mapIDs
		area = (function()
			local fn = GetRealZoneText or GetZoneText
			local ok, t
			if fn then ok, t = pcall(fn) end
			return ok and t or nil
		end)(),
	}
	if mob then zn.mobs = { [mob] = 1 } zn.lastMob = mob end
	UpdateYield(zn, items)
	ZoneEvent(zn, now, items, mobMoney)
	MergePocket(zn, p)
	NoteSub(zn)
	tinsert(list, zn)
	return zn
end

-- ======================== EV model ========================

-- farm EV prices at what it SELLS for: the LOWER of min buyout
-- and market — every price source can carry fantasy values on
-- items nobody lists (mkt said 14g, a feed mb said ~140g for
-- raptor flesh while the book has it at 3s). min() means the EV
-- can never be more optimistic than the most pessimistic source.
-- what one unit of an item is worth to a farmer, the GoldScout
-- way: grays are vendor trash — sell price only, never an auction
-- quote. Everything else takes the LOWER of min-buyout and market
-- floored at vendor sell — a fantasy listing can never beat the
-- guaranteed price a vendor always pays.
ItemVal = function(id)
	local quality, sell
	if GetInfo then
		local ok, q, sp = pcall(function()
			return select(3, GetInfo(id)), select(11, GetInfo(id))
		end)
		if ok then quality, sell = q, sp end
	end
	-- index 11 is sellPrice on standard clients — on Forever it
	-- sometimes returns an unrelated field (appearance/spell ids
	-- land in the millions). Nothing a farm mob drops legitimately
	-- vendors above 5g, so the floor caps there — a garbage field
	-- can never price a drop again
	if sell and sell > 50000 then sell = nil end
	if quality == 0 then return sell end
	local a = GM.Price and GM.Price("dbminbuyout", id)
	local b = GM.Price and GM.Price("dbmarket", id)
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

-- copper value of one loot window at record time — empty corpses
-- and money-only corpses correctly price at zero
LootValue = function(items)
	local v = 0
	for id, q in pairs(items or {}) do
		v = v + (ItemVal(id) or 0) * q
	end
	return v
end

-- Wilson score lower bound (~95%) on a drop chance — the GoldScout
-- ranking rule: the cautious end of the confidence interval, so a
-- lucky streak earns nothing against a steady farm. h events out
-- of n samples.
local WILSON_Z2 = 3.8416
local function WilsonLow(h, n)
	if not h or h <= 0 or not n or n <= 0 then return 0 end
	local p = h / n
	local den = 1 + WILSON_Z2 / n
	return max(0, (p + WILSON_Z2 / (2 * n)
		- 1.96 * sqrt(p * (1 - p) / n + WILSON_Z2 / (4 * n * n)))
		/ den)
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
			ev = ev + (ItemVal(id) or 0) * (qty / rec.cnt)
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
			t = t + (ItemVal(d.id) or 0) * (d.lo + d.hi) / 2
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
G.NodeEV = NodeEV

-- headline camp money rate: value/kill x kills/min. The tag and
-- every tooltip that quotes camp GPM reads through this so the
-- formula can't drift across surfaces
function G.ZoneGPM(zn)
	return ZoneEV(zn) * ZoneRate(zn)
end

-- wall-clock truth: total looted value over the session gaps.
-- Gaps past SESSION_GAP are a real break (not respawn/competition
-- dead time) and don't count toward the session. This is the
-- "earned" figure — what the ground actually paid per minute.
function G.ZoneWall(zn)
	local hi = zn.hist
	if not hi or #hi < 2 then return nil end
	local span, v = 0, hi[1].v
	for i = 2, #hi do
		local g = hi[i].t - hi[i - 1].t
		if g <= SESSION_GAP then span = span + g end
		v = v + hi[i].v
	end
	if span < 60 then return nil end
	return { span = span, v = v, gpm = v / span * 60 }
end

-- typical per-kill cycle from the event log: median of the
-- consecutive deltas, session gaps included — a camp whose
-- respawns stall the loop shows it here
function G.ZoneCycle(zn)
	local hi = zn.hist
	if not hi or #hi < 2 then return nil end
	local gaps = {}
	for i = 2, #hi do
		local g = hi[i].t - hi[i - 1].t
		if g <= SESSION_GAP then gaps[#gaps + 1] = g end
	end
	if #gaps == 0 then return nil end
	table.sort(gaps)
	return gaps[floor(#gaps / 2) + 1]
end

-- mob label for a zone: "Screecher ×5", "Screecher ×3 · Lashtail ×2",
-- "+N" tail when a camp mixes more than two mobs
function G.ZoneMobs(zn)
	local mobs = zn.mobs
	if not mobs then return nil end
	local t = {}
	for name, n in pairs(mobs) do t[#t + 1] = { name, n } end
	table.sort(t, function(a, b) return a[2] > b[2] end)
	local s
	for i = 1, min(2, #t) do
		s = (s and (s .. " · ") or "")
			.. t[i][1] .. " ×" .. t[i][2]
	end
	if #t > 2 then s = s .. " +" .. (#t - 2) end
	return s
end
-- repeatable per-kill EV — drops the one-shot lottery items
-- gear/recipes are LOTTERY income, not farm income — the GoldScout
-- rule: "gear, recipes and gems are rare world drops" excluded from
-- the rate. A 1-in-18 BoE ring still counts in 'earned' (you did
-- loot it) but never in the repeatable projection
local LOTTERY_TYPE = { Weapon = true, Armor = true, Recipe = true }
local function ItemLottery(id)
	if not GetInfo then return false end
	local ok, t = pcall(function() return select(6, GetInfo(id)) end)
	return ok and LOTTERY_TYPE[t] or false
end

-- repeatable per-kill EV at the Wilson lower bound: each item's
-- contribution is (95%-cautious drop chance) x (avg stack when it
-- drops) x value — a 2-in-17 lucky drop earns almost nothing
function G.ZoneSusEV(zn)
	if not zn.cnt or zn.cnt == 0 then return 0 end
	local ev = 0
	for id, qty in pairs(zn.items or {}) do
		if not ItemLottery(id) then
			local h = (zn.hits and zn.hits[id]) or min(qty, zn.cnt)
			if h > 0 then
				ev = ev + WilsonLow(h, zn.cnt) * (qty / h)
					* (ItemVal(id) or 0)
			end
		end
	end
	return ev
end

-- display item for a node/zone: what the farm IS, not the jackpot
-- it lucked into — the kind's own produce family (registry cats)
-- picked by drop frequency, so a thorium vein reads as Thorium
-- Ore, not the 1% Star Ruby that out-values it per unit
-- itemIDs picked for guaranteed presence on this client
local KIND_ICON_ITEM = {
	herb = 765, mine = 2770, skin = 2318, cloth = 2589,
	fish = 6359,
}
local function BestYieldItem(items)
	local best, bv
	for id, qty in pairs(items or {}) do
		-- icon = best FARM drop; a one-off epic ring shouldn't
		-- brand the camp as a gear farm
		if not ItemLottery(id) then
			local v = (ItemVal(id) or 0) * qty
			if not bv or v > bv then best, bv = id, v end
		end
	end
	return best
end
local function ProduceItem(kind, rec)
	local def = G.KindDefs and G.KindDefs[kind]
	local IC = GM.Gathering and GM.Gathering.ItemCat
	local items = rec and rec.items
	if not (def and def.cats and IC and items) then return nil end
	local fam = {}
	for _, c in ipairs(def.cats) do fam[c] = true end
	local hits = rec.hits or {}
	local best, bh, bv
	for id, qty in pairs(items) do
		if not ItemLottery(id) and fam[IC(id)] then
			local h = hits[id] or 0
			local v = (ItemVal(id) or 0) * qty
			if h > (bh or -1) or (h == bh and v > (bv or 0)) then
				best, bh, bv = id, h, v
			end
		end
	end
	return best
end
-- same pick off the STATIC drop table — imported nodes have no
-- yield record yet, but the node name still resolves its table.
-- Non-gem bonus rolls first by pct; the tables list the node's
-- own produce before bonus rolls anyway
local function StaticProduce(kind, key)
	local stat = GM.Gathering and GM.Gathering.nodes
		and GM.Gathering.nodes[key]
	local def = G.KindDefs and G.KindDefs[kind]
	local IC = GM.Gathering and GM.Gathering.ItemCat
	if not (stat and def and def.cats and IC) then return nil end
	local fam = {}
	for _, c in ipairs(def.cats) do fam[c] = true end
	local best, bp
	for _, d in ipairs(stat) do
		if not d.gem and fam[IC(d.id)]
			and (d.pct or 0) > (bp or 0) then
			best, bp = d.id, d.pct
		end
	end
	return best or (stat[1] and stat[1].id)
end
-- icon picks memoize on the data epoch — minimap ticks call these
-- per cluster at 8Hz and the answer only changes on a mutation
local iconMemo = {}
function G.NodeIconID(nd)
	local m = iconMemo[nd]
	if m and m.v == dataV then return m.id end
	local y = db.yields and db.yields[nd.name or nd.kind]
	local id = ProduceItem(nd.kind, y)
		or (y and BestYieldItem(y.items))
		or StaticProduce(nd.kind, nd.name or nd.kind)
		or KIND_ICON_ITEM[nd.kind]
	iconMemo[nd] = { v = dataV, id = id }
	return id
end
function G.ZoneIconID(zn)
	local m = iconMemo[zn]
	if m and m.v == dataV then return m.id end
	local id = ProduceItem(G.ZoneCat(zn), zn)
		or BestYieldItem(zn.items)
		or KIND_ICON_ITEM[zn.kind]
	iconMemo[zn] = { v = dataV, id = id }
	return id
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

-- GL_KIND comes from the registry (glCats) — GatherLite's
-- "fishing" category now maps to the fish kind too
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
	-- GatherLite's worldX/Y come from a different frame than our
	-- UnitPosition n,w — but GM.WorldPos is OUR transform, so the
	-- imported record can carry real world yards. Without n,w the
	-- route solver (nd.n gate) can't see the node at all, and a
	-- live gather at the same spawn can't merge with it either
	local nw, ww, cw = GM.WorldPos(e.mapID, e.posX, e.posY)
	local before = #(db.nodes[e.mapID] or {})
	local nd = MergeNode({
		map = e.mapID, x = e.posX, y = e.posY,
		n = nw, w = ww, c = cw,
	}, kind, GLNodeName(e), { mergeYd = GL_MERGE_YD, stamp = false })
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
	if items then
		UpdateYield(YieldRec(nd.name or kind), items)
		-- GatherLite tags the node type — an unmapped custom id
		-- riding a mining node IS ore; learn it once here. The
		-- family is the kind's registered item family
		local def = G.KindDefs[kind]
		local fam = def and def.cats and def.cats[1] or kind
		if GM.Gathering.LearnCat then
			local IC = GM.Gathering.ItemCat
			for id in pairs(items) do
				if not (IC and IC(id)) then
					GM.Gathering.LearnCat(id, fam)
				end
			end
		end
	end
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
	if stats.wiped > 0 then Bump() end
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

-- the player's riding skill picks the assumed travel speed —
-- no riding = on foot, basic riding = the +40% mount,
-- journeyman+ = +100%. Spell IDs first (vanilla riding spells),
-- then a spellbook scan for "Riding" + its rank word since
-- Forever may use custom IDs
function G.RidingIx()
	local known = IsSpellKnown or (C_Spell and C_Spell.IsSpellKnown)
	if known then
		if known(34091) or known(33391) then return 3 end
		if known(34090) or known(33388) then return 2 end
	end
	local tabs = GetNumSpellTabs and GetNumSpellTabs() or 0
	for t = 1, tabs do
		local _, _, off, n = GetSpellTabInfo(t)
		for s = (off or 0) + 1, (off or 0) + (n or 0) do
			local name, rank
			if GetSpellBookItemName then
				name, rank = GetSpellBookItemName(s, "spell")
			elseif GetSpellName then
				name, rank = GetSpellName(s, "spell")
			end
			local both = ((name or "") .. " " .. (rank or "")):lower()
			if both:find("riding") then
				if both:find("journeyman") or both:find("expert")
					or both:find("artisan") then
					return 3
				end
				return 2
			end
		end
	end
	return 1
end

-- transport-mode index the solver assumes: always the riding
-- skill — the UI no longer offers an override
function G.SpeedIx()
	return G.RidingIx()
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
-- crowd factor: solo by default — no UI control anymore, but the
-- model stays (db.contIx remains the programmatic override)
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

-- 2-opt is the only superlinear pass per loop — bound it by the
-- solve's shared deadline so a huge imported field degrades to the
-- nearest-neighbor order instead of stalling the frame
local function TwoOpt(order, pts, deadline)
	local n = #order
	local function leg(i, j)
		return DistYd(pts[order[i]], pts[order[j]]) or 1e9
	end
	local improved = true
	local passes = 0
	while improved and passes < 10 do
		if deadline and PerfNow() > deadline then return end
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
	TwoOpt(order, pts, ctx.deadline)
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

-- ======================== solve cache ========================
-- SolveRoute is a TSP over every node on a map — hundreds of
-- imported spawns cost seconds. Results key on dataV; misses and
-- TTL-expired entries queue into a pump solving ONE job per frame
-- tick, so Leaderboard (and window open) never blocks on the
-- solver. G.OnRouteSolved listeners repaint as rows stream in.
local SolveNow -- fwd: the wrapper below needs the real solver
local solveCache = {}
local SOLVE_TTL = 120 -- s; prices move without record writes
local solveQ, solveSeen, solveCbs = {}, {}, {}
local solvePump, lastCb

-- a solve's inputs, not just its epoch: respawn/speed/contention
-- can change without a record write (learned bounds, settings)
local function SolveKey(map, kind)
	return tostring(map) .. "|" .. kind .. "|" .. dataV .. "|"
		.. (db.speedIx or 2) .. "|" .. (db.contIx or 1) .. "|"
		.. tostring(G.RespawnSec(map, kind))
end

function G.OnRouteSolved(cb)
	solveCbs[#solveCbs + 1] = cb
end

local function EnqueueSolve(map, kind)
	local key = tostring(map) .. ":" .. kind
	if solveSeen[key] then return end
	solveSeen[key] = true
	solveQ[#solveQ + 1] = { map = map, kind = kind, key = key }
	if solvePump then solvePump:Show() end
end

solvePump = CreateFrame("Frame")
solvePump:Hide()
solvePump:SetScript("OnUpdate", function()
	local job = tremove(solveQ)
	if not job then solvePump:Hide() return end
	solveSeen[job.key] = nil
	G.SolveRoute(job.map, job.kind) -- writes through the cache
	local now = GetTime()
	-- stream the repaint: at most 4/s while draining, always on
	-- the last job so the final set lands promptly
	if #solveQ == 0 or now - (lastCb or 0) > 0.25 then
		lastCb = now
		for _, cb in ipairs(solveCbs) do pcall(cb) end
	end
end)

-- non-blocking read for the leaderboard: cache hit or enqueue —
-- the row simply isn't there until the pump lands it. Slightly
-- stale results still serve (a row beats a gap) while a fresh
-- solve queues behind them
local function SolveCached(map, kind)
	local e = solveCache[SolveKey(map, kind)]
	if not e or GetTime() - e.t >= SOLVE_TTL then
		EnqueueSolve(map, kind)
	end
	return e and e.r
end

-- the synchronous entry point (BUILD button, pump, tests): serve
-- a fresh cache hit, else solve now and write through
function G.SolveRoute(map, kind)
	local key = SolveKey(map, kind)
	local e = solveCache[key]
	if e and GetTime() - e.t < SOLVE_TTL then
		return e.r
	end
	local r = SolveNow(map, kind)
	solveCache[key] = { t = GetTime(), r = r }
	return r
end

-- pick the loop (possibly a sub-pocket of the zone) with the best
-- steady-state GPM under the given transport speed + learned
-- respawn. Stops in the result are node record refs — they survive
-- a later Solve without index remapping.
function SolveNow(map, kind)
	local list = NodeList(map)
	if not list then return nil end
	local pts, evs = {}, {}
	for _, nd in ipairs(list) do
		if nd.kind == kind then
			-- x,y-only records (older imports) backfill real world
			-- yards once — persists on the record, so the solver,
			-- minimap, and live-merge dedup all see the same frame
			if not nd.n and nd.x and nd.y then
				local n, w, c = GM.WorldPos(map, nd.x, nd.y)
				if n then nd.n, nd.w, nd.c = n, w, c end
			end
			-- either coordinate frame routes: cross-frame pairs
			-- get nil distance -> unlinked components, so mixed
			-- records can never corrupt a shared loop
			if nd.n or (nd.x and nd.y) then
				pts[#pts + 1] = nd
				evs[#evs + 1] = NodeEV(nd)
			end
		end
	end
	if #pts < 3 then
		local def = G.KindDefs[kind]
		-- standstill kinds (fishing): the farm IS one spot —
		-- no loop to solve; the best single record is the row,
		-- gpm = spot EV over the cast cadence
		if not (def and def.spot) or #pts == 0 then return nil end
		local bi
		for i = 1, #pts do
			if not bi or evs[i] > evs[bi] then bi = i end
		end
		local cyc = def.cycleSec or GATHER_SEC
		return {
			stops = { pts[bi] },
			kind = kind, map = map,
			speed = G.SPEEDS[db.speedIx or 2].yps,
			respawn = G.RespawnSec(map, kind),
			gpm = evs[bi] * 60 / cyc * G.ContF(),
			lapSec = cyc, yards = 0, evLoop = evs[bi],
			spot = true,
		}
	end

	local ctx = {
		speed = G.SPEEDS[db.speedIx or 2].yps,
		respawn = G.RespawnSec(map, kind),
		-- 200ms cap per solve: candidate loops share the budget, so
		-- 30 scattered pockets can't each burn their own
		deadline = PerfNow() + 200,
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
-- mob-level producer rows for a target item: every hunt:<mob>
-- yield that ever contained it, with observed chance, cautious EV
-- per kill, and the best-known zone to go farm it. Rows navigate
-- through .map/.zone like area rows.
function G.MobRows(id)
	if not id then return {} end
	local rows = {}
	for key, rec in pairs(db.yields or {}) do
		local mob = key:match("^hunt:(.+)$")
		if mob and rec.items and (rec.items[id] or 0) > 0 then
			local cnt = rec.cnt or 0
			local h = (rec.hits and rec.hits[id])
				or min(rec.items[id], cnt)
			local stack = h > 0 and (rec.items[id] / h) or 0
			local evK = cnt > 0
				and WilsonLow(h, cnt) * stack * (ItemVal(id) or 0)
				or 0
			-- best zone = where this mob has died the most
			local bestMap, bestZn, bestK
			for map, zl in pairs(db.zones or {}) do
				for _, zn in ipairs(zl) do
					local mk = zn.mobs and zn.mobs[mob]
					if mk and (not bestK or mk > bestK) then
						bestMap, bestZn, bestK = map, zn, mk
					end
				end
			end
			tinsert(rows, {
				mob = true, kind = "hunt", mobName = mob,
				map = bestMap, zone = bestZn,
				zoneName = bestZn and bestZn.area
					or (bestMap and G.ZoneName(bestMap) or nil),
				kills = cnt,
				chance = cnt > 0 and (h / cnt) or 0,
				stack = stack,
				evLoop = evK, gpm = evK,
				conf = cnt < 5 and "low" or cnt < 15 and "fair"
					or cnt < 50 and "good" or "high",
				unitSuffix = "/kill",
			})
		end
	end
	table.sort(rows, function(a, b) return a.evLoop > b.evLoop end)
	return rows
end

-- does any mob recorded in this zone drop the item? distinguishes
-- mob-attributed production from unattributed legacy data
function G.ZoneHasMobDrop(zn, id)
	for mob in pairs(zn.mobs or {}) do
		local y = db.yields and db.yields["hunt:" .. mob]
		if y and y.items and (y.items[id] or 0) > 0 then
			return true
		end
	end
	return false
end

-- display rows for a yield record's drop table: observed % per
-- item, market value, sorted by expected value contribution.
-- Node names also fall back to the static loot table when the
-- node was never tapped (pct = the static estimate)
-- shared observed-table builder: yields and zone records carry the
-- same items/hits/cnt shape
local function RecRows(y)
	local rows = {}
	if not y or not y.items then return rows end
	for id, qty in pairs(y.items) do
		local h = (y.hits and y.hits[id])
			or min(qty, y.cnt or 0)
		local v = ItemVal(id)
		local stack = h > 0 and qty / h or qty
		local ev = (y.cnt or 0) > 0
			and (h / y.cnt) * stack * (v or 0) or 0
		tinsert(rows, {
			id = id,
			name = GM.ItemNameOr and GM.ItemNameOr(id)
				or ("item " .. id),
			pct = (y.cnt or 0) > 0 and (h / y.cnt * 100) or nil,
			-- expected units per event — the drop RATE, vs pct's
			-- drop chance (2x-a-30%-drop reads 0.6/k)
			rate = (y.cnt or 0) > 0 and qty / y.cnt or nil,
			value = v,
			sort = ev,
		})
	end
	table.sort(rows, function(a, b) return a.sort > b.sort end)
	return rows
end

-- a zone's own loot table — the expansion's "entire recorded
-- drop list" for a farm camp
function G.ZoneDropRows(zn)
	return RecRows(zn)
end

-- expansion detail for a zone row: top mobs by kill count, each
-- with its observed drop table, then the camp total — the "break
-- down of the mob drops" view
function G.ZoneDetail(zn)
	local sec, mobs = {}, {}
	for name, n in pairs(zn.mobs or {}) do
		mobs[#mobs + 1] = { name, n }
	end
	table.sort(mobs, function(a, b) return a[2] > b[2] end)
	-- skin zones record mob tables under skin:<mob>
	local pfx = zn.kind == "skin" and "skin:" or "hunt:"
	for i = 1, min(3, #mobs) do
		local name = mobs[i][1]
		sec[#sec + 1] = {
			head = name .. " ×" .. mobs[i][2],
			cnt = mobs[i][2],
			rows = G.DropRows(pfx .. name),
		}
	end
	sec[#sec + 1] = {
		head = "camp total — " .. (zn.kills or 0) .. " kills",
		cnt = zn.kills, rows = RecRows(zn), total = true,
	}
	return sec
end

function G.DropRows(key)
	local y = db.yields and db.yields[key]
	local rows = {}
	if y and y.items then
		return RecRows(y)
	elseif GM.Gathering and GM.Gathering.nodes
		and GM.Gathering.nodes[key] then
		for _, d in ipairs(GM.Gathering.nodes[key]) do
			local v = ItemVal(d.id)
			tinsert(rows, {
				id = d.id,
				name = GM.ItemNameOr and GM.ItemNameOr(d.id)
					or ("item " .. d.id),
				pct = d.pct,
				value = v,
				sort = (d.pct or 0) / 100
					* ((d.lo + d.hi) / 2) * (v or 0),
			})
		end
	end
	table.sort(rows, function(a, b) return a.sort > b.sort end)
	return rows
end

-- tooltip drop-table blocks for a mob/node name, built from what
-- we OBSERVED: "drops" (hunt yields), "skinning" (skin yields),
-- or "observed" (node taps). Each block's header carries EV/event
-- and the "EV ≈" marker Gathering.lua's dedupe scans for. No data
-- = empty table — callers keep their own static fallbacks.
function G.DropLines(name)
	if not name or not GM.Widgets then return {} end
	local tid = db.target
	local lines = {}
	for _, b in ipairs({
		{ key = "hunt:" .. name, label = "drops", unit = "kills" },
		{ key = "skin:" .. name, label = "skinning", unit = "skins" },
		{ key = name, label = "observed", unit = "taps" },
	}) do
		local y = db.yields and db.yields[b.key]
		if y and y.items and next(y.items) then
			local rows = G.DropRows(b.key)
			local ev = 0
			for _, r in ipairs(rows) do ev = ev + r.sort end
			lines[#lines + 1] = GM.CC("secondary")
				.. format("%s — %d %s · EV ≈ %s|r",
					b.label, y.cnt or 0, b.unit,
					GM.MoneyShort(ev))
			for _, s in ipairs(GM.Widgets.DropLines(rows,
				{ target = tid })) do
				lines[#lines + 1] = s
			end
		end
	end
	return lines
end

-- a camp's display category = the gather family that dominates
-- its recorded drops by qty — "cloth camp" vs "meat camp" vs a
-- generic hunt. The zone's record kind stays the merge key;
-- this is presentational (row label, disc tint)
function G.ZoneCat(zn)
	if zn.kind == "skin" then return "skin" end
	local IC = GM.Gathering and GM.Gathering.ItemCat
	if not IC then return zn.kind end
	local tot
	for id, q in pairs(zn.items or {}) do
		local c = IC(id)
		if c then
			tot = tot or {}
			tot[c] = (tot[c] or 0) + (tonumber(q) or 0)
		end
	end
	if not tot then return zn.kind end
	local best, bq
	for c, q in pairs(tot) do
		if q > (bq or 0) then best, bq = c, q end
	end
	-- ItemCat families map onto the kind taxonomy — "ore" was the
	-- hole: the row tag read raw "ore" and the MINE filter missed
	return best == "flesh" and "cook"
		or best == "leather" and "skin"
		or best == "ore" and "mine"
		or best == "fish" and "fish"
		or best or zn.kind
end

-- zone-merge pass is O(camps²) — run it once per data version,
-- not once per leaderboard rebuild
local coalV
function G.Leaderboard()
	if coalV ~= dataV then
		CoalesceZones()
		coalV = dataV
	end
	local rows = {}
	-- node kinds from the registry: cached hits render now,
	-- misses stream in via the solve pump (OnRouteSolved)
	for map in pairs(db.nodes or {}) do
		for kind in pairs(G.NODE_KINDS) do
			local r = SolveCached(map, kind)
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
			-- targeted: the row answers "what does FARMING THE
			-- TARGET pay" — target qty/kill (misses dilute via
			-- cnt) x price, not the mob's whole loot table
			local tid = db.target
			local evT
			if tid and zn.cnt and zn.cnt > 0
				and (zn.items[tid] or 0) > 0 then
				local h = (zn.hits and zn.hits[tid])
					or min(zn.items[tid], zn.cnt)
				evT = WilsonLow(h, zn.cnt)
					* (zn.items[tid] / h)
					* (ItemVal(tid) or 0)
			end
			local evS, evR = evT or evSus, evT or ev
			-- the time-diff row needs: headline = sustained
			-- projection, "earned" = wall-clock receipt over the
			-- A1..An sequence (falls back to the old projection
			-- until the zone has a two-event log)
			local wall = G.ZoneWall(zn)
			tinsert(rows, {
				area = true, map = map, zone = zn,
				kind = G.ZoneCat(zn),
				zoneName = G.ZonePlace(zn) or G.ZoneName(map),
				gpm = evS * sus,
				gpmRaw = (wall and wall.gpm) or (evR * rate),
				evLoop = evS, evRaw = evR,
				lapSec = G.ZoneCycle(zn)
					or (rate > 0 and (60 / rate) or 0),
				kills = zn.kills,
				spawns = #(zn.pockets or {}),
				-- GoldScout confidence tiers — small samples are
				-- estimates, flagged on the row
				conf = zn.kills < 5 and "low"
					or zn.kills < 15 and "fair"
					or zn.kills < 50 and "good" or "high",
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
local run -- active route instance (declared early: NavDiag reads it)
local tick -- arrival ticker (declared early: StartRoute shows it)
local navErr, routeErr -- last tick errors (NavDiag reports them)

local function NavCVar(name)
	local get = C_CVar and C_CVar.GetCVar or GetCVar
	if type(get) ~= "function" then return end
	local ok, v = pcall(get, name)
	if ok then return v end
end

local function NavCVarSet(name, v)
	local set = C_CVar and C_CVar.SetCVar or SetCVar
	if type(set) ~= "function" then return end
	return pcall(set, name, v)
end

-- normalize the client waypoint slot — Forever's position is a
-- plain {x,y} table, modern clients hand back a GetXY vector.
-- Returns the raw point (for re-setting) + normalized map/x/y.
local function NavWaypoint()
	if not (C_Map and C_Map.GetUserWaypoint) then return end
	local ok, p = pcall(C_Map.GetUserWaypoint)
	if not ok or not p then return nil, ok and "empty" or p end
	local pos = p.position or p
	local x, y
	if pos.GetXY then x, y = pos:GetXY() end
	return p, p.uiMapID or p.map, x or pos.x, y or pos.y
end

-- does the slot still hold OUR point? Release-side ownership
-- check — a hand-placed pin between our set and release isn't
-- ours to clear or restore over
local function NavOwns(raw, map, x, y)
	local t = nav.pt
	return raw and t and map == t.map
		and x and y
		and math.abs(x - t.x) < .001
		and math.abs(y - t.y) < .001
end

-- the waypoint only renders in the 3D world while the client's
-- in-game navigation display is on — MapWise's
-- EnsureNavigationSetting: only flip an explicit '0', own it so a
-- later release restores, never poke an unreadable cvar
local function NavEnsureDisplay()
	if nav.cvarOwned then return end -- already own the flip
	if NavCVar("showInGameNavigation") ~= "0" then return end
	if NavCVarSet("showInGameNavigation", "1")
		and NavCVar("showInGameNavigation") == "1" then
		nav.cvarOwned = "0"
	end
end

-- tracking snapshot: what was super-tracked before we hijack —
-- release puts a tracked quest back instead of leaving nothing
local function NavTracking()
	if not C_SuperTrack then return end
	local qid
	if C_SuperTrack.IsSuperTrackingQuest
		and C_SuperTrack.GetSuperTrackedQuestID then
		local okQ, q = pcall(C_SuperTrack.IsSuperTrackingQuest)
		local okI, id = pcall(C_SuperTrack.GetSuperTrackedQuestID)
		if okQ and q and okI and type(id) == "number"
			and id > 0 then qid = id end
	end
	return qid
end

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
	if not nav.savedSet then
		local prev, meta = NavWaypoint()
		if prev or meta == "empty" then
			nav.saved = prev
			nav.savedSet = true
		end
		nav.prevQuest = NavTracking()
	end
	local okP, pt = pcall(UiMapPoint.CreateFromCoordinates, map, x, y)
	if not okP or not pt then return nil, "bad point" end
	local okS, err = pcall(C_Map.SetUserWaypoint, pt)
	if not okS then return nil, tostring(err) end
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
	end
	NavEnsureDisplay()
	-- remember what we own — the readback if it resolves (the
	-- client may normalize), else the point we asked for; release
	-- only clears a slot that still matches
	local cur, cm, cx, cy = NavWaypoint()
	nav.pt = (cur and cm and cx and cy)
		and { map = cm, x = cx, y = cy }
		or { map = map, x = x, y = y }
	nav.ours = true
	return true
end

-- the client only projects the tracked target — nothing renders
-- it. MapWise's trick, ported: our own UIParent marker anchored
-- at the nav frame's projected screen position each tick. A gold
-- pulse ring + skull + live distance; when the target clamps to
-- the screen edge the native arrow owns the visual and we hide.
local marker

local function NavHideMarker()
	if marker then marker:Hide() end
end

local PULSE_SPEED = 2 * math.pi / 2.4 -- ring period, MapWise's 2.4s

local function NavMarker()
	if marker then return marker end
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetSize(96, 96)
	f:EnableMouse(false)
	f:SetFrameStrata("HIGH")
	local ring = CreateFrame("Frame", nil, f)
	ring:SetPoint("CENTER")
	ring:SetSize(72, 72)
	ring:EnableMouse(false)
	local rad = 30
	for i = 1, 32 do
		local a, b = (i - 1) * 2 * math.pi / 32,
			i * 2 * math.pi / 32
		local ln = ring:CreateLine(nil, "OVERLAY")
		ln:SetThickness(2.5)
		ln:SetColorTexture(1, .82, .25, 1)
		ln:SetStartPoint("CENTER", ring,
			rad * math.cos(a), rad * math.sin(a))
		ln:SetEndPoint("CENTER", ring,
			rad * math.cos(b), rad * math.sin(b))
	end
	f.ring = ring
	local ic = f:CreateTexture(nil, "OVERLAY")
	ic:SetPoint("CENTER")
	ic:SetSize(38, 38)
	ic:SetTexture(
		"Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
	f.icon = ic
	local d = f:CreateFontString(nil, "OVERLAY",
		"NumberFontNormal")
	d:SetPoint("TOP", f, "CENTER", 0, -52)
	d:SetTextColor(1, .82, .25)
	d:SetJustifyH("CENTER")
	f.dist = d
	f.age = 0
	f:Hide()
	marker = f
	return f
end

local function NavDrawMarker(elapsed)
	local f = marker
	if not f then return end
	local gone = NavHideMarker
	if not nav.ours then return gone() end
	if WorldMapFrame and WorldMapFrame.IsShown then
		local okW, shown = pcall(WorldMapFrame.IsShown,
			WorldMapFrame)
		if okW and shown then return gone() end
	end
	if not (C_Navigation
		and C_Navigation.HasValidScreenPosition
		and C_Navigation.GetFrame) then return gone() end
	local okS, valid = pcall(C_Navigation.HasValidScreenPosition)
	if not okS or not valid then return gone() end
	if C_Navigation.WasClampedToScreen then
		local okC, cl = pcall(C_Navigation.WasClampedToScreen)
		if okC and cl then return gone() end -- edge arrow owns it
	end
	local okF, nf = pcall(C_Navigation.GetFrame)
	if not okF or not nf or not nf.GetCenter
		then return gone() end
	local okX, x, y = pcall(nf.GetCenter, nf)
	if not okX or not x or not y or x <= 0 or y <= 0
		then return gone() end
	local lvl = 0
	if nf.GetFrameLevel then
		local okL, l = pcall(nf.GetFrameLevel, nf)
		if okL and l then lvl = l end
	end
	f:SetFrameLevel(lvl + 1)
	f:ClearAllPoints()
	f:SetPoint("CENTER", nf, "CENTER")
	f.age = f.age + (elapsed or 0)
	f.ring:SetAlpha(.25 + .65
		* (1 + math.cos(f.age * PULSE_SPEED)) * .5)
	if C_Navigation.GetDistance then
		local okD, dd = pcall(C_Navigation.GetDistance)
		if okD and type(dd) == "number" and dd >= 0 then
			f.dist:SetFormattedText("%d yd", dd)
		else
			f.dist:SetText("")
		end
	end
	f:Show()
end

-- a throwing OnUpdate is an error storm: wrap the draw, print
-- each distinct error once, and park the marker until the next
-- successful pass. navErr clears on success so a transient
-- fault doesn't mute every future report.
local navDriver = CreateFrame("Frame")
navDriver:SetScript("OnUpdate", function(_, elapsed)
	if not (nav.ours or (marker and marker:IsShown()))
		then return end
	if nav.ours and not marker then NavMarker() end
	local ok, err = pcall(NavDrawMarker, elapsed)
	if ok then
		navErr = nil
	elseif err ~= navErr then
		navErr = err
		GM.Print(GM.CC("bad") .. "nav marker: "
			.. tostring(err) .. "|r")
		NavHideMarker()
	end
end)

local function NavRelease()
	if not nav.ours then return end
	nav.ours = nil
	if marker then marker:Hide() end
	local cur, cm, cx, cy = NavWaypoint()
	local restoreSaved = nav.savedSet and nav.saved
		and C_Map.SetUserWaypoint
	if cur and NavOwns(cur, cm, cx, cy) then
		-- still our pin — clear, then put back what we replaced
		if C_Map.ClearUserWaypoint then
			pcall(C_Map.ClearUserWaypoint)
		end
		if restoreSaved then
			pcall(C_Map.SetUserWaypoint, nav.saved)
		end
	elseif not cur and restoreSaved then
		-- slot's already empty — restoring a hand-cleared pin is
		-- still the polite move
		pcall(C_Map.SetUserWaypoint, nav.saved)
	end
	-- foreign pin in the slot: leave it, drop our claim entirely
	nav.saved, nav.savedSet, nav.pt = nil, nil, nil
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false)
	end
	if nav.prevQuest and C_SuperTrack
		and C_SuperTrack.SetSuperTrackedQuestID then
		pcall(C_SuperTrack.SetSuperTrackedQuestID, nav.prevQuest)
	end
	nav.prevQuest = nil
	if nav.cvarOwned then
		-- only restore while it's still on — a manual switch-off
		-- is the user's call, we just drop ownership
		local v = NavCVar("showInGameNavigation")
		if v == "1" or v == nil then
			NavCVarSet("showInGameNavigation", nav.cvarOwned)
		end
		nav.cvarOwned = nil
	end
end

-- point the native waypoint at a recorded position (map coords);
-- falls back to a chat hint when the API isn't there
function G.PointAt(p)
	if p.x and p.y and p.map then
		local ok, err = G.NavTo(p.map, p.x, p.y)
		if ok then nav.lastErr = nil return true end
		if err ~= nav.lastErr then
			nav.lastErr = err
			GM.Print(GM.CC("textDim") .. "waypoint: "
				.. tostring(err) .. "|r")
		end
		return nil
	end
	return nil
end

-- /goblin navdebug — dump the entire navigation chain: which
-- APIs this client actually has, the cvar, the waypoint slot,
-- tracking state, and our own ownership flags. The 3D marker
-- needs every link; this names the missing one
function G.NavDiag()
	local d = { ours = nav.ours, cvarOwned = nav.cvarOwned,
		run = run ~= nil, navErr = navErr, routeErr = routeErr }
	local function has(t, n)
		return t and type(t[n]) == "function"
	end
	d.api = {
		C_Navigation = C_Navigation ~= nil,
		navGetFrame = has(C_Navigation, "GetFrame"),
		navScreenPos = has(C_Navigation,
			"HasValidScreenPosition"),
		SetUserWaypoint = has(C_Map, "SetUserWaypoint"),
		GetUserWaypoint = has(C_Map, "GetUserWaypoint"),
		CanSetOnMap = has(C_Map, "CanSetUserWaypointOnMap"),
		SuperTrackSet = has(C_SuperTrack,
			"SetSuperTrackedUserWaypoint"),
		SuperTrackIs = has(C_SuperTrack,
			"IsSuperTrackingUserWaypoint"),
		UiMapPoint = UiMapPoint ~= nil
			and type(UiMapPoint.CreateFromCoordinates)
				== "function",
	}
	d.cvar = NavCVar("showInGameNavigation")
	if d.api.GetUserWaypoint then
		local p, m, x, y = NavWaypoint()
		if p then
			d.wp = { map = m, x = x, y = y }
		else
			d.wp = m == "empty" and "nil" or ("err:" .. tostring(m))
		end
	end
	if d.api.SuperTrackIs then
		local ok, v = pcall(
			C_SuperTrack.IsSuperTrackingUserWaypoint)
		d.tracking = ok and v or ("err:" .. tostring(v))
	end
	if C_Navigation and C_Navigation.GetTargetState then
		local ok, v = pcall(C_Navigation.GetTargetState)
		d.navState = ok and v or ("err:" .. tostring(v))
	end
	if C_Navigation
		and C_Navigation.HasValidScreenPosition then
		local ok, v = pcall(
			C_Navigation.HasValidScreenPosition)
		d.navScreen = ok and v or ("err:" .. tostring(v))
	end
	if C_Navigation and C_Navigation.WasClampedToScreen then
		local ok, v = pcall(C_Navigation.WasClampedToScreen)
		d.navClamped = ok and v or ("err:" .. tostring(v))
	end
	if C_Navigation and C_Navigation.GetFrame then
		local okF, nf = pcall(C_Navigation.GetFrame)
		if okF and nf and nf.GetCenter then
			local okX, x, y = pcall(nf.GetCenter, nf)
			d.navFrame = okX and format("%.0f,%.0f",
				x or -1, y or -1) or ("err:" .. tostring(x))
		else
			d.navFrame = "missing"
		end
	end
	if C_Navigation and C_Navigation.GetDistance then
		local ok, v = pcall(C_Navigation.GetDistance)
		d.navDist = ok and v or ("err:" .. tostring(v))
	end
	d.questTracking = NavTracking()
	return d
end

-- waypoint the stop nearest the player — the MapWise
-- checkpoint-chase: you join a loop where it's closest, not at
-- stop 1. Returns the winning index (falls back to 1)
local function NearestStop(stops)
	local p, best, bd = PosNow(), 1, math.huge
	if not p then return best end
	for i, st in ipairs(stops) do
		local d = DistYd(p, st)
		if d and d < bd then bd, best = d, i end
	end
	return best
end

function G.NavRoute(r)
	if not (r and r.stops and r.stops[1]) then return nil end
	return G.PointAt(r.stops[NearestStop(r.stops)])
end

-- ======================== route running ========================

-- active loop: stop refs (survive later solves), index, arrival
-- stamps for lap timing. A full observed lap beats the model —
-- folded into lapObs so the next GPM is measured, not guessed.
function G.StartRoute(r)
	if not r or not r.stops or #r.stops < 2 then return end
	-- join at the nearest stop — it's a loop, any entry is the
	-- head; marching to stop 1 first wasted a whole leg
	run = { route = r, stops = r.stops,
		idx = NearestStop(r.stops) }
	r.running = true
	tick:Show()
	G.PointAt(r.stops[run.idx])
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

-- persist a solved loop: stops serialize as plain positions so
-- the saved route survives node-record churn and reloads. The
-- run only needs map/x/y (+name for display).
function G.SaveRoute(r)
	if not (r and r.map and r.stops and #r.stops > 1) then
		return nil, "no route to save"
	end
	db.saved = db.saved or {}
	local stops = {}
	for i, st in ipairs(r.stops) do
		stops[i] = {
			x = st.x, y = st.y, map = st.map or r.map,
			name = st.name or (st.nd and st.nd.name),
		}
	end
	db.saved[r.map .. ":" .. (r.kind or "?")] = {
		map = r.map, kind = r.kind, stops = stops,
		lapSec = r.lapSec, evLoop = r.evLoop, gpm = r.gpm,
	}
	return true
end

-- best saved loop for a map, kind-pinned when given
function G.LoadRoute(map, kind)
	local best
	for _, r in pairs(db.saved or {}) do
		if r.map == map and (not kind or r.kind == kind)
			and (not best or (r.gpm or 0) > (best.gpm or 0)) then
			best = r
		end
	end
	if best and GM.GatherMap then
		GM.GatherMap.NoteRoute(best)
	end
	return best
end

-- drop a map's route: the noted overlay and a running instance.
-- forget=true also deletes the saved record — plain clears used
-- to nuke the save too, which read as "save doesn't work" when
-- the user cleared the display then tried to load it back
function G.ClearRoute(map, forget)
	if not map then return nil end
	local touched
	if forget and db.saved then
		for k in pairs(db.saved) do
			if tonumber(k:match("^(%d+):")) == map then
				db.saved[k] = nil
				touched = true
			end
		end
	end
	if run and run.route and run.route.map == map then
		G.StopRoute()
		touched = true
	end
	if GM.GatherMap and GM.GatherMap.RouteFor(map) then
		GM.GatherMap.ClearRoute(map)
		touched = true
	end
	return touched
end

-- full wipe: nodes/zones/yields/respawns/journal/saved routes
function G.ClearData()
	Bump()
	wipe(db.nodes)
	wipe(db.zones)
	wipe(db.yields)
	wipe(db.resp)
	wipe(db.journal)
	wipe(db.saved or {})
	G.StopRoute()
end

-- arrival check + lap timing, 4x/sec while a route runs. The
-- body is pcall'd like the nav driver — this ticker was dead
-- code until the forward-declare fix, so it earns the same
-- once-per-error reporting instead of a storm
tick = CreateFrame("Frame")
tick:Hide()
tick.acc = 0
tick:SetScript("OnUpdate", function(_, dt)
	tick.acc = tick.acc + dt
	if tick.acc < 0.25 then return end
	tick.acc = 0
	local ok, err = pcall(function()
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
	if ok then
		routeErr = nil
	elseif err ~= routeErr then
		routeErr = err
		GM.Print(GM.CC("bad") .. "route tick: "
			.. tostring(err) .. "|r")
	end
end)

-- ======================== loot capture ========================

local arm -- { kind, pos, until_ }
local Journal -- forward decl: ArmWindow runs before its definition

local function ArmWindow(kind, until_)
	local prev = arm
	arm = {
		kind = kind, pos = PosNow(),
		until_ = until_ or (GetTime() + (G.KindDefs[kind]
			and G.KindDefs[kind].armSec or WINDOW_SEC)),
	}
	-- a second source may arm the same cast (SUCCEEDED's fixed
	-- fallback lands after CHANNEL_START's channel-derived end —
	-- the shorter window must not clobber the longer one
	if prev and prev.kind == kind and prev.until_ > arm.until_ then
		arm = prev
		return
	end
	Journal("arm", { mob = kind,
		items = format("%.1fs", arm.until_ - GetTime()) })
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

-- ======================== loot journal ========================
-- rolling forensic record of every loot window and what we did
-- with it — the "where did that number come from" surface.
-- Bounded + persisted; /goblin gatherlog prints it.
local JOURNAL_MAX = 60
function Journal(what, e)
	db.journal = db.journal or {}
	local j = db.journal
	e = e or {}
	e.w = what
	e.t = GetTime()
	e.rt = time and time() or nil
	j[#j + 1] = e
	if #j > JOURNAL_MAX then tremove(j, 1) end
end

-- item-derived source verdict: a window whose contents are ALL
-- one gather-material family is a node/skin tap even with no
-- cast arm — Forever gathers instantly (right-click, no
-- UNIT_SPELLCAST_SUCCEEDED), so the arm is usually nil and a
-- vein looted beside a fresh corpse would otherwise read as a
-- kill. Cloth/flesh are corpse loot, not gathers — mixed or
-- corpse-family windows return nil and stay on the kill path.
-- Leather is the ambiguous family: a corpse's own window can
-- carry dropped scales/leather, so it only counts as a skin
-- event when it trails a recent kill on the same mob (the
-- skin-loot pattern) — a leather-bearing first window is corpse
-- loot.
local lastKill -- { t, mob } — anchors the skin-tail check
local SKIN_TAIL_S = 4
local function WindowKind(items, mob)
	local IC = GM.Gathering and GM.Gathering.ItemCat
	if not (IC and items) then return nil end
	local cat, unknown
	for id in pairs(items) do
		local c = IC(id)
		if c then
			-- registry veto — a family marked corpse cargo (cloth,
			-- flesh, fish) can never classify a window on its own.
			-- Unclassified items ride the verdict instead: a
			-- Mithril+Bauxite window is still a vein even though
			-- Bauxite has no family entry
			local kd = CAT_KIND[c] and G.KindDefs[CAT_KIND[c]]
			if not kd or kd.corpse then return nil end
			if cat and c ~= cat then return nil end
			cat = c
		else
			unknown = unknown or {}
			unknown[#unknown + 1] = id
		end
	end
	if not cat then return nil end
	local kd = CAT_KIND[cat] and G.KindDefs[CAT_KIND[cat]]
	-- tailKill families (leather): a corpse's own window can carry
	-- dropped scales, so it only counts trailing a recent kill on
	-- the same mob — a leather-bearing first window is corpse loot
	if kd.tailKill
		and not (lastKill and (not mob or mob == lastKill.mob)
			and GetTime() - lastKill.t <= SKIN_TAIL_S) then
		return nil
	end
	-- accepted window: teach the unknowns this family so a later
	-- solo drop of the same custom item classifies on its own
	if unknown and GM.Gathering.LearnCat then
		for _, id in ipairs(unknown) do
			GM.Gathering.LearnCat(id, cat)
		end
	end
	return CAT_KIND[cat]
end

-- name an unarmed gather tap by its contents: a window of Iron
-- Ore + Heavy Stone IS an Iron Deposit — the unit API can't name
-- objects on this client, but the loot identifies the node type
local function NodeNameFor(items)
	local N = GM.Gathering and GM.Gathering.nodes
	if not (N and items) then return nil end
	local best, bs
	for name, drops in pairs(N) do
		local hit, miss = 0, 0
		for id in pairs(items) do
			local has
			for _, d in ipairs(drops) do
				if d.id == id then has = true break end
			end
			if has then hit = hit + 1 else miss = miss + 1 end
		end
		-- unmodeled drops (customs like Bauxite) shouldn't blank
		-- the name: half-weight misses so a vein still names
		-- itself off the items it DOES share with the DB
		local score = hit - miss * 0.5
		if hit > 0 and score > (bs or 0) then
			best, bs = name, score
		end
	end
	return best
end

local function ItemStr(items)
	if not items then return "-" end
	local p = {}
	for id, q in pairs(items) do
		-- per-item attributed value — the phantom-price smoking gun:
		-- whichever id carries the giant number IS the culprit
		p[#p + 1] = id .. (q > 1 and ("x" .. q) or "")
			.. "@" .. tostring(ItemVal(id) or "?")
	end
	table.sort(p)
	return #p > 0 and table.concat(p, "·") or "none"
end

local function OnLoot()
	if not (GetNumLootItems and GetLootSlotInfo) then return end
	local items, first = LootItems()
	if not items then
		-- an open window with zero item slots = money-only or
		-- truly empty — still a kill event for hunt zones
		if GetNumLootItems() ~= 0 then
			Journal("unparsed", { n = GetNumLootItems() })
			return
		end
		items = {}
	end
	local t = GetTime()
	local sig = tostring(first) .. ":" .. tostring(GetNumLootItems())
	if lastLootSig == sig and t - (lastLootT or 0) < 0.5 then
		Journal("dup", { sig = sig })
		return
	end
	lastLootSig, lastLootT = sig, t

	-- the window's own target — node objects can report names on
	-- some clients; the corpse scan below may reassign srcName to
	-- the dead unit's name instead
	local winName
	for _, unit in ipairs({ "target", "mouseover" }) do
		local nm = UnitName and UnitName(unit)
		if nm then winName = nm break end
	end

	-- corpse scan FIRST: it gates both the gather-vs-kill
	-- disambiguation and the hunt attribution. A live NPC's name
	-- or a stale target must not fabricate kills; only a dead
	-- unit or an unresolvable-API name passes. The corpse must
	-- also have been ATTACKABLE — a permanently-dead questgiver
	-- is not a kill. UnitCanAttack doesn't exist on some
	-- 1.12-API clients; UnitIsFriend/UnitReaction are the
	-- classic-era belts for the same check
	local srcName = winName
	local deadFn = UnitIsDeadOrGhost or UnitIsDead
	local srcDead = srcName ~= nil
	if deadFn then
		srcDead, srcName = false, nil
		for _, u in ipairs({ "target", "mouseover" }) do
			local okD, dead = pcall(deadFn, u)
			-- only an explicit "can't attack"/"is friendly"
			-- disqualifies — a nil or absent API can't disprove the
			-- corpse was killable
			local atk = true
			if UnitCanAttack then
				local okA, a = pcall(UnitCanAttack, "player", u)
				if okA and a == false then atk = false end
			end
			if atk and UnitIsFriend then
				local okF, fr = pcall(UnitIsFriend, "player", u)
				if okF and fr then atk = false end
			end
			if atk and UnitReaction then
				local okR, rx = pcall(UnitReaction, "player", u)
				if okR and rx and rx >= 5 then atk = false end
			end
			if okD and dead and atk then
				srcDead = true
				local nm = UnitName and UnitName(u)
				if nm then srcName = nm break end
			end
		end
		if not srcName then srcName = winName end
	end

	-- disposition: an armed cast wins; the item verdict overrides
	-- when they disagree (instant gather arrives unarmed on
	-- Forever — a vein beside a corpse is a NODE, not a kill);
	-- an arm with corpse-looking loot + a confirmed corpse means
	-- the corpse window won the race, so the arm is dropped.
	-- skin keeps its arm — a skinnable's own window legitimately
	-- holds flesh/cloth loot
	local wkind = WindowKind(items, srcName)
	local armValid = arm and t <= arm.until_ and true or false
	local gKind
	if armValid then
		gKind = arm.kind
		-- item verdict overrides the cast (instant gather arrives
		-- unarmed on Forever — a vein beside a corpse is a NODE,
		-- not a kill) — except where the cast names the object:
		-- a chest holding ore-family loot is still a chest
		if wkind and wkind ~= gKind
			and not (G.KindDefs[gKind]
				and G.KindDefs[gKind].armWins) then
			gKind = wkind
		elseif not wkind and srcDead and next(items)
			and not (G.KindDefs[gKind]
				and G.KindDefs[gKind].keepArm) then
			gKind = nil
		end
	else
		gKind = wkind
	end
	if arm and not armValid then
		Journal("expired", { mob = arm.kind,
			items = format("%.1fs", t - arm.until_) })
	end
	local gPos = arm and arm.pos or nil
	arm = nil

	if gKind then
		local pos = gPos or PosNow()
		if not pos then return end
		if G.NODE_KINDS[gKind] then
			-- name the node: contents first (ore+stone IS the
			-- vein type), then the window target — trusted when a
			-- cast armed this loot or no corpse could be
			-- impersonating the node
			local nm = (gKind == "chest" and "Chest")
				or NodeNameFor(items)
				or ((armValid or not srcDead) and winName)
			local nd
			if gKind == "fish" then
				-- school vs open water: a catch near a KNOWN pool
				-- (imported spawn or recorded node) is that pool's
				-- hit — 36yd because the record stores the player's
				-- spot, not the pool's. Anything else is open-water
				-- fishing: a fishable AREA zoned like a hunt camp —
				-- catches are the camp's "kills", pockets are the
				-- spots fished inside it
				nd = MergeNode(pos, gKind, nm,
					{ mergeOnly = true, mergeYd = 36 })
				if not nd then
					local zn, tail = MergeZone(pos, "fish", items)
					UpdateYield(YieldRec("fish"), items, tail)
					Journal(tail and "tail" or "zone",
						{ kind = "fish", mob = zn and zn.area,
							items = ItemStr(items),
							k = zn and zn.kills })
					if GM.GatherMap then
						GM.GatherMap.Refresh()
					end
					return
				end
			else
				nd = MergeNode(pos, gKind, nm)
			end
			UpdateYield(YieldRec(
				nd and nd.name or gKind), items)
			Journal("node", { kind = gKind, mob = nm or winName,
				items = ItemStr(items) })
		else
			-- skinning: a skinned corpse is a kill event — zone it,
			-- and record yields under both the generic key and the
			-- mob name
			-- money cap: no mob corpse legitimately carries 5g+
			-- of loot cash; an over-large return is a broken API
			-- reading the purse, not the window
			local rawM = (GetLootMoney and GetLootMoney()) or 0
			local money = min(rawM, 50000)
			local zn, tail = MergeZone(pos, "skin", items, srcName, money)
			UpdateYield(YieldRec("skin"), items, tail)
			if srcName then
				UpdateYield(YieldRec("skin:" .. srcName), items, tail)
			end
			Journal(tail and "tail" or "skin", {
				mob = srcName, items = ItemStr(items),
				money = rawM, v = (LootValue(items) or 0) + money,
				k = zn and zn.kills })
		end
		if GM.GatherMap then GM.GatherMap.Refresh() end
		return
	end

	-- no gather verdict: a kill loot = a hunt kill. Any item at all
	-- seeds the zone — the per-item yield map is what lets target
	-- mode answer "where does raptor flesh drop" for drops we never
	-- modeled. An EMPTY window still counts when the source is a
	-- confirmed corpse: a kill with no drops is a failed farm and
	-- must dilute the mean, or per-kill EV only ever sees winners.
	if srcDead then
		local pos = PosNow()
		if pos then
			-- coins in the window count too — money is farm value
			-- (LoneBit tracks it per mob); capped like the skin path
			local rawM = (GetLootMoney and GetLootMoney()) or 0
			local money = min(rawM, 50000)
			local zn, tail = MergeZone(pos, "hunt", items, srcName, money)
			-- every hunt event re-anchors the skin-tail window:
			-- leather looting this corpse in the next seconds is
			-- its skin, not a second kill
			lastKill = { t = t, mob = srcName }
			UpdateYield(YieldRec("hunt"), items, tail)
			-- per-mob drop table: "hunt:Ravasaur" -> flesh/leather —
			-- the seed of a real mob-drop model
			if srcName then
				UpdateYield(YieldRec("hunt:" .. srcName), items, tail)
			end
			Journal(tail and "tail" or "kill", {
				mob = srcName, items = ItemStr(items),
				money = rawM, v = (LootValue(items) or 0) + money,
				k = zn and zn.kills, map = pos.map })
		else
			Journal("skip", { mob = srcName,
				items = ItemStr(items), why = "no-pos" })
		end
		if GM.GatherMap then GM.GatherMap.Refresh() end
	else
		-- no gather verdict, no corpse: what's left is object loot —
		-- chests, barrels, crates (quest items are filtered
		-- upstream by LootItems). A fish-bearing window is never a
		-- chest: catches whose arm didn't survive stay unclaimed
		-- rather than planting treasure where you stood fishing
		local fishy
		local IC = GM.Gathering and GM.Gathering.ItemCat
		if IC then
			for id in pairs(items) do
				if IC(id) == "fish" then fishy = true break end
			end
		end
		if next(items) and not fishy then
			local pos = PosNow()
			if pos then
				MergeNode(pos, "chest", "Chest")
				UpdateYield(YieldRec("chest"), items)
				Journal("chest", { mob = winName,
					items = ItemStr(items) })
				if GM.GatherMap then GM.GatherMap.Refresh() end
			else
				Journal("skip", { mob = winName,
					items = ItemStr(items), why = "no-pos" })
			end
		else
			Journal("skip", { mob = srcName,
				items = ItemStr(items), why = "no-corpse" })
		end
	end
	return
end

-- ======================== events ========================

local evf = CreateFrame("Frame")
for _, e in ipairs({
	"UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_START",
	"UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
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
	if e == "UNIT_SPELLCAST_CHANNEL_START" then
		local unit, _, spellID = ...
		if unit ~= "player" then return end
		-- a channel tells us its own end: arm until endTime +
		-- loot latency rather than a fixed window. endTime comes
		-- back in ms on this API — a value orders of magnitude
		-- past GetTime() can't be seconds
		local kind = spellID and CAST_KIND[spellID]
		local endS
		local cnm
		if UnitChannelInfo then
			local ok, nm, a4, a5, a6, a7, a8, a9, a10 =
				pcall(UnitChannelInfo, "player")
			if ok and nm then
				cnm = nm
				local l = nm:lower()
				for k, pat in pairs(CAST_NAME) do
					if l:find(pat, 1, true) then
						kind = kind or k
						break
					end
				end
				-- endTime is the largest time field — field order
				-- differs across client generations (vanilla puts
				-- it 6th, retail 5th), and units differ too: a
				-- value orders of magnitude past GetTime() is ms
				local et
				for _, v in ipairs({ a4, a5, a6, a7, a8, a9, a10 }) do
					if type(v) == "number"
						and (not et or v > et) then
						et = v
					end
				end
				if et and et > GetTime() * 10 then
					et = et / 1000
				end
				endS = et
			end
		end
		if kind then
			ArmWindow(kind, endS and endS + 1.5)
		else
			Journal("chan", { mob = tostring(spellID or "?"),
				items = tostring(cnm or "no-info") })
		end
		return
	end
	if e == "UNIT_SPELLCAST_FAILED"
		or e == "UNIT_SPELLCAST_INTERRUPTED" then
		local unit = ...
		if unit == "player" then
			if arm then
				Journal("disarm", { mob = arm.kind })
				arm = nil
			end
		end
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

-- ======================== commands ========================
-- self-registered through the shared API (Core.lua loads first).
-- Longest-name match owns ordering now — declaration order can't
-- shadow, so these can live in any order.
GM.Cmd({ "gatherreset", "farmreset" }, function()
	local g = GoblinMindGather
	g.zones, g.yields, g.resp, g.nodes = {}, {}, {}, {}
	g.target = nil
	if GM.GatherMap then GM.GatherMap.Refresh() end
	GM.Print("gather data wiped — IMPORT to reload GatherLite nodes")
end, { prefix = true, help = "wipe gather data" })
GM.Cmd({ "gatherimport", "glimport" }, function()
	local st, err = GM.Gather.ImportGatherLite()
	if st then
		GM.Print("gather import: " .. st.new .. " new, "
			.. st.merged .. " merged" .. (st.skipped > 0
				and (", " .. st.skipped .. " skipped") or ""))
	else
		GM.Print(err or "no GatherLite data found")
	end
end, { prefix = true, help = "import GatherLite nodes" })
-- the forensic dump: every loot window, what we did with it, and
-- the value we attributed — full cycle for phantom-number hunts
GM.Cmd({ "gatherlog", "farmlog" }, function(arg)
	local j = db.journal
	if not j or #j == 0 then
		GM.Print("gather journal: no loot events captured")
		return
	end
	local n = tonumber(arg) or 20
	local lo = max(1, #j - n + 1)
	local prev
	for i = lo, #j do
		local e = j[i]
		local gap = prev and (e.t - prev) or 0
		prev = e.t
		local ts = ""
		if e.rt and date then
			local okD, s = pcall(date, "%H:%M:%S", e.rt)
			if okD then ts = s .. " " end
		end
		GM.Print(("%s+%5.1fs %-8s %-20s it=%s m=%s v=%s%s"):format(
			ts, gap, e.w or "?", tostring(e.mob or "-"),
			e.items or "-", tostring(e.money or "-"),
			tostring(e.v or "-"),
			e.k and (" k=" .. e.k) or ""))
	end
end, true)

GM.Cmd("navdebug", function()
	local d = G.NavDiag and G.NavDiag()
	if not d then
		GM.Print("navdebug: no diag yet")
		return
	end
	GM.Print("--- nav trace ---")
	local parts = {}
	for k, v in pairs(d.api) do
		parts[#parts + 1] = k .. "="
			.. tostring(v and 1 or 0)
	end
	table.sort(parts)
	GM.Print("api: " .. table.concat(parts, " "))
	GM.Print("cvar showInGameNavigation=" .. tostring(d.cvar)
		.. " tracking=" .. tostring(d.tracking)
		.. " quest=" .. tostring(d.questTracking)
		.. " navState=" .. tostring(d.navState)
		.. " navScreen=" .. tostring(d.navScreen))
	GM.Print("navFrame=" .. tostring(d.navFrame)
		.. " clamped=" .. tostring(d.navClamped)
		.. " navDist=" .. tostring(d.navDist))
	if d.navErr or d.routeErr then
		GM.Print("errors: nav=" .. tostring(d.navErr)
			.. " | route=" .. tostring(d.routeErr))
	end
	local wp = d.wp
	GM.Print("waypoint=" .. (type(wp) == "table"
		and format("%s @ %.4f,%.4f",
			tostring(wp.map), wp.x or -1, wp.y or -1)
		or tostring(wp)))
	GM.Print("ours=" .. tostring(d.ours)
		.. " cvarOwned=" .. tostring(d.cvarOwned)
		.. " running=" .. tostring(d.run))
end, { help = "dump the navigation chain state" })

GM.Cmd({ "gather", "farm" }, function() GM.View.Toggle("gather") end,
	{ prefix = true, help = "gather window" })
