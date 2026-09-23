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

### Nothing ages food on its own

Measuring only works if the thing being measured happens when you think it does, and food
rot does not. `Food.age` is not advanced by the passage of time; it is advanced when
something calls `updateAge()`, which catches the item up from the `lastAged` stamp it
carries. `Food.update()` will do that - but only on a dedicated server:

```java
ItemContainer cont = this.getOutermostContainer();
if (cont != null) {
    if (GameServer.server) this.updateAge(false);
```

In single player the one remaining caller is the inventory window's render loop:

```lua
-- ISInventoryPane.lua, once a frame, for the container it is drawing
if instanceof(item, 'InventoryItem') then item:updateAge() end
```

So a cabbage in a cooler in a closed bag is not aged at all while nobody is looking, and
then jumps the whole gap in a single frame the moment the player opens their inventory.
That lump lands inside one pass of this mod, and a pass may only rebate `dt * rotSpeed / 24`
- the rot that could have happened since the pass before it. An hour of rot arriving in a
one-minute pass was rebated one minute's worth and the other fifty-nine were kept. Builds up
to 1.4.0 therefore preserved nothing at all unless the player sat with the inventory window
open: three cabbages, one loose, one in a fridge and one in an iced cooler, came out with the
loose one and the cooler's at the same age.

`CF.ageFood` calls `item:updateAge()` itself now, before reading the age. The game's clock
for the item is then the mod's clock, `aged` is exactly that interval's worth of rot, and the
cap goes back to meaning what it says. It is the same call the inventory pane makes, so
nothing new happens to the item - it just happens on time. It also makes the mod's own passes
the sampling points on every machine, which is what keeps a client and a server rebating the
same rot rather than whichever lumps each of them happened to catch.

`scripts/sim.lua` models the lag rather than the intent: the fake item ages from its own
`lastAged` when `updateAge()` is called and at no other moment, and the regression test only
lets the "player" glance at the inventory every ten minutes. A harness that ages food itself,
neatly in step with the mod's passes, cannot see any of this - which is how it went out.

### Ice remembers where it has been

The same catch-up needs one extra thing that rot does not, because ice is *destroyed* when
it runs out and rot merely accumulates. `tcLast` says when a bag was last looked at, and
`tcCold` says where it was sitting at the time. The gap between the two is charged to
`tcCold`, never to wherever the bag happens to be at the instant somebody finally looks.

Without that, lifting a bag out of a freezer nobody had ticked for a couple of days
applies a couple of days of *melting* the moment it lands in your hands - and a bag lives
about nine hours outside a cooler, so it is destroyed by the act of picking it up. The
freezer that was keeping it is exactly where the gap was spent.

### A drainable cannot hold the charge

The bag of ice is a `DrainableComboItem` so the vanilla UI draws a familiar bar for it,
but that bar is not a float. B42 stores the charge as an integer count of uses:

```java
public void setCurrentUsesFloat(float f) {
    f = PZMath.clamp(f, 0.0f, 1.0f);
    this.uses = Math.round(f / this.useDelta);   // integer
}
public float getCurrentUsesFloat() { return this.uses * this.useDelta; }
```

At the bag's `UseDelta = 0.02` the field holds fiftieths and nothing finer. One pass a
game minute long melts `1/60 / 48` = about **0.0003** of a bag, which `Math.round` puts
straight back on the use it started from - so the write is a no-op, every time, forever.

That is invisible until you notice which containers are ticked *often*. A cooler in your
inventory is walked every `EveryOneMinute`, so its ice never melted at all. The same bag
on the floor is swept every ten seconds and melts five times faster, so its steps clear
the rounding and it empties normally. In multiplayer the two copies then drift apart
until the bag reads full in your hands and empty the moment you set it down.

So `tcCharge` in modData is the real number and the item's field is the *display* of it,
written on every change so the bar stays right. `CF.getCharge` prefers the
note but yields to the item whenever the two differ by more than a whole step, which
rounding can never explain - that is a fresh copy streamed from the server, or a player
having used the item, and in both cases the item is right and the note is stale.

