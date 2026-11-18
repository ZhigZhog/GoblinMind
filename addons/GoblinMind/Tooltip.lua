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
local mfs
local function LineW(text)
	if not text then return 0 end
	if not mfs then
		mfs = UIParent:CreateFontString(nil, "OVERLAY")
		mfs:SetFont(GM.FONT, 10, "")
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
	return d >= 3600 and format("%dh %dm ago", d / 3600, d % 3600 / 60)
		or d >= 60 and format("%dm ago", d / 60) or format("%ds ago", d)
end

local function Trend(value, ref) -- "[+9%]" styled like TSM's caret line
	if not (value and ref and ref > 0) then return "[---]" end
	local d = math.floor((value - ref) / ref * 100 + 0.5)
	return "[" .. GM.CC(d >= 0 and "pos" or "err") .. (d >= 0 and "+" or "")
		.. d .. "%|r]"
end

local function Price(key, itemID)
	local v = GM.Pricing and GM.Pricing.Eval(key, itemID)
	return v
end

-- ============ section 1: General ============

local function P_Group(t, id)
	local path = id and GM.Groups.GroupForItem and GM.Groups.GroupForItem(id)
	if not path or path == "Base Group" then return end
	t:AddTextLine("Group", path)
end

local function P_Ops(t, id, opType)
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
		t:AddTextLine(opType:gsub("^%l", strupper) .. " Operation(s)", path)
	end
end

local function P_VendorBuy(t, id)
	local v = Price("vendorbuy", id)
	if v and v > 0 then t:AddItemValueLine("Vendor Buy Price", v) end
end

local function P_VendorSell(t, id)
	local v = GetInfo and select(11, GetInfo(id))
	if v and v > 0 then t:AddItemValueLine("Vendor Sell Price", v) end
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
	if v and v > vendor then t:AddItemValueLine("Destroy Value", v) end
	if not drops then return end
	for _, d in ipairs(drops) do
		local p = Price("dbmarket", d.id)
		local range = d.lo == d.hi and ("×" .. d.lo)
			or format("×%d–%d", d.lo, d.hi)
		t:AddTextLine(
			"    " .. GM.CC("text") .. GM.ItemNameOr(d.id) .. "|r "
				.. GM.CC("textDim") .. range .. " ~" .. d.pct .. "%|r",
			p and (MoneyFmt(p) .. " ea") or nil)
	end
end

local function P_Convert(t, id)
	-- herbs: convert is mill->pigment on TSM; not a Forever action
	if GM.Gathering and GM.Gathering.IsHerb and GM.Gathering.IsHerb(id) then
		return
	end
	-- mill/prospect/transform source-of-cheapest lands with Part 10
	local v = Price("convert", id)
	if not v then return end
	t:AddItemValueLine("Convert Value", v)
end

local function P_InventoryFull(t, id)
	local inv = GM.Inventory.Count(id)
	if inv.total == 0 then return end
	t:StartSection("Inventory", GM.CC("text") .. format("%d total", inv.total) .. "|r")
	local who = UnitName("player") or "player"
	t:AddTextLine(who, GM.CC("text") .. format("%d (%d bags, %d bank, %d AH, %d mail)",
		inv.bags + inv.bank + inv.auction + inv.mail,
		inv.bags, inv.bank, inv.auction, inv.mail) .. "|r")
	if inv.guild > 0 then
		local g = GetGuildInfo("player") or "guild"
		t:AddTextLine(g, GM.CC("text") .. format("%d in guild vault", inv.guild) .. "|r")
	end
	t:EndSection()
end

local function P_InventorySimple(t, id)
	local inv = GM.Inventory.Count(id)
	if inv.total == 0 then return end
	local player = inv.bags + inv.bank + inv.mail
	t:AddTextLine("Inventory", GM.CC("text") .. format("%d (%d player, %d guild, %d AH)",
		inv.total, player, inv.guild, inv.auction) .. "|r")
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
	local tag = src == "book" and " book" or src == "mesh" and " mesh" or ""
	return GM.CC("text") .. format("%d auctions", n) .. "|r ("
		.. GM.CC(age and age < 300 and "pos" or "warn")
		.. (age and AgeStr(time() - age) or "no data")
		.. GM.CC("pos") .. tag .. "|r)"
end

