local _, GM = ...

-- ================================================================
-- Time.lua — GM.Time, the singleton clock and scheduler. Every
-- timed wait, debounce, throttle, repeat timer, and staleness
-- check routes through this one object: a single seam if the
-- client's clock source ever changes, and a single place to audit
-- pending work.
--
--   Now()               game clock (seconds since epoch)
--   Since(t) / Age(t)   elapsed since a stamp — nil-safe
--   Fresh(t, ttl)       stamp within ttl seconds of now
--   After(delay, fn)    run fn once after delay (moved from
--                       Theme.lua; GM.After remains as an alias)
--   Every(key, p, fn)   repeating timer per key — same key
--                       restarts; Stop(key) cancels
--   Debounce(k, d, fn)  each call resets k's timer — fn fires
--                       once, d after the LAST call
--   Coalesced(k, d, fn) at most one pending call per key — extra
--                       calls while pending are DROPPED (the
--                       view-refresh coalescer: collapse event
--                       storms into one repaint)
--   Throttle(k, i, fn)  leading edge fires now; calls inside the
--                       interval schedule at most one trailing run
--   Stop(key)           cancel an Every ticker
--
-- The debounce/throttle/coalesce keys are plain strings — prefix
-- with the module name ("ahui", "inv") so different subsystems
-- can't collide on a generic key like "refresh".
-- ================================================================

GM.Time = {}
local T = GM.Time

-- ============ clock ============

-- the single time source — everything that stamps or measures
-- staleness reads this, never bare time(), so a server-time
-- correction would land in exactly one place
function T.Now()
	return time()
end

-- elapsed since a stamp (nil-safe — an absent stamp has no age)
function T.Since(t)
	return t and (time() - t) or nil
end
T.Age = T.Since

-- stamp within ttl seconds of now
function T.Fresh(t, ttl)
	return t ~= nil and (time() - t) < ttl or false
end

-- ============ one-shot ============

local afterCalls = 0
function T.After(delay, fn)
	afterCalls = afterCalls + 1 -- cmd_perf reads the counter
	if C_Timer and C_Timer.After then
		return C_Timer.After(delay, fn)
	end
	-- no timer api (shouldn't happen on Forever): run now rather
	-- than drop the work
	fn()
end

-- compat alias — /run snippets and older docs name GM.After
function GM.After(delay, fn)
	return T.After(delay, fn)
end

-- ============ repeating ============

local tickers = {}
function T.Every(key, period, fn)
	T.Stop(key)
	if C_Timer and C_Timer.NewTicker then
		tickers[key] = C_Timer.NewTicker(period, fn)
		return tickers[key]
	end
end

function T.Stop(key)
	local h = tickers[key]
	if h then
		pcall(h.Cancel, h)
		tickers[key] = nil
	end
end

-- ============ keyed primitives ============

local debounced = {}
-- each call resets the key's timer; fn runs once, delay after the
-- LAST call — for "input settled" semantics (search boxes, edits)
function T.Debounce(key, delay, fn)
	local p = debounced[key]
	if not p then p = {} debounced[key] = p end
	p.gen = (p.gen or 0) + 1
	local gen = p.gen
	T.After(delay, function()
		if debounced[key] == p and p.gen == gen then
			debounced[key] = nil
			fn()
		end
	end)
end

local coalesced = {}
-- at most one pending call per key; extra calls while pending are
-- dropped. Different from Debounce: the pending call is NOT pushed
-- out — a storm coalesces into one fire on the ORIGINAL schedule.
-- This is the view-refresh pattern every window used to hand-roll
-- as an evPending flag.
function T.Coalesced(key, delay, fn)
	if coalesced[key] then return end
	coalesced[key] = true
	T.After(delay or 0.2, function()
		coalesced[key] = nil
		fn()
	end)
end

local throttled = {}
-- leading edge: fn runs immediately. Calls inside the interval
-- schedule at most one trailing run at the interval's end.
function T.Throttle(key, interval, fn)
	local now = time()
	local p = throttled[key]
	if not p or (now - p.t) >= interval then
		p = { t = now }
		throttled[key] = p
		fn()
		return
	end
	if p.tail then return end
	p.tail = true
	T.After(interval - (now - p.t), function()
		p.tail = nil
		p.t = time()
		fn()
	end)
end
