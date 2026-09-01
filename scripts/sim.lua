-- Offline harness for CoolerFridge_Shared.lua: fakes just enough of the PZ API to
-- run the cooling maths and check the numbers come out where they should.

local clock = { hours = 0 }

GameTime = { getInstance = function() return { getWorldAgeHours = function() return clock.hours end } end }
SandboxVars = { FoodRotSpeed = 3, CoolerFridge = {} }
function getClimateManager() return { getTemperature = function() return 20.0 end } end
function ZombRand(n) return 12345 end
function getText(k) return k end

local classes = {}
function instanceof(o, c) return o.__cls and o.__cls[c] == true end

-- fake ItemContainer -------------------------------------------------------
local Container = {}
Container.__index = Container

local function newContainer(kind, powered)
    return setmetatable({ list = {}, kind = kind or "bag", powered = powered or false }, Container)
end

function Container:getItems()
    local snapshot = self.list
    return {
        size = function() return #snapshot end,
        get = function(_, i) return snapshot[i + 1] end,
    }
end
function Container:isFridge() return self.kind == "fridge" end
function Container:isFreezer() return self.kind == "freezer" end
function Container:isPowered() return self.powered end
function Container:Remove(item)
    for i, v in ipairs(self.list) do
        if v == item then table.remove(self.list, i) return end
    end
end
function Container:AddItem(fullType)
    local it = newItem(fullType, { InventoryItem = true, DrainableComboItem = true })
    it.delta = 1.0
    it.container = self
    table.insert(self.list, it)
    return it
end
function Container:add(item)
    item.container = self
    table.insert(self.list, item)
    return item
end

-- fake InventoryItem -------------------------------------------------------
local Item = {}
Item.__index = Item

function newItem(fullType, cls)
    return setmetatable({
        fullType = fullType, __cls = cls or {}, md = {}, age = 0.0,
        offAgeMax = 3, frozen = false, delta = 1.0, heat = 1.0,
    }, Item)
end

function Item:getFullType() return self.fullType end
function Item:getModData() return self.md end
function Item:getContainer() return self.container end
function Item:getInventory() return self.inventory end
function Item:getAge() return self.age end
function Item:setAge(v) self.age = v end
function Item:getOffAgeMax() return self.offAgeMax end
function Item:isFrozen() return self.frozen end
function Item:isRotten() return self.age >= self.offAgeMax end
function Item:getUsedDelta() return self.delta end
function Item:setUsedDelta(v) self.delta = v end
function Item:getName() return self.name or self.fullType end
function Item:setName(v) self.name = v end
function Item:getFluidContainer() return self.fluid end
function Item:getHeat() return self.heat end
function Item:setHeat(v) self.heat = v end

-- ---------------------------------------------------------------------------
dofile((arg and arg[1]) or
    "../Contents/mods/CoolerFridge/42/media/lua/shared/CoolerFridge/CoolerFridge_Shared.lua")
local CF = CoolerFridge

local function reportStr(label, value, expected)
    local ok = value == expected
    print(string.format("%-46s %-28s expected %-28s %s", label, tostring(value), tostring(expected), ok and "OK" or "FAIL"))
    return ok
end

local function report(label, value, expected, tol)
    local ok = math.abs(value - expected) <= (tol or 0.01)
    print(string.format("%-46s %8.4f  expected %8.4f  %s", label, value, expected, ok and "OK" or "FAIL"))
    return ok
end

local passed = true

-- Scenario: one cooler, one bag of ice, one steak. Vanilla ages food by
-- rotSpeed/24 per hour; we step an hour at a time and let the mod react.
local cooler = newItem("Base.Cooler", { InventoryItem = true })
cooler.inventory = newContainer("bag")
local ice = cooler.inventory:AddItem("CoolerFridge.IceBag")
local steak = newItem("Base.Steak", { InventoryItem = true, Food = true })
steak.offAgeMax = 1000
cooler.inventory:add(steak)

local top = newContainer("bag")
top:add(cooler)

local ROT = 1.0 / 24.0
for hour = 1, 72 do
    clock.hours = hour
    steak.age = steak.age + ROT     -- what the game itself would do
    CF.processTopLevel(top)
end

