local _, GM = ...

-- Gathering node tooltips — hovering a mining vein or herb node
-- appends its drop table with market prices: ore/stone lines, gems
-- compressed into one combined-probability line, and the node's
-- expected value. Loot tables are static classic-era data;
-- probabilities marked ~ are approximate.

GM.Gathering = {}
local G = GM.Gathering

-- {id, min, max, pct, gem} — qty range, drop % (approx), gem flag
local NODES = {
	["Copper Vein"] = {
		{ id = 2770, lo = 2, hi = 4, pct = 100 }, -- Copper Ore
		{ id = 2835, lo = 1, hi = 3, pct = 100 }, -- Rough Stone
		{ id = 774,  lo = 1, hi = 1, pct = 3, gem = true },  -- Malachite
		{ id = 818,  lo = 1, hi = 1, pct = 3, gem = true },  -- Tigerseye
		{ id = 1210, lo = 1, hi = 1, pct = 1, gem = true },  -- Shadowgem
	},
	["Incendicite Mineral Vein"] = {
		{ id = 3340, lo = 1, hi = 2, pct = 100 }, -- Incendicite Ore
	},
	["Tin Vein"] = {
		{ id = 2771, lo = 2, hi = 4, pct = 100 }, -- Tin Ore
		{ id = 2836, lo = 1, hi = 3, pct = 100 }, -- Coarse Stone
		{ id = 1705, lo = 1, hi = 1, pct = 3, gem = true },  -- L. Moonstone
		{ id = 1206, lo = 1, hi = 1, pct = 3, gem = true },  -- Moss Agate
		{ id = 1210, lo = 1, hi = 1, pct = 2, gem = true },  -- Shadowgem
	},
	["Silver Vein"] = {
		{ id = 2775, lo = 2, hi = 4, pct = 100 },
		{ id = 2836, lo = 1, hi = 2, pct = 100 },
		{ id = 1705, lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 1206, lo = 1, hi = 1, pct = 2, gem = true },
		{ id = 1210, lo = 1, hi = 1, pct = 2, gem = true },
	},
	["Iron Deposit"] = {
		{ id = 2772, lo = 2, hi = 4, pct = 100 }, -- Iron Ore
		{ id = 2838, lo = 1, hi = 3, pct = 100 }, -- Heavy Stone
		{ id = 1705, lo = 1, hi = 1, pct = 4, gem = true },
		{ id = 1529, lo = 1, hi = 1, pct = 3, gem = true },  -- Jade
		{ id = 3864, lo = 1, hi = 1, pct = 2, gem = true },  -- Citrine
	},
	["Gold Vein"] = {
		{ id = 2776, lo = 2, hi = 4, pct = 100 },
		{ id = 2838, lo = 1, hi = 2, pct = 100 },
		{ id = 3864, lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 1529, lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 1705, lo = 1, hi = 1, pct = 2, gem = true },
	},
	["Mithril Deposit"] = {
		{ id = 3858, lo = 2, hi = 4, pct = 100 }, -- Mithril Ore
		{ id = 7912, lo = 1, hi = 3, pct = 100 }, -- Solid Stone
		{ id = 7909, lo = 1, hi = 1, pct = 3, gem = true },  -- Aquamarine
		{ id = 3864, lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 7910, lo = 1, hi = 1, pct = 2, gem = true },  -- Star Ruby
	},
	["Truesilver Deposit"] = {
		{ id = 7911, lo = 2, hi = 4, pct = 100 },
		{ id = 7912, lo = 1, hi = 2, pct = 100 },
		{ id = 7909, lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 7910, lo = 1, hi = 1, pct = 3, gem = true },
	},
	["Small Thorium Vein"] = {
		{ id = 10620, lo = 2, hi = 4, pct = 100 }, -- Thorium Ore
		{ id = 12365, lo = 1, hi = 3, pct = 100 }, -- Dense Stone
		{ id = 12799, lo = 1, hi = 1, pct = 3, gem = true }, -- L. Opal
		{ id = 7910,  lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 12364, lo = 1, hi = 1, pct = 2, gem = true }, -- H. Emerald
		{ id = 12800, lo = 1, hi = 1, pct = 1, gem = true }, -- Az. Diamond
		{ id = 12361, lo = 1, hi = 1, pct = 1, gem = true }, -- B. Sapphire
	},
	["Rich Thorium Vein"] = {
		{ id = 10620, lo = 4, hi = 6, pct = 100 },
		{ id = 12365, lo = 1, hi = 3, pct = 100 },
		{ id = 12799, lo = 1, hi = 1, pct = 4, gem = true },
		{ id = 7910,  lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 12364, lo = 1, hi = 1, pct = 3, gem = true },
		{ id = 12800, lo = 1, hi = 1, pct = 2, gem = true },
		{ id = 12361, lo = 1, hi = 1, pct = 2, gem = true },
	},
	["Dark Iron Deposit"] = {
		{ id = 11370, lo = 2, hi = 4, pct = 100 }, -- Dark Iron Ore
		{ id = 11382, lo = 1, hi = 1, pct = 1, gem = true }, -- Blood/Mt.
	},
	-- herbs: the node name is the herb name; drop is itself +
	-- any secondary rolls
	["Peacebloom"] = { { id = 2447, lo = 1, hi = 4, pct = 100 } },
	["Silverleaf"] = { { id = 765,  lo = 1, hi = 4, pct = 100 } },
	["Earthroot"]  = { { id = 2449, lo = 1, hi = 4, pct = 100 } },
	["Mageroyal"] = {
		{ id = 785,  lo = 1, hi = 4, pct = 100 },
		{ id = 2452, lo = 1, hi = 2, pct = 30 }, -- Swiftthistle
	},
	["Briarthorn"] = {
		{ id = 2450, lo = 1, hi = 4, pct = 100 },
		{ id = 2452, lo = 1, hi = 2, pct = 50 }, -- Swiftthistle
	},
	["Bruiseweed"]       = { { id = 2453, lo = 1, hi = 4, pct = 100 } },
	["Wild Steelbloom"]  = { { id = 3355, lo = 1, hi = 4, pct = 100 } },
	["Grave Moss"]       = { { id = 3369, lo = 1, hi = 4, pct = 100 } },
	["Kingsblood"]       = { { id = 3356, lo = 1, hi = 4, pct = 100 } },
	["Liferoot"]         = { { id = 3357, lo = 1, hi = 4, pct = 100 } },
	["Fadeleaf"]         = { { id = 3818, lo = 1, hi = 4, pct = 100 } },
	["Goldthorn"]        = { { id = 3821, lo = 1, hi = 4, pct = 100 } },
	["Khadgar's Whisker"] = { { id = 3358, lo = 1, hi = 4, pct = 100 } },
	["Wintersbite"]      = { { id = 3819, lo = 1, hi = 4, pct = 100 } },
	["Firebloom"]        = { { id = 4625, lo = 1, hi = 4, pct = 100 } },
	["Purple Lotus"] = {
		{ id = 8831, lo = 1, hi = 4, pct = 100 },
		{ id = 8153, lo = 1, hi = 2, pct = 25 }, -- Wildvine
	},
	["Sungrass"]          = { { id = 8838, lo = 1, hi = 4, pct = 100 } },
	["Blindweed"]         = { { id = 8839, lo = 1, hi = 4, pct = 100 } },
	["Ghost Mushroom"]    = { { id = 8845, lo = 1, hi = 4, pct = 100 } },
	["Gromsblood"]        = { { id = 8846, lo = 1, hi = 4, pct = 100 } },
	["Golden Sansam"]     = { { id = 13464, lo = 1, hi = 4, pct = 100 } },
	["Dreamfoil"]         = { { id = 13463, lo = 1, hi = 4, pct = 100 } },
	["Mountain Silversage"] = {
		{ id = 13465, lo = 1, hi = 4, pct = 100 },
		{ id = 13468, lo = 1, hi = 1, pct = 1, gem = true }, -- Black Lotus
	},
	["Icecap"]   = { { id = 13467, lo = 1, hi = 4, pct = 100 } },
	["Plaguebloom"] = { { id = 13466, lo = 1, hi = 4, pct = 100 } },
}

