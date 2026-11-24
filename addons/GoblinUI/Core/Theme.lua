-- ================================================================
-- GoblinUI/Core/Theme.lua — the standalone default theme and the
-- validation contract every registered theme must satisfy.
-- Palette values are the spec's OKLCH-derived neutral/gold ramp
-- (sRGB hex, no '#'); WCAG pairings are enforced by the style
-- table, not by memory — see goblin-ui-design-system.md §6.2.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")
local internal = lib._internal

-- required palette keys (the host vocabulary is preserved so
-- GoblinMind's adapter maps one-for-one)
local REQUIRED = {
	"surface", "surfaceVariant", "contLowest", "contLow",
	"contMedium", "contHigh", "contHighest", "outline", "outlineVar",
	"text", "textDim", "primary", "secondary", "accent", "accentDark",
	"err", "pos", "warn", "onAccent",
}

local function isHex(v)
	return type(v) == "string" and v:match("^%x%x%x%x%x%x$") ~= nil
end

-- validation: returns ok or nil + diagnostic; immutable contract —
-- callers must not mutate a registered definition
function internal.ValidateTheme(def)
	if type(def) ~= "table" then
		return nil, "theme must be a table"
	end
	if type(def.palette) ~= "table" then
		return nil, "theme.palette must be a table"
	end
	for _, k in ipairs(REQUIRED) do
		if not isHex(def.palette[k]) then
			return nil, "theme.palette." .. k
				.. " must be six-digit sRGB hex"
		end
	end
	if def.fonts and type(def.fonts) ~= "table" then
		return nil, "theme.fonts must be a table"
	end
	if def.styles and type(def.styles) ~= "table" then
		return nil, "theme.styles must be a table"
	end
	return true
end

-- ============ the standalone default ============
-- neutral surfaces + gold accent; text/textDim/primary/accent/
-- pos/warn pass 4.5:1 on every cont* fill; err and secondary are
-- restricted to the darkest surfaces by the style table

lib:RegisterTheme("default", {
	palette = {
		surface        = "0e1313",
		surfaceVariant = "363c3c",
		contLowest     = "090e0e",
		contLow        = "161c1c",
		contMedium     = "1d2323",
		contHigh       = "292f2f",
		contHighest    = "313737",
		outline        = "99a0a0",
		outlineVar     = "434949",
		text           = "ecf4f3",
		textDim        = "b8bfbf",
		primary        = "b9bfbf",
		secondary      = "77818d",
		accent         = "e1ba00",
		accentDark     = "654000",
		err            = "fd392e",
		pos            = "08d36b",
		warn           = "ff9707",
		onAccent       = "090e0e",
	},
	fonts = {
		-- locale-appropriate client font; hosts override with
		-- vendored families through CreateContext{fonts={...}}
		regular  = STANDARD_TEXT_FONT,
		medium   = STANDARD_TEXT_FONT,
		semibold = STANDARD_TEXT_FONT,
		fallback = STANDARD_TEXT_FONT,
	},
	-- semantic text styles: font role × size × color role ×
	-- minimum line box (spec §2.2 — nothing essential under 14)
	styles = {
		title   = { font = "semibold", size = 18, color = "accent",  line = 24 },
		header  = { font = "semibold", size = 16, color = "text",    line = 24 },
		label   = { font = "medium",   size = 14, color = "textDim", line = 20 },
		body    = { font = "regular",  size = 14, color = "text",    line = 20 },
		value   = { font = "medium",   size = 14, color = "text",    line = 20 },
		button  = { font = "semibold", size = 14, color = "text",    line = 20 },
		dim     = { font = "regular",  size = 14, color = "textDim", line = 20 },
		success = { font = "medium",   size = 14, color = "pos",     line = 20 },
		warn    = { font = "medium",   size = 14, color = "warn",    line = 20 },
		error   = { font = "medium",   size = 14, color = "text",    line = 20 },
		caption = { font = "regular",  size = 12, color = "textDim", line = 16 },
	},
	chrome = { kind = "flat" },
	roles = { focus = "accent", controlBorder = "outline",
		errorText = "text", errorSurface = "err" },
})

-- spacing tokens (spec §2.1) — every gap/pad derives from these;
-- widgets never invent their own gutters
internal.SP = {
	none = 0, hair = 2, xs = 4, sm = 8,
	md = 12, lg = 16, xl = 24, xxl = 32,
}
internal.STROKE_THIN = 1
internal.CONTROL_H = 44
internal.ROW_H = 44
internal.ROW_RO_H = 24
internal.HEADER_H = 44
internal.WIN_HEADER_H = 48

function internal.Space(v)
	if type(v) == "number" then return v end
	return internal.SP[v] or internal.SP.md
end
