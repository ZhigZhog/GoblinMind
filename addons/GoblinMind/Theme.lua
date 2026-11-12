local _, GM = ...

-- TSM default theme, resolved from LibTSMApp ThemeColorSets OKLCH ramps
-- (hue/chroma → sRGB, token steps per ThemeColorSets.lua, extracted 2026-11-11).
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
}

-- TSM ships Montserrat in its Media folder; GoblinMind hard-depends on TSM,
-- so referencing the same files keeps typography identical with no copied assets.
GM.FONT      = "Interface\\Addons\\TradeSkillMaster\\Media\\Montserrat-Regular.ttf"
GM.FONT_MED  = "Interface\\Addons\\TradeSkillMaster\\Media\\Montserrat-Medium.ttf"
GM.FONT_BOLD = "Interface\\Addons\\TradeSkillMaster\\Media\\Montserrat-SemiBold.ttf"

function GM.RGB(key)
	local hex = GM.C[key] or GM.C.text
	return tonumber("0x" .. strsub(hex, 1, 2)) / 255,
	       tonumber("0x" .. strsub(hex, 3, 4)) / 255,
	       tonumber("0x" .. strsub(hex, 5, 6)) / 255
end

-- "|cffRRGGBB" embed for font-string text
function GM.CC(key)
	return "|cff" .. GM.C[key]
end

-- TSM-style money: gold accented, silver/copper dim. "12g 34s 56c"
function GM.Money(copper)
	if not copper then return GM.CC("textDim") .. "—|r" end
	copper = floor(copper + 0.5)
	local g = floor(copper / 10000)
	local s = floor(copper % 10000 / 100)
	local c = copper % 100
	local parts = {}
	if g > 0 then tinsert(parts, GM.CC("accent") .. g .. "g|r") end
	if s > 0 or g > 0 then tinsert(parts, GM.CC("textDim") .. s .. "s|r") end
	tinsert(parts, GM.CC("textDim") .. c .. "c|r")
	return table.concat(parts, " ")
end

function GM.Signed(copper)
	local key = copper >= 0 and "pos" or "err"
	return GM.CC(key) .. (copper >= 0 and "+" or "-") .. "|r" .. GM.Money(abs(copper))
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
	local br, bg, bb = GM.RGB(border or "outlineVar")
	for i = 1, 4 do
		frame._gmEdges[i]:SetColorTexture(br, bg, bb)
	end
end

function GM.MakeFontString(parent, template, size, colorKey)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(template or GM.FONT, size or 11, "")
	fs:SetTextColor(GM.RGB(colorKey or "text"))
	return fs
end

-- C_Timer exists on modern clients; fall back to a no-op rescan delay.
function GM.After(delay, fn)
	if C_Timer and C_Timer.After then
		C_Timer.After(delay, fn)
	else
		fn()
	end
end
