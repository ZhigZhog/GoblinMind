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
	-- fishing pools: wreckage yields zone-scaled trunks (one catch =
	-- one item; trunk tier drifts up with zone level so the mix is a
	-- mid-weighted approximation) plus Rumsey/kelp filler; schools
	-- yield their fish with an occasional trunk
	["Floating Debris"] = {
		{ id = 20708, lo = 1, hi = 1, pct = 85 }, -- Tightly Sealed Trunk
		{ id = 20709, lo = 1, hi = 1, pct = 15 }, -- Rumsey Rum Light
	},
	["Floating Wreckage"] = {
		{ id = 21113, lo = 1, hi = 1, pct = 50 }, -- Watertight Trunk
		{ id = 21150, lo = 1, hi = 1, pct = 25 }, -- Iron Bound Trunk
		{ id = 21228, lo = 1, hi = 1, pct = 10 }, -- Mithril Bound Trunk
		{ id = 21114, lo = 1, hi = 1, pct = 15 }, -- Rumsey Rum Dark
	},
	["Schooner Wreckage"] = {
		{ id = 21113, lo = 1, hi = 1, pct = 70 },
		{ id = 21150, lo = 1, hi = 1, pct = 15 },
		{ id = 21114, lo = 1, hi = 1, pct = 15 },
	},
	["Waterlogged Wreckage"] = {
		{ id = 21150, lo = 1, hi = 1, pct = 60 },
		{ id = 21228, lo = 1, hi = 1, pct = 25 },
		{ id = 21115, lo = 1, hi = 1, pct = 15 }, -- Rumsey Rum Black Label
	},
	["Bloodsail Wreckage"] = {
		{ id = 21228, lo = 1, hi = 1, pct = 60 },
		{ id = 21150, lo = 1, hi = 1, pct = 20 },
		{ id = 3820,  lo = 1, hi = 2, pct = 10 }, -- Stranglekelp
		{ id = 21115, lo = 1, hi = 1, pct = 10 },
	},
	["Oil Spill"] = {
		{ id = 6358,  lo = 1, hi = 2, pct = 75 }, -- Oily Blackmouth
		{ id = 20708, lo = 1, hi = 1, pct = 15 },
		{ id = 20709, lo = 1, hi = 1, pct = 10 },
	},
	["Oily Blackmouth"] = {
		{ id = 6358,  lo = 1, hi = 2, pct = 90 },
		{ id = 20708, lo = 1, hi = 1, pct = 10 },
	},
	["Firefin Snapper"] = {
		{ id = 6359,  lo = 1, hi = 2, pct = 90 },
		{ id = 21113, lo = 1, hi = 1, pct = 10 },
	},
	["Sagefish"] = {
		{ id = 21071, lo = 1, hi = 2, pct = 90 }, -- Raw Sagefish
		{ id = 20708, lo = 1, hi = 1, pct = 10 },
	},
	["Greater Sagefish"] = {
		{ id = 21153, lo = 1, hi = 2, pct = 90 }, -- Raw Greater Sagefish
		{ id = 21113, lo = 1, hi = 1, pct = 10 },
	},
	["Deviate Fish"] = {
		{ id = 6522,  lo = 1, hi = 2, pct = 90 },
		{ id = 20708, lo = 1, hi = 1, pct = 10 },
	},
	["Stonescale Eel"] = {
		{ id = 13422, lo = 1, hi = 2, pct = 90 },
		{ id = 21228, lo = 1, hi = 1, pct = 10 },
	},
	["School of Tastyfish"] = {
		{ id = 19807, lo = 1, hi = 2, pct = 100 }, -- Speckled Tastyfish
	},
	["Patch of Elemental Water"] = {
		{ id = 7070, lo = 1, hi = 2, pct = 70 }, -- Elemental Water
		{ id = 7079, lo = 1, hi = 1, pct = 20 }, -- Globe of Water
		{ id = 7080, lo = 1, hi = 1, pct = 10 }, -- Essence of Water
	},
}

G.nodes = NODES

-- Herb item ids (node primary drops + herb secondaries). Milling
-- does not exist on Forever and is not planned, so tooltips suppress
-- destroy/convert output for these entirely — a mill-EV line can
-- never be actionable.
local HERB_ITEMS = {}
for _, id in ipairs({
	765, 785, 2447, 2449, 2450, 2452, 2453, 3355, 3356, 3357, 3358,
	3369, 3818, 3819, 3820, 3821, 4625, 8831, 8836, 8838, 8839,
	8845, 8846, 13463, 13464, 13465, 13466, 13467, 13468, 8153,
}) do HERB_ITEMS[id] = true end

