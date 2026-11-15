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
	["Dragon's Teeth"]  = { { id = 3819, lo = 1, hi = 4, pct = 100 } },
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

-- skinning yields are level-banded, not per-mob: a corpse's tooltip
-- says "Skinnable" (or "Requires Skinning (N)" when the skill is
-- short) and the band table approximates the classic loot table.
-- {id, lo, hi, pct} — same shape as node drops; pct is the share of
-- total skin volume for that item.
local SKIN_BANDS = {
	{ max = 9, drops = {
		{ id = 2934, lo = 1, hi = 3, pct = 65 },  -- Ruined Scraps
		{ id = 2318, lo = 1, hi = 2, pct = 35 },  -- Light Leather
		{ id = 783,  lo = 1, hi = 1, pct = 2 },   -- Light Hide
	}},
	{ max = 19, drops = {
		{ id = 2318, lo = 1, hi = 3, pct = 80 },
		{ id = 2319, lo = 1, hi = 2, pct = 15 },  -- Medium Leather
		{ id = 783,  lo = 1, hi = 1, pct = 3 },
	}},
	{ max = 29, drops = {
		{ id = 2319, lo = 1, hi = 3, pct = 60 },
		{ id = 2318, lo = 1, hi = 2, pct = 30 },
		{ id = 4234, lo = 1, hi = 2, pct = 10 },  -- Heavy Leather
		{ id = 4232, lo = 1, hi = 1, pct = 3 },   -- Medium Hide
	}},
	{ max = 39, drops = {
		{ id = 4234, lo = 1, hi = 3, pct = 65 },
		{ id = 2319, lo = 1, hi = 2, pct = 25 },
		{ id = 4304, lo = 1, hi = 2, pct = 10 },  -- Thick Leather
		{ id = 4235, lo = 1, hi = 1, pct = 3 },   -- Heavy Hide
	}},
	{ max = 49, drops = {
		{ id = 4304, lo = 1, hi = 3, pct = 65 },
		{ id = 4234, lo = 1, hi = 2, pct = 25 },
		{ id = 8170, lo = 1, hi = 2, pct = 10 },  -- Rugged Leather
		{ id = 8169, lo = 1, hi = 1, pct = 3 },   -- Thick Hide
	}},
	{ max = 999, drops = {
		{ id = 8170, lo = 1, hi = 3, pct = 65 },
		{ id = 4304, lo = 1, hi = 2, pct = 30 },
		{ id = 8171, lo = 1, hi = 1, pct = 4 },   -- Rugged Hide
	}},
}

-- family specials: name-pattern matched ADDITIVE rolls on top of the
-- level band (scales roll alongside the leather). First match wins.
-- minLvl/maxLvl gate level-split items; id="color" resolves a
-- dragonscale color off the creature name at render time.
local SKIN_SPECIALS = {
	{ pats = { "deviate" }, drops = {
		{ id = 6470, lo = 1, hi = 2, pct = 35 },  -- Deviate Scale
		{ id = 6471, lo = 1, hi = 1, pct = 6 },   -- Perfect Deviate
	}},
	{ pats = { "devilsaur", "king mosh", "tyrant" }, drops = {
		{ id = 15417, lo = 1, hi = 2, pct = 50 }, -- Devilsaur Leather
	}},
	{ pats = { "core hound", "corehound", "magmadar" }, drops = {
		{ id = 17012, lo = 1, hi = 1, pct = 50 }, -- Core Leather
	}},
	{ pats = { "scorpid", "scorpion", "scorpashi", "scorpok" }, drops = {
		{ id = 8154, lo = 1, hi = 2, pct = 15 },  -- Scorpid Scale
	}},
	{ pats = { "turtle", "snapjaw", "tortoise", "scaleback" }, drops = {
		{ id = 8167, lo = 1, hi = 2, pct = 12 },  -- Turtle Scale
	}},
	{ pats = { "murloc", "gorloc" }, drops = {
		{ id = 5784, lo = 1, hi = 2, pct = 12, maxLvl = 29 }, -- Slimy
		{ id = 5785, lo = 1, hi = 2, pct = 15, minLvl = 30 }, -- Thick
	}},
	{ pats = { "raptor", "lashtail", "razormaw" }, drops = {
		{ id = 4461, lo = 1, hi = 1, pct = 15 },  -- Raptor Hide
	}},
	{ pats = { "whelp", "drake", "dragon", "drakonid", "proto" },
	  drops = {
		{ id = 8165, lo = 1, hi = 1, pct = 15 },  -- Worn Dragonscale
		{ id = "color", lo = 1, hi = 1, pct = 20 },
	}},
}

local DRAGON_COLORS = {
	{ "green", 15412 }, { "black", 15416 }, { "blue", 15415 },
	{ "azure", 15415 }, { "red", 15414 }, { "chrom", 15467 },
}

