local _, GM = ...

-- ============ action spine ============
-- EVERY transaction the mod performs is requested through GM.Ops —
-- the verb owns one validate→expect→execute pipeline so a button's
-- gray state and the commit share the same check, and the ledger's
-- expectation register turns each one-sided log into a verified
-- two-event transaction (buy→item lands, post→item leaves, COD→
-- gold returns). Views never call C_AuctionHouse/SendMail/merchant
-- APIs directly; the engines (AH.Execute, Banking.Execute,
-- Vendoring.Execute) stay the protected-call owners — Ops is the
-- dispatcher in front of them.
GM.Ops = GM.Ops or {}
local O = GM.Ops

local function fail(reason)
	GM.Print(GM.CC("warn") .. (reason or "can't do that") .. "|r")
	return false
end

-- ============ validate ============
-- ONE check per intent — Ops.Can (the button probe) and the verb's
-- own pre-flight run the same function, so a surface can't light up
-- on a rule the commit would fail.
local CHECKS = {
	post = function(ctx, a)
		if not GM.AH.open then return nil, "open the auction house first" end
		if (ctx.bags or 0) < 1 then
			return nil, "nothing in bags to post" end
		if not (a.unit and a.unit > 0) then
			return nil, "post needs a unit price" end
		return true
	end,
	buy = function(ctx, lot)
		if not GM.AH.open then return nil, "open the auction house first" end
		if not lot then return nil, "no lot" end
		if lot.commodity then return true end
		if not (lot.auctionID or lot.aid or lot.id) then
			return nil, "missing auction id — rescan first" end
		return true
	end,
	bid = function(ctx, lot)
		if not GM.AH.open then return nil, "open the auction house first" end
		if not lot then return nil, "no lot" end
		if not (lot.auctionID or lot.aid) then
			return nil, "missing auction id — rescan first" end
		if not (lot.total and lot.total > 0) then
			return nil, "bid needs an amount" end
		if GetMoney and (GetMoney() or 0) < lot.total then
			return nil, "not enough gold" end
		return true
	end,
	cancel = function(ctx, lot)
		if not GM.AH.open then return nil, "open the auction house first" end
		if not (lot and (lot.auctionID or lot.aid)) then
			return nil, "missing auction id" end
		return true
	end,
	mail = function(ctx, a)
		if not (a and a.to and a.to ~= "") then
			return nil, "mail needs a recipient" end
		if (ctx.bags or 0) < (a.qty or 1) then
			return nil, "not enough in bags" end
		return true
	end,
	vendsell = function(ctx, a)
		if (ctx.bags or 0) < 1 then
			return nil, "nothing in bags to sell" end
		return true
	end,
	vendbuy = function(ctx, a)
		if not (a and (a.index or a.itemID or ctx.id)) then
			return nil, "no merchant slot" end
		return true
	end,
	destroy = function(ctx, a)
		if (ctx.bags or 0) < (a and a.qty or 1) then
			return nil, "nothing in bags to destroy" end
		return true
	end,
	move = function(ctx, a)
		-- bank/gbank↔bags warehousing — the source scope must hold
		-- the qty; gbank legs also need the frame open and the tab
		-- perms the executor will re-check at the click
		local from = (a and a.from) or "bags"
		local to = (a and a.to)
			or (from == "bags" and "bank" or "bags")
		local have = from == "bank" and (ctx.bank or 0)
			or from == "gbank" and (ctx.gbank or 0)
			or (ctx.bags or 0)
		if have < (a and a.qty or 1) then
			return nil, "nothing in " .. from .. " to move"
		end
		if from == "gbank" or to == "gbank" then
			if not (GuildBankFrame and GuildBankFrame:IsShown()) then
				return nil, "guild bank is closed"
			end
			local tab = (a and a.tab)
				or (GetCurrentGuildBankTab and GetCurrentGuildBankTab())
			if GetGuildBankTabPermissions and tab then
				local _, canDep, canWd, wdLeft =
					GetGuildBankTabPermissions(tab)
				if to == "gbank" and canDep == false then
					return nil, "no deposit permission on this tab"
				end
				if from == "gbank" and canWd == false then
					return nil, "no withdraw permission on this tab"
				end
				if from == "gbank" and wdLeft ~= nil and wdLeft <= 0 then
					return nil, "daily withdrawal limit reached"
				end
			end
		end
		return true
	end,
	collect = function(ctx, a)
		if not (MailFrame and MailFrame:IsShown()) then
			return nil, "mailbox is closed" end
		return true
	end,
	-- compose-send: recipient + a payload — attached item(s), or
	-- bare money. COD refuses empty hands. Attachments live in the
	-- mailbox's send slots, so the probe reads the frame state
	-- rather than an arg
	sendmail = function(ctx, a)
		if not (MailFrame and MailFrame:IsShown()) then
			return nil, "mailbox is closed" end
		if not (a and a.to and a.to ~= "") then
			return nil, "mail needs a recipient" end
		local attached = 0
		if GetSendMailItem then
			for i = 1, 12 do
				local n1, n2 = GetSendMailItem(i)
				if n1 or tonumber(n2) then
					attached = attached + 1 end
			end
		end
		if attached == 0 then
			if (a.cod or 0) > 0 then
				return nil, "COD needs an item attached" end
			if not (a.money and a.money > 0) then
				return nil, "nothing to send" end
		end
		return true
	end,
}

