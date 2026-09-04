# Tien's Coolers, implementation notes

How the mod works against the Build 42 API, how the art is generated, and how other
mods can extend it. The player-facing description lives in the [readme](../README.md).

## How it works

Build 42 slows food rot in exactly one place. `Food.updateAge()` checks whether the item's
outermost container is a fridge or freezer whose *parent world object* sits on a square with
electricity:

```java
} else if (this.isInFridge(cont) || this.isInFreezer(cont)) {
    if (cont.getSourceGrid() != null && cont.getSourceGrid().haveElectricity()) {
        delta *= this.getFridgeFactor();
    }
```

A cooler carried in your inventory has no parent object and no source grid, so there is no
vanilla hook to hang portable cooling on, and marking the cooler's container as a fridge
does nothing. Setting `ItemContainer.setCustomTemperature()` does not help either, because
`getOutermostContainer()` walks past the cooler up to the player's inventory.

So the mod measures instead of predicting. Each pass it records `item:getAge()` in modData,
and on the next pass hands back part of the ageing the game applied in between:

```lua
local aged = age - prev
local cap  = dt * rotSpeed / 24.0      -- most that could have happened in the cooler
local cooled = math.min(aged, cap)
item:setAge(prev + (aged - cooled) + cooled * factor)
```

That produces exactly the same result as a slower rot rate, needs no per-tick presence, and
self-corrects across unloaded chunks and long absences, since the game catches the item up
when it reloads and the next pass rebates the right share of it.

### Vanilla sandbox options

`SandboxVars.FoodRotSpeed` and `SandboxVars.FridgeFactor` are both read straight out of
`Food`, so the mod tracks the player's own settings instead of assuming defaults:

| FoodRotSpeed | 1 Very Fast | 2 Fast | 3 Normal | 4 Slow | 5 Very Slow |
|---|---|---|---|---|---|
| `getFoodRotSpeed()` | 1.7 | 1.4 | 1.0 | 0.7 | 0.4 |

| FridgeFactor | 1 Very Low | 2 Low | 3 Normal | 4 High | 5 Very High | 6 No decay |
|---|---|---|---|---|---|---|
| `getFridgeFactor()` | 0.4 | 0.3 | 0.2 | 0.1 | 0.03 | 0.0 |

The rot speed bounds the rebate (`cap = dt * rotSpeed / 24`). The fridge factor is a
*floor* on `CoolFactor`: a box of melting ice must never preserve food better than a
working fridge does. At stock settings the floor never bites, because a cooler's 0.25 sits
just behind a fridge's 0.2, but on a Very Low refrigeration game the cooler is pulled back to
0.4 alongside it rather than quietly becoming the best fridge in Kentucky.

### The blue tint

`ISInventoryPane` tints an item's row blue whenever `getHeat() < 1`, at the strength of
`Food.getInvHeat()` = `1 - (heat - 0.2) / 0.8`. A powered fridge produces that by returning
`0.2` from `ItemContainer.getTemprature()`, which `Food.updateAge()` lerps the item's heat
towards, but again only via `getOutermostContainer()`, which walks past a carried cooler.

So the mod clamps `setHeat()` directly: `0.2` for ice (matching a freezer, full-strength
blue) and `0.35` for the cooler's contents, scaled by how much of the interval the ice
actually covered. It only ever pulls heat *down*, so something straight out of a freezer is
not warmed up, and once the ice is gone the mod stops touching heat and vanilla thaws the
food on its own.

### Why the food is not renamed

`Food.getName()` composes the display name in Java from item state, joining the parts with
`", "` and formatting them through `IGUI_FoodNaming` (`"%2 (%1)"`), giving `Steak (Frozen)` or
`Steak (Cooked, Frozen)`. That `(Frozen)` is gated on `isFrozen()`, which only accrues in a
*powered freezer*; food in a working fridge gets the blue tint and no suffix at all.

