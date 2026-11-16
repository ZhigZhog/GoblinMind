local _, GM = ...

-- GoblinMind palette — ramps derived from the artwork's four source
-- colors: #434307 (tab olive), #333506 (body olive), #0e1313 (dark),
-- #000000. Semantic colors (err/pos/warn) keep their hues — they carry
-- buy/sell/error meaning the palette can't express.
GM.C = {
	surface        = "121407",
	surfaceVariant = "333506",
	contLowest     = "0b0d05",
	contLow        = "14170a",
	contMedium     = "1c1f0e",
	contHigh       = "282b14",
	contHighest    = "3a3d17",
	outline        = "6f7229",
	outlineVar     = "3b3e15",
	text           = "ecedd8",
	textDim        = "a2a47c",
	primary        = "b7ba83",
	secondary      = "696c3d",
	accent         = "c6c83f",
	accentDark     = "434307",
	err            = "fd392e",
	pos            = "08d36b",
	warn           = "ff9707",
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
	copper = copper or 0
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
	-- chromed panels use _gmBg as a translucent tint over the inner
	-- slice instead of an opaque fill (SetColorTexture resets alpha)
	frame._gmBg:SetAlpha(frame._gmChrome and 0.55 or 1)
	local br, bg, bb = GM.RGB(border or "outlineVar")
	for i = 1, 4 do
		frame._gmEdges[i]:SetColorTexture(br, bg, bb)
	end
end

function GM.MakeFontString(parent, template, size, colorKey)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	-- a custom font that fails to resolve must degrade, not blank the
	-- UI — Medium.ttf failed once on a first-run install and every
	-- FONT_MED label rendered nothing until /reload
	local ok = fs:SetFont(template or GM.FONT, size or 11, "")
	if ok == false then
		fs:SetFont("Fonts\\FRIZQT__.TTF", size or 11, "")
	end
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
