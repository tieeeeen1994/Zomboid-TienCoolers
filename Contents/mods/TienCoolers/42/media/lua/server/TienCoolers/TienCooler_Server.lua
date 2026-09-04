--[[
    Tien's Coolers - server driver.

    A client owns what its own player carries and ticks that itself. Everything else -
    a freezer, a cooler on a shelf, a car trunk - is owned by the server, because only
    the server's copy of those items is the one that gets saved. Clients ask, this
    file does the work, and the results go back out through the same send*/sync*
    helpers the shared code uses everywhere else.

    Nothing here runs offline or on a co-op host's own actions: OnClientCommand only
    fires for a remote client, and CF.ownsContainer already sends those two down the
    local path.
]]

require "TienCoolers/TienCooler_Shared"

local CF = TienCoolers

-- CF.startFreezingWater and CF.stopFreezingWater push the flag out themselves, so the
-- client that asked - and anyone else looking - sees it on its own copy and is offered
-- "Stop Freezing Into Ice" instead of "Freeze Into Ice".
local function onSetFreezing(container, args)
    local item = container:getItemWithID(args.item)
    if not item then return end

    if not args.on then
        CF.stopFreezingWater(item)
    elseif CF.isFreezingWater(item) then
        -- Already going. Asking again is a client working from a copy that had not heard
        -- yet, so answer it rather than restarting the clock and costing it the wait.
        CF.syncModData(item)
    else
        CF.startFreezingWater(item)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= "TienCoolers" then return end

    -- Answer on the requesting player's connection while we work.
    CF.syncPlayer = player
    if command == "tick" then
        CF.debug("tick from %s: %s",
            player and player:getUsername() or "?", CF.processAddress(args))
    elseif command == "setFreezing" then
        local container = CF.resolveContainer(args)
        if container then onSetFreezing(container, args) end
    elseif command == "version" then
        sendServerCommand(player, "TienCoolers", "version", { v = CF.VERSION })
    end
    CF.syncPlayer = nil
end

Events.OnClientCommand.Add(onClientCommand)
