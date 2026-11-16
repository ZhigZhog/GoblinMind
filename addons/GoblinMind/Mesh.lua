local _, GM = ...

-- Mesh feed (mesh-feed-proposal): diffs over addon comms, never
-- books. Every install joins a hidden custom channel; after a book
-- scan it broadcasts sale events (S) and changed-min-buyout beacons
-- (M). Received records are staged into GM.db.mesh for the brain —
-- beacons become remote books in the emit merge, events become
-- remote sale records. The seq/ack handshake mirrors bugReports:
-- the brain emits the max seq it consumed and we purge locally.

GM.Mesh = {}
local M = GM.Mesh

local PREFIX, CHANNEL = "GoblinMind", "goblinmindx"
local MAX_MSG = 240          -- wire cap is 255; leave header room
local SEND_GAP = 0.35        -- pace sends — addon comms are throttled
local STAGE_CAP = 400        -- staged records kept per list
local MAX_BCAST = 120        -- records per book broadcast (per kind)

-- raw tl bucket -> lower bound on seconds remaining (mirrors the
-- brain's TL_LOWER): gone while elapsed < bound = confident sale
local TL_LOWER = { 0, 1800, 7200, 43200, 172800 }

local Send = C_ChatInfo and C_ChatInfo.SendAddonMessage
	or SendAddonMessage
local RegPrefix = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix
local chanID, sendQ, pumping = 0, {}, false

-- ============ channel lifecycle ============

local function FindChannel()
	local _, _, id = GetChannelName(CHANNEL)
	return id
end

local function TryJoin(tries)
	chanID = FindChannel() or 0
	if chanID > 0 then return end
	JoinChannelByName(CHANNEL)
	chanID = FindChannel() or 0
	if chanID == 0 and tries < 5 then
		GM.After(5, function() TryJoin(tries + 1) end)
	end
end

-- ============ send path ============

local function Pump()
	if not pumping then return end
	if chanID == 0 then chanID = FindChannel() or 0 end
	local msg = tremove(sendQ, 1)
	if not msg then pumping = false return end
	if chanID > 0 then
		pcall(Send, PREFIX, msg, "CHANNEL", chanID)
	else
		tinsert(sendQ, 1, msg) -- channel lost — keep, retry next tick
	end
	GM.After(SEND_GAP, Pump)
end

local function Broadcast(recs, kind)
	-- header: proto | kind | scope — scope lets receivers fold into
	-- the right books_by_scope bucket on their side
	local scope = GM.Scope()
	local head = "1|" .. kind .. "|" .. scope .. "|"
	local buf = head
	for _, r in ipairs(recs) do
		if #buf + #r + 1 > MAX_MSG then
			sendQ[#sendQ + 1] = buf
			buf = head
		end
		buf = buf .. (#buf > #head and "," or "") .. r
	end
	if #buf > #head then sendQ[#sendQ + 1] = buf end
	if not pumping then pumping = true Pump() end
end

-- ============ broadcast source: book diffs ============

local TL_FP = "^(%d+):(%d+):(%d+):?(%w*)$"
local function Pref(fp)
	local a, b, c = fp:match(TL_FP)
	return a and (a .. ":" .. b .. ":" .. c) or fp, a, b, c
end

-- called by AH.Finish after bookLots/book are swapped in. Computes
-- the same prefix-diff the brain does on the server side — S events
-- for disappeared lots, M beacons for mb changes.
function M.OnBook(book, lots, prevBook, prevLots, prevT)
	if not (chanID > 0 or FindChannel()) then return end
	local now = time()
	local elapsed = math.max(0, now - (prevT or now))

	-- sale events — replicate scans only (browse carries no lots)
	if lots and prevLots then
		local newPref, oldPref, oldTlb = {}, {}, {}
		for fp, n in pairs(lots) do
			local p = Pref(fp)
			newPref[p] = (newPref[p] or 0) + n
		end
		for fp, n in pairs(prevLots) do
			local p = Pref(fp)
			local t = fp:match("^%d+:%d+:%d+:(%w+)$")
			oldPref[p] = (oldPref[p] or 0) + n
			local l = oldTlb[p]
			if not l then l = {} oldTlb[p] = l end
			l[#l + 1] = t
		end
		local ev = {}
		for p, on in pairs(oldPref) do
			local gone = on - (newPref[p] or 0)
			if gone > 0 then
				local iid, qty, unit = p:match(TL_FP)
				iid, qty, unit = tonumber(iid), tonumber(qty),
					tonumber(unit)
				local cls = "u"
				local minL
				for _, t in ipairs(oldTlb[p] or {}) do
					local b = tonumber(t)
					if b and TL_LOWER[b + 1] then
						if not minL or TL_LOWER[b + 1] < minL then
							minL = TL_LOWER[b + 1]
						end
					end
				end
				if minL then cls = elapsed < minL and "s" or "i" end
				if iid and qty and unit then
					ev[#ev + 1] = { i = iid, u = qty * gone, p = unit,
						l = gone, c = cls,
						w = qty * gone * unit }
				end
			end
		end
		table.sort(ev, function(a, b) return a.w > b.w end)
		local recs = {}
		for i = 1, math.min(#ev, MAX_BCAST) do
			local e = ev[i]
			recs[i] = e.i .. ":" .. e.u .. ":" .. e.p
				.. ":" .. e.c .. ":" .. e.l
		end
		if #recs > 0 then Broadcast(recs, "S") end
	end

	-- mb beacons — items whose min-buyout moved since the last book
	if book and prevBook then
		local ch = {}
		for id, e in pairs(book) do
			local o = prevBook[id]
			if e.mb and (not o or o.mb ~= e.mb) then
				ch[#ch + 1] = { i = id, m = e.mb, s = e.sup or 0,
					w = math.abs(e.mb - (o and o.mb or 0)) }
			end
		end
		table.sort(ch, function(a, b) return a.w > b.w end)
		local recs = {}
		for i = 1, math.min(#ch, MAX_BCAST) do
			local c = ch[i]
			recs[i] = c.i .. ":" .. c.m .. ":" .. c.s
		end
		if #recs > 0 then Broadcast(recs, "M") end
	end
end

-- ============ receive path ============

local me
local function Stage(list, cap, rec)
	local st = GM.db.mesh[list]
	st[#st + 1] = rec
	GM.db.mesh.seq = (GM.db.mesh.seq or 0) + 1
	rec.q = GM.db.mesh.seq
	while #st > cap do tremove(st, 1) end
end

local function OnAddon(_, prefix, msg, ctype, sender)
	if prefix ~= PREFIX or ctype ~= "CHANNEL" then return end
	if not me then me = UnitName("player") end
	if sender and sender:match("^[^-]+") == me then return end -- own echo
	if not GM.db then return end
	GM.db.mesh = GM.db.mesh or { ev = {}, mb = {}, seq = 0 }
	local proto, kind, scope, body = msg:match(
		"^(%d+)|(%u+)|([^|]*)|?(.*)$")
	if proto ~= "1" or not body then return end
	local t = time()
	if kind == "S" then
		for rec in body:gmatch("[^,]+") do
			local i, u, p, c, l = rec:match(
				"^(%d+):(%d+):(%d+):(%a):(%d+)$")
			if i and u and p and tonumber(p) > 0
				and tonumber(p) < 1e12 then
				Stage("ev", STAGE_CAP, { t = t, s = scope,
					i = tonumber(i), u = tonumber(u),
					p = tonumber(p), l = tonumber(l) or 1,
					c = c })
			end
		end
	elseif kind == "M" then
		for rec in body:gmatch("[^,]+") do
			local i, m, s = rec:match("^(%d+):(%d+):(%d+)$")
			if i and m and tonumber(m) > 0
				and tonumber(m) < 1e12 then
				Stage("mb", STAGE_CAP, { t = t, s = scope,
					i = tonumber(i), m = tonumber(m),
					q = tonumber(s) or 0 })
			end
		end
	end
end

-- test injector — stages a fake wire sale event + beacon without
-- comms, so the staging->brain-consume->emit path can be verified
-- solo (/run GoblinMind.Mesh.Test()). Own echoes are dropped by
-- design, so a real second sender is needed for CHAT_MSG_ADDON.
function M.Test()
	GM.db.mesh = GM.db.mesh or { ev = {}, mb = {}, seq = 0 }
	Stage("ev", STAGE_CAP, { t = time(), s = GM.Scope(),
		i = 2318, u = 40, p = 420, l = 2, c = "s" })
	Stage("mb", STAGE_CAP, { t = time(), s = GM.Scope(),
		i = 2589, m = 2500, q = 500 })
	GM.Print("mesh: staged test event + beacon — reload to flush SV")
end

-- ============ consume handshake + boot ============

-- the brain emits meshAck = max consumed seq; purge staged records
-- it has already folded into sales/books
function M.Purge()
	local st = GM.db and GM.db.mesh
	local ack = GoblinMindDB and GoblinMindDB.meshAck
	if not (st and ack) then return end
	for _, key in ipairs({ "ev", "mb" }) do
		local l = st[key]
		for i = #l, 1, -1 do
			if (l[i].q or 0) <= ack then tremove(l, i) end
		end
	end
end

local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "CHAT_MSG_ADDON")
pcall(f.RegisterEvent, f, "PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, ev, ...)
	if ev == "CHAT_MSG_ADDON" then
		OnAddon(nil, ...)
	elseif ev == "PLAYER_LOGIN" then
		if RegPrefix then pcall(RegPrefix, PREFIX) end
		GM.After(4, function() TryJoin(0) end)
		GM.After(8, M.Purge)
	end
end)
