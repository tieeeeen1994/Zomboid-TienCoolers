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

local function onSetFreezing(container, args, player)
    local item = container:getItemWithID(args.item)
    if not item then return end

    if args.on then
        CF.startFreezingWater(item)
    else
        CF.stopFreezingWater(item)
    end
    -- So the client that asked (and anyone else looking) sees the flag on its own copy
    -- and offers "Cancel Freezing" instead of "Freeze Into Ice".
    syncItemModData(player, item)
end

local function onClientCommand(module, command, player, args)
    if module ~= "TienCoolers" then return end

    -- Answer on the requesting player's connection while we work.
    CF.syncPlayer = player
    if command == "tick" then
        CF.processAddress(args)
    elseif command == "setFreezing" then
        local container = CF.resolveContainer(args)
        if container then onSetFreezing(container, args, player) end
    end
    CF.syncPlayer = nil
end

Events.OnClientCommand.Add(onClientCommand)