-- 48 h of ice at 0.25x, then 24 h uncooled.
passed = report("steak age after 48h iced + 24h warm", steak.age, 48 * ROT * 0.25 + 24 * ROT) and passed
passed = report("ice fully melted", ice.delta, 0.0) and passed
passed = report("melted bag removed from cooler", #cooler.inventory.list, 1) and passed

-- Scenario: ice sitting loose in a backpack melts five times faster (48 * 0.2 = 9.6 h).
clock.hours = 0
local pack = newContainer("bag")
local loose = pack:AddItem("CoolerFridge.IceBag")
CF.processTopLevel(pack)
clock.hours = 5
CF.processTopLevel(pack)
passed = report("loose ice left after 5h", loose.delta, 1 - 5 / 9.6) and passed

-- Scenario: a bag of ice in a powered freezer refills over FreezeHours.
clock.hours = 0
local freezer = newContainer("freezer", true)
local half = freezer:AddItem("CoolerFridge.IceBag")
half.delta = 0.25
CF.processTopLevel(freezer)
clock.hours = 3
CF.processTopLevel(freezer)
passed = report("half bag after 3h refreezing", half.delta, 0.25 + 3 / 6) and passed

-- Scenario: water in a powered freezer becomes ice after FreezeHours.
clock.hours = 0
local freezer2 = newContainer("freezer", true)
local bottle = newItem("Base.WaterBottleFull", { InventoryItem = true })
bottle.amount = 2.5
bottle.fluid = {
    getAmount = function() return bottle.amount end,
    contains = function() return true end,
    removeFluid = function(_, v) bottle.amount = bottle.amount - v end,
}
freezer2:add(bottle)
CF.startFreezingWater(bottle)
CF.processTopLevel(freezer2)
clock.hours = 7
CF.processTopLevel(freezer2)
local bags = 0
for _, it in ipairs(freezer2.list) do
    if it:getFullType() == "CoolerFridge.IceBag" then bags = bags + 1 end
end
passed = report("bags of ice from 2.5 units of water", bags, 2) and passed
passed = report("water left in the bottle", bottle.amount, 0.5) and passed

-- Scenario: the inventory window's blue tint. ISInventoryPane tints a row when
-- getHeat() < 1, at strength getInvHeat() = 1 - (heat - 0.2) / 0.8.
local function invHeat(h) return 1 - (h - 0.2) / 0.8 end

clock.hours = 0
local box = newItem("Base.Cooler", { InventoryItem = true })
box.inventory = newContainer("bag")
local cube = box.inventory:AddItem("CoolerFridge.IceBag")
local ham = newItem("Base.Ham", { InventoryItem = true, Food = true })
ham.offAgeMax = 1000
box.inventory:add(ham)
local warm = newContainer("bag")
warm:add(box)

CF.processTopLevel(warm)
passed = report("ham chilled on first sight", ham.heat, CF.COOLER_HEAT) and passed
passed = report("  -> blue tint strength", invHeat(ham.heat), 0.8125) and passed
passed = report("ice bag as cold as a freezer", cube.heat, CF.ICE_HEAT) and passed
passed = report("  -> blue tint strength", invHeat(cube.heat), 1.0) and passed

-- Vanilla lerps heat back towards the surrounding container between our passes; we
-- clamp it down again, but never warm anything up.
ham.heat = 0.9
clock.hours = 1
CF.processTopLevel(warm)
passed = report("re-chilled after vanilla warmed it", ham.heat, CF.COOLER_HEAT) and passed

ham.heat = 0.2
CF.processTopLevel(warm)
passed = report("freezer-cold food is not warmed up", ham.heat, 0.2) and passed

-- With the ice gone the mod stops touching heat, so vanilla thaws it naturally.
ham.heat = 1.0
cube.delta = 0.0
clock.hours = 2
CF.processTopLevel(warm)
passed = report("no ice, no chill", ham.heat, 1.0) and passed

-- And the sandbox option switches the whole thing off.
SandboxVars.CoolerFridge.ShowColdTint = false
local plain = newItem("Base.Ham", { InventoryItem = true, Food = true })
plain.offAgeMax = 1000
box.inventory:add(plain)
box.inventory:AddItem("CoolerFridge.IceBag")
clock.hours = 3
CF.processTopLevel(warm)
passed = report("tint disabled leaves heat alone", plain.heat, 1.0) and passed
SandboxVars.CoolerFridge.ShowColdTint = nil

-- Scenario: the (Iced) label on the cooler bag itself. Food is deliberately left
-- alone - vanilla tints fridge contents but never renames them, and reserves the
-- name suffix for genuinely frozen items.
local ICED = "IGUI_CoolerFridge_Iced"   -- getText is stubbed to return the key

clock.hours = 0
local labelled = newItem("Base.Cooler", { InventoryItem = true })
labelled.inventory = newContainer("bag")
local chip = labelled.inventory:AddItem("CoolerFridge.IceBag")
local chop = newItem("Base.Steak", { InventoryItem = true, Food = true })
chop.offAgeMax = 1000
labelled.inventory:add(chop)
local room = newContainer("bag")
room:add(labelled)

CF.processTopLevel(room)
passed = reportStr("cooler labelled while iced", labelled:getName(), "Base.Cooler " .. ICED) and passed
passed = reportStr("food in the cooler is NOT renamed", chop:getName(), "Base.Steak") and passed

-- Ice gone: the label comes back off and the original name is restored.
chip.delta = 0.0
clock.hours = 1
CF.processTopLevel(room)
passed = reportStr("label removed once ice is gone", labelled:getName(), "Base.Cooler") and passed

-- Turning the option off has to strip a label that is already on the item.
labelled.inventory:AddItem("CoolerFridge.IceBag")
clock.hours = 2
CF.processTopLevel(room)
passed = reportStr("relabelled after restocking ice", labelled:getName(), "Base.Cooler " .. ICED) and passed

SandboxVars.CoolerFridge.RenameCoolers = false
clock.hours = 3
CF.processTopLevel(room)
passed = reportStr("option off strips an existing label", labelled:getName(), "Base.Cooler") and passed
SandboxVars.CoolerFridge.RenameCoolers = nil

print(passed and "\nALL CHECKS PASSED" or "\nCHECKS FAILED")
