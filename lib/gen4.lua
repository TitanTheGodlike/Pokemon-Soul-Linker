-- Diamond / Pearl / Platinum / HeartGold / SoulSilver (Gen 4): RAM layout, text and data read
-- from the game. game.lua copies these functions over its own when a Gen 4 game is running, so
-- the rest of Soul Link sees the same game.* interface as in Black/White.
local nds = require("nds")
local pkm = require("pkm")

local G = {}
local game -- set by G.attach

-- the five games (first 3 letters of the game code)
G.GAMES = {
  ADA = { version = "D", title = "Diamond", family = "DP" },
  APA = { version = "P", title = "Pearl", family = "DP" },
  CPU = { version = "Pt", title = "Platinum", family = "Pt" },
  IPK = { version = "HG", title = "HeartGold", family = "HGSS" },
  IPG = { version = "SS", title = "SoulSilver", family = "HGSS" },
}

local D = "ARM9 System Bus"
local function u8(a) return memory.read_u8(a, D) end
local function u16(a) return memory.read_u16_le(a, D) end
local function u32(a) return memory.read_u32_le(a, D) end
local function s32(a) return memory.read_s32_le(a, D) end
local function isRam(p) return p >= 0x02000000 and p < 0x02400000 end

------------------------------------------------------------------ per-game layout
-- save: offsets in the save's "general" block (same layout as the save file); storage: the PC
-- boxes block, which follows the general block in RAM. fs: the field system (the game's main
-- overworld state), reached from a pointer the game keeps at a fixed spot (`basePtr`, per
-- language; other languages are found at run time) -> +baseFs.
local LAYOUT = {
  Pt = {
    basePtr = { E = 0x02101D2C }, baseFs = 0x1C,
    save = { name = 0x68, tid = 0x78, gender = 0x80, lang = 0x81, badges = 0x82, partyCap = 0x98, party = 0xA0,
             balls = 0xCEC, location = 0x1280, storage = 0xCF2C },
    boxes = { first = 4, stride = 0xFF0, count = 18 },
    fs = { task = 0x10, location = 0x1C, mapObjMan = 0x38, avatar = 0x3C },
    avatarObj = 0x30,
    obj = { localId = 0x08, facing = 0x28, pos = 0x70, billboard = 0x10C },
    camera = 0x021C5AD8, -- view matrix (English); other versions are searched for
    zone0 = { 0x00, 0x00, 0x00, 0x00, 0x91, 0x01, 0x81, 0x03, 0x17, 0x00, 0xE8, 0x03, 0xE8, 0x03, 0xFF, 0xFF },
    zone = { matrix = 0x02, encounters = 0x0E, place = 0x12 }, -- map header fields (24 bytes each)
  },
  DP = {
    basePtr = { E = 0x02106FAC }, baseFs = 0x1C,
    save = { name = 0x64, tid = 0x74, gender = 0x7C, lang = 0x7D, badges = 0x7E, partyCap = 0x90, party = 0x98,
             balls = 0xCE0, location = 0x1238, storage = 0xC100 },
    boxes = { first = 4, stride = 0xFF0, count = 18 },
    fs = { task = 0x10, location = 0x1C, mapObjMan = 0x34, avatar = 0x38 },
    avatarObj = 0x2C,
    obj = { localId = 0x08, facing = 0x28, pos = 0x70, billboard = 0x10C },
    camera = 0x021CED64,
    zone0 = { 0x00, 0x00, 0x00, 0x00, 0x70, 0x01, 0x3B, 0x03, 0x12, 0x00, 0xE8, 0x03, 0xE8, 0x03, 0xFF, 0xFF },
    zone = { matrix = 0x02, encounters = 0x0E, place = 0x12 },
    -- Diamond/Pearl's billboard entries are 0xB8 bytes: the same fields as Platinum's, shifted
    billboard = { size = 0xB8, shown = 0x18, set = 0x1C, tex = 0x84, texKey = 0x88, palKey = 0x90,
                  seq = 0xAA, frame = 0xAC, next = 0xB0, prev = 0xB4 },
  },
  HGSS = {
    basePtr = { E = 0x0211186C }, baseFs = 0x1C,
    save = { name = 0x64, tid = 0x74, gender = 0x7C, lang = 0x7D, badges = 0x7E, badges2 = 0x83, partyCap = 0x90,
             party = 0x98, balls = 0xD04, location = 0x1234, storage = 0xF700 },
    boxes = { first = 0, stride = 0x1000, count = 18 },
    fs = { task = 0x10, location = 0x20, mapObjMan = 0x3C, avatar = 0x40 },
    avatarObj = 0x30,
    obj = { localId = 0x08, facing = 0x28, pos = 0x70, billboard = 0x10C },
    camera = 0x021DA4E8,
    zone0 = { 0xFF, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x8B, 0x00, 0x8F, 0x01, 0x03, 0x00, 0xE8, 0x03, 0xE8, 0x03 },
    zone = { encounters8 = 0x00, matrix = 0x04, place = 0x12 }, -- encounter table: one byte, 0xFF = none
    encounterRates = "u8",
  },
}

