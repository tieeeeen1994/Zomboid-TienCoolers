-- Offline harness for TienCooler_Shared.lua: fakes just enough of the PZ API to
-- run the cooling maths and check the numbers come out where they should.

local clock = { hours = 0 }

GameTime = { getInstance = function() return { getWorldAgeHours = function() return clock.hours end } end }
SandboxVars = { FoodRotSpeed = 3, TienCoolers = {} }
function getClimateManager() return { getTemperature = function() return 20.0 end } end
function ZombRand(n) return 12345 end
function getText(k) return k end
-- net.translated is what a client has and a dedicated server does not.
net = net or {}
function getTextOrNull(k) return net.translated ~= false and k or nil end
Fluid = { Water = "Water" }

local classes = {}
function instanceof(o, c) return o.__cls and o.__cls[c] == true end

-- The vanilla send*/sync* helpers. In game they do nothing offline, which is why the
-- mod calls them unguarded; here they record what would have gone over the wire.
net.packets, net.client, net.players = {}, false, {}
net.squares, net.vehicles, net.translated = {}, {}, true

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
-- The square sweep asks the cell for its neighbours rather than the loot window for
-- its buttons, so the harness has to be able to answer that too.
function getCell()
    return { getGridSquare = function(_, x, y, z) return getSquare(x, y, z) end }
end
function getVehicleById(id) return net.vehicles[id] end

function sendItemStats(item) net.log("stats:%s", item:getFullType()) end
function syncItemModData(_, item) net.log("moddata:%s", item:getFullType()) end
function syncItemFields(_, item) net.log("fields:%s", item:getFullType()) end
function sendAddItemToContainer(_, item) net.log("add:%s", item:getFullType()) end
function sendRemoveItemFromContainer(_, item) net.log("remove:%s", item:getFullType()) end
function sendServerCommand(_, module, command, args)
    net.log("reply:%s", command)
    net.lastReply = { command = command, args = args }
end
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
function Container:getType() return self.kind end
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
    function player:getCurrentSquare() return self.square end
    function player:setCurrentSquare(square) self.square = square end
    function player:getUsername() return "player" .. num end
    function player:getInventory() return self.inventory end
    net.players[num] = player
    return player
end

-- A container standing in the world, the way a fridge or a crate does. The server
-- looks these up again by square and index, so the stub has to be indexable too.
function squareAt(x, y, z)
    local key = x .. "," .. y .. "," .. z
    local square = net.squares[key]
    if not square then
        square = { objects = {}, dropped = {} }
        function square:getX() return x end
        function square:getY() return y end
        function square:getZ() return z end
        function square:getObjects()
            local list = self.objects
            return { size = function() return #list end,
                     get = function(_, i) return list[i + 1] end }
        end
        -- Dropped items are a separate list from the square's objects. Looking for one
        -- in getObjects() is exactly the mistake that stopped ground coolers working.
        function square:getWorldObjects()
            local list = self.dropped
            return { size = function() return #list end,
                     get = function(_, i) return list[i + 1] end }
        end
        net.squares[key] = square
    end
    return square
end

-- Set a bag down on the ground. IsoWorldInventoryObject's constructor calls
-- IsoObject.setContainer, so the world object becomes the parent of the dropped bag's
-- container: a bag on the ground does have a parent, it just is not one of the
-- square's objects. Anything less faithful hides the bug instead of catching it.
function dropOnGround(item, x, y, z)
    local square = squareAt(x, y, z)
    local worldObject = { getSquare = function() return square end }
    -- IsoWorldInventoryObject is an IsoObject, so this is how the server re-sends a
    -- dropped item to clients. The stub counts the calls.
    function worldObject:transmitCompleteItemToClients() net.log("resend:%s", item:getFullType()) end
    table.insert(square.dropped, { getItem = function() return item end })
    item.worldItem = worldObject
    item.container = nil
    if item.inventory then item.inventory.parent = worldObject end
    return item
end

function newWorldContainer(x, y, z, kind, powered)
    local container = newContainer(kind, powered)
    local square = squareAt(x, y, z)

    local object = { containers = { container } }
    function object:getSquare() return square end
    function object:getContainerIndex(c)
        for i, v in ipairs(self.containers) do
            if v == c then return i - 1 end
        end
        return -1
    end
    function object:getContainerByIndex(i) return self.containers[i + 1] end
    function object:getContainerCount() return #self.containers end

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
passed = report("half bag after 3h refreezing", half.delta, 0.25 + 3 / 7) and passed

