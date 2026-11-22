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
local ROWS = 20
local KIND_ORDER = { "herb", "mine", "skin", "hunt", "cloth", "cook" }

local function KindLabel(k)
	return ({ herb = "HERB", mine = "MINE", hunt = "HUNT",
		skin = "SKIN", cloth = "CLOTH", cook = "COOK" })[k] or k
end

local function KindColor(k)
	local c = GM.Gather.KIND_COLOR[k] or { 1, 1, 1 }
	return format("|cff%02x%02x%02x",
		floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255))
end

local function RowText(r)
	local col = KindColor(r.kind)
	if r.mob then
		-- mob row (target search): name · zone · kills · drop %
		-- · target EV/kill — "the mobs that drop that item"
		return format(
			"%s%-5s|r  %s — %s  ·  %d kills  ·  %s %.0f%%  ·  %s/kill",
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
			"%s%-5s|r  %s  ·  %d kills  ·  %d spawns  ·  %ss/kill  ·  %s/kill%s",
			col, KindLabel(r.kind), where,
			r.kills or 0, r.spawns or 0,
			format("%.0f", r.lapSec),
			GM.MoneyShort(floor((r.evLoop or 0))), raw)
	end
	-- route row: kind · stops · lap time · EV/lap
	return format("%s%-5s|r  %s  ·  %d stops  ·  %s/lap  ·  %s/lap",
		col, KindLabel(r.kind), r.zoneName,
		r.stops and #r.stops or 0,
		GM.Gather.SecondsText(r.lapObs or r.lapSec),
		GM.MoneyShort(floor((r.evLoop or 0))))
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

local function DrawPane()
	if not ui or not ui.pane then return end
	local map = PaneMap()
	ui.mapTitle:SetText(map and GM.Gather.ZoneName(map)
		or "zone map")
	local r = ui.mapRow and ui.mapRow.stops and ui.mapRow
	ui.pane:SetData(map, r, ui.mapRow, ui.kindFilter)
	if map then
		ui.mapLegend:SetText(
			"icons = best drop · size = spawns grouped · "
			.. "blue loop = route · discs = hunt zones")
	else
		ui.mapLegend:SetText(
			"no farm data yet — gather nodes or kill mobs to seed")
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

