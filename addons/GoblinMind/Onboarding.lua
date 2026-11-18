local _, GM = ...

-- Onboarding — a multi-page first-run wizard; more pages slot in by
-- appending to PAGES. The addon can't touch the filesystem, so every
-- config page stages a hex request in SavedVariables — the brain
-- watcher picks them up on the next SV flush and writes feeds.json:
--
--   page 1 BACKEND   — crowdsource price feed (optional). CONNECT
--                      stages a bm- request and advances to API;
--                      SKIP is permanent and goes straight to IMPORT
--                      (/goblin backend re-opens). LATER re-asks next
--                      login.
--   page 2 API       — Blizzard auction API credentials (optional,
--                      reached only after CONNECT). SAVE stages an
--                      api- request; SKIP goes to IMPORT.
--   page 3 IMPORT    — compatible-addon settings (TSM etc.) via
--                      GM.Import; /goblin import opens it directly.
--   page 4 OPTIONS   — persistent toggles (spoiler-free crafting
--                      today; more later) + the watcher-start nudge.
--
-- The watcher itself is the "external program": every page that
-- stages something shows a hint when no recent emit exists —
-- GM.EmitAge() tells us the brain hasn't run yet.

GM.Onboard = {}
local OB = GM.Onboard

local W = GM.Widgets
local Btn = W and W.Btn

local ui

