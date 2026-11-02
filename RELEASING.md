# Releasing

Every change to the mod gets a new version number, and every new version number becomes a GitHub release
automatically.

## Version numbers (`MAJOR.MINOR.PATCH`)

| Change | Example | Bump |
| --- | --- | --- |
| Bug fix, small tweak, performance | Boss damage not counted, wrong colour | `1.0.0` → `1.0.1` |
| New feature or setting | New column, new table, new key | `1.0.1` → `1.1.0` |
| Breaking change | Saved games or `config.lua` from older versions no longer work | `1.1.0` → `2.0.0` |

Commits that only touch documentation or the build workflow (not the `FFW_Scoreboard` folder) do not need a
new version: the zip would be identical.

## For every change to the mod

1. Bump `VERSION` at the top of `FFW_Scoreboard/Scripts/main.lua`.
2. Add a section at the top of `CHANGELOG.md`: `## X.Y.Z – YYYY-MM-DD` with what changed, written for players.
3. Commit (version and changelog in the same commit as the change) and push.

## What happens on push

The `Release` workflow (`.github/workflows/release.yml`) reads `VERSION`:

- **New version:** builds `FFW_Scoreboard_vX.Y.Z.zip` (the `FFW_Scoreboard` folder with README, LICENSE and
  CHANGELOG inside) and publishes a release `vX.Y.Z` with the changelog section as notes.
- **Version already released but the mod changed:** the run fails, as a reminder to bump the version.
- **Version already released, mod unchanged:** nothing happens.

## Nexus Mods

Download the zip from the newest GitHub release and upload it to Nexus as a new file version with the same
version number.
