local _, GM = ...

-- Envelope budgeting: named accounts persisted in GoblinMindSettings.
-- "craft"/"ah" accounts hold a copper allocation that spending draws
-- down; "save" accounts reserve a % of current gold and are never
-- spendable. Free gold = gold − save reserves − unspent allocations.
-- Budget violations never block a step — ExecuteNext warns once per
-- step and a second click confirms the override.

GM.Budget = {}
local B = GM.Budget

B.KINDS = { craft = "CRAFT", ah = "AH", save = "SAVE",
	vendor = "VENDOR" }
B.KIND_ORDER = { "craft", "ah", "save", "vendor" }

local function DB()
	if not GM.db.budgets then GM.db.budgets = {} end
	return GM.db.budgets
end

-- char registry: GM.db.chars[charKey] = { n=name, cls=class token,
-- fac="Horde"/"Alliance", g=copper snapshot, t } — the gold half of
-- what inv[] snapshots do for bags/banks: every char's purse reads
-- back on one screen even though the money itself can't cross chars.
-- Books stay per-char (the AH is per-faction anyway); only the gold
-- side compiles.
local function Chars()
	if not GM.db.chars then GM.db.chars = {} end
	return GM.db.chars
end

-- same character iff the name parts match and neither key's realm
-- part disproves it — IsSelfCharKey's rule generalized to any pair,
-- since stored keys can be bare-name or Name-Realm
local function SameKey(a, b)
	if a == b then return true end
	if type(a) ~= "string" or type(b) ~= "string" then return false end
	local an, ar = a:match("^(.-)%-(.*)$")
	local bn, br = b:match("^(.-)%-(.*)$")
	if (an or a) ~= (bn or b) then return false end
	return not (ar and ar ~= "" and br and br ~= "") or ar == br
end

-- snapshot the current char into the registry; runs on every Sample
-- plus PLAYER_MONEY so the combined-gold strip stays live
-- class token from whatever the client hands back: stock
-- UnitClass returns (localized name, file token, id) but this
-- one can come back name-only — then reverse Blizzard's
-- localized-name tables ("Hunter" -> "HUNTER")
local function PlayerClassToken()
	local cname, cls = UnitClass and UnitClass("player")
	if cls then return cls end
	if not cname then return nil end
	for _, src in ipairs{LOCALIZED_CLASS_NAMES_MALE,
			LOCALIZED_CLASS_NAMES_FEMALE} do
		for tag, nm in pairs(src or {}) do
			if nm == cname then return tag end
		end
	end
	return nil
end

local function StampChar()
	if not GM.db then return end
	local ck = GM.CharKey()
	local name = UnitName and UnitName("player") or ck
	local cls = PlayerClassToken()
	local fac = UnitFactionGroup and UnitFactionGroup("player")
	local ch = Chars()[ck]
	if not ch then ch = {} Chars()[ck] = ch end
	ch.n = name and name ~= "" and name or ch.n
	ch.cls = cls or ch.cls
	ch.fac = fac or ch.fac
	ch.g = GetMoney and GetMoney() or 0
	ch.t = time()
end

-- the char an account belongs to; legacy rows without a stamp behave
-- as owned by whoever is looking (they get claimed at Init)
local function OwnerKey(a) return a.c or GM.CharKey() end
local function IsSelf(a) return GM.IsSelfCharKey(OwnerKey(a)) end
function B.OwnerKey(a) return OwnerKey(a) end

-- the owner's purse: live for this char, last snapshot for alts
local function OwnerGold(a)
	if IsSelf(a) then
		return GetMoney and GetMoney() or 0
	end
	local k = OwnerKey(a)
	for ck, ch in pairs(Chars()) do
		if SameKey(ck, k) then return ch.g or 0 end
	end
	return 0
end

-- registry entry for any spelling of a char key
function B.CharInfo(ck)
	for k, ch in pairs(Chars()) do
		if SameKey(k, ck) then return ch end
	end
	return nil
end

function B.CharName(ck)
	local n = ck and ck:match("^(.-)%-") or ck
	return n or "?"
end

