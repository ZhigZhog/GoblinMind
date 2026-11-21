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
	return GoblinMindDB and GoblinMindDB.backend
		and GoblinMindDB.backend.install or nil
end

-- ============ board data ============

function OR.Boards()
	-- configured names (backend.boards) ∪ pulled snapshots (boards)
	local out, seen = {}, {}
	local be = GoblinMindDB and GoblinMindDB.backend
	for _, b in ipairs(be and be.boards or {}) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	for b in pairs(GoblinMindDB and GoblinMindDB.boards or {}) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	table.sort(out)
	return out
end

function OR.Board(name)
	local bs = GoblinMindDB and GoblinMindDB.boards
	return bs and bs[name] or nil
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
		ctx.rid, ctx.board = rid, b
		local def = f and VERBS[f.v]
		local ev = def and def.replay and def.replay(f, ctx)
		if ev and b then
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
	local rid = OR.Stage(fields)
	local ev = evFields or (def.ev and def.ev(fields, rid))
	if ev then
		ev.v = verb
		ev.rid = rid
		OR.LiveEvent(board, ev)
		if def.wire then
			OR.MeshSend(def.wire(ev, rid, board))
		end
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
	return (GoblinMindDB and GoblinMindDB.orderResults) or {}
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
