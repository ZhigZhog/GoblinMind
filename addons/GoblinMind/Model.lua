local _, GM = ...

-- ================================================================
-- Model.lua — GM.Model, the single data front door. The view layer
-- reads and writes through this facade, never GM.db,
-- GoblinMindSettings/GoblinMindLedger, or a model's raw cache
-- directly: one place to audit what views depend on, one place to
-- change where a fact lives.
--
-- Every export is a thin delegate to the canonical model — the
-- models (AH/Inventory/Ledger/Budget/…) remain the real owners.
--
--   Item(id)        universal item row (mb/mkt/vel/… provenance-tagged)
--   Price(src, id)  pricing model value
--   ItemName(id)    display name
--   Gold()          current char's copper
--   Posted()        posted-auction value (cost basis)
--   Receivable()    unsettled sale proceeds
--   Mine()          owned-auction rows for the MINE view
--   Bids()          bid rows, outbid first
--   Wealth()        latest wealth sample {g, a, h, r, t}
--   WealthHist()    the wealth sample buffer
--   Chars()         registered alts {key → {name, class, faction, gold}}
--   CharKey()       this char's ledger key
--   Accounts(ck)    journal balances for a char
--   TxFor(ck)       transactions for a char
--   Pref(key)       view-facing settings read (GM.db[key])
--   SetPref(k, v)   view-facing settings write
--
--   Gate(name)      a commit-guard for snapshot writers — the
--                   complete-before-commit / sustain-before-empty /
--                   unknown≠zero contract as a reusable mechanism.
--                   See AGENTS.md for the contract text.
-- ================================================================

GM.Model = {}
local M = GM.Model

local T = GM.Time

-- ============ item / price ============

function M.Item(id)
	return GM.ItemEntry and GM.ItemEntry(id) or nil
end

function M.Price(src, id)
	return GM.Price and GM.Price(src, id) or nil
end

function M.ItemName(id)
	return GM.ItemName and GM.ItemName(id) or nil
end

-- ============ gold / wealth ============

function M.Gold()
	return GetMoney and GetMoney() or 0
end

function M.Posted()
	return GM.Inventory and GM.Inventory.PostedValue
		and GM.Inventory.PostedValue() or 0
end

function M.Receivable()
	local b = GM.Ledger and GM.Ledger.Accounts
		and GM.Ledger.Accounts() or nil
	return b and b.rcbl or 0
end

function M.Wealth()
	local w = GM.db and GM.db.wealthHist
	return w and w[#w] or nil
end

function M.WealthHist()
	return (GM.db and GM.db.wealthHist) or {}
end

-- ============ owned auctions ============

function M.Mine()
	return GM.Inventory and GM.Inventory.MineRows
		and GM.Inventory.MineRows() or {}
end

function M.Bids()
	return GM.Inventory and GM.Inventory.BidRows
		and GM.Inventory.BidRows() or {}
end

-- ============ chars / ledger ============

function M.Chars()
	return (GM.db and GM.db.chars) or {}
end

function M.CharKey()
	return GM.Ledger and GM.Ledger.CharKey and GM.Ledger.CharKey()
		or (GM.CharKeyQualified and GM.CharKeyQualified()) or nil
end

function M.Accounts(ck)
	return GM.Ledger and GM.Ledger.Accounts
		and GM.Ledger.Accounts(ck) or {}
end

function M.TxFor(ck)
	return GM.Ledger and GM.Ledger.TxFor
		and GM.Ledger.TxFor(ck) or {}
end

-- ============ view prefs ============
-- the door for view-owned settings (search history, filters,
-- autoscan flags, tooltip options). Pref returns the LIVE table
-- for list-valued keys so callers can tinsert/tremove in place;
-- scalar writes go through SetPref. Views must not name GM.db —
-- if a view needs a setting it doesn't have, that's a facade gap:
-- extend Model, don't reach around it.

-- Pref(key) reads; Pref(key, default) creates-and-stores the
-- default when the key is absent — the GM.db.x = GM.db.x or {}
-- idiom in one call. Table defaults are stored by reference, so
-- list-valued prefs mutate in place as before.
function M.Pref(key, default)
	if not GM.db then return default end
	if GM.db[key] == nil and default ~= nil then
		GM.db[key] = default
	end
	return GM.db[key]
end

function M.SetPref(key, value)
	if not GM.db then return end
	GM.db[key] = value
end

-- ============ snapshot commit-gate ============
-- One gate per snapshot writer. Commit() implements the contract
-- the owned-enum work established:
--   1. complete-before-commit — opts.complete == false refuses to
--      publish (partial delivery isn't state; retry next beat)
--   2. sustain-before-empty   — a nonempty→empty transition must
--      hold for opts.sustain seconds before it may publish
--   3. unknown≠zero           — callers pass complete=false while
--      the source hasn't delivered, rather than committing an
--      empty candidate
-- Returns the value to store: cand on publish, prev while held.

local gates = {}

function M.Gate(name)
	local g = gates[name]
	if not g then g = {} gates[name] = g end
	return g
end

local function IsEmpty(c)
	return c == nil or (type(c) == "table" and next(c) == nil)
end

function M.GateCommit(g, prev, cand, opts)
	opts = opts or {}
	if opts.complete == false then return prev end
	if not IsEmpty(prev) and IsEmpty(cand) then
		g.since = g.since or T.Now()
		if T.Since(g.since) < (opts.sustain or 15) then
			return prev
		end
	end
	g.since = nil
	return cand
end
