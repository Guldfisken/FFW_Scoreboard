-- FFW_Scoreboard (UE4SS Lua mod for Far Far West)
-- Tracks per-player damage, kills, healing, deaths, loadout and jokers, shows them in an in-game overlay,
-- saves each finished game and lets you browse past games. https://github.com/Guldfisken/FFW_Scoreboard
-- License: GPL-3.0

local VERSION = "1.0.0"

local UEHelpers_ok, UEHelpers = pcall(require, "UEHelpers")

local DIR = (debug.getinfo(1, "S").source:match("^@?(.*[\\/])")) or "./"
local CFG_OK, C = pcall(dofile, DIR .. "config.lua")
if not CFG_OK then
  print("[FFW_Scoreboard] could not load config.lua: " .. tostring(C))
  return
end

local feedTally      -- damage feed tally per function + enemy class (diagnostics), set up below
local STATS_SET = { kills = true, damage = true, bossDamage = true, eliteDamage = true, taken = true, revives = true, deaths = true, selfHeal = true, teamHeal = true }
local STATS = { "kills", "damage", "bossDamage", "eliteDamage", "taken", "revives", "deaths", "selfHeal", "teamHeal", "ff", "shield" }

------------------------------------------------------------------ logging
-- A fresh scoreboard.log is started each time the game starts; the previous one is kept as scoreboard.old.log.
local LOGFILE = DIR .. "scoreboard.log"
pcall(os.remove, DIR .. "scoreboard.old.log")
pcall(os.rename, LOGFILE, DIR .. "scoreboard.old.log")
local function log(msg)
  msg = "[FFW_Scoreboard] " .. tostring(msg)
  print(msg .. "\n")
  local f = io.open(LOGFILE, "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n"); f:close() end
end
-- extra detail for finding things after a game update (C.debug = true)
local function dlog(msg) if C.debug then log(msg) end end

local function safe(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

------------------------------------------------------------------ small helpers
local function isObjType(v) return type(v) == "userdata" or type(v) == "table" end

local function unwrap(p)
  if isObjType(p) then
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
  end
  return p
end

local function isValidObj(o)
  if not isObjType(o) then return false end
  local ok, v = pcall(function() return o:IsValid() end)
  return ok and v == true
end

local function className(o)
  return safe(function() return o:GetClass():GetFName():ToString() end) or ""
end

local function fullName(o)
  return safe(function() return o:GetFullName() end) or ""
end

local function matchesAny(str, patterns)
  for _, p in ipairs(patterns or {}) do
    if str:find(p) then return true end
  end
  return false
end

local function boolProp(o, names)
  for _, n in ipairs(names or {}) do
    local v = safe(function() return o[n] end)
    if v == true then return true end
  end
  return false
end

local function sanitize(s) return (tostring(s):gsub("[,\r\n]", " ")) end

------------------------------------------------------------------ players
local function isPlayerState(o)
  return isValidObj(o) and className(o):find(C.playerStateClass or "^BP_PlayerState_C$") ~= nil
end

local function isPlayer(o)
  return isValidObj(o) and (className(o):find(C.playerClass) ~= nil or isPlayerState(o))
end

local nameCache = setmetatable({}, { __mode = "k" })
local function playerName(o)
  if nameCache[o] then return nameCache[o] end
  local name
  local ps = o
  if not isPlayerState(o) then ps = safe(function() return o.PlayerState end) end
  if isValidObj(ps) then
    local s = safe(function() return ps:GetPlayerName():ToString() end)
    if s and s ~= "" then name = s end
  end
  if not name then
    local short = fullName(o):match("([^%.:]+)$") or "Player"
    name = short
  end
  nameCache[o] = name
  return name
end

local function localPlayer()
  local list = safe(FindAllOf, "BP_Player_C")
  if not list then return nil end
  for _, p in ipairs(list) do
    if isValidObj(p) then
      local lc = safe(function() return p:IsLocallyControlled() end)
      if lc == true then return p end
    end
  end
  return nil
end

------------------------------------------------------------------ session / stats model
local Session = nil
local Boards = {}      -- latest replicated leaderboard per player name (see 'leaderboard sync')
local MergeBoards      -- assigned below
local sessionCounter = 0

local function newSession(mapName)
  sessionCounter = sessionCounter + 1
  Session = {
    id = os.time() * 100 + (sessionCounter % 100),
    start = os.time(),
    map = mapName or "?",
    players = {},
    order = {},
    loadouts = {},   -- player name -> { slot = item }
  }
  Boards = {}
end

local function statsFor(name)
  local s = Session.players[name]
  if not s then
    s = {}
    for _, k in ipairs(STATS) do s[k] = 0 end
    s.cat, s.ek, s.ed = {}, {}, {}   -- damage by category / kills by enemy type / damage by enemy type
    s.wd = {}                         -- damage by weapon / item name (from the damage feed)
    Session.players[name] = s
    table.insert(Session.order, name)
  end
  return s
end

local function record(name, stat, amount)
  if not Session then newSession("?") end
  local s = statsFor(name)
  s[stat] = s[stat] + amount
end

local function addTo(t, k, n) t[k] = (t[k] or 0) + n end
local function recordCat(name, cat, amount) if not Session then newSession("?") end addTo(statsFor(name).cat, cat, amount) end
local function recordEnemy(name, label, kills, dmg)
  if not Session then newSession("?") end
  local s = statsFor(name)
  if kills and kills > 0 then addTo(s.ek, label, kills) end
  if dmg and dmg > 0 then addTo(s.ed, label, dmg) end
end

local function sessionHasData(sess)
  for _, s in pairs(sess.players) do
    for _, k in ipairs(STATS) do if s[k] > 0 then return true end end
  end
  return false
end

------------------------------------------------------------------ persistence
local HISTORY = DIR .. "history.csv"
local CURRENT = DIR .. "current.csv"
local CSV_HEADER = "session,start,end,map,player,kills,damage,bossDamage,eliteDamage,taken,revives"

local function sessionRows(sess, endTime)
  local rows = {}
  for _, name in ipairs(sess.order) do
    local s = sess.players[name]
    rows[#rows + 1] = table.concat({
      sess.id, sess.start, endTime or os.time(), sanitize(sess.map), sanitize(name),
      math.floor(s.kills), string.format("%.0f", s.damage), string.format("%.0f", s.bossDamage),
      string.format("%.0f", s.eliteDamage), string.format("%.0f", s.taken), math.floor(s.revives),
    }, ",")
  end
  return rows
end

local BREAKDOWN = DIR .. "breakdown.csv"
local BREAK_HEADER = "session,player,kind,name,value"

