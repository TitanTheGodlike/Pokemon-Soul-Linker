-- Pokémon party icons, read from your own game (a/0/0/7) and cached as PNG files for the panel.
-- The icons share 3 palettes; which one a Pokémon uses isn't stored anywhere easy to reach, so
-- the palette whose colours best match the Pokémon's Pokédex colour (personal data) is used.
local nds = require("nds")

local icons = {}
local narc, palettes, personal
local cacheDir, code
local made = {}

-- rough RGB for each Pokédex colour (personal data byte 0x21, bits 0-6)
local DEX_COLOR = {
  [0] = { 225, 70, 60 },   -- red
  [1] = { 70, 110, 225 },  -- blue
  [2] = { 235, 205, 70 },  -- yellow
  [3] = { 80, 175, 85 },   -- green
  [4] = { 70, 70, 80 },    -- black
  [5] = { 160, 110, 70 },  -- brown
  [6] = { 150, 90, 180 },  -- purple
  [7] = { 150, 150, 155 }, -- gray
  [8] = { 225, 225, 230 }, -- white
  [9] = { 235, 140, 175 }, -- pink
}

local R -- this game's files (Gen 4 games name their own archives)
function icons.init(dir, gameCode)
  cacheDir, code = dir, gameCode
  R = require("game").rom
  narc = nds.narc(R.icons or "a/0/0/7")
  personal = nds.narc(R.personal or "a/0/1/6")
  -- the 3 palettes from the icon palette file (NCLR)
  local base = narc.range(0)
  local p = base
  while nds.u32(p) ~= 0x504C5454 do p = p + 4 end -- "TTLP"
  local data = p + 8 + nds.u32(p + 0x14)
  palettes = {}
  for k = 0, 2 do
    local pal = {}
    for c = 0, 15 do
      local v = nds.u16(data + (k * 16 + c) * 2)
      pal[c] = { (v & 31) * 255 // 31, ((v >> 5) & 31) * 255 // 31, ((v >> 10) & 31) * 255 // 31 }
    end
    palettes[k] = pal
  end
end

-- 32x32 colour indices of an icon's first frame (16 tiles of 8x8, 4 bits per pixel)
local function iconPixels(sp)
  local fid = R.iconBase + (R.iconStep or 2) * sp
  if fid >= narc.count then return nil end
  local a, b = narc.range(fid)
  if b - a < 0x220 then return nil end
  local p = a
  while nds.u32(p) ~= 0x43484152 do p = p + 4; if p > a + 64 then return nil end end -- "RAHC"
  local bytes = nds.bytes(p + 0x20, 0x200)
  local px = {}
  for t = 0, 15 do
    local tx, ty = t % 4, t // 4
    for i = 0, 31 do
      local v = bytes[t * 32 + i + 1]
      local y = ty * 8 + i // 4
      local x = tx * 8 + (i % 4) * 2
      px[y * 32 + x] = v & 15
      px[y * 32 + x + 1] = v >> 4
    end
  end
  return px
end

local function pickPalette(sp, px)
  local want = DEX_COLOR[0]
  if sp < personal.count then
    local a = personal.range(sp)
    want = DEX_COLOR[nds.u8(a + (R.dexColor or 0x21)) & 0x7F] or want
  end
  local best, bestD = 0, nil
  for k = 0, 2 do
    local r, g, b, n = 0, 0, 0, 0
    for i = 0, 1023 do
      local c = px[i]
      if c ~= 0 then
        local col = palettes[k][c]
        local lum = col[1] + col[2] + col[3]
        if lum > 120 and lum < 690 then -- skip outlines and highlights
          r, g, b, n = r + col[1], g + col[2], b + col[3], n + 1
        end
      end
    end
    if n > 0 then
      r, g, b = r / n, g / n, b / n
      local d = (r - want[1]) ^ 2 + (g - want[2]) ^ 2 + (b - want[3]) ^ 2
      if not bestD or d < bestD then best, bestD = k, d end
    end
  end
  return best
end

-- path of a PNG icon for a species (made on first use), or nil
function icons.path(sp)
  if not narc or not sp or sp <= 0 then return nil end
  local cached = made[sp]
  if cached ~= nil then return cached or nil end
  local path = string.format("%s/icon2x_%s_%d.png", cacheDir, code, sp)
  local f = io.open(path, "rb")
  if f then f:close(); made[sp] = path; return path end
  local px = iconPixels(sp)
  if not px then made[sp] = false; return nil end
  local pal = palettes[pickPalette(sp, px)]
  -- saved at twice the size (sharp pixels), so the panel can show it big without blurring
  local rows = {}
  for y = 0, 31 do
    local row = {}
    for x = 0, 31 do
      local c = px[y * 32 + x]
      local v = c == 0 and "\0\0\0\0" or string.char(pal[c][1], pal[c][2], pal[c][3], 255)
      row[2 * x + 1], row[2 * x + 2] = v, v
    end
    local line = table.concat(row)
    rows[2 * y + 1], rows[2 * y + 2] = line, line
  end
  nds.writePng(path, 64, 64, rows)
  made[sp] = path
  return path
end

return icons
