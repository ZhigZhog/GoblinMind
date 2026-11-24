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
styles.cell = { font = "regular", size = 11, color = "text", line = 14 }
styles.cellAccent = { font = "medium", size = 11, color = "accent", line = 14 }
styles.cellDim = { font = "regular", size = 11, color = "textDim", line = 14 }
-- widget chrome at the addon's scale — the lib defaults (14px)
-- are window-scale; GoblinMind's conventions run 9-11px
styles.button = { font = "semibold", size = 10, color = "text", line = 12 }
styles.input = { font = "regular", size = 11, color = "text", line = 14 }
styles.panelTitle = { font = "semibold", size = 10, color = "textDim",
	line = 12 }
styles.panelCount = { font = "regular", size = 10, color = "textDim",
	line = 12 }

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

-- GoblinMind's own enUS table — English keys ARE the lookup keys,
-- so registering literals documents the translatable surface and
-- silences the unregistered-key diagnostic. Keys gather here as
-- the L() migration sweeps each window (market page first).
lib:RegisterLocale("GoblinMind", "enUS", {
	["+ CATEGORY"] = "+ CATEGORY",
	["+ SAVE CURRENT"] = "+ SAVE CURRENT",
	["+CAT"] = "+CAT",
	["0g"] = "0g",
	["24h"] = "24h",
	["< BACK"] = "< BACK",
	["ACC"] = "ACC",
	["Ask Book"] = "Ask Book",
	["ASSIGN"] = "ASSIGN",
	["AUCTION HOUSE"] = "AUCTION HOUSE",
	["Auto"] = "Auto",
	["AUTO"] = "AUTO",
	["autosc"] = "autosc",
	["BANK"] = "BANK",
	["BID"] = "BID",
	["BLIZZARD UI"] = "BLIZZARD UI",
	["BROWSE"] = "BROWSE",
	["BUILD"] = "BUILD",
	["BUY"] = "BUY",
	["CAN LEARN"] = "CAN LEARN",
	["CANCEL SCAN"] = "CANCEL SCAN",
	["CATALOGUE"] = "CATALOGUE",
	["category name…"] = "category name…",
	["CLAIM"] = "CLAIM",
	["class: any"] = "class: any",
	["CLEAR"] = "CLEAR",
	["CLEAR DONE"] = "CLEAR DONE",
	["CLEAR ROUTE"] = "CLEAR ROUTE",
	["CLOSE"] = "CLOSE",
	["COLLAPSE ALL"] = "COLLAPSE ALL",
	["commit"] = "commit",
	["CONNECT"] = "CONNECT",
	["CRAFT"] = "CRAFT",
	["CRAFTABLE ONLY"] = "CRAFTABLE ONLY",
	["CRAFTING"] = "CRAFTING",
	["CURRENT"] = "CURRENT",
	["Custom price sources"] = "Custom price sources",
	["DEL"] = "DEL",
	["DENY"] = "DENY",
	["Depth"] = "Depth",
	["DESTROYING"] = "DESTROYING",
	["DONE"] = "DONE",
	["drop an item — or FIND ITEM below to browse"] = "drop an item — or FIND ITEM below to browse",
	["drop item here · shift-click one · /goblin [link]"] = "drop item here · shift-click one · /goblin [link]",
	["DUP"] = "DUP",
	["EDIT"] = "EDIT",
	["EMIT PLAN"] = "EMIT PLAN",
	["Execute"] = "Execute",
	["EXP"] = "EXP",
	["farm"] = "farm",
	["farmlog"] = "farmlog",
	["farmreset"] = "farmreset",
	["FIELDS"] = "FIELDS",
	["FILE REPORT"] = "FILE REPORT",
	["FILTER"] = "FILTER",
	["filter recipes…"] = "filter recipes…",
	["FILTER: all"] = "FILTER: all",
	["filter…"] = "filter…",
	["FIND ITEM"] = "FIND ITEM",
	["FLIPS ONLY"] = "FLIPS ONLY",
	["FORCE"] = "FORCE",
	["FULL SCAN"] = "FULL SCAN",
	["GATHER"] = "GATHER",
	["Gathered nodes"] = "Gathered nodes",
	["glimport"] = "glimport",
	["GOBLINMIND MARKET"] = "GOBLINMIND MARKET",
	["GOLD"] = "GOLD",
	["gold"] = "gold",
	["gorloc"] = "gorloc",
	["GROUP ▾"] = "GROUP ▾",
	["GROUPS"] = "GROUPS",
	["Groups + item membership"] = "Groups + item membership",
	["GUILD BANK"] = "GUILD BANK",
	["HAS SKILL UP"] = "HAS SKILL UP",
	["HOLD"] = "HOLD",
	["icon"] = "icon",
	["IMP"] = "IMP",
	["IMPORT"] = "IMPORT",
	["In-game bug report"] = "In-game bug report",
	["INBOX"] = "INBOX",
	["Intel"] = "Intel",
	["ISSUES ↗"] = "ISSUES ↗",
	["item name, link or id..."] = "item name, link or id...",
	["ITEMS IN GROUP"] = "ITEMS IN GROUP",
	["LATER"] = "LATER",
	["LEDGER"] = "LEDGER",
	["left"] = "left",
	["LOAD"] = "LOAD",
	["MAIL"] = "MAIL",
	["MAIL SCAN"] = "MAIL SCAN",
	["MARKET"] = "MARKET",
	["mb"] = "mb",
	["MINE"] = "MINE",
	["MINIMAP:"] = "MINIMAP:",
	["mouseover"] = "mouseover",
	["MY AUCTIONS"] = "MY AUCTIONS",
	["myauctions"] = "myauctions",
	["name"] = "name",
	["name…"] = "name…",
	["NEXT >"] = "NEXT >",
	["Numbers"] = "Numbers",
	["Off"] = "Off",
	["OK"] = "OK",
	["On"] = "On",
	["on"] = "on",
	["OPEN ALL"] = "OPEN ALL",
	["OPERATIONS"] = "OPERATIONS",
	["Operations"] = "Operations",
	["operations"] = "operations",
	["options"] = "options",
	["or drop an item on me"] = "or drop an item on me",
	["overview"] = "overview",
	["PAY"] = "PAY",
	["Plan"] = "Plan",
	["POST"] = "POST",
	["POST ANYWAY"] = "POST ANYWAY",
	["Post Scan"] = "Post Scan",
	["POST SCAN"] = "POST SCAN",
	["Price"] = "Price",
	["primary"] = "primary",
	["PROFESSIONS"] = "PROFESSIONS",
	["PROT"] = "PROT",
	["qty"] = "qty",
	["QUEUE"] = "QUEUE",
	["rarity: any"] = "rarity: any",
	["recent"] = "recent",
	["RECIPES"] = "RECIPES",
	["recipient"] = "recipient",
	["REFRESH"] = "REFRESH",
	["REJ"] = "REJ",
	["REN"] = "REN",
	["REPAIR"] = "REPAIR",
	["Rescan"] = "Rescan",
	["RESCAN"] = "RESCAN",
	["RESET"] = "RESET",
	["SAVE"] = "SAVE",
	["SAVED"] = "SAVED",
	["Saved shopping searches"] = "Saved shopping searches",
	["SCAN → PLAN"] = "SCAN → PLAN",
	["SCREENSHOT"] = "SCREENSHOT",
	["search…"] = "search…",
	["SELECT ALL"] = "SELECT ALL",
	["SEND"] = "SEND",
	["SEND COD"] = "SEND COD",
	["SETTINGS"] = "SETTINGS",
	["SHOP"] = "SHOP",
	["shop"] = "shop",
	["SHOPPING SCAN"] = "SHOPPING SCAN",
	["Skip"] = "Skip",
	["SKIP"] = "SKIP",
	["slot: any"] = "slot: any",
	["SNAPSHOT"] = "SNAPSHOT",
	["SNIPER"] = "SNIPER",
	["SOON"] = "SOON",
	["tape"] = "tape",
	["target — drop · shift-click · [link]"] = "target — drop · shift-click · [link]",
	["TASKS"] = "TASKS",
	["TRACK"] = "TRACK",
	["TYPE"] = "TYPE",
	["units"] = "units",
	["VENDOR"] = "VENDOR",
	["WAREHOUSING SCAN"] = "WAREHOUSING SCAN",
	["WRITS"] = "WRITS",
	["zone map"] = "zone map",
	["ZONE: all"] = "ZONE: all",
	["« ITEMS"] = "« ITEMS",
})

-- the English-keyed localizer: L('Post Scan') — enUS source of
-- truth, missing keys degrade to the literal English key
GM.L = GM.ui:GetLocalizer()

-- GoblinUI Text nodes get the same deferred font heal the
-- MakeFontString path has — Refont re-applies dead styles once the
-- client can rasterize them (first-login load-order failure)
local origFixup = GM.FixupFonts
function GM.FixupFonts()
	if origFixup then origFixup() end
	if GM.ui then GM.ui:Refont() end
end
