--[[
    Tien's Coolers - loot.

    Bags of ice turn up wherever the pre-outbreak world kept them frozen: shop display
    freezers first, then household and garage chest freezers.
]]

require "Items/ProceduralDistributions"
require "TienCoolers/TienCooler_Shared"

local FREEZERS = {
    FreezerFrozenFood   = 10,
    FreezerIceCream     = 8,
    FreezerGeneric      = 3,
    FreezerHoarder      = 5,
    FreezerRich         = 3,
    FreezerGarage       = 4,
    FreezerFarmStorage  = 4,
    SafehouseFreezer    = 3,
    CrateChestFreezer   = 4,
}

local function addIceToFreezers()
    if not TienCoolers.opt("SpawnIceInLoot", true) then return end

    for listName, weight in pairs(FREEZERS) do
        local distribution = ProceduralDistributions.list[listName]
        if distribution and distribution.items then
            table.insert(distribution.items, "TienCoolers.IceBag")
            table.insert(distribution.items, weight)
        end
    end
end

Events.OnPreDistributionMerge.Add(addIceToFreezers)
