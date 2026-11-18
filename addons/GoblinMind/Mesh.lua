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
M.stats = { sent = 0, heard = 0, lastSend = nil, lastHear = nil }

-- ============ channel lifecycle ============

local function FindChannel()
	-- first return is the channel number; return 3 is the
	-- INSTANCE id (0 in the world) — reading it as the channel
	-- id left the join state at "not joined" forever
	local id = GetChannelName(CHANNEL)
	return tonumber(id) or 0
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
		local ok, sent = pcall(Send, PREFIX, msg, "CHANNEL", chanID)
		if ok and sent ~= false then
			M.stats.sent = M.stats.sent + 1
			M.stats.lastSend = time()
		end
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

-- newest staged mb beacon for itemID on our scope — the read side of
-- the mesh for ItemEntry's observation overlay: a beacon fresher than
-- the local book AND the emit is the freshest min-buyout we know
function M.LatestMB(itemID)
	local st = GM.db and GM.db.mesh and GM.db.mesh.mb
	if not st then return end
	local scope = GM.Scope()
	for i = #st, 1, -1 do
		local r = st[i]
		if r.i == itemID and (not r.s or r.s == scope) then return r end
	end
end

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
	M.stats.heard = M.stats.heard + 1
	M.stats.lastHear = t
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
				-- supply rides as sup — Stage stamps q with the seq
				Stage("mb", STAGE_CAP, { t = t, s = scope,
					i = tonumber(i), m = tonumber(m),
					sup = tonumber(s) or 0 })
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
		i = 2589, m = 2500, sup = 500 })
	GM.Print("mesh: staged test event + beacon — reload to flush SV")
end

-- ============ status ============

local function Ago(t)
	if not t then return "never" end
	local s = time() - t
	if s < 90 then return s .. "s ago" end
	if s < 5400 then return format("%dm ago", s / 60) end
	if s < 129600 then return format("%dh ago", s / 3600) end
	return ">36h ago"
end

function M.Status()
	local db = GoblinMindDB or {}
	local ch = chanID > 0 and chanID or (FindChannel() or 0)
	local st = GM.db and GM.db.mesh or {}
	local nScopes = 0
	for _ in pairs(db.realms or {}) do nScopes = nScopes + 1 end
	GM.Print(format("feed: %s · DB %s · %d scopes",
		db.feed or "?", Ago(db.generated), nScopes))
	GM.Print(format("mesh: %s · sent %d (%s) · heard %d (%s) · staged %d ev / %d mb · seq %d · ack %s",
		ch > 0 and ("joined " .. CHANNEL .. " (ch " .. ch .. ")")
			or "not joined",
		M.stats.sent, Ago(M.stats.lastSend),
		M.stats.heard, Ago(M.stats.lastHear),
		st.ev and #st.ev or 0, st.mb and #st.mb or 0,
		st.seq or 0, tostring(db.meshAck or "—")))
	local be = db.backend or {}
	GM.Print(format("backend: %s%supload %s%s · pull %s%s · %d install%s",
		be.url and (be.url .. " · ") or "",
		(not be.url and not be.pull and not be.up and not be.peers)
			and "not configured (/goblin backend) — " or "",
		Ago(be.up and be.up.t),
		be.up and (be.up.ok and "" or " (failed)") or "",
		Ago(be.pull and be.pull.t),
		be.pull and (be.pull.ok and "" or " (failed)") or "",
		be.peers or 0, be.peers == 1 and "" or "s"))
	-- staged work waiting on the companion app — reports, connect
	-- and api requests queue in the SV until the watcher consumes them
	local q = 0
	for _, k in ipairs({ "bugReports", "backendReqs", "apiReqs" }) do
		local l = GM.db and GM.db[k]
		if l then q = q + #l end
	end
	if q > 0 then
		local age = GM.EmitAge and GM.EmitAge()
		GM.Print(format("queued: %d request%s/report%s — %s",
			q, q == 1 and "" or "s", q == 1 and "" or "s",
			(age and age <= 900)
				and "the companion app picks them up next cycle"
				or GM.CC("warn") .. "no companion app seen — start "
					.. "it from the app page (/goblin backend)|r"))
	end
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
