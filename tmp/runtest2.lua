local function loadAddon(path)
    local src = assert(io.open(path)):read("*a")
    assert(load(src, path))(nil, GM)
end
loadAddon([[D:\WoW Mods\addons\GoblinMind\Pricing.lua]])
loadAddon([[D:\WoW Mods\addons\GoblinMind\Crafting.lua]])

local c = GoblinMindCrafting
local C = GM.Crafting
local tube, spy = 3938, 6458
print("tube itemID:", c.recipes[tube].itemID, "spy itemID:", c.recipes[spy].itemID)

c.queue[spy] = 1
c.queueOrder = { spy }

-- prices: bronze tube 613c buy; weak flux vendor 35c; moss agate 500c; copper mod 50c; bars 200c
GM.Price = function(key, id)
    if key == "vendorbuy" then return id == 2880 and 35 or nil end
    if key == "dbmarket" then
        local p = { [4371]=613, [2841]=200, [1206]=500, [4363]=50, [4375]=300, [5507]=2000, [2880]=900 }
        return p[id]
    end
end
-- 76 bronze bars in bank, 1 copper modulator in bank
GM.Inventory.Count = function(id)
    if id == 2841 then return { bags=0,bank=76,mail=0,guild=0,auction=0,alts=0,total=76,allTotal=76 } end
    if id == 4363 then return { bags=0,bank=1,mail=0,guild=0,auction=0,alts=0,total=1,allTotal=1 } end
    return { bags=0,bank=0,mail=0,guild=0,auction=0,alts=0,total=0,allTotal=0 }
end

local ok, err = pcall(C.QueueEmit)
print("QueueEmit pcall:", ok, err)
if ok and LASTPLAN then
    for i, s in ipairs(LASTPLAN.steps) do
        print(" ", i, s.kind, s.verb or "", tostring(s.name), "x"..tostring(s.qty), tostring(s.unit or ""), s.desc or "")
    end
elseif ok then print("  (nil plan)") end
local ok2, miss = pcall(C.QueueMissing)
print("QueueMissing:", ok2)
if ok2 then for id, q in pairs(miss) do print("   miss", id, q) end end

-- also single-recipe Queue
LASTPLAN = nil
local ok3, err3 = pcall(C.Queue, spy, 1)
print("C.Queue:", ok3, err3)
if ok3 and LASTPLAN then
    for i, s in ipairs(LASTPLAN.steps) do
        print(" ", i, s.kind, s.verb or "", tostring(s.name), "x"..tostring(s.qty), tostring(s.unit or ""), s.desc or "")
    end
end