local function P_MinBuyout(t, id)
	-- observation source resolved inside ItemEntry (book → mesh → emit);
	-- ef reads the overlaid field
	local v = Price("dbminbuyout", id)
	if v then t:AddItemValueLine("Min Buyout", v) end
end

local function P_Recent(t, id)
	local v = Price("dbrecent", id)
	if v then t:AddItemValueLine("Recent Value", v) end
end

local function P_Market(t, id, trend)
	local v = Price("dbmarket", id)
	if not v then return end
	t:AddItemValueLine("Market Value", v, trend and Trend(v, Price("dbhistorical", id)) or nil)
end

local function P_Historical(t, id)
	local v = Price("dbhistorical", id)
	if v then t:AddItemValueLine("Historical Price", v) end
end

local function P_RegionMarket(t, id, trend)
	local v = Price("dbregionmarketavg", id)
	if not v then return end
	t:AddItemValueLine("Region Market Value Avg", v,
		trend and Trend(v, Price("dbregionhistorical", id)) or nil)
end

local function P_RegionHistorical(t, id)
	local v = Price("dbregionhistorical", id)
	if v then t:AddItemValueLine("Region Historical Price", v) end
end

local function P_RegionSale(t, id)
	local v = Price("dbregionsale", id)
	if v then t:AddItemValueLine("Region Sale Avg", v) end
end

local function P_RegionSaleRate(t, id)
	local v = Price("dbregionsalepercent", id)
	if v then t:AddTextLine("Region Sale Rate", GM.CC("text") .. format("%0.3f", v) .. "|r") end
end

local function P_RegionSoldPerDay(t, id)
	local v = Price("dbregionsalerate", id)
	if v then t:AddTextLine("Region Avg Daily Sold", GM.CC("text") .. (GM.VelRate(v) or format("%0.1f", v)) .. "|r") end
end

-- GoblinMind extensions
local function P_Band(t, id)
	local e = GM.ItemEntry(id)
	if e and e.p10 and e.p90 then
		t:AddItemValuesLine("±15% band", e.p10, e.p90)
	end
end

local function P_VsTSM(t, id)
	local e = GM.ItemEntry(id)
	local m = GM.TSMMarket(id)
	if e and e.p and m and m > 0 then
		local d = (e.p - m) / m * 100
		t:AddTextLine("vs TSM", GM.CC(d >= 0.5 and "pos" or d <= -0.5 and "err" or "textDim")
			.. format("%+.0f%%", d) .. "|r")
	end
end

local function P_Reset(t, id)
	local e = GM.ItemEntry(id)
	local rs = e and e.reset
	if type(rs) == "table" then
		t:AddTextLine("reset", GM.CC("warn") .. "below " .. GM.Money(rs.below)
			.. " · ev " .. GM.Money(rs.ev) .. "|r")
	elseif type(rs) == "number" and rs > 0 then
		-- some feeds emit reset as a bare threshold, not {below, ev}
		t:AddTextLine("reset", GM.CC("warn") .. "below " .. GM.Money(rs) .. "|r")
	end
end

local function P_LiveBook(t, id)
	local fresh = GM.AH.BookLive and GM.AH.BookLive()
	if not fresh then return end
	local mn, sup = GM.AH.BookMin(id), GM.AH.BookSupply(id)
	if mn then
		t:AddTextLine("book", GM.CC("pos") .. "min " .. GM.Money(mn)
			.. (sup and (" · " .. sup .. " listed") or "") .. " · live|r")
	end
end

-- ============ section 3: Accounting ============

local function P_Purchase(t, id, stack)
	local s = GM.Ledger and GM.Ledger.db and GM.Ledger.db.itemStats[id]
	if not s or not s.buyQ or s.buyQ == 0 then return end
	if stack then
		t:AddQuantityValueLine("Purchased (Total Price)", s.buyQ, s.buyT)
	else
		t:AddQuantityValueLine("Purchased (Min/Avg/Max Price)", s.buyQ,
			s.buyMin ~= math.huge and s.buyMin or nil, s.buyT / s.buyQ, s.buyMax)
	end
	local smart = GM.Ledger.Avg(id, "paid")
	if smart then t:AddItemValueLine("Smart Avg Buy Price", smart) end
	if s.lastBuy then t:AddTextLine("Last Purchased", GM.CC("textDim") .. AgeStr(s.lastBuy) .. "|r") end
end

