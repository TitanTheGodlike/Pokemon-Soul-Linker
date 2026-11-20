-- Other players as real in-game characters in Diamond/Pearl/Platinum/HeartGold/SoulSilver.
-- The Gen 4 overworld draws every character as a billboard from one list the game keeps in RAM
-- (a fixed array of 0xC4-byte entries chained through a sentinel). Each remote player gets a copy
-- of your own character's entry: same model and frame tables, its own position, facing and walk
-- frame. When the other player uses the other character (Dawn when you play Lucas), that sheet
-- is uploaded from your own ROM into unused texture memory and the copy points at it.
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
local function isRam(p) return p >= 0x02000000 and p < 0x02400000 end

-- entry layout (Platinum / HeartGold / SoulSilver); Diamond/Pearl's differ (game.layout.billboard)
local ENTRY = 0xC4
local E = { pos = 0x00, scale = 0x0C, shown = 0x24, set = 0x28, tex = 0x90, texKey = 0x94, palKey = 0x9C,
            seq = 0xB6, frame = 0xB8, next = 0xBC, prev = 0xC0 }
local layoutChecked = false
local function useLayout()
  if layoutChecked then return end
  layoutChecked = true
  local B = require("game").layout.billboard
  if B then
    ENTRY = B.size
    for k, v in pairs(B) do if k ~= "size" then E[k] = v end end
  end
end
local MARK = 0x1001 -- x scale of our entries (the game's are 0x1000): invisible, and finds leftovers

actors.status = "starting"
local sys = nil      -- { set, sentinel, base, count, player = entry, playerObj }
local mine = {}      -- id -> entry address
local sheets = {}    -- sheet name -> { tex, pal, size, checkedAt } (our uploads)
local uploads = {}   -- sheet name -> upload in progress
local romSheets = {}

------------------------------------------------------------------ the game's billboard list
local function readSet(entry)
  local set = u32(entry + E.set)
  if not isRam(set) then return nil end
  local base, count = u32(set + 4), u32(set + 8)
  if not isRam(base) or count < 8 or count > 256 then return nil end
  if entry < base or entry >= base + count * ENTRY or (entry - base) % ENTRY ~= 0 then return nil end
  return { set = set, sentinel = set + 0x0C, base = base, count = count }
end

local function linked(e)
  local n, p = u32(e + E.next), u32(e + E.prev)
  return isRam(n) and isRam(p) and u32(p + E.next) == e and u32(n + E.prev) == e
end

local function unlink(e)
  if linked(e) then
    local n, p = u32(e + E.next), u32(e + E.prev)
    w32(p + E.next, n); w32(n + E.prev, p)
  end
  for i = 0, ENTRY - 4, 4 do w32(e + i, 0) end
  w32(e + E.scale, 0x1000); w32(e + E.scale + 4, 0x1000); w32(e + E.scale + 8, 0x1000)
end

-- the player's own entry (through the player's map object) and the list it belongs to
local function discover()
  local game = require("game")
  local mo = game.playerObject()
  if not mo then return nil end
  local entry = u32(mo + game.layout.obj.billboard)
  if not isRam(entry) then return nil end
  -- the entry sits on the map object (x equal, z a little in front)
  if math.abs(s32(entry) - s32(mo + game.layout.obj.pos)) > 0x8000 then return nil end
  local s = readSet(entry)
  if not s or not linked(entry) then return nil end
  s.player, s.playerObj = entry, mo
  return s
end

local function stillValid()
  if not sys then return false end
  local s = discover()
  if not s or s.set ~= sys.set or s.base ~= sys.base then return false end
  sys.player, sys.playerObj = s.player, s.playerObj
  return true
end

-- leftovers from earlier sessions (savestates, crashes): ours carry the scale mark
local function cleanLeftovers(s)
  for k = 0, s.count - 1 do
    local e = s.base + k * ENTRY
    if u32(e + E.scale) == MARK and u32(e + E.set) == s.set then unlink(e) end
  end
