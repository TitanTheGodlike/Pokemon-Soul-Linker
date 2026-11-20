-- Other players as real in-game characters.
-- The overworld draws every character as a "billboard" sprite from a table the game keeps in RAM
-- (the game's own billboard.c system). Each remote player gets a free billboard entry and a shadow
-- entry; the game then draws them like any NPC: with its lighting, fog, depth sorting, grass and
-- buildings in front. Player sprite sheets that aren't loaded in this game (e.g. the girl when you
-- play the boy) are uploaded from your own ROM into unused texture memory.
local nds = require("nds")

local actors = {}
local D = "ARM9 System Bus" -- always pass the domain: implicit-domain writes to VRAM get dropped

local function u8(a) return memory.read_u8(a, D) end
local function u16(a) return memory.read_u16_le(a, D) end
local function u32(a) return memory.read_u32_le(a, D) end
local function s32(a) return memory.read_s32_le(a, D) end
local function w8(a, v) memory.write_u8(a, v, D) end
local function w16(a, v) memory.write_u16_le(a, v, D) end
local function w32(a, v) memory.write_u32_le(a, v & 0xFFFFFFFF, D) end

local ACT_SIZE, RES_SIZE = 0x1C, 0x28
local FREE = 0x3FFF
-- markers on everything we create, so leftovers (savestates, crashes) can be cleaned up
local SCALE_MARK = 1                  -- added to the scale word of our billboards (0x2000 -> 0x2001)
local TAG = { 0x62, 0x69, 0x6C, 0x6C, 0x62, 0x6F, 0x61, 0x72, 0x64, 0x2E, 0x63 } -- "billboard.c"

local systemAlive    -- defined below; used before its definition by name
local sys = nil      -- { char = {act, nAct, res, nRes}, shadow = {...} }
local mine = {}      -- id -> { act = addr, sh = addr, res = idx, sheet = name }
local sheets = {}    -- sheet name -> { res = idx, tex = addr, pal = addr, check = {..} } (our uploads)
local uploads = {}   -- sheet name -> upload in progress { tex, pal, size, next }
local continueUpload -- defined below
local romSheets = {} -- sheet name -> { tex = bytes, pal = bytes, frames = n }
actors.status = "starting"

------------------------------------------------------------------ finding the billboard systems
local function isRam(p) return p >= 0x02000000 and p < 0x02400000 end