local function P_Sale(t, id, stack)
	local s = GM.Ledger and GM.Ledger.db and GM.Ledger.db.itemStats[id]
	if not s or not s.sellQ or s.sellQ == 0 then return end
	if stack then
		t:AddQuantityValueLine("Sold (Total Price)", s.sellQ, s.sellT)
	else
		t:AddQuantityValueLine("Sold (Min/Avg/Max Price)", s.sellQ,
			s.sellMin ~= math.huge and s.sellMin or nil, s.sellT / s.sellQ, s.sellMax)
	end
	if s.lastSell then t:AddTextLine("Last Sold", GM.CC("textDim") .. AgeStr(s.lastSell) .. "|r") end
end

local function P_SaleRate(t, id)
	local st = GM.Ledger and GM.Ledger.Stats and GM.Ledger.Stats(id)
	if st and st.saleRate then
		t:AddTextLine("Sale Rate", GM.CC("text") .. format("%0.2f", st.saleRate) .. "|r")
	end
end

local function P_Expired(t, id)
	local st = GM.Ledger and GM.Ledger.Stats and GM.Ledger.Stats(id)
	if st and st.expireSinceSell > 0 then
		t:AddTextLine("Expired Since Last Sale", tostring(st.expireSinceSell))
	end
end

local function P_Cancelled(t, id)
	local st = GM.Ledger and GM.Ledger.Stats and GM.Ledger.Stats(id)
	if st and st.cancelSinceSell > 0 then
		t:AddTextLine("Cancelled Since Last Sale", tostring(st.cancelSinceSell))
	end
end

-- ============ sections 4-7: ops + crafting ============

local function P_PostQuantity(t, id)
	local ops = GM.Groups.GetOps(id, "auctioning")
	if not ops then return end
	local cap, stack = tonumber(ops.postCap), tonumber(ops.stackSize)
	if not cap or cap == 0 then t:AddTextLine("Post Quantity", "—") return end
	t:AddTextLine("Post Quantity", stack and stack > 0
		and format("%dx%d", cap, stack) or tostring(cap))
end

local function P_OpPrices(t, id)
	local ops = GM.Groups.GetOps(id, "auctioning")
	if not ops then return end
	t:AddItemValuesLine("Min/Normal/Max Prices",
		GM.Groups.EvalOp(ops, "min", id),
		GM.Groups.EvalOp(ops, "normal", id),
		GM.Groups.EvalOp(ops, "max", id))
end

local function P_CraftingCost(t, id)
	local v = Price("crafting", id)
	if not v then return end
	local p = Price("dbmarket", id)
	local profit = p and (p - v)
	t:AddTextLine("Crafting Cost", MoneyFmt(v)
		.. (profit and (" (" .. GM.CC(profit >= 0 and "pos" or "err")
			.. MoneyFmt(profit) .. "|r profit)") or ""))
end

local function P_MatPrice(t, id)
	local v = Price("matprice", id)
	if v then t:AddItemValueLine("Material Cost", v) end
end

local function P_ShoppingMax(t, id)
	local v = GM.Groups.EvalOp(GM.Groups.GetOps(id, "shopping"), "maxPrice", id)
	if v then t:AddItemValueLine("Max Shopping Price", v) end
end

local function P_SniperBelow(t, id)
	local v = GM.Groups.EvalOp(GM.Groups.GetOps(id, "sniper"), "belowPrice", id)
	if v then t:AddItemValueLine("Sniper Max Price", v) end
end