Anything stepping the clock an hour at a time hides all of this, which is exactly how the
sim used to walk it. The regression test steps a game minute at a time instead, and the
harness models `setUsedDelta` with the rounding the real one does.

### A bag of ice weighs its water

Only with `ReworkedIce` on (see *Reworked Ice* below); off, a bag weighs its script's
1.6, as it always has, and `CF.updateIceWeight` puts back that weight on a bag weighed
while the switch was on.

B42 weighs water at one unit a litre: `InventoryItem.getUnequippedWeight()` is
`getActualWeight() + getContentsWeight()`, and the second is the fluid container's
`getAmount()`. A bag of ice has no fluid container, so its weight is whatever the item
says, and the script's fixed `Weight` could only ever be right for one value of
`WaterPerBag`. Worse, the vanilla drainable never lightens it:

```java
public void updateWeight() {
    if (getReplaceOnDeplete() != null) { ... }
    if (getWeightEmpty() != 0.0f) {
        setCustomWeight(true);
        setActualWeight((script.getActualWeight() - weightEmpty) * getCurrentUsesFloat() + weightEmpty);
    }
}
```

The bag has neither, so `CF.updateIceWeight` does it instead: the empty bag from
`CF.IceWeights` (0.1, a vanilla plastic bag) plus `WaterPerBag` times the exact charge,
written as a custom weight. It runs from `CF.storeCharge` on every change and once more on
every look at the bag, so one straight out of the loot table, or saved before an admin
changed the setting, is put right on the next pass, and until then weighs the script's
1.6. Since `updateWeight` is
a no-op for this item, nothing in Java writes over it, and `customWeight` is saved and
sent with the item.

Weighing by the charge rather than the capacity means melting takes weight off the bag,
and with meltwater on, the weight a bag loses is exactly the weight the bottle beside it
gains. A Cold Pack is not in the table and keeps its own weight.

### Vanilla sandbox options

`SandboxVars.FoodRotSpeed` and `SandboxVars.FridgeFactor` are both read straight out of
`Food`, so the mod tracks the player's own settings instead of assuming defaults:

| FoodRotSpeed | 1 Very Fast | 2 Fast | 3 Normal | 4 Slow | 5 Very Slow |
|---|---|---|---|---|---|
| `getFoodRotSpeed()` | 1.7 | 1.4 | 1.0 | 0.7 | 0.4 |

| FridgeFactor | 1 Very Low | 2 Low | 3 Normal | 4 High | 5 Very High | 6 No decay |
|---|---|---|---|---|---|---|
| `getFridgeFactor()` | 0.4 | 0.3 | 0.2 | 0.1 | 0.03 | 0.0 |

The rot speed bounds the rebate (`cap = dt * rotSpeed / 24`, in days, which is the unit
`Food.age` and `DaysFresh` are both in: `age += delta_hours * getFoodRotSpeed() / 24.0`). The fridge factor is the far
end of the `CoolStrength` scale: a cooler's rot rate is read off the line between no cooling
at all and whatever a real fridge manages, `1 - strength * (1 - fridgeFactor)`. A strength of
1 makes a cooler the equal of a fridge, the default 0.5 gets it half way there (0.6 on a
Normal refrigeration game), and 0 leaves food to rot as though the box were empty.

Because the scale stops at 1, a box of melting ice can never preserve food better than a
working fridge does, and the setting now says so itself rather than leaning on a hidden
floor. It used to: builds up to 1.3.0 clamped `CoolFactor` up to the fridge's own rate,
which silently contradicted the tooltip's promise that 0 stopped rot, because on a stock
game it did not - it bought you 0.2 and no more. Renaming the option to `CoolStrength` in
1.4.0 also means an existing save falls through to the new default instead of reading its
old 0.25 on a scale where that now means something close to the opposite.

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
    sandbox-options.txt                        sandbox page + 11 options
    scripts/TienCooler_items.txt               IceBag and IceBagTainted items + their ground models
    textures/Item_TienCoolerIceBag*.png        32x32 inventory icons, clean and tainted
    textures/WorldItems/TienCoolerIceBag*.png  256x256 world model textures, clean and tainted
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

