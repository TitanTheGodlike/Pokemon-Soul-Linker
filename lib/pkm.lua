-- Gen 5 Pokémon data (party format, 220 bytes): decrypt + pick out the fields Soul Link needs.
local pkm = {}

-- For each shuffle value, which stored block position holds logical block A, B, C, D.
local BLOCK_POS = {
  0,1,2,3, 0,1,3,2, 0,2,1,3, 0,3,1,2, 0,2,3,1, 0,3,2,1,
  1,0,2,3, 1,0,3,2, 2,0,1,3, 3,0,1,2, 2,0,3,1, 3,0,2,1,
  1,2,0,3, 1,3,0,2, 2,1,0,3, 3,1,0,2, 2,3,0,1, 3,2,0,1,
  1,2,3,0, 1,3,2,0, 2,1,3,0, 3,1,2,0, 2,3,1,0, 3,2,1,0,
}

local function crypt(words, from, to, seed)
  for i = from, to do
    seed = (seed * 0x41C64E6D + 0x6073) & 0xFFFFFFFF
    words[i] = words[i] ~ ((seed >> 16) & 0xFFFF)
  end
end

local function str16(words, from, count)
  local s = {}
  for i = from, from + count - 1 do
    local c = words[i]
    if c == nil or c == 0xFFFF or c == 0 then break end
    if c < 0xD800 or c > 0xDFFF then s[#s + 1] = utf8.char(c) end
  end
  return table.concat(s)
end

-- Gen 4 nicknames use the games' own character codes (set by game.lua for those games)
pkm.decode = nil

-- addr: start of a party slot (220 bytes in Gen 5, 236 in Gen 4; or 136 for box format with party=false)
function pkm.read(addr, party)
  local gen4 = pkm.decode ~= nil
  local size = party and (gen4 and 236 or 220) or 136
  local b = memory.read_bytes_as_array(addr, size)
  local pid = b[1] | (b[2] << 8) | (b[3] << 16) | (b[4] << 24)
  local checksum = b[7] | (b[8] << 8)
  if pid == 0 and checksum == 0 then return nil end
  -- words indexed by byte offset / 2
  local raw = {}
  for i = 0, size // 2 - 1 do raw[i] = b[i * 2 + 1] | (b[i * 2 + 2] << 8) end
  -- The game now and then works on a Pokémon decrypted in place (for a frame or so), so if the
  -- checksum doesn't match after decrypting, the data may already be plain: try that too.
  local w
  for _, decrypt in ipairs({ true, false }) do
    w = {}
    for i = 0, size // 2 - 1 do w[i] = raw[i] end
    if decrypt then
      crypt(w, 4, 67, checksum)                 -- 0x08..0x87
      if party then crypt(w, 68, size // 2 - 1, pid) end  -- battle stats: 0x88..0xDB (Gen 4: ..0xEB)
    end
    -- unshuffle into logical order
    local sv = ((pid >> 13) & 31) % 24
    local blk = {}
    for logical = 0, 3 do
      local stored = BLOCK_POS[sv * 4 + logical + 1]
      for k = 0, 15 do blk[4 + logical * 16 + k] = w[4 + stored * 16 + k] end
    end
    for i = 4, 67 do w[i] = blk[i] end
    -- verify checksum
    local sum = 0
    for i = 4, 67 do sum = (sum + w[i]) & 0xFFFF end
    if sum == checksum then break end
    if not decrypt then return nil end
  end
  local function byteAt(off)
    local v = w[off >> 1]
    return (off & 1 == 0) and (v & 0xFF) or (v >> 8)
  end
  local iv32 = w[0x38 >> 1] | (w[0x3A >> 1] << 16)
  local m = {
    pid = pid,
    species = w[0x08 >> 1],
    item = w[0x0A >> 1],
    tid = w[0x0C >> 1],
    sid = w[0x0E >> 1],
    ability = byteAt(0x15),
    isEgg = (iv32 >> 30) & 1 == 1,
    form = byteAt(0x40) >> 3,
    gender = (byteAt(0x40) >> 1) & 3, -- 0 male, 1 female, 2 genderless
    nature = byteAt(0x41),
    nickname = str16(w, 0x48 >> 1, 11),
    metLoc = w[0x80 >> 1],
    eggLoc = w[0x7E >> 1],
    ball = byteAt(0x83),
    metLevel = byteAt(0x84) & 0x7F,
  }
  if gen4 then
    local codes = {}
    for i = 0x48 >> 1, (0x48 >> 1) + 10 do codes[#codes + 1] = w[i] end
    m.nickname = pkm.decode(codes)
    m.nature = pid % 25
    m.metLoc = w[0x46 >> 1] ~= 0 and w[0x46 >> 1] or w[0x80 >> 1]
  end
  -- shiny: the trainer IDs and the personality value nearly cancel out
  m.shiny = ((m.tid ~ m.sid ~ (pid >> 16) ~ (pid & 0xFFFF)) & 0xFFFF) < 8
  m.female = m.gender == 1
  if party then
    m.status = byteAt(0x88)
    m.level = byteAt(0x8C)
    m.hp = w[0x8E >> 1]
    m.maxHp = w[0x90 >> 1]
  end
  return m
end

return pkm
