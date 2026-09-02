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
    lua/server/TienCoolers/                    freezer loot
    lua/shared/Translate/EN/                   ItemName / Tooltip / ContextMenu / IG_UI / Sandbox
```

Everything runs client side, on the containers a player is carrying or currently looking at
(`EveryOneMinute` plus `OnRefreshInventoryWindowContainers`). State lives in item modData and
in the drainable's used-delta, both of which the client already owns and transmits, so a
dedicated server needs nothing extra and no correction is ever applied twice.

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

`scripts/sim.lua` stubs out the parts of the PZ API the shared module touches and asserts the
cooling, melting, refreezing, water-to-ice, chill and labelling behaviour, 23 checks in all.
Run it with any Lua 5.4 host, or with `lupa` from Python.
