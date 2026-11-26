local _, GM = ...

-- Gather map overlay — node pins, the active/solved route polyline,
-- and translucent hunt-zone circles on the world map. Forever's map
-- may lack the retail DataProvider API, so pins parent manually to
-- the map's scroll canvas (the GatherLite approach per proposal §5)
-- with defensive lookup — anything missing degrades to nothing
-- rather than erroring.

GM.GatherMap = {}
local M = GM.GatherMap
local G -- GM.Gather, resolved lazily (file order)

local floor, sqrt, cos, sin = math.floor, math.sqrt,
	math.cos, math.sin
local format = string.format

-- canvas lookup: modern frames expose GetCanvas() (the frame
-- MapWise attaches its terrain layer to); older keep a
-- ScrollContainer.Child; last resort the frame itself. Pins
-- anchor CENTER in normalized*pixel coords either way.
local function Canvas()
	local f = WorldMapFrame
	if not f then return nil end
	if f.GetCanvas then
		local ok, c = pcall(f.GetCanvas, f)
		if ok and c then return c end
	end
	if f.ScrollContainer and f.ScrollContainer.Child then
		return f.ScrollContainer.Child
	end
	return f
end

-- our draw host: a frame of our own ON the canvas, leveled above
-- MapWise's terrain layer (canvas+2). Drawing straight on the
-- canvas puts the pins under their view frame and nothing shows
-- — the "no overlays on the world map" bug
local host, hostCanvas
local function Host(canvas)
	if hostCanvas ~= canvas then
		if host then host:Hide() host:SetParent(nil) end
		host = nil
		hostCanvas = canvas
	end
	if not host then
		host = CreateFrame("Frame", nil, canvas)
		host:SetAllPoints(canvas)
		host:EnableMouse(false)
	end
	-- +6 over the canvas on a bare client. MapWise re-levels its
	-- layers dynamically (terrain view, Reveal fog, explored-tile
	-- frames — all canvas children) — up past the native pin
	-- manager's exploration band (~510). Chasing the terrain layer
	-- by name still let a re-leveled sibling sit on top of us:
	-- explored zones painted detail tiles over the icons while
	-- unexplored parchment showed through — the "inverse" bug.
	-- Target the topmost canvas child instead of a named layer —
	-- skip our own host or we'd chase our own tail upward.
	local lv = canvas.GetFrameLevel and canvas:GetFrameLevel()
	local want = (lv or 0) + 6
	if canvas.GetChildren then
		local kids = { canvas:GetChildren() }
		for _, kid in ipairs(kids) do
			if kid and kid ~= host and kid.GetFrameLevel then
				local tl = kid:GetFrameLevel()
				if tl and tl >= want then want = tl + 1 end
			end
		end
	end
	if host.SetFrameLevel and host:GetFrameLevel() ~= want then
		host:SetFrameLevel(want)
	end
	host:Show()
	return host
end

local function MapShown()
	local f = WorldMapFrame
	return f and f.IsShown and f:IsShown()
end

local function CurrentMap()
	local f = WorldMapFrame
	if f and f.GetMapID then
		local ok, id = pcall(f.GetMapID, f)
		if ok and id then return id end
	end
	if C_Map and C_Map.GetBestMapForUnit then
		local ok, id = pcall(C_Map.GetBestMapForUnit, "player")
		if ok and id then return id end
	end
end

-- ======================== pooled layer ========================

-- all world-map drawing goes through a W.MapLayer on the host —
-- the same primitive set the window pane uses, so every map
-- object is identical across surfaces. Recreated whenever the
-- host frame is (canvas swap)
local worldML
local function Reclaim()
	if worldML then worldML:clear() end
end
local function Layer(draw)
	if not worldML or worldML.host ~= draw then
		worldML = GM.Widgets.MapLayer(draw)
	end
	return worldML
end


-- zone radii are yards — convert through the same normalized-unit
-- scale DistYd's fallback uses so the disc covers the modeled area
local function YdToPx(canvas, yd)
	local w = canvas:GetWidth() or 1000
	return yd / 1500 * w
end

-- recorded span can dwarf the real farm (legacy merges let r
-- snowball) — the disc is an extent hint, clamp what we draw;
-- zn.r itself stays the honest kill-span
local ZONE_DRAW_MAX_YD = 220
local function DispR(zn)
	return min(zn.r or 60, ZONE_DRAW_MAX_YD)
end

-- fitted camp boundary: sample the pocket set's support function
-- (farthest pocket projection per direction) so the outline hugs
-- the farm's real spread per-direction instead of the enclosing
-- circle a single radius forces. Chaikin corner-cutting twice is
-- a quadratic-bezier ring — WoW has no curve primitive, but
-- segments through the smoothed points read as one. Fill comes
-- from a soft disc per pocket — the shaded area is the actual
-- kill coverage, not a guess around it
local OUTLINE_SEG, POCKET_PAD_YD, ZONE_MIN_YD = 16, 35, 45

