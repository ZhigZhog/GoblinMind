local _, GM = ...

-- ========================= map manager =========================
-- Singleton registry for the three map surfaces — world-map
-- overlay, Gather-window pane, minimap radar — so every map
-- OBJECT (hunt zone, node cluster, route loop, continent mark)
-- renders through one draw implementation per kind on all three.
-- Consistency lives in two places: the shared W.MapStyle contract
-- (colors/alphas/sizes) and the shared draw logic here.
--
-- A VIEW is an adapter: it owns its surface's host, texture pool,
-- and projection, and answers the contract below in TOPLEFT px —
-- the same space W.MapLayer primitives consume:
--
--   view.L                  MapLayer-compatible primitive set
--   view:proj(rec)          record -> x, y (px) | nil if unprojectable
--   view:ptsRel(zn)         pocket pts, ANCHOR-RELATIVE px, for the fit
--   view:rPx(yd)            yards -> px at this view's scale
--   view:cull(x, y, slack)  true when the point is beyond drawable+slack
--   view:rim(x, y)          -> x, y, pinned (flat views pass through)
--   view:fade(x, y)         distance alpha factor (flat views return 1)
--   view:iconSz(n)          cluster icon px for this surface (S1 scale)
--   view:routeSeg(...)      one route chord (dots on flat views, a
--                           clipped rotated seg on the radar)
--   view:routeStop(x, y, a) one route stop dot
--   view:clusters(nodes)    -> { {nodes, n, x, y}, ... } in view px
--   view.feats              { tag=bool, hot=bool } capability flags
--   view.fit                weak-keyed per-record fit cache table
--   view.fitScale           number folded into the fit signature
--
-- The ZONE outline (ring band + dim interior) is the canonical
-- camp treatment on every surface — it is the readable version.

local MM = {}
GM.MapMgr = MM
MM.Views = {}

function MM.RegisterView(id, view)
	MM.Views[id] = view
end
function MM.View(id) return MM.Views[id] end

local min, max, sqrt, floor = math.min, math.max,
	math.sqrt, math.floor
local cos = math.cos

local G -- GM.Gather, resolved lazily (file order)

-- ======================= shared zone fit =======================
-- One fit path for every view: anchor-relative points in view px
-- through the support-function fit, cached per record keyed by a
-- content+scale signature. Anchor-relative means the cached poly
-- survives player movement — only new pockets/kills/radius or a
-- view-scale change (zoom, canvas resize) rebuilds it.
function MM.ZoneFit(view, zn)
	local Z = GM.GatherMap
	local sig = (zn.kills or 0) .. ":" .. (zn.r or 0) .. ":"
		.. #(zn.pockets or {}) .. ":" .. (view.fitScale or 0)
	local fit = view.fit[zn]
	if fit and fit.sig == sig then
		return fit.poly, fit.cx, fit.cy
	end
	local pts = view:ptsRel(zn)
	if #pts < 3 then
		-- records that predate pockets: fabricate a span-sized
		-- scatter so they blob instead of falling back to a disc
		local r0 = max(20,
			view:rPx(Z.DispR(zn) - Z.POCKET_PAD_YD))
		local skew = (zn.kills or 1) * 0.7
		pts = {}
		for i = 0, 5 do
			local a = skew + i / 6 * 6.2831853
			pts[#pts + 1] = { x = cos(a) * r0,
				y = sin(a) * r0 }
		end
	end
	local poly, cx, cy = Z.ZonePoly(pts,
		view:rPx(Z.POCKET_PAD_YD), view:rPx(Z.ZONE_MIN_YD),
		view:rPx(Z.ZONE_DRAW_MAX_YD))
	fit = { sig = sig, poly = poly, cx = cx, cy = cy }
	view.fit[zn] = fit
	return poly, cx, cy
end

-- ======================= object draws ========================
-- Each object kind holds its views here: one implementation
-- dispatched with whichever registered view it's handed.

