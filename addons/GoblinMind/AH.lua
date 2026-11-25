local _, GM = ...

local Now = debugprofilestop or function() return GetTime() * 1000 end

-- Every C_AuctionHouse mutation is invoked exclusively from a hardware
-- click routed through PlanQueue. Nothing here self-drives.
--
-- API surface verified against TSM v4.15 on the _forever_ (1.60.x) client
-- — see WoWVault/forever-auction-api.md. Notably: item searches are
-- ItemKey-based via MakeItemKey, results come from Get{Num,}*SearchResult*
-- (no GetNumBrowseResults), and purchase confirm is
-- ConfirmCommoditiesPurchase, not ConfirmPurchase.

GM.AH = {
	open = false,
	scanItemID = nil,
	scanItemKey = nil,
	asks = nil,
	onScanDone = nil,
	pendingConfirm = nil, -- { itemID } awaiting ConfirmCommoditiesPurchase
}

local EMPTY_SORTS = {}

-- cancel-ledger dedupe: the owned-enum snapshot can rekey or duplicate
-- a listing between the cancel scan and the click, so the same real
-- auction reaches Execute under several keys. Record once per emitted
-- key, and per fingerprint cap at the cached listing count (identical
-- stacks share one fp — twins may each record, ghosts may not)
local cancelLedger = {} -- [key] = {count, cap, t}

local function RefreshUIs()
	GM.PlanQueue.Refresh()
	if GM.Shopping and GM.Shopping.Refresh then GM.Shopping.Refresh() end
end

local f = CreateFrame("Frame")
-- pcall each: an unknown event name would error and skip the rest
for _, evt in ipairs({
	"AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "PLAYER_LOGIN",
	"COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
	"COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
	"COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
	"AUCTION_HOUSE_POST_ERROR", "AUCTION_MULTISELL_FAILURE",
	"AUCTION_HOUSE_AUCTION_CREATED", "REPLICATE_ITEM_LIST_UPDATE",
	-- this client may deliver replicate results under the legacy name
	"AUCTION_ITEM_LIST_UPDATE",
	-- browse-all is the fallback book source when replicate is silent
	"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
	-- buy-result signals: silent rejections surface here
	"BIDS_UPDATED", "AUCTION_CANCELED", "UI_ERROR_MESSAGE", "CHAT_MSG_SYSTEM",
	"CHAT_MSG_MONEY",
}) do
	pcall(f.RegisterEvent, f, evt)
end
-- === item-vs-commodity dispatch ===
-- Stackables answer BOTH search endpoints on Forever: item rows carry
-- auctionID/bid (biddable, per-lot buyout) while commodity rows are
-- anonymous aggregates with no bid path. The events don't arrive in a
-- fixed order — the item set must get its window before commodity
-- rows are allowed through, or a laggy ITEM_SEARCH_RESULTS_UPDATED
-- hands the job aggregate asks for a listing it could have bid on.
local function ItemResultCount()
	return (GM.AH.scanItemKey and C_AuctionHouse.GetNumItemSearchResults
		and C_AuctionHouse.GetNumItemSearchResults(GM.AH.scanItemKey)) or 0
end
local function PollResults(itemID, waited)
	if GM.AH.scanItemID ~= itemID or GM.AH.scanConsumed then return end
	if ItemResultCount() > 0 then
		-- authoritative whenever they exist — the aggregate side of
		-- the same item is polluted junk (no auctionID, no bid)
		GM.AH.CollectItemAsks()
		return
	end
	local commN = (C_AuctionHouse.GetNumCommoditySearchResults
		and C_AuctionHouse.GetNumCommoditySearchResults(itemID)) or 0
	if GM.AH.itemEvtSeen and commN > 0 then
		-- item set is FINAL-empty: aggregate rows are the real data
		GM.AH.CollectCommodityAsks(itemID)
		return
	end
	-- nothing is provably empty until both sides have answered — but
	-- a non-stackable can't have an aggregate side at all, and the
	-- commodity event may already have landed for a real one
	local gi = C_Item and C_Item.GetItemInfo or GetItemInfo
	local ms = gi and select(8, gi(itemID))
	if GM.AH.itemEvtSeen and (GM.AH.commEvtSeen or (ms and ms <= 1)) then
		GM.AH.CollectItemAsks() -- honest empty book
		return
	end
	if waited < 3 then
		GM.Time.After(0.5, function() PollResults(itemID, waited + 0.5) end)
		return
	end
	-- deadline: partial data beats none
	if commN > 0 then GM.AH.CollectCommodityAsks(itemID)
	else GM.AH.CollectItemAsks() end
end

