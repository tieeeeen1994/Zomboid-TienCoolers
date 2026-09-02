# Tien's Coolers

A cooler packed with ice keeps the food inside it fresh four times longer, anywhere you carry
it. No power and no refrigerator are required.

Coolers already exist in Project Zomboid, but they do nothing for the food they hold. This mod
gives them their intended purpose and adds the ice to fill them with.

## What the mod adds

- **Bag of Ice.** A new item. It is found in shop display freezers and in household and garage
  chest freezers, and it can also be made at home.
- **Cooling.** Put a bag of ice in any cooler, including the Beer, Meat, Soda and Seafood
  coolers, and the food inside rots at a quarter of the usual rate. The cooler is labelled
  *(Iced)* for as long as the ice lasts, and the chilled items are tinted blue in the
  inventory window in the same way as food in a working refrigerator.
- **Melting.** A full bag lasts about two days inside a cooler and melts roughly five times
  faster outside one. Hot weather shortens it further. How much ice is left is shown on the
  bag itself.
- **Freezing water.** Right-click a container of water inside a powered refrigerator or
  freezer and choose *Freeze Into Ice*. Seven hours later the water has become a bag of ice. Water adds up across everything.
  you set to freeze in the same fridge, so a few bottles make a bag between them. A
  bag that has melted refills itself if it is left in a powered freezer.
- **Cold Packs.** The vanilla Cold Pack chills a cooler as well, at 40 percent of the strength
  of a bag of ice.

## Sandbox options

Nine settings are available on the **Tien's Coolers** sandbox page: cooling strength, ice
lifetime, melting speed outside a cooler, freezing time, the water needed per bag, cold pack
support, freezer loot, the blue tint on chilled items and the *(Iced)* label.

The mod also follows the vanilla Food Rot Speed and Refrigeration Effectiveness settings, and
a cooler is never allowed to preserve food better than a powered refrigerator does.

## Compatibility

Build 42 only. The mod can be added to an existing save. Multiplayer is supported: coolers
work the same wherever they are, carried, in a fridge, in a car or on the ground, and every
player sees them update as they happen. A dedicated server needs no additional setup beyond
having the mod installed.

Other mods can register their own coolers and cold sources. The
[implementation notes](docs/implementation.md) explain how, along with the rest of the
mod's internals.