-- where things are in the game files
local ROM = {
  Pt = {
    msg = "msgdata/pl_msg.narc", speciesText = 412, placeText = 433, typeText = 624,
    trainerNameText = 618, trainerClassText = 619,
    personal = "poketool/personal/pl_personal.narc", evolutions = "poketool/personal/evo.narc",
    encounters = "fielddata/encountdata/pl_enc_data.narc",
    trainers = "poketool/trainer/trdata.narc", trainerMons = "poketool/trainer/trpoke.narc",
    trainerMonBase = 6, trainerMonExtra = 2, -- Platinum/HGSS keep a ball-capsule word after each trainer Pokémon
    overworld = "data/mmodel/mmodel.narc", sheets = { boy = 90, girl = 91, boy_bike = 92, girl_bike = 93 },
    icons = "poketool/icongra/pl_poke_icon.narc", iconBase = 7, iconStep = 1,
    battle = "poketool/pokegra/pl_pokegra.narc", battleEncrypt = "pt",
    dexColor = 0x19,
  },
  DP = {
    msg = "msgdata/msg.narc", speciesText = 362, placeText = 382, typeText = 565,
    trainerNameText = 559, trainerClassText = 560,
    personal = "poketool/personal/personal.narc", evolutions = "poketool/personal/evo.narc",
    encounters = "fielddata/encountdata/d_enc_data.narc", encountersBy = { P = "fielddata/encountdata/p_enc_data.narc" },
    trainers = "poketool/trainer/trdata.narc", trainerMons = "poketool/trainer/trpoke.narc",
    trainerMonBase = 6, trainerMonExtra = 0,
    overworld = "data/mmodel/mmodel.narc", sheets = { boy = 90, girl = 91, boy_bike = 92, girl_bike = 93 },
    icons = "poketool/icongra/poke_icon.narc", iconBase = 7, iconStep = 1,
    battle = "poketool/pokegra/pokegra.narc", battleEncrypt = "dp",
    dexColor = 0x19,
  },
  HGSS = {
    msg = "a/0/2/7", speciesText = 237, placeText = 279, typeText = 735,
    trainerNameText = 729, trainerClassText = 730,
    personal = "a/0/0/2", evolutions = "a/0/3/4",
    encounters = "a/0/3/7", encountersBy = { SS = "a/1/3/6" }, -- HeartGold / SoulSilver tables
    trainers = "a/0/5/5", trainerMons = "a/0/5/6", trainerMonBase = 6, trainerMonExtra = 2,
    overworld = "a/0/8/1", sheets = { boy = 69, girl = 70, boy_bike = 71, girl_bike = 72 },
    icons = "a/0/2/0", iconBase = 7, iconStep = 1,
    battle = "a/0/0/4", battleEncrypt = "pt",
    dexColor = 0x19,
  },
}

------------------------------------------------------------------ Gen 4 text
-- the games' own character codes -> Unicode (Western letters, digits and punctuation)
local CHAR = {}
for i = 0, 9 do CHAR[0x121 + i] = string.char(48 + i) end
for i = 0, 25 do CHAR[0x12B + i] = string.char(65 + i); CHAR[0x145 + i] = string.char(97 + i) end
do
  local function add(start, s)
    local i = start
    for _, c in utf8.codes(s) do CHAR[i] = utf8.char(c); i = i + 1 end
  end
  add(0x15F, "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿŒœŞşªº")
  CHAR[0x1A5], CHAR[0x1A6], CHAR[0x1A7] = "er", "re", "r"
  add(0x1A8, "₽¡¿!?,.…·/‘’“”„«»()♂♀+-*#=&~:;♠♣♥♦★◎○□△◇@♪%☀☁☂☃")
  CHAR[0x1DE] = " "