f:SetScript("OnEvent", function(_, event, ...)
	if event == "AUCTION_HOUSE_SHOW" then
		GM.AH.open = true
		-- follow the Blizzard AH window like a normal panel
		GM.PlanQueue.Show()
		-- auto-scan only when no book exists or it's a day old — full
		-- scans are expensive (they stall window open); manual FULL SCAN
		-- covers everything in between. Delayed so it doesn't stack on
		-- top of TSM's own AH-open work
		if GM.AH.BookAge() > 86400 then
			GM.Time.After(3, function()
				if GM.AH.open and GM.AH.BookAge() > 86400 then GM.AH.FullScan() end
			end)
		end
	elseif event == "PLAYER_LOGIN" then
		GM.AH.RestoreBook()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		GM.AH.open = false
		GM.AH.asks = nil
		GM.AH.pendingConfirm = nil
		-- peers stay open and degrade to their AH-closed states —
		-- only the session takeover (AHUI) closes with the frame
	elseif event == "REPLICATE_ITEM_LIST_UPDATE" or event == "AUCTION_ITEM_LIST_UPDATE" then
		if GM.AH.dbgEvents then GM.AH.dbgEvents[event] = true end
		-- either name may carry the replicate result on this client, but
		-- AUCTION_ITEM_LIST_UPDATE also fires for ordinary list updates —
		-- only collect while a full scan is actually outstanding
		if GM.AH.wantBook and not GM.AH.bookPending and not GM.AH.collecting then
			GM.AH.bookPending = true
			-- data can lag the event — retry the read while the buffer
			-- is still empty instead of giving up on the first try
			local tries = 0
			local function TryCollect()
				GM.AH.bookPending = nil
				if not (GM.AH.wantBook and not GM.AH.collecting) then return end
				tries = tries + 1
				local n = C_AuctionHouse.GetNumReplicateItems() or 0
				if n > 0 then
					GM.AH.CollectBook()
				elseif tries < 8 then
					GM.AH.bookPending = true
					GM.Time.After(0.5, TryCollect)
				end
			end
			GM.Time.After(0.5, TryCollect)
		end
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
		or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
		if GM.AH.dbgEvents then GM.AH.dbgEvents[event] = true end
		-- these fire for every browse — ours and TSM's; only consume
		-- while a browse book build is active
		if GM.AH.browse then GM.AH.OnBrowseResults() end
	elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		local itemID = ...
		-- flags are per-scan: foreign searches (TSM's scans run
		-- alongside ours) must not pretend our commodity side
		-- answered, or an item final-empty + a stale flag reads
		-- as "honest empty" while our rows are still in flight
		if itemID == GM.AH.scanItemID then
			GM.AH.commEvtSeen = true
			PollResults(itemID, 0)
		end
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		local ikey = ...
		-- same guard — the event carries the queried ItemKey (or
		-- nothing on some clients; a keyless arg can't be verified
		-- so it counts as ours rather than hanging the job)
		local iid = type(ikey) == "table" and ikey.itemID or ikey
		if GM.AH.scanItemID and (not iid or iid == GM.AH.scanItemID) then
			GM.AH.itemEvtSeen = true
			PollResults(GM.AH.scanItemID, 0)
		end
	elseif event == "COMMODITY_PRICE_UPDATED" then
		-- arg is the quoted total for the staged quantity
		local totalPrice = select(2, ...)
		local pc = GM.AH.pendingConfirm
		if pc then
			-- TSM's wrapper only resolves the buy when the quoted
			-- unit matches what the buy expected (bait pulled / cheap
			-- lots eaten between request and confirm must not buy at
			-- the drifted price). <= passes — a cheaper quote is a
			-- bargain, not a trap
			local unit = math.ceil((totalPrice or 0) / math.max(pc.qty or 1, 1))
			if pc.unit and unit > pc.unit then
				GM.AH.pendingConfirm = nil
				GM.Print(GM.CC("warn") .. format(
					"quote moved — expected %s ea, quoted %s ea — rescan before buying|r",
					GM.Money(pc.unit), GM.Money(unit)))
				if GM.Shopping and GM.Shopping.QuoteDied then
					GM.Shopping.QuoteDied(pc.itemID, true)
				end
			else
				pc.quote = totalPrice
				GM.Print("quote ready — total " .. GM.Money(totalPrice or 0) .. " — click CONFIRM")
			end
			RefreshUIs()
		end
	elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
		local pc = GM.AH.pendingConfirm
		GM.AH.pendingConfirm = nil
		GM.Print(GM.CC("warn") .. "no commodity quote — falling back to per-lot buyouts|r")
		if GM.PlanQueue.CommodityFallback then GM.PlanQueue.CommodityFallback() end
		if GM.Shopping and GM.Shopping.QuoteDied then
			GM.Shopping.QuoteDied(pc and pc.itemID)
		end
		RefreshUIs()
	elseif event == "COMMODITY_PURCHASE_FAILED" then
		local pc = GM.AH.pendingConfirm
		GM.AH.pendingConfirm = nil
		GM.Print(GM.CC("err") .. "commodity purchase failed|r")
		if GM.Shopping and GM.Shopping.QuoteDied then
			GM.Shopping.QuoteDied(pc and pc.itemID)
		end
		RefreshUIs()
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		local pc = GM.AH.pendingConfirm
		if pc then
			GM.Ledger.Add("buy", pc.itemID, pc.qty,
				pc.quote and math.floor(pc.quote / pc.qty) or nil)
		end
		GM.AH.pendingConfirm = nil
		GM.Print("purchase complete")
		RefreshUIs()
	elseif event == "BIDS_UPDATED" then
		local pb = GM.AH.pendingBuy
		if pb then
			GM.AH.pendingBuy = nil
			GM.Ledger.Add("buy", pb.itemID, pb.qty, math.floor(pb.total / pb.qty))
			GM.Print(GM.CC("pos") .. "buyout confirmed|r")
		end
	elseif event == "AUCTION_CANCELED" then
		-- a replicate stream fires this once per listing it replaces —
		-- thousands of lines of churn noise during a scan we asked
		-- for. Suppress while a book build is in flight plus a short
		-- tail so lagging events after Finish() don't leak through.
		if GM.AH.open and not GM.AH.Busy()
			and GetTime() >= (GM.AH.cancelMute or 0) then
			GM.Print(GM.CC("textDim") .. "auction canceled|r")
		end
	elseif event == "UI_ERROR_MESSAGE" then
		-- only surface errors at the AH — combat/gameplay errors like
		-- "target too close" aren't ours to echo
		local msg = select(2, ...) or ...
		if msg and GM.AH.open then
			GM.Print(GM.CC("err") .. tostring(msg) .. "|r")
		end
	elseif event == "CHAT_MSG_SYSTEM" then
		local msg = ...
		if msg then
			-- buyer-found: the message carries only the item name —
			-- mark the owned row SOLD and pull a fresh snapshot so the
			-- delta engine ledgers it. Deformat the client string so
			-- non-enUS clients still match.
			local pat = ERR_AUCTION_SOLD and ("^" ..
				ERR_AUCTION_SOLD:gsub("([%.%(%)%[%]%+%-%?%^%$%*%%])", "%%%1")
					:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)") .. "$")
			local nm = (pat and msg:match(pat))
				or msg:match("buyer has been found for your auction of (.+)")
			if nm then
				GM.Inventory.MarkSold((nm:gsub("%s*%.%s*$", "")))
			end
			if GM.AH.open and (msg:find("auction") or msg:find("bid")) then
				GM.Print(GM.CC("textDim") .. tostring(msg) .. "|r")
			end
		end
	elseif event == "CHAT_MSG_MONEY" then
		-- loose parse: sum g/s/c quantities anywhere in the message
		local msg = ...
		local copper = 0
		for v, u in tostring(msg or ""):gmatch("(%d+)%s*([gsc])") do
			copper = copper + v * ({ g = 10000, s = 100, c = 1 })[u]
		end
		if copper > 0 then GM.Ledger.Gold(copper, "chat") end
	elseif event == "AUCTION_HOUSE_POST_ERROR" or event == "AUCTION_MULTISELL_FAILURE" then
		GM.Print(GM.CC("err") .. "post failed — check the item/stack and try again|r")
		RefreshUIs()
	elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
		-- the owned-auction reconcile writes the post row — it attributes
		-- posts from ANY ui, not just our executor
		GM.Inventory.QueryOwned()
		GM.Print("auction posted")
	end
end)

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

-- TSM semantics on Forever: commodity == stackable (maxStack > 1).
-- C_AuctionHouse.GetItemCommodityStatus needs a real ItemLocation, not an
-- Item mixin, so it can't classify an arbitrary itemID.
function GM.AH.IsCommodity(itemID)
	if not (itemID and GetInfo) then return false end
	local _, _, _, _, _, _, _, maxStack = GetInfo(itemID)
	return (maxStack or 1) > 1
end

-- ======== scan clock + query dispatcher ========
-- One authority for WHEN AH endpoint calls leave the client. The
-- server drops query bursts silently — a dropped query delivers an
-- empty collect that reads as "no asks" — so every call (search,
-- replicate, browse) funnels through one paced queue. The clock
-- half is deltaTime-style: QueryAge(kind)/ScanAge(itemID) answer
-- "how long since X" from a single place instead of every module
-- keeping its own GetTime()/time() snapshot.
local QT = {}          -- kind -> GetTime() of last dispatch
local lastDispatch = 0 -- GetTime() of last dispatch, any kind
local queryQ = {}      -- pending { kind, fn } jobs, FIFO
local pumpArmed = false
local QGAP = 1.5       -- seconds between any two endpoint calls

function GM.AH.QueryAge(kind)
	return QT[kind] and (GetTime() - QT[kind]) or math.huge
end

local function PumpQ()
	pumpArmed = false
	local job = queryQ[1]
	if not job then return end
	-- targeted-search state is single-slot (scanItemID/onScanDone) —
	-- a search job can't run while another scan is still live or it
	-- clobbers its callback mid-flight. A fully-dropped query never
	-- fires an event, so PollResults never runs and scanConsumed
	-- stays nil — the 10s ceiling treats a silent scan as dead
	-- rather than letting it starve the queue
	if job.kind == "search" and GM.AH.scanItemID
		and not GM.AH.scanConsumed
		and GetTime() - (GM.AH.scanItemT or 0) < 10 then
		pumpArmed = true
		GM.Time.After(0.3, PumpQ)
		return
	end
	-- the server reports its own pipe readiness — the fixed gap is a
	-- floor between calls, this is the throttle's actual verdict
	if C_AuctionHouse.IsThrottledMessageSystemReady
		and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		pumpArmed = true
		GM.Time.After(0.3, PumpQ)
		return
	end
	local wait = QGAP - (GetTime() - lastDispatch)
	if wait > 0 then
		pumpArmed = true
		GM.Time.After(wait, PumpQ)
		return
	end
	table.remove(queryQ, 1)
	QT[job.kind], lastDispatch = GetTime(), GetTime()
	job.fn()
	if queryQ[1] then
		pumpArmed = true
		GM.Time.After(QGAP, PumpQ)
	end
end

