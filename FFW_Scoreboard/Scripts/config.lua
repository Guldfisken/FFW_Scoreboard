-- FFW_Scoreboard configuration. Edit freely; reload mods in UE4SS (or restart the game) to apply.
-- Entries marked [VERIFIED] are function names seen in other working Far Far West mods or in the game's own assets.
-- Entries marked [GUESS] are educated guesses; turn on `learn` once, play a mission, and send back learn.log + discovery.txt.

local C = {}

-- Keys (UE4SS Key.* names)
C.keyToggleScoreboard = "F6"   -- show / hide the live scoreboard
C.keyHistory          = "F8"   -- open / close the list of saved past games (works in lobby / saloon too)
C.keyHistoryOlder     = "RIGHT_ARROW" -- while the history is open: show the previous (older) game
C.keyHistoryNewer     = "LEFT_ARROW"  -- while the history is open: show the next (newer) game
C.keyReset            = "F11"  -- throw away the current numbers without saving (also works in the lobby / saloon)
C.keyEndSession       = "F10"  -- force-save the current game to history and start a fresh one
C.keyDiscovery        = "F9"   -- write discovery.txt (lists candidate game functions)
C.keyScrollUp         = "UP_ARROW"    -- scroll the board up   (only when it is taller than the screen)
C.keyScrollDown       = "DOWN_ARROW"  -- scroll the board down
C.scrollStep          = 120           -- how far one key press scrolls
C.minFontSize         = 15            -- with autoFit on: the text shrinks down to this size, then the board scrolls
C.bottomMargin        = 140           -- free space kept below the board (so it stays above the HUD); bigger = shorter board

-- Overlay look
C.style             = "styled"   -- "styled" = looks like the game's own menus, "minimal" = plain text on a dark panel
C.maxRows           = 8          -- most players shown (plus a TEAM row)
C.fontSize          = 15    -- text size; nil = game default (about 24)
C.autoFit           = false -- false = the text size never changes (the board scrolls when it is too tall);
                            -- true  = shrink the text first (down to C.minFontSize) before scrolling
C.columnGap         = 40    -- space between columns
C.lineHeight        = 1.75  -- row height relative to the font size
C.panelPadding      = 22    -- margin inside the dark panel
C.probeJokers       = false -- true = write extra joker / save diagnostics to scoreboard.log (only needed for debugging)
C.noPollMaps        = { "OpeningCredits", "MainMenu", "Menu", "Intro", "Splash" } -- maps where nothing is read from the game
C.backgroundOpacity = 0.6   -- 0 = no dark panel behind the table, 1 = solid black (minimal style)

-- Game graphics (styled look). Names are textures in /Game/Interfaces/Textures. Press F7 in game to see them all.
C.useGameTextures = true
C.textures = {
  border = "T_Holder_VeryLarge_Edges",   -- graphic used for the outer border of the table (9-slice "border" brush)
}
C.borderTint   = nil   -- {r,g,b,a} 0..1 to recolour the border texture; nil = the style's orange
C.borderMarginX = 0.008 -- share of the texture's width used for the left/right frame (the texture is very wide, so keep this small)
C.borderMarginY = 0.10  -- share of the texture's height used for the top/bottom frame
C.borderOutset = 6     -- pixels the frame sticks out past the table

-- Items whose physical damage is NOT a shot (melee weapons, abilities). Used for "Missed". Names as in the
-- "damage by item for ..." lines of scoreboard.log (without the "item" prefix). Case-sensitive.
C.nonShotItems = { "Knuckles", "Melee", "Machete", "Sword", "Axe", "Katana", "Fist", "Bat", "Hammer", "Shovel",
  "Hero", "SheriffStar", "Mount", "Explosion", "Lasso", "Whip", "Boomerang", "Dynamite", "Grenade", "Cactus", "Turret" }

-- Use the server's damage feed (damage of all players). Set to false to go back to counting only your own damage.
C.useDamageFeed = true

-- Learn mode: logs calls of every candidate function to learn.log. Heavier; only use to find names.
C.learn = false

