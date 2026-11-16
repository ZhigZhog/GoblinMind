local function loadAddon(path)
    local src = assert(io.open(path)):read("*a")
    assert(load(src, path))(nil, GM)
end
loadAddon([[D:\WoW Mods\addons\GoblinMind\Pricing.lua]])
loadAddon([[D:\WoW Mods\addons\GoblinMind\Crafting.lua]])

local c = GoblinMindCrafting
local C = GM.Crafting

-- queue EVERY recipe — stress test for a poison recipe
for rid in pairs(c.recipes) do c.queue[rid] = 1 end
local order = {}
for rid in pairs(c.queue) do order[#order+1] = rid end
c.queueOrder = order

-- realistic price stub: half the items priced, flux-type vendor items priced
GM.Price = function(key, id)
    if key == "vendorbuy" then return id == 2880 and 35 or nil end
    if key == "dbmarket" then return (id % 3 == 0) and (id % 5000) or nil end
end

local ok, err = pcall(C.QueueList)
print("QueueList:", ok, type(err) == "table" and #err or err)
if not ok then print("  ERR:", err) end

local ok2, err2 = pcall(C.QueueEmit)
print("QueueEmit:", ok2, err2, LASTPLAN and #LASTPLAN.steps or "no plan")

local ok3, miss = pcall(C.QueueMissing)
print("QueueMissing:", ok3)
if not ok3 then print("  ERR:", miss) end

-- each recipe's Queue individually — find which one throws
for rid in pairs(c.recipes) do
    local okR, eR = pcall(C.Queue, rid, 1)
    if not okR then print("Queue FAIL", rid, c.recipes[rid].name, eR) end
end
print("done")