local function appendBreakdown(sess)
  local lines = {}
  if sess.result then lines[#lines + 1] = table.concat({ sess.id, "_game", "result", sess.result, "1" }, ",") end
  if sess.difficulty then lines[#lines + 1] = table.concat({ sess.id, "_game", "difficulty", sanitize(sess.difficulty), "1" }, ",") end
  for _, name in ipairs(sess.order) do
    local s = sess.players[name]
    local misc = { deaths = s.deaths, ff = s.ff, shield = s.shield, selfHeal = s.selfHeal, teamHeal = s.teamHeal }
    for kind, tbl in pairs({ cat = s.cat, ek = s.ek, ed = s.ed, wd = s.wd or {}, misc = misc }) do
      for label, v in pairs(tbl) do
        lines[#lines + 1] = table.concat({ sess.id, sanitize(name), kind, sanitize(label), string.format("%.0f", v) }, ",")
      end
    end
  end
  if #lines == 0 then return end
  local exists = io.open(BREAKDOWN, "r")
  if exists then exists:close() end
  local f = io.open(BREAKDOWN, "a")
  if not f then return end
  if not exists then f:write(BREAK_HEADER .. "\n") end
  for _, l in ipairs(lines) do f:write(l .. "\n") end
  f:close()
end

local LOADOUTS = DIR .. "loadouts.csv"
local function appendLoadouts(sess)
  local lines = {}
  for _, name in ipairs(sess.order) do
    local lo = (sess.loadouts or {})[name]
    if lo then
      local slots = {}
      for slot in pairs(lo) do slots[#slots + 1] = slot end
      table.sort(slots)
      for _, slot in ipairs(slots) do
        lines[#lines + 1] = table.concat({ sess.id, sanitize(sess.map), sanitize(name), sanitize(slot), sanitize(lo[slot]) }, ",")
      end
    end
  end
  if #lines == 0 then return end
  local exists = io.open(LOADOUTS, "r")
  if exists then exists:close() end
  local f = io.open(LOADOUTS, "a")
  if not f then return end
  if not exists then f:write("session,map,player,slot,item\n") end
  for _, l in ipairs(lines) do f:write(l .. "\n") end
  f:close()
end

local function appendHistory(sess)
  local rows = sessionRows(sess)
  if #rows == 0 then return end
  pcall(appendLoadouts, sess)
  pcall(appendBreakdown, sess)
  local exists = io.open(HISTORY, "r")
  if exists then exists:close() end
  local f = io.open(HISTORY, "a")
  if not f then log("cannot write history.csv"); return end
  if not exists then f:write(CSV_HEADER .. "\n") end
  for _, r in ipairs(rows) do f:write(r .. "\n") end
  f:close()
end

local function autosaveCurrent()
  if not Session or not sessionHasData(Session) then return end
  local f = io.open(CURRENT, "w")
  if not f then return end
  f:write(CSV_HEADER .. "\n")
  for _, r in ipairs(sessionRows(Session)) do f:write(r .. "\n") end
  f:close()
end

local function loadHistory()
  local games, byId = {}, {}
  local f = io.open(HISTORY, "r")
  if not f then return games end
  for line in f:lines() do
    local id, st, en, map, player, k, d, b, e, t, r =
      line:match("^(%d+),(%d+),(%d+),([^,]*),([^,]*),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$")
    if id then
      local g = byId[id]
      if not g then
        g = { id = id, start = tonumber(st), finish = tonumber(en), map = map, rows = {} }
        byId[id] = g
        games[#games + 1] = g
      end
      g.rows[#g.rows + 1] = { player, k, d, b, e, t, r }
    end
  end
  f:close()
  -- breakdown (damage types / enemy types), optional file
  local bf = io.open(BREAKDOWN, "r")
  if bf then
    for line in bf:lines() do
      local id, player, kind, name, v = line:match("^(%d+),([^,]*),(%a+),([^,]*),(%d+)$")
      local g = id and byId[id]
      if g and player == "_game" then
        if kind == "result" then g.result = name end
        if kind == "difficulty" then g.difficulty = name end
      elseif g then
        g.break_ = g.break_ or {}
        local pb = g.break_[player] or { cat = {}, ek = {}, ed = {}, wd = {}, misc = {} }
        g.break_[player] = pb
        if pb[kind] then pb[kind][name] = tonumber(v) end
      end
    end
    bf:close()
  end
  -- loadouts (session,map,player,slot,item), optional file
  local lf = io.open(LOADOUTS, "r")
  if lf then
    for line in lf:lines() do
      local id, _, player, slot, item = line:match("^(%d+),([^,]*),([^,]*),([^,]*),([^,]*)$")
      local g = id and byId[id]
      if g then
        g.loadouts = g.loadouts or {}
        g.loadouts[player] = g.loadouts[player] or {}
        g.loadouts[player][slot] = item
      end
    end
    lf:close()
  end
  table.sort(games, function(a, b) return a.start > b.start end) -- newest first
  return games
end

------------------------------------------------------------------ overlay (UMG, built from Lua)
local UI = { widget = nil, visible = false, mode = nil, texts = {}, imgs = {} }

local BASE_X, BASE_Y = 60, 130
local FONT_DEFAULT = 24

-- Colours are {R, G, B, A} in 0..1
local STYLES = {
  minimal = {
    useGameFont = false,
    panel = { 0, 0, 0, 0.6 }, border = nil,
    title = { 1, 1, 1, 1 }, sub = { 0.85, 0.85, 0.85, 1 }, head = { 1, 1, 1, 1 },
    name = { 1, 1, 1, 1 }, num = { 1, 1, 1, 1 }, footer = { 0.8, 0.8, 0.8, 1 },
    best = { 0.40, 0.92, 0.40, 1 },
    rowBar = nil, rowEdge = nil, teamBar = nil, titleScale = 1.0, upperHeaders = false,
  },
  styled = {   -- modelled on the game's settings menu: dark translucent panels, white labels, yellow values
    useGameFont = true,
    panel = { 0.12, 0.09, 0.08, 0.88 }, border = { 0.62, 0.46, 0.28, 1 },
    title = { 0.98, 0.86, 0.60, 1 }, sub = { 0.78, 0.70, 0.60, 1 }, head = { 0.95, 0.80, 0.52, 1 },
    name = { 1, 1, 1, 1 }, num = { 1.0, 0.76, 0.05, 1 }, footer = { 0.72, 0.65, 0.56, 1 },
    best = { 0.40, 0.92, 0.40, 1 },
    rowBar = { 0.20, 0.17, 0.15, 0.92 }, rowEdge = { 0.07, 0.05, 0.04, 1 },
    teamBar = { 0.30, 0.24, 0.17, 0.92 }, titleScale = 1.5, upperHeaders = false,
  },
}

STYLES.minimal.panel[4] = C.backgroundOpacity or 0.6

local function style() return STYLES[tostring(C.style or "styled"):lower()] or STYLES.styled end

local function fontObjectOk(o)
  if not isValidObj(o) then return false end
  local cn = className(o)
  return cn == "Font" or cn == "FontFace"
end

-- Find the game's own fonts (so the overlay matches the HUD). Falls back to the default font.
local function loadFonts()
  if UI.fontsLoaded then return end
  UI.fontsLoaded = true
  local function try(path)
    local o = safe(StaticFindObject, path)
    if fontObjectOk(o) then return o end
  end
  UI.fontText = try("/Game/Materials/Fonts/Font_Text.Font_Text") or try("/Game/Materials/Fonts/FarFarWest_Text.FarFarWest_Text")
  UI.fontTitle = try("/Game/Materials/Fonts/Font_Title.Font_Title") or try("/Game/Materials/Fonts/FarFarWest_Title.FarFarWest_Title") or UI.fontText
  local source = UI.fontText and "game font asset" or nil
  if not UI.fontText then
    -- borrow the font of an existing HUD text block
    local list = safe(FindAllOf, "TextBlock")
    if list then
      for i, tb in ipairs(list) do
        if i > 400 then break end
        local fo = safe(function() return tb.Font.FontObject end)
        if fontObjectOk(fo) then UI.fontText = fo; UI.fontTitle = fo; source = "borrowed from " .. fullName(tb); break end
      end
    end
  end
  log("fonts: " .. (source or "none found, using default font"))
end

local function applyFont(tb, size, isTitle)
  pcall(function()
    local f = tb.Font
    local fo = isTitle and UI.fontTitle or UI.fontText
    if style().useGameFont and fo then pcall(function() f.FontObject = fo end) end
    f.Size = size
    tb:SetFont(f)
  end)
end

-- Unreal colours are linear; the palette below is written as normal (sRGB) colours, so convert.
local function lin(v) return v ^ 2.2 end

local function setColor(tb, c)
  pcall(function()
    tb:SetColorAndOpacity({ SpecifiedColor = { R = lin(c[1]), G = lin(c[2]), B = lin(c[3]), A = c[4] }, ColorUseRule = 0 })
  end)
end

local function setImageColor(img, c)
  pcall(function() img:SetColorAndOpacity({ R = lin(c[1]), G = lin(c[2]), B = lin(c[3]), A = c[4] }) end)
end

local function loadTexture(name)
  if not name or name == "" then return nil end
  local path = "/Game/Interfaces/Textures/" .. name .. "." .. name
  -- (only textures the game has already loaded are used; forcing a load can crash while a level streams in)
  local o = safe(StaticFindObject, path)
  if isValidObj(o) then return o end
  return nil
end

local IMG_POOL, TEXT_POOL = 80, 140

local function addPoolImage()
  local n = #UI.imgs + 1
  local img = StaticConstructObject(UI.classes.Image, UI.tree, FName("FFWSB_I" .. n))
  local slot = UI.canvas:AddChildToCanvas(img)
  slot:SetAutoSize(false)
  slot:SetPosition({ X = 0, Y = 0 })
  slot:SetSize({ X = 0, Y = 0 })
  UI.imgs[n] = { img = img, slot = slot }
  return UI.imgs[n]
end

local function addPoolText()
  local n = #UI.texts + 1
  local t = StaticConstructObject(UI.classes.TextBlock, UI.tree, FName("FFWSB_T" .. n))
  local slot = UI.canvas:AddChildToCanvas(t)
  slot:SetAutoSize(true)
  slot:SetPosition({ X = 0, Y = 0 })
  pcall(function() t:SetShadowOffset({ X = 1.5, Y = 1.5 }) end)
  pcall(function() t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.75 }) end)
  UI.texts[n] = { tb = t, slot = slot, str = "", size = nil, big = nil, ckey = nil }
  return UI.texts[n]
end

local function buildUI()
  local okAll, err = pcall(function()
    local st = style()
    local gi = UEHelpers_ok and UEHelpers.GetGameInstance() or nil
    if not isValidObj(gi) then error("no game instance") end
    local UserWidget = StaticFindObject("/Script/UMG.UserWidget")
    local WidgetTree = StaticFindObject("/Script/UMG.WidgetTree")
    local CanvasPanel = StaticFindObject("/Script/UMG.CanvasPanel")
    UI.builds = (UI.builds or 0) + 1
    local w = StaticConstructObject(UserWidget, gi, FName("FFWScoreboardWidget" .. UI.builds))
    w.WidgetTree = StaticConstructObject(WidgetTree, w, FName("FFWScoreboardTree"))
    local canvas = StaticConstructObject(CanvasPanel, w.WidgetTree, FName("FFWScoreboardCanvas"))
    w.WidgetTree.RootWidget = canvas
    UI.tree, UI.canvas = w.WidgetTree, canvas
    UI.classes = { Image = StaticFindObject("/Script/UMG.Image"), TextBlock = StaticFindObject("/Script/UMG.TextBlock") }
    UI.texts, UI.imgs = {}, {}
    if st.useGameFont then loadFonts() end

    -- panel pieces (drawn underneath everything else)
    local function fixedImage(name, color)
      local img = StaticConstructObject(UI.classes.Image, UI.tree, FName(name))
      local slot = canvas:AddChildToCanvas(img)
      slot:SetAutoSize(false); slot:SetPosition({ X = 0, Y = 0 }); slot:SetSize({ X = 0, Y = 0 })
      setImageColor(img, color)
      return img, slot
    end
    UI.border, UI.borderSlot = fixedImage("FFWSB_Border", st.border or { 0, 0, 0, 0 })
    UI.panel, UI.panelSlot = fixedImage("FFWSB_Panel", st.panel)
    -- graphic frame (9-slice "Border" brush: only the edges of the texture are drawn, the centre stays open)
    UI.frame, UI.frameSlot = fixedImage("FFWSB_Frame", { 1, 1, 1, 1 })
    UI.frameOk = false
    if st.border and C.useGameTextures ~= false then
      local texName = (C.textures or {}).border
      local tex = loadTexture(texName)
      if tex then
        local ok = pcall(function()
          UI.frame:SetBrushFromTexture(tex, false)
          local br = UI.frame.Brush
          br.DrawAs = 2 -- ESlateBrushDrawType::Border
          local mx, my = C.borderMarginX or 0.008, C.borderMarginY or 0.1
          br.Margin = { Left = mx, Top = my, Right = mx, Bottom = my }
          UI.frame:SetBrush(br)
        end)
        local dn = tonumber(safe(function() return UI.frame.Brush.DrawAs end))
        if ok and (dn == nil or dn == 2) then
          UI.frameOk = true
          setImageColor(UI.frame, C.borderTint or st.border)
        end
      end
      log("border texture " .. tostring(texName) .. ": " .. (UI.frameOk and "applied" or "not available, using a colour border"))
    end
    if not UI.frameOk then setImageColor(UI.frame, { 0, 0, 0, 0 }) end

    -- row bars first (so all text is drawn above them), then the text pool
    for _ = 1, IMG_POOL do addPoolImage() end
    for _ = 1, TEXT_POOL do addPoolText() end

    local first = UI.texts[1]
    applyFont(first.tb, C.fontSize or FONT_DEFAULT, false)
    UI.fontApplied = (C.fontSize == nil) or (tonumber(safe(function() return first.tb.Font.Size end)) == C.fontSize)
    UI.gameFontApplied = false
    if st.useGameFont and UI.fontText then
      local applied = safe(function() return first.tb.Font.FontObject:GetFullName() end)
      UI.gameFontApplied = applied ~= nil and applied == fullName(UI.fontText)
    end
    log(string.format("overlay built: style=%s fontSizeApplied=%s gameFontApplied=%s",
      tostring(C.style or "styled"), tostring(UI.fontApplied), tostring(UI.gameFontApplied)))

    w:AddToViewport(200)
    w:SetVisibility(1) -- Collapsed until shown
    UI.widget = w
  end)
  if not okAll then
    log("overlay could not be created (" .. tostring(err) .. "). Stats still go to the log/CSV files.")
    UI.widget = nil
  end
  return UI.widget ~= nil
end

local function ensureUI()
  if UI.widget and isValidObj(UI.widget) then return true end
  UI.widget = nil
  return buildUI()
end

local function place(slot, x, y, ax, ay)
  safe(function()
    slot:SetPosition({ X = x, Y = y })
    slot:SetAlignment({ X = ax or 0, Y = ay or 0 })
  end)
end

local function box(slot, x, y, w, h)
  safe(function()
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
  end)
end

local function commas(n)
  local s = string.format("%.0f", n)
  local neg = s:sub(1, 1) == "-"
  if neg then s = s:sub(2) end
  s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (neg and "-" or "") .. s
end

-- Draw a list of items. text item: {t=string, x, y, ax, color, size, title}; bar item: {bar=true, x, y, w, h, color}
local function drawItems(texts, bars)
  local nT = 0
  for _, it in ipairs(texts) do
    nT = nT + 1
    local e = UI.texts[nT] or addPoolText()
    if e.str ~= it.t then e.str = it.t; safe(function() e.tb:SetText(FText(it.t)) end) end
    local big = it.title and true or false
    if e.size ~= it.size or e.big ~= big then e.size = it.size; e.big = big; applyFont(e.tb, it.size, big) end
    local ckey = it.color[1] .. "," .. it.color[2] .. "," .. it.color[3]
    if e.ckey ~= ckey then e.ckey = ckey; setColor(e.tb, it.color) end
    place(e.slot, it.x, it.y, it.ax or 0, 0.5)
  end
  for j = nT + 1, #UI.texts do
    local e = UI.texts[j]
    if e.str ~= "" then e.str = ""; safe(function() e.tb:SetText(FText("")) end) end
  end
  local nB = 0
  for _, it in ipairs(bars) do
    if nB < #UI.imgs then
      nB = nB + 1
      local e = UI.imgs[nB]
      local ckey = it.color[1] .. "," .. it.color[2] .. "," .. it.color[3] .. "," .. it.color[4]
      if e.ckey ~= ckey then e.ckey = ckey; setImageColor(e.img, it.color) end
      box(e.slot, it.x, it.y, it.w, it.h)
    end
  end
  for j = nB + 1, #UI.imgs do box(UI.imgs[j].slot, 0, 0, 0, 0) end
end

-- view = { title, subtitle, footer, sections = { { title, heads = {...}, rows = { { cells = {...}, best = {[col]=true}, team = bool } } } } }
local function renderAt(view, fOverride, dry, maxH)
  if not ensureUI() then return false end
  local st = style()
  local f = fOverride or C.fontSize or FONT_DEFAULT
  if not fOverride and C.fontSize and UI.fontApplied == false then f = FONT_DEFAULT end
  local ratio = (st.useGameFont and UI.gameFontApplied) and 0.52 or 0.64
  local rowH = f * (C.lineHeight or 1.75)
  local pad = C.panelPadding or 24
  local gap = C.columnGap or 44
  local titleSize = f * st.titleScale
  local function tw(str, size) return #tostring(str) * size * ratio end

  -- column widths per section
  local innerW = math.max(tw(view.title or "", titleSize), tw(view.subtitle or "", f * 0.8), tw(view.footer or "", f * 0.75))
  for _, sec in ipairs(view.sections) do
    local n = #sec.heads
    sec.widths = {}
    local total = gap * (n - 1)
    for c = 1, n do
      local m = tw(sec.heads[c], f)
      for _, r in ipairs(sec.rows) do m = math.max(m, tw(r.cells[c] or "", f)) end
      sec.widths[c] = math.max(m, 56)
      total = total + sec.widths[c]
    end
    sec.total = total
    innerW = math.max(innerW, total)
  end

  local texts, bars = {}, {}
  local left = BASE_X + pad
  local y = BASE_Y + pad * 0.5
  local function addText(str, x, yc, ax, color, size, title)
    texts[#texts + 1] = { t = tostring(str), x = x, y = yc, ax = ax, color = color, size = size, title = title }
  end

  local titleH = titleSize * 1.3
  addText(view.title or "", left, y + titleH / 2, 0, st.title, titleSize, true)
  y = y + titleH
  if view.subtitle and view.subtitle ~= "" then
    addText(view.subtitle, left, y + f * 0.7, 0, st.sub, f * 0.8, false)
    y = y + f * 1.5
  end
  y = y + f * 0.4
  local bodyTop, headTexts = y, #texts

  for _, sec in ipairs(view.sections) do
    local n = #sec.heads
    if sec.title then
      addText(sec.title, left, y + f * 0.8, 0, st.title, f * 1.2, true)
      y = y + f * 1.8
    end
    -- stretch the columns so every table is as wide as the widest one
    local extra = (n > 1) and ((innerW - sec.total) / (n - 1)) or 0
    local colRight, colLeft, x = {}, {}, left
    for c = 1, n do
      colLeft[c] = x
      colRight[c] = x + sec.widths[c]
      x = x + sec.widths[c] + gap + extra
    end
    local function colX(c) if c == 1 or sec.leftAlign then return colLeft[c] end return colRight[c] end
    local function colA(c) if c == 1 or sec.leftAlign then return 0 end return 1 end
    for c = 1, n do
      addText(sec.heads[c], colX(c), y + rowH / 2, colA(c), st.head, f, false)
    end
    y = y + rowH
    for _, r in ipairs(sec.rows) do
      if st.rowBar then
        bars[#bars + 1] = { x = BASE_X + pad * 0.4, y = y + 1, w = innerW + pad * 1.2, h = rowH - 4, color = r.team and st.teamBar or st.rowBar }
        bars[#bars + 1] = { x = BASE_X + pad * 0.4, y = y + rowH - 3, w = innerW + pad * 1.2, h = 2, color = st.rowEdge }
      end
      for c = 1, n do
        local color = st.num
        if c == 1 then color = st.name
        elseif r.colors and r.colors[c] then color = r.colors[c]
        elseif r.best and r.best[c] then color = st.best
        elseif sec.dimLast and c == n then color = st.sub end
        addText(r.cells[c] or "", colX(c), y + rowH / 2 - 1, colA(c), color, f, false)
      end
      y = y + rowH
    end
    y = y + f * 0.5
  end

  -- scrolling: when the panel would be taller than maxH, the title stays, the tables scroll, the footer stays at the bottom
  local footerH = (view.footer and view.footer ~= "") and f * 1.3 or 0
  local fullH = y + footerH + pad * 0.4 - BASE_Y
  local footer = view.footer
  UI.maxScroll = 0
  if maxH and not dry and fullH > maxH then
    local visBottom = BASE_Y + maxH - pad * 0.4 - footerH
    local bodyH = y - bodyTop
    local maxScroll = math.max(0, bodyH - (visBottom - bodyTop))
    UI.maxScroll = maxScroll
    UI.scroll = math.max(0, math.min(UI.scroll or 0, maxScroll))
    local sc = UI.scroll
    local keepT = {}
    for i, it in ipairs(texts) do
      if i <= headTexts then keepT[#keepT + 1] = it
      else
        it.y = it.y - sc
        if it.y >= bodyTop + f * 0.3 and it.y <= visBottom - f * 0.3 then keepT[#keepT + 1] = it end
      end
    end
    texts = keepT
    local keepB = {}
    for _, b in ipairs(bars) do
      b.y = b.y - sc
      if b.y >= bodyTop - 1 and b.y + b.h <= visBottom + 1 then keepB[#keepB + 1] = b end
    end
    bars = keepB
    y = visBottom
    local pctTxt = maxScroll > 0 and string.format("  (%d%%)", math.floor(100 * sc / maxScroll + 0.5)) or ""
    footer = (footer or "") .. string.format("    %s / %s: scroll%s", (C.keyScrollUp or "UP_ARROW"):gsub("_ARROW$", ""),
      (C.keyScrollDown or "DOWN_ARROW"):gsub("_ARROW$", ""), pctTxt)
  end
  if footer and footer ~= "" then
    addText(footer, left, y + f * 0.5, 0, st.footer, f * 0.75, false)
    y = y + f * 1.3
  end

  local panelW = innerW + pad * 2
  local panelH = y + pad * 0.4 - BASE_Y
  if dry then return fullH, panelW end
  if st.border and not UI.frameOk then box(UI.borderSlot, BASE_X - 5, BASE_Y - 5, panelW + 10, panelH + 10)
  else box(UI.borderSlot, 0, 0, 0, 0) end
  box(UI.panelSlot, BASE_X, BASE_Y, panelW, panelH)
  if UI.frameOk then
    local o = C.borderOutset or 6
    box(UI.frameSlot, BASE_X - o, BASE_Y - o, panelW + 2 * o, panelH + 2 * o)
  end
  drawItems(texts, bars)
  return true
end

-- Height of the screen in UMG units (pixels / DPI scale); nil if it cannot be read.
local function screenUnitsHeight()
  if C.screenHeight then return tonumber(C.screenHeight) end
  local h = nil
  pcall(function()
    local pc = UEHelpers_ok and UEHelpers.GetPlayerController() or nil
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if pc and lib then
      local size = lib:GetViewportSize(pc)
      local sc = tonumber(lib:GetViewportScale(pc)) or 1
      local sy = tonumber(size.Y or size.y)
      if sy and sy > 0 and sc > 0 then h = sy / sc end
    end
  end)
  return h
end

local fitLogged = false
-- Draw the view, shrinking the text if the panel would run off the bottom of the screen.
local function render(view)
  local base = C.fontSize or FONT_DEFAULT
  local f = base
  local avail = (screenUnitsHeight() or 1080) - BASE_Y - (C.bottomMargin or 140)   -- keep clear of the HUD at the bottom
  -- shrink the text down to C.minFontSize; anything that still does not fit can be scrolled
  local minF = math.min(base, C.minFontSize or 15)
  if C.autoFit ~= false then
    for _ = 1, 4 do
      local h = renderAt(view, f, true)
      if not h or h <= avail then break end
      f = math.max(minF, f * avail / h * 0.99)
      if f <= minF then break end
    end
  end
  if not fitLogged then
    fitLogged = true
    log(string.format("overlay fit: screenUnitsHeight=%s fontSize=%.1f (base %s)", tostring(screenUnitsHeight()), f, tostring(base)))
  end
  return renderAt(view, f ~= base and f or nil, false, avail)
end

local function showWidget()
  if UI.widget then safe(function() UI.widget:SetVisibility(3) end) end -- HitTestInvisible
  UI.visible = true
end

local function hideWidget()
  if UI.widget and isValidObj(UI.widget) then safe(function() UI.widget:SetVisibility(1) end) end
  UI.visible = false
  UI.mode = nil
  UI.hideAt = nil
end

local function fmt(n) return string.format("%.0f", n) end

------------------------------------------------------------------ views
local function prettyMap(m)
  m = tostring(m or "?")
  return (m:gsub("^L_Map_", ""):gsub("^L_", ""))
end

local function fmtDuration(sec)
  sec = math.max(0, math.floor(sec or 0))
  local m, s = math.floor(sec / 60), sec % 60
  if m >= 60 then return string.format("%dh %02dm", math.floor(m / 60), m % 60) end
  return string.format("%dm %02ds", m, s)
end

-- A dataset is { order = {names}, stats = { [name] = {kills, damage, bossDamage, eliteDamage, taken, revives, deaths, selfHeal, teamHeal, ff, shield, cat, ek, ed} } }
local function datasetOfSession(sess)
  local ds = { order = {}, stats = {}, loadouts = sess and sess.loadouts or {} }
  if sess then
    for _, name in ipairs(sess.order) do ds.order[#ds.order + 1] = name; ds.stats[name] = sess.players[name] end
  end
  return ds
end

local function normalizeLabels(t)
  local out = {}
  for label, v in pairs(t or {}) do
    local l = (C.labelAliases or {})[label] or label
    out[l] = (out[l] or 0) + v
  end
  return out
end

local function datasetOfGame(g)
  local ds = { order = {}, stats = {}, loadouts = g.loadouts or {} }
  for _, r in ipairs(g.rows) do
    local pb = (g.break_ or {})[r[1]] or { cat = {}, ek = {}, ed = {}, misc = {} }
    ds.order[#ds.order + 1] = r[1]
    ds.stats[r[1]] = { kills = tonumber(r[2]), damage = tonumber(r[3]), bossDamage = tonumber(r[4]),
      eliteDamage = tonumber(r[5]), taken = tonumber(r[6]), revives = tonumber(r[7]),
      deaths = pb.misc.deaths or 0, selfHeal = pb.misc.selfHeal or 0, teamHeal = pb.misc.teamHeal or 0,
      ff = pb.misc.ff or 0, shield = pb.misc.shield or 0,
      cat = normalizeLabels(pb.cat), ek = normalizeLabels(pb.ek), ed = normalizeLabels(pb.ed) }
  end
  return ds
end

local function markBest(rows, col, values, higher)
  local best, worst = nil, nil
  local count = 0
  for i, v in pairs(values) do
    count = count + 1
    if best == nil or (higher and v > best) or (not higher and v < best) then best = v end
    if worst == nil or (higher and v < worst) or (not higher and v > worst) then worst = v end
  end
  if count < 2 or best == worst then return end
  if higher and best <= 0 then return end
  if higher then
    -- only highlight when at least two players actually have a value (otherwise the others are simply not synced)
    local pos = 0
    for _, v in pairs(values) do if v > 0 then pos = pos + 1 end end
    if pos < 2 then return end
  end
  for i, v in pairs(values) do
    if v == best then rows[i].best = rows[i].best or {}; rows[i].best[col] = true end
  end
end

local function buildSections(ds)
  local names = {}
  for i, n in ipairs(ds.order) do if i <= (C.maxRows or 8) then names[#names + 1] = n end end
  local S = function(n) return ds.stats[n] end

  -- 1) overview: players down the side
  -- (Weakspot / Missed were removed: the game does not send them to every player, see README)
  local ov = { heads = { "Player", "Kills", "Damage", "Boss dmg", "Elite dmg", "Taken", "Deaths", "Revives", "Self heal", "Team heal", "Shield" }, rows = {} }
  local t = { kills = 0, damage = 0, bossDamage = 0, eliteDamage = 0, taken = 0, deaths = 0, revives = 0, selfHeal = 0, teamHeal = 0, shield = 0 }
  local vals = {}   -- per column: { rowIndex = number }
  for c = 2, 11 do vals[c] = {} end
  for i, n in ipairs(names) do
    local s = S(n)
    for k in pairs(t) do t[k] = t[k] + (s[k] or 0) end
    local nums = { s.kills or 0, s.damage or 0, s.bossDamage or 0, s.eliteDamage or 0, s.taken or 0, s.deaths or 0, s.revives or 0,
      s.selfHeal or 0, s.teamHeal or 0, s.shield or 0 }
    local cells = { n }
    for c = 1, 10 do cells[c + 1] = commas(nums[c]); vals[c + 1][i] = nums[c] end
    ov.rows[i] = { cells = cells }
  end
  local higher = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = false, [7] = false, [8] = true, [9] = true, [10] = true, [11] = true }
  for c = 2, 11 do markBest(ov.rows, c, vals[c], higher[c]) end
  -- friendly fire column: only when somebody actually hit a teammate
  local ffTotal = 0
  for _, n in ipairs(names) do ffTotal = ffTotal + (S(n).ff or 0) end
  if ffTotal > 0 then
    ov.heads[#ov.heads + 1] = "Friendly fire"
    for i, n in ipairs(names) do
      local v = S(n).ff or 0
      ov.rows[i].cells[12] = v > 0 and commas(v) or "-"
    end
  end
  if #names >= 2 then
    ov.rows[#ov.rows + 1] = { team = true, cells = { "TEAM", commas(t.kills), commas(t.damage), commas(t.bossDamage), commas(t.eliteDamage),
      commas(t.taken), commas(t.deaths), commas(t.revives), commas(t.selfHeal), commas(t.teamHeal), commas(t.shield) } }
    if ffTotal > 0 then ov.rows[#ov.rows].cells[12] = commas(ffTotal) end
  end

  local function playerHeads(first)
    local h = { first }
    for _, n in ipairs(names) do h[#h + 1] = n end
    h[#h + 1] = "Total"
    return h
  end

  -- 2) damage types: type per row, players across
  local order, seen = {}, {}
  local function addLabel(l) if not seen[l] then seen[l] = true; order[#order + 1] = l end end
  for _, l in ipairs(C.alwaysShowTypes or {}) do addLabel(l) end
  local totals = {}
  for _, n in ipairs(names) do for l, v in pairs(S(n).cat or {}) do totals[l] = (totals[l] or 0) + v end end
  for _, e in ipairs(C.damageCategories or {}) do if (totals[e[1]] or 0) > 0 then addLabel(e[1]) end end
  if (totals.Other or 0) > 0 then addLabel("Other") end
  local extra = {}
  for l, v in pairs(totals) do if v > 0 and not seen[l] then extra[#extra + 1] = l end end
  table.sort(extra)
  for _, l in ipairs(extra) do addLabel(l) end

  local ty = { title = "Damage types", heads = playerHeads("Damage type"), rows = {}, dimLast = true }
  for ri, l in ipairs(order) do
    local cells, v, sum = { l }, {}, 0
    for ci, n in ipairs(names) do
      local d = (S(n).cat or {})[l] or 0
      cells[#cells + 1] = d > 0 and commas(d) or "-"
      v[ci] = d; sum = sum + d
    end
    cells[#cells + 1] = sum > 0 and commas(sum) or "-"
    ty.rows[ri] = { cells = cells }
    -- best player for this row (columns 2..n+1)
    local shifted = {}
    for ci, d in pairs(v) do shifted[ci] = d end
    local bestV = 0
    local pos = 0
    for _, d in pairs(shifted) do if d > bestV then bestV = d end; if d > 0 then pos = pos + 1 end end
    if #names >= 2 and bestV > 0 and pos >= 2 then
      local tie = 0
      for _, d in pairs(shifted) do if d == bestV then tie = tie + 1 end end
      if tie < #names then
        ty.rows[ri].best = {}
        for ci, d in pairs(shifted) do if d == bestV then ty.rows[ri].best[ci + 1] = true end end
      end
    end
  end

  -- 3) enemies: top N by damage, "damage (kills)" per player
  local eTot, labels = {}, {}
  for _, n in ipairs(names) do
    local s = S(n)
    for l, v in pairs(s.ed or {}) do eTot[l] = eTot[l] or { d = 0, k = 0 }; eTot[l].d = eTot[l].d + v end
    for l, v in pairs(s.ek or {}) do eTot[l] = eTot[l] or { d = 0, k = 0 }; eTot[l].k = eTot[l].k + v end
  end
  for l in pairs(eTot) do labels[#labels + 1] = l end
  table.sort(labels, function(a, b)
    if eTot[a].d ~= eTot[b].d then return eTot[a].d > eTot[b].d end
    if eTot[a].k ~= eTot[b].k then return eTot[a].k > eTot[b].k end
    return a < b
  end)
  local maxE = C.maxEnemyRows or #labels   -- nil = every enemy type (the board scrolls)
  local en = { title = (maxE < #labels) and string.format("Enemies (top %d)", maxE) or "Enemies", heads = playerHeads("Enemy - damage (kills)"), rows = {}, dimLast = true }
  for ri = 1, math.min(maxE, #labels) do
    local l = labels[ri]
    local cells, v = { l }, {}
    for ci, n in ipairs(names) do
      local d, k = (S(n).ed or {})[l] or 0, (S(n).ek or {})[l] or 0
      cells[#cells + 1] = (d > 0 or k > 0) and string.format("%s (%d)", commas(d), k) or "-"
      v[ci] = d
    end
    cells[#cells + 1] = string.format("%s (%d)", commas(eTot[l].d), eTot[l].k)
    en.rows[ri] = { cells = cells }
    local bestV = 0
    local pos = 0
    for _, d in pairs(v) do if d > bestV then bestV = d end; if d > 0 then pos = pos + 1 end end
    if #names >= 2 and bestV > 0 and pos >= 2 then
      local tie = 0
      for _, d in pairs(v) do if d == bestV then tie = tie + 1 end end
      if tie < #names then
        en.rows[ri].best = {}
        for ci, d in pairs(v) do if d == bestV then en.rows[ri].best[ci + 1] = true end end
      end
    end
  end
  if #en.rows == 0 then en.rows[1] = { cells = { "(nothing recorded yet)" } } ; en.heads = { "Enemy - damage (kills)" } end

  -- 4) loadout: what every player brought (from the game's synced player progress)
  local secs = { ov, ty, en }
  local los = ds.loadouts or {}
  -- in-game names (from the game's tables, or C.displayNames); a duplicate count " x2" is kept
  local function disp(x)
    if not x or x == "-" or x == "" then return x end
    local base, cnt = x:match("^(.-)( x%d+)$")
    base = base or x
    local d = (C.displayNames or {})[base] or (UI.displayNames or {})[base] or base
    if not d:find("%l") and d:find("%u") then    -- the game's names are in capitals: "HEALTHY BOI" -> "Healthy Boi"
      d = d:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
    end
    return d .. (cnt or "")
  end
  -- 4) loadout: one block per player with a row per slot (Hero, Primary, Secondary, Utility, Spells, Picked up);
  --    the jokers of a slot follow in their own cells, coloured by rarity; long lists wrap onto more rows
  local function split(sv)
    local t = {}
    if not sv or sv == "" or sv == "-" then return t end
    for part in (sv .. " / "):gmatch("(.-) / ") do if part ~= "" then t[#t + 1] = part end end
    return t
  end
  local function jokerColor(cellText)
    local base = cellText:gsub(" x%d+$", "")
    local r = (UI.jokerRarity or {})[base]
    local cols = C.jokerRarityColors or {}
    return r and cols[r] or nil
  end
  local perRow = C.jokersPerRow or 6
  local blocks, maxN = {}, 2
  for _, n in ipairs(names) do
    local lo = los[n]
    if lo then
      local spells = {}
      for _, k in ipairs({ "Spell1", "Spell2", "Spell3" }) do if lo[k] then spells[#spells + 1] = lo[k] end end
      local srcs = {
        { slot = "Hero", list = split(lo.HeroJokers), jokers = true },
        { slot = "Primary", item = lo.Primary, list = split(lo.PrimaryJokers), jokers = true },
        { slot = "Secondary", item = lo.Secondary, list = split(lo.SecondaryJokers), jokers = true },
        { slot = "Utility", item = lo.Utility, list = {} },
        { slot = "Spells", item = spells[1], list = { spells[2], spells[3] } },
        { slot = "Picked up", list = split(lo.Jokers), jokers = true },
      }
      local any = false
      for _, sr in ipairs(srcs) do
        if sr.item or #sr.list > 0 then any = true end
        maxN = math.max(maxN, math.min(#sr.list, perRow))
      end
      if any then blocks[#blocks + 1] = { n = n, srcs = srcs } end
    end
  end
  if #blocks > 0 then
    local heads = { "Player", "Slot", "Item" }
    for i = 1, maxN do heads[#heads + 1] = (i == 1) and "Jokers" or "" end
    local rows = {}
    for _, bl in ipairs(blocks) do
      local first = true
      for _, sr in ipairs(bl.srcs) do
        if sr.item or #sr.list > 0 then
          local lines = math.max(1, math.ceil(#sr.list / maxN))
          for line = 1, lines do
            local cells = { first and bl.n or "", line == 1 and sr.slot or "", line == 1 and (disp(sr.item) or "") or "" }
            local colors = {}
            for i = 1, maxN do
              local j = sr.list[(line - 1) * maxN + i]
              cells[#cells + 1] = j and disp(j) or ""
              if j and sr.jokers then colors[#cells] = jokerColor(j) end
            end
            rows[#rows + 1] = { cells = cells, colors = colors }
            first = false
          end
        end
      end
    end
    secs[#secs + 1] = { title = "Loadout", heads = heads, rows = rows, leftAlign = true }
  end
  return secs
end

local function makeView(ds, title, sub, footer)
  return { title = title, subtitle = sub, footer = footer, sections = buildSections(ds) }
end

local function kname(k) return (tostring(k or "?"):gsub("_ARROW$", "")) end
local function liveHelp()
  return string.format("%s: close    %s: saved games    %s: reset (no save)    %s: save game + reset",
    kname(C.keyToggleScoreboard), kname(C.keyHistory), kname(C.keyReset or "F11"), kname(C.keyEndSession))
end
local function historyHelp()
  return string.format("%s / %s: older / newer game    %s: close    %s: live board",
    kname(C.keyHistoryOlder or "LEFT_ARROW"), kname(C.keyHistoryNewer or "RIGHT_ARROW"), kname(C.keyHistory), kname(C.keyToggleScoreboard))
end

local function liveView()
  local sub = ""
  if Session then
    sub = prettyMap(Session.map) .. (Session.difficulty and ("  -  " .. Session.difficulty) or "")
      .. "  -  " .. fmtDuration(os.time() - Session.start)
    if Session.result then sub = sub .. "  -  " .. Session.result end
  end
  return makeView(datasetOfSession(Session), "SCOREBOARD", sub, liveHelp())
end

------------------------------------------------------------------ history viewer
local H = { games = {}, index = 0 }

local function historyView()
  local n = #H.games
  if n == 0 then
    return { title = "NO SAVED GAMES YET", subtitle = "Finished missions will show up here", footer = historyHelp(),
      sections = {} }
  end
  local g = H.games[H.index]
  return makeView(datasetOfGame(g), string.format("GAME %d / %d", H.index, n),
    string.format("%s%s  -  %s  -  %s%s", prettyMap(g.map), g.difficulty and ("  -  " .. g.difficulty) or "",
      os.date("%Y-%m-%d %H:%M", g.start),
      fmtDuration((g.finish or g.start) - g.start), g.result and ("  -  " .. g.result) or ""),
    historyHelp())
end

local function currentView()
  if UI.mode == "history" then return historyView() end
  return liveView()
end

-- While a level is loading the UI must not be touched at all (it crashed the game). The widget is removed completely
-- when a map change starts and rebuilt the next time it is opened.
local UIBlockedUntil = os.time() + (C.startupQuietSeconds or 15)   -- also quiet for the first seconds after the game starts
local uiBlocked   -- assigned further down (needs the map name)
local function destroyUI()
  local w = UI.widget
  UI.widget = nil
  if w and isValidObj(w) then
    pcall(function() w:SetVisibility(1) end)
    pcall(function() w:RemoveFromParent() end)
  end
  UI.visible = false; UI.mode = nil; UI.hideAt = nil
  UI.texts, UI.imgs = {}, {}
end

local function showView(view, mode, seconds)
  if uiBlocked and uiBlocked() then log("scoreboard not opened: level is loading"); return false end
  UI.scroll = 0
  if render(view) then
    showWidget()
    UI.mode = mode
    UI.hideAt = seconds and (os.time() + seconds) or nil
    return true
  end
  return false
end

local function showLive() showView(liveView(), "live") end

local function openHistory()
  H.games = loadHistory()   -- newest first
  H.index = (#H.games > 0) and 1 or 0
  showView(historyView(), "history")
end

local function stepHistory(dir)
  if not (UI.visible and UI.mode == "history") or #H.games == 0 then return end
  if uiBlocked and uiBlocked() then return end
  H.index = ((H.index - 1 + dir) % #H.games) + 1
  UI.scroll = 0
  render(historyView())
end

------------------------------------------------------------------ session lifecycle
local function currentMapName()
  local w = UEHelpers_ok and safe(UEHelpers.GetWorld) or nil
  if isValidObj(w) then
    return (safe(function() return w:GetFName():ToString() end)) or "?"
  end
  return "?"
end

local function isLobby(map) return matchesAny(map, C.lobbyMapPatterns) end

uiBlocked = function()
  local m = tostring(currentMapName())
  return m == "?" or m:find("Transition") ~= nil or os.time() < UIBlockedUntil
end

-- (an experimental hook on the engine's travel functions was removed: hooking engine natives is risky during level loads)

local function endSession(reason)
  if feedTally then
    for k, v in pairs(feedTally) do log(string.format("damage feed tally %s: %.0f", k, v)) end
    for k in pairs(feedTally) do feedTally[k] = nil end
  end
  if MergeBoards and Session then pcall(MergeBoards) end
  -- weapons / items that dealt damage (from the damage feed) -> log + loadouts.csv ("used1", "used2", ...)
  if Session then
    for name, s in pairs(Session.players) do
      local list = {}
      for item, d in pairs(s.wd or {}) do list[#list + 1] = { item, d } end
      table.sort(list, function(a, b) return a[2] > b[2] end)
      if #list > 0 then
        local parts = {}
        Session.loadouts[name] = Session.loadouts[name] or {}
        for i, e in ipairs(list) do
          parts[#parts + 1] = string.format("%s=%.0f", e[1], e[2])
          if i <= 4 then Session.loadouts[name]["used" .. i] = e[1] end
        end
        log("damage by item for " .. name .. ": " .. table.concat(parts, "  "))
      end
    end
  end
  if Session and sessionHasData(Session) and not isLobby(Session.map) then
    appendHistory(Session)
    log(string.format("saved game on %s (%s)", Session.map, reason))
  end
  Session = nil
end

local function checkMapChange()
  local map = currentMapName()
  if map ~= UI.mapName then UI.mapName, UI.mapSince = map, os.time() end   -- when the current map started
  local leaving = map == "?" or map:find("Transition") ~= nil or (Session and Session.map ~= map)
  if leaving then
    UIBlockedUntil = math.max(UIBlockedUntil, os.time() + 8)
    if UI.widget then pcall(destroyUI) end
  end
  if map == "?" then return end
  if not Session then
    newSession(map)
  elseif Session.map ~= map then
    endSession("map change " .. Session.map .. " -> " .. map)
    newSession(map)
  end
end

------------------------------------------------------------------ event handling
local function classifyTarget(target)
  if not isValidObj(target) then return nil end
  local cn = className(target)
  if boolProp(target, C.bossProps) or matchesAny(cn, C.bossPatterns) then return "boss" end
  if boolProp(target, C.eliteProps) or matchesAny(cn, C.elitePatterns) then return "elite" end
  return "normal"
end

-- Split call arguments into numbers and objects
local function collectArgs(self, ...)
  local selfObj = unwrap(self)
  local nums, objs, bools = {}, {}, {}
  for _, p in ipairs({ ... }) do
    local v = unwrap(p)
    if type(v) == "boolean" then bools[#bools + 1] = v
    elseif type(v) == "number" then nums[#nums + 1] = v
    elseif isValidObj(v) then objs[#objs + 1] = v end
  end
  return selfObj, nums, objs, bools
end

local function pickAmount(def, nums)
  if def.amount == "one" then return 1 end
  for _, n in ipairs(nums) do
    if n > 0 then return n end
  end
  return nil
end

-- Split the call into player objects (self first, then params) and everything else (enemies etc.)
local function findActors(selfObj, objs)
  local players, others = {}, {}
  local function add(o)
    if not isValidObj(o) then return end
    if isPlayer(o) then
      for _, p in ipairs(players) do if p == o then return end end
      players[#players + 1] = o
    else
      others[#others + 1] = o
    end
  end
  add(selfObj)
  for _, o in ipairs(objs) do add(o) end
  return players, others
end

local handlers = {}

local function firstLabel(list, str, default)
  local lower = tostring(str or ""):lower()
  for _, e in ipairs(list or {}) do
    if lower:find(tostring(e[2]):lower(), 1, true) then return e[1] end
  end
  return default
end
local otherEnemyLogged = {}
local function enemyLabel(enemy)
  local cn = className(enemy)
  local label = firstLabel(C.enemyTypes, cn, "Other")
  if label == "Other" and not otherEnemyLogged[cn] then
    otherEnemyLogged[cn] = true
    log("enemy class counted as 'Other': " .. tostring(cn))
  end
  return label
end
local function categoryOf(typeObj) return firstLabel(C.damageCategories, fullName(typeObj), "Other") end

local loggedTypes = {}
local function addMisc(name, field, n)
  if not Session then newSession("?") end
  local s = statsFor(name)
  s[field] = (s[field] or 0) + n
end

-- Damage feed: BP_Enemy:F_DamageFeedback_Multicast(Damages, Owner, DamageType, ItemName, Element) is sent by the
-- server to EVERY player, so it carries the damage of all players (the same idea the Darktide scoreboard uses with
-- AttackReportManager.add_attack_result).
local feedActive = false
local feedNoPlayerLogged = {}
local feedRecent, feedRecentN = {}, 0
feedTally = {}
local function playerFromCauser(o)
  for _ = 1, 4 do
    if not isValidObj(o) then return nil end
    if isPlayer(o) then return o end
    if className(o):find("Controller") then
      local ps = safe(function() return o.PlayerState end)
      if isPlayer(ps) then return ps end
    end
    local nxt = safe(function() return o:GetOwner() end)
    if not isValidObj(nxt) then nxt = safe(function() return o:GetInstigator() end) end
    if nxt == o then return nil end
    o = nxt
  end
  return nil
end

local function argText(v)
  v = unwrap(v)
  if v == nil then return nil end
  local s = safe(function() return v:ToString() end)
  if type(s) == "string" and s ~= "" and s ~= "None" then return s end
  return nil
end

handlers.feed = function(def, selfObj, nums, objs, bools, path, args)
  local enemy = selfObj
  if not isValidObj(enemy) or not args then return end
  -- argument positions:
  --   F_DamageFeedback_Multicast(Damages, Owner, DamageType, ItemName, Element)
  --   F_Child_DamageFeedback(Hit, Owner, Damages)
  --   F_DamageFeedback(Hit, Owner, Damages, DamageType, Critical, Element, ItemName)   (Cryptic Train sections)
  local sp = tostring(path)
  local L
  if sp:find(":F_Child_DamageFeedback$") then L = { amount = 3, dt = nil, item = nil, elem = nil }
  elseif sp:find(":F_DamageFeedback$") then L = { amount = 3, dt = 4, item = 7, elem = 6 }
  else L = { amount = 1, dt = 3, item = 4, elem = 5 } end
  local isChild = L.dt == nil
  local amount = unwrap(args[L.amount])
  if type(amount) ~= "number" or amount <= 0 then return end
  local causer = unwrap(args[2])
  local pl = playerFromCauser(causer)
  -- tally per function + enemy class (written to the log at the end of a game)
  local tk = (tostring(path):match("([^/]+)$") or "?") .. " on " .. className(enemy)
  feedTally[tk] = (feedTally[tk] or 0) + amount
  if not pl then
    local cn = isValidObj(causer) and className(causer) or "none"
    if not feedNoPlayerLogged[cn] then feedNoPlayerLogged[cn] = true; log("damage feed: causer " .. cn .. " is not a player (ignored)") end
    return
  end
  local who = playerName(pl)
  -- the same hit can arrive through more than one of the hooked functions (parent + override, child + parent)
  local now = os.clock()
  -- (no enemy in the key: a wagon hit may be reported on the wagon AND on the train; only a different function counts as echo)
  local dk = who .. "|" .. string.format("%.2f", amount)
  local prev = feedRecent[dk]
  if prev and prev.path ~= path and now - prev.t < 0.05 then
    feedTally[tk .. " (echo, skipped)"] = (feedTally[tk .. " (echo, skipped)"] or 0) + amount
    return
  end
  feedTally[tk .. " (counted)"] = (feedTally[tk .. " (counted)"] or 0) + amount
  feedRecent[dk] = { path = path, t = now }
  feedRecentN = feedRecentN + 1
  if feedRecentN > 4000 then feedRecent, feedRecentN = {}, 0 end
  if not feedActive then
    feedActive = true
    log("damage source: F_DamageFeedback_Multicast (damage of all players)")
  end
  record(who, "damage", amount)
  local kind = classifyTarget(enemy)
  if kind == "boss" then record(who, "bossDamage", amount)
  elseif kind == "elite" then record(who, "eliteDamage", amount) end
  recordEnemy(who, enemyLabel(enemy), 0, amount)
  -- damage type (class) -> category; no type = gun / melee
  local dt = L.dt and unwrap(args[L.dt]) or nil
  if type(dt) ~= "userdata" and type(dt) ~= "table" then dt = nil end
  local tn = dt and safe(function() return fullName(dt) end)
  local cat = "Weapon"
  if type(tn) == "string" and tn ~= "" and not tn:find("None") then
    cat = categoryOf(dt)
    local short = tn:match("([^%.:/ ]+)$") or tn
    if not loggedTypes[short] then loggedTypes[short] = true; log("damage type seen: " .. short .. " -> " .. cat) end
  end
  -- weapon / item that dealt it (names look like "itemMinigun", "itemFire", "itemAcid")
  local item = L.item and argText(args[L.item]) or nil
  if item then item = item:gsub("^item", "") end
  if cat == "Weapon" and item then
    -- the damage type class is not readable here, but elemental damage carries the element as item name
    local byItem = firstLabel(C.damageCategories, item, nil)
    if byItem then cat = byItem end
  end
  -- spells: hits that carry an element but no item name (seen in the Saloon: Ice Glaze = no item, element 15),
  -- or that come from a spell actor (turret, decoy ...) owned by the player
  local causerCls = isValidObj(causer) and className(causer) or "none"
  local elem = L.elem and unwrap(args[L.elem]) or nil
  if type(elem) ~= "number" then elem = nil end
  if (not item or item == "") and elem then cat = "Spells" end
  if causer ~= pl and matchesAny(causerCls, C.spellCauserPatterns or { "Spell" }) then cat = "Spells" end
  do
    local ek = tostring(item) .. "|" .. tostring(elem) .. "|" .. causerCls .. "|" .. cat
    if not loggedTypes[ek] then loggedTypes[ek] = true; log("damage feed item/element/causer/type: " .. ek) end
  end
  recordCat(who, cat, amount)
  if item and item ~= "" then
    local s = statsFor(who)
    s.wd = s.wd or {}
    s.wd[item] = (s.wd[item] or 0) + amount
  end
end

handlers.feedsec = function(...) return handlers.feed(...) end

-- difficulty (fallback): BPFL F_ScaleXpWithDifficulty(Difficulty:int) runs at the end of a mission with the real value
handlers.difficulty = function(def, selfObj, nums)
  local v = nums and nums[1]
  if not Session or isLobby(Session.map) or type(v) ~= "number" then return end
  local name = (C.difficultyNames or {})[math.floor(v)] or ("Difficulty " .. tostring(v))
  if Session.difficulty ~= name then
    Session.difficulty = name
    log(string.format("difficulty: %s (value %s via F_ScaleXpWithDifficulty)", name, tostring(v)))
  end
end

local seenKills = {}
local seenKillCount = 0

handlers.kill = function(def, selfObj, nums, objs)
  local players, others = findActors(selfObj, objs)
  -- the dead enemy is the first non-player object (self for F_IncrementLeaderboardKillStats, p1 for F_TriggerOnKillTweaks)
  local enemy = others[1]
  if enemy then
    local key = fullName(enemy)
    local now = os.time()
    if key ~= "" then
      if seenKills[key] and now - seenKills[key] < 60 then return end -- same enemy already counted by another hook
      seenKills[key] = now
      seenKillCount = seenKillCount + 1
      if seenKillCount > 400 then
        for k, t in pairs(seenKills) do if now - t > 60 then seenKills[k] = nil end end
        seenKillCount = 0
      end
    end
  end
  local who = players[1] or localPlayer()
  if who then
    record(playerName(who), "kills", 1)
    if enemy then recordEnemy(playerName(who), enemyLabel(enemy), 1, 0) end
  end
end

-- Damage taken: F_ServerDamages (runs where the server is) or F_PlayerReceiveDamagesFeedback (runs on the hit
-- player's own machine). On the host both can fire for the host's own player, so per player only the function that
-- fired first is used.
local takenPath = {}
local ffLogged = 0
handlers.taken = function(def, selfObj, nums, objs, bools, path)
  local amount = pickAmount(def, nums)
  if not amount then return end
  local players = findActors(selfObj, objs)
  local victim = players[1] or localPlayer()
  if not victim then return end
  local name = playerName(victim)
  if not takenPath[name] then takenPath[name] = path; log("damage taken of " .. name .. " via " .. tostring(path):match("([^:]+)$")) end
  if takenPath[name] ~= path then return end
  record(name, "taken", amount)
  -- friendly fire: the damage came from another player (directly, or from something a player owns)
  local players2, others = findActors(selfObj, objs)
  local attacker = players2[2]
  if not attacker then
    for _, o in ipairs(others) do
      local p = playerFromCauser(o)
      if p then attacker = p; break end
    end
  end
  if attacker then
    local an = playerName(attacker)
    if an ~= name then
      addMisc(an, "ff", amount)
      ffLogged = (ffLogged or 0) + 1
      if ffLogged <= 20 then log(string.format("friendly fire: %s hit %s for %.1f", an, name, amount)) end
    end
  end
end

handlers.death = function(def, selfObj, nums, objs)
  local players = findActors(selfObj, objs)
  local who = players[1] or localPlayer()
  if who then record(playerName(who), "deaths", 1) end
end

handlers.revive = function(def, selfObj, nums, objs)
  local players = findActors(selfObj, objs)
  local who = players[1] or localPlayer()
  if who then record(playerName(who), "revives", 1) end
end

------------------------------------------------------------------ learn mode
local LEARNLOG = DIR .. "learn.log"
local learnCount = {}
local function describe(v)
  local t = type(v)
  if t == "number" or t == "boolean" or t == "string" then return t .. ":" .. tostring(v) end
  if t == "userdata" or t == "table" then
    if isValidObj(v) then return "obj:" .. className(v) .. ":" .. (fullName(v):match("([^%.:]+)$") or "") end
    return "userdata"
  end
  return t
end

local function learnLog(path, self, ...)
  learnCount[path] = (learnCount[path] or 0) + 1
  if learnCount[path] > 6 then return end
  local parts = { "self=" .. describe(unwrap(self)) }
  for i, p in ipairs({ ... }) do parts[#parts + 1] = "p" .. i .. "=" .. describe(unwrap(p)) end
  local f = io.open(LEARNLOG, "a")
  if f then f:write(os.date("%H:%M:%S ") .. path .. "  " .. table.concat(parts, "  ") .. "\n"); f:close() end
end

------------------------------------------------------------------ function discovery & hooking
local function allFunctions()
  local out = {}
  local function consider(obj)
    local fn = fullName(obj)
    local path = fn:match("^Function (/Game/.+)$")
    if path then out[#out + 1] = path end
  end
  local list = safe(FindAllOf, "Function")
  if list then
    for _, f in ipairs(list) do consider(f) end
  elseif ForEachUObject then
    ForEachUObject(function(obj)
      if className(obj) == "Function" then consider(obj) end
    end)
  end
  return out
end

local function shortName(path) return path:match(":([^:]+)$") or path end

local function ownerOk(path)
  for _, pat in ipairs(C.learnOwners or {}) do
    if path:find(pat) then return true end
  end
  return false
end

local function classDump()
  local out = {}
  local function w(line) out[#out + 1] = line end
  w("FFW_Scoreboard class dump - " .. os.date())
  for _, path in ipairs(C.dumpClasses or {}) do
    local cls = safe(StaticFindObject, path)
    w("")
    w("## " .. path)
    if not isValidObj(cls) then
      w("   (not found)")
    else
      local cur, depth = cls, 0
      while isValidObj(cur) and depth < 8 do
        local fn = fullName(cur)
        w("-- " .. fn)
        if fn:find("/Script/", 1, true) then break end -- engine class: name only
        pcall(function()
          cur:ForEachFunction(function(f)
            local parts = {}
            pcall(function()
              f:ForEachProperty(function(p)
                parts[#parts + 1] = p:GetFName():ToString() .. ":" .. p:GetClass():GetFName():ToString()
              end)
            end)
            w("   fn " .. f:GetFName():ToString() .. "(" .. table.concat(parts, ", ") .. ")")
          end)
        end)
        pcall(function()
          cur:ForEachProperty(function(p)
            w("   prop " .. p:GetFName():ToString() .. ":" .. p:GetClass():GetFName():ToString())
          end)
        end)
        cur = safe(function() return cur:GetSuperStruct() end)
        depth = depth + 1
      end
    end
  end
  local f = io.open(DIR .. "classdump.txt", "w")
  if f then f:write(table.concat(out, "\n") .. "\n"); f:close(); log("wrote classdump.txt (" .. #out .. " lines)") end
end

local hooked = {}
local resultSeen = 0
local function hookPath(path, fn)
  if hooked[path] then return end
  local ok, err = pcall(RegisterHook, path, fn)
  if ok then hooked[path] = true else log("hook failed " .. path .. ": " .. tostring(err)) end
end

-- hook one function and send its calls to the handlers of the given events
local function hookEvents(path, evs)
  local sn = shortName(path)
  hookPath(path, function(self, ...)
    local args = table.pack(...)
    local ok, err = pcall(function()
      local selfObj, nums, objs, bools = collectArgs(self, table.unpack(args, 1, args.n))
      if C.learn then learnLog(path, self, table.unpack(args, 1, args.n)) end
      for _, ev in ipairs(evs) do handlers[ev](C.events[ev], selfObj, nums, objs, bools, path, args) end
    end)
    if not ok then log("handler error in " .. sn .. ": " .. tostring(err)) end
  end)
  if hooked[path] then log(string.format("hooked %s -> %s", path, table.concat(evs, "+"))) end
end

local function installHooks()
  local funcs = allFunctions()
  if #funcs == 0 then return false end

  local wanted = {}   -- short name -> list of event ids
  for ev, def in pairs(C.events) do
    for _, n in ipairs(def.names or {}) do
      wanted[n] = wanted[n] or {}
      table.insert(wanted[n], ev)
    end
  end

  local count = 0
  for _, path in ipairs(funcs) do
    local sn = shortName(path)
    local evs = {}
    for _, ev in ipairs(wanted[sn] or {}) do
      local owner = C.events[ev].owner
      local okOwner = not owner
      if type(owner) == "string" then okOwner = path:find(owner) ~= nil
      elseif type(owner) == "table" then for _, o in ipairs(owner) do if path:find(o) then okOwner = true end end end
      if okOwner then evs[#evs + 1] = ev end
    end
    if #evs > 0 and hooked[path] then
      count = count + 1   -- already hooked on an earlier scan
    elseif #evs > 0 then
      hookEvents(path, evs)
      count = count + 1
    elseif C.learn and ownerOk(path) then
      local lower = sn:lower()
      for _, pat in ipairs(C.discoveryPatterns) do
        if lower:find(pat, 1, true) then
          hookPath(path, function(self, ...) learnLog(path, self, ...) end)
          break
        end
      end
    end
  end
  -- mission result (Victory / Defeat): hook functions whose names clearly say so
  local cand = {}
  for _, path in ipairs(funcs) do
    local sn = shortName(path)
    local lower = sn:lower()
    if not lower:find("^onfail") and not lower:find("^onsuccess") and not lower:find("^executeubergraph") then
      for kind, pats in pairs(C.resultPatterns or {}) do
        for _, pat in ipairs(pats) do
          if lower:find(pat, 1, true) then
            if #cand < 40 then
              cand[#cand + 1] = sn
              hookPath(path, function(self, ...)
                pcall(function()
                  resultSeen = resultSeen + 1
                  if resultSeen <= 12 then log("result event: " .. path) end
                  if Session and not isLobby(Session.map) then Session.result = kind end
                end)
              end)
            end
            break
          end
        end
      end
    end
  end
  log("result hooks: " .. (#cand > 0 and table.concat(cand, ", ") or "none found"))
  log(string.format("%d event hook(s) installed from %d Blueprint functions", count, #funcs))
  return true
end

local function writeDiscovery()
  local funcs = allFunctions()
  local f = io.open(DIR .. "discovery.txt", "w")
  if not f then return end
  f:write("FFW_Scoreboard discovery - " .. os.date() .. "\n")
  f:write("Map: " .. currentMapName() .. "\n\n")
  local n = 0
  table.sort(funcs)
  for _, path in ipairs(funcs) do
    local lower = shortName(path):lower()
    for _, pat in ipairs(C.discoveryPatterns) do
      if lower:find(pat, 1, true) then f:write(path .. "\n"); n = n + 1; break end
    end
  end
  f:write(string.format("\n%d candidate functions out of %d Blueprint functions\n", n, #funcs))
  f:close()
  log("wrote discovery.txt (" .. n .. " candidates)")
end

------------------------------------------------------------------ leaderboard sync
-- Every player's PlayerState carries the game's own end-of-mission leaderboard (playerRuntimeLeaderboardReplicated),
-- which is sent to all players. This is how stats of OTHER players are read when you are not the host.
local BOARD_STRUCT = "/Game/Player/SaveGames/S_PlayerRuntimeLeaderboard.S_PlayerRuntimeLeaderboard"
local boardFields = nil
local boardDumped = false

local function listBoardFields()
  if boardFields then return boardFields end
  boardFields = {}
  local st = safe(StaticFindObject, BOARD_STRUCT)
  if isValidObj(st) then
    pcall(function() st:ForEachProperty(function(p) boardFields[#boardFields + 1] = p:GetFName():ToString() end) end)
  end
  dlog("leaderboard struct fields: " .. table.concat(boardFields, ", "))
  return boardFields
end

local function mapField(n)
  local l = n:lower()
  if l:find("selfheal") then return "selfHeal" end
  if l:find("teamheal") then return "teamHeal" end
  if l:find("combo") or l:find("heal") then return nil end
  if l:find("boss") then return "bossDamage" end
  if l:find("elite") then return "eliteDamage" end
  if l:find("damage") and (l:find("taken") or l:find("receiv") or l:find("suffer")) then return "taken" end
  if l:find("damage") then return "damage" end
  if l:find("kill") or l:find("^enemies") then return "kills" end
  if l:find("death") then return "deaths" end
  if l:find("revive") then return "revives" end
  return nil
end

local function readBoard(ps)
  local raw, mapped = {}, {}
  local st = safe(function() return ps.playerRuntimeLeaderboardReplicated end)
  if not st then return raw, mapped end
  for _, n in ipairs(listBoardFields()) do
    local v = unwrap(safe(function() return st[n] end))
    if type(v) == "number" then
      raw[n] = v
      local stat = mapField(n)
      if stat and mapped[stat] == nil then mapped[stat] = v end
    end
  end
  return raw, mapped
end

local function pollBoards()
  if not Session then return end
  local list = safe(FindAllOf, "BP_PlayerState_C")
  if not list then return end
  for _, ps in ipairs(list) do
    if isValidObj(ps) then
      local name = playerName(ps)
      local raw, mapped = readBoard(ps)
      local total = 0
      for _, v in pairs(raw) do total = total + math.abs(v) end
      if total > 0 then
        local prev = Boards[name]
        if not prev or total >= prev.total then Boards[name] = { total = total, mapped = mapped } end
        if not boardDumped then
          boardDumped = true
          local parts = {}
          for n, v in pairs(raw) do parts[#parts + 1] = n .. "=" .. tostring(v) end
          table.sort(parts)
          dlog("leaderboard of " .. name .. ": " .. table.concat(parts, "  "))
        end
      end
    end
  end
end

local pollLoadouts, pollJokers, pollDifficulty, pollShield
do
------------------------------------------------------------------ loadout / jokers / difficulty
-- Every PlayerState has playerProgressReplicated (synced to every player) with the chosen items:
-- selectedItemA (primary), selectedItemB (secondary), selectedItemUtility, spellA / spellB / spellC.

-- describe any value (objects by name, arrays as [count] items)
local function describeValue(v)
  v = unwrap(v)
  local t = type(v)
  if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
  if t ~= "userdata" and t ~= "table" then return nil end
  if isValidObj(v) then return (fullName(v):match("([^%.:/ ]+)$") or "?") end
  local parts, n = {}, 0
  pcall(function()
    v:ForEach(function(a, b)
      n = n + 1
      if n <= 12 then
        local e = b ~= nil and b or a
        local d = describeValue(e and e.get and e:get() or e)
        parts[#parts + 1] = d or "?"
      end
    end)
  end)
  if n > 0 then return "[" .. n .. "] " .. table.concat(parts, ",") end
  local s = safe(function() return v:ToString() end)
  if type(s) == "string" and s ~= "" then return s end
  return nil
end

local function shortField(n) return (n:gsub("_%d+_%x+$", "")) end
local function propClassName(p) return safe(function() return p:GetClass():GetFName():ToString() end) or "?" end

-- describe a value using its property metadata, so structs and arrays of structs are expanded
local function describeProp(p, v, depth)
  depth = depth or 0
  v = unwrap(v)
  if v == nil then return nil end
  local pc = propClassName(p)
  if depth < 4 and pc == "StructProperty" then
    local st = safe(function() return p:GetStruct() end)
    if not st then return describeValue(v) end
    local parts = {}
    pcall(function() st:ForEachProperty(function(f)
      local fn = f:GetFName():ToString()
      local d = describeProp(f, safe(function() return v[fn] end), depth + 1)
      if d and d ~= "" and d ~= "0" and d ~= "false" and d ~= "0.0" and d ~= "None" then parts[#parts + 1] = shortField(fn) .. "=" .. d end
    end) end)
    return "{" .. table.concat(parts, " ") .. "}"
  elseif depth < 4 and pc == "ArrayProperty" then
    local inner = safe(function() return p:GetInner() end)
    local parts, n = {}, 0
    pcall(function() v:ForEach(function(_, e)
      n = n + 1
      if n <= 30 then
        local ev = e and e.get and e:get() or e
        parts[#parts + 1] = (inner and describeProp(inner, ev, depth + 1)) or describeValue(ev) or "?"
      end
    end) end)
    return "[" .. n .. "] " .. table.concat(parts, ", ")
  elseif depth < 4 and (pc == "MapProperty" or pc == "SetProperty") then
    local kp = safe(function() return p:GetKeyProp() end) or safe(function() return p:GetElementProp() end)
    local vp = safe(function() return p:GetValueProp() end)
    local parts, n = {}, 0
    pcall(function() v:ForEach(function(k, val)
      n = n + 1
      if n <= 30 then
        local kv = k and k.get and k:get() or k
        local vv = val and val.get and val:get() or val
        local kd = (kp and describeProp(kp, kv, depth + 1)) or describeValue(kv) or "?"
        local vd = nil
        if vv ~= nil then vd = (vp and describeProp(vp, vv, depth + 1)) or describeValue(vv) or "?" end
        parts[#parts + 1] = vd and (kd .. "=" .. vd) or kd
      end
    end) end)
    return "{" .. n .. "} " .. table.concat(parts, ", ")
  end
  return describeValue(v)
end

-- property object of a class by (short) name
local propCache = {}
local function findProp(owner, name)
  local cls = safe(function() return owner:GetClass() end)
  if not cls then return nil end
  local key = fullName(cls) .. "." .. name
  if propCache[key] ~= nil then return propCache[key] or nil end
  local found = false
  local cur, depth = cls, 0
  while isValidObj(cur) and not found and depth < 6 do
    pcall(function() cur:ForEachProperty(function(p)
      if not found and shortField(p:GetFName():ToString()) == name then found = p end
    end) end)
    cur = safe(function() return cur:GetSuperStruct() end)
    depth = depth + 1
  end
  propCache[key] = found
  return found or nil
end

-- the full (GUID-suffixed) field names of a struct property, by short name
local function structFieldMap(p)
  local map = {}
  local st = p and safe(function() return p:GetStruct() end)
  if st then pcall(function() st:ForEachProperty(function(f)
    local fn = f:GetFName():ToString()
    map[shortField(fn)] = { name = fn, prop = f }
  end) end) end
  return map
end

local function pretty(item)
  item = tostring(item or "")
  if item == "" or item == "None" then return nil end
  item = item:gsub("^item", ""):gsub("^Utility", ""):gsub("^Spell", "")
  item = item:gsub("(%l)(%u)", "%1 %2")
  return item
end

local progressFields = nil
local function readLoadout(ps)
  local out = {}
  local p = findProp(ps, "playerProgressReplicated")
  if not p then return out end
  progressFields = progressFields or structFieldMap(p)
  local st = safe(function() return ps.playerProgressReplicated end)
  if not st then return out end
  local function get(short)
    local f = progressFields[short]
    if not f then return nil end
    return pretty(describeValue(safe(function() return st[f.name] end)))
  end
  out.Primary, out.Secondary, out.Utility = get("selectedItemA"), get("selectedItemB"), get("selectedItemUtility")
  out.Spell1, out.Spell2, out.Spell3 = get("spellA"), get("spellB"), get("spellC")
  return out
end

local loadJokerRarity
do
-- Game tables (read once): DT_PlayerJokers gives every joker's rarity and in-game name, DT_PlayerItems the in-game
-- names of weapons / utilities / spells (e.g. the internal "Ice Lance" is called "Bridge" in the game).
-- Results: UI.jokerRarity[internal pretty name] = rarity number, UI.displayNames[internal pretty name] = in-game name.
local tableTries, tableNext, tablesDone, namesLogged = 0, 0, {}, 0
local function readTable(key, path, prefix, wantRarity)
  if tablesDone[key] then return end
  local dt = safe(StaticFindObject, path)
  -- (no LoadAsset here: forcing a load while a level streams in can crash; the tables are loaded by the game itself)
  if not isValidObj(dt) then log(key .. " table not found: " .. path); return end
  local fields, rarField, nameField = {}, nil, nil
  local rs = safe(function() return dt.RowStruct end)
  if isValidObj(rs) then
    pcall(function() rs:ForEachProperty(function(f)
      fields[#fields + 1] = { name = f:GetFName():ToString(), prop = f, cls = propClassName(f) }
    end) end)
  end
  for _, f in ipairs(fields) do
    local l = shortField(f.name):lower()
    if wantRarity and not rarField and l:find(C.jokerRarityField or "rarity") then rarField = f.name end
    if not nameField and f.cls == "TextProperty" and (l:find("name") or l:find("title")) then nameField = f.name end
  end
  if not nameField then for _, f in ipairs(fields) do if not nameField and f.cls == "TextProperty" then nameField = f.name end end end
  local rar, names, n, samples, dist = {}, {}, 0, {}, {}
  local ok, err = pcall(function()
    dt:ForEachRow(function(rowName, rowData)
      n = n + 1
      local rn = (type(rowName) == "string" and rowName) or safe(function() return rowName:ToString() end) or tostring(rowName)
      local rd = rowData   -- the row struct itself (do not index unknown fields such as "get" on it)
      local internal = pretty((rn:gsub("^" .. prefix, ""))) or rn
      if rarField then
        local v = unwrap(safe(function() return rd[rarField] end))
        local num = tonumber(v)
        if not num and type(v) == "string" then num = tonumber(v:match("(%d+)$")) end
        if not num and v ~= nil then num = tonumber(describeValue(v) or "") end
        if num then
          rar[internal] = num
          dist[num] = (dist[num] or 0) + 1
          samples[num] = samples[num] or rn
        end
      end
      if nameField then
        -- the name is an FText: read it with ToString (describeValue would print "?")
        local raw = unwrap(safe(function() return rd[nameField] end))
        local t = (type(raw) == "string" and raw) or safe(function() return raw:ToString() end)
        if type(t) ~= "string" then t = nil end
        if namesLogged < 6 then namesLogged = namesLogged + 1; dlog(key .. " name: " .. rn .. " -> " .. tostring(t)) end
        if t and t ~= "" and t ~= "?" and t ~= internal then names[internal] = t end
      end
      if n <= 2 then
        local parts = {}
        for _, f in ipairs(fields) do
          local d = describeProp(f.prop, safe(function() return rd[f.name] end))
          if d and d ~= "" then parts[#parts + 1] = shortField(f.name) .. "=" .. d end
        end
        dlog(key .. " table row " .. rn .. ": " .. table.concat(parts, "  "):sub(1, 1500))
      end
    end)
  end)
  local dparts = {}
  for k, v in pairs(dist) do dparts[#dparts + 1] = "rarity " .. k .. ": " .. v .. " (e.g. " .. tostring(samples[k]) .. ")" end
  table.sort(dparts)
  local nn = 0
  for _ in pairs(names) do nn = nn + 1 end
  log(string.format("%s table: %d rows, rarity field %s, name field %s (%d renamed), ok=%s %s %s", key, n,
    tostring(rarField and shortField(rarField)), tostring(nameField and shortField(nameField)), nn, tostring(ok),
    ok and "" or tostring(err), table.concat(dparts, ", ")))
  if not ok then return end
  tablesDone[key] = true
  if next(rar) then UI.jokerRarity = rar end
  UI.displayNames = UI.displayNames or {}
  for k, v in pairs(names) do UI.displayNames[k] = v end
end

loadJokerRarity = function()
  if (tablesDone.joker and tablesDone.item) or tableTries >= 20 or os.time() < tableNext then return end
  tableTries, tableNext = tableTries + 1, os.time() + 60
  readTable("joker", C.jokerTable or "/Game/Progress/DT_PlayerJokers.DT_PlayerJokers", "joker", true)
  readTable("item", C.itemTable or "/Game/Progress/DT_PlayerItems.DT_PlayerItems", "item", false)
end

end

-- weapon jokers of the local player, from the save game in memory: { ["Minigun"] = { "jokerScrubHit", ... }, ... }
UI.readWeaponJokers = function()
  local now = os.time()
  if UI.wjCache and now - (UI.wjTime or 0) < 10 then return UI.wjCache end
  local out = {}
  pcall(function()
    local sg = FindFirstOf("SG_PlayerProgress_C")
    if not isValidObj(sg) then return end
    local p = findProp(sg, "playerProgress")
    local f = p and structFieldMap(p)["itemJokers"]
    local st = p and sg[p:GetFName():ToString()]
    if not f or not st then return end
    local map = st[f.name]
    local vp = safe(function() return f.prop:GetValueProp() end)
    -- the map's values are S_PlayerItemJokers structs; read their fields through the struct definition
    local vfields = {}
    local vst = safe(StaticFindObject, C.itemJokersStruct or "/Game/Progress/S_PlayerItemJokers.S_PlayerItemJokers")
    if isValidObj(vst) then
      pcall(function() vst:ForEachProperty(function(fp) vfields[#vfields + 1] = { name = fp:GetFName():ToString(), prop = fp } end) end)
    end
    map:ForEach(function(k, val)
      local kv = k and k.get and k:get() or k
      local vv = val and val.get and val:get() or val
      local key = describeValue(kv)
      local d
      if #vfields > 0 then
        local parts = {}
        for _, fl in ipairs(vfields) do
          local x = describeProp(fl.prop, safe(function() return vv[fl.name] end))
          if x and x ~= "" then parts[#parts + 1] = shortField(fl.name) .. "=" .. x end
        end
        d = table.concat(parts, " ")
      else
        d = (vp and describeProp(vp, vv)) or describeValue(vv) or ""
      end
      -- only the joker names in the values (the field names jokerA..jokerD / jokers are not jokers); empty = "None"
      local list = {}
      for value in tostring(d):gsub("[%w_]+=", "\1"):gmatch("[^\1]+") do
        for j in value:gmatch("joker[%w_]+") do list[#list + 1] = j end
      end
      if key then out[pretty(key) or key] = list end
      if not UI.wjLogged then log("weapon jokers in save: " .. tostring(key) .. " = " .. tostring(d):sub(1, 600)) end
    end)
    UI.wjLogged = true
  end)
  UI.wjCache, UI.wjTime = out, now
  return out
end

local loadoutLast = {}
pollLoadouts = function()
  if not Session then return end
  pcall(loadJokerRarity)
  local list = safe(FindAllOf, "BP_PlayerState_C")
  if not list then return end
  for _, ps in ipairs(list) do
    if isValidObj(ps) then
      local name = playerName(ps)
      local lo = readLoadout(ps)
      -- jokers picked up during the mission: AC_PlayerStateJoker.playerLocalJokers (kept for the whole game, the
      -- list itself is emptied when the mission ends)
      -- Duplicates: the same joker picked up twice is listed twice, so the highest count seen is kept ("Chad x2").
      Session.jokerSeen = Session.jokerSeen or {}
      local seen = Session.jokerSeen[name] or { list = {}, count = {} }
      Session.jokerSeen[name] = seen
      local function jname(j) return pretty((tostring(j):gsub("^joker", ""))) or j end
      local comp = safe(function() return ps.AC_PlayerStateJoker end)
      if isValidObj(comp) then
        for _, pn in ipairs({ "playerLocalJokers", "playerLocalJokersServerRetrieved" }) do
          local cnt = {}
          pcall(function()
            comp[pn]:ForEach(function(_, e)
              local j = describeValue(e and e.get and e:get() or e)
              if j and j ~= "" and j ~= "None" then cnt[j] = (cnt[j] or 0) + 1 end
            end)
          end)
          for j, c in pairs(cnt) do
            if not seen.count[j] then seen.list[#seen.list + 1] = j end
            if c > (seen.count[j] or 0) then
              seen.count[j] = c
              log(string.format("joker picked up by %s: %s (x%d)", name, j, c))
            end
          end
        end
      end
      if #seen.list > 0 then
        local pj = {}
        for _, j in ipairs(seen.list) do
          local c = seen.count[j] or 1
          pj[#pj + 1] = jname(j) .. (c > 1 and (" x" .. c) or "")
        end
        lo.Jokers = table.concat(pj, " / ")
      end
      -- hero jokers (equipped before the mission): PlayerState.itemHeroJokers
      do
        local hj = {}
        pcall(function()
          ps.itemHeroJokers:ForEach(function(_, e)
            local j = describeValue(e and e.get and e:get() or e)
            if j and j ~= "" and j ~= "None" then hj[#hj + 1] = jname(j) end
          end)
        end)
        if #hj > 0 then lo.HeroJokers = table.concat(hj, " / ") end
      end
      -- weapon jokers: only in YOUR local save (SG_PlayerProgress.playerProgress.itemJokers, item -> jokers); the game
      -- does not send other players' weapon jokers, so they can only be shown for yourself.
      if C.showOwnWeaponJokers ~= false then
        local me = localPlayer()
        if me and playerName(me) == name then
          local wj = UI.readWeaponJokers and UI.readWeaponJokers() or {}
          for _, slot in ipairs({ "Primary", "Secondary" }) do
            local list = lo[slot] and wj[lo[slot]]
            if list and #list > 0 then
              local t = {}
              for _, j in ipairs(list) do t[#t + 1] = jname(j) end
              lo[slot .. "Jokers"] = table.concat(t, " / ")
            end
          end
        end
      end
      if next(lo) then
        Session.loadouts[name] = lo
        local parts = {}
        for _, k in ipairs({ "Primary", "Secondary", "Utility", "Spell1", "Spell2", "Spell3", "HeroJokers", "Jokers" }) do
          if lo[k] then parts[#parts + 1] = k .. "=" .. lo[k] end
        end
        local line = table.concat(parts, "  ")
        if loadoutLast[name] ~= line then
          loadoutLast[name] = line
          log("loadout of " .. name .. ": " .. line)
        end
      end
    end
  end
end

-- Jokers (diagnostics): the joker lists in the synced player progress and in the joker component are written to
-- the log in full whenever they change, to find which list holds the jokers you started with / picked up.
local JOKER_SOURCES = {
  { owner = "ps", path = { "playerProgressReplicated", "itemJokers" } },
  { owner = "ps", path = { "playerProgressReplicated", "runtimeInventory" } },
  { owner = "ps", path = { "playerProgressReplicated", "itemsUpgrades" } },
  { owner = "ps", path = { "playerRuntimeStats", "datasWepA" } },
  { owner = "ps", path = { "playerRuntimeStats", "datasWepB" } },
  { owner = "ps", path = { "selectedPlayerItemsServer", "wepA" } },
  { owner = "ps", path = { "selectedPlayerItemsServer", "wepB" } },
  { owner = "ps", path = { "persistentItems" } },
  { owner = "ps", path = { "itemHeroJokers" } },
  { owner = "comp", path = { "playerLocalJokers" } },
  { owner = "comp", path = { "playerLocalJokersServerRetrieved" } },
}
local jokerLast = {}
-- weapon jokers (diagnostics): the weapon actors (BP_Item_Minigun_C ...) of the players' primary / secondary are
-- searched for properties with joker / tweak / upgrade / owner in their name; those values are logged on change.
local weaponProbeLast = {}
local function probeWeapons()
  local classes = {}
  for _, lo in pairs(Session.loadouts or {}) do
    for _, k in ipairs({ "Primary", "Secondary" }) do
      if lo[k] then classes["BP_Item_" .. lo[k]:gsub(" ", "") .. "_C"] = true end
    end
  end
  for cls in pairs(classes) do
    local insts = safe(FindAllOf, cls) or {}
    local i = 0
    for _, obj in ipairs(insts) do
      if isValidObj(obj) then
        i = i + 1
        if i > 4 then break end
        local parts = {}
        local cur, depth = safe(function() return obj:GetClass() end), 0
        while isValidObj(cur) and depth < 4 and not fullName(cur):find("/Script/", 1, true) do
          pcall(function() cur:ForEachProperty(function(p)
            local pn = p:GetFName():ToString()
            local l = pn:lower()
            if l:find("joker") or l:find("tweak") or l:find("upgrade") or l:find("owner") or l:find("itemname") then
              local d = describeProp(p, safe(function() return obj[pn] end))
              if d and d ~= "" then parts[#parts + 1] = shortField(pn) .. "=" .. d end
            end
          end) end)
          cur = safe(function() return cur:GetSuperStruct() end)
          depth = depth + 1
        end
        local line = table.concat(parts, "  ")
        local k = cls .. "#" .. i
        if weaponProbeLast[k] ~= line then
          weaponProbeLast[k] = line
          log(string.format("weapon %s #%d on %s: %s", cls, i, tostring(Session.map), line:sub(1, 3000)))
        end
      end
    end
  end
end

-- weapon jokers (diagnostics, once per game run): the save-game objects in memory (SG_PlayerItems / SG_PlayerProgress)
-- and the game instance, fields whose name mentions joker / tweak / upgrade / item.
local saveProbed = {}
local function probeSaves()
  local targets = {
    { "SG_PlayerItems", safe(FindFirstOf, "SG_PlayerItems_C") },
    { "SG_PlayerProgress", safe(FindFirstOf, "SG_PlayerProgress_C") },
    { "GameInstance", UEHelpers_ok and safe(UEHelpers.GetGameInstance) or nil },
  }
  for _, t in ipairs(targets) do
    local label, obj = t[1], t[2]
    if not saveProbed[label] then
      if isValidObj(obj) then
        saveProbed[label] = true
        local cur, depth = safe(function() return obj:GetClass() end), 0
        while isValidObj(cur) and depth < 3 and not fullName(cur):find("/Script/", 1, true) do
          pcall(function() cur:ForEachProperty(function(p)
            local pn = p:GetFName():ToString()
            local l = pn:lower()
            if l:find("joker") or l:find("tweak") or l:find("upgrade") or (label ~= "GameInstance" and l:find("item"))
              or (label ~= "GameInstance" and l:find("progress")) then
              local d = describeProp(p, safe(function() return obj[pn] end))
              log(string.format("save probe %s.%s (%s): %s", label, shortField(pn), propClassName(p), tostring(d):sub(1, 4000)))
            end
          end) end)
          cur = safe(function() return cur:GetSuperStruct() end)
          depth = depth + 1
        end
      end
    end
  end
end

pollJokers = function()
  if not Session then return end
  pcall(probeWeapons)
  pcall(probeSaves)
  local list = safe(FindAllOf, "BP_PlayerState_C")
  if not list then return end
  for _, ps in ipairs(list) do
    if isValidObj(ps) then
      local name = playerName(ps)
      local comp = safe(function() return ps.AC_PlayerStateJoker end)
      for _, src in ipairs(JOKER_SOURCES) do
        local obj = (src.owner == "comp") and comp or ps
        if isValidObj(obj) then
          local d
          if #src.path == 1 then
            local p = findProp(obj, src.path[1])
            if p then d = describeProp(p, safe(function() return obj[p:GetFName():ToString()] end)) end
          else
            local p = findProp(obj, src.path[1])
            local fm = p and structFieldMap(p)
            local f = fm and fm[src.path[2]]
            local st = p and safe(function() return obj[p:GetFName():ToString()] end)
            if f and st then d = describeProp(f.prop, safe(function() return st[f.name] end)) end
          end
          d = d or "(not readable)"
          local k = name .. "|" .. table.concat(src.path, ".")
          if jokerLast[k] ~= d then
            jokerLast[k] = d
            log(string.format("jokers %s.%s on %s: %s", name, table.concat(src.path, "."), tostring(Session.map), d:sub(1, 2500)))
          end
        end
      end
    end
  end
end

-- Difficulty: properties with "difficult" in their name on the game state / game instance. All candidates are logged
-- once per map; the first readable one is shown in the title line.
local difficultyMap = nil
pollDifficulty = function()
  if not Session or isLobby(Session.map) or difficultyMap == Session.map then return end
  -- 1) the game's own getter: F_GetDifficulty(out difficulty:int), used by the difficulty curves (game state)
  do
    local gs = safe(FindFirstOf, "BP_GameState_C")
    if isValidObj(gs) then
      local val, how = nil, nil
      local ok1, r1 = pcall(function() return gs:F_GetDifficulty() end)
      if ok1 and tonumber(unwrap(r1)) then val, how = tonumber(unwrap(r1)), "return value" end
      if val == nil then
        local out = {}
        local ok2 = pcall(function() gs:F_GetDifficulty(out) end)
        local v = out.difficulty or out.Difficulty or out[1]
        if ok2 and tonumber(unwrap(v)) then val, how = tonumber(unwrap(v)), "out table" end
      end
      if val == nil then
        log("difficulty: F_GetDifficulty not callable (" .. tostring(r1) .. ")")
      else
        difficultyMap = Session.map
        local names = C.difficultyNames or {}
        Session.difficulty = names[val] or ("Difficulty " .. val)
        log(string.format("difficulty: %s (value %d via F_GetDifficulty %s)", Session.difficulty, val, how))
        return
      end
    end
  end
  local cands = {}
  local objs = {
    { "GameState", safe(FindFirstOf, "BP_GameState_C") },
    { "GameInstance", UEHelpers_ok and safe(UEHelpers.GetGameInstance) or nil },
  }
  for _, o in ipairs(objs) do
    local obj = o[2]
    if isValidObj(obj) then
      local cur, depth = safe(function() return obj:GetClass() end), 0
      while isValidObj(cur) and depth < 4 do
        pcall(function() cur:ForEachProperty(function(p)
          local pn = p:GetFName():ToString()
          if pn:lower():find("difficult") then
            local d = describeProp(p, safe(function() return obj[pn] end))
            cands[#cands + 1] = { label = o[1] .. "." .. shortField(pn), value = d }
          end
        end) end)
        cur = safe(function() return cur:GetSuperStruct() end)
        depth = depth + 1
      end
    end
  end
  if #cands == 0 then
    -- nothing called "difficulty": write the game state's / game instance's simple values to the log once, to find it
    if isValidObj(objs[1][2]) then
      difficultyMap = Session.map
      for _, o in ipairs(C.debug and objs or {}) do
        local obj = o[2]
        if isValidObj(obj) then
          local names = {}
          local cur, depth = safe(function() return obj:GetClass() end), 0
          while isValidObj(cur) and depth < 3 and not fullName(cur):find("/Script/", 1, true) do
            pcall(function() cur:ForEachProperty(function(p)
              local pn = p:GetFName():ToString()
              local pc = propClassName(p)
              if pc ~= "StructProperty" and pc ~= "ArrayProperty" and pc ~= "MapProperty" and pc ~= "ObjectProperty"
                and pc ~= "MulticastInlineDelegateProperty" and pc ~= "ClassProperty" then
                local d = describeValue(safe(function() return obj[pn] end))
                names[#names + 1] = shortField(pn) .. "=" .. tostring(d)
              end
            end) end)
            cur = safe(function() return cur:GetSuperStruct() end)
            depth = depth + 1
          end
          dlog("no difficulty property found; " .. o[1] .. " values on " .. tostring(Session.map) .. ": " .. table.concat(names, "  "):sub(1, 6000))
        end
      end
    end
    return
  end
  difficultyMap = Session.map
  local parts = {}
  for _, c in ipairs(cands) do parts[#parts + 1] = c.label .. "=" .. tostring(c.value) end
  dlog("difficulty candidates on " .. tostring(Session.map) .. ": " .. table.concat(parts, "  "))
  for _, c in ipairs(cands) do
    local v = c.value
    if v and v ~= "" and not v:find("^{") and not v:find("^%[") then
      local label = (C.difficultyNames or {})[v] or (C.difficultyNames or {})[tonumber(v) or ""] or v
      Session.difficulty = pretty(label) or label
      log("difficulty: " .. Session.difficulty .. " (from " .. c.label .. ")")
      break
    end
  end
end



-- Shield: every PlayerState has an AC_PlayerState_Shield component. Its numeric "shield" property is read every
-- second for every player and each increase is added to that player's "Shield" (shield generated).
-- The component's properties / functions are written to the log once, to check that the right value is used.
local SHIELD_COMP = "/Game/Player/AC_PlayerState_Shield.AC_PlayerState_Shield_C"
local shieldProp = nil      -- full property name, false = none found
local shieldLast, shieldSession = {}, nil
pollShield = function()
  if not Session then return end
  if shieldProp == nil then
    local cls = safe(StaticFindObject, SHIELD_COMP)
    if not isValidObj(cls) then return end
    local props, fns, cands = {}, {}, {}
    pcall(function() cls:ForEachProperty(function(p)
      local n, t = p:GetFName():ToString(), propClassName(p)
      props[#props + 1] = n .. ":" .. t
      local l = n:lower()
      if (t == "DoubleProperty" or t == "FloatProperty" or t == "IntProperty") and l:find("shield")
        and not l:find("max") and not l:find("timer") and not l:find("rate") and not l:find("speed")
        and not l:find("delay") and not l:find("decrea") and not l:find("cooldown") then
        cands[#cands + 1] = n
      end
    end) end)
    pcall(function() cls:ForEachFunction(function(f)
      local n = f:GetFName():ToString()
      if not n:find("^ExecuteUbergraph") then fns[#fns + 1] = n end
    end) end)
    dlog("shield component properties: " .. table.concat(props, ", "))
    dlog("shield component functions: " .. table.concat(fns, ", "))
    -- prefer a "current" value, else the first candidate
    shieldProp = false
    for _, n in ipairs(cands) do if n:lower():find("current") then shieldProp = n end end
    if not shieldProp and cands[1] then shieldProp = cands[1] end
    if C.shieldProperty then shieldProp = C.shieldProperty end
    log("shield value used: " .. tostring(shieldProp) .. "  (candidates: " .. table.concat(cands, ", ") .. ")")
  end
  if not shieldProp then return end
  if shieldSession ~= Session.id then shieldSession = Session.id; shieldLast = {} end
  local list = safe(FindAllOf, "BP_PlayerState_C")
  if not list then return end
  for _, ps in ipairs(list) do
    if isValidObj(ps) then
      local comp = safe(function() return ps.AC_PlayerState_Shield end)
      local v = isValidObj(comp) and tonumber(unwrap(safe(function() return comp[shieldProp] end))) or nil
      if v then
        local name = playerName(ps)
        local last = shieldLast[name]
        if last and v > last + 0.01 then addMisc(name, "shield", v - last) end
        shieldLast[name] = v
      end
    end
  end
end
end

MergeBoards = function()
  if not Session then return end
  local me = localPlayer()
  local myName = me and playerName(me) or nil
  for name, b in pairs(Boards) do
    local s = statsFor(name)
    for stat, v in pairs(b.mapped) do
      if STATS_SET[stat] and (name ~= myName or (s[stat] or 0) == 0) then s[stat] = v end
    end
  end
end

------------------------------------------------------------------ start-up
local function key(name)
  if not Key or not name then return nil end
  return Key[name] or Key[tostring(name):upper()] or Key[tostring(name):upper() .. "_ARROW"]
end

local function bind(name, fn)
  local k = key(name)
  if not k then log("unknown key " .. tostring(name)); return end
  RegisterKeyBind(k, function() ExecuteInGameThread(fn) end)
end

bind(C.keyToggleScoreboard, function()
  if UI.visible and UI.mode == "live" then hideWidget() else showLive() end
end)
bind(C.keyHistory, function()
  if UI.visible and UI.mode == "history" then hideWidget() else openHistory() end
end)
bind(C.keyHistoryOlder or "LEFT_ARROW", function() stepHistory(1) end)
-- scroll the board when it is taller than the screen
local function scrollBy(d)
  if not UI.visible or uiBlocked() or (UI.maxScroll or 0) <= 0 then return end
  UI.scroll = math.max(0, math.min((UI.scroll or 0) + d, UI.maxScroll))
  render(currentView())
end
bind(C.keyScrollUp or "UP_ARROW", function() scrollBy(-(C.scrollStep or 120)) end)
bind(C.keyScrollDown or "DOWN_ARROW", function() scrollBy(C.scrollStep or 120) end)
bind(C.keyHistoryNewer or "RIGHT_ARROW", function() stepHistory(-1) end)
bind(C.keyReset or "F11", function()
  -- throw away the current game's numbers WITHOUT saving them (handy for testing, also works in the lobby)
  newSession(currentMapName())
  log("stats reset (discarded, not saved)")
  if UI.visible and UI.mode == "live" and not uiBlocked() then render(liveView()) end
end)
bind(C.keyEndSession, function()
  local map = currentMapName()
  local hadData = Session and sessionHasData(Session)
  if Session then Session.map = isLobby(Session.map) and "Manual" or Session.map end
  endSession("manual")
  newSession(map)
  if not hadData then log("nothing to save (no stats recorded this game)") end
end)
-- research tools (C.debug = true): function list + class dump, used to find the right game functions after an update
if C.debug then bind(C.keyDiscovery or "F9", function() writeDiscovery(); classDump() end) end

-- hooks: retry until the game's Blueprints are loaded
local hooksDone = false
LoopAsync(2000, function()
  if hooksDone then return true end
  local player = safe(FindFirstOf, "BP_Player_C")
  -- wait until the map has been loaded for a few seconds (installing hooks while a level streams in is risky)
  if isValidObj(player) and UI.mapSince and os.time() - UI.mapSince >= (C.hookDelayAfterMapChange or 5) and not tostring(UI.mapName):find("Transition") then
    ExecuteInGameThread(function()
      if hooksDone then return end
      hooksDone = installHooks()
      if hooksDone and C.debug and C.dumpClassesOnStart then pcall(classDump) end
    end)
  end
  return false
end)

-- Some boss Blueprints (the Cryptic Train) only load with their mission, so they cannot be hooked at start-up.
-- After a map change the mod looks up those few functions by their exact name (cheap) every 2 seconds for
-- 2 minutes, and hooks them as soon as they exist. (No full function scan: that caused stutters.)
local scanMap, lateUntil, lateNext = nil, 0, 0
local function tryLateHooks()
  if not hooksDone then return true end
  local allDone = true
  for path, ev in pairs(C.lateHooks or {}) do
    if not hooked[path] then
      local fnObj = safe(StaticFindObject, path)
      if isValidObj(fnObj) and C.events[ev] then
        hookEvents(path, { ev })
      end
      if not hooked[path] then allDone = false end
    end
  end
  return allDone
end

-- map / session watcher and autosave
local tick = 0
LoopAsync(1000, function()
  tick = tick + 1
  ExecuteInGameThread(function()
    local ok, err = pcall(function()
      checkMapChange()
      -- reading other objects is skipped on start-up / menu maps and while a level loads (that crashed the game)
      -- only when the hooks are in (= a player exists) and the map has been loaded for a while
      local canPoll = Session and hooksDone and not uiBlocked()
        and os.time() - (UI.mapSince or os.time()) >= (C.pollDelayAfterMapChange or 12)
        and not matchesAny(tostring(Session.map), C.noPollMaps or { "OpeningCredits", "MainMenu", "Menu", "Intro", "Splash" })
      if canPoll then pcall(pollShield) end
      if Session and Session.map ~= scanMap and not uiBlocked() then
        scanMap = Session.map
        lateUntil = os.time() + 120
      end
      if os.time() <= lateUntil and os.time() >= lateNext and canPoll then
        lateNext = os.time() + 2
        if tryLateHooks() then lateUntil = 0 end
      end
      if tick % 3 == 0 and canPoll then
        pcall(pollBoards)
        pcall(pollLoadouts)
        if C.debug and tick % 15 == 0 then pcall(pollJokers) end
        if tick % 15 == 0 then pcall(pollDifficulty) end
        pcall(MergeBoards)
      end
      if tick % 30 == 0 then autosaveCurrent() end
      if UI.visible and UI.hideAt and os.time() >= UI.hideAt then hideWidget(); UI.hideAt = nil end
      if uiBlocked() then
        if UI.widget then pcall(destroyUI) end
      elseif UI.visible and UI.mode == "live" and tick % 2 == 0 and UI.widget and isValidObj(UI.widget) then
        render(liveView())
      end
    end)
    if not ok then log("tick error: " .. tostring(err)) end
  end)
  return false
end)

log(string.format("FFW_Scoreboard %s loaded%s. F6 scoreboard, F8 saved games, F10 save + new game.", VERSION, C.debug and " (debug mode: F9 = discovery)" or ""))
