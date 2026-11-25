local _, GM = ...

-- GATHER window — the leaderboard over every farmable we've learned:
-- node loops (herb/mine, solver-built) and hunt zones (skin/cloth,
-- kill-rate modeled). Rows sort by gold/min; the right pane renders
-- the selected zone's map with node icons + the route polyline (or
-- a hunt-zone disc). Controls rebuild the current map's loop,
-- start/stop the waypoint run, and pick the transport speed.

GM.GatherUI = {}
local UI = GM.GatherUI
local W = GM.Widgets
local Btn = W.Btn

local ui
local ROWS = 24              -- row-button pool; ~21 show at once
-- filter order comes from the kind registry when it's loaded
-- (new kinds just appear); the literal stays as a load-order
-- fallback for sims
local function KindOrder()
	return (GM.Gather and GM.Gather.KINDS)
		or { "herb", "mine", "skin", "hunt", "cloth", "cook" }
end
-- node kinds (registry flag) are the routeable ones — fish pools
-- solve loops the same as herb/mine spawns
local function Routeable(k)
	return GM.Gather and GM.Gather.NODE_KINDS
		and GM.Gather.NODE_KINDS[k] or false
end

-- shared tag helpers live on Gather (G.KindLabel/G.KindHex) —
-- world-map labels read the same table so tags match in case
-- and color, including the settings color overrides
local function KindLabel(k)
	return GM.Gather.KindLabel(k)
end

local function KindColor(k)
	return GM.Gather.KindHex(k)
end

local function RowText(r)
	local col = KindColor(r.kind)
	if r.mob then
		-- mob row (target search): name · zone · kills · drop %
		-- · target EV/kill — "the mobs that drop that item"
		return format(
			"%s%-5s|r  %s — %s  ·  %d kills  ·  %s %.0f%%  ·  ev %s/kill",
			col, "MOB", r.mobName, r.zoneName or "?",
			r.kills or 0, r.targetName or "?",
			(r.chance or 0) * 100,
			GM.MoneyShort(floor((r.evLoop or 0))))
	end
	if r.area then
		-- zone row: kind · kills · spawns · sec/kill · EV/kill
		-- (+ raw measured GPM when the lottery delta is big)
		local raw = (r.gpmRaw or 0) > (r.gpm or 0) * 1.15
			and (GM.CC("textDim") .. "  earned "
				.. GM.MoneyShort(floor(r.gpmRaw))
				.. "/min|r") or ""
		-- mob names first — "what" distinguishes two camps in the
		-- same zone better than the map name does
		local mobs = r.zone and GM.Gather.ZoneMobs(r.zone)
		local where = mobs and (mobs .. " — " .. r.zoneName)
			or r.zoneName
		return format(
			"%s%-5s|r  %s  ·  %d kills  ·  %d spawns  ·  %ss/kill  ·  ev %s/kill%s",
			col, KindLabel(r.kind), where,
			r.kills or 0, r.spawns or 0,
			format("%.0f", r.lapSec),
			GM.MoneyShort(floor((r.evLoop or 0))), raw)
	end
	-- route row: kind · stops · lap time — the GPM column
	-- already carries the money readout, so a second /lap for
	-- lap EV just reads as a duplicated lap time
	return format("%s%-5s|r  %s  ·  %d stops  ·  %s/lap",
		col, KindLabel(r.kind), r.zoneName,
		r.stops and #r.stops or 0,
		GM.Gather.SecondsText(r.lapObs or r.lapSec))
end

-- the pane shows the selected row's map; default = wherever the
-- player stands, else whichever map has any data
local function PaneMap()
	if ui and ui.mapSel then return ui.mapSel end
	local m = GM.Gather.CurrentMap()
	if m then return m end
	for k in pairs(GoblinMindGather.nodes or {}) do return k end
	for k in pairs(GoblinMindGather.zones or {}) do return k end
end

-- per-zone summary marks for the continent/world view:
-- camps + solvable routes rolled up to the zone slot on the
-- display map (one mark per zone — Forever stores a single
-- place under several mapIDs), medal-ranked by best GPM.
-- Implementation is shared with the world-map overlay
local function ZoneMarks(displayMap, rows)
	if not (GM.GatherMap and GM.GatherMap.ZoneMarks) then
		return {}
	end
	return GM.GatherMap.ZoneMarks(displayMap, rows)
end

local function DrawPane()
	if not ui or not ui.pane then return end
	local map = PaneMap()
	ui.mapTitle:SetText(map and GM.Gather.ZoneName(map)
		or "zone map")
	local r = ui.mapRow and ui.mapRow.stops and ui.mapRow
	local marks
	if map and GM.GatherMap.IsWorldy
		and GM.GatherMap.IsWorldy(map) then
		-- a marker-calc error must not take the whole refresh
		-- down — the pane would keep the previous map's tiles
		local okM, mk = pcall(ZoneMarks, map, ui._all)
		if okM then marks = mk end
		ui.mapLegend:SetText(
			"marker = farm activity · count = camps+routes · "
			.. "medals = top-3 GPM zones")
	else
		ui.mapLegend:SetText(
			"icons = best drop · size = spawns grouped · "
			.. "blue loop = route · discs = hunt zones")
	end
	ui.pane:SetData(map, r, ui.mapRow, ui.kindFilter, marks)
	if not map then
		ui.mapLegend:SetText(
			"no farm data yet — gather nodes or kill mobs to seed")
	end
	-- a draw that failed mid-way stashes its error on the pane —
	-- surface it rather than silently showing stale/empty tiles
	if ui.pane._err then
		ui.mapLegend:SetText("map draw error: "
			.. tostring(ui.pane._err))
	end
end

local function TargetName(id)
	if not id then return nil end
	local n = GM.ItemNameOr and GM.ItemNameOr(id)
	return (n and n ~= "") and n or ("item " .. tostring(id))
end

-- stable row identity — Leaderboard rebuilds row tables every
-- Refresh, so expansion must key on data, not object identity
local function RowID(r)
	if r.mob then return "mob:" .. tostring(r.mobName) end
	if r.area then return "zone:" .. tostring(r.zone) end
	return "route:" .. tostring(r.map) .. ":" .. tostring(r.kind)