-- Look for the game's "billboard.c" heap tags. Scanning all 2 MB at once took ~130 ms (a visible
-- hitch with crackling audio), so the scan runs in small slices, one per frame (~0.5 ms each).
local SCAN_FROM, SCAN_TO, SCAN_SLICE = 0x02200000, 0x02400000, 0x8000
local function scanSlice(base, found)
  local b = memory.read_bytes_as_array(base, SCAN_SLICE + 16, D)
  for i = 1, SCAN_SLICE, 4 do -- heap tags are 4-byte aligned
    if b[i] == 0x62 and b[i + 1] == 0x69 and b[i + 4] == 0x62 and b[i + 9] == 0x2E then
      local ok = true
      for k = 1, #TAG do if b[i + k - 1] ~= TAG[k] then ok = false; break end end
      if ok then
        local data = base + i - 1 + 0xC
        local resP, actP = u32(data + 0x10), u32(data + 0x14)
        if isRam(resP) and isRam(actP) and resP < actP then
          found[#found + 1] = { act = actP, res = resP + 4 }
        end
      end
    end
  end
end

local scan = nil -- { at = address, found = {} } while a sliced scan is running
-- advance a running scan by one slice; returns the result list when it finishes
local function scanStep()
  if not scan then scan = { at = SCAN_FROM, found = {} } end
  scanSlice(scan.at, scan.found)
  scan.at = scan.at + SCAN_SLICE
  if scan.at >= SCAN_TO then
    local r = scan.found
    scan = nil
    return r
  end
end

-- whole scan in one go (only for diagnostics)
local function scanForSystems()
  local found = {}
  for base = SCAN_FROM, SCAN_TO - 1, SCAN_SLICE do scanSlice(base, found) end
  return found
end

-- the entry holding the local player: the in-use entry closest to the player's world position
-- (within a tile and a half; the sprite runs a couple of frames ahead of the stored position)
local NEAR = 0x18000
-- characters sit a little below the player's height (-0x1954), shadows a little above (+0x1000);
-- compared with the player's own height, since the ground isn't at height 0 everywhere
-- (Aspertia City in Black 2 is at height 1)
local SHADOW_DY = 0x800
local function isShadowHeight(y, py) return y - py >= SHADOW_DY end
local function findPlayerEntry(s, px, py, pz, shadow, exclude)
  local best, bestD
  for k = 0, s.nAct - 1 do
    local a = s.act + k * ACT_SIZE
    -- skip our own billboards (scale marker), so a buddy standing on you isn't taken for you
    if u16(a) ~= FREE and not (exclude and exclude[a]) and (u32(a + 0x14) & 0xF) ~= SCALE_MARK then
      local dx, dz = math.abs(s32(a + 4) - px), math.abs(s32(a + 12) - pz)
      if dx < NEAR and dz < NEAR then
        if isShadowHeight(s32(a + 8), py) == (shadow == true) then
          if not bestD or dx + dz < bestD then best, bestD = a, dx + dz end
        end
      end
    end
  end
  return best
end

-- The game's heap marks each block "UD" (0x5544) while in use and "FR" when freed. The billboard
-- tables are freed and their memory reused when the game switches scenes (e.g. the starter gift
-- box), so never touch them unless their blocks are still marked in use.
local function blockInUse(p) return u16(p - 0x2C) == 0x5544 end
function systemAlive(s)
  return s ~= nil and isRam(s.act) and isRam(s.res) and blockInUse(s.act) and blockInUse(s.res - 4)
end

-- table sizes from the current heap headers (never cached: the memory gets reused by other
-- scenes), capped to the sizes the overworld uses
local function measure(s)
  local actAlloc, resAlloc = u32(s.act - 0x28), u32(s.res - 4 - 0x28)
  if actAlloc <= 0x1C or actAlloc > 0x4000 or resAlloc <= 0x28 or resAlloc > 0x4000 then return false end
  s.nAct = math.min(128, (actAlloc - 0x1C) // ACT_SIZE)
  s.nRes = math.min(64, (resAlloc - 0x20) // RES_SIZE)
  -- the texture table must end before the character table starts
  if s.res + s.nRes * RES_SIZE > s.act and s.res < s.act then
    s.nRes = (s.act - s.res) // RES_SIZE
  end
  return true
end

-- the local player's own billboard: right on the player, using a game-loaded 32 px wide sheet
local function looksLikePlayer(s, a, px, pz)
  if math.abs(s32(a + 4) - px) >= 0x4000 or math.abs(s32(a + 12) - pz) >= 0x4000 then return false end
  local r = u16(a) & 0x3FFF
  if r >= s.nRes then return false end
  local e = s.res + r * RES_SIZE
  return u32(e + 0x10) == 3 and (u32(e) & 0xFFFF) == 0x20 and u32(e + 0x1C) ~= 0
end

local lastCandidates = nil
local function discover(me)
  local px, pz = math.floor(me.x * 65536 + 0.5), math.floor(me.z * 65536 + 0.5)
  local py = math.floor(me.y * 65536 + 0.5)
  local function try(cands)
    local s = { }
    for _, c in ipairs(cands) do
      if not systemAlive(c) or not measure(c) then goto continue end
      if not s.char then
        local a = findPlayerEntry(c, px, py, pz, false)
        if a and looksLikePlayer(c, a, px, pz) then s.char = c; s.playerAct = a end
      end
      if not s.shadow then
        local a = findPlayerEntry(c, px, py, pz, true)
        if a then s.shadow = c; s.playerShadow = a end
      end
      ::continue::
    end
    return s.char and s
  end
  -- the systems usually come back at the same addresses after a map change: retry those twice
  -- a second; otherwise keep a sliced memory scan going, one slice per frame
  local s = nil
  if lastCandidates and actors.frame % 30 == 0 then s = try(lastCandidates) end
  if not s and (not lastCandidates or scan or actors.frame % 600 == 0) then
    local result = scanStep()
    if result then
      lastCandidates = result
      s = try(lastCandidates)
    end
  end
  if not s then return nil end
  -- clean up anything a previous session left behind (e.g. loaded from a savestate)
  for _, sysx in ipairs({ s.char, s.shadow }) do
    if sysx then
      for k = 0, sysx.nAct - 1 do
        local a = sysx.act + k * ACT_SIZE
        if u16(a) ~= FREE and (u32(a + 0x14) & 0xF) == SCALE_MARK then w16(a, FREE) end
      end
    end
  end
  -- our texture entries are the in-use ones without video-memory keys (the game's always have keys)
  for k = 0, s.char.nRes - 1 do
    local e = s.char.res + k * RES_SIZE
    if u32(e + 0x10) == 3 and u32(e + 0x1C) == 0 and u32(e + 0x20) == 0 then
      for i = 0, RES_SIZE - 4, 4 do w32(e + i, 0) end
      w32(e + 0x10, 5)
    end
  end
  s.yOff = s32(s.playerAct + 8) - py
  if math.abs(s.yOff) >= 0x8000 then s.yOff = -0x1954 end -- implausible: use the usual offset
  if s.playerShadow then s.shYOff = s32(s.playerShadow + 8) - py end
  return s
end

local claimedNow = {}
local function stillValid(me)
  if not sys then return false end
  if not systemAlive(sys.char) or (sys.shadow and not systemAlive(sys.shadow))
     or not measure(sys.char) or (sys.shadow and not measure(sys.shadow)) then
    sys = nil
    return false
  end
  local px, pz = math.floor(me.x * 65536 + 0.5), math.floor(me.z * 65536 + 0.5)
  local py = math.floor(me.y * 65536 + 0.5)
  local function ok(a, shadow)
    if not a or u16(a) == FREE then return false end
    if math.abs(s32(a + 4) - px) >= NEAR or math.abs(s32(a + 12) - pz) >= NEAR then return false end
    return isShadowHeight(s32(a + 8), py) == shadow
  end
  if not ok(sys.playerAct, false) then
    local a = findPlayerEntry(sys.char, px, py, pz, false, claimedNow)
    if not a then return false end
    sys.playerAct = a
  end
  if sys.shadow and not ok(sys.playerShadow, true) then
    sys.playerShadow = findPlayerEntry(sys.shadow, px, py, pz, true, claimedNow)
  end
  return true
end

------------------------------------------------------------------ texture memory
local BANK_REG = { 0x04000240, 0x04000241, 0x04000242, 0x04000243 }
local LCDC = { 0x06800000, 0x06820000, 0x06840000, 0x06860000 }
local PAL_BANKS = { -- E, F, G: register, lcdc address, size
  { reg = 0x04000244, lcdc = 0x06880000, size = 0x10000 },
  { reg = 0x04000245, lcdc = 0x06890000, size = 0x4000 },
  { reg = 0x04000246, lcdc = 0x06894000, size = 0x4000 },
}

local function withLcdc(reg, fn)
  local old = u8(reg)
  w8(reg, 0x80)
  local ok, r = pcall(fn)
  w8(reg, old)
  if not ok then error(r) end
  return r
end

-- texture slot address -> bank index (1..4) and offset, from the live VRAMCNT settings
local function texBank(addr)
  local slot, off = addr // 0x20000, addr % 0x20000
  for i = 1, 4 do
    local c = u8(BANK_REG[i])
    if c & 0x80 ~= 0 and c & 7 == 3 and (c >> 3) & 3 == slot then return i, off end
  end
end

-- palette address -> bank (E/F/G) and offset (G/F: slots 0,1,4,5 by OFS; E covers slots 0-3)
local function palBank(addr)
  for _, b in ipairs(PAL_BANKS) do
    local c = u8(b.reg)
    if c & 0x80 ~= 0 and c & 7 == 3 then
      local base
      if b.size == 0x10000 then base = 0 else
        local ofs = (c >> 3) & 3
        base = ((ofs & 1) + (ofs & 2) * 2) * 0x4000
      end
      if addr >= base and addr < base + b.size then return b, addr - base end
    end
  end
end

local function usedRanges()
  local used = {}
  local s = sys.char
  for k = 0, s.nRes - 1 do
    local e = s.res + k * RES_SIZE
    if u32(e + 0x10) == 3 then
      local key = u32(e + 0x1C)
      used[#used + 1] = { tex = u32(e + 0x08), size = ((key >> 16) & 0x7FFF) << 4, pal = u32(e + 0x0C) }
    end
  end
  return used
end

local function allZero(bytes)
  for i = 1, #bytes do if bytes[i] ~= 0 then return false end end
  return true
end

local romSheet -- defined below
local SHEET_NAMES = { "boy", "girl", "boy_bike", "girl_bike" }

-- a block counts as ours if it holds one of the player sheets (left from an earlier upload)
-- does video memory at lcdcAddr hold this whole sheet? Compares 8 spots spread over the sheet
-- (the game sometimes reuses part of a block, so one spot isn't enough)
local function sheetIntact(lcdcAddr, name)
  local rs = romSheet(name)
  local size = #rs.tex
  for k = 0, 7 do
    local off = math.floor(size * k / 8) + 0x100
    if off + 16 > size then off = size - 16 end
    local probe = memory.read_bytes_as_array(lcdcAddr + off, 16, D)
    for i = 1, 16 do if probe[i] ~= rs.tex[off + i] then return false end end
  end
  return true
end

local function holdsOurSheet(lcdcAddr)
  for _, name in ipairs(SHEET_NAMES) do
    if sheetIntact(lcdcAddr, name) then return name end
  end
end

local function findFreeTexture(size, taken)
  local used = usedRanges()
  for slot = 0, 3 do
    for off = 0x20000 - size, 0, -0x2000 do -- from the end of each slot backwards
      local addr = slot * 0x20000 + off
      local clash = false
      for _, u in ipairs(used) do
        if addr < u.tex + u.size and u.tex < addr + size then clash = true; break end
      end
      for _, t in ipairs(taken) do
        if addr < t.tex + t.size and t.tex < addr + size then clash = true; break end
      end
      if not clash then
        local bank, boff = texBank(addr)
        if bank then
          local free = withLcdc(BANK_REG[bank], function()
            local base = LCDC[bank] + boff
            if holdsOurSheet(base) ~= nil then return true end
            -- quick look at 32 spots first; only read the whole block if they're all empty
            for k = 0, size - 4, size // 32 do
              if u32(base + k) ~= 0 then return false end
            end
            return allZero(memory.read_bytes_as_array(base, size, D))
          end)
          if free then return addr end
        end
      end
    end
  end
end

local function findFreePalette(taken)
  local used = usedRanges()
  for addr = 0x3FE0, 0x1000, -0x20 do
    local clash = false
    for _, u in ipairs(used) do if u.pal == addr then clash = true; break end end
    for _, t in ipairs(taken) do if t.pal == addr then clash = true; break end end
    if not clash then
      local b, off = palBank(addr)
      if b then
        local zero = withLcdc(b.reg, function() return allZero(memory.read_bytes_as_array(b.lcdc + off, 32, D)) end)
        if zero then return addr end
      end
    end
  end
end

------------------------------------------------------------------ player sprite sheets from the ROM
function romSheet(name)
  if romSheets[name] then return romSheets[name] end
  local R = require("game").rom -- which archive / files hold the player sheets in this game
  local ow = nds.narc(R.overworld)
  local base = ow.range(R.sheets[name])
  local t = base + nds.u32(base + 0x10)
  local texInfo = t + nds.u16(t + 0x0E)
  local frames = nds.u8(texInfo + 1)
  local texData = t + nds.u32(t + 0x14)
  local palData = t + nds.u32(t + 0x38)
  local s = { frames = frames, tex = nds.bytes(texData, frames * 0x200), pal = nds.bytes(palData, 32) }
  romSheets[name] = s
  return s
end

-- is our uploaded sheet still complete in video memory?
local function sheetStillThere(sh, name)
  local bank, off = texBank(sh.tex)
  if not bank then return false end
  return withLcdc(BANK_REG[bank], function() return sheetIntact(LCDC[bank] + off, name) end)
end

local function sameBytes(a, b)
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- make sure our uploaded sheet is still in texture memory and registered; (re)upload if not
local function ensureSheet(name, templateRes)
  local sh = sheets[name]
  local s = sys.char
  if sh then
    local e = s.res + sh.res * RES_SIZE
    if u32(e + 0x08) == sh.tex and u32(e + 0x0C) == sh.pal then
      -- reading video memory means switching a bank, so only re-check the pixels once a second
      if actors.frame - (sh.checkedAt or 0) < 60 then return sh.res end
      sh.checkedAt = actors.frame
      if sheetStillThere(sh, name) then return sh.res end
    end
    -- lost (map reload or the game reused the memory): upload again somewhere free
    sheets[name] = nil
  end
  -- an upload already under way: continue it (a few KB per frame keeps the game smooth)
  local up = uploads[name]
  if up then return continueUpload(name, up, templateRes) end
  -- a registered texture that already holds this sheet (e.g. from a savestate made while
  -- Soul Link was running): just reuse it
  do
    local rs = romSheet(name)
    local dims = ((rs.frames * 32) << 16) | 0x20
    for k = 0, s.nRes - 1 do
      local e = s.res + k * RES_SIZE
      if u32(e + 0x10) == 3 and u32(e) == dims then
        local cand = { res = k, tex = u32(e + 0x08), pal = u32(e + 0x0C), size = rs.frames * 0x200 }
        if cand.tex ~= u32(s.res + templateRes * RES_SIZE + 0x08) and sheetStillThere(cand, name) then
          cand.checkedAt = actors.frame
          sheets[name] = cand
          return k
        end
      end
    end
  end
  -- after a failed attempt, wait a few seconds before scanning texture memory again
  if actors.uploadFailedAt and actors.frame - actors.uploadFailedAt < 300 then return nil end
  local rs = romSheet(name)
  local size = rs.frames * 0x200
  local taken = {}
  for _, o in pairs(sheets) do taken[#taken + 1] = { tex = o.tex, size = o.size, pal = o.pal } end
  for _, o in pairs(uploads) do taken[#taken + 1] = { tex = o.tex, size = o.size, pal = o.pal } end
  local tex = findFreeTexture(size, taken)
  local pal = findFreePalette(taken)
  if not tex or not pal then
    -- last resort: a registered player-sized sheet that isn't your own player's texture can only
    -- be a Soul Link leftover (e.g. an old savestate); take its place
    local dims = ((rs.frames * 32) << 16) | 0x20
    local playerTex = u32(s.res + templateRes * RES_SIZE + 0x08)
    for k = 0, s.nRes - 1 do
      local e = s.res + k * RES_SIZE
      if u32(e + 0x10) == 3 and u32(e) == dims and u32(e + 0x08) ~= playerTex then
        for j = 0, s.nAct - 1 do -- leftover billboards still showing it
          local a = s.act + j * ACT_SIZE
          if (u16(a) & 0x3FFF) == k and not claimedNow[a] then w16(a, FREE) end
        end
        tex, pal = u32(e + 0x08), u32(e + 0x0C)
        for i = 0, RES_SIZE - 4, 4 do w32(e + i, 0) end
        w32(e + 0x10, 5)
        break
      end
    end
  end
  if not tex or not pal then
    actors.status = "no free texture memory for " .. name
    actors.uploadFailedAt = actors.frame
    return nil
  end
  actors.uploadFailedAt = nil
  up = { tex = tex, pal = pal, size = size, next = 0 }
  -- after a map change the sheet is usually still sitting in video memory: no need to upload
  local bank, boff = texBank(tex)
  if withLcdc(BANK_REG[bank], function() return holdsOurSheet(LCDC[bank] + boff) end) == name then
    up.next = #rs.tex
  end
  uploads[name] = up
  return continueUpload(name, up, templateRes)
end

-- upload the next 4 KB of a sheet; once it's all there, write the palette and register it
function continueUpload(name, up, templateRes)
  local s = sys.char
  local rs = romSheet(name)
  local t = rs.tex
  if up.next < #t then
    local bank, boff = texBank(up.tex)
    if not bank then uploads[name] = nil; return nil end
    -- VRAM ignores 8-bit writes (like real hardware), so write whole words
    withLcdc(BANK_REG[bank], function()
      local dst = LCDC[bank] + boff
      local last = math.min(#t, up.next + 0x1000)
      for i = up.next, last - 4, 4 do
        w32(dst + i, t[i + 1] | (t[i + 2] << 8) | (t[i + 3] << 16) | (t[i + 4] << 24))
      end
      up.next = last
    end)
    if up.next < #t then return nil end
  end
  uploads[name] = nil
  local resIdx
  for k = s.nRes - 1, 0, -1 do -- free resource entries from the end, away from the game's own
    if u32(s.res + k * RES_SIZE + 0x10) ~= 3 then resIdx = k; break end
  end
  if not resIdx then actors.status = "no free texture slot"; return nil end
  local pb, poff = palBank(up.pal)
  withLcdc(pb.reg, function()
    local p = rs.pal
    for i = 0, 30, 2 do w16(pb.lcdc + poff + i, p[i + 1] | (p[i + 2] << 8)) end
  end)
  -- resource entry: the player's own entry as a template, pointed at our memory
  local src, dst = s.res + templateRes * RES_SIZE, s.res + resIdx * RES_SIZE
  for i = 0, RES_SIZE - 4, 4 do w32(dst + i, u32(src + i)) end
  w32(dst + 0x00, ((rs.frames * 32) << 16) | 0x20)                -- 32 px wide, frames*32 tall
  w32(dst + 0x04, (u32(src + 0x04) & 0x00FFFFFF) | (rs.frames << 24))
  w32(dst + 0x08, up.tex)
  w32(dst + 0x0C, up.pal)
  w32(dst + 0x10, 3)                         -- 16-colour texture
  w32(dst + 0x14, 2)                         -- 32 px wide
  w32(dst + 0x18, rs.frames > 16 and 7 or 6) -- 1024 / 512 px tall
  -- +0x1C / +0x20 are the game's video-memory allocation keys, handed back to its memory
  -- manager when a scene ends. Ours were never allocated there, so leave them empty;
  -- drawing only uses the plain addresses at +0x08 / +0x0C.
  w32(dst + 0x1C, 0)
  w32(dst + 0x20, 0)
  -- +0x24 must stay 0: the game frees whatever it points to when a scene ends
  -- (writing a marker there corrupted the heap and hung the game at the starter gift box)
  w32(dst + 0x24, 0)
  local sh = { res = resIdx, tex = up.tex, pal = up.pal, size = up.size, checkedAt = actors.frame }
  sheets[name] = sh
  return resIdx
end

------------------------------------------------------------------ per-player billboards
local function freeEntry(s, avoid)
  for k = s.nAct - 1, 0, -1 do -- from the end so the game's own allocations stay in front
    local a = s.act + k * ACT_SIZE
    if u16(a) == FREE and not avoid[a] then return a end -- exactly 0x3FFF (0xFFFF = hidden, in use)
  end
end

local function release(id)
  local m = mine[id]
  if not m then return end
  if sys then
    if m.act and (u16(m.act) & 0x3FFF) == m.res then w16(m.act, FREE) end
    if m.sh and (u16(m.sh) & 0x3FFF) ~= FREE and m.shRes and (u16(m.sh) & 0x3FFF) == m.shRes then w16(m.sh, FREE) end
  end
  mine[id] = nil
end

function actors.reset()
  for id in pairs(mine) do mine[id] = nil end
  sys = nil
end

-- which sheet the local player's billboard currently uses (to share it when it matches)
local function myRes() return u16(sys.playerAct) & 0x3FFF end

-- items: list of { id, x, y, z, frame, sheet, hidden }
function actors.update(frame, me, items, mySheet)
  actors.frame = frame
  if not stillValid(me) then
    if sys or next(mine) or next(sheets) or next(uploads) then
      -- entries from before a map change / scene switch are gone
      for id in pairs(mine) do mine[id] = nil end
      for k in pairs(sheets) do sheets[k] = nil end
      for k in pairs(uploads) do uploads[k] = nil end
    end
    sys = discover(me)
    if not sys then actors.status = "billboards not found"; return false end
  end
  -- height of the sprite relative to the player's position; measured live because it isn't
  -- settled right after a map change (and differs indoors)
  do
    local py = math.floor(me.y * 65536 + 0.5)
    local off = s32(sys.playerAct + 8) - py
    if math.abs(off) < 0x8000 then sys.yOff = off end
    if sys.playerShadow then
      local so = s32(sys.playerShadow + 8) - py
      if so > 0 and so < 0x20000 then sys.shYOff = so end
    end
  end
  actors.status = "ok"
  local s = sys.char
  local present = {}
  local claimed = {}
  for _, m in pairs(mine) do claimed[m.act] = true; if m.sh then claimed[m.sh] = true end end
  claimedNow = claimed

  for _, it in ipairs(items) do
    present[it.id] = true
    local res
    if it.sheet == mySheet then res = myRes() else res = ensureSheet(it.sheet, myRes()) end
    local m = mine[it.id]
    -- our entry must still hold our resource; the game clears everything on map loads
    if m and (u16(m.act) & 0x3FFF) ~= m.res then mine[it.id] = nil; m = nil end
    if res then
      if not m then
        local a = freeEntry(s, claimed)
        if a then
          for i = 0, ACT_SIZE - 4, 4 do w32(a + i, u32(sys.playerAct + i)) end
          w32(a + 0x14, (u32(sys.playerAct + 0x14) & ~0xF) | SCALE_MARK)
          m = { act = a, res = res }
          claimed[a] = true
          if sys.shadow and sys.playerShadow then
            local sh = freeEntry(sys.shadow, claimed)
            if sh then
              for i = 0, ACT_SIZE - 4, 4 do w32(sh + i, u32(sys.playerShadow + i)) end
              w32(sh + 0x14, (u32(sys.playerShadow + 0x14) & ~0xF) | SCALE_MARK)
              m.sh, m.shRes = sh, u16(sh) & 0x3FFF
              claimed[sh] = true
            end
          end
          mine[it.id] = m
        end
      end
      if m then
        m.res = res
        local hideY = it.hidden and -0x4000000 or 0
        local x = math.floor(it.x * 65536 + 0.5)
        local z = math.floor(it.z * 65536 + 0.5)
        local y = math.floor(it.y * 65536 + 0.5)
        w16(m.act, res)
        w32(m.act + 4, x); w32(m.act + 8, y + sys.yOff + hideY); w32(m.act + 12, z)
        w32(m.act + 16, (u32(sys.playerAct + 16) & 0xFFFFFF00) | (it.frame & 0xFF))
        -- the drawing flags follow your own character every frame: the game switches yours off
        -- while a door/warp plays, and a copy made at that moment stayed invisible for good
        w32(m.act + 0x14, (u32(sys.playerAct + 0x14) & ~0xF) | SCALE_MARK)
        w32(m.act + 0x18, u32(sys.playerAct + 0x18))
        if m.sh then
          w32(m.sh + 4, x); w32(m.sh + 8, y + (sys.shYOff or 0x1000) + hideY); w32(m.sh + 12, z)
          if sys.playerShadow and u16(sys.playerShadow) ~= FREE then
            w32(m.sh + 0x14, (u32(sys.playerShadow + 0x14) & ~0xF) | SCALE_MARK)
            w32(m.sh + 0x18, u32(sys.playerShadow + 0x18))
          end
        end
      end
    end
  end
  for id in pairs(mine) do if not present[id] then release(id) end end
  return true
end

function actors.diag(me)
  local px, pz = math.floor(me.x * 65536 + 0.5), math.floor(me.z * 65536 + 0.5)
  local py = math.floor(me.y * 65536 + 0.5)
  local out = {}
  for _, c in ipairs(scanForSystems()) do
    local alive = systemAlive(c)
    local ok = alive and measure(c)
    local line = string.format("act %08X res %08X alive=%s measured=%s", c.act, c.res, tostring(alive), tostring(ok))
    if ok then
      line = line .. string.format(" nAct=%d nRes=%d", c.nAct, c.nRes)
      local a = findPlayerEntry(c, px, py, pz, false)
      if a then
        local r = u16(a) & 0x3FFF
        local e = c.res + r * RES_SIZE
        line = line .. string.format(" near=%08X dx=%X dz=%X res=%X fmt=%d w=%X key=%08X like=%s", a,
          math.abs(s32(a + 4) - px), math.abs(s32(a + 12) - pz), r, u32(e + 0x10), u32(e) & 0xFFFF,
          u32(e + 0x1C), tostring(looksLikePlayer(c, a, px, pz)))
      end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

function actors.debug()
  local out = { "status " .. actors.status }
  if sys then
    out[#out + 1] = string.format("char act %08X res %08X playerAct %08X yOff %d", sys.char.act, sys.char.res, sys.playerAct, sys.yOff)
  end
  for name, sh in pairs(sheets) do
    out[#out + 1] = string.format("sheet %s res %X tex %X pal %X", name, sh.res, sh.tex, sh.pal)
    if sys then
      local e = sys.char.res + sh.res * RES_SIZE
      local t = {}
      for i = 0, RES_SIZE - 4, 4 do t[#t + 1] = string.format("%08X", u32(e + i)) end
      out[#out + 1] = "  entry " .. table.concat(t, " ")
      out[#out + 1] = "  sheet complete in video memory: " .. tostring(sheetStillThere(sh, name))
    end
  end
  for id, m in pairs(mine) do
    local t = {}
    for i = 0, ACT_SIZE - 4, 4 do t[#t + 1] = string.format("%08X", u32(m.act + i)) end
    out[#out + 1] = string.format("actor %s @%08X: %s", id, m.act, table.concat(t, " "))
  end
  return table.concat(out, "\n")
end

function actors.clearAll()
  for id in pairs(mine) do release(id) end
end

return actors