### Containers that are a listing, not a place

Several popular inventory mods add a "nearby items" pane: one container button holding
everything within reach, gathered out of the real containers with
`button.inventory:getItems():addAll(...)`. Proximity Inventory types its pane `proxInv`
(`local` in its B41 build, as CleanUI does); BetterContainers has its own, `proximityInv`,
plus `twistInv_corpses`. `CF.UIContainerTypes` lists them and `CF.isUIContainer` answers
for them.

They have to be skipped, and not because walking one is wasted work. A pane is not a
fridge, so `CF.processTopLevel` reads `containerIsCold` off it as false and every item in
it is treated as being out in the open: `CF.tickFreezing` un-marks water that is sitting
in a powered freezer, and `CF.tickIce` writes `tcCold = false` onto a bag of ice that is
sitting in one, so the *next* pass - the correct one, on the real container - bills that
bag for the whole elapsed gap at the melting-in-the-open rate. The pane and the real
container are both buttons in the same loot window, so both are walked in the same pass
and whichever comes later wins. The visible result is a mod that stops working, on
freezers, for exactly as long as the pane is on screen.

Skipping costs nothing, because everything in the pane is reached through its own
container in the same sweep. The guard sits at both ends: `process` in the client drops
the pane before it can nudge the server about a container that has no address anyway, and
`CF.processTopLevel` drops it again for any other caller.

The test is the type string rather than the shape. The obvious structural check - no
parent object and no containing item - is equally true of the base game's own floor list,
and that one has to be walked: a cooler or a bag of ice set down on the ground is reached
through it.

### Finding every freezer

`ItemContainer.isFreezer()` is a plain string compare against `"freezer"`. There is no
property fallback, unlike `isFridge()`, which also accepts the `IsFridge` sprite property
on the parent object. So what a container answers depends entirely on how its tile was
written, and tiles are written three ways:

- an upright fridge has `IsFridge`, `Freezer` and `container = fridge`, so
  `IsoObject.createContainersFromSpriteProperties` gives it **two** containers, `fridge`
  and `freezer`;
- a chest freezer has `Freezer` and no `container` property at all, so the freezer
  container becomes its **only** one - it answers `isFreezer()`, and always has;
- an object that has `Freezer` *and* names a container of its own gets both: the named one
  alongside the freezer one, and the named half answers neither.

`CF.isColdContainer` therefore asks three things in turn - the two vanilla predicates, the
container type against `CF.ColdContainerTypes`, and finally `objectIsRefrigeration`, which
reads `Freezer` or `IsFridge` off the parent object's sprite properties. The last one is
what makes the third shape work, and it is the only one that can see a freezer added by a
mod that named its container something this mod has never heard of.

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
| cooling, melting, rot rebate, the label | every machine, on its own copy |
| with Reworked Ice on, filling a bag of ice from water set to freeze | whoever owns the freezer (`CF.mayTransfer`); off, a bag refreezes on every machine, like a cold pack |
| the same for a cooler a player carries | that player's client, which reports the result to the server (see below) |
| turning water into bags of ice | whoever owns the container (`CF.mayTransfer`) |
| clearing away a spent bag of ice | the owner (`CF.destroyIce`), unless `CF.serverClearsIce` says otherwise |
| the same with plastic bags or meltwater on, handing back a plastic bag | the server, or the game offline, wherever the bag is (`CF.mayCreate`) |
| pouring meltwater into a catching container | the same |

