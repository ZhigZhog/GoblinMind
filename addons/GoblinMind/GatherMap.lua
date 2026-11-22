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

local floor, sqrt, atan2, cos, sin = math.floor, math.sqrt,
	math.atan2, math.cos, math.sin

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
