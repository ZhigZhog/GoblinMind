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
	-- PLAYER_MONEY is the money feed: delta = GetMoney change. The
	-- CHAT_MSG_MONEY parser it replaces never matched Blizzard's
	-- "2 Gold, 95 Silver" phrasing (it wanted 2g95s) so the gold
	-- stream stayed empty and rcbl never settled. The first event
	-- only seeds + snaps cash to truth — early reads can be 0.
	local mf = CreateFrame("Frame")
	pcall(mf.RegisterEvent, mf, "PLAYER_MONEY")
	local last, acc, flushing
	mf:SetScript("OnEvent", function()
		local now = GetMoney and GetMoney() or 0
		if last then
			acc = (acc or 0) + (now - last)
		else
			-- snap replayed cash to real gold once: every inflow
			-- the pre-feed history missed lands on ext
			GM.Ledger.Adjust("cash", now, "reconcile")
		end
		last = now
		-- deltas flush on a short fuse: a buy's money event can beat
		-- its purchase-confirm journal, and only the journal knows
		-- the spend was modeled. Coalescing the window lets
		-- pendingOut fill first regardless of event order
		if acc and acc ~= 0 and not flushing then
			flushing = true
			GM.Time.After(0.25, function()
				flushing = nil
				local d = acc or 0
				acc = 0
				if d ~= 0 then GM.Ledger.Gold(d, "money") end
			end)
		end
	end)
end

