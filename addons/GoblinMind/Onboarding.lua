local _, GM = ...

-- Onboarding — a multi-page first-run wizard; more pages slot in by
-- appending to PAGES. The addon can't touch the filesystem, so every
-- config page stages a hex request in SavedVariables — the brain
-- watcher picks them up on the next SV flush and writes feeds.json:
--
--   page 1 BACKEND   — crowdsource price feed (optional). CONNECT
--                      stages a bm- request and advances to API;
--                      SKIP is permanent and also goes to API (the
--                      Blizzard feed is independent — solo players
--                      deserve it too). LATER re-asks next login.
--   page 2 API       — Blizzard auction API credentials (optional).
--                      SAVE stages an api- request; SKIP goes to IMPORT.
--   page 3 IMPORT    — compatible-addon settings (TSM etc.) via
--                      GM.Import; /goblin import opens it directly.
--   page 4 APP       — the companion app: where it lives, one
--                      double-click to start, self-registers.
--   page 5 OPTIONS   — persistent toggles (spoiler-free crafting
--                      today; more later).
--
-- The watcher itself is the "external program": every page that
-- stages something shows a hint when no recent emit exists —
-- GM.EmitAge() tells us the brain hasn't run yet.

GM.Onboard = {}
local OB = GM.Onboard

local W = GM.Widgets
local Btn = W and W.Btn

local ui

local PAGES = { "backend", "api", "import", "app", "options" }
local TITLES = {
	backend = "CONNECT TO A PRICE SERVER",
	api = "BLIZZARD PRICE FEED",
	import = "BRING YOUR OLD SETUP",
	app = "START THE COMPANION APP",
	options = "OPTIONS",
}
local PAGE_IX = {}
for i, n in ipairs(PAGES) do PAGE_IX[n] = i end

local function Configured()
	local be = GoblinMindDB and GoblinMindDB.backend
	return be and (be.url or be.pull or be.up or (be.peers or 0) > 0)
		and true or false
end

local function WatchHint(parent)
	-- one-line "start the brain" hint — Refresh() fills/hides it
	local fs = GM.MakeFontString(parent, GM.FONT, 9, "warn")
	fs:SetPoint("BOTTOMLEFT", 12, 30)
	fs:SetWidth(436)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end

local Refresh  -- forward decl — SetPage calls it on every switch

local function SetPage(p)
	local n = type(p) == "number" and p or PAGE_IX[p] or 1
	ui.page = n
	for i, pg in ipairs(ui.pages) do pg:SetShown(i == n) end
	ui.title:SetText(TITLES[PAGES[n]] or "GOBLINMIND")
	if PAGES[n] == "import" and ui.RefreshImport then
		ui.RefreshImport()
	end
	-- the app page's status/path lines read live emit state —
	-- recompute on every page switch, not just on open
	Refresh()
end