-- ============ registry (order = TSM's registration order) ============

local function CustomSourceEntry(name)
	return { key = "customPriceTooltips." .. name, global = true,
		custom = name, set = true, default = false,
		fn = function(t, id)
			local src = GoblinMindPrices and GoblinMindPrices.customSources
				and GoblinMindPrices.customSources[name]
			local v = src and GM.Pricing and GM.Pricing.Eval(src, id)
			if v and v > 0 then
				t:AddItemValueLine("Custom Source (" .. name .. ")", v)
			end
		end }
end

local function Sections()
	local general = {
		heading = "GoblinMind General",
		entries = {
			{ key = "groupNameTooltip", set = true, default = true, fn = P_Group },
		},
	}
	for _, opType in ipairs(GM.Groups.OP_TYPES or {}) do
		tinsert(general.entries, {
			key = "operationTooltips." .. opType, global = true,
			set = true, default = false,
			fn = function(t, id) P_Ops(t, id, opType) end,
		})
	end
	tinsert(general.entries, { key = "destroyTooltipFormat", set = "full",
		default = "simple", fn = P_Destroy })
	tinsert(general.entries, { key = "destroyTooltipFormat", set = "simple",
		default = "simple", fn = P_Destroy })
	tinsert(general.entries, { key = "convertTooltipFormat", set = "full",
		default = "simple", fn = P_Convert })
	tinsert(general.entries, { key = "convertTooltipFormat", set = "simple",
		default = "simple", fn = P_Convert })
	tinsert(general.entries, { key = "vendorBuyTooltip", set = true,
		default = true, fn = P_VendorBuy })
	tinsert(general.entries, { key = "vendorSellTooltip", set = true,
		default = true, fn = P_VendorSell })
	-- custom price sources get one entry each (all default off, like TSM)
	for name in pairs((GoblinMindPrices and GoblinMindPrices.customSources) or {}) do
		tinsert(general.entries, CustomSourceEntry(name))
	end
	tinsert(general.entries, { key = "inventoryTooltipFormat", set = "full",
		default = "full", fn = P_InventoryFull })
	tinsert(general.entries, { key = "inventoryTooltipFormat", set = "simple",
		default = "full", fn = P_InventorySimple })

	return {
		general,
		{
			heading = "GoblinMind AuctionDB", module = "AuctionDB",
			right = A_RightText,
			entries = {
				{ key = "minBuyout", module = "AuctionDB", set = true, default = true, fn = P_MinBuyout },
				{ key = "marketValueRecent", module = "AuctionDB", set = true, default = false, fn = P_Recent },
				{ key = "marketValue", module = "AuctionDB", set = "noTrend", default = "withTrend",
					fn = function(t, id) P_Market(t, id, false) end },
				{ key = "marketValue", module = "AuctionDB", set = "withTrend", default = "withTrend",
					fn = function(t, id) P_Market(t, id, true) end },
				{ key = "historical", module = "AuctionDB", set = true, default = false, fn = P_Historical },
				{ key = "altMinBuyout", module = "AuctionDB", set = true, default = false, fn = function() end },
				{ key = "altMarketValueRecent", module = "AuctionDB", set = true, default = false, fn = function() end },
				{ key = "altMarketValue", module = "AuctionDB", set = "noTrend", default = "none", fn = function() end },
				{ key = "altMarketValue", module = "AuctionDB", set = "withTrend", default = "none", fn = function() end },
				{ key = "altHistorical", module = "AuctionDB", set = true, default = false, fn = function() end },
				{ key = "regionMarketValue", module = "AuctionDB", set = "noTrend", default = "withTrend",
					fn = function(t, id) P_RegionMarket(t, id, false) end },
				{ key = "regionMarketValue", module = "AuctionDB", set = "withTrend", default = "withTrend",
					fn = function(t, id) P_RegionMarket(t, id, true) end },
				{ key = "regionHistorical", module = "AuctionDB", set = true, default = false, fn = P_RegionHistorical },
				{ key = "regionSale", module = "AuctionDB", set = true, default = true, fn = P_RegionSale },
				{ key = "regionSalePercent", module = "AuctionDB", set = true, default = true, fn = P_RegionSaleRate },
				{ key = "regionSoldPerDay", module = "AuctionDB", set = true, default = true, fn = P_RegionSoldPerDay },
				{ key = "band", module = "AuctionDB", set = true, default = true, fn = P_Band },
				{ key = "vsTSM", module = "AuctionDB", set = true, default = true, fn = P_VsTSM },
				{ key = "resetSignal", module = "AuctionDB", set = true, default = true, fn = P_Reset },
				{ key = "liveBook", module = "AuctionDB", set = true, default = true, fn = P_LiveBook },
			},
		},
		{
			heading = "GoblinMind Accounting", module = "Accounting",
			entries = {
				{ key = "purchase", module = "Accounting", set = true, default = true, fn = P_Purchase },
				{ key = "sale", module = "Accounting", set = true, default = true, fn = P_Sale },
				{ key = "saleRate", module = "Accounting", set = true, default = false, fn = P_SaleRate },
				{ key = "expiredAuctions", module = "Accounting", set = true, default = false, fn = P_Expired },
				{ key = "cancelledAuctions", module = "Accounting", set = true, default = false, fn = P_Cancelled },
			},
		},
		{
			heading = "GoblinMind Auctioning", module = "Auctioning",
			entries = {
				{ key = "postQuantity", module = "Auctioning", set = true, default = false, fn = P_PostQuantity },
				{ key = "operationPrices", module = "Auctioning", set = true, default = false, fn = P_OpPrices },
			},
		},
		{
			heading = "GoblinMind Crafting", module = "Crafting",
			entries = {
				{ key = "craftingCost", module = "Crafting", set = true, default = true, fn = P_CraftingCost },
				{ key = "detailedMats", module = "Crafting", set = true, default = false, fn = function() end },
				{ key = "matPrice", module = "Crafting", set = true, default = false, fn = P_MatPrice },
			},
		},
		{
			heading = "GoblinMind Shopping", module = "Shopping",
			entries = {
				{ key = "maxPrice", module = "Shopping", set = true, default = false, fn = P_ShoppingMax },
			},
		},
		{
			heading = "GoblinMind Sniper", module = "Sniper",
			entries = {
				{ key = "belowPrice", module = "Sniper", set = true, default = false, fn = P_SniperBelow },
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

local SIDE_ROW_H = 13

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
	tip.title = GM.MakeFontString(tip, GM.FONT_BOLD, 11, "accent")
	tip.title:SetPoint("TOPLEFT", 8, -6)
	tip.title:SetText("GoblinMind")
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
		r.left = GM.MakeFontString(sideTip, GM.FONT, 10, "textDim")
		r.left:SetPoint("TOPLEFT", 8, -20 - (i - 1) * SIDE_ROW_H)
		r.left:SetJustifyH("LEFT")
		-- right-anchored + right-justified: the text ends at the inset
		-- regardless of the fontstring's (mis-measured) own width
		r.right = GM.MakeFontString(sideTip, GM.FONT, 10, "text")
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
			if On(e) then e.fn(b, itemID, stack) end
		end
		if #b.lines > before and sec.heading then
			tinsert(b.lines, before + 1, {
				section = true, left = sec.heading,
				right = sec.right and sec.right(itemID),
			})
		end
	end
	if b:Empty() then if sideTip then sideTip:Hide() end return end

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
	local parts = {}
	if dbAge and dbAge > maxAge then tinsert(parts, format("feed %dm", dbAge / 60)) end
	if bAge < math.huge and bAge > maxAge then tinsert(parts, format("book %dm", bAge / 60)) end
	local stale = fresh ~= math.huge and fresh > maxAge
		and table.concat(parts, " + ") .. " old — /reload or FULL SCAN" or nil

	if o.embeddedTooltip then
		if sideTip then sideTip:Hide() end
		tooltip:AddLine(" ")
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
		if stale then
			tooltip:AddLine(stale, GM.RGB("warn"))
		end
		tooltip:Show()
		-- widen past the client's broken |T|t measuring — icon-mode
		-- money columns would overhang the auto-sized frame. 40px
		-- covers the double-line insets and column gap.
		if o.tooltipPriceFormat == "icon" then
			local need = 0
			for _, ln in ipairs(b.lines) do
				local w = LineW(ln.left) + LineW(ln.right) + 40
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
	local need, ri = 0, 0
	local function PutLine(left, right, lc, rc)
		ri = ri + 1
		local row = SideRow(ri)
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
		local w = LineW(left) + LineW(right) + (right and 32 or 16)
		if w > need then need = w end
	end
	local LC = { lr, lg, lb }
	local RC = { rr, rg, rb }
	local AC = { ar, ag, ab }
	for _, ln in ipairs(b.lines) do
		if ln.section then
			PutLine(ln.left, ln.right, AC, LC)
		elseif ln.right then
			PutLine(ln.left, ln.right, LC, ln.accent and AC or RC)
		else
			PutLine(ln.left, nil, LC)
		end
	end
	if stale then PutLine(stale, nil, { GM.RGB("warn") }) end
	for j = ri + 1, #sideTip.rows do
		sideTip.rows[j].left:Hide()
		sideTip.rows[j].right:Hide()
	end
	local titleW = LineW("GoblinMind") + 16
	if titleW > need then need = titleW end
	sideTip:SetSize(need, 20 + ri * SIDE_ROW_H + 6)
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
					heading = sec.heading, domain = {},
					default = e.default,
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
