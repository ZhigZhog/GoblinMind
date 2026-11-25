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

-- a stop's n/w may be absent (saved routes serialize x,y) —
-- project the map fraction back to world yards
local function PosNW(st, mapID)
	if st.n and st.w then return st.n, st.w end
	if st.x and st.y then
		return GM.WorldPos(mapID, st.x, st.y)
	end
end

local function Update()
	if not ensureHost() then return end
	local G = GM.Gather
	if not G or not Minimap:IsVisible() then clear() return end
	local n, w, c, mapID = Player()
	if not n then clear() return end

	-- view radius in yards: the zoom-level table is authoritative —
	-- GetViewRadius misreports on Forever (returns 150 where the
	-- outdoor zoom-0 scale is 233.33, shrinking our yard span ~36%
	-- so every overlay element slides ~1.55x against the terrain =
	-- the zone "parallax"). API is only the fallback for a zoom
	-- the table doesn't know. The minimapZoom cvar pins the
	-- outdoor zoom — matching it means we're outdoors
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
	local cs, sn = cos(facing), sin(facing)
	local hw, hh = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
	if hw <= 0 or hh <= 0 then clear() return end

	clear()

	-- world-yard offset -> normalized circle coords + pixels
	local function uv(nw, nn)
		local dx, dy = w - nw, n - nn
		if rotate then
			dx, dy = dx * cs - dy * sn, dx * sn + dy * cs
		end
		local u, v = dx / radius, dy / radius
		return u, v, u * hw, -v * hh
	end

	-- segment–disc intersection: return the chord inside the clip
	-- circle, nil when the segment misses it entirely. The old
	-- both-outside early-out culled chords that cross the radar
	-- edge-to-edge — that's what chopped visible gaps into routes
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

	-- opacity channels hoist above the closures: the route is node
	-- geometry, so it rides oaN (muting nodes must mute its loop)
	local oaZ = M.AlphaZone()
	local oaN = M.AlphaNode()
	local oaI = M.AlphaIcon()
	local SA = GM.Widgets.MapStyle.A

	local function seg(u1, v1, u2, v2)
		local a, b, c2, d = clip(u1, v1, u2, v2)
		if not a then return end
		local x1, y1 = a * hw, -b * hh
		local x2, y2 = c2 * hw, -d * hh
		local dx, dy = x2 - x1, y2 - y1
		local len = sqrt(dx * dx + dy * dy)
		if len < 2 then return end
		local t = put("seg")
		t:SetSize(len, 2)
		t:SetPoint("CENTER", host, "CENTER",
			(x1 + x2) / 2, (y1 + y2) / 2)
		if t.SetRotation then
			-- y is up-positive here (CENTER offsets), so no
			-- sign flip like the TOPLEFT-space map pane uses
			pcall(t.SetRotation, t, atan2(dy, dx))
		end
		t:SetVertexColor(0.4, 0.85, 1.0, SA.route * oaN)
	end

	-- hunt-zone territory under everything: the same fitted
	-- support-function blob the map surfaces draw — pockets in
	-- world yards -> minimap px, scanline fill clipped to the
	-- radar circle band-by-band. Iterating every record list is
	-- free here: world-yard space has no map frames, the distance
	-- cull does the filtering
	local mmSet = mm()
	local ZP = GM.GatherMap
	local clipC = { x = hw, y = hh, r = hw * 0.9 }
	for _, zl in pairs(GoblinMindGather.zones or {}) do
	for _, zn in ipairs(zl) do
		local zc = G.ZoneCat(zn)
		local znN, znW = zn.n, zn.w
		if not (znN and znW) and zn.x and zn.y and zn.map then
			-- memoize the projection onto the record — an
			-- intermittent WorldPos failure must not flap the
			-- fit's inputs between frames (the blob visibly
			-- jumps when a pocket drops out for one repaint)
			znN, znW = GM.WorldPos(zn.map, zn.x, zn.y)
			if znN and znW then zn.n, zn.w = znN, znW end
		end
		-- continent guard: foreign-continent records carry that
		-- continent's yard space — without this a Kalimdor camp
		-- ghost-renders on the EK radar at whatever position the
		-- overlapping ranges land, sliding with the player
		if znN and znW and (zn.c or c) == c
			and mmSet[zc] ~= false
			and ZP and ZP.ZonePoly and GM.Widgets then
			local u0, v0 = uv(znW, znN)
			if sqrt(u0 * u0 + v0 * v0)
				- ZP.DispR(zn) / radius <= 0.9 then
				local col = G.KindCol(zc)
				-- fit in ANCHOR-RELATIVE WORLD YARDS, not screen
				-- px — the support-function fit re-derived in
				-- player-relative screen space every repaint is
				-- what let the blob drift: any per-frame input
				-- wobble (pocket projections flapping, zoom
				-- radius noise) reshaped it. Yard space is
				-- world-fixed; only the render transform moves it
				local sig = (zn.kills or 0) .. ":"
					.. (zn.r or 0) .. ":"
					.. #(zn.pockets or {})
				local fit = zoneFit[zn]
				if not (fit and fit.sig == sig) then
					local pts = {}
					for _, pk in ipairs(zn.pockets or {}) do
						local pn, pw = pk.n, pk.w
						if not (pn and pw) and pk.x and pk.y
							and pk.map then
							pn, pw = GM.WorldPos(pk.map,
								pk.x, pk.y)
							if pn and pw then
								pk.n, pk.w = pn, pw
							end
						end
						if pn and pw and (pk.c or c) == c then
							pts[#pts + 1] = { x = pw - znW,
								y = pn - znN }
						end
					end
					if #pts < 3 then
						local r0 = max(20 * radius / hw,
							ZP.DispR(zn)
							- ZP.POCKET_PAD_YD)
						local skew = (zn.kills or 1) * 0.7
						for i = 0, 5 do
							local a = skew + i / 6
								* 6.2831853
							pts[#pts + 1] = {
								x = cos(a) * r0,
								y = sin(a) * r0 }
						end
					end
					local poly, cx, cy = ZP.ZonePoly(pts,
						ZP.POCKET_PAD_YD, ZP.ZONE_MIN_YD,
						ZP.ZONE_DRAW_MAX_YD)
					fit = { sig = sig, poly = poly,
						cx = cx, cy = cy }
					zoneFit[zn] = fit
				end
				if fit.poly then
					-- yard-space verts -> TOPLEFT px through
					-- the same uv transform every other
					-- layer takes
					local spoly = {}
					for i, p in ipairs(fit.poly) do
						local _, _, px, py = uv(znW + p.x,
							znN + p.y)
						spoly[i] = { x = hw + px,
							y = hh + py }
					end
					local _, _, pcx, pcy = uv(znW + fit.cx,
						znN + fit.cy)
					local scx, scy = hw + pcx, hh + pcy
					GM.Widgets.PolyFill(host, spoly, 6,
						col[1], col[2], col[3],
						SA.zoneRing * oaZ,
						function()
							return put("zring")
						end, clipC)
					-- interior copy shrunk toward the centroid —
					-- the same border-band trick L:blob runs
					GM.Widgets.PolyFill(host,
						GM.Widgets.PolyShrink(spoly,
							scx, scy, -2), 6,
						col[1], col[2], col[3],
						SA.zoneFill * oaZ,
						function()
							return put("zfill")
						end, clipC)
					-- farm icon at the centroid, like the
					-- world map's camp widget
					local it = GM.ItemIcon(G.ZoneIconID
						and G.ZoneIconID(zn))
					if it then
						local ic = put("icon")
						local zsz = GM.Widgets.MapStyle
							.ZONE_ICON_MM
						ic:SetSize(zsz, zsz)
						ic:SetPoint("CENTER", host,
							"CENTER", pcx, pcy)
						ic:SetTexture(it)
						ic:SetVertexColor(1, 1, 1,
							SA.full * oaI)
					end
				end
			end
		end
	end
	end

	-- route loop (running route wins over the noted one)
	local run = G.Route()
	local rt = (run and run.route and run.route.map == mapID
			and run.route)
		or (GM.GatherMap and GM.GatherMap.RouteFor(mapID))
	if rt and rt.stops and #rt.stops > 1 and mmSet.route ~= false then
		local pts = {}
		for i, st in ipairs(rt.stops) do
			local nn, ww = PosNW(st, rt.map or mapID)
			if nn and ww then
				local u, v, px, py = uv(ww, nn)
				pts[i] = { u = u, v = v, px = px, py = py }
			end
		end
		for i = 1, #pts do
			local a, b = pts[i], pts[i % #pts + 1]
			if a and b then seg(a.u, a.v, b.u, b.v) end
			if a and a.u * a.u + a.v * a.v <= CLIP2 then
				local s = put("stop")
				s:SetSize(7, 7)
				s:SetPoint("CENTER", host, "CENTER", a.px, a.py)
				s:SetVertexColor(0.4, 0.85, 1.0, SA.full * oaN)
			end
		end
	end

	-- node clusters on top: same Gatherer-style merge the world
	-- map runs, in world-yard space. Off-view clusters pin to the
	-- rim (the radar edge) so recorded spawns keep pointing at
	-- themselves; empty = plain kind dot when no icon resolves
	if oaN > 0 and GM.GatherMap and GM.GatherMap.Cluster then
		local recs = WrapNodes(mapID, G.NodeList(mapID) or {}, mmSet)
		for _, c in ipairs(GM.GatherMap.Cluster(recs,
				function(r) return r.w, r.n end, 70)) do
			local u, v, px, py = uv(c.x, c.y)
			local rr = u * u + v * v
			local dist = sqrt(rr)
			-- past ~2.5 view radii a rim pin stops being radar
			-- and becomes border noise — cull it outright
			if dist <= 2.5 then
			-- steep distance fade on the TRUE range: full at the
			-- center, ~24% at the rim, floor ~12% for far pins —
			-- near spawns pop, distant ones are whispers.
			-- States only lower it — min() stacking (S3)
			local fade = math.max(0.12, 1 - 0.85 * dist)
			local pinned = rr > CLIP2
			if pinned then
				local s = sqrt(CLIP2 / rr) * 0.96
				u, v = u * s, v * s
				px, py = u * hw, -v * hh
			end
			local rep = c.nodes[1].nd
			local col = G.KindCol(rep.kind)
			-- same dim rule as the world map: every member inside
			-- the learned respawn window → faded
			local dimAll = true
			for _, r in ipairs(c.nodes) do
				if not G.NodeDepleted(r.nd, mapID) then
					dimAll = false break
				end
			end
			local a = oaN * min(
				dimAll and SA.depleted or SA.full, fade)
			-- Questie-icon scale, same as the world map — pinned
			-- icons shrink another notch so the rim stays quiet
			local sz = GM.Widgets.MapStyle.ClusterSize(c.n, true)
				* (pinned and 0.7 or 1)
			local ic = put("icon")
			ic:SetSize(sz, sz)
			ic:SetPoint("CENTER", host, "CENTER", px, py)
			local tex = GM.ItemIcon(G.NodeIconID
				and G.NodeIconID(rep))
			-- same rule as MapLayer's icon: real item art stays
			-- natural, the kind tint is only for the fallback disc
			if tex then
				ic:SetTexture(tex)
				ic:SetVertexColor(1, 1, 1, a)
			else
				ic:SetTexture(DISC)
				ic:SetVertexColor(col[1], col[2], col[3], a)
			end
			if c.n > 1 and not pinned then
				local b = putStr("badge")
				b:SetPoint("CENTER", host, "CENTER",
					px, py - sz / 2 - 4)
				b:SetText(tostring(c.n))
				b:SetTextColor(col[1], col[2], col[3], a)
			end
			end
		end
	end
end

M.Update = Update

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
end, { prefix = true })

local acc = 0
local tick = CreateFrame("Frame")
tick:SetScript("OnUpdate", function(_, dt)
	acc = acc + dt
	if acc < 0.12 then return end
	acc = 0
	Update()
end)