The last two rows are the server's even in a player's own inventory, and that is not a
preference. `sendAddItemToContainer` and `sendItemStats` only do anything on a server
(both check `GameServer.server` and nothing else), so a plastic bag a client hands back,
or water it pours into a bottle, exists on that client alone: the server never saves it,
and moving it later asks the server for an item it has never heard of. Removal alone
would work from a client, since `sendRemoveItemFromContainer` does have a client branch,
but it cannot be split from handing the bag back. A client that removed a spent bag
itself would leave the server with nothing to notice was spent. So `CF.serverClearsIce`
moves the removal to the server whenever something only a server can do goes with it:
`ReworkedIce` is on, or the bag noted a plastic bag to return. With it off and nothing
owed, removal stays with the owner exactly as it was in 1.4.3, which is why a server with
the option off behaves as it did before.

A spent bag left in place is harmless: its charge is zero, so it cools nothing, and
whoever may clear it does so on their next pass. A client that sees ice run out in a
freezer it does not own leaves it for the server, and with the option on it does the
same for a cooler it carries.

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
is why they are called without a mode check: `sendItemStats` for a bag of ice's remaining
charge, `syncItemModData` for a Cold Pack's (it has no used-delta of its own),
`syncItemFields` for the *(Iced)* suffix, and `sendAddItemToContainer` /
`sendRemoveItemFromContainer` for bags of ice that are created or used up.

The helpers that take a player do need one check, and it is not about the mode. They
assemble the packet before deciding whether there is anywhere to send it, and assembling it
works out where the item lives by reading the square the player is standing on, so a player
who has not been put on the map yet takes the call down with a NullPointerException out of
`ContainerID.setInventoryContainer` - offline included, where the send itself would have
done nothing. That gap is real and this mod runs inside it: `ISPlayerData.createPlayerData`
builds the inventory window during loading, building it refreshes the container list, and
that fires `OnRefreshInventoryWindowContainers` and a full pass of this mod. So `placed()`
gates every helper that takes a player, and the loot window's own rebuild is skipped
outright while the player has no square, since the minute tick reaches the same containers
as soon as there is one.

A caller that keeps no record of a change beyond the change itself has to ask first, which
is what `CF.canSync` is for. `CF.updateCoolerName` is the one: the name on the item is the
only evidence the label was applied, so renaming during that gap and losing the send would
leave every other machine reading "Cooler" for good - the next pass would find the name
already right and have nothing left to send. It holds the rename back instead, and the
first pass with somebody to tell makes it. Bookkeeping modData needs no packet of its own, but it
does not stay on the machine that wrote it either: `syncItemFields` sends an item's entire
modData along with its name, and the receiving side wipes its own and takes the sender's.
So every label change carries one machine's cooler timestamps into the other's copy. That
is the reason carried coolers are reported rather than recomputed, below.

Freezing water is started from a client's context menu but always finishes in a fridge or a
freezer, so the flag is set locally for the menu's benefit and sent on with a `setFreezing`
command; the server sets it on its own copy and syncs it back.

Water pools by the fridge rather than by the bottle, so three glasses feed one bag between
them. It has to pool, because B42 capacities are small (a Water Bottle holds 1 unit and a
bucket 10), so a per-bottle rule at any sensible bag size would leave most containers
unable to freeze at all. `CF.processFreezing` runs for every container a pass walks, and
freezes one of two ways depending on `ReworkedIce`.

Off, which is the default and how the mod has always done it, it is a timer
(`classicFreezing`). Once every container's water has sat for `FreezeHours`, the pool turns
into whole bags, `floor(pool / WaterPerBag)` of them, drawn off the emptiest containers
first so the small ones come out empty rather than every one keeping a dribble. A container
still holding water afterwards stays marked and its clock restarts, so each bag costs the
full freezing time, and water short of a bag waits for more. A melted bag refreezes by
itself in any powered fridge or freezer (`CF.refreeze`).

