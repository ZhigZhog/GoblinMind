-- ================================================================
-- Intel.lua — INTERNAL BUILD ONLY: solver/manipulation detection.
-- Marks book rows that look algorithmically posted (step-chain
-- undercuts, bait lots, seller walls) and accumulates a persistent
-- suspect table on sellers. Loads before Sniper.lua so marks land
-- on the shared row objects before any consumer diffs them.
-- ================================================================

local GM = GoblinMind
local I = {}
GM.Intel = I

I.marks = {}    -- itemID -> { bait=?, steps=?, walls={seller=n} }
I.suspects = nil -- seller -> { score, last } (persisted in SV)

local STEP_GAP = 1       -- copper between adjacent asks in a chain
local STEP_MIN = 3       -- chain length that reads as algorithmic
local BAIT_DROP = 0.60   -- cheapest ask <= 60% of next = sniper bait
local WALL_MIN = 4       -- same-seller listings on one item = a wall
local SUSPECT_AT = 4     -- score that marks a seller as a solver

local function Suspects()
	GoblinMindHistory = GoblinMindHistory or {}
	GoblinMindHistory.suspects = GoblinMindHistory.suspects or {}
	I.suspects = GoblinMindHistory.suspects
	return I.suspects
end

local function Bump(seller, pts)
	if not seller or seller == "" then return end
	local s = Suspects()
	local e = s[seller]
	if not e then e = { score = 0 } s[seller] = e end
	e.score = e.score + pts
	e.last = time()
end

function I.Score(seller)
	local e = I.suspects and seller and I.suspects[seller]
	return e and e.score or 0
end

function I.IsSuspect(seller)
	return I.Score(seller) >= SUSPECT_AT
end

-- mark row objects in place; the book pass hands the same tables to
-- every subscriber, so flags are visible downstream for free
local function Analyze(rows)
	I.marks = {}
	Suspects()
	local byItem = {}
	for _, r in ipairs(rows) do
		if r.id then
			local l = byItem[r.id]
			if not l then l = {} byItem[r.id] = l end
			l[#l + 1] = r
		end
	end
	for id, l in pairs(byItem) do
		table.sort(l, function(a, b) return a.unit < b.unit end)
		local m = {}
		-- bait: a lone cheap lot far under the next ask — posted to
		-- drag snipers/solvers into a low reference price
		if #l >= 2 and l[2].unit > 0
			and l[1].unit <= l[2].unit * BAIT_DROP then
			l[1].bait = true
			m.bait = true
			Bump(l[1].seller, 2)
		end
		-- step chains: long runs of asks exactly 1c apart read as
		-- automated repricing — humans round to silver
		local run = 1
		local function CloseRun(hi)
			if run >= STEP_MIN then
				for j = hi - run + 1, hi do
					l[j].step = true
					Bump(l[j].seller, 1)
				end
				m.steps = (m.steps or 0) + run
			end
			run = 1
		end
		for i = 2, #l do
			if l[i].unit - l[i - 1].unit == STEP_GAP then
				run = run + 1
			else
				CloseRun(i - 1)
			end
		end
		CloseRun(#l)
		-- walls: one seller holding a stack of listings on one item
		local bySeller = {}
		for _, r in ipairs(l) do
			if r.seller then
				bySeller[r.seller] = (bySeller[r.seller] or 0) + 1
			end
		end
		for seller, n in pairs(bySeller) do
			if n >= WALL_MIN then
				m.walls = m.walls or {}
				m.walls[seller] = n
				Bump(seller, 2)
				for _, r in ipairs(l) do
					if r.seller == seller then r.wall = true end
				end
			end
		end
		-- already-suspect sellers get every row flagged outright
		for _, r in ipairs(l) do
			if r.seller and I.IsSuspect(r.seller) then r.solver = true end
		end
		I.marks[id] = m
	end
end

-- first subscriber: flags exist before sniper/shopping consume rows
GM.AH.bookSubs[#GM.AH.bookSubs + 1] = function(rows)
	pcall(Analyze, rows or {})
end

-- short flag string for a marked row, or nil when clean
function I.FlagsFor(r)
	if not r then return nil end
	local f = {}
	if r.bait then f[#f + 1] = "bait" end
	if r.solver then f[#f + 1] = "solver" end
	if r.wall then f[#f + 1] = "wall" end
	if r.step then f[#f + 1] = "step" end
	if #f == 0 then return nil end
	return table.concat(f, "·")
end

-- /goblin intel — top suspects by accumulated score
function I.Dump()
	local s = I.suspects or Suspects()
	local list = {}
	for name, e in pairs(s) do
		list[#list + 1] = { name = name, e = e }
	end
	table.sort(list, function(a, b) return a.e.score > b.e.score end)
	if #list == 0 then
		GM.Print("intel: no suspects yet — run a book scan")
		return
	end
	GM.Print("intel suspects:")
	for i = 1, math.min(15, #list) do
		local e = list[i]
		GM.Print(format("  %s%s|r — score %d, last seen %s",
			GM.CC(e.e.score >= SUSPECT_AT and "warn" or "textDim"),
			e.name, e.e.score, date("%H:%M", e.e.last or 0)))
	end
end
