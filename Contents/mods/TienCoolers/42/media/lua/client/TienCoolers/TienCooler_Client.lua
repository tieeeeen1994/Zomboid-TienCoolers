--[[
    Tien's Coolers - client driver.

    This ticks every container near the player, on a slow real-time clock, and whenever
    the loot window rebuilds. Not only the ones this machine owns: a pass is worked out from a
    timestamp on the item, so this client and the server each apply the same elapsed
    time to their own copy and agree without talking, exactly as vanilla does with food
    rot. That is what makes a cooler on the floor cool live on screen.

    The square sweep is what actually reaches world containers. The loot window's
    container list is a UI artefact - it is wiped and rebuilt from whatever that window
    happens to be showing - so hanging the only pass off it left a fridge or a freezer
    untouched for whole days at a time, and water set to freeze in one never finished.
    The sweep walks the squares around the player instead and asks the world directly.

    The server is nudged separately for containers this client does not own, so that
    its copy - the one that gets saved, and the only one allowed to turn water into ice
    - keeps up. Offline that nudge never happens and nothing changes.
]]

require "TienCoolers/TienCooler_Shared"

local CF = TienCoolers

-- The loot window rebuilds itself constantly, so requests for the same container are
-- rate limited. The server tick is idempotent - it works from a timestamp on the item
-- - so a dropped or duplicated request costs nothing either way.
local REQUEST_MS = 10000
local requested = {}
local requestCount = 0

-- Entries are dropped once they are older than the window they enforce, so the table
-- stays the size of "containers seen in the last ten seconds". Emptying it wholesale
-- instead - which is what this used to do once it passed a few hundred keys - lets
-- every container in range go again at once, and in a furnished room that is a burst of
-- packets and a burst of server-side passes every time the count rolls over.
local function prune(now)
    local kept = 0
    for key, when in pairs(requested) do
        if now - when >= REQUEST_MS then
            requested[key] = nil
        else
            kept = kept + 1
        end
    end
    requestCount = kept
end

local function addressKey(address)
    if address.v then return "v" .. address.v .. ":" .. address.p end
    if address.g then return "g" .. address.g end
    return address.x .. "," .. address.y .. "," .. address.z .. "," .. address.o .. "," .. address.c
end

local function request(player, address, item)
    if not address then return false end

    local key = addressKey(address)
    local now = getTimestampMs()
    local last = requested[key]
    if last and now - last < REQUEST_MS then return true end

    if requestCount > 256 then prune(now) end
    requested[key] = now
    requestCount = requestCount + 1

    sendClientCommand(player, "TienCoolers", "tick", address)
    CF.debug("asked the server to tick %s: I see %s", key,
        item and CF.describe(item) or "a container")
    return true
end

-- Only the things the mod actually has work for, so a floor covered in loot does not
-- turn into a floor covered in packets.
local function worthTicking(item)
    return CF.isCoolerBag(item) or CF.icePower(item) ~= nil
        or item:getModData().tcFreezing == true
end

-- Every container this client can see is ticked here, whoever owns it. The pass works
-- from a timestamp on the item, so this machine and the server each apply the same
-- elapsed time to their own copy and land on the same state: nothing is counted twice
-- and nothing has to be sent back, which is what makes a cooler on the floor update
-- live instead of waiting on a round trip.
--
-- The server still gets a nudge for anything this client does not own, because its
-- copy is the one that gets saved and it is the only machine allowed to turn water
-- into ice. That is a slow background correctness job, not what the player is watching.
local function process(player, inventory)
    if not inventory then return "empty" end

    local work = CF.processTopLevel(inventory)

    if not player or CF.ownsContainer(inventory) then return "mine" end

    -- Nothing in here for this mod, so nothing for the server to do about it either.
    -- Without this every cupboard, counter and shelf within reach costs a packet and a
    -- full pass on the server, ten seconds apart, forever.
    if not work then return "ticked, nothing to nudge" end

    if request(player, CF.addressContainer(inventory), inventory:getContainingItem()) then
        return "ticked, server nudged"
    end

    -- The loot window's floor list is built client side and has no address of its own,
    -- but a cooler or a bag of ice lying in it is a world object the server can find.
    local handed = 0
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if worthTicking(item) and request(player, CF.addressGroundItem(item), item) then
            handed = handed + 1
        end
    end
    if handed > 0 then return "ticked, floor nudged" end

    return "ticked, no nudge"
end

--[[ The square sweep ]]

-- How far from the player, in squares, world containers are ticked, and how often in
-- real time. A pass is worked out from a timestamp, so a container missed while the
-- player was away catches up in full the moment they come back within reach: these two
-- decide when the work happens, never how much of it happens. Keep them modest.
--
-- EveryOneMinute is an *in-game* minute, which at the default day length is about two
-- and a half seconds of real time - roughly twenty-four sweeps a real minute, and more
-- on a short day length. Sweeping every one of those is what turns a cheap idea into a
-- stutter, so the sweep runs on a real clock of its own.
local SWEEP_RADIUS = 1
local SWEEP_MS = 10000
local lastSweep = {}   -- by player number, so split screen is not one player's turn