-- journal accounts — every transaction writes je = {acct → signed
-- delta} summing to zero, so a full replay reproduces balances:
--   cash   gold on hand          stock  inventory at cost in bags
--   posted AH escrow at cost     dep    listing deposits outstanding
--   rcbl   auction receivable — sold, proceeds not yet collected
--   pnl    realized trading P&L — CREDIT balance: negative = profit
--   ext    outside world (loot, vendors, mail, unseen gold flows)
--   wip    work in progress — mat cost held between craftout/craftin
local function Journal(kind, s, qty, unit, extra, depOut)
	-- extra.cost overrides the paidQ-average basis — callers that know
	-- the real basis (craftin = consumed-mat total, bidwon = the bid)
	-- pass it so the account legs carry the right copper
	local cost = (extra and extra.cost)
		or (s.paidQ and s.paidQ > 0
			and s.paidT / s.paidQ * qty or 0)
	local dep = extra and extra.dep or 0
	-- a release can't exceed the recorded escrow: a resolution whose
	-- post predates tracking returns a deposit the books never held.
	-- depRel is the on-books portion — the remainder rides pnl (an
	-- unbooked return is windfall, an unbooked loss can't be lost)
	local depRel = math.min(dep, depOut or dep)
	if kind == "buy" or kind == "vendorbuy" then
		local tot = qty * (unit or 0)
		return { cash = -tot, stock = tot }
	elseif kind == "trainer" then
		-- a learned recipe is a service, not stock — a realized
		-- expense with no basis to carry (pnl positive = loss)
		local tot = qty * (unit or 0)
		return { cash = -tot, pnl = tot }
	elseif kind == "post" then
		return { stock = -cost, posted = cost, cash = -dep, dep = dep }
	elseif kind == "sell" then
		-- a sale is unrealized income at verdict time: proceeds ride
		-- the mail until collected, so the debit lands on rcbl and
		-- settles to cash when gold actually arrives (Ledger.Gold)
		local net = qty * (unit or 0)
		return { rcbl = net + dep, posted = -cost, dep = -depRel,
			pnl = cost - net - dep + depRel }
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
	elseif kind == "tradeout" then
		-- items left via trade — same shape as mailout: the world
		-- holds the basis; whatever came back journals its own legs
		-- (items at zero basis, gold via the PLAYER_MONEY delta)
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
	elseif kind == "transfer" then
		-- envelope→envelope reallocation: no real money moves, so
		-- the legs ride named memo accounts that net to zero — the
		-- journal line is the bank statement entry (cr the sender,
		-- dr the receiver)
		local amt = qty or 0
		local from = extra and extra.from or "?"
		local to = extra and extra.to or "?"
		return { ["acct:" .. from] = -amt, ["acct:" .. to] = amt }
	elseif kind == "loot" or kind == "mail" or kind == "tradein" then
		-- unpaid inventory enters at the item's running-avg basis
		-- with the world (ext) supplying it — 0 for a never-bought
		-- item, so legs no-op exactly where no basis exists. paidQ
		-- stays untouched (no Gain): stock+posted − ΣpaidT then reads
		-- as the avg value of unpaid holdings, and exits at avg
		-- balance the entry instead of over-draining
		return { stock = cost, ext = -cost }
	elseif kind == "cancel" or kind == "expire" then
		return { posted = -cost, stock = cost, dep = -depRel,
			pnl = depRel }
	end
	-- unknown kinds journal no legs — provenance only
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

-- spends that journaled a cash leg expect a PLAYER_MONEY delta
-- within a few seconds; pendingOut pairs them so Gold doesn't
-- count them again. Session-local: a stale expectation that outlives
-- its window gets dropped rather than shadowing a real outflow.
local pendingOut = {}
local OUT_WINDOW = 30

local function ConsumeOutflow(amt)
	local i = 1
	while amt > 0 do
		local p = pendingOut[i]
		if not p then break end
		if time() - p.t > OUT_WINDOW then
			table.remove(pendingOut, i)
		elseif p.amt <= amt then
			amt = amt - p.amt
			table.remove(pendingOut, i)
		else
			p.amt = p.amt - amt
			amt = 0
		end
	end
	return amt
end

function GM.Ledger.Add(kind, itemID, qty, unit, extra)
	local L = GM.Ledger.db
	if not L then return end
	-- item-less kinds carry identity in extra: transfer is a
	-- copper-only line (from/to), trainer buys a service (nm).
	-- Everything else needs an item and a positive qty.
	if kind ~= "transfer" and not (extra and extra.nm)
		and (not itemID or not qty or qty <= 0) then return end
	local tx = L.transactions
	local s
	if itemID then
		s = L.itemStats[itemID]
		if not s then s = {} L.itemStats[itemID] = s end
	end
	-- extra.t backdates: mail-derived records carry the real event
	-- time (invoice daysLeft), not the detection time
	local t = extra and extra.t or time()
	-- dep-releasing kinds clamp against the recorded escrow — one
	-- replay per resolution, same order Gold() already spends per
	-- positive delta
	local depOut
	if kind == "sell" or kind == "cancel" or kind == "expire" then
		depOut = GM.Ledger.Accounts().dep or 0
	end
	local je = Journal(kind, s or {}, qty, unit, extra, depOut)
	tx[#tx + 1] = { t = t, ty = kind, i = itemID, q = qty, u = unit,
		x = extra, je = je }
	-- spends register their cash leg as a pending outflow so the
	-- PLAYER_MONEY delta doesn't journal it a second time — only
	-- unattributed outflows belong to the gold stream. extra.noOut
	-- skips it: paired-cost buys record AFTER their money already
	-- moved, so there's no delta left to expect
	if je and je.cash and je.cash < 0
		and not (extra and extra.noOut) then
		pendingOut[#pendingOut + 1] = { t = t, amt = -je.cash }
	end
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
	elseif kind == "tradein" then
		-- like mail-in: no cash basis — Consume on a later sell
		-- clamps against bought-basis only
		s.tradeInQ = (s.tradeInQ or 0) + qty
	elseif kind == "tradeout" then
		s.tradeOutQ = (s.tradeOutQ or 0) + qty
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
	-- envelope routing: proceeds credit the item's kind-preference
	-- purse, purchases debit it — bound group first, kind-matched
	-- otherwise. The journal is the ONLY spend writer so plan buys
	-- and hand buys can never diverge (the old B.Record call at
	-- step execution double-debited every planned vendor buy).
	if GM.Budget and GM.Budget.CreditTo then
		local flowTot = (extra and extra.cost) or qty * (unit or 0)
		if kind == "sell" then
			GM.Budget.CreditTo(itemID, flowTot, "ah")
		elseif kind == "vendor" then
			GM.Budget.CreditTo(itemID, flowTot, "vendor")
		elseif kind == "vendorbuy" or kind == "trainer" then
			GM.Budget.DebitTo(itemID, flowTot, "vendor")
		elseif kind == "buy" or kind == "bidwon" then
			GM.Budget.DebitTo(itemID, flowTot, "ah")
		elseif kind == "post" then
			local dep = extra and extra.dep or 0
			if dep > 0 then GM.Budget.DebitTo(itemID, dep, "ah") end
		end
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
	if kind == "transfer" then
		-- copper-only journal line — qty carries the amount
		return GM.Ledger.Add(kind, nil, tx.amt or tx.qty or 0,
			nil, tx)
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

-- every buy detection routes here: the money outflow is the ONLY
-- cost field that's always right (Forever drops merchant/buyback
-- prices on some items), so the next unattributed negative delta
-- within the window becomes the basis. unit is a provisional
-- fallback for buys whose delta never arrives (extended-cost
-- items, missed events). Expiry journals the row anyway —
-- detected with provisional cost beats invisible.
local pendingBuy = {}
local BUY_WINDOW = 15

function GM.Ledger.ExpectBuy(itemID, qty, unit, extra)
	-- item-less buys (trainer services) pass extra.nm + extra.kind
	if not ((itemID or (extra and extra.nm))
		and qty and qty > 0) then return end
	pendingBuy[#pendingBuy + 1] = { id = itemID, qty = qty,
		unit = unit, t = time(),
		kind = extra and extra.kind, nm = extra and extra.nm }
end

function GM.Ledger.Gold(delta, source)
	local L = GM.Ledger.db
	if not L then return end
	local g = L.gold
	local je
	if delta < 0 then
		-- modeled spends (buy/vendorbuy/post-dep/bid) already wrote
		-- their cash leg — consume the pending outflow; only the
		-- remainder is an outside-world spend (repair, taxi, trade)
		local un = ConsumeOutflow(-delta)
		if un > 0 and next(pendingBuy) then
			-- a detected buy whose cost the client wouldn't tell:
			-- the outflow IS its basis. FIFO — oldest pending first.
			local pb = pendingBuy[1]
			while pb and time() - pb.t > BUY_WINDOW do
				GM.Ledger.Add(pb.kind or "vendorbuy", pb.id, pb.qty,
					pb.unit, { noOut = true, nm = pb.nm })
				table.remove(pendingBuy, 1)
				pb = pendingBuy[1]
			end
			if pb then
				table.remove(pendingBuy, 1)
				-- fractional unit is fine: qty*unit lands on the
				-- delta exactly, no rounding drift in cash
				GM.Ledger.Add(pb.kind or "vendorbuy", pb.id, pb.qty,
					un / pb.qty, { noOut = true, nm = pb.nm })
				un = 0
			end
		end
		if un <= 0 then return end  -- fully attributed
		je = { cash = -un, ext = un }
	else
		je = { cash = delta, ext = -delta }
		-- settle outstanding auction receivables first: positive
		-- inflow is attributed to uncollected proceeds up to the rcbl
		-- balance, remainder stays untracked (ext). Aggregate, not
		-- per-sale — a bare money delta can't name its auction.
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

-- snap an account balance to ground truth: writes an adjustment
-- row with the diff on ext — the unseeable-history account. Repairs
-- pre-feed drift (cash snap on first money event) and keeps rcbl
-- honest against what the AH reports collectable.
function GM.Ledger.Adjust(acct, truth, src)
	local L = GM.Ledger.db
	if not L then return end
	local bal = GM.Ledger.Accounts()[acct] or 0
	local diff = truth - bal
	if diff == 0 then return end
	local g = L.gold
	g[#g + 1] = { t = time(), d = diff, src = src or "adjust",
		je = { [acct] = diff, ext = -diff } }
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

-- ============ expectation register ============
-- The item-movement twin of pendingBuy's cash pairing. Every Ops
-- verb registers the SECOND half of its transaction here before the
-- engine runs: a buy expects the goods to land in bags (via mail
-- collect), a post/mailout/vendor sell expects them to leave, a
-- cancel expects them back. Arrival/departure detectors consume
-- expectations FIFO; what never arrives is a stale expectation —
-- an audit finding, not silent drift. Journal legs still belong to
-- Record/Journal — this register verifies, it doesn't book.
local expects = {}
local EXPECT_WINDOW = 900   -- 15m covers buy→mail→collect
local EXPECT_CAP = 200

function GM.Ledger.Expect(ctx, txn)
	if not (ctx and ctx.id and txn and txn.dir
		and txn.qty and txn.qty > 0) then return end
	if #expects >= EXPECT_CAP then table.remove(expects, 1) end
	expects[#expects + 1] = {
		kind = txn.kind, id = ctx.id, qty = txn.qty,
		got = 0, dir = txn.dir, unit = txn.unit, t = time(),
	}
end

-- consume the oldest matching open expectation; returns the matched
-- row (its kind/qty/unit) or nil. qty is the observed movement.
local function Fulfill(id, qty, dir)
	for i, e in ipairs(expects) do
		if e.id == id and e.dir == dir then
			e.got = e.got + qty
			if e.got >= e.qty then
				table.remove(expects, i)
				return e
			end
			return e
		end
	end
end

function GM.Ledger.Arrived(itemID, qty)
	return itemID and qty and qty > 0
		and Fulfill(itemID, qty, "in")
end

function GM.Ledger.Departed(itemID, qty)
	return itemID and qty and qty > 0
		and Fulfill(itemID, qty, "out")
end

-- the engine refused or the staged flow died (drifted quote, no
-- quote at all): an expectation for a transaction that never ran
-- would sit open to stale — drop it explicitly
function GM.Ledger.Unexpect(itemID, kind)
	for i = #expects, 1, -1 do
		local e = expects[i]
		if e.id == itemID and (not kind or e.kind == kind) then
			table.remove(expects, i)
			return e
		end
	end
end

-- audit surface: open + stale expectation counts
function GM.Ledger.Expectations()
	local now, open, stale = time(), 0, 0
	for _, e in ipairs(expects) do
		if now - e.t <= EXPECT_WINDOW then open = open + 1
		else stale = stale + 1 end
	end
	return { open = open, stale = stale, n = #expects }
end

-- read-only window into the attribution queues for /goblin audit:
-- the sums and staleness the cash-drift check needs, without
-- exposing the queues themselves
function GM.Ledger.Pending()
	local now, out, staleBuy, staleOut = time(), 0, 0, 0
	for _, p in ipairs(pendingOut) do
		if now - p.t <= OUT_WINDOW then out = out + p.amt
		else staleOut = staleOut + 1 end
	end
	for _, pb in ipairs(pendingBuy) do
		if now - pb.t > BUY_WINDOW then staleBuy = staleBuy + 1 end
	end
	local exp = GM.Ledger.Expectations()
	return { out = out, outN = #pendingOut, outStale = staleOut,
		buys = #pendingBuy, buysStale = staleBuy,
		exp = exp.n, expStale = exp.stale }
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
