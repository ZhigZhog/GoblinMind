local _, GM = ...

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local GetIDByInfo = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant

-- Every input path funnels here: target the item, surface the window,
-- and read the book when we're already at the AH.
function GM.TargetItem(itemID, link)
	if not itemID then return end
	if not link or link:match("^item:") then
		local _, full = GetInfo and GetInfo(itemID)
		link = full or link
	end
	GM.PlanQueue.SetItem(itemID, link)
	GM.PlanQueue.Show()
	if GM.AH.open then GM.PlanQueue.Rescan() end
end

-- Alt-click always targets; Shift-click targets only while the plan
-- window is open (shift has native meanings — chat paste, stack
-- split — that still fire alongside; secure hooks can't suppress
-- them, and shouldn't).
local function Capture()
	if IsAltKeyDown() then return true end
	return IsShiftKeyDown() and GM.PlanQueue.IsShown()
end

-- Modified-click a bag slot.
if ContainerFrameItemButton_OnModifiedClick then
	hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self)
		if not Capture() then return end
		local bag = self:GetParent():GetID()
		local slot = self:GetID()
		local info = C_Container and C_Container.GetContainerItemInfo(bag, slot)
		if info and info.itemID then GM.TargetItem(info.itemID, info.hyperlink) end
	end)
end

-- Modified-click a chat link.
if SetItemRef then
	hooksecurefunc("SetItemRef", function(link)
		if not Capture() then return end
		local id = link and tonumber(link:match("item:(%d+)"))
		if id then GM.TargetItem(id) end
	end)
end

-- Modified-click an equipped slot.
if PaperDollItemSlotButton_OnModifiedClick then
	hooksecurefunc("PaperDollItemSlotButton_OnModifiedClick", function(self)
		if not Capture() then return end
		local link = GetInventoryItemLink("player", self:GetID())
		local id = link and GetIDByInfo and GetIDByInfo(link)
		if id then GM.TargetItem(id, link) end
	end)
end
