local _, GM = ...

-- 9+1 sliced window chrome. WoW has no native 9-slice: we cut a
-- texture atlas into region textures via SetTexCoord and anchor them
-- to the frame's edges, so the frame may only grow right and down.
--
-- Assets (TGA, in Media\):
--   chrome-body  — the window: rounded body + overlapping title tab
--   chrome-inner — lighter rounded rect for inner panels
--   chrome-gear  — the emblem floating on the body's top-left corner
--
-- Measured against the 1024px source:
--   body rect  x[0..1023] y[52..1023] — 4x3 grid: 30px side cols,
--   66px top band (top edge + button strip), interior stretch,
--   34px bottom band
--   tab rect   x[0..713]  y[0..56] (+left tail to y~70), floats over
--   the body's top-left
--   the body's top-left corner + part of its top edge are OCCLUDED by
--   the tab — TL corner uses a flat fill sample (hidden anyway) and
--   the top edge stretches a clean strip from right of the tab.
--   Source PNGs arrive flattened on black; conversion un-mattes them
--   (alpha = coverage, RGB = flat palette) — see notes in AGENTS.md.

GM.CHROME = {
	-- rounded chrome retired 2026-11-13: every window uses the flat
	-- square green+gold GM.Panel look. Keep the atlas + slicer — the
	-- minimap button still uses the gear emblem and this can be
	-- re-enabled by flipping the flag.
	enabled = false,
	body = {
		file = "Interface\\AddOns\\GoblinMind\\Media\\chrome-body.tga",
		w = 1024, h = 1024,
		rect = { 0, 52, 1024, 1024 }, -- L,T,R,B of the rounded body
		-- 4x3 grid: side cols 30px, top band 66px (top edge + button
		-- strip), interior stretch, bottom band 34px
		cuts = { l = 30, t = 66, r = 30, b = 34 },
		-- display sizes (bevel scaled down): what the fixed regions
		-- actually occupy on screen, source cuts stay the same
		disp = { l = 16, t = 40, r = 16, b = 18 },
		topSrcX = { 720, 960 },     -- clean top-edge strip, right of tab
		leftSrcY = { 118, 990 },    -- straight left-edge rows
		fillSrc = { 400, 150, 420, 170 }, -- flat interior patch
		tab = { 0, 0, 730, 78 },    -- tab region incl. left tail + AA
		tabOff = { 0, 52 },         -- tab pos vs frame TOPLEFT (atlas px)
		tabScale = 0.8,             -- display scale for the tab texture
	},
	inner = {
		file = "Interface\\AddOns\\GoblinMind\\Media\\chrome-inner.tga",
		w = 1024, h = 1024,
		rect = { 0, 0, 1024, 1024 },
		cuts = { l = 36, t = 36, r = 36, b = 36 },
		disp = { l = 7, t = 7, r = 7, b = 7 },
	},
	gear = {
		file = "Interface\\AddOns\\GoblinMind\\Media\\chrome-gear.tga",
		size = 72,
		off = { 6, 0 }, -- center offset from the tab's LEFT point
	},
}

local function Region(f, file, u0, v0, u1, v1, layer, sub)
	local t = f:CreateTexture(nil, layer or "BACKGROUND")
	-- explicit sublevel: this client draws same-layer textures
	-- oldest-on-top, so the body slices must sit BELOW every panel
	-- fill (all created later on default sublevel 0)
	pcall(t.SetDrawLayer, t, layer or "BACKGROUND", sub or 0)
	t:SetTexture(file)
	-- SetTexCoord signature is (left, right, top, bottom)
	t:SetTexCoord(u0, u1, v0, v1)
	return t
end

-- Slice a rect inside an atlas onto a frame's edges. cuts = {l,t,r,b}
-- are the atlas source cuts; o.disp (defaults to cuts) is how large
-- each fixed region renders — decoupling the two is what scales the
-- bevel down. o.sub sets the BACKGROUND sublevel (this client draws
-- same-layer textures oldest-on-top; default -7 puts the slice below
-- every panel fill created later on sublevel 0).
local function Slice9(f, file, W, H, rect, cuts, o)
	o = o or {}
	local d = o.disp or cuts
	local L, T, R, B = rect[1], rect[2], rect[3], rect[4]
	local cw, th, rw, bh = cuts.l, cuts.t, cuts.r, cuts.b
	local dw, dh, drw, dbh = d.l, d.t, d.r, d.b
	local ch = {}
	local SUB = o.sub or -7
	local function Tex(x0, y0, x1, y1)
		return Region(f, file, x0 / W, y0 / H, x1 / W, y1 / H, nil, SUB)
	end
	-- corners
	local tlSrc = o.tlSrc or { L, T, L + cw, T + th }
	ch.tl = Tex(tlSrc[1], tlSrc[2], tlSrc[3], tlSrc[4])
	ch.tl:SetPoint("TOPLEFT"); ch.tl:SetSize(dw, dh)
	ch.tr = Tex(R - rw, T, R, T + th)
	ch.tr:SetPoint("TOPRIGHT"); ch.tr:SetSize(drw, dh)
	ch.bl = Tex(L, B - bh, L + cw, B)
	ch.bl:SetPoint("BOTTOMLEFT"); ch.bl:SetSize(dw, dbh)
	ch.br = Tex(R - rw, B - bh, R, B)
	ch.br:SetPoint("BOTTOMRIGHT"); ch.br:SetSize(drw, dbh)
	-- edges
	local tSrcX = o.topSrcX or { L + cw, R - rw }
	ch.t = Tex(tSrcX[1], T, tSrcX[2], T + th)
	ch.t:SetPoint("TOPLEFT", dw, 0); ch.t:SetPoint("TOPRIGHT", -drw, 0)
	ch.t:SetHeight(dh)
	ch.b = Tex(L + cw, B - bh, R - rw, B)
	ch.b:SetPoint("BOTTOMLEFT", dw, 0); ch.b:SetPoint("BOTTOMRIGHT", -drw, 0)
	ch.b:SetHeight(dbh)
	local lSrcY = o.leftSrcY or { T + th, B - bh }
	ch.l = Tex(L, lSrcY[1], L + cw, lSrcY[2])
	ch.l:SetPoint("TOPLEFT", 0, -dh); ch.l:SetPoint("BOTTOMLEFT", 0, dbh)
	ch.l:SetWidth(dw)
	ch.r = Tex(R - rw, T + th, R, B - bh)
	ch.r:SetPoint("TOPRIGHT", 0, -dh); ch.r:SetPoint("BOTTOMRIGHT", 0, dbh)
	ch.r:SetWidth(drw)
	-- center
	ch.c = Tex(L + cw, T + th, R - rw, B - bh)
	ch.c:SetPoint("TOPLEFT", dw, -dh); ch.c:SetPoint("BOTTOMRIGHT", -drw, dbh)
	return ch
