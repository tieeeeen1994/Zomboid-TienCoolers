--[[
    Tien's Coolers - shared core.

    Build 42 slows food rot only for containers whose parent IsoObject is a powered
    fridge/freezer (Food.updateAge -> isInFridge/isInFreezer + sourceGrid:haveElectricity).
    A cooler carried in your inventory has no parent object, so there is no vanilla hook
    to hang portable cooling on. Instead this mod measures how much the game aged each
    item since it last looked at it and gives part of that ageing back, which produces
    exactly the same result as a slower rot rate and needs no per-tick presence.
]]

TienCoolers = TienCoolers or {}
local CF = TienCoolers

CF.ICE_BAG = "TienCoolers.IceBag"

-- fullType -> cooling power, where 1.0 is one full bag of ice.
-- Other mods may add their own cold sources to this table.
CF.IceSources = {
    ["TienCoolers.IceBag"] = 1.0,
}

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
-- freezers; a cooler is never allowed to beat it.
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

-- A box of melting ice cannot preserve food better than a working fridge, so the
-- cooling strength is floored at whatever the player's Refrigeration Effectiveness
-- setting gives a real one. At the default settings (cooler 0.25, fridge 0.2) the
-- floor never bites; on a "Very Low" refrigeration game it stops the cooler from
-- quietly becoming the best fridge in Kentucky.
function CF.coolFactor()
    local factor = CF.opt("CoolFactor", 0.25)
    local fridge = CF.fridgeFactor()
    return factor > fridge and factor or fridge
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
    if ft == "Base.Coldpack" and CF.opt("UseColdpacks", true) then return 0.4 end
    return nil
end

-- Bags of ice are drainables so the vanilla UI shows how much is left; anything else
-- (a Coldpack, say) carries its charge in modData.
function CF.getCharge(item)
    if instanceof(item, "DrainableComboItem") then
        -- B42 dropped getUsedDelta(); getCurrentUsesFloat() is the same 0..1 fraction.
        return item:getCurrentUsesFloat()
    end
    local md = item:getModData()
    if md.tcCharge == nil then md.tcCharge = 1.0 end
    return md.tcCharge
end

function CF.setCharge(item, value)
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    if instanceof(item, "DrainableComboItem") then
        item:setUsedDelta(value)
        CF.syncCharge(item)
    else
        item:getModData().tcCharge = value
        CF.syncModData(item)
    end
    return value
end

function CF.destroyIce(item)
    local container = item:getContainer()
    if container then
        CF.removeItem(container, item)
    end
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

local function containerIsCold(inventory)
    if not inventory then return false end
    if not (inventory:isFridge() or inventory:isFreezer()) then return false end
    return inventory:isPowered()
end
CF.containerIsCold = containerIsCold

--[[ Multiplayer ]]

-- Every machine loads this file, so the mod has to agree on who may write to what.
-- Singleplayer and a co-op host are the authority for everything they can see. A
-- remote client is the authority only for what its own player carries: world
-- containers belong to the server, which is asked to tick them instead (see
-- TienCooler_Server.lua). Nothing below needs an isClient() guard - the vanilla
-- send*/sync* helpers are no-ops offline, which is how vanilla itself calls them.

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

-- True when this machine is the one whose writes to `inventory` will be kept.
function CF.ownsContainer(inventory)
    if not inventory then return false end
    if not isClient() then return true end
    local parent = outermostContainer(inventory):getParent()
    if not parent then return false end
    return instanceof(parent, "IsoPlayer") == true and parent:isLocalPlayer() == true
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

    local parent = inventory:getParent()
    if not parent then
        -- A cooler set down on the ground is its own world object: no parent object to
        -- hang off, so it is named by the square it lies on and the item's id. Bags
        -- held by a player fall through here and are left alone, as does the loot
        -- window's floor list, which has no containing item at all.
        return CF.addressGroundItem(inventory:getContainingItem())
    end

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

    local md = item:getModData()
    local age = item:getAge()

    if item:isFrozen() or item:isRotten() or item:getOffAgeMax() >= 1000000000 then
        md.tcAge = age
        md.tcCooler = coolerId
        return
    end

    local prev = md.tcAge
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
    end

    md.tcAge = age
    md.tcCooler = coolerId
end

--[[ Ice ]]

-- Spend `amount` ice units across the bags in the cooler, emptiest bag first.
local function consumeIce(iceItems, amount)
    for _, entry in ipairs(iceItems) do
        if amount <= 0 then break end
        local charge = CF.getCharge(entry.item)
        local available = charge * entry.power
        local taken = available < amount and available or amount
        amount = amount - taken
        local left = charge - taken / entry.power
        if left <= 0.0001 then
            CF.setCharge(entry.item, 0)
            CF.destroyIce(entry.item)
        else
            CF.setCharge(entry.item, left)
        end
    end
end

-- Melt or refreeze a cold source that is not sitting in a cooler.
function CF.tickIce(item, isCold)
    local md = item:getModData()
    local now = CF.worldHours()
    local last = md.tcLast
    md.tcLast = now

    if CF.getCharge(item) > 0 then
        CF.chill(item, CF.ICE_HEAT)
    end

    if last == nil or now <= last then return end

    local dt = now - last
    local charge = CF.getCharge(item)

    if isCold then
        CF.setCharge(item, charge + dt / CF.opt("FreezeHours", 6.0))
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

