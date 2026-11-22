#!/usr/bin/env python
"""Gather-system harness — loads wow_stub + Gather.lua and exercises
the recording pipeline (cast->loot attribution), node/zone models,
respawn learning, and the GPM route solver (incl. the small-pocket
beats whole-zone case the respawn saturation model exists for)."""

import sys
from lupa import LuaRuntime

sys.stdout.reconfigure(encoding='utf-8')

CHECKS = []


def check(name, cond):
    CHECKS.append((name, bool(cond)))
    print(('  ok  ' if cond else ' FAIL ') + name)


lua = LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
lua.execute(open('brain/sim/wow_stub.lua', encoding='utf-8').read())

# ---- gather-specific stubs on top of the shared sim shim ----
lua.execute(r'''
-- the shared shim's frames lack visibility + region methods Gather
-- and the map pane need — give every frame the full widget surface
local _CreateFrame = CreateFrame
local function Region()
	local r = { _shown = true, _pts = {}, _w = 0, _h = 0 }
	function r:Show() self._shown = true end
	function r:Hide() self._shown = false end
	function r:IsShown() return self._shown end
	function r:SetPoint(...) self._pts[#self._pts + 1] = { ... } end
	function r:ClearAllPoints() self._pts = {} end
	function r:SetAllPoints() end
	function r:SetSize(w, h) self._w, self._h = w, h end
	function r:SetWidth(w) self._w = w end
	function r:SetHeight(h) self._h = h end
	function r:GetWidth() return self._w or 0 end
	function r:GetHeight() return self._h or 0 end
	function r:SetTexture(t) self._tex = t end
	function r:SetVertexColor(...) self._col = { ... } end
	function r:SetRotation(a) self._rot = a end
	function r:SetMaskTexture(m) self._mask = m end
	function r:SetText(s) self._text = s end
	function r:GetText() return self._text end
	function r:SetTextColor() end
	function r:SetJustifyH() end
	function r:SetWordWrap() end
	function r:SetParent(p) self._parent = p end
	function r:CreateTexture(...) local t = Region() return t end
	function r:CreateFontString(...) local s = Region() return s end
	return r
end
function CreateFrame(kind, name, parent)
	local f = _CreateFrame(kind, name, parent)
	for k, v in pairs(Region()) do
		if type(v) == "function" then f[k] = v end
	end
	f._pts, f._w, f._h = {}, 0, 0
	f._shown = true
	function f:SetScript(k, fn) self._scripts[k] = fn end
	return f
end

_POS = { n = 1000, w = 2000, z = 10, c = 0, map = 1419, x = 0.5, y = 0.5 }
function UnitPosition() return _POS.n, _POS.w, _POS.z, _POS.c end
C_Map = {
	GetBestMapForUnit = function() return _POS.map end,
	GetMapPosFromWorldPos = function(c, v, map)
		return map, { x = v.x / 4000 + 0.5, y = v.y / 4000 + 0.5 }
	end,
	GetWorldPosFromMapPos = function(map, v)
		return 0, { x = (v.x - 0.5) * 4000, y = (v.y - 0.5) * 4000 }
	end,
	GetMapInfo = function(m) return { name = "Sim Zone " .. m } end,
}
UiMapPoint = {
	CreateFromCoordinates = function(m, x, y)
		return { map = m, x = x, y = y }
	end,
}
_WP = nil
C_Map.SetUserWaypoint = function(p) _WP = p return true end
C_Map.GetUserWaypoint = function() return _WP end
C_Map.ClearUserWaypoint = function() _WP = nil return true end
C_Map.CanSetUserWaypointOnMap = function() return true end
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
function CreateVector2D(x, y) return { x = x, y = y } end

function GetSpellInfo(id)
	return ({ [2383] = "Herb Gathering", [2580] = "Mining",
		[8613] = "Skinning" })[id]
end

-- controllable loot window
_LOOT = {}   -- { {name, qty, link} }
function SetLoot(rows) _LOOT = rows end
function GetNumLootItems() return #_LOOT end
function GetLootSlotInfo(i)
	local r = _LOOT[i]
	return nil, r.name, r.qty
end
function GetLootSlotLink(i)
	return _LOOT[i].link
end

-- prices: GM.Price in copper; the eval stub returns 10000 (1g) per
-- item unless overridden
PRICES = {}
GM.Price = function(_, id) return PRICES[id] or 10000 end
GM.MoneyShort = function(c) return tostring(math.floor(c / 10000)) .. "g" end
GM.ItemName = function(id)
	local e = ITEM_DB[id] or {}
	return e.name
end
-- command API lives in Core.lua, which this harness doesn't load
GM.CMDS = {}
GM.Cmd = function() end
''')

