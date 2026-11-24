-- ================================================================
-- GoblinUI/Locales/enUS.lua — library-owned strings, English source
-- of truth. Override files (deDE/frFR/…) register the same keys
-- under their own locale. Literal-English-keyed by contract.
-- ================================================================

local lib = LibStub("GoblinUI-1.0")

lib:RegisterLocale("GoblinUI", "enUS", {
	["Close"] = "Close",
	["On"] = "On",
	["Off"] = "Off",
	["Cancel"] = "Cancel",
	["Confirm"] = "Confirm",
	["Loading"] = "Loading…",
	["Unsaved"] = "Unsaved",
	["{first}–{last} of {total}"] = "{first}–{last} of {total}",
	["{n} items"] = "{n} items",
	["No items"] = "No items",
	["Back"] = "Back",
	["Next"] = "Next",
	["More"] = "More",
	["Search"] = "Search",
})