local function Refresh()
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
	-- scroll window over the filtered rows (mousewheel on ui)
	ui.scroll = math.min(ui.scroll or 0,
		math.max(0, #rows - ROWS))
	-- expansion state: the clicked row keeps full alpha, every
	-- other row fades, and rows BELOW it physically drop to make
	-- room for the drop tree — a real expansion, not an overlay.
	-- Scrolled out of view, the tree hides but the state survives
	-- so scrolling back restores it
	local exIdx, exLines
	for i, r in ipairs(rows) do
		if RowID(r) == ui.expanded then exIdx = i break end
	end
	if not exIdx then ui.expanded = nil end
	if exIdx then exLines = DetailLines(rows[exIdx]) end
	local exVis = exIdx and (exIdx - ui.scroll)
	local exShown = exVis and exVis >= 1 and exVis <= ROWS
	-- the tree only gets the space below the expanded row down to
	-- the content floor — a longer list truncates with "+N more"
	-- rather than spilling past the window
	local exAvail = 0
	if exShown then
		exAvail = (ui._rowTop or -112) - (exVis - 1) * 20
			- 19 - (ui._floorY or -526)
	end
	-- item rows are taller than header text — sum real heights
	local extra = 0
	if exLines and exShown then
		for _, ln in ipairs(exLines) do
			local lh = ln.item and 16 or 12
			if extra + lh > exAvail then break end
			extra = extra + lh
		end
		extra = extra + 6
	end
	-- rows pushed past the window bottom hide instead of
	-- overrunning the hint line (content floor ≈ -530 of 560)
	local maxOff = (ui._rowTop or -112) + 511
	for vi = 1, ROWS do
		local i = vi + ui.scroll
		local r, fs, rb, gpm =
			rows[i], ui.rowFs[vi], ui.rowBtn[vi], ui.gpmFs[vi]
		local off = (vi - 1) * 20
			+ (exShown and i > exIdx and extra or 0)
		if r and off <= maxOff then
			rb:ClearAllPoints()
			rb:SetPoint("TOPLEFT", 10, (ui._rowTop or -112) - off)
			fs:SetText(RowText(r))
			rb._row = r
			gpm._prefix = (r.conf == "low" or r.conf == "fair")
				and "~" or ""
			gpm:SetCopperShort(floor((r.gpm or 0)),
				r.unitSuffix)
			rb:SetAlpha(ui.expanded
				and RowID(r) ~= ui.expanded and 0.3 or 1)
			rb:Show()
		else
			fs:SetText("")
			rb._row = nil
			ui.gpmFs[vi]:SetText("")
			rb:Hide()
		end
	end
	if ui.tree then
		ui.tree:Clear()
		if exShown then
			ui.tree:Fill(exLines, ui.rowBtn[exVis], exAvail)
		end
	end
	local all = GM.Gather.Leaderboard()
	local filtered = ui.zoneFilter or ui.kindFilter
	ui.count:SetText(tid
		and (#rows .. " producers of " .. TargetName(tid)
			.. "  (" .. #all .. " hidden)")
		or (filtered and (#rows .. " of " .. #all .. " shown"))
		or (#rows > 0 and (#rows .. " routes + zones")
			or "no data yet — gather nodes or farm mobs to seed"))
	W.ScrollText(ui.scrollFs, ui.scroll, ROWS, #rows)
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
			.. "BUILD solves the best loop for your current zone — "
			.. "a tight pocket of rich nodes can beat the whole map.|r")
	end
	-- routes only exist for HERB/MINE — grey out otherwise
	local routeable = ui.kindFilter == "herb" or ui.kindFilter == "mine"
	ui.build:SetEnabled(routeable)
	ui.build:SetAlpha(routeable and 1 or 0.4)
	ui.zoneBtn.text:SetText("zone: " .. (ui.contFilter
		and ui.contFilter.label or ui.zoneFilter
		and GM.Gather.ZoneName(ui.zoneFilter) or "all"))
	ui.filterBtn.text:SetText("filter: " .. (ui.kindFilter
		and string.lower(KindLabel(ui.kindFilter)) or "all"))
	if tid then ui.targetSlot:SetItem(tid)
	else ui.targetSlot:Clear() end
	DrawPane()
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
			Row(x, -2 - RH, COLW, col.label,
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
	m:ClearAllPoints()
	m:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
	m:Show()
	m.catcher:Show()
end

local function FilterEntries()
	local e = { { label = "everything",
		checked = not ui.kindFilter,
		cb = function()
			ui.kindFilter = nil ui.scroll = 0 Refresh()
		end } }
	for _, k in ipairs(KIND_ORDER) do
		e[#e + 1] = {
			label = KindColor(k) .. KindLabel(k) .. "|r",
			checked = ui.kindFilter == k,
			cb = function()
				ui.kindFilter = k ui.scroll = 0 Refresh()
			end,
		}
	end
	return e
end

-- only HERB/MINE have routes — BUILD is gated to those filters
local function Build()
	local kind = ui.kindFilter
	if kind ~= "herb" and kind ~= "mine" then return end
	local p = ui.zoneFilter or GM.Gather.CurrentMap()
	if not p then
		-- fall back to whichever map has the most nodes
		local best, bn
		for m, l in pairs(GoblinMindGather.nodes or {}) do
			if not bn or #l > bn then best, bn = m, #l end
		end
		p = best
	end
	if not p then
		GM.Print(GM.CC("textDim")
			.. "no zone to route — pick one or stand in it|r")
		return
	end
	local r = GM.Gather.SolveRoute(p, kind)
	if r then
		r.zoneName = GM.Gather.ZoneName(p)
		if GM.GatherMap then GM.GatherMap.NoteRoute(r) end
		ui.mapSel = p
		GM.Print(GM.CC("accent") .. "route: " .. r.zoneName .. "|r  "
			.. #r.stops .. " stops, "
			.. GM.Gather.SecondsText(r.lapSec) .. "/lap, ~"
			.. GM.MoneyShort(floor(r.gpm)) .. "/min")
	else
		GM.Print(GM.CC("textDim") .. "not enough " .. kind
			.. " nodes here yet (need 3+)|r")
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

		ui.detail = GM.MakeFontString(ui, GM.FONT, 10, "text")
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
		ui.zoneBtn = Btn(ui, 150, "zone: all", function(s)
			OpenZoneMenu(s)
		end)
		ui.zoneBtn:SetPoint("LEFT", ui.current, "RIGHT", 6, 0)
		ui.filterBtn = Btn(ui, 130, "filter: all", function(s)
			W.PopupMenu(s, FilterEntries(), { host = ui, w = 150 })
		end)
		ui.filterBtn:SetPoint("LEFT", ui.zoneBtn, "RIGHT", 6, 0)
		ui.build = Btn(ui, 70, "BUILD", Build)
		ui.build:SetPoint("LEFT", ui.filterBtn, "RIGHT", 12, 0)
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
		ui.load = Btn(ui, 70, "LOAD", function()
			local p = ui.mapSel or ui.zoneFilter or GM.Gather.CurrentMap()
			local r = p and GM.Gather.LoadRoute(p, ui.kindFilter)
			if r then
				ui.mapSel = r.map
				GM.Gather.StartRoute(r)
				GM.Print(GM.CC("accent") .. "route loaded|r — "
					.. tostring(r.zoneName or GM.Gather.ZoneName(r.map))
					.. ", " .. #r.stops .. " stops")
			else
				GM.Print(GM.CC("textDim")
					.. "no saved route for this map|r")
			end
			Refresh()
		end)
		ui.load:SetPoint("LEFT", ui.save, "RIGHT", 6, 0)
		-- drop the route on the viewed map: saved loop, overlay,
		-- and a running instance — node/zone data is untouched
		ui.clear = Btn(ui, 70, "CLEAR", function()
			local p = ui.mapSel or ui.zoneFilter or GM.Gather.CurrentMap()
			if p and GM.Gather.ClearRoute(p) then
				GM.Print(GM.CC("accent") .. "route cleared|r")
			else
				GM.Print(GM.CC("textDim")
					.. "no route here to clear|r")
			end
			Refresh()
		end)
		ui.clear:SetPoint("LEFT", ui.load, "RIGHT", 6, 0)

		-- controls row 2: the target pick — name/link/id text box
		-- that also takes drops
		ui.target = W.EditBox(ui, 190, "target item...")
		ui.target:SetPoint("TOPLEFT", 14, y - 26)
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
		ui.targetClear = Btn(ui, 60, "CLEAR", function()
			SetTarget(nil)
			ui.target:SetText("")
		end)
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

		-- wheel anywhere in the window pages the list — the row
		-- buttons don't claim the wheel, so it lands here
		ui:EnableMouseWheel(true)
		ui:SetScript("OnMouseWheel", function(_, d)
			local mx = math.max(0, #(ui.rows or {}) - ROWS)
			local ns = math.min(mx,
				math.max(0, (ui.scroll or 0) - d * 3))
			if ns ~= (ui.scroll or 0) then
				ui.scroll = ns
				Refresh()
			end
		end)

		ui.rowFs, ui.gpmFs, ui.rowBtn = {}, {}, {}
		local top = listTop - 16
		ui._rowTop = top
		-- expansion floor: the hint line lives at window bottom —
		-- trees truncate at this y instead of spilling over it
		ui._floorY = -526
		for i = 1, ROWS do
			local rb = CreateFrame("Button", nil, ui)
			rb:SetPoint("TOPLEFT", 10, top - (i - 1) * 20)
			rb:SetSize(560, 19)
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
				-- toggle the drop-tree expansion under this row
				local id = RowID(r)
				ui.expanded = (ui.expanded == id) and nil or id
				-- pane follows the pick either way
				ui.mapSel = r.map
				ui.mapRow = r
				if r.mob then
					-- mob rows navigate to the mob's best zone
					if r.zone then
						GM.Gather.PointAt(r.zone)
						GM.Print(GM.CC("accent")
							.. "waypoint: " .. r.mobName .. " — "
							.. (r.zoneName or "?") .. "|r")
					else
						GM.Print(GM.CC("textDim")
							.. "no farm spot recorded for "
							.. r.mobName .. " yet|r")
					end
				elseif r.area then
					-- hunt zones: waypoint to the centroid
					GM.Gather.PointAt(r.zone)
					GM.Print(GM.CC("accent")
						.. "waypoint: " .. r.zoneName .. " "
						.. r.kind .. " farm|r")
				else
					-- routes: click toggles run/stop (row objects
					-- rebuild each refresh — match by identity)
					local cur = GM.Gather.Route()
					if cur and cur.route
						and cur.route.map == r.map
						and cur.route.kind == r.kind then
						GM.Gather.StopRoute()
					else
						GM.Gather.StartRoute(r)
					end
				end
				Refresh()
			end)
			W.HoverTint(rb)
			ui.rowFs[i], ui.gpmFs[i], ui.rowBtn[i] = fs, gpm, rb
		end

		-- expansion pool: headers fontstrings + item rows, all
		-- parented to `ui` itself — the same surface the status
		-- line uses, which provably renders here (a wrapper
		-- frame's draw level can lose to the row buttons'
		-- auto-assigned levels)
		ui.tree = { fs = {}, items = {} }
		function ui.tree:Clear()
			for _, f in ipairs(self.fs) do f:Hide() end
			for _, r in ipairs(self.items) do r:Hide() end
		end
		function ui.tree:Fill(lines, anchor, avail)
			local fi, ri, y = 0, 0, -2
			local left = avail or 1e6
			for i, ln in ipairs(lines) do
				local lh = ln.item and 16 or 12
				if -y + lh > left then
					-- truncated: one dim "+N more" line if there's
					-- room for it, else stop silently
					if -y + 12 <= left then
						fi = fi + 1
						local f = self.fs[fi]
						if not f then
							f = GM.MakeFontString(ui,
								GM.FONT, 9, "text")
							f:SetJustifyH("LEFT")
							self.fs[fi] = f
						end
						f:ClearAllPoints()
						f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT",
							12, y - 1)
						f:SetText(GM.CC("textDim") .. "   +"
							.. (#lines - i + 1) .. " more|r")
						f:Show()
					end
					break
				end
				if ln.item then
					ri = ri + 1
					local rr = self.items[ri]
					if not rr then
						rr = W.ItemRow(ui, { h = 16, icon = 13 })
						self.items[ri] = rr
					end
					rr:ClearAllPoints()
					rr:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT",
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
						f = GM.MakeFontString(ui, GM.FONT, 9, "text")
						f:SetJustifyH("LEFT")
						self.fs[fi] = f
					end
					f:ClearAllPoints()
					f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT",
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
		ui.hint:SetText(
			"click a route to run it · click a zone for a waypoint · "
			.. "gather casts and cloth/skin loot record automatically")
	end
	if ui:IsShown() then
		ui:Hide()
	else
		ui:Show()
		Refresh()
	end
end

function UI.Toggle()
	Toggle()
end

function UI.Show()
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
