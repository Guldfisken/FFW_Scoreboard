# Changelog

All notable changes to FFW Scoreboard. Versions follow `MAJOR.MINOR.PATCH` (see [RELEASING.md](RELEASING.md)).

## 1.0.0 – 2026-11-02
First public release.

- Live scoreboard (F6) and saved games (F8), styled like the game's menus, scrollable with Up / Down.
- Per player: kills, damage, boss and elite damage, damage taken, deaths, revives, self and team heal, shield
  generated and friendly fire. Works the same whether you host or join, and other players do not need the mod.
- Damage types (Weapon, Spells, Fire, Acid, Elec, Frost, Voodoo) and damage / kills per enemy type, with bosses
  such as the Cryptic Train and the Halloween boss on their own line.
- Loadout: hero jokers, primary and secondary weapon (with your own weapon jokers), utility, spells and the jokers
  picked up during the mission, coloured by rarity.
- Every finished game is saved with map, difficulty, length and Victory / Defeat.
- `config.lua` holds only your settings and can be kept when updating. New enemies, bosses and damage types can be
  named there (`C.extraEnemyTypes` ...) without waiting for an update.
- Debug mode (`C.debug = true`) with extra logging and F9 discovery, for checking the mod after a game update.
