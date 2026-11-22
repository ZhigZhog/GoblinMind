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

-- canvas lookup: retail keeps a ScrollContainer.Child; older/odd
-- map frames get probed for a canvas-ish child, else the frame
-- itself. Pins anchor CENTER in normalized*pixel coords either way.
local function Canvas()
	local f = WorldMapFrame
	if not f then return nil end
	if f.ScrollContainer and f.ScrollContainer.Child then
		return f.ScrollContainer.Child
	end
	return f
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
		c.fill:SetTexture("Interface\\BUTTONS\\WHITE8X8")
		-- circular mask -> translucent disc; if masks don't exist on
		-- this client the fill just stays square and the segment
		-- ring still reads as the zone outline
		pcall(function()
			c.fill:SetMaskTexture(
				"Interface\\CharacterFrame\\TempPortraitAlphaMask")
		end)
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
local function DrawLine(canvas, x1, y1, x2, y2, r, g, b, a)
	local dx, dy = x2 - x1, y2 - y1
	local len = sqrt(dx * dx + dy * dy)
	if len < 2 then return end
	local t = PutLine(canvas)
	t:SetSize(len, 2)
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
	c.fill:SetVertexColor(r, g, b, 0.15)
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
			r, g, b, 0.7)
	end
end

-- zone radii are yards — convert through the same normalized-unit
-- scale DistYd's fallback uses so the disc covers the modeled area
local function YdToPx(canvas, yd)
	local w = canvas:GetWidth() or 1000
	return yd / 1500 * w
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