end

-- Full window chrome: body 9-slice + title tab + corner gear.
-- Returns the tab's title font string.
function GM.ChromeApply(f, titleText)
	if not GM.CHROME.enabled then return nil end
	local B = GM.CHROME.body
	local ch = Slice9(f, B.file, B.w, B.h, B.rect, B.cuts, {
		tlSrc = B.fillSrc,
		topSrcX = B.topSrcX,
		leftSrcY = B.leftSrcY,
		disp = B.disp,
	})
	-- the flat GM.Panel fill would sit over the BACKGROUND slices on
	-- this client (oldest-on-top ordering) — hide it; the olive body
	-- becomes the window background. The 1px edge strips go too — they
	-- draw a square outline over the rounded body corners
	if f._gmBg then f._gmBg:Hide() end
	if f._gmEdges then
		for i = 1, 4 do f._gmEdges[i]:Hide() end
	end

	-- title tab: fixed-size overlay, floats over the top-left
	local tx0, ty0, tx1, ty1 = B.tab[1], B.tab[2], B.tab[3], B.tab[4]
	local tw, th = (tx1 - tx0) * B.tabScale, (ty1 - ty0) * B.tabScale
	ch.tab = Region(f, B.file, tx0 / B.w, ty0 / B.h, tx1 / B.w, ty1 / B.h, "ARTWORK")
	ch.tab:SetPoint("TOPLEFT", f, "TOPLEFT", B.tabOff[1] * B.tabScale, B.tabOff[2] * B.tabScale)
	ch.tab:SetSize(tw, th)

	-- gear emblem straddles the tab's left edge midpoint
	local G = GM.CHROME.gear
	ch.gear = f:CreateTexture(nil, "OVERLAY")
	ch.gear:SetTexture(G.file)
	ch.gear:SetPoint("CENTER", ch.tab, "LEFT", G.off[1], G.off[2])
	ch.gear:SetSize(G.size, G.size)

	-- title text inside the tab (below its top arc, right of the gear)
	local fs = GM.MakeFontString(f, GM.FONT_BOLD, 16, "accent")
	fs:SetPoint("LEFT", ch.tab, "LEFT", 64 * B.tabScale, -2)
	fs:SetText(titleText or "")
	ch.titleFS = fs

	-- the header strip is the drag handle — covers the tab and the top
	-- edge band; interactive children created after it sit higher and
	-- still get their clicks
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	local dz = CreateFrame("Button", nil, f)
	dz:SetPoint("TOPLEFT", ch.tab, "TOPLEFT")
	dz:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, -24)
	dz:RegisterForDrag("LeftButton")
	dz:SetScript("OnDragStart", function() f:StartMoving() end)
	dz:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
	dz:SetScript("OnMouseDown", function()
		if f.Raise then f:Raise() elseif RaiseFrame then RaiseFrame(f) end
	end)
	ch.drag = dz

	f.chrome = ch
	return fs
end

-- Chrome a content panel with the lighter inner atlas: the flat fill
-- becomes a translucent tint layer and the 1px border strips hide.
-- GM.Panel recolors still work — they set the tint's color/alpha.
function GM.ChromePanel(f, disp)
	if not GM.CHROME.enabled then return end
	local I = GM.CHROME.inner
	f.innerChrome = Slice9(f, I.file, I.w, I.h, I.rect, I.cuts, {
		disp = disp or I.disp,
		sub = -6, -- above the window body (-7), under content
	})
	if f._gmBg then
		pcall(f._gmBg.SetDrawLayer, f._gmBg, "BACKGROUND", -5)
		-- strong enough that the slice's transparent corners read as a
		-- shade shift over the body, not a bright-olive bite
		f._gmBg:SetAlpha(0.55)
	end
	if f._gmEdges then
		for i = 1, 4 do f._gmEdges[i]:Hide() end
	end
	f._gmChrome = true
end
