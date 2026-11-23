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
	-- terrain layer dynamically — up past the native pin manager's
	-- exploration band (~510) — so re-check it every refresh: a
	-- fixed offset lands UNDER the opaque terrain and the whole
	-- overlay silently vanishes
	local lv = canvas.GetFrameLevel and canvas:GetFrameLevel()
	local want = (lv or 0) + 6
	local terra = _G.ForeverAtlasTerrainLayer
		or (MapWiseAPI and MapWiseAPI.Map and MapWiseAPI.Map.view)
	if terra and terra.GetFrameLevel then
		local tl = terra:GetFrameLevel()
		if tl and tl >= want then want = tl + 1 end
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

-- pocket px points for the fit; records that predate pockets
-- fabricate a span-proportioned scatter (kill-skewed hexagon) so
-- they draw as blobs too instead of falling back to a circle
local function ZonePts(zn, recXY, w, h, rPx)
	local pts = {}
	for _, pk in ipairs(zn.pockets or {}) do
		local px, py = recXY(pk)
		if px and px >= -0.05 and px <= 1.05
			and py >= -0.05 and py <= 1.05 then
			pts[#pts + 1] = { x = px * w, y = py * h }
		end
	end
	if #pts < 3 then
		local zx, zy = recXY(zn)
		if not zx then return pts end
		local cx0, cy0 = zx * w, zy * h
		-- scatter at recorded-span minus the fit's pad so the
		-- resulting blob lands at roughly DispR's footprint
		local r0 = max(20, rPx(DispR(zn) - POCKET_PAD_YD))
		local skew = (zn.kills or 1) * 0.7
		pts = {}
		for i = 0, 5 do
			local a = skew + i / 6 * 6.2831853
			pts[#pts + 1] = { x = cx0 + cos(a) * r0,
				y = cy0 + sin(a) * r0 }
		end
	end
	return pts
end

local function ItemIcon(id)
	if not id then return nil end
	if C_Item and C_Item.GetItemIconByID then
		local ok, ic = pcall(C_Item.GetItemIconByID, id)
		if ok and ic then return ic end
	end
	if GetItemIcon then
		local ok, ic = pcall(GetItemIcon, id)
		if ok and ic then return ic end
	end
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
		local zc = G.ZoneCat and G.ZoneCat(zn) or zn.kind
		local gpm = G.ZoneEV(zn) * G.ZoneRate(zn)
		tip:AddLine(GM.MoneyShort(floor(gpm)) .. "/min"
			.. GM.CC("textDim") .. " · " .. (zn.kills or 0)
			.. " kills · " .. #(zn.pockets or {})
			.. " pockets|r")
		local place = G.ZonePlace and G.ZonePlace(zn)
		tip:AddLine((G.KindHex and G.KindHex(zc) or "")
			.. (G.KindLabel and G.KindLabel(zc) or zc)
			.. "|r" .. (place and (" · " .. place) or ""))
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
			local resp = G.RespawnSec(mapID, nd.kind)
			if not (nd.last
				and (time() - nd.last) < resp * 0.8) then
				dimAll = false
			end
		end
		tip:AddLine("EV ≈ " .. GM.MoneyShort(floor(ev / c.n))
			.. GM.CC("textDim") .. " / spawn|r")
		local order, tally = {}, {}
		for _, nd in ipairs(c.nodes) do
			local nm = nd.name
				or (G.KindLabel and G.KindLabel(nd.kind))
				or nd.kind
			if not tally[nm] then order[#order + 1] = nm end
			tally[nm] = (tally[nm] or 0) + 1
		end
		local names
		for _, nm in ipairs(order) do
			names = (names and names .. " · " or "") .. nm
				.. (tally[nm] > 1 and (" ×" .. tally[nm]) or "")
		end
		tip:AddLine((G.KindHex and G.KindHex(rep.kind) or "")
			.. (G.KindLabel and G.KindLabel(rep.kind)
				or rep.kind) .. "|r  " .. (names or ""))
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


-- zone object: fitted blob (solid border band + translucent
-- interior) or disc fallback, farm icon at the centroid,
-- optional stats tag beneath. st = {
--   col = {r,g,b}, fillA, ringA, ringPx, sel,
--   iconID (item), iconA, iconSz, tag, tagDY,
--   rPx = fn(yd) -> px }
local function ZoneScene(L, zn, prj, w, h, st)
	local zx, zy = prj(zn)
	if not zx then return end
	G = G or GM.Gather
	local col = st.col
	local pts = ZonePts(zn, prj, w, h, st.rPx)
	local poly, cx, cy = ZonePoly(pts,
		st.rPx(POCKET_PAD_YD), st.rPx(ZONE_MIN_YD),
		st.rPx(ZONE_DRAW_MAX_YD))
	if poly then
		L:blob(poly, cx, cy, col[1], col[2], col[3],
			st.fillA, st.ringA, st.ringPx, st.sel)
	else
		cx, cy = zx * w, zy * h
		local rPx = max(10, st.rPx(DispR(zn)))
		-- disc pair: rim + interior — the same border-band
		-- trick the blob uses, so the fallback reads the same
		L:disc(cx, cy, rPx, col[1], col[2], col[3], st.ringA)
		L:disc(cx, cy, max(4, rPx - (st.ringPx or 3)),
			col[1], col[2], col[3], st.fillA)
	end
	if st.iconID then
		local sz = st.iconSz or 18
		L:icon(cx, cy, sz, ItemIcon(st.iconID),
			col[1], col[2], col[3], st.iconA or 1)
		if st.tip ~= false then
			L:hot(cx, cy, sz + 6, sz + 6,
				ZoneTip(zn, st.mapID))
		end
	end
	if st.tag then L:tag(cx, cy + (st.tagDY or 15), st.tag) end
	return cx, cy
end

-- Gatherer-style cluster: best-drop item art sized by group with
-- a count badge beneath. st = { a, shrink, tid } — tid swaps the
-- icon to the target's own and marks the cluster a producer
local function ClusterScene(L, c, w, h, st)
	G = G or GM.Gather
	local rep = c.nodes[1]
	local col = G.KindCol and G.KindCol(rep.kind)
		or G.KIND_COLOR[rep.kind] or { 1, 1, 1 }
	local best
	for _, nd in ipairs(c.nodes) do
		best = best or (G.NodeIconID and G.NodeIconID(nd))
		if st.tid and G.NodeTargets
			and G.NodeTargets(nd, st.tid) then
			best = st.tid
		end
	end
	local a = st.a or 1
	-- Questie-icon scale: a lone spawn reads ~12px like a quest
	-- marker, and only dense clusters push toward 20
	local sz = min(20, 10 + 3 * sqrt(c.n))
	if st.shrink then sz = min(sz, 8) end
	local x, y = c.x * w, c.y * h
	L:icon(x, y, sz, ItemIcon(best), col[1], col[2], col[3], a)
	if c.n > 1 then
		L:badge(x, y + sz / 2 + 6, tostring(c.n),
			col[1], col[2], col[3], a)
	end
	if st.tip ~= false then
		L:hot(x, y, sz + 6, sz + 6, ClusterTip(c, st.mapID))
	end
end

-- solved-loop tooltip: money first — steady-state GPM the
-- saturation model expects — then lap economics and the
-- respawn-uptime derate behind the headline number
local function RouteTip(r)
	return function(tip)
		local G = GM.Gather
		tip:AddLine("≈ " .. GM.MoneyShort(floor(r.gpm or 0))
			.. "/min" .. GM.CC("textDim") .. " expected|r")
		tip:AddLine((G.KindHex and G.KindHex(r.kind) or "")
			.. (G.KindLabel and G.KindLabel(r.kind)
				or "ROUTE") .. "|r loop · " .. #r.stops
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

-- route loop: dashed polyline (rotation-free — the world-map
-- canvas drops rotated textures on this client). tipFn adds
-- invisible hover pads along each leg so the whole loop shows
-- the route-value tooltip without blocking map drags elsewhere
local function RouteScene(L, stops, prj, w, h, a, tipFn)
	for i = 1, #stops do
		local p, q = stops[i], stops[i % #stops + 1]
		local ax, ay = prj(p)
		local bx, by = prj(q)
		if ax and bx then
			local x1, y1 = ax * w, ay * h
			local x2, y2 = bx * w, by * h
			L:dots(x1, y1, x2, y2, 0.4, 0.85, 1.0, a or 0.85)
			if tipFn then
				local len = sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
				local n = max(1, floor(len / 36))
				for j = 0, n - 1 do
					L:hot(x1 + (x2 - x1) * (j + 0.5) / n,
						y1 + (y2 - y1) * (j + 0.5) / n,
						20, 20, tipFn)
				end
			end
		end
	end
end

-- ======================== refresh ========================

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
	-- record -> normalized map coords on the displayed frame;
	-- cross-mapID records reproject via the shared MapXY
	local function RecXY(p)
		local x, y = MapXY(p, map)
		if x and x >= -0.02 and x <= 1.02
			and y and y >= -0.02 and y <= 1.02 then
			return x, y
		end
	end

	-- continent/world view: one mark per zone SLOT (record mapIDs
	-- roll up under their display ancestor — Forever stores one
	-- place under several IDs), medal-ringed by best gpm — the
	-- same ZoneMarks the window pane draws
	if M.IsWorldy(map) then
		local MEDAL = {
			{ 1.0, 0.84, 0.27 },   -- gold
			{ 0.82, 0.84, 0.9 },   -- silver
			{ 0.82, 0.53, 0.22 },  -- bronze
		}
		for _, m in ipairs(M.ZoneMarks(map,
			G.Leaderboard and G.Leaderboard() or {})) do
			local mc = m.medal and MEDAL[m.medal]
				or { 0.55, 0.6, 0.55 }
			L:mark(m.x * w, m.y * h, m.count,
				mc[1], mc[2], mc[3], m.medal)
		end
		return
	end

	-- hunt zones first (under the pins): fitted blob + farm icon
	-- + stats tag. Label = dominant landmark (ZonePlace) +
	-- display category — the raw record kind is always
	-- "hunt"/"skin", never the cloth/meat/mine family the camp
	-- actually farms. A landmark equal to the map's own name adds
	-- nothing — drop it
	local mapName = G.ZoneName and G.ZoneName(map)
	-- every record landing on the displayed map, whatever mapID
	-- the client stored it under (custom zones, Riverglades, ...)
	for _, zl in pairs(GoblinMindGather.zones or {}) do
	for _, zn in ipairs(zl) do
		if RecXY(zn) then
		-- a bad record can't kill the overlay pass — one zone's
		-- draw failing must not take every later zone/pin with it
		pcall(function()
			local zc = G.ZoneCat and G.ZoneCat(zn) or zn.kind
			local col = G.KindCol and G.KindCol(zc)
				or G.KIND_COLOR[zc] or { 1, 1, 1 }
			local place = G.ZonePlace and G.ZonePlace(zn)
			if place == mapName then place = nil end
			local gpm = G.ZoneEV(zn) * G.ZoneRate(zn)
			-- same tag contract as the mod's rows: kind-colored
			-- UPPERCASE label, then stats in text color
			local label = format("%s%s|r%s · %s kills · %s/min",
				G.KindHex and G.KindHex(zc) or "",
				G.KindLabel and G.KindLabel(zc) or zc,
				place and ("  " .. place) or "",
				zn.kills or 0,
				GM.MoneyShort
					and GM.MoneyShort(floor(gpm))
					or tostring(floor(gpm)))
			ZoneScene(L, zn, RecXY, w, h, {
				col = col,
				fillA = 0.22 * oaZ, ringA = 0.85 * oaZ,
				ringPx = 3,
				iconID = G.ZoneIconID and G.ZoneIconID(zn),
				iconA = 0.95 * oaZ,
				tag = label,
				mapID = map,
				rPx = function(yd)
					return YdToPx(draw, yd)
				end,
			})
		end)
		end
	end
	end

	-- node pins: Gatherer-style stacking — records within ~70yd
	-- merge into one spawn icon (best drop's item art) sized and
	-- badged by group; plain colored pin when the client can't
	-- resolve an icon. Dim when every member is inside the
	-- learned respawn window; a set target dims non-producers
	local tid = G.TargetID and G.TargetID()
	local nodes = {}
	for _, list in pairs(GoblinMindGather.nodes or {}) do
		for _, nd in ipairs(list) do
			if RecXY(nd) then nodes[#nodes + 1] = nd end
		end
	end
	local upy = nodes[1] and UnitsPerYard(map, nodes[1])
		or (1 / 1500)
	for _, c in ipairs(Cluster(nodes, RecXY, 70 * upy)) do
		local dimAll, tHit = true, nil
		for _, nd in ipairs(c.nodes) do
			local resp = G.RespawnSec(map, nd.kind)
			if not (nd.last
				and (time() - nd.last) < resp * 0.8) then
				dimAll = false
			end
			if tid and G.NodeTargets
				and G.NodeTargets(nd, tid) then
				tHit = true
			end
		end
		local match = not tid or tHit
		ClusterScene(L, c, w, h, {
			a = (dimAll and 0.35 or (match and 0.95 or 0.3))
				* oaN,
			shrink = not match,
			tid = tid,
			mapID = map,
		})
	end

	-- route polyline: the active run if one's going, else the last
	-- solved route for this map
	local run = G.Route and G.Route()
	local r = run and run.route or M.RouteFor(map)
	local stops = run and run.stops or (r and r.stops)
	if stops and #stops > 1 then
		RouteScene(L, stops, RecXY, w, h, 0.8 * oaN,
			r and RouteTip(r))
		local s = run and run.stops[run.idx]
		local sx, sy = s and RecXY(s)
		if sx then
			L:pin(sx * w, sy * h, 8,
				0.4, 0.85, 1.0, 1 * oaN)
		end
	end
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
-- wrong size — they get summary marks instead of overlays
function M.IsWorldy(mapID)
	if not mapID then return false end
	if mapID == 947 then return true end
	local GetInfo = C_Map and C_Map.GetMapInfo
	if not GetInfo then return false end
	local ok, info = pcall(GetInfo, mapID)
	return ok and info and info.parentMapID == 947
end

-- the record map's slot on the displayed map: the ancestor
-- directly UNDER display. A zone under a continent -> the zone;
-- anything on the world view -> its continent (or the topmost
-- known ancestor on thin-hierarchy clients). One mark per slot —
-- Forever stores a single place under several mapIDs
function M.MapUnder(m, display)
	if not (m and display) or m == display then return nil end
	local GetInfo = C_Map and C_Map.GetMapInfo
	if not GetInfo then return m end -- thin client: own slot
	local cur = m
	for _ = 1, 8 do
		local ok, info = pcall(GetInfo, cur)
		if not ok or not info then break end
		local p = info.parentMapID
		if p == display then return cur end
		if not p or p == 0 or p == cur then break end
		cur = p
	end
	-- walk couldn't prove a slot: the world view rolls up to the
	-- topmost ancestor; deeper views fall back to the map itself —
	-- off-continent groups simply centroid out of bounds
	return display == 947 and cur or m
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
		if x and x >= -0.02 and x <= 1.02
			and y and y >= -0.02 and y <= 1.02 then
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
		-- terrain beats parchment: real ground tiles via
		-- MapWise's index when the addon is present — same look
		-- as their map
		local terrain = TerrainTiles(mapID)
		if terrain then
			for _, t2 in ipairs(terrain) do
				-- edge tiles bleed past the box — crop them with
				-- texcoords like MapWise's Texture() does
				local l = max(0, t2.x)
				local tp = max(0, t2.y)
				local rr = min(1, t2.x + t2.w)
				local bb = min(1, t2.y + t2.h)
				local t = put("tile")
				local okS, loaded = pcall(t.SetTexture, t,
					t2.file, "CLAMP", "CLAMP", "TRILINEAR")
				if not okS then
					okS, loaded = pcall(t.SetTexture, t, t2.file)
				end
				if okS and loaded ~= false then
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
		end
		if not terrain and C_Map and C_Map.GetMapArtLayers
			and C_Map.GetMapArtLayerTextures then
			local okL, layers = pcall(C_Map.GetMapArtLayers, mapID)
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
							-- MapWise load pattern: checked
							-- SetTexture with clamp+filter, plain
							-- retry, hide on genuine failure
							local okS, loaded = pcall(t.SetTexture, t,
								fileID, "CLAMP", "CLAMP",
								"TRILINEAR")
							if not okS then
								okS, loaded = pcall(t.SetTexture,
									t, fileID)
							end
							if okS and loaded ~= false then
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
		-- explored-art overlay over the parchment: the client's
		-- own overlay tiles via the vendored Leatrix dataset
		-- (MapRevealData[artID]["w:h:ox:oy"] -> tile fileIDs).
		-- Gated by GetExploredMapTextures rects when the API
		-- answers — exact current-state like the default map UI;
		-- an absent/empty explored list is a custom-zone data gap,
		-- so the full set draws rather than a bare parchment.
		if not terrain then
			local artID = C_Map and C_Map.GetMapArtID
				and C_Map.GetMapArtID(mapID)
			local records = artID and GM.MapRevealData
				and GM.MapRevealData[artID]
			local okL2, lay2 = pcall(C_Map.GetMapArtLayers, mapID)
			local lay = okL2 and lay2 and lay2[1]
			if records and lay and lay.tileWidth
				and lay.tileWidth > 0 then
				local explored
				if C_MapExplorationInfo
					and C_MapExplorationInfo
						.GetExploredMapTextures then
					local okE, exps = pcall(
						C_MapExplorationInfo
							.GetExploredMapTextures, mapID)
					if okE and exps and exps[1] then
						explored = {}
						for _, e in ipairs(exps) do
							explored[format(
								"%d:%d:%d:%d",
								e.textureWidth or 0,
								e.textureHeight or 0,
								e.offsetX or 0,
								e.offsetY or 0)] = true
						end
					end
				end
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
				local keys = {}
				for key in pairs(records) do keys[#keys + 1] = key end
				table.sort(keys)
				for _, key in ipairs(keys) do
					if not explored or explored[key] then
						local rw, rh, ox, oy = key:match(
							"^(%d+):(%d+):(%d+):(%d+)$")
						rw, rh, ox, oy = tonumber(rw), tonumber(rh),
							tonumber(ox), tonumber(oy)
						if rw and rw > 0 then
							local files = {}
							for id in records[key]:gmatch("%d+") do
								files[#files + 1] = tonumber(id)
							end
							local cols = math.ceil(rw / lay.tileWidth)
							local rows = math.ceil(rh / lay.tileHeight)
							for row = 0, rows - 1 do
								for col = 0, cols - 1 do
									local fid = files[
										row * cols + col + 1]
									if fid then
										local tw2 = min(
											lay.tileWidth,
											rw - col
												* lay.tileWidth)
										local th2 = min(
											lay.tileHeight,
											rh - row
												* lay.tileHeight)
										local t = put("exptile")
										local okS, loaded =
											pcall(t.SetTexture, t,
												fid, "CLAMP",
												"CLAMP",
												"TRILINEAR")
										if not okS then
											okS, loaded = pcall(
												t.SetTexture, t, fid)
										end
										if okS and loaded ~= false then
											t:SetTexCoord(0,
												tw2 / fsize(
													tw2,
													lay.tileWidth),
												0,
												th2 / fsize(
													th2,
													lay.tileHeight))
											t:SetSize(tw2 * pw,
												th2 * ph)
											t:SetPoint("TOPLEFT",
												inner, "TOPLEFT",
												(ox + col
													* lay.tileWidth)
													* pw,
												-(oy + row
													* lay.tileHeight)
													* ph)
											haveArt = true
										else
											t:Hide()
										end
									end
								end
							end
						end
					end
				end
			end
		end
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
				if MapXY(nd, mapID) then
					nodes[#nodes + 1] = nd
				end
			end
		end
		local ref = nodes[1] or zones[1]
		local upy = UnitsPerYard(mapID, ref)
		local tid = G.TargetID and G.TargetID()
		-- continent/world view: child-zone geometry projects into
		-- the parent's frame at the wrong scale — no camps, pins,
		-- or loops here; the per-zone summary marks replace them
		local worldy = M.IsWorldy(mapID)

		-- hunt zones under everything: disc + drop icon at center.
		-- With a target set, non-producers recede to a faint trace.
		-- Out-of-bounds projections (bad world->map for records with
		-- no stored x,y) get skipped — a px<0 disc bleeds outside the
		-- pane into the list column
		if not worldy then
		for _, zn in ipairs(zones) do
			local zc = G.ZoneCat and G.ZoneCat(zn) or zn.kind
			local x, y = MapXY(zn, mapID)
			if x and x > -0.02 and x < 1.02
				and y > -0.02 and y < 1.02
				-- the category filter isolates the overlay —
				-- non-matching camps drop off the map entirely
				and (not filter or zc == filter) then
				local match = not tid or G.ZoneTargets(zn, tid)
				-- the selected row's camp pops: brighter fill/ring
				-- plus an outer accent band
				local isSel = sel and sel.zone == zn
				local col = G.KindCol and G.KindCol(zc)
					or G.KIND_COLOR[zc] or { 1, 1, 1 }
				ZoneScene(L, zn,
					function(p) return MapXY(p, mapID) end,
					w, h, {
						col = col,
						fillA = isSel and 0.3
							or (match and 0.18 or 0.06),
						ringA = isSel and 0.95
							or (match and 0.55 or 0.15),
						ringPx = 2.5,
						sel = isSel,
						iconID = G.ZoneIconID
							and G.ZoneIconID(zn),
						iconA = (match or isSel) and 1 or 0.3,
						iconSz = isSel and 24 or 18,
						mapID = mapID,
						rPx = function(yd)
							return yd * upy * w
						end,
					})
			end
		end

		-- node clusters; icon = best drop (target's own icon when
		-- it's among them), size ∝ group size, non-producers dim
		local drawable = {}
		for _, nd in ipairs(nodes) do
			local x, y = MapXY(nd, mapID)
			if x and x > -0.02 and x < 1.02
				and y > -0.02 and y < 1.02
				and (not filter or nd.kind == filter) then
				drawable[#drawable + 1] = nd
			end
		end
		local clusters = Cluster(drawable,
			function(nd) return MapXY(nd, mapID) end, 70 * upy)
		for _, c in ipairs(clusters) do
			local tHit
			for _, nd in ipairs(c.nodes) do
				if tid and G.NodeTargets(nd, tid) then tHit = true end
			end
			local match = not tid or tHit
			ClusterScene(L, c, w, h, {
				a = match and 1 or 0.25,
				shrink = not match,
				tid = tid,
				mapID = mapID,
			})
		end

		-- route polyline through its stops
		local run = G.Route and G.Route()
		local r = route
			or (run and run.route and run.route.map == mapID
				and run.route)
			or M.RouteFor(mapID)
		local stops = (run and run.route and run.route.map == mapID
				and run.stops)
			or (r and r.stops)
		-- the kind the drawn loop belongs to — a mismatched
		-- category filter drops it off the overlay too
		local loopKind = (run and run.route
				and run.route.map == mapID and run.route.kind)
			or (r and r.kind)
		-- a selected route row draws its loop wider and brighter —
		-- only when the drawn stops are that row's own (a running
		-- route on the same map keeps the normal look)
		local selLoop = sel and sel.stops and stops == sel.stops
		if stops and #stops > 1
			and (not filter or loopKind == filter) then
			RouteScene(L, stops, function(p)
				local px, py = MapXY(p, mapID)
				if px and px > -0.02 and px < 1.02
					and py > -0.02 and py < 1.02 then
					return px, py
				end
			end, w, h, selLoop and 1 or 0.85,
				r and RouteTip(r))
		end
		end -- not worldy

		-- per-zone summary marks on continent/world maps: count
		-- of camps+routes, medal ring for the top-3 GPM zones
		if worldy and marks then
			local MEDAL = {
				{ 1.0, 0.84, 0.27 },   -- gold
				{ 0.82, 0.84, 0.9 },   -- silver
				{ 0.82, 0.53, 0.22 },  -- bronze
			}
			for _, m in ipairs(marks) do
				if m.x and m.x > -0.02 and m.x < 1.02
					and m.y > -0.02 and m.y < 1.02 then
					local mc = m.medal and MEDAL[m.medal]
						or { 0.55, 0.6, 0.55 }
					L:mark(m.x * w, m.y * h, m.count,
						mc[1], mc[2], mc[3], m.medal)
				end
			end
		end
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
