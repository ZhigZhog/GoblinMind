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

local PREFIX = "GoblinMind"
local CH_A, CH_B = "goblinmindx", "goblinwritx"
-- v2 channel split: market diffs (S/M) and writ traffic ride
-- separate buses. Writ records are rare but heavy — a 50-message
-- snapshot stream must never starve a sale hint, and vice versa.
local WRIT_KINDS = { T=1, D=1, Q=1, F=1, P=1, N=1, W=1, w=1, Z=1,
                     I=1, i=1, O=1 }
local function ChanFor(kind)
	return WRIT_KINDS[kind] and CH_B or CH_A
end
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
local chanID, sendQ, pumping = {}, {}, false
M.stats = { sent = 0, heard = 0, lastSend = nil, lastHear = nil }

-- ============ channel lifecycle ============

local function FindChannel(name)
	-- first return is the channel number; return 3 is the
	-- INSTANCE id (0 in the world) — reading it as the channel
	-- id left the join state at "not joined" forever
	local id = GetChannelName(name)
	return tonumber(id) or 0
end

local function ChanID(name)
	local id = chanID[name]
	if not id or id == 0 then
		id = FindChannel(name)
		chanID[name] = id
	end
	return id or 0
end

local function TryJoin(tries)
	local missing = false
	for _, ch in ipairs({ CH_A, CH_B }) do
		if ChanID(ch) == 0 then
			JoinChannelByName(ch)
			if ChanID(ch) == 0 then missing = true end
		end
	end
	if missing and tries < 5 then
		GM.After(5, function() TryJoin(tries + 1) end)
	end
end

-- ============ send path ============

local function Pump()
	if not pumping then return end
	local msg = tremove(sendQ, 1)
	if not msg then pumping = false return end
	if type(msg) == "table" and msg.target then
		-- whisper transport — the relay tunnel rides directed
		-- comms to a specific peer, not the shared channel
		local ok, sent = pcall(Send, PREFIX, msg.msg, "WHISPER",
			msg.target)
		if ok and sent ~= false then
			M.stats.sent = M.stats.sent + 1
			M.stats.lastSend = time()
		end
	elseif type(msg) == "table" then
		-- channel send — msg.pred is a dequeue-time suppression
		-- check (cancellation must reach QUEUED records, not just
		-- flag intent: a 50-row stream already in sendQ can't be
		-- un-sent once Pump takes it)
		local dead = msg.pred and msg.pred()
		if dead then
			GM.After(SEND_GAP, Pump)
			return
		end
		local ch = ChanID(msg.ch)
		if ch > 0 then
			local ok, sent = pcall(Send, PREFIX, msg.msg,
				"CHANNEL", ch)
			if ok and sent ~= false then
				M.stats.sent = M.stats.sent + 1
				M.stats.lastSend = time()
			end
		else
			-- channel lost: bounded retry, then drop. Spinning on
			-- the head message wedges the whole queue — with two
			-- buses a dead writ channel must not starve market
			-- sends and whispers queued behind it (WoW caps
			-- custom channels, so a failed join is a real state)
			msg.tries = (msg.tries or 0) + 1
			if msg.tries <= 80 then
				tinsert(sendQ, 1, msg)
			end
		end
	else
		-- legacy bare-string entry — market channel
		local ch = ChanID(CH_A)
		if ch > 0 then
			local ok, sent = pcall(Send, PREFIX, msg, "CHANNEL", ch)
			if ok and sent ~= false then
				M.stats.sent = M.stats.sent + 1
				M.stats.lastSend = time()
			end
		else
			tinsert(sendQ, 1, msg)
		end
	end
	GM.After(SEND_GAP, Pump)
end

-- walk the queue and drop entries whose suppress key matches —
-- this is how overheard answers silence queued duplicates BEFORE
-- they transmit (mDNS known-answer / Meshtastic overhear-cancel)
function M.Cancel(pred)
	for i = #sendQ, 1, -1 do
		local m = sendQ[i]
		if type(m) == "table" and m.key and pred(m) then
			tremove(sendQ, i)
		end
	end
end

