-- WoW API shim for the mesh/writ simulator. Loaded into each
-- simulated client's LuaRuntime BEFORE the addon files. _NOW is the
-- sim clock — the Python driver advances it. _WIRE captures every
-- outgoing addon comm so the driver can route it like a server.

_NOW = _NOW or { t = 1795280000 }
_WIRE = {}       -- {msg, ctype, to} — outgoing addon comms
_TASKS = {}      -- GM.After queue: {due, fn}
_FRAMES = {}     -- captured frames (events + OnEvent scripts)
_PRINTS = {}     -- GM.Print sink
_RELOADS = 0
ITEM_DB = ITEM_DB or {}   -- [itemID] = {name=, link=}

-- WoW global aliases the addon uses (WoW exposes math/table
-- functions as flat globals; stock Lua 5.x does not)
tinsert = table.insert
tremove = table.remove
sort = table.sort
format = string.format
floor = math.floor
ceil = math.ceil
abs = math.abs
max = math.max
min = math.min
random = math.random
strlower = string.lower
strupper = string.upper
strlen = string.len
strsub = string.sub
strfind = string.find
strmatch = string.match
strrep = string.rep
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strsplit = function(delim, s)
	local out = {}
	for p in (s .. delim):gmatch("(.-)" .. delim) do
		out[#out + 1] = p
	end
	return table.unpack and table.unpack(out) or unpack(out)
end
strjoin = function(delim, ...) return table.concat({...}, delim) end
tContains = function(t, v)
	for _, x in pairs(t) do if x == v then return true end end
end
wipe = function(t) for k in pairs(t) do t[k] = nil end end

-- WoW: time() is integer epoch, GetTime() has sub-second precision
function time() return math.floor(_NOW.t) end
function GetTime() return _NOW.t end
function UnitName(who) return _NAME end
function GetMoney()
	return (GoblinMindSettings or {})._money or 0
end
function GetItemInfo(id)
	local e = ITEM_DB[id]
	if e then return e.name, e.link end
end
function ReloadUI() _RELOADS = _RELOADS + 1 end
function IsModifiedClick() return false end
-- per-channel membership: v2 runs two buses (goblinmindx market,
-- goblinwritx writs) — a client can be in either, both, or neither
_JOINED = {}
_CHIDS = { goblinmindx = 5, goblinwritx = 6 }
_CHNAMES = { [5] = "goblinmindx", [6] = "goblinwritx" }
_JOIN_FAIL = {}   -- channels a test wants unjoinable
function GetChannelName(ch) return _JOINED[ch] and _CHIDS[ch] or 0 end
function JoinChannelByName(ch)
	if not _JOIN_FAIL[ch] then _JOINED[ch] = true end
end

_SEND_LOG = {}   -- every SendAddonMessage call (debug)
C_ChatInfo = {
	SendAddonMessage = function(prefix, msg, ctype, to)
		_SEND_LOG[#_SEND_LOG + 1] =
			tostring(prefix) .. "|" .. tostring(ctype)
			.. "|" .. tostring(msg):sub(1, 40)
		_WIRE[#_WIRE + 1] = { msg = msg, ctype = ctype, to = to,
			chan = ctype == "CHANNEL" and _CHNAMES[to] or nil }
		return true
	end,
	RegisterAddonMessagePrefix = function(p) return true end,
}
SendAddonMessage = C_ChatInfo.SendAddonMessage
function SendChatMessage(msg, ctype, lang, target)
	_WIRE[#_WIRE + 1] = { msg = msg, ctype = "CHAT:" .. ctype,
		to = target }
end

function CreateFrame(kind, name, parent)
	local f = { _events = {}, _scripts = {} }
	function f:RegisterEvent(ev) self._events[ev] = true end
	function f:UnregisterEvent(ev) self._events[ev] = nil end
	function f:SetScript(k, fn) self._scripts[k] = fn end
	function f:HookScript(k, fn) self._scripts[k] = fn end
	_FRAMES[#_FRAMES + 1] = f
	return f
end

-- deliver an event to every registered frame — this is the mesh
-- input: CHAT_MSG_ADDON with (prefix, msg, ctype, sender) varargs
function fire_event(ev, ...)
	for _, f in ipairs(_FRAMES) do
		if f._events[ev] and f._scripts.OnEvent then
			f._scripts.OnEvent(f, ev, ...)
		end
	end
end

GoblinMindSettings = GoblinMindSettings or {}
GoblinMindDB = GoblinMindDB or {}
GM = {
	db = GoblinMindSettings,
	Scope = function() return "Sim-Realm-A" end,
	EmitAge = function() return 0 end,
	CC = function(k) return "" end,
	RGB = function(k) return 1, 1, 1 end,
	Print = function(s) _PRINTS[#_PRINTS + 1] = tostring(s) end,
	ItemNameOr = function(id)
		local e = ITEM_DB[id] or {}
		return e.name or ("item " .. tostring(id))
	end,
	ItemIcon = function() return nil end,
	NameColor = function() return 1, 1, 1 end,
	ModifiedItemClick = function() end,
	After = function(sec, fn)
		local src = debug.getinfo(2, "nS")
		_TASKS[#_TASKS + 1] = { due = _NOW.t + sec, fn = fn,
			src = (src and src.short_src or "?") .. ":"
				.. tostring(src and src.linedefined or "?") }
	end,
	OrdersUI = { Refresh = function() end },
	PlanQueue = { SetItem = function() end },
}

-- scheduler: fire every due GM.After task; re-armers reschedule
-- inside their own fn
function run_due()
	local n = 0
	while true do
		local idx = nil
		for i, t in ipairs(_TASKS) do
			if t.due <= _NOW.t then idx = i break end
		end
		if not idx then return n end
		local t = table.remove(_TASKS, idx)
		t.fn()
		n = n + 1
	end
end

-- SavedVariables serializer — the watcher scans the raw text for
-- staged records, so the format only needs faithful quoting
local function esc(s)
	return (s:gsub('[%z\1-\31\\"]', function(c)
		return string.format("\\%03d", c:byte())
	end))
end
local function ser(v, d)
	if type(v) == "string" then return '"' .. esc(v) .. '"' end
	if type(v) == "number" then return tostring(v) end
	if type(v) == "boolean" then return v and "true" or "false" end
	if type(v) ~= "table" then return "nil" end
	local parts = {}
	local arr = #v
	for i = 1, arr do
		parts[#parts + 1] = ser(v[i], d + 1)
	end
	for k, x in pairs(v) do
		if not (type(k) == "number" and k >= 1 and k <= arr) then
			parts[#parts + 1] = "[\""
				.. tostring(k):gsub('"', '\\"') .. "\"]="
				.. ser(x, d + 1)
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end
function SerSV()
	return "GoblinMindSettings = " .. ser(GoblinMindSettings, 0)
		.. "\n"
end
