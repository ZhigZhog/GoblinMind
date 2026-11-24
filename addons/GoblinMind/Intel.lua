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

local floor = math.floor

I.marks = {}    -- itemID -> { bait=?, steps=?, walls={seller=n}, wallHist={seller={...}} }
I.suspects = nil -- seller -> { score, last, obs, scanB } (persisted in SV)

local STEP_GAP = 1         -- exact-1c chains are the literal bot tell
local STEP_PCT = 0.02      -- uniform micro-steps <=2% of price read as bot too
local STEP_MIN = 3         -- chain length that reads as algorithmic
local BAIT_DROP = 0.60     -- cheapest ask <= 60% of next = sniper bait
local BAIT_MED = 0.45      -- …or <= 45% of the book's median ask
local WALL_MIN = 4         -- same-seller lots + book share = a wall
local WALL_SHARE = 0.35    --   (4 stray lots on a 75-lot book aren't a wall)
local WALL_TOP = 6         -- …or dominance of the cheapest window chokes
local WALL_TOP_MIN = 3     --   the reference: >=3 of the cheapest 6
local SUSPECT_AT = 4       -- decayed score that marks a seller as a solver
local SCORE_HALF = 259200  -- suspect score half-life (3d) — reputation fades
local OBS_MIN = 2          -- distinct scans before a seller can be branded
local OBS_BUCKET = 900     -- scans inside a 15m window = one observation
local WALL_EXPIRE = 604800 -- drop wall history unseen for 7d

local function Suspects()
	GoblinMindHistory = GoblinMindHistory or {}
	GoblinMindHistory.suspects = GoblinMindHistory.suspects or {}
	I.suspects = GoblinMindHistory.suspects
	return I.suspects
end

-- wall history: itemID -> seller -> { first, seen, scans, n, sig, replenished }
local function Walls()
	GoblinMindHistory = GoblinMindHistory or {}
	GoblinMindHistory.wallHist = GoblinMindHistory.wallHist or {}
	return GoblinMindHistory.wallHist
end

-- lazy decay on read: the stored score is the accumulator, the
-- effective score fades at SCORE_HALF so reputation isn't permanent
local function EffScore(e, now)
	if not e then return 0 end
	local age = math.max(0, (now or time()) - (e.last or 0))
	return (e.score or 0) * 0.5 ^ (age / SCORE_HALF)
end

-- scanB = observation bucket (floor(scanT / OBS_BUCKET)) — repeated
-- scans of the same evidence inside 15m count as ONE observation, so
-- per-item rescans can't inflate a seller toward the suspect line
local function Bump(seller, pts, scanB)
	if not seller or seller == "" then return end
	local s = Suspects()
	local e = s[seller]
	if not e then e = { score = 0, obs = 0 } s[seller] = e end
	e.score = EffScore(e) + pts -- decay in before adding keeps it honest
	e.last = time()
	if e.scanB ~= scanB then
		e.obs = (e.obs or 0) + 1
		e.scanB = scanB
	end
end

function I.Score(seller)
	local e = I.suspects and seller and I.suspects[seller]
	return e and floor(EffScore(e) + 0.5) or 0
end

function I.IsSuspect(seller)
	local e = I.suspects and seller and I.suspects[seller]
	if not e then return false end
	return EffScore(e) >= SUSPECT_AT and (e.obs or 0) >= OBS_MIN
end

function I.WallInfo(id, seller)
	local h = GoblinMindHistory and GoblinMindHistory.wallHist
	return h and h[id] and h[id][seller] or nil
end

-- a wall that reappears across scans needs history: scans counts
-- distinct observation windows; a churned fingerprint set while the
-- lot count holds = the wall is being reposted as it sells
local function RecordWall(id, seller, l, n, scanT, scanB)
	local hist = Walls()
	local hi = hist[id]
	if not hi then hi = {} hist[id] = hi end
	local sig = {}
	for _, r in ipairs(l) do
		if r.seller == seller then
			local fp = tostring(r.qty) .. ":" .. tostring(r.unit)
				.. ":" .. tostring(r.tl or "?")
			sig[fp] = (sig[fp] or 0) + 1
		end
	end
	local e = hi[seller]
	if not e then
		e = { first = scanT, scans = 0 }
		hi[seller] = e
	elseif e.seen and e.seen ~= scanT then
		-- churn check on the PREVIOUS fingerprint set — most of it
		-- gone while the wall still stands = selling + reposting
		local held, prev = 0, 0
		for fp, cnt in pairs(e.sig or {}) do
			prev = prev + cnt
			held = held + math.min(cnt, sig[fp] or 0)
		end
		e.replenished = prev > 0 and held / prev < 0.5 or nil
	end
	if e.scanB ~= scanB then
		e.scans = (e.scans or 0) + 1
		e.scanB = scanB
	end
	e.seen, e.n, e.sig = scanT, n, sig
	return e
end

-- one item's sorted ask ladder: bait / step-chains / walls / solver
-- marks — shared by the book pass and per-item targeted scans
local function AnalyzeLadder(id, l, scanT)
	local scanB = floor(scanT / OBS_BUCKET)
	local m = {}
	-- bait: a lone cheap lot far under the next ask OR the book's own
	-- median — posted to drag snipers/solvers to a low reference
	if #l >= 2 and not l[1].own and l[2].unit > 0 then
		local med = l[math.ceil(#l / 2)].unit
		if l[1].unit <= l[2].unit * BAIT_DROP
			or l[1].unit <= med * BAIT_MED then
			l[1].bait = true
			m.bait = true
			Bump(l[1].seller, 2, scanB)
		end
	end
	-- step chains: long runs of asks 1c apart (or a uniform micro-
	-- stride — same small delta repeated) read as repricing bots;
	-- humans round to silver
	local run, prevGap = 1, nil
	local function CloseRun(hi)
		if run >= STEP_MIN then
			for j = hi - run + 1, hi do
				l[j].step = true
				Bump(l[j].seller, 1, scanB)
			end
			m.steps = (m.steps or 0) + run
		end
		run = 1
	end
	for i = 2, #l do
		local g = l[i].unit - l[i - 1].unit
		if g == STEP_GAP
			or (g > 0 and g == prevGap
				and g <= math.max(STEP_GAP, l[i].unit * STEP_PCT)) then
			run = run + 1
		else
			CloseRun(i - 1)
		end
		prevGap = g
	end
	CloseRun(#l)
	-- walls: one seller choking the top of the book — either >=half
	-- the cheapest WALL_TOP asks, or WALL_MIN+ lots at 35% book share
	local bySeller, topCount = {}, {}
	for _, r in ipairs(l) do
		local s = r.seller
		-- "?" = redacted/unknown — grouping unknowns fabricates a
		-- shared-seller wall out of unrelated listings
		if s and s ~= "?" then
			bySeller[s] = (bySeller[s] or 0) + 1
		end
	end
	for i = 1, math.min(#l, WALL_TOP) do
		local s = l[i].seller
		if s and s ~= "?" then topCount[s] = (topCount[s] or 0) + 1 end
	end
	for seller, n in pairs(bySeller) do
		local top = topCount[seller] or 0
		local topN = math.min(#l, WALL_TOP)
		if (n >= WALL_MIN and n >= #l * WALL_SHARE)
			or (top >= WALL_TOP_MIN and top >= topN * 0.5) then
			m.walls = m.walls or {}
			m.walls[seller] = n
			local e = RecordWall(id, seller, l, n, scanT, scanB)
			m.wallHist = m.wallHist or {}
			m.wallHist[seller] = { scans = e.scans,
				age = e.seen - e.first, replenished = e.replenished }
			Bump(seller, 2, scanB)
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

-- mark row objects in place; the book pass hands the same tables to
-- every subscriber, so flags are visible downstream for free
local function Analyze(rows)
	I.marks = {}
	Suspects()
	local scanT = GM.AH.bookT or time()
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
		AnalyzeLadder(id, l, scanT)
	end
	-- prune wall history not confirmed by this snapshot for a week —
	-- per-item scans aren't allowed to prune the book-wide history
	local hist = GoblinMindHistory and GoblinMindHistory.wallHist
	if hist then
		for id, hi in pairs(hist) do
			for seller, e in pairs(hi) do
				if scanT - (e.seen or 0) > WALL_EXPIRE then
					hi[seller] = nil
				end
			end
			if not next(hi) then hist[id] = nil end
		end
	end
end

-- targeted per-item scans (the market page's ask ladder) feed the
-- same marks + suspect table — intel no longer waits on full books
function I.AnalyzeItem(id, asks, scanT)
	if not (id and asks and asks[1]) then return end
	Suspects()
	table.sort(asks, function(a, b) return a.unit < b.unit end)
	AnalyzeLadder(id, asks, scanT or time())
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

-- /goblin intel — top suspects by decayed score
function I.Dump()
	local s = I.suspects or Suspects()
	local list = {}
	for name, e in pairs(s) do
		list[#list + 1] = { name = name, e = e, sc = floor(EffScore(e) + 0.5) }
	end
	table.sort(list, function(a, b) return a.sc > b.sc end)
	if #list == 0 or list[1].sc <= 0 then
		GM.Print("intel: no suspects yet — run a book scan")
		return
	end
	GM.Print("intel suspects:")
	for i = 1, math.min(15, #list) do
		local e = list[i]
		if e.sc <= 0 then break end
		GM.Print(format("  %s%s|r — score %d across %d obs, last seen %s",
			GM.CC(e.sc >= SUSPECT_AT and (e.e.obs or 0) >= OBS_MIN
				and "warn" or "textDim"),
			e.name, e.sc, e.e.obs or 0, date("%H:%M", e.e.last or 0)))
	end
end
