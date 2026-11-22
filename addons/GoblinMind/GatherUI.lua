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
	return ({ herb = "HERB", mine = "MINE",
		skin = "SKIN", cloth = "CLOTH" })[k] or k
end

local function KindColor(k)
	local c = GM.Gather.KIND_COLOR[k] or { 1, 1, 1 }
	return format("|cff%02x%02x%02x",
		floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255))
end

local function RowText(r)
	local col = KindColor(r.kind)
	if r.area then
		-- zone row: kind · kills · sec/kill · EV/kill
		return format("%s%-5s|r  %s  ·  %d kills  ·  %ss/kill  ·  %s/kill",
			col, KindLabel(r.kind), r.zoneName,
			r.kills or 0,
			format("%.0f", r.lapSec),
			GM.MoneyShort(floor((r.evLoop or 0) * 10000)))
	end
	-- route row: kind · stops · lap time · EV/lap
	return format("%s%-5s|r  %s  ·  %d stops  ·  %s/lap  ·  %s/lap",
		col, KindLabel(r.kind), r.zoneName,
		r.stops and #r.stops or 0,
		GM.Gather.SecondsText(r.lapObs or r.lapSec),
		GM.MoneyShort(floor((r.evLoop or 0) * 10000)))
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
	local r = ui.mapRow and not ui.mapRow.area and ui.mapRow
	ui.pane:SetData(map, r)
	if map then
		ui.mapLegend:SetText(
			"icons = best drop · size = spawns grouped · "
			.. "blue loop = route · discs = hunt zones")
	else
		ui.mapLegend:SetText(
			"no farm data yet — gather nodes or kill mobs to seed")
	end
end

local function Refresh()
	if not ui or not ui:IsShown() then return end
	local rows = GM.Gather.Leaderboard()
	ui.rows = rows
	for i = 1, ROWS do
		local r, fs, rb = rows[i], ui.rowFs[i], ui.rowBtn[i]
		if r then
			fs:SetText(RowText(r))
			rb._row = r
			ui.gpmFs[i]:SetText(
				GM.MoneyShort(floor((r.gpm or 0) * 10000)) .. "/min")
			rb:Show()
		else
			fs:SetText("")
			rb._row = nil
			ui.gpmFs[i]:SetText("")
			rb:Hide()
		end
	end
	ui.count:SetText(#rows > 0
		and (#rows .. " routes + zones")
		or "no data yet — gather nodes or farm mobs to seed")
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
	DrawPane()
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
			.. GM.MoneyShort(floor(r.gpm * 10000)) .. "/min")
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
			w = 1020, h = 540, tab = "gather",
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
		ui.speedBtn = Btn(ui, 150, "speed:", function()
			GoblinMindGather.speedIx =
				(GM.Gather.SpeedIx() % #GM.Gather.SPEEDS) + 1
			Refresh()
		end)
		ui.speedBtn:SetPoint("LEFT", ui.stop, "RIGHT", 6, 0)

		-- leaderboard: left column
		local listTop = y - 26
		ui.count = GM.MakeFontString(ui, GM.FONT, 9, "textDim")
		ui.count:SetPoint("TOPLEFT", 14, listTop)
		ui.count:SetJustifyH("LEFT")

		ui.rowFs, ui.gpmFs, ui.rowBtn = {}, {}, {}
		local top = listTop - 16
		for i = 1, ROWS do
			local rb = CreateFrame("Button", nil, ui)
			rb:SetPoint("TOPLEFT", 10, top - (i - 1) * 20)
			rb:SetSize(560, 19)
			local fs = GM.MakeFontString(rb, GM.FONT, 10, "text")
			fs:SetPoint("LEFT", 4, 0)
			fs:SetJustifyH("LEFT")
			local gpm = GM.MakeFontString(rb, GM.FONT_BOLD, 10, "accent")
			gpm:SetPoint("RIGHT", -6, 0)
			gpm:SetJustifyH("RIGHT")
			rb:SetScript("OnClick", function(s)
				local r = s._row
				if not r then return end
				-- pane follows the pick either way
				ui.mapSel = r.map
				ui.mapRow = r
				if r.area then
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

		-- right column: the zone map pane
		local mp, mt = W.TitledPanel(ui, "zone map")
		mp:SetPoint("TOPLEFT", 590, listTop)
		mp:SetSize(416, 420)
		ui.mapTitle = mt
		ui.pane = GM.GatherMap
			and GM.GatherMap.CreatePane(mp, 404)
		if ui.pane then
			ui.pane:SetPoint("TOPLEFT", 6, -20)
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
