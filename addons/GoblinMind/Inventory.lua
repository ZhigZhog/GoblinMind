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
local ownedPrimed = false -- first refresh just populates — everything
                          -- would look "new" otherwise
local emptyArmed = false  -- empty snapshots must repeat before vanish
                          -- processing (mid-requery reads can be empty)
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

-- ============ mailbox ============

local function scanInbox()
	GM.Inventory._inboxScans = (GM.Inventory._inboxScans or 0) + 1
	wipe(mailCache)
	if not (GetInboxNumItems and GetInboxItem) then return end
	local n = GetInboxNumItems() or 0
	for i = 1, n do
		for slot = 1, 20 do
			local ok, a, b, _, d = pcall(GetInboxItem, i, slot)
			if not ok then break end
			local id, count
			if type(a) == "number" then id, count = a, b
			elseif type(b) == "number" then id, count = b, d end
			if not id then break end
			mailCache[id] = (mailCache[id] or 0) + (count or 1)
		end
	end
end

-- ============ guild bank (current tab only — TSM opens every tab) ============

local function scanGuildBank()
	GM.Inventory._gbScans = (GM.Inventory._gbScans or 0) + 1
	wipe(guildCache)
	if not (GetGuildBankItemInfo and GetGuildBankItemLink) then return end
	local tab = GetCurrentGuildBankTab and GetCurrentGuildBankTab() or 1
	for slot = 1, 98 do
		local link = GetGuildBankItemLink(tab, slot)
		local id = link and tonumber(link:match("item:(%d+)"))
		if id then
			local _, count = GetGuildBankItemInfo(tab, slot)
			guildCache[id] = (guildCache[id] or 0) + (count or 1)
		end
	end
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

-- persist the owned snapshot so the MINE surfaces are a real log: the
-- enum only answers at the AH, but the last-known listings should
-- stay visible between visits (tLeft rebases off the stored `at`)
local function SaveOwned()
	if not GoblinMindSettings then return end
	GoblinMindSettings.owned = GoblinMindSettings.owned or {}
	local rows = {}
	for fp, a in pairs(auctionCache) do
		if a.itemID then
			rows[fp] = { itemID = a.itemID, qty = a.qty,
				buyout = a.buyout, tLeft = a.tLeft, at = a.at,
				n = a.n }
		end
	end
	local bs = {}
	for aid, b in pairs(bids) do bs[aid] = b end
	GoblinMindSettings.owned[GM.CharKey()] =
		{ rows = rows, bids = bs, at = time() }
end