On, it is a rate (`reworkedFreezing`), and the water sets the pace: each container freezes what it held
when it was set to freeze (`tcFreezeAmount`) over `FreezeHours`, a steady trickle, and the
ice goes into bags at `WaterPerBag` units a bagful. The bags only decide where the ice
goes, so more bags never make water freeze faster, and everything set to freeze is ice
`FreezeHours` after it was set, which is the wait the timer had. Ten units give a full bag
half way through and a second at the end; two buckets freeze twice as much as one in the
same time. Water poured into a container after it was set raises its note, so it keeps the
same deadline, and a mark with no note, set before this existed or while the option was
off, takes what is in there.

`tcFreezeStart` is how far a container's water has been frozen up to. Each pass,
`CF.processFreezing` turns what froze since then into ice, puts it into bags, takes that
much water out of the containers in proportion to what each had ready, and moves each
clock on by what it gave (`drawFrozen`). The ice fills the bags that are not yet full,
fullest first and then in the order they sit, loose or in a cooler in there, so one bag
is finished before the next is started and a melted bag fills exactly like a new one.
When no bag can take the rest, a new one is made once there is a use of ice for it
(`MIN_BAG`, 0.02, the least the drainable's field can show), so a bag turns up a few
minutes after the water is set. Ice that finds no bag, for want of a plastic bag to start
one in, is not taken: the clock stays where it was, and it all goes in at once when a bag
arrives, as it did with the timer. A freezer nobody looked at settles the whole gap on the
next look the same way.

Drawing water is a transfer, so only the machine that owns the freezer does any of this
(`CF.mayTransfer`). Nothing else fills a bag of ice: with the option on, `CF.refreeze` only
refreezes a cold pack, which is gel sealed in its pack, and a client sees a bag fill when the server's stats
arrive. Working the charge out anywhere without the water would be a free refreeze.

The *(Iced)* label needs care of its own. It lives in the item's custom name, so whichever
machine writes it writes it for everyone, and a dedicated server has no translations loaded
for a modded key - `getText` there hands back `IGUI_TienCoolers_Iced` itself.
`CF.updateCoolerName` falls back to plain English when the key is missing, works from the
name on the item rather than a flag in its modData (modData crosses the wire, a custom name
does not always follow), and recognises a name stamped with the raw key so it can repair it
instead of labelling it twice.

### What a player carries

The model has one gap, and it is the player's own inventory. The server keeps a copy of
everything a player carries, and that copy matters in two places. It is the one written to
the player database, so it is what the player loads at their next login. And B42 performs
every transfer on the server: taking a steak out of a cooler removes the server's steak from
the server's cooler and sends it to the client (`Transaction` then
`AddInventoryItemToContainer`), and the client draws that steak from then on.

1.4.2 kept that copy level by running the cooling pass over carried bags on the server as
well. On a real dedicated server it did not hold. Log out with food in a carried cooler,
stay away for a few days and log back in: the food looks right in the cooler, and the moment
it is taken out it jumps as if it had never been cooled. Two machines computing the same
thing agree only while nothing else touches the bookkeeping they compute from, and for a
cooler something does. `syncItemFields`, which carries the *(Iced)* label, sends the item's
entire modData, and `SyncItemFieldsPacket` wipes the receiver's modData and copies the
sender's in. Every label change moves one machine's `tcLast` and `tcId` into the other
machine's copy, and a login after a long absence, when the ice may have run out and both
machines relabel the cooler, is where that is most likely to go wrong.

Since 1.4.3 a carried cooler is the carrying client's to compute. After its own pass the
client sends a `carried` report (`CF.reportCarried`), at once on the first pass and every
ten real seconds after that: for each cooler it carries, the cooler's id and `tcId`, the age
of every piece of food inside and the charge of every cold source. The server's `onCarried`
looks each cooler up in that player's own inventory and nowhere else, brings its copy of the
food up to date, and writes the reported numbers in, along with the bookkeeping (`tcAge`,
`tcCooler`, `tcLast`) that the client's first pass after the next login starts from. The
server's own pass over carried inventories still runs for loose ice and freezing marks, but
it passes over coolers (`CF.leaveCoolers`), so it no longer sends the owning client anything
about them.