function GM.AH.Dispatch(kind, fn)
	queryQ[#queryQ + 1] = { kind = kind, fn = fn }
	if not pumpArmed then
		pumpArmed = true
		PumpQ()
	end
end

-- freshness registry — epoch time() so it composes with bookT/
-- bookLotsT (which persist across sessions); the query-side clock
-- stays GetTime() for the sub-second resolution QGAP needs
GM.AH.scanT = {} -- itemID -> time() of last delivered targeted scan
GM.AH.scanN = {} -- itemID -> rows that scan delivered

function GM.AH.ScanAge(itemID)
	local t = itemID and GM.AH.scanT[itemID]
	return t and (time() - t) or math.huge
end

-- one answer to "where do I read this item's ask picture" — the
-- freshest of targeted scan vs book lots; past the ~15m throttle
-- horizon it's the emitted row's job (ItemEntry owns that tier)
function GM.AH.FreshSource(itemID)
	local s = GM.AH.ScanAge(itemID)
	local l = GM.AH.bookLotsT and (time() - GM.AH.bookLotsT) or math.huge
	if s <= l then return "scan", s end
	if l <= 900 then return "book", l end
	return "emit", math.huge
end

-- === Scans (read-only; safe to call from UI, no protection on queries) ===

function GM.AH.ScanItem(itemID, itemName, done, key)
	if not C_AuctionHouse then return done({}) end
	-- state setup rides INSIDE the job — a queued scan must not
	-- clobber the single-slot scanItemID/onScanDone of one still
	-- in flight (the pump already holds it back, this is belt)
	GM.AH.Dispatch("search", function()
		-- Forever's SendSearchQuery only accepts an ItemKey — no bare
		-- itemID path; stackables are searched the same way. Browse
		-- rows carry the exact key (itemID+suffix) — pass it through
		-- so suffixed variants ("of the Bear") resolve their own
		-- listings instead of querying the suffix-0 base item, which
		-- returns none.
		GM.AH.scanItemID = itemID
		GM.AH.scanItemKey = key or C_AuctionHouse.MakeItemKey(itemID, 0, 0, nil)
		GM.AH.scanItemT = GetTime()
		GM.AH.onScanDone = done
		GM.AH.asks = nil
		GM.AH.itemEvtSeen, GM.AH.commEvtSeen, GM.AH.scanConsumed = nil, nil, nil
		C_AuctionHouse.SendSearchQuery(GM.AH.scanItemKey, EMPTY_SORTS, true)
	end)
end

-- a chat/bag/tooltip link carries the variant in itemString field 8
-- (itemID:enchant:gem1:gem2:gem3:gem4:suffixID) — the only key source
-- when the caller didn't drill in through a browse/search row. A
-- suffix-0 key returns no listings when every posting is a variant,
-- so suffixed links MUST come through here.
function GM.AH.ItemKeyFromLink(link)
	local s = link and link:match("item:([^|h]+)")
	if not s or not (C_AuctionHouse and C_AuctionHouse.MakeItemKey) then
		return nil
	end
	local id, _, _, _, _, _, suffix = strsplit(":", s)
	id, suffix = tonumber(id), tonumber(suffix)
	if id and suffix and suffix ~= 0 then
		-- the itemString carries no itemLevel, but Forever keys do
		-- (owndump: Banded Girdle of Spirit = lvl 31) — a level-0 key
		-- can miss a strict server-side match where the real key hits
		local ilvl = GetInfo and (select(4, GetInfo(id))) or 0
		return C_AuctionHouse.MakeItemKey(id, ilvl or 0, suffix, nil)
	end
end

-- Time-left arrives in two shapes on Forever: real seconds on
-- item-search results (timeLeftSeconds) and a 0–3 bucket enum on
-- replicate rows (Short/Medium/Long/VeryLong — the same field
-- GetReplicateItemTimeLeft echoes). Small whole numbers are buckets;
-- map them to representative seconds so every consumer formats
-- seconds only. Anything past the 48h duration cap is a misread
-- field, not a time — nil it rather than show nonsense.
local TL_BUCKETS = { 1800, 7200, 43200, 172800, 172800 }
local function NormTl(v)
	if type(v) == "number" then
		if v >= 0 and v <= 4 and v % 1 == 0 then
			return TL_BUCKETS[v + 1] -- 30m / 2h / 12h / 48h
		end
		return v > 0 and v <= 172800 and v or nil
	end
	if type(v) == "table" then
		return NormTl(v.seconds or v.timeLeftSeconds or v.timeLeft)
	end
end

-- expiry estimation: the bucket enum is coarse, but a listing that
-- CROSSES a bucket boundary between scans pins its expiry exactly
-- (flipping to Long = 12h left at that moment); each later crossing
-- refines the countdown. Until a transition lands, a bucket midpoint
-- stands in — the UI marks estimated times with '~'.
-- key -> { lastB, seen, exp, est } — absolute GetTime expiry guesses
local TL_MID = { 900, 4500, 25200, 108000 } -- 15m / 75m / 7h / 30h
GM.AH.tlEst = GM.AH.tlEst or {}

function GM.AH.CollectCommodityAsks(itemID)
	local asks = {}
	for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
		local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
		if r and r.unitPrice and r.quantity and r.quantity > 0 then
			-- commodity rows carry no seller names on Forever
			-- (owners table is empty) — totalNumberOfOwners is the
			-- only seller signal the API gives back
			tinsert(asks, { qty = r.quantity, unit = r.unitPrice,
				nOwners = r.totalNumberOfOwners,
				own = (r.containsOwnerItem or r.isOwned) or nil })
		end
	end
	GM.AH.MergeOwnAsks(asks, GM.AH.scanItemKey)
	table.sort(asks, function(a, b) return a.unit < b.unit end)
	-- flag rows before delivery — solver/sniper consumers price off
	-- bait/step marks; unflagged rows feed the drag. Suffixed scans
	-- describe one variant's market — flagging them would mint
	-- item-level marks off a subset (same rule MarketUI applies)
	local sfx = GM.AH.scanItemKey and (GM.AH.scanItemKey.itemSuffix or 0) or 0
	if sfx == 0 and GM.Intel and GM.Intel.AnalyzeItem then
		GM.Intel.AnalyzeItem(itemID, asks, time())
	end
	GM.AH.asks = asks
	GM.AH.scanConsumed = true
	-- diagnostic trail: ahdump surfaces why a scan delivered what it
	-- did (throttle drop reads as both counts zero + no events)
	GM.AH.lastScanDiag = { id = itemID, n = #asks, src = "comm",
		itemEvt = GM.AH.itemEvtSeen or false,
		commEvt = GM.AH.commEvtSeen or false, t = time() }
	GM.AH.scanT[itemID], GM.AH.scanN[itemID] = time(), #asks
	if GM.AH.onScanDone then GM.AH.onScanDone(asks) end
end

function GM.AH.CollectItemAsks()
	local key = GM.AH.scanItemKey
	local asks = {}
	local me, meGUID = UnitName("player"),
		UnitGUID and UnitGUID("player")
	for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) do
		local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
		if r and r.auctionID then
			local price = r.buyoutAmount or r.buyout or r.minBid or r.minPrice
			local qty = r.quantity or r.totalQuantity or 1
			if price and qty > 0 then
				-- owners[] uses sentinels on Forever: "player" = our own
				-- listing, "" = redacted — TSM's wrapper translates the
				-- same way (player→UnitName, ""→"?")
				local seller = (r.owners and r.owners[1])
					or r.owner or r.ownerName or r.ownerFullName
					or r.seller or r.sellerName or r.posterName
				-- same leaked-constant guard as the replicate path —
				-- player names never carry underscores
				if type(seller) == "string" and seller:find("_") then
					seller = nil
				end
				local ownSeller = seller == "player"
				if ownSeller then seller = me
				elseif seller == "" then seller = "?" end
				-- Forever returns buyoutAmount PER ITEM, not the lot
				-- total (verified: qty=147 buyout=200 = 2s/bag lot 2g94s).
				-- unit is the price directly; total is the lot cost.
				tinsert(asks, { id = r.auctionID, qty = qty, unit = price, total = price * qty,
					bid = r.bidAmount, minBid = r.minBid,
					-- timeLeftSeconds arrives 0 (unpopulated) on this
					-- client — 0 is truthy in Lua, so without the >0
					-- guard it shadows the real bucket/estimate with
					-- a fake "expires now" everywhere downstream
					tl = (r.timeLeftSeconds and r.timeLeftSeconds > 0
						and r.timeLeftSeconds) or NormTl(r.timeLeft),
					own = (r.containsOwnerItem or r.isOwned or ownSeller) or nil,
					highBidder = (meGUID and r.bidder == meGUID) or nil,
					nOwners = r.totalNumberOfOwners,
					seller = seller })
			end
		end
	end
	GM.AH.MergeOwnAsks(asks, key)
	table.sort(asks, function(a, b) return a.unit < b.unit end)
	local sfx = GM.AH.scanItemKey and (GM.AH.scanItemKey.itemSuffix or 0) or 0
	if sfx == 0 and GM.Intel and GM.Intel.AnalyzeItem then
		GM.Intel.AnalyzeItem(GM.AH.scanItemID, asks, time())
	end
	GM.AH.asks = asks
	GM.AH.scanConsumed = true
	GM.AH.lastScanDiag = { id = GM.AH.scanItemID, n = #asks, src = "item",
		itemEvt = GM.AH.itemEvtSeen or false,
		commEvt = GM.AH.commEvtSeen or false, t = time() }
	if GM.AH.scanItemID then
		GM.AH.scanT[GM.AH.scanItemID], GM.AH.scanN[GM.AH.scanItemID] =
			time(), #asks
	end
	if GM.AH.onScanDone then GM.AH.onScanDone(asks) end
end

