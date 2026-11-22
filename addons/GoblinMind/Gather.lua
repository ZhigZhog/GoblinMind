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

-- record schema version: zone/yield math changed under early data
-- (pockets, per-item hits, failed-loot counting). Bump = wipe the
-- derived records so pre-change loot doesn't poison the model.
-- Nodes keep — positions are still valid; re-import is one click.
local REC_V = 5
if db.v ~= REC_V then
	db.zones, db.yields, db.resp, db.journal = {}, {}, {}, {}
	db.v = REC_V
end

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
	cook = { 0.95, 0.55, 0.55 },
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
local function UpdateYield(rec, items, tail)
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
	if d and d <= max(ZONE_MERGE_YD, (zn.r or 0)) then
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
	if d and d <= max(ZONE_MERGE_YD, a.r or 0) then return true end
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
					break
				end
			end
			if again then break end
		end
	end
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

-- display item for a node/zone: the most valuable thing it drops.
-- itemIDs picked for guaranteed presence on this client
local KIND_ICON_ITEM = {
	herb = 765, mine = 2770, skin = 2318, cloth = 2589,
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
	return best == "flesh" and "cook"
		or best == "leather" and "skin"
		or best or zn.kind
end

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
	CoalesceZones()
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
				zoneName = zn.area or G.ZoneName(map),
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

-- ======================== loot journal ========================
-- rolling forensic record of every loot window and what we did
-- with it — the "where did that number come from" surface.
-- Bounded + persisted; /goblin gatherlog prints it.
local JOURNAL_MAX = 60
local function Journal(what, e)
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
	local cat
	for id in pairs(items) do
		local c = IC(id)
		if c == "cloth" or c == "flesh" then c = nil end
		if not c or (cat and c ~= cat) then return nil end
		cat = c
	end
	if not cat then return nil end
	if cat == "leather" then
		if lastKill and (not mob or mob == lastKill.mob)
			and GetTime() - lastKill.t <= SKIN_TAIL_S then
			return "skin"
		end
		return nil
	end
	return cat == "ore" and "mine" or cat
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
		local score = hit - miss
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
		if wkind and wkind ~= gKind then
			gKind = wkind
		elseif not wkind and srcDead and next(items)
			and gKind ~= "skin" then
			gKind = nil
		end
	else
		gKind = wkind
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
			local nm = NodeNameFor(items)
				or ((armValid or not srcDead) and winName)
			local nd = MergeNode(pos, gKind, nm)
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
		Journal("skip", { mob = srcName,
			items = ItemStr(items), why = "no-corpse" })
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

GM.Cmd({ "gather", "farm" }, function() GM.GatherUI.Toggle() end,
	{ prefix = true, help = "gather window" })