A cooler is a fridge, not a freezer, so the mod follows the same convention: contents are
tinted, never renamed. It also avoids writing to each food item's stored `name`, which would
survive uninstalling the mod. Only the cooler bag itself is labelled `(Iced)`, and that label
is stripped again when the ice runs out or the sandbox option is switched off.

## Layout

```
Contents/mods/TienCoolers/42/
  mod.info, icon.png, poster.png
  media/
    sandbox-options.txt                        sandbox page + 9 options
    scripts/TienCooler_items.txt               IceBag item + its ground model
    textures/Item_TienCoolerIceBag.png         32x32 inventory icon
    textures/WorldItems/TienCoolerIceBag.png   256x256 world model texture
    lua/shared/TienCoolers/                    cooling, melting and freezing logic
    lua/client/TienCoolers/                    event driver + context menu
    lua/server/TienCoolers/                    freezer loot + the world-container driver
    lua/shared/Translate/EN/                   ItemName / Tooltip / ContextMenu / IG_UI / Sandbox
```

The logic itself lives in `shared` and runs on whichever machine owns the container it is
looking at. State lives in item modData and in the drainable's used-delta.

Three things drive a pass, and the order matters:

| driver | what it reaches |
| --- | --- |
| `EveryOneMinute` -> the player's own inventory | coolers and ice you are carrying |
| `EveryOneMinute` -> a sweep of the squares around the player | fridges, freezers, crates, car trunks, anything set down on the floor |
| `OnRefreshInventoryWindowContainers` | whatever the loot window just rebuilt, so opening a container shows it up to date at once |

The sweep is deliberately cheap, because `EveryOneMinute` is an *in-game* minute - about
two and a half real seconds at the default day length, less on a short one. Three things
keep it that way, and all three matter:

- it runs on a **real** clock of its own (`SWEEP_MS`, ten seconds), not on the event that
  triggers it;
- the radius is **1**, the same reach the player has;
- a pass reports whether it found anything of this mod's (`CF.processTopLevel` returns
  it), and a client only nudges the server about containers where it did. Otherwise every
  cupboard, counter and shelf in the room costs a packet and a full server-side pass every
  ten seconds - which is a mod making a room stutter, not a mod keeping ice cold.

None of this changes the outcome, only when the work happens: a container missed while
the player was away settles the whole gap on the next sweep that reaches it.

The square sweep is the one that matters for world containers, and it exists because
hanging that job off the loot window alone did not work. `ISInventoryPage.backpacks` is a
UI artefact: it is wiped and rebuilt from whatever that window happens to be showing, so a
freezer could go days without a single pass, and water marked to freeze in one sat there
for good. The sweep asks `getCell():getGridSquare` for the squares within
`SWEEP_RADIUS`, walks `getObjects()` for containers standing on them (a fridge has two,
the fridge and the freezer, and each needs its own pass) and `getWorldObjects()` for items
dropped on them. Because a pass is worked out from a timestamp, the radius decides *when*
the work happens and never *how much* of it happens: a freezer missed while the player was
away settles the entire gap the moment they walk back within it.

## Multiplayer

The model is vanilla's. `Food.updateAge()` is never sent over the wire: every machine
recomputes it from a `lastAged` timestamp on the item plus state everyone already agrees
on - world time, whether the container is a powered fridge, the sandbox settings - so all
copies land on the same number without anyone being authoritative. That is why a vanilla
fridge needs no synchronisation to work in multiplayer.

This mod does the same thing. A pass is `(state, elapsed time)` in, new state out, keyed
off `tcLast`, so every machine runs it against its own copy of a container and they
converge. A client ticks **every** container it can see, including ones it does not own,
and nothing is pushed back - which is what makes a cooler on the floor cool live on the
screen of whoever is looking at it, and what gives each player the *(Iced)* label in their
own language. Ticking the same copy twice in one moment is a no-op, so a client and a
server both ticking never counts the time twice. The sim asserts exactly this: two
machines, the same elapsed hours, the same resulting ice, rot and name.

Only real transfers need one machine to decide, because two machines each doing one means
two of the item:

