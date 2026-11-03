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
   One line per entry (`- ...`, no line breaks inside an entry): Nexus Mods takes the changelog one line per entry.
3. Commit (version and changelog in the same commit as the change) and push.

## What happens on push

The `Release` workflow (`.github/workflows/release.yml`) reads `VERSION`:

- **New version:** builds `FFW_Scoreboard_vX.Y.Z.zip` (the `FFW_Scoreboard` folder with README, LICENSE and
  CHANGELOG inside) and publishes a release `vX.Y.Z` with the changelog section as notes.
- **Version already released but the mod changed:** the run fails, as a reminder to bump the version.
- **Version already released, mod unchanged:** nothing happens.

## Nexus Mods

After a new release, the `Nexus Mods upload` workflow (`.github/workflows/nexus.yml`) uploads the same zip to
Nexus Mods as a new version of the mod's main file, with the changelog section as the Nexus changelog. The previous
version is moved to the archive and the mod page's version is updated.

One-time setup (Settings → Secrets and variables → Actions):

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `NEXUSMODS_API_KEY` | Personal API key from nexusmods.com → account settings → API keys |
| Variable | `NEXUS_FILE_ID` | The main file's ID: mod page → Files → the file's "API info" (or Manage files → edit) |
| Variable | `NEXUS_MOD_ID` | The `id` from `https://api.nexusmods.com/v3/games/farfarwest/mods/<number in the mod page URL>` |

Without the secret or `NEXUS_FILE_ID` the upload is skipped with a warning; without `NEXUS_MOD_ID` it is uploaded
without a changelog. The file must already exist on Nexus (the first upload is manual).

To retry or upload an older release by hand: Actions → Nexus Mods upload → Run workflow → enter the version.
