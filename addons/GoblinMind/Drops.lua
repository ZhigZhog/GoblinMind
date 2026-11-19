local _, GM = ...

-- Live drop-rate capture: loot windows attribute to a source per
-- slot when the modern API exists (GetLootSourceInfo), else per
-- window via the loot target — this client ships the old surface.
-- Rates mature in SavedVariables — see
-- WoWVault/Proposals/drop-rates-proposal.md.
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

-- per-slot GUID attribution when the modern API exists; this client
-- ships the old loot surface instead (GetLootSlotLink, name at slot
-- pos 2, no GetLootSourceInfo), so the fallback attributes the whole
-- window to the loot target — GUID-parseable unit -> c/o/i key,
-- else name-keyed "n<name>" (merges same-named mobs/objects, which
-- is also the display granularity)
local function WinSource()
	for _, unit in ipairs({ "target", "mouseover" }) do
		local g = UnitGUID and UnitGUID(unit)
		local k = g and SrcKey(g)
		if k then return k, UnitName(unit) end
		local nm = UnitName and UnitName(unit)
		if nm then return "n" .. nm, nm end
	end
end

local function SlotSource(i)
	if not GetLootSourceInfo then return end
	local g = GetLootSourceInfo(i)
	if type(g) == "table" then g = g[1] end
	return SrcKey(g)
end

local lastLoot -- { sig, t } — LOOT_READY+LOOT_OPENED double-fire guard

local function Record()
	if not GM.db then return end
	if not (GetNumLootItems and GetLootSlotInfo) then return end
	local n = GetNumLootItems()
	if not n or n < 1 then return end

	local winSrc, winName = WinSource()
	local hits, firstID = {}, nil
	for i = 1, n do
		-- slot 2 is the item NAME on this client, not a link
		local _, lName, lQty, _, _, _, isQuest = GetLootSlotInfo(i)
		local link = GetLootSlotLink and GetLootSlotLink(i) or lName
		local id = ItemOfLink(link) or ItemOfLink(lName)
		local src = SlotSource(i) or winSrc
		if id and src and not isQuest then
			firstID = firstID or id
			local h = hits[id]
			if not h then
				h = { qty = 0, srcs = {} }
				hits[id] = h
			end
			h.qty = h.qty + (tonumber(lQty) or 1)
			h.srcs[src] = true
		end
	end
	if not firstID then return end

	-- dedup: same window reported by both loot events (or a re-open
	-- within the same instant) records once
	local t = GetTime and GetTime() or 0
	local sig = n .. ":" .. firstID
	if lastLoot and lastLoot.sig == sig and t - lastLoot.t < 0.5 then
		return
	end
	lastLoot = { sig = sig, t = t }

	local winSrcSet = {}
	for _, h in pairs(hits) do
		for src in pairs(h.srcs) do winSrcSet[src] = true end
	end

	GM.db.drops = GM.db.drops or {}
	GM.db.dropsN = GM.db.dropsN or {}
	GM.db.dropsName = GM.db.dropsName or {}

	for src in pairs(winSrcSet) do
		GM.db.dropsN[src] = (GM.db.dropsN[src] or 0) + 1
		-- name-keyed sources carry the name in the key; GUID-keyed
		-- get the best-effort target name (hit-sources only)
		if not GM.db.dropsName[src] then
			if src:sub(1, 1) == "n" then
				GM.db.dropsName[src] = src:sub(2)
			elseif winName and src:sub(1, 1) ~= "i" then
				GM.db.dropsName[src] = winName
			end
		end
	end

	for id, h in pairs(hits) do
		local m = GM.db.drops[id]
		if not m then m = {} GM.db.drops[id] = m end
		for src in pairs(h.srcs) do
			local st = m[src]
			if not st then st = { k = 0, q = 0 } m[src] = st end
			st.k = st.k + 1
			st.q = st.q + h.qty
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
-- this client fires LOOT_OPENED (GatherLite et al); LOOT_READY is
-- the modern twin — register both and dedup inside Record
pcall(f.RegisterEvent, f, "LOOT_OPENED")
pcall(f.RegisterEvent, f, "LOOT_READY")
f:SetScript("OnEvent", function()
	local ok, err = pcall(Record)
	if not ok then GM.Print(GM.CC("err") .. "drop capture: " ..
		tostring(err):sub(1, 80) .. "|r") end
end)
