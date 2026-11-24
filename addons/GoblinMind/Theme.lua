local _, GM = ...

-- GoblinMind palette — neutral surfaces + gold accent, the
-- TSM-derived scheme ratified for the GoblinUI rebuild (see
-- WoWVault/Proposals/goblin-ui-design-system.md §6.2). Keys are the
-- GoblinUI palette contract; the library default ships the same
-- ramp so GoblinUI's own widgets paint identically out of the box.
GM.C = {
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
}

-- Montserrat is vendored in Media/ (copied from TSM — same license,
-- SIL OFL) so the addon renders with or without TSM installed.
GM.FONT      = "Interface\\Addons\\GoblinMind\\Media\\Montserrat-Regular.ttf"
GM.FONT_MED  = "Interface\\Addons\\GoblinMind\\Media\\Montserrat-Medium.ttf"
GM.FONT_BOLD = "Interface\\Addons\\GoblinMind\\Media\\Montserrat-SemiBold.ttf"

function GM.RGB(key)
	local hex = GM.C[key] or GM.C.text
	return tonumber("0x" .. strsub(hex, 1, 2)) / 255,
	       tonumber("0x" .. strsub(hex, 3, 4)) / 255,
	       tonumber("0x" .. strsub(hex, 5, 6)) / 255
end

-- "|cffRRGGBB" embed for font-string text
function GM.CC(key)
	return "|cff" .. (GM.C[key] or GM.C.text)
end

-- WoW coin colors — each denomination takes its metal color, the
-- client convention everyone knows: gold/silver/copper
GM.COIN_G, GM.COIN_S, GM.COIN_C =
	"|cffffd700", "|cffc7c7cf", "|cffeda55f"

-- full money: "12g 34s 56c" with each unit in its coin color
function GM.Money(copper)
	if not copper then return GM.CC("textDim") .. "—|r" end
	copper = floor(copper + 0.5)
	local g = floor(copper / 10000)
	local s = floor(copper % 10000 / 100)
	local c = copper % 100
	local parts = {}
	if g > 0 then tinsert(parts, GM.COIN_G .. g .. "g|r") end
	if s > 0 or g > 0 then tinsert(parts, GM.COIN_S .. s .. "s|r") end
	tinsert(parts, GM.COIN_C .. c .. "c|r")
	return table.concat(parts, " ")
end

-- two-unit money for tight columns: "10g 85s" / "85s 20c" / "34c" —
-- same coin colors, truncated to the top two units
function GM.MoneyShort(copper)
	if not copper then return GM.CC("textDim") .. "—|r" end
	copper = floor(copper + 0.5)
	local g = floor(copper / 10000)
	local s = floor(copper % 10000 / 100)
	if g > 0 then
		return GM.COIN_G .. g .. "g|r"
			.. (s > 0 and (" " .. GM.COIN_S .. s .. "s|r") or "")
	end
	if s > 0 then
		return GM.COIN_S .. s .. "s|r"
			.. (copper % 100 > 0
				and (" " .. GM.COIN_C .. copper % 100 .. "c|r") or "")
	end
	return GM.COIN_C .. copper .. "c|r"
end

-- signed money for profit columns: "+1g 2s" / "-3s 4c" — the sign
-- takes pos/err color, the magnitude stays in coin colors so both
-- signals survive
function GM.Signed(copper)
	copper = copper or 0
	local key = copper >= 0 and "pos" or "err"
	return GM.CC(key) .. (copper >= 0 and "+" or "-") .. "|r" .. GM.Money(abs(copper))
end

-- compact units/day: region-scale velocities hit the millions —
-- "13.2M" / "8.6k" / "1027"; callers append "/d" or "/day"
function GM.VelRate(vel)
	if not vel or vel <= 0 then return nil end
	if vel >= 1e6 then return format("%.1fM", vel / 1e6) end
	if vel >= 1e4 then return format("%.0fk", vel / 1e3) end
	if vel >= 1e3 then return format("%.1fk", vel / 1e3) end
	-- at most 2 decimals — %g printed ~6 sig figs of false precision
	-- ("13.703", "21.1132"); strip the padding zeros it leaves
	return (format("%.2f", vel):gsub("%.?0+$", ""))
