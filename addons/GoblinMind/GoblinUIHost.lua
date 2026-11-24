local _, GM = ...

-- ================================================================
-- GoblinUIHost.lua — GoblinMind's GoblinUI context. Loads right
-- after Theme.lua so every UI file sees GM.ui/GM.L. The library is
-- a hard toc dependency (## Dependencies: GoblinUI); the pcall
-- keeps a missing-lib install diagnosable instead of hard-failing.
-- ================================================================

local ok, lib = pcall(LibStub, "GoblinUI-1.0")
if not ok or not lib then
	GM.ui = nil
	-- printed lazily from Core init where GM.Print exists
	GM._uiMissing = true
	return
end

-- ============ host theme: "goblinmind" ============
-- the neutral/gold default ramp + Montserrat + the market
-- terminal's extra data-cell styles (dense rows aren't captions —
-- they carry prices; 13px is the ratified cell size for tables)

local base = lib._internal.themes.default
local styles = {}
for k, v in pairs(base.styles) do
	local s = {}
	for k2, v2 in pairs(v) do s[k2] = v2 end
	styles[k] = s
end
styles.cell = { font = "regular", size = 13, color = "text", line = 17 }
styles.cellAccent = { font = "medium", size = 13, color = "accent", line = 17 }
styles.cellDim = { font = "regular", size = 13, color = "textDim", line = 17 }

local fonts = {}
for k, v in pairs(base.fonts) do fonts[k] = v end
fonts.regular  = GM.FONT
fonts.medium   = GM.FONT_MED
fonts.semibold = GM.FONT_BOLD

local palette = {}
for k, v in pairs(base.palette) do palette[k] = v end

assert(lib:RegisterTheme("goblinmind", {
	palette = palette,
	fonts = fonts,
	styles = styles,
	chrome = base.chrome,
	roles = base.roles,
}))

GM.ui = lib:CreateContext("GoblinMind", {
	theme = "goblinmind",
	diagnostics = true,        -- dev: reports layout guard trips
})

-- the English-keyed localizer: L('Post Scan') — enUS source of
-- truth, missing keys degrade to the literal English key
GM.L = GM.ui:GetLocalizer()
