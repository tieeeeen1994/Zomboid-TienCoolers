# Tien's Coolers

## New in 1.5.*: beta features, off by default

Version 1.5 adds three new features as a beta. All of them are **off by default**, so the
mod plays exactly as it did before until they are switched on in the sandbox settings,
where each one is marked [BETA].

- **Tainted Ice:** tainted water freezes into a Bag of Ice (Tainted), which cools food just
  as well but melts into tainted water.
- **Freezing Needs Plastic Bags:** each bag of ice made in a freezer needs an empty plastic
  bag or garbage bag, which is given back when the ice is used up.
- **Catch Meltwater:** right-click a bottle, pot or other water container inside a cooler
  and choose *Catch Meltwater*, and the water from the melting ice runs into it until it is
  full. Water that melts while nothing is set to catch it is lost, and water that has run
  out of a bag cannot be frozen back into it.

Please report any bugs if you found one. Thank you!

## About the mod

A cooler packed with ice preserves the food inside it half as well as a working
refrigerator, anywhere you carry it, with no power required.

Put a Bag of Ice in any cooler, including the Beer, Meat, Soda and Seafood coolers, and the
food inside rots more slowly. The cooler is labelled *(Iced)* while the ice lasts, and
chilled items are tinted blue.

A full bag lasts about two days inside a cooler, melts much faster outside one and runs out
sooner in hot weather. A melted bag refreezes in a powered freezer.

Bags of Ice can be found in freezers. To make your own, right-click water in
any powered fridge or freezer, chest freezers included, and choose *Freeze Into Ice*. Water
set to freeze in the same container adds up, and a bag is ready after seven hours.

The vanilla Cold Pack also chills a cooler, at a lower strength than ice.

Thirteen sandbox settings cover cooling strength, ice lifetime, melting, freezing, cold
packs, freezer loot, the blue tint, the *(Iced)* label and the three beta features. Cooling
follows the vanilla Food Rot Speed and Refrigeration Effectiveness settings and never
exceeds a powered refrigerator.

Build 42 only. The mod works in existing saves and in multiplayer, including dedicated
servers, with no extra setup. Other mods can register their own coolers and cold sources.

The [implementation notes](docs/implementation.md) explain how the mod works and how other
mods can extend it.