end

-- compact age/span: "7d" / "14h" / "25m" / "40s" — callers add "ago"
function GM.FmtAge(sec)
	sec = floor(sec or 0)
	if sec >= 86400 then return format("%dd", floor(sec / 86400 + 0.5)) end
	if sec >= 3600 then return format("%dh", floor(sec / 3600 + 0.5)) end
	if sec >= 60 then return format("%dm", floor(sec / 60)) end
	return sec .. "s"
end

-- Shared backdrop matching TSM's flat dark panels + thin outline.
-- This client has no SetBackdrop — flat fill texture + 1px edge strips
-- achieve the identical look on any client.
function GM.Panel(frame, fill, border)
	if not frame._gmBg then
		frame._gmBg = frame:CreateTexture(nil, "BACKGROUND")
		frame._gmBg:SetAllPoints()
		frame._gmEdges = {}
		for i = 1, 4 do
			frame._gmEdges[i] = frame:CreateTexture(nil, "BORDER")
		end
		local t, b, l, r = frame._gmEdges[1], frame._gmEdges[2], frame._gmEdges[3], frame._gmEdges[4]
		t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(1)
		b:SetPoint("BOTTOMLEFT"); b:SetPoint("BOTTOMRIGHT"); b:SetHeight(1)
		l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetWidth(1)
		r:SetPoint("TOPRIGHT"); r:SetPoint("BOTTOMRIGHT"); r:SetWidth(1)
	end
	frame._gmBg:SetColorTexture(GM.RGB(fill or "contLow"))
	-- chromed panels use _gmBg as a translucent tint over the inner
	-- slice instead of an opaque fill (SetColorTexture resets alpha)
	frame._gmBg:SetAlpha(frame._gmChrome and 0.55 or 1)
	local br, bg, bb = GM.RGB(border or "outlineVar")
	for i = 1, 4 do
		frame._gmEdges[i]:SetColorTexture(br, bg, bb)
	end
end

GM._fontFixups = setmetatable({}, { __mode = "k" })

local function ApplyFont(fs, font, size, flags)
	-- a custom font that fails to resolve must degrade, not blank the
	-- UI — a first-run install blanked every FONT_MED label until
	-- /reload. This client's SetFont doesn't return false on failure,
	-- so prove the font works by measuring a real glyph — a dead font
	-- reports zero width.
	local ok = fs:SetFont(font, size, flags or "")
	local dead = ok == false
	if not dead and fs.GetStringWidth then
		local prev = fs:GetText()
		fs:SetText("1")
		dead = fs:GetStringWidth() == 0
		fs:SetText(prev)
	end
	if dead then fs:SetFont("Fonts\\FRIZQT__.TTF", size, flags or "") end
end

function GM.MakeFontString(parent, template, size, colorKey, flags)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	local font = template or GM.FONT
	ApplyFont(fs, font, size or 11, flags)
	GM._fontFixups[fs] = { font, size or 11, flags }
	fs:SetTextColor(GM.RGB(colorKey or "text"))
	return fs
end

function GM.FixupFonts()
	GM._ffRuns = (GM._ffRuns or 0) + 1
	-- re-apply every custom font once the client is fully up. The
	-- first-load failure mode heals here: the font that couldn't
	-- rasterize during Prewarm resolves on a later SetFont; anything
	-- still dead degrades to FRIZQT instead of rendering blank.
	for fs, spec in pairs(GM._fontFixups) do
		if spec[1] ~= "Fonts\\FRIZQT__.TTF" then
			ApplyFont(fs, spec[1], spec[2], spec[3])
		end
	end
end

-- C_Timer exists on modern clients; fall back to a no-op rescan delay.
function GM.After(delay, fn)
	GM._afterCalls = (GM._afterCalls or 0) + 1
	if C_Timer and C_Timer.After then
		C_Timer.After(delay, fn)
	else
		fn()
	end
end
