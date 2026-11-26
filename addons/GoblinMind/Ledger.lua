local _, GM = ...

-- GoblinMindLedger SV: append-only transaction ring + per-item aggregates.
-- Feeds the pricing sources avgbuy/avgsell/avgpaid (Pricing.lua).
-- avgpaid = running cost basis of stock on hand: buys add qty×unit,
-- sells drain at the current average (documented approximation — not
-- true FIFO lot tracking yet).

GM.Ledger = {}

local TX_CAP = 5000
local GOLD_CAP = 200

local CharKey = GM.CharKey

function GM.Ledger.Init()
	GoblinMindLedger = GoblinMindLedger or {}
	local L = GoblinMindLedger
	-- transactions + gold are per-character (keyed Name-Realm);
	-- itemStats stays account-global — market knowledge is shared
	L.byChar = L.byChar or {}
	L.itemStats = L.itemStats or {}
	local ck = CharKey()
	-- the key this session's live bucket was created under — bare
	-- ("Zhig") when Init runs before GetRealmName resolves, which on
	-- Forever can be the whole ADDON_LOADED window. MigrateKeys re-keys
	-- the bucket in place once the realm answers.
	GM.Ledger._ck = ck
	local c = L.byChar[ck]
	if not c then c = {} L.byChar[ck] = c end
	-- migrate legacy root-level data into this char's bucket
	if L.transactions then
		c.transactions = c.transactions or {}
		for _, e in ipairs(L.transactions) do
			tinsert(c.transactions, e)
		end
		L.transactions = nil
	end
	if L.gold then
		c.gold = c.gold or {}
		for _, e in ipairs(L.gold) do tinsert(c.gold, e) end
		L.gold = nil
	end
	c.transactions = c.transactions or {}
	c.gold = c.gold or {}
	-- mailSeen: fingerprints of auction-mail rows already ledgered —
	-- the invoice scan is the authoritative record for offline
	-- resolutions, and the set keeps re-scans idempotent
	c.mailSeen = c.mailSeen or {}
	-- facade: existing readers keep working, data is per-char underneath
	GM.Ledger.db = {
		transactions = c.transactions,
		itemStats = L.itemStats,
		gold = c.gold,
		mailSeen = c.mailSeen,
	}
end

