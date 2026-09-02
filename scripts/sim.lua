-- Offline harness for TienCooler_Shared.lua: fakes just enough of the PZ API to
-- run the cooling maths and check the numbers come out where they should.

local clock = { hours = 0 }

GameTime = { getInstance = function() return { getWorldAgeHours = function() return clock.hours end } end }
SandboxVars = { FoodRotSpeed = 3, TienCoolers = {} }
function getClimateManager() return { getTemperature = function() return 20.0 end } end
function ZombRand(n) return 12345 end
function getText(k) return k end
Fluid = { Water = "Water" }

local classes = {}
function instanceof(o, c) return o.__cls and o.__cls[c] == true end

-- The vanilla send*/sync* helpers. In game they do nothing offline, which is why the
-- mod calls them unguarded; here they record what would have gone over the wire.
net = { packets = {}, client = false, players = {}, squares = {}, vehicles = {} }

function net.log(fmt, ...)
    net.packets[#net.packets + 1] = string.format(fmt, ...)
end

function net.sent(text)
    local n = 0
    for _, p in ipairs(net.packets) do
        if p == text then n = n + 1 end
    end
    return n
end

function isClient() return net.client end
function isServer() return false end
function getTimestampMs() return net.ms or 0 end
function getSpecificPlayer(num) return net.players[num] end
function getSquare(x, y, z) return net.squares[x .. "," .. y .. "," .. z] end
function getVehicleById(id) return net.vehicles[id] end

function sendItemStats(item) net.log("stats:%s", item:getFullType()) end
function syncItemModData(_, item) net.log("moddata:%s", item:getFullType()) end
function syncItemFields(_, item) net.log("fields:%s", item:getFullType()) end
function sendAddItemToContainer(_, item) net.log("add:%s", item:getFullType()) end
function sendRemoveItemFromContainer(_, item) net.log("remove:%s", item:getFullType()) end
function sendClientCommand(_, module, command, args)
    net.log("command:%s", command)
    net.lastCommand = { module = module, command = command, args = args }
end

-- Enough of the event and UI plumbing to load the client and server drivers as-is.
function require(_) end
function round(v) return v end
handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local slot = { Add = function(fn) handlers[name] = fn end }   -- PZ calls this with a dot
    rawset(t, name, slot)
    return slot
end })
ISInventoryPaneContextMenu = { addToolTip = function() return {} end }
function getNumActivePlayers() return 1 end
function getPlayerLoot(_) return net.loot end


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
function Container:getParent() return self.parent end
function Container:getContainingItem() return self.containingItem end
function Container:getVehiclePart() return self.vehiclePart end
function Container:getVehicle() return self.vehicle end
function Container:getItemWithID(id)
    for _, v in ipairs(self.list) do
        if v:getID() == id then return v end
    end
    return nil
end

-- A bag or cooler: an item you can carry that holds a container of its own.
function newBag(fullType)
    local item = newItem(fullType, { InventoryItem = true })
    item.inventory = newContainer("bag")
    item.inventory.containingItem = item
    return item
end

function newPlayer(num, isLocal)
    local player = { __cls = { IsoPlayer = true } }
    player.inventory = newContainer("bag")
    player.inventory.parent = player
    function player:isLocalPlayer() return isLocal end
    function player:getInventory() return self.inventory end
    net.players[num] = player
    return player
end

-- A container standing in the world, the way a fridge or a crate does. The server
-- looks these up again by square and index, so the stub has to be indexable too.
-- Set a bag down on the ground: it becomes its own world object on that square.
function dropOnGround(item, x, y, z)
    newWorldContainer(x, y, z, "bag", false)          -- makes sure the square exists
    local square = net.squares[x .. "," .. y .. "," .. z]
    table.insert(square.dropped, { getItem = function() return item end })
    item.worldItem = { getSquare = function() return square end }
    item.container = nil
    return item
end

