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

-- Shift+click = Blizzard's fill-the-slot gesture (the native AH sell
-- slot works exactly this way). Native meaning is untouched — links
-- still paste, stacks still split — and while the plan window is open
-- the clicked item also becomes its target. Gated on IsShown so a
-- bare shift+click for chat-linking never pops the planner.
local function Capture()
	return IsShiftKeyDown and IsShiftKeyDown()
		and GM.PlanQueue.IsShown()
end

-- The shared funnel every container/click path delegates to on this
-- client: Blizzard's own handlers plus Baganator and EllesmereUIBags
-- (the per-handler globals like ContainerFrameItemButton_OnModifiedClick
-- don't reliably exist or fire here — Baganator replaces the buttons).
--
-- REPLACED, not post-hooked: claiming the click must return true so the
-- caller skips its native follow-through — Baganator's item buttons
-- check the return before opening StackSplitFrame, Blizzard's modified-
-- click path does the same. Unclaimed clicks run the original verbatim.
local origHMI = HandleModifiedItemClick
if origHMI then
	HandleModifiedItemClick = function(link)
		if Capture() then
			local id = GM.LinkID(link)
			if id then
				GM.TargetItem(id, link)
				return true
			end
		end
		return origHMI(link)
	end
end

-- Chat links — SetItemRef may not delegate to the funnel on this
-- client; TargetItem is idempotent if it does.
if SetItemRef then
	hooksecurefunc("SetItemRef", function(link)
		if not Capture() then return end
		local id = GM.LinkID(link)
		if id then GM.TargetItem(id) end
	end)
end
