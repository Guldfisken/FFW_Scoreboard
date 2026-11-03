# FFW Scoreboard

An in-game scoreboard for **Far Far West**, made as a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod.
It shows what every player in the game did — damage, kills, healing, deaths, loadout and jokers — in a panel styled
like the game's own menus, and saves every finished game so you can look back at it later.

It works the same whether you host or join, and the other players do **not** need the mod.

## Features

- **Overview** per player: Kills, Damage, Boss damage, Elite damage, Damage taken, Deaths, Revives, Self heal,
  Team heal, Shield generated, and Friendly fire (only shown when someone hit a teammate). The best value in each
  column is highlighted.
- **Damage types**: Weapon, Spells split by element (e.g. Cactus, Fire), and the elemental effects Fire, Acid and
  Elec (plus any other type that dealt damage).
- **Enemies**: damage and kills per enemy type (bosses such as the Cryptic Train and the Halloween boss get their own line).
- **Loadout**: hero jokers, primary and secondary weapon (with their jokers for yourself), utility, spells, and the
  jokers picked up during the mission (duplicates shown as `x2`, `x3` ...). Jokers are coloured by rarity.
- **Saved games**: every finished game is saved with map, difficulty, date, length and Victory / Defeat, and can be
  browsed later — also from the lobby / saloon.
- Fixed text size; the board scrolls when it is taller than the screen.

## Requirements

- Far Far West (Steam)
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) installed for the game

## Install

1. Install UE4SS into `...\steamapps\common\FarFarWest\FarFarWest\Binaries\Win64\`.
2. Download `FFW_Scoreboard_vX.Y.Z.zip` from [Releases](https://github.com/Guldfisken/FFW_Scoreboard/releases)
   and extract it into `...\Binaries\Win64\ue4ss\Mods\`, so you get `Mods\FFW_Scoreboard\` with `enabled.txt` and
   the `Scripts` folder inside.
3. Start the game and press **F6** during a mission.

To update, replace `Scripts\main.lua`. You can keep your own `Scripts\config.lua`: it only holds your settings,
and anything missing from it uses the built-in default. Your saved games are kept. To uninstall, delete the
`FFW_Scoreboard` folder.

## Keys

| Key | Action |
| --- | --- |
| F6 | Live scoreboard on / off |
| F8 | Saved games on / off |
| Right / Left | Older / newer saved game (while F8 is open) |
| Up / Down | Scroll the board (when it is taller than the screen) |
| F10 | Save the current game now and start a new one |
| F11 | Reset the current numbers without saving (handy on the training dummy) |

All keys can be changed in `Scripts\config.lua`.

## Where the numbers come from

The mod only uses information the game sends to **every** player, so the board is the same for everyone.

- **Damage, damage types, boss / elite damage, enemies** come from the hit feedback the server sends to all players
  on every hit (amount, the player who dealt it, the item and the element). Damage from turrets and other things a
  player owns counts for that player. Mount damage and environment damage are not counted.
- **Kills per enemy type** (the "(kills)" numbers in the Enemies table): when an enemy's health reaches 0, the kill
  goes to the player who hit it last. Enemies killed by something no player caused are not counted there.
- **Kills, Deaths, Revives, Self heal, Team heal** come from the game's own end-of-mission leaderboard. If you join
  mid-game, these are totals for the whole game.
- **Damage types** are based on the item name and element the game reports with each hit, using the game's own list
  of elements:
  - **Weapon**: hits of a player's weapons, melee and hero ability, including joker effects such as "Scrub Hit".
    It is not split into primary and secondary weapon: some weapon damage (such as "Scrub Hit") is reported without
    the weapon's name.
  - **Spells**: damage without a weapon item. The indented rows below it split it by the spell's element (a cactus
    spell such as Pistolero shows under Spells → Cactus).
  - **Fire, Acid, Elec**: damage the game reports under the element itself, such as burning and corrosion ticks.
    These are not linked to the weapon that applied them (the game does not say which one did).
- **Shield** is the sum of every increase of a player's shield.
- **Damage taken** is the health each player lost (every drop of their health, which the game sends to every player).
  Damage absorbed by a shield is not included.

## Limitations

Most numbers are the same for everyone in the game. These are not:

- **When you join someone else's game, your teammates' damage and kills can be too low.** Part of their hits reach
  your game without saying who dealt them, so they cannot be counted. The Kills column itself comes from the game's
  own leaderboard and is always right; the damage and the kills per enemy type can be lower. As host you see
  everyone's.
- **Cryptic Train boss: teammates' damage is only tracked when you host.** The train's carriages only report hits
  to the player who fired and to the host. When you join someone else's game, you see your own train damage, and
  your teammates show 0 boss damage for the train.
- **Friendly fire**: as host you see everyone's; when you join you mainly see your own.
- **Weakspot hits and missed shots are not tracked.** They are not part of what the server sends to everyone, so
  they could not be shown consistently.
- **Weapon jokers are shown for yourself only.** They are stored in each player's own save, not synced.
- **Picked-up jokers** of other players may not be visible when you join someone else's game.
- The difficulty name mapping (`C.difficultyNames`) has not been verified for every difficulty yet.

## Files the mod writes (in `Scripts\`)

| File | Content |
| --- | --- |
| `history.csv` | One line per player per finished game (opens in Excel) |
| `breakdown.csv` | Damage types, enemies, result and difficulty per game |
| `loadouts.csv` | Loadout and jokers per player per game |
| `current.csv` | Autosave of the running game |
| `scoreboard.log` | What the mod found and did (useful for bug reports). A new log starts with every game start; the previous one is kept as `scoreboard.old.log` |

## Settings (`Scripts\config.lua`)

`config.lua` only contains settings; delete a line to go back to the default.

- Keys, text size (`C.fontSize`), spacing (`C.columnGap`, `C.panelPadding`), space below the board (`C.bottomMargin`).
- `C.alwaysShowTypes`, `C.maxEnemyRows`, `C.jokersPerRow`: what the tables show.
- `C.displayNames`, `C.difficultyNames`, `C.jokerRarityColors`: names and colours.

The mod's knowledge of the game (which functions it hooks, enemy and damage type names) lives in `main.lua`, so it
is updated together with the mod.

## After a game update

**New enemies** show up as "Other", and `scoreboard.log` names their class (`enemy class counted as 'Other': ...`).
You can name them yourself without waiting for a mod update:

```lua
C.extraEnemyTypes = { { "Scarecrow", "Scarecrow" } }   -- { name on the board, part of the class name }
C.extraBossPatterns = { "Scarecrow_Boss" }             -- also count it as boss damage
```

`C.extraElitePatterns` and `C.extraDamageCategories` work the same way.

**Debug mode.** Set `C.debug = true` to check the mod against a new game version (renamed functions and the
like). `scoreboard.log` then gets more detail, and **F9** writes `discovery.txt` (game functions that look
relevant) and `classdump.txt` (functions and fields of the main classes). `C.learn = true` also logs the arguments
of those functions to `learn.log`. Turn both off again for normal play.

The mod hooks the game functions it needs by their exact names (listed in `main.lua`, `C.hookPaths`). If a game update
renames one, the matching numbers stay empty; `discovery.txt` (F9 in debug mode) helps to find the new name.

## Reporting a problem

Open an issue and attach `Scripts\scoreboard.log` and, if the game crashed, `ue4ss\UE4SS.log`.

## License

[GPL-3.0](LICENSE). You may use, change and share this mod; shared changed versions must stay GPL-3.0 and include
their source.
