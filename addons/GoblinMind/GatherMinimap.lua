-- GatherMinimap.lua — live gather overlays on the minimap: node
-- pins, hunt-zone discs, and the active route loop, each layer
-- toggleable per category. Geometry follows the HBD-Pins model:
-- world-yard offsets from the player scaled by the view radius,
-- rotated by facing when the minimap spins.

local addonName, GM = ...
local M = {}
GM.GatherMinimap = M

local UnitPosition = UnitPosition
local GetCVar = GetCVar
local GetPlayerFacing = GetPlayerFacing
local CreateVector2D = CreateVector2D
local CreateFrame = CreateFrame
local ipairs, pairs, wipe = ipairs, pairs, wipe
local sqrt, cos, sin, floor, abs =
	math.sqrt, math.cos, math.sin, math.floor, math.abs
local atan2 = math.atan2 or math.atan

local DISC = "Interface\\AddOns\\" .. addonName .. "\\Media\\disc"
local RING = "Interface\\AddOns\\" .. addonName .. "\\Media\\ring"
local FLAT = "Interface\\Buttons\\WHITE8X8"
local CLIP2 = 0.81            -- (0.9)^2 — pins clip at 90% radius

-- zoom-level -> view diameter in yards (the HBD-Pins table);
-- C_Minimap.GetViewRadius wins when the API exists
local VIEW = {
	indoor  = { [0] = 300, 240, 180, 120, 80, 50 },
	outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 1 / 3,
		200, 133 + 1 / 3 },
}

-- layer list derives from the kind registry (this file loads
-- before Gather.lua) — rebuilt lazily on first access so a
-- registered kind shows up with no list edits
local layerSrc
function M.Layers()
	if layerSrc ~= GM.Gather then
		M.LAYERS = { "route" }
		M.LABEL = { route = "ROUTE" }
		for _, k in ipairs(GM.Gather and GM.Gather.KINDS or {}) do
			M.LAYERS[#M.LAYERS + 1] = k
			M.LABEL[k] = GM.Gather.KindLabel(k)
		end
		layerSrc = GM.Gather or false
	end
	return M.LAYERS
end

local function mm()
	GoblinMindGather = GoblinMindGather or {}
	GoblinMindGather.mm = GoblinMindGather.mm or {}
	return GoblinMindGather.mm
end

function M.Enabled(k)
	return mm()[k] ~= false
end
function M.Set(k, on)
	mm()[k] = on and true or false
end
-- world-map overlay opacity (split per object family) + per-kind
-- fill colors ride the same mm settings table — one persistence
-- surface for all map layers. alphaZone falls back to the legacy
-- single "alpha" key so existing settings carry over
function M.AlphaZone()
	return mm().alphaZone or mm().alpha or 1
end
function M.AlphaNode()
	return mm().alphaNode or 1
end
function M.AlphaIcon()
	return mm().alphaIcon or 1
end
function M.SetAlphaZone(v)
	mm().alphaZone = tonumber(v) or 1
end
function M.SetAlphaNode(v)
	mm().alphaNode = tonumber(v) or 1
end
function M.SetAlphaIcon(v)
	mm().alphaIcon = tonumber(v) or 1
end
function M.Color(k)
	local c = mm().col
	return c and c[k]
end
function M.SetColor(k, r, g, b)
	local t = mm()
	t.col = t.col or {}
	if r then t.col[k] = { r, g, b } else t.col[k] = nil end
end
function M.Count()
	local n = 0
	for _, k in ipairs(M.Layers()) do
		if M.Enabled(k) then n = n + 1 end
	end
	return n, #M.LAYERS
end

-- ======================== overlay frame ========================

local host, pools, live

local function ensureHost()
	if host or not Minimap then return host ~= nil end
	host = CreateFrame("Frame", addonName .. "GatherMinimap", Minimap)
	host:SetAllPoints(Minimap)
	host:SetFrameStrata(Minimap:GetFrameStrata())
	host:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 3)
	-- rectangular clip is all the frame API gives; the circle is
	-- enforced per element — border art covers the corner bleed
	pcall(host.SetClipsChildren, host, true)
	pools, live = {}, {}
	return true
end

