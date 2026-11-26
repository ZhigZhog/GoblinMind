local _, GM = ...

-- Shared widget kit — the takeover windows (VendoringUI, AHUI,
-- MailUI, BankUI, GBankUI) and DestroyingUI all grew their own
-- Btn/EditBox/Tip copies with drift. One implementation lives here.
-- Files alias locals: local Btn = GM.Widgets.Btn — keep signatures
-- identical to the old per-file helpers so call sites don't change.

GM.Widgets = {}
local W = GM.Widgets

-- shared localizer pass-through: label/hint/title args flow through
-- GM.L so every window gets the L() migration without callsite
-- churn. Strings carrying a | escape (colour codes) or no letters
-- are data — glyphs, numbers, formatted values — and pass through.
local function LT(s)
	if type(s) == "string" and GM.L and s:find("%a")
		and not s:find("|", 1, true) then
		return GM.L(s)
	end
	return s
end

local HL_R, HL_G, HL_B = nil

-- paneled action button: contHigh base, contHighest+text on hover
function W.Btn(parent, w, label, fn)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, 20)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(w - 8)
	b.text:SetWordWrap(false)
	b.text:SetText(LT(label))
	b:SetScript("OnEnter", function()
		if b._gmBg then b._gmBg:SetColorTexture(GM.RGB("contHighest")) end
		b.text:SetTextColor(GM.RGB("text"))
	end)
	b:SetScript("OnLeave", function()
		if b._gmBg then b._gmBg:SetColorTexture(GM.RGB("contHigh")) end
		b.text:SetTextColor(GM.RGB("textDim"))
	end)
	b:SetScript("OnClick", fn)
	return b
end

-- editbox with hint placeholder, bordered
function W.EditBox(parent, w, hint)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, 18)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(6, 4, 0, 0)
	GM.Panel(eb, "contLowest")
	local lh = LT(hint)
	eb:SetText(lh or "")
	eb:SetTextColor(GM.RGB(hint and "textDim" or "text"))
	eb:SetScript("OnEditFocusGained", function()
		if lh and eb:GetText() == lh then
			eb:SetText("")
			eb:SetTextColor(GM.RGB("text"))
		end
		-- focused fields read as active: brighten the fill
		if eb._gmBg then eb._gmBg:SetColorTexture(GM.RGB("contMedium")) end
	end)
	eb:SetScript("OnEditFocusLost", function()
		if eb._gmBg then eb._gmBg:SetColorTexture(GM.RGB("contLowest")) end
	end)
	eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
	eb:SetScript("OnEnterPressed", function() eb:ClearFocus() end)
	return eb
end

-- inline-editable label: a fontstring that swaps to an edit box on
-- click — THE reusable "editable text" widget. The field's text
-- lands pixel-on the label's painted text and the box's right edge
-- ends where the label's did, so the edit reads as the same text
-- under focus, not a shifted control.
-- f.pad reserves leading width the field must not cover (crest
-- icons) — callers measure it exactly, never guess a constant.
-- One field open at a time, bank-form semantics: opening a second
-- field or clicking anywhere outside validates+commits the first
-- (the commit callback owns validation — reject = no write), Enter
-- commits, Esc cancels. Native editbox focus exclusion covers
-- clicks into other text fields; a screen-wide catcher covers the
-- rest.
local openField, editCatcher
local function EditCatcher()
	if editCatcher then return editCatcher end
	editCatcher = CreateFrame("Button", nil, UIParent)
	editCatcher:SetAllPoints(UIParent)
	editCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
	editCatcher:SetScript("OnClick", function()
		if openField then openField.Finish(true) end
	end)
	return editCatcher
end
local function CloseField(eb, save)
	if openField ~= eb then return end
	openField = nil
	eb._finishing = true
	eb:Hide()
	eb:ClearFocus()
	eb._finishing = nil
	if editCatcher then editCatcher:Hide() end
	local cb = eb._commit
	eb._commit = nil
	if save and cb then cb(eb:GetText()) end
end
function W.EditableLabel(parent, w)
	local f = CreateFrame("Button", nil, parent)
	f:SetSize(w, 18)
	f.pad = 0
	local label = GM.MakeFontString(f, GM.FONT, 10, "text")
	label:SetPoint("LEFT", 0, 0)
	label:SetWidth(w)
	label:SetJustifyH("LEFT")
	label:SetWordWrap(false)
	f.label = label
	-- the box is a sibling of the label button so its left edge can
	-- overhang by the text inset without clipping. Top strata: it
	-- must draw above the click-off catcher while it's open.
	local eb = W.EditBox(parent, w)
	eb:SetFrameStrata("FULLSCREEN_DIALOG")
	eb:Hide()
	f.eb = eb
	-- pad shifts the field's TEXT origin — the box edge sits
	-- inset-left of it so painted and edited text share one x
	function f.Layout()
		eb:ClearAllPoints()
		eb:SetPoint("LEFT", f, "LEFT", f.pad - 6, 0)
		eb:SetWidth(w - f.pad + 6)
	end
	f.Layout()
	function eb.Finish(save) CloseField(eb, save) end
	-- Open(plain, commit): show the field with the unadorned text;
	-- Enter commits, Esc cancels — both drop back to the label
	function f.Open(plain, commit)
		if openField and openField ~= eb then
			openField.Finish(true)
		end
		local c = EditCatcher()
		eb:SetText(plain or "")
		eb:SetTextColor(GM.RGB("text"))
		eb._commit = commit
		openField = eb
		c:Show()
		eb:SetFrameLevel(c:GetFrameLevel() + 1)
		eb:Show()
		eb:SetFocus()
		eb:HighlightText()
	end
	eb:SetScript("OnEnterPressed", function() eb.Finish(true) end)
	eb:SetScript("OnEscapePressed", function() eb.Finish(false) end)
	eb:SetScript("OnEditFocusLost", function()
		-- losing focus to anything but our own close path is a
		-- click-off: validate + commit, don't silently cancel
		if not eb._finishing and openField == eb then
			eb.Finish(true)
		end
	end)
	return f
end

-- hover tooltip: linesFn() returns {title, line, line…} or nil.
-- Renders into an owned frame, NOT GameTooltip — SetText there runs
-- the shared hook chain of every installed addon, and a foreign
-- chain looped into a C stack overflow (Questie/FDJ/EnhanceQoL all
-- hook this tooltip; the trigger was a simple Bronze Tube hint).
-- Hints are static text and don't need the engine's machinery.
local hint
local function HintTip()
	if hint then return hint end
	hint = CreateFrame("Frame", "GoblinMindHint", UIParent)
	GM.Panel(hint, "contHigh")
	hint:SetFrameStrata("TOOLTIP")
	pcall(hint.SetClampedToScreen, hint, true)
	hint.lines = {}
	hint:Hide()
	return hint
end

-- direct show/hide for sites that used to SetOwner+SetText on
-- GameTooltip (same foreign-chain exposure as W.Tip's old path)
function W.HintShow(f, lines)
	if not lines or not lines[1] then return end
	local tip = HintTip()
	local w, n = 0, math.min(#lines, 12)
	for i = 1, n do
		local fs = tip.lines[i]
		if not fs then
			fs = GM.MakeFontString(tip, GM.FONT, 10, "text")
			fs:SetPoint("TOPLEFT", 8, -7 - (i - 1) * 13)
			tip.lines[i] = fs
		end
		-- truncate on DISPLAY length: a byte-wise sub() can sever a
		-- |cff…|r escape mid-code or a UTF-8 glyph mid-sequence, and
		-- the remainder renders as literal "|cff…" text in the tip.
		-- Escapes are free — they occupy bytes but no pixels
		local s = tostring(lines[i])
		if #s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") > 96 then
			s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
				:gsub("|r", ""):sub(1, 96)
		end
		fs:SetText(s)
		fs:SetTextColor(i == 1 and 1 or 0.8,
			i == 1 and 1 or 0.8, i == 1 and 1 or 0.75)
		fs:Show()
		local sw = fs.GetStringWidth and fs:GetStringWidth() or 0
		if sw > w then w = sw end
	end
	for j = n + 1, #tip.lines do tip.lines[j]:Hide() end
	tip:SetSize(w + 16, 10 + n * 13)
	tip:ClearAllPoints()
	tip:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 4)
	tip:Show()
end

function W.HintHide()
	if hint then hint:Hide() end
end

function W.Tip(f, linesFn)
	-- accepts a fn returning lines, a lines table, a plain
	-- string, or nil (no tip)
	if type(linesFn) == "string" then
		local s = linesFn
		linesFn = function() return { s } end
	elseif type(linesFn) == "table" then
		local t = linesFn
		linesFn = function() return t end
	end
	if type(linesFn) ~= "function" then return end
	-- idempotent: the hooks bind ONCE per frame and read the fn at
	-- hover. Re-calling swaps the data, never stacks — a Tip() left
	-- inside a render loop piled a hook pair per refresh until the
	-- hover chain blew the C stack mid-craft-run
	f._gmTipFn = linesFn
	if f._gmTipBound then return end
	f._gmTipBound = true
	f:HookScript("OnEnter", function()
		W.HintShow(f, f._gmTipFn and f._gmTipFn())
	end)
	f:HookScript("OnLeave", W.HintHide)
end

-- any modified click = Blizzard's default item action (ctrl+click =
-- dress-up preview, shift+click = chat link / context transfer).
-- For rows with no own OnClick — rows that have one guard inside
-- their handler instead. idFn may be an id or fn() -> id, resolved
-- at click time.
function W.ModifiedClick(f, idFn)
	-- same idempotence as Tip — the fn is data, not a new hook
	f._gmClickFn = idFn
	if f._gmClickBound then return end
	f._gmClickBound = true
	f:HookScript("OnMouseDown", function(_, btn)
		if btn ~= "LeftButton" or not IsModifiedClick() then return end
		local fn = f._gmClickFn
		local id = type(fn) == "function" and fn() or fn
		if id then GM.ModifiedItemClick(id) end
	end)
