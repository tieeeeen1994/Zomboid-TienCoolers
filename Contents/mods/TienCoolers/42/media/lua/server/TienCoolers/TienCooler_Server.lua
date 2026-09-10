--[[
    Tien's Coolers - server driver.

    A client owns what its own player carries: it is the machine allowed to add and
    remove things there. Everything else - a freezer, a cooler on a shelf, a car trunk -
    is owned by the server, because only the server's copy of those items is the one
    that gets saved. Clients ask, this file does the work, and the results go back out
    through the same send*/sync* helpers the shared code uses everywhere else.

    Owning is not the same as ticking, though. The server keeps a copy of everything,
    including what players carry, and on a dedicated server that copy ages on its own
    (Food.update runs `if (GameServer.server)`). So the server runs the cooling pass
    over carried bags as well - not to be the authority on them, but so its copy holds
    the same numbers the carrying client's does. See tickCarried.

    OnClientCommand only fires for a remote client, so none of that half runs offline or
    on a co-op host's own actions; CF.ownsContainer already sends those two down the
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

--[[ What the players are carrying ]]

-- A client ticks its own bags and never asks the server about them, so until now the
-- server never looked at a carried cooler at all. On a dedicated server that is not the
-- same as nobody looking: Food.update() runs `if (GameServer.server)`, so the server's
-- copy of a steak in someone's cooler ages at the open-air rate the whole time, with
-- nothing rebating it, while the client's copy is being cooled properly. Two different
-- numbers for one steak, and the server's is the one that gets saved and re-sent - so
-- the moment the cooler leaves the player's hands, that number is the one that surfaces
-- and every hour of cooling is undone at once. Taking the cooler out of a bag and
-- dropping it on the floor is exactly that moment.
--
-- So the server ticks what players carry too. Nothing here is authoritative: it is the
-- same pass from the same timestamps as the client's, so the two copies land on the
-- same state, which is how the rest of this mod already works. Transfers stay the
-- carrying client's to make - CF.ownsContainer says so - because those are the one
-- thing two machines must not both do.
local CARRIED_MS = 10000
local lastCarried = nil

local function tickCarried()
    -- Offline and on a client the owner already does this, and only a server has other
    -- people's inventories to look at.
    if not isServer() then return end

    -- EveryOneMinute is an in-game minute - a couple of real seconds at the default day
    -- length - and this walks every online player's inventory, so it keeps a real clock
    -- of its own, exactly as the client's square sweep does. A pass is worked out from a
    -- timestamp, so this decides when the work happens, never how much of it happens.
    local now = getTimestampMs()
    if lastCarried and now - lastCarried < CARRIED_MS then return end
    lastCarried = now

    local players = getOnlinePlayers()
    if not players then return end

    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player then
            -- Answer on that player's own connection while we work on their bags.
            CF.syncPlayer = player
            CF.processTopLevel(player:getInventory())
            CF.syncPlayer = nil
        end
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
Events.EveryOneMinute.Add(tickCarried)
