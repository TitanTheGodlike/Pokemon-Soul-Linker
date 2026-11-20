-- Pokémon Black/White and Black 2/White 2: version detection, RAM addresses, and data read from
-- the game itself.
local nds = require("nds")
local pkm = require("pkm")

local game = {}

-- the four games (first 3 letters of the game code)
local GAMES = {
  IRB = { version = "B", title = "Black", sequel = false },
  IRA = { version = "W", title = "White", sequel = false },
  IRE = { version = "B2", title = "Black 2", sequel = true },
  IRD = { version = "W2", title = "White 2", sequel = true },
}

-- RAM addresses for Black and Black 2 (English). `save` is where the game keeps its save data in
-- RAM; the save fields below are at the same offsets in all four games (only the "misc" block,
-- which holds money and badges, moved in Black 2/White 2).
local BASE = {
  [false] = { -- Black (English)
    save        = 0x0221BBAC,
    zone        = 0x0224F90C,
    posX        = 0x0224F910,
    posY        = 0x0224F914,
    posZ        = 0x0224F918,
    facing      = 0x0224F924,
    onBike      = 0x0224F94C,
    battleFlag  = 0x0226ACE6, -- 0x41 while a battle is running
    foeCount    = 0x0226ACF0,
    foeParty    = 0x0226ACF4, -- party-format foe Pokémon
    trainerBattle = 0x022697BE, -- non-zero opposing trainer id
  },
  [true] = { -- Black 2 (English)
    save        = 0x022055E4,
    zone        = 0x0223B444,
    posX        = 0x0223B448,
    posY        = 0x0223B44C,
    posZ        = 0x0223B450,
    facing      = 0x0223B45C,
    onBike      = 0x0223B484,
    -- the game's process system ("procsys.c" heap block, data address): +0x10 points at the
    -- running process's parameters, which during a battle is the battle setup (see battleSetup)
    procSys     = 0x02246B28,
  },
}
local SAVE = {
  itemsPouch  = 0x18400, -- 310 slots of (u16 item, u16 count); balls live here
  partyCount  = 0x18E04,
  party       = 0x18E08,
  trainerName = 0x19404,
  trainerId   = 0x19414,
  gender      = 0x19421, -- 0 boy, 1 girl
  boxes       = 0x00400, -- 24 boxes of 30 Pokémon (136 bytes each), 0x1000 apart
}
local BADGES = { [false] = 0x21204, [true] = 0x21104 }

-- offsets per version + language letter (game code 4th char). The whole RAM layout shifts by
-- one amount per version/language; versions not listed here are found at run time (game.locate).
local OFFSETS = {
  B = { J = -0x1A0, O = 0x0, E = 0x0, F = -0x80, I = -0x100, D = -0xC0, S = -0x40 },
  W = { J = -0x180, O = 0x20, E = 0x20, F = -0x60, I = -0xE0, D = -0xA0, S = -0x40 },
  B2 = { O = 0x0 },
  W2 = {},
}

-- what the trainer block in the save says about the game: language (game code 4th letter) and
-- version numbers; used to find the save data of versions without known offsets
local LANG_ID = { J = 1, E = 2, O = 2, F = 3, I = 4, D = 5, S = 7, K = 8 }
local VERSION_ID = { W = 20, B = 21, W2 = 22, B2 = 23 }

-- where things are in the game files (Black 2/White 2 moved some archives and text)
local ROM = {
  [false] = {
    speciesText = 70, placeText = 89, typeText = 199,
    overworld = "a/0/4/9", sheets = { boy = 6, girl = 9, boy_bike = 7, girl_bike = 10 },
    encounters = "a/1/2/6", trainers = "a/0/9/2", trainerMons = "a/0/9/3",
    iconBase = 7, -- party icon of species s = file iconBase + 2*s in a/0/0/7
  },
  [true] = {
    speciesText = 90, placeText = 109, typeText = 398,
    overworld = "a/0/4/8", sheets = { boy = 209, girl = 218, boy_bike = 210, girl_bike = 219 },
    encounters = "a/1/2/7", trainers = "a/0/9/1", trainerMons = "a/0/9/2",
    iconBase = 8,
  },
}

game.A = {}
game.located = false -- RAM addresses known (right away for listed versions, else once a save is loaded)

local function useOffset(off)
  local A = {}
  for k, v in pairs(BASE[game.sequel]) do A[k] = v + off end
  for k, v in pairs(SAVE) do A[k] = A.save + v end
  A.badges = A.save + BADGES[game.sequel]
  game.A, game.offset, game.located = A, off, true
