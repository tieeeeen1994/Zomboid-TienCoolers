# Tien's Coolers

## New in 1.5.*: Reworked Ice, a beta option, off by default

Version 1.5 adds a beta sandbox option, **Reworked Ice**, which makes ice behave like the
water it is made of. It is **off by default**, so the mod plays exactly as it did before
until it is switched on in the sandbox settings, where it is marked [BETA]. With it on:

- **Tainted ice:** tainted water freezes into a Bag of Ice (Tainted), which cools food just
  as well but melts into tainted water. A clean bag topped up with tainted water becomes
  tainted.
- **Plastic bags:** each new bag of ice made in a freezer needs an empty plastic bag or
  garbage bag, which is given back when the ice is used up.
- **Catch meltwater:** right-click a bottle, pot or other water container inside a cooler
  and choose *Catch Meltwater*, and the water from the melting ice runs into it until it is
  full. Water that melts while nothing is set to catch it is lost.
- **Freezing takes water:** water set to freeze turns to ice a little at a time over the
  freezing time, filling one bag of ice before starting the next, and water short of a full
  bag makes a partly filled one. A melted bag fills up again only from water set to freeze
  beside it.
- **Weight:** a bag of ice weighs as much as the water in it and gets lighter as it melts.

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

Eleven sandbox settings cover cooling strength, ice lifetime, melting, freezing, cold
packs, freezer loot, the blue tint, the *(Iced)* label and the Reworked Ice beta. Cooling
follows the vanilla Food Rot Speed and Refrigeration Effectiveness settings and never
exceeds a powered refrigerator.

Build 42 only. The mod works in existing saves and in multiplayer, including dedicated
servers, with no extra setup. Other mods can register their own coolers and cold sources.

The [implementation notes](docs/implementation.md) explain how the mod works and how other
mods can extend it.
