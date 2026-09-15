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
Fluid = { Water = "Water", TaintedWater = "TaintedWater", CarbonatedWater = "CarbonatedWater" }

local classes = {}
function instanceof(o, c) return o.__cls and o.__cls[c] == true end

-- The vanilla send*/sync* helpers. In game they do nothing offline, which is why the
-- mod calls them unguarded; here they record what would have gone over the wire.
net.packets, net.client, net.players = {}, false, {}
net.squares, net.vehicles, net.translated = {}, {}, true
net.server, net.online = false, {}

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
-- Most of the tests below model "the server" as simply "not a client", which is all the
-- ownership rules ever needed. The pass over what players carry is the exception: it is
-- the one thing that must not also happen in single player, so it asks this instead.
function isServer() return net.server == true end
function getTimestampMs() return net.ms or 0 end
function getSpecificPlayer(num) return net.players[num] end
function getSquare(x, y, z) return net.squares[x .. "," .. y .. "," .. z] end
-- The square sweep asks the cell for its neighbours rather than the loot window for
-- its buttons, so the harness has to be able to answer that too.
function getCell()
    return { getGridSquare = function(_, x, y, z) return getSquare(x, y, z) end }
end
function getVehicleById(id) return net.vehicles[id] end

-- A deep copy of plain Lua data, which is what modData becomes on the wire.
function net.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = net.copy(v) end
    return out
end

function sendItemStats(item) net.log("stats:%s", item:getFullType()) end
function syncItemModData(_, item) net.log("moddata:%s", item:getFullType()) end
-- syncItemFields sends the name and the item's *whole modData*, and SyncItemFieldsPacket
-- wipes the receiver's modData and takes the sender's. So a label change carries one
-- machine's cooler timestamps into the other machine's copy. When a test pairs two copies
-- of an inventory (net.peers), the harness does exactly that to the other copy.
function syncItemFields(_, item)
    net.log("fields:%s", item:getFullType())
    local peer = net.peers and (net.client and net.peers.server or net.peers.client)
    local other = peer and peer:getItemWithIDRecursiv(item:getID())
    if other then
        other.name = item.name
        other.md = net.copy(item.md)
    end
end
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

-- Both halves of the mod hang off EveryOneMinute now, so an event has to be able to
-- hold more than one handler. Keeping only the last one silently replaced the client's
-- sweep with the server's pass over what players carry, and every test below that calls
-- handlers.EveryOneMinute() would have been testing the wrong half.
handlers = {}
local handlerLists = {}
Events = setmetatable({}, { __index = function(t, name)
    local slot = { Add = function(fn)                             -- PZ calls this with a dot
        local list = handlerLists[name]
        if not list then
            list = {}
            handlerLists[name] = list
            handlers[name] = function(...)
                for _, handler in ipairs(list) do handler(...) end
            end
        end
        list[#list + 1] = fn
    end }
    rawset(t, name, slot)
    return slot
end })
ISInventoryPaneContextMenu = { addToolTip = function() return {} end }

-- On a dedicated server there are no active players in the local sense - the client
-- half's loop runs zero times - but there is a list of everyone connected.
function getNumActivePlayers() return net.activePlayers or 1 end
function getOnlinePlayers()
    local list = net.online or {}
    return { size = function() return #list end,
             get = function(_, i) return list[i + 1] end }
end
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
function Container:getItemWithIDRecursiv(id)
    for _, v in ipairs(self.list) do
        if v:getID() == id then return v end
        local found = v.inventory and v.inventory:getItemWithIDRecursiv(id)
        if found then return found end
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
        fullType = fullType, __cls = cls or {}, md = {}, age = 0.0, lastAged = 0.0,
        offAgeMax = 3, frozen = false, delta = 1.0, heat = 1.0, id = nextItemId,
    }, Item)
end

function Item:getFullType() return self.fullType end
function Item:getModData() return self.md end
function Item:getContainer() return self.container end
function Item:getInventory() return self.inventory end
function Item:getAge() return self.age end
function Item:setAge(v) self.age = v end