-- Forever's item search can omit our own listings — merge them back
-- from the owned snapshot (deduped by auctionID, no-op when the API
-- already returns them). Without this a sole-variant poster sees an
-- empty ladder and the solver reports "no asks listed" with their
-- own auction up. suffix match is exact: a variant scan must not
-- pull own listings of a different "of X".
function GM.AH.MergeOwnAsks(asks, key)
	if not (key and key.itemID and GM.Inventory
		and GM.Inventory.auctions) then return end
	local have = {}
	for _, a in ipairs(asks) do
		if a.id then have[a.id] = true end
		if a.own then return end -- API already answers own rows
	end
	local suffix = key.itemSuffix or 0
	for _, a in pairs(GM.Inventory.auctions) do
		local k = a.itemKey
		if a.itemID == key.itemID and a.buyout
			and (k and (k.itemSuffix or 0) or 0) == suffix
			and not (a.aid and have[a.aid]) then
			tinsert(asks, { id = a.aid, qty = a.qty or 1,
				unit = a.buyout, total = a.buyout * (a.qty or 1),
				own = true, seller = UnitName("player"),
				link = a.itemLink })
		end
	end
end
-- book[itemID] = { mb = cheapest unit incl. ours, mbx = cheapest unit
-- excluding ours, sup = units listed, n = auctions }. Subscribers get
-- the raw per-listing rows too (sniper diffs those).

GM.AH.book = nil
GM.AH.bookT = 0
GM.AH.bookSubs = {}
GM.AH.bookLots = nil -- iid:qty:unit lot fingerprints (others' listings)

-- rebuild a display ladder from the persisted book's lot
-- fingerprints when a targeted scan delivers empty — the replicate
-- endpoint and SendSearchQuery fail independently, so a fresh book
-- is often right where the item query got throttled to death.
-- Lots older than the server's own ~15m replicate throttle don't
-- count: a genuinely cleared market should show empty, not ghosts.
-- Rows carry no seller/auctionID — fromBook marks them so
-- consumers can downgrade buy/intel
function GM.AH.BookAsks(itemID)
	if not (itemID and GM.AH.bookLots and GM.AH.bookLotsT) then return end
	if time() - GM.AH.bookLotsT > 900 then return end
	local asks = {}
	local prefix = itemID .. ":"
	for fp, n in pairs(GM.AH.bookLots) do
		if fp:sub(1, #prefix) == prefix then
			local _, qty, unit, tlb = strsplit(":", fp)
			qty, unit = tonumber(qty), tonumber(unit)
			if qty and unit then
				for _ = 1, n do
					tinsert(asks, { qty = qty, unit = unit,
						tl = NormTl(tonumber(tlb)),
						fromBook = true })
				end
			end
		end
	end
	if #asks == 0 then return end
	table.sort(asks, function(a, b) return a.unit < b.unit end)
	return asks
end

-- The aggregate book persists in SavedVariables across sessions so a
-- login doesn't force a fresh full scan. Per-auction rows are
-- session-only — the sniper diff wants live listings anyway.
-- math.huge (the "no non-own listing" sentinel) can't survive
-- serialization, so it round-trips through -1.
function GM.AH.SaveBook()
	if not (GM.db and GM.AH.book) then return end
	local items = {}
	for id, e in pairs(GM.AH.book) do
		items[id] = { mb = e.mb,
			mbx = e.mbx == math.huge and -1 or e.mbx,
			mbx2 = e.mbx2 == math.huge and -1 or e.mbx2,
			sup = e.sup, n = e.n }
	end
	-- books are keyed by realm-faction scope — a char on another
	-- realm must not clobber this realm's AH picture
	GM.db.books = GM.db.books or {}
	local scope = GM.Scope()
	GM.db.books[scope] = { t = GM.AH.bookT,
		kind = GM.AH.bookKind, scope = scope, items = items,
		lots = GM.AH.bookLots, lotsT = GM.AH.bookLotsT }
	-- migrate legacy flat book once, then drop it
	GM.db.book = nil
end

function GM.AH.RestoreBook()
	local s = GM.db and (
		(GM.db.books and GM.db.books[GM.Scope()])
		or GM.db.book) -- legacy flat book: no scope = accept once
	if not (s and s.items) then return end
	local book = {}
	for id, e in pairs(s.items) do
		book[tonumber(id) or id] = { mb = e.mb,
			mbx = e.mbx == -1 and math.huge or e.mbx,
			mbx2 = e.mbx2 == -1 and math.huge or e.mbx2,
			sup = e.sup, n = e.n }
	end
	GM.AH.book, GM.AH.bookT, GM.AH.bookKind = book, s.t or time(), s.kind
	GM.AH.bookLots, GM.AH.bookLotsT = s.lots, s.lotsT
end

function GM.AH.FullScan()
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return
	end
	if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then return end
	-- never stack a second replicate pass on an in-flight collect —
	-- a parallel Poll chain doubles the frame work the loop below does
	if GM.AH.wantBook or GM.AH.collecting then
		GM.PlanQueue.ScanStatus(GM.CC("textDim")
			.. "a full scan is already running|r")
		return
	end
	-- ReplicateItems is heavy: this client enforces a script execution
	-- limit AND TSM hook-processes every replicate scan too — 30s floor
	if GM.AH.BookAge() < 30 then
		GM.Print(GM.CC("textDim") .. "full scan ran a moment ago — give it a few seconds|r")
		return
	end
	-- the server throttles ReplicateItems (~15 min after the last
	-- successful replicate collect — calls inside the window come back
	-- silently empty and the book falls back to browse). Warn, don't
	-- block: a stale stamp is possible and a real scan is worth trying.
	local lastOK = GM.db and GM.db.lastReplicateOK or 0
	local ago = time() - lastOK
	if lastOK > 0 and ago < 900 then
		GM.Print(GM.CC("warn") .. format(
			"last full scan was %dm ago — the server usually throttles "
			.. "for ~15m; this may fall back to browse|r", ago / 60))
	end
	local msg = GM.CC("textDim") .. "starting full scan…|r"
	GM.PlanQueue.ScanStatus(msg)
	if GM.Shopping and GM.Shopping.Status then GM.Shopping.Status(msg) end
	local prevT = GM.AH.bookT
	GM.AH.wantBook = true
	-- this client fires no completion event for replicate scans (neither
	-- REPLICATE_ITEM_LIST_UPDATE nor the legacy name) — poll the buffer
	-- instead: when the row count is nonzero and stable, data has landed
	local polls, lastN, stable = 0, -1, 0
	local eventsSeen = {}
	GM.AH.dbgEvents = eventsSeen
	local function Poll()
		if not GM.AH.wantBook then return end -- collect ran or gave up
		polls = polls + 1
		local n = C_AuctionHouse.GetNumReplicateItems() or 0
		if n > 0 then
			if n == lastN then
				stable = stable + 1
				-- this server trickles the buffer in bursts — a flat
				-- second is not "done". 4s stable (~8 polls) before
				-- declaring the stream complete; a premature collect
				-- still self-heals (the buffer keeps filling and the
				-- next click re-collects over it)
				if stable >= 8 then GM.AH.CollectBook(); return end
			else
				lastN, stable = n, 0
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					format("receiving auctions — %d so far…|r", n))
			end
		else
			-- replicate is being silently dropped (server throttle) —
			-- after ~5s fall back to a browse-all book build in parallel
			if polls == 10 and not GM.AH.browse then
				local lastOK = GM.db and GM.db.lastReplicateOK or 0
				local left = lastOK > 0 and 900 - (time() - lastOK) or 0
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					(left > 0 and format("full scan throttled — ~%dm left, browsing instead…|r",
						left / 60 + 1)
					or "full scan unanswered — switching to browse mode…|r"))
				GM.AH.BrowseBook()
			end
			-- debug surface stays in GM.AH.dbgEvents (poll count,
			-- buffer size, fired events) — the status line only needs
			-- to tell the player the server is slow to answer
			GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
				format("waiting for the auction house… (%ds)|r",
					floor(polls / 2)))
		end
		-- give-up while the buffer is EMPTY stays a flat timer (20s);
		-- once data is flowing, stable-count collect handles the end
		-- and the only bail left is a 4m absolute cap on a stream
		-- that never finishes trickling
		if polls < 480 and not (lastN <= 0 and polls >= 40) then
			GM.Time.After(0.5, Poll)
		else
			GM.AH.wantBook = nil
			if GM.AH.bookT == prevT and GM.AH.open and not GM.AH.browse then
				local warn = GM.CC("warn") .. (lastN > 0
					and format("stream paused at %d auctions — "
						.. "click FULL SCAN to resume|r", lastN)
					or "the auction house didn't answer — try again|r")
				GM.PlanQueue.ScanStatus(warn)
				if GM.Shopping and GM.Shopping.Status then GM.Shopping.Status(warn) end
				GM.PlanQueue.Progress(nil)
			end
			GM.PlanQueue.Refresh()
		end
	end
	-- ReplicateItems goes out on the shared queue — a search/browse
	-- still in flight can't make it arrive inside a burst
	GM.AH.Dispatch("replicate", function()
		local ok, err = pcall(C_AuctionHouse.ReplicateItems)
		if not ok then
			GM.AH.wantBook = nil
			GM.PlanQueue.ScanStatus(GM.CC("warn") .. "full scan failed: " .. tostring(err) .. "|r")
			GM.PlanQueue.Refresh()
			return
		end
		GM.Time.After(0.5, Poll)
	end)
	GM.PlanQueue.Refresh()