MM.Draw = {}

-- hunt zone: fitted outline blob + centered farm icon, tag and
-- hover tip where the surface supports them. st = { col, fillA,
-- ringA, ringPx, sel, iconID, iconA, iconSz, tag, tagDY, tip,
-- mapID }
function MM.Draw.zone(view, zn, st)
	local ax, ay = view:proj(zn)
	if not ax then return end
	local Z = GM.GatherMap
	-- extent-aware cull: a blob still touches the radar when its
	-- anchor sits a DispR past the edge (flat views ignore slack)
	if view:cull(ax, ay, view:rPx(Z.DispR(zn))) then return end
	local col = st.col
	local cx, cy = ax, ay
	local poly, pcx, pcy = MM.ZoneFit(view, zn)
	if poly then
		local spoly = {}
		for i, p in ipairs(poly) do
			spoly[i] = { x = ax + p.x, y = ay + p.y }
		end
		cx, cy = ax + pcx, ay + pcy
		view.L:blob(spoly, cx, cy, col[1], col[2], col[3],
			st.fillA, st.ringA, st.ringPx, st.sel)
	else
		-- disc pair reads as the same rim+interior treatment
		local rPx = max(10, view:rPx(Z.DispR(zn)))
		view.L:disc(ax, ay, rPx, col[1], col[2], col[3], st.ringA)
		view.L:disc(ax, ay, max(4, rPx - (st.ringPx or 3)),
			col[1], col[2], col[3], st.fillA)
	end
	if st.iconID then
		local sz = st.iconSz or GM.Widgets.MapStyle.ZONE_ICON
		view.L:icon(cx, cy, sz, GM.ItemIcon(st.iconID),
			col[1], col[2], col[3], st.iconA or 1)
		if view.feats.hot and st.tip ~= false then
			view.L:hot(cx, cy, sz + 6, sz + 6,
				GM.GatherMap.ZoneTip(zn, st.mapID))
		end
		if view.feats.tag and st.tag then
			view.L:tag(cx, cy + (st.tagDY or sz / 2 + 8),
				st.tag, st.iconA)
		end
	elseif view.feats.tag and st.tag then
		view.L:tag(cx, cy + (st.tagDY or 14), st.tag, st.iconA)
	end
	return cx, cy
end

-- node cluster: best-drop item art sized by group with a count
-- badge. The alpha contract is shared (S3): states only lower
-- alpha — min() of depleted/nonMatch, times the node channel and
-- the view's distance fade. st = { tid, mapID, oa, tip }
function MM.Draw.cluster(view, c, st)
	G = G or GM.Gather
	local S = GM.Widgets.MapStyle.A
	local dimAll, tHit = true, nil
	for _, nd in ipairs(c.nodes) do
		if not G.NodeDepleted(nd, st.mapID) then dimAll = false end
		if st.tid and G.NodeTargets
			and G.NodeTargets(nd, st.tid) then
			tHit = true
		end
	end
	local match = not st.tid or tHit
	local x, y, pinned = view:rim(c.x, c.y)
	local a = min(dimAll and S.depleted or S.full,
		match and S.full or S.nonMatch) * (st.oa or 1)
		* view:fade(x, y)
	local rep = c.nodes[1]
	local col = G.KindCol(rep.kind)
	local best
	for _, nd in ipairs(c.nodes) do
		best = best or (G.NodeIconID and G.NodeIconID(nd))
		if st.tid and G.NodeTargets
			and G.NodeTargets(nd, st.tid) then
			best = st.tid
		end
	end
	local sz = view:iconSz(c.n)
	if not match then
		sz = min(sz, GM.Widgets.MapStyle.SHRINK_CAP)
	end
	if pinned then sz = sz * 0.7 end
	view.L:icon(x, y, sz, GM.ItemIcon(best),
		col[1], col[2], col[3], a)
	if c.n > 1 and not pinned then
		view.L:badge(x, y + sz / 2 + 6, tostring(c.n),
			col[1], col[2], col[3], a)
	end
	if view.feats.hot and st.tip ~= false then
		view.L:hot(x, y, sz + 6, sz + 6,
			GM.GatherMap.ClusterTip(c, st.mapID))
	end
