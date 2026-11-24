-- ================================================================
-- GoblinUI/Core/Core.lua — library registration, host contexts,
-- theme and locale registries, diagnostics, frame scheduling.
-- No GoblinMind symbols; modules resolve the LibStub handle only.
-- ================================================================

local MAJOR, MINOR = "GoblinUI-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end -- same-or-newer copy already owns the handle

lib.MINOR = MINOR

-- module registry: files attach via lib._module(name) and receive
-- the shared internal table (contexts, factories, constants)
local internal = {
	contexts = {},  -- ownerId -> context record
	themes = {},    -- themeId -> validated theme definition
	locales = {},   -- ownerId -> { locale -> { key -> string } }
}
lib._internal = internal

function lib._module(name)
	local m = {}
	internal[name] = m
	return m
end

-- ============ diagnostics ============
-- development-only reporting: once per distinct key so a broken
-- caller gets a readable report, not a chat-spam loop

local function Report(ctx, key, msg)
	if not (ctx and ctx.diagnostics) then return end
	ctx.seen = ctx.seen or {}
	if ctx.seen[key] then return end
	ctx.seen[key] = true
	DEFAULT_CHAT_FRAME:AddMessage(
		"|cffe1ba00GoblinUI|r " .. tostring(msg))
end
internal.report = Report

-- ============ contexts ============

local ctxMT = { __index = {} }
internal.ctxMT = ctxMT

-- lib:CreateContext(ownerId, options) -> ui
-- one isolated theme/strings/scheduler scope per host addon — an
-- embedding addon can never restyle or restring another's context
function lib:CreateContext(ownerId, options)
	assert(type(ownerId) == "string" and ownerId ~= "",
		"GoblinUI: ownerId must be a non-empty string")
	assert(not internal.contexts[ownerId],
		"GoblinUI: duplicate context '" .. ownerId .. "'")
	options = options or {}
	local ctx = setmetatable({
		owner = ownerId,
		themeId = options.theme or "default",
		textScale = options.textScale or 1,
		locale = options.locale
			or (GetLocale and GetLocale()) or "enUS",
		diagnostics = options.diagnostics and true or false,
		fonts = options.fonts,
		motion = options.motion and true or false,
	}, ctxMT)
	internal.contexts[ownerId] = ctx
	return ctx
end

-- ============ theme registry ============

-- lib:RegisterTheme(themeId, definition) -> ok, err?
-- immutable validated definitions; Core/Theme.lua registers the
-- standalone default, hosts inject their own before CreateContext
function lib:RegisterTheme(themeId, definition)
	assert(type(themeId) == "string" and themeId ~= "",
		"GoblinUI: themeId must be a non-empty string")
	local ok, err = internal.ValidateTheme
		and internal.ValidateTheme(definition)
	if not ok then return nil, err end
	internal.themes[themeId] = definition
	return true
end

function ctxMT.__index:SetTheme(themeId)
	if not internal.themes[themeId] then
		return nil, "GoblinUI: unknown theme '" .. tostring(themeId) .. "'"
	end
	self.themeId = themeId
	if internal.InvalidateAll then internal.InvalidateAll(self) end
	return true
end

-- palette lookup with a logged fallback for unknown optional keys
function ctxMT.__index:Color(key)
	local t = internal.themes[self.themeId]
	local v = t and t.palette and t.palette[key]
	if type(v) == "string" and #v == 6 then
		return tonumber(v:sub(1, 2), 16) / 255,
			tonumber(v:sub(3, 4), 16) / 255,
			tonumber(v:sub(5, 6), 16) / 255
	end
	Report(self, "palette:" .. tostring(key),
		"unknown palette key '" .. tostring(key) .. "' — text fallback")
	v = t and t.palette and t.palette.text or "ecf4f3"
	return tonumber(v:sub(1, 2), 16) / 255,
		tonumber(v:sub(3, 4), 16) / 255,
		tonumber(v:sub(5, 6), 16) / 255
end

function ctxMT.__index:Font(role)
	local t = internal.themes[self.themeId]
	local f = self.fonts and self.fonts[role]
		or (t and t.fonts and t.fonts[role])
		or (t and t.fonts and t.fonts.fallback)
	return f or (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
end

-- raw six-digit hex for inline color escapes ("|cff" .. Hex() ..)
function ctxMT.__index:Hex(key)
	local t = internal.themes[self.themeId]
	return t and t.palette and t.palette[key] or "ffffff"
end

-- ============ locale registry ============

-- lib:RegisterLocale(ownerId, locale, strings)
-- literal English keys -> translated values; owner's enUS table is
-- the source of truth, per-locale tables override it
function lib:RegisterLocale(ownerId, locale, strings)
	assert(type(strings) == "table", "GoblinUI: strings must be a table")
	local reg = internal.locales[ownerId]
	if not reg then reg = {} internal.locales[ownerId] = reg end
	local t = reg[locale]
	if not t then t = {} reg[locale] = t end
	for k, v in pairs(strings) do t[k] = v end
	return true
end

function ctxMT.__index:L(key)
	-- owner's locale, owner's enUS, then the library's own table
	-- (widgets resolve their strings in any context)
	for _, owner in ipairs({ self.owner, "GoblinUI" }) do
		local reg = internal.locales[owner]
		if reg then
			local loc = reg[self.locale] or reg.enUS
			if loc and loc[key] ~= nil then return loc[key] end
		end
	end
	Report(self, "L:" .. tostring(key),
		"unregistered L key '" .. tostring(key) .. "'")
	return key
end

-- the English-keyed callable the spec requires: local L =
-- ui:GetLocalizer() then L('Post Scan') — closure, no colon receiver
function ctxMT.__index:GetLocalizer()
	local ctx = self
	return function(key) return ctx:L(key) end
end

-- ui:Format('{first}–{last} of {total}', {first=1,last=5,total=39})
-- named placeholders only; values substitute verbatim, no nested
-- pattern interpretation
function ctxMT.__index:Format(key, args)
	local s = self:L(key)
	if type(args) == "table" then
		s = s:gsub("{(%w+)}", function(name)
			local v = args[name]
			return v ~= nil and tostring(v) or "{" .. name .. "}"
		end)
	end
	return s
end

-- ============ scheduling ============
-- one shared dispatcher frame: layouts coalesce into a single
-- OnUpdate pass; clean roots do zero per-frame work

local dirty = {}   -- root frame -> context
local sched = CreateFrame("Frame")
sched:Hide()
sched:SetScript("OnUpdate", function()
	sched:Hide()
	local batch = dirty
	dirty = {}
	for root, ctx in pairs(batch) do
		if internal.ArrangeRoot then
			internal.ArrangeRoot(ctx, root)
		end
	end
end)

function internal.MarkDirty(ctx, root)
	if not next(dirty) then sched:Show() end
	dirty[root] = ctx
end

internal.sched = sched