-- Nothing in the game ages food as time passes. Food.update() ages it only
-- `if (GameServer.server)`, and in single player the one remaining caller is
-- ISInventoryPane's render loop - `if instanceof(item, 'InventoryItem') then
-- item:updateAge() end`, once a frame, for whichever container that window is drawing.
-- Everywhere else the age simply stands still, and the whole gap is caught up from
-- `lastAged` the moment somebody finally looks.
--
-- Modelling that lag is the point of this stub. A harness that ages the food itself,
-- neatly in step with the mod's own passes, cannot see the mod lose the rot that
-- arrives in one lump - which is the whole of the bug 1.4.1 fixes.
local SIM_ROT_SPEED = { 1.7, 1.4, 1.0, 0.7, 0.4 }
local SIM_FRIDGE_FACTOR = { 0.4, 0.3, 0.2, 0.1, 0.03, 0.0 }

-- Food.getOutermostContainer(): a cooler inside a backpack inside a fridge is in the
-- fridge, which is why marking the cooler's own container cold would achieve nothing.
local function outermostContainer(item)
    local container = item.container
    for _ = 1, 8 do
        if not container then return nil end
        local holder = container.containingItem
        if not holder or not holder.container then return container end
        container = holder.container
    end
    return container
end

function Item:updateAge()
    if not self.__cls.Food then return end

    local delta = clock.hours - self.lastAged
    self.lastAged = clock.hours
    if delta <= 0 or self.frozen then return end

    local outer = outermostContainer(self)
    if outer and (outer:isFridge() or outer:isFreezer()) and outer:isPowered() then
        delta = delta * (SIM_FRIDGE_FACTOR[SandboxVars.FridgeFactor] or 0.2)
    end
    self.age = self.age + delta * (SIM_ROT_SPEED[SandboxVars.FoodRotSpeed] or 1.0) / 24.0
end
function Item:getOffAgeMax() return self.offAgeMax end
function Item:isFrozen() return self.frozen end
function Item:isRotten() return self.age >= self.offAgeMax end
-- B42 keeps a drainable's charge as an integer count of uses: setCurrentUsesFloat is
-- `uses = round(f / useDelta)` and getCurrentUsesFloat gives `uses * useDelta` back, so
-- the field can only hold multiples of UseDelta - fiftieths, for the ice bag - and any
-- change smaller than half a step rounds away to nothing. Modelling it as a plain float
-- is what hid ice in a carried cooler never melting at all. getUsedDelta itself is gone.
function Item:getUseDelta() return self.useDelta or 0.02 end
function Item:getCurrentUsesFloat() return self.delta end
function Item:setUsedDelta(v)
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    local step = self:getUseDelta()
    self.delta = math.floor(v / step + 0.5) * step
end
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

-- Scenario: one cooler, one bag of ice, one steak. The game ages food by rotSpeed/24
-- per hour, but only when asked; we step an hour at a time and let the mod react.
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
    CF.processTopLevel(top)
end

-- 48 h of ice at 0.6x, then 24 h uncooled.
passed = report("steak age after 48h iced + 24h warm", steak.age, 48 * ROT * 0.6 + 24 * ROT) and passed
passed = report("ice fully melted", ice.delta, 0.0) and passed
passed = report("melted bag removed from cooler", #cooler.inventory.list, 1) and passed

-- Regression, 1.4.1: the same cooler, with nobody looking at it. The game ages food
-- when something asks, not as time passes, so a cooler in a closed bag is untouched
-- until the player opens their inventory and then jumps the whole gap in one frame.
-- Until 1.4.1 that lump landed inside a single one-minute pass, and a pass may only
-- rebate the minute of rot that could have happened since the pass before it: an hour
-- of rot was rebated a minute's worth and the other fifty-nine minutes were kept. A
-- carried cooler preserved nothing at all unless the player sat with the inventory
-- window open. Ticked a minute at a time and never looked at, it has to come out at
-- exactly the cooled rate - and the food beside it in the same bag at the plain one.
clock.hours = 0
local unwatched = newBag("Base.Cooler")
unwatched.inventory:AddItem("TienCoolers.IceBag")
local chilled = newItem("Base.Cabbage", { InventoryItem = true, Food = true })
chilled.offAgeMax = 1000
unwatched.inventory:add(chilled)
local control = newItem("Base.Cabbage", { InventoryItem = true, Food = true })
control.offAgeMax = 1000
local pocket = newContainer("bag")
pocket:add(unwatched)
pocket:add(control)
CF.processTopLevel(pocket)

for minute = 1, 60 do
    clock.hours = minute / 60.0
    CF.processTopLevel(pocket)
    -- The player glances at their inventory every ten minutes. Nothing else in single
    -- player ages food, so this is the only place the game's own catch-up can land, and
    -- it lands ten minutes at a time into a pass allowed to rebate one.
    if minute % 10 == 0 then
        chilled:updateAge()
        control:updateAge()
    end
end

passed = report("an unwatched hour in a cooler still cools", chilled.age, ROT * 0.6, 1e-9) and passed
passed = report("  while the same hour beside it does not", control.age, ROT, 1e-9) and passed

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

-- Scenario: cooling strength is a fraction of a working fridge, so the cooler is read off
-- the line between no cooling (1.0) and whatever Refrigeration Effectiveness gives a real
-- fridge. The ends of the scale are what the setting promises: 1 matches a fridge exactly
-- and 0 leaves food to rot as though the cooler were empty. Neither can beat a fridge,
-- which is the guarantee the old hidden floor used to make and kept getting wrong.
passed = report("cool factor at default refrigeration", CF.coolFactor(), 0.6) and passed
SandboxVars.TienCoolers.CoolStrength = 1.0
passed = report("strength 1 matches a fridge", CF.coolFactor(), CF.fridgeFactor()) and passed
SandboxVars.TienCoolers.CoolStrength = 0.0
passed = report("strength 0 does nothing at all", CF.coolFactor(), 1.0) and passed
SandboxVars.TienCoolers.CoolStrength = nil

-- With Refrigeration Effectiveness on "Very Low" a real fridge only manages 0.4, so half
-- of one is 0.7 rather than the 0.6 it is on a Normal game: the cooler follows the fridge.
SandboxVars.FridgeFactor = 1
passed = report("cool factor tracks Very Low fridges", CF.coolFactor(), 0.7) and passed

clock.hours = 0
local halved = newItem("Base.Cooler", { InventoryItem = true })
halved.inventory = newContainer("bag")
halved.inventory:AddItem("TienCoolers.IceBag")
local roast = newItem("Base.Steak", { InventoryItem = true, Food = true })
roast.offAgeMax = 1000
halved.inventory:add(roast)
local shed = newContainer("bag")
shed:add(halved)
CF.processTopLevel(shed)          -- baseline pass, as the first minute in game would
for hour = 1, 24 do
    clock.hours = hour
    CF.processTopLevel(shed)
end
passed = report("roast age after 24h at half a Very Low fridge", roast.age, 24 * ROT * 0.7) and passed
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
handlers.OnClientCommand("TienCoolers", "tick", me, groundAddress)
passed = report("the server melts ice in a cooler on the ground", droppedIce.delta, 0.5) and passed
passed = report("and rebates the rot it prevented", droppedSteak.age, 0.6) and passed

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
-- The player is still carrying a cooler from earlier on, and reporting that is a separate
-- matter from the floor, so it is left out of the count.
passed = reportStr("  and the plank next to it is not",
    #net.packets - net.sent("command:carried"), 1) and passed

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
net.client = true
CF.processTopLevel(clientCooler.inventory)        -- the client's own copy
net.client = false
CF.processTopLevel(serverCooler.inventory)        -- the server's own copy

passed = report("client and server melt the ice to the same point",
    clientIce.delta, serverIce.delta) and passed
passed = report("  and rebate the same rot", clientFood.age, serverFood.age) and passed
passed = reportStr("  and label it the same", clientCooler:getName(), serverCooler:getName()) and passed
passed = reportStr("  which is not the untouched value", clientIce.delta < 1.0, true) and passed

-- The same claim again, with the one thing the old harness assumed away: the two
-- machines catch their copies up at different moments. A client's food ages when its
-- inventory pane draws the container; a dedicated server's ages when Food.update()
-- reaches the item, which is a different clock entirely. If the rebate depended on
-- where those moments fell - and until 1.4.1 it did, because a lump of ageing was only
-- ever rebated one pass's worth - the copies would drift apart on their own, with no
-- packet lost and nothing to blame it on. Neither machine is authoritative here; both
-- have to arrive at the same number from the same timestamps.
clock.hours = 0
net.client = true
local watchedCooler, _, watchedFood = newIdenticalCooler(0)
net.client = false
local unwatchedCooler, _, unwatchedFood = newIdenticalCooler(0)

for minute = 1, 360 do
    clock.hours = minute / 60.0
    net.client = true
    CF.processTopLevel(watchedCooler.inventory)
    watchedFood:updateAge()                       -- this player has the window open
    net.client = false
    CF.processTopLevel(unwatchedCooler.inventory) -- and nothing is looking at this copy
end
unwatchedFood:updateAge()                         -- six hours, arriving all at once

passed = report("copies caught up on different clocks still agree",
    watchedFood.age, unwatchedFood.age, 1e-9) and passed
passed = report("  at the cooled rate, not the raw one",
    unwatchedFood.age, 6 * ROT * 0.6, 1e-9) and passed

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

function newWaterHolder(amount, fluidName)
    fluidName = fluidName or "Water"
    local item = newItem("Base.BucketWood", { InventoryItem = true })
    item.amount = amount
    item.fluid = {
        getAmount = function() return item.amount end,
        contains = function(_, f) return f == fluidName end,
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

-- Ice in a cooler you are carrying is ticked every game minute, because that is what
-- EveryOneMinute means. A game minute of melting is about 0.0003 of a bag, well under
-- half of the 0.02 step the item's own charge field can hold, so every pass rounds back
-- to where it started and the bag never empties. Stepping an hour at a time - which is
-- how every other test here walks the clock - hides it completely.
clock.hours = 0
net.client = false
SandboxVars.TienCoolers.IceLifeHours = 48.0

local carried = newBag("Base.Cooler")
local carriedIce = carried.inventory:AddItem("TienCoolers.IceBag")
local worn = newContainer("bag")
worn:add(carried)
CF.processTopLevel(worn)

local function runMinutes(upToHour)
    for minute = 1, math.floor(upToHour * 60) do
        clock.hours = minute / 60.0
        CF.processTopLevel(worn)
    end
end

runMinutes(24)
passed = report("half a bag gone after 24h, a minute at a time", CF.getCharge(carriedIce), 0.5) and passed
passed = reportStr("  and the cooler still reads as iced",
    carried:getName(), "Base.Cooler IGUI_TienCoolers_Iced") and passed

runMinutes(48)
passed = reportStr("  then it is spent and cleared out", #carried.inventory.list, 0) and passed
passed = reportStr("  and the cooler loses its label", carried:getName(), "Base.Cooler") and passed

-- Cold pack strength is a sandbox setting now. Cold packs are far rarer than ice you
-- can make yourself, so how much one is worth is the player's call.
SandboxVars.TienCoolers.UseColdpacks = true
SandboxVars.TienCoolers.ColdpackPower = nil
local pack = newItem("Base.Coldpack", { InventoryItem = true })
passed = report("a cold pack is worth 0.4 bags by default", CF.icePower(pack), 0.4) and passed

SandboxVars.TienCoolers.ColdpackPower = 0.9
passed = report("  and whatever the setting says", CF.icePower(pack), 0.9) and passed

-- Zero has to mean off, not a cold source worth nothing: consumeIce divides by the power.
SandboxVars.TienCoolers.ColdpackPower = 0.0
passed = reportStr("  and zero turns them off rather than dividing by it",
    CF.icePower(pack), nil) and passed

SandboxVars.TienCoolers.ColdpackPower = 0.4
SandboxVars.TienCoolers.UseColdpacks = false
passed = reportStr("  the switch still overrides the strength", CF.icePower(pack), nil) and passed
SandboxVars.TienCoolers.UseColdpacks = true

-- Water set to freeze changes nothing a player can see until a bag turns up hours later.
-- Short of a bagful it never turns up at all, and an empty freezer looks the same either
-- way, so the menu has to be able to say where things stand.
SandboxVars.TienCoolers.FreezeHours = 7.0
SandboxVars.TienCoolers.WaterPerBag = 5.0
clock.hours = 100
net.client = false

local tellFreezer = newWorldContainer(700, 700, 0, "freezer", true)
local dribble = newWaterHolder(2.0)
tellFreezer:add(dribble)
CF.startFreezingWater(dribble)

local pooled, perBag, remaining = CF.freezeProgress(tellFreezer)
passed = report("the pooled water is reported", pooled, 2.0) and passed
passed = report("  against what a bag costs", perBag, 5.0) and passed
passed = report("  with the wait still to run", remaining, 7.0) and passed

clock.hours = 105
local _, _, left = CF.freezeProgress(tellFreezer)
passed = report("  which counts down", left, 2.0) and passed

clock.hours = 110
local _, _, none = CF.freezeProgress(tellFreezer)
passed = report("  and stops at zero rather than going negative", none, 0.0) and passed

-- The same container with the power out. The option is offered but greyed, because
-- silence here is indistinguishable from the mod being broken.
local darkFreezer = newWorldContainer(710, 710, 0, "freezer", false)
local darkWater = newWaterHolder(10.0)
darkFreezer:add(darkWater)

local darkMenu = { options = {} }
function darkMenu:addOption(text, target, callback, args)
    local o = { text = text, target = target, callback = callback, args = args }
    table.insert(self.options, o); return o
end
handlers.OnFillInventoryObjectContextMenu(0, darkMenu, { darkWater })
passed = reportStr("an unpowered freezer still offers the option", #darkMenu.options, 1) and passed
passed = reportStr("  greyed out", darkMenu.options[1] and darkMenu.options[1].notAvailable, true) and passed

-- And a powered one offers the real thing, not the greyed one.
local litMenu = { options = {} }
function litMenu:addOption(text, target, callback, args)
    local o = { text = text, target = target, callback = callback, args = args }
    table.insert(self.options, o); return o
end
handlers.OnFillInventoryObjectContextMenu(0, litMenu, { dribble })
passed = reportStr("a powered one offers a live option", #litMenu.options, 1) and passed
passed = reportStr("  that is not greyed", litMenu.options[1] and litMenu.options[1].notAvailable, nil) and passed

-- What counts as water. A bottle filled from a rain barrel or a lake is tainted in B42,
-- and refusing those silently - no menu entry, no reason - reads exactly like the mod
-- not working. Freezing is not filtering, so the bag that comes out is an ordinary one.
clock.hours = 200
net.client = false
SandboxVars.TienCoolers.FreezeHours = 7.0
SandboxVars.TienCoolers.WaterPerBag = 5.0

passed = reportStr("clean water can be frozen",
    CF.canFreezeWater(newWaterHolder(5.0, "Water")), true) and passed
passed = reportStr("tainted water can be frozen too",
    CF.canFreezeWater(newWaterHolder(5.0, "TaintedWater")), true) and passed
passed = reportStr("seltzer cannot",
    CF.canFreezeWater(newWaterHolder(5.0, "CarbonatedWater")), false) and passed
passed = reportStr("and neither can petrol",
    CF.canFreezeWater(newWaterHolder(5.0, "Petrol")), false) and passed

-- All the way through, to an ordinary bag of ice.
local rainFreezer = newWorldContainer(800, 800, 0, "freezer", true)
local rainWater = newWaterHolder(5.0, "TaintedWater")
rainFreezer:add(rainWater)
CF.startFreezingWater(rainWater)
CF.processTopLevel(rainFreezer)
clock.hours = 208
CF.processTopLevel(rainFreezer)
passed = reportStr("rain barrel water makes an ordinary bag of ice", bagsIn(rainFreezer), 1) and passed
passed = report("  and is spent doing it", rainWater.amount, 0.0) and passed

-- Scenario: the cooler a player is carrying, seen from the server. The server holds a copy
-- of it that matters twice over: it is what the player database saves at logout, and B42
-- moves items on the server and hands the result back, so taking a steak out of the
-- cooler gives the player the server's steak. The reported bug is that copy falling
-- behind: log out with food in a carried cooler, stay away a few days, log back in, and the
-- food looks right until it is taken out, when it jumps as if it had never been cooled.
--
-- The server used to run the cooling pass over its copy itself. That only agrees with the
-- client while nothing else touches the bookkeeping, and syncItemFields does (see the stub
-- at the top). So now the carrying client reports its numbers and the server writes them in.
clock.hours = 0
net.packets = {}
net.loot = { backpacks = {} }
net.online = { them }
SandboxVars.FoodRotSpeed = 3
SandboxVars.TienCoolers.IceLifeHours = 48.0
SandboxVars.TienCoolers.CoolStrength = nil
me:setCurrentSquare(squareAt(5000, 5000, 0))     -- nothing nearby for the sweep to find

-- An item as bytes and back, which is how both the player database and a transfer see it.
local function copyItem(item)
    local copy = setmetatable({}, Item)
    for k, v in pairs(item) do
        if k ~= "container" and k ~= "inventory" and k ~= "worldItem" then
            copy[k] = net.copy(v)
        end
    end
    copy.__cls = item.__cls
    if item.inventory then
        copy.inventory = newContainer(item.inventory.kind)
        copy.inventory.containingItem = copy
        for _, inner in ipairs(item.inventory.list) do
            copy.inventory:add(copyItem(inner))
        end
    end
    return copy
end

local function saveInventory(player)
    local saved = {}
    for _, item in ipairs(player.inventory.list) do saved[#saved + 1] = copyItem(item) end
    return saved
end

local function loadInventory(player, saved)
    player.inventory.list = {}
    for _, item in ipairs(saved) do player.inventory:add(copyItem(item)) end
end

local function find(player, item)
    return player.inventory:getItemWithIDRecursiv(item:getID())
end

-- Food.update(), which a dedicated server runs on everything a character carries.
local function ageAll(container)
    for _, item in ipairs(container.list) do
        item:updateAge()
        if item.inventory then ageAll(item.inventory) end
    end
end

-- One cooler with a bag of ice and a steak, buried in a backpack the way it was first
-- reported, in the inventory of the client that carries it.
local function carriedCooler(owner, offAgeMax)
    local pack = newBag("Base.Backpack")
    local cooler = newBag("Base.Cooler")
    pack.inventory:add(cooler)
    local ice = cooler.inventory:AddItem("TienCoolers.IceBag")
    local steak = newItem("Base.Steak", { InventoryItem = true, Food = true })
    steak.offAgeMax = offAgeMax or 1000
    steak.lastAged = clock.hours
    cooler.inventory:add(steak)
    owner.inventory.list = {}
    owner.inventory:add(pack)
    return cooler, ice, steak
end

-- One game minute, a couple of real seconds, on both machines. The server goes first,
-- because that is the order that used to go wrong: its own pass relabelled the cooler and
-- sent the client its timestamps just before the client needed its own.
local function bothMinute(hours)
    clock.hours = hours
    net.ms = net.ms + 2500

    net.client, net.server, net.activePlayers = false, true, 0
    ageAll(them.inventory)
    handlers.EveryOneMinute()

    net.client, net.server, net.activePlayers = true, false, 1
    net.lastCommand = nil
    handlers.EveryOneMinute()
    local sent = net.lastCommand
    if sent and sent.command == "carried" then
        net.client, net.server = false, true
        handlers.OnClientCommand("TienCoolers", "carried", them, sent.args)
    end

    net.client, net.server, net.activePlayers = false, false, 1
end

local mineCooler, mineIce, mineSteak = carriedCooler(me)
loadInventory(them, saveInventory(me))           -- the server's copy of the same things
net.peers = { client = me.inventory, server = them.inventory }

for minute = 0, 359 do
    bothMinute(minute / 60.0)
end
-- Reports go out every ten real seconds, so the server's copy trails by up to that much.
-- Line the last minute up with one so the two can be compared exactly.
net.ms = net.ms + 10000
bothMinute(6)

passed = report("the server's copy of a carried steak is the client's",
    find(them, mineSteak).age, mineSteak.age, 1e-9) and passed
passed = report("  at the cooled rate, not the raw one", mineSteak.age, 6 * ROT * 0.6, 1e-9) and passed
passed = report("  and its ice holds what the client has left",
    CF.getCharge(find(them, mineIce)), CF.getCharge(mineIce), 1e-9) and passed
passed = reportStr("  and its label is the client's",
    find(them, mineCooler):getName(), mineCooler:getName()) and passed

-- The player logs out. The database keeps the server's copy, and nothing touches it for
-- the day and a quarter they are away. At login both machines load that same copy.
local saved = saveInventory(them)
net.ms = net.ms + 30 * 60 * 1000
loadInventory(me, saved)
loadInventory(them, saved)
bothMinute(36)

-- Taking the steak out of the cooler hands the player the server's steak.
local handedBack = copyItem(find(them, mineSteak))
handedBack:updateAge()
passed = report("back after 30 hours, the steak taken out of the cooler is cooled",
    handedBack.age, 36 * ROT * 0.6, 1e-9) and passed
passed = report("  and is the steak the player saw in it", handedBack.age, find(me, mineSteak).age, 1e-9) and passed

-- Away long enough for the ice to run out, which is the case that was reported: a hundred
-- hours, with twelve hours of ice left at logout. Both machines relabel the cooler on the
-- first pass after login, and the server's own pass used to do it first, carrying its
-- cooler bookkeeping into the client's copy and costing the client the whole absence.
saved = saveInventory(them)
net.ms = net.ms + 100 * 60 * 1000
loadInventory(me, saved)
loadInventory(them, saved)
bothMinute(136)

handedBack = copyItem(find(them, mineSteak))
handedBack:updateAge()
passed = report("away until the ice ran out, the steak is cooled while it lasted",
    handedBack.age, (48 * 0.6 + 88) * ROT, 1e-6) and passed
passed = report("  and is still the steak the player saw", handedBack.age, find(me, mineSteak).age, 1e-9) and passed

-- The label comes off on the pass after the one that used the last of the ice, and the
-- server's copy takes it from the client along with everything else.
net.ms = net.ms + 10000
bothMinute(136 + 1 / 60)
passed = reportStr("  and the cooler loses its label", find(me, mineCooler):getName(), "Base.Cooler") and passed
passed = reportStr("  on the server's copy too", find(them, mineCooler):getName(), "Base.Cooler") and passed
net.peers = nil

-- A report is a client's word, and the server holds it to what a cooler could have done:
-- no more than the open-air rate, no less than the best a cooler manages.
clock.hours = 200
net.ms = net.ms + 60000
local heldCooler, heldIce, heldSteak = carriedCooler(me)
loadInventory(them, saveInventory(me))
bothMinute(200)

local serverSteak, serverIce = find(them, heldSteak), find(them, heldIce)
local serverCooler = find(them, heldCooler)
local settled = serverSteak.age
local function claim(items)
    net.client, net.server = false, true
    handlers.OnClientCommand("TienCoolers", "carried", them, { coolers = {
        { id = serverCooler:getID(), tag = serverCooler.md.tcId, items = items } } })
    net.client, net.server = false, false
end

clock.hours = 210
claim({ { id = serverSteak:getID(), age = settled } })
passed = report("a report cannot stop food rotting",
    serverSteak.age, settled + 10 * ROT * CF.coolFactor(), 1e-9) and passed

claim({ { id = serverIce:getID(), charge = 0.5 } })
claim({ { id = serverIce:getID(), charge = 0.9 } })
passed = report("  nor put back ice that has already melted", CF.getCharge(serverIce), 0.5, 1e-9) and passed

local stranger = newPlayer(2, false)
local _, _, strangerSteak = carriedCooler(stranger)
strangerSteak.age = 5.0
local strangerCooler = stranger.inventory.list[1].inventory.list[1]
net.client, net.server = false, true
handlers.OnClientCommand("TienCoolers", "carried", them, { coolers = {
    { id = strangerCooler:getID(), tag = "x", items = { { id = strangerSteak:getID(), age = 0 } } } } })
passed = report("  nor touch a cooler someone else is carrying", strangerSteak.age, 5.0) and passed

local survived = pcall(function()
    handlers.OnClientCommand("TienCoolers", "carried", them, { coolers = { "junk", { id = "7" } } })
    handlers.OnClientCommand("TienCoolers", "carried", them, { coolers = 3 })
end)
passed = reportStr("  and a malformed one is ignored, not thrown", survived, true) and passed
net.client, net.server = false, false
net.players[2] = nil

-- The server still ticks what a player carries outside a cooler, so a loose bag of ice is
-- current when a transfer hands it back. It does not reach into the bag, though, since two
-- machines both adding and removing there is two of the item, and it leaves the coolers to
-- the report, sending the client nothing about them.
clock.hours = 0
net.ms = net.ms + 60000
local looseBag = newItem("TienCoolers.IceBag", { InventoryItem = true, DrainableComboItem = true })
looseBag.delta = 0.01
local leftCooler = newBag("Base.Cooler")
local leftIce = leftCooler.inventory:AddItem("TienCoolers.IceBag")
them.inventory.list = {}
them.inventory:add(looseBag)
them.inventory:add(leftCooler)
net.packets = {}

net.client, net.server, net.activePlayers = false, true, 0
handlers.EveryOneMinute()
clock.hours = 20
net.ms = net.ms + 60000
handlers.EveryOneMinute()
passed = report("the server melts a remote player's loose ice", CF.getCharge(looseBag), 0.0) and passed
passed = reportStr("  but leaves clearing it away to that client", #them.inventory.list, 2) and passed
passed = report("  and leaves the ice in their cooler to their report", leftIce.delta, 1.0) and passed
passed = reportStr("  sending nothing about that cooler", net.sent("fields:Base.Cooler"), 0) and passed
net.client, net.server, net.activePlayers = false, false, 1

-- A long absence arrives in one lump. A lump big enough to carry food past its rotten mark
-- used to skip the rebate that should have kept it short of the mark, so a steak that a
-- cooler had kept fresh came back rotten.
clock.hours = 0
local lumpCooler = newBag("Base.Cooler")
lumpCooler.inventory:AddItem("TienCoolers.IceBag")
local lumpSteak = newItem("Base.Steak", { InventoryItem = true, Food = true })
lumpSteak.offAgeMax = 1
lumpCooler.inventory:add(lumpSteak)
local lumpTop = newContainer("bag")
lumpTop:add(lumpCooler)
CF.processTopLevel(lumpTop)
clock.hours = 24
CF.processTopLevel(lumpTop)
passed = report("a day in one lump is cooled even when a raw day rots it",
    lumpSteak.age, 24 * ROT * 0.6, 1e-9) and passed
passed = reportStr("  so the steak is not rotten", lumpSteak:isRotten(), false) and passed

-- And none of it happens in single player, where the client half already did the work.
-- Melting the same bag twice a minute is exactly the double count the shared timestamp
-- is there to prevent, but it costs nothing to say so.
clock.hours = 0
net.ms = net.ms + 60000
net.online = { me }
net.packets = {}
local _, soloIce = carriedCooler(me)
handlers.EveryOneMinute()                          -- net.server is false: offline
clock.hours = 24
net.ms = net.ms + 60000
CF.processTopLevel(me:getInventory())
passed = report("offline the ice is only ever melted once", soloIce.delta, 0.5) and passed
passed = reportStr("  and nothing is reported to a server that is not there",
    net.sent("command:carried"), 0) and passed
net.online = {}

print(passed and "\nALL CHECKS PASSED" or "\nCHECKS FAILED")
