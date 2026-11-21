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

function OR.Orders(name)
	local b = OR.Board(name)
	return b and b.orders or {}
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

function OR.Post(board, itemID, qty, ppu, ttl, charname)
	return OR.Stage({
		v = "post", b = board, itemID = itemID, qtyTotal = qty,
		pricePerUnit = ppu, claimTTL = ttl, poster = charname or CharName(),
		backed = OR.PurseCovers(ppu * qty),
	})
end

function OR.Claim(board, oid, units, charname)
	return OR.Stage({
		v = "claim", b = board, oid = oid, units = units,
		crafter = charname or CharName(),
	})
end

function OR.Fill(board, oid, units, cid, mailFrom)
	return OR.Stage({
		v = "fill", b = board, oid = oid, units = units,
		commit = cid, mailFrom = mailFrom,
	})
end

function OR.Reject(board, oid, cid, mailFrom)
	return OR.Stage({ v = "reject", b = board, oid = oid,
		commit = cid, mailFrom = mailFrom })
end

function OR.Cancel(board, oid, units)
	return OR.Stage({ v = "cancel", b = board, oid = oid, units = units })
end

function OR.Release(board, cid)
	return OR.Stage({ v = "release", b = board, cid = cid })
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
