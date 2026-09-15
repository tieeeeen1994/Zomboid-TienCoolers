--[[
    Tien's Coolers - shared core.

    Build 42 slows food rot only for containers whose parent IsoObject is a powered
    fridge/freezer (Food.updateAge -> isInFridge/isInFreezer + sourceGrid:haveElectricity).
    A cooler carried in your inventory has no parent object, so there is no vanilla hook
    to hang portable cooling on. Instead this mod asks the game to bring each item's
    ageing up to date, measures how much it applied since the last pass, and gives part
    of that ageing back, which produces exactly the same result as a slower rot rate and
    needs no per-tick presence. Asking first is not a detail: nothing ages food on its
    own in single player, so left alone the ageing arrives in lumps far larger than the
    pass that has to rebate them. See CF.ageFood.
]]

TienCoolers = TienCoolers or {}
local CF = TienCoolers

-- Keep in step with modversion in mod.info. The client and the server compare these
-- at login: a dedicated server only picks up a new Workshop build when it restarts,
-- and half this mod lives on the server, so a stale one fails in ways that look like
-- bugs (nothing works on the ground, nothing works in a fridge).
CF.VERSION = "1.5.0"

-- Prints what the mod is doing with containers it does not own, on both machines, at
-- most a line a minute. Set true when a server needs tracing.
CF.DEBUG = false

function CF.debug(fmt, ...)
    if CF.DEBUG then
        print("TienCoolers: " .. string.format(fmt, ...))
    end
end

CF.ICE_BAG = "TienCoolers.IceBag"
CF.ICE_BAG_TAINTED = "TienCoolers.IceBagTainted"

-- fullType -> cooling power, where 1.0 is one full bag of ice.
-- Other mods may add their own cold sources to this table.
CF.IceSources = {
    ["TienCoolers.IceBag"] = 1.0,
    ["TienCoolers.IceBagTainted"] = 1.0,
}

-- fullType -> the fluid a cold source melts back into, by name, for the ones that are
-- water at all. A Cold Pack is gel and has no entry. Ice made from tainted water is its
-- own item, because freezing is not filtering: what went in dirty comes out dirty.
CF.Meltwater = {
    ["TienCoolers.IceBag"] = "Water",
    ["TienCoolers.IceBagTainted"] = "TaintedWater",
}

-- fullType -> order of use, lowest first. The bags a bag of ice can be frozen in, which
-- have to be empty. Every vanilla item that shows up as a Plastic Bag counts, the grocery
-- bags that spawn full included, and garbage bags go last because they are worth more as
-- containers. Other mods may add their own.
CF.PlasticBags = {
    ["Base.Plasticbag"] = 1,
    ["Base.Plasticbag_Bags"] = 1,
    ["Base.Plasticbag_Clothing"] = 1,
    ["Base.GroceryBag1"] = 1,
    ["Base.GroceryBag2"] = 1,
    ["Base.GroceryBag3"] = 1,
    ["Base.GroceryBag4"] = 1,
    ["Base.GroceryBag5"] = 1,
    ["Base.GroceryBagGourmet"] = 1,
    ["Base.Garbagebag"] = 2,
    ["Base.Bag_TrashBag"] = 2,
}

-- What a spent bag of ice leaves behind when nobody recorded what it was frozen in: one
-- found in a freezer, or one made before bags were needed.
CF.PLASTIC_BAG = "Base.Plasticbag"

-- fullType -> true. Bags that behave as insulated coolers.
-- Other mods may add their own cooler bags to this table.
CF.CoolerBags = {
    ["Base.Cooler"] = true,
    ["Base.Cooler_Beer"] = true,
    ["Base.Cooler_Meat"] = true,
    ["Base.Cooler_Soda"] = true,
    ["Base.Cooler_Seafood"] = true,
}

-- Food.getFoodRotSpeed(), keyed by SandboxVars.FoodRotSpeed.
local ROT_SPEED = { 1.7, 1.4, 1.0, 0.7, 0.4 }