end

local function freeEntry(s, avoid)
  for k = s.count - 1, 0, -1 do -- from the end, away from where the game allocates
    local e = s.base + k * ENTRY
    if u32(e + E.set) == 0 and not avoid[e] then return e end
  end
end

------------------------------------------------------------------ texture memory
local BANK_REG = { 0x04000240, 0x04000241, 0x04000242, 0x04000243 }
local LCDC = { 0x06800000, 0x06820000, 0x06840000, 0x06860000 }
local PAL_BANKS = {
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

local function texBank(addr)
  local slot, off = addr // 0x20000, addr % 0x20000
  for i = 1, 4 do
    local c = u8(BANK_REG[i])
    if c & 0x80 ~= 0 and c & 7 == 3 and (c >> 3) & 3 == slot then return i, off end
  end
end

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

local function texKeyAddr(k) return (k & 0xFFFF) << 3 end
local function texKeySize(k) return ((k >> 16) & 0x7FFF) << 4 end
local function palKeyAddr(k) return (k & 0xFFFF) << 3 end

-- video memory the game's characters use right now
local function usedRanges()
  local used = {}
  for k = 0, sys.count - 1 do
    local e = sys.base + k * ENTRY
    if u32(e + E.set) ~= 0 and u32(e + E.scale) ~= MARK then
      local tk, pk = u32(e + E.texKey), u32(e + E.palKey)
      used[#used + 1] = { tex = texKeyAddr(tk), size = texKeySize(tk), pal = palKeyAddr(pk) }
    end
  end
  return used
end

local function allZero(bytes)
  for i = 1, #bytes do if bytes[i] ~= 0 then return false end end
  return true
end

-- player sheet from the ROM: texture image (all frames) + palette
local function romSheet(name)
  if romSheets[name] then return romSheets[name] end
  local R = require("game").rom
  local ow = nds.narc(R.overworld)
  local base = ow.range(R.sheets[name])
  local t = base + nds.u32(base + 0x10)
  local size = nds.u16(t + 0x0C) << 3
  local texData = t + nds.u32(t + 0x14)
  local palData = t + nds.u32(t + 0x38)
  -- the frame layout (each texture's offset/size/format), to tell whether two sheets line up
  local texInfo = t + nds.u16(t + 0x0E)
  local cnt = nds.u8(texInfo + 1)
  local head = texInfo + nds.u16(texInfo + 6)
  local per = (nds.u16(head + 2) - 4) // math.max(1, cnt)
  local params = {}
  for k = 0, cnt - 1 do params[#params + 1] = string.format("%08X", nds.u32(head + 4 + k * per)) end
  local s = { tex = nds.bytes(texData, size), pal = nds.bytes(palData, 32), layout = table.concat(params) }
  romSheets[name] = s
  return s
end

-- The copies use your character's frame tables. Which of your sheets is showing (walking or
-- cycling; HeartGold/SoulSilver also switch sheets for running) is told by its texture size;
-- the other character's matching sheet is only used when its frames line up exactly, otherwise
-- the copy shares your sheet (better your character than scrambled frames).
local function sheetFor(want, mySheet, playerTexSize)
  local myGender = mySheet:match("^(%a+)") or "boy"
  local mine
  for _, kind in ipairs({ "", "_bike" }) do
    local ok, rs = pcall(romSheet, myGender .. kind)
    if ok and #rs.tex == playerTexSize then mine = { name = myGender .. kind, kind = kind, rs = rs } end
  end
  local gender = want:match("^(%a+)") or "boy"
  if not mine or gender == myGender then return nil end -- share yours
  local name = gender .. mine.kind
  local ok, rs = pcall(romSheet, name)
  if ok and rs.layout == mine.rs.layout then return name end
  return nil
end

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

local function sheetStillThere(sh, name)
  local bank, off = texBank(sh.tex)
  if not bank then return false end
  return withLcdc(BANK_REG[bank], function() return sheetIntact(LCDC[bank] + off, name) end)
end

local function findFreeTexture(size, name, taken)
  local used = usedRanges()
  for slot = 0, 3 do
    for off = 0x20000 - size, 0, -0x800 do -- from the end of each slot backwards
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
        if bank and boff + size <= 0x20000 then
          local free = withLcdc(BANK_REG[bank], function()
            local base = LCDC[bank] + boff
            if sheetIntact(base, name) then return "same" end
            for k = 0, size - 4, size // 32 do
              if u32(base + k) ~= 0 then return false end
            end
            return allZero(memory.read_bytes_as_array(base, size, D))
          end)
          if free then return addr, free == "same" end
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

local function continueUpload(name, up)
  local rs = romSheet(name)
  local t = rs.tex
  if up.next < #t then
    local bank, boff = texBank(up.tex)
    if not bank then uploads[name] = nil; return nil end
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
  local pb, poff = palBank(up.pal)
  if not pb then return nil end
  withLcdc(pb.reg, function()
    local p = rs.pal
    for i = 0, 30, 2 do w16(pb.lcdc + poff + i, p[i + 1] | (p[i + 2] << 8)) end
  end)
  local sh = { tex = up.tex, pal = up.pal, size = up.size, checkedAt = actors.frame }
  sheets[name] = sh
  return sh
end

-- our uploaded copy of a sheet (nil while uploading or when there's no room)
local function ensureSheet(name)
  local sh = sheets[name]
  if sh then
    if actors.frame - (sh.checkedAt or 0) < 60 then return sh end
    sh.checkedAt = actors.frame
    if sheetStillThere(sh, name) then return sh end
    sheets[name] = nil
  end
  local up = uploads[name]
  if up then return continueUpload(name, up) end
  if actors.uploadFailedAt and actors.frame - actors.uploadFailedAt < 300 then return nil end
  local rs = romSheet(name)
  local taken = {}
  for _, o in pairs(sheets) do taken[#taken + 1] = o end
  for _, o in pairs(uploads) do taken[#taken + 1] = o end
  local tex, already = findFreeTexture(#rs.tex, name, taken)
  local pal = findFreePalette(taken)
  if not tex or not pal then
    actors.status = "no free texture memory for " .. name
    actors.uploadFailedAt = actors.frame
    return nil
  end
  actors.uploadFailedAt = nil
  up = { tex = tex, pal = pal, size = #rs.tex, next = already and #rs.tex or 0 }
  uploads[name] = up
  return continueUpload(name, up)
end

------------------------------------------------------------------ per-player entries
local function release(id)
  local e = mine[id]
  if e and sys and u32(e + E.scale) == MARK then unlink(e) end
  mine[id] = nil
end

function actors.reset()
  for id in pairs(mine) do mine[id] = nil end
  sys = nil
end

-- walking pose: facing (Soul Link: 0 up, 1 left, 2 down, 3 right) -> the game's sequence
-- (0 up, 1 down, 2 left, 3 right); frame = sequence * 16 + phase, 8 phases per tile (standing
-- on the tile centre = phase 0 or 8)
local SEQ = { [0] = 0, [1] = 2, [2] = 1, [3] = 3 }
local function pose(it)
  local seq = SEQ[it.f or 2] or 1
  local t = (it.f == 1 or it.f == 3) and it.x or it.z
  local d = t - 0.5
  if it.f == 0 or it.f == 1 then d = -d end -- walking up / left counts down
  local phase = math.floor(d * 8 + 0.5) % 16
  return seq, seq * 0x10000 + phase * 0x1000
end

-- items: list of { id, x, y, z, f, sheet, hidden }
function actors.update(frame, me, items, mySheet)
  actors.frame = frame
  useLayout()
  if not stillValid() then
    if sys or next(mine) then
      for id in pairs(mine) do mine[id] = nil end
      for k in pairs(sheets) do sheets[k] = nil end
      for k in pairs(uploads) do uploads[k] = nil end
    end
    sys = discover()
    if not sys then actors.status = "billboards not found"; return false end
    cleanLeftovers(sys)
  end
  actors.status = "ok"
  local P, mo = sys.player, sys.playerObj
  local posOff = require("game").layout.obj.pos
  -- the entry's offset from the map object (the sprite sits a little in front of its tile)
  local dx = s32(P) - s32(mo + posOff)
  local dy = s32(P + 4) - s32(mo + posOff + 4)
  local dz = s32(P + 8) - s32(mo + posOff + 8)
  local claimed, present = {}, {}
  for _, e in pairs(mine) do claimed[e] = true end
  -- the copies use your character's frame tables, so they walk / cycle / run the way you do;
  -- only the character (boy / girl) is theirs
  local playerTexSize = texKeySize(u32(P + E.texKey))
  for _, it in ipairs(items) do
    present[it.id] = true
    local e = mine[it.id]
    if e and (u32(e + E.scale) ~= MARK or u32(e + E.set) ~= sys.set or not linked(e)) then mine[it.id] = nil; e = nil end
    local other = sheetFor(it.sheet, mySheet, playerTexSize)
    local sh = nil
    if other then sh = ensureSheet(other) end
    if not other or sh then
      if not e then
        e = freeEntry(sys, claimed)
        if e then
          for i = 0, E.next - 4, 4 do w32(e + i, u32(P + i)) end
          w32(e + E.scale, MARK)
          local last = u32(sys.sentinel + E.prev)
          w32(e + E.next, sys.sentinel); w32(e + E.prev, last)
          w32(last + E.next, e); w32(sys.sentinel + E.prev, e)
          mine[it.id], claimed[e] = e, true
        end
      end
      if e then
        local hideY = it.hidden and -0x4000000 or 0
        w32(e + E.pos, math.floor(it.x * 65536 + 0.5) + dx)
        w32(e + E.pos + 4, math.floor(it.y * 65536 + 0.5) + dy + hideY)
        w32(e + E.pos + 8, math.floor(it.z * 65536 + 0.5) + dz)
        -- shown / hidden follows your own character (the game hides it during some scenes)
        w32(e + E.shown, u32(P + E.shown))
        -- the sheet: your own (shared) or our upload
        w32(e + E.tex, u32(P + E.tex))
        if sh then
          local tk = u32(P + E.texKey)
          w32(e + E.texKey, (tk & 0xFFFF0000) | ((sh.tex >> 3) & 0xFFFF))
          local pk = u32(P + E.palKey)
          w32(e + E.palKey, (pk & 0xFFFF0000) | ((sh.pal >> 3) & 0xFFFF))
        else
          w32(e + E.texKey, u32(P + E.texKey))
          w32(e + E.palKey, u32(P + E.palKey))
        end
        local seq, fr = pose(it)
        w16(e + E.seq, seq)
        w32(e + E.frame, fr)
      end
    end
  end
  for id in pairs(mine) do if not present[id] then release(id) end end
  return true
end

function actors.debug()
  local out = { "status " .. actors.status }
  if sys then
    out[#out + 1] = string.format("set %08X base %08X count %d player %08X", sys.set, sys.base, sys.count, sys.player)
  end
  for name, sh in pairs(sheets) do
    out[#out + 1] = string.format("sheet %s tex %X pal %X", name, sh.tex, sh.pal)
  end
  for id, e in pairs(mine) do
    local t = {}
    for i = 0, ENTRY - 4, 4 do t[#t + 1] = string.format("%08X", u32(e + i)) end
    out[#out + 1] = string.format("actor %s @%08X: %s", id, e, table.concat(t, " "))
  end
  return table.concat(out, "\n")
end

function actors.clearAll()
  for id in pairs(mine) do release(id) end
end

return actors
