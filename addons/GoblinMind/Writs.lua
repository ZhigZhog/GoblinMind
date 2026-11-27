local _, GM = ...

-- Crafting writs v2 — open shops and point-to-point work requests
-- (craft-orders-proposal revision, 2026-11-26). The buy-order board
-- model flips: the CRAFTER publishes a roster ("open shop") on a
-- board; the customer browses rosters and addresses a writ — "make
-- this for me" — to that crafter's install uuid. Requests can also
-- ride real mail as GMW1-tagged letters for non-addon players.
--
-- Same staged-op transport as Orders.lua: the addon never talks to
-- the server. Ops stage into GoblinMindSettings.writQueue as
-- "wrt-<ts>-<n>|hex"; the watcher POSTs them; results return in
-- GoblinMindDB.writResults[rid]; roster pulls land in
-- GoblinMindDB.rosters[board]; the private inbox lands in
-- GoblinMindDB.writs = {in={...}, out={...}}. Everything is
-- flush-timescale — /reload refreshes the shop.

GM.Writs = {}
local W = GM.Writs

-- tiny flat-map JSON writer + hex staging — local copies per the
-- codebase convention (Settings.lua keeps its own HexEnc too)
local function hexenc(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end
local function unhex(h)
	return (h:gsub("..", function(p)
		return string.char(tonumber(p, 16))
	end))
end
local function jesc(s)
	return (tostring(s):gsub('[%z\1-\31\\"]', function(c)
		return string.format("\\u%04x", c:byte())
	end))
end
-- recursive JSON writer — offers carry nested rows so the flat
-- OpJSON can't pack them; the server json.loads() this string field
local function JEnc(v)
	local t = type(v)
	if t == "number" then return tostring(v) end
	if t == "boolean" then return v and "true" or "false" end
	if t == "string" then return '"' .. jesc(v) .. '"' end
	if t ~= "table" then return "null" end
	local n, isArr = 0, true
	for k in pairs(v) do
		n = n + 1
		if type(k) ~= "number" then isArr = false end
	end
	local parts = {}
	if isArr then
		for _, x in ipairs(v) do parts[#parts + 1] = JEnc(x) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	for k, x in pairs(v) do
		parts[#parts + 1] = '"' .. jesc(k) .. '":' .. JEnc(x)
	end
	return "{" .. table.concat(parts, ",") .. "}"
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
	return (GM.OwnName and GM.OwnName())
		or (UnitName and UnitName("player")) or "?"
end

-- ============ identity (delegated to Orders when present) ============

function W.MyUUID()
	if GM.Orders and GM.Orders.MyUUID then return GM.Orders.MyUUID() end
	return GoblinMindDB and GoblinMindDB.backend
		and GoblinMindDB.backend.install or nil
end

function W.MyBoards()
	local out, seen = {}, {}
	local be = GoblinMindDB and GoblinMindDB.backend
	for _, b in ipairs(be and be.boards or {}) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	for b in pairs(GoblinMindDB and GoblinMindDB.rosters or {}) do
		if not seen[b] then seen[b] = true; out[#out + 1] = b end
	end
	table.sort(out)
	return out
end

-- ============ roster: what my shop sells ============
-- Sources: the crafting scan's learned recipes (craft) + services
-- (enchant/lock work — no output item), plus hand-entered services in
-- GM.db.shopOffers. Per-offer terms (price, who supplies mats, note)
-- persist in GM.db.shopTerms[ref] so republishing keeps the shop's
-- pricing across sessions.

local function TermsFor(ref)
	local t = GM.db and GM.db.shopTerms and GM.db.shopTerms[ref]
	return (type(t) == "table") and t or {}
end

-- MY SHOP writes these: on/off, price, mats policy, note — all
-- persist so republishing keeps the shop's pricing across sessions
function W.SetTerms(ref, key, val)
	if not (GM.db and ref) then return end
	GM.db.shopTerms = GM.db.shopTerms or {}
	local t = GM.db.shopTerms[ref] or {}
	t[key] = val
	GM.db.shopTerms[ref] = t
end

function W.Terms(ref)
	return TermsFor(ref)
end

-- profession → owning toon, inferred from stamped rows: a recipe
-- scanned before toon-stamps existed has no owner — guess its
-- profession's known owner rather than crediting whoever happens
-- to be publishing (the "alt owns my Engineer's offers" bug).
-- Two stamped owners for one prof → ambiguous → don't guess.
-- a stamp is a claim that char knows the recipe — a char whose
-- recorded prof list lacks the profession provably can't (foreign-
-- session scans stamped lies). nil recorded list = unknown →
-- benefit of the doubt.
local function TrustedStamp(toon, prof)
	if not toon then return nil end
	local known = GM.db and GM.db.charProfs
	local tk = (GM.FirstName and GM.FirstName(toon)) or toon
	local cp = known and known[tostring(tk):lower()]
	if cp and not cp[tostring(prof or ""):lower()] then return nil end
	return toon
end

local function ProfOwners()
	local own = {}
	for _, tbl in ipairs({ GoblinMindCrafting
			and GoblinMindCrafting.recipes,
			GoblinMindCrafting and GoblinMindCrafting.services }) do
		for _, r in pairs(tbl or {}) do
			if type(r) == "table" and r.toon and r.prof then
				local stamp = TrustedStamp(r.toon, r.prof)
				if stamp then
					local k = tostring(r.prof):lower()
					if own[k] == nil then own[k] = stamp
					elseif own[k] ~= stamp then own[k] = false end
				end
			end
		end
	end
	return own
end

function W.RosterOffers()
	local out = {}
	local owners
	local function ownerFor(stamp, prof)
		owners = owners or ProfOwners()
		return TrustedStamp(stamp, prof)
			or owners[(prof or ""):lower()] or CharName()
	end
	-- ';' is the relay envelope's field delimiter — offer text must
	-- never carry it (JSON in the queue is hex-packed and fine; the
	-- tunneled copy is not)
	local profs = GoblinMindCrafting
		and (GoblinMindCrafting.recipes or {}) or {}
	for id, r in pairs(profs) do
		if not r.unlearned and r.name then
			local ref = "r:" .. id
			local t = TermsFor(ref)
			out[#out + 1] = {
				ref = ref, name = r.name:gsub(";", " "),
				prof = r.prof and r.prof:gsub(";", " ") or nil,
				itemID = r.itemID, kind = "craft",
				numMade = r.numMade or 1, on = t.on == true,
				-- the toon stamped at scan time owns the recipe —
				-- requests route to it, not to chars[1]
				toon = ownerFor(t.toon or r.toon, r.prof),
				price = t.price, mats = t.mats,
				note = t.note and t.note:gsub(";", " ") or nil,
			}
		end
	end
	local svc = GoblinMindCrafting
		and (GoblinMindCrafting.services or {}) or {}
	for id, r in pairs(svc) do
		if r.name then
			local ref = "s:" .. id
			local t = TermsFor(ref)
			out[#out + 1] = {
				ref = ref, name = r.name:gsub(";", " "),
				prof = r.prof and r.prof:gsub(";", " ") or nil,
				kind = "service", on = t.on == true,
				toon = ownerFor(t.toon or r.toon, r.prof),
				price = t.price, mats = t.mats,
				note = t.note and t.note:gsub(";", " ") or nil,
			}
		end
	end
	-- hand-entered work that the tradeskill scan can't see —
	-- lockpicking, portals, summons. Every entry carries its own ref.
	for _, s in ipairs(GM.db and GM.db.shopOffers or {}) do
		if type(s) == "table" and s.name and s.ref
				and not tostring(s.ref):find(";") then
			local t = TermsFor(s.ref)
			out[#out + 1] = {
				ref = s.ref, name = tostring(s.name):gsub(";", " "),
				prof = s.prof and tostring(s.prof):gsub(";", " ") or nil,
				kind = s.kind == "service" and "service" or "craft",
				itemID = s.itemID, on = t.on == true,
				toon = s.toon and tostring(s.toon):gsub(";", " ")
					or ownerFor(t.toon, s.prof),
				price = t.price or s.price,
				mats = t.mats or s.mats,
				note = (t.note or s.note)
					and tostring(t.note or s.note):gsub(";", " "),
			}
		end
	end
	table.sort(out, function(a, b)
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

-- resolve an offer ref back to scan data (mats, icon item)
function W.Resolve(ref)
	local kind, id = tostring(ref or ""):match("^(%l+):(%d+)$")
	id = tonumber(id)
	if not id then return nil end
	if kind == "r" then
		return GoblinMindCrafting
			and GoblinMindCrafting.recipes
			and GoblinMindCrafting.recipes[id]
	elseif kind == "s" then
		return GoblinMindCrafting
			and GoblinMindCrafting.services
			and GoblinMindCrafting.services[id]
	end
end

-- ============ price suggestion ============
-- "Suggested price" is data we already have: mat cost from the book's
-- per-item values, market anchor from the model price of the crafted
-- item. Returns the numbers and ONE suggestion — mats + 15% service
-- margin for recipes, mat-free services fall back to any scan-mat
-- cost (enchant dusts do exist) with a flat skill fee.

function W.Suggest(ref, qty)
	qty = math.max(1, math.floor(tonumber(qty) or 1))
	local r = W.Resolve(ref)
	if not r then return nil end
	local mats = 0
	for _, m in ipairs(r.mats or {}) do
		local v = m.id and (GM.Price("dbmarket", m.id)
			or (GM.ItemEntry(m.id) or {}).mb) or 0
		mats = mats + v * (m.qty or 1)
	end
	mats = mats * qty
	local market = r.itemID
		and (GM.Price("dbmarket", r.itemID)
			or (GM.ItemEntry(r.itemID) or {}).mb) or nil
	if market then market = market * qty end
	local price
	if market and market > 0 then
		-- crafted goods: never under the finished-item market
		price = math.floor(math.max(market * 0.97, mats * 1.15) + 0.5)
	elseif mats > 0 then
		price = math.floor(mats * 1.25 + 0.5)
	else
		price = nil
	end
	return { mats = mats > 0 and mats or nil, market = market,
		price = price }
end

-- ============ staged ops ============

function W.Stage(fields)
	local rid = string.format("wrt-%d-%d", time(), math.random(100, 999))
	GM.db.writQueue = GM.db.writQueue or {}
	GM.db.writQueue[#GM.db.writQueue + 1] =
		rid .. "|" .. hexenc(OpJSON(fields))
	return rid
end

-- publish the whole roster (replace semantics) on a joined board
function W.Publish(board)
	if not board or board == "" then return nil end
	local chars, seenC = {}, {}
	-- every char key the ledger knows = a toon the shop can be
	-- reached through; the mail channel needs real names
	for k in pairs(GoblinMindLedger and GoblinMindLedger.byChar or {}) do
		local c = tostring(k):match("^(.-)%-") or tostring(k)
		-- mail needs the surname on Forever — publish the
		-- deliverable form when any source can resolve it
		c = (GM.FullName and GM.FullName(c)) or c
		-- bare + realm-qualified + resolved forms of one toon
		-- collapse — dedup AFTER resolution
		local key = c:lower()
		if not seenC[key] then
			seenC[key] = true
			chars[#chars + 1] = c
		end
	end
	if #chars == 0 then chars[1] = CharName() end
	table.sort(chars)
	local enabled = {}
	for _, o in ipairs(W.RosterOffers()) do
		if o.on then
			o.on = nil
			o.toon = (GM.FullName and GM.FullName(o.toon))
				or o.toon
			enabled[#enabled + 1] = o
		end
	end
	-- our own roster is known NOW — the pulled copy lags by
	-- watcher-flush cadence (staged op → POST → pull → emit →
	-- reload). Cache it so W.Rosters can overlay instantly; a
	-- pulled row for our uuid wins once it proves newer.
	if GM.db then
		GM.db.localRosters = GM.db.localRosters or {}
		GM.db.localRosters[board] = { t = time(), uuid = W.MyUUID(),
			chars = chars, offers = enabled }
	end
	return W.Op("roster", board, {
		chars = table.concat(chars, ","),
		offers = JEnc(enabled),
	})
end

-- address a work request to a roster owner's install uuid
function W.Request(board, toUUID, toChar, f)
	if not (board and toUUID) then return nil end
	f = f or {}
	return W.Op("wpost", board, {
		to = toUUID,
		toChar = (GM.FullName and GM.FullName(toChar))
			or toChar or "?", fromChar = CharName(),
		ref = f.ref or "", name = f.name or "Work request",
		itemID = f.itemID, qty = f.qty or 1,
		offer = f.offer or 0,
		mats = f.mats or "buyer",
		deliver = f.deliver or "cod",
		note = f.note or "",
	})
end

-- lifecycle verbs on an existing writ — pass the writ row (or bare
-- id); the board resolves off the row/inbox when not given
function W.Act(verb, w, fields)
	local wid, board
	if type(w) == "table" then
		wid, board = w.id, w.board
	else
		wid = w
	end
	if not wid then return nil end
	fields = fields or {}
	fields.wid = wid
	return W.Op(verb, board or fields.b or W.BoardOf(wid), fields)
end

-- ============ reads ============

-- a locally-published roster rides over the pulled copy for this
-- long — beyond boards-pull cadence + slack; after it the server
-- view (however old) is honest again
local LOCAL_ROSTER_TTL = 1800

function W.Rosters(board)
	-- remote board = the relay stream's roster rows (y records)
	local rows
	if GM.Orders and GM.Orders.IsRemote
			and GM.Orders.IsRemote(board) then
		local rb = GM.Orders.RBoard and GM.Orders.RBoard(board)
		rows = (rb and rb.rosters) or {}
	else
		local b = GoblinMindDB and GoblinMindDB.rosters
			and GoblinMindDB.rosters[board]
		rows = (b and b.rosters) or {}
	end
	-- overlay our own publish while the pull lags behind it
	local lr = GM.db and GM.db.localRosters
		and GM.db.localRosters[board]
	local me = W.MyUUID()
	if lr and me and lr.uuid == me
			and time() - (lr.t or 0) < LOCAL_ROSTER_TTL then
		local mine
		for _, r in ipairs(rows) do
			if r.uuid == me then mine = r break end
		end
		if not mine or (mine.t or 0) < lr.t then
			local out = {}
			for _, r in ipairs(rows) do
				if r.uuid ~= me then out[#out + 1] = r end
			end
			out[#out + 1] = { uuid = me, chars = lr.chars,
				offers = lr.offers, t = lr.t,
				stats = mine and mine.stats }
			return out
		end
	end
	-- the published payload's toon is whatever the stamp chain said
	-- at publish time — an old publish can mis-attribute (or drop
	-- the field outright: older servers whitelisted it away). Our
	-- own row re-resolves against the live recipe DB so a stale
	-- publish can't outlive current truth.
	if me then
		for _, r in ipairs(rows) do
			if r.uuid == me and type(r.offers) == "table" then
				local live
				for _, o in ipairs(r.offers) do
					if o.ref then
						if not live then
							live = {}
							for _, ro in ipairs(W.RosterOffers()) do
								live[ro.ref] = ro.toon
							end
						end
						if live[o.ref] then o.toon = live[o.ref] end
					end
				end
			end
		end
	end
	return rows
end

function W.RosterStamp(board)
	local t
	if GM.Orders and GM.Orders.IsRemote
			and GM.Orders.IsRemote(board) then
		local rb = GM.Orders.RBoard and GM.Orders.RBoard(board)
		t = (rb and rb.t) or 0
	else
		local b = GoblinMindDB and GoblinMindDB.rosters
			and GoblinMindDB.rosters[board]
		t = (b and b.t) or 0
	end
	local lr = GM.db and GM.db.localRosters
		and GM.db.localRosters[board]
	if lr and lr.uuid == W.MyUUID()
			and time() - (lr.t or 0) < LOCAL_ROSTER_TTL
			and (lr.t or 0) > t then
		t = lr.t
	end
	return t
end

function W.Pending()
	local res = W.Results()
	local out = {}
	for _, s in ipairs(GM.db.writQueue or {}) do
		local rid = s:match("^(wrt%-[^|]+)")
		if rid and not res[rid] then out[#out + 1] = rid end
	end
	return out
end

function W.ClearAcked()
	local res = W.Results()
	local q = GM.db.writQueue
	if not q then return end
	for i = #q, 1, -1 do
		local rid = q[i]:match("^(wrt%-[^|]+)")
		if rid and res[rid] then table.remove(q, i) end
	end
end

-- ============ live overlay (mesh 'V' events) ============
-- Same hint-vs-truth contract as Orders' 'O' records: writ events
-- ride the writ bus so an online crafter's MY WRITS sees a request
-- in seconds; the /v1/writs pull stays authoritative — a pull that
-- already shows the ev's effect CONFIRMS it out, a failed rid or a
-- 10-min orphan TTL drops it.

W.live = {}            -- [board] = {ev, ...}, session-only
local LIVE_TTL = 600
local _evSeq = 0

function W.LiveEvent(board, ev)
	if not board or board == "" then return end
	ev.t = math.min(ev.t or time(), time())
	_evSeq = _evSeq + 1
	ev.seq = _evSeq
	local L = W.live[board]
	if not L then L = {} W.live[board] = L end
	L[#L + 1] = ev
	while #L > 200 do table.remove(L, 1) end
	GM.View.Refresh("orders")
end

-- ';' is the record-field delimiter and ',' the batch delimiter —
-- every free-text field scrubs both before touching either wire
local function clean(s)
	return (tostring(s or ""):gsub("[;,\r\n]", " "))
end

-- one-letter wire: V;<board>;<verb>;<rid>;<inst>;<actor>;<t>;<tail>
-- ':' inside ids ('install:op') is safe — only ';' splits fields
local WVERBS = {}

local function widApply(ev, view, byId)
	local w = byId[ev.wid]
	if not w then return end
	w.updated = ev.t
	w._pendOp = ev.v
	return w
end

-- a verb that just moves state — most verbs are this
local function stateApply(state)
	return function(ev, view, byId)
		local w = widApply(ev, view, byId)
		if w then w.state = state end
	end
end
-- a pull state AT or PAST the ev's state confirms it out — 'done'
-- can only be reached through 'shipped', so a terminal pull also
-- clears the earlier shadows (a fast pull cycle would otherwise
-- leave 'shipped' painted over 'done' for the full hint TTL)
local WRIT_RANK = { open = 1, quoted = 2, agreed = 3, shipped = 4,
	done = 5 }
local WRIT_TERMINAL = { done = true, declined = true,
	cancelled = true, expired = true }
local function stateConfirm(state)
	return function(ev, byId)
		local w = byId[ev.wid]
		if not w then return false end
		if w.state == state or WRIT_TERMINAL[w.state] then
			return true
		end
		return (WRIT_RANK[w.state] or 0) > (WRIT_RANK[state] or 0)
	end
end
-- fields = verb-tail keys the ev needs; apply writes them onto w
local function fieldApply(state, ...)
	local keys = { ... }
	return function(ev, view, byId)
		local w = widApply(ev, view, byId)
		if not w then return end
		if state then w.state = state end
		for _, k in ipairs(keys) do
			if ev[k] ~= nil then w[k] = ev[k] end
		end
		if ev.price then w.price = ev.price end
	end
end

WVERBS.wpost = {
	-- the new-writ hint: only paints for a party (privacy — the
	-- broadcast channel hears every writ but only from/to see it)
	ev = function(f, rid)
		local inst = GM.Orders and GM.Orders.MyInstallID
			and GM.Orders.MyInstallID()
		return {
			wid = (inst or "?") .. ":" .. rid,
			to = f.to, toChar = f.toChar, fromChar = f.fromChar,
			ref = f.ref, name = f.name, itemID = f.itemID,
			qty = f.qty, offer = f.offer, mats = f.mats,
			deliver = f.deliver,
			actor = W.MyUUID(), fromUUID = W.MyUUID(),
		}
	end,
	wire = function(ev, rid, board)
		return table.concat({ "V", board, "wpost", rid,
			GM.Orders and GM.Orders.MyInstallID() or "?",
			ev.actor or "?", ev.t or time(),
			ev.to or "-", clean(ev.toChar), clean(ev.fromChar),
			ev.ref or "-", clean(ev.name), ev.itemID or 0,
			ev.qty or 1, ev.offer or 0, ev.mats or "buyer",
			ev.deliver or "cod" }, ";")
	end,
	parse = function(f)
		local ev = {
			wid = (f[5] or "?") .. ":" .. (f[4] or "?"),
			to = f[8] ~= "-" and f[8] or nil, toChar = f[9],
			fromChar = f[10], ref = f[11] ~= "-" and f[11] or nil,
			name = f[12], itemID = tonumber(f[13]),
			qty = tonumber(f[14]), offer = tonumber(f[15]),
			mats = f[16] ~= "-" and f[16] or nil,
			deliver = f[17] ~= "-" and f[17] or nil,
			fromUUID = f[6] ~= "-" and f[6] or nil,
		}
		return ev
	end,
	apply = function(ev, view, byId, me)
		-- not my writ, not my pane
		if ev.to ~= me and ev.actor ~= me then return end
		if not ev.wid or byId[ev.wid] then return end
		local w = {
			id = ev.wid, board = ev.board, state = "open",
			_rid = ev.rid,
			fromUUID = ev.actor, fromChar = ev.fromChar,
			toUUID = ev.to, toChar = ev.toChar,
			ref = ev.ref, name = ev.name, itemID = ev.itemID,
			qty = ev.qty, offer = ev.offer, mats = ev.mats,
			deliver = ev.deliver, price = ev.offer,
			created = ev.t, updated = ev.t,
			expires = (ev.t or time()) + 72 * 3600,
			_live = true, _pendOp = "wpost",
		}
		byId[w.id] = w
		w._side = (ev.to == me) and "inb" or "out"
		view[w._side][#view[w._side] + 1] = w
	end,
	confirm = function(ev, byId)
		return ev.wid and byId[ev.wid] ~= nil
	end,
	replay = function(f, ctx)
		return {
			wid = (ctx.inst or "?") .. ":" .. (ctx.rid or "?"),
			to = f.to, toChar = f.toChar, fromChar = f.fromChar,
			ref = f.ref, name = f.name, itemID = f.itemID,
			qty = f.qty, offer = f.offer, mats = f.mats,
			deliver = f.deliver, actor = ctx.uuid,
		}
	end,
}

local function widEv(f)
	return { wid = f.wid }
end
local function widWire(verb, ...)
	local keys = { ... }
	return function(ev, rid, board)
		local p = { "V", board, verb, rid or "-",
			ev.inst or "?", ev.actor or "?", ev.t or time() }
		p[#p + 1] = ev.wid or "-"
		for _, k in ipairs(keys) do
			p[#p + 1] = clean(ev[k]) ~= "" and clean(ev[k]) or "-"
		end
		return table.concat(p, ";")
	end
end
local function widParse(...)
	local keys = { ... }
	return function(f)
		local ev = { wid = f[8] ~= "-" and f[8] or nil }
		if not ev.wid then return nil end
		for i, k in ipairs(keys) do
			local v = f[8 + i]
			if v and v ~= "-" then
				ev[k] = tonumber(v) or v
			end
		end
		return ev
	end
end
-- staged-queue replay for the simple verbs — everything needed is
-- already on the op fields
local function widReplay(...)
	local keys = { ... }
	return function(f, ctx)
		local ev = { wid = f.wid, actor = ctx.uuid }
		for _, k in ipairs(keys) do ev[k] = f[k] end
		return ev
	end
end

WVERBS.wquote = {
	ev = function(f) return { wid = f.wid, price = f.price } end,
	wire = widWire("wquote", "price"),
	parse = widParse("price"),
	apply = function(ev, view, byId)
		local w = widApply(ev, view, byId)
		if w then
			w.state = "quoted"
			w.quote = ev.price or w.quote
			w.price = ev.price or w.price
		end
	end,
	confirm = stateConfirm("quoted"),
	replay = widReplay("price"),
}
WVERBS.waccept = {
	ev = function(f) return { wid = f.wid, meet = f.meet,
		matsFp = f.matsFp } end,
	wire = widWire("waccept", "meet", "matsFp"),
	parse = widParse("meet", "matsFp"),
	apply = fieldApply("agreed", "meet", "matsFp"),
	confirm = stateConfirm("agreed"),
	replay = widReplay("meet", "matsFp"),
}
WVERBS.wdecline = {
	ev = widEv, wire = widWire("wdecline"), parse = widParse(),
	apply = stateApply("declined"),
	confirm = stateConfirm("declined"), replay = widReplay(),
}
WVERBS.wship = {
	ev = function(f) return { wid = f.wid, cod = f.cod,
		mailFrom = f.mailFrom } end,
	wire = widWire("wship", "cod", "mailFrom"),
	parse = widParse("cod", "mailFrom"),
	apply = fieldApply("shipped", "cod", "mailFrom"),
	confirm = stateConfirm("shipped"),
	replay = widReplay("cod", "mailFrom"),
}
WVERBS.wrecv = {
	ev = widEv, wire = widWire("wrecv"), parse = widParse(),
	apply = stateApply("done"),
	confirm = stateConfirm("done"), replay = widReplay(),
}
WVERBS.wcancel = {
	ev = widEv, wire = widWire("wcancel"), parse = widParse(),
	apply = stateApply("cancelled"),
	confirm = stateConfirm("cancelled"), replay = widReplay(),
}
WVERBS.wmeet = {
	ev = function(f) return { wid = f.wid, meet = f.meet,
		matsFp = f.matsFp } end,
	wire = widWire("wmeet", "meet", "matsFp"),
	parse = widParse("meet", "matsFp"),
	apply = fieldApply(nil, "meet", "matsFp"),
	confirm = function(ev, byId)
		local w = byId[ev.wid]
		if not w then return false end
		return (ev.meet and w.meet == ev.meet)
			or (ev.matsFp and w.matsFp == ev.matsFp) or false
	end,
	replay = widReplay("meet", "matsFp"),
}
-- roster publish hints nothing — the offer payload can't ride a
-- mesh record; stage-only verb (the pull carries the shop)
WVERBS.roster = {}

function W.MeshSend(rec)
	if GM.Mesh and GM.Mesh.Send then
		GM.Mesh.Send("V", { rec })
	end
end

function W.MeshEvent(rec)
	local f = {}
	for x in rec:gmatch("[^;]*") do f[#f + 1] = x end
	if f[1] ~= "V" then return end
	local def = WVERBS[f[3]]
	local ev = def and def.parse and def.parse(f)
	if ev then
		ev.v = f[3]
		ev.rid = f[4] ~= "-" and f[4] or nil
		ev.inst = f[5] ~= "-" and f[5] or nil
		ev.actor = f[6] ~= "-" and f[6] or nil
		ev.t = tonumber(f[7])
		W.LiveEvent(f[2], ev)
	end
end

local function evConfirmed(ev, byId, liveIds)
	local def = WVERBS[ev.v]
	return (def and def.confirm)
		and (def.confirm(ev, byId, liveIds) and true or false)
		or false
end

local function evDrop(ev, byId, res, pullT, liveIds)
	if ev.rid then
		local r = res[ev.rid]
		if r and not r.ok then return true end
		if r and r.ok and (pullT or 0) >= (r.t or 0)
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
	return c
end

-- drop a staged op that never landed (remote rejects unwind the
-- queue entry so a /reload can't re-pend it)
function W.Unstage(rid)
	if not rid then return end
	local q = GM.db and GM.db.writQueue
	if not q then return end
	for i = #q, 1, -1 do
		if q[i]:match("^wrt%-[^|]+") == rid then
			table.remove(q, i)
		end
	end
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

-- staged-but-unconsumed ops survive in the SV queue — replay them
-- into the live overlay on first read, same contract as Orders:
-- ClearAcked drops answered rids, so what's left is unconfirmed
local _replayed = false
function W.ReplayPending()
	if _replayed then return end
	_replayed = true
	local ctx = {}
	for _, rec in ipairs(GM.db and GM.db.writQueue or {}) do
		local rid, h = rec:match("^(wrt%-[^|]+)|(%x+)$")
		local f = h and unjson(unhex(h)) or nil
		local b = f and f.b or nil
		ctx.inst = (f and f.rly and GM.Orders
			and GM.Orders.RelayCreds(b)
			and GM.Orders.RelayCreds(b).i)
			or (GM.Orders and GM.Orders.MyInstallID
				and GM.Orders.MyInstallID()) or "?"
		ctx.uuid = W.MyUUID()
		ctx.rid = rid
		local def = f and WVERBS[f.v]
		local ev = def and def.replay and def.replay(f, ctx)
		if ev and b then
			ev.v, ev.rid, ev.board = f.v, rid, b
			ev.rly = f.rly and true or nil
			ev.t = tonumber(rid:match("^wrt%-(%d+)"))
			local dup = false
			for _, e in ipairs(W.live[b] or {}) do
				if e.rid == rid then dup = true break end
			end
			if not dup then W.LiveEvent(b, ev) end
		end
	end
end

-- ============ THE op path ============
-- Mirror of OR.Op: stage -> overlay ev -> mesh hint, with the same
-- relay detour for boards our own tracker doesn't serve. Every verb
-- wrapper funnels here so an op can never partially fire.
function W.Op(verb, board, fields, evFields)
	local def = WVERBS[verb]
	if not def then return nil end
	fields = fields or {}
	fields.v = verb
	fields.b = fields.b or board
	board = fields.b
	local remote = board and GM.Orders and GM.Orders.IsRemote
		and GM.Orders.IsRemote(board)
	local creds
	if remote then
		creds = GM.Orders.RelayCreds(board)
		if not creds then
			GM.Orders.RelayRegister(board)
			GM.Orders.RelayQueueOp(board, verb, fields)
			return nil
		end
		fields.rly = 1
	end
	local rid = W.Stage(fields)
	local ev = evFields or (def.ev and def.ev(fields, rid))
	if ev then
		ev.v = verb
		ev.rid = rid
		ev.board = board
		if remote then
			ev.rly = true
			-- server-side ids resolve under OUR relay install —
			-- creds.i is the install the Y reply issued us
			if creds.i and verb == "wpost" then
				ev.wid = creds.i .. ":" .. rid
			end
		end
		W.LiveEvent(board, ev)
		-- remote ops skip the channel record — a same-named board
		-- on a peer's tracker is a different swarm's data
		if def.wire and not remote then
			W.MeshSend(def.wire(ev, rid, board))
		end
	end
	if remote then
		GM.Orders.RelaySend(board, verb, fields, rid, creds)
	end
	return rid
end

-- ============ composed view (pull truth + live hints) ============

-- results feed folds relayed-op failures (X records) the way
-- OR.Results does — remote rejects must drop evs like local ones
function W.Results()
	local r = GoblinMindDB and GoblinMindDB.writResults or {}
	local re = GM.db and GM.db.relayErr
	if not re then return r end
	local merged = {}
	for k, v in pairs(r) do merged[k] = v end
	for rid, code in pairs(re) do
		if not merged[rid] then
			merged[rid] = { ok = false, code = code }
		end
	end
	return merged
end

-- {inb = [...], out = [...], t = pull ts} — pulled truth plus live
-- 'V' hints; _live/_pendOp mark unconfirmed rows for the UI
function W.Writs()
	W.ReplayPending()
	local me = W.MyUUID()
	local w = GoblinMindDB and GoblinMindDB.writs
	local pullT = (w and w.t) or 0
	local view = { inb = {}, out = {}, t = pullT }
	local byId = {}
	for _, o in ipairs((w and w["in"]) or {}) do
		local c = shallow(o)
		c._side = "inb"
		byId[c.id] = c
		view.inb[#view.inb + 1] = c
	end
	for _, o in ipairs((w and w.out) or {}) do
		local c = shallow(o)
		c._side = "out"
		byId[c.id] = c
		view.out[#view.out + 1] = c
	end
	-- tunneled board inbox: staged relay ops are all the customer
	-- sees until their crafter's server-side verbs hint back over
	-- the channel — the composed overlay below is what paints them
	local res = W.Results()
	-- drop pass first (tail-first per list), then apply in global
	-- event order so reordered packets land right
	for _, L in pairs(W.live) do
		for i = #L, 1, -1 do
			if evDrop(L[i], byId, res, pullT) then
				if L[i].rly then W.Unstage(L[i].rid) end
				table.remove(L, i)
			end
		end
	end
	local ord = {}
	for _, L in pairs(W.live) do
		for _, ev in ipairs(L) do ord[#ord + 1] = ev end
	end
	table.sort(ord, function(a, b)
		if (a.t or 0) ~= (b.t or 0) then
			return (a.t or 0) < (b.t or 0)
		end
		return (a.seq or 0) < (b.seq or 0)
	end)
	for _, ev in ipairs(ord) do
		local def = WVERBS[ev.v]
		if def and def.apply then def.apply(ev, view, byId, me) end
	end
	-- local mail channel — never reaches the server: my mailed
	-- requests ride out, parsed GMW1 letters ride in. MY WRITS
	-- labels them unmistakably (mail, not wire).
	view.mailOut = W.MailWrits()
	local mi = {}
	for _, r in pairs(GM.db.writIn or {}) do mi[#mi + 1] = r end
	view.mailIn = mi
	return view
end

-- find a writ's board when the caller only has the id — pulls
-- carry board on every row; live evs keep theirs
function W.BoardOf(wid)
	local w = GoblinMindDB and GoblinMindDB.writs
	for _, side in ipairs({ (w and w["in"]) or {},
		(w and w.out) or {} }) do
		for _, o in ipairs(side) do
			if o.id == wid then return o.board end
		end
	end
	for b, L in pairs(W.live) do
		for _, ev in ipairs(L) do
			if ev.wid == wid or ev.id == wid then return b end
		end
	end
end

-- ============ mail channel (non-addon crafters) ============
-- A writ can leave as a REAL letter: the subject advertises the job,
-- the body carries a machine-readable GMW1 line under the text so a
-- GoblinMind-equipped recipient parses it back into a live request.

W.MAIL_TAG = "GMW1"

function W.MailBody(fields)
	local subject = string.format("[GM Writ] %s x%d",
		fields.name or "Work request", fields.qty or 1)
	local wire = table.concat({
		W.MAIL_TAG, fields.wid or "-", fields.ref or "-",
		tostring(fields.qty or 1), tostring(fields.offer or 0),
		fields.mats or "buyer", fields.deliver or "cod",
		CharName() }, ";")
	local body = string.format(
		"Hello %s,\n\nI need %d x %s made. I can pay %s%s.\n\n— %s\n%s",
		fields.toChar or "crafter", fields.qty or 1,
		fields.name or "work",
		(GM.MoneyShort and GM.MoneyShort(fields.offer or 0))
			or tostring(fields.offer or 0),
		fields.note and fields.note ~= ""
			and ("\n" .. fields.note) or "",
		CharName(), wire)
	return subject, body
end

-- inverse of MailBody — MailUI feeds subject+body of suspicious mail
function W.MailParse(subject, body)
	if type(subject) == "string"
		and not subject:match("^%[GM Writ%]") then
		-- tagged replies can keep the subject bare; body decides
		if not (body and body:match(W.MAIL_TAG)) then return nil end
	end
	if type(body) ~= "string" then return nil end
	local line = body:match("(" .. W.MAIL_TAG .. ";[^\n]+)")
	if not line then return nil end
	local f = {}
	for x in line:gmatch("[^;]*") do f[#f + 1] = x end
	if #f < 7 then return nil end
	return {
		wid = f[2] ~= "-" and f[2] or nil,
		ref = f[3] ~= "-" and f[3] or nil,
		qty = tonumber(f[4]), offer = tonumber(f[5]),
		mats = f[6], deliver = f[7],
		fromChar = f[8] ~= "-" and f[8] or nil,
		subject = subject,
	}
end

W.MAIL_TAGLINE = "— sent via GoblinMind (CurseForge)"
local MAIL_TTL = 7 * 86400

local function mailDB(key)
	GM.db[key] = GM.db[key] or {}
	return GM.db[key]
end

-- ============ 2a: mail-channeled writs ============
-- a writ to a non-GM crafter leaves as a REAL letter. Local-only:
-- the server never sees it — MY WRITS shows state 'mailed' until
-- the TTL ages it out. An intentional fork in the lifecycle.

function W.MailRequest(toChar, fields)
	toChar = (GM.FullName and GM.FullName(toChar)) or toChar
	if not (toChar and toChar ~= "") then return nil end
	fields = fields or {}
	fields.wid = fields.wid
		or string.format("ml-%d-%d", time(), math.random(100, 999))
	fields.toChar = toChar
	local subject, body = W.MailBody(fields)
	local ok = GM.Ops.SendMail({ to = toChar, subject = subject,
		body = body .. "\n" .. W.MAIL_TAGLINE })
	if ok then
		mailDB("writMail")[fields.wid] = {
			toChar = toChar, t = time(), state = "mailed",
			name = fields.name, qty = fields.qty,
			offer = fields.offer, mats = fields.mats,
			deliver = fields.deliver, via = "mail",
		}
	end
	return ok and fields.wid or nil
end

-- the local mailed writs, TTL-pruned on read
function W.MailWrits()
	local m, out, cut = mailDB("writMail"), {}, time() - MAIL_TTL
	for wid, r in pairs(m) do
		if (r.t or 0) < cut then m[wid] = nil
		else r.id = wid; out[#out + 1] = r end
	end
	return out
end

-- ============ 2b: inbound GMW1 (crafter side) ============
-- mail↔mesh bridging is v2.1 — the loop here is parse → notify →
-- reply-letter. A mail writ to a GM recipient becomes a local
-- 'received' record the reply flow quotes against.

function W.FromMail(parsed, sender)
	if not parsed then return nil end
	local key = (sender or "?"):lower() .. "|" .. (parsed.subject or "")
	local box = mailDB("writIn")
	if box[key] then return box[key] end
	local rec = { id = key, via = "mail", state = "received",
		sender = sender, t = time(), subject = parsed.subject,
		wid = parsed.wid, ref = parsed.ref, qty = parsed.qty,
		offer = parsed.offer, mats = parsed.mats,
		deliver = parsed.deliver,
		fromChar = parsed.fromChar or sender }
	box[key] = rec
	GM.Print(GM.CC("accent") .. "writ mail from " .. (sender or "?")
		.. (parsed.qty and (" — x" .. parsed.qty) or "") .. "|r")
	return rec
end

-- quote reply to a mail-channel writ — plain letter + GMW1R wire so
-- a GM customer can read the quote back mechanically too
function W.MailReply(rec, price, note)
	local to = rec and (rec.fromChar or rec.sender)
	if not to then return nil end
	local body = string.format("%s\n%s\n%s",
		(note and note ~= "") and note or string.format(
			"I can do that for %s.",
			(GM.MoneyShort and GM.MoneyShort(price or 0))
				or tostring(price or 0)),
		table.concat({ "GMW1R", rec.wid or "-",
			tostring(price or 0), CharName() }, ";"),
		W.MAIL_TAGLINE)
	return GM.Ops.SendMail({ to = to,
		subject = "Re: " .. (rec.subject or "[GM Writ]"),
		body = body })
end

-- ============ inbox wiring (2b/2c/2d) ============
-- one scan feeds three matches: inbound GMW1 letters, mats
-- shipments whose fingerprint rides the writ's matsFp, and COD
-- deliveries on shipped writs. GetInboxText is the costly read —
-- subject-gated and capped per pass.

local inIdx, inScanAt = {}, 0

-- sorted "name:qty" across attachments — the mats fingerprint's
-- item half, computable identically on send and receive sides
local function mailItemCSV(index)
	if not GetInboxItemLink then return "" end
	local parts = {}
	for slot = 1, 20 do
		local link = GetInboxItemLink(index, slot)
		if link then
			local a, b, _, d = GetInboxItem(index, slot)
			local qty = (type(a) == "number" and b)
				or (type(b) == "number" and d) or 1
			parts[#parts + 1] = (link:match("%[(.-)%]") or "?")
				.. ":" .. qty
		end
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function sendItemCSV()
	local parts = {}
	if GetSendMailItem then
		for i = 1, 12 do
			local ret = { GetSendMailItem(i) }
			if ret[1] then
				parts[#parts + 1] = tostring(ret[1]) .. ":"
					.. (tonumber(ret[#ret]) or 1)
			end
		end
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function matsFp(sender, subject, csv)
	-- sender rides the fingerprint — normalize to the base name so a
	-- surname-carrying inbox header still matches the staged fp
	local s = (GM.FirstName and GM.FirstName(sender)) or sender
	return (s or "?"):lower() .. "|" .. (subject or "")
		.. "|" .. (csv or "")
end

function W.ScanInbox(force)
	if not (GetInboxNumItems and GetInboxHeaderInfo) then
		return inIdx
	end
	local now = GetTime()
	if not force and now - inScanAt < 1.5 then return inIdx end
	inScanAt = now
	for k in pairs(inIdx) do inIdx[k] = nil end
	-- toChar stores the deliverable "First Last" on Forever but
	-- inbox senders may come back either form — compare identities
	-- by first name only
	local function FN(s)
		return ((GM.FirstName and GM.FirstName(s)) or s or ""):lower()
	end
	local me, myName = W.MyUUID(), FN(CharName())
	-- customer side: my shipped writs → the crafter's COD lands here
	local codWants, matsWants = {}, nil
	for _, w in ipairs(W.Writs().out) do
		if w.state == "shipped" and w.toChar then
			codWants[FN(w.toChar)] = w
		end
	end
	-- crafter side: agreed writs with a mats fingerprint staged
	for _, w in ipairs(W.Writs().inb) do
		if w.matsFp and w.toUUID == me then
			matsWants = matsWants or {}
			matsWants[w.matsFp] = w
		end
	end
	local box, bodyReads = mailDB("writIn"), 0
	for i = 1, GM.MailCount() do
		local _, _, sender, subject, _, cod, _, items =
			GetInboxHeaderInfo(i)
		subject = subject or ""
		local sLow = (sender or ""):lower()
		if subject:match("^%[GM Writ%]") and FN(sender) ~= myName then
			inIdx[i] = { kind = "gmw1", sender = sender,
				subject = subject }
			local key = sLow .. "|" .. subject
			if box[key] then
				inIdx[i].rec = box[key]
			elseif bodyReads < 2 and GetInboxText then
				bodyReads = bodyReads + 1
				local ok, body = pcall(GetInboxText, i)
				local parsed = ok and W.MailParse(subject, body)
				if parsed then
					inIdx[i].rec = W.FromMail(parsed, sender)
				end
			end
		elseif (cod or 0) > 0 then
			local w = codWants[FN(sender)]
			if w then
				local price = w.price or w.quote or w.offer or 0
				if price <= 0 or math.abs(cod - price)
						<= math.max(1, price * 0.02) then
					inIdx[i] = { kind = "cod", w = w, cod = cod,
						sender = sender, subject = subject }
				end
			end
		elseif (items or 0) > 0 and matsWants then
			local w = matsWants[matsFp(sender, subject, mailItemCSV(i))]
			if w then
				inIdx[i] = { kind = "mats", w = w, sender = sender,
					subject = subject }
			end
		end
	end
	return inIdx
end

-- MailUI's per-row hook — "WRIT" | "RECV" | "MATS" | nil
function W.RowFlag(index)
	local m = W.ScanInbox()[index]
	return m and ({ gmw1 = "WRIT", cod = "RECV", mats = "MATS" })
		[m.kind] or nil
end

function W.MailHit(index)
	return W.ScanInbox()[index]
end

-- ============ 2c: prepaid mats — attach-then-track ============
-- MAIL MATS (customer, mats="prepaid"): whatever sits in the send
-- slots ships to the crafter under a fixed subject; the send's
-- fingerprint stages onto the writ so the crafter's inbox
-- recognizes the shipment. quoted/open → waccept carries it;
-- already-agreed → wmeet updates it.

function W.MailMats(w)
	local wid = type(w) == "table" and w.id or w
	if not wid then return nil end
	w = type(w) == "table" and w or nil
	local to = w and w.toChar
	if not (to and to ~= "" and to ~= "?") then
		GM.Print(GM.CC("warn")
			.. "no crafter char on that writ — can't mail mats|r")
		return nil
	end
	local csv = sendItemCSV()
	if csv == "" then
		GM.Print(GM.CC("warn")
			.. "attach the mats in the send slots first|r")
		return nil
	end
	local subject = "[GM Writ] mats " .. (w.name or wid)
	local fp = matsFp(CharName(), subject, csv)
	local ok = GM.Ops.SendMail({ to = to, subject = subject,
		body = "mats for your writ — " .. (w.name or wid)
			.. "\n" .. W.MAIL_TAGLINE })
	if ok then
		mailDB("writMatsFp")[wid] = fp
		W.Act((w and w.state == "agreed") and "wmeet" or "waccept",
			w or wid, { matsFp = fp })
	end
	return ok and fp or nil
end

-- mats status for a crafter-side writ: sent | transit | arrived
function W.MatsStatus(w)
	if not (w and w.matsFp) then return nil end
	if mailDB("writMatsGot")[w.id] then return "arrived" end
	for _, m in pairs(W.ScanInbox()) do
		if m.kind == "mats" and m.w == w then return "transit" end
	end
	return "sent"
end

-- ============ 2d: COD-loot → wrecv ============
-- the protected take IS the pay decision — same one-click semantics
-- OR.AcceptCOD documents. Return = refused shipment → wdecline.

function W.InboxWrits()
	local out = {}
	for i, m in pairs(W.ScanInbox()) do
		if m.kind == "cod" then
			out[#out + 1] = { index = i, sender = m.sender,
				cod = m.cod, w = m.w }
		end
	end
	table.sort(out, function(a, b) return a.index < b.index end)
	return out
end

function W.AcceptMail(hit)
	if not (hit and TakeInboxItem) then return false end
	TakeInboxItem(hit.index)   -- the loot hook stages wrecv
	return true
end

function W.RejectMail(hit)
	if not (hit and ReturnInboxItem) then return false end
	ReturnInboxItem(hit.index) -- the return hook stages wdecline
	return true
end

-- indexes shift as collected mails delete — re-verify the mail at
-- this index is still the one we matched before staging a verb
local function stillMatch(index, m)
	if not (m and not m.done) then return false end
	local _, _, sender, subject = GetInboxHeaderInfo(index)
	return (sender or "") == (m.sender or "")
		and (subject or "") == (m.subject or "")
end

local function hookTake(index)
	W.ScanInbox()  -- Blizzard's own mail UI can loot without us
	local m = inIdx[index]
	if not stillMatch(index, m) then return end
	if m.kind == "cod" and m.w then
		m.done = true  -- AutoLoot may route through TakeInboxItem too
		W.Act("wrecv", m.w)
	elseif m.kind == "mats" and m.w then
		m.done = true
		mailDB("writMatsGot")[m.w.id] = time()
		GM.Print(GM.CC("accent") .. "writ mats arrived — "
			.. (m.w.name or m.w.id or "?") .. "|r")
	end
end

local function hookReturn(index)
	local m = inIdx[index]
	if stillMatch(index, m) and m.kind == "cod" and m.w then
		m.done = true
		W.Act("wdecline", m.w, { reason = "shipment-returned" })
	end
end

if hooksecurefunc then
	if AutoLootMailItem then
		hooksecurefunc("AutoLootMailItem", hookTake)
	end
	if TakeInboxItem then
		hooksecurefunc("TakeInboxItem", hookTake)
	end
	if ReturnInboxItem then
		hooksecurefunc("ReturnInboxItem", hookReturn)
	end
end

-- ============ P4: yell listener ============
-- Trade-channel + yell scan turns Stormwind barkers into session
-- pseudo-offers on the SHOPS market view — no account needed, no
-- backend. Deliberately loose keyword match; GM.db.yellTerms adds
-- user terms. Session-only ring, deduped per sender.
local yellRing, yellSeen = {}, {}
local YELL_MAX, YELL_TTL = 100, 30
local YELL_WORDS = { "enchant", "lockpick", "lock pick", "lfw",
	"will craft", "crafting", "portal", "summon", "wts", "wtb",
	"selling", "buying" }
local YELL_PROF = { enchant = "Enchanting", lockpick = "Lockpicking",
	["lock pick"] = "Lockpicking", portal = "Mage",
	summon = "Warlock" }
-- pseudo-profs that are really classes — they display on the row
-- but must not mint a prof filter chip
local YELL_CLASS = { Mage = true, Warlock = true }

-- user-configurable lifetime (Settings → GENERAL), minutes
local function yellTTL()
	local v = tonumber(GM.Model and GM.Model.Pref("yellTTL"))
	return v and math.max(1, math.floor(v)) or YELL_TTL
end
W.YellTTL = yellTTL

local function yellHit(msg)
	local l = msg:lower()
	for _, kw in ipairs(YELL_WORDS) do
		if l:find(kw, 1, true) then return kw, YELL_PROF[kw] end
	end
	for _, kw in ipairs(GM.db and GM.db.yellTerms or {}) do
		if l:find(kw:lower(), 1, true) then return kw, nil end
	end
end

-- passive link harvest: every [|H..|h[..]|h] capsule in a bark is
-- an offer the yeller advertises — items, enchant/spell services,
-- |Htrade: profession links. Each becomes a sub-line under the
-- yeller's row; the raw link is kept for hover tooltips. The first
-- link still fills the legacy itemID/linkName/ref fields.
local function yellLinks(msg)
	local links, itemID, lname, ref = {}
	for link, kind, payload, name in
			msg:gmatch("(|?c?%x*|H(%a+):([^|]*)|h%[(.-)%]|h)") do
		local l = { kind = kind, name = name, link = link }
		if kind == "item" then
			l.id = tonumber(payload)
			if not itemID then
				itemID, lname = l.id, name
			end
		elseif kind == "enchant" or kind == "spell" then
			l.id = tonumber(payload:match("(%d+)"))
			if not ref then ref, lname =
				l.id and ("s:" .. l.id) or nil, name end
		elseif kind == "trade" then
			-- |Htrade:<who>:<spell>:... — no item ref, but the prof
			-- capsule is still an offer line
			if not ref then lname = lname or name end
		end
		links[#links + 1] = l
	end
	return links, itemID, lname, ref
end

-- foreign-capsule pricing: our DB only knows OUR recipes, so an
-- advertised enchant's mats come from the link's own tooltip —
-- the Reagents: section lists "Name (n)" chunks until a line
-- stops resolving to items. Any chunk that won't resolve to a
-- priced item kills the suggestion — a partial sum understates.
-- Same 25% service margin as W.Suggest's mat-only fallback.
local reagTT
local function ReagentCost(link)
	if reagTT == nil then
		local ok, tt = pcall(CreateFrame, "GameTooltip",
			"GMReagProbe", UIParent, "GameTooltipTemplate")
		reagTT = (ok and tt) or false
	end
	if not reagTT then return nil end
	reagTT:SetOwner(UIParent, "ANCHOR_NONE")
	if not pcall(reagTT.SetHyperlink, reagTT, link) then
		return nil
	end
	local cost, on = 0
	for i = 1, reagTT:NumLines() or 0 do
		local fs = _G["GMReagProbeTextLeft" .. i]
		local s = fs and fs:GetText()
		if s then
			if s:find("^Reagents:") then
				on = i
			elseif on then
				local resolved = true
				for chunk in s:gmatch("[^,]+") do
					local nm, cnt = chunk:match(
						"^%s*(.-)%s*%(%s*(%d+)%s*%)%s*$")
					nm = nm or chunk:match("^%s*(.-)%s*$")
					local _, lk = GetItemInfo and GetItemInfo(nm)
					local id = lk and GM.LinkID(lk)
					if not id then resolved = nil break end
					cost = cost + (tonumber(cnt) or 1)
						* (GM.Price("dbmarket", id)
							or (GM.ItemEntry(id) or {}).mb or 0)
				end
				if not resolved then break end
			end
		end
	end
	return cost > 0 and cost or nil
end

-- what a capsule line advertises at market: item links price
-- direct; service links try our own recipe first, then the
-- link tooltip's reagent list with the service margin
function W.CapsulePrice(l)
	if not l then return nil end
	if l.kind == "item" and l.id then
		return GM.Price("dbmarket", l.id)
			or (GM.ItemEntry(l.id) or {}).mb
	end
	if not l.id then return nil end
	local s = W.Suggest and W.Suggest("s:" .. l.id)
	if s and s.price then return s.price end
	local m = ReagentCost(l.link)
	return m and math.floor(m * 1.25 + 0.5) or nil
end

-- SHOPS market folds these in alongside roster offers; expired
-- entries prune on read so a quiet session drains naturally
function W.YellOffers()
	local cut = time() - yellTTL() * 60
	local kept = {}
	for i = #yellRing, 1, -1 do
		local y = yellRing[i]
		local drop = (y.t or 0) < cut
		-- newest row per yeller survives; older dupes fold their
		-- count in and go (rows from before stacking existed)
		if not drop and kept[y.char] then
			kept[y.char].n = (kept[y.char].n or 1) + (y.n or 1)
			drop = true
		end
		if drop then
			table.remove(yellRing, i)
			if yellSeen[y.char] == y then yellSeen[y.char] = nil end
		else
			kept[y.char] = y
		end
	end
	return yellRing
end

local yells = CreateFrame("Frame")
yells:RegisterEvent("CHAT_MSG_CHANNEL")
yells:RegisterEvent("CHAT_MSG_YELL")
yells:SetScript("OnEvent", function(_, ev, msg, sender, ...)
	if GM.Model and GM.Model.Pref("yellListen") == false then
		return
	end
	if ev == "CHAT_MSG_CHANNEL" then
		-- Trade-ish channels only; yells fire anywhere. Channel
		-- identity can't ride a fixed slot — Forever's payload
		-- inserts fields (surnames shift everything) and Trade's
		-- number varies per char. Haystack every string field plus
		-- GetChannelName on any numeric one — a hit anywhere means
		-- the message came from a trade-ish channel.
		local ch
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			if type(v) == "string" then
				ch = (ch or "") .. " " .. v
			elseif type(v) == "number" and GetChannelName then
				local ok, n = pcall(GetChannelName, v)
				if ok and type(n) == "string" then
					ch = (ch or "") .. " " .. n
				end
			end
		end
		ch = (ch or ""):lower()
		if not (ch:find("trade", 1, true)
				or ch:find("lookingfor", 1, true)
				or ch:find("lfg", 1, true)) then return end
	end
	if not (msg and sender) then return end
	if GM.SameChar and GM.SameChar(sender) then return end
	local hit, prof = yellHit(msg)
	local links, itemID, lname, ref = yellLinks(msg)
	if not hit then
		-- a bare capsule IS the bark — nobody links their
		-- profession in Trade conversationally, and item/enchant
		-- links there are sellers by context. Link-free and
		-- keyword-free is the only "not a bark" left.
		if #links == 0 then return end
		hit = "link"
		for _, l in ipairs(links) do
			if not prof then
				prof = l.kind == "trade" and l.name
					or l.kind == "enchant" and "Enchanting" or nil
			end
		end
	end
	local seen = yellSeen[sender]
	if seen then
		-- one row per yeller: a re-yell updates it in place and
		-- counts (loot-line stacking, same idea) — a serial
		-- advertiser can't flood the list every dedup window
		seen.t, seen.text = time(), msg:sub(1, 120)
		seen.n = (seen.n or 1) + 1
		seen.itemID, seen.ref, seen.linkName = itemID, ref, lname
		seen.links = links
		if prof then seen.prof, seen.clsProf =
			prof, YELL_CLASS[prof] or nil end
		return
	end
	local y = { source = "yell", char = sender,
		text = msg:sub(1, 120), t = time(), prof = prof, n = 1,
		clsProf = prof and YELL_CLASS[prof] or nil,
		itemID = itemID, ref = ref, linkName = lname,
		links = links }
	yellSeen[sender] = y
	yellRing[#yellRing + 1] = y
	if #yellRing > YELL_MAX then
		local old = table.remove(yellRing, 1)
		if yellSeen[old.char] == old then yellSeen[old.char] = nil end
	end
end)

-- drop ops the watcher already consumed once the player is in-world —
-- the view's Data() pass will reconcile again when a writs pane opens
local wrinit = CreateFrame("Frame")
wrinit:RegisterEvent("PLAYER_LOGIN")
wrinit:SetScript("OnEvent", function() W.ClearAcked() end)