end
G.CHAR = CHAR

-- a list of character codes -> UTF-8 (stops at 0xFFFF; compressed names start with 0xF100)
function G.decode(codes)
  if codes[1] == 0xF100 then
    -- compressed: 9-bit codes packed into 15 bits of each word
    local out, bits, nb = {}, 0, 0
    for i = 2, #codes do
      bits = bits | ((codes[i] & 0x7FFF) << nb); nb = nb + 15
      while nb >= 9 do
        local c = bits & 0x1FF
        bits, nb = bits >> 9, nb - 9
        if c == 0x1FF then codes = out; goto plain end
        out[#out + 1] = c
      end
    end
    codes = out
  end
  ::plain::
  local s = {}
  for _, c in ipairs(codes) do
    if c == 0xFFFF then break end
    if c == 0xE000 or c == 0x25BC or c == 0x25BD then s[#s + 1] = " "
    elseif c ~= 0xFFFE then s[#s + 1] = CHAR[c] or "?" end
  end
  return table.concat(s)
end

-- encrypted text file (absolute ROM address) -> list of strings (entry 0 at [1])
function G.textFile(base)
  local n, seed = nds.u16(base), nds.u16(base + 2)
  local out = {}
  for i = 0, n - 1 do
    local key = (seed * 0x2FD * (i + 1)) & 0xFFFF
    local k2 = key | (key << 16)
    local off = nds.u32(base + 4 + i * 8) ~ k2
    local size = nds.u32(base + 8 + i * 8) ~ k2
    local codes = {}
    if size > 0 and size < 0x1000 then
      local b = nds.bytes(base + off, size * 2)
      local ck = (0x91BD3 * (i + 1)) & 0xFFFF
      for j = 1, size do
        codes[j] = ((b[j * 2 - 1] | (b[j * 2] << 8)) ~ ck) & 0xFFFF
        ck = (ck + 0x493D) & 0xFFFF
      end
    end
    out[i + 1] = G.decode(codes)
  end
  return out
end

-- in-game names are in capitals in the English games ("TURTWIG"); show them like Gen 5 does
local KEEP_CAPS = { TM = true, HM = true, HP = true, PP = true, TV = true, GTS = true, ["???"] = true }
function G.nice(s)
  if not s:find("%u%u") or s:find("%l") then return s end
  return (s:gsub("[%a\128-\255][%a\128-\255'%.]*", function(w)
    if KEEP_CAPS[w] then return w end
    local first = w:match("^[%z\1-\127\194-\244][\128-\191]*")
    return first .. w:sub(#first + 1):lower()
  end))
end

------------------------------------------------------------------ finding the save in RAM
local L, R -- this game's layout / files

-- general save block: the trainer block with this language, a name and a 6-slot party
local function looksLikeSave(g)
  if not isRam(g) then return false end
  local S = L.save
  local c = u16(g + S.name)
  if c == 0 or c == 0xFFFF then return false end
  if u8(g + S.lang) ~= game.langId then return false end
  if u8(g + S.gender) > 1 then return false end
  return u32(g + S.partyCap) == 6 and u32(g + S.partyCap + 4) <= 6
end

-- the field system behind the fixed pointer, or nil (not in the overworld)
local function fieldSystem()
  local A = game.A
  if not A.basePtr then return nil end
  local base = u32(A.basePtr)
  if not isRam(base) then return nil end
  local fs = u32(base + L.baseFs)
  if not isRam(fs) then return nil end
  -- it points at the location in our save
  if u32(fs + L.fs.location) ~= A.save + L.save.location then return nil end
  return fs
end

local function useSave(g, basePtr)
  local S = L.save
  local A = { save = g, basePtr = basePtr }
  A.trainerName = g + S.name
  A.trainerId = g + S.tid
  A.gender = g + S.gender
  A.badges = g + S.badges
  A.badges2 = S.badges2 and g + S.badges2 or nil
  A.partyCount = g + S.partyCap + 4
  A.party = g + S.party
  A.ballsPouch = g + S.balls
  A.location = g + S.location
  A.boxes = g + S.storage + L.boxes.first
  game.A, game.located = A, true
end

-- Finding the save: through the fixed pointer for listed versions; otherwise search RAM for the
-- trainer block (a slice per call) and then the fixed spot that leads to its field system.
local search -- { at, found }
local SLICE = 0x10000
function G.locate(frame)
  if game.located then return true end
  local hint = L.basePtr[game.lang]
  if hint then
    local base = u32(hint)
    if isRam(base) then
      local fs = u32(base + L.baseFs)
      if isRam(fs) then
        local loc = u32(fs + L.fs.location)
        local g = loc - L.save.location
        if looksLikeSave(g) then useSave(g, hint); return true end
      end
    end
  end
  -- unlisted version: find the save block, then the pointer
  search = search or { at = 0x02200000 }
  if not search.save then
    local b = memory.read_bytes_as_array(search.at, SLICE + 0x100, D)
    local S = L.save
    for i = 1, SLICE, 4 do
      -- party capacity 6 followed by a count <= 6
      if b[i + S.partyCap] == 6 and b[i + S.partyCap + 1] == 0 and b[i + S.partyCap + 2] == 0
         and b[i + S.lang] == game.langId and looksLikeSave(search.at + i - 1) then
        search.save = search.at + i - 1
        search.at = 0x02000000
        break
      end
    end
    if not search.save then
      search.at = search.at + SLICE
      if search.at >= 0x02400000 then search.at = 0x02200000 end
      return false
    end
  end
  -- a pointer in the game's static data whose target +baseFs leads to a field system
  -- pointing at our save's location (only while in the overworld)
  local want = search.save + L.save.location
  local b = memory.read_bytes_as_array(search.at, SLICE, D)
  for i = 1, SLICE - 3, 4 do
    local p = b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
    if p >= 0x02200000 and p < 0x02400000 then
      local fs = u32(p + L.baseFs)
      if isRam(fs) and u32(fs + L.fs.location) == want then
        useSave(search.save, search.at + i - 1)
        print(string.format("Soul Link: found the save data of %s (%s) at %08X", game.title, game.code, search.save))
        return true
      end
    end
  end
  search.at = search.at + SLICE
  if search.at >= 0x02200000 then search.at = 0x02000000; search.save = nil end
  return false
end

------------------------------------------------------------------ data from the ROM
local zoneTable -- RAM address of the map header table (24 bytes per map)
local zoneCount = 0
local personal

local function findZoneTable()
  local sig = L.zone0
  local from, to = 0x02000000, 0x02120000
  for base = from, to - 1, 0x10000 do
    local b = memory.read_bytes_as_array(base, 0x10000 + #sig, D)
    for i = 1, 0x10000, 4 do
      if b[i] == sig[1] then
        local ok = true
        for k = 2, #sig do if b[i + k - 1] ~= sig[k] then ok = false; break end end
        if ok then return base + i - 1 end
      end
    end
  end
end

function G.loadRomData(cacheDir)
  nds.init()
  local msg = nds.narc(R.msg)
  local function text(i) return G.textFile((msg.range(i))) end
  game.speciesNames, game.locationNames, game.typeNames = {}, {}, {}
  for i, s in ipairs(text(R.speciesText)) do game.speciesNames[i] = G.nice(s) end
  for i, s in ipairs(text(R.placeText)) do game.locationNames[i] = G.nice(s) end
  for i, s in ipairs(text(R.typeText)) do game.typeNames[i] = G.nice(s) end
  personal = nds.narc(R.personal)
  zoneTable = findZoneTable()
  -- the table ends where the entries stop looking like map headers
  zoneCount = 0
  if zoneTable then
    for k = 0, 1999 do
      local a = zoneTable + k * 24
      if u16(a + L.zone.matrix) >= 1000 or u8(a + L.zone.place) >= #game.locationNames + 8 then break end
      zoneCount = k + 1
    end
  end
  -- player sprite sheets for the drawn-overlay fallback (frame order differs from Gen 5's)
  game.sprites, game.spriteSpans = {}, {}
  local ow = nds.narc(R.overworld)
  for _, name in ipairs({ "boy", "girl", "boy_bike", "girl_bike" }) do
    local path = cacheDir .. "/" .. game.code .. "_" .. name .. ".png"
    local f = io.open(path, "rb")
    if f then f:close() end
    local ok, _, _, _, spans = pcall(nds.btxToSheet, (ow.range(R.sheets[name])), path, 12, 32, f == nil)
    game.sprites[name] = path
    game.spriteSpans[name] = ok and spans or {}
  end
end

function G.zoneInfo(zone)
  if not zoneTable or zone < 0 or zone >= zoneCount then return nil end
  local a = zoneTable + zone * 24
  local Z = L.zone
  local enc
  if Z.encounters8 then
    enc = u8(a + Z.encounters8)
    if enc == 0xFF then enc = 0xFFFF end
  else
    enc = u16(a + Z.encounters)
  end
  return { matrix = u16(a + Z.matrix), encounters = enc, loc = u8(a + Z.place) }
end

-- all map headers, for the route list: place id + encounter table of each
function G.zones()
  local out = {}
  for z = 0, zoneCount - 1 do out[#out + 1] = G.zoneInfo(z) end
  return out
end

-- what an encounter table offers: "land" (grass/caves), "water" (only surfing/fishing) or nil
local encNarc
function G.wildKind(e)
  encNarc = encNarc or nds.narc(R.encountersBy and R.encountersBy[game.version] or R.encounters)
  if e >= encNarc.count then return nil end
  local a, b = encNarc.range(e)
  if L.encounterRates == "u8" then -- HGSS: rate bytes for grass, surf, rock smash, rods
    if nds.u8(a) > 0 then return "land" end
    for i = 1, 5 do if nds.u8(a + i) > 0 then return "water" end end
    return nil
  end
  -- Diamond/Pearl/Platinum: grass rate first, surfing and fishing from +0xCC
  if nds.u32(a) > 0 then return "land" end
  for o = 0xCC, b - a - 4, 4 do if nds.u32(a + o) ~= 0 then return "water" end end
  return nil
end

function G.tileBehavior() return nil end
function G.inGrass() return false end

function G.types(sp)
  if not personal or sp <= 0 or sp >= personal.count then return nil end
  local a = personal.range(sp)
  return nds.u8(a + 6), nds.u8(a + 7)
end

local familyRoot
function G.family(sp)
  if not familyRoot then
    familyRoot = {}
    local evo = nds.narc(R.evolutions)
    local parent = {}
    for s = 1, evo.count - 1 do
      local a, b = evo.range(s)
      for i = 0, 6 do
        if a + i * 6 + 6 > b then break end
        local method, target = nds.u16(a + i * 6), nds.u16(a + i * 6 + 4)
        if method ~= 0 and target > 0 and target ~= s and not parent[target] then parent[target] = s end
      end
    end
    for s = 1, evo.count - 1 do
      local r, guard = s, 0
      while parent[r] and guard < 5 do r = parent[r]; guard = guard + 1 end
      familyRoot[s] = r
    end
  end
  return familyRoot[sp] or sp
end

------------------------------------------------------------------ live state
-- the local player's map object (nil outside the overworld)
local function playerObject()
  local fs = fieldSystem()
  if not fs then return nil end
  local av = u32(fs + L.fs.avatar)
  if not isRam(av) then return nil end
  local mo = u32(av + L.avatarObj)
  if not isRam(mo) or u8(mo + L.obj.localId) ~= 0xFF then return nil end
  return mo
end
G.playerObject = playerObject
G.fieldSystem = fieldSystem

-- facing in the map object: 0 up, 1 down, 2 left, 3 right -> Soul Link's 0 up, 1 left, 2 down, 3 right
local FACING = { [0] = 0, [1] = 2, [2] = 1, [3] = 3 }
local lastPos
function G.position()
  local mo = playerObject()
  if not mo then return lastPos end
  local p = mo + L.obj.pos
  lastPos = {
    zone = u32(game.A.location),
    x = s32(p) / 65536, y = s32(p + 4) / 65536, z = s32(p + 8) / 65536,
    facing = FACING[u8(mo + L.obj.facing) & 3],
    bike = false,
  }
  return lastPos
end

-- a Pokémon without a nickname carries its species name in capitals: show it like the species
local function niceNick(m)
  if m and m.nickname ~= "" then
    local sp = game.speciesName(m.species)
    if m.nickname:upper() == sp:upper() then m.nickname = sp end
  end
  return m
end
G.niceNick = niceNick

-- The battle setup while a battle runs (nil otherwise). The overworld starts a battle from a
-- field task whose data holds the setup; the setup (pret decompilations: FieldBattleDTO /
-- BattleSetup) starts with the battle type flags and the four parties (yours first, then the
-- opponent's). Found by following the field system's task chain and checking each task's data.
local function validParty(p)
  if not isRam(p) then return false end
  local cap, n = u32(p), u32(p + 4)
  return cap == 6 and n >= 1 and n <= 6
end
local function looksLikeSetup(d)
  return isRam(d) and u32(d) <= 0x3FFF and validParty(u32(d + 4)) and validParty(u32(d + 8))
end
local lastSetup
local function battleSetup()
  if lastSetup and looksLikeSetup(lastSetup.addr) and lastSetup.frame == emu.framecount() then return lastSetup.addr end
  local fs = fieldSystem()
  local found = nil
  if fs then
    local task, guard = u32(fs + L.fs.task), 0
    while not found and isRam(task) and guard < 8 do
      local env = u32(task + 0x0C)
      if isRam(env) then
        for o = 0, 0x40, 4 do
          local p = u32(env + o)
          if looksLikeSetup(p) then found = p; break end
        end
      end
      task = u32(task) -- the task that started this one
      guard = guard + 1
    end
  end
  lastSetup = found and { addr = found, frame = emu.framecount() } or nil
  return found
end
G.battleSetup = battleSetup

function G.inBattle() return battleSetup() ~= nil end

-- not a wild battle: trainers, link and Battle Frontier battles, Pal Park, the catching tutorial
local NOT_WILD = 0x1 | 0x4 | 0x80 | 0x200 | 0x400
function G.trainerBattle()
  local d = battleSetup()
  return d ~= nil and (u32(d) & NOT_WILD) ~= 0
end

function G.foes()
  local d = battleSetup()
  local p = d and u32(d + 8) -- parties[1]: the opponent
  if not p or not validParty(p) then return {} end
  local out = {}
  for i = 0, u32(p + 4) - 1 do
    local m = niceNick(pkm.read(p + 8 + i * 236, true))
    if m then out[#out + 1] = m end
  end
  return out
end

function G.party()
  local n = u32(game.A.partyCount)
  if n > 6 then return nil end
  local out = {}
  for i = 0, n - 1 do out[#out + 1] = niceNick(pkm.read(game.A.party + i * 236, true)) end
  return out, n
end

-- the Poké Ball pocket only holds balls
function G.hasPokeBalls()
  local b = memory.read_bytes_as_array(game.A.ballsPouch, 15 * 4, D)
  for i = 0, 14 do
    local item = b[i * 4 + 1] | (b[i * 4 + 2] << 8)
    local count = b[i * 4 + 3] | (b[i * 4 + 4] << 8)
    if item ~= 0 and count > 0 then return true end
  end
  return false
end

function G.trainerName()
  if not game.located then return "" end
  local codes = {}
  for i = 0, 7 do codes[#codes + 1] = u16(game.A.trainerName + i * 2) end
  return G.decode(codes) -- as typed (not title-cased like the game's own capitals)
end

-- gym badges (HeartGold/SoulSilver: Johto and Kanto)
function G.badgeCount()
  local n = 0
  for _, a in ipairs({ game.A.badges, game.A.badges2 }) do
    local b = u8(a)
    for i = 0, 7 do if (b >> i) & 1 == 1 then n = n + 1 end end
  end
  return n
end

-- is a Pokémon with this personality value in a PC box?
function G.inBoxes(pid)
  local B = L.boxes
  local p1, p2, p3, p4 = pid & 0xFF, (pid >> 8) & 0xFF, (pid >> 16) & 0xFF, (pid >> 24) & 0xFF
  for box = 0, B.count - 1 do
    local b = memory.read_bytes_as_array(game.A.boxes + box * B.stride, 30 * 136, D)
    for slot = 0, 29 do
      local i = slot * 136 + 1
      if b[i] == p1 and b[i + 1] == p2 and b[i + 2] == p3 and b[i + 3] == p4 then return true end
    end
  end
  return false
end

------------------------------------------------------------------ hook into game.lua
function G.attach(g, info)
  game = g
  L, R = LAYOUT[info.family], ROM[info.family]
  if not L or not R then return nil, info.title .. " isn't supported yet." end
  game.gen = 4
  game.family4 = info.family
  game.region = info.family == "HGSS" and "johto" or "sinnoh"
  game.rom = R
  game.layout = L
  for _, k in ipairs({ "locate", "loadRomData", "zoneInfo", "zones", "wildKind", "tileBehavior", "inGrass", "types",
                       "family", "position", "inBattle", "trainerBattle", "foes", "party", "hasPokeBalls",
                       "trainerName", "badgeCount", "inBoxes" }) do
    game[k] = G[k]
  end
  game.decodeString = G.decode
  game.playerObject = playerObject
  game.fieldSystem = fieldSystem
  game.battleSetup = battleSetup
  pkm.decode = G.decode
  return true
end

return G
