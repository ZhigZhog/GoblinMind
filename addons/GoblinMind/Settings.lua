local _, GM = ...

-- Part 12: in-game settings. GENERAL edits the scalar GM.db keys;
-- TOOLTIP LINES is generated from the tooltip module's option
-- registry (deduped entries, bool = On/Off, enum = click-to-cycle);
-- PROFILE exports/imports settings as a paste-able hex string.

GM.Settings = {}
local S = GM.Settings
local ui

-- options that only take effect at load — toggling them queues a
-- "reload required" prompt rather than pretending they're live
local RELOAD_KEYS = { embeddedTooltip = true, minimapAngle = true }

function S.FlagReload()
	S.needReload = true
	if ui then
		ui.reloadBar:Show()
		S.Relayout()
	end
end

-- sections slide down to make room for the reload banner
function S.Relayout()
	if not ui then return end
	local genY = S.needReload and 62 or 34
	ui.gen:SetPoint("TOPLEFT", 10, -genY)
	local ttY = genY + 128 + 6
	ui.ttPanel:SetPoint("TOPLEFT", 10, -ttY)
	ui.ttPanel:SetHeight(428 - ttY)
	ui.ttScroll:SetHeight(428 - ttY - 22)
end

local function Panel(f, x, y, w, h, title)
	local p = CreateFrame("Frame", nil, f)
	p:SetSize(w, h)
	p:SetPoint("TOPLEFT", x, y)
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(title)
	return p
end

local function EditBox(parent, w)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, 20)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(5, 4, 0, 0)
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(GM.RGB("contLowest"))
	eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
	return eb
end

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
local function CycleBtn(parent, w, get, set, domain)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w or 76, 18)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_MED, 9, "textDim")
	b.text:SetPoint("CENTER")
	local function paint()
		b.text:SetText(tostring(get()))
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

local function ImportProfile(str)
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
	local f = CreateFrame("Frame", "GoblinMindSettings", UIParent)
	f:SetSize(620, 560)
	f:SetPoint("CENTER", -60, 10)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:Hide()
	GM.Panel(f, "contLow", "outlineVar")
	ui.frame = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("SETTINGS")
	if GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, title, "settings")
	end

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	-- reload-required banner: appears when a flagged option changes
	local bar = CreateFrame("Frame", nil, f)
	bar:SetSize(600, 24)
	bar:SetPoint("TOPLEFT", 10, -32)
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
	ui.risk = EditBox(gen, 56)
	ui.risk:SetPoint("TOPLEFT", 240, -22)
	ui.risk:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then GM.db.riskBudget = max(0, min(1, v / 100)) end
		self:ClearFocus()
		S.Refresh()
	end)
	Row(gen, "Min profit margin (%)", 50)
	ui.margin = EditBox(gen, 56)
	ui.margin:SetPoint("TOPLEFT", 240, -46)
	ui.margin:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then GM.db.minProfitMargin = max(0, v / 100) end
		self:ClearFocus()
		S.Refresh()
	end)
	Row(gen, "Max days to clear", 74)
	ui.days = EditBox(gen, 56)
	ui.days:SetPoint("TOPLEFT", 240, -70)
	ui.days:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then GM.db.maxDaysToClear = max(1, floor(v)) end
		self:ClearFocus()
		S.Refresh()
	end)
	Row(gen, "Data stale after (sec)", 98)
	ui.age = EditBox(gen, 56)
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
	RowAt(gen, "Tooltip side panel", 320, 50)
	ui.embed = BoolSeg(gen,
		function() return GM.db.tooltip and GM.db.tooltip.embeddedTooltip or false end,
		function(v)
			GM.Tooltip.SetOption("embeddedTooltip", nil, v)
			S.FlagReload()
		end)
	ui.embed:SetPoint("TOPLEFT", 500, -48)
	RowAt(gen, "Show on modifier", 320, 74)
	ui.mod = CycleBtn(gen, 76,
		function() return (GM.db.tooltip and GM.db.tooltip.tooltipShowModifier) or "none" end,
		function(v) GM.Tooltip.SetOption("tooltipShowModifier", nil, v) end,
		{ "none", "alt", "ctrl" })
	ui.mod:SetPoint("TOPLEFT", 500, -72)
	RowAt(gen, "Price format", 320, 98)
	ui.fmt = CycleBtn(gen, 76,
		function() return (GM.db.tooltip and GM.db.tooltip.tooltipPriceFormat) or "text" end,
		function(v) GM.Tooltip.SetOption("tooltipPriceFormat", nil, v) end,
		{ "text", "icon" })
	ui.fmt:SetPoint("TOPLEFT", 500, -96)

	-- ===== TOOLTIP LINES =====
	local tt = Panel(f, 10, -168, 600, 256, "TOOLTIP LINES")
	ui.ttPanel = tt
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
	ui.profBox = EditBox(prof, 400)
	ui.profBox:SetPoint("TOPLEFT", 12, -54)
	ui.profBox:SetMultiLine(true)
	ui.profBox:SetMaxLetters(0)
	ui.profBox:SetHeight(52)
	expBtn:SetScript("OnClick", function()
		ui.profBox:SetText(ExportProfile())
		ui.profBox:HighlightText()
		ui.profBox:SetFocus()
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
		-- snapshot reload-gated values so an import that changes them
		-- surfaces the reload prompt
		local before = {
			embeddedTooltip = GM.db.tooltip and GM.db.tooltip.embeddedTooltip,
			minimapAngle = GM.db.minimapAngle,
		}
		local ok, err = ImportProfile(ui.profBox:GetText())
		ui.profMsg:SetText(ok
			and GM.CC("pos") .. "applied — settings live now|r"
			or GM.CC("err") .. (err or "import failed") .. "|r")
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
	end)
	local hint = GM.MakeFontString(prof, GM.FONT, 9, "secondary")
	hint:SetPoint("BOTTOMLEFT", 12, 6)
	hint:SetText("export → copy the string · import → paste + IMPORT")

	S.Relayout()
end

-- tooltip-line control rows are built once from the registry —
-- deduped entries, two columns
local function BuildTooltipRows()
	if ui.ttRows then return end
	ui.ttRows = {}
	local opts = GM.Tooltip.OptionEntries()
	sort(opts, function(a, b)
		if (a.heading or "") ~= (b.heading or "") then
			return (a.heading or "") < (b.heading or "")
		end
		return Label(a) < Label(b)
	end)
	local colW, rowH, top = 290, 18, 24
	for i, d in ipairs(opts) do
		local col = i <= ceil(#opts / 2) and 0 or 1
		local ri = col == 0 and i or i - ceil(#opts / 2)
		local x = 6 + col * colW
		local y = -top - (ri - 1) * rowH
		local fs = GM.MakeFontString(ui.ttHost, GM.FONT, 9, "text")
		fs:SetPoint("TOPLEFT", x + 6, y)
		fs:SetWidth(colW - 90)
		fs:SetJustifyH("LEFT")
		fs:SetText(Label(d))
		local ctl
		if d.kind == "bool" then
			ctl = BoolSeg(ui.ttHost, d.get, d.set)
		else
			ctl = CycleBtn(ui.ttHost, 84, d.get, d.set, d.domain)
		end
		ctl:SetPoint("TOPLEFT", x + colW - 84, y + 3)
		tinsert(ui.ttRows, { d = d, ctl = ctl })
	end
	ui.ttInnerH = math.max(234, ceil(#opts / 2) * rowH + top + 10)
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
	ui.fmt.paint()
	for _, r in ipairs(ui.ttRows or {}) do
		if r.ctl.paint then r.ctl.paint() end
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
