local _, GM = ...

local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local GetIDByInfo = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant

-- Every input path funnels here: target the item, surface the window,
-- and read the book when we're already at the AH.
function GM.TargetItem(itemID, link, key)
	local ctx = GM.Ctx(itemID, link, key)
	if not ctx then return end
	GM.PlanQueue.SetItem(ctx)
	-- AH planning lives in the market terminal while the session
	-- window is up; the standalone plan window keeps everything else
	if GM.AH.open and GM.AHUI and GM.AHUI.IsOpen and GM.AHUI.IsOpen() then
		GM.AHUI.OpenMarket(ctx)
	else
		GM.PlanQueue.Show()
	end
	if GM.AH.open then GM.PlanQueue.Rescan() end
end

-- Shift+click = Blizzard's fill-the-slot gesture (the native AH sell
-- slot works exactly this way). Native meaning is untouched — links
-- still paste, stacks still split — and while the plan window is open
-- the clicked item also becomes its target. Gated on IsShown so a
-- bare shift+click for chat-linking never pops the planner.
-- shift+click captures whenever a planning surface is up — the
-- standalone window, or the AH session window hosting the market
-- page (which also eats AHUI's search-fill hook; the market page
-- shows everything the search row would and more)
local function Capture()
	return IsShiftKeyDown and IsShiftKeyDown()
		and (GM.PlanQueue.IsShown()
			or (GM.AHUI and GM.AHUI.IsOpen and GM.AHUI.IsOpen()))
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
-- ============ link provenance ============
-- A clicked link says WHAT was linked; the writ flow also needs WHO
-- posted it. CHAT_MSG_* args carry the raw |H...|h markup verbatim,
-- so a small ring of recent link-bearing messages gives a chat
-- click a poster to address. Bag-link clicks just miss the ring and
-- resolve nil — which is exactly how "from another player" is told
-- from "from my own bags".
local linkRing = {}
local LINK_RING_MAX, LINK_RING_AGE = 40, 120

local linkFeed = CreateFrame("Frame")
for _, ev in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_YELL",
	"CHAT_MSG_SAY", "CHAT_MSG_WHISPER", "CHAT_MSG_GUILD",
	"CHAT_MSG_OFFICER", "CHAT_MSG_PARTY", "CHAT_MSG_RAID",
	"CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT" }) do
	linkFeed:RegisterEvent(ev)
end
linkFeed:SetScript("OnEvent", function(_, _, msg, sender)
	if not (msg and sender) or not msg:find("|H") then return end
	linkRing[#linkRing + 1] = { sender = sender, msg = msg,
		t = time() }
	if #linkRing > LINK_RING_MAX then table.remove(linkRing, 1) end
end)

-- newest-ring lookup for a clicked link. "|Hkind:id" occurs in the
-- raw message verbatim — match with a ":" or "|" boundary so an
-- item:123 click can't false-positive inside item:1234
local function linkPoster(link)
	local kind, id = link:match("|H(%a+):(%d+)")
	if not kind then kind, id = link:match("^(%a+):(%d+)") end
	if not kind then return nil end
	local me = UnitName("player") or ""
	local needle = "|H" .. kind .. ":" .. id
	local cut = time() - LINK_RING_AGE
	for i = #linkRing, 1, -1 do
		local e = linkRing[i]
		if (e.t or 0) < cut then break end
		if e.sender:match("^[^-]+") ~= me then
			local pos = e.msg:find(needle, 1, true)
			if pos then
				local nxt = e.msg:sub(pos + #needle, pos + #needle)
				if nxt == ":" or nxt == "|" then
					return { char = e.sender, msg = e.msg, t = e.t,
						kind = kind, id = tonumber(id) }
				end
			end
		end
	end
end

local origHMI = HandleModifiedItemClick
if origHMI then
	HandleModifiedItemClick = function(link)
		if Capture() then
			local id = GM.LinkID(link)
			if id then
				GM.LinkFrom = linkPoster(link)
				GM.TargetItem(id, link)
				return true
			end
		end
		return origHMI(link)
	end
end

-- ============ ops spine ============
-- THE click dispatcher — one decision tree owns every pointer op,
-- the way AH.Execute owns AH mutations. Views call Ops.Click(ctx)
-- and never re-implement the modifier/chat/planner branching or
-- compose (id, link, key, name) args. Call inside IsModifiedClick()
-- (or any click handler — a bare click just falls to the context
-- transfer). ctx may be a GM.Ctx or a plain {id,link,key} row —
-- Ctx normalizes either.
GM.Ops = GM.Ops or {}
function GM.Ops.Click(ctxOrRow)
	-- a row that carries its own ctx wins; otherwise Ctx normalizes
	-- whatever raw identity triple (or bare id) arrived
	local ctx = (type(ctxOrRow) == "table" and ctxOrRow.ctx)
		or GM.Ctx(ctxOrRow)
	if not ctx then return end
	-- one rule everywhere: shift+click targets the planner when a
	-- planning surface is open; otherwise the native chain runs
	-- (chat paste, stack split, context transfer)
	if Capture() then
		GM.TargetItem(ctx.id, ctx.link, ctx.key)
		return true
	end
	GM.ModifiedItemClick(ctx.id, ctx._link, ctx.key, ctx.name)
	return true
end

-- Chat links — SetItemRef may not delegate to the funnel on this
-- client; TargetItem is idempotent if it does.
if SetItemRef then
	hooksecurefunc("SetItemRef", function(link)
		if not Capture() then return end
		local id = GM.LinkID(link)
		-- pass the link through — Ctx extracts the itemKey from
		-- its itemString suffix field, so variant chat links
		-- target the variant, not the base
		if id then
			GM.LinkFrom = linkPoster(link)
			GM.TargetItem(id, link)
		end
	end)
end