-- faction crest as a fontstring texture escape — renders inline in
-- any SetText, no widget needed
function B.Crest(ck)
	local ch = B.CharInfo(ck)
	local fac = ch and ch.fac
	if fac ~= "Alliance" and fac ~= "Horde" then return "" end
	-- 18px, dropped 3 below baseline — the escape default sits the
	-- texture's bottom ON the baseline, which reads low next to
	-- x-height text; negative yofs centers it visually
	return "|TInterface\\TargetingFrame\\UI-PVP-" .. fac
		.. ":18:18:0:-3|t "
end

-- char colors: a per-char override (ch.col = "rrggbb"), else the
-- class color, else a stable palette hash for classless snapshots.
-- Settings exposes the pick; rows just ask CharCC/CharRGB.
local CHAR_PALETTE = {
	"ffd24a", "4ad2ff", "7be382", "c08cff", "ff9a5c",
	"ff7bd0", "4ae3c3", "ff6b6b", "7aa8ff", "c8e34a",
}
local function HexRGB(hex)
	return tonumber("0x" .. hex:sub(1, 2)) / 255,
		tonumber("0x" .. hex:sub(3, 4)) / 255,
		tonumber("0x" .. hex:sub(5, 6)) / 255
end

-- Blizzard's own class colors, carried for clients without
-- RAID_CLASS_COLORS in FrameXML
local CLASS_RGB = {
	WARRIOR = {0.78, 0.61, 0.43}, PALADIN = {0.96, 0.55, 0.73},
	HUNTER = {0.67, 0.83, 0.45}, ROGUE = {1.00, 0.96, 0.41},
	PRIEST = {1.00, 1.00, 1.00}, SHAMAN = {0.00, 0.44, 0.87},
	MAGE = {0.25, 0.78, 0.92}, WARLOCK = {0.53, 0.53, 0.93},
	DRUID = {1.00, 0.49, 0.04},
}