-- How to recognise things (Lua patterns matched against class / object names)
C.playerClass   = "^BP_Player_C$"
C.playerStateClass = "^BP_PlayerState_C$"
C.bossPatterns  = { "Boss", "Necromancer_B", "Saloon_B", "Cryptic_Train", "CrypticTrain" } -- bosses (plus anything the game flags with isBoss)
C.elitePatterns = { "Elite" }                                          -- classes such as BP_Enemy_Cryptic_Lich_Elite exist; other elites may be a flag (see classdump.txt)
-- Boolean properties on the enemy object that also mark boss / elite (checked if they exist)
C.bossProps  = { "isBoss", "bIsBoss" }                                 -- isBoss exists on BP_Enemy_C [VERIFIED]
C.eliteProps = { "isElite", "bIsElite", "elite" }                      -- isElite exists on BP_Enemy_C [VERIFIED]

-- Damage types that are always listed (even with 0 damage). Others appear when they have damage.
C.alwaysShowTypes = { "Weapon", "Spells", "Fire", "Acid", "Elec", "Frost", "Voodoo" }
-- Damage from an actor whose class name contains one of these (and that is owned by a player) counts as "Spells".
-- Check the "damage feed item/element/causer/type" lines in scoreboard.log for the real class names.
C.spellCauserPatterns = { "Spell", "Turret", "Decoy", "Totem" }
C.maxEnemyRows    = nil   -- rows in the Enemies table; nil = all enemy types (the board scrolls when needed)

-- Difficulty names by the game's difficulty number (see "difficulty: ... (value N ...)" in scoreboard.log).
C.difficultyNames = { [0] = "Easy", [1] = "Normal", [2] = "Hard", [3] = "Very Hard", [4] = "Nightmare" }

-- Renames. Joker names come from the game's own joker table automatically (capitals are turned into normal case);
-- use this list only to rename something. Left = name as the mod shows it, right = name you want to see.
C.displayNames = {
  ["Ice Lance"] = "Bridge",
}