function G.IsHerb(itemID)
	return HERB_ITEMS[itemID] == true
end

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

-- static names for every item id in the tables — uncached items
-- come back nil from GetItemInfo on Forever and these are all fixed
-- classic-era ids; the API name still wins when it's cached
local NAMES = {
	-- ores, stones, gems
	[774]="Malachite", [818]="Tigerseye", [1206]="Moss Agate",
	[1210]="Shadowgem", [1529]="Jade", [1705]="Lesser Moonstone",
	[2770]="Copper Ore", [2771]="Tin Ore", [2772]="Iron Ore",
	[2775]="Silver Ore", [2776]="Gold Ore", [7911]="Truesilver Ore",
	[2835]="Rough Stone", [2836]="Coarse Stone",
	[2838]="Heavy Stone", [3340]="Incendicite Ore",
	[3858]="Mithril Ore", [3864]="Citrine", [7909]="Aquamarine",
	[7910]="Star Ruby", [7912]="Solid Stone", [10620]="Thorium Ore",
	[11370]="Dark Iron Ore", [11382]="Blood of the Mountain",
	[12361]="Blue Sapphire", [12364]="Huge Emerald",
	[12365]="Dense Stone", [12799]="Large Opal",
	[12800]="Azerothian Diamond",
	-- herbs
	[765]="Silverleaf", [785]="Mageroyal", [2447]="Peacebloom",
	[2449]="Earthroot", [2450]="Briarthorn", [2452]="Swiftthistle",
	[2453]="Bruiseweed", [3355]="Wild Steelbloom",
	[3356]="Kingsblood", [3357]="Liferoot",
	[3358]="Khadgar's Whisker", [3369]="Grave Moss",
	[3818]="Fadeleaf", [3819]="Wintersbite", [3820]="Stranglekelp",
	[3821]="Goldthorn", [4625]="Firebloom", [8831]="Purple Lotus",
	[8836]="Arthas' Tears", [8838]="Sungrass", [8839]="Blindweed",
	[8845]="Ghost Mushroom", [8846]="Gromsblood",
	[13463]="Dreamfoil", [13464]="Golden Sansam",
	[13465]="Mountain Silversage", [13466]="Plaguebloom",
	[13467]="Icecap", [13468]="Black Lotus", [8153]="Wildvine",
	-- leathers, hides, scales
	[783]="Light Hide", [2318]="Light Leather",
	[2319]="Medium Leather", [2934]="Ruined Leather Scraps",
	[4232]="Medium Hide", [4234]="Heavy Leather",
	[4235]="Heavy Hide", [4304]="Thick Leather",
	[4461]="Raptor Hide", [5784]="Slimy Murloc Scale",
	[5785]="Thick Murloc Scale", [6470]="Deviate Scale",
	[6471]="Perfect Deviate Scale", [8154]="Scorpid Scale",
	[8165]="Worn Dragonscale", [8167]="Turtle Scale",
	[8169]="Thick Hide", [8170]="Rugged Leather",
	[8171]="Rugged Hide", [15412]="Green Dragonscale",
	[15414]="Red Dragonscale", [15415]="Blue Dragonscale",
	[15416]="Black Dragonscale", [15417]="Devilsaur Leather",
	[15467]="Chromatic Dragonscale", [17012]="Core Leather",
	-- fishing: fish, trunks, rum, elementals
	[6358]="Oily Blackmouth", [6359]="Firefin Snapper",
	[6522]="Deviate Fish", [13422]="Stonescale Eel",
	[19807]="Speckled Tastyfish", [21071]="Raw Sagefish",
	[21153]="Raw Greater Sagefish",
	[20708]="Tightly Sealed Trunk", [21113]="Watertight Trunk",
	[21150]="Iron Bound Trunk", [21228]="Mithril Bound Trunk",
	[20709]="Rumsey Rum Light", [21114]="Rumsey Rum Dark",
	[21115]="Rumsey Rum Black Label",
	[7070]="Elemental Water", [7079]="Globe of Water",
	[7080]="Essence of Water",
}

local function Name(id)
	return GM.ItemName(id) or NAMES[id] or ("item " .. id)