end

-- continent grouping for the zone picker and continent-scope
-- filtering: the records' own `c` (UnitPosition's continent —
-- data-driven, works even when the client's map hierarchy is
-- thin), else a parentMapID walk up to the ancestor directly
-- under a world/cosmic map
local CONT_NAME = { [1] = "Kalimdor", [2] = "Eastern Kingdoms",
	[3] = "Outland", [4] = "Northrend" }

local function MapContinent(map)
	-- records' `c` is UnitPosition's continent; 0 means "the
	-- client didn't know", not a continent, so it can't be a key
	local zl = map and GoblinMindGather.zones
		and GoblinMindGather.zones[map]
	if zl and zl[1] and zl[1].c and zl[1].c ~= 0 then
		return zl[1].c
	end
	local nl = map and GoblinMindGather.nodes
		and GoblinMindGather.nodes[map]
	if nl and nl[1] and nl[1].c and nl[1].c ~= 0 then
		return nl[1].c
	end
	local GetInfo = C_Map and C_Map.GetMapInfo
	if not (map and GetInfo) then return nil end
	local cur, prev = map, nil
	for _ = 1, 8 do
		local ok, info = pcall(GetInfo, cur)
		if not (ok and info) then return prev end
		local p = info.parentMapID
		if not p or p == 0 or p == cur then return prev end
		local ok2, pi = pcall(GetInfo, p)
		if ok2 and pi and pi.mapType and pi.mapType <= 1 then
			return cur -- cur's parent is a world/cosmic map
		end
		prev, cur = cur, p
	end
end

-- label the continent key — small ints are UnitPosition
-- continents, big numbers resolve as mapIDs
local function ContLabel(c)
	if not c then return "other" end
	if CONT_NAME[c] then return CONT_NAME[c] end
	return GM.Gather.ZoneName(c)
end

-- a mob row's category is its best camp's, not its recording
-- disposition — a cook camp's mob belongs under COOK
local function RowKind(r)
	if r.mob and r.zone and GM.Gather.ZoneCat then
		return GM.Gather.ZoneCat(r.zone)
	end
	return r.kind
end

local function RowKeep(r)
	if ui.zoneFilter and r.map ~= ui.zoneFilter then return false end
	-- a continent scope matches every map inside it plus any
	-- records stored on the continent mapID itself
	if ui.contFilter and r.map ~= ui.contFilter.id
		and ContLabel(MapContinent(r.map)) ~= ui.contFilter.label then
		return false
	end
	if ui.kindFilter and RowKind(r) ~= ui.kindFilter then
		return false
	end
	return true
end