-- Food.getFridgeFactor(), keyed by SandboxVars.FridgeFactor (the "Refrigeration
-- Effectiveness" sandbox option). Vanilla applies this to powered fridges *and*
-- freezers; a cooler is measured as a fraction of it.
local FRIDGE_FACTOR = { 0.4, 0.3, 0.2, 0.1, 0.03, 0.0 }

-- ISInventoryPane tints a row blue whenever getHeat() < 1, at the strength of
-- getInvHeat() = 1 - (heat - 0.2) / 0.8. A powered fridge sets 0.2, so ice matches it
-- and a cooler reads a shade warmer.
CF.ICE_HEAT = 0.2
CF.COOLER_HEAT = 0.35

local MAX_NESTING = 3

function CF.opt(name, default)
    local vars = SandboxVars and SandboxVars.TienCoolers
    if not vars then return default end
    local v = vars[name]
    if v == nil then return default end
    return v
end

function CF.worldHours()
    return GameTime.getInstance():getWorldAgeHours()
end

function CF.foodRotSpeed()
    local v = SandboxVars and SandboxVars.FoodRotSpeed
    return ROT_SPEED[v] or 1.0
end

function CF.fridgeFactor()
    local v = SandboxVars and SandboxVars.FridgeFactor
    return FRIDGE_FACTOR[v] or 0.2
end

-- "Cooling Strength" is how much of a working fridge's cooling a cooler manages, so the
-- rot rate is read off the line between no cooling at all and whatever the player's
-- Refrigeration Effectiveness gives a real fridge: 1 makes the two equal, the default 0.5
-- gets a cooler half way there, 0 leaves food to rot as though the box were empty. The
-- slider stops at 1, so a box of melting ice can never beat a machine and there is no
-- hidden floor to make the setting lie about what it does. Reading it against the fridge
-- also means the mod follows a modded or dialled-down refrigeration game for free.
function CF.coolFactor()
    local strength = CF.opt("CoolStrength", 0.5)
    if strength < 0.0 then strength = 0.0 end
    if strength > 1.0 then strength = 1.0 end
    return 1.0 - strength * (1.0 - CF.fridgeFactor())
end

-- Ice melts faster in a Kentucky summer than in a January cold snap.
function CF.tempMult()
    local temp = 20.0
    local cm = getClimateManager()
    if cm then
        local ok, t = pcall(function() return cm:getTemperature() end)
        if ok and t then temp = t end
    end
    local m = 0.5 + temp / 40.0
    if m < 0.2 then m = 0.2 end
    if m > 2.0 then m = 2.0 end
    return m
end

function CF.isCoolerBag(item)
    return item ~= nil and CF.CoolerBags[item:getFullType()] == true
end

-- Returns the cooling power of item if it is a cold source, otherwise nil.
function CF.icePower(item)
    if not item then return nil end
    local ft = item:getFullType()
    local power = CF.IceSources[ft]
    if power then return power end

    if ft == "Base.Coldpack" and CF.opt("UseColdpacks", true) then
        power = CF.opt("ColdpackPower", 0.4)
        -- Nil rather than zero: a zero-power cold source is still a cold source
        -- everywhere else in here, and consumeIce divides by the power to work out how
        -- much of a bag it spent. Turning the strength down to nothing means off.
        if power and power > 0 then return power end
    end
    return nil
end

-- Bags of ice are drainables so the vanilla UI shows how much is left; anything else
-- (a Coldpack, say) carries its charge in modData.
--
-- A drainable cannot hold the real number, though. B42 keeps the charge as an integer
-- count of uses - setCurrentUsesFloat is `uses = round(f / useDelta)`, and
-- getCurrentUsesFloat hands back `uses * useDelta` - so at the bag's UseDelta of 0.02 the
-- field only holds fiftieths. A pass one game minute long melts about 0.0003 of a bag,
-- which rounds straight back to the use it started on. Every pass. So ice in a cooler
-- you are carrying, ticked every game minute, never melts at all, while the same bag
-- left on the floor - ticked rarely, and five times faster - empties normally, and in
-- multiplayer the two copies drift until the bag reads full in your hands and empty the
-- moment you set it down.
--
-- So the exact charge is ours, in modData, and the item's own field is the display of
-- it. If something outside this mod moves that field - a fresh copy streamed from the
-- server, a player using the item - it disagrees by more than rounding can explain, and
-- the item wins.
function CF.getCharge(item)
    local md = item:getModData()

    if instanceof(item, "DrainableComboItem") then
        local shown = item:getCurrentUsesFloat()
        local exact = md.tcCharge
        if exact == nil then return shown end

        local step = item:getUseDelta()
        if step == nil or step <= 0 then step = 1.0 end
        -- Rounding can never account for a whole step, so anything past that is somebody
        -- else's doing.
        if math.abs(shown - exact) > step then return shown end
        return exact
    end

    if md.tcCharge == nil then md.tcCharge = 1.0 end
    return md.tcCharge
end

-- The charge, without telling anyone. The server uses this for what a client reports
-- about its own bags, where sending the number straight back would be worse than
-- useless: ItemStatsPacket applies a drainable's charge as `(int)(maxUses * usedDelta)`,
-- which truncates, and at several charges (0.98, 0.92, 0.8 among them) that lands a whole
-- use below the one sent. CF.getCharge reads a gap of more than a step as a correction, so
-- the client's bag can lose a use each time the server answers it.
function CF.storeCharge(item, value)
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end

    item:getModData().tcCharge = value

    if instanceof(item, "DrainableComboItem") then
        item:setUsedDelta(value)   -- the bar the player sees, to the nearest use
    end
    return value
end

function CF.setCharge(item, value)
    value = CF.storeCharge(item, value)

    if instanceof(item, "DrainableComboItem") then
        CF.syncCharge(item)
    else
        CF.syncModData(item)
    end
    return value
end

-- True on the machine allowed to create an item, or to change how much fluid one holds,
-- anywhere at all: the server, or the game itself offline. In B42 sendAddItemToContainer
-- and sendItemStats only do anything on a server, so a plastic bag a client hands back or
-- water a client pours into a bottle exists on that client alone. The server never has it
-- and never saves it, and moving the thing later asks the server for an item it does not
-- know about.
function CF.mayCreate()
    return not isClient()
end

-- Whether clearing this spent bag away is the server's job wherever it is. It is when
-- something has to happen along with the removal that only a server can do: a plastic bag
-- to hand back, or the last of the meltwater to pour (see CF.settleIce). A client that
-- removed the ice itself, which B42 would let it do, would leave the server with no bag
-- of ice to notice was spent, and neither would ever happen.
--
-- With those options off and no plastic bag owed, nothing comes of the removal but the
-- removal, and it stays with whoever owns the container, exactly as before 1.5.0.
function CF.serverClearsIce(item)
    return CF.opt("NeedPlasticBags", false) == true
        or CF.meltwaterEnabled()
        or type(item:getModData().tcWrap) == "string"
end

-- Clear a spent bag of ice away and give back the bag it was frozen in, if one is owed.
--
-- A spent bag left in place is inert: its charge is zero, so it cools nothing and reads
-- as empty. Whoever may clear it does so on their next pass, and when that is the server
-- and the bag is in a client's hands, it is never more than a few seconds.
function CF.destroyIce(item)
    local container = item:getContainer()
    if not container then return end
    if CF.serverClearsIce(item) then
        if not CF.mayCreate() then return end
    elseif not CF.mayTransfer(container) then
        return
    end

    local wrapper = nil
    if CF.Meltwater[item:getFullType()] then
        wrapper = item:getModData().tcWrap
        if type(wrapper) ~= "string" and CF.opt("NeedPlasticBags", false) then
            wrapper = CF.PLASTIC_BAG
        end
    end

    CF.removeItem(container, item)
    if type(wrapper) == "string" then CF.addItem(container, wrapper) end
end

-- Pull an item's temperature down to `target`, never up: something just out of a freezer
-- stays as cold as it was. Vanilla lerps heat back towards the surrounding container
-- every update, so this is re-applied each pass and food warms up on its own once it
-- leaves the cooler or the ice runs out.
function CF.chill(item, target)
    if not CF.opt("ShowColdTint", true) then return end
    if not (instanceof(item, "Food") or instanceof(item, "DrainableComboItem")) then return end
    if item:getHeat() > target then
        item:setHeat(target)
    end
end

-- A fridge or a freezer, whether or not it is running. Kept apart from the powered
-- check so the context menu can tell "this is not the right kind of container" from
-- "this is the right container and the power is out" - the second is a silent failure
-- otherwise, and looks exactly like the mod not working.
local function isColdContainer(inventory)
    if not inventory then return false end
    return inventory:isFridge() == true or inventory:isFreezer() == true
end
CF.isColdContainer = isColdContainer

local function containerIsCold(inventory)
    if not isColdContainer(inventory) then return false end
    return inventory:isPowered() == true
end
CF.containerIsCold = containerIsCold

--[[ Multiplayer ]]

-- The model is vanilla's. Food.updateAge() is never sent over the wire: every machine
-- recomputes it from a timestamp on the item (lastAged) plus state everyone already
-- agrees on - world time, whether the container is a powered fridge, the sandbox
-- settings - so all copies land on the same number without anyone being authoritative.
-- This mod works the same way. A pass is (state, elapsed time) in, new state out, so
-- every machine runs it against its own copy of a container and they converge. Nothing
-- has to be pushed, which is why a cooler on the floor updates live on the screen of
-- whoever is looking at it.
--
-- Only real transfers need one machine to decide, because two machines each doing one
-- means two of the item: creating bags of ice out of water, in particular. Those are
-- gated on CF.mayTransfer and otherwise left to the server, which clients nudge (see
-- CF.processAddress and TienCooler_Server.lua) so its copy - the one that gets saved -
-- keeps up and the transfers actually happen.
--
-- What a player carries is the one place that model is not enough. The server's copy of
-- a carried cooler is the one that gets saved when the player logs out, and B42 moves
-- items on the server and sends the result back, so taking a steak out of the cooler
-- hands the player the server's steak. That copy has to hold the carrying client's
-- numbers, not merely numbers worked out the same way, so the client reports them and
-- the server writes them in. See CF.reportCarried and onCarried in TienCooler_Server.lua.
--
-- Nothing below needs an isClient() guard: the vanilla send*/sync* helpers are no-ops
-- offline, which is how vanilla itself calls them.

-- Set by the server while it acts on a client's request, so the helpers below know
-- which connection to answer. nil everywhere else.
CF.syncPlayer = nil

local function syncingPlayer()
    return CF.syncPlayer or getSpecificPlayer(0)
end

-- A drainable's remaining charge rides along with the item's stats.
function CF.syncCharge(item)
    sendItemStats(item)
end

-- So does what is left in a fluid container, which is how the vanilla fill and empty
-- actions push a jug's new level out. Without this the water drawn off to make ice
-- disappears only on the machine that did the drawing: every other client keeps drawing
-- a full bucket until something else makes it re-read the item, and picking it up then
-- reveals it was empty all along.
function CF.syncFluid(item)
    sendItemStats(item)
end

-- Item modData does not travel on its own; a Coldpack keeps its charge there.
function CF.syncModData(item)
    local player = syncingPlayer()
    if player then syncItemModData(player, item) end
end

-- Custom names (the "(Iced)" suffix) live in the item's fields.
function CF.syncFields(item)
    local player = syncingPlayer()
    if player then
        syncItemFields(player, item)
    else
        item:syncItemFields()
    end
end

function CF.addItem(container, fullType)
    local item = container:AddItem(fullType)
    if item then sendAddItemToContainer(container, item) end
    return item
end

function CF.removeItem(container, item)
    container:Remove(item)
    sendRemoveItemFromContainer(container, item)
end

-- A cooler inside a backpack inside your inventory resolves to your inventory.
local function outermostContainer(inventory)
    for _ = 1, MAX_NESTING + 1 do
        local item = inventory:getContainingItem()
        if not item then break end
        local parent = item:getContainer()
        if not parent then break end
        inventory = parent
    end
    return inventory
end

-- True when this machine may add or remove items here. Everyone computes; only the
-- machine that owns a container is allowed to change what is in it.
function CF.mayTransfer(inventory)
    return CF.ownsContainer(inventory)
end

-- The player carrying this container, if one is, however deep it is buried: a cooler
-- inside a backpack on someone's back answers with that someone.
function CF.carryingPlayer(inventory)
    if not inventory then return nil end
    local parent = outermostContainer(inventory):getParent()
    if not parent or not instanceof(parent, "IsoPlayer") then return nil end
    return parent
end

-- True when this machine is the one whose writes to `inventory` will be kept.
function CF.ownsContainer(inventory)
    if not inventory then return false end

    local carrier = CF.carryingPlayer(inventory)

    -- On a client, what its own player carries and nothing else.
    if isClient() then
        return carrier ~= nil and carrier:isLocalPlayer() == true
    end

    -- Offline every container is this machine's, and on a server so is everything out
    -- in the world - but not what a *remote* player is carrying. That client ticks its
    -- own bags (see TienCooler_Client.lua) and the server ticks its copy of them too,
    -- which is fine for a computation and is two of the item for a transfer. The pass
    -- converges without anyone being authoritative; only adding and removing has to be
    -- one machine's job, and there it is the machine holding the bag.
    if carrier and isServer() and not carrier:isLocalPlayer() then return false end
    return true
end

-- Item containers cannot travel over the wire, but "the third container of the second
-- object at x,y,z" can. Returns nil for a container the server cannot look up again,
-- which includes the loot window's floor list (a UI-only container).
function CF.addressContainer(inventory)
    if not inventory then return nil end

    local part = inventory:getVehiclePart()
    if part then
        local vehicle = inventory:getVehicle()
        if not vehicle then return nil end
        return { v = vehicle:getId(), p = part:getId() }
    end

    -- Ask this before the parent: dropping a bag wraps it in an IsoWorldInventoryObject
    -- and calls IsoObject.setContainer, which makes that object the container's parent.
    -- So a bag on the ground does have a parent, it just is not one of the square's
    -- objects - it is one of its world objects, named by item id instead. Bags held by
    -- a player have no world item and fall through, as does the loot window's floor
    -- list, which has no containing item at all.
    local held = inventory:getContainingItem()
    if held and held:hasWorldItem() then
        return CF.addressGroundItem(held)
    end

    local parent = inventory:getParent()
    if not parent then return nil end

    local square = parent:getSquare()
    if not square then return nil end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        if objects:get(i) == parent then
            return { x = square:getX(), y = square:getY(), z = square:getZ(),
                     o = i, c = parent:getContainerIndex(inventory) }
        end
    end
    return nil
end

-- The same for a single item lying on the ground, which is how a loose bag of ice or
-- a jug of water set down outside is named.
function CF.addressGroundItem(item)
    if not (item and item:hasWorldItem()) then return nil end
    -- Not item:getSquare(): that one answers with the square of the character holding
    -- the item, so it is nil for exactly the case this function exists for. The world
    -- object an item on the ground is drawn as is the thing that knows where it lies.
    local ground = item:getWorldItem():getSquare()
    if not ground then return nil end
    return { x = ground:getX(), y = ground:getY(), z = ground:getZ(), g = item:getID() }
end

function CF.resolveGroundItem(address)
    if type(address) ~= "table" or not address.g then return nil end
    local square = getSquare(address.x, address.y, address.z)
    if not square then return nil end

    local dropped = square:getWorldObjects()
    for i = 0, dropped:size() - 1 do
        local item = dropped:get(i):getItem()
        if item and item:getID() == address.g then return item end
    end
    return nil
end

-- The other half of addressContainer, run on the server against its own world.
function CF.resolveContainer(address)
    if type(address) ~= "table" then return nil end

    if address.v then
        local vehicle = getVehicleById(address.v)
        if not vehicle then return nil end
        local part = vehicle:getPartById(address.p)
        return part and part:getItemContainer() or nil
    end

    if not (address.x and address.y and address.z) then return nil end
    local square = getSquare(address.x, address.y, address.z)
    if not square then return nil end

    if address.g then
        local item = CF.resolveGroundItem(address)
        if item and item:IsInventoryContainer() then return item:getInventory() end
        return nil
    end

    if not (address.o and address.c) then return nil end
    local objects = square:getObjects()
    local index = math.floor(address.o)
    if index < 0 or index >= objects:size() then return nil end
    return objects:get(index):getContainerByIndex(math.floor(address.c))
end

--[[ Food ageing ]]

-- Hand back part of the ageing the game applied to this item since we last saw it.
-- `dt` bounds how much of that ageing can have happened inside the cooler, so an item
-- dropped into a full cooler cannot claim credit for rotting it did on a shelf.
function CF.ageFood(item, factor, dt, rotSpeed, coolerId)
    if not instanceof(item, "Food") then return end

    -- The game does not age food as time passes. It ages food when something asks it
    -- to, from a timestamp on the item, and in single player the only thing that ever
    -- asks is ISInventoryPane - once a frame, for whichever container that window
    -- happens to be drawing:
    --
    --     if instanceof(item, 'InventoryItem') then item:updateAge() end
    --
    -- (Food.update() does the same, but only `if (GameServer.server)`.) So a cabbage in
    -- a cooler holds its age for as long as nobody looks and then jumps the whole gap in
    -- one frame when the player opens their inventory. That lump lands inside a single
    -- pass of ours, and a pass may only rebate the sliver of rot that could have
    -- happened since the pass before it - so an hour of rot arriving in a one-minute
    -- pass was rebated one minute's worth and the other fifty-nine were kept. A cooler
    -- preserved nothing at all unless the player sat with the inventory window open.
    --
    -- So ask for the catch-up here, before measuring. The game's clock for this item is
    -- then our clock, `aged` is exactly this interval's worth of rot, and the cap below
    -- goes back to meaning what it says. It is the same call the inventory pane makes,
    -- so nothing new happens to the item - it just happens on time.
    item:updateAge()

    local md = item:getModData()
    local age = item:getAge()
    local prev = md.tcAge

    -- Rotten food has nothing left to save, but only food that was rotten the last time we
    -- looked. A player back from a few days away brings the whole absence in one lump, and
    -- when that lump carries a steak past its rotten mark, asking isRotten() now would skip
    -- the rebate that should have kept it short of the mark: the steak stays rotten for good.
    local wasRotten = item:isRotten() and not (prev ~= nil and prev < item:getOffAgeMax())

    if item:isFrozen() or wasRotten or item:getOffAgeMax() >= 1000000000 then
        md.tcAge = age
        md.tcCooler = coolerId
        return
    end

    if prev == nil or md.tcCooler ~= coolerId or age < prev then
        md.tcAge = age
        md.tcCooler = coolerId
        return
    end

    local aged = age - prev
    if aged > 0 and factor < 1.0 then
        local cap = dt * rotSpeed / 24.0
        local cooled = aged < cap and aged or cap
        age = prev + (aged - cooled) + cooled * factor
        item:setAge(age)
        -- Food.age is a float and this is a Lua double, so read back what the item
        -- actually kept. Noting the number we meant to write instead leaves the two a
        -- rounding apart, and next pass that difference is measured as rot.
        age = item:getAge()
    end

    md.tcAge = age
    md.tcCooler = coolerId
end

--[[ Ice ]]

-- A melted bag of ice refreezes in a freezer, whether or not anything caught its water.
-- Water that did run out into a bottle is the exception: that is gone from the bag for
-- good, and tcDrained is how much of a bagful it has been. Without it a player could let
-- a bag half melt into a bottle, refreeze it to full for nothing and do it again, which
-- is a freezer that makes water.
--
-- Nothing drained is the default, so a bag from before this existed refreezes exactly as
-- it always did.
function CF.iceCapacity(item)
    local drained = item:getModData().tcDrained
    if type(drained) ~= "number" or drained <= 0 then return 1.0 end
    if drained >= 1.0 then return 0.0 end
    return 1.0 - drained
end

-- Refreeze a cold source for `dt` hours, never past what it still holds.
function CF.refreeze(item, dt)
    local charge = CF.getCharge(item)
    local cap = CF.iceCapacity(item)
    local frozen = charge + dt / CF.opt("FreezeHours", 7.0)
    if frozen > cap then frozen = cap end
    if frozen < charge then frozen = charge end
    CF.setCharge(item, frozen)
end

-- Spend `amount` ice units across the bags in the cooler, emptiest bag first, and return
-- how much of a bagful each one melted, for CF.settleIce. A bag that runs out is left at
-- zero for CF.settleIce too, which pours the last of its water before it clears it away.
local function consumeIce(iceItems, amount)
    local melts = {}
    for _, entry in ipairs(iceItems) do
        if amount <= 0 then break end
        local charge = CF.getCharge(entry.item)
        local available = charge * entry.power
        local taken = available < amount and available or amount
        amount = amount - taken
        local left = charge - taken / entry.power
        if left <= 0.0001 then left = 0 end
        CF.setCharge(entry.item, left)
        melts[#melts + 1] = { item = entry.item, amount = charge - left }
    end
    return melts
end

--[[ Catching meltwater ]]

-- A container in a cooler can be set to catch the water from the ice melting beside it.
-- The mark is the player's choice, so it lives on the item like the freezing mark, and
-- it only means anything inside a cooler: CF.processItem clears it anywhere else, so a
-- bottle taken out and put back has to be set again.
function CF.isCatching(item)
    return item:getModData().tcCatch == true
end

-- Off unless the sandbox turns it on, like everything 1.5.0 added.
function CF.meltwaterEnabled()
    return CF.opt("CatchMeltwater", false) == true
end

function CF.canCatchMeltwater(item)
    if not CF.meltwaterEnabled() then return false end
    if not item or CF.icePower(item) then return false end
    local container = item:getContainer()
    local holder = container and container:getContainingItem()
    if not (holder and CF.isCoolerBag(holder)) then return false end
    local fc = item:getFluidContainer()
    local water = Fluid and Fluid.Water
    return fc ~= nil and water ~= nil and fc:canAddFluid(water) == true
end

-- CF.syncModData only reaches anyone from the server, so on a client this is local and
-- the mark travels by the setCatching command instead (see TienCooler_Client.lua).
function CF.startCatching(item)
    item:getModData().tcCatch = true
    CF.syncModData(item)
end

function CF.stopCatching(item)
    item:getModData().tcCatch = nil
    CF.syncModData(item)
end

-- Run what one bag has just melted, `water` bagfuls of it, into the catching containers,
-- in the order they sit in the cooler, as far as they have room.
--
-- Only water melting right now is poured. What melted with nothing set to catch it, and
-- what finds no room, is lost: setting a bottle later does not bring back water that
-- melted before it. The bag can still refreeze that part, since nothing ran out of it.
local function pourMeltwater(bag, water, catchers)
    if water <= 0.0001 then return end

    local name = CF.Meltwater[bag:getFullType()]
    if not name then return end                 -- a cold pack is gel, not water
    local fluid = Fluid and Fluid[name]
    if not fluid then return end

    local perBag = CF.opt("WaterPerBag", 5.0)
    local owed = water * perBag
    for _, catcher in ipairs(catchers) do
        if owed <= 0.0001 then break end
        local fc = catcher:getFluidContainer()
        if fc and fc:canAddFluid(fluid) then
            local room = fc:getFreeCapacity()
            local poured = room < owed and room or owed
            if poured > 0 then
                fc:addFluid(fluid, poured)
                CF.syncFluid(catcher)
                owed = owed - poured
            end
        end
    end

    local ran = water - owed / perBag
    if ran > 0 then
        local md = bag:getModData()
        md.tcDrained = (type(md.tcDrained) == "number" and md.tcDrained or 0) + ran
    end
end

-- Pour what just melted in one cooler into whatever is catching it, then clear away the
-- bags with nothing left frozen in them. Pouring changes what the server keeps, so only a
-- server pours (CF.mayCreate), and a client sees the water arrive when the server's pass
-- sends it. Clearing away follows CF.destroyIce.
--
-- `melts` is a list of { item, amount }, how much of a bagful each bag melted in the pass
-- being settled. Nil for a pass that melted nothing: a cooler in a freezer, or the first
-- look at one.
function CF.settleIce(inventory, melts)
    if not inventory then return end

    local bags, catchers = {}, {}
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if CF.icePower(item) then
            bags[#bags + 1] = item
        elseif CF.isCatching(item) and item:getFluidContainer() then
            catchers[#catchers + 1] = item
        end
    end

    if melts and #catchers > 0 and CF.meltwaterEnabled() and CF.mayCreate() then
        for _, melt in ipairs(melts) do pourMeltwater(melt.item, melt.amount, catchers) end
    end

    -- CF.destroyIce decides who may clear each one.
    for _, bag in ipairs(bags) do
        if CF.getCharge(bag) <= 0.0001 then CF.destroyIce(bag) end
    end
end

-- Melt or refreeze a cold source that is not sitting in a cooler.
function CF.tickIce(item, isCold)
    local md = item:getModData()
    local now = CF.worldHours()
    local last = md.tcLast

    -- The gap since the last look belongs to where the item *was* through it, not to
    -- wherever it happens to be at this instant. Without that, a bag pulled out of a
    -- freezer nobody had ticked for a day has a day of melting applied the moment it
    -- lands in your hands - and a bag only lives about nine hours outside, so it is
    -- destroyed on the way out of the freezer that was keeping it.
    local wasCold = md.tcCold
    if wasCold == nil then wasCold = isCold end

    md.tcLast = now
    md.tcCold = isCold

    if CF.getCharge(item) > 0 then
        CF.chill(item, CF.ICE_HEAT)
    end

    if last == nil or now <= last then return end

    local dt = now - last
    local charge = CF.getCharge(item)

    if wasCold then
        CF.refreeze(item, dt)
        return
    end

    local life = CF.opt("IceLifeHours", 48.0) * CF.opt("IceLifeOutsideMult", 0.2)
    if life <= 0 then life = 1 end
    charge = charge - dt * CF.tempMult() / life
    if charge <= 0 then
        CF.setCharge(item, 0)
        CF.destroyIce(item)
    else
        CF.setCharge(item, charge)
    end
end

--[[ Turning water into ice ]]

-- Fluids a bag of ice can be made out of, by name rather than by object: this file is
-- loaded before the game will necessarily hand one over, and a name this build does not
-- have has to be skipped rather than becoming a nil in the middle of the list. Other
-- mods may add their own.
--
-- Tainted water counts. A bottle filled from a rain barrel or a lake is tainted in B42,
-- and refusing those silently, with no menu entry and no reason given, reads exactly like
-- the mod not working. With the TaintedIce sandbox option on it makes a Bag of Ice
-- (Tainted), which melts back into tainted water; off, an ordinary one. Purified water is Fluid.Water already;
-- purifying converts it.
CF.FreezableFluids = { "Water", "TaintedWater" }

-- Any of these in a container makes all of its water tainted, however little there is.
CF.TaintedFluids = { "TaintedWater" }

local function containsAny(fc, names)
    for _, name in ipairs(names) do
        local fluid = Fluid and Fluid[name]
        if fluid and fc:contains(fluid) then return true end
    end
    return false
end

local function fluidIsFreezable(fc)
    return containsAny(fc, CF.FreezableFluids)
end

function CF.isTaintedWater(fc)
    return fc ~= nil and containsAny(fc, CF.TaintedFluids)
end

-- The empty bags in a container that a bag of ice could be frozen in, the ones to use
-- first at the front. Nil when the sandbox says no bag is needed.
function CF.emptyPlasticBags(inventory)
    if not CF.opt("NeedPlasticBags", false) then return nil end

    local found = {}
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local order = CF.PlasticBags[item:getFullType()]
        if order and item:IsInventoryContainer() then
            local inside = item:getInventory()
            if inside and inside:getItems():size() == 0 then
                found[#found + 1] = { item = item, order = order, index = i }
            end
        end
    end
    -- Stable on the container's own order, so every machine picks the same bag.
    table.sort(found, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.index < b.index
    end)
    return found
end

function CF.canFreezeWater(item)
    if not item then return false end
    local fc = item:getFluidContainer()
    if not fc then return false end
    if not fluidIsFreezable(fc) then return false end
    -- Any amount will do: what is marked in one fridge pools, so a glass that could
    -- never make a bag on its own still counts towards one.
    return fc:getAmount() > 0
end

function CF.isFreezingWater(item)
    return item:getModData().tcFreezing == true
end

-- The mark is the one piece of this mod's state a player can see in a menu, so it has
-- to reach the other machines. CF.syncModData is server-only, so on a client these are
-- purely local and the flag travels by the setFreezing command instead (see
-- TienCooler_Client.lua); on the server it goes straight out to everyone nearby.
function CF.startFreezingWater(item)
    local md = item:getModData()
    md.tcFreezing = true
    md.tcFreezeStart = CF.worldHours()
    CF.syncModData(item)
end

function CF.stopFreezingWater(item)
    local md = item:getModData()
    md.tcFreezing = nil
    md.tcFreezeStart = nil
    CF.syncModData(item)
end

-- Called for every item in a powered fridge/freezer. Water marked for freezing turns
-- into bags of ice once it has sat there long enough.
-- Marked water that is no longer in the cold is forgotten, so it cannot be marked in a
-- freezer, carried around and dropped back in to finish instantly. The making of the
-- ice itself happens a level up, in processFreezing, because it pools.
function CF.tickFreezing(item, isCold)
    local md = item:getModData()
    if not md.tcFreezing then return end

    if not isCold then
        CF.stopFreezingWater(item)
        return
    end

    local now = CF.worldHours()
    if md.tcFreezeStart == nil or md.tcFreezeStart > now then
        md.tcFreezeStart = now
    end
end

-- What is pooled for freezing in one container and how far along it is. Nothing in the
-- mod needs this; the player does. Water set to freeze changes nothing visible until a
-- bag appears hours later, so without it an empty freezer looks the same whether the
-- mod is working, the water is short of a bagful, or nothing was ever marked at all.
-- Returns the pooled amount, what one bag costs, the hours the newest of it still has to
-- wait, and how many empty plastic bags are in there to freeze it in (nil when none are
-- needed).
function CF.freezeProgress(inventory)
    local now = CF.worldHours()
    local wait = CF.opt("FreezeHours", 7.0)
    local pooled, remaining = 0.0, 0.0

    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local md = item:getModData()
        if md.tcFreezing then
            local fluid = item:getFluidContainer()
            local amount = fluid and fluid:getAmount() or 0
            if amount > 0 then
                pooled = pooled + amount
                local left = wait - (now - (md.tcFreezeStart or now))
                if left < 0 then left = 0 end
                if left > remaining then remaining = left end
            end
        end
    end

    local bags = CF.emptyPlasticBags(inventory)
    return pooled, CF.opt("WaterPerBag", 5.0), remaining, bags and #bags or nil
end

-- Take up to `owed` units from the entries, emptiest first, noting on each how much was
-- taken. Returns what is still owed.
local function drawWater(entries, owed)
    table.sort(entries, function(a, b) return a.left < b.left end)
    for _, entry in ipairs(entries) do
        if owed <= 0.0001 then break end
        local taken = entry.left < owed and entry.left or owed
        entry.left = entry.left - taken
        owed = owed - taken
    end
    return owed
end

-- Water freezes by the container, not by the bottle. Everything marked for freezing in
-- one fridge pools, so three glasses add up to a bag of ice where none of them could
-- make one alone, and a bucket that holds two bags' worth still gives two.
--
-- Clean and tainted water pool apart. Clean water makes clean bags first; whatever clean
-- water is left short of a bag then joins the tainted water, and the bags that makes are
-- tainted. So nothing freezes into fewer bags than it did before tainted ice existed, and
-- clean water only turns dirty when there was not enough of it for a clean bag.
function CF.processFreezing(inventory, isCold)
    local now = CF.worldHours()
    local wait = CF.opt("FreezeHours", 7.0)
    local ready, pool = {}, 0.0
    local cleanPool, taintedPool = 0.0, 0.0

    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local md = item:getModData()
        if md.tcFreezing then
            if not isCold then
                CF.stopFreezingWater(item)
            else
                if md.tcFreezeStart == nil or md.tcFreezeStart > now then
                    md.tcFreezeStart = now
                end
                local fluid = item:getFluidContainer()
                local amount = fluid and fluid:getAmount() or 0
                if amount > 0 and now - md.tcFreezeStart >= wait then
                    -- With tainted ice switched off, all water freezes into ordinary ice
                    -- and pools together, as it did before 1.5.0.
                    local tainted = CF.opt("TaintedIce", false) == true
                        and CF.isTaintedWater(fluid)
                    ready[#ready + 1] = { item = item, fluid = fluid, amount = amount,
                                          left = amount, tainted = tainted }
                    pool = pool + amount
                    if tainted then
                        taintedPool = taintedPool + amount
                    else
                        cleanPool = cleanPool + amount
                    end
                elseif not fluid then
                    CF.stopFreezingWater(item)      -- nothing to freeze in there
                else
                    -- Still waiting. Say so again: a client that walked out of range and
                    -- back has a freshly streamed copy of this item, and modData does not
                    -- ride along with one, so without this its menu offers "Freeze Into
                    -- Ice" on water that is already freezing - and taking that offer
                    -- restarts the clock. Server-only, and only for water actually
                    -- waiting, so it costs nothing anywhere else.
                    CF.syncModData(item)
                end
            end
        end
    end

    local perBag = CF.opt("WaterPerBag", 5.0)
    if math.floor(pool / perBag) < 1 then return end

    -- Making the ice is a transfer, not a computation: if every machine that can see
    -- this fridge made bags there would be a bag per machine. Leave it for whoever owns
    -- the container, which on a client is the server that a nudge will bring round to
    -- it, and keep the water marked until then.
    if not CF.mayTransfer(inventory) then return end

    -- Every bag of ice needs an empty plastic bag to freeze in, when the sandbox says so.
    -- Short of bags the water just keeps waiting, already frozen as long as it needs to
    -- be, and turns into ice the moment a bag is put in with it.
    local wrappers = CF.emptyPlasticBags(inventory)
    local limit = wrappers and #wrappers or math.huge

    local cleanBags = math.floor(cleanPool / perBag)
    if cleanBags > limit then cleanBags = limit end
    local taintedBags = 0
    if taintedPool > 0 then
        local leftover = cleanPool - cleanBags * perBag
        taintedBags = math.floor((leftover + taintedPool) / perBag)
        if taintedBags > limit - cleanBags then taintedBags = limit - cleanBags end
    end
    if cleanBags + taintedBags < 1 then return end

    -- Draw from the emptiest first, so the little containers come out empty rather than
    -- every one of them being left with a dribble. Tainted bags use the tainted water
    -- first and top up with clean.
    local clean, tainted = {}, {}
    for _, entry in ipairs(ready) do
        if entry.tainted then tainted[#tainted + 1] = entry else clean[#clean + 1] = entry end
    end
    drawWater(clean, cleanBags * perBag)
    local short = drawWater(tainted, taintedBags * perBag)
    if short > 0.0001 then drawWater(clean, short) end

    for _, entry in ipairs(ready) do
        local taken = entry.amount - entry.left
        if taken > 0 then
            entry.fluid:removeFluid(taken)
            CF.syncFluid(entry.item)
            if entry.left <= 0.0001 then
                CF.stopFreezingWater(entry.item)
            else
                entry.item:getModData().tcFreezeStart = now   -- the next bag takes as long
                CF.syncModData(entry.item)
            end
        end
    end

    local made = 0
    local function makeBags(fullType, count)
        for _ = 1, count do
            local wrapper = nil
            if wrappers then
                made = made + 1
                wrapper = wrappers[made].item
                CF.removeItem(inventory, wrapper)
            end
            local bag = CF.addItem(inventory, fullType)
            if bag then
                CF.setCharge(bag, 1.0)
                local md = bag:getModData()
                md.tcLast = now
                -- The bag comes back as the kind it went in as, so a garbage bag is not
                -- quietly traded down for a grocery bag.
                if wrapper then md.tcWrap = wrapper:getFullType() end
            end
        end
    end
    makeBags(CF.ICE_BAG, cleanBags)
    makeBags(CF.ICE_BAG_TAINTED, taintedBags)
end

--[[ Coolers ]]

local function coolerId(coolerItem)
    local md = coolerItem:getModData()
    if not md.tcId then
        md.tcId = tostring(ZombRand(2000000000)) .. "-" .. tostring(ZombRand(2000000000))
    end
    return md.tcId
end

local ICED_KEY = "IGUI_TienCoolers_Iced"

-- A dedicated server has no translations loaded for a modded key, and the name it
-- writes is the one every client then reads, so fall back to plain English rather than
-- stamping the raw key onto the item. A label written by the server is in the server's
-- language for everyone: unavoidable, since the label lives in the item's name.
local function icedSuffix()
    return " " .. (getTextOrNull(ICED_KEY) or "(Iced)")
end

-- Names already carrying a label have to be recognised so they can be repaired rather
-- than labelled twice, including ones stamped with the raw key by an older version.
local function stripLabel(name)
    for _, suffix in ipairs({ icedSuffix(), " " .. ICED_KEY }) do
        if #name > #suffix and string.sub(name, -#suffix) == suffix then
            return string.sub(name, 1, #name - #suffix)
        end
    end
    return name
end

function CF.updateCoolerName(coolerItem, iced)
    -- Switching the option off has to fall through to the unlabelling branch, otherwise
    -- a cooler that is already labelled keeps its suffix for the rest of the save.
    if not CF.opt("RenameCoolers", true) then
        iced = false
    end

    -- The name on the item decides, never a flag in its modData: modData travels with
    -- an item across the wire and the custom name does not always follow, so a copy can
    -- arrive claiming to be labelled while reading "Cooler". Reading the name back also
    -- leaves a cooler the player has renamed themselves alone.
    local name = coolerItem:getName()
    local base = stripLabel(name)
    local wanted = iced and (base .. icedSuffix()) or base

    -- Older versions kept this state in modData. The name is the truth now.
    local md = coolerItem:getModData()
    md.tcNamed, md.tcBaseName = nil, nil

    if name ~= wanted then
        coolerItem:setName(wanted)
        CF.syncFields(coolerItem)
    end
end

-- Melt the ice in one cooler and roll back the rot it prevented.
function CF.processCooler(coolerItem, isCold)
    local inventory = coolerItem:getInventory()
    if not inventory then return end

    local id = coolerId(coolerItem)
    local md = coolerItem:getModData()
    local now = CF.worldHours()
    local last = md.tcLast
    md.tcLast = now

    local contents = {}
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        contents[#contents + 1] = list:get(i)
    end

    local iceItems, totalIce = {}, 0.0
    for _, item in ipairs(contents) do
        local power = CF.icePower(item)
        if power then
            -- So it does not melt twice once taken out, and so that whoever ticks it
            -- next knows a cooler is not a freezer: the gap it spent in here was spent
            -- being used up, not being refilled - unless the cooler itself was in one.
            item:getModData().tcLast = now
            item:getModData().tcCold = isCold
            local charge = CF.getCharge(item)
            if charge > 0 then
                CF.chill(item, CF.ICE_HEAT)
                iceItems[#iceItems + 1] = { item = item, power = power }
                totalIce = totalIce + charge * power
            end
        end
    end

    CF.updateCoolerName(coolerItem, totalIce > 0)

    local dt = (last ~= nil and now > last) and (now - last) or 0
    if dt <= 0 then
        -- First sight of this cooler: take an ageing baseline, but show the chill now.
        for _, item in ipairs(contents) do
            CF.ageFood(item, 1.0, 0, 0, id)
            if totalIce > 0 and not CF.icePower(item) then
                CF.chill(item, CF.COOLER_HEAT)
            end
        end
        CF.settleIce(inventory, nil)
        return
    end

    -- Sitting in a powered fridge or freezer: the vanilla rot rules already apply to
    -- the food (getOutermostContainer walks past the cooler), so only recharge the ice.
    if isCold then
        for _, entry in ipairs(iceItems) do
            CF.refreeze(entry.item, dt)
        end
        for _, item in ipairs(contents) do
            CF.ageFood(item, 1.0, dt, 0, id)
        end
        CF.settleIce(inventory, nil)
        return
    end

    local coverage = 0.0
    local melts = nil
    if totalIce > 0 then
        local meltPerHour = CF.tempMult() / CF.opt("IceLifeHours", 48.0)
        local covered = totalIce / meltPerHour
        if covered > dt then covered = dt end
        coverage = covered / dt
        melts = consumeIce(iceItems, covered * meltPerHour)
    end

    local factor = coverage * CF.coolFactor() + (1.0 - coverage)
    local rotSpeed = CF.foodRotSpeed()
    -- Partly melted ice reads as a partial chill rather than snapping back to warm.
    local chillTarget = 1.0 - coverage * (1.0 - CF.COOLER_HEAT)
    for _, item in ipairs(contents) do
        CF.ageFood(item, factor, dt, rotSpeed, id)
        if coverage > 0 and not CF.icePower(item) then
            CF.chill(item, chillTarget)
        end
    end
    CF.settleIce(inventory, melts)
end

-- What the client carrying these coolers has worked out about them, as ids and numbers
-- so it survives the wire: for each cooler, the age of every piece of food in it and the
-- charge of every cold source. Run it after the pass, so every cooler has its id and
-- every number is the settled one. Coolers inside bags are found the same way the pass
-- finds them.
function CF.reportCarried(inventory, depth, coolers)
    coolers = coolers or {}
    depth = depth or 0
    if not inventory or depth > MAX_NESTING then return coolers end

    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if CF.isCoolerBag(item) then
            local tag = item:getModData().tcId
            local inside = item:getInventory()
            if tag and inside then
                local entries = {}
                local contents = inside:getItems()
                for j = 0, contents:size() - 1 do
                    local content = contents:get(j)
                    if CF.icePower(content) then
                        entries[#entries + 1] = { id = content:getID(), charge = CF.getCharge(content) }
                    elseif instanceof(content, "Food") then
                        entries[#entries + 1] = { id = content:getID(), age = content:getAge() }
                    end
                end
                coolers[#coolers + 1] = { id = item:getID(), tag = tag, items = entries }
            end
        elseif item:IsInventoryContainer() then
            CF.reportCarried(item:getInventory(), depth + 1, coolers)
        end
    end
    return coolers
end

--[[ Traversal ]]

-- Whether the pass currently running found anything this mod owns work for: a cooler, a
-- cold source, or water marked to freeze. A client uses it to decide whether the server
-- is worth nudging about a container, which is the difference between a packet for every
-- shelf, counter and cupboard in the room and a packet for the one that matters. The
-- walk visits all of it anyway, so this costs an increment.
local passWork = 0

local function noteWork()
    passWork = passWork + 1
end

-- Walk a container, cooling what needs cooling and melting what needs melting.
function CF.processContainer(inventory, isCold, depth)
    if not inventory then return end
    depth = depth or 0
    if depth > MAX_NESTING then return end

    local contents = {}
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        contents[#contents + 1] = list:get(i)
    end

    CF.processFreezing(inventory, isCold)

    for _, item in ipairs(contents) do
        CF.processItem(item, isCold, depth)
    end
end

-- Set by the server while it walks what a remote player carries. The coolers in there
-- are that player's client's to work out and report (see onCarried in
-- TienCooler_Server.lua), so the walk passes them by. nil everywhere else.
CF.leaveCoolers = nil

-- One item's worth of work. A cooler has to go through processCooler rather than have
-- its contents walked, or the ice inside it melts at the out-in-the-open rate and the
-- food inside it never gets its rot rebated.
function CF.processItem(item, isCold, depth)
    if CF.isCoolerBag(item) then
        noteWork()
        if not CF.leaveCoolers then CF.processCooler(item, isCold) end
    elseif CF.icePower(item) then
        noteWork()
        CF.tickIce(item, isCold)
    else
        local md = item:getModData()
        if md.tcFreezing then noteWork() end
        -- Everything in a cooler goes through processCooler instead, so anything reaching
        -- here has been taken out of one and is not catching anything any more.
        if md.tcCatch then CF.stopCatching(item) end
        CF.tickFreezing(item, isCold)
        -- getInventory() only exists on InventoryContainer; asking a plain item
        -- (an equipped belt, say) for one is an error, not a nil.
        if item:IsInventoryContainer() then
            local nested = item:getInventory()
            if nested then
                CF.processContainer(nested, isCold or containerIsCold(nested), (depth or 0) + 1)
            end
        end
    end
end

-- Returns whether the pass found anything worth another machine's attention.
function CF.processTopLevel(inventory)
    if not inventory then return false end
    passWork = 0

    -- The loot window gives a cooler bag its own container button, so this can be
    -- handed the inside of a cooler. Walking that as an ordinary container would melt
    -- the ice in it at the out-in-the-open rate and never label or rebate anything, so
    -- go back up to the cooler itself and process it as one.
    local held = inventory:getContainingItem()
    if held and CF.isCoolerBag(held) then
        local outer = held:getContainer()
        CF.processItem(held, outer ~= nil and containerIsCold(outer) or false, 0)
        return passWork > 0
    end

    CF.processContainer(inventory, containerIsCold(inventory), 0)
    return passWork > 0
end

-- What one machine can see of an item, so a client's view and the server's can be laid
-- side by side. Both halves of the mod print this for the same cooler.
function CF.describe(item)
    if not item then return "nothing" end

    local text = item:getFullType() .. "#" .. tostring(item:getID())
    local inventory = item:IsInventoryContainer() and item:getInventory() or nil
    if inventory then
        local contents, ice = {}, 0.0
        local list = inventory:getItems()
        for i = 0, list:size() - 1 do
            local content = list:get(i)
            contents[#contents + 1] = content:getFullType()
            local power = CF.icePower(content)
            if power then ice = ice + CF.getCharge(content) * power end
        end
        text = text .. string.format(" holding %d [%s] ice=%.2f",
            list:size(), table.concat(contents, " "), ice)
    end
    return text .. " named " .. tostring(item:getName())
end

-- What the server can see lying on a square, for when it cannot find what a client
-- asked about. Item ids are the one thing in an address that has to agree across the
-- wire, so print both sides of that comparison.
local function groundReport(address)
    local square = getSquare(address.x, address.y, address.z)
    if not square then return "no such square" end

    local seen, dropped = {}, square:getWorldObjects()
    for i = 0, dropped:size() - 1 do
        local item = dropped:get(i):getItem()
        seen[#seen + 1] = item and (item:getFullType() .. "#" .. tostring(item:getID())) or "?"
    end
    if #seen == 0 then return "square holds nothing" end
    return "square holds " .. table.concat(seen, ", ")
end

-- Run a pass on whatever a client's address names, and say what that was. Nothing on
-- the ground is ever cold: a powered fridge is an object, not a dropped item.
function CF.processAddress(address)
    if type(address) ~= "table" then return "not an address" end

    if address.g then
        local item = CF.resolveGroundItem(address)
        if not item then
            return string.format("item #%s not on the ground at %s,%s,%s - %s",
                tostring(address.g), tostring(address.x), tostring(address.y),
                tostring(address.z), groundReport(address))
        end
        local before = CF.describe(item)
        CF.processItem(item, false, 0)

        -- No attempt to push this back out. Nothing lying on the ground is in a
        -- container, and sendItemStats and syncItemFields both address an item by the
        -- container holding it, so neither can carry a dropped item's state. The one
        -- call that does reach a world object, transmitCompleteItemToClients, ADDS an
        -- object rather than updating one: clients end up with a second cooler beside
        -- the first, and the ghost cannot be picked up because the server has only
        -- ever had one. So the server keeps the true state - it is the copy that gets
        -- saved - and a client catches up when the item is streamed again or picked
        -- up, at which point its own pass reconciles the whole gap from the timestamp.
        return "ground " .. before .. " -> " .. CF.describe(item)
    end

    local container = CF.resolveContainer(address)
    if not container then
        return string.format("no container at %s,%s,%s object %s index %s",
            tostring(address.x), tostring(address.y), tostring(address.z),
            tostring(address.o), tostring(address.c))
    end
    CF.processTopLevel(container)
    return "container " .. tostring(container:getType())
end
