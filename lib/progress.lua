-- Nuzlocke progress: the areas with wild Pokémon in story order (which is next, which are still
-- open) and the level caps (the strongest Pokémon of the next gym leader / boss).
-- Everything except the story order is read from your own game, so randomized games work too.
local nds = require("nds")
local game = require("game")

local progress = {}

-- place ids (zone header byte 0x1A, the area keys of the run) in the order the story reaches them
local STORY_BW = {
  14, 15, 6, 32, 16, 53, 33, 17, 34, 35, 29, 72, 18, 65, 10, 36, 19, 54, 74, 37, 20, 56,
  38, 12, 39, 21, 57, 22, 23, 40, 73,
}
local AFTER_BW = { 24, 25, 67, 26, 61, 42, 71, 27, 70, 28, 68, 30, 31, 63, 59 }

-- Black 2 / White 2: Aspertia, Route 19 ... Victory Road (optional side areas like Twist Mountain
-- where they open up); the old Unova areas mostly open after the story
local STORY_B2W2 = {
  117, 124, 125, 130, 118, 131, 8, 129, 17, 34, 35, 29, 72, 18, 65, 136, 19, 37, 54, 74, 20,
  56, 38, 132, 133, 42, 71, 26, 25, 67, 24, 22, 119, 126, 127, 141, 61, 128, 134,
}
local AFTER_B2W2 = {
  12, 21, 57, 39, 14, 15, 16, 53, 32, 33, 6, 30, 31, 63, 27, 70, 28, 68, 40, 137, 147,
  149, 150, 151, 152,
}