G.nodes = NODES

local function Price(id)
	local e = GM.ItemEntry and GM.ItemEntry(id)
	local m = e and (e.mkt or e.p) or nil
	if not m and GM.TSMMarket then m = GM.TSMMarket(id) end
	return m
end

local function Name(id)
	return (GM.ItemName and GM.ItemName(id)) or ("item " .. id)
end

-- append drop lines + node EV to a tooltip for a known node name
local function Fill(tt, node)
	local drops = NODES[node]
	if not drops then return end
	local total, gemPct, gemEV, anyPrice = 0, 0, 0, false
	tt:AddLine(" ")
	for _, d in ipairs(drops) do
		if not d.gem then
			local p = Price(d.id)
			anyPrice = anyPrice or p ~= nil
			local qty = (d.lo + d.hi) / 2
			total = total + (p or 0) * qty * d.pct / 100
			local range = d.lo == d.hi and ("×" .. d.lo)
				or format("×%d–%d", d.lo, d.hi)
			tt:AddLine(
				GM.CC("text") .. Name(d.id) .. "|r "
				.. GM.CC("textDim") .. range
				.. (d.pct < 100 and (" ~" .. d.pct .. "%") or "") .. "|r"
				.. (p and ("  " .. GM.Money(p) .. " ea") or ""))
		else
			gemPct = gemPct + d.pct
			local p = Price(d.id)
			gemEV = gemEV + (p or 0) * d.pct / 100
			total = total + (p or 0) * ((d.lo + d.hi) / 2) * d.pct / 100
		end
	end
	if gemPct > 0 then
		tt:AddLine(
			GM.CC("secondary") .. "rare gems ~" .. gemPct .. "%|r"
			.. (gemEV > 0 and ("  +" .. GM.Money(gemEV) .. " expected") or ""))
	end
	tt:AddLine(GM.CC("accent") .. "node EV ≈ "
		.. (total > 0 and GM.Money(total) or "?")
		.. (anyPrice and "" or " (no price data)") .. "|r")
	tt:Show()
end

-- game-object tooltips have no data-type event — poll the first
-- line on a throttle and inject once per node-text change
if GameTooltip then
	-- the client redraws object tooltips every frame, wiping
	-- appended lines — re-inject when our block count is gone
	local pollT = 0
	GameTooltip:HookScript("OnUpdate", function(tt, e)
		pollT = pollT + e
		if pollT < 0.15 then return end
		pollT = 0
		if not tt:IsShown() then tt._gmNodeN = nil return end
		local fs = GameTooltipTextLeft1
		local text = fs and fs:IsShown() and fs:GetText()
		if text then
			text = strtrim((text:gsub("|c%x%x%x%x%x%x%x%x", "")
				:gsub("|r", "")))
		end
		if text and NODES[text] then
			if not tt._gmNodeN or tt:NumLines() < tt._gmNodeN then
				Fill(tt, text)
				tt._gmNodeN = tt:NumLines()
			end
		else
			tt._gmNodeN = nil
		end
	end)
	GameTooltip:HookScript("OnHide", function(tt) tt._gmNodeN = nil end)
end
