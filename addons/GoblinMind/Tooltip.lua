local _, GM = ...

-- Full port of TSM's tooltip: a registry of named sections (General,
-- AuctionDB, Accounting, Auctioning, Crafting, Shopping, Sniper), each
-- with settings-gated entries. Keys/defaults mirror TSM's schema
-- (LibTSMSystem/AddonSettings/Schema.lua + each section's Register()).
-- Entries whose data doesn't exist yet (crafting, destroy, convert,
-- vendor buy, alt realm) are still registered — they populate nothing
-- until their parts land, matching TSM's nil-hides-line behavior.
--
-- Render: side tip beside the native tooltip (default) or embedded
-- lines inside it (tooltip.embeddedTooltip). Shift shows stack totals
-- on accounting lines like TSM's showStackValues.

GM.Tooltip = {}
local TT = GM.Tooltip

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo

-- ============ settings (TSM tooltipOptions schema) ============

local OPT_DEFAULTS = {
	enabled = true,
	embeddedTooltip = false,   -- TSM default is true; ours renders beside
	tooltipShowModifier = "none", -- "none" | "alt" | "ctrl"
	tooltipPriceFormat = "text",  -- "text" | "icon"
	vendorBuyTooltip = true,
	vendorSellTooltip = true,
	groupNameTooltip = true,
	destroyTooltipFormat = "simple", -- "full" | "simple" | "none"
	dropSourceTooltipFormat = "simple",
	convertTooltipFormat = "simple",
	inventoryTooltipFormat = "full", -- "full" | "simple" | "none"
	operationTooltips = {},          -- [opType] = bool, all default false
	customPriceTooltips = {},        -- [sourceName] = bool, all default false
	moduleTooltips = {
		AuctionDB = {
			minBuyout = true,
			marketValueRecent = false,
			marketValue = "withTrend", -- "withTrend" | "noTrend" | "none"
			historical = false,
			-- alt-realm entries registered for parity; no alt data on
			-- a single-realm Forever scope, so they never populate
			altMinBuyout = false,
			altMarketValueRecent = false,
			altMarketValue = "none",
			altHistorical = false,
			regionMarketValue = "withTrend",
			regionHistorical = false,
			regionSale = true,
			regionSalePercent = true,
			regionSoldPerDay = true,
			-- GoblinMind extensions (not in TSM)
			band = true,
			vsTSM = true,
			resetSignal = true,
			liveBook = true,
		},
		Accounting = {
			purchase = true,
			sale = true,
			saleRate = false,
			expiredAuctions = false,
			cancelledAuctions = false,
		},
		Auctioning = {
			postQuantity = false,
			operationPrices = false,
		},
		Crafting = {
			craftingCost = true,
			detailedMats = false,
			matPrice = false,
		},
		Shopping = { maxPrice = false },
		Sniper = { belowPrice = false },
	},
}