A report is the client's word, so the server holds it to what a cooler could have done:

| reported | accepted between |
| --- | --- |
| age of a piece of food | the server's own copy aged at the open-air rate, and that less the most the best cooler could have saved since the server last heard about this food (`tcReported`), or at most an hour for food it has not heard about yet |
| charge of a cold source | zero and the charge the server's copy already holds, since nothing a player carries is in a freezer |

Charges are written with `CF.storeCharge`, which sends nothing back. Answering with
`sendItemStats` would round the charge on the way: `ItemStatsPacket` applies it as
`(int)(maxUses * usedDelta)`, which lands a whole use low at several charges, and the
client would take the rounded value as a correction.

A second fix belongs with this one. `CF.ageFood` skips food that is already rotten, and it
used to ask `isRotten()` after catching the item up. The catch-up after a long absence
arrives in one lump, so a lump that carried food past its rotten mark skipped the very
rebate that should have kept it short of the mark. It now skips only food that was rotten
at the previous look.

The sim covers this end to end: a session with reports, a logout that saves the server's
copy, an absence with and without the ice running out, a login that loads the same copy on
both machines, and a steak taken out afterwards that has to match the one the player saw.
It cannot reproduce the real server's failure, since the harness's server computes the same
numbers the client does, so what it pins is the new rule: the saved copy holds the client's
numbers.

### Reworked Ice

One sandbox option, `ReworkedIce` (`CF.reworkedIce`), labelled [BETA] and off by default,
turns on everything that treats a bag of ice as the water it is made of: tainted ice,
plastic bags, catching meltwater, melted bags that fill again only from water, freezing as
a rate (see *Multiplayer* above) and weight (see *A bag of ice weighs its water*). Off, a
save plays exactly as it did on 1.4.3.

Up to 1.5.1 the first three were separate options, `TaintedIce`, `NeedPlasticBags` and
`CatchMeltwater`. They were folded into this one because they only make sense together, the
freezing rules lean on all of them, and one switch is one thing to test both ways. A server
that had any of them on has to switch on Reworked Ice, since the old keys are no longer
read.

#### Tainted ice

Freezing is not filtering, so water that goes in tainted comes out tainted, and it is a
separate item, `TienCoolers.IceBagTainted`. It cools exactly as well as clean ice and is
registered in `CF.IceSources` at the same power. A second item rather than a flag on the
first means nothing has to survive the wire for the player to tell them apart, and a bag
found in a store freezer, or made before 1.5.0, is simply the clean kind.

With Reworked Ice off, all water freezes into the ordinary bag and pools together, as it
did before. With it on, a container is tainted when it holds any `TaintedWater` at all
(`CF.TaintedFluids`), and its water is tainted ice. Each kind fills bags of its own kind
first and then starts new ones. It goes into a bag of the other kind only when none of that
kind's water is freezing in the same freezer: a melted clean bag set in with tainted water
alone is topped up with it and becomes a tainted bag (`taintBag`, a swap to the other item
that keeps the charge and everything noted on the bag), while clean and tainted water
freezing side by side keep apart and spoil no clean ice. Clean ice in a tainted bag just
leaves it tainted.

Up to 1.5.1 clean water left short of a bag joined the tainted water, so that it would not
sit there for good. Bags can be part-filled now, so it makes a part-filled clean bag instead.

#### Plastic bags

With Reworked Ice on, every new bag of ice uses up one empty bag from the same freezer
when it appears. A bag that is filling or being topped up already has one. `CF.PlasticBags` lists every vanilla item that shows up as a
Plastic Bag or a Garbage Bag, eleven in all, with an order of use: plastic first, garbage
bags last. Only bags holding nothing count. Short of bags the water keeps waiting, already
frozen for as long as it needs, and turns to ice as soon as a bag is put in with it; the
*Stop Freezing* tooltip says so rather than leaving the freezer looking broken.