| what | who |
| --- | --- |
| cooling, melting, refreezing, rot rebate, the label | every machine, on its own copy |
| turning water into bags of ice | whoever owns the container (`CF.mayTransfer`) |
| adding and removing items generally | the owner: your own inventory, else the server |

A client that sees water finish freezing in a base freezer therefore leaves the flag set
and makes nothing; the server does it, and the new bag arrives by the ordinary container
packets. What does **not** arrive by itself is everything the server changed on an item
that was already there, so each of those is pushed by hand:

| what changed | pushed by | why it has to be |
| --- | --- | --- |
| water drawn out of a jug to make a bag | `CF.syncFluid` -> `sendItemStats` | the packet carries the fluid container; without it a client draws a full bucket until something makes it re-read the item, and picking it up reveals it was empty all along |
| the freezing mark, set or cleared | `CF.syncModData` -> `syncItemModData` | modData does not ride along with a streamed item |
| the mark, while the water is still waiting | the same, once per pass | a client that walked out of range and back has a *fresh* copy with no modData on it. Nothing changed, so no change can announce it; the owner simply says it again |

That last one is why the menu is right after a walk. It also protects the wait: a client
working from a copy that had not heard yet offers *Freeze Into Ice*, and `onSetFreezing`
answers a repeat ask with the current state rather than restarting the clock. Clients nudge the server every ten seconds per container they do not own
(`sendClientCommand` -> `CF.processAddress`) so the copy that gets saved keeps up and those
transfers happen. That nudge is a background correctness job, not what the player is
watching: if it never arrives, the screen is still right and only the saved state lags.

Containers cannot travel over the wire, so `CF.addressContainer` names one as "the *n*th
container of the object at x,y,z" (or a vehicle id and part id) and `CF.resolveContainer`
looks it back up on the other side. Something set down on the ground has no parent object
to hang off, so `CF.addressGroundItem` names it by its square and item id instead and the
server finds it again in `square:getWorldObjects()`. The loot window's floor list is built
client-side and has no address of its own, so a client that meets it walks it and asks for
the coolers and cold sources lying in it one at a time.

A ground address names an *item*, not a container, which matters: a cooler has to go
through `CF.processCooler` rather than have its contents walked, or the ice inside it melts
at the out-in-the-open rate and the food inside it never gets its rot rebated.
`CF.processItem` is the one item's worth of work that both paths share, and
`CF.processAddress` is the single entry point the server uses for either kind of address.

Two things about dropped items are easy to get wrong, and both cost a round of "it does
nothing on the ground":

- `InventoryItem.getSquare()` answers with the square of the *character holding the item*,
  so it is null for exactly the case a ground address exists for. The square has to come
  from `item:getWorldItem():getSquare()`.
- Dropping a bag wraps it in an `IsoWorldInventoryObject` whose constructor calls
  `IsoObject.setContainer`, which makes that object the parent of the bag's container. So a
  bag on the ground *does* have a parent - it simply is not one of the square's objects, it
  is one of its world objects. Anything that tests `getParent() == nil` to spot a dropped
  bag, or looks for that parent in `square:getObjects()`, silently finds nothing.

`CF.processTopLevel` guards the same edge from the other side. The loot window gives a
cooler on the ground its own container button, so the mod can be handed the inside of a
cooler directly; it goes back up to the cooler item and processes it as a cooler.

Do not reach for `transmitCompleteItemToClients` to push a dropped item's state. It is an
*add object* packet, not an update: the client keeps the world object it already had and
gains a second one beside it, so one cooler shows up as two container buttons and the ghost
cannot be picked up, because the server only ever had one. Under this model nothing needs
pushing anyway. A test pins it.

Changes that do need transmitting use the vanilla helpers, which do nothing offline, which
is why they are called unguarded: `sendItemStats` for a bag of ice's remaining charge,
`syncItemModData` for a Cold Pack's (it has no used-delta of its own), `syncItemFields` for
the *(Iced)* suffix, and `sendAddItemToContainer` / `sendRemoveItemFromContainer` for bags
of ice that are created or used up. Bookkeeping modData needs no packet: it is only ever
read by the machine that wrote it, and it travels with the item when the item is moved.