local PAGES = { "backend", "api", "import", "options" }
local TITLES = {
	backend = "GOBLINMIND BACKEND",
	api = "BLIZZARD API",
	import = "IMPORT SETTINGS",
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

local function SetPage(p)
	local n = type(p) == "number" and p or PAGE_IX[p] or 1
	ui.page = n
	for i, pg in ipairs(ui.pages) do pg:SetShown(i == n) end
	ui.title:SetText(TITLES[PAGES[n]] or "GOBLINMIND")
	if PAGES[n] == "import" and ui.RefreshImport then
		ui.RefreshImport()
	end
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

	ui.pages = {}
	for i = 1, #PAGES do
		local pg = CreateFrame("Frame", nil, f)
		pg:SetAllPoints()
		pg:Hide()
		ui.pages[i] = pg
	end
	local p1, p2, p3, p4 = ui.pages[1], ui.pages[2], ui.pages[3],
		ui.pages[4]

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
		"GoblinMind can join a shared price feed — installs that opt in "
		.. "pool their auction books into a crowdsourced realm book, keep "
		.. "long-term price history, and file bug reports automatically.\n\n"
		.. GM.CC("textDim")
		.. "Optional — without it, prices come from your own scans and the "
		.. "mesh, and every feature still works. SKIP goes straight to "
		.. "the import page.|r\n\n"
		.. GM.CC("textDim")
		.. "CONNECT also asks about the free Blizzard API on the next "
		.. "page — everything you set here is applied by the companion "
		.. "watcher, no command-line install needed.|r")

	-- fields cascade off the body's bottom edge — wrapped text height
	-- varies by width/font, fixed offsets overlapped the body copy
	local urlLab = GM.MakeFontString(p1, GM.FONT, 9, "textDim")
	urlLab:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -12)
	urlLab:SetText("SERVER")
	local urlEb = W.EditBox(p1, 300)
	urlEb:SetPoint("TOPLEFT", urlLab, "BOTTOMLEFT", -2, -4)
	urlEb:SetText("http://127.0.0.1:8765")
	ui.urlEb = urlEb

	local nameLab = GM.MakeFontString(p1, GM.FONT, 9, "textDim")
	nameLab:SetPoint("TOPLEFT", urlEb, "BOTTOMLEFT", 2, -10)
	nameLab:SetText("CALLSIGN")
	local nameEb = W.EditBox(p1, 200)
	nameEb:SetPoint("TOPLEFT", nameLab, "BOTTOMLEFT", -2, -4)
	nameEb:SetText(UnitName and UnitName("player") or "goblinmind")
	ui.nameEb = nameEb

	local keyLab = GM.MakeFontString(p1, GM.FONT, 9, "textDim")
	keyLab:SetPoint("TOPLEFT", nameEb, "BOTTOMLEFT", 2, -10)
	keyLab:SetText("KEY (only if the server gave you one)")
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
		SetPage("import")
	end)
	skip:SetPoint("LEFT", connect, "RIGHT", 8, 0)

	local later = Btn(p1, 90, "LATER", function() f:Hide() end)
	later:SetPoint("LEFT", skip, "RIGHT", 8, 0)

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
		"The watcher can also pull Blizzard's auction API — it keeps "
		.. "regional price history fresh even between your own scans.\n\n"
		.. GM.CC("textDim")
		.. "Credentials are free: make a client at develop.battle.net "
		.. "(create application → any name → copy the ID + secret). "
		.. "SKIP leaves this off — your scans and the mesh still work.|r")

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
	iBody:SetText("Settings found in other addons. Each item lists "
		.. "what comes over — import merges, it never wipes your "
		.. "existing GoblinMind setup.")

	local rows = {}
	ui.rows = rows
	ui.iStatus2 = GM.MakeFontString(p3, GM.FONT, 9, "textDim")
	ui.iStatus2:SetPoint("BOTTOMLEFT", 12, 36)
	ui.iStatus2:SetWidth(436)
	ui.iStatus2:SetJustifyH("LEFT")

	local back = Btn(p3, 90, "< BACK", function() SetPage("api") end)
	back:SetPoint("BOTTOMLEFT", 12, 10)

	local toOpts = Btn(p3, 90, "NEXT >", function() SetPage("options") end)
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

	-- ======================= page 4: options =======================

	local oBody = GM.MakeFontString(p4, GM.FONT, 10, "text")
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

	local spoiler = Btn(p4, 220, "", function()
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

	ui.watch4 = WatchHint(p4)

	local done = Btn(p4, 90, "DONE", function() f:Hide() end)
	done:SetPoint("BOTTOMRIGHT", -12, 10)
	local oBack = Btn(p4, 90, "< BACK", function() SetPage("import") end)
	oBack:SetPoint("BOTTOMLEFT", 12, 10)
end

local function Refresh()
	if not ui then return end
	local req = GM.db and GM.db.backendReq
	local be = GoblinMindDB and GoblinMindDB.backend
	if Configured() then
		ui.status:SetText(GM.CC("pos")
			.. "connected: " .. tostring(be.url or be.name or "?") .. "|r")
	elseif req then
		ui.status:SetText(GM.CC("warn")
			.. "request staged — waiting for the watcher (needs /reload)|r")
	else
		ui.status:SetText("not configured")
	end
	local ap = GoblinMindDB and GoblinMindDB.api
	if ap and ap.configured then
		ui.aStatus:SetText(GM.CC("pos")
			.. "blizzard api configured|r")
	elseif GM.db and GM.db.apiReq then
		ui.aStatus:SetText(GM.CC("warn")
			.. "request staged — waiting for the watcher (needs /reload)|r")
	else
		ui.aStatus:SetText("not configured")
	end
	-- "start the external program" — visible whenever the watcher
	-- hasn't emitted recently and something needs it (or could)
	local age = GM.EmitAge and GM.EmitAge()
	local silent = (not age) or age > 900
	local hint = silent
		and "the brain watcher hasn't run yet — start "
		.. "brain\\goblin-watch.bat once, then /reload"
		or ""
	if ui.watch1 then ui.watch1:SetText(hint) end
	if ui.watch2 then ui.watch2:SetText(hint) end
	if ui.watch4 then ui.watch4:SetText(hint) end
end

-- OB.Show("import"|"api"|"options") opens a specific page; no
-- argument lands on page 1, the backend page.
function OB.Show(page)
	Build()
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