# map art + item icons for the window pane
lua.execute(r'''
C_Map.GetMapArtLayers = function(m)
	return { { layerWidth = 1002, layerHeight = 668,
	           tileWidth = 256, tileHeight = 256 } }
end
C_Map.GetMapArtLayerTextures = function(m, li)
	if li ~= 1 then return nil end
	return { 1001, 1002, 1003, 1004, 1005, 1006,
	         1007, 1008, 1009, 1010, 1011, 1012 }
end
function GetItemIcon(id) return 40000 + id end
''')

# load Gather.lua with the addon vararg contract
src = open('addons/GoblinMind/Gather.lua', encoding='utf-8').read()
chunk = g.load(src, '@Gather.lua')
chunk('GoblinMind', g.GM)

# GatherMap for the window-pane checks
src = open('addons/GoblinMind/GatherMap.lua', encoding='utf-8').read()
chunk = g.load(src, '@GatherMap.lua')
chunk('GoblinMind', g.GM)

G = g.GM.Gather
ev = lambda e, *a: g.fire_event(e, *a)

print('== cast->loot attribution: herb node ==')

# gather cast at (1000,2000) then a herb loot window
lua.execute('''
_POS.n, _POS.w = 1000, 2000
_NAME = "Silverleaf"
SetLoot({ { name = "Silverleaf", qty = 2,
            link = "|Hitem:765::::::::|h[Silverleaf]|h" } })
''')
ev('UNIT_SPELLCAST_SUCCEEDED', 'player', 'c1', 2383)
ev('LOOT_OPENED')

nodes = g.GoblinMindGather.nodes[1419]
check('node recorded on map', nodes is not None and len(nodes) == 1)
nd = nodes[1]
check('kind=herb', nd.kind == 'herb')
check('position stored', nd.n == 1000 and nd.w == 2000)
check('hits=1', nd.hits == 1)

# yield learned under the loot source name (target name is _NAME)
lua.execute('_NAME = "Silverleaf"')
y = g.GoblinMindGather.yields and g.GoblinMindGather.yields['Silverleaf']
check('yield recorded', y is not None and y['items'][765] == 2 and y.cnt == 1)

print('== merge + respawn learn ==')
# same node again 600s later, slightly offset — merges, learns bound
lua.execute('_NOW.t = _NOW.t + 600; _POS.n = 1005; _POS.w = 2005')
ev('UNIT_SPELLCAST_SUCCEEDED', 'player', 'c2', 2383)
lua.execute('_NAME = "Silverleaf"')
ev('LOOT_OPENED')
check('merged (still 1 node)', len(g.GoblinMindGather.nodes[1419]) == 1)
check('hits=2', g.GoblinMindGather.nodes[1419][1].hits == 2)
resp = G.RespawnSec(1419, 'herb')
check('respawn bound learned (<=600)', resp and resp <= 600)

print('== far node is a new spawn point ==')
lua.execute('_POS.n = 1500; _POS.w = 2000')
ev('UNIT_SPELLCAST_SUCCEEDED', 'player', 'c3', 2383)
lua.execute('''
SetLoot({ { name = "Peacebloom", qty = 3,
            link = "|Hitem:2447::::::::|h[Peacebloom]|h" } })
_NAME = "Peacebloom"
''')
ev('LOOT_OPENED')
check('second node recorded', len(g.GoblinMindGather.nodes[1419]) == 2)

print('== cloth kill zones ==')
lua.execute('_POS.n, _POS.w = 1000, 1500')
lua.execute('''
SetLoot({ { name = "Linen Cloth", qty = 2,
            link = "|Hitem:2589::::::::|h[Linen Cloth]|h" },
          { name = "Malachite", qty = 1,
            link = "|Hitem:774::::::::|h[Malachite]|h" } })
''')
ev('LOOT_OPENED')
zs = g.GoblinMindGather.zones and g.GoblinMindGather.zones[1419]
check('cloth zone created', zs is not None and len(zs) == 1)
zn = zs[1]
check('zone kind=hunt', zn.kind == 'hunt')
check('zone kills=1', zn.kills == 1)
check('zone yield has cloth', zn['items'][2589] == 2)

