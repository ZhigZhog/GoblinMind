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
local ROWS = 15

local function KindLabel(k)
	return ({ herb = "HERB", mine = "MINE", hunt = "HUNT",
		skin = "SKIN", cloth = "CLOTH" })[k] or k
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
	ui.pane:SetData(map, r, ui.mapRow)
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

-- the expansion tree: headers per mob + the camp total, each
-- with observed drop rows (name · drop% · value)
local function DetailLines(r)
	local W = GM.Widgets
	local tid = GM.Gather.TargetID()
	local lines = {}
	local function addRows(rows, cap)
		for _, s in ipairs(W.DropLines(rows,
			{ target = tid, max = cap or 5 })) do
			lines[#lines + 1] = s
		end
	end
	if r.mob then
		lines[#lines + 1] = GM.CC("secondary") .. r.mobName
			.. " — " .. (r.kills or 0) .. " kills recorded|r"
		addRows(GM.Gather.DropRows("hunt:" .. r.mobName), 10)
	elseif r.area and r.zone then
		for _, sec in ipairs(GM.Gather.ZoneDetail(r.zone)) do
			lines[#lines + 1] = GM.CC("secondary") .. sec.head .. "|r"
			addRows(sec.rows, sec.total and 8 or 4)
		end
	elseif r.stops then
		local seen = {}
		for _, st in ipairs(r.stops) do
			local nm = st.name or (st.nd and st.nd.name)
			if nm and not seen[nm] then
				seen[nm] = true
				lines[#lines + 1] = GM.CC("secondary") .. nm .. "|r"
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
			if keep then rows[#rows + 1] = r end
		end
		for _, r in ipairs(GM.Gather.MobRows(tid)) do
			r.targetName = tn
			rows[#rows + 1] = r
		end
		table.sort(rows, function(a, b)
			return (a.gpm or 0) > (b.gpm or 0)
		end)
	else
		for _, r in ipairs(GM.Gather.Leaderboard()) do
			rows[#rows + 1] = r
		end
	end
	ui.rows = rows
	-- expansion state: the clicked row keeps full alpha, every
	-- other row fades, and rows BELOW it physically drop to make
	-- room for the drop tree — a real expansion, not an overlay
	local exIdx, exLines
	for i, r in ipairs(rows) do
		if RowID(r) == ui.expanded then exIdx = i break end
	end
	if not exIdx then ui.expanded = nil end
	if exIdx then exLines = DetailLines(rows[exIdx]) end
	local extra = exLines and (#exLines * 12 + 6) or 0
	-- rows pushed past the window bottom hide instead of
	-- overrunning the hint line (content floor ≈ -530 of 560)
	local maxOff = (ui._rowTop or -92) + 511
	for i = 1, ROWS do
		local r, fs, rb, gpm =
			rows[i], ui.rowFs[i], ui.rowBtn[i], ui.gpmFs[i]
		local off = (i - 1) * 20
			+ (exIdx and i > exIdx and extra or 0)
		if r and off <= maxOff then
			rb:ClearAllPoints()
			rb:SetPoint("TOPLEFT", 10, (ui._rowTop or -92) - off)
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
			ui.gpmFs[i]:SetText("")
			rb:Hide()
		end
	end
	if ui.tree then
		ui.tree:Clear()
		if exIdx then
			ui.tree:Fill(exLines, ui.rowBtn[exIdx])
		end
	end
	local all = GM.Gather.Leaderboard()
	ui.count:SetText(tid
		and (#rows .. " producers of " .. TargetName(tid)
			.. "  (" .. #all .. " hidden)")
		or (#rows > 0 and (#rows .. " routes + zones")
			or "no data yet — gather nodes or farm mobs to seed"))
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
	local sp = GM.Gather.SPEEDS[GM.Gather.SpeedIx()]
	ui.speedBtn:SetText("speed: " .. sp.name)
	ui.contBtn:SetText("crowd: "
		.. GM.Gather.CONTS[GM.Gather.ContIx()].name)
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

local function Build()
	local p = GM.Gather.CurrentMap()
	if not p then
		-- fall back to whichever map has the most nodes
		local best, bn
		for m, l in pairs(GoblinMindGather.nodes or {}) do
			if not bn or #l > bn then best, bn = m, #l end
		end
		p = best
	end
	if not p then return end
	local r1 = GM.Gather.SolveRoute(p, "herb")
	local r2 = GM.Gather.SolveRoute(p, "mine")
	local r = (r1 and r2 and (r1.gpm > r2.gpm and r1 or r2)) or r1 or r2
	if r then
		r.zoneName = GM.Gather.ZoneName(p)
		if GM.GatherMap then GM.GatherMap.NoteRoute(r) end
		ui.mapSel = p
		GM.Print(GM.CC("accent") .. "route: " .. r.zoneName .. "|r  "
			.. #r.stops .. " stops, "
			.. GM.Gather.SecondsText(r.lapSec) .. "/lap, ~"
			.. GM.MoneyShort(floor(r.gpm)) .. "/min")
	else
		GM.Print(GM.CC("textDim")
			.. "not enough nodes here yet (need 3+)|r")
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

		-- controls row
		local y = -50
		ui.build = Btn(ui, 80, "BUILD", Build)
		ui.build:SetPoint("TOPLEFT", 14, y)
		ui.start = Btn(ui, 80, "START", function()
			local p = ui.mapSel or GM.Gather.CurrentMap()
			local r = p and GM.GatherMap and GM.GatherMap.RouteFor(p)
			if r then
				GM.Gather.StartRoute(r)
			else
				GM.Print(GM.CC("textDim")
					.. "no route for this map — BUILD first|r")
			end
			Refresh()
		end)
		ui.start:SetPoint("LEFT", ui.build, "RIGHT", 6, 0)
		ui.stop = Btn(ui, 80, "STOP", function()
			GM.Gather.StopRoute()
			Refresh()
		end)
		ui.stop:SetPoint("LEFT", ui.start, "RIGHT", 6, 0)
		ui.import = Btn(ui, 80, "IMPORT", function()
			local st, err = GM.Gather.ImportGatherLite()
			if st then
				GM.Print(GM.CC("accent") .. "gather import:|r "
					.. st.new .. " new, " .. st.merged
					.. " merged" .. (st.skipped > 0
						and (", " .. st.skipped .. " skipped") or ""))
			else
				GM.Print(GM.CC("textDim") .. (err
					or "no GatherLite data found") .. "|r")
			end
			Refresh()
		end)
		ui.import:SetPoint("LEFT", ui.stop, "RIGHT", 6, 0)
		ui.speedBtn = Btn(ui, 150, "speed:", function()
			GoblinMindGather.speedIx =
				(GM.Gather.SpeedIx() % #GM.Gather.SPEEDS) + 1
			Refresh()
		end)
		ui.speedBtn:SetPoint("LEFT", ui.import, "RIGHT", 6, 0)
		ui.contBtn = Btn(ui, 110, "crowd:", function()
			GoblinMindGather.contIx =
				(GM.Gather.ContIx() % #GM.Gather.CONTS) + 1
			Refresh()
		end)
		ui.contBtn:SetPoint("LEFT", ui.speedBtn, "RIGHT", 6, 0)

		-- target pick: name/link/id text box that also takes drops
		ui.target = W.EditBox(ui, 190, "target item...")
		ui.target:SetPoint("LEFT", ui.contBtn, "RIGHT", 10, 0)
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
		ui.targetSlot = W.ItemSlot(ui, {
			w = 240, h = 30, icon = 26,
			nameSize = 10, subSize = 8,
			hint = "or drop an item on me",
			onItem = function(id) SetTarget(id) end,
		})
		ui.targetSlot:SetPoint("LEFT", ui.targetClear, "RIGHT", 8, 0)

		-- leaderboard: left column
		local listTop = y - 26
		ui.count = GM.MakeFontString(ui, GM.FONT, 9, "textDim")
		ui.count:SetPoint("TOPLEFT", 14, listTop)
		ui.count:SetJustifyH("LEFT")

		ui.rowFs, ui.gpmFs, ui.rowBtn = {}, {}, {}
		local top = listTop - 16
		ui._rowTop = top
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
					-- routes: start the loop from stop 1
					GM.Gather.StartRoute(r)
				end
				Refresh()
			end)
			W.HoverTint(rb)
			ui.rowFs[i], ui.gpmFs[i], ui.rowBtn[i] = fs, gpm, rb
		end

		-- expansion pool: fontstrings parented to `ui` itself —
		-- the same surface the status line uses, which provably
		-- renders here (a wrapper frame's draw level can lose to
		-- the row buttons' auto-assigned levels)
		ui.tree = { fs = {} }
		function ui.tree:Clear()
			for _, f in ipairs(self.fs) do f:Hide() end
		end
		function ui.tree:Fill(lines, anchor)
			for i, s in ipairs(lines) do
				local f = self.fs[i]
				if not f then
					f = GM.MakeFontString(ui, GM.FONT, 9, "text")
					f:SetJustifyH("LEFT")
					self.fs[i] = f
				end
				f:ClearAllPoints()
				f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT",
					12, -2 - (i - 1) * 12)
				f:SetText(s)
				f:Show()
			end
		end

		-- right column: the zone map pane, stretched flush to the
		-- panel bottom above the legend
		local mp, mt = W.TitledPanel(ui, "zone map")
		mp:SetPoint("TOPLEFT", 590, listTop)
		mp:SetSize(576, 470)
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
