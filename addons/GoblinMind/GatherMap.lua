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
-- atan2 exists on WoW's Lua 5.1-derived runtime; newer hosts (the
-- harness) only have two-arg atan
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

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

-- ======================== pooled primitives ========================

-- pools hold idle objects; `live` holds what the last pass drew —
-- refresh hides live, returns it to the pools, then redraws
local pinPool, linePool, circPool = {}, {}, {}
local live = {}

local function Reclaim()
	for _, o in ipairs(live) do
		o:Hide()
		o:SetParent(nil)
	end
	wipe(live)
end

local function PutPin(canvas)
	local t = tremove(pinPool)
	if not t then
		t = canvas:CreateTexture(nil, "OVERLAY")
		t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
	end
	t:SetParent(canvas)
	t:Show()
	live[#live + 1] = t
	return t
end

local function PutLine(canvas)
	local t = tremove(linePool)
	if not t then
		t = canvas:CreateTexture(nil, "OVERLAY", nil, 1)
		t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
	end
	t:SetParent(canvas)
	t:Show()
	live[#live + 1] = t
	return t
end

local function PutZone(canvas)
	local c = tremove(circPool)
	if not c then
		c = { fill = canvas:CreateTexture(nil, "OVERLAY") }
		-- vendored soft circle — SetMaskTexture no-ops on this
		-- client and left a square halo over the map; the TGA
		-- carries its own alpha edge (same fix as the pane discs)
		c.fill:SetTexture(
			"Interface\\AddOns\\GoblinMind\\Media\\disc.tga")
		c.label = canvas:CreateFontString(nil, "OVERLAY",
			"GameFontHighlightSmall")
	end
	c.fill:SetParent(canvas)
	c.fill:Show()
	c.label:SetParent(canvas)
	c.label:Show()
	live[#live + 1] = c.fill
	live[#live + 1] = c.label
	return c
end

-- ======================== draw helpers ========================

local function DrawPin(canvas, x, y, r, g, b, a)
	local t = PutPin(canvas)
	t:SetSize(8, 8)
	t:ClearAllPoints()
	t:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
	t:SetVertexColor(r, g, b, a or 1)
end

-- axis-free segment: center + rotation on a white texture
local function DrawLine(canvas, x1, y1, x2, y2, r, g, b, a, wd)
	local dx, dy = x2 - x1, y2 - y1
	local len = sqrt(dx * dx + dy * dy)
	if len < 2 then return end
	local t = PutLine(canvas)
	t:SetSize(len, wd or 2)
	t:ClearAllPoints()
	t:SetPoint("CENTER", canvas, "TOPLEFT",
		(x1 + x2) / 2, -(y1 + y2) / 2)
	if t.SetRotation then
		pcall(t.SetRotation, t, atan2(-dy, dx))
	end
	t:SetVertexColor(r, g, b, a or 0.9)
end

local function DrawZone(canvas, x, y, rPx, r, g, b, label)
	local c = PutZone(canvas)
	c.fill:SetSize(rPx * 2, rPx * 2)
	c.fill:ClearAllPoints()
	c.fill:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
	c.fill:SetVertexColor(r, g, b, 0.22)
	c.label:ClearAllPoints()
	c.label:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
	c.label:SetText(label or "")
	-- ring from segments — always available, masks or not
	local seg = 24
	for i = 1, seg do
		local a0 = (i - 1) / seg * 6.2831853
		local a1 = i / seg * 6.2831853
		DrawLine(canvas,
			x + cos(a0) * rPx, y + sin(a0) * rPx,
			x + cos(a1) * rPx, y + sin(a1) * rPx,
			r, g, b, 0.85, 3)
	end
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

local function DrawZoneFit(canvas, zn, RecXY, w, h, r, g, b, label)
	local pts = {}
	for _, pk in ipairs(zn.pockets or {}) do
		local px, py = RecXY(pk)
		if px and px >= -0.05 and px <= 1.05
			and py >= -0.05 and py <= 1.05 then
			pts[#pts + 1] = { x = px * w, y = py * h }
		end
	end
	-- pocket centroid anchors the fit (zn.x is the FIRST kill,
	-- not the middle); need a real cluster to fit around
	if #pts < 3 then return false end
	local cx, cy = 0, 0
	for _, p in ipairs(pts) do cx, cy = cx + p.x, cy + p.y end
	cx, cy = cx / #pts, cy / #pts
	local pad = YdToPx(canvas, POCKET_PAD_YD)
	local minR = YdToPx(canvas, ZONE_MIN_YD)
	local poly = {}
	for i = 0, OUTLINE_SEG - 1 do
		local a = i / OUTLINE_SEG * 6.2831853
		local dx, dy = cos(a), -sin(a)
		local d = minR
		for _, p in ipairs(pts) do
			local proj = (p.x - cx) * dx + (p.y - cy) * dy
			if proj > d then d = proj end
		end
		poly[#poly + 1] = { x = cx + dx * (d + pad),
			y = cy + dy * (d + pad) }
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
	-- fill: scanline bands across the smoothed polygon — each
	-- band's left/right edge crossings bound one rect, so the
	-- shaded area is the true blob shape (not a dot union, and
	-- no fan-convergence bright spot). The polygon is
	-- star-shaped around the centroid so a band crosses twice
	local ymin, ymax = 1e9, -1e9
	for _, p in ipairs(poly) do
		if p.y < ymin then ymin = p.y end
		if p.y > ymax then ymax = p.y end
	end
	local step = 7
	for y = ymin + step / 2, ymax, step do
		local xl, xr = 1e9, -1e9
		for i = 1, #poly do
			local a, b = poly[i], poly[i % #poly + 1]
			if (a.y <= y) ~= (b.y <= y) then
				local t = (y - a.y) / (b.y - a.y)
				local xi = a.x + t * (b.x - a.x)
				if xi < xl then xl = xi end
				if xi > xr then xr = xi end
			end
		end
		if xl < xr then
			local t = PutPin(canvas)
			t:SetSize(xr - xl, step + 0.5)
			t:ClearAllPoints()
			t:SetPoint("TOPLEFT", canvas, "TOPLEFT", xl,
				-(y - step / 2))
			t:SetVertexColor(r, g, b, 0.18)
		end
	end
	local c = PutZone(canvas)
	c.fill:Hide()
	c.label:ClearAllPoints()
	c.label:SetPoint("CENTER", canvas, "TOPLEFT", cx, -cy)
	c.label:SetText(label or "")
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		DrawLine(canvas, a.x, a.y, b.x, b.y, r, g, b, 0.85, 3)
	end
	return true
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
	Reclaim()
	local w, h = canvas:GetWidth() or 1, canvas:GetHeight() or 1
	-- record -> normalized map coords on the displayed frame;
	-- n,w-only records project, everything else fails nil
	local function RecXY(p)
		if p.x and p.y then return p.x, p.y end
		if p.n and p.w then
			local x, y = GM.MapPos(p.c or 0, p.n, p.w, map)
			if x and x >= 0 and x <= 1
				and y >= 0 and y <= 1 then
				return x, y
			end
		end
	end

	-- continent/world view: child-zone geometry projects at the
	-- wrong scale — a count disc per record-bearing zone, same
	-- summary model the window pane uses (no ring segments:
	-- 24/zone on a 1s ticker would paint thousands of lines)
	if M.IsWorldy(map) then
		local db = GoblinMindGather or {}
		local function mark(m, list, r, g, b, n)
			local rec = list[1]
			if not rec then return end
			local sn, sw, cnt, c = 0, 0, 0, nil
			for _, p in ipairs(list) do
				if p.n and p.w then
					sn, sw, cnt = sn + p.n, sw + p.w, cnt + 1
					c = c or (p.c ~= 0 and p.c or nil)
				end
			end
			local x, y
			if cnt > 0 then
				x, y = GM.MapPos(c or 0, sn / cnt, sw / cnt, map)
			elseif rec.x then
				-- x,y-only list (imports): hop through world yards —
				-- rec.x is normalized to m, not to the continent
				local n2, w2, c2 = GM.WorldPos(m, rec.x, rec.y)
				if n2 then
					x, y = GM.MapPos(c2 or rec.c or 0,
						n2, w2, map)
				end
			end
			if x and x >= 0 and x <= 1
				and y and y >= 0 and y <= 1 then
				local mk = PutZone(draw)
				mk.fill:SetSize(22, 22)
				mk.fill:ClearAllPoints()
				mk.fill:SetPoint("CENTER", draw, "TOPLEFT",
					x * w, -(y * h))
				mk.fill:SetVertexColor(r, g, b, 0.6)
				mk.label:ClearAllPoints()
				mk.label:SetPoint("CENTER", draw, "TOPLEFT",
					x * w, -(y * h))
				mk.label:SetText(tostring(n))
			end
		end
		for m, list in pairs(db.nodes or {}) do
			mark(m, list, 0.4, 0.85, 1.0, #list)
		end
		for m, list in pairs(db.zones or {}) do
			mark(m, list, 0.95, 0.8, 0.3, #list)
		end
		return
	end

	-- hunt zones first (under the pins): fitted blob + stats.
	-- Label = dominant landmark (ZonePlace) + display category —
	-- the raw record kind is always "hunt"/"skin", never the
	-- cloth/meat/mine family the camp actually farms. A landmark
	-- equal to the map's own name adds nothing — drop it
	local mapName = G.ZoneName and G.ZoneName(map)
	for _, zn in ipairs(G.ZoneList(map) or {}) do
		-- a bad record can't kill the overlay pass — one zone's
		-- draw failing must not take every later zone/pin with it
		pcall(function()
			local x, y = RecXY(zn)
			if not x then return end
			local zc = G.ZoneCat and G.ZoneCat(zn) or zn.kind
			local col = G.KIND_COLOR[zc] or { 1, 1, 1 }
			local place = G.ZonePlace and G.ZonePlace(zn)
			if place == mapName then place = nil end
			local gpm = G.ZoneEV(zn) * G.ZoneRate(zn)
			local label = format("%s · %s kills · %s/min",
				place and (place .. " · " .. zc) or zc,
				zn.kills or 0,
				GM.MoneyShort
					and GM.MoneyShort(floor(gpm))
					or tostring(floor(gpm)))
			if not DrawZoneFit(draw, zn, RecXY, w, h,
				col[1], col[2], col[3], label) then
				DrawZone(draw, x * w, y * h,
					YdToPx(draw, DispR(zn)),
					col[1], col[2], col[3], label)
			end
		end)
	end

	-- node pins; dim inside the learned respawn window
	for _, nd in ipairs(G.NodeList(map) or {}) do
		local x, y = RecXY(nd)
		if x then
			local col = G.KIND_COLOR[nd.kind] or { 1, 1, 1 }
			local resp = G.RespawnSec(map, nd.kind)
			local dim = nd.last
				and (time() - nd.last) < resp * 0.8
			DrawPin(draw, x * w, y * h,
				col[1], col[2], col[3], dim and 0.35 or 0.95)
		end
	end

	-- route polyline: the active run if one's going, else the last
	-- solved route for this map
	local run = G.Route and G.Route()
	local r = run and run.route or M.RouteFor(map)
	local stops = run and run.stops or (r and r.stops)
	if stops and #stops > 1 then
		for i = 1, #stops do
			local a, b = stops[i], stops[i % #stops + 1]
			local ax, ay = RecXY(a)
			local bx, by = RecXY(b)
			if ax and bx then
				DrawLine(draw, ax * w, ay * h,
					bx * w, by * h,
					0.4, 0.85, 1.0, 0.8)
			end
		end
		local s = run and run.stops[run.idx]
		local sx, sy = s and RecXY(s)
		if sx then
			DrawPin(draw, sx * w, sy * h,
				0.4, 0.85, 1.0, 1)
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

local function MapXY(p, mapID)
	-- cached x,y is only valid in the map frame it was projected
	-- for — a record merged from a different mapID must reproject
	-- its world coords instead (cross-map zone merging)
	if p.x and p.y and (not p.map or p.map == mapID) then
		return p.x, p.y
	end
	if p.n and p.w then
		local mx, my = GM.MapPos(p.c or 0, p.n, p.w, mapID)
		if mx and mx >= 0 and mx <= 1 then
			if not p.map or p.map == mapID then
				p.x, p.y = mx, my
			end
			return mx, my
		end
	end
	-- fall back to the raw stored coords only when the frame can't
	-- be proven foreign
	if p.x and p.y then return p.x, p.y end
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
local function Cluster(nodes, mapID, thresh)
	local out = {}
	for _, nd in ipairs(nodes) do
		local x, y = MapXY(nd, mapID)
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
	pane.live = {}
	pane.pool = { tile = {}, exptile = {}, disc = {}, line = {},
		icon = {}, lbl = {}, medal = {} }

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

	local function put(kind)
		local t = tremove(pane.pool[kind])
		if not t then
			if kind == "lbl" then
				t = inner:CreateFontString(nil, "OVERLAY",
					"GameFontHighlightSmall")
			elseif kind == "tile" then
				t = inner:CreateTexture(nil, "BACKGROUND")
			elseif kind == "exptile" then
				-- explored terrain sits over the parchment base,
				-- under every overlay
				t = inner:CreateTexture(nil, "ARTWORK", nil, -1)
			elseif kind == "disc" then
				t = inner:CreateTexture(nil, "OVERLAY")
				-- vendored soft circle — SetMaskTexture either
				-- doesn't exist here or silently fails, leaving a
				-- square halo; the TGA carries its own alpha edge
				t:SetTexture(
					"Interface\\AddOns\\GoblinMind\\Media\\disc.tga")
			elseif kind == "line" then
				t = inner:CreateTexture(nil, "OVERLAY", nil, 1)
				t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
			elseif kind == "medal" then
				t = inner:CreateTexture(nil, "OVERLAY", nil, 3)
				t:SetTexture(
					"Interface\\AddOns\\GoblinMind\\Media\\ring.tga")
			else -- icon
				t = inner:CreateTexture(nil, "OVERLAY", nil, 2)
			end
		end
		t:ClearAllPoints()
		t:Show()
		pane.live[#pane.live + 1] = { kind, t }
		return t
	end

	local function line(x1, y1, x2, y2, r, g, b, a, wd)
		local dx, dy = x2 - x1, y2 - y1
		local len = sqrt(dx * dx + dy * dy)
		if len < 2 then return end
		local t = put("line")
		t:SetSize(len, wd or 2)
		t:SetPoint("CENTER", inner, "TOPLEFT",
			(x1 + x2) / 2, -(y1 + y2) / 2)
		if t.SetRotation then
			pcall(t.SetRotation, t, atan2(-dy, dx))
		end
		t:SetVertexColor(r, g, b, a or 0.9)
	end

	local function clear()
		for _, e in ipairs(pane.live) do
			e[2]:Hide()
			pane.pool[e[1]][#pane.pool[e[1]] + 1] = e[2]
		end
		wipe(pane.live)
	end
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

		local zones = G.ZoneList(mapID) or {}
		local nodes = G.NodeList(mapID) or {}
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
				-- plus an outer accent outline
				local isSel = sel and sel.zone == zn
				local col = G.KIND_COLOR[zc] or { 1, 1, 1 }
				local rPx = max(10, DispR(zn) * upy * w)
				local px, py = x * w, y * h
				local d = put("disc")
				d:SetSize(rPx * 2, rPx * 2)
				d:SetPoint("CENTER", inner, "TOPLEFT", px, -py)
				d:SetVertexColor(col[1], col[2], col[3],
					isSel and 0.3 or (match and 0.16 or 0.05))
				local seg = 24
				for i = 1, seg do
					local a0 = (i - 1) / seg * 6.2831853
					local a1 = i / seg * 6.2831853
					line(px + cos(a0) * rPx, py + sin(a0) * rPx,
						px + cos(a1) * rPx, py + sin(a1) * rPx,
						col[1], col[2], col[3],
						isSel and 0.95 or (match and 0.5 or 0.15))
					if isSel then
						line(px + cos(a0) * (rPx + 4),
							py + sin(a0) * (rPx + 4),
							px + cos(a1) * (rPx + 4),
							py + sin(a1) * (rPx + 4),
							1, 0.82, 0.1, 0.85)
					end
				end
				local ic = put("icon")
				local fid = ItemIcon(G.ZoneIconID(zn))
				if fid then
					ic:SetTexture(fid)
					ic:SetVertexColor(1, 1, 1,
						(match or isSel) and 1 or 0.3)
				else
					ic:SetTexture("Interface\\BUTTONS\\WHITE8X8")
					ic:SetVertexColor(col[1], col[2], col[3],
						(match or isSel) and 0.9 or 0.3)
				end
				ic:SetSize(isSel and 24 or 18, isSel and 24 or 18)
				ic:SetPoint("CENTER", inner, "TOPLEFT", px, -py)
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
		local clusters = Cluster(drawable, mapID, 70 * upy)
		for _, c in ipairs(clusters) do
			local rep = c.nodes[1]
			local col = G.KIND_COLOR[rep.kind] or { 1, 1, 1 }
			local best, tHit
			for _, nd in ipairs(c.nodes) do
				if tid and G.NodeTargets(nd, tid) then tHit = true end
				best = best or G.NodeIconID(nd)
			end
			local match = not tid or tHit
			if tHit then best = tid end
			local sz = math.min(30, 12 + 5 * sqrt(c.n))
			if not match then sz = math.min(sz, 10) end
			local ic = put("icon")
			local fid = ItemIcon(best)
			if fid then
				ic:SetTexture(fid)
				ic:SetVertexColor(1, 1, 1, match and 1 or 0.25)
			else
				ic:SetTexture("Interface\\BUTTONS\\WHITE8X8")
				ic:SetVertexColor(col[1], col[2], col[3],
					match and 0.95 or 0.3)
			end
			ic:SetSize(sz, sz)
			ic:SetPoint("CENTER", inner, "TOPLEFT",
				c.x * w, -c.y * h)
			if c.n > 1 then
				local l = put("lbl")
				l:SetPoint("TOP", ic, "BOTTOM", 0, -1)
				l:SetText(tostring(c.n))
				l:SetTextColor(col[1], col[2], col[3])
			end
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
			for i = 1, #stops do
				local a, b = stops[i], stops[i % #stops + 1]
				local ax, ay = MapXY(a, mapID)
				local bx, by = MapXY(b, mapID)
				if ax and bx
					and ax > -0.02 and ax < 1.02
					and bx > -0.02 and bx < 1.02 then
					line(ax * w, ay * h, bx * w, by * h,
						0.4, 0.85, 1.0, selLoop and 1 or 0.85,
						selLoop and 4 or 2)
				end
			end
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
					local px, py = m.x * w, m.y * h
					local mc = m.medal and MEDAL[m.medal]
						or { 0.55, 0.6, 0.55 }
					local d = put("disc")
					d:SetSize(22, 22)
					d:SetPoint("CENTER", inner, "TOPLEFT",
						px, -py)
					d:SetVertexColor(0.02, 0.03, 0.02, 0.85)
					local rg = put("medal")
					rg:SetSize(25, 25)
					rg:SetPoint("CENTER", inner, "TOPLEFT",
						px, -py)
					rg:SetVertexColor(mc[1], mc[2], mc[3],
						m.medal and 0.95 or 0.4)
					local l = put("lbl")
					l:SetPoint("CENTER", inner, "TOPLEFT",
						px, -py)
					l:SetText(tostring(m.count))
					l:SetTextColor(mc[1], mc[2], mc[3], 1)
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