local function Merge(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			Merge(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

local function Opts()
	if not GM.db then return OPT_DEFAULTS end
	GM.db.tooltip = GM.db.tooltip or {}
	Merge(GM.db.tooltip, OPT_DEFAULTS)
	return GM.db.tooltip
end

-- entry enabled check: module entries read moduleTooltips[module],
-- global entries read the top-level table; dotted keys nest one level
-- ("operationTooltips.auctioning" → tbl.operationTooltips.auctioning);
-- value-entries match a mode ("marketValue" == "withTrend")
local OptTable -- forward decl (lives with TT.GetOption below)

local function On(e)
	local tbl, key = OptTable(e.key, e.module)
	if type(tbl) ~= "table" then return e.default == e.set end
	local v = tbl[key]
	if v == nil then
		v = e.default
		tbl[key] = v
	end
	return v == e.set
end

local MoneyFmt -- forward decl: Builder methods reference it

-- ============ line builder (mirrors TooltipBuilder surface) ============

local function Builder()
	local lines = {}
	local B = { lines = lines, disabled = false }
	function B:AddTextLine(left, right)
		tinsert(lines, { left = left, right = right })
	end
	function B:AddItemValueLine(left, copper, suffix)
		local r = MoneyFmt(copper)
		if suffix then r = r .. " " .. suffix end
		tinsert(lines, { left = left, right = r, accent = true })
	end
	function B:AddItemValuesLine(left, ...)
		local parts = {}
		for _, v in ipairs({ ... }) do tinsert(parts, MoneyFmt(v) or "—") end
		tinsert(lines, { left = left, right = table.concat(parts, " / "), accent = true })
	end
	function B:AddQuantityValueLine(left, qty, ...)
		local parts = {}
		for _, v in ipairs({ ... }) do tinsert(parts, MoneyFmt(v) or "—") end
		tinsert(lines, { left = left, right = "×" .. qty .. " @ " .. table.concat(parts, " / "), accent = true })
	end
	function B:AddSubItemValueLine(itemID, copper, qty, rate, mn, mx)
		local nm = (GM.ItemName and GM.ItemName(itemID)) or ("item " .. tostring(itemID))
		local extra = rate and format(" @%.0f%%", rate * 100)
			or (mn and mx and mn ~= mx and format(" %d–%d", mn, mx) or "")
		tinsert(lines, { left = "    " .. nm .. (qty and (" ×" .. format("%.1f", qty)) or "") .. (extra or ""),
			right = MoneyFmt(copper) })
	end
	function B:StartSection(heading, right)
		tinsert(lines, { section = true, left = heading, right = right })
	end
	function B:EndSection() end
	function B:Empty() return #lines == 0 end
	return B
end

-- ============ money + misc helpers ============

local COIN_TEX = {
	g = "|TInterface\\MoneyFrame\\UI-GoldIcon:11:11:1:0|t",
	s = "|TInterface\\MoneyFrame\\UI-SilverIcon:11:11:1:0|t",
	c = "|TInterface\\MoneyFrame\\UI-CopperIcon:11:11:1:0|t",
}

MoneyFmt = function(v)
	if not v then return nil end
	if Opts().tooltipPriceFormat ~= "icon" then return GM.Money(v) end
	local g, s = floor(v / 10000), floor(v / 100) % 100
	local c = floor(v) % 100
	local out = c .. COIN_TEX.c
	if s > 0 or g > 0 then out = s .. COIN_TEX.s .. " " .. out end
	if g > 0 then out = g .. COIN_TEX.g .. " " .. out end
	return out
end

-- this client's string-width measuring ignores |T|t texture escapes,
-- so a GameTooltip auto-sizes icon-mode money lines too narrow and
-- the right column overhangs the frame. Measure with the tags
-- stripped, sum the icon widths back in, and widen the tip ourselves.
local measurers = {}
local function LineW(text, font, size)
	if not text then return 0 end
	font, size = font or GM.FONT, size or 11
	local key = font .. "|" .. size
	local mfs = measurers[key]
	if not mfs then
		mfs = UIParent:CreateFontString(nil, "OVERLAY")
		mfs:SetFont(font, size, "")
		measurers[key] = mfs
	end
	local icons = 0
	mfs:SetText((text:gsub("|T[^|]-|t", function(tag)
		icons = icons + (tonumber(tag:match(":(%d+)")) or 11) + 2
		return ""
	end)))
	return mfs:GetStringWidth() + icons
end

local function AgeStr(t0)
	if not t0 then return nil end
	local d = time() - t0
	return GM.FmtAge(d) .. " ago"
end

local function Trend(value, ref)
	-- signed, colored, no brackets: "1g 20s +9%". nil when there's no
	-- long-run reference — a bare "[---]" reads as broken, not absent
	if not (value and ref and ref > 0) then return nil end
	local d = math.floor((value - ref) / ref * 100 + 0.5)
	return GM.CC(d >= 0 and "pos" or "err") .. (d >= 0 and "+" or "")
		.. d .. "%|r"
end

local function Price(key, itemID)
	local v = GM.Pricing and GM.Pricing.Eval(key, itemID)
	return v
end

-- ============ section 1: General ============

local function P_Group(t, id)
	local path = id and GM.Groups.GroupForItem and GM.Groups.GroupForItem(id)
	if not path or path == "Base Group" then return end
	-- deep paths eat the label column — keep the tail: "…/B/C"
	local a, b = path:match("([^/]+)/([^/]+)$")
	if a and path:find("/[^/]+/[^/]+") then path = "…/" .. a .. "/" .. b end
	t:AddTextLine("Group", path)
end

local function P_Ops(t, id, opType, e)
	local path = id and GM.Groups.GroupForItem and GM.Groups.GroupForItem(id)
	if not path then return end
	-- only list op types actually overridden somewhere in the chain,
	-- not the always-on defaults — walk "A", "A/B", "A/B/C"
	local found, acc = false, nil
	for seg in path:gmatch("[^/]+") do
		acc = acc and (acc .. "/" .. seg) or seg
		local g = GM.Groups.db.groups[acc]
		if g and g.ops and g.ops[opType] then found = true end
	end
	if found then
		t:AddTextLine(e.label, path)
	end
end

local function P_VendorBuy(t, id)
	local v = Price("vendorbuy", id)
	if v and v > 0 then t:AddItemValueLine("Buy from vendor", v) end
end

local function P_VendorSell(t, id)
	local v = GetInfo and select(11, GetInfo(id))
	if v and v > 0 then t:AddItemValueLine("Sell to vendor", v) end
end

local function P_Destroy(t, id)
	-- herbs: milling doesn't exist on Forever — no destroy output at all
	if GM.Gathering and GM.Gathering.IsHerb and GM.Gathering.IsHerb(id) then
		return
	end
	local v = Price("destroy", id)
	-- "full" format appends the disenchant drop table — same shape as
	-- the gathering node tooltips: name ×lo–hi ~pct% · price ea. The
	-- table is data (not priced) — render it even when the EV itself
	-- is honest-nil so the drop chances are never gated on mat prices
	local drops = Opts().destroyTooltipFormat == "full"
		and GM.Destroying and GM.Destroying.DisenchantDrops
		and GM.Destroying.DisenchantDrops(id)
	-- suppress when destroying earns nothing over vendoring — herbs,
	-- ores, and mats only ever show vendor price (mill/prospect don't
	-- exist on Forever) and the sell line already carries it
	local vendor = GetInfo and select(11, GetInfo(id)) or 0
	if v and v > vendor then t:AddItemValueLine("Disenchant value", v) end
	if not drops then return end
	for _, d in ipairs(drops) do
		local p = Price("dbmarket", d.id)
		local range = d.lo == d.hi and tostring(d.lo)
			or format("%d–%d", d.lo, d.hi)
		t:AddTextLine(
			"    " .. GM.CC("text") .. GM.ItemNameOr(d.id) .. "|r "
				.. GM.CC("textDim") .. range .. " · " .. d.pct .. "%|r",
			p and (MoneyFmt(p) .. " each") or nil)
	end
end

local function P_Drops(t, id)
	local src = GM.Drops and GM.Drops.TopSources
		and GM.Drops.TopSources(id, 3)
	if not src then return end
	local full = Opts().dropSourceTooltipFormat == "full"
	local parts = {}
	for _, s in ipairs(src) do
		local nm = s.name or ("#" .. s.src:sub(2))
		local pct = format("%d%%", floor(s.rate * 100 + 0.5))
		if s.low then pct = "~" .. pct end
		tinsert(parts, nm .. " " .. pct
			.. (full and GM.CC("textDim") .. " n=" .. s.n .. "|r" or ""))
	end
	-- whole line bounded: names truncated, joined list clipped
	local line = "Drops: " .. table.concat(parts, " · ")
	if #line > 96 then line = line:sub(1, 93) .. "…" end
	t:AddTextLine(GM.CC("text") .. line .. "|r")
end

local function P_Convert(t, id)
	-- herbs: convert is mill->pigment on TSM; not a Forever action
	if GM.Gathering and GM.Gathering.IsHerb and GM.Gathering.IsHerb(id) then
		return
	end
	-- mill/prospect/transform source-of-cheapest lands with Part 10
	local v = Price("convert", id)
	if not v then return end
	t:AddItemValueLine("Convert value", v)
end

-- inventory "where" parts — omit zero buckets entirely
local function InvParts(bags, bank, auction, mail)
	local p = {}
	if bags > 0 then p[#p + 1] = bags .. " bags" end
	if bank > 0 then p[#p + 1] = bank .. " bank" end
	if auction > 0 then p[#p + 1] = auction .. " listed" end
	if mail > 0 then p[#p + 1] = mail .. " mail" end
	return table.concat(p, " · ")
end

local function P_InventoryFull(t, id)
	local inv = GM.Inventory.Count(id)
	if inv.total == 0 then return end
	t:AddTextLine("You own", GM.CC("text") .. inv.total .. "|r")
	local who = UnitName("player") or "player"
	local mine = InvParts(inv.bags, inv.bank, inv.auction, inv.mail)
	t:AddTextLine("    " .. who,
		GM.CC("text") .. (mine ~= "" and mine or "0 held") .. "|r")
	if inv.guild > 0 then
		local g = GetGuildInfo("player") or "guild"
		t:AddTextLine("    " .. g,
			GM.CC("text") .. format("%d in guild bank", inv.guild) .. "|r")
	end
end

local function P_InventorySimple(t, id)
	local inv = GM.Inventory.Count(id)
	if inv.total == 0 then return end
	local p = {}
	local mine = inv.bags + inv.bank + inv.mail
	if mine > 0 then p[#p + 1] = mine .. " yours" end
	if inv.guild > 0 then p[#p + 1] = inv.guild .. " guild" end
	if inv.auction > 0 then p[#p + 1] = inv.auction .. " listed" end
	t:AddTextLine("You own", GM.CC("text") .. inv.total
		.. (#p > 0 and (" (" .. table.concat(p, " · ") .. ")") or "") .. "|r")
end

-- ============ section 2: AuctionDB ============

local function A_RightText(id)
	-- provenance comes from the resolver itself: ItemEntry tags the
	-- observation source that won (_src/_srcT) — book, mesh, or the
	-- emitted row — so the label always matches the value shown
	local e = GM.ItemEntry(id)
	local n = e and e.sup or 0
	local src, srcT = e and e._src, e and e._srcT
	local age = srcT and (time() - srcT) or GM.DataAge()
	local maxAge = GM.db and GM.db.dataMaxAge or 7200
	-- one threshold rule (F6): textDim until dataMaxAge, warn past it
	local tag = src == "book" and " · your scan"
		or src == "mesh" and " · shared" or ""
	return GM.CC("text") .. format("%d listed", n) .. GM.CC("textDim")
		.. " · " .. GM.CC(age and age >= maxAge and "warn" or "textDim")
		.. (age and (GM.FmtAge(age) .. " ago") or "no scan yet")
		.. tag .. "|r"
end

local function P_MinBuyout(t, id)
	-- observation source resolved inside ItemEntry (book → mesh → emit);
	-- ef reads the overlaid field
	local v = Price("dbminbuyout", id)
	if v then t:AddItemValueLine("Lowest buyout", v) end
end

local function P_Recent(t, id)
	local v = Price("dbrecent", id)
	if v then t:AddItemValueLine("Recent price", v) end
end

local function P_Market(t, id, trend)
	local v = Price("dbmarket", id)
	if not v then return end
	t:AddItemValueLine("Typical price", v, trend and Trend(v, Price("dbhistorical", id)) or nil)
end

local function P_Historical(t, id)
	local v = Price("dbhistorical", id)
	if v then t:AddItemValueLine("Long-run price", v) end
end

local function P_RegionMarket(t, id, trend)
	local v = Price("dbregionmarketavg", id)
	if not v then return end
	t:AddItemValueLine("Typical (region)", v,
		trend and Trend(v, Price("dbregionhistorical", id)) or nil)
end

local function P_RegionHistorical(t, id)
	local v = Price("dbregionhistorical", id)
	if v then t:AddItemValueLine("Long-run (region)", v) end
end

local function P_RegionSale(t, id)
	local v = Price("dbregionsale", id)
	if v then t:AddItemValueLine("Sold for (region)", v) end
end

local function P_RegionSaleRate(t, id)
	local v = Price("dbregionsalepercent", id)
	if v then
		-- percent reads like a chance; TSM's own docs explain it that way
		t:AddTextLine("Sell chance (region)", GM.CC("text")
			.. (v < 0.005 and "<1%" or format("%.0f%%", v * 100)) .. "|r")
	end
end

local function P_RegionSoldPerDay(t, id)
	local v = Price("dbregionsalerate", id)
	if v then t:AddTextLine("Sold/day (region)", GM.CC("text") .. (GM.VelRate(v) or format("%0.1f", v)) .. "|r") end
end

-- GoblinMind extensions
local function P_Band(t, id)
	local e = GM.ItemEntry(id)
	if e and e.p10 and e.p90 then
		-- placeholder math upstream (p × 0.85 / p × 1.15), NOT a real
		-- percentile band — the label must not read as a forecast
		t:AddTextLine("±15% of price",
			MoneyFmt(e.p10) .. " – " .. MoneyFmt(e.p90))
	end
end

local function P_VsTSM(t, id)
	local e = GM.ItemEntry(id)
	local m = GM.TSMMarket(id)
	if e and e.p and m and m > 0 then
		local d = (e.p - m) / m * 100
		t:AddTextLine("vs TSM price", GM.CC(d >= 0.5 and "pos" or d <= -0.5 and "err" or "textDim")
			.. format("%+.0f%%", d) .. "|r")
	end
end

local function P_Reset(t, id)
	local e = GM.ItemEntry(id)
	local rs = e and e.reset
	if type(rs) == "table" then
		t:AddTextLine("Bargain listed", GM.CC("warn") .. GM.Money(rs.below)
			.. " · flip ~" .. GM.Money(rs.ev) .. "|r")
	elseif type(rs) == "number" and rs > 0 then
		-- the in-house feed emits reset as a bare flag (=1), not a
		-- threshold — rendering it as money printed "below 1c" (F5).
		-- Anchor on the current cheapest listing instead
		t:AddTextLine("Bargain listed", GM.CC("warn")
			.. (e.mb and GM.Money(e.mb) or "cheap")
			.. " · half price or less|r")
	end
end

local function P_LiveBook(t, id)
	local fresh = GM.AH.BookLive and GM.AH.BookLive()
	if not fresh then return end
	local mn, sup = GM.AH.BookMin(id), GM.AH.BookSupply(id)
	if mn then
		t:AddTextLine("Your scan", GM.CC("text") .. GM.Money(mn)
			.. (sup and (" · " .. sup .. " listed") or "") .. "|r")
	end
end

-- ============ section 3: Accounting ============

local function P_Purchase(t, id, stack)
	local s = GM.Ledger and GM.Ledger.db and GM.Ledger.db.itemStats[id]
	if not s or not s.buyQ or s.buyQ == 0 then return end
	if stack then
		t:AddTextLine("You bought ×" .. s.buyQ,
			MoneyFmt(s.buyT) .. " total")
	else
		t:AddTextLine("You bought ×" .. s.buyQ,
			"avg " .. MoneyFmt(s.buyT / s.buyQ))
		-- range is trader-level detail (R6) — Simple mode stays lean
		if (not TT.CurrentPreset or TT.CurrentPreset() ~= "simple")
			and s.buyMin ~= math.huge and s.buyMin ~= s.buyMax then
			t:AddTextLine("    range",
				MoneyFmt(s.buyMin) .. " – " .. MoneyFmt(s.buyMax))
		end
	end
	local smart = GM.Ledger.Avg(id, "paid")
	if smart then t:AddItemValueLine("Avg cost (on hand)", smart) end
	if s.lastBuy then t:AddTextLine("Last bought", GM.CC("textDim") .. AgeStr(s.lastBuy) .. "|r") end
end

local function P_Sale(t, id, stack)
	local s = GM.Ledger and GM.Ledger.db and GM.Ledger.db.itemStats[id]
	if not s or not s.sellQ or s.sellQ == 0 then return end
	if stack then
		t:AddTextLine("You sold ×" .. s.sellQ,
			MoneyFmt(s.sellT) .. " total")
	else
		t:AddTextLine("You sold ×" .. s.sellQ,
			"avg " .. MoneyFmt(s.sellT / s.sellQ))
		-- range is trader-level detail (R6) — Simple mode stays lean
		if (not TT.CurrentPreset or TT.CurrentPreset() ~= "simple")
			and s.sellMin ~= math.huge and s.sellMin ~= s.sellMax then
			t:AddTextLine("    range",
				MoneyFmt(s.sellMin) .. " – " .. MoneyFmt(s.sellMax))
		end
	end
	if s.lastSell then t:AddTextLine("Last sold", GM.CC("textDim") .. AgeStr(s.lastSell) .. "|r") end
end

local function P_SaleRate(t, id)
	local st = GM.Ledger and GM.Ledger.Stats and GM.Ledger.Stats(id)
	if st and st.saleRate then
		t:AddTextLine("Your sell rate", GM.CC("text")
			.. format("%.0f%%", st.saleRate * 100) .. "|r")
	end
end

local function P_Expired(t, id)
	local st = GM.Ledger and GM.Ledger.Stats and GM.Ledger.Stats(id)
	if st and st.expireSinceSell > 0 then
		t:AddTextLine("Expired (since sale)", tostring(st.expireSinceSell))
	end
end

local function P_Cancelled(t, id)
	local st = GM.Ledger and GM.Ledger.Stats and GM.Ledger.Stats(id)
	if st and st.cancelSinceSell > 0 then
		t:AddTextLine("Cancelled (since sale)", tostring(st.cancelSinceSell))
	end
end

-- ============ sections 4-7: ops + crafting ============

local function P_PostQuantity(t, id)
	local ops = GM.Groups.GetOps(id, "auctioning")
	if not ops then return end
	local cap, stack = tonumber(ops.postCap), tonumber(ops.stackSize)
	if not cap or cap == 0 then
		t:AddTextLine("Posts at a time", "not set") return end
	t:AddTextLine("Posts at a time", stack and stack > 0
		and format("%d stacks of %d", cap, stack) or tostring(cap))
end

local function P_OpPrices(t, id)
	local ops = GM.Groups.GetOps(id, "auctioning")
	if not ops then return end
	t:AddItemValuesLine("Post min/normal/max",
		GM.Groups.EvalOp(ops, "min", id),
		GM.Groups.EvalOp(ops, "normal", id),
		GM.Groups.EvalOp(ops, "max", id))
end

local function P_CraftingCost(t, id)
	local v = Price("crafting", id)
	if not v then return end
	local p = Price("dbmarket", id)
	local profit = p and (p - v)
	t:AddTextLine("Cost to craft", MoneyFmt(v)
		.. (profit and (" · " .. GM.CC(profit >= 0 and "pos" or "err")
			.. (profit >= 0 and "+" or "-") .. MoneyFmt(math.abs(profit))
			.. (profit >= 0 and " profit" or " loss") .. "|r") or ""))
end

local function P_MatPrice(t, id)
	local v = Price("matprice", id)
	if v then t:AddItemValueLine("Value as material", v) end
end

local function P_ShoppingMax(t, id)
	local v = GM.Groups.EvalOp(GM.Groups.GetOps(id, "shopping"), "maxPrice", id)
	if v then t:AddItemValueLine("Shopping buys under", v) end
end

local function P_SniperBelow(t, id)
	local v = GM.Groups.EvalOp(GM.Groups.GetOps(id, "sniper"), "belowPrice", id)
	if v then t:AddItemValueLine("Sniper buys under", v) end
end

-- ============ registry (order = TSM's registration order) ============

local function CustomSourceEntry(name)
	local short = #name > 22 and (name:sub(1, 21) .. "…") or name
	return { key = "customPriceTooltips." .. name, global = true,
		custom = name, set = true, default = false,
		label = short, settingLabel = "Custom: " .. name,
		gloss = 'Your custom price formula "' .. name .. '".',
		fn = function(t, id)
			local src = GoblinMindPrices and GoblinMindPrices.customSources
				and GoblinMindPrices.customSources[name]
			local v = src and GM.Pricing and GM.Pricing.Eval(src, id)
			if v and v > 0 then
				t:AddItemValueLine(short, v)
			end
		end }
end

local function Sections()
	-- heading = tooltip section head (nil = straight under the title);
	-- name = settings group label. label = the row's left-column text
	-- (≤22 chars); gloss = settings hover text; settingLabel overrides
	-- label for the settings row when it needs different phrasing
	local general = {
		name = "Item",
		entries = {
			{ key = "groupNameTooltip", set = true, default = false,
				label = "Group",
				gloss = "The GoblinMind group this item is filed under; its rules come from here.",
				fn = P_Group },
		},
	}
	for _, opType in ipairs(GM.Groups.OP_TYPES or {}) do
		local cap = opType:gsub("^%l", strupper)
		tinsert(general.entries, {
			key = "operationTooltips." .. opType, global = true,
			set = true, default = false,
			label = cap .. " rules from",
			settingLabel = cap .. " rules source",
			gloss = "This item's " .. opType .. " settings come from this group, not the defaults.",
			fn = function(t, id, s, e) P_Ops(t, id, opType, e) end,
		})
	end
	tinsert(general.entries, { key = "destroyTooltipFormat", set = "full",
		default = "simple", label = "Disenchant value",
		gloss = "Typical AH worth of the materials from disenchanting one. Only shown when it beats the vendor price.",
		fn = P_Destroy })
	tinsert(general.entries, { key = "destroyTooltipFormat", set = "simple",
		default = "simple", label = "Disenchant value",
		gloss = "Typical AH worth of the materials from disenchanting one. Only shown when it beats the vendor price.",
		fn = P_Destroy })
	tinsert(general.entries, { key = "dropSourceTooltipFormat", set = "full",
		default = "simple", label = "Drop sources",
		gloss = "Mobs/objects you've actually looted this item from, with observed rates (sample counts shown).",
		fn = P_Drops })
	tinsert(general.entries, { key = "dropSourceTooltipFormat", set = "simple",
		default = "simple", label = "Drop sources",
		gloss = "Mobs/objects you've actually looted this item from, with observed rates.",
		fn = P_Drops })
	-- hidden = stays registered for TSM import parity but no settings
	-- row — the producer is a no-op / not active on this client (R7)
	tinsert(general.entries, { key = "convertTooltipFormat", set = "full",
		default = "none", hidden = true, label = "Convert value",
		gloss = "Worth of what this turns into (e.g. combining essences). Not active yet.",
		fn = P_Convert })
	tinsert(general.entries, { key = "convertTooltipFormat", set = "simple",
		default = "none", hidden = true, label = "Convert value",
		gloss = "Worth of what this turns into (e.g. combining essences). Not active yet.",
		fn = P_Convert })
	tinsert(general.entries, { key = "vendorBuyTooltip", set = true,
		default = false, label = "Buy from vendor",
		gloss = "What an NPC merchant charges you for one.",
		fn = P_VendorBuy })
	tinsert(general.entries, { key = "vendorSellTooltip", set = true,
		default = true, label = "Sell to vendor",
		gloss = "What an NPC merchant pays you for one.",
		fn = P_VendorSell })
	-- custom price sources get one entry each (all default off, like TSM)
	for name in pairs((GoblinMindPrices and GoblinMindPrices.customSources) or {}) do
		tinsert(general.entries, CustomSourceEntry(name))
	end
	tinsert(general.entries, { key = "inventoryTooltipFormat", set = "full",
		default = "simple", label = "You own",
		settingLabel = "How many you own",
		gloss = "How many you have, and where.",
		fn = P_InventoryFull })
	tinsert(general.entries, { key = "inventoryTooltipFormat", set = "simple",
		default = "simple", label = "You own",
		settingLabel = "How many you own",
		gloss = "Count across your bags, bank, mail, guild bank, and live auctions.",
		fn = P_InventorySimple })

	return {
		general,
		{
			heading = "Auction House", name = "Auction House",
			module = "AuctionDB",
			right = A_RightText,
			entries = {
				{ key = "minBuyout", module = "AuctionDB", set = true, default = true,
					label = "Lowest buyout",
					gloss = "Cheapest buyout on the Auction House right now, per item.",
					fn = P_MinBuyout },
				{ key = "marketValueRecent", module = "AuctionDB", set = true, default = false,
					label = "Recent price",
					gloss = "Market price weighted toward the latest scans.",
					fn = P_Recent },
				{ key = "marketValue", module = "AuctionDB", set = "noTrend", default = "withTrend",
					label = "Typical price",
					gloss = "What this usually goes for, averaged over recent days with odd listings ignored.",
					fn = function(t, id) P_Market(t, id, false) end },
				{ key = "marketValue", module = "AuctionDB", set = "withTrend", default = "withTrend",
					label = "Typical price",
					gloss = "What this usually goes for, averaged over recent days with odd listings ignored. The % compares it with the long-run price.",
					fn = function(t, id) P_Market(t, id, true) end },
				{ key = "historical", module = "AuctionDB", set = true, default = false,
					label = "Long-run price",
					gloss = "Average over a longer stretch (up to 60 days on TSM data, 14 on your own scans).",
					fn = P_Historical },
				{ key = "altMinBuyout", module = "AuctionDB", set = true, default = false, hidden = true, fn = function() end },
				{ key = "altMarketValueRecent", module = "AuctionDB", set = true, default = false, hidden = true, fn = function() end },
				{ key = "altMarketValue", module = "AuctionDB", set = "noTrend", default = "none", hidden = true, fn = function() end },
				{ key = "altMarketValue", module = "AuctionDB", set = "withTrend", default = "none", hidden = true, fn = function() end },
				{ key = "altHistorical", module = "AuctionDB", set = true, default = false, hidden = true, fn = function() end },
				{ key = "regionMarketValue", module = "AuctionDB", set = "noTrend", default = "none",
					label = "Typical (region)",
					gloss = "Typical price averaged across every realm in your region.",
					fn = function(t, id) P_RegionMarket(t, id, false) end },
				{ key = "regionMarketValue", module = "AuctionDB", set = "withTrend", default = "none",
					label = "Typical (region)",
					gloss = "Typical price averaged across every realm in your region.",
					fn = function(t, id) P_RegionMarket(t, id, true) end },
				{ key = "regionHistorical", module = "AuctionDB", set = true, default = false,
					label = "Long-run (region)",
					gloss = "Long-run price across the whole region.",
					fn = P_RegionHistorical },
				{ key = "regionSale", module = "AuctionDB", set = true, default = false,
					label = "Sold for (region)",
					gloss = "Average price that actually sold, not just listed. Can come from this realm's scans when fresher.",
					fn = P_RegionSale },
				{ key = "regionSalePercent", module = "AuctionDB", set = true, default = true,
					label = "Sell chance (region)",
					gloss = "How often a listing actually sells instead of expiring. 33% ≈ 1 sale per 3 posts.",
					fn = P_RegionSaleRate },
				{ key = "regionSoldPerDay", module = "AuctionDB", set = true, default = true,
					label = "Sold/day (region)",
					gloss = "Average number sold per day per Auction House. High = sells fast.",
					fn = P_RegionSoldPerDay },
				{ key = "band", module = "AuctionDB", set = true, default = false,
					label = "±15% of price", settingLabel = "±15% reference",
					gloss = "A fixed ±15% around the typical price, for reference only. It is not a forecast.",
					fn = P_Band },
				{ key = "vsTSM", module = "AuctionDB", set = true, default = false,
					label = "vs TSM price",
					gloss = "How GoblinMind's price compares with TradeSkillMaster's. Only shown when TSM is installed.",
					fn = P_VsTSM },
				{ key = "resetSignal", module = "AuctionDB", set = true, default = false,
					label = "Bargain listed",
					gloss = "Someone is listing well under the typical price. Buying those and reposting could earn about this much.",
					fn = P_Reset },
				{ key = "liveBook", module = "AuctionDB", set = true, default = false,
					label = "Your scan", settingLabel = "Your latest scan",
					gloss = "Lowest price and count from your own latest AH scan.",
					fn = P_LiveBook },
			},
		},
		{
			heading = "Your history", name = "Your history",
			module = "Accounting",
			entries = {
				{ key = "purchase", module = "Accounting", set = true, default = false,
					label = "You bought",
					gloss = "How many you've bought on the AH and what you paid on average.",
					fn = P_Purchase },
				{ key = "sale", module = "Accounting", set = true, default = true,
					label = "You sold",
					gloss = "How many you've sold and the average you got.",
					fn = P_Sale },
				{ key = "saleRate", module = "Accounting", set = true, default = false,
					label = "Your sell rate",
					gloss = "Share of your posts that sold, versus expired or cancelled.",
					fn = P_SaleRate },
				{ key = "expiredAuctions", module = "Accounting", set = true, default = false,
					label = "Expired (since sale)",
					gloss = "Your posts that expired unsold since your last sale. Many = priced too high.",
					fn = P_Expired },
				{ key = "cancelledAuctions", module = "Accounting", set = true, default = false,
					label = "Cancelled (since sale)",
					gloss = "Your posts you cancelled since your last sale.",
					fn = P_Cancelled },
			},
		},
		{
			heading = "Your posting rules", name = "Your posting rules",
			module = "Auctioning",
			entries = {
				{ key = "postQuantity", module = "Auctioning", set = true, default = false,
					label = "Posts at a time",
					gloss = "How many auctions your rules post in one go.",
					fn = P_PostQuantity },
				{ key = "operationPrices", module = "Auctioning", set = true, default = false,
					label = "Post min/normal/max",
					gloss = "The floor, normal, and ceiling prices your auctioning rules use.",
					fn = P_OpPrices },
			},
		},
		{
			heading = "Crafting", name = "Crafting", module = "Crafting",
			entries = {
				{ key = "craftingCost", module = "Crafting", set = true, default = true,
					label = "Cost to craft",
					gloss = "Price of the materials, and what's left after selling at the typical price (before the AH's cut).",
					fn = P_CraftingCost },
				{ key = "detailedMats", module = "Crafting", set = true, default = false, hidden = true, fn = function() end },
				{ key = "matPrice", module = "Crafting", set = true, default = false,
					label = "Value as material",
					gloss = "Price GoblinMind uses for this item when it's an ingredient in a craft.",
					fn = P_MatPrice },
			},
		},
		{
			heading = "Shopping list", name = "Shopping list",
			module = "Shopping",
			entries = {
				{ key = "maxPrice", module = "Shopping", set = true, default = false,
					label = "Shopping buys under",
					gloss = "Your shopping list only buys this below this price.",
					fn = P_ShoppingMax },
			},
		},
		{
			heading = "Sniper", name = "Sniper", module = "Sniper",
			entries = {
				{ key = "belowPrice", module = "Sniper", set = true, default = false,
					label = "Sniper buys under",
					gloss = "Your sniper flags listings below this price.",
					fn = P_SniperBelow },
			},
		},
	}
end

-- ============ render ============

local sideTip
local hideHooked = {}

local function AnchorSideTip()
	-- Blizzard's compare tips (ShoppingTooltip1/2) claim the TOPRIGHT
	-- slot of GameTooltip — the same spot we want. Anchor off the
	-- widest edge of the whole shown chain so they can't cover us,
	-- and flip left of the chain when the right edge runs into the
	-- screen bound.
	if not sideTip or not sideTip:IsShown() then return end
	local src = sideTip._src or GameTooltip
	local right, left = src, src
	for _, name in ipairs({ "ShoppingTooltip1", "ShoppingTooltip2" }) do
		local t = _G[name]
		if t and t:IsShown() and t:GetRight() then
			if not right:GetRight() or t:GetRight() > right:GetRight() then
				right = t
			end
			if t:GetLeft() and left:GetLeft()
				and t:GetLeft() < left:GetLeft() then
				left = t
			end
		end
	end
	sideTip:ClearAllPoints()
	local w = sideTip:GetWidth() or 0
	local screenR = UIParent:GetRight() or math.huge
	if right:GetRight() and right:GetRight() + w > screenR
		and left:GetLeft() and left:GetLeft() > w then
		sideTip:SetPoint("TOPRIGHT", left, "TOPLEFT", -2, 0)
	else
		sideTip:SetPoint("TOPLEFT", right, "TOPRIGHT", 2, 0)
	end
end

local SIDE_ROW_H = 15

local function BuildSideTip()
	if sideTip then return end
	-- plain frame, NOT a GameTooltip — this client ignores |T|t icon
	-- escapes when auto-sizing, so icon-mode money columns overhang
	-- the tooltip frame. Our own panel sizes off LineW's real
	-- measurements instead of the broken auto-size.
	local tip = CreateFrame("Frame", "GoblinMindSideTip", UIParent)
	tip:SetFrameStrata("TOOLTIP")
	tip:SetClampedToScreen(true)
	GM.Panel(tip, "contLowest", "outlineVar")
	tip.title = GM.MakeFontString(tip, GM.FONT_BOLD, 12, "accent")
	tip.title:SetPoint("TOPLEFT", 8, -6)
	tip.title:SetText("GoblinMind")
	-- 1px rule under the title — cheap hierarchy separator (R4)
	tip.rule = tip:CreateTexture(nil, "ARTWORK")
	tip.rule:SetColorTexture(GM.RGB("outlineVar"))
	tip.rule:SetPoint("TOPLEFT", 8, -19)
	tip.rule:SetPoint("TOPRIGHT", -8, -19)
	tip.rule:SetHeight(1)
	tip.rows = {}
	tip:Hide()
	sideTip = tip
	-- compare tips can finish populating a frame after our fill —
	-- re-anchor whenever one shows so we stay clear of them
	for _, name in ipairs({ "ShoppingTooltip1", "ShoppingTooltip2" }) do
		local t = _G[name]
		if t then pcall(t.HookScript, t, "OnShow", AnchorSideTip) end
	end
end

local function SideRow(i)
	local r = sideTip.rows[i]
	if not r then
		r = {}
		r.left = GM.MakeFontString(sideTip, GM.FONT, 11, "textDim")
		r.left:SetPoint("TOPLEFT", 8, -20 - (i - 1) * SIDE_ROW_H)
		r.left:SetJustifyH("LEFT")
		-- right-anchored + right-justified: the text ends at the inset
		-- regardless of the fontstring's (mis-measured) own width
		r.right = GM.MakeFontString(sideTip, GM.FONT_MED, 11, "text")
		r.right:SetPoint("TOPRIGHT", -8, -20 - (i - 1) * SIDE_ROW_H)
		r.right:SetJustifyH("RIGHT")
		sideTip.rows[i] = r
	end
	return r
end

local function Fill(itemID, tooltip)
	local o = Opts()
	if not o.enabled then return end
	local mod = o.tooltipShowModifier
	if mod == "alt" and not IsAltKeyDown() then return end
	if mod == "ctrl" and not IsControlKeyDown() then return end

	local b = Builder()
	local stack = IsShiftKeyDown()
	for _, sec in ipairs(Sections()) do
		local before = #b.lines
		for _, e in ipairs(sec.entries) do
			if On(e) then e.fn(b, itemID, stack, e) end
		end
		if #b.lines > before and sec.heading then
			tinsert(b.lines, before + 1, {
				section = true, left = sec.heading,
				right = sec.right and sec.right(itemID),
			})
		end
	end
	if b:Empty() then if sideTip then sideTip:Hide() end return end
	-- Simple-mode teach moment: the shift-total rows exist but nothing
	-- on screen says so. One textDim hint, only when a history row is
	-- actually there to shift-expand
	if TT.CurrentPreset and TT.CurrentPreset() == "simple" then
		for _, ln in ipairs(b.lines) do
			if ln.left and ln.left:match("^You (bought|sold)") then
				tinsert(b.lines, { left = "Shift: lifetime totals" })
				break
			end
		end
	end

	local lr, lg, lb = GM.RGB("textDim")
	local rr, rg, rb = GM.RGB("text")
	local ar, ag, ab = GM.RGB("accent")
	-- freshness is per-leg: the backend feed (RealmAge) and the local
	-- book have separate clocks — a fresh DB next to a stale book is
	-- not stale data, it's a stale book
	local maxAge = GM.db and GM.db.dataMaxAge or 7200
	local dbAge = GM.RealmAge() or GM.DataAge()
	local bAge = GM.AH and GM.AH.BookAge and GM.AH.BookAge() or math.huge
	local fresh = math.min(dbAge or math.huge, bAge)
	-- stale line: the freshest leg is what the shown prices rest on —
	-- two short rows so neither sets the panel width (§4.6)
	local staleMain, staleSub
	if fresh ~= math.huge and fresh > maxAge then
		staleMain = "Prices " .. GM.FmtAge(fresh) .. " old"
		staleSub = "Scan at the AH to refresh"
	end

	if o.embeddedTooltip then
		if sideTip then sideTip:Hide() end
		tooltip:AddLine(" ")
		-- F11: IsItemTooltip keys on a "GoblinMind" line in embedded
		-- mode — the old "GoblinMind <Section>" heads provided it, the
		-- friendly heads don't, so emit the marker explicitly
		tooltip:AddLine("GoblinMind", ar, ag, ab)
		for _, ln in ipairs(b.lines) do
			if ln.section then
				tooltip:AddDoubleLine(ln.left, ln.right or "", ar, ag, ab, lr, lg, lb)
			elseif ln.right then
				local vr, vg, vb = ln.accent and ar or rr, ln.accent and ag or rg, ln.accent and ab or rb
				tooltip:AddDoubleLine(ln.left, ln.right, lr, lg, lb, vr, vg, vb)
			else
				tooltip:AddLine(ln.left, lr, lg, lb)
			end
		end
		if staleMain then
			tooltip:AddLine(staleMain, GM.RGB("warn"))
			tooltip:AddLine(staleSub, GM.RGB("textDim"))
		end
		tooltip:Show()
		-- widen past the client's broken |T|t measuring — icon-mode
		-- money columns would overhang the auto-sized frame. 40px
		-- covers the double-line insets and column gap.
		if o.tooltipPriceFormat == "icon" then
			local need = 0
			for _, ln in ipairs(b.lines) do
				local w = LineW(ln.left) + LineW(ln.right, GM.FONT_MED, 11) + 40
				if w > need then need = w end
			end
			if need > (tooltip:GetWidth() or 0) then
				tooltip:SetWidth(need)
			end
		end
		return
	end

	-- side tip: our own frame — measured width, so icon money can
	-- never spill past the panel edge
	BuildSideTip()
	if not sideTip then return end
	sideTip._src = tooltip
	local need, ri, y = 0, 0, 0
	local function PutLine(left, right, lc, rc, section)
		ri = ri + 1
		-- +4u of air above each heading after the first (R4); rows
		-- re-anchor off accumulated y since pitch is no longer uniform
		if section and ri > 1 then y = y + 4 end
		local row = SideRow(ri)
		row.left:SetFont(section and GM.FONT_BOLD or GM.FONT, 11, "")
		row.left:ClearAllPoints()
		row.left:SetPoint("TOPLEFT", 8, -22 - y)
		row.right:ClearAllPoints()
		row.right:SetPoint("TOPRIGHT", -8, -22 - y)
		y = y + SIDE_ROW_H
		row.left:Show()
		row.left:SetText(left or "")
		row.left:SetTextColor(lc[1], lc[2], lc[3])
		if right then
			row.right:Show()
			row.right:SetText(right)
			row.right:SetTextColor(rc[1], rc[2], rc[3])
		else
			row.right:Hide()
		end
		local w = LineW(left, section and GM.FONT_BOLD or GM.FONT, 11)
			+ LineW(right, GM.FONT_MED, 11) + (right and 32 or 16)
		if w > need then need = w end
	end
	local LC = { lr, lg, lb }
	local RC = { rr, rg, rb }
	local AC = { ar, ag, ab }
	for _, ln in ipairs(b.lines) do
		if ln.section then
			PutLine(ln.left, ln.right, AC, LC, true)
		elseif ln.right then
			PutLine(ln.left, ln.right, LC, ln.accent and AC or RC)
		else
			PutLine(ln.left, nil, LC)
		end
	end
	if staleMain then
		PutLine(staleMain, nil, { GM.RGB("warn") })
		PutLine(staleSub, nil, { GM.RGB("textDim") })
	end
	for j = ri + 1, #sideTip.rows do
		sideTip.rows[j].left:Hide()
		sideTip.rows[j].right:Hide()
	end
	local titleW = LineW("GoblinMind", GM.FONT_BOLD, 12) + 16
	if titleW > need then need = titleW end
	sideTip:SetSize(need, 22 + y + 6)
	sideTip:Show()
	AnchorSideTip()

	if not hideHooked[tooltip] then
		hideHooked[tooltip] = true
		local hide = function() if sideTip then sideTip:Hide() end end
		tooltip:HookScript("OnHide", hide)
		pcall(function() tooltip:HookScript("OnTooltipCleared", hide) end)
	end
end

-- authoritative "is this an item tooltip" marker for consumers that
-- can't trust GetItem on Forever — same-named world objects (a
-- Kingsblood node vs the bag item) still report an item link there.
-- The side tip is only built/shown by the Item post-call; embedded
-- mode instead leaves our "GoblinMind" header inside the tooltip.
function TT.IsItemTooltip(tt)
	if sideTip and sideTip._src == tt then
		return sideTip:IsShown() and true or false
	end
	if Opts().embeddedTooltip then
		for i = 1, tt:NumLines() do
			local fs = _G["GameTooltipTextLeft" .. i]
			local ok, hit = pcall(function()
				local lt = fs and fs:GetText()
				return lt and lt:find("GoblinMind") ~= nil
			end)
			if ok and hit then return true end
		end
	end
	return false
end

local function Hook(tooltip, data)
	-- Postcalls fire for every GameTooltip-template frame, including the
	-- ShoppingTooltip compare windows — those carry the player's equipped
	-- item and would clobber the tracked item.
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
	if tooltip == sideTip then return end
	-- world objects file Item postcalls on this client (same-named
	-- items like a Kingsblood node) — a GameObject subject GUID
	-- means the hover is an object, not an item: no side tip, no
	-- item marker for Gathering's IsItemTooltip
	local guid = data and data.guid
	if guid then
		local ok, t = pcall(strsplit, "-", guid)
		if ok and t == "GameObject" then return end
	end
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
	Fill(itemID, tooltip)
end

-- ============ settings surface (Part 12) ============
-- Writable view of the tooltip option tree: deduped entries with
-- get/set closures for the settings pane.

OptTable = function(key, module)
	local o = Opts()
	local tbl = module and o.moduleTooltips[module] or o
	if type(tbl) ~= "table" then return nil end
	local k1, k2 = strsplit(".", key)
	if k2 then return tbl[k1], k2 end
	return tbl, key
end

function TT.GetOption(key, module)
	local tbl, k = OptTable(key, module)
	return tbl and tbl[k]
end

function TT.SetOption(key, module, v)
	local o = Opts()
	if module then
		o.moduleTooltips[module] = o.moduleTooltips[module] or {}
		o = o.moduleTooltips[module]
	end
	local k1, k2 = strsplit(".", key)
	if k2 then
		o[k1] = o[k1] or {}
		o[k1][k2] = v
	else
		o[key] = v
	end
end

-- one descriptor per unique (module, key): kind "bool" | "enum",
-- domain = the entry's set values (+ "none" for enums — the TSM off),
-- default = the entry's declared default
function TT.OptionEntries()
	local seen, out = {}, {}
	for _, sec in ipairs(Sections()) do
		for _, e in ipairs(sec.entries) do
			local id = (e.module or "") .. "|" .. e.key
			if not seen[id] then
				seen[id] = {
					key = e.key, module = e.module,
					heading = sec.name or sec.heading, domain = {},
					default = e.default,
					label = e.label, settingLabel = e.settingLabel,
					gloss = e.gloss, hidden = e.hidden,
				}
				tinsert(out, seen[id])
			end
			local d = seen[id]
			local dup = false
			for _, v in ipairs(d.domain) do
				if v == e.set then dup = true end
			end
			if not dup then tinsert(d.domain, e.set) end
		end
	end
	for _, d in ipairs(out) do
		if #d.domain == 1 and d.domain[1] == true then
			d.kind = "bool"
		else
			d.kind = "enum"
			local hasNone = false
			for _, v in ipairs(d.domain) do
				if v == "none" then hasNone = true end
			end
			if not hasNone then tinsert(d.domain, "none") end
		end
		d.get = function() return TT.GetOption(d.key, d.module) end
		d.set = function(v) TT.SetOption(d.key, d.module, v) end
	end
	return out
end

-- ============ detail presets (tooltip-ux R3) ============
-- Presets just write the existing per-entry keys — no second render
-- path, and the settings grid still shows exactly what's on. The
-- control's displayed state is DERIVED (current values vs preset
-- maps): toggle anything by hand and it reads "Custom".

local PRESET_SIMPLE = {
	minBuyout = true,
	marketValue = "withTrend",
	regionSoldPerDay = true,
	regionSalePercent = true,
	vendorSellTooltip = true,
	destroyTooltipFormat = "simple",
	inventoryTooltipFormat = "simple",
	craftingCost = true,
	sale = true,
}

local PRESET_TRADER = {
	groupNameTooltip = true,
	vendorBuyTooltip = true,
	vendorSellTooltip = true,
	destroyTooltipFormat = "simple",
	convertTooltipFormat = "simple",
	inventoryTooltipFormat = "full",
	minBuyout = true,
	marketValue = "withTrend",
	regionMarketValue = "withTrend",
	regionSale = true,
	regionSalePercent = true,
	regionSoldPerDay = true,
	vsTSM = true,
	resetSignal = true,
	purchase = true,
	sale = true,
	craftingCost = true,
}

local PRESET_ORDER = { "simple", "trader", "everything" }

-- "richest" mode per enum when Everything is picked
local ON_PREF = { withTrend = 1, full = 2, simple = 3, noTrend = 4 }

local function OffValue(d)
	return d.kind == "bool" and false or "none"
end

local function OnValue(d)
	if d.kind == "bool" then return true end
	local best, bi
	for i, v in ipairs(d.domain) do
		if v ~= "none" then
			local r = ON_PREF[v] or (10 + i)
			if not best or r < bi then best, bi = v, r end
		end
	end
	return best or "none"
end

local function PresetMap(name, opts)
	local fixed = name == "simple" and PRESET_SIMPLE
		or name == "trader" and PRESET_TRADER
	local map = {}
	for _, d in ipairs(opts or TT.OptionEntries()) do
		if name == "everything" then
			map[d.key] = OnValue(d)
		else
			map[d.key] = fixed and fixed[d.key]
			if map[d.key] == nil then map[d.key] = OffValue(d) end
		end
	end
	return map
end

function TT.ApplyPreset(name)
	local opts = TT.OptionEntries()
	local map = PresetMap(name, opts)
	for _, d in ipairs(opts) do
		d.set(map[d.key])
	end
end

function TT.CurrentPreset()
	local opts = TT.OptionEntries()
	for _, name in ipairs(PRESET_ORDER) do
		local map = PresetMap(name, opts)
		local match = true
		for _, d in ipairs(opts) do
			local cur = d.get()
			if cur == nil then cur = d.default end -- unset → On() default
			if cur ~= map[d.key] then match = false break end
		end
		if match then return name end
	end
	return "custom"
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
			Fill(id, tt)
		end
	end)
end
