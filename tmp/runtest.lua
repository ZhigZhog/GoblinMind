-- load Pricing + Crafting with addon varargs
local loader = loadfile or function() end
local function loadAddon(path)
    local src = assert(io.open(path)):read("*a")
    assert(load(src, path))(nil, GM)
end
loadAddon([[D:\WoW Mods\addons\GoblinMind\Pricing.lua]])
loadAddon([[D:\WoW Mods\addons\GoblinMind\Crafting.lua]])
print("loaded")

-- real SV data is already loaded (GoblinMindCrafting global)
local C = GM.Crafting
print("queue entries:")
for rid, qty in pairs(GoblinMindCrafting.queue or {}) do
    print("  ", rid, qty, GoblinMindCrafting.recipes[rid] and GoblinMindCrafting.recipes[rid].name)
end

local ok, err = pcall(C.QueueEmit)
print("QueueEmit ->", ok, err)
if ok == true then
    for i, s in ipairs(LASTPLAN.steps) do
        print(i, s.kind, s.verb or "", s.name, "x"..tostring(s.qty), s.unit or "", s.desc or "")
    end
end

local ok2, miss = pcall(C.QueueMissing)
print("QueueMissing ->", ok2)
if ok2 == true then for id, q in pairs(miss) do print("  miss", id, q) end end