-- journal accounts — every transaction writes je = {acct → signed
-- delta} summing to zero, so a full replay reproduces balances:
--   cash   gold on hand          stock  inventory at cost in bags
--   posted AH escrow at cost     dep    listing deposits outstanding
--   rcbl   auction receivable — sold, proceeds not yet collected
--   pnl    realized trading P&L — CREDIT balance: negative = profit
--   ext    outside world (loot, vendors, mail, unseen gold flows)
--   wip    work in progress — mat cost held between craftout/craftin
local function Journal(kind, s, qty, unit, extra)
	-- extra.cost overrides the paidQ-average basis — callers that know
	-- the real basis (craftin = consumed-mat total, bidwon = the bid)
	-- pass it so the account legs carry the right copper
	local cost = (extra and extra.cost)
		or (s.paidQ and s.paidQ > 0
			and s.paidT / s.paidQ * qty or 0)
	local dep = extra and extra.dep or 0
	if kind == "buy" or kind == "vendorbuy" then
		local tot = qty * (unit or 0)
		return { cash = -tot, stock = tot }
	elseif kind == "post" then
		return { stock = -cost, posted = cost, cash = -dep, dep = dep }
	elseif kind == "sell" then
		-- a sale is unrealized income at verdict time: proceeds ride
		-- the mail until collected, so the debit lands on rcbl and
		-- settles to cash when gold actually arrives (Ledger.Gold)
		local net = qty * (unit or 0)
		return { rcbl = net + dep, posted = -cost, dep = -dep,
			pnl = cost - net }
	elseif kind == "vendor" then
		-- vendor proceeds arrive as an unattributed money message —
		-- NO cash leg here: CHAT_MSG_MONEY's Gold(+net) credits cash
		-- and debits ext, settling this ext credit to zero. Missing
		-- the message leaves ext drifted (visible) rather than
		-- double-counted cash
		local net = qty * (unit or 0)
		return { stock = -cost, ext = net, pnl = cost - net }
	elseif kind == "destroy" then
		-- item written off — its cost basis is a realized loss
		return { stock = -cost, pnl = cost }
	elseif kind == "mailout" then
		-- items leave our accounts; the basis rides ext (the world
		-- now holds it) — matching mail-in on an alt can't correlate
		return { stock = -cost, ext = cost }
	elseif kind == "craftout" then
		-- mats consumed into the craft — basis parks in wip until
		-- the product lands (craftin pairs it the same tick)
		return { stock = -cost, wip = cost }
	elseif kind == "craftin" then
		-- product at consumed-mat cost (extra.cost) — the paid basis
		-- transfers so a later sale reports real profit
		return { wip = -cost, stock = cost }
	elseif kind == "bid" then
		-- bid escrow: cash out, nothing back yet — the win pairs it
		-- (bidwon: stock in, ext settles); a lost bid refunds via
		-- mail gold (ext settles through Gold's catch-all)
		local b = qty * (unit or 0)
		return { cash = -b, ext = b }
	elseif kind == "bidwon" then
		-- won item arrives — cost = the bid paid (extra.cost)
		return { stock = cost, ext = -cost }
	elseif kind == "loot" then
		-- provenance only: zero cost basis — a later sale reads as
		-- pure profit, which is what found value IS
		return {}
	elseif kind == "cancel" or kind == "expire" then
		return { posted = -cost, stock = cost, dep = -dep, pnl = dep }
	end
	-- mail items have no known cost — no money movement to balance
end

-- paid-basis helpers: Consume decrements the on-hand basis at its
-- running average (FIFO-ish), Gain adds a fresh lot
local function Consume(s, qty)
	if not (s.paidQ and s.paidQ > 0) then return end
	local avg = s.paidT / s.paidQ
	local d = math.min(qty, s.paidQ)
	s.paidQ = s.paidQ - d
	s.paidT = math.max(0, (s.paidT or 0) - d * avg)
end
local function Gain(s, qty, tot)
	s.paidQ = (s.paidQ or 0) + qty
	s.paidT = (s.paidT or 0) + tot
end

function GM.Ledger.Add(kind, itemID, qty, unit, extra)
	local L = GM.Ledger.db
	if not L or not itemID or not qty or qty <= 0 then return end
	local tx = L.transactions
	local s = L.itemStats[itemID]
	if not s then s = {} L.itemStats[itemID] = s end
	-- extra.t backdates: mail-derived records carry the real event
	-- time (invoice daysLeft), not the detection time
	local t = extra and extra.t or time()
	tx[#tx + 1] = { t = t, ty = kind, i = itemID, q = qty, u = unit,
		x = extra, je = Journal(kind, s, qty, unit, extra) }
	if #tx > TX_CAP then table.remove(tx, 1) end
	if kind == "buy" or kind == "bidwon" then
		-- bidwon counts in buy aggregates too: a won bid IS a purchase
		-- (unit may be nil on bidwon — extra.cost carries the total)
		local tot = extra and extra.cost or qty * (unit or 0)
		s.buyQ = (s.buyQ or 0) + qty
		s.buyT = (s.buyT or 0) + tot
		Gain(s, qty, tot)
		if unit then
			s.buyMin = math.min(s.buyMin or math.huge, unit)
			s.buyMax = math.max(s.buyMax or 0, unit)
		end
		s.lastBuy = t
	elseif kind == "vendorbuy" then
		-- vendor stock is a purchase but not a market trade — own
		-- counters keep buy aggregates market-only
		s.vendorBuyQ = (s.vendorBuyQ or 0) + qty
		s.vendorBuyT = (s.vendorBuyT or 0) + qty * (unit or 0)
		Gain(s, qty, qty * (unit or 0))
	elseif kind == "sell" then
		s.sellQ = (s.sellQ or 0) + qty
		s.sellT = (s.sellT or 0) + qty * (unit or 0)
		if unit then
			s.sellMin = math.min(s.sellMin or math.huge, unit)
			s.sellMax = math.max(s.sellMax or 0, unit)
		end
		s.lastSell = t
		Consume(s, qty)
	elseif kind == "vendor" then
		-- vendor sales are revenue but not market velocity — own
		-- counter keeps sellQ meaning "auctioned"
		s.vendorQ = (s.vendorQ or 0) + qty
		s.vendorT = (s.vendorT or 0) + qty * (unit or 0)
		Consume(s, qty)
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
	elseif kind == "mailout" then
		s.mailOutQ = (s.mailOutQ or 0) + qty
		Consume(s, qty)
	elseif kind == "destroy" then
		s.destroyQ = (s.destroyQ or 0) + qty
		Consume(s, qty)
	elseif kind == "craftout" then
		Consume(s, qty)
	elseif kind == "craftin" then
		s.craftQ = (s.craftQ or 0) + qty
		Gain(s, qty, extra and extra.cost or 0)
	elseif kind == "loot" then
		s.lootQ = (s.lootQ or 0) + qty
	elseif kind == "bid" then
		s.bidQ = (s.bidQ or 0) + qty
	end
	-- sell proceeds return to the matching budget envelope
	if kind == "sell" and GM.Budget and GM.Budget.CreditSale then
		GM.Budget.CreditSale(itemID, qty * (unit or 0))
	end
	-- resample wealth on stock txns — buys/posts change the held vs
	-- posted split at event resolution, not just the 5-min tick
	if GM.Budget and GM.Budget.Sample then GM.Budget.Sample() end
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

-- the single write path for every wealth-relevant movement. All
-- detectors call Record — Journal owns the account legs, so call
-- sites pass facts ({itemID, qty, unit, dep, cost, to, t, ...}),
-- never pre-computed deltas. kind == "gold" routes to the gold
-- stream; every other kind journals an item transaction.
function GM.Ledger.Record(kind, tx)
	tx = tx or {}
	if kind == "gold" then
		return GM.Ledger.Gold(tx.delta or tx.copper or tx.total or 0,
			tx.src or tx.source)
	end
	return GM.Ledger.Add(kind, tx.itemID or tx.id, tx.qty,
		tx.unit or tx.price or tx.each, tx)
end

-- cost basis of stock on hand (paidQ running average), copper/unit —
-- what the paid legs would move at right now. 0 when nothing's
-- journaled; callers use it for craft-cost transfer
function GM.Ledger.Basis(itemID)
	local s = GM.Ledger.db and GM.Ledger.db.itemStats[itemID]
	return s and s.paidQ and s.paidQ > 0 and s.paidT / s.paidQ or 0
end

function GM.Ledger.Gold(delta, source)
	local L = GM.Ledger.db
	if not L then return end
	local g = L.gold
	local je = { cash = delta, ext = -delta }
	if delta > 0 then
		-- settle outstanding auction receivables first: positive
		-- inflow is attributed to uncollected proceeds up to the rcbl
		-- balance, remainder stays untracked (ext). Aggregate, not
		-- per-sale — a bare money message can't name its auction.
		local owe = GM.Ledger.Accounts
			and (GM.Ledger.Accounts().rcbl or 0) or 0
		local x = math.min(delta, owe)
		if x > 0 then
			je = { cash = delta, rcbl = -x, ext = -(delta - x) }
		end
	end
	g[#g + 1] = { t = time(), d = delta, src = source, je = je }
	if #g > GOLD_CAP then table.remove(g, 1) end
end

-- replay the journal for one char: every tx's acct deltas summed
-- into balances. pnl reads as a credit account — negative = profit;
-- -pnl is lifetime realized P&L. ext's drift from zero is how much
-- the journal can't see (untracked gold flow).
function GM.Ledger.Accounts(charKey)
	local bal = { cash = 0, stock = 0, posted = 0, dep = 0,
		rcbl = 0, pnl = 0, ext = 0, wip = 0 }
	local c = GoblinMindLedger and GoblinMindLedger.byChar
		and GoblinMindLedger.byChar[charKey or GM.Ledger._ck]
	if not c then return bal end
	for _, list in ipairs({ c.transactions, c.gold }) do
		for _, e in ipairs(list or {}) do
			for a, d in pairs(e.je or {}) do
				bal[a] = (bal[a] or 0) + d
			end
		end
	end
	return bal
end

-- char-switcher surface for the ledger window: sorted char keys and
-- per-char transaction access (byChar is file-local)
function GM.Ledger.Chars()
	local out = {}
	for k in pairs(GoblinMindLedger and GoblinMindLedger.byChar or {}) do
		out[#out + 1] = k
	end
	sort(out)
	return out
end

function GM.Ledger.TxFor(charKey)
	local c = GoblinMindLedger and GoblinMindLedger.byChar
		and GoblinMindLedger.byChar[charKey]
	return c and c.transactions or {}
end

function GM.Ledger.CharKey()
	return CharKey()
end

-- merge src's txn/gold history into dst's arrays in place (the facade
-- holds references to the live bucket's tables), time-ordered, capped
local function MergeHist(dst, src)
	for _, f in ipairs({ "transactions", "gold" }) do
		local d = dst[f] or {}
		for _, e in ipairs(src[f] or {}) do d[#d + 1] = e end
		sort(d, function(x, y) return (x.t or 0) < (y.t or 0) end)
		local cap = f == "gold" and GOLD_CAP or TX_CAP
		while #d > cap do table.remove(d, 1) end
		dst[f] = d
	end
end

-- called by GM.MigrateCharKeys once GetRealmName answers: re-keys the
-- live bucket when it sits under a bare name from the empty-realm
-- window, then folds any other bare keys (older sessions' splits).
function GM.Ledger.MigrateKeys()
	local L = GoblinMindLedger
	if not (L and L.byChar) then return end
	local ck = GM.CharKeyQualified()
	if not ck then return end
	local oldCk = GM.Ledger._ck
	if oldCk and oldCk ~= ck and L.byChar[oldCk] then
		local live = L.byChar[oldCk]
		local prev = L.byChar[ck]
		if prev and prev ~= live then MergeHist(live, prev) end
		L.byChar[ck] = live
		L.byChar[oldCk] = nil
		GM.Ledger._ck = ck
	end
	GM.CanonicalizeCharKeys(L.byChar, function(a, b)
		if not b then return a end
		MergeHist(b, a)
		return b
	end)
end

function GM.Ledger.Recent(n)
	local tx = GM.Ledger.db and GM.Ledger.db.transactions or {}
	n = math.min(n or 10, #tx)
	local out = {}
	for i = #tx - n + 1, #tx do out[#out + 1] = tx[i] end
	return out
end