function B.CharRGB(ck)
	local ch = B.CharInfo(ck)
	local col = ch and ch.col
	if type(col) == "string" and col:match("^%x%x%x%x%x%x$") then
		return HexRGB(col)
	end
	local cc = ch and ch.cls and (RAID_CLASS_COLORS
		or CLASS_RGB)[ch.cls]
	if cc then
		return cc.r or cc[1], cc.g or cc[2], cc.b or cc[3]
	end
	local h = 5381
	for i = 1, #ck do h = (h * 33 + ck:byte(i)) % 16777216 end
	return HexRGB(CHAR_PALETTE[h % #CHAR_PALETTE + 1])
end

-- "|cffRRGGBB" for inline fontstring coloring
function B.CharCC(ck)
	local r, g, b = B.CharRGB(ck)
	return format("|cff%02x%02x%02x",
		floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- hex "rrggbb" = custom override, nil = back to class color
function B.SetCharColor(ck, hex)
	for k, ch in pairs(Chars()) do
		if SameKey(k, ck) then ch.col = hex end
	end
end

function B.CharColorMode(ck)
	local ch = B.CharInfo(ck)
	return ch and ch.col and "custom" or "class"
end

-- account display order: this char's accounts first, then alts by
-- name; returns indices into B.List() so row ops still hit the real
-- positions
function B.Order()
	local out = {}
	for i in ipairs(DB()) do out[#out + 1] = i end
	local function rank(i)
		local a = DB()[i]
		return IsSelf(a) and 0 or 1,
			B.CharName(OwnerKey(a)):lower(), i
	end
	sort(out, function(x, y)
		local xs, xn, xi = rank(x)
		local ys, yn, yi = rank(y)
		if xs ~= ys then return xs < ys end
		if xn ~= yn then return xn < yn end
		return xi < yi
	end)
	return out
end

-- every char key the registry knows, self first then by name —
-- drives the combined-gold legend
function B.CharsOrdered()
	local out = {}
	for ck in pairs(Chars()) do out[#out + 1] = ck end
	sort(out, function(a, b)
		local as = GM.IsSelfCharKey(a) and 0 or 1
		local bs = GM.IsSelfCharKey(b) and 0 or 1
		if as ~= bs then return as < bs end
		return B.CharName(a):lower() < B.CharName(b):lower()
	end)
	return out
end

-- "12g50s25c" / "12g 50s" / "1.5g" / "5000" (bare number = copper) →
-- copper or nil. Whitespace- and case-tolerant.
function B.ParseMoney(str)
	if not str then return nil end
	local s = str:lower():gsub("%s", "")
	if s == "" then return nil end
	local total, found = 0, false
	for num, unit in s:gmatch("([%d%.]+)([gsc])") do
		local v = tonumber(num)
		if not v then return nil end
		found = true
		total = total + v * (unit == "g" and 10000 or unit == "s" and 100 or 1)
	end
	if not found then
		local v = tonumber(s)
		if not v or v < 0 then return nil end
		return floor(v)
	end
	-- leftover characters that aren't part of a unit token → reject
	if s:gsub("[%d%.]+[gsc]", "") ~= "" then return nil end
	return floor(total)
end

function B.List() return DB() end

function B.Add(name, kind, alloc)
	if not (name and name ~= "" and B.KINDS[kind]) then return nil end
	-- c: owning char — envelopes are per-char purses even though the
	-- list is account-wide, so a spend can only draw its own char's
	-- allocation
	local a = { name = name, kind = kind, spent = 0, income = 0,
		c = GM.CharKey() }
	if kind == "save" then
		a.pct = math.max(0, math.min(100, floor(tonumber(alloc) or 0)))
	else
		a.alloc = math.max(0, floor(tonumber(alloc) or 0))
	end
	tinsert(DB(), a)
	B.Sample()
	return a
end

-- the pool is the char's purse itself — undeletable, unbindable,
-- un-rekindable. Data-level guards so no caller (row widgets
-- included) can violate the invariants.
function B.Del(i)
	local a = DB()[i]
	if a and not a.pool then tremove(DB(), i) end
end

-- rename keeps the account record (spent/income/group all survive) —
-- rejects empty names and dupes
function B.Rename(i, name)
	local a = DB()[i]
	name = type(name) == "string" and strtrim(name) or ""
	if not (a and name ~= "") then return nil end
	for j, o in ipairs(DB()) do
		if j ~= i and o.name == name then return nil end
	end
	a.name = name
	return a
end
function B.ResetSpent(i)
	local a = DB()[i]
	if a then a.spent, a.income, a.xfer = 0, 0, 0 B.Sample() end
end

function B.SetKind(i, kind)
	local a = DB()[i]
	if not (a and B.KINDS[kind]) or a.pool then return end
	a.kind = kind
	-- kind swap reinterprets the allocation field
	if kind == "save" and not a.pct then
		a.pct = 10
		a.alloc = nil
	elseif kind ~= "save" and not a.alloc then
		a.alloc = B.Alloc(a)
		a.pct = nil
	end
	B.Sample()
end

-- binds the account to a group path (reagents, ammo, …): spends and
-- sales of items in that group route here regardless of step kind
function B.SetGroup(i, path)
	local a = DB()[i]
	-- pools apply to every group by definition — no binding
	if a and not a.pool then a.group = (path ~= "" and path) or nil end
end

-- sorted list of assignable group paths for the function picker
function B.GroupPaths()
	local out = {}
	if GM.Groups and GM.Groups.db and GM.Groups.db.groups then
		for path in pairs(GM.Groups.db.groups) do tinsert(out, path) end
	end
	sort(out)
	return out
end

-- bank-model transfer: move copper between two envelopes on the
-- same char. xfer is a signed accumulator that shifts Remaining
-- without touching spent/income — a transfer is a move, not a
-- spend. The pool is the residual purse (gold minus every claimed
-- envelope) so it never carries a counter: the other side's shift
-- moves it automatically. The ledger journals the line — the
-- journal IS the bank statement.
function B.Transfer(fromI, toI, amt)
	local l = DB()
	local a, b = l[fromI], l[toI]
	amt = floor(tonumber(amt) or 0)
	if not (a and b) or a == b or amt <= 0 then return nil end
	-- envelopes are per-char purses — char→char gold moves by
	-- mail, which journals its own way (mailout/mailin)
	if not SameKey(OwnerKey(a), OwnerKey(b)) then return nil end
	if B.Remaining(a) < amt then return nil end  -- insufficient
	if not a.pool then a.xfer = (a.xfer or 0) - amt end
	if not b.pool then b.xfer = (b.xfer or 0) + amt end
	GM.Ledger.Record("transfer",
		{ from = a.name, to = b.name, amt = amt })
	B.Sample()
	return amt
end

-- transfer targets: every other account owned by the same char,
-- the pool included (transfers in/out of it are the deposit and
-- withdraw sides of the bank model)
function B.TransferTargets(i)
	local a = DB()[i]
	local out = {}
	if not a then return out end
	for j, o in ipairs(DB()) do
		if j ~= i and SameKey(OwnerKey(o), OwnerKey(a)) then
			tinsert(out, { i = j, a = o })
		end
	end
	return out
end

local function Gold() return GetMoney and GetMoney() or 0 end

-- effective reserve/allocation in copper right now
function B.Alloc(a)
	-- the base pool is every copper no other envelope claims — it
	-- reads live gold instead of a stored alloc so it never drifts.
	-- Multi-char: only the OWNER's accounts deduct — an alt's
	-- envelopes can't carve pieces out of this char's pool
	if a.pool then
		local g = OwnerGold(a)
		for _, o in ipairs(DB()) do
			if o ~= a and SameKey(OwnerKey(o), OwnerKey(a)) then
				g = g - B.Remaining(o)
			end
		end
		return math.max(0, g)
	end
	if a.pct then return floor(OwnerGold(a) * a.pct / 100) end
	return a.alloc or 0
end

-- signed balance: an overdrawn account goes negative — the deficit
-- is real data (spent exceeded alloc+income), not a display clamp.
function B.Balance(a)
	if a.pool or a.kind == "save" then
		return B.Alloc(a) + (a.xfer or 0)
	end
	return B.Alloc(a) + (a.income or 0)
		- (a.spent or 0) + (a.xfer or 0)
end

function B.Remaining(a)
	-- spendable never goes below zero: the pool residual and Free()
	-- math use the clamp, the row paints the signed Balance — an
	-- overdrawn account is debt already taken from the purse, not
	-- negative claim on it
	return math.max(0, B.Balance(a))
end

-- overdraw notice: a spend that takes a warn-enabled account below
-- zero announces each NEW low-water mark — repeat buys while
-- overdrawn don't spam, only deeper holes do. Session-local mark:
-- it resets on reload (Balance going back ≥0 clears it too).
local warnLow = {}
function B.WarnOverdrawn(a)
	if a.warn == false then return end
	local bal = B.Balance(a)
	if bal >= 0 then warnLow[a] = nil return end
	if warnLow[a] and bal >= warnLow[a] then return end
	warnLow[a] = bal
	GM.Print(GM.CC("warn") .. (a.name or "?") .. " over budget — "
		.. GM.Money(-bal) .. " over|r")
end

-- gold with no claim on it: minus save reserves, minus everything
-- still earmarked in spendable accounts — this char's purse only;
-- an alt's envelopes ride on the alt's snapshot gold
function B.Free()
	local free = Gold()
	for _, a in ipairs(DB()) do
		if IsSelf(a) then free = free - B.Remaining(a) end
	end
	return math.max(0, free)
end

local function StepTag(step)
	if step.btag and B.KINDS[step.btag] then return step.btag end
	if step.kind == "vendbuy" or step.kind == "buy" then return "ah" end
	return nil
end

-- the specific account a step/item draws on: a group-bound account
-- takes precedence over kind matching (an "ammo" envelope pays for
-- ammo whether the buy is at the AH or a vendor). Bound-path match
-- follows op-cascade semantics — an envelope bound to "Engineering"
-- covers "Engineering/Schematics". When several envelopes bind the
-- item's path, kind-matching wins first, then deepest path — so a
-- group can split its flows: an "ah" envelope for sales, a "vendor"
-- one for merchant moves, both bound to the same group.
local function BoundAccount(itemID, kind)
	if not (itemID and GM.Groups and GM.Groups.GroupForItem) then return end
	local path = GM.Groups.GroupForItem(itemID)
	if not path then return end
	local best, bestScore
	for _, a in ipairs(DB()) do
		local g = a.group
		if g and IsSelf(a)
			and (path == g or path:sub(1, #g + 1) == g .. "/") then
			-- kind match is worth more than any depth difference
			local score = ((not kind or a.kind == kind) and 1 or 0)
				* 100000 + #g
			if not bestScore or score > bestScore then
				best, bestScore = a, score
			end
		end
	end
	return best
end

local function StepAccount(step)
	-- kind preference for bound matching: a vendbuy step prefers a
	-- vendor envelope, a buy an AH one (the unbound tag maps both
	-- to "ah" — bound matching wants the flow's real home)
	local pref = (step.btag and B.KINDS[step.btag] and step.btag)
		or (step.kind == "vendbuy" and "vendor")
		or (step.kind == "buy" and "ah")
	return BoundAccount(step.itemID, pref)
end

local function MatchingAccounts(step)
	local bound = StepAccount(step)
	if bound then return { bound }, true end
	local tag = StepTag(step)
	local out = {}
	if tag then
		for _, a in ipairs(DB()) do
			if a.kind == tag and IsSelf(a) then tinsert(out, a) end
		end
	end
	-- nothing kind-matched: the base pool is the catch-all — every
	-- spend draws gold, so every spend may draw the pool down
	if #out == 0 then
		for _, a in ipairs(DB()) do
			if a.pool and IsSelf(a) then tinsert(out, a) end
		end
	end
	return out, false
end

-- over, spendable, deficit — over=false always when no budget accounts
-- exist, so the system stays silent until the player opts in
function B.Check(step, cost)
	if not cost or cost <= 0 then return false end
	if not next(DB()) then return false end
	local tag = StepTag(step)
	if not tag and not StepAccount(step) then return false end
	local matching = MatchingAccounts(step)
	local spendable = B.Free()
	for _, a in ipairs(matching) do
		spendable = spendable + B.Remaining(a)
	end
	if cost > spendable then
		return true, spendable, cost - spendable
	end
	return false, spendable, 0
end

-- draw the cost down against matching accounts in order
function B.Record(step, cost)
	if not cost or cost <= 0 then return end
	local matching = MatchingAccounts(step)
	if #matching == 0 then return end
	local owed = cost
	for _, a in ipairs(matching) do
		if a.kind ~= "save" and owed > 0 then
			local take = math.min(B.Remaining(a), owed)
			a.spent = (a.spent or 0) + take
			owed = owed - take
		end
	end
	-- overspend lands on the first matching account so the row shows
	-- the hole rather than silently dropping it
	if owed > 0 then
		for _, a in ipairs(matching) do
			if a.kind ~= "save" then
				a.spent = (a.spent or 0) + owed
				break
			end
		end
	end
	for _, a in ipairs(matching) do B.WarnOverdrawn(a) end
	B.Sample()
end

-- sale proceeds top the envelope back up (trading float): bound
-- account for the item's group, else the first AH account
function B.CreditSale(itemID, amount)
	if not amount or amount <= 0 then return end
	local target = BoundAccount(itemID, "ah")
	if not target then
		for _, a in ipairs(DB()) do
			if a.kind == "ah" and IsSelf(a) then target = a break end
		end
	end
	if target then
		target.income = (target.income or 0) + amount
		B.Sample()
	end
end

-- NPC-vendor envelope: vendor sales credit it, vendor buys draw it
-- down — separate from AH so flip margins don't pollute the
-- auction float. A group-bound account takes the item's flows
-- first (an "Ammo" envelope buys ammo, sells ammo); unbound falls
-- back to the first self-owned vendor account.
function B.CreditVendor(itemID, amount)
	if not amount or amount <= 0 then return end
	local target = BoundAccount(itemID, "vendor")
	if not target then
		for _, a in ipairs(DB()) do
			if a.kind == "vendor" and IsSelf(a) then target = a break end
		end
	end
	if target then
		target.income = (target.income or 0) + amount
		B.Sample()
	end
end
function B.DebitVendor(itemID, amount)
	if not amount or amount <= 0 then return end
	-- a bound account is the designated purse for this item's
	-- spends — the hole lands there even when it can't cover
	-- (save accounts never pay spends, same rule as B.Record)
	local bound = BoundAccount(itemID, "vendor")
	if bound and bound.kind ~= "save" then
		bound.spent = (bound.spent or 0) + amount
		B.WarnOverdrawn(bound)
		B.Sample()
		return
	end
	local owed = amount
	for _, a in ipairs(DB()) do
		if a.kind == "vendor" and IsSelf(a) and owed > 0 then
			local take = math.min(B.Remaining(a), owed)
			a.spent = (a.spent or 0) + take
			owed = owed - take
		end
	end
	-- overspend lands on the first vendor account — same rule as
	-- B.Record, the row shows the hole instead of dropping it
	if owed > 0 then
		for _, a in ipairs(DB()) do
			if a.kind == "vendor" and IsSelf(a) then
				a.spent = (a.spent or 0) + owed
				break
			end
		end
	end
	for _, a in ipairs(DB()) do
		if a.kind == "vendor" and IsSelf(a) then B.WarnOverdrawn(a) end
	end
	B.Sample()
end

-- trend sampling: remaining-balance history per account plus a
-- free-gold series — capped rolling buffers in the SV
local HIST_CAP = 200
function B.Sample()
	StampChar()
	-- every budget mutation funnels here — coalesce a repaint of the
	-- account surfaces so rows can't read stale between events (a
	-- buy's debit once painted "spent 0c" for a full minute because
	-- nothing re-ran the paint). Early returns below only gate the
	-- wealth-series append; the mutation already happened.
	if GM.View and GM.View.Coalesced then
		GM.View.Coalesced("accts", function()
			GM.View.Refresh("planner")
			GM.View.Refresh("overview")
		end)
	end
	local t = time()
	for _, a in ipairs(DB()) do
		a.hist = a.hist or {}
		local h = a.hist
		local n = #h
		-- collapse same-value adjacent samples so a flat week doesn't
		-- push real movement out of the window
		if n == 0 or h[n].v ~= B.Remaining(a) or t - h[n].t > 3600 then
			h[n + 1] = { t = t, v = B.Remaining(a),
				inc = a.income or 0, out = a.spent or 0 }
			if #h > HIST_CAP then tremove(h, 1) end
		end
	end
	local f = GM.db.budgetFree
	if not f then f = {} GM.db.budgetFree = f end
	local free = B.Free()
	if #f == 0 or f[#f].v ~= free or t - f[#f].t > 3600 then
		f[#f + 1] = { t = t, v = free }
		if #f > HIST_CAP then tremove(f, 1) end
	end
	-- wealth series for the account chart: real gold on hand + the
	-- posted-buyout snapshot, so the plot shows what you'd be worth
	-- if every listing sold at asking
	local w = GM.db.wealthHist
	if not w then w = {} GM.db.wealthHist = w end
	local gold = GetMoney and GetMoney() or 0
	local posted = GM.Inventory and GM.Inventory.PostedValue
		and GM.Inventory.PostedValue() or 0
	-- h: bought-stock-in-bags at cost — a buy moves gold into held
	-- inventory instead of cratering W (the chart's giant Xs)
	local held = GM.Inventory and GM.Inventory.HeldValue
		and GM.Inventory.HeldValue() or 0
	-- r: uncollected auction proceeds — at sale the posted term drops
	-- but gold hasn't arrived; without the receivable the line dips
	-- for the whole mail window then jumps back
	local rcbl = GM.Ledger and GM.Ledger.Accounts
		and (GM.Ledger.Accounts().rcbl or 0) or 0
	-- an all-zero sample is never information — it's a penniless alt
	-- writing into the shared SV or an init race where money and
	-- inventory haven't populated yet, and either way it draws as a
	-- giant fake dip on every char's wealth chart
	if gold + posted + held + rcbl == 0 then return end
	-- the init sample lands at ADDON_LOADED — before PLAYER_LOGIN's
	-- LoadOwned rehydrates the owned-auction snapshot — so it would
	-- write a=0/h=0 against real gold and dip every reload. "Not
	-- loaded yet" is unknown, not zero: skip until the load ran.
	if GM.Inventory.OwnedLoaded
		and not GM.Inventory.OwnedLoaded() then return end
	if #w == 0 or w[#w].g ~= gold or w[#w].a ~= posted
		or w[#w].h ~= held or (w[#w].r or 0) ~= rcbl
		or t - w[#w].t > 3600 then
		-- c: the sampler char — wealth is per-char by nature and
		-- untagged mixing drew alt logins as giant fake dips.
		-- CharKey() not Qualified: the realm stays empty on this
		-- client and a nil tag makes the chart filter toothless —
		-- IsSelfCharKey matches a bare name fine
		w[#w + 1] = { t = t, g = gold, a = posted, h = held,
			r = rcbl, c = GM.CharKey() }
		if #w > HIST_CAP then tremove(w, 1) end
	end
end

-- windowed income/spend: cumulative-counter delta since the sample
-- at or before `days` ago (earliest carrying fields when the buffer
-- is younger). A mid-window reset can only under-report; samples
-- that predate the inc/out fields yield nils so the UI shows "—"
-- rather than a padded number
function B.Flow(a, days)
	local h = a.hist
	if not h or #h == 0 then return nil, nil end
	local cutoff = time() - (days or 7) * 86400
	local base, oldest
	for _, p in ipairs(h) do
		if p.inc then
			oldest = oldest or p
			if p.t <= cutoff then base = p end
		end
	end
	base = base or oldest
	if not base then return nil, nil end
	return math.max(0, (a.income or 0) - base.inc),
	       math.max(0, (a.spent or 0) - base.out)
end

-- fold bare-name keys written in the empty-realm window into
-- Name-Realm form once the realm resolves — registry keys via the
-- canonicalizer, a.c owner stamps by the same rule
function B.MigrateKeys()
	if not GM.db then return end
	GM.CanonicalizeCharKeys(Chars(), function(a, b)
		if not a then return b end
		if not b then return a end
		return ((a.t or 0) >= (b.t or 0)) and a or b
	end)
	local realm = GetRealmName and GetRealmName() or ""
	if realm == "" then return end
	for _, a in ipairs(DB()) do
		if a.c and not a.c:find("-", 1, true) then
			a.c = a.c .. "-" .. realm
		end
	end
end

-- one-shot wealth-buffer repair: the enum-flap era left single-
-- sample excursions in the persisted series — a or g spiking for
-- ONE sample while the neighbors hold an identical vector. A real
-- wealth event can't make that shape: buys/sells/posts move two
-- fields at once, and single-field events (expires, loot) persist
-- into the next sample instead of snapping back. Interior samples
-- whose neighbors match each other on every field are deleted —
-- multi-sample flap runs need a few passes to collapse.
local function RepairWealthHist()
	local w = GM.db.wealthHist
	if not w or #w < 3 then return end
	local changed, passes = true, 0
	while changed and passes < 8 do
		changed = false
		passes = passes + 1
		local i = 2
		while i < #w do
			local p, n1, n2 = w[i], w[i - 1], w[i + 1]
			if (p.c or "") == (n1.c or "")
				and (n1.c or "") == (n2.c or "")
				and n1.g == n2.g and n1.a == n2.a and n1.h == n2.h
				and (p.g ~= n1.g or p.a ~= n1.a or p.h ~= n1.h) then
				tremove(w, i)
				changed = true
			else
				i = i + 1
			end
		end
	end
end

function B.Init()
	DB()
	RepairWealthHist()
	GM.db.acctColorMode = nil -- replaced by per-char ch.col
	local me = GM.CharKey()
	local myName = (UnitName and UnitName("player")) or me
	-- legacy accounts carry no owner — whoever loads first after the
	-- migration claims them; that char was the de-facto owner anyway
	-- since the envelope math always used the live purse
	for _, a in ipairs(DB()) do
		if not a.c then a.c = me end
	end
	-- "Base Pool" → the owner's name: the pool IS the char's purse,
	-- so the row reads "Zhig" not a feature label
	for _, a in ipairs(DB()) do
		if a.pool and IsSelf(a) and a.name == "Base Pool" then
			a.name = myName
		end
	end
	-- every char gets its own pool on first post-migration login —
	-- a live envelope over all unearmarked gold so the ledger's
	-- spend math has a home before the player creates budgets
	local hasPool = false
	for _, a in ipairs(DB()) do
		if a.pool and IsSelf(a) then hasPool = true break end
	end
	if not hasPool then
		tinsert(DB(), { name = myName, kind = "ah", pool = true,
			spent = 0, income = 0, c = me })
	end
	B.Sample()
	-- PLAYER_MONEY keeps the registry's gold cell live between
	-- samples — the combined strip reads it every repaint
	local mf = CreateFrame("Frame")
	pcall(mf.RegisterEvent, mf, "PLAYER_MONEY")
	mf:SetScript("OnEvent", function() StampChar() end)
	-- background sampler keeps the trend lines honest while idle
	local function tick()
		B.Sample()
		GM.Time.After(300, tick)
	end
	GM.Time.After(300, tick)
end

-- display helper: "5g" for budgets, "30%" for saves
function B.AllocText(a)
	if a.pool then return GM.Money(B.Alloc(a)) end
	if a.kind == "save" then return a.pct .. "%" end
	return GM.Money(a.alloc or 0)
end