-- the bosses in order: the cap after N badges is boss N+1 (trainer ids, checked against their class)
local BOSSES_BW = {
  { name = "Cilan, Chili & Cress", place = 6, trainers = { 11, 12, 13 }, classes = { 10, 11, 12 }, gym = true },
  { name = "Lenora", place = 7, trainers = { 21 }, classes = { 19 }, gym = true },
  { name = "Burgh", place = 8, trainers = { 22 }, classes = { 20 }, gym = true },
  { name = "Elesa", place = 9, trainers = { 23 }, classes = { 21 }, gym = true },
  { name = "Clay", place = 10, trainers = { 24 }, classes = { 22 }, gym = true },
  { name = "Skyla", place = 11, trainers = { 25 }, classes = { 23 }, gym = true },
  { name = "Brycen", place = 12, trainers = { 131 }, classes = { 54 }, gym = true },
  { name = { B = "Drayden", W = "Iris" }, place = 13, trainers = { 132, 133 }, classes = { 55, 56 }, gym = true },
  { name = "Elite Four", place = 44, trainers = { 228, 229, 230, 231 }, classes = { 78, 79, 80, 81 } },
  { name = "N", place = 45, trainers = { 586, 587 }, classes = { 101 } },
  { name = "Ghetsis", place = 45, trainers = { 232 }, classes = { 82 } },
}
local BOSSES_B2W2 = {
  { name = "Cheren", place = 117, trainers = { 156 }, classes = { 115 }, gym = true },
  { name = "Roxie", place = 118, trainers = { 157 }, classes = { 116 }, gym = true },
  { name = "Burgh", place = 8, trainers = { 154 }, classes = { 113 }, gym = true },
  { name = "Elesa", place = 9, trainers = { 153 }, classes = { 112 }, gym = true },
  { name = "Clay", place = 10, trainers = { 158 }, classes = { 117 }, gym = true },
  { name = "Skyla", place = 11, trainers = { 155 }, classes = { 114 }, gym = true },
  { name = "Drayden", place = 13, trainers = { 159 }, classes = { 118 }, gym = true },
  { name = "Marlon", place = 119, trainers = { 160 }, classes = { 119 }, gym = true },
  { name = "Ghetsis", place = 61, trainers = { 345 }, classes = { 189 } },
  { name = "Elite Four", place = 44, trainers = { 38, 39, 40, 41 }, classes = { 78, 79, 80, 81 } },
  { name = "Iris", place = 44, trainers = { 341 }, classes = { 193 } },
}
-- Platinum (place ids = the location name list): Route 201 ... Victory Road; side areas where
-- the story passes them
local STORY_PT = {
  16, 76, 17, 18, 59, 46, 22, 19, 57, 47, 20, 48, 26, 50, 21, 65, 23, 24, 53, 25, 30, 29, 67, 66,
  73, 28, 52, 27, 68, 33, 69, 77, 31, 32, 74, 78, 34, 35, 36, 37, 38, 54,
}
local AFTER_PT = { 61, 62, 70, 49, 64, 39, 40, 41, 42, 43, 44, 45, 84, 1, 5, 7, 9, 11, 13, 15, 83 }
local BOSSES_PT = {
  { name = "Roark", place = 8, trainers = { 246 }, classes = { 62 }, gym = true },
  { name = "Gardenia", place = 9, trainers = { 315 }, classes = { 74 }, gym = true },
  { name = "Fantina", place = 10, trainers = { 318 }, classes = { 77 }, gym = true },
  { name = "Maylene", place = 12, trainers = { 317 }, classes = { 76 }, gym = true },
  { name = "Crasher Wake", place = 11, trainers = { 316 }, classes = { 75 }, gym = true },
  { name = "Byron", place = 7, trainers = { 250 }, classes = { 64 }, gym = true },
  { name = "Candice", place = 14, trainers = { 319 }, classes = { 78 }, gym = true },
  { name = "Cyrus", place = 51, trainers = { 403, 404 }, classes = { 86 } },
  { name = "Volkner", place = 13, trainers = { 320 }, classes = { 79 }, gym = true },
  { name = "Elite Four", place = 15, trainers = { 261, 262, 263, 264 }, classes = { 65, 66, 67, 68 } },
  { name = "Cynthia", place = 15, trainers = { 267 }, classes = { 69 } },
}
-- HeartGold/SoulSilver: Route 29 ... Victory Road, then Kanto (any order: listed by route number)
local STORY_HGSS = {
  177, 178, 179, 220, 204, 180, 209, 210, 181, 211, 214, 182, 207, 183, 184, 185, 206, 186, 187,
  188, 189, 218, 195, 228, 234, 196, 202, 190, 216, 191, 135, 217, 192, 193, 194, 222, 175, 174,
  223, 221,
}
local AFTER_HGSS = {
  205, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166,
  167, 168, 169, 170, 172, 173, 176, 197, 198, 199, 200, 203, 224, 137, 219,
  126, 127, 128, 130, 132, 133, 136, 138, 139, 141, 143, 144, 145, 146,
}
local BOSSES_HGSS = {
  { name = "Falkner", place = 128, trainers = { 20 }, classes = { 66 }, gym = true },
  { name = "Bugsy", place = 129, trainers = { 21 }, classes = { 67 }, gym = true },
  { name = "Whitney", place = 131, trainers = { 30 }, classes = { 70 }, gym = true },
  { name = "Morty", place = 133, trainers = { 31 }, classes = { 72 }, gym = true },
  { name = "Chuck", place = 130, trainers = { 34 }, classes = { 75 }, gym = true },
  { name = "Jasmine", place = 132, trainers = { 33 }, classes = { 74 }, gym = true },
  { name = "Pryce", place = 134, trainers = { 32 }, classes = { 73 }, gym = true },
  { name = "Clair", place = 136, trainers = { 35 }, classes = { 76 }, gym = true },
  { name = "Elite Four", place = 147, trainers = { 245, 247, 418, 246 }, classes = { 87, 89, 112, 88 } },
  { name = "Lance", place = 147, trainers = { 244 }, classes = { 86 } },
  { name = "Lt. Surge", place = 143, trainers = { 255 }, classes = { 104 }, gym = true },
  { name = "Sabrina", place = 148, trainers = { 258 }, classes = { 107 }, gym = true },
  { name = "Misty", place = 141, trainers = { 254 }, classes = { 103 }, gym = true },
  { name = "Erika", place = 144, trainers = { 256 }, classes = { 105 }, gym = true },
  { name = "Janine", place = 145, trainers = { 257 }, classes = { 106 }, gym = true },
  { name = "Brock", place = 140, trainers = { 253 }, classes = { 98 }, gym = true },
  { name = "Blaine", place = 203, trainers = { 259 }, classes = { 108 }, gym = true },
  { name = "Blue", place = 139, trainers = { 261 }, classes = { 110 }, gym = true },
  { name = "Red", place = 137, trainers = { 260 }, classes = { 109 } },
}

