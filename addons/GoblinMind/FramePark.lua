local _, GM = ...

-- Shared frame-takeover mechanics (CraftingUI → ProfessionsFrame,
-- VendoringUI → MerchantFrame). TSM's Move approach: a parked frame is
-- never Hide()n — hiding the native frame fires its session-close
-- handler, killing the tradeskill/merchant session our API calls need.
-- Instead: collapse the UIPanel footprint + pin offscreen at
-- 100000,100000 + a SetPoint hook that re-parks it whenever Blizzard's
-- panel manager repositions it. While parked it's also stripped from
-- UIPanelWindows/UISpecialFrames: a parked frame is still SHOWN, so
-- the ESC handler keeps finding it and runs native behavior (book
-- page flips) instead of reaching our window.

GM.FramePark = {}
local FP = GM.FramePark
local unpack = unpack or table.unpack

local saved = {}   -- [frame] = {point, xoff, width, panel, special, hooked}
local pending = {} -- [frame] = "park"|"restore" while combat-locked

-- position fallbacks when we never captured a real home (TSM Move
-- point table); panel attrs are snapshotted per-frame instead
local FALLBACK_XY = {
	ProfessionsFrame  = { 15, -116 },
	TradeSkillFrame   = { 0, -104 },
	MerchantFrame     = { 16, -116 },
	AuctionHouseFrame = { 36, -116 },
}

function FP.Park(pf)
	if not pf then return end
	if InCombatLockdown and InCombatLockdown() then
		pending[pf] = "park" -- some natives are combat-locked (ProfessionsFrame)
		return
	end
	if pending[pf] == "park" then pending[pf] = nil end
	if not pf:IsShown() then return end
	local s = saved[pf] or {}
	saved[pf] = s
	if not s.point and pf:GetPoint(1) then
		local pt, relTo, rel, x, y = pf:GetPoint(1)
		-- don't snapshot an already-parked position (TSM parks it the
		-- same way) — offscreen coords aren't a real home
		if math.abs(x or 0) < 5000 then
			s.point = { pt, relTo, rel, x, y }
		end
	end
	if GetUIPanelAttribute then
		if s.xoff == nil then
			s.xoff = select(2, pcall(GetUIPanelAttribute, pf, "xoffset"))
		end
		if s.width == nil then
			s.width = select(2, pcall(GetUIPanelAttribute, pf, "width"))
		end
	end
	s.parked = true
	pf._gmParked = true
	pf.ignoreFramePositionManager = true
	if SetUIPanelAttribute then
		pcall(SetUIPanelAttribute, pf, "xoffset", -32)
		pcall(SetUIPanelAttribute, pf, "width", 0)
		pcall(UpdateUIPanelPositions, pf)
	end
	pf:ClearAllPoints()
	pf:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100000, 100000)
	if not s.hooked then
		s.hooked = true
		hooksecurefunc(pf, "SetPoint", function(self)
			if self._gmParked and not self._gmRepoint then
				self._gmRepoint = true
				self:ClearAllPoints()
				self:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100000, 100000)
				self._gmRepoint = nil
			end
		end)
	end
	local name = pf:GetName()
	if name then
		if UIPanelWindows and UIPanelWindows[name] then
			s.panel = s.panel or UIPanelWindows[name]
			UIPanelWindows[name] = nil
		end
		if UISpecialFrames then
			for i = #UISpecialFrames, 1, -1 do
				if UISpecialFrames[i] == name then
					s.special = i
					tremove(UISpecialFrames, i)
				end
			end
		end
	end
end

function FP.Restore(pf)
	if not pf then return end
	if InCombatLockdown and InCombatLockdown() then
		pending[pf] = "restore"
		return
	end
	if pending[pf] == "restore" then pending[pf] = nil end
	local s = saved[pf]
	if not (s and s.parked) then return end -- we didn't move it
	s.parked = nil
	pf._gmParked = nil
	local name = pf:GetName()
	-- hand the panel/special-frame registrations back BEFORE re-
	-- positioning so the panel manager can own it again
	if name then
		if s.panel then
			UIPanelWindows[name] = s.panel
			s.panel = nil
		end
		if s.special and UISpecialFrames then
			tinsert(UISpecialFrames,
				math.min(s.special, #UISpecialFrames + 1), name)
			s.special = nil
		end
	end
	local fb = name and FALLBACK_XY[name]
	pf._gmRepoint = true
	pf:ClearAllPoints()
	if s.point then
		pf:SetPoint(unpack(s.point))
	else
		pf:SetPoint("TOPLEFT", UIParent, "TOPLEFT",
			fb and fb[1] or 0, fb and fb[2] or -104)
	end
	pf._gmRepoint = nil
	pf.ignoreFramePositionManager = nil
	if SetUIPanelAttribute then
		if s.xoff ~= nil then
			pcall(SetUIPanelAttribute, pf, "xoffset", s.xoff)
		end
		if s.width ~= nil then
			pcall(SetUIPanelAttribute, pf, "width", s.width)
		end
		pcall(UpdateUIPanelPositions, pf)
	end
	-- never Show() it ourselves: if the session already died the frame
	-- is hidden and popping it back open is the bug we had. A still-
	-- shown parked frame becomes visible by reposition alone.
end

function FP.IsParked(pf)
	local s = saved[pf]
	return s and s.parked or false
end

-- diagnostic: which frames are currently parked, and are they still
-- shown? A parked frame stays SHOWN — its OnUpdate + events keep
-- firing, so this list doubles as a churn suspect sheet
function FP.ParkedList()
	local out = {}
	for pf, s in pairs(saved) do
		if s.parked then
			-- IsShown/GetName can return secret values on protected
			-- frames — read + test + tostring inside one pcall
			local ok, name, shown = pcall(function()
				return pf:GetName(), pf:IsShown() and true or false
			end)
			out[#out + 1] = format("%s(shown=%s)",
				tostring(ok and name or "?"),
				tostring(ok and shown or "?"))
		end
	end
	return out
end

-- deferred moves land after combat drops
local f = CreateFrame("Frame")
pcall(f.RegisterEvent, f, "PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function()
	for pf, op in pairs(pending) do
		pending[pf] = nil
		if op == "park" then FP.Park(pf) else FP.Restore(pf) end
	end
end)
