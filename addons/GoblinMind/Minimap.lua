local _, GM = ...

-- Hand-rolled minimap button (no LibDBIcon dependency): drag around the
-- ring to reposition, left-click toggles the plan window. Angle and
-- visibility persist in GoblinMindSettings.
GM.minimapBtn = nil

local RADIUS = 80
local atan2 = atan2 or function(y, x) return math.atan(y, x) end

local function Place()
	local a = (GM.db and GM.db.minimapAngle) or -0.785
	GM.minimapBtn:ClearAllPoints()
	GM.minimapBtn:SetPoint("CENTER", Minimap, "CENTER", cos(a) * RADIUS, sin(a) * RADIUS)
end

local function UpdatePositionFromCursor()
	local mx, my = Minimap:GetCenter()
	local cx, cy = GetCursorPosition()
	local s = Minimap:GetEffectiveScale()
	cx, cy = cx / s, cy / s
	GM.db.minimapAngle = atan2(cy - my, cx - mx)
	Place()
end

function GM.MinimapInit()
	if GM.minimapBtn or not Minimap then return end
	local b = CreateFrame("Button", "GoblinMindMinimapButton", Minimap)
	b:SetSize(31, 31)
	-- LibDBIcon convention: pin strata+level so other UI can't bury it
	b:SetFrameStrata("MEDIUM")
	if b.SetFixedFrameStrata then b:SetFixedFrameStrata(true) end
	b:SetFrameLevel(8)
	if b.SetFixedFrameLevel then b:SetFixedFrameLevel(true) end
	b:RegisterForClicks("LeftButtonUp")
	b:RegisterForDrag("LeftButton")

	b.icon = b:CreateTexture(nil, "BACKGROUND")
	b.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
	b.icon:SetSize(20, 20)
	b.icon:SetPoint("CENTER")
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	b.border:SetSize(53, 53)
	b.border:SetPoint("TOPLEFT", -11, 11)

	b.hl = b:CreateTexture(nil, "HIGHLIGHT")
	b.hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	b.hl:SetBlendMode("ADD")
	b.hl:SetAllPoints()

	b:SetScript("OnClick", function(_, btn)
		if btn == "LeftButton" then GM.PlanQueue.Toggle() end
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", UpdatePositionFromCursor)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(GM.CC("accent") .. "GoblinMind|r")
		GameTooltip:AddLine("Left-click: plan window", 1, 1, 1)
		GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
		GameTooltip:AddLine("/goblin minimap — show/hide this button", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	GM.minimapBtn = b
	b:SetShown(not (GM.db and GM.db.minimapHide))
	Place()
end
