local _, GM = ...

-- /goblin bug — public bug-report helper for strangers filing issues.
-- Builds a diagnostics block (version / client / data state / frame
-- audit / recent log tail) into a selectable editbox — Ctrl+A, Ctrl+C,
-- paste into the issue, attach the screenshot it offers to take.

GM.BugReport = {}
local BR = GM.BugReport

-- the public tracker the brain watcher files staged reports to
local ISSUES_URL = "github.com/ZhigZhog/GoblinMind/issues"

local floor = math.floor
local ui

local function Collect()
	local L = {}
	local function line(s) L[#L + 1] = s end
	line("### GoblinMind bug report")
	local meta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	local ok, ver = pcall(function()
		return meta and meta("GoblinMind", "Version") end)
	line("version: " .. (ok and tostring(ver) or "?"))
	if GetBuildInfo then
		local v, b, d, t = GetBuildInfo()
		line(format("client: %s build %s (interface %s)",
			tostring(v), tostring(b), tostring(t)))
	end
	if UnitName then
		line(format("toon: %s @ %s", tostring(UnitName("player")),
			tostring(GetRealmName and GetRealmName())))
	end
	local n = 0
	if GoblinMindDB and GoblinMindDB.items then
		for _ in pairs(GoblinMindDB.items) do n = n + 1 end
	end
	local bookAge = GM.AH and GM.AH.BookAge and GM.AH.BookAge() or math.huge
	line(format("data: %d db items · book %s", n,
		bookAge < math.huge and (floor(bookAge) .. "s old") or "empty"))
	-- the GoblinMindSettings collision class: a GoblinMind* name in
	-- UISpecialFrames that doesn't resolve to a real frame
	if UISpecialFrames then
		local bad = {}
		for i = 1, #UISpecialFrames do
			local nm = UISpecialFrames[i]
			local fr = nm and _G[nm]
			if nm and nm:match("^GoblinMind")
					and not (fr and fr.IsShown) then
				bad[#bad + 1] = nm
			end
		end
		line("special-frames: " .. (#bad == 0 and "ok"
			or table.concat(bad, ", ")))
	end
	if GM.log and #GM.log > 0 then
		line("--- recent log ---")
		for i = math.max(1, #GM.log - 14), #GM.log do
			line(GM.log[i])
		end
	end
	line("---")
	line("what I did / expected / got:")
	return table.concat(L, "\n")
end

local W = GM.Widgets
local Btn = W and W.Btn

local function Build()
	if ui then return end
	local f = CreateFrame("Frame", "GoblinMindBugFrame", UIParent)
	f:SetSize(640, 420)
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
	tinsert(UISpecialFrames, "GoblinMindBugFrame")
	ui = f

	local title = GM.MakeFontString(f, GM.FONT_BOLD, 13, "accent")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText("BUG REPORT")

	local close = CreateFrame("Button", nil, f)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.text = GM.MakeFontString(close, GM.FONT_BOLD, 12, "textDim")
	close.text:SetPoint("CENTER")
	close.text:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)

	local hint = GM.MakeFontString(f, GM.FONT, 9, "textDim")
	hint:SetPoint("TOPLEFT", 12, -30)
	hint:SetText("Ctrl+A, Ctrl+C — paste into the issue · "
		.. "attach the screenshot there too")

	-- scrollable multiline editbox carrying the diagnostics block
	local scroll = CreateFrame("ScrollFrame", nil, f,
		"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -50)
	scroll:SetPoint("BOTTOMRIGHT", -30, 44)
	GM.Panel(scroll, "contLowest")
	local eb = CreateFrame("EditBox", nil, scroll)
	eb:SetMultiLine(true)
	eb:SetAutoFocus(false)
	eb:SetFont(GM.FONT, 10, "")
	eb:SetTextColor(GM.RGB("text"))
	eb:SetWidth(500)
	eb:SetScript("OnEscapePressed", function() f:Hide() end)
	scroll:SetScrollChild(eb)
	ui.eb = eb

	local copy = Btn(f, 90, "SELECT ALL", function()
		eb:SetFocus()
		eb:HighlightText()
	end)
	copy:SetPoint("BOTTOMLEFT", 12, 10)
	local shot = Btn(f, 100, "SCREENSHOT", function()
		-- Screenshot is protected on this client — a pcall can't shield
		-- a protection block (it trips ADDON_ACTION_BLOCKED, not a Lua
		-- error). issecurefunction checks first; PrintScreen is the
		-- fallback message.
		-- no issecurefunction on this client → can't verify the call
		-- is safe, and Screenshot is protected here → attempting it
		-- trips ADDON_ACTION_BLOCKED (pcall can't shield that). Treat
		-- "can't check" as protected; other clients still try.
		local ok = type(Screenshot) == "function"
			and issecurefunction and not issecurefunction(Screenshot)
			and pcall(Screenshot)
		GM.Print(ok and "screenshot saved to WoW\\Screenshots"
			or "press PrintScreen — saves to WoW\\Screenshots")
	end)
	shot:SetPoint("LEFT", copy, "RIGHT", 8, 0)

	-- stage into SavedVariables — the brain watcher picks it up on
	-- the next /reload and files it to GitHub. Title comes from the
	-- user's own text under the prompt line.
	local file = Btn(f, 96, "FILE REPORT", function()
		local txt = strtrim(eb:GetText() or "")
		local user = strtrim(txt:match(
			"what I did / expected / got:%s*\n?(.*)") or "")
		if user == "" then
			GM.Print(GM.CC("warn")
				.. "fill in 'what I did / expected / got' first|r")
			return
		end
		if not (GM.db and GM.StageReport) then
			GM.Print(GM.CC("warn") .. "report staging unavailable|r")
			return
		end
		local id = GM.StageReport(txt, user:gsub("\n.*", ""))
		GM.Print("bug report filed (" .. id .. ") — uploads "
			.. "automatically in ~90s (SavedVariables autosave), or "
			.. "/reload to send now")
	end)
	file:SetPoint("LEFT", shot, "RIGHT", 8, 0)

	-- the link itself, selectable — most clients can't launch a
	-- browser from Lua, so copy-out is the reliable path; LaunchURL
	-- gets a shot first in case Forever honors it (protected on most
	-- clients → issecurefunction gate, same as Screenshot)
	local urlBox = CreateFrame("EditBox", nil, f)
	urlBox:SetSize(196, 18)
	urlBox:SetAutoFocus(false)
	urlBox:SetFont(GM.FONT, 9, "")
	urlBox:SetTextColor(GM.RGB("textDim"))
	urlBox:SetTextInsets(6, 4, 0, 0)
	urlBox:SetText(ISSUES_URL)
	urlBox:SetCursorPosition(0)
	GM.Panel(urlBox, "contLowest")
	urlBox:SetScript("OnEscapePressed", function() urlBox:ClearFocus() end)
	urlBox:SetScript("OnEnterPressed", function() urlBox:ClearFocus() end)
	local issues = Btn(f, 82, "ISSUES ↗", function()
		if type(LaunchURL) == "function" and issecurefunction
			and not issecurefunction(LaunchURL) then
			pcall(LaunchURL, "https://" .. ISSUES_URL)
		end
		urlBox:SetFocus()
		urlBox:HighlightText()
	end)
	issues:SetPoint("LEFT", file, "RIGHT", 8, 0)
	urlBox:SetPoint("LEFT", issues, "RIGHT", 8, 0)
	urlBox:SetPoint("BOTTOM", copy, "BOTTOM", 0, 0)
end

function BR.Show()
	Build()
	ui.eb:SetText(Collect())
	ui:Show()
	ui.eb:ClearFocus()
end