local function put(kind)
	local pool = pools[kind]
	if not pool then
		pool = {}
		pools[kind] = pool
	end
	local t = pool[#pool]
	if not t then
		t = host:CreateTexture(nil, "OVERLAY")
		if kind == "seg" then
			t:SetTexture(FLAT)
			t:SetDrawLayer("OVERLAY", 4)
		elseif kind == "zring" then
			t:SetTexture(FLAT)
			t:SetDrawLayer("OVERLAY", 1)
		elseif kind == "zfill" then
			t:SetTexture(FLAT)
			t:SetDrawLayer("OVERLAY", 2)
		elseif kind == "ring" then
			t:SetTexture(RING)
			t:SetDrawLayer("OVERLAY", 1)
		elseif kind == "zone" then
			t:SetTexture(DISC)
			t:SetDrawLayer("OVERLAY", 0)
		elseif kind == "stop" then
			t:SetTexture(RING)
			t:SetDrawLayer("OVERLAY", 5)
		elseif kind == "pin" then
			t:SetTexture(FLAT)
			t:SetDrawLayer("OVERLAY", 5)
		elseif kind == "icon" then
			t:SetTexture(DISC)   -- real item art set per draw
			t:SetDrawLayer("OVERLAY", 6)
		else
			t:SetTexture(DISC)
			t:SetDrawLayer("OVERLAY", kind == "edge" and 6 or 7)
		end
	end
	pool[#pool] = nil
	t:ClearAllPoints()
	t:Show()
	live[#live + 1] = { kind, t }
	return t
end

-- fontstring pool for cluster count badges — textures can't
-- carry text and a second object type pools identically
local function putStr(kind)
	local pool = pools[kind]
	if not pool then
		pool = {}
		pools[kind] = pool
	end
	local fs = pool[#pool]
	if not fs then
		fs = host:CreateFontString(nil, "OVERLAY")
		fs:SetFont(GM.FONT, 8, "OUTLINE")
	end
	pool[#pool] = nil
	fs:ClearAllPoints()
	fs:Show()
	live[#live + 1] = { kind, fs }
	return fs
end

-- shared cluster merge runs in world-yard space here (the map
-- surfaces run it in map-fraction space) — same routine either way
local cluMap, cluN, cluSig, cluList

-- per-record zone blob fits, in anchor-relative world yards.
-- Keyed weakly by the SV record (zones persist for the session;
-- the fit only changes when pockets/kills/radius do, so a
-- signature check rebuilds it — movement alone can never reshape)
local zoneFit = setmetatable({}, { __mode = "k" })



local function WrapNodes(mapID, recs, mmSet)
	local sig = ""
	for _, k in ipairs(M.Layers()) do
		sig = sig .. (mmSet[k] ~= false and "1" or "0")
	end
	if cluMap == mapID and cluN == #recs and cluSig == sig then
		return cluList
	end
	cluMap, cluN, cluSig, cluList = mapID, #recs, sig, {}
	for _, nd in ipairs(recs) do
		if mmSet[nd.kind] ~= false then
			local nn, ww = nd.n, nd.w
			if not (nn and ww) and nd.x and nd.y then
				nn, ww = GM.WorldPos(mapID, nd.x, nd.y)
			end
			if nn and ww then
				cluList[#cluList + 1] = { nd = nd, n = nn, w = ww }
			end
		end
	end
	return cluList
end

local function clear()
	if not live then return end
	for _, e in ipairs(live) do
		e[2]:Hide()
		pools[e[1]][#pools[e[1]] + 1] = e[2]
	end
	wipe(live)
end

-- ======================== per-frame geometry ========================

local function Player()
	local ok, n, w, z, c = pcall(UnitPosition, "player")
	if not ok or type(n) ~= "number" or n == 0 then return nil end
	local mapID
	if C_Map and C_Map.GetBestMapForUnit then
		local okM, m = pcall(C_Map.GetBestMapForUnit, "player")
		if okM then mapID = m end
	end
	if not mapID then return nil end
	return n, w, c, mapID
end


-- ======================= per-frame view state =======================
-- populated by Update() before each paint; the adapter + helpers
-- below close over it so projections always read the current frame
local V = {}

-- world-yard offset -> normalized circle coords (u = east, v = north,
-- range roughly -1..1 inside the radar disc)
local function uv(nw, nn)
	local dx, dy = V.w - nw, V.n - nn
	if V.rotate then
		dx, dy = dx * V.cs - dy * V.sn, dx * V.sn + dy * V.cs
	end
	return dx / V.radius, dy / V.radius
end

-- segment-disc intersection: return the chord inside the clip
-- circle, nil when the segment misses it entirely. The old
-- both-outside early-out culled chords that cross the radar
-- edge-to-edge -- that's what chopped visible gaps into routes
local function clip(u1, v1, u2, v2)
	local du, dv = u2 - u1, v2 - v1
	local aa = du * du + dv * dv
	if aa == 0 then
		if u1 * u1 + v1 * v1 <= CLIP2 then
			return u1, v1, u2, v2
		end
		return nil
	end
	local bb = 2 * (u1 * du + v1 * dv)
	local cc = u1 * u1 + v1 * v1 - CLIP2
	local disc = bb * bb - 4 * aa * cc
	if disc <= 0 then return nil end
	local sq = sqrt(disc)
	local lo = math.max(0, (-bb - sq) / (2 * aa))
	local hi = math.min(1, (-bb + sq) / (2 * aa))
	if lo >= hi then return nil end
	return u1 + du * lo, v1 + dv * lo,
		u1 + du * hi, v1 + dv * hi
end

-- one route chord in normalized coords, clipped to the radar disc
local function seg(u1, v1, u2, v2, a)
	local x1, y1, x2, y2 = clip(u1, v1, u2, v2)
	if not x1 then return end
	x1, y1, x2, y2 = x1 * V.hw, -y1 * V.hh, x2 * V.hw, -y2 * V.hh
	local dx, dy = x2 - x1, y2 - y1
	local len = sqrt(dx * dx + dy * dy)
	if len < 2 then return end
	local t = put("seg")
	t:SetSize(len, 2)
	t:SetPoint("CENTER", host, "CENTER",
		(x1 + x2) / 2, (y1 + y2) / 2)
	if t.SetRotation then
		-- y is up-positive here (CENTER offsets), so no
		-- sign flip like the TOPLEFT-space map pane uses.
		-- WoW's atan2/math.atan return degrees — SetRotation
		-- wants radians
		pcall(t.SetRotation, t, math.rad(atan2(dy, dx)))
	end
	t:SetVertexColor(0.4, 0.85, 1.0, a)
end

-- ========================== view: minimap ==========================
-- the manager's radar adapter: world yards -> normalized disc ->
-- TOPLEFT px, circle clip/rim/fade where flat views pass through
local mmView = {
	id = "minimap",
	feats = {},
	fit = zoneFit,
	L = {},
}
local mL = mmView.L

function mmView:proj(rec)
	local nn, ww = rec.n, rec.w
	if not (nn and ww) and rec.x and rec.y and (rec.map or V.mapID) then
		nn, ww = GM.WorldPos(rec.map or V.mapID, rec.x, rec.y)
		-- memoize the projection onto the record -- an intermittent
		-- WorldPos failure must not flap the fit's inputs between
		-- frames (the blob visibly jumps when a pocket drops out
		-- for one repaint)
		if nn and ww then rec.n, rec.w = nn, ww end
	end
	if not (nn and ww) then return end
	-- continent guard: foreign-continent records carry that
	-- continent's yard space -- without this a Kalimdor camp
	-- ghost-renders on the EK radar at whatever position the
	-- overlapping ranges land, sliding with the player
	if (rec.c or V.c) ~= V.c then return end
	local u, v = uv(ww, nn)
	return V.hw + u * V.hw, V.hh + v * V.hh
end

-- pocket pts for the shared fit, anchor-relative px: the vert's
-- TOPLEFT delta from the anchor's TOPLEFT is just the yard delta
-- negated into the same axes (u,v both flip sign relative to
-- (west,north) deltas) times the px-per-yard scale
function mmView:ptsRel(zn)
	local pts = {}
	local znN, znW = zn.n, zn.w
	if not (znN and znW) and zn.x and zn.y and zn.map then
		znN, znW = GM.WorldPos(zn.map, zn.x, zn.y)
		if znN and znW then zn.n, zn.w = znN, znW end
	end
	if not (znN and znW) then return pts end
	local kx, ky = V.hw / V.radius, V.hh / V.radius
	for _, pk in ipairs(zn.pockets or {}) do
		local pn, pw = pk.n, pk.w
		if not (pn and pw) and pk.x and pk.y and pk.map then
			pn, pw = GM.WorldPos(pk.map, pk.x, pk.y)
			if pn and pw then pk.n, pk.w = pn, pw end
		end
		if pn and pw and (pk.c or V.c) == V.c then
			pts[#pts + 1] = { x = (znW - pw) * kx,
				y = (znN - pn) * ky }
		end
	end
	return pts
end

function mmView:rPx(yd) return yd * V.hw / V.radius end

-- beyond the radar disc + slack = undrawable (flat views use the
-- frame rect; the circle is the radar's equivalent)
function mmView:cull(x, y, slack)
	local dx, dy = x - V.hw, y - V.hh
	return dx * dx + dy * dy
		> (V.hw * 0.9 + (slack or 0)) ^ 2
end

-- off-rim clusters pin to the radar edge so recorded spawns keep
-- pointing at themselves (flat views pass through)
function mmView:rim(x, y)
	local dx, dy = x - V.hw, y - V.hh
	local d2 = dx * dx + dy * dy
	local lim = V.hw * 0.9
	if d2 <= lim * lim then return x, y end
	local s = lim * 0.96 / sqrt(d2)
	return V.hw + dx * s, V.hh + dy * s, true
end

-- steep distance fade on the TRUE range: full at the center,
-- ~24% at the rim, floor ~12% for far pins -- near spawns pop,
-- distant ones are whispers. States only lower it (S3)
function mmView:fade(x, y)
	local dx, dy = x - V.hw, y - V.hh
	return math.max(0.12, 1 - 0.85 * sqrt(dx * dx + dy * dy) / V.hw)
end

function mmView:iconSz(n)
	return GM.Widgets.MapStyle.ClusterSize(n, true)
end

function mmView:routeSeg(x1, y1, x2, y2, a)
	seg((x1 - V.hw) / V.hw, (y1 - V.hh) / V.hh,
		(x2 - V.hw) / V.hw, (y2 - V.hh) / V.hh, a)
end

function mmView:routeStop(x, y, a)
	local s = put("stop")
	s:SetSize(7, 7)
	s:SetPoint("CENTER", host, "TOPLEFT", x, -y)
	s:SetVertexColor(0.4, 0.85, 1.0, a)
end

-- Gatherer-style merge in world-yard space (the flat views run it
-- in map-fraction space -- same routine either way). Returns raw
-- node records per cluster; past ~2.5 view radii a rim pin stops
-- being radar and becomes border noise -- cull it outright
function mmView:clusters(nodes)
	local recs = WrapNodes(V.mapID, nodes, V.mmSet)
	local out = {}
	for _, c in ipairs(GM.GatherMap.Cluster(recs,
			function(r) return r.w, r.n end, 70)) do
		local u, v = uv(c.x, c.y)
		if u * u + v * v <= 6.25 then
			local raw = {}
			for i, r in ipairs(c.nodes) do raw[i] = r.nd end
			out[#out + 1] = { nodes = raw, n = c.n,
				x = V.hw + u * V.hw, y = V.hh + v * V.hh }
		end
	end
	return out
end

-- ======================= minimap primitives ========================
-- MapLayer-compatible set in TOPLEFT px, backed by the radar's
-- texture/fontstring pools
function mL:clear() clear() end

function mL:pin(x, y, sz, r, g, b, a)
	local t = put("pin")
	t:SetSize(sz, sz)
	t:SetPoint("CENTER", host, "TOPLEFT", x, -y)
	t:SetVertexColor(r, g, b, a or 1)
end

function mL:disc(x, y, rPx, r, g, b, a)
	local t = put("zone")
	t:SetSize(rPx * 2, rPx * 2)
	t:SetPoint("CENTER", host, "TOPLEFT", x, -y)
	t:SetVertexColor(r, g, b, a or 1)
end

-- same rule as MapLayer's icon: real item art stays natural, the
-- kind tint is only for the fallback disc
function mL:icon(x, y, sz, fid, r, g, b, a)
	local t = put("icon")
	if fid then
		t:SetTexture(fid)
		t:SetVertexColor(1, 1, 1, a or 1)
	else
		t:SetTexture(DISC)
		t:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
	end
	t:SetSize(sz, sz)
	t:SetPoint("CENTER", host, "TOPLEFT", x, -y)
end

function mL:badge(x, y, text, r, g, b, a)
	local t = putStr("badge")
	t:SetPoint("CENTER", host, "TOPLEFT", x, -y)
	t:SetText(text)
	t:SetTextColor(r or 1, g or 1, b or 1, a or 1)
end

-- the canonical camp look everywhere: border band + dim interior,
-- scanline fill clipped to the radar circle band-by-band
function mL:blob(poly, cx, cy, r, g, b, fillA, ringA, ringPx, sel)
	ringPx = ringPx or 3
	local W = GM.Widgets
	if sel then
		W.PolyFill(host, W.PolyShrink(poly, cx, cy, ringPx + 3),
			6, 1, 0.82, 0.1, 0.9,
			function() return put("zring") end, V.clipC)
	end
	W.PolyFill(host, poly, 6, r, g, b, ringA,
		function() return put("zring") end, V.clipC)
	W.PolyFill(host, W.PolyShrink(poly, cx, cy, -ringPx),
		6, r, g, b, fillA,
		function() return put("zfill") end, V.clipC)
end

local function Update()
	if not ensureHost() then return end
	local G = GM.Gather
	if not G or not Minimap:IsVisible() then clear() return end
	local n, w, c, mapID = Player()
	if not n then clear() return end

	-- view radius in yards: the zoom-level table is authoritative --
	-- GetViewRadius misreports on Forever (returns 150 where the
	-- outdoor zoom-0 scale is 233.33, shrinking our yard span ~36%
	-- so every overlay element slides ~1.55x against the terrain =
	-- the zone "parallax"). API is only the fallback for a zoom
	-- the table doesn't know. The minimapZoom cvar pins the
	-- outdoor zoom -- matching it means we're outdoors
	local zoom = Minimap:GetZoom() or 0
	local indoor = (GetCVar("minimapZoom") or 0) + 0 ~= zoom
	local radius = ((indoor and VIEW.indoor or VIEW.outdoor)[zoom]
		or 0) / 2
	if radius <= 0 then
		radius = C_Minimap and C_Minimap.GetViewRadius
			and C_Minimap.GetViewRadius()
	end
	if not radius or radius <= 0 then clear() return end

	local rotate = GetCVar("rotateMinimap") == "1"
	local facing = rotate and (GetPlayerFacing() or 0) or 0
	V.rotate = rotate
	V.cs, V.sn = cos(facing), sin(facing)
	V.hw, V.hh = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
	if V.hw <= 0 or V.hh <= 0 then clear() return end
	V.n, V.w, V.c, V.mapID, V.radius = n, w, c, mapID, radius
	V.mmSet = mm()
	V.clipC = { x = V.hw, y = V.hh, r = V.hw * 0.9 }
	mmView.fitScale = floor(V.hw / V.radius * 4096)

	clear()

	-- opacity channels: the route is node geometry, so it rides
	-- oaN (muting nodes must mute its loop)
	local oaZ = M.AlphaZone()
	local oaN = M.AlphaNode()
	local oaI = M.AlphaIcon()
	local SA = GM.Widgets.MapStyle.A
	local mmSet = V.mmSet

	-- every record list: world-yard space has no map frames, the
	-- adapter's continent guard + distance cull do the filtering
	local zones = {}
	for _, zl in pairs(GoblinMindGather.zones or {}) do
		for _, zn in ipairs(zl) do zones[#zones + 1] = zn end
	end

	-- route loop (running route wins over the noted one)
	local run = G.Route()
	local rt = (run and run.route and run.route.map == mapID
			and run.route)
		or (GM.GatherMap and GM.GatherMap.RouteFor(mapID))
	local route = rt and rt.stops and #rt.stops > 1
		and mmSet.route ~= false
		and { stops = rt.stops, a = SA.route * oaN }

	GM.MapMgr.Paint(mmView, {
		mapID = mapID,
		zones = zones,
		nodes = oaN > 0 and G.NodeList(mapID) or nil,
		route = route,
		oa = { n = oaN },
		zoneSt = function(zn)
			local zc = G.ZoneCat(zn)
			if mmSet[zc] == false then return nil end
			local col = G.KindCol(zc)
			return {
				col = col,
				fillA = SA.zoneFill * oaZ,
				ringA = SA.zoneRing * oaZ,
				ringPx = 2,
				iconID = G.ZoneIconID and G.ZoneIconID(zn),
				iconSz = GM.Widgets.MapStyle.ZONE_ICON_MM,
				iconA = SA.full * oaI,
			}
		end,
	})
end

M.Update = Update

local mmDebugT0, mmDebugN, mmDebugW

-- radius resolution diagnostic: the live API is trusted over the
-- zoom table — if it misreports on this client the whole overlay
-- parallaxes against the terrain (the camp-zone drift report).
-- /goblin mmdebug prints both sources at the current zoom
GM.Cmd("mmdebug", function()
	local apiR = C_Minimap and C_Minimap.GetViewRadius
		and C_Minimap.GetViewRadius()
	local zoom = Minimap and Minimap:GetZoom() or 0
	local indoor = (GetCVar("minimapZoom") or 0) + 0 ~= zoom
	local tblR = ((indoor and VIEW.indoor or VIEW.outdoor)[zoom]
		or 0) / 2
	GM.Print(("minimap: zoom=%s indoor=%s api=%s table=%s rotate=%s facing=%s")
		:format(tostring(zoom), tostring(indoor),
			tostring(apiR), tostring(tblR),
			GetCVar("rotateMinimap") or "?",
			tostring(GetPlayerFacing and GetPlayerFacing())))
	-- axis-swap probe: UnitPosition's (n,w) vs the world-space
	-- re-projection of the same spot. If unitN tracks wpW instead
	-- of wpN the client's returns are (east,north), not
	-- (north,west) — the whole overlay is axis-swapped and a
	-- world-fixed point drifts on one screen axis only
	local n, w, z, c = UnitPosition("player")
	local mapID = C_Map and C_Map.GetBestMapForUnit
		and C_Map.GetBestMapForUnit("player")
	local x, y
	if mapID then x, y = GM.MapPos(c, n, w, mapID) end
	local wpn, wpw, wpc
	if x and y and GM.WorldPos then
		wpn, wpw, wpc = GM.WorldPos(mapID, x, y)
	end
	GM.Print(("unit: n=%.1f w=%.1f c=%s | map=%s x=%.3f y=%.3f | wp: n=%s w=%s c=%s")
		:format(n or -1, w or -1, tostring(c), tostring(mapID),
			x or -1, y or -1,
			tostring(wpn), tostring(wpw), tostring(wpc)))
	-- axis-identity probe: field NAMES may not match field
	-- MEANINGS. Run once, walk ~20yd in a known direction, run
	-- again — the field that moved is that axis
	local dt = mmDebugT0 and (GetTime() - mmDebugT0)
	if mmDebugT0 then
		GM.Print(("delta since last call (%.0fs): dn=%.1f dw=%.1f")
			:format(dt or 0, n - mmDebugN, w - mmDebugW))
	end
	mmDebugT0, mmDebugN, mmDebugW = GetTime(), n, w
	-- live projection dump for fish zones: what the renderer
	-- computes for the anchor — if u0 barely moves while you
	-- walk E-W, the horizontal displacement is dead at runtime
	for _, zl in pairs(GoblinMindGather
			and GoblinMindGather.zones or {}) do
		for _, zn in ipairs(zl) do
			if zn.kind == "fish" and zn.n and zn.w then
				local dx, dy = w - zn.w, n - zn.n
				GM.Print(("zone fish: dn=%.0f dw=%.0f -> u=%.2f v=%.2f (anchor n=%.0f w=%.0f | n=%.1f)")
					:format(dy, dx, dx / tblR, dy / tblR,
						zn.n, zn.w, n))
			end
		end
	end
	-- stability probe: if a second read of the same spot differs
	-- microseconds later, UnitPosition returns unstable values —
	-- that alone would parallax every world-fixed element
	local n2, w2 = UnitPosition("player")
	GM.Print(("recheck: n=%s w=%s (first read n=%.1f w=%.1f)")
		:format(tostring(n2), tostring(w2), n or -1, w or -1))
end, { prefix = true })

local acc = 0
local tick = CreateFrame("Frame")
tick:SetScript("OnUpdate", function(_, dt)
	acc = acc + dt
	if acc < 0.12 then return end
	acc = 0
	Update()
end)
