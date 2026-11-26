local _, GM = ...

-- Per-location inventory: bags/bank counted live; mail, guild bank, and
-- owned auctions cached from the last time their frame/API was reachable.
-- Feeds the numinventory price source and /goblin inv.

GM.Inventory = {}

local mailCache = {}      -- [itemID] = qty, refreshed at the mailbox
local guildCache = {}     -- [itemID] = qty, current gbank tab only
-- Listings are keyed by fingerprint ("itemID:qty:buyout"), not
-- auctionID: Forever's GetOwnedAuctionInfo hands the same listing
-- different ids across enumerations (and sometimes none, which fell
-- back to the unstable row index) — one post read as a stream of
-- post phantoms every refresh. The fingerprint is stable for the
-- life of a listing; `n` tracks how many identical listings share it.
local auctionCache = {}   -- [fp] = {fp, aid, idx, itemID, qty, buyout, tLeft, at, n}
local aidIndex = {}       -- [raw auctionID or enum index] = fp — resolves
                          -- cancel callers' raw ids back to their entry
local recentCancels = {}  -- [fp or raw id] = time()
local soldMarks = {}      -- [fp] = time() — ERR_AUCTION_SOLD marks
local expireMarks = {}    -- [fp] = time() — AuctionExpired notif marks
local removedMarks = {}   -- [fp] = time() — AuctionRemoved (cancel)
                          -- survive until the enum drops the row
local ownedPrimed = false -- first refresh just populates — everything
                          -- would look "new" otherwise
local emptyArmed = nil  -- timestamp of the first zero report; an
-- empty snapshot must SUSTAIN before it may vanish the cache
                          -- processing (mid-requery reads can be empty)
local partialSince = nil -- first incomplete-read timestamp — the same
                         -- sustained-state gate shape as emptyArmed
