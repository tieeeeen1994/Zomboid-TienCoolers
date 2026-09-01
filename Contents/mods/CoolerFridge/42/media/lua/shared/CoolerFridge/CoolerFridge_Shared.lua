--[[
    Cooler Fridge - shared core.

    Build 42 slows food rot only for containers whose parent IsoObject is a powered
    fridge/freezer (Food.updateAge -> isInFridge/isInFreezer + sourceGrid:haveElectricity).
    A cooler carried in your inventory has no parent object, so there is no vanilla hook
    to hang portable cooling on. Instead this mod measures how much the game aged each
    item since it last looked at it and gives part of that ageing back, which produces
    exactly the same result as a slower rot rate and needs no per-tick presence.
]]

CoolerFridge = CoolerFridge or {}
local CF = CoolerFridge

CF.ICE_BAG = "CoolerFridge.IceBag"

-- fullType -> cooling power, where 1.0 is one full bag of ice.
-- Other mods may add their own cold sources to this table.
CF.IceSources = {
    ["CoolerFridge.IceBag"] = 1.0,
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

-- ISInventoryPane tints a row blue whenever getHeat() < 1, at the strength of
-- getInvHeat() = 1 - (heat - 0.2) / 0.8. A powered fridge sets 0.2, so ice matches it
-- and a cooler reads a shade warmer.
CF.ICE_HEAT = 0.2
CF.COOLER_HEAT = 0.35

local MAX_NESTING = 3

function CF.opt(name, default)
    local vars = SandboxVars and SandboxVars.CoolerFridge
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
        return item:getUsedDelta()
    end
    local md = item:getModData()
    if md.cfCharge == nil then md.cfCharge = 1.0 end
    return md.cfCharge
end

function CF.setCharge(item, value)
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    if instanceof(item, "DrainableComboItem") then
        item:setUsedDelta(value)
    else
        item:getModData().cfCharge = value
    end
    return value
end

function CF.destroyIce(item)
    local container = item:getContainer()
    if container then
        container:Remove(item)
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

--[[ Food ageing ]]

-- Hand back part of the ageing the game applied to this item since we last saw it.
-- `dt` bounds how much of that ageing can have happened inside the cooler, so an item
-- dropped into a full cooler cannot claim credit for rotting it did on a shelf.
function CF.ageFood(item, factor, dt, rotSpeed, coolerId)
    if not instanceof(item, "Food") then return end

    local md = item:getModData()
    local age = item:getAge()

    if item:isFrozen() or item:isRotten() or item:getOffAgeMax() >= 1000000000 then
        md.cfAge = age
        md.cfCooler = coolerId
        return
    end

    local prev = md.cfAge
    if prev == nil or md.cfCooler ~= coolerId or age < prev then
        md.cfAge = age
        md.cfCooler = coolerId
        return
    end

    local aged = age - prev
    if aged > 0 and factor < 1.0 then
        local cap = dt * rotSpeed / 24.0
        local cooled = aged < cap and aged or cap
        age = prev + (aged - cooled) + cooled * factor
        item:setAge(age)
    end

    md.cfAge = age
    md.cfCooler = coolerId
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
    local last = md.cfLast
    md.cfLast = now

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
    return item:getModData().cfFreezing == true
end

function CF.startFreezingWater(item)
    local md = item:getModData()
    md.cfFreezing = true
    md.cfFreezeStart = CF.worldHours()
end

function CF.stopFreezingWater(item)
    local md = item:getModData()
    md.cfFreezing = nil
    md.cfFreezeStart = nil
end

-- Called for every item in a powered fridge/freezer. Water marked for freezing turns
-- into bags of ice once it has sat there long enough.
function CF.tickFreezing(item, isCold)
    local md = item:getModData()
    if not md.cfFreezing then return end

    -- Taken back out of the freezer: forget about it.
    if not isCold then
        CF.stopFreezingWater(item)
        return
    end

    local now = CF.worldHours()
    if md.cfFreezeStart == nil or md.cfFreezeStart > now then
        md.cfFreezeStart = now
        return
    end
    if now - md.cfFreezeStart < CF.opt("FreezeHours", 6.0) then return end

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
        local bag = container:AddItem(CF.ICE_BAG)
        if bag then
            CF.setCharge(bag, 1.0)
            bag:getModData().cfLast = now
        end
    end
end

--[[ Coolers ]]

local function coolerId(coolerItem)
    local md = coolerItem:getModData()
    if not md.cfId then
        md.cfId = tostring(ZombRand(2000000000)) .. "-" .. tostring(ZombRand(2000000000))
    end
    return md.cfId
end

function CF.updateCoolerName(coolerItem, iced)
    local md = coolerItem:getModData()
    -- Switching the option off has to fall through to the cleanup branch, otherwise a
    -- cooler that is already labelled keeps its suffix for the rest of the save.
    if not CF.opt("RenameCoolers", true) then
        iced = false
    end
    if iced then
        if md.cfNamed then return end
        md.cfBaseName = coolerItem:getName()
        coolerItem:setName(md.cfBaseName .. " " .. getText("IGUI_CoolerFridge_Iced"))
        md.cfNamed = true
    elseif md.cfNamed then
        if md.cfBaseName then coolerItem:setName(md.cfBaseName) end
        md.cfNamed = nil
        md.cfBaseName = nil
    end
end

-- Melt the ice in one cooler and roll back the rot it prevented.
function CF.processCooler(coolerItem, isCold)
    local inventory = coolerItem:getInventory()
    if not inventory then return end

    local id = coolerId(coolerItem)
    local md = coolerItem:getModData()
    local now = CF.worldHours()
    local last = md.cfLast
    md.cfLast = now

    local contents = {}
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        contents[#contents + 1] = list:get(i)
    end

    local iceItems, totalIce = {}, 0.0
    for _, item in ipairs(contents) do
        local power = CF.icePower(item)
        if power then
            item:getModData().cfLast = now -- so it does not melt twice once taken out
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

    local factor = coverage * CF.opt("CoolFactor", 0.25) + (1.0 - coverage)
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
        if CF.isCoolerBag(item) then
            CF.processCooler(item, isCold)
        elseif CF.icePower(item) then
            CF.tickIce(item, isCold)
        else
            CF.tickFreezing(item, isCold)
            local nested = item:getInventory()
            if nested then
                CF.processContainer(nested, isCold or containerIsCold(nested), depth + 1)
            end
        end
    end
end

function CF.processTopLevel(inventory)
    if not inventory then return end
    CF.processContainer(inventory, containerIsCold(inventory), 0)
end