-- intents that probe frame/compose state, not item state — a nil
-- ctx still gets a real answer (O.Can(nil, "sendmail", a) for the
-- SEND button's gray state)
local NOCTX = { sendmail = true, collect = true }
local EMPTY = {}

-- normalize once: callers may pass a ctx, a row, or a bare id
local function AsCtx(v)
	return (type(v) == "table" and v.id and v.bookKey ~= nil) and v
		or GM.Ctx(v)
end

-- dry-run for UI state AND the verb's pre-flight — one validator
function O.Check(ctx, intent, a)
	ctx = AsCtx(ctx) or (NOCTX[intent] and EMPTY)
	if not ctx then return nil, "no item" end
	local f = CHECKS[intent]
	if not f then return nil, "unknown op " .. tostring(intent) end
	return f(ctx, a or {})
end

function O.Can(ctx, intent, a)
	return (O.Check(ctx, intent, a))
end

-- ============ verbs ============
-- Each builds the same step the planner emits and hands it to the
-- engine that already owns the protected call. Expectations ride
-- alongside — the journal rows the engines write close when the
-- arrival detector sees the goods move.

-- post a stack (or the whole ctx.bags when qty omitted)
function O.Post(ctx, a)
	ctx = AsCtx(ctx)
	a = a or {}
	local ok, reason = O.Check(ctx, "post", a)
	if not ok then return fail(reason) end
	local qty = a.qty or ctx.bags
	if GM.Ledger and GM.Ledger.Expect then
		-- posting moves the stack out of bags — verify the departure
		GM.Ledger.Expect(ctx, { kind = "post", qty = qty,
			dir = "out", unit = a.unit })
	end
	local r = GM.AH.Execute({ kind = "post", itemID = ctx.id,
		item = ctx.link, name = ctx.name,
		qty = qty, unit = a.unit, bid = a.bid,
		duration = a.dur or a.duration })
	-- refused outright → no transaction, no expectation
	if r == false and GM.Ledger and GM.Ledger.Unexpect then
		GM.Ledger.Unexpect(ctx.id, "post") end
	return r
end

-- buyout a lot (non-commodity: lot.auctionID; commodity:
-- lot.commodity + lot.unit expected-price)
function O.Buy(ctx, lot)
	ctx = AsCtx(ctx)
	local ok, reason = O.Check(ctx, "buy", lot)
	if not ok then return fail(reason) end
	local qty = lot.qty or 1
	if GM.Ledger and GM.Ledger.Expect then
		-- the goods arrive via mail — an uncollected expectation is
		-- an audit finding, not silent drift
		GM.Ledger.Expect(ctx, { kind = "buy", qty = qty,
			dir = "in", unit = lot.unit or lot.price })
	end
	local r = GM.AH.Execute(lot.commodity
		and { kind = "buy", commodity = true,
			itemID = ctx.id, qty = qty, unit = lot.unit }
		or { kind = "buy", itemID = ctx.id,
			qty = qty, unit = lot.unit or lot.price,
			total = lot.total,
			auctionID = lot.auctionID or lot.aid or lot.id })
	if r == false and GM.Ledger and GM.Ledger.Unexpect then
		GM.Ledger.Unexpect(ctx.id, "buy") end
	return r
end

-- real bid (escrow, not buyout) — lot.total is the bid amount
function O.Bid(ctx, lot)
	ctx = AsCtx(ctx)
	local ok, reason = O.Check(ctx, "bid", lot)
	if not ok then return fail(reason) end
	return GM.AH.Execute({ kind = "bid", itemID = ctx.id,
		qty = lot.qty or 1, total = lot.total,
		auctionID = lot.auctionID or lot.aid })
end

-- cancel one of our listings — the engine journals cancel and the
-- item returns by mail (the enum owns detecting that)
function O.Cancel(ctx, lot)
	ctx = AsCtx(ctx)
	local ok, reason = O.Check(ctx, "cancel", lot)
	if not ok then return fail(reason) end
	if GM.Ledger and GM.Ledger.Expect and lot.qty then
		GM.Ledger.Expect(ctx, { kind = "cancel", qty = lot.qty,
			dir = "in" })
	end
	local r = GM.AH.Execute({ kind = "cancel",
		auctionID = lot.auctionID or lot.aid })
	if r == false and GM.Ledger and GM.Ledger.Unexpect then
		GM.Ledger.Unexpect(ctx.id, "cancel") end
	return r
end

-- mail items — one Execute tick attaches + sends; multi-stack sends
-- still belong to the planner (it re-ticks until the step completes)
function O.Mail(ctx, a)
	ctx = AsCtx(ctx)
	local ok, reason = O.Check(ctx, "mail", a)
	if not ok then return fail(reason) end
	local ekind = (a.cod and a.cod > 0) and "codout" or "mailout"
	if GM.Ledger and GM.Ledger.Expect then
		GM.Ledger.Expect(ctx, { kind = ekind,
			qty = a.qty or 1, dir = "out" })
	end
	local r = GM.Banking.Execute({ kind = "mail", itemID = ctx.id,
		qty = a.qty or 1, to = a.to, cod = a.cod })
	if r == nil and GM.Ledger and GM.Ledger.Unexpect then
		GM.Ledger.Unexpect(ctx.id, ekind) end
	return r
end

-- compose-send — the mail window's SEND button: attachments already
-- sit in send slots (possibly several item types), letter fields and
-- a COD/gold amount ride the one request. Expectations register per
-- attached item so the bag diff verifies the send exactly like a
-- planner mail; a send that never happens unexpects them all.
function O.SendMail(a)
	a = a or {}
	-- Forever requires the surname for delivery — resolve the
	-- "First" form into "First Last" before anything stages
	if GM.FullName and a.to then a.to = GM.FullName(a.to) end
	local ok, reason = O.Check(nil, "sendmail", a)
	if not ok then return fail(reason) end
	local items = {}
	if GetSendMailItem then
		for i = 1, 12 do
			local ret = { GetSendMailItem(i) }
			local id = tonumber(ret[2])
			if ret[1] or id then
				items[#items + 1] = { id = id,
					qty = tonumber(ret[#ret]) or 1 }
			end
		end
	end
	local ekind = (a.cod and a.cod > 0) and "codout" or "mailout"
	if GM.Ledger and GM.Ledger.Expect then
		for _, it in ipairs(items) do
			if it.id then
				GM.Ledger.Expect({ id = it.id }, { kind = ekind,
					qty = it.qty, dir = "out" })
			end
		end
	end
	local r = GM.Banking.Execute({ kind = "mailsend", to = a.to,
		subject = a.subject, body = a.body,
		cod = a.cod, money = a.money })
	if r == nil and GM.Ledger and GM.Ledger.Unexpect then
		for _, it in ipairs(items) do
			if it.id then GM.Ledger.Unexpect(it.id, ekind) end
		end
	end
	return r ~= nil and r ~= false
end

-- sell to the open merchant
function O.Vendor(ctx, a)
	ctx = AsCtx(ctx)
	a = a or {}
	local ok, reason = O.Check(ctx, "vendsell", a)
	if not ok then return fail(reason) end
	if GM.Ledger and GM.Ledger.Expect then
		GM.Ledger.Expect(ctx, { kind = "vendsell",
			qty = a.qty or 1, dir = "out" })
	end
	local r = GM.Vendoring.Execute({ kind = "vendsell",
		itemID = ctx.id, qty = a.qty or 1 })
	if (r == false or r == nil)
			and GM.Ledger and GM.Ledger.Unexpect then
		GM.Ledger.Unexpect(ctx.id, "vendsell") end
	return r
end

-- destroy-value sell (max of vendor/DE/auction floor) — one unit per
-- Execute tick; the planner re-ticks for multi-unit destroys
function O.Destroy(ctx, a)
	ctx = AsCtx(ctx)
	a = a or {}
	local ok, reason = O.Check(ctx, "destroy", a)
	if not ok then return fail(reason) end
	if GM.Ledger and GM.Ledger.Expect then
		GM.Ledger.Expect(ctx, { kind = "destroy",
			qty = a.qty or 1, dir = "out" })
	end
	local r = GM.Destroying and GM.Destroying.Execute
		and GM.Destroying.Execute({ kind = "destroy",
			itemID = ctx.id, qty = a.qty or 1, name = ctx.name })
	if (r == false or r == nil)
			and GM.Ledger and GM.Ledger.Unexpect then
		GM.Ledger.Unexpect(ctx.id, "destroy") end
	return r
end

-- bank/gbank↔bags move — the warehousing verb. Direction lives on
-- the step, not the verb: from="bank"|"gbank" deposits-to-bags,
-- from="bags" carries out; the expectation watches the BAG side
-- either way. a.tab + a.gslot / a.srcBag+srcSlot pin the gbank tab
-- and the clicked stack when the caller is a gbank row
function O.Move(ctx, a)
	ctx = AsCtx(ctx)
	a = a or {}
	local ok, reason = O.Check(ctx, "move", a)
	if not ok then return fail(reason) end
	local from = a.from or "bags"
	local toBags = from == "bank" or from == "gbank"
	local to = a.to or (toBags and "bags" or "bank")
	if GM.Ledger and GM.Ledger.Expect then
		GM.Ledger.Expect(ctx, { kind = "move",
			qty = a.qty or 1, dir = toBags and "in" or "out" })
	end
	local r, why = GM.Banking.Execute({ kind =
			(from == "gbank" or to == "gbank") and "gmove" or "move",
		itemID = ctx.id, qty = a.qty or 1,
		from = from, to = to, tab = a.tab,
		gslot = a.gslot, srcBag = a.srcBag, srcSlot = a.srcSlot })
	if r == nil or r == "bounce" then
		-- a bounced interactive click is silent otherwise (bounce is
		-- the plan-queue's rotate signal) — say why
		if r == "bounce" and why then
			GM.Print(GM.CC("warn") .. "[bank] " .. tostring(why) .. "|r")
		end
		if GM.Ledger and GM.Ledger.Unexpect then
			GM.Ledger.Unexpect(ctx.id, "move") end
	end
	return r
end

-- collect this item's inbox mail — the fetch leg of buy→mailbox→
-- bags. bagBase bakes now so a partial collect still verifies
function O.Collect(ctx, a)
	ctx = AsCtx(ctx)
	a = a or {}
	local ok, reason = O.Check(ctx, "collect", a)
	if not ok then return fail(reason) end
	if GM.Ledger and GM.Ledger.Expect then
		GM.Ledger.Expect(ctx, { kind = "mailin",
			qty = a.qty or ctx.mail or 1, dir = "in" })
	end
	local r = GM.Banking.Execute({ kind = "mailcollect",
		itemID = ctx.id, qty = a.qty or ctx.mail or 1,
		bagBase = ctx.bags })
	if r == nil and GM.Ledger and GM.Ledger.Unexpect then
		GM.Ledger.Unexpect(ctx.id, "mailin") end
	return r
end

-- buy from the open merchant — MerchantBuy journals via ExpectBuy
function O.VendorBuy(ctx, a)
	ctx = AsCtx(ctx)
	a = a or {}
	local ok, reason = O.Check(ctx, "vendbuy", a)
	if not ok then return fail(reason) end
	GM.MerchantBuy(a.index or a.slot, a.qty or 1)
	return true
end