-- Everything on one square: containers standing on it (a fridge has two, the fridge
-- and the freezer, and both need their own pass) and items dropped on it.
local function sweepSquare(player, square, seen, tally)
    if not square then return end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for index = 1, object:getContainerCount() do
            local container = object:getContainerByIndex(index - 1)
            if container and not seen[container] then
                seen[container] = true
                tally.containers = tally.containers + 1
                -- Only worth asking while tracing: isPowered() walks the square's
                -- neighbours, and this runs for every container within the radius.
                if CF.DEBUG and CF.containerIsCold(container) then
                    tally.cold = tally.cold + 1
                end
                process(player, container)
            end
        end
    end

    -- A cooler or a bag of ice set down on the floor is a world object rather than
    -- something inside a container, so it is never reached by the loop above.
    local dropped = square:getWorldObjects()
    for i = 0, dropped:size() - 1 do
        local item = dropped:get(i):getItem()
        if item and not seen[item] then
            seen[item] = true
            tally.dropped = tally.dropped + 1
            CF.processItem(item, false, 0)
            if worthTicking(item) then
                request(player, CF.addressGroundItem(item), item)
            end
        end
    end
end

local function sweepNearby(playerNum, player)
    local now = getTimestampMs()
    local last = lastSweep[playerNum]
    if last and now - last < SWEEP_MS then return end
    lastSweep[playerNum] = now

    local square = player:getCurrentSquare()
    local cell = getCell()
    if not (square and cell) then return end

    local x, y, z = square:getX(), square:getY(), square:getZ()
    local seen = {}
    local tally = { containers = 0, cold = 0, dropped = 0 }
    for dy = -SWEEP_RADIUS, SWEEP_RADIUS do
        for dx = -SWEEP_RADIUS, SWEEP_RADIUS do
            sweepSquare(player, cell:getGridSquare(x + dx, y + dy, z), seen, tally)
        end
    end

    CF.debug("sweep at %d,%d,%d: %d containers (%d powered cold), %d dropped items",
        x, y, z, tally.containers, tally.cold, tally.dropped)
end

--[[ Version handshake ]]

-- Half of this mod runs on the server, and a dedicated server only picks up a new
-- Workshop build when it restarts. A server left on an older build still accepts a
-- player who has the newer one, and the result reads exactly like a mod bug. Asking it
-- which build it is on settles that in one line - but it is a diagnostic, so it goes
-- through CF.DEBUG like the rest: nothing is asked and nothing is said unless someone
-- has turned tracing on. An older server has no handler for this and never answers,
-- which is itself the answer.
local handshake = { asked = false, heard = false, minutes = 0 }

local function checkServerVersion(player)
    if not isClient() or not CF.DEBUG then return end

    if not handshake.asked then
        handshake.asked = true
        sendClientCommand(player, "TienCoolers", "version", {})
        return
    end

    if handshake.heard then return end
    handshake.minutes = handshake.minutes + 1
    if handshake.minutes == 3 then
        CF.debug("the server has not answered a version check. It is probably running an "
            .. "older build of the mod - restart it to pick up %s. Until then coolers work "
            .. "in your inventory but not on the ground or in a fridge.", CF.VERSION)
    end
end

local function onServerCommand(module, command, args)
    if module ~= "TienCoolers" or command ~= "version" then return end
    handshake.heard = true

    if args.v == CF.VERSION then
        CF.debug("server and client are both on %s.", CF.VERSION)
    else
        CF.debug("version mismatch - server is on %s, this client is on %s. "
            .. "Restart the server to pick up the new build.", tostring(args.v), CF.VERSION)
    end
end

local function onEveryOneMinute()
    for playerNum = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(playerNum)
        if player then
            if playerNum == 0 then checkServerVersion(player) end
            CF.processTopLevel(player:getInventory())
            sweepNearby(playerNum, player)

            local loot = getPlayerLoot(playerNum)
            if loot and loot.backpacks then
                local counts, mine = {}, 0
                for _, containerButton in ipairs(loot.backpacks) do
                    local what = process(player, containerButton.inventory)
                    if what == "mine" then
                        mine = mine + 1
                    else
                        counts[what] = (counts[what] or 0) + 1
                    end
                end

                local parts = {}
                for _, key in ipairs({ "ticked, server nudged", "ticked, floor nudged",
                                       "ticked, no nudge", "empty" }) do
                    if counts[key] then parts[#parts + 1] = counts[key] .. " " .. key end
                end
                if #parts > 0 then
                    CF.debug("loot window: %d containers, %d mine, %s",
                        #loot.backpacks, mine, table.concat(parts, ", "))
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
            round(CF.opt("FreezeHours", 7.0), 1), round(CF.opt("WaterPerBag", 5.0), 2))
        option.toolTip = tooltip
    end

    if #cancellable > 0 then
        context:addOption(getText("ContextMenu_TienCoolers_CancelFreeze"), player,
            onStopFreezing, cancellable)
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnRefreshInventoryWindowContainers.Add(onRefreshContainers)
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryContextMenu)