-- support-function fit over pocket px points: farthest projection
-- per direction around the centroid, padded + floored + capped
-- (maxR keeps legacy mega-camps inside the same display bound the
-- disc path clamps to), Chaikin-smoothed twice into a bezier ring.
-- Shared by the world-map overlay and the window pane — returns
-- poly + centroid, or nil when there aren't enough pockets
local function ZonePoly(pts, pad, minR, maxR)
	if #pts < 3 then return nil end
	local cx, cy = 0, 0
	for _, p in ipairs(pts) do cx, cy = cx + p.x, cy + p.y end
	cx, cy = cx / #pts, cy / #pts
	local poly = {}
	for i = 0, OUTLINE_SEG - 1 do
		local a = i / OUTLINE_SEG * 6.2831853
		local dx, dy = cos(a), -sin(a)
		local d = minR
		for _, p in ipairs(pts) do
			local proj = (p.x - cx) * dx + (p.y - cy) * dy
			if proj > d then d = proj end
		end
		local ext = d + pad
		if maxR and ext > maxR then ext = maxR end
		poly[#poly + 1] = { x = cx + dx * ext,
			y = cy + dy * ext }
	end
	for _ = 1, 2 do
		local out = {}
		for i = 1, #poly do
			local a, b = poly[i], poly[i % #poly + 1]
			out[#out + 1] = { x = a.x * 0.75 + b.x * 0.25,
				y = a.y * 0.75 + b.y * 0.25 }
			out[#out + 1] = { x = a.x * 0.25 + b.x * 0.75,
				y = a.y * 0.25 + b.y * 0.75 }
		end
		poly = out
	end
	return poly, cx, cy
end

-- map-units per yard near (n,w): project two points a known world
-- distance apart and measure. Fallback matches the world map's
-- 1500yd-per-map-width assumption
local function UnitsPerYard(mapID, p)
	if p and p.n and p.w then
		local ax, ay = GM.MapPos(p.c or 0, p.n, p.w, mapID)
		local bx, by = GM.MapPos(p.c or 0, p.n + 100, p.w, mapID)
		if ax and bx then
			local d = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
			if d > 1e-6 then return d / 100 end
		end
	end
	return 1 / 1500
end

-- greedy proximity merge in map units — display-only; the data
-- layer's tighter merge already ran, this just thins pin spam
local function Cluster(nodes, xy, thresh)
	local out = {}
	for _, nd in ipairs(nodes) do
		local x, y = xy(nd)
		if x then
			local hit
			for _, c in ipairs(out) do
				local dx, dy = x - c.x, y - c.y
				if dx * dx + dy * dy < thresh * thresh then
					hit = c break
				end
			end
			if hit then
				hit.x = (hit.x * hit.n + x) / (hit.n + 1)
				hit.y = (hit.y * hit.n + y) / (hit.n + 1)
				hit.n = hit.n + 1
				hit.nodes[#hit.nodes + 1] = nd
			else
				out[#out + 1] = { x = x, y = y, n = 1, nodes = { nd } }
			end
		end
	end
	return out
end
-- normalized map coords for a record; projects world->map for
-- records captured before the map projection resolved (harness
-- data, early-login casts). x,y is only trusted in the map frame
-- it was projected for — Forever resolves one place to several
-- mapIDs, so records stored under a different ID reproject world
-- coords (custom zones reporting as Tanaris, Riverglades, ...)
-- per-record projection memo (session-only): the projection is
-- deterministic for a given (n,w,c)->mapID, and Refresh ticks once
-- a second while the map is open — re-calling the pcall'd API for
-- every record every tick is the old "several seconds" problem.
-- nil results aren't cached: map data can be unloaded at login and
-- the next tick should retry
local projCache = setmetatable({}, { __mode = "k" })
local function MapXY(p, mapID)
	-- world yards are the authoritative shared frame: Forever swaps
	-- a zone's map variant under the same mapID (compact vs composite
	-- canvas), which leaves stored x,y in a stale frame that draws
	-- the record on the WRONG zone — the "all zones but the
	-- selected one" inverse. n,w reproject every time and heal x,y.
	if p.n and p.w then
		local pc = projCache[p]
		if pc and pc.m == mapID and pc.n == p.n
			and pc.w == p.w and pc.c == p.c then
			return pc.x, pc.y
		end
		local mx, my = GM.MapPos(p.c or 0, p.n, p.w, mapID)
		if mx then
			projCache[p] = { m = mapID, n = p.n, w = p.w,
				c = p.c, x = mx, y = my }
			if not p.map or p.map == mapID then
				p.x, p.y = mx, my
			end
			return mx, my
		end
	end
	if p.x and p.y and (not p.map or p.map == mapID) then
		return p.x, p.y
	end
	-- x,y-only foreign record: hop through its own map frame
	if p.x and p.y and p.map and p.map ~= mapID then
		local n, w, c = GM.WorldPos(p.map, p.x, p.y)
		if n then
			return GM.MapPos(c or 0, n, w, mapID)
		end
		return -- proven foreign: raw x,y would draw in the wrong spot
	end
	-- fall back to the raw stored coords only when the frame can't
	-- be proven foreign
	if p.x and p.y then return p.x, p.y end
end

-- normalized coords on (or a hair off) the displayed canvas.
-- The bleed margin keeps edge pins from clipping mid-draw;
-- pockets get a wider one since they're just fit input
local FRAME_M = 0.02
function M.OnFrame(x, y, m)
	m = m or FRAME_M
	return x and y and x >= -m and x <= 1 + m
		and y >= -m and y <= 1 + m
end

-- shared proximity merge — GatherMinimap clusters in world-yard
-- space with the same routine instead of a second merge
M.Cluster = Cluster
-- same story for the camp fit: the minimap draws the identical
-- blob in its own pixel space, so it consumes the support-fn fit
-- and the pad/floor/cap constants rather than re-deriving them
M.ZonePoly, M.DispR = ZonePoly, DispR
M.POCKET_PAD_YD, M.ZONE_MIN_YD = POCKET_PAD_YD, ZONE_MIN_YD
M.ZONE_DRAW_MAX_YD = ZONE_DRAW_MAX_YD


-- ======================== shared scenes ========================
-- every map object renders through these — world-map overlay and
-- window pane both call them with per-surface style, so a camp,
-- cluster, route, or mark looks the same on every map
--
-- GoblinMind-flavored tooltips ride the same objects: money line
-- first, then identity, then the observed drop table — built
-- fresh on each hover so prices/rates are live
local function ZoneTip(zn, mapID)
	return function(tip)
		local G = GM.Gather
		local zc = G.ZoneCat(zn)
		local gpm = G.ZoneValueNow(zn)
		tip:AddLine(GM.MoneyShort(floor(gpm)) .. "/min"
			.. GM.CC("textDim") .. " · " .. (zn.kills or 0)
			.. " kills · " .. #(zn.pockets or {})
			.. " pockets|r")
		if zn.vTot and zn.vTot > 0 then
			tip:AddLine(GM.CC("textDim") .. "looted "
				.. GM.MoneyShort(zn.vTot) .. "|r")
		end
		local place = G.ZonePlace and G.ZonePlace(zn)
		tip:AddLine(G.KindTag(zc)
			.. (place and (" · " .. place) or ""))
		local mobs = G.ZoneMobs and G.ZoneMobs(zn)
		if mobs then
			tip:AddLine(GM.CC("secondary") .. mobs .. "|r")
		end
		local rows = G.ZoneDropRows and G.ZoneDropRows(zn)
		if rows and rows[1] and GM.Widgets then
			for _, s in ipairs(GM.Widgets.DropLines(rows, {
				max = 6,
				target = G.TargetID and G.TargetID() })) do
				tip:AddLine(s)
			end
		end
	end
end

local function ClusterTip(c, mapID)
	return function(tip)
		local G = GM.Gather
		local rep = c.nodes[1]
		-- money first: observed expected value of one spawn
		local ev, dimAll = 0, true
		for _, nd in ipairs(c.nodes) do
			ev = ev + (G.NodeEV and G.NodeEV(nd) or 0)
			if not G.NodeDepleted(nd, mapID) then
				dimAll = false
			end
		end
		tip:AddLine("EV ≈ " .. GM.MoneyShort(floor(ev / c.n))
			.. GM.CC("textDim") .. " / spawn|r")
		local order, tally = {}, {}
		for _, nd in ipairs(c.nodes) do
			local nm = nd.name or G.KindLabel(nd.kind)
			if not tally[nm] then order[#order + 1] = nm end
			tally[nm] = (tally[nm] or 0) + 1
		end
		local names
		for _, nm in ipairs(order) do
			names = (names and names .. " · " or "") .. nm
				.. (tally[nm] > 1 and (" ×" .. tally[nm]) or "")
		end
		tip:AddLine(G.KindTag(rep.kind) .. "  " .. (names or ""))
		tip:AddLine(GM.CC("secondary") .. c.n
			.. (c.n == 1 and " node" or " nodes")
			.. " · respawn ~"
			.. G.SecondsText(G.RespawnSec(mapID, rep.kind))
			.. (dimAll and " · depleted" or "") .. "|r")
		-- drops from the dominant member's observed table
		local rows = G.DropRows
			and G.DropRows(rep.name or rep.kind)
		if rows and rows[1] and GM.Widgets then
			for _, s in ipairs(GM.Widgets.DropLines(rows, {
				max = 6,
				target = G.TargetID and G.TargetID() })) do
				tip:AddLine(s)
			end
		end
	end
end


-- kills abbrev: Nk — "5k" for 5, "1.2k" ≥1000 (tag contract S2)
local function KillsK(n)
	return n >= 1000 and format("%.1fk", n / 1000)
		or tostring(n) .. "k"
end

-- canonical camp tag: KINDTAG · Nk · GPM/m, font-8 glance line.
-- The place name is a textDim aside kept only while the whole
-- line stays ≤26 visible chars — the hover tip carries the
-- full story (pockets, mobs, drop table)
local function ZoneLabel(zn, mapName)
	local zc = G.ZoneCat(zn)
	local stats = KillsK(zn.kills or 0) .. " · "
		.. GM.MoneyShort(floor(G.ZoneValueNow(zn))) .. "/m"
	local place = G.ZonePlace and G.ZonePlace(zn)
	if place == mapName then place = nil end
	local vis = #G.KindLabel(zc) + 3 + #stats
	if place and vis + 3 + #place <= 26 then
		return G.KindTag(zc) .. " · " .. stats
			.. GM.CC("textDim") .. " · " .. place .. "|r"
	end
	return G.KindTag(zc) .. " · " .. stats
end

local function RouteTip(r)
	return function(tip)
		local G = GM.Gather
		tip:AddLine("≈ " .. GM.MoneyShort(floor(r.gpm or 0))
			.. "/min" .. GM.CC("textDim") .. " expected|r")
		tip:AddLine(G.KindTag(r.kind) .. " loop · " .. #r.stops
			.. " stops" .. (r.running and " · active" or ""))
		if r.evLoop then
			tip:AddLine(GM.MoneyShort(floor(r.evLoop)) .. "/lap"
				.. GM.CC("textDim")
				.. (r.lapSec
					and (" · ~" .. G.SecondsText(r.lapSec)
						.. " lap") or "") .. "|r")
		end
		local info
		if r.yards then
			info = "~" .. (r.yards >= 1000
				and format("%.1fk", r.yards / 1000)
				or floor(r.yards + 0.5)) .. " yd"
		end
		if r.respawn and r.lapSec then
			local up = min(1, r.lapSec / r.respawn) * 100
			info = (info and (info .. " · ") or "")
				.. floor(up + 0.5) .. "% uptime"
		end
		if info then
			tip:AddLine(GM.CC("secondary") .. info .. "|r")
		end
	end
end


-- the manager consumes the shared scene vocabulary — the draw
-- logic lives in MapManager; these are the tooltip/label/projection
-- helpers its object draws reach back for
M.MapXY, M.UnitsPerYard, M.YdToPx = MapXY, UnitsPerYard, YdToPx
M.ZoneTip, M.ClusterTip, M.RouteTip = ZoneTip, ClusterTip, RouteTip
M.ZoneLabel = ZoneLabel

-- remember the freshest solved route per map so the overlay draws
-- without re-running the solver every frame
local lastRoutes = {}
function M.NoteRoute(r)
	if r and r.map then lastRoutes[r.map] = r end
end
function M.RouteFor(map)
	return lastRoutes[map]
end
function M.ClearRoute(map)
	lastRoutes[map] = nil
end


-- ====================== view: world map ======================
-- the manager's adapter for the WorldMapFrame overlay: fractions
-- -> canvas px, pools through worldML, tags + hover enabled
local worldView = {
	id = "world",
	feats = { tag = true, hot = true },
	fit = setmetatable({}, { __mode = "k" }),
}
function worldView:proj(rec)
	local x, y = MapXY(rec, self.mapID)
	if not x then return end
	return x * self.w, y * self.h
end
function worldView:ptsRel(zn)
	local pts = {}
	local zx, zy = MapXY(zn, self.mapID)
	if not zx then return pts end
	for _, pk in ipairs(zn.pockets or {}) do
		local px, py = MapXY(pk, self.mapID)
		if px and M.OnFrame(px, py, 0.05) then
			pts[#pts + 1] = { x = (px - zx) * self.w,
				y = (py - zy) * self.h }
		end
	end
	return pts
end
function worldView:rPx(yd) return YdToPx(self.canvas, yd) end
function worldView:cull(x, y, slack)
	slack = slack or 0
	return x < -slack or x > self.w + slack
		or y < -slack or y > self.h + slack
end
function worldView:rim(x, y) return x, y end
function worldView:fade() return 1 end
function worldView:iconSz(n)
	return GM.Widgets.MapStyle.ClusterSize(n)
end
function worldView:routeSeg(x1, y1, x2, y2, a)
	self.L:dots(x1, y1, x2, y2, 0.4, 0.85, 1.0, a)
end
function worldView:routeStop() end -- flat views draw the loop only
function worldView:clusters(nodes)
	local ref = nodes[1]
	local upy = UnitsPerYard(self.mapID, ref)
	local function frac(nd)
		local x, y = MapXY(nd, self.mapID)
		if M.OnFrame(x, y) then return x, y end
	end
	local out = {}
	for _, c in ipairs(Cluster(nodes, frac, 70 * upy)) do
		out[#out + 1] = { nodes = c.nodes, n = c.n,
			x = c.x * self.w, y = c.y * self.h }
	end
	return out
end

function M.Refresh()
	G = G or GM.Gather
	if not MapShown() or not G then
		Reclaim()
		return
	end
	local canvas = Canvas()
	if not canvas then Reclaim() return end
	local map = CurrentMap()
	if not map then Reclaim() return end
	local draw = Host(canvas)
	local L = Layer(draw)
	L:clear()
	local w, h = canvas:GetWidth() or 1, canvas:GetHeight() or 1
	-- overlay opacity per family (settings → GoblinMindGather.mm):
	-- zones covers fills/borders/farm icons/tags/route/marks,
	-- nodes covers spawn cluster icons and badges
	local oaZ = GM.GatherMinimap and GM.GatherMinimap.AlphaZone() or 1
	local oaN = GM.GatherMinimap and GM.GatherMinimap.AlphaNode() or 1
	local oaI = GM.GatherMinimap and GM.GatherMinimap.AlphaIcon() or 1
	local S = GM.Widgets.MapStyle

	worldView.canvas, worldView.mapID = canvas, map
	worldView.w, worldView.h = w, h
	worldView.L = L
	worldView.fitScale = w * 4096 + h

	-- continent/world view: one mark per zone SLOT replaces the
	-- camps entirely (record mapIDs roll up under their display
	-- ancestor — Forever stores one place under several IDs)
	local marks
	if M.IsWorldy(map) then
		marks = M.ZoneMarks(map,
			G.Leaderboard and G.Leaderboard() or {})
	end

	-- every record landing on the displayed map, whatever mapID
	-- the client stored it under (custom zones, Riverglades, ...)
	local zones, nodes
	if not marks then
		zones, nodes = {}, {}
		for _, zl in pairs(GoblinMindGather.zones or {}) do
			for _, zn in ipairs(zl) do
				if worldView:proj(zn) then
					zones[#zones + 1] = zn
				end
			end
		end
		for _, list in pairs(GoblinMindGather.nodes or {}) do
			for _, nd in ipairs(list) do
				if worldView:proj(nd) then
					nodes[#nodes + 1] = nd
				end
			end
		end
	end

	-- route polyline: the active run if one's going, else the last
	-- solved route for this map
	local run = G.Route and G.Route()
	local r = run and run.route or M.RouteFor(map)
	local stops = run and run.stops or (r and r.stops)
	local route = stops and #stops > 1 and {
		stops = stops,
		active = run and run.stops[run.idx],
		tipFn = r and RouteTip(r),
		a = S.A.route * oaN,
	}

	local mapName = G.ZoneName and G.ZoneName(map)
	local tid = G.TargetID and G.TargetID()
	GM.MapMgr.Paint(worldView, {
		mapID = map,
		zones = zones,
		nodes = nodes,
		route = route,
		marks = marks,
		tid = tid,
		oa = { n = oaN },
		zoneSt = function(zn)
			local zc = G.ZoneCat(zn)
			return {
				col = G.KindCol(zc),
				fillA = S.A.zoneFill * oaZ,
				ringA = S.A.zoneRing * oaZ,
				ringPx = 3,
				iconID = G.ZoneIconID and G.ZoneIconID(zn),
				iconA = S.A.full * oaI,
				-- kind tag + landmark + kills/gpm line — the
				-- glance label S2 specifies, world-map only
				tag = ZoneLabel(zn, mapName),
				mapID = map,
			}
		end,
	})
end

-- ======================== window pane ========================
-- self-contained zone map for the GATHER window: map-art tiles when
-- the client exposes them (dark fill otherwise), hunt-zone discs
-- with a centered drop icon, node spawn icons clustered by proximity
-- (size ∝ group size) with the route polyline through them. Own
-- pools — the world-map pass above must not reclaim our textures.

local abs = math.abs


-- normalized map coords for a record; projects world->map for
-- records captured before the map projection resolved (harness
-- data, early-login casts)
-- continent scale: the world map or its direct children
-- (continents). Child-zone geometry projects onto them at the
-- wrong size — they get summary marks instead of overlays.
-- Memoized: the check runs every refresh tick
local worldyCache = {}
function M.IsWorldy(mapID)
	if not mapID then return false end
	local hit = worldyCache[mapID]
	if hit ~= nil then return hit end
	local wy = false
	if mapID == 947 then
		wy = true
	else
		local GetInfo = C_Map and C_Map.GetMapInfo
		if GetInfo then
			local ok, info = pcall(GetInfo, mapID)
			wy = ok and info and info.parentMapID == 947
				or false
		end
	end
	worldyCache[mapID] = wy
	return wy
end

-- the record map's slot on the displayed map: the ancestor
-- directly UNDER display. A zone under a continent -> the zone;
-- anything on the world view -> its continent (or the topmost
-- known ancestor on thin-hierarchy clients). One mark per slot —
-- Forever stores a single place under several mapIDs. The
-- hierarchy is immutable per session, so the 8-hop GetInfo walk
-- memoizes — ZoneMarks asks per record map every refresh tick
local underCache = {}
function M.MapUnder(m, display)
	if not (m and display) or m == display then return nil end
	local key = m .. "|" .. display
	local hit = underCache[key]
	if hit ~= nil then return hit or nil end
	local slot
	local GetInfo = C_Map and C_Map.GetMapInfo
	if not GetInfo then
		slot = m -- thin client: own slot
	else
		local cur = m
		for _ = 1, 8 do
			local ok, info = pcall(GetInfo, cur)
			if not ok or not info then break end
			local p = info.parentMapID
			if p == display then slot = cur break end
			if not p or p == 0 or p == cur then break end
			cur = p
		end
		-- walk couldn't prove a slot: the world view rolls up to
		-- the topmost ancestor; deeper views fall back to the map
		-- itself — off-continent groups centroid out of bounds
		slot = slot or (display == 947 and cur or m)
	end
	underCache[key] = slot or false
	return slot
end

-- grouped per-zone marks for a continent/world display: camps +
-- solved-route rows rolled up to their zone slot, centroided over
-- every record map inside it, medal-ranked by best gpm. The
-- world-map overlay and the window pane draw the same marks
local function MarkAccum(e, m, p)
	if p.n and p.w then
		e.sn, e.sw, e.n = (e.sn or 0) + p.n,
			(e.sw or 0) + p.w, (e.n or 0) + 1
		if not e.c and p.c and p.c ~= 0 then e.c = p.c end
	elseif p.x and p.y and not e.xy then
		e.xy = { m = m, x = p.x, y = p.y }
	end
end
function M.ZoneMarks(display, rows)
	local groups, mapGrp = {}, {}
	local function grpOf(m)
		local g = mapGrp[m]
		if g == nil then
			g = M.MapUnder(m, display) or false
			mapGrp[m] = g
		end
		return g or nil
	end
	for _, r in ipairs(rows or {}) do
		if r.map and not r.mob then
			local z = grpOf(r.map)
			if z then
				local e = groups[z]
				if not e then e = { count = 0, gpm = 0 }
					groups[z] = e end
				e.count = e.count + 1
				if (r.gpm or 0) > e.gpm then e.gpm = r.gpm end
			end
		end
	end
	local db = GoblinMindGather or {}
	for m, list in pairs(db.nodes or {}) do
		local e = grpOf(m) and groups[grpOf(m)]
		if e then
			for _, p in ipairs(list) do MarkAccum(e, m, p) end
		end
	end
	for m, list in pairs(db.zones or {}) do
		local e = grpOf(m) and groups[grpOf(m)]
		if e then
			for _, p in ipairs(list) do MarkAccum(e, m, p) end
		end
	end
	local out = {}
	for _, e in pairs(groups) do
		local x, y
		if (e.n or 0) > 0 then
			x, y = GM.MapPos(e.c or 0, e.sn / e.n,
				e.sw / e.n, display)
		elseif e.xy then
			local n, w, c = GM.WorldPos(e.xy.m, e.xy.x, e.xy.y)
			if n then
				x, y = GM.MapPos(c or 0, n, w, display)
			end
		end
		if M.OnFrame(x, y) then
			out[#out + 1] = { x = x, y = y,
				count = e.count, gpm = e.gpm }
		end
	end
	table.sort(out, function(a, b)
		return (a.gpm or 0) > (b.gpm or 0) end)
	for i, mm in ipairs(out) do
		if i <= 3 and (mm.gpm or 0) > 0 then mm.medal = i end
	end
	return out
end

-- MapWise terrain path: MapWiseAPI exposes the addon's whole
-- table — TerrainIndex holds world-terrain tile fileIDs
-- (map%02d_%02d on a 533.33yd grid) plus per-zone world bounding
-- boxes. We draw the real ground tiles instead of the parchment
-- art whenever the index is present, calibrated to the map's
-- world corners the same way their Geometry does so map-coord
-- overlays stay aligned. Nil when MapWise isn't installed or has
-- no index for this map.
-- ====================== view: gather pane ======================
-- same adapter contract as the world map — fraction space, its
-- own MapLayer pool inside the scroll child, hot regions but no
-- zone tags (the pane lists that data beside the map)
local paneView = {
	id = "pane",
	feats = { hot = true },
	fit = setmetatable({}, { __mode = "k" }),
}
function paneView:proj(rec)
	local x, y = MapXY(rec, self.mapID)
	if not x then return end
	return x * self.w, y * self.h
end
function paneView:ptsRel(zn)
	local pts = {}
	local zx, zy = MapXY(zn, self.mapID)
	if not zx then return pts end
	for _, pk in ipairs(zn.pockets or {}) do
		local px, py = MapXY(pk, self.mapID)
		if px and M.OnFrame(px, py, 0.05) then
			pts[#pts + 1] = { x = (px - zx) * self.w,
				y = (py - zy) * self.h }
		end
	end
	return pts
end
function paneView:rPx(yd) return yd * self.upy * self.w end
function paneView:cull(x, y, slack)
	slack = slack or 0
	return x < -slack or x > self.w + slack
		or y < -slack or y > self.h + slack
end
function paneView:rim(x, y) return x, y end
function paneView:fade() return 1 end
function paneView:iconSz(n)
	return GM.Widgets.MapStyle.ClusterSize(n)
end
function paneView:routeSeg(x1, y1, x2, y2, a)
	self.L:dots(x1, y1, x2, y2, 0.4, 0.85, 1.0, a)
end
function paneView:routeStop() end
function paneView:clusters(nodes)
	local out = {}
	for _, c in ipairs(Cluster(nodes,
			function(nd) return MapXY(nd, self.mapID) end,
			70 * self.upy)) do
		out[#out + 1] = { nodes = c.nodes, n = c.n,
			x = c.x * self.w, y = c.y * self.h }
	end
	return out
end

local function TerrainTiles(mapID)
	local A = MapWiseAPI
	local TI = A and A.TerrainIndex
	if not (TI and TI.files and TI.boxes
		and TI.valid and TI.maps) then return end
	local rel = TI.maps[mapID]
	local set, b
	if rel then
		set = rel[1]
		b = TI.boxes[set] and TI.boxes[set][rel[2]]
	else
		-- continent-scale maps aren't in the index — ask which
		-- world instance the map lives on (survives custom
		-- continent ids), else the two classic defaults
		local wid
		if C_Map and C_Map.GetWorldPosFromMapPos
			and CreateVector2D then
			local ok, w = pcall(C_Map.GetWorldPosFromMapPos,
				mapID, CreateVector2D(0.5, 0.5))
			if ok and type(w) == "number" then wid = w end
		end
		set = ({ [0] = "Azeroth", [1] = "Kalimdor",
			[2991] = "2991" })[wid]
			or (mapID == 1414 and "Kalimdor")
			or (mapID == 1415 and "Azeroth")
		b = set and TI.boxes[set] and TI.boxes[set][0]
	end
	local files, valid = TI.files[set], TI.valid[set]
	if not (files and valid and b) then return end
	-- prefer the map's own world corners (their Geometry C_Map
	-- path): the tile frame must equal the map's 0..1 space or
	-- node/zone overlays won't sit on the terrain they belong to
	local wid = ({ Azeroth = 0, Kalimdor = 1, ["2991"] = 2991 })[set]
	if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
		local ok0, w0, v0 = pcall(C_Map.GetWorldPosFromMapPos,
			mapID, CreateVector2D(0, 0))
		local ok1, w1, v1 = pcall(C_Map.GetWorldPosFromMapPos,
			mapID, CreateVector2D(1, 1))
		if ok0 and ok1 and w0 and w0 == w1
			and (not wid or w0 == wid)
			and v0 and v1 and v0.x and v1.x
			and v0.x ~= v1.x and v0.y ~= v1.y then
			b = { v0.y, v1.y, v0.x, v1.x }
		end
	end
	-- their BuildTerrain math: world->tile grid, clipped to 0..1
	local cell = 1600 / 3
	local c0 = max(0, floor(32 - max(b[1], b[2]) / cell) - 1)
	local c1 = min(63, floor(32 - min(b[1], b[2]) / cell) + 1)
	local r0 = max(0, floor(32 - max(b[3], b[4]) / cell) - 1)
	local r1 = min(63, floor(32 - min(b[3], b[4]) / cell) + 1)
	local out = {}
	for row = r0, r1 do
		for col = c0, c1 do
			local file = files[format("map%02d_%02d", col, row)]
			if file and file > 0 and valid[col .. "x" .. row] then
				local x = ((32 - col) * cell - b[1])
					/ (b[2] - b[1])
				local y = ((32 - row) * cell - b[3])
					/ (b[4] - b[3])
				local tw, th = -cell / (b[2] - b[1]),
					-cell / (b[4] - b[3])
				if tw > 0 and th > 0
					and x < 1 and x + tw > 0
					and y < 1 and y + th > 0 then
					out[#out + 1] = {
						file = file, x = x, y = y,
						w = tw, h = th,
					}
				end
			end
		end
	end
	return #out > 0 and out or nil
end

function M.CreatePane(parent, w)
	local pane = CreateFrame("Frame", nil, parent)
	pane:SetWidth(w)

	-- every drawable lives on a scroll child: a ScrollFrame is the
	-- only hard clip rect textures get, and edge-anchored icons,
	-- ring segments, and camp discs would otherwise bleed past the
	-- pane onto the window chrome (the "overlap"). Forever widget
	-- APIs can exist but silently no-op (SetMaskTexture's trick) —
	-- verify the child actually attached before trusting the clip,
	-- and let SetClipsChildren back it up either way
	local inner = pane
	local clip = CreateFrame("ScrollFrame", nil, pane)
	clip:SetAllPoints()
	clip:EnableMouse(false)
	local sc = CreateFrame("Frame", nil, clip)
	if clip.SetScrollChild then
		pcall(clip.SetScrollChild, clip, sc)
		local okG, child = pcall(clip.GetScrollChild, clip)
		if okG and child == sc then inner = sc end
	end
	if inner == pane and pane.SetClipsChildren then
		pane:SetClipsChildren(true)
	end
	pane._inner = inner

	-- same pooled layer the world map draws through — every map
	-- object is the same primitives at the same sublevels. The
	-- tables stay exposed on the pane for introspection/tests
	local L = GM.Widgets.MapLayer(inner)
	pane.live, pane.pool = L.live, L.pool
	local put = L.put
	local function clear() L:clear() end
	pane.Clear = clear

	-- art tiles cover a TOPLEFT-anchored rect sized to the art's own
	-- aspect (letterboxed into the pane); overlays map 0-1 coords
	-- onto the same rect
	local function draw(self, mapID, route, sel, filter, marks)
		clear()
		local G = GM.Gather
		local w = self:GetWidth()
		if not (mapID and w and w > 0) then return end

		local aspect = 1.5 -- fallback when the art API is missing
		if C_Map and C_Map.GetMapArtLayers then
			local okL, layers = pcall(C_Map.GetMapArtLayers, mapID)
			local lay = okL and layers and layers[1]
			if lay and lay.layerWidth and lay.layerHeight
				and lay.layerHeight > 0 then
				aspect = lay.layerWidth / lay.layerHeight
			end
		end
		-- when the host frame pins the height (flush-bottom map
		-- pane) the tiles stretch into it; otherwise the map keeps
		-- its true aspect. GetHeight can read 0 before the anchored
		-- layout resolves — fall back to the aspect height and let
		-- OnSizeChanged redraw once the real size settles
		local h = self._fixedH and self:GetHeight() or nil
		if not h or h <= 0 then h = floor(w / aspect + 0.5) end
		if not self._fixedH then self:SetHeight(h) end
		self._dw, self._dh = w, floor(h)
		-- the scroll child carries every drawable at the draw
		-- rect's size; the clip frame crops anything past it.
		-- When inner IS the pane (no clip API), SetSize would
		-- override the anchored height and stretch the map frame
		-- over the legend strip below
		local inner = self._inner or self
		if inner ~= self then inner:SetSize(w, h) end

		local haveArt = false
		local tr = {}
		local att, okd, bad = 0, 0, 0
		local function note(s, ...)
			tr[#tr + 1] = "|cff9fd35fmap|r " .. format(s, ...)
		end
		M.ArtTrace = tr
		note("mapID=%s w=%.0f h=%.0f inner=%s lvl=%s",
			tostring(mapID), w, h, tostring(inner ~= self),
			tostring(inner.GetFrameLevel
				and inner:GetFrameLevel()))
		-- terrain beats parchment: real ground tiles via
		-- MapWise's index when the addon is present — same look
		-- as their map
		local terrain = TerrainTiles(mapID)
		-- MapWise load pattern: checked SetTexture with
		-- clamp+filter, plain retry, hide on genuine failure —
		-- traced per call so mapdebug can see WHERE the chain
		-- dies on a given client
		local function setfile(t, fid)
			att = att + 1
			local okS, loaded = pcall(t.SetTexture, t,
				fid, "CLAMP", "CLAMP", "TRILINEAR")
			if not okS then
				okS, loaded = pcall(t.SetTexture, t, fid)
			end
			if okS and loaded ~= false then
				okd = okd + 1
				return true
			end
			bad = bad + 1
			return false
		end
		if terrain then
			for _, t2 in ipairs(terrain) do
				-- edge tiles bleed past the box — crop them with
				-- texcoords like MapWise's Texture() does
				local l = max(0, t2.x)
				local tp = max(0, t2.y)
				local rr = min(1, t2.x + t2.w)
				local bb = min(1, t2.y + t2.h)
				local t = put("tile")
				if setfile(t, t2.file) then
					t:SetTexCoord((l - t2.x) / t2.w,
						(rr - t2.x) / t2.w,
						(tp - t2.y) / t2.h,
						(bb - t2.y) / t2.h)
					t:SetSize((rr - l) * w, (bb - tp) * h)
					t:SetPoint("TOPLEFT", inner, "TOPLEFT",
						l * w, -tp * h)
					haveArt = true
				else
					t:Hide()
				end
			end
			note("terrain loaded: %d/%d", okd, att)
		end
		if not terrain and C_Map and C_Map.GetMapArtLayers
			and C_Map.GetMapArtLayerTextures then
			local okL, layers = pcall(C_Map.GetMapArtLayers, mapID)
			note("artlayers: ok=%s n=%d",
				tostring(okL), okL and layers and #layers or 0)
			if okL and layers then
				for li, lay in ipairs(layers) do
					local okT, texs = pcall(
						C_Map.GetMapArtLayerTextures, mapID, li)
					local cols = max(1, floor(
						(lay.layerWidth or 1002)
						/ max(1, lay.tileWidth or 256) + 0.5))
					local rows = max(1, floor(
						(lay.layerHeight or 668)
						/ max(1, lay.tileHeight or 256) + 0.5))
					if okT and texs then
						local tw, th = w / cols, h / rows
						for i, fileID in ipairs(texs) do
							local t = put("tile")
							if setfile(t, fileID) then
								t:SetSize(tw, th)
								t:SetPoint("TOPLEFT", inner,
									"TOPLEFT",
									((i - 1) % cols) * tw,
									-floor((i - 1) / cols)
										* th)
								haveArt = true
							else
								t:Hide()
							end
						end
					end
				end
			end
		end
		-- explored-art overlay: the client's own reveal tiles via
		-- the vendored Leatrix dataset (MapRevealData[artID]
		-- ["w:h:ox:oy"] -> tile fileIDs). Draws over WHICHEVER base
		-- we laid down — gating it on `not terrain` meant any map
		-- with MapWise ground tiles lost its revealed detail
		-- entirely (the "missing revealed tiles" pane bug).
		-- Gated by GetExploredMapTextures rects when the API
		-- answers — exact current-state like the default map UI;
		-- an absent/empty explored list is a custom-zone data gap,
		-- so the full set draws rather than a bare parchment.
		do
			local artID = C_Map and C_Map.GetMapArtID
				and C_Map.GetMapArtID(mapID)
			-- MapWise's own RevealData wins when present: its
			-- fileIDs come from THIS client's DB2 (the Leatrix
			-- set carries classic-era ids that may not exist on
			-- Forever — SetTexture fails quietly and the overlay
			-- was invisible). Rows are already normalized:
			-- {fileID, ox, oy, w, h, tcRight, tcBottom}
			local mw = MapWiseAPI and MapWiseAPI.RevealData
				and MapWiseAPI.RevealData[artID]
			note("artID=%s mwReveal=%d leatrix=%d",
				tostring(artID),
				mw and #mw or 0,
				artID and GM.MapRevealData
					and GM.MapRevealData[artID] and 1 or 0)
			if mw then
				local before = okd
				for _, row in ipairs(mw) do
					local t = put("exptile")
					if setfile(t, row[1]) then
						t:SetTexCoord(0, row[6], 0, row[7])
						t:SetSize(row[4] * w, row[5] * h)
						t:SetPoint("TOPLEFT", inner, "TOPLEFT",
							row[2] * w, -row[3] * h)
						haveArt = true
					else
						t:Hide()
					end
				end
				note("mwReveal loaded: %d/%d", okd - before, #mw)
			end
			local records = (not mw) and artID
				and GM.MapRevealData
				and GM.MapRevealData[artID]
			local okL2, lay2 = pcall(C_Map.GetMapArtLayers, mapID)
			local lay = okL2 and lay2 and lay2[1]
			if not mw then
				note("leatrix path: records=%s lay=%s tileW=%s",
					tostring(records ~= nil),
					tostring(lay ~= nil),
					tostring(lay and lay.tileWidth))
			end
			if lay and lay.tileWidth and lay.tileWidth > 0 then
				local tileH = lay.tileHeight or lay.tileWidth
				local pw = w / (lay.layerWidth or 1002)
				local ph = h / (lay.layerHeight or 668)
				-- partial edge tiles live in power-of-two
				-- textures (min 16) — GatherLite's fileSize
				local function fsize(px, ts)
					if px == ts then return ts end
					local s = 16
					while s < px do s = s * 2 end
					return s
				end
				-- one grid-draw for both explored shapes: a rect's
				-- files lay out row-major over tile cells
				local function drawRect(rw, rh, ox, oy, files)
					local drew = 0
					local cols = math.ceil(rw / lay.tileWidth)
					local rows = math.ceil(rh / tileH)
					for row = 0, rows - 1 do
						for col = 0, cols - 1 do
							local fid = files[
								row * cols + col + 1]
							if fid then
								local tw2 = min(lay.tileWidth,
									rw - col * lay.tileWidth)
								local th2 = min(tileH,
									rh - row * tileH)
								local t = put("exptile")
								if setfile(t, fid) then
									t:SetTexCoord(0,
										tw2 / fsize(tw2,
											lay.tileWidth),
										0, th2 / fsize(th2, tileH))
									t:SetSize(tw2 * pw, th2 * ph)
									t:SetPoint("TOPLEFT", inner,
										"TOPLEFT",
										(ox + col
											* lay.tileWidth) * pw,
										-(oy + row * tileH) * ph)
									haveArt = true
									drew = drew + 1
								else
									t:Hide()
								end
							end
						end
					end
					return drew
				end
				-- modern shape: an explored entry carries its own
				-- fileDataIDs — draw it directly. classic shape:
				-- the entry is a bare rect that only keys leatrix
				local exps
				if C_MapExplorationInfo
					and C_MapExplorationInfo
						.GetExploredMapTextures then
					local okE, r = pcall(
						C_MapExplorationInfo
							.GetExploredMapTextures, mapID)
					if okE then exps = r end
				end
				local filed, unfiled = 0
				if exps and exps[1] then
					local e1 = exps[1]
					note("explored=%d e[1] w=%s h=%s ox=%s "
						.. "oy=%s files=%s", #exps,
						tostring(e1.textureWidth),
						tostring(e1.textureHeight),
						tostring(e1.offsetX),
						tostring(e1.offsetY),
						tostring(type(e1.fileDataIDs) == "table"
							and #e1.fileDataIDs))
					unfiled = {}
					for _, e in ipairs(exps) do
						if type(e.fileDataIDs) == "table"
							and e.fileDataIDs[1]
							and (e.textureWidth or 0) > 0 then
							filed = filed + drawRect(
								e.textureWidth, e.textureHeight,
								e.offsetX or 0, e.offsetY or 0,
								e.fileDataIDs)
						else
							unfiled[format("%d:%d:%d:%d",
								e.textureWidth or 0,
								e.textureHeight or 0,
								e.offsetX or 0,
								e.offsetY or 0)] = true
						end
					end
					if not next(unfiled) then unfiled = nil end
					note("explored: %d filed tiles, unfiled=%s",
						filed, tostring(unfiled ~= nil))
				else
					note("explored absent/empty — data gap, "
						.. "leatrix draws its full set")
				end
				-- leatrix key-matching for rects the API didn't
				-- self-describe; skipped entirely when every
				-- explored rect already drew from fileDataIDs
				if records
					and (not exps or not exps[1] or unfiled) then
					local keys = {}
					for key in pairs(records) do
						keys[#keys + 1] = key
					end
					table.sort(keys)
					local function keyed(k)
						local rw, rh, ox, oy = k:match(
							"^(%d+):(%d+):(%d+):(%d+)$")
						rw, rh, ox, oy = tonumber(rw), tonumber(rh),
							tonumber(ox), tonumber(oy)
						if not rw or rw <= 0 then return end
						local files = {}
						for id in records[k]:gmatch("%d+") do
							files[#files + 1] = tonumber(id)
						end
						drawRect(rw, rh, ox, oy, files)
					end
					local match, skipped = 0, 0
					for _, key in ipairs(keys) do
						if not unfiled or unfiled[key] then
							match = match + 1
							keyed(key)
						else
							skipped = skipped + 1
						end
					end
					note("leatrix keys: %d match, %d skipped "
						.. "(unfiled=%s)", match, skipped,
						tostring(unfiled ~= nil))
					-- the API answered but zero keys resolved —
					-- its rect shape doesn't match this client's
					-- dataset (tile vs record granularity). Same
					-- policy as a missing list: draw the records
					if match == 0 and skipped > 0 and filed == 0 then
						for _, key in ipairs(keys) do keyed(key) end
						note("shape mismatch — drew all %d keys",
							#keys)
					end
				end
			end
		end
		note("done: tiles att=%d ok=%d bad=%d haveArt=%s "
			.. "shown=%s alpha=%s", att, okd, bad,
			tostring(haveArt),
			tostring(inner.IsShown and inner:IsShown()),
			tostring(inner.GetAlpha and inner:GetAlpha()))
		if not haveArt then
			local t = put("tile")
			t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
			t:SetVertexColor(0.04, 0.06, 0.05, 1)
			t:SetAllPoints()
		end
		if not G then return end

		-- every record that projects into the displayed frame —
		-- Forever stores one place under several mapIDs, so the
		-- exact-key lists miss cross-map records that draw fine
		local zones, nodes = {}, {}
		for _, list in pairs(GoblinMindGather.zones or {}) do
			for _, zn in ipairs(list) do
				if MapXY(zn, mapID) then
					zones[#zones + 1] = zn
				end
			end
		end
		for _, list in pairs(GoblinMindGather.nodes or {}) do
			for _, nd in ipairs(list) do
				local x, y = MapXY(nd, mapID)
				-- the category filter isolates the overlay —
				-- non-matching camps drop off the map entirely
				if M.OnFrame(x, y)
					and (not filter or nd.kind == filter) then
					nodes[#nodes + 1] = nd
				end
			end
		end
		local ref = nodes[1] or zones[1]
		local upy = UnitsPerYard(mapID, ref)
		local tid = G.TargetID and G.TargetID()
		local oaI = GM.GatherMinimap
			and GM.GatherMinimap.AlphaIcon() or 1
		local S = GM.Widgets.MapStyle
		-- continent/world view: child-zone geometry projects into
		-- the parent's frame at the wrong scale — no camps, pins,
		-- or loops here; the per-zone summary marks replace them
		local worldy = M.IsWorldy(mapID)

		-- route polyline through its stops: a selected route row
		-- draws its loop brighter — only when the drawn stops are
		-- that row's own (a running route on the same map keeps
		-- the normal look); a mismatched category filter drops it
		local run = G.Route and G.Route()
		local r = route
			or (run and run.route and run.route.map == mapID
				and run.route)
			or M.RouteFor(mapID)
		local stops = (run and run.route and run.route.map == mapID
				and run.stops)
			or (r and r.stops)
		local loopKind = (run and run.route
				and run.route.map == mapID and run.route.kind)
			or (r and r.kind)
		local selLoop = sel and sel.stops and stops == sel.stops
		local rt
		if stops and #stops > 1
			and (not filter or loopKind == filter) then
			rt = {
				stops = stops,
				tipFn = r and RouteTip(r),
				a = selLoop and S.A.routeSel or S.A.route,
			}
		end

		paneView.mapID, paneView.w, paneView.h = mapID, w, h
		paneView.L, paneView.upy = L, upy
		paneView.fitScale = w * 4096 + h
		GM.MapMgr.Paint(paneView, {
			mapID = mapID,
			zones = worldy and nil or zones,
			nodes = worldy and nil or nodes,
			route = worldy and nil or rt,
			marks = worldy and marks or nil,
			tid = tid,
			zoneSt = function(zn)
				local zc = G.ZoneCat(zn)
				if filter and zc ~= filter then return nil end
				local match = not tid or G.ZoneTargets(zn, tid)
				local isSel = sel and sel.zone == zn
				return {
					col = G.KindCol(zc),
					fillA = isSel and S.A.zoneFillSel
						or (match and S.A.zoneFill
							or S.A.zoneFillMute),
					ringA = isSel and S.A.zoneRingSel
						or (match and S.A.zoneRing
							or S.A.zoneRingMute),
					ringPx = 2.5,
					sel = isSel,
					iconID = G.ZoneIconID
						and G.ZoneIconID(zn),
					iconA = ((match or isSel) and S.A.full
						or S.A.nonMatch) * oaI,
					iconSz = isSel and S.ZONE_ICON_SEL
						or S.ZONE_ICON,
					mapID = mapID,
				}
			end,
		})
	end

	-- the draw is wrapped: a mid-draw error used to leave
	-- _drawing latched and the pane frozen on the previous map's
	-- tiles forever (the "Eastern Kingdoms shows Kalimdor" bug).
	-- Now the flag always clears and the error is stashed where
	-- the host can surface it instead of failing silently
	function pane:SetData(mapID, route, sel, filter, marks)
		self._mapID, self._route, self._sel, self._filter,
			self._marks = mapID, route, sel, filter, marks
		if self._drawing then return end
		self._drawing = true
		local ok, err = xpcall(draw, function(e)
			return tostring(e)
		end, self, mapID, route, sel, filter, marks)
		self._drawing = nil
		self._err = ok and nil or err
	end

	-- anchored (_fixedH) panes resolve their real size after the
	-- first SetData — redraw into it once it settles, and on any
	-- later resize
	pane:SetScript("OnSizeChanged", function(self, w, h)
		if self._mapID and w and h and w > 0 and h > 0
			and (self._dw ~= w or self._dh ~= floor(h)) then
			self:SetData(self._mapID, self._route, self._sel,
				self._filter, self._marks)
		end
	end)

	return pane
end

-- refresh on map show + a slow ticker while it's open (depleted
-- dimming, route progress)
local mf = CreateFrame("Frame")
pcall(mf.RegisterEvent, mf, "WORLD_MAP_OPEN")
mf.acc = 0
mf:SetScript("OnEvent", function() M.Refresh() end)
mf:SetScript("OnUpdate", function(_, dt)
	mf.acc = mf.acc + dt
	if mf.acc >= 1 then
		mf.acc = 0
		M.Refresh()
	end
end)

-- /goblin mapdebug — dumps the pane's last art-pass trace (what
-- mapID/artID it ran for, which tile source answered, how many
-- files actually loaded). The pane re-traces on every redraw, so
-- open the Gather window on the broken zone first, then run this.
GM.Cmd("mapdebug", function()
	G = G or GM.Gather
	local tr = M.ArtTrace
	if not tr then
		GM.Print("mapdebug: no pane draw yet — "
			.. "open the Gather window first")
		return
	end
	GM.Print("--- map art trace (last pane draw) ---")
	for _, s in ipairs(tr) do GM.Print(s) end
	-- live context: what the map + MapWise are doing right now
	local mapID = CurrentMap()
	local okA, art = pcall(C_Map.GetMapArtID, mapID or 0)
	GM.Print(format(
		"live: worldmap=%s artID=%s shown=%s",
		tostring(mapID), tostring(okA and art),
		tostring(MapShown())))
	if MapWiseAPI then
		local rd = MapWiseAPI.RevealData
		GM.Print(format(
			"MapWise: RevealData=%s rows[artID]=%s "
			.. "revealMap=%s",
			tostring(rd ~= nil),
			tostring(rd and art and rd[art] and #rd[art]),
			tostring(MapWiseAPI.db
				and MapWiseAPI.db.revealMap)))
	end
end, { help = "dump the pane map art-pass trace" })