end

-- route loop: one chord per leg through the view's route
-- primitive, stop dots where the view allows them, the running
-- route's next stop pinned. st = { a, active, tipFn }
function MM.Draw.route(view, rt, st)
	local S = GM.Widgets.MapStyle.A
	local a = st.a or S.route
	for i = 1, #rt.stops do
		local p, q = rt.stops[i], rt.stops[i % #rt.stops + 1]
		local ax, ay = view:proj(p)
		local bx, by = view:proj(q)
		if ax and bx then
			view:routeSeg(ax, ay, bx, by, a)
			if view.feats.hot and st.tipFn then
				local len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
				local n = max(1, floor(len
					/ GM.Widgets.MapStyle.ROUTE_HOT_SPACING))
				for j = 0, n - 1 do
					view.L:hot(
						ax + (bx - ax) * (j + 0.5) / n,
						ay + (by - ay) * (j + 0.5) / n,
						20, 20, st.tipFn)
				end
			end
		end
		if ax and not view:cull(ax, ay, 0) then
			view:routeStop(ax, ay, a)
		end
	end
	if st.active then
		local x, y = view:proj(st.active)
		if x and not view:cull(x, y, 0) then
			view.L:pin(x, y, 8, 0.4, 0.85, 1.0,
				S.full * (st.oa or 1))
		end
	end
end

-- continent summary mark: count disc + medal ring (worldy maps
-- only — the view never receives these on the radar)
function MM.Draw.mark(view, m, st)
	local x, y = view:proj(m)
	if not x or view:cull(x, y, 0) then return end
	local S = GM.Widgets.MapStyle
	local mc = m.medal and S.MEDAL[m.medal] or S.MEDAL_OFF
	view.L:mark(x, y, m.count, mc[1], mc[2], mc[3], m.medal)
end

-- ======================= composition =========================
-- Shared paint pass for every view: marks on continent maps, else
-- zones under, node clusters mid, the route loop on top — one
-- order and one state resolution on all three surfaces. Each
-- object's draw is isolated so one bad record can't kill the pass.
--
-- ctx = {
--   mapID        display map the view is painting
--   zones, nodes record lists already filtered to this view
--   route        { stops, active=stop, tipFn } | nil
--   marks        continent mark list | nil (worldy views)
--   tid          target itemID for producer dimming | nil
--   filter       category filter for the zone path | nil
--   oa           { z=.., n=.., i=.. } opacity channels
--   zoneSt(zn)   -> st for Draw.zone (sel/match/tag state)
-- }

function MM.Paint(view, ctx)
	G = G or GM.Gather
	local S = GM.Widgets.MapStyle.A
	local oa = ctx.oa or {}

	-- continent/world view: summary marks replace camps entirely
	if ctx.marks then
		for _, m in ipairs(ctx.marks) do
			pcall(MM.Draw.mark, view, m, {})
		end
		return
	end

	for _, zn in ipairs(ctx.zones or {}) do
		local ok, st = pcall(function()
			if ctx.zoneSt then return ctx.zoneSt(zn) end
			return {}
		end)
		-- nil st = the surface's own filter dropped this object
		if ok and st then
			pcall(MM.Draw.zone, view, zn, st)
		end
	end

	local cst = { tid = ctx.tid, mapID = ctx.mapID,
		oa = oa.n or 1 }
	for _, c in ipairs(view:clusters(ctx.nodes or {})) do
		pcall(MM.Draw.cluster, view, c, cst)
	end

	if ctx.route and ctx.route.stops
		and #ctx.route.stops > 1 then
		ctx.route.oa = oa.n or 1
		MM.Draw.route(view, ctx.route, ctx.route)
	end
end
