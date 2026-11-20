-- Reads data straight out of the player's own game (BizHawk "ROM" memory domain):
-- NitroFS paths, NARC archives, Gen 5 text, and NSBTX sprite textures -> PNG.
-- Nothing from the game is shipped with the tool; it is all read at runtime.
local nds = {}
local D = "ROM"

local function u8(a) return memory.read_u8(a, D) end
local function u16(a) return memory.read_u16_le(a, D) end
local function u32(a) return memory.read_u32_le(a, D) end
local function bytes(a, n) return memory.read_bytes_as_array(a, n, D) end
nds.u8, nds.u16, nds.u32, nds.bytes = u8, u16, u32, bytes

local FNT, FAT

local function dirEntries(dirId)
  local e = FNT + (dirId & 0xFFF) * 8
  local p = FNT + u32(e)
  local fid = u16(e + 4)
  local out = {}
  while true do
    local t = u8(p); p = p + 1
    if t == 0 then break end
    local n = t & 0x7F
    local b = bytes(p, n)
    local chars = {}
    for i = 1, n do chars[i] = string.char(b[i]) end
    local name = table.concat(chars)
    p = p + n
    if t & 0x80 ~= 0 then
      out[#out + 1] = { name = name, dir = true, id = u16(p) }; p = p + 2
    else
      out[#out + 1] = { name = name, dir = false, id = fid }; fid = fid + 1
    end
  end
  return out
end

function nds.init()
  FNT = u32(0x40)
  FAT = u32(0x48)
end

-- path like "a/0/1/2" -> file id
function nds.lookup(path)
  local cur = 0xF000
  local parts = {}
  for p in path:gmatch("[^/]+") do parts[#parts + 1] = p end
  for i, part in ipairs(parts) do
    local found
    for _, e in ipairs(dirEntries(cur)) do
      if e.name == part then found = e; break end
    end
    if not found then error("not found: " .. path) end
    if i == #parts then return found.id end
    cur = found.id
  end
end

function nds.fileRange(fid)
  return u32(FAT + fid * 8), u32(FAT + fid * 8 + 4)
end

-- NARC archive object with absolute ROM addresses for each member file
function nds.narc(path)
  local start = nds.fileRange(nds.lookup(path))
  local hs = u16(start + 12)
  local p = start + hs
  local btafSize = u32(p + 4)
  local count = u16(p + 8)
  local ents = p + 12
  p = p + btafSize
  p = p + u32(p + 4) -- BTNF
  local gmif = p + 8
  local n = { count = count }
  function n.range(i) -- 0-based member index -> absolute start, end
    return gmif + u32(ents + i * 8), gmif + u32(ents + i * 8 + 4)
  end
  return n
end

-- Gen 5 encrypted text file at absolute address -> list of UTF-8 strings (1-based, entry 0 at [1])
function nds.text(base)
  local nentries = u16(base + 2)
  local boff = u32(base + 12)
  local out = {}
  for i = 0, nentries - 1 do
    local off = u32(base + boff + 4 + i * 8)
    local len = u16(base + boff + 8 + i * 8)
    local b = bytes(base + boff + off, len * 2)
    local chars = {}
    for j = 1, len do chars[j] = b[j * 2 - 1] | (b[j * 2] << 8) end
    local key = chars[len] ~ 0xFFFF
    for j = len, 1, -1 do
      chars[j] = chars[j] ~ key
      key = ((key >> 3) | (key << 13)) & 0xFFFF
    end
    local s = {}
    for j = 1, len do
      local c = chars[j]
      if c == 0xFFFF then break end
      if c == 0xFFFE then s[#s + 1] = " "
      elseif c < 0xF000 then s[#s + 1] = utf8.char(c) end
    end
    out[i + 1] = table.concat(s)
  end
  return out
end

------------------------------------------------------------------------ PNG writer
local crcTable = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  crcTable[i] = c
end
-- (both read the string in chunks, which is much faster; pause() is called between chunks)
local CHUNK = 4000
local function crc32(s, pause)
  local c = 0xFFFFFFFF
  for i = 1, #s, CHUNK do
    local t = { s:byte(i, math.min(#s, i + CHUNK - 1)) }
    for k = 1, #t do c = crcTable[(c ~ t[k]) & 0xFF] ~ (c >> 8) end
    if pause then pause() end
  end
  return c ~ 0xFFFFFFFF
end
local function adler32(s, pause)
  local a, b = 1, 0
  for i = 1, #s, CHUNK do
    local t = { s:byte(i, math.min(#s, i + CHUNK - 1)) }
    for k = 1, #t do
      a = a + t[k]
      b = b + a
    end
    a, b = a % 65521, b % 65521
    if pause then pause() end
  end
  return (b << 16) | a
end

-- rows: array of strings, each w*4 bytes RGBA; pause (optional) is called now and then
function nds.writePng(path, w, h, rows, pause)
  local raw = {}
  for y = 1, h do raw[#raw + 1] = "\0"; raw[#raw + 1] = rows[y] end
  raw = table.concat(raw)
  local z = { "\120\1" }
  local pos = 1
  while pos <= #raw do
    local chunk = raw:sub(pos, pos + 65534)
    pos = pos + #chunk
    local final = pos > #raw and 1 or 0
    z[#z + 1] = string.pack("<BI2I2", final, #chunk, (~#chunk) & 0xFFFF)
    z[#z + 1] = chunk
  end
  z[#z + 1] = string.pack(">I4", adler32(raw, pause))
  z = table.concat(z)
  local function chunk(t, data)
    return string.pack(">I4", #data) .. t .. data .. string.pack(">I4", crc32(t .. data, pause))
  end
  local png = "\137PNG\r\n\26\n"
    .. chunk("IHDR", string.pack(">I4I4BBBBB", w, h, 8, 6, 0, 0, 0))
    .. chunk("IDAT", z)
    .. chunk("IEND", "")
  local f = assert(io.open(path, "wb"))
  f:write(png); f:close()
end

------------------------------------------------------------------------ NSBTX textures
local function dict3d(o)
  local cnt = u8(o + 1)
  local p = o + u16(o + 6)
  local infoSize = u16(p + 2)
  local per = (infoSize - 4) // cnt
  p = p + 4
  local infos = {}
  for i = 0, cnt - 1 do infos[i + 1] = p + i * per end
  return infos, cnt
end

-- Decode all textures of a BTX0 file at absolute address into one sprite sheet PNG.
-- Frames are laid out `cols` per row. Returns frame width, height, count and, per frame,
-- the solid pixel span of each row (spans[frame][row] = {left, right}, 0-based) for occlusion.
-- With writePng = false only the spans are computed.
function nds.btxToSheet(base, path, cols, maxFrames, writePng)
  local t = base + u32(base + 0x10)
  local texInfo = t + u16(t + 0x0E)
  local texData = t + u32(t + 0x14)
  local palInfo = t + u32(t + 0x34)
  local palData = t + u32(t + 0x38)
  local texs, cnt = dict3d(texInfo)
  local pals = dict3d(palInfo)
  local palAddr = palData + (u16(pals[1]) << 3)
  if maxFrames and cnt > maxFrames then cnt = maxFrames end
  local frames, fw, fh = {}, 0, 0
  local spans = {}
  for k = 1, cnt do
    local param = u32(texs[k])
    local off = (param & 0xFFFF) << 3
    local w = 8 << ((param >> 20) & 7)
    local h = 8 << ((param >> 23) & 7)
    local fmt = (param >> 26) & 7
    local c0 = (param >> 29) & 1
    local bpp = (fmt == 2 and 2) or (fmt == 3 and 4) or 8
    local ncol = 1 << bpp
    local colors = {}
    for i = 0, ncol - 1 do
      local v = u16(palAddr + i * 2)
      local r = (v & 31) * 255 // 31
      local g = ((v >> 5) & 31) * 255 // 31
      local b = ((v >> 10) & 31) * 255 // 31
      colors[i] = string.char(r, g, b, 255)
    end
    local clear = string.char(0, 0, 0, 0)
    local data = bytes(texData + off, w * h * bpp // 8)
    local rows = {}
    local fs = {}
    for y = 0, h - 1 do
      local row = {}
      local l, r
      for x = 0, w - 1 do
        local i = y * w + x
        local bit = i * bpp
        local byte = data[(bit >> 3) + 1]
        local idx = (byte >> (bit & 7)) & (ncol - 1)
        local transparent = idx == 0 and c0 == 1
        row[x + 1] = transparent and clear or colors[idx]
        if not transparent then
          l = l or x
          r = x
        end
      end
      rows[y + 1] = table.concat(row)
      if l then fs[y] = { l, r } end
    end
    frames[k] = rows
    spans[k] = fs
    fw, fh = w, h
  end
  if writePng == false then return fw, fh, cnt, spans end
  local rowsOut = {}
  local nrows = (cnt + cols - 1) // cols
  local blank = string.rep("\0", fw * 4)
  for r = 0, nrows - 1 do
    for y = 1, fh do
      local line = {}
      for c = 0, cols - 1 do
        local f = frames[r * cols + c + 1]
        line[c + 1] = f and f[y] or blank
      end
      rowsOut[#rowsOut + 1] = table.concat(line)
    end
  end
  nds.writePng(path, cols * fw, nrows * fh, rowsOut)
  return fw, fh, cnt, spans
end

return nds