-- Jokers: colour by rarity (number from the game's joker table DT_PlayerJokers, see "joker table" in scoreboard.log).
C.jokerRarityColors = {
  [0] = { 0.92, 0.92, 0.92, 1 },   -- white
  [1] = { 0.40, 0.90, 0.40, 1 },   -- green
  [2] = { 0.35, 0.65, 1.00, 1 },   -- blue
  [3] = { 0.75, 0.45, 1.00, 1 },   -- purple
  [4] = { 1.00, 0.60, 0.15, 1 },   -- orange
  [5] = { 1.00, 0.30, 0.30, 1 },   -- red
}
C.jokersPerRow = 6        -- picked-up jokers per line in the Jokers table
C.labelAliases    = { ["Saloon Boss"] = "Boss", ["Physical"] = "Weapon" }   -- renames labels of older saved games

-- Damage categories: the first entry whose pattern occurs in the damage type's class name wins (case-insensitive).
-- Classes in the game: BP_DamageType_Bullets, _Melee, _Explosion(_Large/_Medium), _Buff_Fire, _Buff_Acid, _Buff_Elec,
-- _Buff_Curse, _Buff_Shroom, _Voodoo, _Mount, _Enviro. Categories without any damage are not shown.
-- Add e.g. { "Frost", "Frost" } if a frost damage type shows up as "Other".
C.damageCategories = {
  { "Weapon", "Bullets" }, { "Weapon", "Melee" },   -- guns and melee are one group ("Weapon")
  { "Fire", "Fire" }, { "Acid", "Acid" }, { "Elec", "Elec" },
  { "Frost", "Frost" }, { "Frost", "Ice" }, { "Frost", "Cold" },
  { "Voodoo", "Voodoo" }, { "Voodoo", "Curse" },
  { "Explosive", "Explosion" }, { "Shroom", "Shroom" },
  { "Mount", "Mount" }, { "Environment", "Enviro" },
}

-- Enemy types: first entry whose pattern occurs in the enemy's class name wins. Elite / ghost variants join their base type.
-- Anything not listed ends up as "Other".
C.enemyTypes = {
  { "Horseman", "Horseman" }, { "Lich", "Lich" }, { "Nuker", "Nuker" }, { "Bull", "Buffalo" },
  { "Deadeye", "DeadEye" }, { "Barricade", "Barricade" }, { "Minigunner", "Gunner" },
  { "Shielder", "Shield" }, { "Grenadier", "Grenadier" }, { "Assassin", "Assassin" }, { "Revolver", "Revolver" },
  { "Kamikaze", "Kamikaze" }, { "Invoker", "Invoker" }, { "Necromancer", "Necromancer" },
  { "Halloween Boss", "Halloween_Boss" }, { "Crow", "HalloweenCrow" }, { "Dummy", "TrainingTarget" },
  { "Boss", "Saloon_B" }, { "Vulture", "Vulture" }, { "Raven", "Raven" }, { "Snake", "Snake" },
  { "Cryptic Train", "Cryptic_Train" }, { "Cryptic Train", "CrypticTrain" }, { "Pumpkin", "Pumpkin" }, { "Marauder", "Marauder" }, { "Grunt", "Grunt" },
  { "Ghost", "Ghost" }, { "Goblin", "Goblin" }, { "Chicken", "Chicken" }, { "Cactus", "Cactus" },
}

-- Shots fired = player bullet actors that appear in the world. Weakspot rate = gun hits whose "critical" flag is set
-- (p4 of F_ShowDamagesAmount) / gun hits. Missed = shots that did not hit. Both need a real mission to verify.
C.shotClasses = {}   -- (bullet-actor counting did not work; shots now come from F_LeaderboardStats_AddShot)

-- Maps in which no game is recorded (lobby / saloon / hub)
C.lobbyMapPatterns = { "Lobby", "Transition", "Hub", "MainMenu", "Menu" } -- map names seen: L_Lobby, L_TransitionMap, L_Map_FarWest, L_Map_Area41

-- Events. `names` are short function names; every Blueprint function with that name is hooked automatically.
--   stat   : which counter to add to
--   amount : "number" = first positive number parameter is the amount, "one" = always +1
C.events = {
  -- Damage feed sent by the server to ALL players: self = enemy, p1 = amount, p2 = owner (player), p3 = damage type,
  -- p4 = item name, p5 = element. Gives the damage of every player, also when you joined someone else's game.
  -- When it fires, the "damage" / "dmgType" events below are switched off automatically.   [seen in learn.log]
  -- Also hooked in enemy classes that override it (e.g. the Cryptic Train), and F_Child_DamageFeedback
  -- (self = enemy, p2 = owner, p3 = amount) used by multi-part enemies such as the Train's wagons. Duplicates are removed.
  feed = {
    names  = { "F_DamageFeedback_Multicast", "F_Child_DamageFeedback" },
    owner  = "/Game/Enemies/",
    amount = "none",
  },
  -- Cryptic Train boss: its locomotive / carts (BP_CrypticTrain_Section*) are not normal enemies and report hits with
  -- F_DamageFeedback(Hit, Owner, Damages, DamageType, Critical, Element, ItemName).
  feedsec = {
    names  = { "F_DamageFeedback" },
    owner  = "/Game/Enemies/Assets/Cryptic/CrypticTrain/",
    amount = "none",
  },
  -- (fallback) self = the enemy that was hit; p2 = amount; p3 = the attacking player.             [VERIFIED in learn.log]
  damage = {
    names  = { "F_ShowDamagesAmount" },
    owner  = "BP_Enemy_C:",
    amount = "number",
  },
  -- Counted once per dead enemy (duplicates from the hooks below are removed).
  -- F_IncrementLeaderboardKillStats: self = dead enemy, p1 = killer.                              [VERIFIED]
  -- F_TriggerOnKillTweaks(_Client): self = killer's PlayerState, p1 = dead enemy.                  [VERIFIED]
  kill = {
    names  = { "F_IncrementLeaderboardKillStats", "F_TriggerOnKillTweaks", "F_TriggerOnKillTweaks_Client" },
    amount = "one",
  },
  -- Damage type of a hit (Bullets, Melee, Buff_Fire ...). Matched to the damage amount above per enemy.
  --   BP_Enemy:F_ServerDamages(self = enemy, p1 = amount, p2 = damage type class, p3 = causer)       [VERIFIED]
  --   BP_PlayerState:F_ClientDamagesServer(p1 = target, p2 = amount, p3 = player, p4 = damage type)  [VERIFIED]
  dmgType = {
    names  = { "F_ServerDamages", "F_ClientDamagesServer" },
    owner  = { "/Game/Enemies/BP_Enemy%.BP_Enemy_C:", "/Game/Player/BP_PlayerState%.BP_PlayerState_C:" },
    amount = "none",
  },
  -- self = PlayerState of the player that died (the game's own leaderboard counter).                [GUESS - same style as revive]
  death = {
    names  = { "F_LeaderboardStats_AddDeath" },
    amount = "one",
  },
  -- (Weakspot / Missed hooks were removed: that data is not broadcast to every player - see README.)
  -- Damage taken. F_ServerDamages (self = player, p1 = amount) runs on the host; F_PlayerReceiveDamagesFeedback
  -- (self = player, p2 = enemy, p3 = amount) runs on the hit player's machine (so it also works when you joined).
  taken = {
    names  = { "F_ServerDamages", "F_PlayerReceiveDamagesFeedback" },
    owner  = "/Game/Player/BP_Player%.BP_Player_C:",
    amount = "number",
  },
  -- self = PlayerState of the reviver (the game's own leaderboard counter).                       [GUESS - not seen in a log yet]
  revive = {
    names  = { "F_LeaderboardStats_AddRevive" },
    amount = "one",
  },
  -- Difficulty (fallback, end of mission): BPFL F_ScaleXpWithDifficulty(Difficulty:int)
  difficulty = {
    names  = { "F_ScaleXpWithDifficulty" },
    amount = "none",
  },
}

-- Functions of Blueprints that only load with their mission (bosses). After each map change they are looked up by
-- exact name for 2 minutes and hooked as soon as they exist.   full function path -> event
C.lateHooks = {
  ["/Game/Enemies/Assets/Cryptic/CrypticTrain/BP_CrypticTrain_Section.BP_CrypticTrain_Section_C:F_DamageFeedback"] = "feedsec",
}

-- Mission result: Blueprint functions whose lower-case name contains one of these words are hooked; the last one that
-- fires during a mission decides Victory / Defeat. Check scoreboard.log ("result hooks" / "result event") to see what was found.
C.resultPatterns = {
  Victory = { "victory", "missionsuccess", "missioncomplete", "missionwon" },
  Defeat  = { "defeat", "gameover", "missionfail", "missionlost" },
}

-- Learn mode only hooks functions whose path matches one of these (Lua patterns)
C.learnOwners = { "/Game/Enemies/BP_Enemy%.", "/Game/Characters/", "/Game/Player/", "/Game/Gamework/BP_Interface", "/Game/Gamework/BPFL_FunctionLibrary", "Channel_Revive", "/Game/Gamework/DamageTypes/" }

-- classdump.txt: functions (with parameters) and properties of these classes, written once at start and on F9
C.dumpClassesOnStart = false
C.dumpClasses = {
  "/Game/Enemies/BP_Enemy.BP_Enemy_C",
  "/Game/Enemies/BP_Enemy_Cryptic_Lich_Elite.BP_Enemy_Cryptic_Lich_Elite_C",
  "/Game/Enemies/BP_Enemy_Cryptic_Necromancer_B.BP_Enemy_Cryptic_Necromancer_B_C",
  "/Game/Player/BP_Player.BP_Player_C",
  "/Game/Player/BP_PlayerState.BP_PlayerState_C",
  "/Game/Player/BP_PlayerGhost.BP_PlayerGhost_C",
  "/Game/Items/BP_Items_Hands_Channel_Revive.BP_Items_Hands_Channel_Revive_C",
  "/Game/Gamework/BP_Interface.BP_Interface_C",
  "/Game/Gamework/BPFL_FunctionLibrary.BPFL_FunctionLibrary_C",
}

-- Name fragments used by discovery / learn mode (case-insensitive)
C.discoveryPatterns = { "damage", "kill", "death", "dead", "die", "revive", "resurrect", "downed", "hurt", "health", "boss", "elite" }

return C