end

-- build drop lines + node EV once per node, cached — the engine
-- wipes object tooltips every frame, so the hot path just re-adds
-- the stored strings (price lookups happen at most once/60s)
local nodeCache, skinCache = {}, {}
local function NodeLines(node)
	local c = nodeCache[node]
	if c and GetTime() - c.t < 60 then return c.lines end
	local drops = NODES[node]
	if not drops then return nil end
	local lines = { " " }
	local total, gemPct, gemEV, anyPrice = 0, 0, 0, false
	for _, d in ipairs(drops) do
		if not d.gem then
			local p = Price(d.id)
			anyPrice = anyPrice or p ~= nil
			local qty = (d.lo + d.hi) / 2
			total = total + (p or 0) * qty * d.pct / 100
			local range = d.lo == d.hi and ("×" .. d.lo)
				or format("×%d–%d", d.lo, d.hi)
			lines[#lines + 1] =
				GM.CC("text") .. Name(d.id) .. "|r "
				.. GM.CC("textDim") .. range
				.. (d.pct < 100 and (" ~" .. d.pct .. "%") or "") .. "|r"
				.. (p and ("  " .. GM.Money(p) .. " ea") or "")
		else
			gemPct = gemPct + d.pct
			local p = Price(d.id)
			gemEV = gemEV + (p or 0) * d.pct / 100
			total = total + (p or 0) * ((d.lo + d.hi) / 2) * d.pct / 100
		end
	end
	if gemPct > 0 then
		lines[#lines + 1] =
			GM.CC("secondary") .. "rare gems ~" .. gemPct .. "%|r"
			.. (gemEV > 0 and ("  +" .. GM.Money(gemEV) .. " expected") or "")
	end
	lines[#lines + 1] = GM.CC("accent") .. "node EV ≈ "
		.. (total > 0 and GM.Money(total) or "?")
		.. (anyPrice and "" or " (no price data)") .. "|r"
	nodeCache[node] = { t = GetTime(), lines = lines }
	return lines
end

-- build the level-banded skin table as cached line strings; family
-- specials (additive extra rolls) render above the band, EV sums
-- both, and a short skill appends the warning row last
local function SkinLines(lvl, name, short)
	local key = tostring(lvl) .. "|" .. tostring(name)
		.. "|" .. tostring(short)
	local c = skinCache[key]
	if c and GetTime() - c.t < 60 then return c.lines end
	local band = SKIN_BANDS[#SKIN_BANDS]
	for _, b in ipairs(SKIN_BANDS) do
		if (lvl or 999) <= b.max then band = b break end
	end
	local specIdx, ln = SpecialFor(name)
	local total, anyPrice = 0, false
	local lines = {
		" ",
		GM.CC("secondary") .. "skinning"
			.. (lvl and lvl > 0 and (" — lvl " .. lvl) or " yields")
			.. "|r",
	}
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
		lines[#lines + 1] =
			GM.CC(mark or "text") .. Name(id) .. "|r "
			.. GM.CC("textDim") .. range
			.. (d.pct < 100 and (" ~" .. d.pct .. "%") or "") .. "|r"
			.. (p and ("  " .. GM.Money(p) .. " ea") or "")
	end
	if specIdx then
		for _, d in ipairs(SKIN_SPECIALS[specIdx].drops) do
			Row(d, "accent")
		end
	end
	for _, d in ipairs(band.drops) do Row(d) end
	lines[#lines + 1] = GM.CC("accent") .. "skin EV ≈ "
		.. (total > 0 and GM.Money(total) or "?")
		.. (anyPrice and "" or " (no price data)") .. "|r"
	if short then
		lines[#lines + 1] = GM.CC("err") .. "skinning skill too low|r"
	end
	skinCache[key] = { t = GetTime(), lines = lines }
	return lines
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

-- true when our appended block is still physically on the tooltip —
-- looting a corpse toggles the "Skinnable" marker and rebuilds the
-- tooltip WITHOUT always wiping appended lines, so bookkeeping state
-- alone can't dedupe re-injection (the source of duplicate blocks)
local function BlockPresent(tt)
	for i = 1, tt:NumLines() do
		local fs = _G["GameTooltipTextLeft" .. i]
		local ok, hit = pcall(function()
			local lt = fs and fs:GetText()
			return lt and lt:find("EV ≈") ~= nil
		end)
		if ok and hit then return true end
	end
	return false
end

-- objects beat the item marker: world objects still report an item
-- link on this client, so a same-named item's side tip can mark an
-- OBJECT tooltip as "item" and suppress the node block. Items never
-- carry "Requires <profession>" lines — when one is present the
-- tooltip is a world object no matter what the marker says.
local function LooksObject(tt)
	for i = 2, math.min(tt:NumLines(), 5) do
		local fs = _G["GameTooltipTextLeft" .. i]
		local ok, hit = pcall(function()
			local lt = fs and fs:GetText()
			return lt and lt:find("^Requires") ~= nil
		end)
		if ok and hit then return true end
	end
	return false
end

-- game-object tooltips have no data-type event — poll the first
-- line on a throttle and inject once per node-text change
if GameTooltip then
	-- the client redraws object tooltips every frame, wiping
	-- appended lines — the fast path re-injects every frame from the
	-- cached line strings so the block never visibly blinks; the
	-- subject-text scan stays throttled
	local pollT = 0
	local function TooltipTick(tt, e)
		if not tt:IsShown() then
			tt._gmInject, tt._gmInjectN, tt._gmInjectTag = nil, nil, nil
			return
		end
		-- item tooltips never take node/skin blocks — a bag item's
		-- name can equal a node name (Kingsblood etc.). GetItem can't
		-- be trusted on Forever (world objects still report a link),
		-- so the check is our own side-tip marker, only built by the
		-- Item post-call
		if GM.Tooltip and GM.Tooltip.IsItemTooltip
			and GM.Tooltip.IsItemTooltip(tt)
			and not LooksObject(tt) then
			tt._gmInject, tt._gmInjectN, tt._gmInjectTag = nil, nil, nil
			return
		end
		-- re-inject ONLY when the whole block is gone — requiring the
		-- full line-count drop prevents partial client redraws from
		-- growing the tooltip's fontstring pool every frame (each
		-- AddLine creates a pooled fontstring that persists until
		-- /reload — unbounded growth = permanent degrade)
		local need = tt._gmInject and #tt._gmInject or 0
		if need > 0 and tt:NumLines() <= tt._gmInjectN - need then
			for _, s in ipairs(tt._gmInject) do tt:AddLine(s) end
			tt:Show()
			tt._gmInjectN = tt:NumLines()
		end
		pollT = pollT + e
		if pollT < 0.15 then return end
		pollT = 0
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
		-- secret-text fallback: object names still read via the
		-- mouseover unit; only node names match, so units/mobs and
		-- bag hovers can't false-positive
		if not text and UnitName then
			local ok, nm = pcall(UnitName, "mouseover")
			if ok and nm and NODES[nm] then text = nm end
		end
		if text and NODES[text] then
			local tag = "node:" .. text
			if tt._gmInjectTag ~= tag and not BlockPresent(tt) then
				local lines = NodeLines(text)
				if lines then
					-- fresh array — NodeLines returns the CACHED
					-- table; appending observed lines to it would
					-- corrupt nodeCache
					local out = {}
					for _, s in ipairs(lines) do
						out[#out + 1] = s
					end
					if GM.Gather and GM.Gather.DropLines then
						for _, s in ipairs(
							GM.Gather.DropLines(text)) do
							out[#out + 1] = s
						end
					end
					lines = out
					for _, s in ipairs(lines) do tt:AddLine(s) end
					tt:Show()
					tt._gmInject, tt._gmInjectTag = lines, tag
					tt._gmInjectN = tt:NumLines()
				end
			end
		else
			-- unit/corpse tooltip — observed drop tables from the
			-- gather yields (kill + skinning records) ahead of the
			-- static skinnable estimate when it applies
			local skin, shortSkill = Skinnable(tt)
			-- GetUnit/UnitLevel can hand back secrets under
			-- taint — keep the whole read inside one pcall
			local okU, name, lvl = pcall(function()
				local n, u = tt:GetUnit()
				return n, u and UnitLevel(u)
			end)
			local lines = {}
			if okU and name and GM.Gather
				and GM.Gather.DropLines then
				for _, s in ipairs(GM.Gather.DropLines(name)) do
					lines[#lines + 1] = s
				end
			end
			if skin then
				for _, s in ipairs(
					SkinLines(lvl, okU and name, shortSkill)
						or {}) do
					lines[#lines + 1] = s
				end
			end
			local tag = "unit:" .. tostring(okU and name)
				.. ":" .. tostring(lvl) .. ":" .. tostring(skin)
			if #lines > 0 then
				if tt._gmInjectTag ~= tag and not BlockPresent(tt) then
					for _, s in ipairs(lines) do tt:AddLine(s) end
					tt:Show()
					tt._gmInject, tt._gmInjectTag = lines, tag
					tt._gmInjectN = tt:NumLines()
				end
			else
				tt._gmInject, tt._gmInjectN, tt._gmInjectTag =
					nil, nil, nil
			end
		end
	end

	-- timing wrapper: perf reports need to separate "the hook fired"
	-- (fps, tooltip visibility) from "the hook cost" (our own ms).
	-- The whole body is pcalled — this client returns SECRET values
	-- from IsShown/GetName under taint, and a per-frame throw is
	-- itself a perf bomb (stack walk + error handler each frame)
	local profStop = debugprofilestop
		or function() return GetTime() * 1000 end
	GameTooltip:HookScript("OnUpdate", function(tt, e)
		local t0 = profStop()
		G._ticks = (G._ticks or 0) + 1
		local okT = pcall(function()
			if tt:IsShown() then
				G._shownTicks = (G._shownTicks or 0) + 1
			end
			TooltipTick(tt, e)
		end)
		if not okT then
			G._tickErrs = (G._tickErrs or 0) + 1
		end
		G._costMs = (G._costMs or 0) + profStop() - t0
	end)
	GameTooltip:HookScript("OnHide", function(tt)
		tt._gmInject = nil
		tt._gmInjectN = nil
		tt._gmInjectTag = nil
	end)
end

-- itemID -> gather-source family: "ore" | "herb" | "leather" |
-- "cloth" | "flesh". Used by the loot recorder to tell a
-- node/skin window from a corpse window (Forever gathers
-- instantly — no spellcast arm survives to attribute the loot),
-- and by camp rows to label what a zone actually produces.
-- Static ids cover the classic mats; the item-subtype fallback
-- catches Forever customs and edge drops.
local CAT_ID = {}
for _, id in ipairs({
	774, 818, 11370, 11382, 1206, 1210, 1529, 1705, 2770, 2771,
	2772, 2775, 2776, 2835, 2836, 2838, 3340, 3858, 3864, 7909,
	7910, 7911, 7912, 10620, 12361, 12364, 12365, 12799, 12800,
}) do CAT_ID[id] = "ore" end
for id in pairs(HERB_ITEMS) do CAT_ID[id] = "herb" end
for _, id in ipairs({
	783, 2318, 2319, 2934, 4232, 4234, 4235, 4304, 4461, 5784,
	5785, 6470, 6471, 8154, 8165, 8167, 8169, 8170, 8171, 15412,
	15414, 15415, 15416, 15417, 15467, 17012,
}) do CAT_ID[id] = "leather" end
for _, id in ipairs({
	2589, 2592, 4306, 4338, 14047, 14256, 14342, 2996, 2997,
	4305, 4339, 14048,
}) do CAT_ID[id] = "cloth" end
for _, id in ipairs({
	2672, 2673, 2674, 3173, 3685, 5503, 5504, 6303, 6308, 6317,
	6358, 6359, 6361, 6362, 6522, 6889, 8365, 12037, 12184,
	12202, 12203, 12204, 12205, 12206, 12207, 12208, 12223,
	13422, 13754, 13755, 13756, 13757, 13758, 13759, 13760,
	13888, 13889, 13893, 19807, 21024, 21071, 21153,
}) do CAT_ID[id] = "flesh" end

local SUB_CAT = {
	["Metal & Stone"] = "ore",
	["Herb"] = "herb",
	["Leather"] = "leather",
	["Cloth"] = "cloth",
	["Cooking"] = "flesh",
	["Meat"] = "flesh",
}

local catCache = {}
function G.ItemCat(id)
	local c = catCache[id]
	if c ~= nil then return c or nil end
	c = CAT_ID[id]
	if not c and GetItemInfo then
		-- itemSubType is index 7 on both classic and modern
		-- GetItemInfo shapes
		local ok, sub = pcall(function()
			return select(7, GetItemInfo(id))
		end)
		if ok and type(sub) == "string" then
			c = SUB_CAT[sub]
		end
	end
	catCache[id] = c or false
	return c
end