end

-- paneled action button, larger variant (contHigh + FONT_BOLD 10
-- accent, centered). No handlers wired — callers SetScript their own
-- OnClick; CraftingUI's secure OPEN overlay needs a bare button to
-- cover. Was an identical Btn triple in CraftingUI/GroupsUI/OpsUI.
function W.ActionBtn(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h or 20)
	GM.Panel(b, "contHigh")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 10, "accent")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(w - 8)
	b.text:SetWordWrap(false)
	b.text:SetText(LT(label))
	return b
end

-- status line setter — the ui.footer pattern in the takeover windows
function W.Footer(fs, msg, err)
	fs:SetText(msg)
	fs:SetTextColor(GM.RGB(err and "err" or "secondary"))
end

-- marked editbox: 2px edge mark goes accent when the user edits
-- (eb.dirty set), Escape drops dirty + clears focus. onEscape fires
-- after ClearFocus — pass the module's Refresh so the row repaints.
-- Was an identical pair in GroupsUI/OpsUI (GroupsUI layers its own
-- OnEditFocusGained capture on top via SetScript).
function W.DirtyEditBox(parent, w, h, onEscape)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetSize(w, h or 20)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetTextInsets(5, 4, 0, 0)
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(GM.RGB("contLowest"))
	local mark = eb:CreateTexture(nil, "ARTWORK")
	mark:SetSize(2, (h or 20) - 2)
	mark:SetPoint("TOPLEFT", eb, "TOPLEFT", 0, -1)
	mark:SetColorTexture(GM.RGB("outlineVar"))
	eb.mark = mark
	eb:SetScript("OnEscapePressed", function(self)
		self.dirty = nil
		self:ClearFocus()
		if onEscape then onEscape() end
	end)
	eb:SetScript("OnTextChanged", function(self, user)
		if user then
			self.dirty = true
			self.mark:SetColorTexture(GM.RGB("accent"))
		end
	end)
	return eb
end

-- dirty-mark paint for W.DirtyEditBox: the 2px edge strip reads
-- accent while typed-dirty; callers repaint it on validate/commit.
function W.SetMark(eb, state)
	eb.mark:SetColorTexture(GM.RGB(
		state == "err" and "err" or state == "ok" and "pos"
			or state == "dirty" and "accent" or "outlineVar"))
end

-- text segment button (toggle-strip member) + selected-state paint.
-- Was an identical Segment/PaintSeg pair in GroupsUI/OpsUI.
function W.Segment(parent, label, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h or 18)
	GM.Panel(b, "contLowest")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(w - 8)
	b.text:SetWordWrap(false)
	b.text:SetText(LT(label))
	return b
end

function W.PaintSeg(b, selected)
	b._gmBg:SetColorTexture(GM.RGB(selected and "contHighest" or "contLowest"))
	b.text:SetTextColor(GM.RGB(selected and "accent" or "textDim"))
end

