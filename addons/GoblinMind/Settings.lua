local _, GM = ...

-- Part 12: in-game settings. GENERAL edits the scalar GM.db keys;
-- TOOLTIP LINES is generated from the tooltip module's option
-- registry (deduped entries, bool = On/Off, enum = click-to-cycle);
-- PROFILE exports/imports settings as a paste-able hex string.

GM.Settings = {}
local S = GM.Settings
local W = GM.Widgets
local ui

-- options that only take effect at load — toggling them queues a
-- "reload required" prompt rather than pretending they're live
local RELOAD_KEYS = { embeddedTooltip = true, minimapAngle = true }

-- ============ bug reports ============
-- In-game addons can't reach the network, so reports stage into the
-- GoblinMindSettings SavedVariable as "id|hex" strings; the brain
-- watcher reads the SV file after the next /reload and files each
-- one to GitHub, then echoes filed ids back through GoblinMindDB.

-- ring-buffer the last Lua errors for the diagnostic bundle — wrap
-- once and chain to the previous handler so error addons still work
if seterrorhandler and geterrorhandler then
	local prev = geterrorhandler()
	seterrorhandler(function(msg, ...)
		if GM.db then
			GM.db.errLog = GM.db.errLog or {}
			local log = GM.db.errLog
			log[#log + 1] = date("%H:%M:%S") .. " " .. tostring(msg)
			while #log > 20 do tremove(log, 1) end
		end
		if prev then return prev(msg, ...) end
	end)
end

local function ClearFiledBugs()
	local filed = GoblinMindDB and GoblinMindDB.filedBugs
	if not filed or not (GM.db and GM.db.bugReports) then return end
	local urls = {}
	for _, f in ipairs(filed) do urls[f.id] = f.url end
	local announced = GM.db.bugsAnnounced or {}
	for i = #GM.db.bugReports, 1, -1 do
		local rid = GM.db.bugReports[i]:match("^(gm%-%d+%-%d+)|")
		if rid and urls[rid] then
			if not announced[rid] then
				announced[rid] = true
				GM.Print("bug report filed — " .. urls[rid])
			end
			tremove(GM.db.bugReports, i)
		end
	end
	GM.db.bugsAnnounced = announced
end

local bugEv = CreateFrame("Frame")
pcall(bugEv.RegisterEvent, bugEv, "PLAYER_LOGIN")
bugEv:SetScript("OnEvent", ClearFiledBugs)

-- the report dialog lives in BugReport.lua (one bug window for
-- /goblin bug AND the settings button). StageReport below hex-stages
-- into SavedVariables; it's exported as GM.StageReport and
-- forward-declared here only because its body sits past HexEnc.
local StageReport
local ShowProfDialog

function S.FlagReload()
	S.needReload = true
	if ui then
		ui.reloadBar:Show()
		S.Relayout()
	end
end

-- sections slide down to make room for the reload banner
function S.Relayout()
	if not ui or not ui.barLeaf then return end
	-- the banner is a layout node now — toggling it reflows the
	-- stack and the tooltip panel's fill height absorbs the shift
	ui.barLeaf:SetVisible(S.needReload and true or false)
end

local function Panel(f, x, y, w, h, title)
	local p = W.TitledPanel(f, title)
	p:SetSize(w, h)
	return p
end

local EditBox = W.EditBox

-- On/Off pair of segment buttons; get()→bool, set(b)
local function BoolSeg(parent, get, set)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(76, 18)
	local on = CreateFrame("Button", nil, holder)
	on:SetSize(38, 18)
	on:SetPoint("LEFT")
	GM.Panel(on, "contHigh")
	on.text = GM.MakeFontString(on, GM.FONT_MED, 9, "textDim")
	on.text:SetPoint("CENTER")
	on.text:SetText("On")
	local off = CreateFrame("Button", nil, holder)
	off:SetSize(38, 18)
	off:SetPoint("LEFT", on, "RIGHT", 1, 0)
	GM.Panel(off, "contHigh")
	off.text = GM.MakeFontString(off, GM.FONT_MED, 9, "textDim")
	off.text:SetPoint("CENTER")
	off.text:SetText("Off")
	local function paint()
		local v = get()
		on.text:SetTextColor(GM.RGB(v and "accent" or "textDim"))
		off.text:SetTextColor(GM.RGB(not v and "accent" or "textDim"))
	end
	on:SetScript("OnClick", function() set(true) paint() S.Refresh() end)
	off:SetScript("OnClick", function() set(false) paint() S.Refresh() end)
	holder.paint = paint
	paint()
	return holder
end

-- single button cycling a domain; get()→value
local function CycleBtn(parent, w, get, set, domain, disp)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w or 76, 18)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_MED, 9, "textDim")
	b.text:SetPoint("CENTER")
	local function paint()
		local v = get()
		b.text:SetText(disp and disp[v] or tostring(v))
		b.text:SetTextColor(GM.RGB("text"))
	end
	b:SetScript("OnClick", function()
		local cur = get()
		for i, v in ipairs(domain) do
			if v == cur then
				set(domain[i % #domain + 1])
				paint()
				S.Refresh()
				return
			end
		end
		set(domain[1])
		paint()
		S.Refresh()
	end)
	b.paint = paint
	paint()
	return b
end

local function Row(parent, label, y)
	local fs = GM.MakeFontString(parent, GM.FONT, 10, "text")
	fs:SetPoint("TOPLEFT", 12, -y)
	fs:SetWidth(200)
	fs:SetJustifyH("LEFT")
	fs:SetText(label)
	return fs
end

local function RowAt(parent, label, x, y)
	local fs = GM.MakeFontString(parent, GM.FONT, 10, "text")
	fs:SetPoint("TOPLEFT", x, -y)
	fs:SetWidth(170)
	fs:SetJustifyH("LEFT")
	fs:SetText(label)
	return fs
end

-- ============ profile codec ============

local function Ser(v, buf)
	local t = type(v)
	if t == "number" then
		buf[#buf + 1] = tostring(v)
	elseif t == "string" then
		buf[#buf + 1] = format("%q", v)
	elseif t == "boolean" then
		buf[#buf + 1] = tostring(v)
	elseif t == "table" then
		buf[#buf + 1] = "{"
		for k, x in pairs(v) do
			if type(k) == "string" and k:match("^[%a_][%w_]*$") then
				buf[#buf + 1] = k .. "="
				Ser(x, buf)
			elseif type(k) == "number" then
				buf[#buf + 1] = "[" .. k .. "]="
				Ser(x, buf)
			end
			buf[#buf + 1] = ","
		end
		buf[#buf + 1] = "}"
	end
end

-- hex encode — foolproof, survives any editbox/chat
local function HexEnc(s)
	return (s:gsub(".", function(c) return format("%02x", c:byte()) end))
end
local function HexDec(h)
	if not h or h:find("[^0-9a-fA-F]") or #h % 2 ~= 0 then return nil end
	return (h:gsub("..", function(cc) return strchar(tonumber(cc, 16)) end))
end

local PROFILE_KEYS = {
	"riskBudget", "minProfitMargin", "maxDaysToClear", "dataMaxAge",
	"minimapAngle", "minimapHide", "tooltip",
}

-- stage: build the report body (description + diagnostics), hex it
-- with the profile codec, store "id|hex" so the brain can regex it
-- straight out of the SavedVariables file
function StageReport(desc, title)
	local id = format("gm-%d-%d", time(), math.random(100, 999))
	local _, _, _, build = GetBuildInfo()
	local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata)
		or GetAddOnMetadata
	local ver = getMeta
		and getMeta("GoblinMind", "Version") or "?"
	local body = {
		desc, "", "---", "### diagnostics",
		"- addon: GoblinMind " .. tostring(ver),
		"- client build: " .. tostring(build or "?"),
		"- interface: 16001 (Forever)",
		"- AH book: " .. (GM.AH and GM.AH.BookAge
			and (GM.AH.BookAge() .. "s old") or "none"),
		"- sniper hits: " .. #(GM.Sniper and GM.Sniper.hits or {}),
		"", "recent lua errors:",
	}
	for _, e in ipairs(GM.db.errLog or {}) do
		body[#body + 1] = "- " .. e
	end
	local payload = table.concat(body, "\n")
	title = title and strtrim(title) or strtrim(desc:gsub("\n.*", ""))
	if title == "" then title = "In-game bug report" end
	if #title > 80 then title = title:sub(1, 77) .. "..." end
	GM.db.bugReports = GM.db.bugReports or {}
	GM.db.bugReports[#GM.db.bugReports + 1] =
		id .. "|" .. HexEnc(title .. "\n" .. payload)
	return id
end
GM.StageReport = StageReport

-- stage a backend-onboarding request the same way reports ride the
-- SV — "bm-<ts>-<n>|<hex(url\nname\nscope\nkey)>" — the watcher
-- regexes it out of the file and writes the feeds.json backend
-- block; GoblinMindDB.backend.url + .ack confirm it landed
local function StageBackendReq(url, name, scope, key)
	local id = format("bm-%d-%d", time(), math.random(100, 999))
	GM.db.backendReqs = GM.db.backendReqs or {}
	GM.db.backendReqs[#GM.db.backendReqs + 1] = id .. "|"
		.. HexEnc(url .. "\n" .. name .. "\n" .. scope .. "\n" .. (key or ""))
	return id
end
GM.StageBackendReq = StageBackendReq

-- same staging pattern for the Blizzard API onboarding page —
-- "api-<ts>-<n>|<hex(clientId\nsecret\nregion\nscope)>" → feeds.json
-- 'api' block; GoblinMindDB.api.ack confirms it landed
local function StageApiReq(clientId, secret, region, scope)
	local id = format("api-%d-%d", time(), math.random(100, 999))
	GM.db.apiReqs = GM.db.apiReqs or {}
	GM.db.apiReqs[#GM.db.apiReqs + 1] = id .. "|"
		.. HexEnc((clientId or "") .. "\n" .. (secret or "")
			.. "\n" .. (region or "") .. "\n" .. (scope or ""))
	return id
end
GM.StageApiReq = StageApiReq

-- seconds since the watcher's last emit (nil = never seen). This
-- measures the LOADED snapshot — it grows all session even with a
-- live watcher. "Is the app running" gates use GM.emitAgeAtLogin
-- (captured at ADDON_LOADED in Core.lua); "is my data stale" gates
-- keep this. Callers pick their own threshold.
function GM.EmitAge()
	local gen = GoblinMindDB and GoblinMindDB.generated
	return gen and (time() - gen) or nil
end


local function ExportProfile()
	local t = {}
	for _, k in ipairs(PROFILE_KEYS) do
		if GM.db[k] ~= nil then t[k] = GM.db[k] end
	end
	local buf = {}
	Ser(t, buf)
	return HexEnc(table.concat(buf))
end

local function MergeInto(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" and type(dst[k]) == "table" then
			MergeInto(dst[k], v)
		elseif type(v) == "table" then
			dst[k] = v
		else
			dst[k] = v
		end
	end
end

-- shared import path — panel feedback goes to ui.profMsg when the
-- settings window exists; the dialog also shows inline errors
local ImportProfile -- forward-declared: defined below ApplyImport
local function ApplyImport(str)
	-- snapshot reload-gated values so an import that changes them
	-- surfaces the reload prompt
	local before = {
		embeddedTooltip = GM.db.tooltip and GM.db.tooltip.embeddedTooltip,
		minimapAngle = GM.db.minimapAngle,
	}
	local ok, err = ImportProfile(str)
	if ui and ui.profMsg then
		ui.profMsg:SetText(ok
			and GM.CC("pos") .. "applied — settings live now|r"
			or GM.CC("err") .. (err or "import failed") .. "|r")
	end
	if ok then
		S.Refresh()
		if GM.minimapBtn then
			GM.minimapBtn:SetShown(not GM.db.minimapHide)
		end
		for k, v in pairs(before) do
			local now = k == "embeddedTooltip"
				and GM.db.tooltip and GM.db.tooltip.embeddedTooltip
				or GM.db[k]
			if now ~= v then S.FlagReload() break end
		end
	end
	return ok, err
end

-- profile string dialog — a real multiline box in a modal, not the
-- cramped inline field. mode "export" shows the string (copy out),
-- "import" evaluates the pasted text on IMPORT.
local profD
local function BuildProfDialog()
	if profD then return end
	local d = CreateFrame("Frame", "GoblinMindProfileDialog", UIParent)
	d:SetSize(480, 330)
	d:SetPoint("CENTER", 0, 40)
	d:SetFrameStrata("FULLSCREEN_DIALOG")
	d:SetToplevel(true)
	d:SetMovable(true)
	d:EnableMouse(true)
	d:RegisterForDrag("LeftButton")
	d:SetScript("OnDragStart", d.StartMoving)
	d:SetScript("OnDragStop", d.StopMovingOrSizing)
	GM.Panel(d, "contLow", "outlineVar")
	tinsert(UISpecialFrames, "GoblinMindProfileDialog")
	profD = d

	d.title = GM.MakeFontString(d, GM.FONT_BOLD, 13, "accent")
	d.title:SetPoint("TOPLEFT", 12, -10)

	local eb = CreateFrame("EditBox", nil, d)
	eb:SetPoint("TOPLEFT", 12, -34)
	eb:SetSize(456, 230)
	eb:SetAutoFocus(false)
	eb:SetMultiLine(true)
	eb:SetMaxLetters(0)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(6, 6, 6, 6)
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(GM.RGB("contLowest"))
	eb:SetScript("OnEscapePressed", function() d:Hide() end)
	d.eb = eb

	d.msg = GM.MakeFontString(d, GM.FONT, 9, "textDim")
	d.msg:SetPoint("TOPLEFT", eb, "BOTTOMLEFT", 2, -6)
	d.msg:SetWidth(456)
	d.msg:SetJustifyH("LEFT")

	local ok = CreateFrame("Button", nil, d)
	ok:SetSize(110, 22)
	ok:SetPoint("BOTTOMRIGHT", -12, 10)
	GM.Panel(ok, "accent")
	ok.text = GM.MakeFontString(ok, GM.FONT_BOLD, 10, "contLowest")
	ok.text:SetPoint("CENTER")
	d.ok = ok
	ok:SetScript("OnClick", function()
		if d.mode == "export" then
			d.eb:HighlightText()
			d.eb:SetFocus()
			return
		end
		local good, err = ApplyImport(d.eb:GetText() or "")
		if good then
			d:Hide()
		else
			d.msg:SetText(GM.CC("err")
				.. (err or "import failed") .. "|r")
		end
	end)

	local cancel = CreateFrame("Button", nil, d)
	cancel:SetSize(80, 22)
	cancel:SetPoint("BOTTOMRIGHT", ok, "BOTTOMLEFT", -8, 0)
	GM.Panel(cancel, "contHigh")
	cancel.text = GM.MakeFontString(cancel, GM.FONT_BOLD, 10, "text")
	cancel.text:SetPoint("CENTER")
	cancel.text:SetText("CANCEL")
	cancel:SetScript("OnClick", function() d:Hide() end)
end

ShowProfDialog = function(mode)
	BuildProfDialog()
	local d = profD
	d.mode = mode
	if mode == "export" then
		d.title:SetText("EXPORT PROFILE")
		d.eb:SetText(ExportProfile())
		d.eb:HighlightText()
		d.ok.text:SetText("SELECT ALL")
		d.msg:SetText("Ctrl+C copies — share the whole string")
	else
		d.title:SetText("IMPORT PROFILE")
		d.eb:SetText("")
		d.ok.text:SetText("IMPORT")
		d.msg:SetText("paste a profile string, then IMPORT")
	end
	d:Show()
	d.eb:SetFocus()
end

ImportProfile = function(str)
	local raw = HexDec(str and str:gsub("%s", ""))
	if not raw or raw:sub(1, 1) ~= "{" or raw:find("[%(]") then
		return nil, "not a profile string"
	end
	local fn = loadstring("return " .. raw)
	if not fn then return nil, "corrupt data" end
	local ok, t = pcall(fn)
	if not ok or type(t) ~= "table" then return nil, "corrupt data" end
	for _, k in ipairs(PROFILE_KEYS) do
		if t[k] ~= nil then
			if type(t[k]) == "table" and type(GM.db[k]) == "table" then
				MergeInto(GM.db[k], t[k])
			else
				GM.db[k] = t[k]
			end
		end
	end
	return true
end

-- ============ window ============

-- friendly names for stored enum values (stored keys never change —
-- only the display). "none"→"off" is the tooltip-line sense; the
-- modifier control passes its own map ("none"→"always")
local ENUM_DISP = {
	withTrend = "with trend", noTrend = "price only", none = "off",
	full = "detailed", simple = "short",
}

local LABELS = {
	groupNameTooltip = "Group name",
	destroyTooltipFormat = "Destroy value",
	convertTooltipFormat = "Convert value",
	vendorBuyTooltip = "Vendor buy price",
	vendorSellTooltip = "Vendor sell price",
	inventoryTooltipFormat = "Inventory value",
	minBuyout = "Min buyout",
	marketValueRecent = "Recent market value",
	marketValue = "Market value",
	historical = "Historical price",
	altMinBuyout = "Alt-realm min buyout",
	altMarketValueRecent = "Alt-realm recent",
	altMarketValue = "Alt-realm market",
	altHistorical = "Alt-realm historical",
	regionMarketValue = "Region market value",
	regionHistorical = "Region historical",
	regionSale = "Region sale",
	regionSalePercent = "Region sale rate",
	regionSoldPerDay = "Region sold/day",
	band = "Price band",
	vsTSM = "vs TSM price",
	resetSignal = "Reset signal",
	liveBook = "Live book stats",
	purchase = "Purchase price",
	sale = "Sale price",
	saleRate = "Sale rate",
	expiredAuctions = "Expired auctions",
	cancelledAuctions = "Cancelled auctions",
	postQuantity = "Post quantity",
	operationPrices = "Operation prices",
	craftingCost = "Crafting cost",
	detailedMats = "Detailed mats",
	matPrice = "Material price",
	maxPrice = "Max shopping price",
	belowPrice = "Sniper threshold",
}
local function Label(d)
	-- registry is authoritative (tooltip-ux R1): the same label the
	-- tooltip row shows, so settings and tip can't drift apart
	if d.settingLabel then return d.settingLabel end
	if d.label then return d.label end
	if LABELS[d.key] then return LABELS[d.key] end
	local op = d.key:match("^operationTooltips%.(.+)$")
	if op then return "Ops: " .. op end
	local cs = d.key:match("^customPriceTooltips%.(.+)$")
	if cs then return "Source: " .. cs end
	return d.key
end

local function Build()
	if ui then return end
	ui = { rows = {}, genRows = {} }
	-- name must NOT collide with the GoblinMindSettings SavedVariable —
	-- SVs populate after file load and would overwrite the frame global,
	-- leaving UISpecialFrames pointing at a plain table (IsShown crash)
	local f = GM.Widgets.Window({
		name = "GoblinMindSettingsFrame", title = "SETTINGS",
		w = 620, h = 1100, x = -60, y = 10, tab = "settings",
	})
	ui.frame = f

	-- reload-required banner: appears when a flagged option changes
	local bar = CreateFrame("Frame", nil, f)
	bar:SetSize(600, 24)
	GM.Panel(bar, "contHigh")
	local barEdge = bar:CreateTexture(nil, "ARTWORK")
	barEdge:SetPoint("TOPLEFT")
	barEdge:SetPoint("BOTTOMLEFT")
	barEdge:SetWidth(3)
	barEdge:SetColorTexture(GM.RGB("warn"))
	local barText = GM.MakeFontString(bar, GM.FONT, 10, "warn")
	barText:SetPoint("LEFT", 12, 0)
	barText:SetText("changes need a UI reload to fully apply")
	local rl = CreateFrame("Button", nil, bar)
	rl:SetSize(92, 18)
	rl:SetPoint("RIGHT", -4, 0)
	GM.Panel(rl, "accent")
	rl.text = GM.MakeFontString(rl, GM.FONT_BOLD, 10, "contLowest")
	rl.text:SetPoint("CENTER")
	rl.text:SetText("RELOAD UI")
	rl:SetScript("OnClick", function() ReloadUI() end)
	bar:Hide()
	ui.reloadBar = bar
	if S.needReload then bar:Show() end

	-- ===== GENERAL =====
	local gen = Panel(f, 10, -34, 600, 128, "GENERAL")
	ui.gen = gen
	Row(gen, "Risk budget (% of gold)", 26)
	ui.risk = EditBox(gen, 72)
	ui.risk:SetPoint("TOPLEFT", 240, -22)
	ui.risk:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then GM.db.riskBudget = max(0, min(1, v / 100)) end
		self:ClearFocus()
		S.Refresh()
	end)
	Row(gen, "Min profit margin (%)", 50)
	ui.margin = EditBox(gen, 72)
	ui.margin:SetPoint("TOPLEFT", 240, -46)
	ui.margin:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then GM.db.minProfitMargin = max(0, v / 100) end
		self:ClearFocus()
		S.Refresh()
	end)
	Row(gen, "Max days to clear", 74)
	ui.days = EditBox(gen, 72)
	ui.days:SetPoint("TOPLEFT", 240, -70)
	ui.days:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then GM.db.maxDaysToClear = max(1, floor(v)) end
		self:ClearFocus()
		S.Refresh()
	end)
	Row(gen, "Data stale after (sec)", 98)
	ui.age = EditBox(gen, 72)
	ui.age:SetPoint("TOPLEFT", 240, -94)
	ui.age:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then GM.db.dataMaxAge = max(60, floor(v)) end
		self:ClearFocus()
		S.Refresh()
	end)

	RowAt(gen, "Minimap button", 320, 26)
	ui.mmHide = BoolSeg(gen,
		function() return not GM.db.minimapHide end,
		function(v)
			GM.db.minimapHide = not v
			if GM.minimapBtn then GM.minimapBtn:SetShown(v) end
		end)
	ui.mmHide:SetPoint("TOPLEFT", 500, -24)
	RowAt(gen, "Show beside tooltip", 320, 50)
	ui.embed = BoolSeg(gen,
		-- the stored flag is INVERTED (embeddedTooltip=true embeds
		-- into the native tip); the checkbox reads as "side panel"
		function() return not (GM.db.tooltip and GM.db.tooltip.embeddedTooltip) end,
		function(v) GM.Tooltip.SetOption("embeddedTooltip", nil, not v) end)
	ui.embed:SetPoint("TOPLEFT", 500, -48)
	RowAt(gen, "Show on modifier", 320, 74)
	ui.mod = CycleBtn(gen, 76,
		function() return (GM.db.tooltip and GM.db.tooltip.tooltipShowModifier) or "none" end,
		function(v) GM.Tooltip.SetOption("tooltipShowModifier", nil, v) end,
		{ "none", "alt", "ctrl" },
		{ none = "always", alt = "hold Alt", ctrl = "hold Ctrl" })
	ui.mod:SetPoint("TOPLEFT", 500, -72)
	RowAt(gen, "Price format", 320, 98)
	ui.fmt = CycleBtn(gen, 76,
		function() return (GM.db.tooltip and GM.db.tooltip.tooltipPriceFormat) or "text" end,
		function(v) GM.Tooltip.SetOption("tooltipPriceFormat", nil, v) end,
		{ "text", "icon" }, { text = "text", icon = "coin icons" })
	ui.fmt:SetPoint("TOPLEFT", 500, -96)

	-- ===== TOOLTIP LINES =====
	local tt = Panel(f, 10, -168, 600, 256, "TOOLTIP LINES")
	ui.ttPanel = tt
	-- preset sits with the grid it presets; display is derived —
	-- any hand-toggled row reads "Custom"
	local dl = GM.MakeFontString(tt, GM.FONT, 9, "textDim")
	dl:SetPoint("TOPRIGHT", -96, -4)
	dl:SetText("Tooltip detail")
	ui.detail = CycleBtn(tt, 84,
		function() return GM.Tooltip.CurrentPreset() end,
		function(v) GM.Tooltip.ApplyPreset(v) end,
		{ "simple", "trader", "everything" },
		{ simple = "Simple", trader = "Trader",
		  everything = "Everything", custom = "Custom" })
	ui.detail:SetPoint("TOPRIGHT", -8, -2)
	-- clip host + sliding inner so extra rows scroll instead of
	-- spilling past the panel edge
	local ttScroll = CreateFrame("Frame", nil, tt)
	ttScroll:SetPoint("TOPLEFT", 4, -18)
	ttScroll:SetSize(592, 234)
	if ttScroll.SetClipsChildren then ttScroll:SetClipsChildren(true) end
	ui.ttScroll = ttScroll
	ui.ttInner = CreateFrame("Frame", nil, ttScroll)
	ui.ttInner:SetPoint("TOPLEFT")
	ui.ttInner:SetSize(592, 1000)
	ui.ttOff = 0
	ui.ttInnerH = 234
	local function Wheel(_, d)
		local clipH = ui.ttScroll:GetHeight()
		local maxOff = math.max(0, ui.ttInnerH - clipH)
		ui.ttOff = math.max(0, math.min(maxOff, ui.ttOff - d * 36))
		ui.ttInner:SetPoint("TOPLEFT", 0, ui.ttOff)
	end
	tt:EnableMouseWheel(true)
	tt:SetScript("OnMouseWheel", Wheel)
	ttScroll:EnableMouseWheel(true)
	ttScroll:SetScript("OnMouseWheel", Wheel)
	ui.ttHost = ui.ttInner

	-- ===== PROFILE =====
	local prof = Panel(f, 10, -432, 600, 118, "PROFILE · EXPORT / IMPORT")
	local expBtn = CreateFrame("Button", nil, prof)
	expBtn:SetSize(90, 22)
	expBtn:SetPoint("TOPLEFT", 12, -24)
	GM.Panel(expBtn, "accent")
	expBtn.text = GM.MakeFontString(expBtn, GM.FONT_BOLD, 10, "contLowest")
	expBtn.text:SetPoint("CENTER")
	expBtn.text:SetText("EXPORT")
	expBtn:SetScript("OnClick", function()
		ShowProfDialog("export")
	end)
	local impBtn = CreateFrame("Button", nil, prof)
	impBtn:SetSize(90, 22)
	impBtn:SetPoint("TOPLEFT", expBtn, "BOTTOMLEFT", 0, -8)
	GM.Panel(impBtn, "contHigh")
	impBtn.text = GM.MakeFontString(impBtn, GM.FONT_BOLD, 10, "text")
	impBtn.text:SetPoint("CENTER")
	impBtn.text:SetText("IMPORT")
	ui.profMsg = GM.MakeFontString(prof, GM.FONT, 9, "textDim")
	ui.profMsg:SetPoint("TOPLEFT", impBtn, "TOPRIGHT", 10, -6)
	ui.profMsg:SetWidth(180)
	ui.profMsg:SetJustifyH("LEFT")
	impBtn:SetScript("OnClick", function()
		ShowProfDialog("import")
	end)
	local hint = GM.MakeFontString(prof, GM.FONT, 9, "secondary")
	hint:SetPoint("BOTTOMLEFT", 12, 6)
	hint:SetText("export → opens the string · import → paste in the dialog")

	local bug = CreateFrame("Button", nil, prof)
	bug:SetSize(110, 22)
	bug:SetPoint("BOTTOMRIGHT", -12, 6)
	GM.Panel(bug, "contHigh")
	bug.text = GM.MakeFontString(bug, GM.FONT_BOLD, 10, "accent")
	bug.text:SetPoint("CENTER")
	bug.text:SetText("BUG REPORT")
	bug:SetScript("OnClick", function()
		if GM.BugReport then GM.BugReport.Show() end
	end)

	-- ===== CUSTOM PRICE SOURCES =====
	-- GUI for what used to be slash-only (/goblin price set/unset):
	-- name + expression rows into GoblinMindPrices.customSources,
	-- validated through the real parser on add
	local src = Panel(f, 10, -556, 600, 148, "CUSTOM PRICE SOURCES")
	ui.srcName = EditBox(src, 110)
	ui.srcName:SetPoint("TOPLEFT", 12, -26)
	ui.srcExpr = EditBox(src, 300)
	ui.srcExpr:SetPoint("TOPLEFT", ui.srcName, "TOPRIGHT", 6, 0)
	local addBtn = CreateFrame("Button", nil, src)
	addBtn:SetSize(46, 20)
	addBtn:SetPoint("TOPLEFT", ui.srcExpr, "TOPRIGHT", 6, 0)
	GM.Panel(addBtn, "contHigh")
	addBtn.text = GM.MakeFontString(addBtn, GM.FONT_BOLD, 9, "accent")
	addBtn.text:SetPoint("CENTER")
	addBtn.text:SetText("ADD")
	ui.srcMsg = GM.MakeFontString(src, GM.FONT, 9, "textDim")
	ui.srcMsg:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
	ui.srcMsg:SetWidth(100)
	ui.srcMsg:SetJustifyH("LEFT")
	ui.srcMsg:SetWordWrap(false)
	local function AddSource()
		local name = strtrim(ui.srcName:GetText() or ""):lower()
		local expr = strtrim(ui.srcExpr:GetText() or "")
		if not name:match("^[%w]+$") then
			ui.srcMsg:SetText(GM.CC("warn") .. "name = letters/digits only|r")
			return
		end
		if expr == "" then
			ui.srcMsg:SetText(GM.CC("warn") .. "expression required|r")
			return
		end
		-- parse before storing: a syntax error lands here, not
		-- silently in every op field that later names it
		local _, err = GM.Pricing.Eval(expr, GM.PlanQueue.itemID)
		if err and err ~= "empty" then
			ui.srcMsg:SetText(GM.CC("err") .. tostring(err) .. "|r")
			return
		end
		GoblinMindPrices.customSources[name] = expr
		ui.srcName:SetText("")
		ui.srcExpr:SetText("")
		ui.srcMsg:SetText(GM.CC("pos") .. "saved|r")
		S.Refresh()
	end
	addBtn:SetScript("OnClick", AddSource)
	ui.srcExpr:SetScript("OnEnterPressed", AddSource)
	-- pooled list rows — name · expression · DEL, sorted
	ui.srcRows = {}
	for i = 1, 5 do
		local row = CreateFrame("Frame", nil, src)
		row:SetSize(576, 18)
		row:SetPoint("TOPLEFT", 12, -52 - (i - 1) * 18)
		row.n = GM.MakeFontString(row, GM.FONT_MED, 10, "accent")
		row.n:SetPoint("LEFT")
		row.n:SetWidth(110)
		row.n:SetJustifyH("LEFT")
		row.e = GM.MakeFontString(row, GM.FONT, 9, "text")
		row.e:SetPoint("LEFT", 118, 0)
		row.e:SetWidth(398)
		row.e:SetJustifyH("LEFT")
		row.e:SetWordWrap(false)
		local del = CreateFrame("Button", nil, row)
		del:SetSize(30, 14)
		del:SetPoint("RIGHT")
		GM.Panel(del, "contHigh")
		del.text = GM.MakeFontString(del, GM.FONT_BOLD, 8, "err")
		del.text:SetPoint("CENTER")
		del.text:SetText("DEL")
		row.del = del
		ui.srcRows[i] = row
	end
	local hint = GM.MakeFontString(src, GM.FONT, 9, "secondary")
	hint:SetPoint("BOTTOMLEFT", 12, 6)
	hint:SetText("usable in any op price field · builtins can't be "
		.. "shadowed · >5 manage via /goblin price set")

	-- ===== GATHERING =====
	-- the same layer toggles the gather window's MINIMAP: dropdown
	-- owns; both write GoblinMindGather.mm through
	-- GatherMinimap.Set so they can't disagree
	local gt = Panel(f, 10, -710, 600, 78, "GATHERING · MINIMAP LAYERS")
	ui.mmLayers = {}
	if GM.GatherMinimap then
		for i, k in ipairs(GM.GatherMinimap.Layers()) do
			local col, r = (i - 1) % 4, floor((i - 1) / 4)
			RowAt(gt, GM.GatherMinimap.LABEL[k] or k,
				12 + col * 148, 26 + r * 24)
			local seg = BoolSeg(gt,
				function() return GM.GatherMinimap.Enabled(k) end,
				function(v) GM.GatherMinimap.Set(k, v) end)
			seg:SetPoint("TOPLEFT", 12 + col * 148 + 64, -24 - r * 24)
			ui.mmLayers[i] = seg
		end
	end

	-- world-map overlay: master opacity + per-farm-type fill
	-- colors. Same mm table the layer toggles write — colors flow
	-- through G.KindCol so rows, labels, discs, and blobs all
	-- honor a pick
	local ov = Panel(f, 10, -794, 600, 142, "GATHERING · MAP OVERLAY")
	if GM.GatherMinimap and GM.Gather then
		-- three opacity channels: zone blobs/borders, farm icons
		-- + labels, node spawn clusters — settings persist
		-- separately
		local steps = { 0.25, 0.5, 0.75, 1 }
		local function segRow(label, y, get, set)
			RowAt(ov, label, 12, y)
			local segs = {}
			local function paint()
				local cur = get()
				for i, s in ipairs(steps) do
					W.PaintSeg(segs[i],
						math.abs(cur - s) < 0.01)
				end
			end
			for i, s in ipairs(steps) do
				local seg = W.Segment(ov,
					format("%d%%", s * 100), 52, 18)
				seg:SetPoint("TOPLEFT",
					116 + (i - 1) * 56, -(y - 2))
				seg:SetScript("OnClick", function()
					set(s) paint()
				end)
				segs[i] = seg
			end
			paint()
			return segs
		end
		ui.ovSegsZ = segRow("ZONES", 26,
			GM.GatherMinimap.AlphaZone,
			GM.GatherMinimap.SetAlphaZone)
		ui.ovSegsN = segRow("NODES", 50,
			GM.GatherMinimap.AlphaNode,
			GM.GatherMinimap.SetAlphaNode)
		ui.ovSegsI = segRow("ICONS", 74,
			GM.GatherMinimap.AlphaIcon,
			GM.GatherMinimap.SetAlphaIcon)

		RowAt(ov, "FILL COLORS", 12, 104)
		ui.ovSwatch = {}
		-- click = pick; right-click = back to the builtin color.
		-- Swatch list = the kind registry — new kinds appear
		-- automatically (spacing tightens past 6 so they fit)
		local kinds = GM.Gather.KINDS
		local function paintSwatch(k)
			local c = GM.Gather.KindCol(k)
			ui.ovSwatch[k]._gmBg:SetColorTexture(
				c[1], c[2], c[3])
		end
		local function pick(k)
			local cur = GM.Gather.KindCol(k)
			local function apply(r, g, b)
				GM.GatherMinimap.SetColor(k, r, g, b)
				paintSwatch(k)
			end
			local CPF = ColorPickerFrame
			if not CPF then return end
			if CPF.SetupColorPickerAndShow then
				CPF:SetupColorPickerAndShow({
					r = cur[1], g = cur[2], b = cur[3],
					swatchFunc = function()
						apply(CPF:GetColorRGB())
					end,
					cancelFunc = function(prev)
						apply(prev.r, prev.g, prev.b)
					end,
				})
			else
				CPF.func = function()
					apply(CPF:GetColorRGB())
				end
				CPF.cancelFunc = function(prev)
					apply(prev.r, prev.g, prev.b)
				end
				CPF.previousValues = {
					r = cur[1], g = cur[2], b = cur[3],
				}
				CPF:SetColorRGB(cur[1], cur[2], cur[3])
				CPF:Show()
			end
		end
		local pitch = #kinds > 6 and floor(470 / #kinds) or 82
		for i, k in ipairs(kinds) do
			local x = 116 + (i - 1) * pitch
			local sw = CreateFrame("Button", nil, ov)
			sw:SetSize(16, 16)
			sw:SetPoint("TOPLEFT", x, -102)
			GM.Panel(sw, "contHigh")
			sw:RegisterForClicks("LeftButtonUp",
				"RightButtonUp")
			sw:SetScript("OnClick", function(_, btn)
				if btn == "RightButton" then
					GM.GatherMinimap.SetColor(k)
					paintSwatch(k)
				else pick(k) end
			end)
			W.Tip(sw, function()
				return {
					(GM.Gather.KindLabel(k)) .. " fill",
					"click = pick a color",
					"right-click = default",
				}
			end)
			local lbl = GM.MakeFontString(ov, GM.FONT, 9,
				"textDim")
			lbl:SetPoint("TOPLEFT", x + 20, -106)
			lbl:SetText(GM.Gather.KindLabel(k))
			ui.ovSwatch[k] = sw
			paintSwatch(k)
		end
	end

	-- ===== IMPORT FROM OTHER ADDONS =====
	-- entry point to the shared importer (GM.Import.Mount — the same
	-- row list the onboarding wizard shows). Panel itself only
	-- reports what detection sees; the window does the work
	-- ===== TICKER =====
	local tk = Panel(f, 10, -942, 600, 88, "TICKER TAPE")
	local function tkStore() return GM.Ticker.Opts() end
	Row(tk, "Width (px — blank = auto)", 22)
	ui.tkW = EditBox(tk, 72)
	ui.tkW:SetPoint("TOPLEFT", 240, -20)
	ui.tkW:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		GM.Ticker.SetDims(v or 0, nil)
		self:ClearFocus()
		S.Refresh()
	end)
	Row(tk, "Height (px)", 46)
	ui.tkH = EditBox(tk, 72)
	ui.tkH:SetPoint("TOPLEFT", 240, -44)
	ui.tkH:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		GM.Ticker.SetDims(nil, v or 0)
		self:ClearFocus()
		S.Refresh()
	end)
	Row(tk, "Font size (px)", 70)
	ui.tkF = EditBox(tk, 72)
	ui.tkF:SetPoint("TOPLEFT", 240, -68)
	ui.tkF:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		GM.Ticker.SetFontSize(v or 0)
		self:ClearFocus()
		S.Refresh()
	end)
	RowAt(tk, "Locked (no drag)", 320, 22)
	ui.tkLock = BoolSeg(tk,
		function() return tkStore().locked end,
		function(v) tkStore().locked = v end)
	ui.tkLock:SetPoint("TOPLEFT", 500, -20)
	RowAt(tk, "Click-through", 320, 46)
	ui.tkClick = BoolSeg(tk,
		function() return tkStore().click end,
		function(v)
			tkStore().click = v
			GM.Ticker.Apply()
		end)
	ui.tkClick:SetPoint("TOPLEFT", 500, -44)

	-- ===== CHARACTERS · LEDGER =====
	-- one row per char the budget registry knows: crest + name in
	-- the char's ledger color, a swatch to pick a custom color,
	-- right-click returns to class color. The ledger's account
	-- rows and gold strip read B.CharCC, so a pick repaints both.
	ui.charRows = {}
	local cks = GM.Budget and GM.Budget.CharsOrdered
		and GM.Budget.CharsOrdered() or {}
	local cpH = 30 + math.max(1, #cks) * 22
	local cp = Panel(f, 10, -1036, 600, cpH, "CHARACTERS · LEDGER")
	local function paintCharRow(r)
		r.name:SetText(GM.Budget.Crest(r.ck)
			.. GM.Budget.CharCC(r.ck) .. GM.Budget.CharName(r.ck)
			.. "|r")
		local cr, cg, cb = GM.Budget.CharRGB(r.ck)
		r.sw._gmBg:SetColorTexture(cr, cg, cb)
		r.mode:SetText(GM.Budget.CharColorMode(r.ck) == "custom"
			and "CUSTOM" or "CLASS")
	end
	local function pickCharColor(r)
		local cr, cg, cb = GM.Budget.CharRGB(r.ck)
		local function apply(rr, gg, bb)
			GM.Budget.SetCharColor(r.ck, format("%02x%02x%02x",
				floor(rr * 255 + 0.5), floor(gg * 255 + 0.5),
				floor(bb * 255 + 0.5)))
			paintCharRow(r)
			if GM.Overview and GM.Overview.Refresh then
				pcall(GM.Overview.Refresh)
			end
		end
		local CPF = ColorPickerFrame
		if not CPF then return end
		if CPF.SetupColorPickerAndShow then
			CPF:SetupColorPickerAndShow({
				r = cr, g = cg, b = cb,
				swatchFunc = function() apply(CPF:GetColorRGB()) end,
				cancelFunc = function(prev)
					apply(prev.r, prev.g, prev.b)
				end,
			})
		else
			CPF.func = function() apply(CPF:GetColorRGB()) end
			CPF.cancelFunc = function(prev)
				apply(prev.r, prev.g, prev.b)
			end
			CPF.previousValues = { r = cr, g = cg, b = cb }
			CPF:SetColorRGB(cr, cg, cb)
			CPF:Show()
		end
	end
	for i, ck in ipairs(cks) do
		local r = { ck = ck }
		r.name = GM.MakeFontString(cp, GM.FONT, 10, "text")
		r.name:SetPoint("TOPLEFT", 14, -20 - (i - 1) * 22)
		r.name:SetWidth(220)
		r.name:SetJustifyH("LEFT")
		r.name:SetWordWrap(false)
		r.sw = CreateFrame("Button", nil, cp)
		r.sw:SetSize(16, 16)
		r.sw:SetPoint("TOPLEFT", 244, -22 - (i - 1) * 22)
		GM.Panel(r.sw, "contHigh")
		r.sw:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		r.sw:SetScript("OnClick", function(_, btn)
			if btn == "RightButton" then
				GM.Budget.SetCharColor(r.ck)
				paintCharRow(r)
				if GM.Overview and GM.Overview.Refresh then
					pcall(GM.Overview.Refresh)
				end
			else
				pickCharColor(r)
			end
		end)
		W.Tip(r.sw, function() return {
			"Ledger color for " .. GM.Budget.CharName(ck),
			"click = pick a custom color",
			"right-click = class color" } end)
		r.mode = GM.MakeFontString(cp, GM.FONT, 9, "textDim")
		r.mode:SetPoint("LEFT", r.sw, "RIGHT", 8, 0)
		r.mode:SetJustifyH("LEFT")
		ui.charRows[i] = r
		paintCharRow(r)
	end
	ui.paintCharRow = paintCharRow

	local imp = Panel(f, 10, -1036, 600, 60,
		"IMPORT FROM OTHER ADDONS")
	ui.impScan = CreateFrame("Button", nil, imp)
	ui.impScan:SetSize(110, 22)
	ui.impScan:SetPoint("TOPLEFT", 12, -24)
	GM.Panel(ui.impScan, "accent")
	ui.impScan.text = GM.MakeFontString(ui.impScan, GM.FONT_BOLD,
		10, "contLowest")
	ui.impScan.text:SetPoint("CENTER")
	ui.impScan.text:SetText("OPEN IMPORTER")
	ui.impScan:SetScript("OnClick", function()
		if GM.Import then GM.Import.Show() end
	end)
	ui.impCount = GM.MakeFontString(imp, GM.FONT, 9, "textDim")
	ui.impCount:SetPoint("TOPLEFT", ui.impScan, "TOPRIGHT", 10, -6)
	ui.impCount:SetWidth(300)
	ui.impCount:SetJustifyH("LEFT")
	local hint = GM.MakeFontString(imp, GM.FONT, 9, "secondary")
	hint:SetPoint("BOTTOMLEFT", 12, 6)
	hint:SetText("TSM groups/ops/searches · GatherLite nodes "
		.. "· merges into your setup, never deletes")

	-- ============ layout wiring ============
	-- the window is a vertical stack of titled panels — one managed
	-- Column owns their slots; the reload banner is a toggleable
	-- node and the tooltip panel fills whatever height remains
	local u = GM.ui
	local root = u:AttachRoot(f, {
		direction = "column", gap = 6,
		pad = { top = 34, right = 10, bottom = 4, left = 10 },
	})
	ui.barLeaf = root:Add(u:Adopt(bar, { width = 600, height = 24 }),
		{ height = 24 })
	ui.barLeaf:SetVisible(S.needReload and true or false)
	local function StackPanel(p, h)
		root:Add(u:Adopt(p, { width = 600, height = h }), { height = h })
	end
	StackPanel(gen, 128)
	root:Add(u:Adopt(tt, { width = 600, height = 256 }),
		{ height = "fill", minHeight = 60 })
	StackPanel(prof, 118)
	StackPanel(src, 148)
	StackPanel(gt, 78)
	StackPanel(ov, 142)
	StackPanel(tk, 88)
	StackPanel(cp, cpH)
	StackPanel(imp, 60)
	-- the tooltip panel's height is layout-owned now — keep the clip
	-- viewport tracking it (Relayout used to resize it by hand)
	tt:HookScript("OnSizeChanged", function(_, _, th)
		ttScroll:SetHeight(math.max(40, th - 22))
	end)

	S.Relayout()
end

-- tooltip-line control rows are built once from the registry —
-- deduped entries in REGISTRY order with visible group headings
-- (R7): sorting alphabetically scattered related rows across
-- columns. Single column because headings can't span two.
local function BuildTooltipRows()
	if ui.ttRows then return end
	ui.ttRows = {}
	local opts = GM.Tooltip.OptionEntries()
	local rowH, y = 18, -24
	local lastHead
	for _, d in ipairs(opts) do
		if not d.hidden then
			if d.heading ~= lastHead then
				lastHead = d.heading
				if y < -24 then y = y - 6 end -- air above later groups
				local h = GM.MakeFontString(ui.ttHost,
					GM.FONT_BOLD, 9, "accent")
				h:SetPoint("TOPLEFT", 12, y)
				h:SetText(strupper(d.heading or ""))
				y = y - 16
			end
			local fs = GM.MakeFontString(ui.ttHost, GM.FONT, 9, "text")
			fs:SetPoint("TOPLEFT", 24, y)
			fs:SetWidth(440)
			fs:SetJustifyH("LEFT")
			fs:SetText(Label(d))
			-- invisible hover surface over the label — the ONLY place
			-- the entry's gloss can live (F10): GameTooltip on hover
			local hov = CreateFrame("Button", nil, ui.ttHost)
			hov:SetPoint("TOPLEFT", 20, y + 4)
			hov:SetSize(468, rowH)
			hov.d = d
			hov:SetScript("OnEnter", function(self)
				local dd = self.d
				if not dd.gloss then return end
				GM.Widgets.HintShow(self, { Label(dd), dd.gloss })
			end)
			hov:SetScript("OnLeave", GM.Widgets.HintHide)
			local ctl
			if d.kind == "bool" then
				ctl = BoolSeg(ui.ttHost, d.get, d.set)
			else
				ctl = CycleBtn(ui.ttHost, 84, d.get, d.set,
					d.domain, ENUM_DISP)
			end
			ctl:SetPoint("TOPLEFT", 496, y)
			tinsert(ui.ttRows, { d = d, ctl = ctl })
			y = y - rowH
		end
	end
	ui.ttInnerH = math.max(234, -y + 10)
end

function S.Refresh()
	if not ui then return end
	ui.risk:SetText(tostring(floor((GM.db.riskBudget or 0) * 100 + 0.5)))
	ui.margin:SetText(tostring(floor((GM.db.minProfitMargin or 0) * 100 + 0.5)))
	ui.days:SetText(tostring(GM.db.maxDaysToClear or ""))
	ui.age:SetText(tostring(GM.db.dataMaxAge or ""))
	ui.mmHide.paint()
	ui.embed.paint()
	ui.mod.paint()
	if ui.mmLayers then
		for _, seg in ipairs(ui.mmLayers) do seg.paint() end
	end
	ui.fmt.paint()
	if ui.detail then ui.detail.paint() end
	if ui.tkW then
		local st = GM.Ticker.Opts()
		ui.tkW:SetText(tostring(st.w or GM.Ticker.DEF_W))
		ui.tkH:SetText(tostring(st.h or GM.Ticker.DEF_H))
		ui.tkF:SetText(tostring(st.fs or GM.Ticker.DEF_FS))
		ui.tkLock.paint()
		ui.tkClick.paint()
	end
	for _, r in ipairs(ui.ttRows or {}) do
		if r.ctl.paint then r.ctl.paint() end
	end
	if ui.charRows and ui.paintCharRow then
		for _, r in ipairs(ui.charRows) do ui.paintCharRow(r) end
	end
	-- custom price source rows
	if ui.srcRows then
		local names = {}
		for n in pairs((GoblinMindPrices
			and GoblinMindPrices.customSources) or {}) do
			names[#names + 1] = n
		end
		sort(names)
		local cs = GoblinMindPrices.customSources
		for i, row in ipairs(ui.srcRows) do
			local n = names[i]
			if n then
				row:Show()
				row.n:SetText(n)
				row.e:SetText(cs[n])
				local key = n
				row.del:SetScript("OnClick", function()
					GoblinMindPrices.customSources[key] = nil
					S.Refresh()
				end)
			else
				row:Hide()
			end
		end
	end
	-- addon-import detection count — cheap scan, same Detect() the
	-- importer window runs so the numbers always agree
	if ui.impCount and GM.Import then
		local items = GM.Import.Detect()
		local pending = 0
		for _, it in ipairs(items) do
			if not it.done then pending = pending + 1 end
		end
		ui.impCount:SetText(#items == 0
			and "no compatible addon data found"
			or format("%d importable item%s (%d pending)",
				#items, #items == 1 and "" or "s", pending))
	end
end

function S.Show()
	Build()
	BuildTooltipRows()
	S.Refresh()
	ui.frame:Show()
end

function S.Hide()
	if ui and ui.frame then ui.frame:Hide() end
end

function S.Toggle()
	Build()
	if ui.frame:IsShown() then ui.frame:Hide() else S.Show() end
end
