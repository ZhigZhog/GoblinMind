local _, GM = ...

-- Price history — self-recorded market-value snapshots. TSM's AppData
-- exposes no per-item series, so we keep our own: one global snapshot
-- whenever at least MIN_GAP has passed (login + an hourly ticker).
-- Each item stores a packed "t.p.s.n,…" string (supply + lots came
-- with the market terminal; the parser tolerates old "t.p" points)
-- so the SavedVariable stays small.

GM.History = {}

local MAX_AGE = 8 * 86400 -- keep a week plus margin
local MAX_PTS = 56      -- per-item cap — 7d at the 3h minimum gap
local MIN_GAP = 3 * 3600

function GM.History.Init()
	GoblinMindHistory = GoblinMindHistory or { items = {}, lastT = 0 }
	GM.History.db = GoblinMindHistory
	GM.History.Snapshot()
	GM.After(3600, GM.History.Tick)
end

function GM.History.Tick()
	GM.History.Snapshot()
	GM.After(3600, GM.History.Tick)
end

function GM.History.Snapshot()
	local db = GM.History.db
	local now = time()
	if now - (db.lastT or 0) < MIN_GAP then return end
	local items = GoblinMindDB and GoblinMindDB.items
	if not items then return end
	db.lastT = now
	local book = GM.AH and GM.AH.book
	for id, e in pairs(items) do
		local p = GM.Price("dbmarket", id)
		if p then
			local b = book and book[id]
			local tail = b and ("." .. (b.sup or 0) .. "." .. (b.n or 0))
				or ""
			local s = db.items[id]
			db.items[id] = GM.History.Prune(
				(s and s .. "," or "") .. now .. "." .. floor(p) .. tail, now)
		end
	end
end

-- drop points older than MAX_AGE, cap the string at MAX_PTS points
function GM.History.Prune(s, now)
	local keep, n = {}, 0
	for pt in s:gmatch("[^,]+") do
		local t = tonumber(pt:match("^(%d+)"))
		if t and now - t <= MAX_AGE then
			n = n + 1
			keep[n] = pt
		end
	end
	while n > MAX_PTS do
		tremove(keep, 1)
		n = n - 1
	end
	return table.concat(keep, ",")
end

-- { {t, p, s, n}, ... } ascending over the last maxAge seconds —
-- s/n are nil on points written before the supply fields existed
function GM.History.Points(itemID, maxAge)
	local s = GM.History.db and GM.History.db.items[itemID]
	if not s then return {} end
	local cutoff = time() - (maxAge or MAX_AGE)
	local out = {}
	for pt in s:gmatch("[^,]+") do
		local t, p, sup, n = pt:match("^(%d+)%.(%d+)%.?(%d*)%.?(%d*)")
		t, p = tonumber(t), tonumber(p)
		if t and p and t >= cutoff then
			out[#out + 1] = { t = t, p = p,
				s = tonumber(sup), n = tonumber(n) }
		end
	end
	table.sort(out, function(a, b) return a.t < b.t end)
	return out
end