# second cloth kill nearby within ACTIVE_GAP merges + accrues time
lua.execute('_NOW.t = _NOW.t + 30; _POS.n, _POS.w = 1010, 1510')
lua.execute('''
SetLoot({ { name = "Linen Cloth", qty = 3,
            link = "|Hitem:2589::::::::|h[Linen Cloth]|h" } })
''')
ev('LOOT_OPENED')
check('zone merged (still 1)', len(g.GoblinMindGather.zones[1419]) == 1)
zn = g.GoblinMindGather.zones[1419][1]
check('kills=2', zn.kills == 2)
check('activeT accrued', (zn.activeT or 0) >= 30)
check('cloth qty summed (2+3)', zn['items'][2589] == 5)

# meat kill: any non-gather loot builds the hunt zone + a per-mob
# yield record — raptor flesh is a cooking drop, not cloth
lua.execute('_POS.n, _POS.w = 1020, 1520')
lua.execute('''
_NAME = "Young Raptor"
SetLoot({ { name = "Raptor Flesh", qty = 1,
            link = "|Hitem:12184::::::::|h[Raptor Flesh]|h" } })
''')
ev('LOOT_OPENED')
check('meat kill merged into same zone',
      len(g.GoblinMindGather.zones[1419]) == 1)
zn = g.GoblinMindGather.zones[1419][1]
check('flesh on zone yield', zn['items'][12184] == 1)
yh = g.GoblinMindGather.yields['hunt:Young Raptor']
check('per-mob hunt record', yh is not None and yh['items'][12184] == 1)

print('== spawn pockets / capacity / contention ==')
# a second kill 100yd away = a new mob spawn pocket
lua.execute('_NOW.t = _NOW.t + 30; _POS.n, _POS.w = 1100, 1500')
lua.execute('''
_NAME = "Young Raptor"
SetLoot({ { name = "Raptor Flesh", qty = 1,
            link = "|Hitem:12184::::::::|h[Raptor Flesh]|h" } })
''')
ev('LOOT_OPENED')
zn = g.GoblinMindGather.zones[1419][1]
check('second pocket created',
      zn.pockets is not None and len(zn.pockets) == 2)

# re-kill the same pocket 200s later — mob was back, so respawn
# is bounded at <=200s (gap > ACTIVE_GAP so no activeT accrual)
lua.execute('_NOW.t = _NOW.t + 200; _POS.n, _POS.w = 1100, 1505')
lua.execute('''
SetLoot({ { name = "Raptor Flesh", qty = 1,
            link = "|Hitem:12184::::::::|h[Raptor Flesh]|h" } })
''')
ev('LOOT_OPENED')
zn = g.GoblinMindGather.zones[1419][1]
check('respawn learned from rekill', zn.resp == 200)

# capacity = 2 pockets * 60s/200s = 0.6 kills/min — far under the
# measured ~3.3/min grinding rate, so sustained uses the cap
cap = G.ZoneCapacity(zn)
check('capacity = 0.6/min', cap is not None
      and abs(cap - 0.6) < 0.01)
sus = G.ZoneSusRate(zn)
check('sustained rate = capacity', abs(sus - 0.6) < 0.01)

# sustained EV drops one-shot items (malachite: 1 hit of 1 qty)
ev_sus = G.ZoneSusEV(zn)
ev_raw = G.ZoneEV(zn)
check('common EV < raw EV', ev_sus < ev_raw)

# contention selector derates the cap, not the measured rate
lua.execute('GoblinMindGather.contIx = 2')
sus2 = G.ZoneSusRate(zn)
check('shared contention = 60%', abs(sus2 - 0.36) < 0.01)
lua.execute('GoblinMindGather.contIx = 1')

# leaderboard rows carry the diff: gpm (sustained) vs gpmRaw
row = None
for r in G.Leaderboard().values():
    if r.area and r.zoneName == G.ZoneName(1419) \
            and r.kills == zn.kills:
        row = r
check('zone row has spawns', row is not None and row.spawns == 2)
check('row gpm is sustained', row is not None
      and row.gpm < row.gpmRaw)

