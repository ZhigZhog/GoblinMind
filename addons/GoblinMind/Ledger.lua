local _, GM = ...

-- GoblinMindLedger SV: append-only transaction ring + per-item aggregates.
-- Feeds the pricing sources avgbuy/avgsell/avgpaid (Pricing.lua).
-- avgpaid = running cost basis of stock on hand: buys add qty×unit,
-- sells drain at the current average (documented approximation — not
-- true FIFO lot tracking yet).

GM.Ledger = {}

local TX_CAP = 5000
local GOLD_CAP = 200

function GM.Ledger.Init()
	GoblinMindLedger = GoblinMindLedger or {}
	local L = GoblinMindLedger
	L.transactions = L.transactions or {}
	L.itemStats = L.itemStats or {}
	L.gold = L.gold or {}
	GM.Ledger.db = L
end

function GM.Ledger.Add(kind, itemID, qty, unit, extra)
	local L = GM.Ledger.db
	if not L or not itemID or not qty or qty <= 0 then return end
	local tx = L.transactions
	tx[#tx + 1] = { t = time(), ty = kind, i = itemID, q = qty, u = unit, x = extra }
	if #tx > TX_CAP then table.remove(tx, 1) end
	local s = L.itemStats[itemID]
	if not s then s = {} L.itemStats[itemID] = s end
	local t = time()
	if kind == "buy" then
		local tot = qty * (unit or 0)
		s.buyQ = (s.buyQ or 0) + qty
		s.buyT = (s.buyT or 0) + tot
		s.paidQ = (s.paidQ or 0) + qty
		s.paidT = (s.paidT or 0) + tot
		if unit then
			s.buyMin = math.min(s.buyMin or math.huge, unit)
			s.buyMax = math.max(s.buyMax or 0, unit)
		end
		s.lastBuy = t
	elseif kind == "sell" then
		s.sellQ = (s.sellQ or 0) + qty
		s.sellT = (s.sellT or 0) + qty * (unit or 0)
		if unit then
			s.sellMin = math.min(s.sellMin or math.huge, unit)
			s.sellMax = math.max(s.sellMax or 0, unit)
		end
		s.lastSell = t
		if s.paidQ and s.paidQ > 0 then
			local avg = s.paidT / s.paidQ
			local d = math.min(qty, s.paidQ)
			s.paidQ = s.paidQ - d
			s.paidT = math.max(0, (s.paidT or 0) - d * avg)
		end
	elseif kind == "post" then
		s.postQ = (s.postQ or 0) + qty
		s.postT = (s.postT or 0) + qty * (unit or 0)
	elseif kind == "cancel" then
		s.cancelQ = (s.cancelQ or 0) + qty
	elseif kind == "expire" then
		s.expireQ = (s.expireQ or 0) + qty
		s.lastExpire = t
	elseif kind == "mail" then
		s.mailInQ = (s.mailInQ or 0) + qty
	end
end

-- per-item aggregate snapshot for the tooltip/accounting surface;
-- cancelled/expired counts are filtered to after the last sale the
-- way TSM's "since last sale" lines report them
function GM.Ledger.Stats(itemID)
	local s = GM.Ledger.db and GM.Ledger.db.itemStats[itemID]
	if not s then return nil end
	local cancelSinceSell, expireSinceSell = 0, 0
	local lastSell = s.lastSell or 0
	for _, tx in ipairs(GM.Ledger.db.transactions) do
		if tx.i == itemID and tx.t > lastSell then
			if tx.ty == "cancel" then cancelSinceSell = cancelSinceSell + 1
			elseif tx.ty == "expire" then expireSinceSell = expireSinceSell + 1 end
		end
	end
	return {
		buyQ = s.buyQ or 0, buyAvg = s.buyQ and s.buyQ > 0 and s.buyT / s.buyQ or nil,
		buyMin = s.buyMin ~= math.huge and s.buyMin or nil, buyMax = s.buyMax,
		lastBuy = s.lastBuy,
		sellQ = s.sellQ or 0, sellAvg = s.sellQ and s.sellQ > 0 and s.sellT / s.sellQ or nil,
		sellMin = s.sellMin ~= math.huge and s.sellMin or nil, sellMax = s.sellMax,
		lastSell = s.lastSell,
		cancelSinceSell = cancelSinceSell, expireSinceSell = expireSinceSell,
		saleRate = (s.sellQ or 0) > 0 and s.sellQ / math.max(1, (s.sellQ or 0) + (s.cancelQ or 0) + (s.expireQ or 0)) or nil,
	}
end

-- kind: "buy" (lifetime avg buy), "sell" (lifetime avg sell),
-- "paid" (avg cost of stock on hand), "minbuy" (alias of buy for now)
function GM.Ledger.Avg(itemID, kind)
	local s = GM.Ledger.db and GM.Ledger.db.itemStats[itemID]
	if not s then return nil end
	if kind == "buy" then
		return s.buyQ and s.buyQ > 0 and s.buyT / s.buyQ or nil
	elseif kind == "sell" then
		return s.sellQ and s.sellQ > 0 and s.sellT / s.sellQ or nil
	elseif kind == "paid" then
		return s.paidQ and s.paidQ > 0 and s.paidT / s.paidQ or nil
	elseif kind == "minbuy" then
		return GM.Ledger.Avg(itemID, "buy")
	end
end

function GM.Ledger.Gold(delta, source)
	local L = GM.Ledger.db
	if not L then return end
	local g = L.gold
	g[#g + 1] = { t = time(), d = delta, src = source }
	if #g > GOLD_CAP then table.remove(g, 1) end
end

function GM.Ledger.Recent(n)
	local tx = GM.Ledger.db and GM.Ledger.db.transactions or {}
	n = math.min(n or 10, #tx)
	local out = {}
	for i = #tx - n + 1, #tx do out[#out + 1] = tx[i] end
	return out
end
