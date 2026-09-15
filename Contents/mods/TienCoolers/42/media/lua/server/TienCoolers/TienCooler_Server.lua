--[[
    Tien's Coolers - server driver.

    A client owns what its own player carries: it is the machine allowed to add and
    remove things there. Everything else - a freezer, a cooler on a shelf, a car trunk -
    is owned by the server, because only the server's copy of those items is the one
    that gets saved. Clients ask, this file does the work, and the results go back out
    through the same send*/sync* helpers the shared code uses everywhere else.

    What a player carries is saved on the server too, though, and a transfer hands the
    player the server's copy of whatever moved. So the server keeps its copy of carried
    things current: loose ice and freezing marks by running the pass itself, and coolers
    by writing in what the carrying client reports. See tickCarried and onCarried.

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

-- The server holds a copy of everything a player carries, and that copy matters twice
-- over. It is the one written to the player database, so it is what the player gets back
-- when they log in again. And B42 moves items on the server: taking a steak out of a
-- cooler removes the server's steak from the server's cooler and sends it to the client,
-- which draws that one from then on. A copy that has fallen behind is invisible right up
-- until one of those moments, and then every hour of cooling it missed is undone at once.
--
-- Running the cooling pass here as well, from the same timestamps, was meant to keep it
-- level, and it did not hold up on a real server. The reported case: log out with food in
-- a carried cooler, stay away a few days, log back in. The food in the cooler looks right,
-- and the moment it is taken out it jumps as if it had never been cooled. Two machines
-- computing the same thing only agree while nothing else touches the bookkeeping they
-- compute from, and here something does. syncItemFields, which is how the (Iced) label
-- travels, sends the item's whole modData along, and the receiving side wipes its own and
-- takes the sender's, so every label change swaps one machine's cooler timestamps into
-- the other's copy. A login after a long absence, where the ice may well have run out and
-- both machines relabel the cooler at once, is where that is most likely to bite.
--
-- So the coolers a player carries are that player's client's to work out, and the client
-- tells the server the result every few seconds (CF.reportCarried). The server brings its
-- copy up to date and writes the reported numbers in, holding them to what a cooler could
-- actually have done, so a client cannot report its way to food that never rots or ice
-- that never melts. The rest of what a player carries, loose ice and water that was
-- marked to freeze, has no such race, and the server still ticks it itself.

-- A report is plain data off the wire. Anything that is not the shape we sent is ignored.
local function isNumber(v)
    return type(v) == "number" and v == v
end

-- The server's copy of a piece of food, set to what the client says it is now. The
-- client's figure is held between two limits. It can be no older than the server's own
-- copy brought up to date at the open-air rate, because a cooler only ever slows rot. And
-- it can take back no more rot than the best cooler could have saved since the server
-- last heard about this food, or, for food that has only just gone in, about this cooler.
-- After a login that interval is the whole absence, which is exactly what needs settling.
local function acceptAge(food, reported, tag, since, now)
    food:updateAge()
    local current = food:getAge()
    local md = food:getModData()

    local hours = 0
    local heard = md.tcReported
    if isNumber(heard) and heard <= now then
        hours = now - heard
    elseif isNumber(since) and since <= now then
        -- The cooler's timestamp can arrive from the client along with its label (see
        -- above), so food the server has never heard about gets no more than an hour.
        hours = math.min(now - since, 1.0)
    end
    local lowest = current - hours * CF.foodRotSpeed() / 24.0 * (1.0 - CF.coolFactor())

    -- Nor can food come back younger than it was last settled at. Frozen food is the case
    -- that needs saying: it does not age, so the limit above would otherwise reach back
    -- past where it already stood.
    local settled = md.tcAge
    if isNumber(settled) and settled <= current and settled > lowest then lowest = settled end

    local age = reported
    if age > current then age = current end
    if age < lowest then age = lowest end
    food:setAge(age)

    -- Written the way CF.ageFood writes them, so that the copy saved at logout is one the
    -- client's first pass after login can pick up from.
    md.tcAge = food:getAge()
    md.tcCooler = tag
    md.tcReported = now
end

-- Ice in a carried cooler only melts: nothing a player carries is sitting in a freezer.
-- So the client's charge is taken as long as it is no more than the server's copy holds.
local function acceptCharge(item, reported, now)
    local current = CF.getCharge(item)
    CF.storeCharge(item, reported < current and reported or current)
    local md = item:getModData()
    md.tcLast = now
    md.tcCold = false
end

local function onCarried(player, args)
    if not player or type(args) ~= "table" or type(args.coolers) ~= "table" then return end

    local now = CF.worldHours()
    local inventory = player:getInventory()
    for _, report in ipairs(args.coolers) do
        -- Looked up in this player's own inventory and nowhere else, so a report can only
        -- ever touch the reporting player's coolers.
        local cooler = type(report) == "table" and isNumber(report.id)
            and inventory:getItemWithIDRecursiv(report.id) or nil
        local inside = cooler and CF.isCoolerBag(cooler) and cooler:getInventory() or nil
        if inside and type(report.tag) == "string" and type(report.items) == "table" then
            local md = cooler:getModData()
            local since = md.tcLast
            md.tcId = report.tag
            md.tcLast = now

            for _, entry in ipairs(report.items) do
                -- Anything not found has just been moved, and the next report covers it.
                local item = type(entry) == "table" and isNumber(entry.id)
                    and inside:getItemWithID(entry.id) or nil
                if item then
                    if isNumber(entry.charge) and CF.icePower(item) then
                        acceptCharge(item, entry.charge, now)
                    elseif isNumber(entry.age) and instanceof(item, "Food") then
                        acceptAge(item, entry.age, report.tag, since, now)
                    end
                end
            end
        end
    end
end

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
            -- Answer on that player's own connection while we work on their bags, and
            -- leave their coolers to what their client reports. The flags are cleared even
            -- if the pass fails, because a leaveCoolers left set would stop the server
            -- cooling anything on the ground or in a fridge from then on.
            CF.syncPlayer, CF.leaveCoolers = player, true
            local ok, err = pcall(CF.processTopLevel, player:getInventory())
            CF.syncPlayer, CF.leaveCoolers = nil, nil
            if not ok then error(err) end
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
    elseif command == "carried" then
        onCarried(player, args)
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