print('== failed farm: empty corpse counts ==')
# a money-only / empty loot window on a dead target is a kill that
# dropped nothing — must dilute cnt or EV only sees winners
k0 = zn.kills
lua.execute('_NOW.t = _NOW.t + 5; _POS.n, _POS.w = 1100, 1505')
lua.execute('_NAME = "Young Raptor"; SetLoot({})')
ev('LOOT_OPENED')
zn = g.GoblinMindGather.zones[1419][1]
check('empty corpse counted as kill', zn.kills == k0 + 1)
check('items unchanged by empty loot',
      zn['items'][12184] == 3 and zn.cnt == k0 + 1)
check('zone tracks mob names',
      zn.mobs['Young Raptor'] == 4 and zn.mobs['Peacebloom'] == 2)
check('mob label sorts by kills',
      G.ZoneMobs(zn) == 'Young Raptor ×4 · Peacebloom ×2')

print('== target-relative EV ==')
# with raptor flesh targeted the row shows flesh-per-kill, not the
# whole loot table: 3 drops over 6 kills x 1g = 0.5g/kill
G.SetTarget(12184)
row = None
for r in G.Leaderboard().values():
    if r.area and r.zoneName == G.ZoneName(1419) \
            and r.kills == zn.kills:
        row = r
check('target EV = qty/cnt x price', row is not None
      and abs(row.evLoop - 5000) < 1)
check('target gpm = ev x sustained', row is not None
      and abs(row.gpm - 3000) < 1)
G.SetTarget(None)

print('== skinning -> skin zone ==')
lua.execute('_POS.n, _POS.w = 500, 500')
lua.execute('''
SetLoot({ { name = "Light Leather", qty = 2,
            link = "|Hitem:2318::::::::|h[Light Leather]|h" } })
_NAME = "Young Wolf"
''')
ev('UNIT_SPELLCAST_SUCCEEDED', 'player', 'c4', 8613)
ev('LOOT_OPENED')
zs = g.GoblinMindGather.zones[1419]
check('skin zone exists', any(z.kind == 'skin' for z in zs.values()))
y = g.GoblinMindGather.yields['skin']
check('skin yield recorded', y is not None and y['items'][2318] == 2)
y2 = g.GoblinMindGather.yields['skin:Young Wolf']
check('per-mob skin yield', y2 is not None and y2.cnt == 1)

print('== solver: dense pocket beats whole zone ==')
# build a fresh node set on a new map: a tight 4-node rich cluster
# and 4 far-apart poor nodes. Rich EV (10g) vs poor (1g): the whole-
# zone lap drags in travel the pocket doesn't pay.
lua.execute(r'''
GoblinMindGather.nodes[1420] = {
	{ map=1420, n=0,    w=0,    c=0, x=0.50, y=0.50, kind='mine',
		name='Rich Vein', hits=1 },
	{ map=1420, n=40,   w=0,    c=0, x=0.51, y=0.50, kind='mine',
		name='Rich Vein', hits=1 },
	{ map=1420, n=0,    w=40,   c=0, x=0.50, y=0.51, kind='mine',
		name='Rich Vein', hits=1 },
	{ map=1420, n=40,   w=40,   c=0, x=0.51, y=0.51, kind='mine',
		name='Rich Vein', hits=1 },
	{ map=1420, n=2000, w=0,    c=0, x=1.00, y=0.50, kind='mine',
		name='Poor Vein', hits=1 },
	{ map=1420, n=0,    w=2000, c=0, x=0.50, y=1.00, kind='mine',
		name='Poor Vein', hits=1 },
	{ map=1420, n=2000, w=2000, c=0, x=1.00, y=1.00, kind='mine',
		name='Poor Vein', hits=1 },
	{ map=1420, n=-2000,w=-2000,c=0, x=0.00, y=0.00, kind='mine',
		name='Poor Vein', hits=1 },
}
GoblinMindGather.yields = GoblinMindGather.yields or {}
GoblinMindGather.yields['Rich Vein'] = { items = { [9999] = 100 }, cnt = 1 }
GoblinMindGather.yields['Poor Vein'] = { items = { [8888] = 10 }, cnt = 1 }
PRICES[9999] = 10000   -- rich node ~1g/visit
PRICES[8888] = 10000   -- poor node ~0.1g/visit
GoblinMindGather.speedIx = 1   -- on foot: travel costs hurt most
-- fast respawn regime: nodes are back before the lap finishes, so
-- extra travel is pure cost and the dense pocket should win
GoblinMindGather.resp = { [1420] = { mine = 300 } }
''')
r = G.SolveRoute(1420, 'mine')
check('route solved', r is not None)
if r:
    names = set(s.name for s in r.stops.values())
    check('winner is the rich pocket only',
          names == {'Rich Vein'} and len(r.stops) == 4)
    check('gpm positive', r.gpm > 0)
    check('lapSec modeled', r.lapSec and r.lapSec > 0)
    check('stops are node refs', r.stops[1].kind == 'mine')