-- scanline fill of a polygon: each horizontal band lays one pooled
-- rect between its left/right outline crossings, so the shaded
-- area IS the shape — unified Stellaris-style blob, not a dot
-- union or a fan with a bright center. poly = { {x=px, y=px} }
-- with screen-y down; put() yields a fresh WHITE8X8 texture the
-- caller pools/reclaims. Star-shaped outlines cross each band
-- exactly twice — that's the support-function fit contract.
-- clip: optional {x, y, r} circle in the same TOPLEFT-px space —
-- each band's span intersects the circle chord at that y, so
-- fills can pour onto the minimap without bleeding past the rim
function W.PolyFill(canvas, poly, step, r, g, b, a, put, clip)
	local ymin, ymax = 1e9, -1e9
	for _, p in ipairs(poly) do
		if p.y < ymin then ymin = p.y end
		if p.y > ymax then ymax = p.y end
	end
	step = step or 7
	for y = ymin + step / 2, ymax, step do
		local xl, xr
		for i = 1, #poly do
			local q, s = poly[i], poly[i % #poly + 1]
			if (q.y <= y) ~= (s.y <= y) then
				local xi = q.x + (y - q.y) / (s.y - q.y)
					* (s.x - q.x)
				if not xl or xi < xl then xl = xi end
				if not xr or xi > xr then xr = xi end
			end
		end
		if clip then
			local ch2 = clip.r * clip.r - (y - clip.y) ^ 2
			if ch2 <= 0 then
				xl, xr = nil, nil
			elseif xl then
				local ch = math.sqrt(ch2)
				xl = math.max(xl, clip.x - ch)
				xr = math.min(xr, clip.x + ch)
			end
		end
		if xl and xr and xl < xr then
			local t = put()
			t:SetSize(xr - xl, step + 0.5)
			t:ClearAllPoints()
			t:SetPoint("TOPLEFT", canvas, "TOPLEFT", xl,
				-(y - step / 2))
			t:SetVertexColor(r, g, b, a or 1)
		end
	end
end

-- pooled map-draw layer shared by the world-map overlay host and
-- the gather window's map pane — one primitive set at fixed
-- sublevels so a blob/icon/route is the same object on every map.
-- Sublevels ride high in OVERLAY: MapWise's own pins sit in the
-- same frame-level band as our host, and low-sublevel textures
-- lose the ordering there. Fontstring kinds (tag/badge) always
-- paint above every texture in the layer.
--   ring(3) blob borders · disc/fill(4) interiors + count discs
--   pin/line(5) route dots + fallback pins · icon(6) · medal(7)
-- ====================== map style contract ======================
-- ONE style table every map surface (world map, window pane,
-- minimap) reads — see WoWVault/Proposals/map-widget-unification.
-- Object alphas multiply the user's oaZ/oaN channel sliders;
-- state alphas never stack multiplicatively — callers take min().
W.MapStyle = {
	A = {
		full      = 0.95,  -- normal object
		depleted  = 0.35,  -- all members inside respawn window
		nonMatch  = 0.28,  -- target set, not a producer
		muted     = 0.15,  -- deepest "barely there"
		zoneFill  = 0.18,  zoneFillSel = 0.30, zoneFillMute = 0.06,
		zoneRing  = 0.70,  zoneRingSel = 0.95, zoneRingMute = 0.15,
		route     = 0.85,  routeSel    = 1.00,
	},
	MEDAL = { { 1.0, 0.84, 0.27 }, { 0.82, 0.84, 0.9 },
		{ 0.82, 0.53, 0.22 } },          -- gold / silver / bronze
	MEDAL_OFF = { 0.55, 0.6, 0.55 },
	TAG_FONT = 8, BADGE_FONT = 8, MARK_FONT = 9,
	ZONE_ICON = 16, ZONE_ICON_SEL = 20, ZONE_ICON_MM = 13,
	SHRINK_CAP = 8, SHRINK_CAP_MM = 7,   -- non-match icon caps
	ROUTE_HOT_SPACING = 36,              -- px between hover pads
}
-- cluster icon px by member count — minimap runs a size class
-- smaller (its canvas is tiny). math.* not the bare globals: the
-- test harness extracts this block without WoW's aliases
function W.MapStyle.ClusterSize(n, mini)
	return mini and math.min(12, 7 + 1.5 * math.sqrt(n))
		or math.min(18, 9 + 2.5 * math.sqrt(n))
end

-- shrink/expand a polygon toward/away from its centroid by d px —
-- the border-band trick blob() uses; minimap blobs share it
function W.PolyShrink(poly, cx, cy, d)
	local out = {}
	for i, p in ipairs(poly) do
		local dx, dy = p.x - cx, p.y - cy
		local len = math.sqrt(dx * dx + dy * dy)
		local s = len > 0 and (len + d) / len or 1
		out[i] = { x = cx + dx * s, y = cy + dy * s }
	end
	return out
end

function W.MapLayer(host)
	local L = { host = host, live = {}, pool = {} }
	local sqrt = math.sqrt
	local atan2 = math.atan2
		or function(y, x) return math.atan(y, x) end
	local S = W.MapStyle

	local function put(kind)
		local pool = L.pool[kind]
		if not pool then pool = {} L.pool[kind] = pool end
		local t = tremove(pool)
		if not t then
			if kind == "tag" then
				-- map terrain is noisy — always OUTLINE, small:
				-- the tag annotates, it doesn't shout (S1)
				t = GM.MakeFontString(host, GM.FONT,
					S.TAG_FONT, "text", "OUTLINE")
			elseif kind == "badge" then
				t = GM.MakeFontString(host, GM.FONT,
					S.BADGE_FONT, "text", "OUTLINE")
			elseif kind == "mbadge" then
				-- mark counts keep the bigger rank font (S1)
				t = GM.MakeFontString(host, GM.FONT,
					S.MARK_FONT, "text", "OUTLINE")
			elseif kind == "tile" then
				t = host:CreateTexture(nil, "BACKGROUND")
			elseif kind == "exptile" then
				t = host:CreateTexture(nil, "ARTWORK", nil, -1)
			elseif kind == "ring" then
				t = host:CreateTexture(nil, "OVERLAY", nil, 3)
				t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
			elseif kind == "disc" then
				t = host:CreateTexture(nil, "OVERLAY", nil, 4)
				t:SetTexture("Interface\\AddOns\\GoblinMind"
					.. "\\Media\\disc.tga")
			elseif kind == "fill" then
				t = host:CreateTexture(nil, "OVERLAY", nil, 4)
				t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
			elseif kind == "pin" or kind == "line" then
				t = host:CreateTexture(nil, "OVERLAY", nil, 5)
				t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
			elseif kind == "medal" then
				t = host:CreateTexture(nil, "OVERLAY", nil, 7)
				t:SetTexture("Interface\\AddOns\\GoblinMind"
					.. "\\Media\\ring.tga")
			elseif kind == "hot" then
				-- invisible mouse catcher — textures can't take
				-- scripts, so hover regions are real Buttons that
				-- ask their _tipFn to fill GameTooltip on enter
				t = CreateFrame("Button", nil, host)
				t:SetScript("OnEnter", function(s)
					if not s._tipFn then return end
					GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
					s._tipFn(GameTooltip)
					GameTooltip:Show()
				end)
				t:SetScript("OnLeave", function()
					GameTooltip:Hide()
				end)
			else -- icon
				t = host:CreateTexture(nil, "OVERLAY", nil, 6)
			end
		end
		t:ClearAllPoints()
		t:Show()
		L.live[#L.live + 1] = { kind, t }
		return t
	end
	L.put = put

	function L:clear()
		for _, e in ipairs(self.live) do
			e[2]:Hide()
			local p = self.pool[e[1]]
			p[#p + 1] = e[2]
		end
		wipe(self.live)
	end

	function L:pin(x, y, sz, r, g, b, a)
		local t = put("pin")
		t:SetSize(sz or 8, sz or 8)
		t:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
		t:SetVertexColor(r, g, b, a or 1)
	end

	-- rotated segment — only safe inside our own windows; the
	-- world-map canvas drops rotated textures on this client
	function L:line(x1, y1, x2, y2, r, g, b, a, wd)
		local dx, dy = x2 - x1, y2 - y1
		local len = sqrt(dx * dx + dy * dy)
		if len < 2 then return end
		local t = put("line")
		t:SetSize(len, wd or 2)
		t:SetPoint("CENTER", self.host, "TOPLEFT",
			(x1 + x2) / 2, -(y1 + y2) / 2)
		if t.SetRotation then
			pcall(t.SetRotation, t, atan2(-dy, dx))
		end
		t:SetVertexColor(r, g, b, a or 0.9)
	end

	-- dashed segment from square dots — rotation-free, so it
	-- survives the world-map canvas where :line() does not
	function L:dots(x1, y1, x2, y2, r, g, b, a, sz, gap)
		local dx, dy = x2 - x1, y2 - y1
		local len = sqrt(dx * dx + dy * dy)
		if len < 1 then return end
		sz = sz or 4
		local n = math.max(1, math.floor(len / (gap or 9)))
		for i = 0, n do
			self:pin(x1 + dx * i / n, y1 + dy * i / n,
				sz, r, g, b, a or 1)
		end
	end

	function L:disc(x, y, rPx, r, g, b, a)
		local t = put("disc")
		t:SetSize(rPx * 2, rPx * 2)
		t:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
		t:SetVertexColor(r, g, b, a or 1)
	end

	-- item art when fid resolves, kind-tinted square when not —
	-- one primitive so callers never branch on icon availability
	function L:icon(x, y, sz, fid, r, g, b, a)
		local t = put("icon")
		if fid then
			t:SetTexture(fid)
			t:SetVertexColor(1, 1, 1, a or 1)
		else
			t:SetTexture("Interface\\BUTTONS\\WHITE8X8")
			t:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
		end
		t:SetSize(sz, sz)
		t:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
	end

	function L:badge(x, y, text, r, g, b, a)
		local l = put("badge")
		l:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
		l:SetText(text)
		l:SetTextColor(r or 1, g or 1, b or 1, a or 1)
	end

	function L:tag(x, y, text, a)
		local l = put("tag")
		l:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
		l:SetMaxLines(1) -- one glance line, never a wrap
		l:SetText(text or "")
		l:SetAlpha(a or 1) -- pooled: always re-set
	end

	-- invisible hover region: fn(GameTooltip) fills and shows it
	-- on enter. Kept tight to its object so the map's own pins
	-- and drags keep working everywhere else
	function L:hot(x, y, w, h, fn)
		if not fn then return end
		local b = put("hot")
		b:SetSize(w or 16, h or 16)
		b:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
		b._tipFn = fn
	end

	-- Stellaris-style blob: the border is a FILLED band, not a
	-- ring of rotated segments — outer poly in ring color, an
	-- inner copy shrunk ringPx toward the centroid in the interior
	-- tint, leaving a uniform rim. sel adds a gold rim 3px out
	function L:blob(poly, cx, cy, r, g, b, fillA, ringA, ringPx, sel)
		ringPx = ringPx or 3
		if sel then
			W.PolyFill(self.host,
				W.PolyShrink(poly, cx, cy, ringPx + 3), 6,
				1, 0.82, 0.1, 0.9,
				function() return put("ring") end)
		end
		W.PolyFill(self.host, poly, 6, r, g, b, ringA,
			function() return put("ring") end)
		W.PolyFill(self.host,
			W.PolyShrink(poly, cx, cy, -ringPx), 6, r, g, b,
			fillA, function() return put("fill") end)
	end

	-- continent summary mark: dark count disc + ring + number —
	-- medal tiers ring bright in their color, plain marks dim
	function L:mark(x, y, count, r, g, b, medal)
		self:disc(x, y, 11, 0.02, 0.03, 0.02, 0.85)
		local rg = put("medal")
		rg:SetSize(25, 25)
		rg:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
		rg:SetVertexColor(r, g, b, medal and 0.95 or 0.4)
		local l = put("mbadge")
		l:SetPoint("CENTER", self.host, "TOPLEFT", x, -y)
		l:SetText(tostring(count))
		l:SetTextColor(r, g, b, 1)
	end

	return L
end

-- full-height column panel with title (+count fs at top right). topY
-- positions under the toolbar row — CraftingUI uses -52, OpsUI -34.
-- Was two near-identical Panel()s; p.titleFs and p.count are both set
-- so either consumer's field name resolves.
function W.ColPanel(parent, x, w, title, topY)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOPLEFT", x, topY or -52)
	p:SetPoint("BOTTOM", 0, 30)
	p:SetWidth(w)
	GM.Panel(p, "contLowest")
	p:SetClipsChildren(true)
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetText(LT(title))
	p.titleFs = t
	p.count = GM.MakeFontString(p, GM.FONT, 9, "textDim")
	p.count:SetPoint("TOPRIGHT", -8, -7)
	t:SetWordWrap(false)
	return p
end

-- GOBLINMIND switch button on a Blizzard frame — the takeover
-- windows' shared "go back / come back" affordance. Was six copies
-- (AHUI/BankUI/GBankUI/MailUI/VendoringUI/CraftingUI). onClick fires
-- when the user wants OUR window back; onShow hooks the native
-- frame's show so the caller can re-park it. Returns nil if the
-- native frame doesn't exist yet.
-- a standalone framed box with a bold title — callers position it.
-- Returns (panel, titleFS) — the title fs lets callers recolor/wrap.
function W.TitledPanel(f, title)
	local p = CreateFrame("Frame", nil, f)
	GM.Panel(p, "contLowest")
	local t = GM.MakeFontString(p, GM.FONT_BOLD, 9, "secondary")
	t:SetPoint("TOPLEFT", 8, -6)
	t:SetWordWrap(false)
	t:SetText(LT(title))
	return p, t
end

function W.SwitchBtn(native, onClick, onShow)
	if not native then return nil end
	local b = CreateFrame("Button", nil, native)
	b:SetSize(84, 16)
	b:SetPoint("TOPRIGHT", native, "TOPRIGHT", -40, -8)
	b:SetFrameLevel(native:GetFrameLevel() + 20)
	GM.Panel(b, "accent")
	b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "contLowest")
	b.text:SetPoint("CENTER")
	b.text:SetWidth(76)
	b.text:SetWordWrap(false)
	b.text:SetText("GOBLINMIND")
	b:SetScript("OnClick", onClick)
	if onShow then native:HookScript("OnShow", onShow) end
	return b
end

-- subtle hover tint — attach at row creation; the HIGHLIGHT layer
-- draws itself, no script needed
-- create ui.switchBtn once on a native Blizzard frame: click
-- re-opens our window over it; the frame reparks itself when we
-- didn't explicitly take over (wantDefault stays nil → park).
-- Shared by every *UI module that overlays a Blizzard window —
-- the six per-file copies differed only in frame + reopen fn.
-- onPark: custom "back to default" repark (CraftingUI parks its
-- tradeskill scaffold, not the stock FramePark path).
function W.EnsureSwitchBtn(ui, frame, onOpen, onPark)
	if not (frame and ui and not ui.switchBtn) then return end
	ui.switchBtn = W.SwitchBtn(frame, function()
		ui.wantDefault = nil
		onOpen()
	end, function()
		if not ui.wantDefault then
			if onPark then onPark() else GM.FramePark.Park(frame) end
		end
	end)
end

function W.HoverTint(row)
	if not HL_R then HL_R, HL_G, HL_B = GM.RGB("contHighest") end
	row.hl = row:CreateTexture(nil, "HIGHLIGHT")
	row.hl:SetAllPoints()
	row.hl:SetColorTexture(HL_R, HL_G, HL_B, 0.35)
end

-- page toggle strip: text tabs with an accent underline under the
-- active one (reads as tabs, not action buttons). defs = {{key,label}}
-- onPick(key) fires on click. Returns {btns={key=btn}, set=fn}.
function W.PageTabs(parent, defs, onPick)
	local strip = {}
	strip.btns = {}
	local x = 0
	for _, d in ipairs(defs) do
		local key, label = d[1], d[2]
		local b = CreateFrame("Button", nil, parent)
		b:SetSize(56, 20)
		b:SetPoint("TOPLEFT", x, 0)
		b.text = GM.MakeFontString(b, GM.FONT_BOLD, 9, "textDim")
		b.text:SetPoint("CENTER", 0, 2)
		b.text:SetWidth(52)
		b.text:SetWordWrap(false)
		b.text:SetText(LT(label))
		b.line = b:CreateTexture(nil, "ARTWORK")
		b.line:SetSize(44, 2)
		b.line:SetPoint("BOTTOM", 0, 1)
		b.line:SetColorTexture(GM.RGB("accent"))
		b.line:Hide()
		b:SetScript("OnEnter", function()
			if not b.active then b.text:SetTextColor(GM.RGB("text")) end
		end)
		b:SetScript("OnLeave", function()
			if not b.active then b.text:SetTextColor(GM.RGB("textDim")) end
		end)
		b:SetScript("OnClick", function() onPick(key) end)
		strip.btns[key] = b
		x = x + 62
	end
	function strip.set(key)
		for k, b in pairs(strip.btns) do
			b.active = (k == key) or nil
			b.line:SetShown(k == key)
			b.text:SetTextColor(GM.RGB(k == key and "accent" or "textDim"))
		end
	end
	return strip
end

-- scroll range readout for pane headers — "1–14 of 47" or "" when the
-- list fits. Anchor fs at the pane header's RIGHT edge.
function W.ScrollText(fs, off, visible, total)
	if not fs then return end
	off = off or 0
	if (total or 0) <= visible then
		fs:SetText("")
	else
		fs:SetText(GM.CC("textDim") ..
			string.format("%d–%d of %d", off + 1,
				math.min(off + visible, total), total) .. "|r")
	end
end

-- dropdown popover anchored under a button: entries are
-- { label, checked, cb } rows; wheel-pages long lists, a
-- screen-wide catcher dismisses it. One menu per host frame —
-- re-pressing the same button toggles it closed.
function W.PopupMenu(btn, entries, opts)
	opts = opts or {}
	local host = opts.host or (btn and btn:GetParent()) or UIParent
	local m = host._gmMenu
	if m and m:IsShown() and m.btn == btn then
		m:Hide()
		if m.catcher then m.catcher:Hide() end
		return
	end
	if not m then
		local catcher = CreateFrame("Button", nil, host)
		catcher:SetAllPoints(UIParent)
		catcher:SetFrameLevel(host:GetFrameLevel() + 39)
		catcher:SetScript("OnClick", function()
			host._gmMenu:Hide()
			catcher:Hide()
		end)
		m = CreateFrame("Frame", nil, host)
		m:SetFrameLevel(host:GetFrameLevel() + 40)
		GM.Panel(m, "contLow", "outline")
		m.catcher = catcher
		host._gmMenu = m
	end
	if not (entries and #entries > 0) then return end
	local w = opts.w or 220
	local MAX = opts.maxRows or 14
	local vis = math.min(#entries, MAX)
	m.btns = m.btns or {}
	m.off = 0
	local function Paint()
		for _, b in ipairs(m.btns) do b:Hide() end
		for i = 1, vis do
			local e = entries[m.off + i]
			if not e then break end
			local b = m.btns[i]
			if not b then
				b = CreateFrame("Button", nil, m)
				b:SetHeight(18)
				b.text = GM.MakeFontString(b, GM.FONT, 10, "text")
				b.text:SetPoint("LEFT", 6, 0)
				b.text:SetWidth(w - 12)
				b.text:SetWordWrap(false)
				local hov = b:CreateTexture(nil, "ARTWORK")
				hov:SetAllPoints()
				hov:SetColorTexture(GM.RGB("contHigh"))
				hov:Hide()
				b:SetScript("OnEnter", function() hov:Show() end)
				b:SetScript("OnLeave", function() hov:Hide() end)
				m.btns[i] = b
			end
			b:SetWidth(w)
			b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
			b.text:SetJustifyH(opts.justify or "LEFT")
			-- raw: dynamic data (group paths, zone names) — LT on
			-- those logs "unregistered L key" against the strict
			-- localizer for every entry, every open
			b.text:SetText((opts.raw or e.raw) and e.label or LT(e.label))
			b.text:SetTextColor(GM.RGB(e.checked and "accent" or "text"))
			b:SetScript("OnClick", function()
				m:Hide()
				m.catcher:Hide()
				e.cb()
			end)
			b:Show()
		end
	end
	m:EnableMouseWheel(true)
	m:SetScript("OnMouseWheel", function(_, d)
		m.off = math.min(math.max(0, #entries - vis),
			math.max(0, m.off - d))
		Paint()
	end)
	Paint()
	m:SetSize(w + 4, 4 + vis * 18)
	-- TOPRIGHT grows the menu left of the button — flip when that
	-- would underflow the screen edge; the clamp is the hard guard
	m:ClearAllPoints()
	local br = btn and btn:GetRight() or 0
	if br - (w + 4) < 0 then
		m:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
	else
		m:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
	end
	m:SetClampedToScreen(true)
	m.btn = btn
	m:Show()
	m.catcher:Show()
end

-- forward decl: XferOpen/AcctRow/AcctAdd all repaint through it;
-- defined below near AcctRow
local AcctRefresh

-- account-to-account transfer popover: amount + destination
-- dropdown + SEND, bank-app style. One per host panel, re-anchored
-- under the row that opened it; the PopupMenu catcher-dismiss
-- pattern. B.Transfer owns validation — a rejected send flashes
-- the amount red (bad input or insufficient funds).
function W.XferOpen(row, fromIdx)
	local p = row:GetParent()
	local pop = p._gmXfer
	if not pop then
		local catcher = CreateFrame("Button", nil, p)
		catcher:SetAllPoints(UIParent)
		catcher:SetFrameLevel(p:GetFrameLevel() + 39)
		pop = CreateFrame("Frame", nil, p)
		pop:SetSize(256, 50)
		pop:SetFrameLevel(p:GetFrameLevel() + 40)
		GM.Panel(pop, "contLow", "outline")
		pop.catcher = catcher
		catcher:SetScript("OnClick", function()
			pop:Hide() catcher:Hide()
		end)
		local title = GM.MakeFontString(pop, GM.FONT_MED, 9, "secondary")
		title:SetPoint("TOPLEFT", 8, -6)
		pop.title = title
		local amt = W.EditBox(pop, 80, "0g")
		amt:SetPoint("TOPLEFT", 8, -26)
		pop.amt = amt
		local toLbl = GM.MakeFontString(pop, GM.FONT, 9, "textDim")
		toLbl:SetPoint("LEFT", amt, "RIGHT", 6, 0)
		toLbl:SetText(LT("to"))
		local dest = CreateFrame("Button", nil, pop)
		dest:SetSize(96, 20)
		dest:SetPoint("LEFT", toLbl, "RIGHT", 4, 0)
		GM.Panel(dest, "contMedium")
		dest.text = GM.MakeFontString(dest, GM.FONT, 9, "text")
		dest.text:SetPoint("LEFT", 5, 0)
		dest.text:SetPoint("RIGHT", -4, 0)
		dest.text:SetJustifyH("LEFT")
		dest.text:SetWordWrap(false)
		pop.dest = dest
		local send = CreateFrame("Button", nil, pop)
		send:SetSize(50, 18)
		send:SetPoint("TOPRIGHT", -6, -5)
		GM.Panel(send, "accent")
		send.text = GM.MakeFontString(send, GM.FONT_BOLD, 9, "contLowest")
		send.text:SetPoint("CENTER")
		send.text:SetText(LT("SEND"))
		send:SetScript("OnClick", function()
			local v = GM.Budget.ParseMoney(pop.amt:GetText())
			if v and GM.Budget.Transfer(pop._from, pop._dest, v) then
				pop:Hide() pop.catcher:Hide()
				AcctRefresh()
			else
				pop.amt:SetTextColor(GM.RGB("err"))
			end
		end)
		W.Tip(send, function() return {
			"Move the amount to the",
			"destination account —",
			"journaled like a bank transfer" } end)
		p._gmXfer = pop
	end
	pop._from = fromIdx
	local src = GM.Budget.List()[fromIdx]
	pop.title:SetText(LT("TRANSFER") .. "   "
		.. GM.CC("textDim") .. "from|r " .. (src and src.name or "?"))
	local targets = GM.Budget.TransferTargets(fromIdx)
	pop._dest = targets[1] and targets[1].i
	local function PaintDest()
		local name = "—"
		for _, tg in ipairs(targets) do
			if tg.i == pop._dest then
				name = tg.a.name .. (tg.a.pool and " (pool)" or "")
			end
		end
		pop.dest.text:SetText(name)
	end
	pop.dest:SetScript("OnClick", function()
		local entries = {}
		for _, tg in ipairs(targets) do
			local ti = tg.i
			entries[#entries + 1] = {
				label = tg.a.name .. (tg.a.pool and " (pool)" or ""),
				checked = pop._dest == ti,
				cb = function() pop._dest = ti PaintDest() end,
			}
		end
		W.PopupMenu(pop.dest, entries, { raw = true, w = 150 })
	end)
	PaintDest()
	pop.amt:SetText("")
	pop.amt:SetTextColor(GM.RGB("text"))
	pop:ClearAllPoints()
	pop:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -4)
	pop:Show()
	pop.catcher:Show()
end

-- standard frame furniture: title + close X, shared offsets so every
-- window's chrome sits identically
function W.Chrome(f, name, titleText)
	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(LT(titleText))
	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)
	W.Tip(close, function() return { "Close", "ESC also closes" } end)
	return title
end

-- ============ budget account controls (shared) ============
-- One row contract for every surface that lists budget accounts —
-- dashboard BUDGETS and overview ACCOUNTS both build rows through
-- W.AcctRow and paint through W.PaintAcctRow, so add/cycle/bind/
-- reset/delete behave identically on either window.

AcctRefresh = function()
	-- repaint every surface that might show this account
	GM.View.Refresh("planner")
	GM.View.Refresh("overview")
end

-- row: name · kind cycle · group bind · alloc · remaining · reset · del
-- compact drops the alloc column so remaining keeps readable width
function W.AcctRow(parent, idx, compact)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(24)
	local nameW = compact and 88 or 104
	local grpW = compact and 100 or 120

	-- name is an editable label: click swaps to an aligned field,
	-- Enter commits (B.Rename validates empty/dup), Esc cancels
	local nameBtn = W.EditableLabel(row, nameW)
	nameBtn:SetPoint("LEFT", 2, 0)
	row.name = nameBtn.label
	row.nameBtn = nameBtn
	-- fold chevron: overview nests each char's named accounts under
	-- their pool — the chevron rides the pool row's left gutter and
	-- only paints when the row carries children. Blizzard's own
	-- plus/minus textures: the ▸/▾ glyphs don't exist in Montserrat
	local fold = CreateFrame("Button", nil, row)
	fold:SetSize(14, 18)
	fold:SetPoint("LEFT", 2, 0)
	fold.tex = fold:CreateTexture(nil, "ARTWORK")
	fold.tex:SetSize(14, 14)
	fold.tex:SetPoint("CENTER")
	fold:Hide()
	row.fold = fold
	nameBtn:SetScript("OnClick", function()
		local a = GM.Budget.List()[row._idx or idx]
		if not a then return end
		nameBtn.Open(a.name, function(text)
			GM.Budget.Rename(row._idx or idx, text)
			AcctRefresh()
		end)
	end)
	W.Tip(nameBtn, function() return {
		"Rename account", "click to edit the name" } end)

	local kind = CreateFrame("Button", nil, row)
	kind:SetSize(50, 20)
	-- ride the name button's right edge so ind/fold indents carry
	-- the whole row, not just the name
	kind:SetPoint("LEFT", nameBtn, "RIGHT", 4, 0)
	GM.Panel(kind, "contHigh")
	kind.text = GM.MakeFontString(kind, GM.FONT_MED, 9, "secondary")
	kind.text:SetPoint("CENTER")
	kind.text:SetWidth(46)
	kind.text:SetWordWrap(false)
	kind:SetScript("OnClick", function()
		local a = GM.Budget.List()[row._idx or idx]
		if not a or a.pool then return end
		-- pools can't rekind — the pool flag owns the row's function
		-- regardless of the underlying kind field
		local order = GM.Budget.KIND_ORDER
		for j, k in ipairs(order) do
			if k == a.kind then
				GM.Budget.SetKind(row._idx or idx, order[j % #order + 1])
				break
			end
		end
		AcctRefresh()
	end)
	W.Tip(kind, function()
		local a = GM.Budget.List()[row._idx or idx]
		if a and a.pool then return {
			"The char's purse",
			"every copper no other account claims —",
			"it can't change function" } end
		return {
			"Account function",
			"craft: mat/craft spends · ah: auction spends",
			"save: reserve that never leaves",
			"click to cycle" }
	end)
	row.kind = kind

	local grp = CreateFrame("Button", nil, row)
	grp:SetSize(grpW, 20)
	grp:SetPoint("LEFT", kind, "RIGHT", 6, 0)
	GM.Panel(grp, "contMedium")
	grp.text = GM.MakeFontString(grp, GM.FONT, 9, "textDim")
	grp.text:SetPoint("LEFT", 5, 0)
	grp.text:SetPoint("RIGHT", -4, 0)
	grp.text:SetJustifyH("LEFT")
	grp.text:SetWordWrap(false)
	grp:SetScript("OnClick", function()
		local a = GM.Budget.List()[row._idx or idx]
		if not a then return end
		local ri = row._idx or idx
		-- real dropdown: blind cycling through a dozen group paths
		-- read like a dead text box
		local entries = { {
			label = "— unbound",
			checked = not a.group,
			cb = function() GM.Budget.SetGroup(ri, nil) AcctRefresh() end,
		} }
		for _, p in ipairs(GM.Budget.GroupPaths()) do
			local path = p
			entries[#entries + 1] = {
				label = path,
				checked = a.group == path,
				cb = function()
					GM.Budget.SetGroup(ri, path)
					AcctRefresh()
				end,
			}
		end
		W.PopupMenu(grp, entries,
			{ w = math.max(160, grpW + 40), raw = true })
	end)
	W.Tip(grp, function() return {
		"Group binding",
		"items in this group route their",
		"spends and sales to this account",
		"click for the group list" } end)
	row.grp = grp

	row.alloc = GM.MakeFontString(row, GM.FONT, 10, "text")
	row.alloc:SetPoint("LEFT", grp, "RIGHT", 8, 0)
	row.alloc:SetWidth(90)
	row.alloc:SetJustifyH("LEFT")
	if compact then row.alloc:Hide() end

	row.left = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.left:SetPoint("LEFT",
		compact and grp or row.alloc, "RIGHT", 6, 0)
	row.left:SetJustifyH("LEFT")
	row.left:SetWordWrap(false)

	local del = CreateFrame("Button", nil, row)
	del:SetSize(16, 16)
	del:SetPoint("RIGHT", 0, 0)
	del.text = GM.MakeFontString(del, GM.FONT_BOLD, 10, "textDim")
	del.text:SetPoint("CENTER")
	del.text:SetText("x")
	del:SetScript("OnClick", function()
		GM.Budget.Del(row._idx or idx)
		AcctRefresh()
	end)
	W.Tip(del, function() return { "Delete account" } end)
	row.del = del

	local rst = CreateFrame("Button", nil, row)
	rst:SetSize(16, 16)
	rst:SetPoint("RIGHT", del, "LEFT", -4, 0)
	rst.text = GM.MakeFontString(rst, GM.FONT_BOLD, 9, "textDim")
	rst.text:SetPoint("CENTER")
	rst.text:SetText("r")
	rst:SetScript("OnClick", function()
		GM.Budget.ResetSpent(row._idx or idx)
		AcctRefresh()
	end)
	W.Tip(rst, function() return { "Reset spent to zero" } end)
	row.rst = rst

	-- transfer: move copper between this char's accounts — the
	-- bank-app primitive, journaled as a transfer line
	local xfr = CreateFrame("Button", nil, row)
	xfr:SetSize(16, 16)
	xfr:SetPoint("RIGHT", rst, "LEFT", -4, 0)
	xfr.text = GM.MakeFontString(xfr, GM.FONT_BOLD, 10, "textDim")
	xfr.text:SetPoint("CENTER")
	xfr.text:SetText("→")
	xfr:SetScript("OnClick", function()
		W.XferOpen(row, row._idx or idx)
	end)
	W.Tip(xfr, function() return {
		"Transfer gold",
		"move copper to another of this",
		"char's accounts — journaled",
		"like a bank transfer" } end)
	row.xfr = xfr

	-- 7d income/spend column: fixed-width right-justified block before
	-- the row buttons; `left` re-anchors to it so nothing overlaps
	row.flow = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.flow:SetPoint("RIGHT", xfr, "LEFT", -8, 0)
	row.flow:SetWidth(140)
	row.flow:SetJustifyH("RIGHT")
	row.flow:SetWordWrap(false)

	-- left text stops before the flow column
	row.left:SetPoint("RIGHT", row.flow, "LEFT", -8, 0)
	return row
end

-- unified paint: alloc text per kind, save accounts show "reserved",
-- spend accounts show left + spent (red when overdrawn)
function W.PaintAcctRow(row, a, idx, opts)
	opts = opts or {}
	row._idx = idx
	-- nest/fold: children indent past the chevron gutter; pool rows
	-- with kids carry the fold glyph at the far left
	row.nameBtn:ClearAllPoints()
	row.nameBtn:SetPoint("LEFT",
		2 + (opts.indent or 0) * 16 + (opts.fold and 14 or 0), 0)
	if opts.fold then
		row.fold:Show()
		row.fold.tex:SetTexture(opts.fold == "closed"
			and "Interface\\Buttons\\UI-PlusButton-Up"
			or "Interface\\Buttons\\UI-MinusButton-Up")
		row.fold:SetScript("OnClick", opts.onFold)
	else
		row.fold:Hide()
	end
	local ck = GM.Budget.OwnerKey and GM.Budget.OwnerKey(a)
	local label = a.name
	if ck then
		label = (GM.Budget.Crest(ck) or "")
			.. GM.Budget.CharCC(ck) .. a.name .. "|r"
		-- an alt's named account needs its owner spelled out — the
		-- pool's name already IS the char's, so it skips the tag
		if not GM.IsSelfCharKey(ck)
			and a.name ~= GM.Budget.CharName(ck) then
			label = label .. GM.CC("textDim") .. " · "
				.. GM.Budget.CharName(ck) .. "|r"
		end
	end
	row.name:SetText(label)
	-- crest pad, exact: measure the crest escape itself — texture
	-- escapes measure at display width, so this lands the field's
	-- text on the name no matter what suffix the label carries
	row._measure = row._measure
		or GM.MakeFontString(row, GM.FONT, 10, "text")
	row._measure:SetText(ck and GM.Budget.Crest(ck) or "")
	row.nameBtn.pad = row._measure:GetStringWidth() or 0
	row.nameBtn.Layout()
	row.kind.text:SetText(a.pool and "POOL" or GM.Budget.KINDS[a.kind])
	-- the pool IS every group — it can't be deleted or rebound, so
	-- both controls hide on pool rows; a stale binding left by the
	-- old cycler gets cleared for honesty
	if a.pool and a.group then
		a.group = nil
	end
	row.grp:SetShown(not a.pool)
	row.del:SetShown(not a.pool)
	row.grp.text:SetText(a.group or "—")
	row.grp.text:SetTextColor(GM.RGB(a.group and "accent" or "textDim"))
	row.alloc:SetText(GM.Budget.AllocText(a))
	local rem = GM.Budget.Remaining(a)
	if a.kind == "save" then
		row.left:SetText("reserved " .. GM.MoneyShort(rem))
		row.left:SetTextColor(GM.RGB("accent"))
	else
		row.left:SetText("left " .. GM.MoneyShort(rem)
			.. " · spent " .. GM.MoneyShort(a.spent or 0))
		row.left:SetTextColor(GM.RGB(rem > 0 and "textDim" or "err"))
	end
	local fin, fout = GM.Budget.Flow(a)
	if fin then
		row.flow:SetText(GM.CC("pos") .. "+" .. GM.MoneyShort(fin) .. "|r"
			.. GM.CC("textDim") .. " / |r"
			.. GM.CC("warn") .. "-" .. GM.MoneyShort(fout) .. "|r")
	else
		row.flow:SetText("—")
	end
end

-- add-row: name box · kind cycle · amount box · + button.
-- Returns the container; parent anchors it where it wants.
-- parse: bare number = gold for craft/ah budgets, % for saves.
function W.AcctAdd(parent)
	local f = CreateFrame("Frame", nil, parent)
	-- real width, not zero: a 0px-wide region computes a degenerate
	-- rect on this client and every child anchored into it vanishes
	f:SetSize(560, 22)

	local name = W.EditBox(f, 130, "name")
	name:SetPoint("LEFT", 0, 0)

	local addKind = "craft"
	local kindBtn = CreateFrame("Button", nil, f)
	kindBtn:SetSize(56, 20)
	kindBtn:SetPoint("LEFT", name, "RIGHT", 6, 0)
	GM.Panel(kindBtn, "contHigh")
	kindBtn.text = GM.MakeFontString(kindBtn, GM.FONT_MED, 9, "secondary")
	kindBtn.text:SetPoint("CENTER")
	kindBtn.text:SetWidth(52)
	kindBtn.text:SetWordWrap(false)
	local function PaintKind()
		kindBtn.text:SetText(GM.Budget.KINDS[addKind])
	end
	PaintKind()
	kindBtn:SetScript("OnClick", function()
		local order = GM.Budget.KIND_ORDER
		for i, k in ipairs(order) do
			if k == addKind then
				addKind = order[i % #order + 1]
				break
			end
		end
		PaintKind()
	end)
	W.Tip(kindBtn, function() return {
		"New account's function", "click to cycle" } end)

	local amt = W.EditBox(f, 80, "0g")
	amt:SetPoint("LEFT", kindBtn, "RIGHT", 6, 0)

	local btn = CreateFrame("Button", nil, f)
	btn:SetSize(110, 20)
	btn:SetPoint("LEFT", amt, "RIGHT", 6, 0)
	GM.Panel(btn, "accent")
	btn.text = GM.MakeFontString(btn, GM.FONT_BOLD, 9, "contLowest")
	btn.text:SetPoint("CENTER")
	btn.text:SetText(LT("+ NEW ACCOUNT"))

	local hint = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	hint:SetPoint("LEFT", btn, "RIGHT", 8, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText(LT("craft/ah/vendor: gold · save: %"))

	btn:SetScript("OnClick", function()
		local n = name:GetText()
		if n == LT("name") then n = "" end
		local a = amt:GetText()
		local alloc = addKind == "save"
			and tonumber((a or ""):gsub("%%", ""))
			or (tonumber(a) and floor(tonumber(a) * 10000)
				or GM.Budget.ParseMoney(a))
		local acct = alloc and GM.Budget.Add(n, addKind, alloc)
		AcctRefresh()
		if acct then
			name:SetText("")
			amt:SetText(addKind == "save" and "30" or "0g")
			hint:SetText(LT("craft/ah/vendor: gold · save: %"))
		else
			hint:SetText(GM.CC("err")
				.. (addKind == "save" and "need a % (0-100)"
					or "bad amount — try 10g, 5s, 2500c") .. "|r")
		end
	end)
	f.hint = hint
	return f
end

-- Standard module window chrome — every window was hand-copying the
-- same block (strata/toplevel/movable/drag/clamp/panel/ESC/title/x/
-- dashboard tabs) with drift: OrdersUI/OpsUI/CraftingUI missed ESC
-- and clamping, close buttons wandered between "x"/"×" at -6/-8,
-- titles between 12/13pt at 10/12/14px. One recipe, opts for deltas:
--   name, title, w, h, x, y        -- frame basics (CENTER offset)
--   tab                            -- dashboard tab key (nil = no strip)
--   fill, border                   -- GM.Panel colors
--   strata, level                  -- layering overrides
--   onHide                         -- session-teardown hook
--   onClose                        -- fires on X click before Hide
--     (CraftingUI sets ui.closing — deliberate-close semantics)
--   noChrome                       -- frame+drag+panel+ESC only: no
--     title/close/tabs (PlanQueue's title strip is bespoke)
-- Returns frame, titleFS, closeBtn.
function W.Window(o)
	local f = CreateFrame("Frame", o.name, UIParent)
	f:SetSize(o.w or 640, o.h or 480)
	f:SetPoint("CENTER", o.x or 0, o.y or 0)
	-- "normal" window strata on this client (PlanQueue's note): HIGH +
	-- Toplevel stacks with TSM/Ellesmere panels. Toplevel's auto-raise
	-- is unreliable here, so clicks raise manually — last-clicked wins.
	f:SetFrameStrata(o.strata or "HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	if o.level then f:SetFrameLevel(o.level) end
	f:SetScript("OnMouseDown", function(fr)
		if fr.Raise then fr:Raise()
		elseif RaiseFrame then RaiseFrame(fr) end
	end)
	GM.Panel(f, o.fill or "contLow", o.border or "outlineVar")
	if o.name then tinsert(UISpecialFrames, o.name) end
	f:Hide()
	if o.onHide then f:SetScript("OnHide", o.onHide) end
	if o.noChrome then return f end

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(LT(o.title or ""))
	f.titleFs = title

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function()
		if o.onClose then o.onClose() end
		f:Hide()
	end)
	f.closeBtn = close

	if o.tab and GM.Dashboard and GM.Dashboard.AddTabs then
		GM.Dashboard.AddTabs(f, title, o.tab)
	end
	return f, title, close
end

-- Blizzard-style coin input: three digit boxes with persistent
-- g/s/c unit labels — the canonical way to enter coin values, one
-- implementation for every field (writ price, mail money, AH price
-- filters + post dialog). :GetCopper() returns copper, or nil when
-- all three boxes are empty so callers can tell "0c" from "blank".
-- :SetCopper splits a copper value back out; nil/<=0 clears.
-- Tab walks g→s→c. Sub-boxes are exposed (.g/.s/.c) for callers
-- that wire Enter/Escape handlers.
function W.GoldEdit(parent, w)
	local h = CreateFrame("Frame", nil, parent)
	w = w or 118
	h:SetSize(w, 18)
	-- gold gets the extra room (the big number); silver/copper are
	-- two-digit by construction like Blizzard's own coin fields
	local gw = math.max(34, math.floor(w * 0.42))
	local sw = math.max(20, math.floor((w - gw - 24) / 2))
	local function mk(ww, maxc)
		local e = CreateFrame("EditBox", nil, h)
		e:SetSize(ww, 18)
		e:SetAutoFocus(false)
		e:SetFont(GM.FONT, 10, "")
		e:SetTextColor(GM.RGB("text"))
		e:SetTextInsets(4, 2, 0, 0)
		e:SetMaxLetters(maxc)
		GM.Panel(e, "contLowest")
		e:SetScript("OnTextChanged", function(s)
			local t = s:GetText():gsub("%D", "")
			if t ~= s:GetText() then s:SetText(t) end
		end)
		e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
		return e
	end
	local function unit(anchor, txt, color)
		local fs = GM.MakeFontString(h, GM.FONT, 9, color)
		fs:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
		fs:SetText(txt)
		return fs
	end
	h.g = mk(gw, 7)
	h.g:SetPoint("LEFT", 0, 0)
	local lg = unit(h.g, "g", "accent")
	h.s = mk(sw, 2)
	h.s:SetPoint("LEFT", lg, "RIGHT", 4, 0)
	local ls = unit(h.s, "s", "textDim")
	h.c = mk(sw, 2)
	h.c:SetPoint("LEFT", ls, "RIGHT", 4, 0)
	unit(h.c, "c", "textDim")
	h.g:SetScript("OnTabPressed", function() h.s:SetFocus() end)
	h.s:SetScript("OnTabPressed", function() h.c:SetFocus() end)
	h.c:SetScript("OnTabPressed", function() h.c:ClearFocus() end)
	local function digits(e) return tonumber(e:GetText()) or 0 end
	function h:GetCopper()
		local t = digits(h.g) * 10000 + digits(h.s) * 100 + digits(h.c)
		if t == 0 and h.g:GetText() == "" and h.s:GetText() == ""
			and h.c:GetText() == "" then
			return nil
		end
		return t
	end
	function h:SetCopper(v)
		if not v or v <= 0 then
			h.g:SetText(""); h.s:SetText(""); h.c:SetText("")
			return
		end
		h.g:SetText(tostring(math.floor(v / 10000)))
		h.s:SetText(tostring(math.floor(v / 100) % 100))
		h.c:SetText(tostring(v % 100))
	end
	function h:SetFocus() h.g:SetFocus() end
	return h
end

-- W.ItemSlot(parent, opts) — the shared item-target strip lifted
-- from the planner header: bordered icon slot (real item tooltip
-- on hover) + name + meta sub-line, accepting drag/drop,
-- click-with-item-on-cursor, and modified-click passthrough.
-- opts: w, h, icon, hint, nameSize, subSize, onItem(id, link).
-- Fields: .icon .iconBtn .name .sub · .itemID .itemLink
-- Methods: :SetItem(id, link) paints it; :Clear() back to hint.
function W.ItemSlot(parent, opts)
	opts = opts or {}
	local h = opts.h or 56
	local iconSz = opts.icon or (h - 12)
	local f = CreateFrame("Button", nil, parent)
	f:SetHeight(h)
	if opts.w then f:SetWidth(opts.w) end
	GM.Panel(f, "contMedium")
	if GM.ChromePanel then GM.ChromePanel(f) end
	f:SetScript("OnEnter", function() GM.Panel(f, "contHigh") end)
	f:SetScript("OnLeave", function() GM.Panel(f, "contMedium") end)

	local iconBox = CreateFrame("Frame", nil, f)
	iconBox:SetSize(iconSz, iconSz)
	iconBox:SetPoint("LEFT", 6, 0)
	GM.Panel(iconBox, "contHighest", "outlineVar")
	if GM.ChromePanel then GM.ChromePanel(iconBox) end
	f.icon = iconBox:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(iconSz - 4, iconSz - 4)
	f.icon:SetPoint("CENTER")
	-- hover → real item tooltip (textures can't take scripts)
	f.iconBtn = CreateFrame("Button", nil, iconBox)
	f.iconBtn:SetAllPoints()
	f.iconBtn:SetScript("OnEnter", function(s)
		if not s.itemID then return end
		GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(s.itemID)
		else
			GameTooltip:SetHyperlink("item:" .. s.itemID)
		end
		GameTooltip:Show()
	end)
	f.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- compact slots can't stack name+sub at the roomy offsets —
	-- the sub would spill past the bottom edge, so the pair hugs
	-- the icon's vertical span: name top at the icon top centers
	-- the two-line block on the icon (which is slot-centered)
	local compact = h <= 30
	f.name = GM.MakeFontString(f, GM.FONT_MED,
		opts.nameSize or 12, "text")
	f.name:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 10, compact and 0 or -4)
	f.name:SetPoint("RIGHT", f, "RIGHT", -8, 0)
	f.name:SetJustifyH("LEFT")
	f.name:SetWordWrap(false)
	f.sub = GM.MakeFontString(f, GM.FONT, opts.subSize or 10, "textDim")
	f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, compact and 0 or -4)
	f.sub:SetPoint("RIGHT", f, "RIGHT", -8, 0)
	f.sub:SetJustifyH("LEFT")

	local function Drop()
		local infoType, itemID, link = GetCursorInfo()
		if infoType ~= "item" then return end
		ClearCursor()
		if opts.onItem then opts.onItem(itemID, link) end
	end
	local function Click()
		if IsModifiedClick() then
			GM.ModifiedItemClick(f.iconBtn.itemID)
		elseif CursorHasItem() then
			Drop()
		end
	end
	f:EnableMouse(true)
	f:SetScript("OnReceiveDrag", Drop)
	f:SetScript("OnClick", Click)
	-- the icon button sits on top — mirror handlers or its clicks die
	f.iconBtn:SetScript("OnReceiveDrag", Drop)
	f.iconBtn:SetScript("OnClick", Click)

	function f:SetItem(id, link)
		f.itemID, f.itemLink = id, link
		f.iconBtn.itemID = id
		local name = (link and link:find("%[") and link)
			or (id and GM.ItemName and GM.ItemName(id))
			or (id and ("item " .. id))
		f.name:SetText(name or "")
		if id and GM.NameColor then
			f.name:SetTextColor(GM.NameColor(id))
		end
		local icon = id and ((C_Item and C_Item.GetItemIconByID
			and C_Item.GetItemIconByID(id))
			or (C_Item and C_Item.GetItemInfo
				and select(10, C_Item.GetItemInfo(id))))
		if icon then f.icon:SetTexture(icon) f.icon:Show()
		else f.icon:Hide() end
		f.sub:SetText(id and ("id " .. id) or "")
	end
	function f:Clear()
		f.itemID, f.itemLink = nil, nil
		f.iconBtn.itemID = nil
		f.icon:Hide()
		f.name:SetText(GM.CC("textDim")
			.. LT(opts.hint or "drop item here · shift-click one")
			.. "|r")
		f.sub:SetText("")
	end
	f:Clear()
	return f
end

-- compact item row: icon + rarity-colored name on the left,
-- "pct% · price · ~vel/d" right-aligned. The shared shape any
-- list needs when a row IS one item — hover shows the real item
-- tooltip, shift/ctrl click runs Blizzard's default chain (chat
-- link, dress-up, context transfers) via W.ModifiedClick.
-- SetItem accepts an itemID or {id|itemID, name, price, vel,
-- pct}; price/vel fall back to GM.ItemEntry's market fields
-- unless opts.auto = false. opts.onClick fires only on a plain
-- left click — modified clicks belong to the default chain.
function W.ItemRow(parent, opts)
	opts = opts or {}
	local h = opts.h or 18
	local iconSz = opts.icon or (h - 4)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(h)
	if opts.w then row:SetWidth(opts.w) end
	W.HoverTint(row)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(iconSz, iconSz)
	row.icon:SetPoint("LEFT", 2, 0)
	row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

	-- right block, anchored inside-out: ~vel/d · price · rate · pct
	row.vel = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.vel:SetPoint("RIGHT", -4, 0)
	row.vel:SetJustifyH("RIGHT")
	row.price = W.Money(row, { size = 9 })
	row.price:SetPoint("RIGHT", row.vel, "LEFT", -6, 0)
	row.price:SetJustifyH("RIGHT")
	-- expected qty per event ("0.6/k") — the drop RATE alongside
	-- pct's drop CHANCE
	row.rate = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.rate:SetPoint("RIGHT", row.price, "LEFT", -6, 0)
	row.rate:SetJustifyH("RIGHT")
	row.pct = GM.MakeFontString(row, GM.FONT, 9, "textDim")
	row.pct:SetPoint("RIGHT", row.rate, "LEFT", -6, 0)
	row.pct:SetJustifyH("RIGHT")

	row.name = GM.MakeFontString(row, GM.FONT,
		opts.nameSize or 10, "text")
	row.name:SetPoint("LEFT", iconSz + 6, 0)
	row.name:SetPoint("RIGHT", row.pct, "LEFT", -8, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row:SetScript("OnEnter", function(self)
		if not self.id then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(self.id)
		else
			GameTooltip:SetHyperlink("item:" .. self.id)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	if opts.onClick then
		row:SetScript("OnClick", function(self)
			if IsModifiedClick() or not self.id then return end
			opts.onClick(self, self.id)
		end)
	end
	W.ModifiedClick(row, function() return row.id end)

	function row:SetItem(d)
		local id = type(d) == "table" and (d.id or d.itemID) or d
		row.id = id
		if not id then row:Clear() return end
		row:SetAlpha(1)
		row.icon:SetTexture(GM.ItemIcon and GM.ItemIcon(id)
			or "Interface\\Icons\\INV_Misc_QuestionMark")
		local nm = type(d) == "table" and d.name or nil
		row.name:SetText((nm and nm ~= "" and nm)
			or GM.ItemNameOr(id))
		row.name:SetTextColor(GM.NameColor(id))
		local price = type(d) == "table" and d.price or nil
		local vel = type(d) == "table" and d.vel or nil
		if opts.auto ~= false and (not price or not vel) then
			local e = GM.ItemEntry and GM.ItemEntry(id)
			if e then
				price = price or (e.mb or e.p or e.mkt)
				vel = vel or e.vel
			end
		end
		if price and price > 0 then
			row.price:SetCopper(price)
		else
			row.price:SetText("")
		end
		local vr = GM.VelRate and GM.VelRate(vel)
		row.vel:SetText(vr and ("· ~" .. vr .. "/d") or "")
		local pct = type(d) == "table" and d.pct or nil
		row.pct:SetText(pct and format("%d%%", pct + 0.5) or "")
		local rate = type(d) == "table" and d.rate or nil
		row.rate:SetText(rate and format("%.2g/k", rate) or "")
	end
	function row:Clear()
		row.id = nil
		row.icon:SetTexture(
			"Interface\\Icons\\INV_Misc_QuestionMark")
		row.name:SetText("")
		row.pct:SetText("")
		row.rate:SetText("")
		row.price:SetText("")
		row.vel:SetText("")
	end
	return row
end

-- dense item row: zebra striping, icon, rarity-colored name and
-- a caller-defined column grid — the shared skeleton behind
-- Destroying/Sniper-style tables. cols = { {key, x, w, size,
-- color, align, font, maxLines, right} } → row[key] = the
-- fontstring (right anchors at offset x instead of LEFT).
-- Same item contract as W.ItemRow: SetItem(id|{id,name}), hover
-- tooltip, modified clicks. opts.onClick = plain left click
-- (modified clicks are consumed by the chain).
function W.ColumnRow(parent, opts)
	opts = opts or {}
	local h = opts.h or 20
	local iconSz = opts.icon or 16
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(h)
	if opts.w then row:SetWidth(opts.w) end
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	W.HoverTint(row)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(iconSz, iconSz)
	row.icon:SetPoint("LEFT", 4, 0)
	row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

	row.name = GM.MakeFontString(row, GM.FONT,
		opts.nameSize or 10, "text")
	row.name:SetPoint("LEFT", iconSz + 10, 0)
	row.name:SetWidth(opts.nameW or 180)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	for _, c in ipairs(opts.cols or {}) do
		local fs = GM.MakeFontString(row, c.font or GM.FONT,
			c.size or 10, c.color or "text")
		fs:SetPoint(c.right and "RIGHT" or "LEFT", c.x, 0)
		if c.w then fs:SetWidth(c.w) end
		if c.maxLines then fs:SetMaxLines(c.maxLines) end
		fs:SetJustifyH(c.align or "LEFT")
		fs:SetWordWrap(false)
		row[c.key] = fs
	end

	row:SetScript("OnEnter", function(self)
		if not self.id then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then
			GameTooltip:SetItemByID(self.id)
		else
			GameTooltip:SetHyperlink("item:" .. self.id)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	if opts.onClick then
		row:SetScript("OnClick", function(self)
			if IsModifiedClick() or not self.id then return end
			opts.onClick(self, self.id)
		end)
	end
	W.ModifiedClick(row, function() return row.id end)

	function row:SetItem(d)
		local id = type(d) == "table" and (d.id or d.itemID) or d
		row.id = id
		row.icon:SetTexture(
			id and GM.ItemIcon and GM.ItemIcon(id)
			or "Interface\\Icons\\INV_Misc_QuestionMark")
		local nm = type(d) == "table" and d.name or nil
		row.name:SetText((type(nm) == "string" and nm ~= "" and nm)
			or (id and GM.ItemNameOr(id)) or "")
		-- `a and X or Y` truncates to one arg — SetTextColor needs
		-- the full triple so pick the source, not the expression
		if id then row.name:SetTextColor(GM.NameColor(id))
		else row.name:SetTextColor(GM.RGB("text")) end
	end
	-- zebra parity lives on the row so reordered pools repaint right
	function row:SetZebra(i)
		row.bg:SetColorTexture(GM.RGB(
			i % 2 == 0 and "contMedium" or "contLowest"))
	end
	return row
end

-- currency text — a fontstring that formats copper through the
-- coin-colored GM.Money/MoneyShort/Signed formatters, so every
-- money field gets g/s/c metal colors for free. opts.suffix
-- appends after every set ("/min" on rate columns); fs._prefix
-- prepends before the value (a "~" estimate marker).
function W.Money(parent, opts)
	opts = opts or {}
	local fs = GM.MakeFontString(parent, opts.font or GM.FONT,
		opts.size or 10, opts.color or "text")
	fs.SetCopper = function(self, c, suffix)
		self:SetText((self._prefix or "") .. GM.Money(c)
			.. (suffix or opts.suffix or ""))
	end
	fs.SetCopperShort = function(self, c, suffix)
		self:SetText((self._prefix or "") .. GM.MoneyShort(c)
			.. (suffix or opts.suffix or ""))
	end
	fs.SetSigned = function(self, c, suffix)
		self:SetText((self._prefix or "") .. GM.Signed(c)
			.. (suffix or opts.suffix or ""))
	end
	if opts.copper then fs:SetCopper(opts.copper) end
	return fs
end

-- drop-table rows for tooltips — returns STRINGS (not written to
-- a frame) because Gathering.lua's tooltip injector caches and
-- re-AddLines them on client redraws. Each row renders
-- "name  pct%  coin-value"; when opts.target names a hunted item
-- the matching row stays accent-bright with a > marker and every
-- other row fades to textDim. rows: {id, name, pct, value}
function W.DropLines(rows, opts)
	opts = opts or {}
	local tid = opts.target
	local out, shown = {}, 0
	for _, r in ipairs(rows or {}) do
		if shown >= (opts.max or 8) then
			out[#out + 1] = GM.CC("textDim") .. "   +"
				.. (#rows - shown) .. " more|r"
			break
		end
		local hit = tid ~= nil and r.id == tid
		local c = hit and "accent" or (tid and "textDim" or "text")
		local pct = r.pct
			and format(" %d%%", floor(r.pct + 0.5)) or ""
		out[#out + 1] = format("%s%s %s%s|r%s",
			GM.CC(c), hit and ">" or "·", r.name, pct,
			r.value and ("  " .. GM.MoneyShort(r.value)) or "")
		shown = shown + 1
	end
	return out
end
