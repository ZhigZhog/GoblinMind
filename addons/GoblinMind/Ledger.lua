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
	if kind == "buy" then
		local tot = qty * (unit or 0)
		s.buyQ = (s.buyQ or 0) + qty
		s.buyT = (s.buyT or 0) + tot
		s.paidQ = (s.paidQ or 0) + qty
		s.paidT = (s.paidT or 0) + tot
	elseif kind == "sell" then
		s.sellQ = (s.sellQ or 0) + qty
		s.sellT = (s.sellT or 0) + qty * (unit or 0)
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
	elseif kind == "mail" then
		s.mailInQ = (s.mailInQ or 0) + qty
	end
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