-- Scenario: water in a powered freezer becomes ice after FreezeHours.
clock.hours = 0
local freezer2 = newContainer("freezer", true)
local bottle = newItem("Base.WaterBottleFull", { InventoryItem = true })
bottle.amount = 12.5
bottle.fluid = {
    getAmount = function() return bottle.amount end,
    contains = function() return true end,
    removeFluid = function(_, v) bottle.amount = bottle.amount - v end,
}
freezer2:add(bottle)
CF.startFreezingWater(bottle)
CF.processTopLevel(freezer2)
clock.hours = 8
CF.processTopLevel(freezer2)
local bags = 0
for _, it in ipairs(freezer2.list) do
    if it:getFullType() == "TienCoolers.IceBag" then bags = bags + 1 end
end
passed = report("bags of ice from 12.5 units of water", bags, 2) and passed
passed = report("water left in the bottle", bottle.amount, 2.5) and passed

-- Scenario: water pools by container. Three glasses that could never make a bag on
-- their own add up to one, and the water is drawn off the emptiest first so the little
-- containers come out empty rather than all of them keeping a dribble.
local function newGlass(amount)
    local glass = newItem("Base.Glass", { InventoryItem = true })
    glass.amount = amount
    glass.fluid = {
        getAmount = function() return glass.amount end,
        contains = function() return true end,
        removeFluid = function(_, v) glass.amount = glass.amount - v end,
    }
    return glass
end

clock.hours = 0
local pooling = newContainer("freezer", true)
local glassA, glassB, glassC = newGlass(2.0), newGlass(2.0), newGlass(2.0)
for _, glass in ipairs({ glassA, glassB, glassC }) do
    pooling:add(glass)
    passed = reportStr("a glass too small for a bag can still be marked",
        CF.canFreezeWater(glass), true) and passed
    CF.startFreezingWater(glass)
end

CF.processTopLevel(pooling)
clock.hours = 8
CF.processTopLevel(pooling)

local pooledBags = 0
for _, it in ipairs(pooling.list) do
    if it:getFullType() == "TienCoolers.IceBag" then pooledBags = pooledBags + 1 end
end
passed = report("three 2-unit glasses make one 5-unit bag", pooledBags, 1) and passed
passed = report("  and the water comes out of them in turn",
    glassA.amount + glassB.amount + glassC.amount, 1.0) and passed
passed = reportStr("  emptying the first two rather than sipping all three",
    (glassA.amount == 0 and glassB.amount == 0), true) and passed
passed = reportStr("  the drained ones stop waiting to freeze",
    CF.isFreezingWater(glassA), false) and passed
passed = reportStr("  and the one still holding water keeps waiting",
    CF.isFreezingWater(glassC), true) and passed