local function Build()
	if ui then return end
	local f = CreateFrame("Frame", "GoblinMindOnboardFrame", UIParent)
	f:SetSize(460, 400)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	GM.Panel(f, "contLow")
	tinsert(UISpecialFrames, "GoblinMindOnboardFrame")
	ui = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	ui.title = title

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)
	-- every hide that isn't the DONE button = dismissed mid-flow;
	-- MaybeShow re-opens it at login until the wizard is finished
	f:SetScript("OnHide", function()
		if f._done then return end
		if GM.db then GM.db.obDismissed = time() end
	end)

	ui.pages = {}
	for i = 1, #PAGES do
		local pg = CreateFrame("Frame", nil, f)
		pg:SetAllPoints()
		pg:Hide()
		ui.pages[i] = pg
	end
	local p1, p2, p3, p4, p5 = ui.pages[1], ui.pages[2], ui.pages[3],
		ui.pages[4], ui.pages[5]

	-- ======================= page 1: backend =======================

	local status = GM.MakeFontString(p1, GM.FONT, 9, "textDim")
	status:SetPoint("TOPLEFT", 12, -28)
	ui.status = status

	local body = GM.MakeFontString(p1, GM.FONT, 10, "text")
	body:SetPoint("TOPLEFT", 14, -46)
	body:SetWidth(432)
	body:SetJustifyH("LEFT")
	body:SetSpacing(3)
	body:SetText(
		"Team up: GoblinMind installs that join the same server pool "
		.. "their price scans into a shared book — prices stay fresh "
		.. "even while you're offline.\n\n"
		.. GM.CC("textDim")
		.. "Only fill this in if a friend gave you a server address "
		.. "and key. Playing solo? Press SKIP — everything still works "
		.. "on your own scans, the mesh, and the free Blizzard feed on "
		.. "the next page.|r")

	-- fields cascade off the body's bottom edge — wrapped text height
	-- varies by width/font, fixed offsets overlapped the body copy
	local urlLab = GM.MakeFontString(p1, GM.FONT, 9, "textDim")
	urlLab:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -12)
	urlLab:SetText("SERVER ADDRESS")
	local urlEb = W.EditBox(p1, 300)
	urlEb:SetPoint("TOPLEFT", urlLab, "BOTTOMLEFT", -2, -4)
	urlEb:SetText("http://127.0.0.1:8765")
	ui.urlEb = urlEb

	local nameLab = GM.MakeFontString(p1, GM.FONT, 9, "textDim")
	nameLab:SetPoint("TOPLEFT", urlEb, "BOTTOMLEFT", 2, -10)
	nameLab:SetText("YOUR NAME (shown to the server)")
	local nameEb = W.EditBox(p1, 200)
	nameEb:SetPoint("TOPLEFT", nameLab, "BOTTOMLEFT", -2, -4)
	nameEb:SetText(UnitName and UnitName("player") or "goblinmind")
	ui.nameEb = nameEb

	local keyLab = GM.MakeFontString(p1, GM.FONT, 9, "textDim")
	keyLab:SetPoint("TOPLEFT", nameEb, "BOTTOMLEFT", 2, -10)
	keyLab:SetText("KEY (only if your friend gave you one)")
	local keyEb = W.EditBox(p1, 200)
	keyEb:SetPoint("TOPLEFT", keyLab, "BOTTOMLEFT", -2, -4)
	ui.keyEb = keyEb

	local connect = Btn(p1, 90, "CONNECT", function()
		local url = strtrim(urlEb:GetText() or "")
		if not url:match("^https?://[%w%.%-%:]+") then
			GM.Print(GM.CC("warn")
				.. "server needs a full http(s):// URL|r")
			return
		end
		GM.StageBackendReq(url, strtrim(nameEb:GetText() or ""),
			GM.Scope and GM.Scope() or "",
			strtrim(keyEb:GetText() or ""))
		GM.db.backendReq = { at = time(), url = url }
		SetPage("api")
	end)
	connect:SetPoint("BOTTOMLEFT", 12, 10)

	local skip = Btn(p1, 90, "SKIP", function()
		GM.db.backendSkip = true
		SetPage("api")
	end)
	skip:SetPoint("LEFT", connect, "RIGHT", 8, 0)

	local later = Btn(p1, 90, "LATER", function() f:Hide() end)
	later:SetPoint("LEFT", skip, "RIGHT", 8, 0)

	-- self-host share line — filled by Refresh() only when the emit
	-- carries backend.invite (loopback host provenance)
	ui.invite = GM.MakeFontString(p1, GM.FONT, 9, "accent")
	ui.invite:SetPoint("BOTTOMLEFT", 12, 44)
	ui.invite:SetWidth(436)
	ui.invite:SetJustifyH("LEFT")

	ui.watch1 = WatchHint(p1)

	-- ===================== page 2: blizzard api ====================

	local aStatus = GM.MakeFontString(p2, GM.FONT, 9, "textDim")
	aStatus:SetPoint("TOPLEFT", 12, -28)
	ui.aStatus = aStatus

	local aBody = GM.MakeFontString(p2, GM.FONT, 10, "text")
	aBody:SetPoint("TOPLEFT", 14, -46)
	aBody:SetWidth(432)
	aBody:SetJustifyH("LEFT")
	aBody:SetSpacing(3)
	aBody:SetText(
		"Free, official, and the best data you can get without a "
		.. "group: the companion app can pull Blizzard's auction feed "
		.. "so prices stay fresh even when you haven't scanned.\n\n"
		.. GM.CC("textDim")
		.. "One-time setup on the web — the game can't open it for you:\n"
		.. "1. Go to develop.battle.net and sign in\n"
		.. "2. Create Client (any name, any redirect link)\n"
		.. "3. Copy the Client ID and Client Secret here|r\n\n"
		.. GM.CC("textDim")
		.. "SKIP keeps it off — your own scans still work.|r")

	local idLab = GM.MakeFontString(p2, GM.FONT, 9, "textDim")
	idLab:SetPoint("TOPLEFT", aBody, "BOTTOMLEFT", 0, -12)
	idLab:SetText("CLIENT ID")
	local idEb = W.EditBox(p2, 300)
	idEb:SetPoint("TOPLEFT", idLab, "BOTTOMLEFT", -2, -4)
	ui.idEb = idEb

	local secLab = GM.MakeFontString(p2, GM.FONT, 9, "textDim")
	secLab:SetPoint("TOPLEFT", idEb, "BOTTOMLEFT", 2, -10)
	secLab:SetText("CLIENT SECRET")
	local secEb = W.EditBox(p2, 300)
	secEb:SetPoint("TOPLEFT", secLab, "BOTTOMLEFT", -2, -4)
	ui.secEb = secEb

	local regLab = GM.MakeFontString(p2, GM.FONT, 9, "textDim")
	regLab:SetPoint("TOPLEFT", secEb, "BOTTOMLEFT", 2, -10)
	regLab:SetText("REGION (us / eu / kr / tw)")
	local regEb = W.EditBox(p2, 80)
	regEb:SetPoint("TOPLEFT", regLab, "BOTTOMLEFT", -2, -4)
	regEb:SetText("us")
	ui.regEb = regEb

	local aSave = Btn(p2, 90, "SAVE", function()
		local cid = strtrim(idEb:GetText() or "")
		local sec = strtrim(secEb:GetText() or "")
		if cid == "" or sec == "" then
			GM.Print(GM.CC("warn")
				.. "needs both the client id and secret|r")
			return
		end
		GM.StageApiReq(cid, sec, strtrim(regEb:GetText() or ""):lower(),
			GM.Scope and GM.Scope() or "")
		GM.db.apiReq = { at = time() }
		SetPage("import")
	end)
	aSave:SetPoint("BOTTOMLEFT", 12, 10)

	local aSkip = Btn(p2, 90, "SKIP", function()
		GM.db.apiSkip = true
		SetPage("import")
	end)
	aSkip:SetPoint("LEFT", aSave, "RIGHT", 8, 0)

	local aBack = Btn(p2, 90, "< BACK", function() SetPage("backend") end)
	aBack:SetPoint("LEFT", aSkip, "RIGHT", 8, 0)

	ui.watch2 = WatchHint(p2)

	-- ======================= page 3: import ========================

	local iStatus = GM.MakeFontString(p3, GM.FONT, 9, "textDim")
	iStatus:SetPoint("TOPLEFT", 12, -28)
	ui.iStatus = iStatus

	local iBody = GM.MakeFontString(p3, GM.FONT, 10, "text")
	iBody:SetPoint("TOPLEFT", 14, -44)
	iBody:SetWidth(432)
	iBody:SetJustifyH("LEFT")
	iStatus:SetWordWrap(false)
	iBody:SetSpacing(3)
	iBody:SetText("Found settings in other addons. Importing adds "
		.. "to GoblinMind — it never deletes anything you already made.")

	local rows = {}
	ui.rows = rows
	ui.iStatus2 = GM.MakeFontString(p3, GM.FONT, 9, "textDim")
	ui.iStatus2:SetPoint("BOTTOMLEFT", 12, 36)
	ui.iStatus2:SetWidth(436)
	ui.iStatus2:SetJustifyH("LEFT")

	local back = Btn(p3, 90, "< BACK", function() SetPage("api") end)
	back:SetPoint("BOTTOMLEFT", 12, 10)

	local toOpts = Btn(p3, 90, "NEXT >", function() SetPage("app") end)
	toOpts:SetPoint("BOTTOMRIGHT", -12, 10)

	local function MakeRow(ix)
		local r = CreateFrame("Frame", nil, p3)
		r:SetSize(436, 46)
		r:SetPoint("TOPLEFT", 12, -64 - (ix - 1) * 50)
		GM.Panel(r, "contLowest")
		r.addon = GM.MakeFontString(r, GM.FONT, 8, "textDim")
		r.addon:SetPoint("TOPLEFT", 8, -4)
		r.title = GM.MakeFontString(r, GM.FONT_BOLD, 10, "text")
		r.title:SetPoint("TOPLEFT", 8, -15)
		r.title:SetWidth(340)
		r.title:SetJustifyH("LEFT")
		r.detail = GM.MakeFontString(r, GM.FONT, 9, "textDim")
		r.detail:SetPoint("TOPLEFT", 8, -29)
		r.detail:SetWidth(340)
		r.detail:SetJustifyH("LEFT")
		r.btn = Btn(r, 70, "IMPORT", function()
			local summary, err = GM.Import.Run(r.data)
			if summary then
				r.btn.text:SetText("DONE")
				r.btn.text:SetTextColor(GM.RGB("pos"))
				r.result:SetText(GM.CC("pos") .. summary .. "|r")
			else
				r.result:SetText(GM.CC("warn")
					.. tostring(err or "nothing") .. "|r")
			end
		end)
		r.btn:SetPoint("RIGHT", -8, 0)
		r.result = GM.MakeFontString(r, GM.FONT, 8, "textDim")
		r.result:SetPoint("TOPRIGHT", r.btn, "BOTTOMRIGHT", 0, -2)
		r.result:SetWidth(240)
		r.result:SetJustifyH("RIGHT")
		r.result:SetWordWrap(false)
		r:Hide()
		return r
	end

	function ui.RefreshImport()
		if not GM.Import then return end
		local items, extras = GM.Import.Detect()
		for i, item in ipairs(items) do
			local r = rows[i] or MakeRow(i)
			rows[i] = r
			r.data = item
			r.addon:SetText(item.addon:upper())
			r.title:SetText(item.title)
			r.detail:SetText(item.detail)
			r.result:SetText("")
			r.btn.text:SetText(item.done and "DONE" or "IMPORT")
			r.btn.text:SetTextColor(GM.RGB(
				item.done and "pos" or "textDim"))
			r:Show()
		end
		for i = #items + 1, #rows do rows[i]:Hide() end
		local note = extras and #extras > 0
			and table.concat(extras, "\n") or nil
		if #items == 0 then
			ui.iStatus:SetText(GM.CC("warn")
				.. "no compatible addon data found|r")
		else
			ui.iStatus:SetText(format("%d importable item%s detected",
				#items, #items == 1 and "" or "s"))
		end
		ui.iStatus2:SetText(note or "")
	end

	-- ================= page 4: companion app ==================

	local cStatus = GM.MakeFontString(p4, GM.FONT, 9, "textDim")
	cStatus:SetPoint("TOPLEFT", 12, -28)
	ui.cStatus = cStatus

	local cBody = GM.MakeFontString(p4, GM.FONT, 10, "text")
	cBody:SetPoint("TOPLEFT", 14, -46)
	cBody:SetWidth(432)
	cBody:SetJustifyH("LEFT")
	cBody:SetSpacing(3)
	cBody:SetText(
		"One last thing — GoblinMind's number-cruncher lives outside "
		.. "the game, and it hasn't started yet.\n\n"
		.. "1. Open this folder:\n"
		.. "2. Double-click goblin-watch.bat\n\n"
		.. GM.CC("textDim")
		.. "That's the only time you ever have to. It sets itself to "
		.. "start with Windows, then keeps prices and bug reports "
		.. "moving on its own — and if you gave it a backend address "
		.. "on this PC, it starts the server for you too. Come back "
		.. "and /reload once it's running.|r")

	-- selectable path box — the watcher emits its absolute brain dir
	-- (GoblinMindDB.brain); before any emit we can only show the
	-- relative location inside the WoW install
	local pathLab = GM.MakeFontString(p4, GM.FONT, 9, "textDim")
	pathLab:SetPoint("TOPLEFT", cBody, "BOTTOMLEFT", 0, -8)
	pathLab:SetText("FOLDER (click the box, ctrl+a, ctrl+c)")
	local pathEb = W.EditBox(p4, 432)
	pathEb:SetPoint("TOPLEFT", pathLab, "BOTTOMLEFT", -2, -4)
	pathEb:SetAutoFocus(false)
	pathEb:SetScript("OnEditFocusGained", function(eb)
		eb:HighlightText()
	end)
	pathEb:SetScript("OnTextChanged", function(eb, user)
		-- read-only: restore the real path if the player types
		if user then eb:SetText(ui.pathText or "") eb:HighlightText() end
	end)
	pathEb:SetScript("OnEscapePressed", function(eb)
		eb:ClearFocus()
	end)
	ui.pathEb = pathEb

	local cBack = Btn(p4, 90, "< BACK", function() SetPage("import") end)
	cBack:SetPoint("BOTTOMLEFT", 12, 10)
	local cNext = Btn(p4, 90, "NEXT >", function() SetPage("options") end)
	cNext:SetPoint("BOTTOMRIGHT", -12, 10)

	-- ======================= page 5: options =======================

	local oBody = GM.MakeFontString(p5, GM.FONT, 10, "text")
	oBody:SetPoint("TOPLEFT", 14, -44)
	oBody:SetWidth(432)
	oBody:SetJustifyH("LEFT")
	oBody:SetSpacing(3)
	oBody:SetText(
		"Persistent options — change any of these later from the "
		.. "SETTINGS tab on the dashboard.\n\n"
		.. GM.CC("textDim")
		.. "SPOILER-FREE CRAFTING — hides recipes you haven't learned "
		.. "yet (and where to get them). Leaves everything else "
		.. "visible.|r")

	local spoiler = Btn(p5, 220, "", function()
		GM.db.hideUnlearned = not GM.db.hideUnlearned
		ui.spoiler.text:SetText("HIDE UNLEARNED RECIPES: "
			.. (GM.db.hideUnlearned and "ON" or "OFF"))
		ui.spoiler.text:SetTextColor(GM.RGB(
			GM.db.hideUnlearned and "accent" or "textDim"))
		if GM.CraftingUI and GM.CraftingUI.Refresh then
			GM.CraftingUI.Refresh()
		end
	end)
	spoiler:SetPoint("TOPLEFT", oBody, "BOTTOMLEFT", 0, -10)
	spoiler.text:SetText("HIDE UNLEARNED RECIPES: "
		.. (GM.db.hideUnlearned and "ON" or "OFF"))
	ui.spoiler = spoiler

	ui.watch5 = WatchHint(p5)

	local done = Btn(p5, 90, "DONE", function()
		f._done = true
		if GM.db then
			GM.db.obDone = true
			GM.db.obDismissed = nil
		end
		f:Hide()
	end)
	done:SetPoint("BOTTOMRIGHT", -12, 10)
	local oBack = Btn(p5, 90, "< BACK", function() SetPage("app") end)
	oBack:SetPoint("BOTTOMLEFT", 12, 10)
end

-- shared staged-request copy — the ~2 min figure is the SV
-- autosave cadence; /reload flushes immediately
local STAGED = "saved — the companion app picks this up within "
	.. "~2 min; /reload once it's running"

function Refresh()
	if not ui then return end
	local req = GM.db and GM.db.backendReq
	local be = GoblinMindDB and GoblinMindDB.backend
	if be and be.lastError then
		ui.status:SetText(GM.CC("warn")
			.. "can't reach that server — " .. GM.CC("textDim")
			.. tostring(be.lastError):sub(1, 80) .. "|r")
	elseif Configured() then
		ui.status:SetText(GM.CC("pos")
			.. "connected: " .. tostring(be.url or be.name or "?")
			.. " · " .. tostring(be.peers or 1) .. " installs|r")
	elseif req then
		ui.status:SetText(GM.CC("warn") .. STAGED .. "|r")
	else
		ui.status:SetText("not configured")
	end
	-- R5: on the loopback host the emit carries the share invite —
	-- show it so the player can hand friends the URL + key in game
	if be and be.invite and ui.invite then
		ui.invite:SetText(GM.CC("accent") .. "hosting — friends use: "
			.. tostring(be.invite.url)
			.. " · key " .. tostring(be.invite.key) .. "|r")
	end
	local ap = GoblinMindDB and GoblinMindDB.api
	if ap and ap.ok == false then
		ui.aStatus:SetText(GM.CC("warn")
			.. "those credentials were rejected — re-check both"
			.. (ap.error and (" " .. GM.CC("textDim") .. "("
				.. tostring(ap.error):sub(1, 60) .. ")") or "") .. "|r")
	elseif ap and ap.configured then
		ui.aStatus:SetText(GM.CC("pos")
			.. "blizzard api configured|r")
	elseif GM.db and GM.db.apiReq then
		ui.aStatus:SetText(GM.CC("warn") .. STAGED .. "|r")
	else
		ui.aStatus:SetText("not configured")
	end
	-- companion-app page: fill the selectable path box and the
	-- running/not-yet status line
	local br = GoblinMindDB and GoblinMindDB.brain
	ui.pathText = (br and br.dir)
		or "Interface\\AddOns\\GoblinMind\\brain"
	ui.pathEb:SetText(ui.pathText)
	ui.pathEb:SetCursorPosition(0)
	local age = GM.EmitAge and GM.EmitAge()
	local silent = (not age) or age > 900
	ui.cStatus:SetText(silent
		and (GM.CC("warn") .. "not running yet — one double-click "
			.. "starts it|r")
		or (GM.CC("pos") .. "running — latest data "
			.. floor(age) .. "s old|r"))
	-- "start the external program" — visible whenever the watcher
	-- hasn't emitted recently and something needs it (or could)
	local hint = silent
		and "the companion app hasn't run yet — see step 4"
		or ""
	if ui.watch1 then ui.watch1:SetText(hint) end
	if ui.watch2 then ui.watch2:SetText(hint) end
	if ui.watch5 then ui.watch5:SetText(hint) end
end

-- OB.Show("import"|"api"|"options") opens a specific page; no
-- argument lands on page 1, the backend page.
function OB.Show(page)
	Build()
	ui._done = nil
	Refresh()
	SetPage(PAGE_IX[page] or 1)
	ui:Show()
end

function OB.MaybeShow()
	if not GM.db then return end
	-- first install: show once regardless of any config state — the
	-- in-game flow IS the primary path (install.bat exists for the
	-- server host + autostart, not for the connect step itself).
	-- Flag before Show so a mid-login crash can't loop the prompt.
	if not GM.db.onboarded then
		GM.db.onboarded = true
		OB.Show()
		return
	end
	-- can't determine config state without an emit carrying a backend
	-- block: a missing/stale DB isn't "not configured" — don't nag.
	-- (backend={} in the emit IS a determination — watcher checked.)
	if not (GoblinMindDB and GoblinMindDB.backend) then
		GM.db.obDbg = { t = time(), why = "no backend block",
			gen = GoblinMindDB and GoblinMindDB.generated }
		return
	end
	-- consumed-request acks: drop staged requests the watcher already
	-- folded into feeds.json, and confirm the pending flags
	local be = GoblinMindDB.backend
	local req = GM.db.backendReq
	if be and be.ack then
		local list = GM.db.backendReqs
		for i = list and #list or 0, 1, -1 do
			local ts = tonumber(list[i]:match("^bm%-(%d+)"))
			if ts and ts <= be.ack then tremove(list, i) end
		end
		if req and be.ack >= req.at then
			GM.db.backendReq = nil
			GM.Print("backend connected — "
				.. tostring(be.url or req.url))
		end
	end
	local ap = GoblinMindDB.api
	if ap and ap.ack and GM.db.apiReqs then
		for i = #GM.db.apiReqs, 1, -1 do
			local ts = tonumber(GM.db.apiReqs[i]:match("^api%-(%d+)"))
			if ts and ts <= ap.ack then tremove(GM.db.apiReqs, i) end
		end
		if GM.db.apiReq and ap.ack >= GM.db.apiReq.at then
			GM.db.apiReq = nil
			GM.Print("blizzard api configured")
		end
	end
	-- DONE on the last page = finished — never auto-show again
	if GM.db.obDone then
		return
	end
	-- closed mid-flow (x / ESC / LATER): re-show each login until the
	-- wizard is completed, whatever the config state — dismissing a
	-- half-finished wizard mustn't count as finishing it
	if GM.db.obDismissed then
		GM.db.obDbg = { t = time(), why = "reshow-dismissed",
			gen = GoblinMindDB.generated }
		OB.Show()
		return
	end
	if Configured() or GM.db.backendSkip or GM.db.backendReq then
		return
	end
	-- capture what the emit said when we decided to prompt — if this
	-- ever fires on a configured install, obDbg holds the evidence
	GM.db.obDbg = { t = time(), why = "shown",
		gen = GoblinMindDB and GoblinMindDB.generated,
		url = be.url, ack = be.ack,
		up = be.up and be.up.ok, pull = be.pull and be.pull.ok }
	OB.Show()
end

-- login hook — delayed so it doesn't fight the loading screen
local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
	if GM.After then GM.After(6, OB.MaybeShow) end
end)
