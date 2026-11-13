local _, GM = ...

-- Per-location inventory: bags/bank counted live; mail, guild bank, and
-- owned auctions cached from the last time their frame/API was reachable.
-- Feeds the numinventory price source and /goblin inv.

GM.Inventory = {}

local mailCache = {}      -- [itemID] = qty, refreshed at the mailbox
local guildCache = {}     -- [itemID] = qty, current gbank tab only
local auctionCache = {}   -- [auctionID] = {itemID, qty, buyout, tLeft, at}
local recentCancels = {}  -- [auctionID] = time()
local ownedPrimed = false -- first refresh just populates — everything
                          -- would look "new" otherwise
GM.Inventory.recentCancels = recentCancels

-- ============ mailbox ============

local function scanInbox()
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

function GM.Inventory.RefreshOwned()
	if not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions) then return end
	local ok, n = pcall(C_AuctionHouse.GetNumOwnedAuctions)
	if not ok or not n then return end
	local now = {}
	for i = 1, n do
		local ok2, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
		if ok2 and type(info) == "table" then
			local id = (info.itemKey and info.itemKey.itemID) or info.itemID
			local aid = info.auctionID or info.auctionId or i
			if id then
				now[aid] = {
					itemID = id,
					qty = info.quantity or 1,
					-- per-ITEM buyout (Forever convention — not lot total)
					buyout = info.buyoutAmount or info.bidAmount,
					tLeft = info.timeLeftSeconds,
					at = time(),
				}
			end
		end
	end
	local t = time()
	for aid, t0 in pairs(recentCancels) do
		if t - t0 > 300 then recentCancels[aid] = nil end
	end
	-- new auctionID = posted (any UI — TSM, Blizzard, or ours)
	for aid, cur in pairs(now) do
		if ownedPrimed and not auctionCache[aid] then
			GM.Ledger.Add("post", cur.itemID, cur.qty, cur.buyout)
		end
	end
	for aid, prev in pairs(auctionCache) do
		local couldExpire = prev.tLeft and (t - prev.at) >= prev.tLeft
		if ownedPrimed and not now[aid] and not recentCancels[aid] then
			if couldExpire then
				-- vanished on schedule without a cancel → expiry
				GM.Ledger.Add("expire", prev.itemID, prev.qty, nil, { auctionID = aid })
			else
				-- buyout is per-item on Forever — sale proceeds per
				-- unit are buyout minus the 5% AH cut
				local unit = prev.buyout and prev.qty > 0
					and math.floor(prev.buyout * 0.95) or nil
				GM.Ledger.Add("sell", prev.itemID, prev.qty, unit, { auctionID = aid })
			end
		end
	end
	auctionCache = now
	GM.Inventory.auctions = now
	ownedPrimed = true
	-- one-shot waiter for a fresh snapshot (cancel scan)
	local cb = GM.Inventory.onOwned
	GM.Inventory.onOwned = nil
	if cb then cb() end
end

function GM.Inventory.QueryOwned()
	if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
		pcall(C_AuctionHouse.QueryOwnedAuctions)
	end
end

-- ============ counts ============

function GM.Inventory.Count(itemID)
	local bags = GM.BagCount(itemID)
	local bank = GM.BankCount(itemID)
	local mail = mailCache[itemID] or 0
	local guild = guildCache[itemID] or 0
	local auction = 0
	for _, a in pairs(auctionCache) do
		if a.itemID == itemID then auction = auction + a.qty end
	end
	return {
		bags = bags, bank = bank, mail = mail, guild = guild,
		auction = auction, total = bags + bank + mail + guild + auction,
	}
end

-- Set of owned itemIDs across every location (ledger inventory page).
-- Bank slots only enumerate while the bank frame is open — same
-- constraint BankCount has; the set just lacks bank items otherwise.
function GM.Inventory.Owned()
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
end

-- ============ events ============

local f = CreateFrame("Frame")
for _, evt in ipairs({
	"MAIL_INBOX_UPDATE", "MAIL_SHOW",
	"OWNED_AUCTIONS_UPDATED", "AUCTION_HOUSE_SHOW",
	"GUILDBANKBAGSLOTS_CHANGED",
	"PLAYER_LOGIN",
}) do
	pcall(f.RegisterEvent, f, evt)
end
f:SetScript("OnEvent", function(_, event)
	if event == "MAIL_INBOX_UPDATE" or event == "MAIL_SHOW" then
		scanInbox()
	elseif event == "OWNED_AUCTIONS_UPDATED" then
		GM.Inventory.RefreshOwned()
	elseif event == "AUCTION_HOUSE_SHOW" or event == "PLAYER_LOGIN" then
		GM.Inventory.QueryOwned()
	elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
		scanGuildBank()
	end
end)
