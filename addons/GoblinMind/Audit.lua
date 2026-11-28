local _, GM = ...

-- /goblin audit — read-only invariant checks over the journal and
-- envelope state. Every detector change ships drift risk: a path
-- that moves money without a journal leg, legs that don't net to
-- zero, an envelope counter that disagrees with the journal's memo
-- legs. The audit converts that class into a printed verdict. The
-- report also stages into GoblinMindSettings.auditLog as
-- "aud-<ts>-<n>|<hex>" — the watcher regexes it out of the SV like
-- every other staged payload and writes the lines to brain.log.

local format = string.format

local AUDIT_CAP = 20

-- Settings.lua's HexEnc is a file-local; same copy convention as
-- Orders.lua — the watcher only needs \x -> %02x
local function hexenc(s)
	return (s:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

local checks = {}
local function check(name, fn)
	checks[#checks + 1] = { name = name, fn = fn }
end

-- every journal entry's legs net to zero — a nonzero sum is a
-- malformed Journal() shape leaking or conjuring copper
check("journal conservation", function()
	local bad, entries = 0, 0
	for _, c in pairs(GoblinMindLedger and GoblinMindLedger.byChar or {}) do
		for _, list in ipairs({ c.transactions, c.gold }) do
			for _, e in ipairs(list or {}) do
				entries = entries + 1
				local s = 0
				for _, d in pairs(e.je or {}) do s = s + d end
				if s > 0.5 or s < -0.5 then bad = bad + 1 end
			end
		end
	end
	if bad > 0 then
		return "fail", format("%d of %d entries don't net to zero",
			bad, entries)
	end
	return "ok", format("%d entries balanced", entries)
end)

-- replayed cash sits at purse minus the modeled outflows still
-- awaiting their PLAYER_MONEY delta — anything else is money that
-- moved without the journal seeing it
check("cash", function()
	local bal = GM.Ledger.Accounts()
	local pend = GM.Ledger.Pending and GM.Ledger.Pending()
		or { out = 0 }
	local gold = GetMoney()
	local expect = gold - (pend.out or 0)
	local drift = (bal.cash or 0) - expect
	if drift >= -1 and drift <= 1 then
		return "ok", format("%s on hand, %s pending",
			GM.Money(gold), GM.Money(pend.out or 0))
	end
	return "warn", format("journal %s vs expected %s — drift %s",
		GM.Money(bal.cash), GM.Money(expect), GM.Money(drift))
end)

-- escrow accounts are structurally non-negative: nothing can be
-- un-posted below zero, un-receivable below zero, or un-work below
-- zero. stock and cash get dedicated checks — zero-basis lots can
-- legitimately pull them down
check("escrow signs", function()
	local bal = GM.Ledger.Accounts()
	local neg = {}
	for _, a in ipairs({ "posted", "dep", "rcbl", "wip" }) do
		if (bal[a] or 0) < -0.5 then
			neg[#neg + 1] = a .. " " .. GM.Money(bal[a])
		end
	end
	if #neg > 0 then
		return "fail", table.concat(neg, ", ") .. " negative"
	end
	return "ok", "posted/dep/rcbl/wip all non-negative"
end)

-- stock+posted carries everything at running-avg basis; Σ paidT is
-- the paid-only basis of the same holdings. The gap is a quantity,
-- not a bug: unpaid inventory (looted/mailed/traded units enter
-- stock at avg with no paidQ) plus exit-attribution slop
check("stock basis", function()
	local bal = GM.Ledger.Accounts()
	local paid, items = 0, 0
	for _, s in pairs(GM.Ledger.db and GM.Ledger.db.itemStats or {}) do
		if (s.paidQ or 0) > 0 or (s.paidT or 0) > 0 then
			items = items + 1
			paid = paid + (s.paidT or 0)
		end
	end
	local carry = (bal.stock or 0) + (bal.posted or 0)
	local drift = carry - paid
	local tol = math.max(100, math.abs(paid) * 0.01)
	if math.abs(drift) <= tol then
		return "ok", format("%s carried across %d items",
			GM.Money(carry), items)
	end
	return "info", format(
		"carried %s vs paid %s — %s unpaid inventory at avg",
		GM.Money(carry), GM.Money(paid), GM.Money(drift))
end)

-- a transfer writes acct:<name> memo legs AND the envelope's signed
-- xfer counter — the two must agree per account, and the memo
-- accounts net to zero globally
check("envelope transfers", function()
	if not (GM.Budget and GM.Budget.List) then
		return "info", "no budget module"
	end
	local replay = GM.Ledger.Accounts()
	local sum, n = 0, 0
	local mismatched = {}
	for k, v in pairs(replay) do
		if k:sub(1, 5) == "acct:" then sum = sum + v end
	end
	for _, a in ipairs(GM.Budget.List()) do
		if not a.pool
			and GM.IsSelfCharKey(GM.Budget.OwnerKey(a)) then
			n = n + 1
			local rep = replay["acct:" .. (a.name or "?")] or 0
			if math.abs((a.xfer or 0) - rep) > 0.5 then
				mismatched[#mismatched + 1] = format(
					"%s(env %s·journal %s)", a.name or "?",
					GM.MoneyShort(a.xfer or 0),
					GM.MoneyShort(rep))
			end
		end
	end
	if #mismatched > 0 then
		return "fail", table.concat(mismatched, ", ")
			.. " xfer/journal mismatch"
	end
	if sum > 0.5 or sum < -0.5 then
		return "fail", format("acct legs net to %s, not zero",
			GM.Money(sum))
	end
	return "ok", format("%d envelopes consistent", n)
end)

-- paidQ and paidT move together: negative is corruption, and one
-- nonzero without the other means basis landed without quantity
check("paid basis", function()
	local neg, odd = 0, 0
	for _, s in pairs(GM.Ledger.db and GM.Ledger.db.itemStats or {}) do
		local q, t = s.paidQ or 0, s.paidT or 0
		if q < -0.01 or t < -0.01 then neg = neg + 1
		elseif (q > 0) ~= (t > 0.5) then odd = odd + 1 end
	end
	if neg > 0 then
		return "fail", format("%d items with negative paidQ/paidT", neg)
	end
	if odd > 0 then
		return "warn", format("%d items carry quantity without basis (or vice versa)", odd)
	end
	return "ok", "paidQ/paidT consistent"
end)

-- detected buys whose money delta never arrived sit past their
-- pairing window — they journal at provisional basis eventually,
-- but a pileup means the money feed misses real outflows
check("buy pairing", function()
	local p = GM.Ledger.Pending and GM.Ledger.Pending()
	if not p then return "info", "no pending accessor" end
	if p.buysStale > 0 then
		return "warn", format(
			"%d detected buy(s) never saw their money delta",
			p.buysStale)
	end
	return "ok", format("%d outflow(s), %d buy(s) in window",
		p.outN, p.buys)
end)

-- Ops verbs register the second half of every transaction as an
-- expectation — goods arriving (buy), goods leaving (post/mailout/
-- vend), goods returning (cancel). A stale expectation means the
-- engine ran but the world didn't follow: the buy's mail never got
-- collected, the post's stack never left bags.
check("op verification", function()
	local e = GM.Ledger.Expectations and GM.Ledger.Expectations()
	if not e then return "info", "no expectation register" end
	if e.stale > 0 then
		return "warn", format(
			"%d op expectation(s) unmet past their window", e.stale)
	end
	return "ok", format("%d open op(s)", e.open)
end)

-- clamped envelope claims vs the real purse: claims above gold are
-- allocation overcommit — legal (envelopes are claims, not vaults)
-- but worth seeing
check("envelope claims", function()
	if not (GM.Budget and GM.Budget.List) then
		return "info", "no budget module"
	end
	local claims, n = 0, 0
	for _, a in ipairs(GM.Budget.List()) do
		if GM.IsSelfCharKey(GM.Budget.OwnerKey(a)) then
			n = n + 1
			claims = claims + GM.Budget.Remaining(a)
		end
	end
	local gold = GetMoney()
	if claims > gold + 1 then
		return "info", format(
			"%s claimed across %d envelopes vs %s purse — overcommit",
			GM.Money(claims), n, GM.Money(gold))
	end
	return "ok", format("%s claimed of %s purse across %d envelopes",
		GM.Money(claims), GM.Money(gold), n)
end)

-- the spine is how every transaction gets requested: GM.Ctx for
-- reads, GM.Ops verbs for commits, engine accessors for the
-- questions views ask (book state, ledger rollups, zone value).
-- The check can't grep the view sources in-game, so it probes the
-- surface the views route through — a deleted accessor or dropped
-- CHECKS intent is the regression signature. Any answer that
-- isn't "unknown op" proves the intent is still registered.
check("spine coverage", function()
	local apis = {
		{ "AH", "FreshenBook" }, { "AH", "ShopState" },
		{ "AH", "PostShopRows" }, { "AH", "BookAsks" },
		{ "Ledger", "Flow" }, { "Ledger", "Cashflow" },
		{ "Gather", "ZoneValueNow" }, { "Intel", "Mark" },
		{ "Intel", "AnalyzeItem" }, { "Banking", "Execute" },
	}
	local verbs = { "Check", "Can", "Post", "Buy", "Bid",
		"Cancel", "Mail", "SendMail", "Vendor", "VendorBuy",
		"Destroy", "Move", "Collect" }
	local intentList = { "post", "buy", "bid", "cancel", "mail",
		"vendsell", "vendbuy", "destroy", "move", "collect",
		"sendmail" }
	local missing = {}
	for _, p in ipairs(apis) do
		local m = GM[p[1]]
		if not (m and type(m[p[2]]) == "function") then
			missing[#missing + 1] = "GM." .. p[1] .. "." .. p[2]
		end
	end
	if type(GM.Ctx) ~= "function" then
		missing[#missing + 1] = "GM.Ctx" end
	if type(GM.FarmValue) ~= "function" then
		missing[#missing + 1] = "GM.FarmValue" end
	local O = GM.Ops
	if not O then missing[#missing + 1] = "GM.Ops" end
	for _, v in ipairs(verbs) do
		if O and type(O[v]) ~= "function" then
			missing[#missing + 1] = "Ops." .. v end
	end
	local intents = 0
	local probe = GM.Ctx and GM.Ctx(2454) or nil
	if O and type(O.Check) == "function" then
		for _, it in ipairs(intentList) do
			local _, why = O.Check(probe, it, {})
			if why and why:match("^unknown op") then
				missing[#missing + 1] = "intent:" .. it
			else
				intents = intents + 1
			end
		end
	end
	if #missing > 0 then
		return "fail", "missing: " .. table.concat(missing, ", ")
	end
	return "ok", format("%d verbs, %d intents, ctx live",
		13, intents)
end)

local LV = {
	ok   = { c = "pos",     t = "ok"   },
	info = { c = "textDim", t = "info" },
	warn = { c = "warn",    t = "warn" },
	fail = { c = "err",     t = "FAIL" },
}

local function Run()
	local lines = { "goblin audit " .. date("%Y-%m-%d %H:%M:%S") }
	local rank = { ok = 0, info = 1, warn = 2, fail = 3 }
	local worst = "ok"
	for _, ch in ipairs(checks) do
		local good, lv, detail = pcall(ch.fn)
		if not good then lv, detail = "fail",
			"check error: " .. tostring(lv) end
		lv = LV[lv] and lv or "info"
		if rank[lv] > rank[worst] then worst = lv end
		local line = format("[%s] %s — %s", LV[lv].t, ch.name,
			detail or "")
		lines[#lines + 1] = line
		GM.Print(GM.CC(LV[lv].c) .. line .. "|r")
	end
	if GM.db then
		GM.db.auditLog = GM.db.auditLog or {}
		local id = format("aud-%d-%d", time(), math.random(100, 999))
		GM.db.auditLog[#GM.db.auditLog + 1] =
			id .. "|" .. hexenc(table.concat(lines, "\n"))
		while #GM.db.auditLog > AUDIT_CAP do
			table.remove(GM.db.auditLog, 1)
		end
	end
	GM.Print(GM.CC("accent") .. "audit " .. LV[worst].t
		.. "|r — staged for brain.log")
end

GM.Cmd("audit", function() Run() end,
	{ help = "run invariant checks over the ledger and envelopes" })