local function Broadcast(recs, kind, key, pred)
	-- header: proto | kind | scope — scope lets receivers fold into
	-- the right books_by_scope bucket on their side
	local scope = GM.Scope()
	local head = "1|" .. kind .. "|" .. scope .. "|"
	local ch = ChanFor(kind)
	local buf = head
	for _, r in ipairs(recs) do
		if #buf + #r + 1 > MAX_MSG then
			sendQ[#sendQ + 1] = { msg = buf, ch = ch, key = key,
				pred = pred }
			buf = head
		end
		buf = buf .. (#buf > #head and "," or "") .. r
	end
	if #buf > #head then
		sendQ[#sendQ + 1] = { msg = buf, ch = ch, key = key,
			pred = pred }
	end
	if not pumping then pumping = true Pump() end
end

-- generic send for other modules — writ board uses kind "O"; the
-- M/S kinds stay owned by OnBook's book-diff machinery. Volatile
-- realtime records drop when the channel is down rather than queue
-- — a writ event that arrives late is worse than one that doesn't.
function M.Send(kind, recs, key, pred)
	if ChanID(ChanFor(kind)) == 0 then return end
	Broadcast(recs, kind, key, pred)
end

-- whisper transport: the writ relay tunnel — op envelopes and
-- board snapshots ride directed WHISPER comms between a tunneled
-- peer and its relay. Same 1|kind|scope|rec envelope, same pump
-- pacing; sends don't need the channel joined.
function M.Whisper(target, kind, rec)
	if not target or target == "" then return end
	sendQ[#sendQ + 1] = {
		msg = "1|" .. kind .. "|" .. (GM.Scope() or "")
			.. "|" .. rec,
		target = target,
	}
	if not pumping then pumping = true Pump() end
end

-- relay capability beacon: the boards THIS install can serve —
-- the ones its own backend pulls. A tunneled peer picks a serving
-- advertiser and whispers its envelopes there.
function M.Advertise()
	local bs = GoblinMindDB and GoblinMindDB.boards
	-- board:tag — the tag is our tracker's url hash; peers use it to
	-- serve snapshots only for boards on the SAME tracker (a foreign
	-- same-named board is a different swarm, never a refresh source)
	local tag = GM.Orders and GM.Orders.TrackerTag
		and GM.Orders.TrackerTag() or "-"
	local names = {}
	for b in pairs(bs or {}) do
		names[#names + 1] = b .. ":" .. tag
	end
	if #names == 0 then return end
	M._advT = GetTime()
	-- our own beacon is coverage we can't hear — Orders counts it
	-- explicitly so the Trickle-lite bound actually converges
	if GM.Orders and GM.Orders.relay then
		GM.Orders.relay.selfAdv = time()
	end
	M.Send("T", { table.concat(names, ",") })
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
	if ChanID(CH_A) == 0 then return end
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
	if prefix ~= PREFIX then return end
	-- UnitName is "Unknown Entity" before PLAYER_LOGIN — never cache
	-- that, or the echo filter stays broken for the whole session
	if not me then
		local n = UnitName("player")
		if n and n ~= "Unknown Entity" then me = n end
	end
	if me and sender and sender:match("^[^-]+") == me then
		return -- own echo
	end
	if not GM.db then return end
	local proto, kind, scope, body = msg:match(
		"^(%d+)|([%a]+)|([^|]*)|?(.*)$")
	if proto ~= "1" or not body then return end
	if ctype == "WHISPER" then
		-- relay tunnel records (R/Q/W/w/Z/Y) — Orders.lua owns the
		-- grammar; mesh just delivers
		M.stats.heard = M.stats.heard + 1
		M.stats.lastHear = time()
		if GM.Orders and GM.Orders.MeshWhisper then
			GM.Orders.MeshWhisper(kind, body, sender)
		end
		return
	end
	if ctype ~= "CHANNEL" then return end
	GM.db.mesh = GM.db.mesh or { ev = {}, mb = {}, seq = 0 }
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
	elseif kind == "T" then
		-- relay capability — Orders.lua maps board -> serving peers
		if GM.Orders and GM.Orders.RelayPeer then
			GM.Orders.RelayPeer(body, sender)
		end
	elseif kind == "D" then
		-- discovery probe — v2: Orders decides whether WE are
		-- needed (coverage suppression) and answers on jitter.
		-- The v1 "every client re-beacons" rule was an
		-- N-squared storm at scale
		if GM.Orders and GM.Orders.MeshProbe then
			GM.Orders.MeshProbe(body, sender)
		end
	elseif kind == "Q" then
		-- distributed board query — "who serves a fresh pull of
		-- this board?" v2: servers answer with small offers (F);
		-- the asker picks one source (P) which alone streams
		if GM.Orders and GM.Orders.MeshQuery then
			GM.Orders.MeshQuery(body, sender)
		end
	elseif kind == "F" then
		if GM.Orders and GM.Orders.MeshOffer then
			GM.Orders.MeshOffer(body, sender)
		end
	elseif kind == "P" then
		if GM.Orders and GM.Orders.MeshPull then
			GM.Orders.MeshPull(body, sender)
		end
	elseif kind == "N" then
		-- stream announcement — binds (board,gen) to a sender +
		-- tracker tag; ingest only admits pinned streams. Kind is
		-- "N" not "S": the S branch above owns price-scan records
		if GM.Orders and GM.Orders.StreamStart then
			GM.Orders.StreamStart(body, sender)
		end
	elseif kind == "I" then
		-- distributed item search — "who holds open listings for
		-- this itemID?" Servers answer with 'i' rows on-channel
		if GM.Orders and GM.Orders.MeshItemQuery then
			GM.Orders.MeshItemQuery(body, sender)
		end
	elseif kind == "i" then
		-- item-search responses — rows batch comma-joined
		for rec in (body or ""):gmatch("[^,]+") do
			local f = {}
			for s in rec:gmatch("[^;]*") do f[#f + 1] = s end
			if GM.Orders and GM.Orders.ItemIngest then
				GM.Orders.ItemIngest(f, sender)
			end
		end
	elseif kind == "W" or kind == "w" or kind == "Z" then
		-- snapshot stream rows — records batch comma-joined in one
		-- message; ingest only admits streams its S pinned
		for rec in (body or ""):gmatch("[^,]+") do
			local f = {}
			for s in rec:gmatch("[^;]*") do f[#f + 1] = s end
			if GM.Orders and GM.Orders.RelayIngest then
				GM.Orders.RelayIngest(kind, f, sender)
			end
		end
	elseif kind == "O" then
		-- writ events are volatile overlays — Orders.lua owns the
		-- grammar and the confirmation/drop rules; mesh just relays
		if GM.Orders and GM.Orders.MeshEvent then
			for rec in body:gmatch("[^,]+") do
				GM.Orders.MeshEvent(rec)
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
	local st = GM.db and GM.db.mesh or {}
	local nScopes = 0
	for _ in pairs(db.realms or {}) do nScopes = nScopes + 1 end
	GM.Print(format("feed: %s · DB %s · %d scopes",
		db.feed or "?", Ago(db.generated), nScopes))
	GM.Print(format("mesh: %s · sent %d (%s) · heard %d (%s) · staged %d ev / %d mb · seq %d · ack %s",
		(ChanID(CH_A) > 0 and CH_A or "-") .. "/"
			.. (ChanID(CH_B) > 0 and CH_B or "-"),
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
	-- writ boards: local pulls are served by our tracker; remote
	-- boards are T-beacon discovered and ride the whisper tunnel
	if GM.Orders then
		local OR = GM.Orders
		local loc, rem = {}, {}
		for _, b in ipairs(OR.Boards and OR.Boards() or {}) do
			local bd = OR.Board(b)
			local open = 0
			for _, o in ipairs(bd and bd.orders or {}) do
				if (o.state or "open") == "open" then open = open + 1 end
			end
			local s = b .. " (" .. open .. " open)"
			if OR.IsRemote(b) then
				s = s .. " via " .. (OR.RelayServing(b) or "?")
					.. (OR.RelayCreds(b) and ""
						or " — registering")
				rem[#rem + 1] = s
			else
				loc[#loc + 1] = s
			end
		end
		if #loc > 0 or #rem > 0 then
			GM.Print("boards: "
				.. (#loc > 0 and table.concat(loc, ", ") or "")
				.. (#loc > 0 and #rem > 0 and " · " or "")
				.. (#rem > 0 and ("mesh " .. table.concat(rem, ", "))
					or ""))
		end
		-- relay health: ops deferred behind register, our outbound
		-- forwarding queue (host side), and unacked staged ops
		local regq, out = 0, GM.db and GM.db.relayOut
		for _, q in pairs(GM.db and GM.db.relayPend or {}) do
			regq = regq + #q
		end
		local pendN = OR.Pending and #OR.Pending() or 0
		if regq > 0 or (out and #out > 0) or pendN > 0 then
			GM.Print(format("relay: %d op%s pending%s%s",
				pendN, pendN == 1 and "" or "s",
				regq > 0 and format(" · %d waiting for creds", regq)
					or "",
				out and #out > 0
					and format(" · forwarding %d for peers", #out)
					or ""))
		end
		local u, iid = OR.MyUUID and OR.MyUUID(),
			OR.MyInstallID and OR.MyInstallID()
		if u then
			GM.Print("install: " .. tostring(u)
				.. (iid and (" · tracker id " .. iid)
					or " · mesh-only (no tracker id)"))
		end
	end
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
		if GM.Orders and GM.Orders.RelayStart then
			GM.Orders.RelayStart()
		end
		-- relay capability beacons — cadence low enough to be
		-- noise-free, frequent enough for peers to find us.
		-- v2: BeaconNeeded() suppresses the beacon when every
		-- board we serve is already covered by enough fresh
		-- beaconers (Trickle-lite — small swarms keep total
		-- coverage, big swarms stay quiet)
		GM.After(30, function()
			if not (GM.Orders and GM.Orders.BeaconNeeded
				and not GM.Orders.BeaconNeeded()) then
				M.Advertise()
			end
			local function advTick()
				if not (GM.Orders and GM.Orders.BeaconNeeded
					and not GM.Orders.BeaconNeeded()) then
					M.Advertise()
				end
				GM.After(280, advTick)
			end
			GM.After(280, advTick)
		end)
		-- discovery probe: if no peer advertised a board we care
		-- about by the time we've settled, ask the channel. v2:
		-- DiscoveryNeeded() — covered boards don't probe, and a
		-- probe that got answered in the last 30s coalesces with
		-- the next asker's instead of stacking
		GM.After(40, function()
			if not (GM.Orders and GM.Orders.DiscoveryNeeded
				and not GM.Orders.DiscoveryNeeded()) then
				M.Send("D", { "x" })
			end
		end)
	end
end)