-- Not enough between them: nothing happens and nothing is lost.
clock.hours = 0
local shortfall = newContainer("freezer", true)
local dribbleA, dribbleB = newGlass(1.0), newGlass(1.5)
shortfall:add(dribbleA)
shortfall:add(dribbleB)
CF.startFreezingWater(dribbleA)
CF.startFreezingWater(dribbleB)
CF.processTopLevel(shortfall)
clock.hours = 8
CF.processTopLevel(shortfall)
passed = report("two glasses short of a bag make none", #shortfall.list, 2) and passed
passed = report("  and keep their water", dribbleA.amount + dribbleB.amount, 2.5) and passed
passed = reportStr("  and stay marked, waiting for more",
    CF.isFreezingWater(dribbleA), true) and passed

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

-- A fridge with nothing of ours in it is still walked, and still says nothing: the
-- server has no work to do about a cupboard full of tinned beans, and asking it to look
-- at every container within reach every ten seconds is how a mod makes a room stutter.
everyMinute()
passed = reportStr("an empty fridge is not handed to the server", net.sent("command:tick"), 0) and passed

fridge:AddItem("TienCoolers.IceBag")
net.ms = net.ms + 60000
net.packets = {}
everyMinute()
passed = reportStr("the fridge is handed to the server", net.sent("command:tick"), 1) and passed
passed = reportStr("no version check while tracing is off", net.sent("command:version"), 0) and passed

CF.DEBUG = true                                  -- the handshake is part of the tracing
everyMinute()                                    -- same moment, so no second tick
passed = reportStr("the client asks the server which build it is running",
    net.sent("command:version"), 1) and passed
CF.DEBUG = false
everyMinute()
passed = reportStr("a repeat inside the window is dropped", net.sent("command:tick"), 1) and passed
net.ms = net.ms + 60000
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
jug.amount = 5.0
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

clock.hours = 8
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

-- Putting ice into a cooler that is already on the ground: the loot window hands us
-- that cooler's own container button, which is the inside of a cooler and must not be
-- walked as if it were an ordinary container.
net.client = true
clock.hours = 0
local onFloor = newBag("Base.Cooler")
dropOnGround(onFloor, 12, 35, 0)
local floorIce = onFloor.inventory:AddItem("TienCoolers.IceBag")
passed = reportStr("a dropped cooler's container has the world object as its parent",
    onFloor.inventory:getParent() ~= nil, true) and passed
passed = reportStr("and it is still addressable",
    CF.addressContainer(onFloor.inventory) ~= nil, true) and passed

net.client = false
CF.processTopLevel(onFloor.inventory)          -- what the cooler's own button gives us
passed = reportStr("ice put into a cooler on the ground labels it",
    onFloor:getName(), "Base.Cooler " .. ICED) and passed
clock.hours = 24
CF.processTopLevel(onFloor.inventory)
passed = report("and melts at the in-a-cooler rate, not the open-air one",
    floorIce.delta, 0.5) and passed

-- transmitCompleteItemToClients ADDS a world object rather than updating one, so using
-- it to push a dropped item's new state gives every client a second cooler next to the
-- first, and the ghost cannot be picked up. Nothing may re-send a world object here.
net.packets = {}
clock.hours = clock.hours + 12
handlers.OnClientCommand("TienCoolers", "tick", me, groundAddress)
passed = reportStr("a ground pass never re-sends the world object",
    net.sent("resend:Base.Cooler"), 0) and passed

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

-- A server with no translations for a modded key must not stamp the raw key onto the
-- item, and a cooler already carrying one has to be repaired rather than labelled twice.
net.translated = false
local serverSide = newBag("Base.Cooler")
serverSide.inventory:AddItem("TienCoolers.IceBag")
me.inventory:add(serverSide)
clock.hours = 0
CF.processTopLevel(me:getInventory())
passed = reportStr("an untranslated label falls back to plain English",
    serverSide:getName(), "Base.Cooler (Iced)") and passed

local stamped = newBag("Base.Cooler")
stamped:setName("Base.Cooler " .. ICED)          -- what the raw key left behind
stamped.inventory:AddItem("TienCoolers.IceBag")
me.inventory:add(stamped)
CF.processTopLevel(me:getInventory())
passed = reportStr("a name stamped with the raw key is repaired",
    stamped:getName(), "Base.Cooler (Iced)") and passed
net.translated = true

-- The model, stated as a test: two machines each tick their own copy of the same
-- cooler over the same stretch of time and land on the same state, without exchanging
-- anything. That is what lets a client tick a container it does not own - which is
-- what makes a cooler on the floor cool live - and it is how vanilla treats food rot.
local function newIdenticalCooler(hours)
    local cooler = newBag("Base.Cooler")
    local ice = cooler.inventory:AddItem("TienCoolers.IceBag")
    local food = newItem("Base.Steak", { InventoryItem = true, Food = true })
    food.offAgeMax = 1000
    cooler.inventory:add(food)
    clock.hours = hours
    CF.processTopLevel(cooler.inventory)          -- both start from the same baseline
    return cooler, ice, food
end

clock.hours = 0
net.client = true
local clientCooler, clientIce, clientFood = newIdenticalCooler(0)
net.client = false
local serverCooler, serverIce, serverFood = newIdenticalCooler(0)

clock.hours = 18
clientFood.age = 18 / 24
serverFood.age = 18 / 24
net.client = true
CF.processTopLevel(clientCooler.inventory)        -- the client's own copy
net.client = false
CF.processTopLevel(serverCooler.inventory)        -- the server's own copy

passed = report("client and server melt the ice to the same point",
    clientIce.delta, serverIce.delta) and passed
passed = report("  and rebate the same rot", clientFood.age, serverFood.age) and passed
passed = reportStr("  and label it the same", clientCooler:getName(), serverCooler:getName()) and passed
passed = reportStr("  which is not the untouched value", clientIce.delta < 1.0, true) and passed

-- Ticking the same copy twice in the same moment must stay a no-op, or a client and a
-- server both ticking would count the time twice.
local before = clientIce.delta
CF.processTopLevel(clientCooler.inventory)
CF.processTopLevel(clientCooler.inventory)
passed = report("and a second pass in the same moment changes nothing", clientIce.delta, before) and passed

-- Making ice out of water is the exception: a transfer, not a computation. If every
-- machine did it there would be a bag of ice per machine.
clock.hours = 0
local sharedFreezer = newWorldContainer(60, 60, 0, "freezer", true)
local sharedJug = newItem("Base.WaterBottleFull", { InventoryItem = true })
sharedJug.amount = 5.0
sharedJug.fluid = {
    getAmount = function() return sharedJug.amount end,
    contains = function() return true end,
    removeFluid = function(_, v) sharedJug.amount = sharedJug.amount - v end,
}
sharedFreezer:add(sharedJug)
CF.startFreezingWater(sharedJug)

net.client = true
CF.processTopLevel(sharedFreezer)
clock.hours = 8
CF.processTopLevel(sharedFreezer)
local made = 0
for _, it in ipairs(sharedFreezer.list) do
    if it:getFullType() == "TienCoolers.IceBag" then made = made + 1 end
end
passed = reportStr("a client makes no ice in a freezer it does not own", made, 0) and passed
passed = reportStr("  and leaves the water marked so the server still will",
    CF.isFreezingWater(sharedJug), true) and passed

net.client = false
CF.processTopLevel(sharedFreezer)
made = 0
for _, it in ipairs(sharedFreezer.list) do
    if it:getFullType() == "TienCoolers.IceBag" then made = made + 1 end
end
passed = reportStr("and the owner does make it", made, 1) and passed

-- A client still nudges the server for what it does not own, so the saved copy keeps up.
net.client = true
net.packets = {}
net.ms = net.ms + 60000
net.loot = { backpacks = { { inventory = fridge } } }
handlers.EveryOneMinute()
passed = reportStr("a client ticks locally and nudges the server", net.sent("command:tick"), 1) and passed

-- The version handshake, which is how a server left on an older build makes itself
-- known instead of just looking like a broken mod.
net.packets = {}
net.client = true
CF.DEBUG = true
handlers.EveryOneMinute()
passed = reportStr("and does not ask again", net.sent("command:version"), 0) and passed
CF.DEBUG = false

net.client = false
handlers.OnClientCommand("TienCoolers", "version", me, {})
passed = reportStr("the server answers with its own", net.lastReply.args.v, CF.VERSION) and passed

CF.DEBUG = true
local ok = pcall(function() handlers.OnServerCommand("TienCoolers", "version", { v = "0.0.1" }) end)
passed = reportStr("a mismatched answer is reported, not thrown", ok, true) and passed
CF.DEBUG = false

net.packets = {}
handlers.OnClientCommand("SomeOtherMod", "tick", me, request)
passed = reportStr("another mod's commands are ignored", #net.packets, 0) and passed

local resolved = pcall(function()
    handlers.OnClientCommand("TienCoolers", "tick", me, { x = 99, y = 99, z = 0, o = 0, c = 0 })
end)
passed = reportStr("a stale request is a no-op, not an error", resolved, true) and passed

-- The square sweep. This is what actually reaches a fridge or a freezer: the loot
-- window's container list is wiped and rebuilt from whatever that window happens to be
-- showing, so hanging the only pass off it left water marked in a freezer sitting there
-- untouched. The sweep is given an empty loot window here on purpose - everything below
-- has to happen without one.
clock.hours = 0
net.client = false
net.loot = { backpacks = {} }
SandboxVars.TienCoolers.FreezeHours = 7.0
SandboxVars.TienCoolers.WaterPerBag = 5.0

-- Comfortably past the sweep's own real-time interval. EveryOneMinute is an in-game
-- minute and fires far too often to sweep on, so the sweep keeps its own clock.
local SWEEP_GAP = 30000

function newWaterHolder(amount)
    local item = newItem("Base.BucketWood", { InventoryItem = true })
    item.amount = amount
    item.fluid = {
        getAmount = function() return item.amount end,
        contains = function() return true end,
        removeFluid = function(_, v) item.amount = item.amount - v end,
    }
    return item
end

local sweptFreezer = newWorldContainer(200, 200, 0, "freezer", true)
local sweptWater = newWaterHolder(10.0)
sweptFreezer:add(sweptWater)
CF.startFreezingWater(sweptWater)

me:setCurrentSquare(squareAt(201, 201, 0))
net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()
clock.hours = 8
net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()

function bagsIn(container)
    local n = 0
    for _, it in ipairs(container.list) do
        if it:getFullType() == "TienCoolers.IceBag" then n = n + 1 end
    end
    return n
end

passed = reportStr("the sweep freezes water with no loot window at all", bagsIn(sweptFreezer), 2) and passed
passed = report("  and takes the water it paid for", sweptWater.amount, 0.0) and passed

-- Out of range is a delay, never a loss: the timestamp stays on the item, so the whole
-- gap is settled the moment the player walks back.
clock.hours = 0
local farFreezer = newWorldContainer(300, 300, 0, "freezer", true)
local farWater = newWaterHolder(10.0)
farFreezer:add(farWater)
CF.startFreezingWater(farWater)

me:setCurrentSquare(squareAt(310, 310, 0))
clock.hours = 30
net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()
passed = reportStr("a freezer out of range is left alone", bagsIn(farFreezer), 0) and passed
passed = reportStr("  and keeps its mark rather than losing it", CF.isFreezingWater(farWater), true) and passed

me:setCurrentSquare(squareAt(301, 300, 0))
net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()
passed = reportStr("  so walking back settles the whole gap at once", bagsIn(farFreezer), 2) and passed

-- A cooler set down on the floor is a world object, not something inside a container,
-- so the sweep has to look at a square's dropped items as well as its containers.
clock.hours = 0
local sweptCooler = newBag("Base.Cooler")
local sweptIce = sweptCooler.inventory:AddItem("TienCoolers.IceBag")
dropOnGround(sweptCooler, 200, 199, 0)
me:setCurrentSquare(squareAt(201, 200, 0))
net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()
clock.hours = 24
net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()
passed = report("the sweep melts ice in a cooler on the ground", sweptIce.delta, 0.5) and passed

-- Keeping the other machines in step. Everything this mod changes on an item it does
-- not own has to be pushed, or a client goes on drawing state that stopped being true:
-- a bucket that reads full until you pick it up, water offered "Freeze Into Ice" while
-- it is already freezing.
clock.hours = 0
net.client = false
net.packets = {}
net.loot = { backpacks = {} }
SandboxVars.TienCoolers.FreezeHours = 7.0
SandboxVars.TienCoolers.WaterPerBag = 5.0

local syncFreezer = newWorldContainer(400, 400, 0, "freezer", true)
local syncWater = newWaterHolder(10.0)
syncFreezer:add(syncWater)

CF.startFreezingWater(syncWater)
passed = reportStr("marking water is transmitted", net.sent("moddata:Base.BucketWood"), 1) and passed

-- Still waiting. The mark is re-asserted so a client that walked out of range and back,
-- and so has a freshly streamed copy with no modData on it, learns of it again.
net.packets = {}
CF.processTopLevel(syncFreezer)
passed = reportStr("water still waiting says so again", net.sent("moddata:Base.BucketWood"), 1) and passed

-- The water actually going into the ice has to travel too.
net.packets = {}
clock.hours = 8
CF.processTopLevel(syncFreezer)
passed = report("the water is gone", syncWater.amount, 0.0) and passed
passed = reportStr("and the new level is transmitted", net.sent("stats:Base.BucketWood"), 1) and passed
passed = reportStr("as is the mark being cleared", net.sent("moddata:Base.BucketWood"), 1) and passed

-- A partly drawn container keeps its mark, and its new level goes out just the same.
clock.hours = 0
net.packets = {}
local partFreezer = newWorldContainer(410, 410, 0, "freezer", true)
local partWater = newWaterHolder(8.0)
partFreezer:add(partWater)
CF.startFreezingWater(partWater)
CF.processTopLevel(partFreezer)
clock.hours = 8
net.packets = {}
CF.processTopLevel(partFreezer)
passed = report("a partly drawn container keeps the remainder", partWater.amount, 3.0) and passed
passed = reportStr("  and transmits it", net.sent("stats:Base.BucketWood"), 1) and passed
passed = reportStr("  and stays marked", CF.isFreezingWater(partWater), true) and passed

-- A client whose copy had not heard yet asks again. Answer it; do not restart its wait.
local reFreezer = newWorldContainer(420, 420, 0, "freezer", true)
local reWater = newWaterHolder(10.0)
reFreezer:add(reWater)
clock.hours = 20
CF.startFreezingWater(reWater)
local markedAt = reWater.md.tcFreezeStart

clock.hours = 24
local reAddress = CF.addressContainer(reFreezer)
reAddress.item = reWater:getID()
reAddress.on = true
net.packets = {}
handlers.OnClientCommand("TienCoolers", "setFreezing", me, reAddress)
passed = report("asking twice does not restart the wait", reWater.md.tcFreezeStart, markedAt) and passed
passed = reportStr("  and the asker is told where it stands", net.sent("moddata:Base.BucketWood"), 1) and passed

-- The sweep's own clock. EveryOneMinute is an in-game minute - a couple of real seconds
-- at the default day length - so sweeping on every one of them walks every container in
-- reach dozens of times a real minute. It is meant to be idempotent, not free.
clock.hours = 0
net.client = false
net.packets = {}
net.loot = { backpacks = {} }

local throttleFreezer = newWorldContainer(500, 500, 0, "freezer", true)
local throttleWater = newWaterHolder(10.0)
throttleFreezer:add(throttleWater)
me:setCurrentSquare(squareAt(500, 501, 0))
net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()
CF.startFreezingWater(throttleWater)

clock.hours = 8
handlers.EveryOneMinute()          -- same real moment, so no sweep and no ice
passed = reportStr("a second sweep in the same real moment is skipped", bagsIn(throttleFreezer), 0) and passed

net.ms = net.ms + SWEEP_GAP
handlers.EveryOneMinute()
passed = reportStr("  and the next one past the interval does the lot", bagsIn(throttleFreezer), 2) and passed

-- Containers with nothing of this mod's in them cost the server nothing.
net.client = true
net.ms = net.ms + SWEEP_GAP
net.packets = {}
local dullShelf = newWorldContainer(510, 510, 0, "shelves", false)
dullShelf:add(newItem("Base.Plank", { InventoryItem = true }))
me:setCurrentSquare(squareAt(510, 511, 0))
handlers.EveryOneMinute()
passed = reportStr("a shelf of junk is never handed to the server", net.sent("command:tick"), 0) and passed
net.client = false

-- Ice remembers where it has been. The elapsed gap belongs to the container the bag sat
-- in through it, not to whatever it is being held in at the instant somebody finally
-- looks: a bag lifted out of a freezer nobody had ticked for two days would otherwise
-- have two days of melting applied on the way out, and it only lives about nine hours
-- outside, so it would be destroyed by the act of picking it up.
clock.hours = 0
net.client = false
net.packets = {}

local restFreezer = newContainer("freezer", true)
local restBag = restFreezer:AddItem("TienCoolers.IceBag")
CF.processTopLevel(restFreezer)

clock.hours = 48                       -- two days nobody came near it
local pocket = newContainer("bag")
restFreezer:Remove(restBag)
pocket:add(restBag)
CF.processTopLevel(pocket)

passed = report("a bag out of an unwatched freezer comes out whole", restBag.delta, 1.0) and passed
passed = reportStr("  and is still there to be carried", #pocket.list, 1) and passed

clock.hours = 53                       -- and only now does it start melting
CF.processTopLevel(pocket)
passed = report("  then melts at the outside rate from there", restBag.delta, 1 - 5 / 9.6) and passed

-- Clearing a spent bag away is a transfer like any other, and a client doing it to a
-- freezer it does not own deletes the bag out from under the server.
clock.hours = 0
net.client = true
net.packets = {}
local otherFreezer = newWorldContainer(600, 600, 0, "freezer", false)   -- no power: it melts
local spent = otherFreezer:AddItem("TienCoolers.IceBag")
spent.delta = 0.01
CF.processTopLevel(otherFreezer)
clock.hours = 20
CF.processTopLevel(otherFreezer)

passed = report("a client melts a bag in a freezer it does not own", CF.getCharge(spent), 0.0) and passed
passed = reportStr("  but leaves the removal to the owner", #otherFreezer.list, 1) and passed
passed = reportStr("  and sends no removal of its own", net.sent("remove:TienCoolers.IceBag"), 0) and passed

net.client = false
clock.hours = 21
net.packets = {}
CF.processTopLevel(otherFreezer)
passed = reportStr("and the owner clears it away", #otherFreezer.list, 0) and passed
passed = reportStr("  and says so", net.sent("remove:TienCoolers.IceBag"), 1) and passed

print(passed and "\nALL CHECKS PASSED" or "\nCHECKS FAILED")