print('== solver: slow respawn -> bigger loop wins ==')
# the model's other branch: when respawn >> lap, re-hitting the same
# few nodes is wasted travel — the solver should pull in more unique
# stops instead
lua.execute('GoblinMindGather.resp[1420] = { mine = 3600 }')
r2 = G.SolveRoute(1420, 'mine')
check('slower respawn widens the route',
      r2 is not None and len(r2.stops) > len(r.stops))

print('== solver: respawn saturation discounts fast laps ==')
# same map, respawn >> lap: effective GPM must sit well below the
# naive unsaturated ev*60/lap, and below the fast-respawn figure.
# evLoop is already avail-discounted, so raw EV comes from the
# injected yields: Rich=100qty×1g, Poor=10qty×1g per stop
if r2:
    raw_ev = sum(
        1_000_000 if s.name == 'Rich Vein' else 100_000
        for s in r2.stops.values())
    naive = raw_ev * 60 / r2.lapSec
    check('saturation applied (gpm < naive)', r2.gpm < naive * 0.9)
check('longer respawn lowers gpm', r2.gpm < r.gpm)

print('== leaderboard ==')
rows = G.Leaderboard()
check('rows returned', rows is not None and len(rows) > 0)
check('sorted by gpm', all(
    (lua.table_from(rows)[i].gpm >= lua.table_from(rows)[i + 1].gpm)
    for i in range(1, len(rows))))
row0 = lua.table_from(rows)[1]
check('best row first has gpm', row0.gpm > 0)

print('== window pane: art + clustered icons + route ==')
M = g.GM.GatherMap
parent = g.CreateFrame('Frame')
pane = M.CreatePane(parent, 400)
pane.SetData(pane, 1420, r)
kinds = [e[1] for e in pane.live.values()]
check('map art tiled', kinds.count('tile') == 12)
check('pane sized to art aspect',
      abs(pane.GetHeight(pane) - 267) <= 1)
icons = [e[2] for e in pane.live.values() if e[1] == 'icon']
check('clusters drawn as icons', len(icons) == 5)
# icon texture = GetItemIcon(best yield item): rich cluster -> 9999
texs = set(ic._tex for ic in icons)
check('item icon on clustered node', 49999 in texs)
check('poor vein icon too', 48888 in texs)
# size scales with group: find the big one
szs = sorted(ic._w for ic in icons)
check('group size scales icon', szs[-1] > szs[0])
# exactly one cluster carries a count badge of 4
lbls = [e[2] for e in pane.live.values() if e[1] == 'lbl']
check('group badge shows count',
      any(l._text == '4' for l in lbls))
check('route polyline drawn',
      kinds.count('line') == 4)

print('== window pane: hunt-zone disc + icon ==')
pane.SetData(pane, 1419, None)
kinds = [e[1] for e in pane.live.values()]
check('zone discs drawn', kinds.count('disc') == 2)
icons = [e[2] for e in pane.live.values() if e[1] == 'icon']
texs = set(ic._tex for ic in icons)
check('cloth icon at zone center', 42589 in texs)
check('skin icon at zone center', 42318 in texs)
check('nodes still drawn on same map',
      kinds.count('icon') >= 4)

print('== target filter: producers stay bright ==')
G.SetTarget(9999)   # the ore only Rich Veins yield
check('target stored', G.TargetID() == 9999)
nodes1420 = g.GoblinMindGather.nodes[1420]
check('rich node produces target', G.NodeTargets(nodes1420[1]))
check('poor node does not', not G.NodeTargets(nodes1420[5]))
zn1419 = g.GoblinMindGather.zones[1419]
cloth = next(z for z in zn1419.values() if z.kind == 'hunt')
skin = next(z for z in zn1419.values() if z.kind == 'skin')
check('cloth zone does not produce', not G.ZoneTargets(cloth))
check('skin zone does not produce', not G.ZoneTargets(skin))
# row targeting: a zone row only passes if the zone produces
check('row filter honors target',
      not G.RowTargets(lua.table_from({'area': True, 'zone': cloth})))