-- name may arrive as a secret string under taint — all indexing
-- stays inside the pcall
local function SpecialFor(name)
	if not name then return nil end
	local ok, idx, ln = pcall(function()
		local l = name:lower()
		for i, s in ipairs(SKIN_SPECIALS) do
			for _, p in ipairs(s.pats) do
				if l:find(p, 1, true) then return i, l end
			end
		end
	end)
	if ok and idx then return idx, ln end
	return nil
end

local function DragonScaleID(ln)
	for _, c in ipairs(DRAGON_COLORS) do
		if ln:find(c[1], 1, true) then return c[2] end
	end
end

local function Price(id)
	return GM.Price("dbmarket", id)
end

local Name = GM.ItemNameOr

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

-- append the level-banded skin table to a corpse tooltip; family
-- specials (additive extra rolls) render above the band, EV sums both
local function FillSkin(tt, lvl, name)
	local band = SKIN_BANDS[#SKIN_BANDS]
	for _, b in ipairs(SKIN_BANDS) do
		if (lvl or 999) <= b.max then band = b break end
	end
	local specIdx, ln = SpecialFor(name)
	local total, anyPrice = 0, false
	tt:AddLine(" ")
	tt:AddLine(GM.CC("secondary") .. "skinning"
		.. (lvl and lvl > 0 and (" — lvl " .. lvl) or " yields")
		.. "|r")
	local function Row(d, mark)
		local id = d.id == "color" and (ln and DragonScaleID(ln))
			or d.id
		if not id then return end
		if (d.minLvl and lvl and lvl < d.minLvl)
			or (d.maxLvl and lvl and lvl > d.maxLvl) then return end
		local p = Price(id)
		anyPrice = anyPrice or p ~= nil
		local qty = (d.lo + d.hi) / 2
		total = total + (p or 0) * qty * d.pct / 100
		local range = d.lo == d.hi and ("×" .. d.lo)
			or format("×%d–%d", d.lo, d.hi)
		tt:AddLine(
			GM.CC(mark or "text") .. Name(id) .. "|r "
			.. GM.CC("textDim") .. range
			.. (d.pct < 100 and (" ~" .. d.pct .. "%") or "") .. "|r"
			.. (p and ("  " .. GM.Money(p) .. " ea") or ""))
	end
	if specIdx then
		for _, d in ipairs(SKIN_SPECIALS[specIdx].drops) do
			Row(d, "accent")
		end
	end
	for _, d in ipairs(band.drops) do Row(d) end
	tt:AddLine(GM.CC("accent") .. "skin EV ≈ "
		.. (total > 0 and GM.Money(total) or "?")
		.. (anyPrice and "" or " (no price data)") .. "|r")
	tt:Show()
end

-- a corpse tooltip is skinnable when any line carries the client's
-- marker text; returns true plus whether the skill is short
local function Skinnable(tt)
	for i = 1, tt:NumLines() do
		local fs = _G["GameTooltipTextLeft" .. i]
		-- the text AND its indexing both live inside the pcall —
		-- secret strings throw on :find, not just on read
		local ok, hit = pcall(function()
			local lt = fs and fs:GetText()
			if not lt then return 0 end
			if lt:find("Requires Skinning") then return 2 end
			if lt:find("Skinnable") then return 1 end
			return 0
		end)
		if ok and hit == 2 then return true, true end
		if ok and hit == 1 then return true, false end
	end
	return false
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
		-- GetText can hand back a "secret string" under taint —
		-- indexing it throws; skip the poll instead
		if text then
			local ok, clean = pcall(function()
				return strtrim((text:gsub("|c%x%x%x%x%x%x%x%x", "")
					:gsub("|r", "")))
			end)
			text = ok and clean or nil
		end
		if text and NODES[text] then
			if not tt._gmNodeN or tt:NumLines() < tt._gmNodeN then
				Fill(tt, text)
				tt._gmNodeN = tt:NumLines()
			end
			tt._gmSkinN = nil
		else
			tt._gmNodeN = nil
			-- not a node — check for a skinnable corpse (unit tooltip)
			local skin, shortSkill = Skinnable(tt)
			if skin then
				if not tt._gmSkinN or tt:NumLines() < tt._gmSkinN then
					local okU, name, unit = pcall(tt.GetUnit, tt)
					local lvl = okU and unit and UnitLevel(unit)
					FillSkin(tt, lvl, okU and name)
					if shortSkill then
						tt:AddLine(GM.CC("err")
							.. "skinning skill too low|r")
						tt:Show()
					end
					tt._gmSkinN = tt:NumLines()
				end
			else
				tt._gmSkinN = nil
			end
		end
	end)
	GameTooltip:HookScript("OnHide", function(tt)
		tt._gmNodeN = nil
		tt._gmSkinN = nil
	end)
end