local rearmQueued = false -- dedupe the incomplete-read retry arm
local postedDep = {}      -- fp -> {dep, t}: execute-time deposit truth
local postUntil = 0       -- posts are only ledgered inside this window —
                          -- enumeration ghost rows (sold/history rows the
                          -- status filter can't catch) otherwise ratchet
                          -- fp counts up and read as phantom posts
local pendingLost = {}    -- [fp] = {e, lost, fresh} — a vanished row must
                          -- STAY gone one refresh before sell/expire
                          -- ledgers; transient ghost rows (the mirror of
                          -- phantom posts) would otherwise log fake sales
                          -- and poison the brain's vel feed
GM.Inventory.recentCancels = recentCancels

function GM.Inventory.ArmPost(sec)
	postUntil = math.max(postUntil, time() + (sec or 15))
end

-- an execute-time post hands its real deposit forward: the enum
-- can't recompute CalculateItemDeposit for an item already listed
-- (it's out of bags), so the number rides here keyed by fingerprint
function GM.Inventory.NotePostedDep(fp, dep)
	if fp and dep and dep > 0 then
		postedDep[fp] = { dep = dep, t = time() }
	end
end

-- ============ mailbox ============

local function scanInbox()
	GM.Inventory._inboxScans = (GM.Inventory._inboxScans or 0) + 1
	-- build-then-swap, never wipe-then-scan: an absent API or a
	-- mid-load event keeps the last good cache instead of zeroing it
	if not (GetInboxNumItems and GetInboxItem) then return end
	local t = {}
	local n = GM.MailCount()
	for i = 1, n do
		for slot = 1, 20 do
			local ok, a, b, _, d = pcall(GetInboxItem, i, slot)
			if not ok then break end
			local id, count
			if type(a) == "number" then id, count = a, b
			elseif type(b) == "number" then id, count = b, d end
			if not id then break end
			t[id] = (t[id] or 0) + (count or 1)
		end
	end
	mailCache = t
end

-- ============ auction-mail records (TSM's invoice model) ============
-- the owned enum is the real-time view; the AUTHORITATIVE record of
-- a resolution is the auction mail: seller invoices carry the exact
-- bid and the REAL AH cut (no *0.95 estimate), expire/cancel mails
-- carry the item itself, and daysLeft backdates the event. The enum
-- paths stay the fast path — this pass catches what they can't see
-- (offline resolutions) with exact amounts. mailSeen fingerprints
-- keep re-scans idempotent across sessions.

local mailScanAt = 0

local EXP_SUBJ = AUCTION_EXPIRED_MAIL_SUBJECT
	and AUCTION_EXPIRED_MAIL_SUBJECT:gsub("%%s", "") or nil
local CAN_SUBJ = AUCTION_REMOVED_MAIL_SUBJECT
	and AUCTION_REMOVED_MAIL_SUBJECT:gsub("%%s", "") or nil

-- invoice mails name items, never id them — resolve through the
-- owned cache (variant-aware names) then the ledger's own nm history
local function MailNameToID(name)
	for _, e in pairs(auctionCache) do
		if e.name == name and e.itemID then return e.itemID end
	end
	local tx = GM.Ledger.db and GM.Ledger.db.transactions
	if tx then
		for i = #tx, 1, -1 do
			local e = tx[i]
			if e.x and e.x.nm == name and e.i then return e.i end
		end
	end
	for id in pairs(GoblinMindLedger and GoblinMindLedger.itemStats
		or {}) do
		if GM.ItemName(id) == name then return id end
	end
end

-- has an enum-side txn already covered this item+qty+kind recently?
-- bounded tail scan, not a break-on-old: backdated mail records make
-- the list non-monotonic, so an early exit could skip newer rows
local function TxnSeen(kind, itemID, qty, window)
	local tx = GM.Ledger.db and GM.Ledger.db.transactions
	if not tx then return false end
	local cutoff = time() - (window or 129600)
	for i = #tx, math.max(1, #tx - 400), -1 do
		local e = tx[i]
		if e.ty == kind and e.i == itemID and e.q == qty
			and (e.t or 0) >= cutoff then
			return true
		end
	end
	return false
end

local function MailMark(fp)
	local ms = GM.Ledger.db and GM.Ledger.db.mailSeen
	if not ms then return end
	ms[fp] = time()
	-- bound: mail lives 30 days — prune stale keys and cap the table
	local n = 0
	for k, t0 in pairs(ms) do
		n = n + 1
		if n > 400 or time() - t0 > 32 * 86400 then ms[k] = nil end
	end
end

-- item attachments: the expire/cancel/won mails carry the item
-- itself — the link gives the exact itemID (and suffix variant) the
-- invoice name can't. Quantities sum across slots like TSM's
-- GetQuantity: an expiry can return the item in several stacks.
local function MailAttachmentItem(index)
	if not GetInboxItemLink then return end
	local id, qty
	for slot = 1, 20 do
		local link = GetInboxItemLink(index, slot)
		if link then
			id = id or tonumber(link:match("item:(%d+)"))
			-- GetInboxItem's return shape varies on this client (see
			-- scanInbox): a=id,b=count or b=id,d=count
			local a, b, _, d = GetInboxItem(index, slot)
			qty = (qty or 0) + ((type(a) == "number" and b)
				or (type(b) == "number" and d) or 1)
		end
	end
	return id, qty
end

local function scanAuctionMail()
	if not (GetInboxNumItems and GetInboxHeaderInfo) then return end
	local now = GetTime()
	if now - mailScanAt < 2 then return end
	mailScanAt = now
	local L = GM.Ledger.db
	if not (L and GM.Ledger.Record) then return end
	for i = 1, GM.MailCount() do
		local invoiceType, itemName, playerName, bid, buyout,
			deposit, consignment, _, _, _, count, invAid
		if GetInboxInvoiceInfo then
			invoiceType, itemName, playerName, bid, buyout,
				deposit, consignment, _, _, _, count, invAid =
				GetInboxInvoiceInfo(i)
		end
		if invoiceType == "seller"
			or invoiceType == "seller_temp_invoice" then
			-- sold-proceeds mail: exact bid minus the real consignment
			local id = itemName and MailNameToID(itemName)
			local qty = count or 1
			if id then
				local fp = "s|" .. itemName .. "|"
					.. tostring(bid or 0) .. "|" .. qty
				if not L.mailSeen[fp] then
					if TxnSeen("sell", id, qty) then
						MailMark(fp)
					else
						local net = (bid or 0) - (consignment or 0)
						local unit = qty > 0
							and math.floor(net / qty + 0.5) or nil
						local _, _, _, _, _, _, daysLeft =
							GetInboxHeaderInfo(i)
						GM.Ledger.Record("sell", { itemID = id, qty = qty,
							unit = unit, dep = deposit or 0,
							nm = itemName, auctionID = invAid,
							t = daysLeft and math.floor(
								time() + (daysLeft - 30) * 86400) })
						MailMark(fp)
					end
				end
			end
		elseif invoiceType == "buyer" then
			-- won-auction delivery: exact paid price, no estimate
			local qty = count or 1
			local id, q2 = MailAttachmentItem(i)
			id = id or (itemName and MailNameToID(itemName))
			qty = q2 or qty
			if id then
				local fp = "b|" .. tostring(itemName or id) .. "|"
					.. tostring(bid or 0) .. "|" .. qty
				if not L.mailSeen[fp] then
					if TxnSeen("buy", id, qty) then
						MailMark(fp)
					else
						local unit = qty > 0
							and math.floor((bid or 0) / qty + 0.5) or nil
						local _, _, _, _, _, _, daysLeft =
							GetInboxHeaderInfo(i)
						local bt = daysLeft and math.floor(
							time() + (daysLeft - 30) * 86400)
						if TxnSeen("bid", id, qty) then
							-- a journaled bid placed the escrow — the
							-- win pairs it (stock in, ext settles)
							-- instead of double-debiting cash
							GM.Ledger.Record("bidwon", {
								itemID = id, qty = qty, unit = unit,
								cost = bid or 0, nm = itemName, t = bt })
						else
							GM.Ledger.Record("buy", { itemID = id,
								qty = qty, unit = unit,
								nm = itemName, t = bt })
						end
						MailMark(fp)
					end
				end
			end
		elseif not invoiceType then
			-- subject-typed AH mails: expire/cancel carry the item
			-- back — the attachment IS the record
			local _, _, _, subject, _, _, daysLeft =
				GetInboxHeaderInfo(i)
			subject = subject or ""
			local kind = (EXP_SUBJ and subject:find(EXP_SUBJ) and "expire")
				or (CAN_SUBJ and subject:find(CAN_SUBJ) and "cancel")
			if kind then
				local id, qty = MailAttachmentItem(i)
				if id and qty and qty > 0 then
					local fp = kind:sub(1, 1) .. "|" .. id .. "|" .. qty
						.. "|" .. math.floor((daysLeft or 0) * 24)
					if not L.mailSeen[fp] then
						if TxnSeen(kind, id, qty) then
							MailMark(fp)
						else
							GM.Ledger.Record(kind, { itemID = id, qty = qty,
								nm = subject,
								t = daysLeft and math.floor(
									time() + (daysLeft - 30) * 86400) })
							MailMark(fp)
						end
					end
				end
			end
		end
	end
end

-- ============ guild bank (current tab only — TSM opens every tab) ============

local function scanGuildBank()
	GM.Inventory._gbScans = (GM.Inventory._gbScans or 0) + 1
	-- same swap contract as the inbox: a missing API must not
	-- zero the cache — an empty tab still commits as truth
	if not (GetGuildBankItemInfo and GetGuildBankItemLink) then return end
	local t = {}
	local tab = GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 1
	for slot = 1, 98 do
		local link = GetGuildBankItemLink(tab, slot)
		local id = GM.LinkID(link)
		if id then
			local _, count = GetGuildBankItemInfo(tab, slot)
			t[id] = (t[id] or 0) + (count or 1)
		end
	end
	guildCache = t
end

-- ============ owned auctions ============
-- Field names are unverified on Forever — read defensively, cache what we
-- get. A lot that vanishes with time-left remaining and wasn't canceled
-- through us counts as a sale (sold = money arrives by mail; the 5% cut
-- is applied here, deposits ignored).

local function EntryFp(e)
	return e.itemID .. ":" .. (e.qty or 1) .. ":" .. (e.buyout or 0)
end

-- resolve a raw auctionID/enumeration index/fingerprint to its
-- cache entry — the cancel step in AH.Execute goes through this
function GM.Inventory.OwnedByKey(key)
	local e = auctionCache[key]
	if e then return e end
	local fp = aidIndex[key]
	return fp and auctionCache[fp] or nil
end

GM.Inventory.bids = {}
local bids = GM.Inventory.bids

local lastOwnedAt -- unix time of the last live snapshot (or of the
                  -- persisted one rehydrated at login)

function GM.Inventory.OwnedAt() return lastOwnedAt end

-- true only after a LIVE enum this session — LoadOwned's rehydrated
-- snapshot deliberately doesn't set it, so "not in the table" reads
-- as never-asked, not as canceled
function GM.Inventory.OwnedPrimed() return ownedPrimed end

-- name matching for marks/notifications — the message only carries
-- the item NAME, so it resolves against the cached rows by name.
-- Exact match first (variant links carry "of X"), prefix either way
-- covers base-name vs variant-name pairs.
local function NameMatches(e, name)
	local en = e.name or (GM.ItemName and GM.ItemName(e.itemID))
	-- notifications can carry a numeric auctionID instead of a
	-- name — a non-string key is an aid compare, never a name
	return type(en) == "string" and type(name) == "string" and (en == name
		or en:sub(1, #name) == name
		or name:sub(1, #en) == en)
end

-- "A buyer has been found for your auction of X" / the AuctionSold
-- notification — either may carry a name OR an auctionID.
function GM.Inventory.MarkSold(key)
	if not key or key == "" then return end
	local t, marked = time(), 0
	for fp, e in pairs(auctionCache) do
		if e.aid == key or NameMatches(e, key) then
			soldMarks[fp] = t
			e.sold = true
			if GM.Inventory.auctions[fp] then
				GM.Inventory.auctions[fp].sold = true
			end
			marked = marked + 1
		end
	end
	if marked > 0 then
		-- pull a fresh snapshot so the delta engine ledgers the sell
		-- sooner — and repaint the surfaces that render the mark
		GM.Time.After(1, GM.Inventory.QueryOwned)
		GM.View.Refresh("auctions")
		GM.View.Refresh("ah")
		GM.View.Refresh("planner")
	end
	return marked
end

-- the AuctionExpired/AuctionRemoved notifications carry the same
-- name-or-aid arg — they give pendingLost a direct verdict instead
-- of the couldExpire heuristic
function GM.Inventory.MarkExpired(key)
	if not key or key == "" then return end
	local t = time()
	for fp, e in pairs(auctionCache) do
		if e.aid == key or NameMatches(e, key) then expireMarks[fp] = t end
	end
end

function GM.Inventory.MarkRemoved(key)
	if not key or key == "" then return end
	local t = time()
	for fp, e in pairs(auctionCache) do
		if e.aid == key or NameMatches(e, key) then removedMarks[fp] = t end
	end
end

-- total buyout value of currently listed auctions (last snapshot —
-- stale between AH visits, rebased whenever the enum answers)
function GM.Inventory.PostedValue()
	local t = 0
	for _, a in pairs(auctionCache) do
		if a.itemID and a.buyout then
			t = t + a.buyout * (a.qty or 1) * (a.n or 1)
		end
	end
	return t
end

-- units of an item currently listed, from the same snapshot
function GM.Inventory.PostedQty(itemID)
	local q = 0
	for _, a in pairs(auctionCache) do
		if a.itemID == itemID then
			q = q + (a.qty or 1) * (a.n or 1)
		end
	end
	return q
end

-- cost basis of bought stock still held in bags — the third wealth
-- term. The ledger's paidQ/paidT counts bought-minus-sold stock at
-- average cost, but posted units still sit inside it and the chart
-- already values those at buyout in `a`, so the posted share comes
-- back out. Without this term a buy reads as a wealth collapse
-- until the item sells — the giant Xs on the wealth chart.
-- (Outflow legs drain paidQ at the running average — Consume runs on
-- sell/vendor/mailout/destroy/craftout — so only unjournaled stock
-- moves (loots, trades) leave residue; BagCount bounds it.
-- Bank-only stock isn't reachable — bags are the trading boundary.)
function GM.Inventory.HeldValue()
	local st = GM.Ledger and GM.Ledger.db and GM.Ledger.db.itemStats
	if not st then return 0 end
	local held = 0
	for id, s in pairs(st) do
		local pq, pt = s.paidQ or 0, s.paidT or 0
		if pq > 0 and pt > 0 then
			local inBags = math.max(0, pq - GM.Inventory.PostedQty(id))
			held = held + math.min(inBags, GM.BagCount(id) or 0)
				* (pt / pq)
		end
	end
	return held
end

-- persist the owned snapshot so the MINE surfaces are a real log: the
-- enum only answers at the AH, but the last-known listings should
-- stay visible between visits (tLeft rebases off the stored `at`)
local function SaveOwned()
	if not GoblinMindSettings then return end
	local me = GM.CharKeyQualified()
	if not me then return end -- never persist a bare-name key
	GoblinMindSettings.owned = GoblinMindSettings.owned or {}
	local rows = {}
	for fp, a in pairs(auctionCache) do
		if a.itemID then
			rows[fp] = { itemID = a.itemID, qty = a.qty,
				buyout = a.buyout, tLeft = a.tLeft, at = a.at,
				n = a.n, dep = a.dep, aid = a.aid, name = a.name,
				itemKey = a.itemKey, itemLink = a.itemLink }
		end
	end
	local bs = {}
	for aid, b in pairs(bids) do bs[aid] = b end
	GoblinMindSettings.owned[me] =
		{ rows = rows, bids = bs, at = time() }
end

-- rehydrate at login — ownedPrimed deliberately stays FALSE: a stale
-- snapshot must never feed post/sell ledger deltas; the first live
-- refresh re-primes cleanly
local ownedLoaded = false -- the ATTEMPT ran — PostedValue is honest
function GM.Inventory.OwnedLoaded() return ownedLoaded end
local function LoadOwned()
	ownedLoaded = true
	local owned = GoblinMindSettings and GoblinMindSettings.owned
	if not owned then return end
	-- the same char can sit under bare and realm-qualified keys (the
	-- empty-realm window) — take the newest self-keyed snapshot
	local snap, at = nil, -1
	for char, s in pairs(owned) do
		if GM.IsSelfCharKey(char) and (s.at or 0) >= at then
			snap, at = s, s.at or 0
		end
	end
	if not snap then return end
	local dead = {}
	for fp, a in pairs(snap.rows or {}) do
		local e = { fp = fp, itemID = a.itemID, qty = a.qty,
			buyout = a.buyout, tLeft = a.tLeft, at = a.at, n = a.n,
			dep = a.dep, aid = a.aid, name = a.name,
			-- suffix data must survive hydration: MergeOwnAsks
			-- matches owned lots to the scan under their exact
			-- itemKey, and the merged ask's link feeds step labels
			itemKey = a.itemKey, itemLink = a.itemLink }
		-- a snapshot row whose listing deadline elapsed while offline
		-- is dead on arrival — hydrating it counts an expired auction
		-- as live wealth until the first enum corrects it (a flat
		-- plateau that snaps down, the "weird jump" on the chart).
		-- Ledger it as an expiry now: the same couldExpire verdict
		-- pendingLost hands a row gone past its timeLeft.
		if e.tLeft and e.at and (time() - e.at) >= e.tLeft then
			dead[#dead + 1] = e
		else
			auctionCache[fp] = e
		end
	end
	if #dead > 0 then
		-- strip from the persisted snapshot now: without an AH visit
		-- SaveOwned never runs and the same ghosts would re-ledger on
		-- every login
		for _, e in ipairs(dead) do snap.rows[e.fp] = nil end
		-- defer: the ledger isn't guaranteed primed at PLAYER_LOGIN
		GM.Time.After(2, function()
			for _, e in ipairs(dead) do
				if GM.Ledger and GM.Ledger.Record then
					local dep = e.dep or (GM.AH.DepositCost
						and GM.AH.DepositCost(e.itemID, e.qty or 1)) or 0
					for _ = 1, (e.n or 1) do
						GM.Ledger.Record("expire", { itemID = e.itemID,
							qty = e.qty, auctionID = e.aid or e.fp,
							dep = dep, nm = e.name })
					end
				end
			end
		end)
	end
	for aid, b in pairs(snap.bids or {}) do bids[aid] = b end
	GM.Inventory.auctions = auctionCache
	lastOwnedAt = snap.at
end

function GM.Inventory.RefreshOwned()
	if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions) then return end
	-- the enum only answers meaningfully at the AH — a bare call from
	-- the login ladder would report zero rows and wipe the persisted
	-- snapshot with them
	if not GM.AH.open then return end
	local ok, n = pcall(C_AuctionHouse.GetNumOwnedAuctions)
	if not ok or not n then return end
	-- first pass: collect rows. A nonzero info.status marks
	-- sold/history rows and is filtered below — no "some row reports
	-- status==0" precondition: a sole SOLD row has no active sibling
	-- to prove the field, so it sailed through as active and sat
	-- POSTED until collection dropped it (missed-completion bug).
	-- If a client ever reports status always-nonzero garbage the
	-- cache goes empty — but that's exactly the shape the 15s
	-- sustained-empty gate exists to catch.
	local infos = {}
	for i = 1, n do
		local ok2, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
		if ok2 and type(info) == "table" then
			infos[#infos + 1] = { i = i, info = info }
		end
	end
	-- completeness gate, same shape as the empty gate below: the enum
	-- delivers asynchronously, so n>0 with unread rows — or
	-- HasFullOwnedAuctionResults saying delivery isn't done — is a
	-- PARTIAL read, not truth. Committing it flaps PostedValue and
	-- mints phantom sell/expire verdicts. Don't swap; retry shortly.
	-- The flag is trusted but not blindly: if Forever's never goes
	-- true we accept after 10s rather than stall the cache forever.
	-- (TSM's scanner does the same refusal + 2-frame retry.)
	local full = true
	if C_AuctionHouse.HasFullOwnedAuctionResults then
		local okF, f = pcall(C_AuctionHouse.HasFullOwnedAuctionResults)
		full = okF and f == true
	end
	if (not full or #infos < n) and ownedPrimed then
		if not partialSince then partialSince = time() end
		if time() - partialSince < 10 then
			if not rearmQueued then
				rearmQueued = true
				GM.Time.After(0.75, function()
					rearmQueued = nil
					GM.Inventory.RefreshOwned()
				end)
			end
			return
		end
	end
	partialSince = nil
	local now = {}
	local seenAid = {}
	-- receivable truth = "sold AND proceeds not yet collected".
	-- Forever keeps status~=0 rows flagged AFTER the proceeds mail
	-- is taken — a wholesale snap then resurrects collected
	-- receivables on every reconcile (the recurring phantom
	-- incoming). The mailbox is the resolution authority: a flagged
	-- row whose invoice aid is present still owes; one whose
	-- journaled sell has no invoice left in a live inbox already
	-- paid — the journal's own rcbl carries it until Gold(+)
	-- settles. Rows with no aid join stay status-quo.
	local pending = 0  -- sold rows awaiting collection = true rcbl
	local invAidNet, invOrphan = {}, 0
	if GetInboxInvoiceInfo then
		for i = 1, GM.MailCount() do
			local it, _, _, bid, _, dep, con,
				_, _, _, _, ia = GetInboxInvoiceInfo(i)
			if it == "seller" or it == "seller_temp_invoice" then
				local net = (bid or 0) - (con or 0) + (dep or 0)
				if ia then invAidNet[ia] = net
				else invOrphan = invOrphan + net end
			end
		end
	end
	local journaledSell = {}
	local txns = GM.Ledger and GM.Ledger.TxFor
		and GM.Ledger.TxFor() or {}
	for _, tx in ipairs(txns) do
		if tx.ty == "sell" and tx.x and tx.x.auctionID then
			journaledSell[tx.x.auctionID] = true
		end
	end
	-- invoice-absence is only evidence once the inbox has actually
	-- been live this session — before that it's "not fetched", not
	-- "collected"
	local inboxLive = (GM.Inventory._inboxScans or 0) > 0
		or GM.MailCount() > 0
	local rowAids = {}
	-- deposit truth for enum rows: a journaled post (or an
	-- execute-time note) carries the real CalculateItemDeposit the
	-- estimator can't reproduce for an already-listed item. Without
	-- this every tracked resolution releases an estimate against a
	-- real deposit and the dep account drifts negative
	local postDep = {}
	for _, tx in ipairs(GM.Ledger and GM.Ledger.TxFor
		and GM.Ledger.TxFor() or {}) do
		if tx.ty == "post" and tx.x and tx.x.dep then
			postDep[tx.i .. ":" .. (tx.q or 1) .. ":"
				.. (tx.u or 0)] = tx.x.dep
		end
	end
	for fp, d in pairs(postedDep) do
		if time() - d.t > 600 then postedDep[fp] = nil
		else postDep[fp] = d.dep end
	end
	wipe(aidIndex)
	for _, r in ipairs(infos) do
		local i, info = r.i, r.info
		local id = (info.itemKey and info.itemKey.itemID) or info.itemID
		local aid = info.auctionID or info.auctionId
		if type(aid) ~= "number" and type(aid) ~= "string" then aid = nil end
		local dupAid = aid and seenAid[aid]  -- same id twice = ghost row
		local inactive = info.status ~= nil and info.status ~= 0
		if inactive then
			if aid then rowAids[aid] = true end
			if aid and invAidNet[aid] then
				-- sold, invoice still uncollected — its net is the
				-- exact receivable
				pending = pending + invAidNet[aid]
			elseif not (aid and inboxLive and journaledSell[aid]) then
				pending = pending + (info.buyoutAmount or info.buyout
					or info.bidAmount or 0)
			end
			-- else: journaled + invoice gone + live inbox = collected
		end
		if id and not dupAid and not inactive then
			if aid then seenAid[aid] = true end
			local e = {
				itemID = id,
				-- keep the API key: suffixed variants scan/post/cancel
				-- under their exact itemKey, never the suffix-0 base.
				-- itemLink is the fallback key source on clients whose
				-- owned rows don't carry itemKey, and doubles as the
				-- variant-aware display name ("Banded Girdle of X")
				itemKey = info.itemKey
					or (GM.AH.ItemKeyFromLink
						and GM.AH.ItemKeyFromLink(info.itemLink)),
				itemLink = info.itemLink,
				name = info.itemLink and info.itemLink:match("%[(.-)%]")
					or nil,
				qty = info.quantity or 1,
				-- per-ITEM buyout (Forever convention — not lot total)
				buyout = info.buyoutAmount or info.buyout
					or info.bidAmount,
				tLeft = info.timeLeftSeconds,
				at = time(),
				-- listing deposit, captured once: the post, sale, and
				-- cancel legs must move the SAME number or the ledger's
				-- dep account never closes. Prefer the journaled post's
				-- real fee (or the execute-time note) — the estimate
				-- only fills in when neither saw this lot
				dep = postDep[id .. ":" .. (info.quantity or 1) .. ":"
					.. (info.buyoutAmount or info.buyout
						or info.bidAmount or 0)]
					or (GM.AH and GM.AH.DepositCost
						and GM.AH.DepositCost(id, info.quantity or 1)) or 0,
				aid = aid, idx = i, n = 1,
			}
			e.fp = EntryFp(e)
			local prev = now[e.fp]
			-- identical listings share a fingerprint — count them and
			-- prefer the entry carrying a real id for cancel actions,
			-- but keep EVERY row's key: n identical lots need n
			-- distinct cancel targets (CancelAuction takes the raw
			-- key, and every aid/idx resolves back through aidIndex)
			if prev then
				prev.n = (prev.n or 1) + 1
				prev.keys[#prev.keys + 1] = aid or i
				if aid and not prev.aid then
					prev.aid, prev.idx = aid, i
				end
				if aid then aidIndex[aid] = e.fp end
				aidIndex[i] = e.fp
			else
				e.keys = { aid or i }
				now[e.fp] = e
				if aid then aidIndex[aid] = e.fp end
				aidIndex[i] = e.fp
			end
		end
	end
	local t = time()
	for key, t0 in pairs(recentCancels) do
		if t - t0 > 300 then recentCancels[key] = nil end
	end
	-- zero-result gate, on the OUTCOME not the row count: n=0 is one
	-- shape, but a throttled enum can also report n>0 while every
	-- GetOwnedAuctionInfo errors or filters out — now builds empty
	-- and the swap below would wipe a healthy cache the same way.
	-- Zero usable rows must SUSTAIN for 15s before the cache may go
	-- empty. ownedPrimed is deliberately NOT in the condition: after
	-- /reload the cache is rehydrated-but-unprimed and the first
	-- enum's zeros were wiping it — the X that popped in on every
	-- reload.
	if not next(now) and next(auctionCache) then
		if not emptyArmed then
			emptyArmed = t
			return
		elseif t - emptyArmed < 15 then
			return
		end
	end
	emptyArmed = nil
	-- sold rows still listed are proceeds awaiting collection — the
	-- AH's own receivable truth. Snap rcbl to it: the pre-feed drift
	-- (sells that journaled but never settled) dies here. dep's truth
	-- is the same enum: deposits outstanding = Σ live rows' fees —
	-- resolutions that released unjournaled deposits (pre-feed posts)
	-- converge back to the live count
	-- seller invoices with no flagged row still owe proceeds — the
	-- row can drop from the enum while its mail lives
	pending = pending + invOrphan
	for a, net in pairs(invAidNet) do
		if not rowAids[a] then pending = pending + net end
	end
	if GM.Ledger and GM.Ledger.Adjust then
		GM.Ledger.Adjust("rcbl", pending, "reconcile")
		local depLive = 0
		for _, e in pairs(now) do
			depLive = depLive + (e.dep or 0) * (e.n or 1)
		end
		GM.Ledger.Adjust("dep", depLive, "reconcile")
	end
	-- sold marks ride the cache: the buyer-found message lands before
	-- the enum drops the row, so the mark has to survive refreshes —
	-- and die with the row (or on a stale-mark timeout)
	for fp, e in pairs(now) do e.sold = soldMarks[fp] or nil end
	for fp, t0 in pairs(soldMarks) do
		if not now[fp] or t - t0 > 600 then soldMarks[fp] = nil end
	end
	for fp, t0 in pairs(expireMarks) do
		if t - t0 > 600 then expireMarks[fp] = nil end
	end
	for fp, t0 in pairs(removedMarks) do
		if t - t0 > 600 then removedMarks[fp] = nil end
	end
	-- fingerprint delta: more listings at an fp than cached = posts,
	-- fewer = sells/expires — identical twins stay distinguishable by
	-- count even though they share one entry
	for fp, e in pairs(now) do
		local old = auctionCache[fp]
		local extra = (e.n or 1) - ((old and old.n) or 0)
		if ownedPrimed and extra > 0 and not recentCancels[fp]
			and t <= postUntil then
			for _ = 1, extra do
				GM.Ledger.Record("post", { itemID = e.itemID, qty = e.qty,
					unit = e.buyout, dep = e.dep, aid = e.aid,
					dur = e.tLeft, nm = e.name })
			end
		end
	end
	for fp, prev in pairs(auctionCache) do
		local lost = (prev.n or 1) - (now[fp] and now[fp].n or 0)
		-- lost-detection is NOT primed-gated: the first live enum is
		-- the only chance to verdict rows that resolved while offline
		-- (deadline elapsed → expire, else sell — pendingLost's own
		-- couldExpire). The "posts" side above stays gated: a hydrated
		-- row re-seen must never ledger a duplicate post.
		if lost > 0
			and not recentCancels[fp]
			and not (prev.aid and recentCancels[prev.aid]) then
			-- a ghost row that popped in and out is noise, a real sale
			-- stays gone — and on a throttled enum "one refresh" can
			-- arrive 0.5s later, so the hold is a TIME gate, not a
			-- pass count: missing must sustain 15s before the verdict
			local pl = pendingLost[fp]
			if pl then pl.lost = lost
			else pendingLost[fp] = { e = prev, lost = lost, at = t } end
		end
	end
	for fp, pl in pairs(pendingLost) do
		local cur = now[fp]
		local deficit = (pl.e.n or 1) - (cur and (cur.n or 1) or 0)
		if deficit <= 0 or recentCancels[fp]
			or (pl.e.aid and recentCancels[pl.e.aid]) then
			pendingLost[fp] = nil -- repopulated or canceled while pending
		elseif t - (pl.at or t) >= 15 then
			local n = math.min(pl.lost, deficit)
			-- a mail-side record may already cover one of these (the
			-- invoice scan writes sells/expires/cancels the enum can
			-- never see) — don't double-ledger the same resolution
			if n > 0 and (TxnSeen("sell", pl.e.itemID, pl.e.qty)
				or TxnSeen("expire", pl.e.itemID, pl.e.qty)
				or TxnSeen("cancel", pl.e.itemID, pl.e.qty)) then
				n = n - 1
			end
			if n > 0 then
				local couldExpire = pl.e.tLeft
					and (t - pl.e.at) >= pl.e.tLeft
				for _ = 1, n do
					if removedMarks[fp] then
						-- the AuctionRemoved notification already said
						-- cancel — no heuristic needed
						GM.Ledger.Record("cancel", { itemID = pl.e.itemID,
							qty = pl.e.qty, unit = pl.e.buyout,
							auctionID = pl.e.aid or fp,
							dep = pl.e.dep, nm = pl.e.name })
					elseif soldMarks[fp] then
						-- buyer-found beat the enum drop
						local unit = pl.e.buyout and pl.e.qty > 0
							and math.floor(pl.e.buyout * 0.95) or nil
						GM.Ledger.Record("sell", { itemID = pl.e.itemID,
							qty = pl.e.qty, unit = unit,
							auctionID = pl.e.aid or fp,
							dep = pl.e.dep, nm = pl.e.name })
					elseif couldExpire or expireMarks[fp] then
						-- vanished on schedule without a cancel → expiry
						GM.Ledger.Record("expire", { itemID = pl.e.itemID,
							qty = pl.e.qty,
							auctionID = pl.e.aid or fp,
							dep = pl.e.dep, nm = pl.e.name })
					else
						-- buyout is per-item on Forever — sale proceeds
						-- per unit are buyout minus the 5% AH cut
						local unit = pl.e.buyout and pl.e.qty > 0
							and math.floor(pl.e.buyout * 0.95) or nil
						GM.Ledger.Record("sell", { itemID = pl.e.itemID,
							qty = pl.e.qty, unit = unit,
							auctionID = pl.e.aid or fp,
							dep = pl.e.dep, nm = pl.e.name })
					end
				end
			end
			pendingLost[fp] = nil
		end
	end
	auctionCache = now
	GM.Inventory.auctions = now
	ownedPrimed = true
	lastOwnedAt = t
	SaveOwned()
	-- one-shot waiter for a fresh snapshot (cancel scan)
	local cb = GM.Inventory.onOwned
	GM.Inventory.onOwned = nil
	if cb then cb() end
	-- plan steps waiting on a manual cancel watch every snapshot —
	-- the listing vanishing is the step's completion signal
	if GM.PlanQueue and GM.PlanQueue.OnOwnedRefresh then
		GM.PlanQueue.OnOwnedRefresh()
	end
end

-- Forever's QueryOwnedAuctions takes a sorts table (TSM passes
-- OWNER_SORTS_TABLE, Syndicator {}) — a bare call fails inside pcall,
-- the server never answers, and MINE stays empty. Direct RefreshOwned
-- retries cover a missing OWNED_AUCTIONS_UPDATED event too.
local OWNER_SORTS = Enum and Enum.AuctionHouseSortOrder and {
	{ sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
	{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
} or {}

-- /goblin owndump — raw GetOwnedAuctionInfo rows + cache fingerprints.
-- Chasing phantom ledger posts: prints every field that distinguishes a
-- real listing from ghost rows (sold/history rows with no status to
-- filter on, nil-aid duplicates).
function GM.Inventory.DumpOwned()
	if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions) then
		GM.Print("no C_AuctionHouse")
		return
	end
	local n = C_AuctionHouse.GetNumOwnedAuctions() or 0
	GM.Print(format("owned auctions: %d rows", n))
	for i = 1, n do
		local ok, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
		if ok and type(info) == "table" then
			local keys = {}
			for k in pairs(info) do keys[#keys + 1] = tostring(k) end
			table.sort(keys)
			local ik = info.itemKey
			GM.Print(format("  [%d] id=%s aid=%s qty=%s buyout=%s bid=%s status=%s tLeft=%s",
				i,
				tostring(ik and ik.itemID or info.itemID),
				tostring(info.auctionID or info.auctionId),
				tostring(info.quantity), tostring(info.buyoutAmount),
				tostring(info.bidAmount), tostring(info.status),
				tostring(info.timeLeftSeconds)))
			GM.Print(format("      itemKey: id=%s suf=%s lvl=%s pet=%s · link=%s",
				tostring(ik and ik.itemID), tostring(ik and ik.itemSuffix),
				tostring(ik and ik.itemLevel),
				tostring(ik and ik.battlePetSpeciesID),
				info.itemLink and info.itemLink:sub(1, 60) or "nil"))
			GM.Print("      keys: " .. table.concat(keys, ","))
		else
			GM.Print(format("  [%d] <error>", i))
		end
	end
end

-- /goblin cancelprobe — fires ONE real cancel at the first owned
-- listing that resolves an auctionID, reporting which signature the
-- client accepts (aid vs owner-list index) and any thrown error.
-- Destructive by design: run it on a listing you want gone anyway.
function GM.Inventory.CancelProbe()
	local C = C_AuctionHouse
	GM.Print(format("cancel APIs: C_AuctionHouse.CancelAuction=%s global=%s",
		tostring(C and type(C.CancelAuction)),
		tostring(type(CancelAuction))))
	local n = C and C.GetNumOwnedAuctions
		and C.GetNumOwnedAuctions() or 0
	local row
	for i = 1, n do
		local ok, info = pcall(C.GetOwnedAuctionInfo, i)
		if ok and info and info.auctionID then
			row = { i = i, aid = info.auctionID,
				status = info.status }
			break
		end
	end
	if not row then
		GM.Print("no owned auctions with an auctionID to probe")
		return
	end
	GM.Print(format("probing row %d aid=%s status=%s — aid signature first",
		row.i, tostring(row.aid), tostring(row.status)))
	local fn = (C and C.CancelAuction) or CancelAuction
	if not fn then
		GM.Print("no cancel function to call")
		return
	end
	local ok, err = pcall(fn, row.aid)
	GM.Print(format("  CancelAuction(aid): ok=%s err=%s",
		tostring(ok), tostring(err)))
	local t0 = time()
	GM.Inventory.QueryOwned()
	GM.Time.After(3, function()
		local fresh = GM.Inventory.OwnedAt() or 0
		local e = GM.Inventory.OwnedByKey
			and GM.Inventory.OwnedByKey(row.aid)
		GM.Print(format("  enum fresh=%s stillListed=%s",
			tostring(fresh > t0), tostring(e ~= nil)))
		if e and e.idx then
			GM.Print("  still listed — index signature next")
			local ok2, err2 = pcall(fn, e.idx)
			GM.Print(format("  CancelAuction(idx=%s): ok=%s err=%s",
				tostring(e.idx), tostring(ok2), tostring(err2)))
			GM.Time.After(2, GM.Inventory.QueryOwned)
		elseif e then
			GM.Print("  still listed — aid call did not take")
		end
	end)
end

function GM.Inventory.QueryOwned()
	if not (C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions) then
		return
	end
	pcall(C_AuctionHouse.QueryOwnedAuctions, OWNER_SORTS)
	-- belt-and-suspenders: if the event name differs on this client the
	-- list still lands; GetNumOwnedAuctions returns what's loaded
	for _, d in ipairs({ 0.5, 1.5, 4 }) do
		GM.Time.After(d, GM.Inventory.RefreshOwned)
	end
end

-- ============ bids we're in ============
-- GM.Inventory.bids[auctionID] = { itemID, qty, ourBid, buyout, tl, at,
--   status } — status: winning | outbid | won | lost | gone. Sources:
-- PlaceBid hook (our bids anywhere), BIDS_UPDATED enumeration when the
-- client exposes GetNumBids/GetBidInfo, and formatted notifications
-- (AuctionOutbid / AuctionWon / AuctionRemoved) for terminal state.
-- The table itself is declared above the owned-snapshot block —
-- SaveOwned/LoadOwned persist it alongside auctionCache.

local function BidInfoByID(aid)
	if not (C_AuctionHouse and C_AuctionHouse.GetAuctionInfoByID) then
		return
	end
	local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, aid)
	if ok and type(info) == "table" then return info end
end

local function TrackBid(aid, ourBid)
	local info = BidInfoByID(aid)
	local id = info and info.itemKey and info.itemKey.itemID
	local b = bids[aid] or {}
	b.itemID = b.itemID or id
	b.qty = (info and info.quantity) or b.qty or 1
	b.buyout = (info and info.buyoutAmount) or b.buyout
	b.ourBid = ourBid or b.ourBid
	b.tl = (info and info.timeLeftSeconds) or b.tl
	b.at = time()
	b.status = "winning"
	bids[aid] = b
end

-- re-pull each tracked bid: auctionID known → GetAuctionInfoByID tells
-- whether playerGUID still leads and what the current bid is
function GM.Inventory.RefreshBids()
	if not (C_AuctionHouse and GM.AH.open) then return end
	local me = UnitGUID and UnitGUID("player")
	local t = time()
	for aid, b in pairs(bids) do
		if b.status == "winning" or b.status == "outbid" then
			local info = BidInfoByID(aid)
			if info then
				b.curBid = info.bidAmount or b.curBid
				b.tl = info.timeLeftSeconds or b.tl
				b.status = (me and info.bidder == me) and "winning"
					or "outbid"
				b.goneAt = nil
			else
				-- vanished without a terminal notification: sold to us
				-- surfaces as AuctionWon; silent removal = expired/outbid.
				-- Same time gate as the owned snapshot — a throttled
				-- enum can drop a live bid for one pass
				b.goneAt = b.goneAt or t
				if t - b.goneAt >= 15 and b.status == "outbid" then
					b.status = "lost"
				end
			end
		end
	end
end

function GM.Inventory.QueryBids()
	if not (C_AuctionHouse and C_AuctionHouse.QueryBids) then return end
	pcall(C_AuctionHouse.QueryBids, OWNER_SORTS)
	for _, d in ipairs({ 0.5, 1.5 }) do
		GM.Time.After(d, GM.Inventory.RefreshBids)
	end
end

local function EnumerateBids()
	-- probe the results API — name unverified on Forever, so nothing
	-- here is fatal; the PlaceBid hook already covers our own bids
	local getN = C_AuctionHouse.GetNumBids or C_AuctionHouse.GetNumBidAuctions
	local getI = C_AuctionHouse.GetBidInfo or C_AuctionHouse.GetBidAuctionInfo
	if not (getN and getI) then return end
	local me = UnitGUID and UnitGUID("player")
	local ok, n = pcall(getN)
	if not (ok and n) then return end
	for i = 1, n do
		local ok2, info = pcall(getI, i)
		if ok2 and type(info) == "table" and info.auctionID then
			local aid = info.auctionID
			local b = bids[aid] or {}
			b.itemID = b.itemID
				or (info.itemKey and info.itemKey.itemID)
			b.itemKey = b.itemKey or info.itemKey
				or (GM.AH.ItemKeyFromLink
					and GM.AH.ItemKeyFromLink(info.itemLink))
			b.itemLink = b.itemLink or info.itemLink
			b.qty = info.quantity or b.qty or 1
			b.curBid = info.bidAmount or info.requiredBid or b.curBid
			b.ourBid = b.ourBid or b.curBid
			b.buyout = info.buyoutAmount or b.buyout
			b.tl = info.timeLeftSeconds or b.tl
			b.at = time()
			b.status = (me and info.bidder == me) and "winning" or "outbid"
			bids[aid] = b
		end
	end
end

-- outbid entries drive the task list — GM.Inventory.Outbids() →
-- array of { itemID, qty, ourBid, curBid, tl, aid }
function GM.Inventory.Outbids()
	local t = {}
	for aid, b in pairs(bids) do
		if b.status == "outbid" then
			t[#t + 1] = {
				aid = aid, itemID = b.itemID, qty = b.qty,
				ourBid = b.ourBid, curBid = b.curBid,
				ctx = GM.Ctx(b.itemID, b.itemLink, b.itemKey),
				remain = b.tl and b.at and (b.at + b.tl - time()) or nil,
			}
		end
	end
	return t
end

-- display-ready posted rows for both mine surfaces (AH MINE tab and
-- the MyAuctions window): lot data + market ref + the undercut flag
-- CancelScan uses (book mbx < our unit). Undercut rows sort first —
-- they're the ones to cancel.
function GM.Inventory.MineRows()
	local rows = {}
	for fp, a in pairs(auctionCache) do
		if a.itemID then
			local mkt = GM.Price("dbmarket", a.itemID)
			local cheap, live
			if a.itemKey and (a.itemKey.itemSuffix or 0) ~= 0 then
				-- variants are separate markets: the itemID-wide mbx
				-- mixes every "of X" into one min that says nothing
				-- about THIS suffix. A same-variant ladder (the last
				-- targeted scan under the matching key) is the
				-- freshest proof; the variant's OWN book row (mbx
				-- under "v<id>:<sfx>:<lvl>") is the standing source —
				-- the base item's row stays a false alarm
				local sk = GM.AH.scanItemKey
				if sk and sk.itemID == a.itemID
					and (sk.itemSuffix or 0) == a.itemKey.itemSuffix
					and GM.AH.asks then
					for _, ask in ipairs(GM.AH.asks) do
						if not ask.own and ask.unit then
							cheap = ask.unit break
						end
					end
					live = true -- a scan result is live by definition
				end
				if not cheap then
					local e0 = GM.ItemEntry(a.itemID, a.itemKey)
					cheap = e0 and e0.mbx ~= math.huge and e0.mbx
					live = e0 and (e0._src == "mesh" or (e0._src == "book"
						and GM.AH.BookLive and GM.AH.BookLive()))
				end
			else
				-- mbx through the resolver: live book when it's
				-- freshest, mesh beacon when newer still, emitted row
				-- otherwise
				local e0 = GM.ItemEntry(a.itemID)
				cheap = e0 and e0.mbx ~= math.huge and e0.mbx
				-- undercut claims someone beats us NOW — only a live
				-- source (fresh book or mesh beacon) can say that; a
				-- stale emit mbx flags phantom undercuts on sole
				-- listings
				live = e0 and (e0._src == "mesh" or (e0._src == "book"
					and GM.AH.BookLive and GM.AH.BookLive()))
			end
			local undercut = live and cheap and a.buyout
				and cheap < a.buyout or nil
			-- tLeft is remaining-seconds at capture — rebase it or the
			-- column freezes at whatever the last refresh saw
			local remain = a.tLeft and a.at
				and (a.at + a.tLeft - time()) or a.tLeft
			local ctx = GM.Ctx(a.itemID, a.itemLink, a.itemKey)
			rows[#rows + 1] = {
				-- fp-keyed cache: hand cancel the real auctionID when
				-- the snapshot had one, else the enumeration index
				aid = a.aid or a.idx or fp,
				id = a.itemID, key = a.itemKey, link = a.itemLink,
				ctx = ctx,
				qty = (a.qty or 1) * (a.n or 1),
				unit = a.buyout, tLeft = remain,
				mkt = mkt, cheap = cheap, undercut = undercut,
				sold = a.sold,
				name = ctx.name or a.name
					or ("item " .. a.itemID),
			}
		end
	end
	table.sort(rows, function(a, b)
		if a.undercut ~= b.undercut then return a.undercut and true or false end
		return (a.name or "") < (b.name or "")
	end)
	return rows
end

-- auctions we've bid on (PlaceBid hook + BIDS_UPDATED enumeration).
-- Outbid sorts first — that's the row to act on.
function GM.Inventory.BidRows()
	local rows = {}
	for aid, b in pairs(bids) do
		if b.itemID and b.status ~= "gone" then
			local remain = b.tl and b.at
				and (b.at + b.tl - time()) or b.tl
			local ctx = GM.Ctx(b.itemID, b.itemLink, b.itemKey)
			rows[#rows + 1] = {
				aid = aid, id = b.itemID, key = b.itemKey,
				link = b.itemLink, qty = b.qty or 1, ctx = ctx,
				ourBid = b.ourBid, curBid = b.curBid or b.ourBid,
				buyout = b.buyout, status = b.status or "winning",
				remain = remain,
				name = ctx.name or ("item " .. b.itemID),
			}
		end
	end
	table.sort(rows, function(a, b)
		if (a.status == "outbid") ~= (b.status == "outbid") then
			return a.status == "outbid"
		end
		return (a.remain or math.huge) < (b.remain or math.huge)
	end)
	return rows
end

-- notifications carry the terminal transitions — the same
-- (notification, _, auctionID) triple Syndicator reads
local NOTIF = Enum and Enum.AuctionHouseNotification or {}
local function OnNotification(msg, _, aid)
	if not aid then return end
	if msg == NOTIF.AuctionOutbid then
		local b = bids[aid]
		if b then
			b.status = "outbid"
			GM.Print(GM.CC("warn") .. "outbid on "
				.. (GM.ItemName and GM.ItemName(b.itemID)
					or ("auction " .. aid)) .. "|r")
		end
		GM.Inventory.RefreshBids()
	elseif msg == NOTIF.AuctionWon then
		local b = bids[aid]
		if b then b.status = "won" end
	elseif msg == NOTIF.AuctionSold then
		-- the owned-side notifications carry the item name (or an aid
		-- on some builds) — MarkSold accepts either
		GM.Inventory.MarkSold(aid)
		GM.Inventory.QueryOwned()
	elseif msg == NOTIF.AuctionExpired then
		GM.Inventory.MarkExpired(aid)
	elseif msg == NOTIF.AuctionRemoved then
		-- bid rows drop by aid; owned rows mark by name/aid for the
		-- cancel verdict — the call covers whichever shape arrives
		if aid then
			bids[aid] = nil
			GM.Inventory.MarkRemoved(aid)
			GM.Inventory.QueryOwned()
		end
	elseif msg == NOTIF.BidPlaced then
		GM.Inventory.RefreshBids()
	end
end

-- capture bids placed anywhere (our window, Blizzard UI, TSM)
if C_AuctionHouse and C_AuctionHouse.PlaceBid
		and hooksecurefunc then
	hooksecurefunc(C_AuctionHouse, "PlaceBid", function(aid, amt)
		if aid then TrackBid(aid, amt) end
		GM.Time.After(1, GM.Inventory.RefreshBids)
	end)
end

-- ============ bank + alt snapshots ============
-- Bank contents only exist while the bank frame is open, and alts are
-- never live — both persist to GoblinMindSettings.inv[char] =
-- { bags = {id=qty}, bank = {id=qty}, at }. Bags snapshot on
-- BAG_UPDATE (debounced) + logout; bank on BANKFRAME_OPENED + bag
-- changes while the frame is up.

-- container lists are built per call — the carried range is learned
-- dynamically (a reagent/profession bag past the computed range gets
-- added the first time items enumerate there while the bank is
-- closed), so a load-time table would freeze the wrong boundary.
local function CarriedBags()
	return GM.CarriedContainerList()
end
local function BankBags()
	return (GM.BankContainerList and GM.BankContainerList())
		or { -1 }
end

local function ScanContainers(bags)
	local t = {}
	GM.EachBagSlot(bags, function(_, _, id, n)
		t[id] = (t[id] or 0) + n
	end)
	return t
end

local function Snapshot(where)
	GM.Inventory._snaps = (GM.Inventory._snaps or 0) + 1
	GM.MigrateCharKeys() -- one-shot canon once the realm resolves
	if not GoblinMindSettings then return end
	-- realm-unresolved sessions must not write a bare-name key — it
	-- reads back as a different character (phantom alt) forever after
	local me = GM.CharKeyQualified()
	if not me then return end
	GoblinMindSettings.inv = GoblinMindSettings.inv or {}
	local snap = GoblinMindSettings.inv[me]
		or { bags = {}, bank = {}, at = 0 }
	snap[where] = ScanContainers(
		where == "bags" and CarriedBags() or BankBags())
	snap.at = time()
	GoblinMindSettings.inv[me] = snap
end

-- this char's bank: live while the bank is open (0 counts — an open
-- bank is authoritative), snapshot only while it's closed
function GM.Inventory.BankStored(itemID)
	local live = GM.BankCount(itemID)
	if live > 0 or GM.bankOpen
		or (BankFrame and BankFrame:IsShown()) then
		return live
	end
	local inv = GoblinMindSettings and GoblinMindSettings.inv
	if not inv then return 0 end
	-- newest snapshot keyed to THIS char — bare and realm-qualified
	-- spellings of the same char both count as self
	local best, at = 0, -1
	for char, snap in pairs(inv) do
		if GM.IsSelfCharKey(char) and (snap.at or 0) >= at then
			at = snap.at or 0
			best = snap.bank and snap.bank[itemID] or 0
		end
	end
	return best
end

-- every OTHER character's bag + bank stock combined
function GM.Inventory.AltTotal(itemID)
	GM.MigrateCharKeys() -- realm may resolve between login and first read
	local n = 0
	for char, snap in pairs(
		GoblinMindSettings and GoblinMindSettings.inv or {}) do
		if not GM.IsSelfCharKey(char) then
			n = n + (snap.bags and snap.bags[itemID] or 0)
				+ (snap.bank and snap.bank[itemID] or 0)
		end
	end
	return n
end

-- called by GM.MigrateCharKeys once the realm answers: folds bare-name
-- inv/owned keys into Name-Realm form (snapshots are newest-wins), then
-- rehydrates the owned cache if it populated under a stale key at login
function GM.Inventory.MigrateKeys()
	if not GoblinMindSettings then return end
	local keepNewest = function(a, b)
		if not a then return b end
		if not b then return a end
		return ((a.at or 0) >= (b.at or 0)) and a or b
	end
	GM.CanonicalizeCharKeys(GoblinMindSettings.inv, keepNewest)
	GM.CanonicalizeCharKeys(GoblinMindSettings.owned, keepNewest)
	-- live auction data always outranks a rehydrated snapshot
	if not ownedPrimed then
		wipe(auctionCache)
		wipe(bids)
		LoadOwned()
	end
end

-- ============ counts ============

-- C.List/Economics ask for the same mat hundreds of times a render;
-- scanning auctionCache+alts per call was the "execution limit"
-- killer on window-open — shared BucketMemo, read-only rows.
local countOf = GM.BucketMemo(function(itemID)
	local bags = GM.BagCount(itemID)
	local bank = GM.Inventory.BankStored(itemID)
	local mail = mailCache[itemID] or 0
	local guild = guildCache[itemID] or 0
	local auction = 0
	for _, a in pairs(auctionCache) do
		if a.itemID == itemID then auction = auction + a.qty end
	end
	local alts = GM.Inventory.AltTotal(itemID)
	return {
		bags = bags, bank = bank, mail = mail, guild = guild,
		auction = auction, alts = alts,
		total = bags + bank + mail + guild + auction,
		allTotal = bags + bank + mail + guild + auction + alts,
	}
end)
GM.Inventory.Count = countOf

-- Set of owned itemIDs across every location (ledger inventory page).
-- Bank slots only enumerate while the bank frame is open — same
-- constraint BankCount has; the set just lacks bank items otherwise.
GM.Inventory.Owned = GM.BucketCache(function()
	local set = GM.BagItems and GM.BagItems() or {}
	for id in pairs(mailCache) do set[id] = true end
	for id in pairs(guildCache) do set[id] = true end
	for _, a in pairs(auctionCache) do
		if a.itemID then set[a.itemID] = true end
	end
	if GM.bankOpen or (BankFrame and BankFrame:IsShown()) then
		GM.EachBagSlot(BankBags(), function(_, _, id)
			set[id] = true
		end)
	end
	return set
end)

-- ============ events ============

local f = CreateFrame("Frame")
for _, evt in ipairs({
	"MAIL_INBOX_UPDATE", "MAIL_SHOW",
	"OWNED_AUCTIONS_UPDATED", "AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_AUCTION_CREATED",
	"BIDS_UPDATED", "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION",
	"GUILDBANKBAGSLOTS_CHANGED", "BANKFRAME_OPENED",
	"BAG_UPDATE", "PLAYER_LOGOUT", "PLAYER_LOGIN",
	"TRADE_SHOW", "TRADE_CLOSED",
}) do
	pcall(f.RegisterEvent, f, evt)
end
f:SetScript("OnEvent", function(_, event, ...)
	if event == "MAIL_INBOX_UPDATE" or event == "MAIL_SHOW" then
		scanInbox()
		scanAuctionMail()
	elseif event == "OWNED_AUCTIONS_UPDATED" then
		GM.Inventory.RefreshOwned()
	elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
		GM.Inventory.ArmPost(15)
		GM.Inventory.QueryOwned()
	elseif event == "BIDS_UPDATED" then
		EnumerateBids()
		GM.Inventory.RefreshBids()
	elseif event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION" then
		OnNotification(...)
	elseif event == "AUCTION_HOUSE_SHOW" or event == "PLAYER_LOGIN" then
		if event == "PLAYER_LOGIN" then LoadOwned() end
		GM.Inventory.QueryOwned()
		GM.Inventory.QueryBids()
	elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
		scanGuildBank()
	elseif event == "BANKFRAME_OPENED" then
		-- bank contents resolve async after the frame opens — the
		-- instant read can be empty, so snapshot on a beat. The event
		-- flag is authoritative — the native frame never shows on
		-- this client (custom bank), so gating on it never fired
		GM.Time.After(0.5, function()
			if GM.bankOpen or (BankFrame and BankFrame:IsShown()) then
				Snapshot("bank")
			end
		end)
	elseif event == "TRADE_SHOW" then
		-- the trade mirror: bag state before the window — slot reads
		-- inside the trade UI lie about provenance and empty on
		-- close, so the honest detector is the bag diff itself
		f._tradeBags = ScanContainers(CarriedBags())
	elseif event == "TRADE_CLOSED" then
		local before = f._tradeBags
		f._tradeBags = nil
		if not before then return end
		-- bag events settle a beat after the window drops; a
		-- cancelled trade diffs to zero and journals nothing
		GM.Time.After(0.4, function()
			if not (GM.Ledger and GM.Ledger.Record) then return end
			local now = ScanContainers(CarriedBags())
			for id in pairs(before) do
				local d = (now[id] or 0) - before[id]
				if d < 0 then
					GM.Ledger.Record("tradeout",
						{ itemID = id, qty = -d })
				elseif d > 0 then
					GM.Ledger.Record("tradein",
						{ itemID = id, qty = d })
				end
				now[id] = nil
			end
			for id, n in pairs(now) do
				GM.Ledger.Record("tradein", { itemID = id, qty = n })
			end
		end)
	elseif event == "BAG_UPDATE" or event == "PLAYER_LOGOUT" then
		-- coalesce bag churn into one snapshot; bank only while open
		if f._snapPending then return end
		f._snapPending = true
		GM.Time.After(0.5, function()
			f._snapPending = nil
			Snapshot("bags")
			if GM.bankOpen or (BankFrame and BankFrame:IsShown()) then
				Snapshot("bank")
			end
		end)
	end
end)
