local _, GM = ...

-- Part 9: item movement. Warehousing ops (bags↔bank, keepQty) and
-- mailing ops (sendTo/keepQty/maxQty) scan into move/send steps that
-- execute one protected call per click: PickupContainerItem+place for
-- moves, attach+SendMail for mail, AutoLootMailItem for collecting.
-- Bank contents only exist while the bank frame is open — moves to or
-- from the bank gate on that, like everything else.

GM.Banking = {}
local B = GM.Banking

local function Dbg(fmt, ...)
	if not B.debug then return end
	GM.Print(GM.CC("textDim") .. "[bank] " .. format(fmt, ...) .. "|r")
end

-- Container IDs computed like TSM's: bags = 0..NUM_BAG_SLOTS +
-- NumReagentBagSlots, bank bags follow, reagent bank = -3 if present.
local BAGS, BANK
do
	local inv = Constants and Constants.InventoryConstants
	local numBags = (NUM_BAG_SLOTS or 4) + (inv and inv.NumReagentBagSlots or 0)
	BAGS = {}
	for b = 0, numBags do BAGS[#BAGS + 1] = b end
	local numBank = (inv and inv.NumCharacterBankSlots) or NUM_BANKBAGSLOTS or 7
	BANK = {}
	-- TSM: BANK_CONTAINER (-1) is a valid drop target on classic only —
	-- on the modern bank UI (retail/Forever) items live in the bank BAG
	-- containers and -1 is a phantom that rejects drops.
	for b = numBags + 1, numBags + numBank do BANK[#BANK + 1] = b end
	if C_Container and C_Container.GetContainerNumSlots
		and (C_Container.GetContainerNumSlots(-3) or 0) > 0 then
		BANK[#BANK + 1] = -3 -- reagent bank
	end
end

local function DumpRanges()
	local inv = Constants and Constants.InventoryConstants
	Dbg("NUM_BAG_SLOTS=%s NumReagentBagSlots=%s NumCharacterBankSlots=%s NUM_BANKBAGSLOTS=%s",
		tostring(NUM_BAG_SLOTS), tostring(inv and inv.NumReagentBagSlots),
		tostring(inv and inv.NumCharacterBankSlots), tostring(NUM_BANKBAGSLOTS))
	Dbg("BAGS=%s BANK=%s", table.concat(BAGS, ","), table.concat(BANK, ","))
end

-- TSM's BagTracking.ItemWillGoInBag: specialized bags (reagent,
-- profession) reject items whose family doesn't match the equipped
-- bag's family mask. Backpack/bank container accept everything.
-- GetItemFamily on this client needs a LINK for items — raw IDs
-- return 0 (verified via bankdebug: itemFam=0 for every item).
-- GetItemInfo's second return is the link (C_Item.GetItemLink takes
-- an ItemLocation here, not an ID).
local function ItemFamily(itemID)
	local info = C_Item and C_Item.GetItemInfo or GetItemInfo
	local link = info and select(2, info(itemID))
	if not link then return 0 end
	return C_Item and C_Item.GetItemFamily and C_Item.GetItemFamily(link) or 0
end

local function BagFamily(bag)
	if bag == (BACKPACK_CONTAINER or 0) or bag == (BANK_CONTAINER or -1) then
		return 0
	end
	local invId = C_Container.ContainerIDToInventoryID
		and C_Container.ContainerIDToInventoryID(bag)
	if not invId then return 0, nil end
	local link = GetInventoryItemLink("player", invId)
	return link and C_Item and C_Item.GetItemFamily
		and C_Item.GetItemFamily(link) or 0, link, invId
end

local function ItemWillGoInBag(itemID, bag)
	local bagFamily = BagFamily(bag)
	return bagFamily == 0 or bit.band(ItemFamily(itemID), bagFamily) > 0
end

local function Slots(scope)
	local out = {}
	for _, bag in ipairs(scope == "bank" and BANK or BAGS) do
		local n = C_Container and C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, n do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			tinsert(out, { bag = bag, slot = slot, itemID = info and info.itemID,
				count = info and info.stackCount or 0 })
		end
	end
	return out
end

local function CountIn(scope, itemID)
	local n = 0
	for _, s in ipairs(Slots(scope)) do
		if s.itemID == itemID then n = n + s.count end
	end
	return n
end

-- first bag stack of itemID → {bag,slot,count}; shared with
-- destroying/vendoring which also move items out of bags
function B.FindStack(itemID)
	for _, s in ipairs(Slots("bags")) do
		if s.itemID == itemID and s.count > 0 then return s end
	end
end

function B.BagSlots()
	return Slots("bags")
end

local function BankOpen()
	return BankFrame and BankFrame:IsShown()
end

-- GetOpsForPath merges defaults into every group — ops only apply where
-- the path (or an ancestor) explicitly defines them.
local function HasOp(path, opType)
	local seg
	for part in (path or ""):gmatch("[^/]+") do
		seg = seg and seg .. "/" .. part or part
		local g = GM.Groups.db.groups[seg]
		if g and g.ops and g.ops[opType] then return true end
	end
end

-- ============ warehousing scan ============

-- For each grouped item with a warehousing op, emit a move step toward
-- the op's keepQty. moveTo="bags" pulls bank→bags; "bank" pushes
-- bags→bank leaving keepQty behind.
function B.WarehousingScan()
	if not BankOpen() then
		GM.Print(GM.CC("warn") .. "warehousing needs the bank frame open|r")
		return
	end
	local steps = {}
	for _, g in ipairs(GM.Groups.List()) do
		if HasOp(g.path, "warehousing") then
			local ops = GM.Groups.GetOpsForPath(g.path, "warehousing")
			local keep = tonumber(ops.keepQty) or 0
			local moveTo = ops.moveTo or "bags"
			for id in GM.Groups.IterateItems(g.path) do
				local inBags, inBank = CountIn("bags", id), CountIn("bank", id)
				local need = keep - inBags
				if moveTo == "bags" and need > 0 and inBank > 0 then
					tinsert(steps, { kind = "move", itemID = id,
						qty = math.min(need, inBank), from = "bank", to = "bags",
						name = GM.ItemName(id) })
				elseif (moveTo == "bank" or (moveTo == "bags" and need < 0))
					and inBags > keep then
					tinsert(steps, { kind = "move", itemID = id,
						qty = inBags - keep, from = "bags", to = "bank",
						name = GM.ItemName(id) })
				end
			end
		end
	end
	if #steps == 0 then
		GM.Print(GM.CC("textDim") .. "warehousing: nothing to move|r")
		return
	end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "warehousing",
		itemCount = #steps })
	GM.PlanQueue.Show()
end

-- ============ mailing scan ============

-- Items in groups whose mailing op names a recipient and whose bag
-- count exceeds keepQty → send steps. maxQty caps per-send units.
function B.MailingScan()
	if not (MailFrame and MailFrame:IsShown()) then
		GM.Print(GM.CC("warn") .. "mailing needs the mailbox open|r")
		return
	end
	local steps = {}
	for _, g in ipairs(GM.Groups.List()) do
		local ops = GM.Groups.GetOpsForPath(g.path, "mailing")
		local to = ops.sendTo
		if HasOp(g.path, "mailing") and type(to) == "string" and #to > 0 then
			local maxQ = tonumber(ops.maxQty) or 0
			local keep = tonumber(ops.keepQty) or 0
			for id in GM.Groups.IterateItems(g.path) do
				local have = CountIn("bags", id)
				local qty = math.min(have - keep, maxQ > 0 and maxQ or math.huge)
				if qty > 0 then
					tinsert(steps, { kind = "mail", itemID = id, qty = qty,
						to = to, name = GM.ItemName(id) })
				end
			end
		end
	end
	if #steps == 0 then
		GM.Print(GM.CC("textDim") .. "mailing: nothing to send|r")
		return
	end
	GM.PlanQueue.SetScanPlan({ steps = steps, mode = "mailing",
		itemCount = #steps })
	GM.PlanQueue.Show()
end

-- ============ execution (one protected call per click) ============

-- move: pick up one stack of itemID from `from`, drop in a free `to`
-- slot. Advances when the step's total moved reaches qty.
local function DoMove(step)
	if not BankOpen() then
		return nil, "bank is closed"
	end
	DumpRanges()
	Dbg("move %s %s→%s qty=%s moved=%s", tostring(step.itemID), step.from,
		step.to, tostring(step.qty), tostring(step.moved))
	local srcSlot
	for _, s in ipairs(Slots(step.from)) do
		if s.itemID == step.itemID and s.count > 0 then srcSlot = s break end
	end
	if not srcSlot then
		Dbg("no source stack found — done")
		return true -- nothing left → done
	end
	Dbg("src: bag=%d slot=%d count=%d", srcSlot.bag, srcSlot.slot, srcSlot.count)
	-- prefer merging onto a same-item partial stack (always legal —
	-- the item clearly belongs); empty slots must be drop-legal
	local dstSlot
	local max = select(8, (C_Item and C_Item.GetItemInfo or GetItemInfo)(step.itemID))
	Dbg("item maxStack=%s", tostring(max))
	for _, s in ipairs(Slots(step.to)) do
		if s.itemID == step.itemID and max and s.count < max then
			dstSlot = s break
		end
	end
	if dstSlot then
		Dbg("dst: merge bag=%d slot=%d (have %d)", dstSlot.bag, dstSlot.slot, dstSlot.count)
	else
		for _, s in ipairs(Slots(step.to)) do
			if not s.itemID then
				local bFam, link, invId = BagFamily(s.bag)
				local iFam = ItemFamily(step.itemID)
				local ok = ItemWillGoInBag(step.itemID, s.bag)
				Dbg("dst? bag=%d slot=%d invId=%s bagLink=%s itemFam=%s bagFam=%s → %s",
					s.bag, s.slot, tostring(invId), link and link:match("%[(.-)%]") or "none",
					tostring(iFam), tostring(bFam), ok and "OK" or "REJECT")
				if ok and not dstSlot then dstSlot = s end
			end
		end
	end
	if not dstSlot then
		GM.Print(GM.CC("warn") .. "[bank] no legal drop slot in " .. step.to .. "|r")
		return nil, "no room in " .. step.to
	end
	Dbg("drop: bag=%d slot=%d", dstSlot.bag, dstSlot.slot)
	C_Container.PickupContainerItem(srcSlot.bag, srcSlot.slot)
	local curType, curId = GetCursorInfo()
	Dbg("after pickup: cursor=%s id=%s", tostring(curType), tostring(curId))
	C_Container.PickupContainerItem(dstSlot.bag, dstSlot.slot)
	curType, curId = GetCursorInfo()
	Dbg("after drop: cursor=%s id=%s", tostring(curType), tostring(curId))
	-- report the src slot state; the move itself is server-confirmed —
	-- if it bounced, the item reappears and the next click retries
	local after = C_Container.GetContainerItemInfo
		and C_Container.GetContainerItemInfo(srcSlot.bag, srcSlot.slot)
	Dbg("src slot now: %s", after and ("still " .. tostring(after.itemID)
		.. " x" .. tostring(after.stackCount)) or "EMPTY (landed)")
	step.moved = (step.moved or 0) + srcSlot.count
	return (step.moved or 0) >= step.qty
end

-- mail: attach one stack per click; when qty worth of attachments is
-- in, the click sends. getSendMailItem counts what's attached.
local function DoMail(step)
	if not (MailFrame and MailFrame:IsShown()) then
		return nil, "mailbox is closed"
	end
	local attached = 0
	for i = 1, 12 do
		local _, _, _, q = GetSendMailItem(i)
		attached = attached + (q or 0)
	end
	if attached >= step.qty then
		SendMail(step.to, (GM.ItemName(step.itemID) or "items")
			.. " ×" .. attached)
		return true
	end
	local slot
	for _, s in ipairs(Slots("bags")) do
		if s.itemID == step.itemID and s.count > 0 then slot = s break end
	end
	if not slot then return nil, "no more in bags" end
	local free
	for i = 1, 12 do
		local name = GetSendMailItem(i)
		if not name then free = i break end
	end
	if not free then return nil, "mail is full (12 attachments)" end
	C_Container.PickupContainerItem(slot.bag, slot.slot)
	ClickSendMailItemButton(free)
	-- stay on the step until the send click — "confirm" keeps index put
	return "confirm"
end

-- collect: loot one mail containing the item (or any attachment if
-- itemID is nil). Returns true when the inbox has nothing left to take.
local function DoMailCollect(step)
	if not (MailFrame and MailFrame:IsShown()) then
		return nil, "mailbox is closed"
	end
	local n = GetInboxNumItems and GetInboxNumItems() or 0
	for i = 1, n do
		for a = 1, 16 do
			-- returns (name, itemID, texture, count, ...); nil name = end
			local _, id = GetInboxItem(i, a)
			if not id then break end
			if not step.itemID or id == step.itemID then
				AutoLootMailItem(i)
				return "confirm" -- looted one mail; more may remain
			end
		end
	end
	return true -- inbox has nothing matching → step done
end

function B.Execute(step)
	local fn = step.kind == "move" and DoMove
		or step.kind == "mail" and DoMail
		or step.kind == "mailcollect" and DoMailCollect
	if not fn then return end
	local ok, reason = fn(step)
	if ok == nil and reason then
		GM.Print(GM.CC("warn") .. "[bank] " .. reason .. "|r")
	end
	return ok
end
