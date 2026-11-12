local _, GM = ...

-- GoblinMind info lives in a second tooltip window, anchored beside the
-- native one — TSM's ExtraTooltip pattern. A GameTooltip-template frame
-- gives the Blizzard look (backdrop, fonts, auto-sizing) for free.

local sideTip
local hideHooked = {}

local function BuildSideTip()
	if sideTip then return end
	local ok, tip = pcall(CreateFrame, "GameTooltip", "GoblinMindSideTip",
		UIParent, "GameTooltipTemplate")
	if not ok or not tip then return end
	tip:SetClampedToScreen(true)
	sideTip = tip
end

local function FillSideTip(tooltip, itemID)
	BuildSideTip()
	if not sideTip then return end
	local entry = GM.ItemEntry(itemID)
	local market = GM.TSMMarket(itemID)
	local p = (entry and entry.p) or market
	local lr, lg, lb = GM.RGB("textDim")
	local rr, rg, rb = GM.RGB("text")
	local ar, ag, ab = GM.RGB("accent")
	local wr, wg, wb = GM.RGB("warn")
	local pr, pg, pb = GM.RGB("pos")
	local er, eg, eb = GM.RGB("err")
	local function trend(v) -- green up, red down, dim near-flat
		if v >= 0.5 then return pr, pg, pb elseif v <= -0.5 then return er, eg, eb end
		return lr, lg, lb
	end

	sideTip:SetOwner(tooltip, "ANCHOR_NONE")
	sideTip:ClearAllPoints()
	sideTip:SetPoint("TOPLEFT", tooltip, "TOPRIGHT", 0, 0)
	sideTip:SetText("GoblinMind", ar, ag, ab)

	if p then
		sideTip:AddDoubleLine("est.", GM.Money(p), lr, lg, lb, ar, ag, ab)
		if entry and entry.p10 and entry.p90 then
			sideTip:AddDoubleLine("band", GM.Money(entry.p10) .. " – " .. GM.Money(entry.p90),
				lr, lg, lb, rr, rg, rb)
		end
		if entry and entry.p and market and market > 0 then
			local d = (entry.p - market) / market * 100
			sideTip:AddDoubleLine("vs TSM", format("%+.0f%%", d), lr, lg, lb, trend(d))
		end
	end
	if entry then
		if entry.hist and p then
			local d = (p - entry.hist) / entry.hist * 100
			sideTip:AddDoubleLine("hist", format("%s %+.0f%%", GM.Money(entry.hist), d),
				lr, lg, lb, trend(d))
		end
		if entry.recent and p and entry.recent ~= p then
			local d = (entry.recent - p) / p * 100
			sideTip:AddDoubleLine("recent", format("%+.0f%%", d), lr, lg, lb, trend(d))
		end
		if entry.vel then
			sideTip:AddDoubleLine("sells/day", tostring(entry.vel), lr, lg, lb, rr, rg, rb)
		end
		if entry.sup then
			sideTip:AddDoubleLine("supply", tostring(entry.sup), lr, lg, lb, rr, rg, rb)
		end
		if entry.reset then
			sideTip:AddDoubleLine("reset", "below " .. GM.Money(entry.reset.below)
				.. " · ev " .. GM.Money(entry.reset.ev), wr, wg, wb, wr, wg, wb)
		end
	end
	sideTip:AddDoubleLine("itemID", tostring(itemID), lr, lg, lb, lr, lg, lb)
	local age = GM.DataAge()
	if age and age > GM.db.dataMaxAge then
		sideTip:AddLine(format("data %dm old — /reload to refresh", age / 60), wr, wg, wb)
	end
	sideTip:Show()

	if not hideHooked[tooltip] then
		hideHooked[tooltip] = true
		local hide = function() if sideTip then sideTip:Hide() end end
		tooltip:HookScript("OnHide", hide)
		pcall(function() tooltip:HookScript("OnTooltipCleared", hide) end)
	end
end

local function Hook(tooltip, data)
	-- Postcalls fire for every GameTooltip-template frame, including the
	-- ShoppingTooltip compare windows — those carry the player's equipped
	-- item and would clobber the tracked item.
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
	if tooltip == sideTip then return end
	local itemID = data and data.id
	local link
	if TooltipUtil and TooltipUtil.GetDisplayedItem then
		_, link = TooltipUtil.GetDisplayedItem(tooltip)
	end
	local GetIDByInfo = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
	if not itemID and link then
		itemID = GetIDByInfo(link)
	end
	if not itemID then return end
	GM.lastTooltipItemID = itemID
	GM.lastTooltipLink = link
	local entry = GM.ItemEntry(itemID)
	local market = GM.TSMMarket(itemID)
	if entry or market then
		FillSideTip(tooltip, itemID)
	elseif sideTip then
		sideTip:Hide()
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, Hook)
elseif GameTooltip then
	-- legacy hook path for clients without TooltipDataProcessor
	GameTooltip:HookScript("OnTooltipSetItem", function(tt)
		local _, link = tt:GetItem()
		local GetIDByInfo = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
		local id = link and GetIDByInfo(link)
		if id then
			GM.lastTooltipItemID = id
			GM.lastTooltipLink = link
			FillSideTip(tt, id)
		end
	end)
end