end

game.gen = 5

function game.detect()
  local code = {}
  for i = 0, 3 do code[#code + 1] = string.char(memory.read_u8(0x023FFE0C + i)) end
  code = table.concat(code)
  -- Diamond / Pearl / Platinum / HeartGold / SoulSilver: their own module takes over
  local gen4 = require("gen4")
  local g4 = gen4.GAMES[code:sub(1, 3)]
  if g4 then
    local lang = code:sub(4, 4)
    if not LANG_ID[lang] and lang ~= "P" then return nil, "Unknown language version of " .. g4.title .. " (" .. code .. ")." end
    game.version, game.title, game.sequel = g4.version, g4.title, false
    game.code, game.lang = code, lang
    game.langId = LANG_ID[lang] or 2
    return gen4.attach(game, g4)
  end
  local g = GAMES[code:sub(1, 3)]
  if not g then
    return nil, "This doesn't look like a supported Pokémon game (game code " .. code .. ")."
  end
  local lang = code:sub(4, 4)
  if not LANG_ID[lang] then return nil, "Unknown language version of " .. g.title .. " (" .. code .. ")." end
  game.version = g.version -- "B", "W", "B2", "W2"
  game.title = g.title
  game.sequel = g.sequel   -- Black 2 / White 2
  game.code = code
  game.lang = lang
  game.region = g.sequel and "unova2" or "unova1" -- games whose area numbers line up
  game.rom = ROM[g.sequel]
  local off = OFFSETS[g.version][lang]
  if off then useOffset(off) end
  return true
end

-- For versions without a known offset: once a save is loaded, find its trainer block near where
-- the listed versions keep it (language + version numbers at +0x1E/+0x1F, a name at +4, a sane
-- party count) and move every address by the same amount. Cheap; call it every frame.
local nextLocate = 0
function game.locate(frame)
  if game.located then return true end
  if frame < nextLocate then return false end
  nextLocate = frame + 30
  local want = BASE[game.sequel].save + SAVE.trainerName - 4
  local from, size = want - 0x2000, 0x4000
  local b = memory.read_bytes_as_array(from, size + 0x20)
  local lang, ver = LANG_ID[game.lang], VERSION_ID[game.version]
  for i = 1, size, 4 do
    if b[i + 0x1E] == lang and b[i + 0x1F] == ver then
      local c = b[i + 4] | (b[i + 5] << 8)
      if c ~= 0 and c ~= 0xFFFF then
        local off = from + i - 1 - want
        local count = memory.read_u32_le(BASE[game.sequel].save + off + SAVE.partyCount)
        if count <= 6 then
          useOffset(off)
          print(string.format("Soul Link: found the save data of %s (%s), offset %d", game.title, game.code, off))
          return true
        end
      end
    end
  end
  return false
end

------------------------------------------------------------------ data from the ROM
game.speciesNames, game.locationNames, game.typeNames = {}, {}, {}
local zoneTable, personal

function game.loadRomData(cacheDir)
  nds.init()
  local R = game.rom
  local text = nds.narc("a/0/0/2")
  local function textFile(i) return nds.text((text.range(i))) end
  game.speciesNames = textFile(R.speciesText)  -- [species+1]
  game.locationNames = textFile(R.placeText)   -- [loc+1]
  game.typeNames = textFile(R.typeText)        -- [type+1]
  local z = nds.narc("a/0/1/2")
  local zs, ze = z.range(0)
  zoneTable = { start = zs, count = (ze - zs) // 48 }
  personal = nds.narc("a/0/1/6")
  -- player sprite sheets (boy, girl) from the overworld sprite archive
  local ow = nds.narc(R.overworld)
  game.sprites = {}      -- name -> png path
  game.spriteSpans = {}  -- name -> per-frame row spans (for drawing other players behind you)
  for _, name in ipairs({ "boy", "girl", "boy_bike", "girl_bike" }) do
    local path = cacheDir .. "/" .. game.code .. "_" .. name .. ".png"
    local f = io.open(path, "rb")
    if f then f:close() end
    local _, _, _, spans = nds.btxToSheet((ow.range(R.sheets[name])), path, 12, 24, f == nil)
    game.sprites[name] = path
    game.spriteSpans[name] = spans
  end
end

function game.speciesName(sp)
  return game.speciesNames[sp + 1] or ("#" .. tostring(sp))
end

function game.locationName(loc)
  return game.locationNames[loc + 1] or ("Area " .. tostring(loc))
end

-- encounter table id of a zone header at ROM address a (0xFFFF = none). Black 2/White 2 keep
-- flags in the upper byte, so only the lower byte is the table (0xFF = none).
function game.zoneEncounters(a)
  if game.sequel then
    local e = nds.u8(a + 0x14)
    return e == 0xFF and 0xFFFF or e
  end
  return nds.u16(a + 0x14)
end

-- zone header: matrix id + location name id
function game.zoneInfo(zone)
  if not zoneTable or zone < 0 or zone >= zoneTable.count then return nil end
  local a = zoneTable.start + zone * 48
  return {
    matrix = nds.u16(a + 0x04),
    encounters = game.zoneEncounters(a),
    loc = nds.u8(a + 0x1A),
  }
end

-- tile type under a position, read from the map files: zone -> matrix -> map file -> 32x32 tiles
local matrices, mapFiles
local tileCache = {}
local GRASS = { [0x04] = true, [0x06] = true }
function game.tileBehavior(pos)
  local zi = game.zoneInfo(pos.zone)
  if not zi then return nil end
  local tx, tz = math.floor(pos.x), math.floor(pos.z)
  local key = zi.matrix .. ":" .. tx .. ":" .. tz
  local cached = tileCache[key]
  if cached ~= nil then return cached or nil end
  matrices = matrices or nds.narc("a/0/0/9")
  mapFiles = mapFiles or nds.narc("a/0/0/8")
  local result = false
  if zi.matrix < matrices.count then
    local m = matrices.range(zi.matrix)
    local w, h = nds.u16(m + 4), nds.u16(m + 6)
    local cx, cz = tx // 32, tz // 32
    if cx >= 0 and cz >= 0 and cx < w and cz < h then
      local mapId = nds.u32(m + 8 + (cz * w + cx) * 4)
      if mapId < mapFiles.count then
        local f = mapFiles.range(mapId)
        local magic = nds.u16(f)
        if magic == 0x4257 or magic == 0x4347 then -- "WB" / "GC": section 1 holds the tiles
          local perm = f + nds.u32(f + 8)
          local pw, ph = nds.u16(perm), nds.u16(perm + 2)
          local lx, lz = tx % 32, tz % 32
          if lx < pw and lz < ph then result = nds.u8(perm + 4 + (lz * pw + lx) * 8 + 4) end
        end
      end
    end
  end
  game.tileCacheSize = (game.tileCacheSize or 0) + 1
  if game.tileCacheSize > 4096 then tileCache, game.tileCacheSize = {}, 0 end
  tileCache[key] = result
  return result or nil
end

function game.inGrass(pos)
  local b = game.tileBehavior(pos)
  return b ~= nil and GRASS[b] == true
end

-- evolution family root (for the dupes clause), built from this game's evolution table
local familyRoot
function game.family(sp)
  if not familyRoot then
    familyRoot = {}
    local evo = nds.narc("a/0/1/9")
    local parent = {}
    for s = 1, evo.count - 1 do
      local a = evo.range(s)
      for i = 0, 6 do
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

-- primary/secondary type ids of a species (from this game's data, so randomized types work)
function game.types(sp)
  if not personal or sp <= 0 or sp >= personal.count then return nil end
  local a = personal.range(sp)
  return nds.u8(a + 6), nds.u8(a + 7)
end

------------------------------------------------------------------ live state
local function fx16(a) return memory.read_s32_le(a) / 65536 end

function game.position()
  local A = game.A
  return {
    zone = memory.read_u16_le(A.zone),
    x = fx16(A.posX), y = fx16(A.posY), z = fx16(A.posZ),
    facing = (memory.read_u16_le(A.facing) >> 14) & 3, -- 0 up,1 left,2 down,3 right
    bike = memory.read_u8(A.onBike) ~= 0,
  }
end

local function isRam(p) return p >= 0x02000000 and p < 0x02400000 end

-- The game's heap keeps a header in front of every block: "UD" while in use, and the source file
-- that allocated it ("procsys.c", "btl_setup.c", ...) 0x18 bytes before the block's data.
local function heapBlock(data, tag)
  if not isRam(data) or memory.read_u16_le(data - 0x2C) ~= 0x5544 then return false end
  local b = memory.read_bytes_as_array(data - 0x18, #tag + 1)
  for i = 1, #tag do if b[i] ~= tag:byte(i) then return false end end
  return b[#tag + 1] == 0
end

-- Black 2 / White 2: the battle setup while a battle runs (nil otherwise). The game runs nested
-- process systems ("procsys.c" blocks); the one the field and battles run in has the running
-- process's parameters at +0x10, which during a battle is a "btl_setup.c" block pointing at your
-- own save's trainer block. Battle setup: +0x00 kind of battle (0 wild, 1 trainer, 2 Battle
-- Subway, 3 link, 4 catching demo), +0x24 / +0x28 your / the opposing party, +0x74 trainer block.
local function setupFrom(ps)
  if not heapBlock(ps, "procsys.c") then return nil end
  local d = memory.read_u32_le(ps + 0x10)
  if not heapBlock(d, "btl_setup.c") then return nil end
  if memory.read_u32_le(d + 0x74) ~= game.A.save + SAVE.trainerName - 4 then return nil end
  return d
end

-- other process systems, found by their heap tag a slice of memory per call (a full pass takes
-- about half a second, then again every 20 seconds), in case a version keeps them elsewhere
local procCands, procScan, procNextPass = {}, nil, 0
local function scanProcSlice()
  if not procScan then
    if emu.framecount() < procNextPass then return end
    procScan = 0x02200000
  end
  local SLICE = 0x8000
  local b = memory.read_bytes_as_array(procScan, SLICE + 16)
  for i = 1, SLICE, 4 do
    if b[i] == 0x70 and b[i + 1] == 0x72 and b[i + 4] == 0x73 and b[i + 7] == 0x2E then -- "pr..s..."
      local data = procScan + i - 1 + 0x18
      if data ~= game.A.procSys and not procCands[data] and heapBlock(data, "procsys.c") then procCands[data] = true end
    end
  end
  procScan = procScan + SLICE
  if procScan >= 0x02300000 then procScan, procNextPass = nil, emu.framecount() + 1200 end
end

local function battleSetup()
  local d = game.A.procSys and setupFrom(game.A.procSys)
  if d then return d end
  for ps in pairs(procCands) do
    d = setupFrom(ps)
    if d then return d end
    if not heapBlock(ps, "procsys.c") then procCands[ps] = nil end
  end
  scanProcSlice()
  return nil
end

function game.inBattle()
  if game.sequel then return battleSetup() ~= nil end
  return memory.read_u8(game.A.battleFlag) == 0x41
end

-- not a wild battle (a trainer, the Battle Subway, a link battle or a catching demonstration)
function game.trainerBattle()
  if game.sequel then
    local d = battleSetup()
    return d ~= nil and memory.read_u32_le(d) ~= 0
  end
  return memory.read_u16_le(game.A.trainerBattle) ~= 0
end

function game.party()
  local n = memory.read_u32_le(game.A.partyCount)
  if n > 6 then return nil end
  local out = {}
  for i = 0, n - 1 do
    out[#out + 1] = pkm.read(game.A.party + i * 220, true)
  end
  return out, n
end

-- the opposing party: count + party-format Pokémon
local function foeParty()
  if not game.sequel then return game.A.foeCount, game.A.foeParty end
  local d = battleSetup()
  local p = d and memory.read_u32_le(d + 0x28)
  if not p or not isRam(p) then return nil end
  return p + 4, p + 8
end

function game.foes()
  local countAt, at = foeParty()
  if not countAt then return {} end
  local n = memory.read_u32_le(countAt)
  if n < 1 or n > 6 then return {} end
  local out = {}
  for i = 0, n - 1 do
    local m = pkm.read(at + i * 220, true)
    if m then out[#out + 1] = m end
  end
  return out
end

-- any kind of Poké Ball in the bag (item ids 1-16, plus Park/Dream Ball)
local BALLS = { [500] = true, [576] = true }
for i = 1, 16 do BALLS[i] = true end
function game.hasPokeBalls()
  local b = memory.read_bytes_as_array(game.A.itemsPouch, 310 * 4)
  for i = 0, 309 do
    local item = b[i * 4 + 1] | (b[i * 4 + 2] << 8)
    local count = b[i * 4 + 3] | (b[i * 4 + 4] << 8)
    if item ~= 0 and BALLS[item] and count > 0 then return true end
  end
  return false
end

function game.trainerName()
  if not game.located then return "" end -- (no save data found yet)
  local s = {}
  for i = 0, 7 do
    local c = memory.read_u16_le(game.A.trainerName + i * 2)
    if c == 0xFFFF or c == 0 then break end
    s[#s + 1] = utf8.char(c)
  end
  return table.concat(s)
end

function game.badgeCount()
  local b = memory.read_u8(game.A.badges)
  local n = 0
  for i = 0, 7 do if (b >> i) & 1 == 1 then n = n + 1 end end
  return n
end

return game
