local _, GM = ...

-- Live drop-rate capture: loot windows are attributed per SLOT to a
-- source GUID (shared taps can mix sources in one window, so the
-- window itself is never the unit of attribution). Rates mature in
-- SavedVariables — see WoWVault/Proposals/drop-rates-proposal.md.
--
-- Store shape:
--   GM.db.drops[itemID][srcKey]  = { k = windows containing item,
--                                   q = total qty }
--   GM.db.dropsN[srcKey]         = windows seen from that source
--   GM.db.dropsName[srcKey]      = display name (hit-sources only)
--
-- srcKey = "c<npcID>" | "o<objectID>" | "i<itemID>" — creature,
-- game object (nodes/chests/fishing), or container item.
--
-- Denominator caveat: dropsN counts windows with >=1 attributable
-- item slot. A window that yields nothing readable (money-only or
-- already-empty corpse) can't be attributed — rates are measured
-- per yielding window, not per kill. Rates rank sources against
-- each other under the same convention, which is all the tooltip
-- needs.

GM.Drops = {}
local D = GM.Drops

local MAX_SOURCES = 5      -- stored sources per item
local DISPLAY_FLOOR = 20   -- windows needed before a source ranks
local APPROX_FLOOR = 50    -- below this the tooltip marks ~

local PREFIX = { Creature = "c", Vehicle = "c", GameObject = "o",
	Item = "i" }

local function SrcKey(guid)
	if not guid then return end
	local t, _, _, _, _, id = strsplit("-", guid)
	-- modern GUID: Type-0-server-inst-zoneUID-unitID-spawnUID —
	-- field 6 is the type's numeric id for every mapped prefix
	local p = PREFIX[t]
	if p and id then return p .. id end
end

local function ItemOfLink(link)
	if type(link) ~= "string" then return end
	return tonumber(link:match("item:(%d+)"))
		or (GetItemInfoInstant and GetItemInfoInstant(link))
end

-- keep a src map to MAX_SOURCES entries by hit count; called after
-- every write so the SV stays bounded
local function PruneItem(map)
	local n = 0
	for _ in pairs(map) do n = n + 1 end
	if n <= MAX_SOURCES then return end
	local ranked = {}
	for src, st in pairs(map) do
		tinsert(ranked, { src = src, k = st.k or 0 })
	end
	table.sort(ranked, function(a, b) return a.k > b.k end)
	for i = MAX_SOURCES + 1, #ranked do
		map[ranked[i].src] = nil
	end
end

local function Record()
	if not GM.db then return end
	if not (GetNumLootItems and GetLootSlotInfo and GetLootSourceInfo) then
		return
	end
	local n = GetNumLootItems()
	if not n or n < 1 then return end

	-- per-window aggregates: one window counts once per source (k)
	-- even when the item arrives across several slots
	local winSrc, hits = {}, {}
	for i = 1, n do
		local _, link, qty = GetLootSlotInfo(i)
		local id = ItemOfLink(link)
		-- first source GUID only; handles both varargs and
		-- table-returning client flavors
		local g = GetLootSourceInfo(i)
		if type(g) == "table" then g = g[1] end
		local src = SrcKey(g)
		if id and src then
			winSrc[src] = true
			local h = hits[id]
			if not h then
				h = { qty = 0, srcs = {} }
				hits[id] = h
			end
			h.qty = h.qty + (tonumber(qty) or 1)
			h.srcs[src] = true
		end
	end

	if not next(winSrc) then return end
	GM.db.drops = GM.db.drops or {}
	GM.db.dropsN = GM.db.dropsN or {}
	GM.db.dropsName = GM.db.dropsName or {}

	for src in pairs(winSrc) do
		GM.db.dropsN[src] = (GM.db.dropsN[src] or 0) + 1
	end

	-- creature/object names aren't in the GUID — best-effort from
	-- the loot target; only needed for sources that produce hits
	local tgt = UnitName and (UnitName("target") or UnitName("mouseover"))

	for id, h in pairs(hits) do
		local m = GM.db.drops[id]
		if not m then m = {} GM.db.drops[id] = m end
		for src in pairs(h.srcs) do
			local st = m[src]
			if not st then st = { k = 0, q = 0 } m[src] = st end
			st.k = st.k + 1
			st.q = st.q + h.qty
			if tgt and not GM.db.dropsName[src]
				and src:sub(1, 1) ~= "i" then
				GM.db.dropsName[src] = tgt
			end
		end
		PruneItem(m)
	end
end

-- ranked sources for a tooltip: { {src, name, rate, k, n, q, low} }
-- only sources past the observation floor rank
function D.TopSources(itemID, count)
	local m = GM.db and GM.db.drops and GM.db.drops[itemID]
	if not m then return end
	local out = {}
	for src, st in pairs(m) do
		local n0 = GM.db.dropsN and GM.db.dropsN[src] or 0
		if n0 >= DISPLAY_FLOOR and st.k and st.k > 0 then
			tinsert(out, {
				src = src,
				name = GM.db.dropsName and GM.db.dropsName[src],
				rate = st.k / n0,
				k = st.k, q = st.q, n = n0,
				low = n0 < APPROX_FLOOR,
			})
		end
	end
	if #out == 0 then return end
	table.sort(out, function(a, b) return a.rate > b.rate end)
	while #out > (count or 3) do tremove(out) end
	return out
end

local f = CreateFrame("Frame")
-- LOOT_READY is the modern event; fall back to LOOT_OPENED if this
-- client only knows the old name (pcall: unknown events error)
if not pcall(f.RegisterEvent, f, "LOOT_READY") then
	pcall(f.RegisterEvent, f, "LOOT_OPENED")
end
f:SetScript("OnEvent", function()
	local ok, err = pcall(Record)
	if not ok then GM.Print(GM.CC("err") .. "drop capture: " ..
		tostring(err):sub(1, 80) .. "|r") end
end)