function newWorldContainer(x, y, z, kind, powered)
    local container = newContainer(kind, powered)
    local key = x .. "," .. y .. "," .. z
    local square = net.squares[key]
    if not square then
        square = { objects = {} }
        function square:getX() return x end
        function square:getY() return y end
        function square:getZ() return z end
        function square:getObjects()
            local list = self.objects
            return { size = function() return #list end,
                     get = function(_, i) return list[i + 1] end }
        end
        square.dropped = {}
        function square:getWorldObjects()
            local list = self.dropped
            return { size = function() return #list end,
                     get = function(_, i) return list[i + 1] end }
        end
        net.squares[key] = square
    end

    local object = { containers = { container } }
    function object:getSquare() return square end
    function object:getContainerIndex(c)
        for i, v in ipairs(self.containers) do
            if v == c then return i - 1 end
        end
        return -1
    end
    function object:getContainerByIndex(i) return self.containers[i + 1] end

    table.insert(square.objects, object)
    container.parent = object
    return container
end

-- fake InventoryItem -------------------------------------------------------
local Item = {}
Item.__index = Item

local nextItemId = 1

function newItem(fullType, cls)
    nextItemId = nextItemId + 1
    return setmetatable({
        fullType = fullType, __cls = cls or {}, md = {}, age = 0.0,
        offAgeMax = 3, frozen = false, delta = 1.0, heat = 1.0, id = nextItemId,
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
function Item:getCurrentUsesFloat() return self.delta end   -- B42; getUsedDelta is gone
function Item:setUsedDelta(v) self.delta = v end
function Item:IsInventoryContainer() return self.inventory ~= nil end
function Item:getID() return self.id end
function Item:syncItemFields() net.log("fields:%s", self.fullType) end
function Item:getName() return self.name or self.fullType end
function Item:setName(v) self.name = v end
function Item:getFluidContainer() return self.fluid end
function Item:hasWorldItem() return self.worldItem ~= nil end
function Item:getWorldItem() return self.worldItem end
-- Mirrors the real one, which answers with the square of the character holding the
-- item: nil for anything lying on the ground. Where a dropped item lies is known only
-- to its world object, and stubbing that faithfully is the point.
function Item:getSquare() return self.holder and self.holder:getSquare() or nil end
function Item:getHeat() return self.heat end
function Item:setHeat(v) self.heat = v end

-- ---------------------------------------------------------------------------
local MEDIA = "../Contents/mods/TienCoolers/42/media/lua/"
if arg and arg[1] then MEDIA = (string.gsub(arg[1], "shared.*$", "")) end

dofile(MEDIA .. "shared/TienCoolers/TienCooler_Shared.lua")
dofile(MEDIA .. "client/TienCoolers/TienCooler_Client.lua")
dofile(MEDIA .. "server/TienCoolers/TienCooler_Server.lua")
local CF = TienCoolers

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
local ice = cooler.inventory:AddItem("TienCoolers.IceBag")
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
local loose = pack:AddItem("TienCoolers.IceBag")
CF.processTopLevel(pack)
clock.hours = 5
CF.processTopLevel(pack)
passed = report("loose ice left after 5h", loose.delta, 1 - 5 / 9.6) and passed

-- Scenario: a bag of ice in a powered freezer refills over FreezeHours.
clock.hours = 0
local freezer = newContainer("freezer", true)
local half = freezer:AddItem("TienCoolers.IceBag")
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
    if it:getFullType() == "TienCoolers.IceBag" then bags = bags + 1 end
end
passed = report("bags of ice from 2.5 units of water", bags, 2) and passed
passed = report("water left in the bottle", bottle.amount, 0.5) and passed

-- Scenario: the inventory window's blue tint. ISInventoryPane tints a row when
-- getHeat() < 1, at strength getInvHeat() = 1 - (heat - 0.2) / 0.8.
local function invHeat(h) return 1 - (h - 0.2) / 0.8 end

clock.hours = 0
local box = newItem("Base.Cooler", { InventoryItem = true })
box.inventory = newContainer("bag")
local cube = box.inventory:AddItem("TienCoolers.IceBag")
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
SandboxVars.TienCoolers.ShowColdTint = false
local plain = newItem("Base.Ham", { InventoryItem = true, Food = true })
plain.offAgeMax = 1000
box.inventory:add(plain)
box.inventory:AddItem("TienCoolers.IceBag")
clock.hours = 3
CF.processTopLevel(warm)
passed = report("tint disabled leaves heat alone", plain.heat, 1.0) and passed
SandboxVars.TienCoolers.ShowColdTint = nil

-- Scenario: a cooler can never preserve food better than a working fridge. With
-- Refrigeration Effectiveness on "Very Low" a real fridge only manages 0.4, so the
-- cooler's own 0.25 is floored up to match instead of beating it.
passed = report("cool factor at default refrigeration", CF.coolFactor(), 0.25) and passed
SandboxVars.FridgeFactor = 1
passed = report("cool factor floored by Very Low fridges", CF.coolFactor(), 0.4) and passed

clock.hours = 0
local floored = newItem("Base.Cooler", { InventoryItem = true })
floored.inventory = newContainer("bag")
floored.inventory:AddItem("TienCoolers.IceBag")
local roast = newItem("Base.Steak", { InventoryItem = true, Food = true })
roast.offAgeMax = 1000
floored.inventory:add(roast)
local shed = newContainer("bag")
shed:add(floored)
CF.processTopLevel(shed)          -- baseline pass, as the first minute in game would
for hour = 1, 24 do
    clock.hours = hour
    roast.age = roast.age + ROT
    CF.processTopLevel(shed)
end
passed = report("roast age after 24h at the floor", roast.age, 24 * ROT * 0.4) and passed
SandboxVars.FridgeFactor = nil

-- Scenario: the (Iced) label on the cooler bag itself. Food is deliberately left
-- alone - vanilla tints fridge contents but never renames them, and reserves the
-- name suffix for genuinely frozen items.
local ICED = "IGUI_TienCoolers_Iced"   -- getText is stubbed to return the key

clock.hours = 0
local labelled = newItem("Base.Cooler", { InventoryItem = true })
labelled.inventory = newContainer("bag")
local chip = labelled.inventory:AddItem("TienCoolers.IceBag")
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
labelled.inventory:AddItem("TienCoolers.IceBag")
clock.hours = 2
CF.processTopLevel(room)
passed = reportStr("relabelled after restocking ice", labelled:getName(), "Base.Cooler " .. ICED) and passed

SandboxVars.TienCoolers.RenameCoolers = false
clock.hours = 3
CF.processTopLevel(room)
passed = reportStr("option off strips an existing label", labelled:getName(), "Base.Cooler") and passed
SandboxVars.TienCoolers.RenameCoolers = nil

-- Scenario: multiplayer. A remote client is the authority only for what its own
-- player carries; a container out in the world belongs to the server, so the client
-- asks for it to be ticked instead of writing to it. Offline the question does not
-- arise and ownsContainer is true for everything.
clock.hours = 0
net.client = true
local me = newPlayer(0, true)
local them = newPlayer(1, false)
local fridge = newWorldContainer(10, 20, 0, "fridge", true)
local carried = newBag("Base.Cooler")
me.inventory:add(carried)

passed = reportStr("client owns its own inventory", CF.ownsContainer(me:getInventory()), true) and passed
passed = reportStr("client owns a cooler it carries", CF.ownsContainer(carried.inventory), true) and passed
passed = reportStr("client does not own another player", CF.ownsContainer(them:getInventory()), false) and passed
passed = reportStr("client does not own a fridge", CF.ownsContainer(fridge), false) and passed
net.client = false
passed = reportStr("offline every container is owned", CF.ownsContainer(fridge), true) and passed
net.client = true

-- A world container has to survive the trip to the server and back as plain numbers.
local address = CF.addressContainer(fridge)
passed = reportStr("fridge resolves back to itself", CF.resolveContainer(address), fridge) and passed
local second = newWorldContainer(10, 20, 0, "fridge", true)   -- same square
passed = reportStr("a second object on the square resolves too",
    CF.resolveContainer(CF.addressContainer(second)), second) and passed
passed = reportStr("a stale address resolves to nothing",
    CF.resolveContainer({ x = 99, y = 99, z = 0, o = 0, c = 0 }), nil) and passed
passed = reportStr("the floor list cannot be addressed",
    CF.addressContainer(newContainer("bag")), nil) and passed

-- What a client puts on the wire while ticking a cooler of its own.
clock.hours = 0
net.packets = {}
local mine = newBag("Base.Cooler")
me.inventory:add(mine)
mine.inventory:AddItem("TienCoolers.IceBag")
CF.processTopLevel(me:getInventory())
passed = reportStr("the (Iced) label is transmitted", net.sent("fields:Base.Cooler"), 1) and passed

net.packets = {}
clock.hours = 12
CF.processTopLevel(me:getInventory())
passed = reportStr("melting is transmitted", net.sent("stats:TienCoolers.IceBag") > 0, true) and passed

net.packets = {}
clock.hours = 500
CF.processTopLevel(me:getInventory())
passed = reportStr("the spent bag's removal is transmitted",
    net.sent("remove:TienCoolers.IceBag"), 1) and passed

-- The client driver: its own cooler is ticked here, the fridge is handed over. The
-- request is rate limited because the loot window rebuilds itself constantly.
clock.hours = 0
net.ms = 0
net.packets = {}
net.loot = { backpacks = { { inventory = fridge } } }
local everyMinute = handlers.EveryOneMinute
everyMinute()
passed = reportStr("the fridge is handed to the server", net.sent("command:tick"), 1) and passed
everyMinute()
passed = reportStr("a repeat inside the window is dropped", net.sent("command:tick"), 1) and passed
net.ms = 60000
everyMinute()
passed = reportStr("and it goes again once the window passes", net.sent("command:tick"), 2) and passed

net.client = false
net.packets = {}
everyMinute()
passed = reportStr("offline nothing is sent at all", net.sent("command:tick"), 0) and passed
net.client = true

-- Freezing water happens in a fridge, which the server owns: the flag is set locally
-- so the menu updates at once, and the work itself is handed over.
net.packets = {}
local jug = newItem("Base.WaterBottleFull", { InventoryItem = true })
jug.amount = 1.0
jug.fluid = {
    getAmount = function() return jug.amount end,
    contains = function() return true end,
    removeFluid = function(_, v) jug.amount = jug.amount - v end,
}
fridge:add(jug)

local menu = { options = {} }
function menu:addOption(text, target, callback, args)
    local option = { text = text, target = target, callback = callback, args = args }
    table.insert(self.options, option)
    return option
end
handlers.OnFillInventoryObjectContextMenu(0, menu, { jug })
local freeze = menu.options[1]
passed = reportStr("the freeze option is offered",
    freeze and freeze.text, "ContextMenu_TienCoolers_Freeze") and passed
freeze.callback(freeze.target, freeze.args)
passed = reportStr("the flag is set locally at once", CF.isFreezingWater(jug), true) and passed
passed = reportStr("and the server is told", net.sent("command:setFreezing"), 1) and passed

-- The server side of that same request, working on its own copy of the fridge.
net.client = false
net.packets = {}
local request = net.lastCommand.args
handlers.OnClientCommand("TienCoolers", "setFreezing", me, request)
passed = reportStr("the server marked the water", jug.md.tcFreezing, true) and passed
passed = reportStr("and told the client", net.sent("moddata:Base.WaterBottleFull"), 1) and passed
passed = reportStr("the sync player is released again", CF.syncPlayer, nil) and passed

clock.hours = 7
net.packets = {}
handlers.OnClientCommand("TienCoolers", "tick", me, request)
passed = reportStr("the server froze the water on request",
    net.sent("add:TienCoolers.IceBag"), 1) and passed

-- A cooler set down on the ground has no parent object, so it is addressed by the
-- square it lies on instead. Without that the server cannot find it and its contents
-- would sit there rotting until someone picked the cooler back up.
net.client = true
clock.hours = 0
local dropped = newBag("Base.Cooler")
dropOnGround(dropped, 12, 34, 0)
local droppedIce = dropped.inventory:AddItem("TienCoolers.IceBag")
local droppedSteak = newItem("Base.Steak", { InventoryItem = true, Food = true })
droppedSteak.offAgeMax = 1000
dropped.inventory:add(droppedSteak)

local groundAddress = CF.addressContainer(dropped.inventory)
passed = reportStr("a cooler on the ground can be addressed",
    groundAddress and groundAddress.g, dropped:getID()) and passed
passed = reportStr("and resolves back to its container",
    CF.resolveContainer(groundAddress), dropped.inventory) and passed
passed = reportStr("a bag held by a player still has no address",
    CF.addressContainer(carried.inventory), nil) and passed

net.client = false
handlers.OnClientCommand("TienCoolers", "tick", me, groundAddress)   -- baseline pass
clock.hours = 24
droppedSteak.age = droppedSteak.age + 24 / 24
handlers.OnClientCommand("TienCoolers", "tick", me, groundAddress)
passed = report("the server melts ice in a cooler on the ground", droppedIce.delta, 0.5) and passed
passed = report("and rebates the rot it prevented", droppedSteak.age, 0.25) and passed

-- A loose bag of ice lying next to it is a world object too, and the floor list is
-- walked for exactly these because the list itself has no address.
net.client = true
clock.hours = 0
net.packets = {}
local loose = newItem("TienCoolers.IceBag", { InventoryItem = true, DrainableComboItem = true })
dropOnGround(loose, 12, 34, 0)
local junk = newItem("Base.Plank", { InventoryItem = true })
dropOnGround(junk, 12, 34, 0)
local floorList = newContainer("bag")            -- what the loot window builds
floorList:add(loose)
floorList:add(junk)
net.loot = { backpacks = { { inventory = floorList } } }
net.ms = net.ms + 60000
everyMinute()
passed = reportStr("a bag of ice on the floor is handed over", net.sent("command:tick"), 1) and passed
passed = reportStr("  and the plank next to it is not", #net.packets, 1) and passed

net.client = false
local looseAddress = CF.addressGroundItem(loose)
handlers.OnClientCommand("TienCoolers", "tick", me, looseAddress)
clock.hours = 5
handlers.OnClientCommand("TienCoolers", "tick", me, looseAddress)
passed = report("loose ice on the ground melts at the outside rate", loose.delta, 1 - 5 / 9.6) and passed

-- modData crosses the wire but a custom name does not always follow, so a copy can
-- arrive claiming to be labelled while still reading "Cooler". It has to label itself
-- anyway rather than trust the flag and stay that way for good.
clock.hours = 0
local stuck = newBag("Base.Cooler")
stuck:getModData().tcNamed = true
stuck:getModData().tcBaseName = "Base.Cooler"
stuck.inventory:AddItem("TienCoolers.IceBag")
me.inventory:add(stuck)
CF.processTopLevel(me:getInventory())
passed = reportStr("a cooler that only thinks it is labelled gets its label",
    stuck:getName(), "Base.Cooler " .. ICED) and passed

-- And one the player renamed themselves keeps that name when the ice runs out.
local ownName = newBag("Base.Cooler")
ownName:setName("Beer Stash")
local ownIce = ownName.inventory:AddItem("TienCoolers.IceBag")
me.inventory:add(ownName)
CF.processTopLevel(me:getInventory())
passed = reportStr("a renamed cooler keeps its own name", ownName:getName(), "Beer Stash " .. ICED) and passed
ownIce.delta = 0.0
clock.hours = 1
CF.processTopLevel(me:getInventory())
passed = reportStr("  and gets it back when the ice is gone", ownName:getName(), "Beer Stash") and passed

net.packets = {}
handlers.OnClientCommand("SomeOtherMod", "tick", me, request)
passed = reportStr("another mod's commands are ignored", #net.packets, 0) and passed

local resolved = pcall(function()
    handlers.OnClientCommand("TienCoolers", "tick", me, { x = 99, y = 99, z = 0, o = 0, c = 0 })
end)
passed = reportStr("a stale request is a no-op, not an error", resolved, true) and passed

print(passed and "\nALL CHECKS PASSED" or "\nCHECKS FAILED")
