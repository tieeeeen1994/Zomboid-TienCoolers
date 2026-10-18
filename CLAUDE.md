# Tien's Coolers

Project Zomboid B42 mod: a cooler packed with ice preserves the food in it, anywhere it is carried, plus Bags of Ice
(found or frozen from water) and the beta Reworked Ice option. The live code is under `Contents/mods/TienCoolers/42/`.
General engine findings go in `~/Zomboid/Workshop/ZomboidFixesB42/CLAUDE.md`. The full design (drivers, multiplayer
model, ice maths, addressing) is in `docs/implementation.md`: keep it in step with the code. This file holds working
notes.

## Status

1.5.4 (2026-10-18, not committed or played yet): fix for a 3-5 s freeze on every change of clothes with a cooler in a
backpack (report against 1.5.3, with ExtraSauce Quality of Life's nested containers among many other mods). To verify
in game: wearing and removing clothing with a cooler of ice and food in a worn backpack, ExtraSauce on and off; that a
carried cooler's ice charge, "(Iced)" label and food freshness still update within a game minute; that the minute tick
itself has no noticeable hitch with a full cooler (one pass was never timed; add a timing log if it does).

## Where the time goes (the 1.5.4 fix)

- A pass works from timestamps on the items, so how often it runs decides when the work happens, not how much: a
  skipped pass is made up in full by the next. The one inexactness: the time since an item's last pass is charged at
  the rate of where it is now, so an item that moved in between is off by that gap (at most about a game minute).
- `OnRefreshInventoryWindowContainers` fires for the player's own inventory page too (`window.onCharacter`), and that
  page rebuilds many times per change of clothes. Walking its buttons reached a carried cooler once per button leading
  to it (main inventory, the bag holding it, the cooler's own button with a nested-containers mod) on each page: about
  6 `processCooler` runs per rebuild. `onRefreshContainers` now skips `onCharacter` pages; the minute tick walks the
  whole inventory, worn bags included.
- `CF.processCooler` returns right after the ice upkeep and `updateCoolerName` when no game time has passed since its
  last pass (`last ~= nil and dt <= 0`). Placed after the label so a rename held back by `CF.canSync` still goes out on
  the next pass. Cost: food added at that same moment takes its baseline a pass later.
- The expensive part per food item is `Food.updateAge`: with the food chilled below its container's temperature it
  scans the cell's whole processed-items list on every call.
- A user's pastebin patch (2026-10-18) throttled `CF.processTopLevel` to once per container per 3 s with a cached
  result. Not adopted: it throttles every caller (the minute tick, the server's nudged passes), a cached "no work"
  holds back the server nudge for up to 3 s, and a cooler is still walked once per distinct button container
  every 3 s, so the freeze becomes a hitch instead of going away.

## Testing

- `scripts/sim.lua` fakes the PZ API and runs all three Lua files (315 checks). From `scripts/`:
  `PYTHONPATH=<scratch>/lupa py -c "import lupa,io; lupa.LuaRuntime().execute(io.open('sim.lua').read())"`
  (`py -m pip install --target <scratch>/lupa lupa`). It must end with `ALL CHECKS PASSED`.
- When the mod starts calling a new game API, the sim needs a stub for it, or it stops part way with a nil call (1.5.3
  shipped with `player:getPlayerNum()` and `ISInventoryPane.getActualItems` unstubbed; both are in now).
- The main chunk is at Lua's 200-local limit: put new checks in a `local function checkX() ... end checkX()`.
- Check a new test against the old code too (`git show HEAD:<file>` over the live file, run, put it back): it must fail
  there.
- Syntax: `luac -p` from luaj (`org/luaj/luaj-jse/3.0.1`) with the game's JRE; it writes a stray `luac.out` into the
  current folder.

## Conventions

- `modversion` in mod.info and `CF.VERSION` in the shared file must match (the client/server handshake compares them;
  they had drifted to 1.5.3 / 1.5.1 before 1.5.4).
- The Lua source is heavily commented, reasoning included; keep new code in that style.
- Files are CRLF in the working tree: edit with the Edit tool or binary-mode Python, never Git Bash `sed -i`.
