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

-- ============ live overlay (mesh 'O' events) ============
-- Pulled boards are authoritative but flush-timescale. Order events
-- also ride the mesh as 'O' records — volatile hints applied on top
-- of the pulled view until a pull CONFIRMS them (matching id/commit/
-- state), the op's own result errors out, or a 10-min TTL orphans
-- them. Server truth always wins on the next pull.

OR.live = OR.live or {}    -- [board] = {ev, ...}, session-only
local LIVE_TTL = 600

function OR.LiveEvent(board, ev)
	if not board or board == "" then return end
	ev.t = ev.t or time()
	local L = OR.live[board]
	if not L then L = {} OR.live[board] = L end
	L[#L + 1] = ev
	while #L > 200 do table.remove(L, 1) end
	if GM.OrdersUI and GM.OrdersUI.Refresh then
		GM.OrdersUI.Refresh()
	end
end

local function evConfirmed(ev, byId)
	local o = ev.oid and byId[ev.oid]
	if ev.v == "post" then
		return ev.realID and byId[ev.realID] ~= nil
	elseif ev.v == "claim" then
		if not o then return false end
		for _, c in ipairs(o.commits or {}) do
			if c.id == ev.cid then return true end
		end
		return false
	elseif ev.v == "fill" then
		return o and (o.qtyFilled or 0) >= (ev.newFilled or 0)
	elseif ev.v == "cancel" then
		if (ev.units or 0) == 0 then
			return not o or o.state ~= "open"
		end
		return not o or (o.qtyTotal or 0) <= (ev.newTotal or 0)
	elseif ev.v == "reject" or ev.v == "release" then
		if not o then return false end
		for _, c in ipairs(o.commits or {}) do
			if c.id == ev.cid then return c.state ~= "active" end
		end
		return false
	end
	return false
end

local function evDrop(ev, byId, res, pullT)
	if ev.rid then
		local r = res[ev.rid]
		if r and not r.ok then return true end  -- my op failed outright
		-- acked ok + a pull NEWER than the ack missing the effect =
		-- the server already moved past it (cancelled post, expired
		-- commit) — no reason to phantom it until TTL
		if r and r.ok and (pullT or 0) > (r.t or 0)
				and not evConfirmed(ev, byId) then
			return true
		end
	end
	if evConfirmed(ev, byId) then return true end
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
	if ev.v == "post" then
		if ev.realID and not byId[ev.realID] then
			local o = {
				id = ev.realID, board = ev.board,
				itemID = ev.itemID, qtyTotal = ev.qtyTotal,
				qtyFilled = 0, remaining = ev.qtyTotal,
				pricePerUnit = ev.pricePerUnit,
				claimTTL = ev.ttl, poster = ev.poster,
				posterUUID = ev.posterUUID, backed = true,
				created = ev.t, expires = ev.t + 7 * 86400,
				state = "open", _live = true, commits = {},
			}
			byId[o.id] = o
			view[#view + 1] = o
		end
	elseif ev.v == "claim" then
		local o = byId[ev.oid]
		if o and o.state == "open" then
			o.remaining = math.max(0,
				(o.remaining or 0) - (ev.units or 0))
			o.commits = o.commits or {}
			o.commits[#o.commits + 1] = {
				id = ev.cid, units = ev.units, unitsFilled = 0,
				crafter = ev.crafter, crafterUUID = ev.crafterUUID,
				expires = ev.t + (o.claimTTL or 86400),
				state = "active", _live = true,
			}
		end
	elseif ev.v == "fill" then
		local o = byId[ev.oid]
		if o then
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
			if not seen then
				o.remaining = math.max(0,
					(o.remaining or 0) - (ev.units or 0))
			end
			if o.qtyFilled >= (o.qtyTotal or 0) then
				o.state = "filled"
			end
		end
	elseif ev.v == "cancel" then
		local o = byId[ev.oid]
		if o then
			if (ev.units or 0) == 0 then
				o.state = "cancelled"
				for i, x in ipairs(view) do
					if x == o then table.remove(view, i) break end
				end
				byId[ev.oid] = nil
			else
				ev.newTotal = math.max((o.qtyFilled or 0),
					(o.qtyTotal or 0) - ev.units)
				o.qtyTotal = ev.newTotal
				o.remaining = math.max(0,
					(o.remaining or 0) - ev.units)
			end
		end
	elseif ev.v == "reject" or ev.v == "release" then
		local o = byId[ev.oid]
		if o then
			for _, c in ipairs(o.commits or {}) do
				if c.id == ev.cid and c.state == "active" then
					c.state = ev.v == "reject" and "rejected" or "released"
					o.remaining = (o.remaining or 0)
						+ ((c.units or 0) - (c.unitsFilled or 0))
				end
			end
		end
	end
end

-- staged-but-unconsumed ops survive in the SavedVariables queue —
-- replay them into the live overlay on first read so a post/claim
-- the watcher hasn't acked yet doesn't vanish on /reload. The
-- queue IS the pending set: ClearAcked drops rids the server has
-- answered, so what's left is by definition unconfirmed.
local _replayed = false
local function oidForCommit(board, cid)
	local b = OR.Board(board)
	for _, o in ipairs(b and b.orders or {}) do
		for _, c in ipairs(o.commits or {}) do
			if c.id == cid then return o.id end
		end
	end
end

function OR.ReplayPending()
	if _replayed then return end
	_replayed = true
	local inst = OR.MyInstallID()
	for _, rec in ipairs((GM.db and GM.db.orderQueue) or {}) do
		local rid, h = rec:match("^(ord%-[^|]+)|(%x+)$")
		local f = h and unjson(unhex(h)) or nil
		local b = f and f.b or nil
		local ev
		if f and b then
			if f.v == "post" then
				ev = { v = "post", rid = rid, board = b,
					itemID = f.itemID, qtyTotal = f.qtyTotal,
					pricePerUnit = f.pricePerUnit, ttl = f.claimTTL,
					poster = f.poster, posterUUID = OR.MyUUID() }
				if inst then
					ev.realID = inst .. ":" .. rid
				end
			elseif f.v == "claim" then
				ev = { v = "claim", rid = rid, oid = f.oid,
					units = f.units, crafter = f.crafter,
					crafterUUID = OR.MyUUID() }
				if inst then ev.cid = inst .. ":" .. rid end
			elseif f.v == "fill" then
				ev = { v = "fill", rid = rid, oid = f.oid,
					units = f.units, cid = f.commit }
			elseif f.v == "reject" then
				ev = { v = "reject", rid = rid, oid = f.oid,
					cid = f.commit }
			elseif f.v == "cancel" then
				ev = { v = "cancel", rid = rid, oid = f.oid,
					units = f.units }
			elseif f.v == "release" then
				ev = { v = "release", rid = rid, cid = f.cid,
					oid = oidForCommit(b, f.cid) }
			end
		end
		if ev then
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
		-- drop pass goes tail-first (safe removal mid-iteration);
		-- apply pass goes head-first so chains land in order —
		-- a cancel/claim must see the post that created the row
		for i = #L, 1, -1 do
			if evDrop(L[i], byId, res, pullT) then
				table.remove(L, i)
			end
		end
		for _, ev in ipairs(L) do
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

function OR.Post(board, itemID, qty, ppu, ttl, charname)
	local poster = charname or CharName()
	local rid = OR.Stage({
		v = "post", b = board, itemID = itemID, qtyTotal = qty,
		pricePerUnit = ppu, claimTTL = ttl, poster = poster,
		backed = OR.PurseCovers(ppu * qty),
	})
	local inst = OR.MyInstallID() or "?"
	local ev = { v = "post", rid = rid, board = board,
		itemID = itemID, qtyTotal = qty, pricePerUnit = ppu,
		ttl = ttl, poster = poster, posterUUID = OR.MyUUID() }
	if inst ~= "?" then ev.realID = inst .. ":" .. rid end
	OR.LiveEvent(board, ev)
	OR.MeshSend(table.concat({ "P", board, rid, itemID, qty, ppu,
		ttl or 0, inst, OR.MyUUID() or "?", poster }, ";"))
	return rid
end

function OR.Claim(board, oid, units, charname)
	local crafter = charname or CharName()
	local rid = OR.Stage({
		v = "claim", b = board, oid = oid, units = units,
		crafter = crafter,
	})
	local inst = OR.MyInstallID() or "?"
	local ev = { v = "claim", rid = rid, oid = oid, units = units,
		crafter = crafter, crafterUUID = OR.MyUUID() }
	if inst ~= "?" then ev.cid = inst .. ":" .. rid end
	OR.LiveEvent(board, ev)
	OR.MeshSend(table.concat({ "C", board, oid, rid, units,
		inst, OR.MyUUID() or "?", crafter }, ";"))
	return rid
end

function OR.Fill(board, oid, units, cid, mailFrom)
	local rid = OR.Stage({
		v = "fill", b = board, oid = oid, units = units,
		commit = cid, mailFrom = mailFrom,
	})
	OR.LiveEvent(board, { v = "fill", rid = rid, oid = oid,
		units = units, cid = cid })
	OR.MeshSend(table.concat({ "F", board, oid, units,
		cid or "" }, ";"))
	return rid
end

function OR.Reject(board, oid, cid, mailFrom)
	local rid = OR.Stage({ v = "reject", b = board, oid = oid,
		commit = cid, mailFrom = mailFrom })
	OR.LiveEvent(board, { v = "reject", rid = rid, oid = oid,
		cid = cid })
	OR.MeshSend(table.concat({ "R", board, oid, cid or "" }, ";"))
	return rid
end

function OR.Cancel(board, oid, units)
	local rid = OR.Stage({ v = "cancel", b = board, oid = oid,
		units = units })
	OR.LiveEvent(board, { v = "cancel", rid = rid, oid = oid,
		units = units or 0 })
	OR.MeshSend(table.concat({ "X", board, oid, units or 0 }, ";"))
	return rid
end

function OR.Release(board, cid, oid)
	local rid = OR.Stage({ v = "release", b = board, cid = cid })
	OR.LiveEvent(board, { v = "release", rid = rid, oid = oid,
		cid = cid })
	OR.MeshSend(table.concat({ "L", board, oid or "", cid }, ";"))
	return rid
end

-- mesh 'O' receive: ';'-separated records — ':' can't be the
-- separator because server ids are 'install:op' and carry colons;
-- ';' is illegal in char names, board scopes, and rids.
function OR.MeshEvent(rec)
	local f = {}
	for x in rec:gmatch("[^;]*") do f[#f + 1] = x end
	local v = f[1]
	if v == "P" then
		local ev = { v = "post", board = f[2],
			itemID = tonumber(f[4]), qtyTotal = tonumber(f[5]),
			pricePerUnit = tonumber(f[6]), ttl = tonumber(f[7]),
			posterUUID = f[9], poster = f[10] }
		if f[8] and f[8] ~= "?" and f[8] ~= "0" then
			ev.realID = f[8] .. ":" .. f[3]
		end
		if ev.itemID and ev.qtyTotal then OR.LiveEvent(f[2], ev) end
	elseif v == "C" then
		local ev = { v = "claim", board = f[2], oid = f[3],
			units = tonumber(f[5]), crafterUUID = f[7], crafter = f[8] }
		if f[6] and f[6] ~= "?" and f[6] ~= "0" then
			ev.cid = f[6] .. ":" .. f[4]
		end
		if ev.oid and ev.units then OR.LiveEvent(f[2], ev) end
	elseif v == "F" then
		OR.LiveEvent(f[2], { v = "fill", oid = f[3],
			units = tonumber(f[4]), cid = f[5] })
	elseif v == "R" then
		OR.LiveEvent(f[2], { v = "reject", oid = f[3], cid = f[4] })
	elseif v == "X" then
		OR.LiveEvent(f[2], { v = "cancel", oid = f[3],
			units = tonumber(f[4]) or 0 })
	elseif v == "L" then
		OR.LiveEvent(f[2], { v = "release", oid = f[3], cid = f[4] })
	end
end

function OR.Ignore(uuid, on)
	return OR.Stage({ v = "ignore", uuid = uuid, on = on })
end

function OR.BoardBan(board, uuid, on)
	return OR.Stage({ v = "ban", b = board, uuid = uuid, on = on })
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
