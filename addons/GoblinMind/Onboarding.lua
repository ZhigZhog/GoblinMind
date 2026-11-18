local _, GM = ...

-- Onboarding — two pages. Page 1: backend configuration (optional —
-- the addon can't touch the filesystem, so CONNECT stages a
-- bm-<ts>|<hex> request the brain watcher picks up on the next SV
-- flush and writes into feeds.json; the emitted GoblinMindDB.backend
-- .url + .ack confirm it landed. SKIP is permanent — re-open with
-- /goblin backend; LATER re-asks next login). Page 2: compatible-
-- addon import — detects TSM and similar via their SavedVariables
-- globals and imports settings per-item via GM.Import. Re-open that
-- page directly with /goblin import.

GM.Onboard = {}
local OB = GM.Onboard

local W = GM.Widgets
local Btn = W and W.Btn

local ui

local function Configured()
	local be = GoblinMindDB and GoblinMindDB.backend
	return be and (be.url or be.pull or be.up or (be.peers or 0) > 0)
		and true or false
end

local function SetPage(n)
	ui.page = n
	ui.p1:SetShown(n == 1)
	ui.p2:SetShown(n == 2)
	ui.title:SetText(n == 2 and "IMPORT SETTINGS" or "GOBLINMIND BACKEND")
	if n == 2 and ui.RefreshImport then ui.RefreshImport() end
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

	-- page containers swap whole; children anchor inside their page
	local p1 = CreateFrame("Frame", nil, f)
	p1:SetAllPoints()
	local p2 = CreateFrame("Frame", nil, f)
	p2:SetAllPoints()
	p2:Hide()
	ui.p1, ui.p2 = p1, p2

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
		.. "mesh, and every feature still works.|r\n\n"
		.. GM.CC("textDim")
		.. "The companion watcher (brain\\goblin-watch.bat) applies the "
		.. "request on your next /reload.|r")

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
		f:Hide()
		GM.Print("backend request staged — /reload to activate")
	end)
	connect:SetPoint("BOTTOMLEFT", 12, 10)

	local skip = Btn(p1, 90, "SKIP", function()
		GM.db.backendSkip = true
		f:Hide()
		GM.Print("backend skipped — scans + mesh still drive prices. "
			.. "/goblin backend re-opens this.")
	end)
	skip:SetPoint("LEFT", connect, "RIGHT", 8, 0)

	local later = Btn(p1, 90, "LATER", function() f:Hide() end)
	later:SetPoint("LEFT", skip, "RIGHT", 8, 0)

	local toImport = Btn(p1, 90, "IMPORT >", function() SetPage(2) end)
	toImport:SetPoint("BOTTOMRIGHT", -12, 10)

	-- ======================= page 2: import ========================

	local iStatus = GM.MakeFontString(p2, GM.FONT, 9, "textDim")
	iStatus:SetPoint("TOPLEFT", 12, -28)
	ui.iStatus = iStatus

	local iBody = GM.MakeFontString(p2, GM.FONT, 10, "text")
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
	ui.iStatus2 = GM.MakeFontString(p2, GM.FONT, 9, "textDim")
	ui.iStatus2:SetPoint("BOTTOMLEFT", 12, 36)
	ui.iStatus2:SetWidth(436)
	ui.iStatus2:SetJustifyH("LEFT")

	local back = Btn(p2, 90, "< BACK", function() SetPage(1) end)
	back:SetPoint("BOTTOMLEFT", 12, 10)

	local done = Btn(p2, 90, "DONE", function() f:Hide() end)
	done:SetPoint("BOTTOMRIGHT", -12, 10)

	local function MakeRow(ix)
		local r = CreateFrame("Frame", nil, p2)
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
		r.result:SetWidth(140)
		r.result:SetJustifyH("RIGHT")
		r.result:SetWidth(240)
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
end

-- OB.Show("import") opens page 2 directly (/goblin import); any other
-- argument (or none) lands on page 1, the backend page.
function OB.Show(page)
	Build()
	Refresh()
	SetPage(page == "import" and 2 or 1)
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
	-- consumed-request ack: drop staged requests the watcher already
	-- folded into feeds.json, and confirm the pending flag
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