function CF.canFreezeWater(item)
    if not item then return false end
    local fc = item:getFluidContainer()
    if not fc then return false end
    if not fc:contains(Fluid.Water) then return false end
    return fc:getAmount() >= CF.opt("WaterPerBag", 1.0)
end

function CF.isFreezingWater(item)
    return item:getModData().tcFreezing == true
end

function CF.startFreezingWater(item)
    local md = item:getModData()
    md.tcFreezing = true
    md.tcFreezeStart = CF.worldHours()
end

function CF.stopFreezingWater(item)
    local md = item:getModData()
    md.tcFreezing = nil
    md.tcFreezeStart = nil
end

-- Called for every item in a powered fridge/freezer. Water marked for freezing turns
-- into bags of ice once it has sat there long enough.
function CF.tickFreezing(item, isCold)
    local md = item:getModData()
    if not md.tcFreezing then return end

    -- Taken back out of the freezer: forget about it.
    if not isCold then
        CF.stopFreezingWater(item)
        return
    end

    local now = CF.worldHours()
    if md.tcFreezeStart == nil or md.tcFreezeStart > now then
        md.tcFreezeStart = now
        return
    end
    if now - md.tcFreezeStart < CF.opt("FreezeHours", 6.0) then return end

    local fc = item:getFluidContainer()
    local container = item:getContainer()
    if not fc or not container then
        CF.stopFreezingWater(item)
        return
    end

    local perBag = CF.opt("WaterPerBag", 1.0)
    local bags = math.floor(fc:getAmount() / perBag)
    CF.stopFreezingWater(item)
    if bags < 1 then return end

    fc:removeFluid(bags * perBag)
    for _ = 1, bags do
        local bag = CF.addItem(container, CF.ICE_BAG)
        if bag then
            CF.setCharge(bag, 1.0)
            bag:getModData().tcLast = now
        end
    end
end

--[[ Coolers ]]

local function coolerId(coolerItem)
    local md = coolerItem:getModData()
    if not md.tcId then
        md.tcId = tostring(ZombRand(2000000000)) .. "-" .. tostring(ZombRand(2000000000))
    end
    return md.tcId
end

function CF.updateCoolerName(coolerItem, iced)
    -- Switching the option off has to fall through to the unlabelling branch, otherwise
    -- a cooler that is already labelled keeps its suffix for the rest of the save.
    if not CF.opt("RenameCoolers", true) then
        iced = false
    end

    local md = coolerItem:getModData()
    local suffix = " " .. getText("IGUI_TienCoolers_Iced")
    local name = coolerItem:getName()

    -- The name on the item decides, not the flag in its modData. modData travels with
    -- an item across the wire and the custom name does not always follow, so a copy can
    -- arrive claiming to be labelled while reading "Cooler"; trusting the flag would
    -- leave it that way for good. Reading the name back also keeps a cooler the player
    -- has renamed themselves intact.
    local labelled = #name > #suffix and string.sub(name, -#suffix) == suffix
    local base = labelled and string.sub(name, 1, #name - #suffix) or md.tcBaseName or name
    local wanted = iced and (base .. suffix) or base

    md.tcNamed = iced or nil
    md.tcBaseName = iced and base or nil

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
            item:getModData().tcLast = now -- so it does not melt twice once taken out
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
        return
    end

    -- Sitting in a powered fridge or freezer: the vanilla rot rules already apply to
    -- the food (getOutermostContainer walks past the cooler), so only recharge the ice.
    if isCold then
        for _, entry in ipairs(iceItems) do
            CF.setCharge(entry.item, CF.getCharge(entry.item) + dt / CF.opt("FreezeHours", 6.0))
        end
        for _, item in ipairs(contents) do
            CF.ageFood(item, 1.0, dt, 0, id)
        end
        return
    end

    local coverage = 0.0
    if totalIce > 0 then
        local meltPerHour = CF.tempMult() / CF.opt("IceLifeHours", 48.0)
        local covered = totalIce / meltPerHour
        if covered > dt then covered = dt end
        coverage = covered / dt
        consumeIce(iceItems, covered * meltPerHour)
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
end

--[[ Traversal ]]

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

    for _, item in ipairs(contents) do
        CF.processItem(item, isCold, depth)
    end
end

-- One item's worth of work. A cooler has to go through processCooler rather than have
-- its contents walked, or the ice inside it melts at the out-in-the-open rate and the
-- food inside it never gets its rot rebated.
function CF.processItem(item, isCold, depth)
    if CF.isCoolerBag(item) then
        CF.processCooler(item, isCold)
    elseif CF.icePower(item) then
        CF.tickIce(item, isCold)
    else
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

function CF.processTopLevel(inventory)
    if not inventory then return end
    CF.processContainer(inventory, containerIsCold(inventory), 0)
end

-- Run a pass on whatever a client's address names. Nothing on the ground is ever cold:
-- a powered fridge is an object, not a dropped item.
function CF.processAddress(address)
    if type(address) ~= "table" then return end

    if address.g then
        local item = CF.resolveGroundItem(address)
        if item then CF.processItem(item, false, 0) end
        return
    end

    CF.processTopLevel(CF.resolveContainer(address))
end