-- rehydrate at login — ownedPrimed deliberately stays FALSE: a stale
-- snapshot must never feed post/sell ledger deltas; the first live
-- refresh re-primes cleanly
local function LoadOwned()
	local snap = GoblinMindSettings and GoblinMindSettings.owned
		and GoblinMindSettings.owned[GM.CharKey()]
	if not snap then return end
	for fp, a in pairs(snap.rows or {}) do
		auctionCache[fp] = { fp = fp, itemID = a.itemID,
			qty = a.qty, buyout = a.buyout, tLeft = a.tLeft,
			at = a.at, n = a.n }
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
	-- a requery can briefly report zero rows mid-flight; only trust an
	-- empty snapshot when it repeats, or every cached listing logs a
	-- phantom sale and comes back as a phantom post
	if n == 0 and ownedPrimed and next(auctionCache) and not emptyArmed then
		emptyArmed = true
		return
	end
	emptyArmed = nil
	-- first pass: collect rows + detect a reliable status field (only
	-- filter sold/history rows when some row actually reports active=0 —
	-- guards an inverted enum on this unverified client)
	local infos = {}
	local anyActive = false
	for i = 1, n do
		local ok2, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
		if ok2 and type(info) == "table" then
			infos[#infos + 1] = { i = i, info = info }
			if info.status == 0 then anyActive = true end
		end
	end
	local now = {}
	local seenAid = {}
	wipe(aidIndex)
	for _, r in ipairs(infos) do
		local i, info = r.i, r.info
		local id = (info.itemKey and info.itemKey.itemID) or info.itemID
		local aid = info.auctionID or info.auctionId
		if type(aid) ~= "number" and type(aid) ~= "string" then aid = nil end
		local dupAid = aid and seenAid[aid]  -- same id twice = ghost row
		local inactive = anyActive
			and info.status ~= nil and info.status ~= 0
		if id and not dupAid and not inactive then
			if aid then seenAid[aid] = true end
			local e = {
				itemID = id,
				qty = info.quantity or 1,
				-- per-ITEM buyout (Forever convention — not lot total)
				buyout = info.buyoutAmount or info.bidAmount,
				tLeft = info.timeLeftSeconds,
				at = time(),
				aid = aid, idx = i, n = 1,
			}
			e.fp = EntryFp(e)
			local prev = now[e.fp]
			-- identical listings share a fingerprint — count them and
			-- prefer the entry carrying a real id for cancel actions
			if prev then
				prev.n = (prev.n or 1) + 1
				if aid and not prev.aid then
					prev.aid, prev.idx = aid, i
				end
				if aid then aidIndex[aid] = e.fp end
				aidIndex[i] = e.fp
			else
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
	-- fingerprint delta: more listings at an fp than cached = posts,
	-- fewer = sells/expires — identical twins stay distinguishable by
	-- count even though they share one entry
	for fp, e in pairs(now) do
		local old = auctionCache[fp]
		local extra = (e.n or 1) - ((old and old.n) or 0)
		if ownedPrimed and extra > 0 and not recentCancels[fp]
			and t <= postUntil then
			for _ = 1, extra do
				GM.Ledger.Add("post", e.itemID, e.qty, e.buyout)
			end
		end
	end
	for fp, prev in pairs(auctionCache) do
		local lost = (prev.n or 1) - (now[fp] and now[fp].n or 0)
		if ownedPrimed and lost > 0
			and not recentCancels[fp]
			and not (prev.aid and recentCancels[prev.aid]) then
			-- hold the verdict one refresh — a ghost row that popped
			-- in and out is noise, a real sale stays gone
			pendingLost[fp] = { e = prev, lost = lost, fresh = true }
		end
	end
	for fp, pl in pairs(pendingLost) do
		if pl.fresh then
			pl.fresh = nil -- just armed this pass — verdict next refresh
		elseif recentCancels[fp]
			or (pl.e.aid and recentCancels[pl.e.aid]) then
			pendingLost[fp] = nil -- canceled while pending — not a sale
		else
			local cur = now[fp]
			local deficit = (pl.e.n or 1) - (cur and (cur.n or 1) or 0)
			local n = math.min(pl.lost, deficit)
			if n > 0 then
				local couldExpire = pl.e.tLeft
					and (t - pl.e.at) >= pl.e.tLeft
				for _ = 1, n do
					if couldExpire then
						-- vanished on schedule without a cancel → expiry
						GM.Ledger.Add("expire", pl.e.itemID, pl.e.qty,
							nil, { auctionID = pl.e.aid or fp })
					else
						-- buyout is per-item on Forever — sale proceeds
						-- per unit are buyout minus the 5% AH cut
						local unit = pl.e.buyout and pl.e.qty > 0
							and math.floor(pl.e.buyout * 0.95) or nil
						GM.Ledger.Add("sell", pl.e.itemID, pl.e.qty,
							unit, { auctionID = pl.e.aid or fp })
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
			GM.Print(format("  [%d] id=%s aid=%s qty=%s buyout=%s bid=%s status=%s tLeft=%s",
				i,
				tostring(info.itemKey and info.itemKey.itemID or info.itemID),
				tostring(info.auctionID or info.auctionId),
				tostring(info.quantity), tostring(info.buyoutAmount),
				tostring(info.bidAmount), tostring(info.status),
				tostring(info.timeLeftSeconds)))
			GM.Print("      keys: " .. table.concat(keys, ","))
		else
			GM.Print(format("  [%d] <error>", i))
		end
	end
end

function GM.Inventory.QueryOwned()
	if not (C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions) then
		return
	end
	pcall(C_AuctionHouse.QueryOwnedAuctions, OWNER_SORTS)
	-- belt-and-suspenders: if the event name differs on this client the
	-- list still lands; GetNumOwnedAuctions returns what's loaded
	for _, d in ipairs({ 0.5, 1.5, 4 }) do
		GM.After(d, GM.Inventory.RefreshOwned)
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
	for aid, b in pairs(bids) do
		if b.status == "winning" or b.status == "outbid" then
			local info = BidInfoByID(aid)
			if info then
				b.curBid = info.bidAmount or b.curBid
				b.tl = info.timeLeftSeconds or b.tl
				b.status = (me and info.bidder == me) and "winning"
					or "outbid"
			else
				-- vanished without a terminal notification: sold to us
				-- surfaces as AuctionWon; silent removal = expired/outbid
				if b.status == "outbid" then b.status = "lost" end
			end
		end
	end
end

function GM.Inventory.QueryBids()
	if not (C_AuctionHouse and C_AuctionHouse.QueryBids) then return end
	pcall(C_AuctionHouse.QueryBids, OWNER_SORTS)
	for _, d in ipairs({ 0.5, 1.5 }) do
		GM.After(d, GM.Inventory.RefreshBids)
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
			-- mbx through the resolver: live book when it's freshest,
			-- mesh beacon when newer still, emitted row otherwise
			local e0 = GM.ItemEntry(a.itemID)
			local cheap = e0 and e0.mbx ~= math.huge and e0.mbx
			local undercut = cheap and a.buyout
				and cheap < a.buyout or nil
			-- tLeft is remaining-seconds at capture — rebase it or the
			-- column freezes at whatever the last refresh saw
			local remain = a.tLeft and a.at
				and (a.at + a.tLeft - time()) or a.tLeft
			rows[#rows + 1] = {
				-- fp-keyed cache: hand cancel the real auctionID when
				-- the snapshot had one, else the enumeration index
				aid = a.aid or a.idx or fp,
				id = a.itemID, qty = (a.qty or 1) * (a.n or 1),
				unit = a.buyout, tLeft = remain,
				mkt = mkt, cheap = cheap, undercut = undercut,
				name = GM.ItemName(a.itemID) or ("item " .. a.itemID),
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
			rows[#rows + 1] = {
				aid = aid, id = b.itemID, qty = b.qty or 1,
				ourBid = b.ourBid, curBid = b.curBid or b.ourBid,
				buyout = b.buyout, status = b.status or "winning",
				remain = remain,
				name = GM.ItemName(b.itemID) or ("item " .. b.itemID),
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
	elseif msg == NOTIF.AuctionRemoved then
		bids[aid] = nil
	elseif msg == NOTIF.BidPlaced then
		GM.Inventory.RefreshBids()
	end
end

-- capture bids placed anywhere (our window, Blizzard UI, TSM)
if C_AuctionHouse and C_AuctionHouse.PlaceBid
		and hooksecurefunc then
	hooksecurefunc(C_AuctionHouse, "PlaceBid", function(aid, amt)
		if aid then TrackBid(aid, amt) end
		GM.After(1, GM.Inventory.RefreshBids)
	end)
end

-- ============ bank + alt snapshots ============
-- Bank contents only exist while the bank frame is open, and alts are
-- never live — both persist to GoblinMindSettings.inv[char] =
-- { bags = {id=qty}, bank = {id=qty}, at }. Bags snapshot on
-- BAG_UPDATE (debounced) + logout; bank on BANKFRAME_OPENED + bag
-- changes while the frame is up.

local CharKey = GM.CharKey

local BANK_BAGS = { -1, -3 } -- classic bank container + reagent bank
do
	local inv = Constants and Constants.InventoryConstants
	local first = (NUM_BAG_SLOTS or 4) + (inv and inv.NumReagentBagSlots or 0) + 1
	local n = (inv and inv.NumCharacterBankSlots) or NUM_BANKBAGSLOTS or 7
	for b = first, first + n - 1 do tinsert(BANK_BAGS, b) end
end

local function ScanContainers(bags)
	local t = {}
	if not (C_Container and C_Container.GetContainerItemInfo) then return t end
	for _, bag in ipairs(bags) do
		for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				t[info.itemID] = (t[info.itemID] or 0) + (info.stackCount or 1)
			end
		end
	end
	return t
end

local function Snapshot(where)
	GM.Inventory._snaps = (GM.Inventory._snaps or 0) + 1
	if not GoblinMindSettings then return end
	GoblinMindSettings.inv = GoblinMindSettings.inv or {}
	local me = CharKey()
	local snap = GoblinMindSettings.inv[me]
		or { bags = {}, bank = {}, at = 0 }
	snap[where] = ScanContainers(
		where == "bags" and { 0, 1, 2, 3, 4, 5 } or BANK_BAGS)
	snap.at = time()
	GoblinMindSettings.inv[me] = snap
end

-- this char's bank: live while the frame is open, snapshot otherwise
function GM.Inventory.BankStored(itemID)
	local live = GM.BankCount(itemID)
	if live > 0 then return live end
	local snap = GoblinMindSettings and GoblinMindSettings.inv
		and GoblinMindSettings.inv[CharKey()]
	return snap and snap.bank and snap.bank[itemID] or 0
end

-- every OTHER character's bag + bank stock combined
function GM.Inventory.AltTotal(itemID)
	local me, n = CharKey(), 0
	for char, snap in pairs(
		GoblinMindSettings and GoblinMindSettings.inv or {}) do
		if char ~= me then
			n = n + (snap.bags and snap.bags[itemID] or 0)
				+ (snap.bank and snap.bank[itemID] or 0)
		end
	end
	return n
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
	if BankFrame and BankFrame:IsShown()
		and C_Container and C_Container.GetContainerItemInfo then
		for _, bag in ipairs({ -1, 6, 7, 8, 9, 10, 11 }) do
			for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info and info.itemID then set[info.itemID] = true end
			end
		end
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
}) do
	pcall(f.RegisterEvent, f, evt)
end
f:SetScript("OnEvent", function(_, event, ...)
	if event == "MAIL_INBOX_UPDATE" or event == "MAIL_SHOW" then
		scanInbox()
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
		Snapshot("bank")
	elseif event == "BAG_UPDATE" or event == "PLAYER_LOGOUT" then
		-- coalesce bag churn into one snapshot; bank only while open
		if f._snapPending then return end
		f._snapPending = true
		GM.After(0.5, function()
			f._snapPending = nil
			Snapshot("bags")
			if BankFrame and BankFrame:IsShown() then Snapshot("bank") end
		end)
	end
end)
