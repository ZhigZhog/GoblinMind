local _, GM = ...

-- Part 9: item movement. Warehousing ops (bags↔bank, keepQty) and
-- mailing ops (sendTo/keepQty/maxQty) scan into move/send steps that
-- execute one protected call per click: PickupContainerItem+place for
-- moves, attach+SendMail for mail, AutoLootMailItem for collecting.
-- Bank contents only exist while the bank frame is open — moves to or
-- from the bank gate on that, like everything else.

GM.Banking = {}
local B = GM.Banking

local PickupItem = C_Container and C_Container.PickupContainerItem
	or PickupContainerItem

local function Dbg(fmt, ...)
	if not B.debug then return end
	GM.Print(GM.CC("textDim") .. "[bank] " .. format(fmt, ...) .. "|r")
end

-- Container IDs computed like TSM's: bags = 0..NUM_BAG_SLOTS +
-- NumReagentBagSlots, bank bags follow, reagent bank = -3 if present.
-- The lists rebuild when CarriedBagMax changes — a learned extra
-- carried bag (reagent/profession bag past the computed range)
-- shifts the bank-bag start with it.
local BAGS, BANK, bagsBuiltFor
local function Ranges()
	local numBags = (GM.CarriedBagMax and GM.CarriedBagMax())
		or (NUM_BAG_SLOTS or 4)
	if bagsBuiltFor == numBags then return BAGS, BANK end
	bagsBuiltFor = numBags
	BAGS = {}
	for b = 0, numBags do BAGS[#BAGS + 1] = b end
	BANK = {}
	-- TSM: BANK_CONTAINER (-1) is a valid drop target on classic only —
	-- on the modern bank UI (retail/Forever) items live in the bank BAG
	-- containers and -1 is a phantom that rejects drops.
	for _, b in ipairs(GM.BankContainerList()) do
		if b > 0 then BANK[#BANK + 1] = b end
	end
	if C_Container and C_Container.GetContainerNumSlots
		and (C_Container.GetContainerNumSlots(-3) or 0) > 0 then
		BANK[#BANK + 1] = -3 -- reagent bank
	end
	return BAGS, BANK
end

local function DumpRanges()
	local inv = Constants and Constants.InventoryConstants
	Dbg("NUM_BAG_SLOTS=%s NumReagentBagSlots=%s NumCharacterBankSlots=%s NUM_BANKBAGSLOTS=%s",
		tostring(NUM_BAG_SLOTS), tostring(inv and inv.NumReagentBagSlots),
		tostring(inv and inv.NumCharacterBankSlots), tostring(NUM_BANKBAGSLOTS))
	local BAGS, BANK = Ranges()
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
	local BAGS, BANK = Ranges()
	for _, bag in ipairs(scope == "bank" and BANK or BAGS) do
		local n = C_Container and C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, n do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			tinsert(out, { bag = bag, slot = slot, itemID = info and info.itemID,
				count = info and info.stackCount or 0,
				locked = info and info.isLocked or nil })
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
	-- same Forever custom-bank rule as BankUI: the BANKFRAME_*
	-- event flag is authoritative, the native frame a fallback
	return GM.bankOpen or (BankFrame and BankFrame:IsShown())
		or nil
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

-- One group's pending send set — shared by the scan and the mail
-- window's GROUPS preview. Only groups where the path (or an
-- ancestor) explicitly defines a mailing op participate; merged
-- defaults would otherwise try to mail every grouped item.
local function MailPreview(path)
	if not HasOp(path, "mailing") then return end
	local ops = GM.Groups.GetOpsForPath(path, "mailing")
	local to = ops.sendTo
	if type(to) ~= "string" or #to == 0 then return end
	local maxQ = tonumber(ops.maxQty) or 0
	local keep = tonumber(ops.keepQty) or 0
	local items, pend = {}, 0
	for id in GM.Groups.IterateItems(path) do
		local have = CountIn("bags", id)
		local qty = math.min(have - keep, maxQ > 0 and maxQ or math.huge)
		if qty > 0 then
			pend = pend + qty
			items[#items + 1] = { id = id, qty = qty }
		end
	end
	return { to = to, keep = keep, maxQ = maxQ,
		pend = pend, items = items }
end

-- rows for the mail window's GROUPS page: every group with a mailing
-- op, its resolved recipient/rule and how much is pending now
function B.MailableGroups()
	local out = {}
	for _, g in ipairs(GM.Groups.List()) do
		local p = MailPreview(g.path)
		if p then
			out[#out + 1] = { path = g.path,
				name = GM.Groups.Leaf(g.path), to = p.to,
				keep = p.keep, maxQ = p.maxQ,
				pend = p.pend, n = #p.items }
		end
	end
	return out
end

-- Items in groups whose mailing op names a recipient and whose bag
-- count exceeds keepQty → send steps. maxQty caps per-send units.
-- onlyPath restricts the scan to one group (the GROUPS page's row
-- action); nil scans all op'd groups.
function B.MailingScan(onlyPath)
	if not (MailFrame and MailFrame:IsShown()) then
		GM.Print(GM.CC("warn") .. "mailing needs the mailbox open|r")
		return
	end
	local steps = {}
	for _, g in ipairs(GM.Groups.List()) do
		if not onlyPath or g.path == onlyPath then
			local p = MailPreview(g.path)
			if p then
				for _, it in ipairs(p.items) do
					tinsert(steps, { kind = "mail", itemID = it.id,
						qty = it.qty, to = p.to,
						name = GM.ItemName(it.id) })
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

-- pick srcSlot {bag,slot,itemID,count} up and drop it into `toScope`:
-- prefer merging onto a same-item partial stack (always legal), else
-- the first drop-legal empty slot. Shared by plan moves and BankUI's
-- manual per-stack moves. Returns true when the drop was made.
local function MoveStack(srcSlot, toScope)
	Dbg("src: bag=%d slot=%d count=%d → %s",
		srcSlot.bag, srcSlot.slot, srcSlot.count, toScope)
	local dstSlot
	local max = select(8, (C_Item and C_Item.GetItemInfo or GetItemInfo)(srcSlot.itemID))
	for _, s in ipairs(Slots(toScope)) do
		if s.itemID == srcSlot.itemID and max and s.count < max then
			dstSlot = s break
		end
	end
	if not dstSlot then
		for _, s in ipairs(Slots(toScope)) do
			if not s.itemID and ItemWillGoInBag(srcSlot.itemID, s.bag) then
				dstSlot = s break
			end
		end
	end
	if not dstSlot then return nil, "no room in " .. toScope end
	PickupItem(srcSlot.bag, srcSlot.slot)
	PickupItem(dstSlot.bag, dstSlot.slot)
	return true
end

-- public single-stack move for the bank window's manual rows
function B.MoveTo(srcSlot, toScope)
	if not BankOpen() then return nil, "bank is closed" end
	local ok, err = MoveStack(srcSlot, toScope)
	if not ok then
		GM.Print(GM.CC("warn") .. "[bank] " .. tostring(err) .. "|r")
	end
	return ok
end

function B.BankSlots()
	return Slots("bank")
end

-- plan-queue fetch step: pull step.qty of step.itemID bank→bags, one
-- stack per click (same protected-call-per-click contract as moves).
-- Returns true when qty is covered or reachable stacks ran dry,
-- nil while more stacks remain (stays armed for the next click), or
-- "bounce", reason when the bank can't help — the queue rotates the
-- step to the plan tail instead of stalling. Tries a manual
-- BankFrame:Show() first — some clients expose the bank away from the
-- banker; when it didn't produce real slots, the fake frame gets
-- hidden again. A REAL open bank is left open, per the workflow.
-- fetch progress = bags gained since the step emitted, not just what
-- this executor moved — a manual bank pull or mail collect satisfies
-- the step too. MatSteps bakes bagBase (bags-at-emit); legacy steps
-- without it fall back to moved-only.
local function FetchDone(step)
	return math.max(step.moved or 0, GM.BagDelta(step) or 0)
end
B.FetchDone = FetchDone

function B.FetchBank(step)
	if FetchDone(step) >= (step.qty or 1) then return true end
	local faked
	if not BankOpen() and BankFrame and BankFrame.Show then
		pcall(BankFrame.Show, BankFrame)
		faked = BankOpen() -- shown now; real access is proven by slots
	end
	if not BankOpen() then return "bounce", "bank is closed" end
	local srcSlot
	for _, s in ipairs(Slots("bank")) do
		if s.itemID == step.itemID and s.count > 0 then
			srcSlot = s break
		end
	end
	if not srcSlot then
		if FetchDone(step) > 0 then return true end
		if faked then pcall(BankFrame.Hide, BankFrame) end
		return "bounce", "not in the bank (mail/gbank/alt?)"
	end
	local ok, err = MoveStack(srcSlot, "bags")
	if not ok then
		if FetchDone(step) > 0 then return true end
		return "bounce", err or "no room in bags"
	end
	step.moved = (step.moved or 0) + srcSlot.count
	return FetchDone(step) >= (step.qty or 1) or nil
end

-- move: pick up one stack of itemID from `from`, drop in a free `to`
-- slot. Advances when the step's total moved reaches qty.
local function DoMove(step)
	if not BankOpen() then
		return "bounce", "bank is closed"
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
	local ok, err = MoveStack(srcSlot, step.to)
	if not ok then
		if (step.moved or 0) > 0 then return true end
		return "bounce", err or "no legal drop slot"
	end
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
		return "bounce", "mailbox is closed"
	end
	local attached = 0
	for i = 1, 12 do
		local _, _, _, q = GetSendMailItem(i)
		attached = attached + (q or 0)
	end
	if attached >= step.qty then
		SendMail(step.to, (GM.ItemName(step.itemID) or "items")
			.. " ×" .. attached)
		-- items left our hands — basis rides ext (Ledger mailout)
		GM.Ledger.Record("mailout", { itemID = step.itemID,
			qty = attached, to = step.to })
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
	PickupItem(slot.bag, slot.slot)
	ClickSendMailItemButton(free)
	-- stay on the step until the send click — "confirm" keeps index put
	return "confirm"
end

-- collect: loot one mail containing the item (or any attachment if
-- itemID is nil). Returns true when the inbox has nothing left to take.
-- HasNewMail() only moves on a server header push — pull it after a
-- loot so the mail icon drops now, not on the lazy refresh.
local PullInbox = GM.PullInbox

local function DoMailCollect(step)
	-- bags already grew to cover it — the winnings arrived by another
	-- path (manual loot, earlier collect). No mailbox trip needed.
	if step.bagBase and GM.BagDelta
		and GM.BagDelta(step) >= (step.qty or 1) then
		return true
	end
	if not (MailFrame and MailFrame:IsShown()) then
		return "bounce", "mailbox is closed"
	end
	local n = GM.MailCount()
	for i = 1, n do
		for a = 1, 16 do
			-- returns (name, itemID, texture, count, ...); nil name = end
			local _, id = GetInboxItem(i, a)
			if not id then break end
			if not step.itemID or id == step.itemID then
				AutoLootMailItem(i)
				PullInbox()
				step.got = (step.got or 0) + 1
				return "confirm" -- looted one mail; more may remain
			end
		end
	end
	-- an itemID'd collect that never found a thing: the buy is likely
	-- still in transit — bounce to the plan tail so delivery gets a
	-- leg or two to land; an untargeted drain is simply done
	if step.itemID and (step.got or 0) == 0 then
		return "bounce", "nothing arrived yet"
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
	return ok, reason
end
