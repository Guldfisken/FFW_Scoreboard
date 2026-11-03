-- FFW_Scoreboard settings. Change what you like and restart the game (or reload mods in UE4SS).
-- Everything left out (or deleted) uses the built-in default, so this file can be kept when you update the mod.

local C = {}

------------------------------------------------------------------ keys (UE4SS Key names, e.g. "F6", "UP_ARROW")
C.keyToggleScoreboard = "F6"           -- live scoreboard on / off
C.keyHistory          = "F8"           -- saved games on / off (also in the lobby / saloon)
C.keyHistoryOlder     = "RIGHT_ARROW"  -- saved games: older game
C.keyHistoryNewer     = "LEFT_ARROW"   -- saved games: newer game
C.keyScrollUp         = "UP_ARROW"     -- scroll up   (when the board is taller than the screen)
C.keyScrollDown       = "DOWN_ARROW"   -- scroll down
C.keyEndSession       = "F10"          -- save the current game now and start a new one
C.keyReset            = "F11"          -- throw away the current numbers without saving

------------------------------------------------------------------ look
C.style         = "styled"  -- "styled" = like the game's menus, "minimal" = plain text on a dark panel
C.fontSize      = 15        -- text size
C.autoFit       = false     -- true = shrink the text (down to C.minFontSize) before scrolling
C.minFontSize   = 15
C.columnGap     = 40        -- space between columns
C.lineHeight    = 1.75      -- row height relative to the text size
C.panelPadding  = 22        -- margin inside the panel
C.bottomMargin  = 140       -- free space below the board (keeps it above the HUD); bigger = shorter board
C.scrollStep    = 120       -- how far one key press scrolls
C.maxRows       = 8         -- most players shown (plus a TEAM row)
C.backgroundOpacity = 0.6   -- dark panel behind the table in the "minimal" style (0 = none, 1 = solid)
-- C.borderTint = { 1, 0.6, 0.2, 1 }   -- recolour the frame (r, g, b, a from 0 to 1)

------------------------------------------------------------------ tables
C.alwaysShowTypes = { "Weapon", "Spells", "Fire", "Acid", "Elec", "Frost", "Voodoo", "Cactus" } -- damage types always listed
C.maxEnemyRows    = nil     -- rows in the Enemies table; nil = all
C.jokersPerRow    = 6       -- jokers per line in the Loadout table
C.showOwnWeaponJokers = true -- show the jokers on your own weapons (other players' are not available)

-- Difficulty names by the game's difficulty number
C.difficultyNames = { [0] = "Easy", [1] = "Normal", [2] = "Hard", [3] = "Very Hard", [4] = "Nightmare" }

-- Rename anything shown on the board. Left = name the mod shows, right = name you want.
C.displayNames = {
  ["Ice Lance"] = "Bridge",
}

-- Joker colours by rarity (r, g, b, a from 0 to 1)
C.jokerRarityColors = {
  [0] = { 0.92, 0.92, 0.92, 1 },   -- white
  [1] = { 0.40, 0.90, 0.40, 1 },   -- green
  [2] = { 0.35, 0.65, 1.00, 1 },   -- blue
  [3] = { 0.75, 0.45, 1.00, 1 },   -- purple
  [4] = { 1.00, 0.60, 0.15, 1 },   -- orange
  [5] = { 1.00, 0.30, 0.30, 1 },   -- red
}

------------------------------------------------------------------ after a game update
-- New enemies show up as "Other" (scoreboard.log names them: "enemy class counted as 'Other': ..."). Name them here
-- without waiting for a mod update: { "Name on the board", "part of the class name" }. These are checked first.
C.extraEnemyTypes = {
  -- { "Scarecrow", "Scarecrow" },
}
C.extraBossPatterns   = {}   -- e.g. { "Scarecrow_Boss" }: counts as boss damage
C.extraElitePatterns  = {}
C.extraDamageCategories = {} -- e.g. { { "Frost", "Blizzard" } }: { "Type on the board", "part of the damage name" }

-- Research tools (off for normal play):
--   C.debug = true : more detail in scoreboard.log, and F9 writes discovery.txt (game functions that look relevant)
--                    and classdump.txt (functions and fields of the main classes)
--   C.learn = true : also logs the arguments of those functions to learn.log (heavier)
C.debug        = false
C.keyDiscovery = "F9"
C.learn        = false

return C
