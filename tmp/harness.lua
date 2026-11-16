-- WoW/GM stub environment for offline Crafting.lua testing
wipe = function(t) for k in pairs(t) do t[k]=nil end end
tinsert = table.insert
sort = table.sort
min, max, floor, ceil, abs = math.min, math.max, math.floor, math.ceil, math.abs
format = string.format
strlower = string.lower
time = os.time
GetTime = function() return os.clock() end
UnitName = function() return "Testchar" end
GetRealmName = function() return "Realm" end
CreateFrame = function() return { SetScript=function() end, RegisterEvent=function() end, IsShown=function() return false end } end
hooksecurefunc = function() end
C_Item = { GetItemInfo = function() return nil end, GetItemInfoInstant = function() return nil end }
C_Container = { GetContainerItemInfo = function() return nil end, GetContainerNumSlots = function() return 0 end }
C_TradeSkillUI = {}
C_AuctionHouse = {}
Constants = nil
Enum = nil
TSMAPI_FOUR = nil
GoblinMindDB = { realms = {}, items = {}, vendorBuy = {} }
GoblinMindSettings = { inv = {}, book = {} }
GoblinMindPrices = { customSources = {} }
GoblinMindLedger = {}

GM = {}
GM.After = function(d, fn) end
GM.BagCount = function(id) return 0 end
GM.BankCount = function(id) return 0 end
GM.BagItems = function() return {} end
GM.ItemName = function(id) return "item"..id end
GM.ItemEntry = function() return nil end
GM.Money = function(c) return tostring(c).."c" end
GM.TSMMarket = function() return nil end
GM.Inventory = { Count = function(id) return { bags=0,bank=0,mail=0,guild=0,auction=0,alts=0,total=0,allTotal=0 } end }
GM.Ledger = { Avg = function() return nil end }
GM.PlanQueue = { SetScanPlan = function(p) _G.LASTPLAN = p end, SetItem=function() end, Show=function() end, IsShown=function() return true end, Rescan=function() end }
GM.Groups = { GetOps = function() return {} end }
GM.AH = { open = false }
GM.OnItemInfoLoaded = function() end
GM.CC = function() return "" end
GM.RGB = function() return 1,1,1 end
GM.Print = function() end
GM.Price = function(key, id) return nil end

-- extra globals for real Core/Inventory/Theme
GetNormalizedRealmName = function() return "Realm" end
UnitFactionGroup = function() return "Horde" end
GetMoney = function() return 100000 end
GetItemInfo = nil
GetItemInfoInstant = nil
GetItemIcon = nil
IsShiftKeyDown = function() return false end
IsAltKeyDown = function() return false end
IsControlKeyDown = function() return false end
_G.GM = GM
GM.FONT = "Fonts\ARIALN.TTF"
GM.FONT_BOLD = "Fonts\ARIALN.TTF"
GM.FONT_MED = "Fonts\ARIALN.TTF"
GM.THEME = {
  text = {1,1,1}, textDim = {.5,.5,.5}, accent = {1,.5,0}, pos = {0,1,0},
  err = {1,0,0}, warn = {1,.8,0}, contLowest = {0,0,0}, contHigh = {.2,.2,.2},
  contHighest = {.3,.3,.3}, frame = {.1,.1,.1}
}
GM.CC = function(k) return "" end
GM.RGB = function(k) local c = GM.THEME[k] or {1,1,1} return c[1],c[2],c[3] end