end

function GM.AH.BookAge()
	return GM.AH.bookT > 0 and (time() - GM.AH.bookT) or math.huge
end

-- freshest source wins: the live book is the authority only while
-- its snapshot is newer than the backend's upstream data. No DB →
-- the book always wins; no book → never live.
function GM.AH.BookLive()
	-- +2s epsilon: when the emit folded this very book snapshot in
	-- (scope dataAge == book_t), the two ages differ by a tick and a
	-- strict < would let the book beat the emit that already holds it
	return GM.AH.BookAge() + 2 < (GM.DataAge() or math.huge)
end

-- a full scan of either kind is in flight — used to disable the button
function GM.AH.Busy()
	return GM.AH.wantBook or GM.AH.collecting or GM.AH.browse
		or (#queryQ > 0 and true) or nil
end

-- cheapest unit excluding our own listings (decisions use this). A
-- bait-flagged drag lot isn't the market — when intel marks the
-- cheapest ask, answer the price behind it instead
function GM.AH.BookCheapest(itemID)
	local e = GM.AH.book and GM.AH.book[itemID]
	if not e or e.mbx == math.huge then return nil end
	local m = GM.Intel and GM.Intel.marks and GM.Intel.marks[itemID]
	if m and m.bait and (e.mbx2 or math.huge) < math.huge then
		return e.mbx2
	end
	return e.mbx
end

-- cheapest unit including ours (display)
function GM.AH.BookMin(itemID)
	local e = GM.AH.book and GM.AH.book[itemID]
	return e and e.mb
end

function GM.AH.BookSupply(itemID)
	local e = GM.AH.book and GM.AH.book[itemID]
	return e and e.sup
end

local collectGen = 0

-- Diagnostic: dump raw ask/book data so field meanings can be verified
-- against the client's actual API contract. Three sources:
--   item-search asks  — named-field tables (the plan's ask list)
--   replicate rows    — positional tuples (the full-scan book)
--   book aggregate    — what we actually stored
local function DumpReplicate(itemID, maxRows)
	local n = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
	GM.Print(format("replicate rows: %d%s", n, itemID and (" — dumping id " .. itemID) or ""))
	local shown = 0
	for i = 0, n - 1 do
		local link = C_AuctionHouse.GetReplicateItemLink(i)
		local id = GM.LinkID(link)
		if not itemID or id == itemID then
			local t = { C_AuctionHouse.GetReplicateItemInfo(i) }
			local o = {}
			for j = 1, math.min(#t, 20) do o[j] = tostring(t[j]) end
			GM.Print(format("row %d · linkid=%s · %s", i, tostring(id),
				link and (link:match("%[(.-)%]") or "?") or "no-link"))
			GM.Print("  fields(" .. #t .. "): " .. table.concat(o, " | "))
			shown = shown + 1
			if shown >= (maxRows or 10) then break end
		end
	end
	if itemID and shown == 0 then
		GM.Print("no matching rows — item not in this snapshot")
	end
	return n
end

function GM.AH.DumpRows(itemID, maxRows)
	maxRows = maxRows or 10
	-- part 1: live item-search asks — the same call the plan consumes.
	-- fire a real query so results are guaranteed fresh, then dump the
	-- raw named-field tables the API hands back.
	if itemID and C_AuctionHouse.MakeItemKey and C_AuctionHouse.GetItemSearchResultInfo
		and C_AuctionHouse.SendSearchQuery then
		local key = C_AuctionHouse.MakeItemKey(itemID, 0, 0, nil)
		local function dumpDone()
			local n = C_AuctionHouse.GetNumItemSearchResults(key) or 0
			GM.Print(format("item-search results: %d", n))
			for i = 1, math.min(n, 2) do
				local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
				if r then
					local o = {}
					for k, v in pairs(r) do
						if type(v) == "table" then v = "n=" .. #v end
						o[#o + 1] = k .. "=" .. tostring(v)
					end
					table.sort(o)
					GM.Print("  ask[" .. i .. "] " .. table.concat(o, " · "))
				end
			end
			-- compact sweep of every row — the buyout/qty relationship
			-- is what we're verifying (per-item vs lot total)
			for i = 1, n do
				local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
				if r then
					GM.Print(format("  [%d] qty=%s buyout=%s bid=%s minBid=%s",
						i, tostring(r.quantity), tostring(r.buyoutAmount),
						tostring(r.bidAmount), tostring(r.minBid)))
				end
			end
			GM.AH.onScanDone = nil
			GM.AH.scanItemKey = nil
			GM.AH.scanConsumed = true -- release the dispatch queue
		end
		GM.AH.Dispatch("search", function()
			GM.AH.scanItemID = itemID
			GM.AH.scanItemKey = key
			GM.AH.itemEvtSeen, GM.AH.commEvtSeen, GM.AH.scanConsumed = nil, nil, nil
			GM.AH.onScanDone = dumpDone
			C_AuctionHouse.SendSearchQuery(key, EMPTY_SORTS, true)
		end)
		-- commodity side of the same item — what CollectCommodityAsks
		-- would have consumed if the event fired
		if C_AuctionHouse.GetCommoditySearchResultInfo then
			GM.Time.After(1.5, function()
				local n = C_AuctionHouse.GetNumCommoditySearchResults
					and C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
				GM.Print(format("commodity-search results: %d (maxStack check: %s)",
					n, tostring(GM.AH.IsCommodity(itemID))))
				for i = 1, math.min(n, maxRows) do
					local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
					if r then
						local o = {}
						for k, v in pairs(r) do
							if type(v) == "table" then v = "n=" .. #v end
							o[#o + 1] = k .. "=" .. tostring(v)
						end
						table.sort(o)
						GM.Print("  cask[" .. i .. "] " .. table.concat(o, " · "))
					end
				end
			end)
		end
	end
	-- part 2: replicate snapshot; if empty, kick ReplicateItems and retry
	if not (C_AuctionHouse and C_AuctionHouse.GetReplicateItemInfo) then
		GM.Print("replicate API unavailable")
	else
		local n = C_AuctionHouse.GetNumReplicateItems() or 0
		if n == 0 and GM.AH.open and C_AuctionHouse.ReplicateItems then
			GM.Print("snapshot empty — calling ReplicateItems, retrying in 4s…")
			pcall(C_AuctionHouse.ReplicateItems)
			GM.Time.After(4, function() DumpReplicate(itemID, maxRows) end)
		else
			DumpReplicate(itemID, maxRows)
		end
	end
	-- part 3: what we actually stored
	if itemID and GM.AH.book and GM.AH.book[itemID] then
		local e = GM.AH.book[itemID]
		GM.Print(format("book[%d]: mb=%s mbx=%s sup=%d n=%d", itemID,
			GM.Money(e.mb), e.mbx == math.huge and "—" or GM.Money(e.mbx), e.sup, e.n))
	end
	-- part 4: how the last targeted scan actually delivered — a
	-- dropped/throttled query reads as n=0 with both events false
	local d = GM.AH.lastScanDiag
	if d then
		GM.Print(format("last scan: id=%s n=%d src=%s itemEvt=%s commEvt=%s · %ds ago",
			tostring(d.id), d.n, d.src, tostring(d.itemEvt),
			tostring(d.commEvt), time() - d.t))
	end
	if itemID and GM.AH.bookLots and GM.AH.bookLotsT then
		local n = 0
		local prefix = itemID .. ":"
		for fp in pairs(GM.AH.bookLots) do
			if fp:sub(1, #prefix) == prefix then n = n + 1 end
		end
		GM.Print(format("bookLots[%d]: %d fingerprints · %ds old",
			itemID, n, time() - GM.AH.bookLotsT))
	end
end

function GM.AH.CollectBook()
	if not (C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems) then return end
	local n = C_AuctionHouse.GetNumReplicateItems() or 0
	if n == 0 then return end
	-- same snapshot size as the book we just built — a duplicate update,
	-- not new data
	if n == GM.AH.lastBookN and GM.AH.BookAge() < 30 then return end
	GM.AH.collecting = true
	GM.AH.browse = nil -- replicate data wins over an in-flight browse build
	collectGen = collectGen + 1
	local gen = collectGen
	-- own-listing keys so "cheapest" never counts ourselves
	local ownSet = {}
	for _, a in pairs(GM.Inventory.auctions or {}) do
		if a.itemID and a.qty and a.buyout then
			ownSet[a.itemID .. ":" .. a.qty .. ":" .. a.buyout] = true
		end
	end
	local rows, book, lots = {}, {}, {}
	local i = 0
	local lastReport = 0
	local buyIdx -- field position of buyoutPrice; detected once below
	local function Finish()
		GM.AH.collecting = nil
		GM.AH.wantBook = nil
		GM.AH.cancelMute = GetTime() + 8
		GM.AH.lastBookN = n
		GM.AH.bookKind = "replicate"
		-- mesh broadcast diffs against the PREVIOUS snapshot — grab
		-- it before the swap
		local prevBook, prevLots, prevT =
			GM.AH.book, GM.AH.bookLots, GM.AH.bookT
		GM.AH.book, GM.AH.bookT = book, time()
		GM.AH.bookLots, GM.AH.bookLotsT = lots, GM.AH.bookT
		if GM.db then GM.db.lastReplicateOK = time() end
		pcall(GM.AH.SaveBook) -- persistence failure must not kill completion
		-- drop expiry estimates for listings that left this scan —
		-- dead or relisted, either way the anchor is stale
		for k, e in pairs(GM.AH.tlEst) do
			if (e.seen or 0) < gen then GM.AH.tlEst[k] = nil end
		end
		local items = 0
		for _ in pairs(book) do items = items + 1 end
		GM.PlanQueue.Progress(nil)
		GM.PlanQueue.ScanStatus(GM.CC("textDim") .. format("full scan complete — %d auctions · %d items priced|r", n, items))
		GM.Print(GM.CC("textDim") .. format("full scan complete — %d auctions · %d items priced|r", n, items))
		for _, cb in ipairs(GM.AH.bookSubs) do pcall(cb, rows, book) end
		if GM.Mesh and GM.Mesh.OnBook then
			pcall(GM.Mesh.OnBook, book, lots, prevBook, prevLots, prevT)
		end
		GM.PlanQueue.Refresh()
	end
	local function ProcessRow(idx)
		local link = C_AuctionHouse.GetReplicateItemLink(idx)
		-- one API call per row — the tuple serves stackSize, buyout
		-- AND the field-map detection (was 3 calls/row before)
		local t = { C_AuctionHouse.GetReplicateItemInfo(idx) }
		local stackSize = t[3]
		if link and not buyIdx then
			-- Forever's tuple carries an extra field early on, so
			-- buyout sits one slot past the retail map (11 vs 10).
			-- Instead of hardcoding, find the itemID field — it is
			-- always buyoutIndex + 7 in both layouts.
			local id = GM.LinkID(link)
			for j = #t, 11, -1 do
				if id and t[j] == id then buyIdx = j - 7 break end
			end
			buyIdx = buyIdx or 10
			GM.Print(GM.CC("textDim") ..
				format("book field map: buyout at index %d|r", buyIdx))
		end
		local buyout = buyIdx and t[buyIdx] or nil
		if link and stackSize and stackSize > 0 and buyout and buyout > 0 then
			local id = GM.LinkID(link)
			-- Forever convention is per-item buyout everywhere
			-- (verified in item-search: qty=147 buyout=200 = 2s/bag);
			-- replicate follows the same server store — do NOT
			-- divide by stackSize or multi-stack items underprice
			local unit = buyout
			local own = id and ownSet[id .. ":" .. stackSize .. ":" .. buyout] or false
			-- seller name for intel marks: scan ONLY the window
			-- between buyout and itemID — that's bidder/owner
			-- territory in both known layouts (retail owner =
			-- buyout+4, Forever's extra field moves it but stays
			-- inside the window). Whole-tuple scans picked up
			-- leaked localization keys ("REQ_LEVEL_ABBR") from
			-- unrelated fields. Reject any string with an
			-- underscore too — player names can't have them, so a
			-- constant token can never stand in for a seller
			local seller
			for j = buyIdx + 1, math.min(buyIdx + 6, #t) do
				local v = t[j]
				if type(v) == "string" and v ~= "" and v ~= link
					and not v:find("_") then
					seller = v
				end
			end
			-- bid sits right after buyout in the replicate tuple
			-- (retail map: buyoutPrice=10, bidAmount=11 — Forever's
			-- shift moves both). Number-typed only; a wrong index is
			-- a string/flag and fails the check.
			local bid = type(t[buyIdx + 1]) == "number" and t[buyIdx + 1] or nil
			local rawTl
			if type(C_AuctionHouse.GetReplicateItemTimeLeft) == "function" then
				local ok, s = pcall(C_AuctionHouse.GetReplicateItemTimeLeft, idx)
				if ok then rawTl = s end
			end
			if rawTl == nil and buyIdx and buyIdx > 3 then
				-- the replicate tuple itself carries timeLeft three
				-- slots before buyoutPrice in both known layouts
				-- (buyout 11→tl 8 on Forever, 10→7 on retail) —
				-- read it straight when the dedicated API is absent
				-- or returns nothing NormTl can use
				rawTl = t[buyIdx - 3]
			end
			local tl = NormTl(rawTl)
			local key = link .. ":" .. stackSize .. ":" .. buyout
			-- raw enum bucket (0-3) feeds the transition tracker —
			-- crossings between CONSECUTIVE scans pin the expiry;
			-- a gap means the row vanished and may be a relist
			local tlb = type(rawTl) == "number" and rawTl >= 0
				and rawTl <= 4 and rawTl % 1 == 0 and rawTl or nil
			local gennow = GetTime()
			local est = GM.AH.tlEst[key]
			if tlb then
				if not est or est.seen ~= gen - 1 then
					est = { lastB = tlb, seen = gen,
						est = gennow + TL_MID[tlb + 1] }
					GM.AH.tlEst[key] = est
				else
					if tlb < est.lastB then
						est.exp, est.est =
							gennow + TL_BUCKETS[tlb + 1], nil
					elseif tlb > est.lastB then
						est.exp, est.est = nil, nil -- relisted — reset
					end
					est.lastB, est.seen = tlb, gen
				end
			end
			rows[#rows + 1] = { id = id, link = link, qty = stackSize, unit = unit,
				buyout = buyout, bid = bid, tl = tl,
				tlex = est and (est.exp or est.est) or nil,
				key = key, own = own, seller = seller }
			if id then
				local e = book[id]
				if not e then
					book[id] = { mb = unit, mbx = own and math.huge or unit,
						mbx2 = math.huge, sup = stackSize, n = 1 }
				else
					if unit < e.mb then e.mb = unit end
					-- two cheapest non-own units — a flagged bait lot
					-- poisons mbx; mbx2 is the price behind the drag
					if not own then
						if unit < e.mbx then
							e.mbx2, e.mbx = e.mbx, unit
						elseif unit < (e.mbx2 or math.huge) then
							e.mbx2 = unit
						end
					end
					e.sup = e.sup + stackSize
					e.n = e.n + 1
				end
				-- lot fingerprint for the brain's sale-delta engine —
				-- others' listings only; own cancels would read as sales.
				-- The time-left bucket rides as a 4th field: the brain
				-- diffs on the 3-field prefix (identity) and uses the
				-- bucket to classify disappearances — gone with time
				-- provably left = confident sale; else inconclusive.
				if not own then
					local fp = id .. ":" .. stackSize .. ":" .. unit
						.. ":" .. (tlb or "x")
					lots[fp] = (lots[fp] or 0) + 1
				end
			end
		end
	end
	local lastI, stalled = 0, 0
	local function Chunk()
		if gen ~= collectGen then return end -- superseded by a newer collect
		-- time-budgeted, not row-budgeted: a fixed chunk either froze
		-- frames on fat books or crawled on thin ones. 5ms of Lua per
		-- tick with an inter-slice breather — After(0) chained the
		-- slices back-to-back and held ~half of every frame for tens
		-- of seconds under AUTO.
		local t0 = Now()
		while i < n and Now() - t0 < 5 do
			-- a throwing row (bad index, transient buffer state) must
			-- not kill the chain — the next chunk only schedules at
			-- the bottom of this function
			pcall(ProcessRow, i)
			i = i + 1
		end
		if i < n then
			-- status text is font work — ~2 updates/sec, not per chunk
			if Now() - lastReport > 400 then
				lastReport = Now()
				GM.PlanQueue.Progress(i / n)
				GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
					format("processing results — %d/%d|r", i, n))
			end
			GM.Time.After(0.03, Chunk)
		else
			Finish()
		end
	end
	Chunk()
	-- watchdog: if the chunk chain died silently (i stops advancing),
	-- restart it rather than leaving collect stuck forever
	GM.Time.After(3, function()
		if gen ~= collectGen or not GM.AH.collecting then return end
		local function Dog()
			if gen ~= collectGen or not GM.AH.collecting then return end
			if i == lastI then
				stalled = stalled + 1
				if stalled == 2 then
					-- 10s no progress — revive the chain where it
					-- stopped, and keep the dog alive: a second
					-- stall must not become permanent
					stalled = 0
					GM.Print(GM.CC("warn") ..
						format("book collect stalled at %d/%d — resuming|r", i, n))
					Chunk()
				end
			else
				lastI, stalled = i, 0
			end
			GM.Time.After(5, Dog)
		end
		lastI = i
		GM.Time.After(5, Dog)
	end)
end

-- Browse-all book build — the fallback when ReplicateItems is silently
-- dropped (server throttle, no completion event on this client).
-- SendBrowseQuery returns per-itemKey aggregates — {itemKey, minPrice,
-- totalQuantity} — so this book has mb/sup but no per-auction rows and
-- no own-listing exclusion (mbx ≈ mb).
local BROWSE_SORTS = Enum and Enum.AuctionHouseSortOrder and {
	{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
	{ sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
} or nil

function GM.AH.BrowseBook()
	if not (C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.GetBrowseResults) then
		return false
	end
	local b = { seen = 0, book = {}, rows = {}, tries = 0 }
	GM.AH.browse = b
	-- the query rides the shared queue — GM.AH.browse is set now so
	-- the wait is visible as busy, but the endpoint call + watchdog
	-- only arm when the job actually dispatches
	GM.AH.Dispatch("browse", function()
		local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, {
			searchString = "", sorts = BROWSE_SORTS,
			filters = {}, itemClassFilters = {},
		})
		if not ok then
			GM.AH.browse = nil
			GM.PlanQueue.ScanStatus(GM.CC("warn") .. "browse query failed: " .. tostring(err) .. "|r")
			GM.PlanQueue.Refresh()
			return
		end
		-- stall watchdog: browse events should arrive promptly
		GM.Time.After(6, function()
			if GM.AH.browse == b and b.seen == 0 then
				GM.AH.browse = nil
				GM.PlanQueue.ScanStatus(GM.CC("warn") .. "the auction house isn't responding — try again later|r")
				GM.PlanQueue.Refresh()
			end
		end)
		GM.PlanQueue.Refresh()
	end)
	GM.PlanQueue.Refresh()
	return true
end

local function FinishBrowse(b)
	GM.AH.browse = nil
	GM.AH.cancelMute = GetTime() + 8
	-- a fresh replicate book beats aggregate data — don't clobber it
	if GM.AH.BookAge() < 60 and GM.AH.bookKind == "replicate" then return end
	GM.AH.bookKind = "browse"
	GM.AH.book, GM.AH.bookT = b.book, time()
	-- browse has no per-lot rows, but the last replicate's fingerprint
	-- map stays valid on its own timestamp — keep bookLots/bookLotsT
	-- riding persists or the brain's sale-delta engine starves (SV
	-- flushes nearly always caught the post-browse lots=nil book)
	pcall(GM.AH.SaveBook) -- persistence failure must not kill completion
	local items = 0
	for _ in pairs(b.book) do items = items + 1 end
	GM.PlanQueue.Progress(nil)
	local msg = GM.CC("textDim") .. format("scan complete — %d items priced (browse mode)|r", items)
	GM.PlanQueue.ScanStatus(msg)
	GM.Print(msg)
	for _, cb in ipairs(GM.AH.bookSubs) do pcall(cb, b.rows, b.book) end
	GM.PlanQueue.Refresh()
end

function GM.AH.OnBrowseResults()
	local b = GM.AH.browse
	if not b then return end
	local results = C_AuctionHouse.GetBrowseResults() or {}
	-- the array resets when someone (TSM) sends a new browse query —
	-- rebuild rather than trust stale indexes
	if #results < b.seen then
		b.seen, b.book, b.rows = 0, {}, {}
	end
	b.tries = 0 -- any delivered page resets the retry budget —
	-- pauses between pages are normal on a slow server
	for i = b.seen + 1, #results do
		local r = results[i]
		local id = r.itemKey and r.itemKey.itemID
		if id and r.minPrice and r.minPrice > 0 then
			local e = b.book[id]
			if not e then
				b.book[id] = { mb = r.minPrice, mbx = r.minPrice,
					mbx2 = math.huge, sup = r.totalQuantity or 0, n = 1 }
			else
				if r.minPrice < e.mb then
					e.mbx2, e.mb, e.mbx = e.mbx, r.minPrice, r.minPrice
				elseif r.minPrice < (e.mbx2 or math.huge) then
					e.mbx2 = r.minPrice
				end
				e.sup = e.sup + (r.totalQuantity or 0)
				e.n = e.n + 1
			end
			-- key carries the price so a later min-price drop re-flags
			-- for the sniper diff
			b.rows[#b.rows + 1] = { id = id, qty = r.totalQuantity or 1,
				unit = r.minPrice, buyout = r.minPrice,
				key = "b:" .. id .. ":" .. r.minPrice }
		end
		b.seen = i
	end
	GM.PlanQueue.ScanStatus(GM.CC("textDim") ..
		format("browsing the auction house — %d items…|r", b.seen))
	if C_AuctionHouse.HasFullBrowseResults and C_AuctionHouse.HasFullBrowseResults() then
		FinishBrowse(b)
	else
		-- request the next page; the ADDED event drives the next pass.
		-- retry once after 4s if the event never comes
		pcall(C_AuctionHouse.RequestMoreBrowseResults)
		local mySeen = b.seen
		GM.Time.After(4, function()
			if GM.AH.browse == b and b.seen == mySeen then
				b.tries = b.tries + 1
				if b.tries <= 3 then
					pcall(C_AuctionHouse.RequestMoreBrowseResults)
				else
					-- keep the partial book — hundreds of priced items
					-- beat throwing the whole build away
					GM.PlanQueue.ScanStatus(GM.CC("warn") ..
						format("scan stalled at %d items — keeping partial book|r", mySeen))
					FinishBrowse(b)
				end
			end
		end)
	end
end

-- Posting needs a real ItemLocation from the bags, not a link.
function GM.AH.FindInBags(itemID)
	if not ItemLocation then return end
	local loc, count
	GM.EachBagSlot(GM.CarriedContainerList(),
		function(bag, slot, id, n, locked)
			if id == itemID and not locked then
				loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
				count = n
				return true
			end
		end)
	return loc, count
end

-- Listing fee for posting `qty` of itemID (24h listing, duration=2).
-- Commodities resolve by itemID alone; items need a real bag stack, so a
-- pure flip falls back to a vendor-value estimate.
function GM.AH.DepositCost(itemID, qty)
	if not (itemID and qty and C_AuctionHouse) then return 0 end
	if GM.AH.IsCommodity(itemID) and C_AuctionHouse.CalculateCommodityDeposit then
		local ok, cost = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, 2, qty)
		if ok and cost then return cost end
	end
	local loc = GM.AH.FindInBags(itemID)
	if loc and C_AuctionHouse.CalculateItemDeposit then
		local ok, cost = pcall(C_AuctionHouse.CalculateItemDeposit, loc, 2, qty)
		if ok and cost then return cost end
	end
	local vendor = GetInfo and select(11, GetInfo(itemID))
	if vendor and vendor > 0 then
		return floor(vendor * qty * 0.30) -- ~15% MSV per 12h; verify against client
	end
	return 0
end

-- === Executors: ONE protected call per hardware click, nothing more ===

function GM.AH.Execute(step)
	if not GM.AH.open then
		GM.Print("open the auction house first")
		return false
	end
	if step.kind == "buy" and step.commodity then
		-- StartCommoditiesPurchase(itemID, quantity, expectedUnitPrice)
		GM.Print(format("requesting quote for %d× @ %s ea…", step.qty, GM.Money(step.unit)))
		C_AuctionHouse.StartCommoditiesPurchase(step.itemID, step.qty, step.unit)
		-- pc.unit rides for the quote-drift check on PRICE_UPDATED
		local pc = { itemID = step.itemID, qty = step.qty, unit = step.unit }
		GM.AH.pendingConfirm = pc
		-- if no quote lands the staged flow is dead on this client —
		-- splice in per-lot buyouts automatically
		GM.Time.After(4, function()
			if GM.AH.pendingConfirm == pc and not pc.quote then
				GM.AH.pendingConfirm = nil
				GM.Print(GM.CC("warn") .. "no commodity quote — falling back to per-lot buyouts|r")
				if GM.PlanQueue.CommodityFallback then GM.PlanQueue.CommodityFallback() end
				if GM.Shopping and GM.Shopping.QuoteDied then
					GM.Shopping.QuoteDied(pc.itemID)
				end
				RefreshUIs()
			end
		end)
		return "confirm"
	elseif step.kind == "buy" then
		if not step.auctionID then
			GM.Print(GM.CC("err") .. "missing auction id — hit RESCAN|r")
			return false
		end
		-- bidBuyout is the lot total — the scanned total avoids copper drift
		local total = step.total or step.unit * step.qty
		GM.Print(format("buying %d× for %s…", step.qty, GM.Money(total)))
		GM.AH.pendingBuy = { itemID = step.itemID, qty = step.qty, total = total }
		C_AuctionHouse.PlaceBid(step.auctionID, total)
		return true
	elseif step.kind == "bid" then
		-- a real bid, not a buyout — total is the lot bid amount
		if not step.auctionID then
			GM.Print(GM.CC("err") .. "missing auction id — rescan first|r")
			return false
		end
		GM.Print(format("bidding %s…", GM.Money(step.total)))
		C_AuctionHouse.PlaceBid(step.auctionID, step.total)
		return true
	elseif step.kind == "confirm" then
		if not GM.AH.pendingConfirm then return false end
		GM.Print("confirming purchase…")
		C_AuctionHouse.ConfirmCommoditiesPurchase(GM.AH.pendingConfirm.itemID, GM.AH.pendingConfirm.qty)
		return true
	elseif step.kind == "post" then
		local loc, stackCount = GM.AH.FindInBags(step.itemID)
		if not loc then
			GM.Print("no unlocked stack of that item in bags")
			return false
		end
		-- post only what bags actually hold — bought lots sit in the mailbox
		-- until fetched, and skipped buys shrink the plan
		local have = GM.BagCount(step.itemID)
		local qty = math.min(step.qty, have)
		if qty < 1 then
			GM.Print("nothing in bags to post — collect the mailbox first")
			return false
		end
		if qty < step.qty then
			GM.Print(format("posting %d of %d (rest still in mail/bank)", qty, step.qty))
		end
		-- Ask the client itself: commodity status from the real ItemLocation,
		-- exactly like TSM's PostAuction. Fall back to the maxStack heuristic.
		local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, loc)
		local isComm = (ok and Enum and Enum.ItemCommodityStatus
			and status == Enum.ItemCommodityStatus.Commodity)
			or (not ok and GM.AH.IsCommodity(step.itemID))
		-- bid below buyout only — a bid equal to buyout is rejected
		local bid = step.bid and step.bid < step.unit and step.bid or nil
		if GM.Inventory.ArmPost then GM.Inventory.ArmPost(15) end
		if isComm then
			C_AuctionHouse.PostCommodity(loc, step.duration or 2, qty, step.unit)
		else
			-- PostItem's qty is this auction's stack size — can't exceed the stack.
			-- bid/buyout are LOT prices (TSM: itemBid*stackSize — verified in
			-- LibTSMWoW AuctionHouseWrapper) — step.unit/bid are per-item, so
			-- scale by the posted stack or a multi-stack lists at 1 item's price
			local postQty = math.min(qty, stackCount or qty)
			C_AuctionHouse.PostItem(loc, step.duration or 2, postQty,
				bid and bid * postQty or nil, step.unit * postQty)
		end
		return true
	elseif step.kind == "cancel" then
		if not step.auctionID then
			GM.Print(GM.CC("err") .. "missing auction id — rescan first|r")
			return false
		end
		GM.Inventory.recentCancels[step.auctionID] = time()
		local a = GM.Inventory.OwnedByKey
			and GM.Inventory.OwnedByKey(step.auctionID)
		-- already gone (canceled in Blizzard's UI) and a live enum has
		-- answered this session — the step just completes
		if not a and GM.Inventory.OwnedPrimed
			and GM.Inventory.OwnedPrimed() then
			return true
		end
		local now = time()
		for k, c in pairs(cancelLedger) do
			if now - (c.t or 0) > 600 then cancelLedger[k] = nil end
		end
		-- a step already recorded for this key never records again —
		-- re-emitted steps and ghost rows resolving the same listing
		-- would otherwise mint a ledger line per click
		local dup = false
		local key = a and (step.auctionID
			or (a.fp and ("fp:" .. a.fp)))
		if key and cancelLedger[key] then dup = true end
		if a and not dup and a.fp then
			local fpk = "fp:" .. a.fp
			local f = cancelLedger[fpk]
			local cap = math.max((f and f.cap) or 0, a.n or 1)
			if f and f.count >= cap then
				dup = true
			else
				cancelLedger[fpk] = { count = (f and f.count or 0) + 1,
					cap = cap, t = now }
			end
		end
		if a and not dup then
			if key then
				cancelLedger[key] = { count = 1, cap = 1, t = now }
			end
			-- suppress by fingerprint too — the owned list can rekey
			-- the listing on the next snapshot
			if a.fp then GM.Inventory.recentCancels[a.fp] = now end
			GM.Ledger.Add("cancel", a.itemID, a.qty, a.buyout,
				{ dep = a.dep, auctionID = step.auctionID,
					nm = a.name })
		end
		-- CancelAuction is PROTECTED on Forever — the call throws the
		-- client-side "Interface action failed" block, never reaches
		-- the server. Fire it anyway (some build may take it), then
		-- keep the step armed: the real completion is the listing
		-- vanishing from the owned snapshot — cancel it in the
		-- BLIZZARD UI auctions tab, the plan advances on the enum.
		local cancelFn = C_AuctionHouse.CancelAuction or CancelAuction
		if cancelFn then pcall(cancelFn, step.auctionID) end
		GM.Inventory.QueryOwned()
		GM.Print(GM.CC("warn") .. "cancel is protected here — cancel it "
			.. "in the BLIZZARD UI auctions tab; the plan advances when "
			.. "the listing clears|r")
		return false
	end
end

-- === Active scan — periodic book refresh while the AH is open ===
-- The intel layer (marks, wall history, suspects) is only as fresh
-- as the book; this keeps a scan cadence running during an AH
-- session the way the sniper's auto loop does, without needing the
-- sniper feed open. Cadence respects the server's ~15m replicate
-- throttle: a background feature doesn't get the browse fallback —
-- that's reserved for an explicit FULL SCAN click.
local AUTO_AGE = 300 -- refresh once the book is 5m stale
local autoAcc = 0
local autoF = CreateFrame("Frame")
autoF:SetScript("OnUpdate", function(_, dt)
	if not (GM.db and GM.db.autoscan and GM.AH.open) then
		autoAcc = 0
		return
	end
	autoAcc = autoAcc + dt
	if autoAcc < 20 then return end -- cheap 20s check cadence
	autoAcc = 0
	if GM.AH.Busy() then return end
	local lastOK = GM.db.lastReplicateOK or 0
	if GM.AH.BookAge() > AUTO_AGE
		and (lastOK == 0 or time() - lastOK >= 900) then
		GM.AH.FullScan()
	end
end)

function GM.AH.SetAutoScan(on)
	if not GM.db then return end
	GM.db.autoscan = on and true or false
end

function GM.AH.AutoScanOn()
	return GM.db and GM.db.autoscan and true or false
end

GM.Cmd({ "autoscan", "autosc" }, function(arg)
	local sub = (arg or ""):match("^%s*(%S*)") or ""
	if sub == "on" then GM.AH.SetAutoScan(true)
	elseif sub == "off" then GM.AH.SetAutoScan(false)
	else GM.AH.SetAutoScan(not GM.AH.AutoScanOn()) end
	GM.Print(format("auto-scan %s%s — book refreshes while the AH is open",
		GM.AH.AutoScanOn() and GM.CC("pos") .. "on" or GM.CC("textDim") .. "off",
		"|r"))
end, true)
