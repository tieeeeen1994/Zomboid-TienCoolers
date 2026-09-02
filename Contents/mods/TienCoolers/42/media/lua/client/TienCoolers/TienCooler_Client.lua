--[[
    Tien's Coolers - client driver.

    The player's own inventory is ticked here: the client owns what its player carries
    and transmits it, so a cooler on your back behaves the same offline and online.
    A container out in the world belongs to the server, so in multiplayer this file
    only asks for it to be ticked and TienCooler_Server.lua does the work. Offline and
    on a co-op host CF.ownsContainer is true for everything and nothing is sent.
]]

require "TienCoolers/TienCooler_Shared"

local CF = TienCoolers

-- The loot window rebuilds itself constantly, so requests for the same container are
-- rate limited. The server tick is idempotent - it works from a timestamp on the item
-- - so a dropped or duplicated request costs nothing either way.
local REQUEST_MS = 10000
local requested = {}
local requestCount = 0

local function addressKey(address)
    if address.v then return "v" .. address.v .. ":" .. address.p end
    if address.g then return "g" .. address.g end
    return address.x .. "," .. address.y .. "," .. address.z .. "," .. address.o .. "," .. address.c
end

local function request(player, address)
    if not address then return false end

    local key = addressKey(address)
    local now = getTimestampMs()
    local last = requested[key]
    if last and now - last < REQUEST_MS then return true end

    if requestCount > 256 then
        requested = {}
        requestCount = 0
    end
    requested[key] = now
    requestCount = requestCount + 1

    sendClientCommand(player, "TienCoolers", "tick", address)
    return true
end

-- Only the things the mod actually has work for, so a floor covered in loot does not
-- turn into a floor covered in packets.
local function worthTicking(item)
    return CF.isCoolerBag(item) or CF.icePower(item) ~= nil
        or item:getModData().tcFreezing == true
end

local function process(player, inventory)
    if not inventory then return end
    if CF.ownsContainer(inventory) then
        CF.processTopLevel(inventory)
        return
    end
    if not player then return end
    if request(player, CF.addressContainer(inventory)) then return end

    -- The loot window's floor list is built client side and has no address of its own,
    -- but a cooler or a bag of ice lying in it is a world object the server can find.
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if worthTicking(item) then
            request(player, CF.addressGroundItem(item))
        end
    end
end

local function onEveryOneMinute()
    for playerNum = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(playerNum)
        if player then
            CF.processTopLevel(player:getInventory())

            local loot = getPlayerLoot(playerNum)
            if loot and loot.backpacks then
                for _, containerButton in ipairs(loot.backpacks) do
                    process(player, containerButton.inventory)
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
    local player = getSpecificPlayer(window.player or 0)
    for _, containerButton in ipairs(window.backpacks) do
        process(player, containerButton.inventory)
    end
end

--[[ Context menu: freeze water into ice ]]

-- Water is frozen in a fridge or a freezer, which is a container the server owns in
-- multiplayer. The flag is still set locally so the menu updates at once, and sent on
-- so that the server is the one that eventually turns the water into ice.
local function setFreezing(player, items, on)
    for _, item in ipairs(items) do
        if on then
            CF.startFreezingWater(item)
        else
            CF.stopFreezingWater(item)
        end

        local container = item:getContainer()
        if player and container and not CF.ownsContainer(container) then
            local address = CF.addressContainer(container)
            if address then
                address.item = item:getID()
                address.on = on
                sendClientCommand(player, "TienCoolers", "setFreezing", address)
            end
        end
    end
end

local function onStartFreezing(player, items)
    setFreezing(player, items, true)
end

local function onStopFreezing(player, items)
    setFreezing(player, items, false)
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
    local player = getSpecificPlayer(playerNum)
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
        local option = context:addOption(getText("ContextMenu_TienCoolers_Freeze"), player,
            onStartFreezing, freezable)
        local tooltip = ISInventoryPaneContextMenu.addToolTip()
        tooltip.description = getText("Tooltip_TienCoolers_Freeze",
            round(CF.opt("FreezeHours", 6.0), 1), round(CF.opt("WaterPerBag", 1.0), 2))
        option.toolTip = tooltip
    end

    if #cancellable > 0 then
        context:addOption(getText("ContextMenu_TienCoolers_CancelFreeze"), player,
            onStopFreezing, cancellable)
    end
end

Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnRefreshInventoryWindowContainers.Add(onRefreshContainers)
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryContextMenu)
