local function loadAddon(path)
    local src = assert(io.open(path)):read("*a")
    assert(load(src, path))(nil, GM)
end
loadAddon([[D:\WoW Mods\addons\GoblinMind\Theme.lua]])
loadAddon([[D:\WoW Mods\addons\GoblinMind\Core.lua]])
loadAddon([[D:\WoW Mods\addons\GoblinMind\Inventory.lua]])
loadAddon([[D:\WoW Mods\addons\GoblinMind\Pricing.lua]])
loadAddon([[D:\WoW Mods\addons\GoblinMind\Crafting.lua]])

local C = GM.Crafting
local c = GoblinMindCrafting

-- queue the spyglass like the user
c.queue[6458] = 1
c.queueOrder = { 6458 }

local ok, err = pcall(C.QueueEmit)
print("QueueEmit:", ok, err)
if ok and LASTPLAN then
    for i, s in ipairs(LASTPLAN.steps) do
        print(" ", i, s.kind, s.verb or "", tostring(s.name), "x"..tostring(s.qty), tostring(s.unit or ""), s.desc or "")
    end
end
local ok2, miss = pcall(C.QueueMissing)
print("QueueMissing:", ok2, miss)
