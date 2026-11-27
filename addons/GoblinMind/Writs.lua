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
	return UnitName("player") or "?"
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

function W.RosterOffers()
	local out = {}
	local profs = GoblinMindCrafting
		and (GoblinMindCrafting.recipes or {}) or {}
	for id, r in pairs(profs) do
		if not r.unlearned and r.name then
			local ref = "r:" .. id
			local t = TermsFor(ref)
			out[#out + 1] = {
				ref = ref, name = r.name, prof = r.prof,
				itemID = r.itemID, kind = "craft",
				numMade = r.numMade or 1,
				price = t.price, mats = t.mats, note = t.note,
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
				ref = ref, name = r.name, prof = r.prof,
				kind = "service",
				price = t.price, mats = t.mats, note = t.note,
			}
		end
	end
	-- hand-entered work that the tradeskill scan can't see —
	-- lockpicking, portals, summons. Every entry carries its own ref.
	for _, s in ipairs(GM.db and GM.db.shopOffers or {}) do
		if type(s) == "table" and s.name then
			local t = TermsFor(s.ref)
			out[#out + 1] = {
				ref = s.ref, name = s.name, prof = s.prof,
				kind = s.kind == "service" and "service" or "craft",
				itemID = s.itemID,
				price = t.price or s.price,
				mats = t.mats or s.mats, note = t.note or s.note,
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
	local chars = {}
	-- every char key the ledger knows = a toon the shop can be
	-- reached through; the mail channel needs real names
	for k in pairs(GoblinMindLedger and GoblinMindLedger.byChar or {}) do
		chars[#chars + 1] = tostring(k):match("^(.-)%-") or tostring(k)
	end
	if #chars == 0 then chars[1] = CharName() end
	table.sort(chars)
	return W.Stage({
		v = "roster", b = board,
		chars = table.concat(chars, ","),
		offers = JEnc(W.RosterOffers()),
	})
end

-- address a work request to a roster owner's install uuid
function W.Request(board, toUUID, toChar, f)
	if not (board and toUUID) then return nil end
	f = f or {}
	return W.Stage({
		v = "wpost", b = board, to = toUUID,
		toChar = toChar or "?", fromChar = CharName(),
		ref = f.ref or "", name = f.name or "Work request",
		itemID = f.itemID, qty = f.qty or 1,
		offer = f.offer or 0,
		mats = f.mats or "buyer",
		deliver = f.deliver or "cod",
		note = f.note or "",
	})
end

-- lifecycle verbs on an existing writ id
function W.Act(verb, wid, fields)
	if not wid then return nil end
	fields = fields or {}
	fields.v = verb
	fields.wid = wid
	return W.Stage(fields)
end

-- ============ reads ============

function W.Rosters(board)
	local b = GoblinMindDB and GoblinMindDB.rosters
		and GoblinMindDB.rosters[board]
	return (b and b.rosters) or {}
end

function W.RosterStamp(board)
	local b = GoblinMindDB and GoblinMindDB.rosters
		and GoblinMindDB.rosters[board]
	return (b and b.t) or 0
end

-- {in = [...], out = [...], t = pull timestamp}
function W.Writs()
	local w = GoblinMindDB and GoblinMindDB.writs
	return { inb = (w and w["in"]) or {}, out = (w and w.out) or {},
		t = (w and w.t) or 0 }
end

function W.Results()
	return GoblinMindDB and GoblinMindDB.writResults or {}
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

-- drop ops the watcher already consumed once the player is in-world —
-- the view's Data() pass will reconcile again when a writs pane opens
local wrinit = CreateFrame("Frame")
wrinit:RegisterEvent("PLAYER_LOGIN")
wrinit:SetScript("OnEvent", function() W.ClearAcked() end)