function M.Refresh()
	G = G or GM.Gather
	if not MapShown() or not G then
		Reclaim()
		return
	end
	local canvas = Canvas()
	if not canvas then return end
	Reclaim()
	local map = CurrentMap()
	if not map then return end
	local w, h = canvas:GetWidth() or 1, canvas:GetHeight() or 1

	-- hunt zones first (under the pins): translucent disc + stats
	for _, zn in ipairs(G.ZoneList(map) or {}) do
		if zn.x and zn.y then
			local col = G.KIND_COLOR[zn.kind] or { 1, 1, 1 }
			local gpm = G.ZoneEV(zn) * G.ZoneRate(zn)
			DrawZone(canvas, zn.x * w, zn.y * h,
				YdToPx(canvas, zn.r or 60),
				col[1], col[2], col[3],
				format("%s · %s kills · %s/min",
					zn.kind, zn.kills or 0,
					GM.MoneyShort
						and GM.MoneyShort(floor(gpm * 10000))
						or tostring(floor(gpm))))
		end
	end

	-- node pins; dim inside the learned respawn window
	for _, nd in ipairs(G.NodeList(map) or {}) do
		if nd.x and nd.y then
			local col = G.KIND_COLOR[nd.kind] or { 1, 1, 1 }
			local resp = G.RespawnSec(map, nd.kind)
			local dim = nd.last
				and (time() - nd.last) < resp * 0.8
			DrawPin(canvas, nd.x * w, nd.y * h,
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
			if a.x and b.x then
				DrawLine(canvas, a.x * w, a.y * h,
					b.x * w, b.y * h,
					0.4, 0.85, 1.0, 0.8)
			end
		end
		local s = run and run.stops[run.idx]
		if s and s.x then
			DrawPin(canvas, s.x * w, s.y * h,
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
local function MapXY(p, mapID)
	if p.x and p.y then return p.x, p.y end
	if p.n and p.w and C_Map and C_Map.GetMapPosFromWorldPos
		and CreateVector2D then
		local ok, _, mp = pcall(C_Map.GetMapPosFromWorldPos,
			p.c or 0, CreateVector2D(p.n, p.w), mapID)
		if ok and mp and mp.x and mp.x >= 0 and mp.x <= 1 then
			p.x, p.y = mp.x, mp.y
			return mp.x, mp.y
		end
	end
end

-- map-units per yard near (n,w): project two points a known world
-- distance apart and measure. Fallback matches the world map's
-- 1500yd-per-map-width assumption
local function UnitsPerYard(mapID, p)
	if p and p.n and p.w and C_Map
		and C_Map.GetMapPosFromWorldPos and CreateVector2D then
		local okA, _, a = pcall(C_Map.GetMapPosFromWorldPos,
			p.c or 0, CreateVector2D(p.n, p.w), mapID)
		local okB, _, b = pcall(C_Map.GetMapPosFromWorldPos,
			p.c or 0, CreateVector2D(p.n + 100, p.w), mapID)
		if okA and okB and a and b then
			local d = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
			if d and d > 1e-6 then return d / 100 end
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

function M.CreatePane(parent, w)
	local pane = CreateFrame("Frame", nil, parent)
	pane:SetWidth(w)
	pane.live = {}
	pane.pool = { tile = {}, disc = {}, line = {}, icon = {}, lbl = {} }

	local function put(kind)
		local t = tremove(pane.pool[kind])
		if not t then
			if kind == "lbl" then
				t = pane:CreateFontString(nil, "OVERLAY",
					"GameFontHighlightSmall")
			elseif kind == "tile" then
				t = pane:CreateTexture(nil, "BACKGROUND")
			elseif kind == "disc" then
				t = pane:CreateTexture(nil, "OVERLAY")
				t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
				pcall(function()
					t:SetMaskTexture(
						"Interface\\CharacterFrame\\TempPortraitAlphaMask")
				end)
			elseif kind == "line" then
				t = pane:CreateTexture(nil, "OVERLAY", nil, 1)
				t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
			else -- icon
				t = pane:CreateTexture(nil, "OVERLAY", nil, 2)
			end
		end
		t:ClearAllPoints()
		t:Show()
		pane.live[#pane.live + 1] = { kind, t }
		return t
	end

	local function line(x1, y1, x2, y2, r, g, b, a)
		local dx, dy = x2 - x1, y2 - y1
		local len = sqrt(dx * dx + dy * dy)
		if len < 2 then return end
		local t = put("line")
		t:SetSize(len, 2)
		t:SetPoint("CENTER", pane, "TOPLEFT",
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
	function pane:SetData(mapID, route)
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
		local h = floor(w / aspect + 0.5)
		self:SetHeight(h)

		local haveArt = false
		if C_Map and C_Map.GetMapArtLayers
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
							t:SetTexture(fileID)
							t:SetSize(tw, th)
							t:SetPoint("TOPLEFT", self, "TOPLEFT",
								((i - 1) % cols) * tw,
								-floor((i - 1) / cols) * th)
							haveArt = true
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

		-- hunt zones under everything: disc + drop icon at center.
		-- With a target set, non-producers recede to a faint trace
		for _, zn in ipairs(zones) do
			local x, y = MapXY(zn, mapID)
			if x then
				local match = not tid or G.ZoneTargets(zn, tid)
				local col = G.KIND_COLOR[zn.kind] or { 1, 1, 1 }
				local rPx = max(10, (zn.r or 60) * upy * w)
				local px, py = x * w, y * h
				local d = put("disc")
				d:SetSize(rPx * 2, rPx * 2)
				d:SetPoint("CENTER", self, "TOPLEFT", px, -py)
				d:SetVertexColor(col[1], col[2], col[3],
					match and 0.16 or 0.05)
				local seg = 24
				for i = 1, seg do
					local a0 = (i - 1) / seg * 6.2831853
					local a1 = i / seg * 6.2831853
					line(px + cos(a0) * rPx, py + sin(a0) * rPx,
						px + cos(a1) * rPx, py + sin(a1) * rPx,
						col[1], col[2], col[3], match and 0.5 or 0.15)
				end
				local ic = put("icon")
				local fid = ItemIcon(G.ZoneIconID(zn))
				if fid then
					ic:SetTexture(fid)
					ic:SetVertexColor(1, 1, 1, match and 1 or 0.3)
				else
					ic:SetTexture("Interface\\BUTTONS\\WHITE8X8")
					ic:SetVertexColor(col[1], col[2], col[3],
						match and 0.9 or 0.3)
				end
				ic:SetSize(18, 18)
				ic:SetPoint("CENTER", self, "TOPLEFT", px, -py)
			end
		end

		-- node clusters; icon = best drop (target's own icon when
		-- it's among them), size ∝ group size, non-producers dim
		local clusters = Cluster(nodes, mapID, 70 * upy)
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
			ic:SetPoint("CENTER", self, "TOPLEFT",
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
		if stops and #stops > 1 then
			for i = 1, #stops do
				local a, b = stops[i], stops[i % #stops + 1]
				local ax, ay = MapXY(a, mapID)
				local bx, by = MapXY(b, mapID)
				if ax and bx then
					line(ax * w, ay * h, bx * w, by * h,
						0.4, 0.85, 1.0, 0.85)
				end
			end
		end
	end

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
