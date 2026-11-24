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

GM.ui = lib:CreateContext("GoblinMind", {
	theme = "default",         -- neutral/gold; GoblinUI's default
	fonts = {
		regular  = GM.FONT,
		medium   = GM.FONT_MED,
		semibold = GM.FONT_BOLD,
	},
	diagnostics = true,        -- dev: reports layout guard trips
})

-- the English-keyed localizer: L('Post Scan') — enUS source of
-- truth, missing keys degrade to the literal English key
GM.L = GM.ui:GetLocalizer()