-- Diamond/Pearl: same places as Platinum; Maylene and Crasher Wake come before Fantina
local BOSSES_DP = {
  { name = "Roark", place = 8, trainers = { 246 }, classes = { 62 }, gym = true },
  { name = "Gardenia", place = 9, trainers = { 315 }, classes = { 74 }, gym = true },
  { name = "Maylene", place = 12, trainers = { 317 }, classes = { 76 }, gym = true },
  { name = "Crasher Wake", place = 11, trainers = { 316 }, classes = { 75 }, gym = true },
  { name = "Fantina", place = 10, trainers = { 318 }, classes = { 77 }, gym = true },
  { name = "Byron", place = 7, trainers = { 250 }, classes = { 64 }, gym = true },
  { name = "Candice", place = 14, trainers = { 319 }, classes = { 78 }, gym = true },
  { name = "Cyrus", place = 51, trainers = { 403, 404 }, classes = { 86 } },
  { name = "Volkner", place = 13, trainers = { 320 }, classes = { 79 }, gym = true },
  { name = "Elite Four", place = 15, trainers = { 261, 262, 263, 264 }, classes = { 65, 66, 67, 68 } },
  { name = "Cynthia", place = 15, trainers = { 267 }, classes = { 69 } },
}

local GEN4 = {
  Pt = { STORY_PT, AFTER_PT, BOSSES_PT },
  DP = { STORY_PT, AFTER_PT, BOSSES_DP },
  HGSS = { STORY_HGSS, AFTER_HGSS, BOSSES_HGSS },
}

local STORY, AFTER, BOSSES = STORY_BW, AFTER_BW, BOSSES_BW

local wild = {}   -- place id -> "land" | "water" (only surfing/fishing)
local caps = {}   -- boss index -> { name, where, lv }

local function trainerLevel(trd, trp, i)
  if i >= trd.count then return nil end
  local a, b = trd.range(i)
  if b - a < 20 then return nil end
  local flags, cls, cnt = nds.u8(a), nds.u8(a + 1), nds.u8(a + 3)
  local pa = trp.range(i)
  -- each Pokémon: 8 bytes in Gen 5 (6 in Gen 4, plus a ball-capsule word in Platinum/HGSS),
  -- then the held item and the moves when the trainer has them
  local R = game.rom
  local size = (R.trainerMonBase or 8) + (R.trainerMonExtra or 0)
    + ((flags & 2) ~= 0 and 2 or 0) + ((flags & 1) ~= 0 and 8 or 0)
  local lv = 0
  for k = 0, math.min(cnt, 6) - 1 do lv = math.max(lv, nds.u8(pa + k * size + 2)) end
  return lv, cls
end