-- the expansion tree: typed lines — {h=text} headers per mob +
-- the camp total, and {item=rowRec, dim} for each observed drop.
-- Item lines render as W.ItemRow frames (icon, rarity name,
-- drop %, price, vel, item tooltip + modified clicks)
local function DetailLines(r)
	local tid = GM.Gather.TargetID()
	local lines = {}
	local function head(s) lines[#lines + 1] = { h = s } end
	local function addRows(rows, cap)
		local shown = 0
		for _, dr in ipairs(rows or {}) do
			if shown >= (cap or 5) then
				head(GM.CC("textDim") .. "   +"
					.. (#rows - shown) .. " more|r")
				return
			end
			lines[#lines + 1] = { item = dr,
				dim = tid ~= nil and dr.id ~= tid }
			shown = shown + 1
		end
	end
	if r.mob then
		head(GM.CC("secondary") .. r.mobName
			.. " — " .. (r.kills or 0) .. " kills recorded|r")
		addRows(GM.Gather.DropRows("hunt:" .. r.mobName), 10)
	elseif r.area and r.zone then
		for _, sec in ipairs(GM.Gather.ZoneDetail(r.zone)) do
			head(GM.CC("secondary") .. sec.head .. "|r")
			addRows(sec.rows, sec.total and 8 or 4)
		end
	elseif r.stops then
		local seen = {}
		for _, st in ipairs(r.stops) do
			local nm = st.name or (st.nd and st.nd.name)
			if nm and not seen[nm] then
				seen[nm] = true
				head(GM.CC("secondary") .. nm .. "|r")
				addRows(GM.Gather.DropRows(nm), 3)
			end
			if #lines > 14 then break end
		end
	end
	return lines
end

-- lite skips the map-pane rebuild — the solve pump streams route
-- rows in through OnRouteSolved and only the list needs repainting
local function Refresh(lite)
	if not ui or not ui:IsShown() then return end
	local tid = GM.Gather.TargetID()
	local rows = {}
	if tid then
		-- target search answers "which mobs drop this" — mob rows
		-- from per-mob drop tables + producing routes. Zones show
		-- only when the drop isn't mob-attributed (records older
		-- than mob tracking have no hunt:<mob> yield)
		local tn = TargetName(tid)
		for _, r in ipairs(GM.Gather.Leaderboard()) do
			local keep
			if not r.area then
				keep = GM.Gather.RowTargets(r, tid)
			else
				keep = GM.Gather.RowTargets(r, tid)
					and not GM.Gather.ZoneHasMobDrop(r.zone, tid)
			end
			if keep and RowKeep(r) then rows[#rows + 1] = r end
		end
		for _, r in ipairs(GM.Gather.MobRows(tid)) do
			r.targetName = tn
			if RowKeep(r) then rows[#rows + 1] = r end
		end
		table.sort(rows, function(a, b)
			return (a.gpm or 0) > (b.gpm or 0)
		end)
	else
		for _, r in ipairs(GM.Gather.Leaderboard()) do
			if RowKeep(r) then rows[#rows + 1] = r end
		end
	end
	ui.rows = rows
	-- content model: every row 20px; the expanded row adds its
	-- tree's full height right below it. Rows + tree live on the
	-- scroll child's content plane — ui.scroll is a PIXEL offset
	-- and the clip culls the edges, so truncated content is always
	-- reachable by wheel
	local exIdx, exLines, extra = nil, nil, 0
	for i, r in ipairs(rows) do
		if RowID(r) == ui.expanded then exIdx = i break end
	end
	if not exIdx then ui.expanded = nil end
	if exIdx then
		exLines = DetailLines(rows[exIdx])
		for _, ln in ipairs(exLines) do
			extra = extra + (ln.item and 16 or 12)
		end
		extra = extra + 6
	end
	local viewH = ui.clip and ui.clip:GetHeight() or 0
	if viewH <= 0 then viewH = 400 end   -- anchors unresolved yet
	local contentH = #rows * 20 + extra
	ui._contentH = contentH
	ui.scroll = math.min(math.max(0, ui.scroll or 0),
		math.max(0, contentH - viewH))
	if ui.clip then ui.clip:SetVerticalScroll(ui.scroll) end
	if ui.inner then
		ui.inner:SetHeight(math.max(1, contentH))
	end
	-- pool buttons only render rows intersecting the viewport
	local y, vi, firstVis, lastVis = 0, 0, nil, nil
	for i, r in ipairs(rows) do
		local topY = y
		y = y + 20
		if i == exIdx then y = y + extra end
		if topY + 20 > ui.scroll and topY < ui.scroll + viewH then
			vi = vi + 1
			local rb, fs, gpm =
				ui.rowBtn[vi], ui.rowFs[vi], ui.gpmFs[vi]
			if rb then
				firstVis = firstVis or i
				lastVis = i
				rb:ClearAllPoints()
				rb:SetPoint("TOPLEFT", 0, -topY)
				-- expansion affordance: > closed, v open —
				-- nothing else marked a row as expandable
				fs:SetText((RowID(r) == ui.expanded and "v "
					or "> ") .. RowText(r))
				rb._row = r
				if rb.zb then
					local cr, cg, cb = GM.RGB("contHighest")
					rb.zb:SetColorTexture(cr, cg, cb,
						vi % 2 == 0 and 0.05 or 0)
				end
				-- estimated GPM (~) reads dim, confirmed stays
				-- accent — the honesty signal was invisible
				local est = r.conf == "low" or r.conf == "fair"
				gpm._prefix = est and "~" or ""
				gpm:SetTextColor(GM.RGB(
					est and "textDim" or "accent"))
				gpm:SetCopperShort(floor((r.gpm or 0)),
					r.unitSuffix)
				rb:SetAlpha(ui.expanded
					and RowID(r) ~= ui.expanded and 0.3 or 1)
				rb:Show()
			end
		end
	end
	for b = vi + 1, #ui.rowBtn do
		ui.rowFs[b]:SetText("")
		ui.gpmFs[b]:SetText("")
		ui.rowBtn[b]._row = nil
		ui.rowBtn[b]:Hide()
	end
	if ui.tree then
		ui.tree:Clear()
		if exIdx and exLines then
			-- tree top = expanded row's bottom on the content
			-- plane (rows before it are all 20px)
			ui.tree:Fill(exLines, exIdx * 20)
		end
	end
	local all = GM.Gather.Leaderboard()
	ui._all = all
	local filtered = ui.zoneFilter or ui.kindFilter
	ui.count:SetText(tid
		and (#rows .. " producers of " .. TargetName(tid)
			.. "  (" .. #all .. " hidden)")
		or (filtered and (#rows .. " of " .. #all .. " shown"))
		or (#rows > 0 and (#rows .. " farms")
			or "no data yet — gather nodes or farm mobs to seed"))
	W.ScrollText(ui.scrollFs, (firstVis or 1) - 1,
		math.max(0, (lastVis or 0) - (firstVis or 1) + 1), #rows)
	-- detail line for the selected/current-map route
	local run = GM.Gather.Route()
	if run then
		ui.detail:SetText(GM.CC("accent") .. "RUNNING|r  "
			.. (run.route.zoneName or "") .. "  ·  stop " .. run.idx
			.. "/" .. #run.stops
			.. (run.laps and run.laps > 0
				and ("  ·  " .. run.laps .. " laps") or ""))
	else
		ui.detail:SetText(GM.CC("textDim")
			.. "BUILD solves the best loop in the zone scope — "
			.. "a tight pocket of rich nodes can beat the whole map.|r")
	end
	-- routes only exist for HERB/MINE — grey out otherwise
	local routeable = Routeable(ui.kindFilter)
	ui.build:SetEnabled(routeable)
	ui.build:SetAlpha(routeable and 1 or 0.4)
	ui.zoneBtn.text:SetText("ZONE: " .. (ui.contFilter
		and ui.contFilter.label or ui.zoneFilter
		and GM.Gather.ZoneName(ui.zoneFilter) or "all"))
	ui.filterBtn.text:SetText("FILTER: " .. (ui.kindFilter
		and string.lower(KindLabel(ui.kindFilter)) or "all"))
	if GM.GatherMinimap then
		local n, total = GM.GatherMinimap.Count()
		ui.mmBtn.text:SetText("MINIMAP: " .. n .. "/" .. total)
	end
	if tid then ui.targetSlot:SetItem(tid)
	else ui.targetSlot:Clear() end
	if not lite then DrawPane() end
end

-- item name / link / raw id -> itemID, using the client's own item
-- cache for names (it's been in your bags, it's cached)
local function ResolveTarget(text)
	if not text or text == "" then return nil end
	local id = tonumber(text) or GM.LinkID(text)
	if id then return id end
	local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
	if GetInfo and #text > 2 then
		local _, link = GetInfo(text)
		if link then return GM.LinkID(link) end
	end
end

local function SetTarget(id)
	GM.Gather.SetTarget(id)
	if id then
		GM.Print(GM.CC("accent") .. "gather target: "
			.. TargetName(id) .. "|r")
	else
		GM.Print(GM.CC("textDim") .. "gather target cleared|r")
	end
	Refresh()
end

-- every mapID carrying any farm record — node loops and hunt
-- zones — sorted by display name for the zone picker
local function KnownMaps()
	local seen, out = {}, {}
	for m in pairs(GoblinMindGather.nodes or {}) do seen[m] = true end
	for m in pairs(GoblinMindGather.zones or {}) do seen[m] = true end
	for m in pairs(seen) do out[#out + 1] = m end
	table.sort(out, function(a, b)
		return GM.Gather.ZoneName(a) < GM.Gather.ZoneName(b)
	end)
	return out
end

local function SetZoneFilter(m)
	ui.zoneFilter = m
	ui.contFilter = nil
	if m then ui.mapSel = m end
	ui.scroll = 0
	Refresh()
end

-- continent scope: every map under this continent counts, plus
-- records stored on the continent mapID itself
local function SetContFilter(cid, label)
	ui.contFilter = { id = cid, label = label }
	ui.zoneFilter = nil
	ui.mapSel = cid -- the pane gets the whole continent
	ui.scroll = 0
	Refresh()
end

-- every zone the client knows, columned by continent (Kalimdor
-- and Eastern Kingdoms first). Continent/world mapIDs never
-- appear as entries — they're the clickable column headers, and
-- the world is the "Azeroth" row. Record-carrying maps the walk
-- misses get appended under whatever continent their records
-- claim — Forever custom zones can nest oddly
local function ZoneColumns()
	local cols, colIx, listed = {}, {}, {}
	local contIds = {}
	local function colFor(label)
		local c = colIx[label]
		if not c then
			c = { label = label, entries = {},
				order = label == "Kalimdor" and 1
					or label == "Eastern Kingdoms" and 2
					or label == "other" and 99 or 50 }
			colIx[label] = c
			cols[#cols + 1] = c
		end
		return c
	end
	local GI = C_Map and C_Map.GetMapChildrenInfo
	if GI then
		local conts = {}
		local ok, kids = pcall(GI, 947)
		for _, k in ipairs(ok and kids or {}) do
			local id = k.mapID or k.uiMapID
			if id then
				conts[#conts + 1] = { id = id, name = k.name }
				contIds[id] = true
			end
		end
		if #conts == 0 then
			conts = { { id = 1414 }, { id = 1415 } }
			contIds[1414], contIds[1415] = true, true
		end
		for _, c in ipairs(conts) do
			local col = colFor(c.name or GM.Gather.ZoneName(c.id))
			col.id = c.id -- the header's clickable scope
			local function walk(pid, depth)
				if depth > 3 then return end
				local ok2, zones = pcall(GI, pid)
				for _, z in ipairs(ok2 and zones or {}) do
					local zid = z.mapID or z.uiMapID
					if zid and not listed[zid] then
						listed[zid] = true
						-- take every child — a stray dungeon beats
						-- a missing zone
						col.entries[#col.entries + 1] = zid
						walk(zid, depth + 1)
					end
				end
			end
			walk(c.id, 1)
		end
	end
	-- record-carrying maps the enumeration never produced —
	-- but never a world/continent map (those are the headers)
	for _, map in ipairs(KnownMaps()) do
		if not listed[map] and not contIds[map] and map ~= 947 then
			local col = colFor(ContLabel(MapContinent(map)))
			col.entries[#col.entries + 1] = map
		end
	end
	table.sort(cols, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.label < b.label
	end)
	for _, col in ipairs(cols) do
		table.sort(col.entries, function(a, b)
			return GM.Gather.ZoneName(a) < GM.Gather.ZoneName(b)
		end)
	end
	return cols
end

-- the zone menu: "Azeroth" = the whole world (the old ALL row),
-- then one column per continent — Kalimdor, Eastern Kingdoms,
-- then any others — with that continent's zones underneath
local function OpenZoneMenu(btn)
	local m = ui.zmenu
	if m and m:IsShown() then
		m:Hide()
		if m.catcher then m.catcher:Hide() end
		return
	end
	if not m then
		local catcher = CreateFrame("Button", nil, ui)
		catcher:SetAllPoints(UIParent)
		catcher:SetFrameLevel(ui:GetFrameLevel() + 39)
		catcher:SetScript("OnClick", function()
			ui.zmenu:Hide()
			catcher:Hide()
		end)
		m = CreateFrame("Frame", nil, ui)
		m:SetFrameLevel(ui:GetFrameLevel() + 40)
		GM.Panel(m, "contLow", "outline")
		m.catcher = catcher
		m.rows = {}
		ui.zmenu = m
	end
	local cols = ZoneColumns()
	local COLW, RH, MAXR = 168, 18, 18
	local ncols = math.max(#cols, 1)
	local width = ncols * COLW + 4
	local maxRows = 0
	for _, col in ipairs(cols) do
		if #col.entries > maxRows then maxRows = #col.entries end
	end
	local vis = math.min(maxRows, MAXR)
	m.off = 0
	local function Paint()
		local rowIx = 0
		local function Row(x, y, w, label, checked, cb, head)
			rowIx = rowIx + 1
			local b = m.rows[rowIx]
			if not b then
				b = CreateFrame("Button", nil, m)
				b:SetHeight(RH)
				b.text = GM.MakeFontString(b, GM.FONT, 10, "text")
				b.text:SetPoint("LEFT", 6, 0)
				b.text:SetWordWrap(false)
				b.text:SetJustifyH("LEFT")
				local hov = b:CreateTexture(nil, "ARTWORK")
				hov:SetAllPoints()
				hov:SetColorTexture(GM.RGB("contHigh"))
				hov:Hide()
				b:SetScript("OnEnter", function() hov:Show() end)
				b:SetScript("OnLeave", function() hov:Hide() end)
				-- buttons eat wheel events — forward to the menu's
				-- pager or scrolling only works over the 2px gaps
				b:EnableMouseWheel(true)
				b:SetScript("OnMouseWheel", function(_, d)
					local f = m:GetScript("OnMouseWheel")
					if f then f(m, d) end
				end)
				m.rows[rowIx] = b
			end
			b.text:SetWidth(w - 12)
			b:SetWidth(w)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", x, y)
			b.text:SetText(label)
			b.text:SetTextColor(GM.RGB(
				checked and "accent" or head and "textDim" or "text"))
			b:SetScript("OnClick", cb and function()
				m:Hide()
				m.catcher:Hide()
				cb()
			end or nil)
			b:Show()
		end
		-- "Azeroth" spans the whole menu: the world = every zone
		Row(2, -2, width - 4, "Azeroth",
			not ui.zoneFilter and not ui.contFilter,
			function() SetZoneFilter(nil) end)
		-- continent headers are clickable — selecting one scopes
		-- the rows to the whole continent — then paged entries
		for ci, col in ipairs(cols) do
			local x = 2 + (ci - 1) * COLW
			-- a column past its window isn't missing zones, it's
			-- paged — say so on the header (Wetlands etc live past
			-- row 18 on Eastern Kingdoms)
			local hidden = #col.entries - m.off - vis
			Row(x, -2 - RH, COLW,
				col.label .. (hidden > 0
					and format(" · +%d", hidden) or ""),
				ui.contFilter and ui.contFilter.id == col.id,
				col.id and function()
					SetContFilter(col.id, col.label)
				end, true)
			for i = 1, vis do
				local map = col.entries[m.off + i]
				if not map then break end
				Row(x, -2 - RH - i * RH, COLW,
					GM.Gather.ZoneName(map),
					ui.zoneFilter == map,
					function() SetZoneFilter(map) end)
			end
		end
		for i = rowIx + 1, #m.rows do m.rows[i]:Hide() end
		m:SetSize(width, 8 + RH * (2 + vis))
	end
	m:EnableMouseWheel(true)
	m:SetScript("OnMouseWheel", function(_, d)
		m.off = math.min(math.max(0, maxRows - vis),
			math.max(0, m.off - d))
		Paint()
	end)
	Paint()
	-- TOPRIGHT extends the menu LEFT of the button — a multi-column
	-- menu overflows the screen's left edge when the window sits
	-- near it. Flip to grow right when the left edge would
	-- underflow; SetClampedToScreen is the hard guard either way
	m:ClearAllPoints()
	local br = btn:GetRight() or 0
	if br - width < 0 then
		m:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
	else
		m:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
	end
	m:SetClampedToScreen(true)
	m:Show()
	m.catcher:Show()
end

local function FilterEntries()
	local e = { { label = "everything",
		checked = not ui.kindFilter,
		cb = function()
			ui.kindFilter = nil ui.scroll = 0 Refresh()
		end } }
	for _, k in ipairs(KindOrder()) do
		e[#e + 1] = {
			label = GM.Gather.KindTag(k),
			checked = ui.kindFilter == k,
			cb = function()
				ui.kindFilter = k ui.scroll = 0 Refresh()
			end,
		}
	end
	return e
end

-- checkable layer toggles for the minimap overlay
local function MiniEntries()
	local e = {}
	local MM = GM.GatherMinimap
	if not MM then return e end
	for _, k in ipairs(MM.Layers()) do
		local kk = k
		e[#e + 1] = {
			label = MM.LABEL[k],
			checked = MM.Enabled(k),
			cb = function()
				MM.Set(kk, not MM.Enabled(kk))
				Refresh()
			end,
		}
	end
	return e
end

-- only HERB/MINE have routes — BUILD is gated to those filters
local function Build()
	local kind = ui.kindFilter
	if not Routeable(kind) then return end
	-- explicit zone scope = solve just that zone. Everything
	-- else ranks candidates by solved GPM: "zone: all" means the
	-- best loop anywhere, not wherever the player happens to
	-- stand (CurrentMap once won by default and built a
	-- Stormwind route when the profitable nodes were in Arathi)
	local cands, seen = {}, {}
	local function cand(m)
		if m and not seen[m] then
			seen[m] = true
			cands[#cands + 1] = m
		end
	end
	if ui.zoneFilter then
		cand(ui.zoneFilter)
	else
		for m in pairs(GoblinMindGather.nodes or {}) do
			if not ui.contFilter or m == ui.contFilter.id
				or ContLabel(MapContinent(m))
					== ui.contFilter.label then
				cand(m)
			end
		end
		cand(GM.Gather.CurrentMap())
	end
	local r, p
	for _, m in ipairs(cands) do
		local s = GM.Gather.SolveRoute(m, kind)
		if s and (not r or (s.gpm or 0) > (r.gpm or 0)) then
			r, p = s, m
		end
	end
	if r then
		r.zoneName = GM.Gather.ZoneName(p)
		if GM.GatherMap then GM.GatherMap.NoteRoute(r) end
		ui.mapSel = p
		-- BUILD means run it: StartRoute joins at the nearest
		-- stop, starts the arrival tick, and plants the marker —
		-- a planted waypoint nobody chases never advances
		GM.Gather.StartRoute(r)
		GM.Print(GM.CC("accent") .. "route: " .. r.zoneName .. "|r  "
			.. #r.stops .. " stops, "
			.. GM.Gather.SecondsText(r.lapSec) .. "/lap, ~"
			.. GM.MoneyShort(floor(r.gpm)) .. "/min")
	else
		GM.Print(GM.CC("textDim") .. "not enough " .. kind
			.. " nodes "
			.. (ui.zoneFilter and "here" or "anywhere")
			.. " yet (need 3+)|r")
	end
	Refresh()
end

local function Toggle()
	if not ui then
		ui = W.Window({
			name = "GoblinMindGatherUI",
			title = "GATHER",
			w = 1180, h = 560, tab = "gather",
		})

		ui.detail = GM.MakeFontString(ui, GM.FONT, 10, "textDim")
		ui.detail:SetPoint("TOPLEFT", 14, -32)

		-- controls row 1: zone scope + category filter, then the
		-- route controls and the model assumptions
		local y = -50
		ui.current = Btn(ui, 80, "CURRENT", function()
			local m = GM.Gather.CurrentMap()
			if m then
				SetZoneFilter(m)
			else
				GM.Print(GM.CC("textDim") .. "no map here|r")
			end
		end)
		ui.current:SetPoint("TOPLEFT", 14, y)
		W.Tip(ui.current, {
			"Current zone",
			"Scope the list and the map pane to the zone you're standing in.",
		})
		ui.zoneBtn = Btn(ui, 150, "ZONE: all", function(s)
			OpenZoneMenu(s)
		end)
		ui.zoneBtn:SetPoint("LEFT", ui.current, "RIGHT", 6, 0)
		ui.filterBtn = Btn(ui, 130, "FILTER: all", function(s)
			W.PopupMenu(s, FilterEntries(), { host = ui, w = 150 })
		end)
		ui.filterBtn:SetPoint("LEFT", ui.zoneBtn, "RIGHT", 6, 0)
		ui.build = Btn(ui, 70, "BUILD", Build)
		ui.build:SetPoint("LEFT", ui.filterBtn, "RIGHT", 12, 0)
		-- the herb/mine gate is invisible otherwise — the tip
		-- explains why the button sits grey
		W.Tip(ui.build, function()
			if Routeable(ui.kindFilter) then
				return { "Build route",
					"Solves the most profitable loop from the",
					"recorded nodes in the scoped zone." }
			end
			return { "Build route",
				"Pick a node filter (HERB, MINE, FISH) —",
				"routes need gathering-node records." }
		end)
		ui.save = Btn(ui, 70, "SAVE", function()
			local p = ui.mapSel or GM.Gather.CurrentMap()
			local r = p and GM.GatherMap and GM.GatherMap.RouteFor(p)
			local ok, err = GM.Gather.SaveRoute(r)
			if ok then
				GM.Print(GM.CC("accent") .. "route saved|r — "
					.. tostring(r.zoneName or GM.Gather.ZoneName(r.map))
					.. ", " .. #r.stops .. " stops")
			else
				GM.Print(GM.CC("textDim") .. (err
					or "no route here — BUILD first") .. "|r")
			end
			Refresh()
		end)
		ui.save:SetPoint("LEFT", ui.build, "RIGHT", 6, 0)
		W.Tip(ui.save, {
			"Save route",
			"Stores the loop shown on the pane —",
			"survives reloads, keyed to this map.",
		})
		ui.load = Btn(ui, 70, "LOAD", function()
			local kind = ui.kindFilter
			-- same "best in scope" ladder BUILD uses: the pane's
			-- map first, then the zone filter, then every saved
			-- loop the continent scope admits — a save under a
			-- sibling map used to read "no saved route" while the
			-- record sat one scope level down
			local r = GM.Gather.LoadRoute(
				ui.mapSel or ui.zoneFilter or GM.Gather.CurrentMap(),
				kind)
			if not r and ui.zoneFilter then
				r = GM.Gather.LoadRoute(ui.zoneFilter, kind)
			end
			if not r then
				for _, s in pairs(GoblinMindGather.saved or {}) do
					if (not kind or s.kind == kind)
						and (not ui.contFilter
							or s.map == ui.contFilter.id
							or ContLabel(MapContinent(s.map))
								== ui.contFilter.label)
						and (not r or (s.gpm or 0) > (r.gpm or 0)) then
						r = s
					end
				end
				if r and GM.GatherMap then GM.GatherMap.NoteRoute(r) end
			end
			if r then
				if r.map then SetZoneFilter(r.map) end
				GM.Gather.StartRoute(r)
				GM.Print(GM.CC("accent") .. "route loaded|r — "
					.. tostring(r.zoneName or GM.Gather.ZoneName(r.map))
					.. ", " .. #r.stops .. " stops")
			else
				GM.Print(GM.CC("textDim")
					.. "no saved route in scope|r")
			end
			Refresh()
		end)
		ui.load:SetPoint("LEFT", ui.save, "RIGHT", 6, 0)
		W.Tip(ui.load, {
			"Load route",
			"Restores the best saved loop for the viewed",
			"map and starts running it.",
		})
		-- plain click drops the live route (overlay + running
		-- instance) but keeps the save — forgetting the record is
		-- the destructive path and needs a shift-click
		ui.clear = Btn(ui, 92, "CLEAR ROUTE", function()
			local p = ui.mapSel or ui.zoneFilter or GM.Gather.CurrentMap()
			local forget = IsShiftKeyDown and IsShiftKeyDown()
			if p and GM.Gather.ClearRoute(p, forget) then
				GM.Print(GM.CC("accent") .. (forget
					and "saved route deleted|r" or "route cleared|r"))
			else
				GM.Print(GM.CC("textDim")
					.. "no route here to clear|r")
			end
			Refresh()
		end)
		ui.clear:SetPoint("LEFT", ui.load, "RIGHT", 6, 0)
		W.Tip(ui.clear, {
			"Clear route",
			"Drops the running loop and pane overlay on the",
			"viewed map — the saved record stays.",
			"Shift-click also deletes the saved route.",
		})
		-- per-layer minimap overlay toggles
		ui.mmBtn = Btn(ui, 110, "MINIMAP:", function(s)
			W.PopupMenu(s, MiniEntries(), { host = ui, w = 120 })
		end)
		ui.mmBtn:SetPoint("LEFT", ui.clear, "RIGHT", 12, 0)

		-- controls row 2: the target pick — name/link/id text box
		-- that also takes drops. The "target:" label makes it
		-- plain the row scopes the leaderboard to producers
		local tlbl = GM.MakeFontString(ui, GM.FONT, 9, "textDim")
		tlbl:SetPoint("TOPLEFT", 14, y - 31)
		tlbl:SetText("target:")
		ui.target = W.EditBox(ui, 190, "item name, link or id...")
		ui.target:SetPoint("TOPLEFT", 56, y - 26)
		ui.target:SetScript("OnEnterPressed", function(s)
			local id = ResolveTarget(s:GetText())
			if id then
				SetTarget(id)
			else
				GM.Print(GM.CC("textDim")
					.. "no item matched — try the link or id|r")
			end
			s:ClearFocus()
		end)
		ui.target:EnableMouse(true)
		ui.target:SetScript("OnReceiveDrag", function(s)
			local t, id = GetCursorInfo()
			if t == "item" and id then
				ClearCursor()
				SetTarget(id)
				s:SetText(TargetName(id) or "")
			end
		end)
		ui.targetClear = Btn(ui, 60, "RESET", function()
			SetTarget(nil)
			ui.target:SetText("")
		end)
		W.Tip(ui.targetClear, {
			"Reset target",
			"Clears the producer search —",
			"the list goes back to all farms.",
		})
		ui.targetClear:SetPoint("LEFT", ui.target, "RIGHT", 6, 0)

		-- shared slot: drop a target item onto it; shows icon+name+id
		-- h=26 fits the row pitch — the old 30px slot poked a
		-- pixel into the button row and sat on the count line
		ui.targetSlot = W.ItemSlot(ui, {
			w = 240, h = 26, icon = 22,
			nameSize = 10, subSize = 8,
			hint = "or drop an item on me",
			onItem = function(id) SetTarget(id) end,
		})
		ui.targetSlot:SetPoint("LEFT", ui.targetClear, "RIGHT", 8, 0)

		-- leaderboard: left column (under the 26px target slot)
		local listTop = y - 56
		ui.count = GM.MakeFontString(ui, GM.FONT, 9, "textDim")
		ui.count:SetPoint("TOPLEFT", 14, listTop)
		ui.count:SetJustifyH("LEFT")
		ui.scrollFs = GM.MakeFontString(ui, GM.FONT, 9, "textDim")
		ui.scrollFs:SetPoint("TOPRIGHT", -598, listTop)
		ui.scrollFs:SetJustifyH("RIGHT")

		-- list region is a clipped ScrollFrame: row buttons and
		-- expansion trees live on the scroll child at content-y;
		-- ui.scroll is a pixel offset applied via SetVerticalScroll
		ui.clip = CreateFrame("ScrollFrame", nil, ui)
		ui.clip:SetPoint("TOPLEFT", 10, listTop - 16)
		ui.clip:SetPoint("BOTTOMRIGHT", -598, 30)
		ui.inner = CreateFrame("Frame", nil, ui.clip)
		ui.inner:SetSize(560, 1)
		ui.clip:SetScrollChild(ui.inner)

		local function Wheel(_, d)
			local vh = ui.clip:GetHeight() or 0
			if vh <= 0 then vh = 400 end
			local mx = math.max(0, (ui._contentH or 0) - vh)
			local ns = math.min(mx,
				math.max(0, (ui.scroll or 0) - d * 40))
			if ns ~= (ui.scroll or 0) then
				ui.scroll = ns
				ui.clip:SetVerticalScroll(ns)
				Refresh()
			end
		end
		ui:EnableMouseWheel(true)
		ui:SetScript("OnMouseWheel", Wheel)
		-- the clip covers the list — it needs the handler too, or
		-- wheeling over rows would eat the event
		ui.clip:EnableMouseWheel(true)
		ui.clip:SetScript("OnMouseWheel", Wheel)

		ui.rowFs, ui.gpmFs, ui.rowBtn = {}, {}, {}
		for i = 1, ROWS do
			local rb = CreateFrame("Button", nil, ui.inner)
			rb:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
			rb:SetSize(560, 19)
			-- zebra striping — SniperUI's list convention; the
			-- pool indexes visible rows so Refresh decides parity
			rb.zb = rb:CreateTexture(nil, "BACKGROUND")
			rb.zb:SetAllPoints()
			local gpm = W.Money(rb, {
				font = GM.FONT_BOLD, size = 10, color = "accent",
				suffix = "/min",
			})
			gpm:SetPoint("RIGHT", -6, 0)
			gpm:SetJustifyH("RIGHT")
			local fs = GM.MakeFontString(rb, GM.FONT, 10, "text")
			fs:SetPoint("LEFT", 4, 0)
			-- clip before the gpm column — the AGENTS.md pattern:
			-- width cap + no wrap, long text truncates
			fs:SetPoint("RIGHT", gpm, "LEFT", -8, 0)
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(false)
			rb:SetScript("OnClick", function(s)
				local r = s._row
				if not r then return end
				-- routes: double-click = run/stop, single = inspect.
				-- click used to do both — expanding a route's tree
				-- committed you to the run
				local isRoute = not r.mob and not r.area
				local now = GetTime and GetTime() or 0
				local dbl = s._lastC and (now - s._lastC) < 0.35
				s._lastC = now
				if dbl then
					if isRoute then
						-- route rows: double-click = run/stop; the
						-- run drives the native waypoint stop-to-stop
						-- (the in-world marker MapWise chases with)
						local cur = GM.Gather.Route()
						if cur and cur.route
							and cur.route.map == r.map
							and cur.route.kind == r.kind then
							GM.Gather.StopRoute()
						else
							GM.Gather.StartRoute(r)
						end
					elseif r.zone then
						-- camp/mob rows: double-click plants the
						-- waypoint in the world — single click
						-- used to navigate, which made "look"
						-- and "go" the same gesture
						GM.Gather.PointAt(r.zone)
						GM.Print(GM.CC("accent") .. "waypoint: "
							.. (r.mobName or r.zoneName or "?")
							.. (r.mobName and r.zoneName
								and (" — " .. r.zoneName) or "")
							.. "|r")
					else
						GM.Print(GM.CC("textDim")
							.. "no farm spot recorded for "
							.. (r.mobName or "that row")
							.. " yet|r")
					end
					Refresh()
					return
				end
				-- toggle the drop-tree expansion under this row —
				-- collapsing it also drops the map highlight
				local id = RowID(r)
				local opening = ui.expanded ~= id
				ui.expanded = opening and id or nil
				ui.mapRow = opening and r or nil
				-- selecting a row scopes the window to its zone —
				-- the ZONE button, the list, and the pane must all
				-- say the same map or "select" reads broken
				if r.map then SetZoneFilter(r.map) end
				Refresh()
			end)
			W.HoverTint(rb)
			ui.rowFs[i], ui.gpmFs[i], ui.rowBtn[i] = fs, gpm, rb
		end

		-- expansion pool on the scroll child — same surface the
		-- row buttons use, so its draw level can't lose. The clip
		-- culls overflow; every line draws at its content-y
		ui.tree = { fs = {}, items = {} }
		function ui.tree:Clear()
			for _, f in ipairs(self.fs) do f:Hide() end
			for _, r in ipairs(self.items) do r:Hide() end
		end
		function ui.tree:Fill(lines, topY)
			local fi, ri, y = 0, 0, -(topY or 0) - 2
			for _, ln in ipairs(lines) do
				if ln.item then
					ri = ri + 1
					local rr = self.items[ri]
					if not rr then
						rr = W.ItemRow(ui.inner, { h = 16, icon = 13 })
						self.items[ri] = rr
					end
					rr:ClearAllPoints()
					rr:SetPoint("TOPLEFT", ui.inner, "TOPLEFT",
						10, y)
					rr:SetWidth(548)
					rr:SetItem({
						id = ln.item.id,
						name = ln.item.name,
						pct = ln.item.pct,
						rate = ln.item.rate,
						price = ln.item.value,
					})
					rr:SetAlpha(ln.dim and 0.45 or 1)
					rr:Show()
					y = y - 16
				else
					fi = fi + 1
					local f = self.fs[fi]
					if not f then
						f = GM.MakeFontString(ui.inner,
							GM.FONT, 9, "text")
						f:SetJustifyH("LEFT")
						self.fs[fi] = f
					end
					f:ClearAllPoints()
					f:SetPoint("TOPLEFT", ui.inner, "TOPLEFT",
						12, y - 1)
					f:SetText(ln.h)
					f:Show()
					y = y - 12
				end
			end
		end

		-- right column: the zone map pane, stretched flush to the
		-- panel bottom above the legend
		local mp, mt = W.TitledPanel(ui, "zone map")
		mp:SetPoint("TOPLEFT", 590, listTop)
		mp:SetSize(576, 444)
		ui.mapTitle = mt
		ui.pane = GM.GatherMap
			and GM.GatherMap.CreatePane(mp, 562)
		if ui.pane then
			ui.pane._fixedH = true
			ui.pane:SetPoint("TOPLEFT", 6, -20)
			ui.pane:SetPoint("BOTTOMRIGHT", mp, "BOTTOMRIGHT", -6, 24)
		end
		ui.mapLegend = GM.MakeFontString(mp, GM.FONT, 9, "textDim")
		ui.mapLegend:SetPoint("BOTTOMLEFT", 8, 6)
		ui.mapLegend:SetJustifyH("LEFT")

		ui.hint = GM.MakeFontString(ui, GM.FONT, 9, "textDim")
		ui.hint:SetPoint("BOTTOMLEFT", 12, 10)
		-- bound to the left column — the line used to run under
		-- the map panel, whose bg clips it mid-word
		ui.hint:SetWidth(566)
		ui.hint:SetWordWrap(false)
		ui.hint:SetText(
			"click = inspect · double-click = waypoint "
			.. "· double-click route = run · "
			.. "loot records automatically")

		-- ============ GoblinUI managed layout ============
		-- hand-laid: detail line at -32, two chained control rows,
		-- then a left leaderboard column beside the fixed 576px map
		-- pane. As columns/rows: the two control rows pack left, the
		-- body row gives the list column the left slack and the map
		-- pane its width, hint pins the bottom edge. The scroll clip
		-- and map internals adapt to fill — scroll math reads
		-- clip:GetHeight() live, so the new rect needs no rewiring.
		local u = GM.ui
		if u then
			local root = u:AttachRoot(ui, { direction = "column", gap = 4,
				pad = { top = 30, left = 10, right = 10, bottom = 8 } })
			root:Add(u:Adopt(ui.detail), { width = "fill", height = 12 })
			local r1 = u:Row(root, { gap = 6 })
			root:Add(r1, { width = "fill", height = 20 })
			r1:Add(u:Adopt(ui.current), { width = 80, height = 20 })
			r1:Add(u:Adopt(ui.zoneBtn), { width = 150, height = 20 })
			r1:Add(u:Adopt(ui.filterBtn), { width = 130, height = 20 })
			r1:Add(u:Leaf(r1), { width = 6, height = 1 })
			r1:Add(u:Adopt(ui.build), { width = 70, height = 20 })
			r1:Add(u:Adopt(ui.save), { width = 70, height = 20 })
			r1:Add(u:Adopt(ui.load), { width = 70, height = 20 })
			r1:Add(u:Adopt(ui.clear), { width = 70, height = 20 })
			r1:Add(u:Leaf(r1), { width = 6, height = 1 })
			r1:Add(u:Adopt(ui.mmBtn), { width = 110, height = 20 })
			local r2 = u:Row(root, { gap = 6 })
			root:Add(r2, { width = "fill", height = 26 })
			r2:Add(u:Adopt(tlbl), { width = 42, height = 12 })
			r2:Add(u:Adopt(ui.target), { width = 190, height = 18 })
			r2:Add(u:Adopt(ui.targetClear), { width = 60, height = 20 })
			r2:Add(u:Adopt(ui.targetSlot), { width = 240, height = 26 })
			local body = u:Row(root, { gap = 8 })
			root:Add(body, { width = "fill", height = "fill" })
			local leftCol = u:Column(body, { gap = 4 })
			body:Add(leftCol, { width = "fill", height = "fill" })
			local lrow = u:Row(leftCol, { gap = 6 })
			leftCol:Add(lrow, { width = "fill", height = 12 })
			lrow:Add(u:Adopt(ui.count), { width = "fill", height = 12 })
			lrow:Add(u:Adopt(ui.scrollFs), { width = 110, height = 12 })
			leftCol:Add(u:Adopt(ui.clip), { width = "fill", height = "fill" })
			body:Add(u:Adopt(mp), { width = 576, height = "fill" })
			root:Add(u:Adopt(ui.hint), { width = "fill", height = 12 })
		end
	end
	if ui:IsShown() then
		ui:Hide()
	else
		ui:Show()
		Refresh()
	end
end

-- export for the view registry — V.Refresh("gather") routes here
UI.Refresh = Refresh

function UI.Toggle()
	Toggle()
end

local solvedHooked
function UI.Show()
	-- this file loads before Gather.lua — hook the solve pump's
	-- stream callback here, once, at first show
	if not solvedHooked and GM.Gather
		and GM.Gather.OnRouteSolved then
		solvedHooked = true
		GM.Gather.OnRouteSolved(function() Refresh(true) end)
	end
	if not ui then Toggle() return end
	ui:Show()
	Refresh()
end

function UI.Hide()
	if ui then ui:Hide() end
end

function UI.IsShown()
	return ui and ui:IsShown()
end

GM.View.Register("gather", {
	Show = UI.Show, Hide = UI.Hide, Toggle = UI.Toggle,
	Refresh = UI.Refresh, IsShown = UI.IsShown })