Freezing water is started from a client's context menu but always finishes in a fridge or a
freezer, so the flag is set locally for the menu's benefit and sent on with a `setFreezing`
command; the server sets it on its own copy and syncs it back.

Freezing itself is a container-level pass, `CF.processFreezing`, not a per-item one: every
container marked for freezing in the same fridge pools its water, so three glasses make a
bag between them where none of them could alone. It has to work that way, because B42
capacities are small - a Water Bottle holds 1 unit and a bucket 10 - so a per-bottle rule
at any sensible bag size would leave most containers unable to freeze at all. Water is
drawn off the emptiest containers first, so the small ones come out empty instead of every
one keeping a dribble; a container that still holds water afterwards stays marked and its
clock restarts, so each bag costs the full freezing time.

The *(Iced)* label needs care of its own. It lives in the item's custom name, so whichever
machine writes it writes it for everyone, and a dedicated server has no translations loaded
for a modded key - `getText` there hands back `IGUI_TienCoolers_Iced` itself.
`CF.updateCoolerName` falls back to plain English when the key is missing, works from the
name on the item rather than a flag in its modData (modData crosses the wire, a custom name
does not always follow), and recognises a name stamped with the raw key so it can repair it
instead of labelling it twice.

### Tracing it

`CF.DEBUG` in the shared file turns on a line a minute from each machine, which is what
to reach for when the mod works in your hands and nowhere else. The client says how many
containers the loot window offered, how many it owned, how many it handed to the server,
and - for anything it could not address - the parent, containing item and world item it
found. The server says what became of every request: which item it ticked, or which id it
could not find along with every id actually lying on that square, since item ids agreeing
across the wire is the one assumption a ground address rests on.

### Version handshake

`CF.VERSION` in the shared file is compared at login, as part of the tracing above: with
`CF.DEBUG` on the client asks once, the server answers, and a mismatch prints to the
console. With it off nothing is asked and nothing is said - the mod is silent by default. A dedicated server only picks up a new
Workshop build when it restarts, and half this mod lives on the server, so a stale server
fails in a way that reads exactly like a mod bug - coolers work in your hands and do
nothing on the ground or in a fridge. A server on a build older than this handshake has no
handler for it and never answers, which the client reports too. Keep it in step with
`modversion` in mod.info.

## Extending

Other mods can register their own gear:

```lua
TienCoolers.CoolerBags["MyMod.BigCooler"] = true
TienCoolers.IceSources["MyMod.IcePack"] = 0.6   -- 1.0 == one full bag of ice
```

## Naming

Everything the game sees is namespaced to avoid colliding with other mods: the mod id, the
Lua table, the script module, the sandbox page and every translation key are `TienCoolers`,
item and texture filenames are prefixed `TienCooler`, and item modData keys are prefixed
`tc`. `TienCoolers.IceBag` is the item's full type.

## Art

All art is generated by `scripts/make_art.py` (icon, world texture, mod icon, poster and the
Workshop preview). Re-run it after editing that script to regenerate every asset.

The poster and Workshop preview are not drawings: `scripts/pz_model.py` parses the game's
binary FBX meshes and rasterises them, so the poster shows the real `Cooler_Ground` model
with our bag of ice in front of it, and the cold moodle (`Status_TemperatureLow`) sits
behind them. That needs the game's media folder - set `CF_PZ_MEDIA` if it is not in a
standard Steam location. Without it the poster quietly falls back to the drawn cooler.

## Development

`scripts/sim.lua` stubs out the parts of the PZ API the mod touches, loads all three Lua
files, and asserts the cooling, melting, refreezing, water-to-ice, chill and labelling
behaviour along with container ownership, addressing, what goes on the wire and the
client-to-server round trip, 91 checks in all. Run it from `scripts/` with any Lua 5.4 host,
or with `lupa` from Python:

```
python -c "import lupa,io; lupa.LuaRuntime().execute(io.open('sim.lua').read())"
```
