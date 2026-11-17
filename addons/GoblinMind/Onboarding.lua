local _, GM = ...

-- Backend onboarding — the crowdsource server is optional, and the
-- addon can't touch the filesystem to configure it. The bridge is
-- SavedVariables: CONNECT stages a bm-<ts>|<hex> request the brain
-- watcher picks up on the next SV flush and writes into feeds.json;
-- the emitted GoblinMindDB.backend.url + .ack confirm it landed.
-- SKIP is permanent (re-open with /goblin backend); LATER re-asks
-- next login. Re-staging a newer request reconfigures — newest wins.

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

local function Build()
	if ui then return end
	local f = CreateFrame("Frame", "GoblinMindOnboardFrame", UIParent)
	f:SetSize(460, 318)
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
	title:SetText("GOBLINMIND BACKEND")

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	local status = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	status:SetPoint("TOPLEFT", 12, -28)
	ui.status = status

	local body = GM.MakeFontString(f, GM.FONT, 10, "text")
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
	local urlLab = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	urlLab:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -12)
	urlLab:SetText("SERVER")
	local urlEb = W.EditBox(f, 300)
	urlEb:SetPoint("TOPLEFT", urlLab, "BOTTOMLEFT", -2, -4)
	urlEb:SetText("http://127.0.0.1:8765")
	ui.urlEb = urlEb

	local nameLab = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	nameLab:SetPoint("TOPLEFT", urlEb, "BOTTOMLEFT", 2, -10)
	nameLab:SetText("CALLSIGN")
	local nameEb = W.EditBox(f, 200)
	nameEb:SetPoint("TOPLEFT", nameLab, "BOTTOMLEFT", -2, -4)
	nameEb:SetText(UnitName and UnitName("player") or "goblinmind")
	ui.nameEb = nameEb

	local keyLab = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	keyLab:SetPoint("TOPLEFT", nameEb, "BOTTOMLEFT", 2, -10)
	keyLab:SetText("KEY (only if the server gave you one)")
	local keyEb = W.EditBox(f, 200)
	keyEb:SetPoint("TOPLEFT", keyLab, "BOTTOMLEFT", -2, -4)
	ui.keyEb = keyEb

	local connect = Btn(f, 90, "CONNECT", function()
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

	local skip = Btn(f, 90, "SKIP", function()
		GM.db.backendSkip = true
		f:Hide()
		GM.Print("backend skipped — scans + mesh still drive prices. "
			.. "/goblin backend re-opens this.")
	end)
	skip:SetPoint("LEFT", connect, "RIGHT", 8, 0)

	local later = Btn(f, 90, "LATER", function() f:Hide() end)
	later:SetPoint("LEFT", skip, "RIGHT", 8, 0)
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

function OB.Show()
	Build()
	Refresh()
	ui:Show()
end

function OB.MaybeShow()
	if not GM.db then return end
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
