# Changelog

## 1.0.0 – 2026-10-30
First public release.

- Live scoreboard (F6) and saved games (F8) styled like the game's menus.
- Damage, boss / elite damage, damage taken, kills, deaths, revives, self / team heal, shield and friendly fire per player.
- Damage types including Spells; damage and kills per enemy type, bosses on their own line.
- Loadout with hero jokers, weapons, utility, spells and picked-up jokers, coloured by rarity.
- Map, difficulty, length and Victory / Defeat saved with each game.
- Fixed text size with scrolling.
- Removed the F7 texture gallery (a development tool).
- Victory / Defeat uses the game's own answer (lost games could be saved as Victory before).
- config.lua holds only player settings; the game knowledge lives in main.lua, so a kept config.lua never blocks fixes.
- New enemies, bosses and damage types can be named in config.lua (C.extraEnemyTypes ...).
- Research tools (F9 discovery, extra logging) are off unless C.debug = true.
- Performance: far fewer game look-ups per hit, the board only moves what changed, weapon jokers are read once per
  mission and saved games are read from disk only after a new game was saved.
