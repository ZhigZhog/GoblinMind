local _, GM = ...

-- ================================================================
-- ViewMgr.lua — GM.View, the singleton view registry and window
-- manager. Every window registers once (at file end, before any
-- use); all showing/hiding/coalescing/event-plumbing routes here.
--
--   Register(key, def) — def:
--     Show(), Hide(), Toggle(), Refresh()   the view's entry points
--     IsShown()                             optional; needed for
--                                           View.IsShown
--     class:
--       "exclusive"  (default) — one-at-a-time set; Switch hides it
--       "peer"       — keeps sibling peers open; hidden only when
--                    Switch targets a non-peer (auctions, crafting,
--                    destroy, vendor)
--       "contextual" — takeover/session windows bound to a native
--                    frame (ah, bank, gbank, mail, sniper, tasks);
--                    Switch never touches them
--       "mode"       — tab keys that flip a window's mode rather
--                    than open a window (dash/plan on the planner);
--                    Switch disturbs nothing for these
--
--   Switch(key)   tab-strip navigation — the exclusivity logic that
--                 used to live as Dashboard.Switch's hardcoded hide
--                 lists
--   Show/Hide/Toggle(key)   routed by registry, nil-safe
--   IsShown(key)
--   Coalesced(key, fn, delay)   one pending refresh per view —
--                 replaces each file's hand-rolled evPending block
--   On(key, event, fn) / Off(key, event)   shared event dispatch —
--                 one frame for all view event plumbing instead of
--                 a hidden frame per window
--
-- Views still own their frames, their Build, and their state table.
-- The registry owns LIFECYCLE: who is open, what a tab switch
-- disturbs, and how event storms collapse into one refresh.
-- ================================================================

GM.View = {}
local V = GM.View

local T = GM.Time

local views = {}

-- forward decl: def.events closures call Paint at event time
local Paint

-- ============ registration ============

function V.Register(key, def)
	assert(type(key) == "string" and type(def) == "table")
	def.key = key
	def.class = def.class or "exclusive"
	views[key] = def
	-- def.events: events that mean "repaint when shown". Any firing
	-- schedules a coalesced Refresh — the pure plumbing case needs
	-- no per-file event frame at all
	if def.events and def.Refresh then
		for _, ev in ipairs(def.events) do
			V.On(key, ev, function()
				if not def.IsShown or def.IsShown() then
					V.Coalesced(key, function() Paint(def) end,
						def.evDelay)
				end
			end)
		end
	end
end

function V.Def(key)
	return views[key]
end

function V.Keys()
	local out = {}
	for k in pairs(views) do out[#out + 1] = k end
	return out
end

-- ============ lifecycle ============

function V.Show(key)
	local d = views[key]
	if d and d.Show then d.Show() end
end

function V.Hide(key)
	local d = views[key]
	if d and d.Hide then d.Hide() end
end

function V.Toggle(key)
	local d = views[key]
	if d then
		if d.Toggle then d.Toggle()
		elseif d.Show then d.Show() end
	end
end

function V.IsShown(key)
	local d = views[key]
	return d and d.IsShown and d.IsShown() or false
end

-- compute the view-model once (if the view declares Data) and hand
-- it to the painter — the single point where a view-model cache or
-- diffing could land later
function Paint(d)
	if d.Data then d.Refresh(d.Data())
	else d.Refresh() end
end

-- a refresh only if the window's visible — the guard every event
-- handler wants. Views whose IsShown isn't registered always pass.
function V.Refresh(key)
	local d = views[key]
	if d and d.Refresh and (not d.IsShown or d.IsShown()) then
		Paint(d)
	end
end

-- ============ tab switching ============
-- the semantics that were Dashboard.Switch:
--   mode target   → call its Show, disturb nothing
--   peer target   → hide every non-peer, keep peers open
--   other target  → hide peers AND the exclusive set
-- contextual views and mode defs are never hidden here

function V.Switch(key)
	local target = views[key]
	if not target then return end
	if target.class == "mode" then
		if target.Show then target.Show() end
		return
	end
	-- only exclusive and peer defs participate in switch-hiding —
	-- every other class (mode, contextual, pinned, anything added
	-- later) is left alone
	for k, d in pairs(views) do
		if k ~= key and d.Hide then
			if d.class == "exclusive" then
				d.Hide()
			elseif d.class == "peer" and target.class ~= "peer" then
				d.Hide()
			end
		end
	end
	if target.Show then target.Show() end
end

-- ============ refresh coalescing ============
-- the "if shown and not already pending, repaint on a 0.2s beat"
-- pattern — event storms collapse into one repaint per view

function V.Coalesced(key, fn, delay)
	T.Coalesced("view:" .. key, delay or 0.2, fn)
end

-- ============ shared event dispatch ============
-- one hidden frame for all view event plumbing; handlers keyed
-- per view so Off(key, event) never starves another window

local evFrame, subs
local function EnsureEv()
	if evFrame then return end
	evFrame = CreateFrame("Frame")
	subs = {}
	evFrame:SetScript("OnEvent", function(_, event, ...)
		local handlers = subs and subs[event]
		if not handlers then return end
		for _, fn in pairs(handlers) do
			fn(event, ...)
		end
	end)
end

function V.On(key, event, fn)
	EnsureEv()
	local h = subs[event]
	if not h then h = {} subs[event] = h end
	h[key] = fn
	pcall(evFrame.RegisterEvent, evFrame, event)
end

function V.Off(key, event)
	if subs and subs[event] then subs[event][key] = nil end
end