The bag of ice notes what it was frozen in (`tcWrap`), and `CF.destroyIce` hands that back
when the ice is spent. A bag with no note, from loot or from an older build, gives back a
plain `Base.Plasticbag`, but only while the option is on, so switching it off cannot turn
found ice into free plastic bags. A bag that did note one gives it back either way, since
the plastic bag was paid for. Cold packs are not water and leave nothing.

`CF.processFreezing` builds the ice before it spends anything on it, and spends only for
what actually turned up. `CF.addItem` is `ItemContainer.AddItem`, which answers nil rather
than raising when it will not take the item - a mod policing a container's contents is the
likely reason, since vanilla enforces room in the UI (`hasRoomFor`) rather than in
`AddItem`. Up to 1.5.0 the water was drawn and the wrapper removed first, so a nil
destroyed both and left nothing in their place: the one outcome worse than not freezing.
Building first costs a moment with the wrapper and the ice both in the container, which
nothing minds, and whatever could not be built stays marked and waiting - the same answer
as running out of plastic bags. The sim drives it with a container that refuses everything
and one with room for a single bag.

#### Meltwater

With Reworked Ice on, a container inside a cooler can be marked to catch meltwater
(`tcCatch`, *Catch Meltwater*). Off, `CF.canCatchMeltwater` refuses every container, so the
menu offers nothing and the server ignores the command, and `CF.settleIce` pours nothing,
even into a container marked while the option was on. The mark only means anything in a
cooler: `CF.processItem` never sees a cooler's contents, so anything it does see has been
taken out, and it clears the mark.

Only water melting while something is set to catch it is poured. Water that melted
before the container was set, and water that finds no room, is simply lost, and nothing
is kept for later: setting a bottle does not bring back what melted before it. So a pass
pours exactly what it melted, and no pouring state is carried from one pass to the next.

Whatever melts has left the bag, caught or not, so nothing about it is carried either.
Up to 1.5.1 a melted bag refroze to full in any powered freezer, and `tcDrained` limited
that only for water that had run into a container. Now a melted bag only fills again from
water set to freeze in the same fridge or freezer (the one its cooler sits in, for ice in a
cooler), like any other bag that is not full (see *Multiplayer* above for the freezing
itself), so a freezer never makes water and the weight a bag gains is the weight the water
loses. Caught water can be set to freeze beside the bag it came from. Cold packs are gel
and still refreeze by themselves.

`CF.settleIce` runs at the end of every cooler pass, handed what each bag melted in that
pass (`consumeIce` returns it). It pours each bag's melt into the catching containers in
the order they sit, as far as they have room, at `WaterPerBag` units to a bagful, and then
clears away any bag with nothing left frozen. Pouring first means a bag that runs out
empties its last water before it goes. A cooler sitting in a freezer, or seen for the
first time, melted nothing and pours nothing.

Both halves are the server's (see the table above). For a world cooler that is the
server's own pass. For a cooler a player carries, which the server leaves to the client's
report, `onCarried` calls `CF.settleIce` after writing in the reported charges, handing it
how far each charge fell on the server's own copy, so the water poured is the server's
reckoning of what melted and never a number the client sent.
The mark reaches the server by a `setCatching` command, which finds the container by its
address or, for a carried cooler that has none, in the asking player's own inventory and
nowhere else.

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
TienCoolers.Meltwater["MyMod.IcePack"] = "Water" -- melts into this fluid, by name
TienCoolers.PlasticBags["MyMod.ZipBag"] = 1     -- freezes ice; lower numbers used first
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
client-to-server round trip, tainted ice, plastic bags and meltwater, 262 checks in all. Run it from `scripts/` with any Lua 5.4 host,
or with `lupa` from Python:

```
python -c "import lupa,io; lupa.LuaRuntime().execute(io.open('sim.lua').read())"
```