function progress.init()
  if game.sequel then STORY, AFTER, BOSSES = STORY_B2W2, AFTER_B2W2, BOSSES_B2W2 end
  if game.gen == 4 then
    local t = GEN4[game.family4]
    if t then STORY, AFTER, BOSSES = t[1], t[2], t[3] else STORY, AFTER, BOSSES = {}, {}, {} end
    -- which places have wild Pokémon: every map header with an encounter table
    for _, zi in ipairs(game.zones()) do
      local kind = zi.encounters ~= 0xFFFF and game.wildKind(zi.encounters)
      if kind == "land" then wild[zi.loc] = "land" elseif kind and not wild[zi.loc] then wild[zi.loc] = "water" end
    end
  else
    -- which places have wild Pokémon, from the zone headers and their encounter tables
    local z = nds.narc("a/0/1/2")
    local enc = nds.narc(game.rom.encounters)
    local zs, ze = z.range(0)
    for i = 0, (ze - zs) // 48 - 1 do
      local a = zs + i * 48
      local loc, e = nds.u8(a + 0x1A), game.zoneEncounters(a)
      if e ~= 0xFFFF and e < enc.count then
        local fa = enc.range(e)
        local land = nds.u8(fa) + nds.u8(fa + 1) + nds.u8(fa + 2) > 0 -- grass/cave encounter rates
        if land then wild[loc] = "land" elseif not wild[loc] then wild[loc] = "water" end
      end
    end
  end
  -- level caps
  local trd, trp = nds.narc(game.rom.trainers), nds.narc(game.rom.trainerMons)
  for k, b in ipairs(BOSSES) do
    local want = {}
    for _, c in ipairs(b.classes) do want[c] = true end
    local lv = 0
    for _, t in ipairs(b.trainers) do
      local l, cls = trainerLevel(trd, trp, t)
      if l and want[cls] then lv = math.max(lv, l) end
    end
    if lv == 0 then -- not where expected: the first trainer of each of the boss's classes
      local found = {}
      for t = 0, trd.count - 1 do
        local l, cls = trainerLevel(trd, trp, t)
        if l and want[cls] and not found[cls] then found[cls] = true; lv = math.max(lv, l) end
      end
    end
    local name = type(b.name) == "table" and (b.name[game.version] or b.name.B) or b.name
    local where = b.gym and (game.locationName(b.place) .. " Gym") or game.locationName(b.place)
    caps[k] = { name = name, where = where, lv = lv > 0 and lv or nil, gym = b.gym }
  end
end

-- the first boss after your last gym (story bosses can come between gyms, e.g. Cyrus)
local function firstAfter(badges)
  local seen = 0
  for k, c in ipairs(caps) do
    if seen >= badges then return k end
    if c.gym then seen = seen + 1 end
  end
  return #caps
end

-- the next bosses for someone with this many badges (the first one is the level cap)
function progress.caps(badges)
  local out = {}
  local first = math.max(1, firstAfter(badges or 0))
  for k = first, math.min(first + 2, #caps) do
    if caps[k] and caps[k].lv then out[#out + 1] = caps[k] end
  end
  return out
end

function progress.levelCap(badges)
  local c = progress.caps(badges)[1]
  return c and c.lv or nil
end

-- the route list: { key, post = after the story, water = only surfing/fishing }, story order.
-- Areas someone has an encounter in that aren't on the list are added at the end.
function progress.areas(used)
  local list, seen = {}, {}
  for _, loc in ipairs(STORY) do
    if wild[loc] then list[#list + 1] = { key = tostring(loc), water = wild[loc] == "water" }; seen[tostring(loc)] = true end
  end
  for _, loc in ipairs(AFTER) do
    if wild[loc] then list[#list + 1] = { key = tostring(loc), water = wild[loc] == "water", post = true }; seen[tostring(loc)] = true end
  end
  local extra = {}
  for k in pairs(used or {}) do if k ~= "starter" and not seen[k] then extra[#extra + 1] = k end end
  table.sort(extra, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  for _, k in ipairs(extra) do list[#list + 1] = { key = k, post = true } end
  return list
end

-- your next new area (the first open one after the furthest area you've had an encounter in)
-- and the open ones you passed. mine = your encounters (areaKey -> entry)
function progress.next(list, mine)
  local furthest = 0
  for i, a in ipairs(list) do if mine[a.key] then furthest = i end end
  local nextKey, behind = nil, {}
  for i, a in ipairs(list) do
    if not mine[a.key] and not a.water then
      if i < furthest then behind[#behind + 1] = a.key
      elseif not nextKey then nextKey = a.key end
    end
  end
  return nextKey, behind
end

return progress
