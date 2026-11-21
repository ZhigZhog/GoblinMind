local _, GM = ...

-- Writ board (craft-orders-proposal 2026-11-20): standing buy orders
-- on the in-house backend. The addon NEVER talks to the server — it
-- stages ops into GoblinMindSettings.orderQueue ("ord-<ts>-<n>|hex"),
-- the watcher POSTs them, results come back on the next emit as
-- GoblinMindDB.orderResults[rid]; pulled boards arrive as
-- GoblinMindDB.boards. Everything below is therefore
-- flush-timescale — /reload refreshes the board.

GM.Orders = {}
local OR = GM.Orders

-- Settings.lua's HexEnc is a file-local; stage with our own copy —
-- the watcher only needs \x -> %02x to regex the payload back out
local function hexenc(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- tiny flat-map JSON writer — op bodies are one level of scalars
local function jesc(s)
	return (tostring(s):gsub('[%z\1-\31\\"]', function(c)
		return string.format("\\u%04x", c:byte())
	end))
end
local function OpJSON(f)
	local parts = {}
	for k, v in pairs(f) do
		if type(v) == "number" then
			parts[#parts + 1] = '"' .. k .. '":' .. tostring(v)
		elseif type(v) == "boolean" then
			parts[#parts + 1] = '"' .. k .. '":' .. (v and "true" or "false")
		else
			parts[#parts + 1] = '"' .. k .. '":"' .. jesc(v) .. '"'
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function unhex(h)
	return (h:gsub("..", function(p)
		return string.char(tonumber(p, 16))
	end))
end

-- inverse of OpJSON — flat {"k":scalar} only; jesc maps every
-- embedded quote/backslash to \uXXXX so bare " never appears
-- inside string values (the two-pass match below stays safe)
local function unjson(s)
	local out = {}
	for k, v in s:gmatch('"([^"]-)":"(.-)"[,}]') do
		out[k] = v:gsub("\\u(%x%x%x%x)", function(x)
			return string.char(tonumber(x, 16) % 256)
		end)
	end
	for k, v in s:gmatch('"([^"]-)":([^",}]+)') do
		if v == "true" then out[k] = true
		elseif v == "false" then out[k] = false
		else out[k] = tonumber(v) end
	end
	return out
end

local function CharName()
	return UnitName("player") or "?"
end

-- ============ identity ============

function OR.MyUUID()
	local u = GoblinMindDB and GoblinMindDB.backend
		and GoblinMindDB.backend.install
	if u then return u end
	-- pure-mesh peer: no backend emit means no install uuid, but
	-- relay envelopes still need a stable author id — generate one
	-- and keep it in SV so it survives reloads
	if GM.db then
		GM.db.myUUID = GM.db.myUUID
			or ("gm-%x-%04x"):format(time(), math.random(0xffff))
		return GM.db.myUUID
	end
	return nil
end

-- ============ board data ============

function OR.Boards()
	-- configured names (backend.boards) ∪ pulled snapshots (boards)
	-- ∪ relayed boards (rboards snapshots ∪ T-beacon discovery)
	local out, seen = {}, {}
	local be = GoblinMindDB and GoblinMindDB.backend
	for _, b in ipairs(be and be.boards or {}) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	for b in pairs(GoblinMindDB and GoblinMindDB.boards or {}) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	for b in pairs(GM.db and GM.db.rboards or {}) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	for b in pairs(OR.relay.peers) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	table.sort(out)
	return out
end

function OR.Board(name)
	local bs = GoblinMindDB and GoblinMindDB.boards
	local b = bs and bs[name]
	local rb = GM.db and GM.db.rboards and GM.db.rboards[name]
	-- freshest snapshot wins: a tag-matched peer's pull can be
	-- fresher than the file copy (which only moves at /reload)
	if b and rb and (rb.t or 0) > (b.t or 0) then return rb end
	return b or rb
end

-- tracker identity for T beacons — two boards named "main" on
-- different trackers are different swarms; the tag keeps a peer's
-- snapshot from poisoning our board view on a same-name collision
local function urlHash(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 0x100000000
	end
	return format("%x", h)
end

function OR.TrackerTag()
	local u = GoblinMindDB and GoblinMindDB.backend
		and GoblinMindDB.backend.url
	return u and urlHash(u) or nil
end

function OR.MyInstallID()
	return GoblinMindDB and GoblinMindDB.backend
		and GoblinMindDB.backend.installID or nil
end

-- item catalog the browse mode lists + the emit generation for
-- cache invalidation — the UI reads the catalog through here,
-- never raw GoblinMindDB
function OR.Catalog()
	local db = GoblinMindDB
	return db and ((db.realms and db.realms[GM.Scope()]
		and db.realms[GM.Scope()].items) or db.items) or nil
end

function OR.Generated()
	return (GoblinMindDB and GoblinMindDB.generated) or 0
end

-- ============ live overlay (mesh 'O' events) ============
-- Pulled boards are authoritative but flush-timescale. Order events
-- also ride the mesh as 'O' records — volatile hints applied on top
-- of the pulled view until a pull CONFIRMS them (matching id/commit/
-- state), the op's own result errors out, or a 10-min TTL orphans
-- them. Server truth always wins on the next pull.

OR.live = OR.live or {}    -- [board] = {ev, ...}, session-only
-- relay session state: peers[board][name]=t from T beacons,
-- asked[board]=t (Q throttle), gen counters, reg flags, rpend,
-- src[board]=stream pin, askGen[board]=last asked gen.
-- Stream pins and ask-gens live here (session), never in the SV
-- rboards table — phantom "0"/"5"/"7" boards were RBoard entries
-- persisted by ingest paths that ran before admission checks
OR.relay = { peers = {}, asked = {}, reg = {}, rpend = {}, gen = 0,
	src = {}, askGen = {} }
local LIVE_TTL = 600

-- seq breaks same-timestamp ties; sender t (wire records) keeps
-- cross-client events ordered even when packets arrive scrambled
local _evSeq = 0
function OR.LiveEvent(board, ev)
	if not board or board == "" then return end
	ev.t = math.min(ev.t or time(), time())  -- fast remote clocks
	_evSeq = _evSeq + 1
	ev.seq = _evSeq
	local L = OR.live[board]
	if not L then L = {} OR.live[board] = L end
	L[#L + 1] = ev
	while #L > 200 do table.remove(L, 1) end
	if GM.OrdersUI and GM.OrdersUI.Refresh then
		GM.OrdersUI.Refresh()
	end
end

-- find an order id by a commit id on the pulled board — release
-- stages only cid (that's the server route), the overlay needs
-- the parent to paint on
local function oidForCommit(board, cid)
	local b = OR.Board(board)
	for _, o in ipairs(b and b.orders or {}) do
		for _, c in ipairs(o.commits or {}) do
			if c.id == cid then return o.id end
		end
	end
end

-- ============ verb registry ============
-- Every op the system knows lives here — one table, so each
-- concern has exactly ONE execution path instead of parallel
-- if-chains:
--   ev(f,rid)          staged fields -> overlay event
--                      (absent = stage-only, no overlay/mesh)
--   wire(ev,rid,board) ev -> ';' mesh record
--   parse(f)           ';' fields -> ev (inverse of wire)
--   apply(ev,view,byId)      mutate the pulled view
--   confirm(ev,byId,live)    pull already reflects it -> drop ev
--   replay(f,ctx)            decoded queue fields -> ev (reload)
local VERBS = {}

-- reject/release/deny/force share semantics: an active commit
-- leaves the pool, its unfilled units return
local function relApply(ev, view, byId)
	local o = byId[ev.oid]
	if not o then return end
	o._pendOp = ev.v
	for _, c in ipairs(o.commits or {}) do
		if c.id == ev.cid and c.state == "active" then
			c.state = ev.v == "reject" and "rejected" or "released"
			c._pendOp = ev.v
			o.remaining = (o.remaining or 0)
				+ ((c.units or 0) - (c.unitsFilled or 0))
		end
	end
end

local function relConfirm(ev, byId)
	local o = ev.oid and byId[ev.oid]
	if not o then return false end
	for _, c in ipairs(o.commits or {}) do
		if c.id == ev.cid then return c.state ~= "active" end
	end
	return false
end

-- short-form commit evs — most verbs are just {oid, cid}
local function cidEv(f)
	return { oid = f.oid, cid = f.commit }
end
local function cidParse(f)
	return { oid = f[3], cid = f[4], t = tonumber(f[5]) }
end

VERBS.post = {
	letter = "P",
	ev = function(f, rid)
		local ev = {
			board = f.b, itemID = f.itemID, qtyTotal = f.qtyTotal,
			pricePerUnit = f.pricePerUnit, ttl = f.claimTTL,
			poster = f.poster, posterUUID = OR.MyUUID(),
		}
		local inst = OR.MyInstallID()
		if inst then ev.realID = inst .. ":" .. rid end
		return ev
	end,
	wire = function(ev, rid, board)
		return table.concat({ "P", board, rid, ev.itemID,
			ev.qtyTotal, ev.pricePerUnit, ev.ttl or 0,
			OR.MyInstallID() or "?", ev.posterUUID or "?",
			ev.poster or "?", time() }, ";")
	end,
	parse = function(f)
		local ev = {
			board = f[2], itemID = tonumber(f[4]),
			qtyTotal = tonumber(f[5]),
			pricePerUnit = tonumber(f[6]), ttl = tonumber(f[7]),
			posterUUID = f[9], poster = f[10], t = tonumber(f[11]),
		}
		if f[8] and f[8] ~= "?" and f[8] ~= "0" then
			ev.realID = f[8] .. ":" .. f[3]
		end
		if ev.itemID and ev.qtyTotal then return ev end
	end,
	replay = function(f, ctx)
		local ev = {
			board = ctx.board, itemID = f.itemID,
			qtyTotal = f.qtyTotal, pricePerUnit = f.pricePerUnit,
			ttl = f.claimTTL, poster = f.poster,
			posterUUID = ctx.uuid,
		}
		if ctx.inst then ev.realID = ctx.inst .. ":" .. ctx.rid end
		return ev
	end,
	apply = function(ev, view, byId)
		if ev.realID and not byId[ev.realID] then
			local o = {
				id = ev.realID, board = ev.board,
				itemID = ev.itemID, qtyTotal = ev.qtyTotal,
				qtyFilled = 0, remaining = ev.qtyTotal,
				pricePerUnit = ev.pricePerUnit,
				claimTTL = ev.ttl, poster = ev.poster,
				posterUUID = ev.posterUUID, backed = true,
				created = ev.t, expires = ev.t + 7 * 86400,
				state = "open", _live = true, _pendOp = "post",
				commits = {},
			}
			byId[o.id] = o
			view[#view + 1] = o
		end
	end,
	confirm = function(ev, byId)
		return ev.realID and byId[ev.realID] ~= nil
	end,
}

VERBS.claim = {
	letter = "C",
	ev = function(f, rid)
		local ev = {
			oid = f.oid, units = f.units, crafter = f.crafter,
			crafterUUID = OR.MyUUID(),
		}
		local inst = OR.MyInstallID()
		if inst then ev.cid = inst .. ":" .. rid end
		return ev
	end,
	wire = function(ev, rid, board)
		return table.concat({ "C", board, ev.oid, rid, ev.units,
			OR.MyInstallID() or "?", ev.crafterUUID or "?",
			ev.crafter or "?", time() }, ";")
	end,
	parse = function(f)
		local ev = {
			board = f[2], oid = f[3], units = tonumber(f[5]),
			crafterUUID = f[7], crafter = f[8], t = tonumber(f[9]),
		}
		if f[6] and f[6] ~= "?" and f[6] ~= "0" then
			ev.cid = f[6] .. ":" .. f[4]
		end
		if ev.oid and ev.units then return ev end
	end,
	replay = function(f, ctx)
		local ev = {
			oid = f.oid, units = f.units, crafter = f.crafter,
			crafterUUID = ctx.uuid,
		}
		if ctx.inst then ev.cid = ctx.inst .. ":" .. ctx.rid end
		return ev
	end,
	apply = function(ev, view, byId)
		local o = byId[ev.oid]
		if o and o.state == "open" then
			o.remaining = math.max(0,
				(o.remaining or 0) - (ev.units or 0))
			o._pendOp = "claim"
			o.commits = o.commits or {}
			o.commits[#o.commits + 1] = {
				id = ev.cid, units = ev.units, unitsFilled = 0,
				crafter = ev.crafter, crafterUUID = ev.crafterUUID,
				expires = ev.t + (o.claimTTL or 86400),
				state = "active", _live = true, _pendOp = "claim",
			}
		end
	end,
	confirm = function(ev, byId)
		local o = ev.oid and byId[ev.oid]
		if not o then return false end
		for _, c in ipairs(o.commits or {}) do
			if c.id == ev.cid then return true end
		end
		return false
	end,
}

VERBS.fill = {
	letter = "F",
	ev = function(f)
		return { oid = f.oid, units = f.units, cid = f.commit }
	end,
	wire = function(ev, rid, board)
		return table.concat({ "F", board, ev.oid, ev.units,
			ev.cid or "", time() }, ";")
	end,
	parse = function(f)
		return { oid = f[3], units = tonumber(f[4]), cid = f[5],
			t = tonumber(f[6]) }
	end,
	replay = function(f)
		return { oid = f.oid, units = f.units, cid = f.commit }
	end,
	apply = function(ev, view, byId)
		local o = byId[ev.oid]
		if not o then return end
		-- server: fill moves units held→filled (remaining stays —
		-- the claim already took them out). Only decrement
		-- remaining when we never saw the claim (blind fill).
		local seen
		for _, c in ipairs(o.commits or {}) do
			if c.id == ev.cid then
				seen = c
				break
			end
		end
		if seen and seen.state == "active" then
			seen.unitsFilled = (seen.unitsFilled or 0)
				+ (ev.units or 0)
			if seen.unitsFilled >= (seen.units or 0) then
				seen.state = "filled"
			end
		end
		ev.newFilled = (o.qtyFilled or 0) + (ev.units or 0)
		o.qtyFilled = ev.newFilled
		o._pendOp = "fill"
		if not seen then
			o.remaining = math.max(0,
				(o.remaining or 0) - (ev.units or 0))
		end
		if o.qtyFilled >= (o.qtyTotal or 0) then
			o.state = "filled"
		end
	end,
	confirm = function(ev, byId)
		local o = ev.oid and byId[ev.oid]
		if not o then return false end
		-- confirm against the filled commit — ev.newFilled is only
		-- set during apply, never at drop-check time, so the old
		-- qtyFilled>=newFilled test confirmed every fill instantly
		-- (>=0) and dropped it unapplied
		for _, c in ipairs(o.commits or {}) do
			if c.id == ev.cid then
				return (c.unitsFilled or 0) >= (ev.units or 0)
					or c.state == "filled"
			end
		end
		-- blind fill (claim never seen): the order reaching a
		-- terminal state is the only observable confirmation
		return o.state ~= "open"
	end,
}

VERBS.reject = {
	letter = "R",
	ev = cidEv,
	wire = function(ev, rid, board)
		return table.concat({ "R", board, ev.oid, ev.cid or "",
			time() }, ";")
	end,
	parse = cidParse,
	replay = cidEv,
	apply = relApply,
	confirm = relConfirm,
}

VERBS.cancel = {
	letter = "X",
	ev = function(f)
		return { oid = f.oid, units = f.units or 0 }
	end,
	wire = function(ev, rid, board)
		return table.concat({ "X", board, ev.oid, ev.units or 0,
			time() }, ";")
	end,
	parse = function(f)
		return { oid = f[3], units = tonumber(f[4]) or 0,
			t = tonumber(f[5]) }
	end,
	replay = function(f)
		return { oid = f.oid, units = f.units }
	end,
	apply = function(ev, view, byId)
		local o = byId[ev.oid]
		if not o then return end
		-- pending cancel keeps the row (grayed + flagged) until a
		-- pull confirms — a failed cancel op drops the ev and the
		-- order snaps back, never having visibly left
		o._pendOp = "cancel"
		if (ev.units or 0) > 0 then
			ev.newTotal = math.max((o.qtyFilled or 0),
				(o.qtyTotal or 0) - ev.units)
			o.qtyTotal = ev.newTotal
			o.remaining = math.max(0,
				(o.remaining or 0) - ev.units)
		end
	end,
	confirm = function(ev, byId, liveIds)
		local o = ev.oid and byId[ev.oid]
		-- `not o` = order absent from the pull. But when the cancel
		-- targets an overlay-only order (pending post), absence just
		-- means the post hasn't been pulled yet — NOT that the cancel
		-- landed. Only treat missing as confirmed when no live post
		-- ev could still create it.
		local absent = not o and not (liveIds and liveIds[ev.oid])
		if (ev.units or 0) == 0 then
			return absent or (o and o.state ~= "open") or false
		end
		return absent or (o and (o.qtyTotal or 0)
			<= (ev.newTotal or 0)) or false
	end,
}

VERBS.release = {
	letter = "L",
	-- the stage body stays cid-only (that's the server route); the
	-- overlay's parent oid comes from evFields at stage time or the
	-- pulled board on replay
	ev = function(f)
		return { oid = oidForCommit(f.b, f.cid), cid = f.cid }
	end,
	wire = function(ev, rid, board)
		return table.concat({ "L", board, ev.oid or "", ev.cid,
			time() }, ";")
	end,
	parse = cidParse,
	replay = function(f, ctx)
		return { oid = oidForCommit(ctx.board, f.cid), cid = f.cid }
	end,
	apply = relApply,
	confirm = relConfirm,
}

-- poster-side claim management: accept green-lights a crafter,
-- deny frees the units with no stat hit, force frees them and
-- books the vendor's rating
VERBS.accept = {
	letter = "A",
	ev = cidEv,
	wire = function(ev, rid, board)
		return table.concat({ "A", board, ev.oid, ev.cid,
			time() }, ";")
	end,
	parse = cidParse,
	replay = cidEv,
	apply = function(ev, view, byId)
		local o = byId[ev.oid]
		if not o then return end
		o._pendOp = "accept"
		for _, c in ipairs(o.commits or {}) do
			if c.id == ev.cid then
				c.accepted = true
				c._pendOp = "accept"
			end
		end
	end,
	confirm = function(ev, byId)
		local o = ev.oid and byId[ev.oid]
		if not o then return false end
		for _, c in ipairs(o.commits or {}) do
			if c.id == ev.cid then return c.accepted and true or false end
		end
		return false
	end,
}

VERBS.deny = {
	letter = "D",
	ev = cidEv,
	wire = function(ev, rid, board)
		return table.concat({ "D", board, ev.oid, ev.cid,
			time() }, ";")
	end,
	parse = cidParse,
	replay = cidEv,
	apply = relApply,
	confirm = relConfirm,
}

VERBS.force = {
	letter = "K",
	ev = cidEv,
	wire = function(ev, rid, board)
		return table.concat({ "K", board, ev.oid, ev.cid,
			time() }, ";")
	end,
	parse = cidParse,
	replay = cidEv,
	apply = relApply,
	confirm = relConfirm,
}

-- stage-only verbs: moderation ops have no overlay and no mesh
VERBS.ignore = {}
VERBS.ban = {}

local LETTER = {}
for name, def in pairs(VERBS) do
	def.name = name
	if def.letter then LETTER[def.letter] = def end
end

local function evConfirmed(ev, byId, liveIds)
	local def = VERBS[ev.v]
	return (def and def.confirm)
		and (def.confirm(ev, byId, liveIds) and true or false)
		or false
end

local function evDrop(ev, byId, res, pullT, liveIds)
	if ev.rid then
		local r = res[ev.rid]
		if r and not r.ok then return true end  -- my op failed outright
		-- acked ok + a pull NEWER than the ack missing the effect =
		-- the server already moved past it (cancelled post, expired
		-- commit) — no reason to phantom it until TTL
		if r and r.ok and (pullT or 0) > (r.t or 0)
				and not evConfirmed(ev, byId, liveIds) then
			return true
		end
	end
	if evConfirmed(ev, byId, liveIds) then return true end
	return (ev.t or 0) < time() - LIVE_TTL
end

local function shallow(o)
	local c = {}
	for k, v in pairs(o) do c[k] = v end
	-- clone the commits list too — applyEv appends/flags it and the
	-- pulled GoblinMindDB rows must stay pristine
	if o.commits then
		local cs = {}
		for i, cm in ipairs(o.commits) do
			local cc = {}
			for k, v in pairs(cm) do cc[k] = v end
			cs[i] = cc
		end
		c.commits = cs
	end
	return c
end

local function applyEv(ev, view, byId)
	local def = VERBS[ev.v]
	if def and def.apply then def.apply(ev, view, byId) end
end

-- staged-but-unconsumed ops survive in the SavedVariables queue —
-- replay them into the live overlay on first read so a post/claim
-- the watcher hasn't acked yet doesn't vanish on /reload. The
-- queue IS the pending set: ClearAcked drops rids the server has
-- answered, so what's left is by definition unconfirmed.
local _replayed = false
function OR.ReplayPending()
	if _replayed then return end
	_replayed = true
	local ctx = { inst = OR.MyInstallID(), uuid = OR.MyUUID() }
	for _, rec in ipairs((GM.db and GM.db.orderQueue) or {}) do
		local rid, h = rec:match("^(ord%-[^|]+)|(%x+)$")
		local f = h and unjson(unhex(h)) or nil
		local b = f and f.b or nil
		-- remote ops confirm against the RELAY install's server ids
		-- (<iid>:<rid>), not the local backend install's
		ctx.inst = (f and f.rly and OR.RelayCreds(b)
			and OR.RelayCreds(b).i) or OR.MyInstallID()
		ctx.rid, ctx.board = rid, b
		local def = f and VERBS[f.v]
		local ev = def and def.replay and def.replay(f, ctx)
		if ev and b then
			ev.rly = f.rly and true or nil
			-- the rid embeds the stage timestamp — replayed ops keep
			-- their real age (TTL, event-order sort) instead of
			-- looking brand new every login
			ev.v = f.v
			ev.rid = rid
			ev.t = tonumber(rid:match("^ord%-(%d+)"))
			local dup = false
			for _, e in ipairs(OR.live[b] or {}) do
				if e.rid == rid then dup = true break end
			end
			if not dup then OR.LiveEvent(b, ev) end
		end
	end
end

function OR.Orders(name)
	OR.RelayStart()
	OR.ReplayPending()
	local b = OR.Board(name)
	local pulled = b and b.orders or {}
	local view, byId = {}, {}
	for _, o in ipairs(pulled) do
		local c = shallow(o)
		byId[o.id] = c
		view[#view + 1] = c
	end
	local L = OR.live[name]
	if L then
		local res = OR.Results()
		local pullT = b and b.t or 0
		-- ids the overlay itself can still create — a cancel ev must
		-- not read "absent from pull" as confirmed when its target is
		-- a pending post
		local liveIds = {}
		for _, ev in ipairs(L) do
			if ev.v == "post" and ev.realID then
				liveIds[ev.realID] = true
			end
		end
		-- drop pass goes tail-first (safe removal mid-iteration);
		-- apply pass goes head-first so chains land in order —
		-- a cancel/claim must see the post that created the row
		for i = #L, 1, -1 do
			if evDrop(L[i], byId, res, pullT, liveIds) then
				-- remote ops never reach orderResults — when
				-- their ev drops, unstage so reload can't
				-- re-pend a phantom
				if L[i].rly then OR.Unstage(L[i].rid) end
				table.remove(L, i)
			end
		end
		-- apply in event-time order, not arrival order — reordered
		-- mesh packets and replayed queue entries both land right
		local ord = {}
		for _, ev in ipairs(L) do ord[#ord + 1] = ev end
		table.sort(ord, function(a, b)
			if (a.t or 0) ~= (b.t or 0) then
				return (a.t or 0) < (b.t or 0)
			end
			return (a.seq or 0) < (b.seq or 0)
		end)
		for _, ev in ipairs(ord) do
			applyEv(ev, view, byId)
		end
	end
	return view
end

-- my orders on a board (posterUUID == my install uuid)
function OR.MyOrders(name)
	local me = OR.MyUUID()
	local out = {}
	for _, o in ipairs(OR.Orders(name)) do
		if o.posterUUID == me then out[#out + 1] = o end
	end
	return out
end

-- my active commits across a board (crafterUUID == me)
function OR.MyCommits(name)
	local me = OR.MyUUID()
	local out = {}
	for _, o in ipairs(OR.Orders(name)) do
		for _, c in ipairs(o.commits or {}) do
			if c.crafterUUID == me then
				out[#out + 1] = { order = o, commit = c }
			end
		end
	end
	return out
end

-- ============ op staging ============

-- stage a verb into GM.db.orderQueue; returns the rid (which the
-- server also uses as the op nonce → orderResults key)
function OR.Stage(fields)
	fields.v = fields.v or "post"
	local rid = string.format("ord-%d-%d", time(), math.random(100, 999))
	GM.db.orderQueue = GM.db.orderQueue or {}
	GM.db.orderQueue[#GM.db.orderQueue + 1] =
		rid .. "|" .. hexenc(OpJSON(fields))
	return rid
end

function OR.MeshSend(rec)
	if GM.Mesh and GM.Mesh.Send then
		GM.Mesh.Send("O", { rec })
	end
end

-- THE op path: stage -> overlay ev -> mesh broadcast. Every verb
-- wrapper below is a thin field-map into this one pipeline, so an
-- op can never partially fire (queue without overlay, overlay
-- without mesh). evFields overrides the def's ev builder when the
-- caller knows overlay detail the stage body shouldn't carry
-- (release's parent oid — the server route doesn't want it).
function OR.Op(verb, board, fields, evFields)
	local def = VERBS[verb]
	if not def then return nil end
	fields = fields or {}
	fields.v = verb
	fields.b = fields.b or board
	local remote = board and OR.IsRemote(board)
	local creds
	if remote then
		-- tunneled board: the op must carry our relay creds; on
		-- first contact the whole op defers behind register —
		-- RelayCredsSet flushes GM.db.relayPend through OR.Op
		creds = OR.RelayCreds(board)
		if not creds then
			OR.RelayRegister(board)
			OR.RelayQueueOp(board, verb, fields)
			return nil
		end
		fields.rly = 1     -- our own watcher must not POST this
	end
	local rid = OR.Stage(fields)
	local ev = evFields or (def.ev and def.ev(fields, rid))
	if ev then
		ev.v = verb
		ev.rid = rid
		if remote then
			ev.rly = true
			-- server ids are <install_id>:<op> — our RELAY
			-- install id, not the local one (which is absent
			-- for pure-mesh peers anyway)
			if creds.i then
				if verb == "post" then
					ev.realID = creds.i .. ":" .. rid
				elseif verb == "claim" then
					ev.cid = creds.i .. ":" .. rid
				end
			end
		end
		OR.LiveEvent(board, ev)
		-- remote ops skip the channel O-record — a same-named
		-- board on a peer's tracker is a different swarm; the
		-- record would mislead their overlay
		if def.wire and not remote then
			OR.MeshSend(def.wire(ev, rid, board))
		end
	end
	if remote then
		OR.RelaySend(board, verb, fields, rid, creds)
	end
	return rid
end

function OR.Post(board, itemID, qty, ppu, ttl, charname)
	return OR.Op("post", board, {
		itemID = itemID, qtyTotal = qty, pricePerUnit = ppu,
		claimTTL = ttl, poster = charname or CharName(),
		backed = OR.PurseCovers(ppu * qty),
	})
end

function OR.Claim(board, oid, units, charname)
	return OR.Op("claim", board, {
		oid = oid, units = units, crafter = charname or CharName(),
	})
end

function OR.Fill(board, oid, units, cid, mailFrom)
	return OR.Op("fill", board, {
		oid = oid, units = units, commit = cid, mailFrom = mailFrom,
	})
end

function OR.Reject(board, oid, cid, mailFrom)
	return OR.Op("reject", board, {
		oid = oid, commit = cid, mailFrom = mailFrom,
	})
end

function OR.Cancel(board, oid, units)
	return OR.Op("cancel", board, { oid = oid, units = units })
end

function OR.Release(board, cid, oid)
	return OR.Op("release", board, { cid = cid },
		{ oid = oid, cid = cid })
end

function OR.Accept(board, oid, cid)
	return OR.Op("accept", board, { oid = oid, commit = cid })
end

function OR.Deny(board, oid, cid)
	return OR.Op("deny", board, { oid = oid, commit = cid })
end

function OR.Force(board, oid, cid)
	return OR.Op("force", board, { oid = oid, commit = cid })
end

-- mesh 'O' receive: ';'-separated records — ':' can't be the
-- separator because server ids are 'install:op' and carry colons;
-- ';' is illegal in char names, board scopes, and rids.
function OR.MeshEvent(rec)
	local f = {}
	for x in rec:gmatch("[^;]*") do f[#f + 1] = x end
	local def = LETTER[f[1]]
	local ev = def and def.parse and def.parse(f)
	if ev then
		ev.v = def.name
		OR.LiveEvent(f[2], ev)
	end
end

function OR.Ignore(uuid, on)
	return OR.Op("ignore", nil, { uuid = uuid, on = on })
end

function OR.BoardBan(board, uuid, on)
	return OR.Op("ban", board, { uuid = uuid, on = on })
end

function OR.JoinBoard(name, on)
	local id = string.format("bo-%d-%d", time(), math.random(100, 999))
	GM.db.boardReqs = GM.db.boardReqs or {}
	GM.db.boardReqs[#GM.db.boardReqs + 1] =
		id .. "|" .. hexenc(name .. "\n" .. (on and "1" or "0"))
	return id
end

-- ============ op results ============

function OR.Results()
	local r = GoblinMindDB and GoblinMindDB.orderResults or {}
	local re = GM.db and GM.db.relayErr
	if not re then return r end
	-- relayed ops never land in orderResults — their failures come
	-- back over the tunnel as X records; merge so evDrop treats a
	-- rejected remote op like any other server error
	local merged = {}
	for k, v in pairs(r) do merged[k] = v end
	for rid, code in pairs(re) do
		if not merged[rid] then
			merged[rid] = { ok = false, code = code }
		end
	end
	return merged
end

function OR.Result(rid)
	return OR.Results()[rid]
end

-- staged-but-unacked ops (rid -> raw fields decoded isn't stored;
-- the queue string's rid is all the UI needs to show "pending")
function OR.Pending()
	local res = OR.Results()
	local out = {}
	for _, s in ipairs(GM.db.orderQueue or {}) do
		local rid = s:match("^(ord%-[^|]+)")
		if rid and not res[rid] then out[#out + 1] = rid end
	end
	return out
end

-- drop queue entries the watcher already consumed (called on load
-- + on OrdersUI open — same lifecycle as filedBugs)
function OR.ClearAcked()
	local res = OR.Results()
	local q = GM.db.orderQueue
	if not q then return end
	for i = #q, 1, -1 do
		local rid = q[i]:match("^(ord%-[^|]+)")
		if rid and res[rid] then table.remove(q, i) end
	end
	local rq = GM.db.boardReqs
	-- boardReqs ack comes via backend.boards — leave them; they're
	-- idempotent and the watcher watermarks by rid anyway
end

-- ============ relay (the mesh NAT tunnel) ============
-- A peer that can't reach a board's tracker tunnels the whole
-- client<->tracker conversation through WHISPER comms to a peer
-- that can — the chat channel IS the tunnel:
--
--   A (tunneled)             B (relay — its watcher reaches T)
--   op     -> R whisper -> SV relayOut -> watcher POSTs -> T
--   board  <- W/w/Z    <- pulled snapshot (B's own board data)
--   creds  <- Y        <- register-relay result via relayResults
--   errors <- X        <- op failure result via relayResults
--
-- The op applies under A's OWN install — the envelope carries A's
-- uuid + relay_token, an op-scoped credential safe to whisper to
-- the chosen relay (never the bearer — that authorizes uploads).
-- B is a dumb pipe: it cannot poster-verb A's orders.
--
-- Wire records (whisper-only, ';'-delimited):
--   R;<board>;<uuid>;<rtoken>;<op>;<verb>;<fields...>  op envelope
--   Q;<board>;<gen>                                  pull request
--   W;<board>;<gen>;<order fields>                   order row
--   w;<board>;<gen>;<oid>;<commit fields>            commit row
--   Z;<board>;<gen>                                  stream end
--   Y;<board>;<iid>;<uuid>;<rtoken>                  issued creds
--   X;<arid>;<code>                                  op failure
-- Channel-side: T;<board,...> advertises serving capability.

local RELAY_ASK_TTL = 60    -- seconds between Q polls per board
local RELAY_PEER_TTL = 600  -- a T beacon older than this is stale

-- positional field order inside the R envelope — the host decodes
-- back into the staged body; v/b/op/uuid/rtoken ride the envelope
local RELAY_KEYS = {
	post = { "itemID", "qtyTotal", "pricePerUnit", "claimTTL",
		"expires", "poster", "backed" },
	claim = { "oid", "units", "crafter" },
	fill = { "oid", "units", "commit", "mailFrom" },
	reject = { "oid", "commit", "mailFrom" },
	cancel = { "oid", "units" },
	accept = { "oid", "commit" },
	deny = { "oid", "commit" },
	force = { "oid", "commit" },
	release = { "cid" },
	ignore = { "uuid", "on" },
	ban = { "uuid", "on" },
	register = { "name" },
}

local STAT_FIELDS = { "commits_filled", "commits_expired",
	"fills_rejected", "orders_posted", "orders_filled",
	"orders_cancelled", "commits_forced" }

local function statCSV(s)
	if not s then return "-" end
	local p = {}
	for i, k in ipairs(STAT_FIELDS) do
		p[i] = tostring(s[k] or 0)
	end
	return table.concat(p, ",")
end

local function unstatCSV(s)
	if not s or s == "-" then return nil end
	local out, i = {}, 0
	for v in s:gmatch("[^,]+") do
		i = i + 1
		out[STAT_FIELDS[i]] = tonumber(v) or 0
	end
	return i > 0 and out or nil
end

-- ============ remote board view ============

function OR.RBoard(board)
	GM.db.rboards = GM.db.rboards or {}
	local rb = GM.db.rboards[board]
	if not rb then
		rb = { orders = {}, t = 0, _remote = true }
		GM.db.rboards[board] = rb
	end
	return rb
end

function OR.IsRemote(b)
	if not b or b == "" then return false end
	local bs = GoblinMindDB and GoblinMindDB.boards
	if bs and bs[b] then return false end  -- own tracker serves it
	if GM.db and GM.db.rboards and GM.db.rboards[b] then
		return true
	end
	return OR.relay.peers[b] ~= nil         -- discovered via T
end

-- ============ creds + envelopes (tunneled side) ============

function OR.RelayCreds(board)
	local r = GM.db and GM.db.relay and GM.db.relay[board]
	return (r and r.k) and r or nil
end

function OR.RelayCredsSet(board, iid, uuid, rtoken)
	if not (board and rtoken and rtoken ~= "-") then return end
	GM.db.relay = GM.db.relay or {}
	GM.db.relay[board] = { i = iid, u = uuid, k = rtoken }
	OR.relay.reg[board] = nil
	-- ops pended behind register flush as real ops now
	local q = GM.db.relayPend and GM.db.relayPend[board]
	GM.db.relayPend[board] = nil
	for _, o in ipairs(q or {}) do
		OR.Op(o.v, board, o.f)
	end
end

function OR.RelayQueueOp(board, verb, fields)
	GM.db.relayPend = GM.db.relayPend or {}
	local q = GM.db.relayPend[board] or {}
	local f = {}
	for k, v in pairs(fields) do f[k] = v end
	q[#q + 1] = { v = verb, f = f }
	GM.db.relayPend[board] = q
end

function OR.RelayServing(board)
	local best, bt, now = nil, nil, time()
	-- for a board our own tracker serves, only a peer on the SAME
	-- tracker may refresh it — a foreign same-named board would
	-- poison the view. Remote boards have no local truth: any peer.
	local local_ = GoblinMindDB and GoblinMindDB.boards
		and GoblinMindDB.boards[board]
	local ourTag = OR.TrackerTag()
	for name, e in pairs(OR.relay.peers[board] or {}) do
		local t = type(e) == "table" and e.t or e
		local tag = type(e) == "table" and e.tag or nil
		if now - (t or 0) < RELAY_PEER_TTL
				and (not bt or t > bt)
				and (not local_ or (ourTag and tag == ourTag)) then
			best, bt = name, t
		end
	end
	return best
end

function OR.RelayWhisper(board, rec)
	local peer = OR.RelayServing(board)
	if peer and GM.Mesh and GM.Mesh.Whisper then
		GM.Mesh.Whisper(peer, "R", rec)
		return true
	end
	-- no serving peer yet — pend; T beacons and Y replies flush
	local q = OR.relay.rpend[board] or {}
	q[#q + 1] = rec
	OR.relay.rpend[board] = q
	return false
end

function OR.RelayRegister(board)
	if OR.relay.reg[board] then return end
	OR.relay.reg[board] = true
	-- register is a pseudo-verb: no creds exist yet — the Y reply
	-- IS the creds
	local rec = table.concat({ board, OR.MyUUID() or "?", "-",
		"-", "register", CharName() }, ";")
	OR.RelayWhisper(board, rec)
end

function OR.RelaySend(board, verb, fields, rid, creds)
	local keys = RELAY_KEYS[verb]
	if not keys then return end
	local p = { board, (creds and creds.u) or OR.MyUUID() or "?",
		creds.k or "-", rid, verb }
	for _, k in ipairs(keys) do
		local v = fields[k]
		if type(v) == "boolean" then v = v and 1 or 0 end
		p[#p + 1] = tostring(v == nil and "-" or v)
	end
	OR.RelayWhisper(board, table.concat(p, ";"))
end

function OR.RelayAsk(board, force)
	if not board then return nil end
	-- force = the manual refresh path: a local board's file copy is
	-- /reload-bound, so a tag-matched peer's newer pull is the only
	-- live view. Without force, only remote boards ask — the local
	-- watcher's pull is already the freshest source we'll get.
	if not (force or OR.IsRemote(board)) then return nil end
	local now = time()
	local ttl = force and 10 or RELAY_ASK_TTL
	if now - (OR.relay.asked[board] or 0) < ttl then
		return nil, "cooldown"
	end
	OR.relay.asked[board] = now
	OR.relay.gen = (OR.relay.gen or 0) + 1
	OR.relay.askGen[board] = OR.relay.gen
	if GM.Mesh and GM.Mesh.Send then
		-- the distributed ask, one broadcast and done: every server
		-- holding a matching snapshot streams it back on-channel,
		-- first responder's stream wins. Tag picks the swarm —
		-- local boards want same-tracker servers, remote boards
		-- want anyone NOT on our tracker ("!" = negative match)
		local ourTag = OR.TrackerTag()
		local tag = OR.IsRemote(board)
			and (ourTag and ("!" .. ourTag) or "-")
			or (ourTag or "-")
		GM.Mesh.Send("Q", { board .. ";" .. OR.relay.gen
			.. ";" .. tag })
	end
	return true
end

-- T beacon: peer advertises the boards it can serve — build the
-- peer map and flush any envelopes pended behind discovery
function OR.RelayPeer(body, sender)
	if not sender or sender == "" then return end
	-- never register ourselves: Mesh's echo filter can miss when it
	-- captured "Unknown Entity" pre-login, and a self-whispered Q is
	-- dropped by the client (REFRESH would dead-end asking ourselves)
	if sender:match("^[^-]+") == UnitName("player") then return end
	for entry in (body or ""):gmatch("[^,]+") do
		-- "board[:tag]" — tag is the serving peer's tracker hash;
		-- absent = legacy beacon (only trusted for remote boards)
		local b, tag = entry:match("^([^:]+):?(.*)$")
		local m = OR.relay.peers[b] or {}
		m[sender] = { t = time(), tag = tag ~= "" and tag or nil }
		OR.relay.peers[b] = m
		local q = OR.relay.rpend[b]
		if q then
			OR.relay.rpend[b] = nil
			for _, rec in ipairs(q) do
				OR.RelayWhisper(b, rec)
			end
		end
	end
end

-- ============ host side (relay serving) ============

-- a tunneled peer's envelope -> our SV relayOut queue, which OUR
-- watcher POSTs to OUR backend. from/b/op ride alongside the op
-- body so the result can route back to the asker.
function OR.RelayStage(sender, f)
	local board, uuid, rtok, arid, v = f[1], f[2], f[3], f[4], f[5]
	local keys = RELAY_KEYS[v]
	if not (board and v and keys) then return end
	local body = { from = sender, b = board, v = v }
	if uuid and uuid ~= "-" then body.uuid = uuid end
	if rtok and rtok ~= "-" then body.rtoken = rtok end
	if arid and arid ~= "-" then body.op = arid end
	for i, k in ipairs(keys) do
		local x = f[5 + i]
		if x and x ~= "-" then body[k] = x end
	end
	GM.db.relayOut = GM.db.relayOut or {}
	local rid = ("rel-%d-%d"):format(time(), math.random(100, 999))
	GM.db.relayOut[#GM.db.relayOut + 1] =
		rid .. "|" .. hexenc(OpJSON(body))
end

-- answer a Q pull: stream our pulled board as W/w rows ended by Z
function OR.RelayServe(sender, board, gen, tag)
	if not (sender and board and gen) then return end
	if not (GM.Mesh and GM.Mesh.Send) then return end
	-- swarm selection: a positive tag only answers when we sit on
	-- the asker's tracker; "!tag" means serve only when we DON'T
	-- (a remote-board ask must not pull our same-named local board)
	if tag and tag ~= "-" then
		if tag:sub(1, 1) == "!" then
			if OR.TrackerTag() == tag:sub(2) then return end
		elseif OR.TrackerTag() ~= tag then return end
	end
	-- one stream per board per 10s covers every same-swarm asker —
	-- listeners ingest opportunistically, so per-asker throttling
	-- would just multiply identical streams onto the channel
	local now = time()
	OR.relay.served = OR.relay.served or {}
	if now - (OR.relay.served[board] or 0) < 10 then return end
	OR.relay.served[board] = now
	local b = GoblinMindDB and GoblinMindDB.boards
		and GoblinMindDB.boards[board]
	if not b or not b.orders then return end  -- can't serve it
	-- N announces the stream + our tracker tag so listeners can
	-- verify the swarm before ingesting opportunistically. Rows
	-- batch per kind — Broadcast comma-joins them into as few
	-- channel messages as MAX_MSG allows. (NOT "S" — the mesh
	-- protocol already uses S for price-scan records)
	GM.Mesh.Send("N", { board .. ";" .. gen .. ";"
		.. (OR.TrackerTag() or "-") })
	local ws, cs = {}, {}
	for _, o in ipairs(b.orders) do
		ws[#ws + 1] = table.concat({
			board, gen, o.id, o.itemID, o.qtyTotal or 0,
			o.qtyFilled or 0, o.remaining or 0,
			o.pricePerUnit or 0, o.claimTTL or 0,
			o.poster or "-", o.posterUUID or "-",
			math.floor(o.expires or 0), o.state or "open",
			o.backed and 1 or 0, statCSV(o.posterStats) }, ";")
		for _, c in ipairs(o.commits or {}) do
			cs[#cs + 1] = table.concat({
				board, gen, o.id, c.id, c.units or 0,
				c.unitsFilled or 0, c.crafter or "-",
				c.crafterUUID or "-",
				math.floor(c.expires or 0),
				c.state or "active", c.accepted and 1 or 0,
				statCSV(c.crafterStats) }, ";")
		end
	end
	GM.Mesh.Send("W", ws)
	GM.Mesh.Send("w", cs)
	GM.Mesh.Send("Z", { board .. ";" .. gen })
end

-- our watcher surfaced relay results in the emit — whisper them
-- back to their requesters: register creds (Y), op failures (X)
function OR.RelayScanResults()
	local rr = GoblinMindDB and GoblinMindDB.relayResults
	if not rr or not (GM.Mesh and GM.Mesh.Whisper) then return end
	GM.db.relayAcked = GM.db.relayAcked or {}
	for rid, r in pairs(rr) do
		if not GM.db.relayAcked[rid] and r.from then
			if r.relay_token and r.b then
				GM.Mesh.Whisper(r.from, "Y", table.concat({
					r.b, r.install_id or "-",
					r.uuid or "-", r.relay_token }, ";"))
				GM.db.relayAcked[rid] = true
			elseif r.arid and not r.ok then
				GM.Mesh.Whisper(r.from, "X",
					r.arid .. ";" .. (r.code or 0))
				GM.db.relayAcked[rid] = true
			end
		end
	end
end

-- ============ tunneled side (snapshot ingest) ============

-- S announces a stream on the channel: board;gen;serverTag. This is
-- the admission gate — rows are only ingested for a (gen,sender)
-- pair an S pinned, never by gen alone. A local board demands a
-- tag match (our swarm only — a foreign same-named stream would
-- poison the view); a remote board admits the first S answering
-- our ask's gen.
function OR.StreamStart(body, sender)
	if not sender or sender:match("^[^-]+") == UnitName("player") then
		return
	end
	local b, gen, tag = (body or ""):match("^([^;]+);(%d+);?(.*)$")
	if not b then return end
	local g = tonumber(gen)
	if GoblinMindDB and GoblinMindDB.boards
			and GoblinMindDB.boards[b] then
		-- local board: only our own swarm may refresh it
		if tag ~= OR.TrackerTag() then return end
		OR.relay.src[b] = { gen = g, peer = sender, t = time() }
	elseif g == OR.relay.askGen[b] then
		-- remote board: first stream answering our pending ask wins
		local s = OR.relay.src[b]
		if not (s and s.peer and time() - (s.t or 0) < 30) then
			OR.relay.src[b] = { gen = g, peer = sender,
				t = time() }
		end
	end
end

function OR.RelayIngest(kind, f, sender)
	local gen = tonumber(f[2])
	local s = gen and OR.relay.src[f[1]]
	-- admitted only by an N pin for this (gen,sender) — gen alone
	-- proves nothing on a broadcast medium. The pin check runs
	-- BEFORE RBoard so stray rows can't persist phantom boards
	if not s or gen ~= s.gen or sender ~= s.peer then
		return
	end
	local rb = OR.RBoard(f[1])
	if kind == "Z" then
		-- stream end: rows not stamped this gen are gone; release
		-- the pin so the next stream (any asker, any server) can bind
		rb.t = time()
		OR.relay.src[f[1]] = nil
		for i = #rb.orders, 1, -1 do
			if rb.orders[i]._gen ~= gen then
				table.remove(rb.orders, i)
			end
		end
		-- the refresh button's whole point — the snapshot just
		-- landed live; repaint without waiting for another trigger
		if GM.OrdersUI and GM.OrdersUI.Refresh then
			GM.OrdersUI.Refresh()
		end
		return
	end
	if kind == "W" then
		local o = {
			id = f[3], board = f[1], itemID = tonumber(f[4]),
			qtyTotal = tonumber(f[5]), qtyFilled = tonumber(f[6]),
			remaining = tonumber(f[7]),
			pricePerUnit = tonumber(f[8]),
			claimTTL = tonumber(f[9]),
			poster = f[10] ~= "-" and f[10] or nil,
			posterUUID = f[11] ~= "-" and f[11] or nil,
			expires = tonumber(f[12]), state = f[13],
			backed = f[14] == "1",
			posterStats = unstatCSV(f[15]),
			_gen = gen, commits = {},
		}
		for i, x in ipairs(rb.orders) do
			if x.id == o.id then
				o.commits = x.commits or {}
				o.created = x.created
				rb.orders[i] = o
				return
			end
		end
		rb.orders[#rb.orders + 1] = o
	elseif kind == "w" then
		local o
		for _, x in ipairs(rb.orders) do
			if x.id == f[3] then o = x break end
		end
		if not o then
			o = { id = f[3], board = f[1], commits = {},
				_gen = gen }
			rb.orders[#rb.orders + 1] = o
		end
		o.commits = o.commits or {}
		local c = {
			id = f[4], units = tonumber(f[5]),
			unitsFilled = tonumber(f[6]),
			crafter = f[7] ~= "-" and f[7] or nil,
			crafterUUID = f[8] ~= "-" and f[8] or nil,
			expires = tonumber(f[9]), state = f[10],
			accepted = f[11] == "1",
			crafterStats = unstatCSV(f[12]),
		}
		for i, x in ipairs(o.commits) do
			if x.id == c.id then o.commits[i] = c return end
		end
		o.commits[#o.commits + 1] = c
	end
end

-- ============ distributed item search ============
-- I query broadcast: "itemID;gen;tag" — every server holding open
-- orders for the item answers with 'i' rows on-channel. Tag picks
-- the swarm the same way as board Qs; "-" asks every tracker in
-- earshot, which is what a market-wide search wants.

OR.search = nil  -- {gen, t, itemID, rows={[board|oid]=row}}

function OR.SearchItem(itemID)
	if not (GM.Mesh and GM.Mesh.Send) then return 0 end
	local iid = tonumber(itemID)
	if not iid then return 0 end
	OR.relay.gen = (OR.relay.gen or 0) + 1
	local g = OR.relay.gen
	OR.search = { gen = g, t = time(), itemID = iid, rows = {} }
	-- our own boards seed the results locally — freshest source,
	-- no wire needed
	for b, bd in pairs(GoblinMindDB and GoblinMindDB.boards or {}) do
		for _, o in ipairs(bd.orders or {}) do
			if o.itemID == iid and o.state == "open"
					and (o.remaining or 0) > 0 then
				OR.search.rows[b .. "|" .. o.id] = {
					board = b, oid = o.id, qty = o.qtyTotal,
					rem = o.remaining, ppu = o.pricePerUnit,
					exp = o.expires, poster = o.poster }
			end
		end
	end
	-- "-" tag: every swarm answers — a market search wants all
	-- reachable listings, not just our tracker's
	GM.Mesh.Send("I", { iid .. ";" .. g .. ";-" })
	return g
end

function OR.SearchRows()
	local s = OR.search
	if not s then return nil, 0 end
	local out = {}
	for _, r in pairs(s.rows) do out[#out + 1] = r end
	table.sort(out, function(a, b)
		return (a.ppu or 0) < (b.ppu or 0) end)
	return out, s.itemID, time() - s.t
end

-- a server's 'i' row:
-- gen;itemID;board;oid;qty;rem;ppu;exp;poster;backed
function OR.ItemIngest(f, sender)
	local s = OR.search
	if not s then return end
	local gen, iid = tonumber(f[1]), tonumber(f[2])
	if gen ~= s.gen or iid ~= s.itemID then return end
	local key = (f[3] or "?") .. "|" .. (f[4] or "?")
	s.rows[key] = {
		board = f[3], oid = f[4],
		qty = tonumber(f[5]), rem = tonumber(f[6]),
		ppu = tonumber(f[7]), exp = tonumber(f[8]),
		poster = f[9] ~= "-" and f[9] or nil,
		backed = f[10] == "1", via = sender }
	-- a server answering for a board is proof it can serve it —
	-- register it as a peer so claims on foreign boards route
	-- through the relay like any other remote board
	if sender and not (GoblinMindDB and GoblinMindDB.boards
			and GoblinMindDB.boards[f[3]]) then
		local m = OR.relay.peers[f[3]] or {}
		m[sender] = { t = time() }
		OR.relay.peers[f[3]] = m
	end
	if GM.OrdersUI and GM.OrdersUI.Refresh then
		GM.OrdersUI.Refresh()
	end
end

-- host side: 'I' record asks for open listings of one item
function OR.MeshItemQuery(body, sender)
	if not sender or sender:match("^[^-]+") == UnitName("player") then
		return
	end
	local iid, gen, tag = (body or ""):match("^(%d+);(%d+);?(.*)$")
	if not iid then return end
	OR.ItemServe(sender, tonumber(iid), tonumber(gen),
		tag ~= "" and tag or nil)
end

function OR.ItemServe(sender, iid, gen, tag)
	if not (sender and iid and gen) then return end
	if not (GM.Mesh and GM.Mesh.Send) then return end
	-- same swarm rules as board streams
	if tag and tag ~= "-" then
		if tag:sub(1, 1) == "!" then
			if OR.TrackerTag() == tag:sub(2) then return end
		elseif OR.TrackerTag() ~= tag then return end
	end
	-- responses are asker-scoped (they echo the ask's gen), so
	-- throttle per asker+item
	local now = time()
	OR.relay.served = OR.relay.served or {}
	local key = "i:" .. iid .. ":" .. sender
	if now - (OR.relay.served[key] or 0) < 10 then return end
	OR.relay.served[key] = now
	local rows = {}
	for b, bd in pairs(GoblinMindDB
			and GoblinMindDB.boards or {}) do
		for _, o in ipairs(bd.orders or {}) do
			if o.itemID == iid and o.state == "open"
					and (o.remaining or 0) > 0 then
				rows[#rows + 1] = table.concat({
					gen, iid, b, o.id, o.qtyTotal or 0,
					o.remaining or 0, o.pricePerUnit or 0,
					math.floor(o.expires or 0),
					o.poster or "-",
					o.backed and 1 or 0 }, ";")
			end
		end
	end
	if #rows > 0 then GM.Mesh.Send("i", rows) end
end

-- channel-broadcast board query ("who serves this board?") — the
-- distributed refresh: any peer holding a tag-matched snapshot
-- answers by streaming it back on-channel
function OR.MeshQuery(body, sender)
	if not sender or sender:match("^[^-]+") == UnitName("player") then
		return
	end
	local b, gen, tag = (body or ""):match("^([^;]+);(%d+);?(.*)$")
	if not b then return end
	OR.RelayServe(sender, b, tonumber(gen), tag ~= "" and tag or nil)
end

-- single entry point for whisper-delivered records
function OR.MeshWhisper(kind, body, sender)
	local f = {}
	for s in (body or ""):gmatch("[^;]*") do f[#f + 1] = s end
	if kind == "R" then
		OR.RelayStage(sender, f)
	elseif kind == "Q" then
		OR.RelayServe(sender, f[1], tonumber(f[2]), f[3])
	elseif kind == "W" or kind == "w" or kind == "Z" then
		OR.RelayIngest(kind, f, sender)
	elseif kind == "Y" then
		OR.RelayCredsSet(f[1], tonumber(f[2]), f[3], f[4])
	elseif kind == "X" then
		GM.db.relayErr = GM.db.relayErr or {}
		GM.db.relayErr[f[1]] = tonumber(f[2]) or 0
	end
end

-- drop a queue line by rid — remote ops never reach orderResults,
-- so their queue entries clear when the overlay ev drops instead
-- of lingering and re-pending phantom rows on reload
function OR.Unstage(rid)
	local q = GM.db and GM.db.orderQueue
	if not (q and rid) then return end
	for i = #q, 1, -1 do
		if q[i]:match("^(ord%-[^|]+)") == rid then
			table.remove(q, i)
		end
	end
end

-- result sweep — cheap cadence; runs whether or not the window is
-- open since the host half has a duty even when we're not looking
local _relayTick = false
function OR.RelayStart()
	if _relayTick or not (GM.After and GM.db) then return end
	_relayTick = true
	-- purge phantom remote boards — junk entries old ingest paths
	-- persisted (t=0, no orders: never populated by a real stream)
	for k, v in pairs(GM.db.rboards or {}) do
		if (v.t or 0) == 0 and not next(v.orders or {}) then
			GM.db.rboards[k] = nil
		end
	end
	-- solo REFRESH, reload #2: the staged 'br-' request flushed on
	-- the first reload; the watcher pulls + patch-emits inside its
	-- 5s poll, so a reload ~20s out lands on the fresh boards.
	-- refPend.fired marks the second reload done — clear and stop.
	local rp = GM.db.refPend
	if rp then
		if rp.fired or time() - (rp.t or 0) > 120 then
			GM.db.refPend = nil
		else
			rp.fired = true
			GM.After(20, ReloadUI)
		end
	end
	local function loop()
		OR.RelayScanResults()
		GM.After(15, loop)
	end
	GM.After(15, loop)
end

-- unified REFRESH entry — first the distributed ask (broadcast Q,
-- peers stream their newest pull live), then the solo fallback:
-- no stream in ~8s on a local board means no peer can help, so
-- stage a pull request for our own watcher and let it reload.
function OR.RefreshBoard(board)
	if not board then return "no board selected" end
	local t0 = (OR.Board(board) or {}).t or 0
	local asked = OR.RelayAsk(board, true)
	if not OR.IsRemote(board) then
		GM.After(8, function()
			local b = OR.Board(board)
			if b and (b.t or 0) > t0 then return end -- a peer answered
			OR.RefreshLocal()
		end)
		return asked and "asking channel — solo pull if quiet"
			or "asked just now — waiting"
	end
	return asked and ("asking channel for " .. board)
		or "asked just now — waiting"
end

-- the only path to OUR server: stage a 'br-' pull request, reload
-- to flush it into the SV file, watcher pulls + patch-emits, a
-- second reload (scheduled post-login) reads it. No whisper can
-- reach the tracker — the file boundary is the channel.
function OR.RefreshLocal()
	GM.db.boardReqs = GM.db.boardReqs or {}
	local rid = ("br-%d-%d"):format(time(), math.random(999))
	GM.db.boardReqs[#GM.db.boardReqs + 1] =
		rid .. "|" .. hexenc("pull")
	if #GM.db.boardReqs > 10 then
		table.remove(GM.db.boardReqs, 1)
	end
	GM.db.refPend = { t = time(), rid = rid }
	ReloadUI()
end

-- ============ ledger reserve (advisory — addons can't custody gold) ============
-- GM.db.orderReserves[rid] = {gold, board, orderID?} — set at post,
-- orderID filled when the result/board names it. Fills retire
-- units*ppu; cancels/expiry release the remainder. The UI warns when
-- purse - total < 0; underfunded posts carry backed=false.

function OR.Reserves()
	GM.db.orderReserves = GM.db.orderReserves or {}
	return GM.db.orderReserves
end

function OR.ReserveTotal()
	local t = 0
	for _, r in pairs(OR.Reserves()) do t = t + (r.gold or 0) end
	return t
end

function OR.Purse()
	return GetMoney and GetMoney() or 0
end

function OR.PurseCovers(gold)
	return (OR.Purse() - OR.ReserveTotal() - gold) >= 0
end

function OR.Underfunded()
	return (OR.Purse() - OR.ReserveTotal()) < 0
end

function OR.ReserveAdd(rid, gold, board)
	OR.Reserves()[rid] = { gold = gold, board = board }
end

function OR.ReserveRetire(orderID, gold)
	-- called on observed fills — decrement the matching reserve
	for rid, r in pairs(OR.Reserves()) do
		if r.orderID == orderID then
			r.gold = math.max(0, (r.gold or 0) - gold)
			if r.gold <= 0 then OR.Reserves()[rid] = nil end
			return
		end
	end
end

function OR.ReserveRelease(orderID)
	for rid, r in pairs(OR.Reserves()) do
		if r.orderID == orderID then OR.Reserves()[rid] = nil end
	end
end

-- reconcile reserves against pulled board state each refresh:
-- an order that vanished (cancelled/expired/filled) frees its gold;
-- fills shrink it (qtyFilled*ppu worth is spent)
function OR.ReserveSync()
	local res = OR.Reserves()
	local live = {}
	for _, name in ipairs(OR.Boards()) do
		for _, o in ipairs(OR.Orders(name)) do
			live[o.id] = o
		end
	end
	for rid, r in pairs(res) do
		-- bind orderID once the board names it (id = install:rid)
		if not r.orderID then
			for oid in pairs(live) do
				if oid:sub(-#rid) == rid then
					r.orderID = oid
					break
				end
			end
		end
		local o = r.orderID and live[r.orderID]
		if r.orderID and not o then
			res[rid] = nil                       -- gone -> release
		elseif o then
			local unspent = (o.qtyTotal - (o.qtyFilled or 0))
				* (o.pricePerUnit or 0)
			r.gold = unspent                     -- fills shrink it
		end
	end
end

-- ============ inbox COD detection (poster side) ============
-- scans the open inbox for COD mails whose sender matches a commit
-- crafter on one of my orders. Forever's GetInboxHeaderInfo tuple
-- carries COD at index 6 (1.12-era signature); the probe verified
-- GetInboxInvoiceInfo exists for detail. One click per protected
-- call: TakeInboxItem to accept+pay, ReturnInboxItem to reject.

function OR.InboxCODs()
	local out = {}
	local n = GetInboxNumItems and GetInboxNumItems() or 0
	local me = OR.MyUUID()
	local want = {}  -- sender charname -> {order, commit}
	for _, name in ipairs(OR.Boards()) do
		for _, o in ipairs(OR.Orders(name)) do
			if o.posterUUID == me then
				for _, c in ipairs(o.commits or {}) do
					if c.state == "active" and c.crafter then
						want[c.crafter:lower()] = { order = o, commit = c }
					end
				end
			end
		end
	end
	for i = 1, n do
		local _, _, sender, subject, money, cod, daysLeft, hasItem =
			GetInboxHeaderInfo(i)
		if (cod or 0) > 0 and sender then
			local hit = want[sender:lower()]
			out[#out + 1] = {
				index = i, sender = sender, cod = cod,
				subject = subject, hasItem = hasItem,
				order = hit and hit.order, commit = hit and hit.commit,
			}
		end
	end
	return out
end

-- accept: TakeInboxItem pays the COD (protected — the click IS the
-- payment). The fill op stages after; units default to the commit's
-- unfilled remainder.
function OR.AcceptCOD(hit)
	if not TakeInboxItem then return false end
	local units = hit.commit
		and (hit.commit.units - (hit.commit.unitsFilled or 0)) or 1
	TakeInboxItem(hit.index)
	OR.Fill(hit.order and hit.order.board or "main",
		hit.order and hit.order.id or "?",
		units, hit.commit and hit.commit.id, hit.sender)
	return true
end

function OR.RejectCOD(hit)
	if not ReturnInboxItem then return false end
	ReturnInboxItem(hit.index)
	OR.Reject(hit.order and hit.order.board or "main",
		hit.order and hit.order.id or "?",
		hit.commit and hit.commit.id, hit.sender)
	return true
end
