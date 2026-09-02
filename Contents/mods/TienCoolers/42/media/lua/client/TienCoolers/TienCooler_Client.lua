--[[
    Tien's Coolers - client driver.

    Everything runs client side. Item state lives in modData and on the item itself,
    which is what the client already owns and transmits, so a dedicated server needs
    no extra work and nothing is applied twice.
]]

require "TienCoolers/TienCooler_Shared"

local CF = TienCoolers

local function onEveryOneMinute()
    for playerNum = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(playerNum)
        if player then
            CF.processTopLevel(player:getInventory())

            local loot = getPlayerLoot(playerNum)
            if loot and loot.backpacks then
                for _, containerButton in ipairs(loot.backpacks) do
                    if containerButton.inventory then
                        CF.processTopLevel(containerButton.inventory)
                    end
                end
            end
        end
    end
end

-- Fires whenever the loot window rebuilds its container list, which is the moment a
-- cooler left on the ground or a freezer full of water comes back into view.
local function onRefreshContainers(window, state)
    if state ~= "end" then return end
    if not window or not window.backpacks then return end
    for _, containerButton in ipairs(window.backpacks) do
        if containerButton.inventory then
            CF.processTopLevel(containerButton.inventory)
        end
    end
end

--[[ Context menu: freeze water into ice ]]

local function onStartFreezing(_, items)
    for _, item in ipairs(items) do
        CF.startFreezingWater(item)
    end
end

local function onStopFreezing(_, items)
    for _, item in ipairs(items) do
        CF.stopFreezingWater(item)
    end
end

local function collectItems(selected)
    local out = {}
    for _, entry in ipairs(selected) do
        if instanceof(entry, "InventoryItem") then
            out[#out + 1] = entry
        elseif entry.items then
            for _, item in ipairs(entry.items) do
                out[#out + 1] = item
            end
        end
    end
    return out
end

local function onFillInventoryContextMenu(playerNum, context, selected)
    local freezable, cancellable = {}, {}
    for _, item in ipairs(collectItems(selected)) do
        local container = item:getContainer()
        if container and CF.containerIsCold(container) then
            if CF.isFreezingWater(item) then
                cancellable[#cancellable + 1] = item
            elseif CF.canFreezeWater(item) then
                freezable[#freezable + 1] = item
            end
        end
    end

    if #freezable > 0 then
        local option = context:addOption(getText("ContextMenu_TienCoolers_Freeze"), nil,
            onStartFreezing, freezable)
        local tooltip = ISInventoryPaneContextMenu.addToolTip()
        tooltip.description = getText("Tooltip_TienCoolers_Freeze",
            round(CF.opt("FreezeHours", 6.0), 1), round(CF.opt("WaterPerBag", 1.0), 2))
        option.toolTip = tooltip
    end

    if #cancellable > 0 then
        context:addOption(getText("ContextMenu_TienCoolers_CancelFreeze"), nil,
            onStopFreezing, cancellable)
    end
end

Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnRefreshInventoryWindowContainers.Add(onRefreshContainers)
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryContextMenu)