G.SetTarget(2318)   # light leather: the skin zone's drop
check('skin zone produces leather', G.ZoneTargets(skin))
check('skin row passes',
      G.RowTargets(lua.table_from({'area': True, 'zone': skin})))

# pane dimming: target back on the ore
G.SetTarget(9999)
pane.SetData(pane, 1420, r)
icons = [e[2] for e in pane.live.values() if e[1] == 'icon']
bright = [ic for ic in icons if ic._col and ic._col[4] >= 1]
dim = [ic for ic in icons if ic._col and ic._col[4] < 1]
check('producer cluster stays bright',
      len(bright) == 1 and bright[0]._tex == 49999)
check('non-producers dimmed', len(dim) == 4)
check('non-producers shrunk',
      all(ic._w <= 10 for ic in dim))
# hunt-zone dimming: no zone produces ore on 1419
pane.SetData(pane, 1419, None)
discs = [e[2] for e in pane.live.values() if e[1] == 'disc']
check('non-producing zone discs faint',
      all(d._col[4] <= 0.06 for d in discs))
G.SetTarget(None)

print('== GatherLite import ==')
# stub the SV + the runtime API. Two personal mining points ~21yd
# apart (tighter than the 40yd live-merge, wider than the 8yd
# import dedup) must stay separate; a runtime predefined point and
# an exact-position dup exercise new/merged paths.
lua.execute('''
GatherLiteSettings = { global = { nodes = {
	mining = {
		{ type="mining", mapID=1421, posX=0.40, posY=0.60,
		  object=1731, loot={ { name="Copper Ore", count=2,
		    link="|Hitem:2770::::::::|h[Copper Ore]|h" } } },
		{ type="mining", mapID=1421, posX=0.41, posY=0.61,
		  object=1731, loot={ { name="Copper Ore", count=2,
		    link="|Hitem:2770::::::::|h[Copper Ore]|h" } } },
	},
	containers = {
		{ type="containers", mapID=1421, posX=0.5, posY=0.5,
		  object=106319 },
	},
} } }
GatherLite = {
	GetNodeObject = function(self, id)
		return ({ [1731] = { name = "copper_vein" },
		          [1735] = { name = "iron_deposit" } })[id]
	end,
	translate = function(self, key)
		return ({ ["node.copper_vein"] = "Copper Vein",
		          ["node.iron_deposit"] = "Iron Deposit" })[key]
			or key
	end,
	GetNodes = function(self) return {
		{ type="mining", mapID=1421, posX=0.80, posY=0.80,
		  object=1735, predefined=true },
		{ type="mining", mapID=1421, posX=0.40, posY=0.60,
		  object=1731 },
	} end,
}
''')
st = G.ImportGatherLite()
check('import returns stats', st is not None)
nodes1421 = g.GoblinMindGather.nodes[1421]
check('imported 3 nodes', nodes1421 is not None
      and len(nodes1421) == 3)
check('close spawns kept separate', len(nodes1421) == 3)
check('runtime dup merged', st.merged >= 1)
check('new count = 3', st.new == 3)
names = set(n.name for n in nodes1421.values())
check('locale names resolved',
      names == {'Copper Vein', 'Iron Deposit'})
check('import flag set', all(n.src == 'gl'
      for n in nodes1421.values()))
y = g.GoblinMindGather.yields['Copper Vein']
check('loot seeded yield',
      y is not None and y['items'][2770] == 4 and y.cnt == 2)
# re-import: prior imports wiped and rebuilt — count + mean stable
st2 = G.ImportGatherLite()
check('re-import wiped old', st2.wiped >= 2)
check('count stable after re-import',
      len(g.GoblinMindGather.nodes[1421]) == 3)
y = g.GoblinMindGather.yields['Copper Vein']
check('yield mean unchanged', y['items'][2770] / y.cnt == 2)

print()
fails = [n for n, ok in CHECKS if not ok]
if fails:
    print('%d FAILURES:' % len(fails))
    for f in fails:
        print('  -', f)
    sys.exit(1)
print('all %d checks passed' % len(CHECKS))
