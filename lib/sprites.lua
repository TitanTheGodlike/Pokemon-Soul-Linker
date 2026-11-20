-- Pokémon battle sprites (the big front pictures) with their idle animation, read from your own
-- game and cached as PNG strips (one pose after another, at twice the size so they stay sharp).
-- In Black/White each Pokémon is a puppet: a parts sheet (a 256x128 picture), cells (which parts
-- make up each piece), one looping animation per piece (which cell, moved / scaled / turned, for
-- how long) and a multi-cell that places the pieces. Files per species in a/0/0/4 (20 each):
-- 2 = parts sheet (LZ11), 3 = the female's parts sheet (only for the 96 species that look
-- different), 4 = cells (NCER), 5 = animations (NANR, LZ11), 6 = multi-cell (NMCR),
-- 18 = palette (NCLR), 19 = shiny palette. Multi-cell 0 with the first animations is the idle
-- loop seen in battle.
-- Building a strip takes a moment, so it is done a few milliseconds per frame (sprites.work).
local nds = require("nds")

local sprites = {}
local narc, cacheDir, code
local made = {}        -- key ("495", "25fs", ...) -> entry | false
local queue, queued = {}, {}
local job              -- { key, co }
local femaleSheet = {} -- species -> has its own female look
local deadline = 0
sprites.changed = false -- a new strip got ready (the panel redraws)

local STEP = 6         -- game frames per pose (the games animate at 10 poses a second)
local MAX_PERIOD = 240 -- at most 4 seconds of animation per strip

-- Gen 4 (Diamond/Pearl/Platinum/HGSS): six files per species (female back, back, female
-- front, front, palette, shiny palette); each picture is two 80x80 frames side by side,
-- 16 colours, stored scrambled. They don't animate in battle; the strip shows the first frame
-- with a short hop to the second now and then.
local gen4 = nil -- this game's files (game.rom) when it's a Gen 4 game

function sprites.init(dir, gameCode)
  cacheDir, code = dir, gameCode
  local game = require("game")
  gen4 = game.gen == 4 and game.rom or nil
  local ok, n = pcall(nds.narc, gen4 and gen4.battle or "a/0/0/4")
  narc = ok and n or nil
end

local function pause()
  if os.clock() > deadline and coroutine.isyieldable() then coroutine.yield() end
end

------------------------------------------------------------------ byte tables (1-based, offsets 0-based)
local function U16(t, o) return t[o + 1] | (t[o + 2] << 8) end
local function S16(t, o) local v = U16(t, o); return v >= 0x8000 and v - 0x10000 or v end
local function U32(t, o) return t[o + 1] | (t[o + 2] << 8) | (t[o + 3] << 16) | (t[o + 4] << 24) end
local function S32(t, o) local v = U32(t, o); return v >= 0x80000000 and v - 0x100000000 or v end
local function find(t, magic)
  local a, b, c, d = magic:byte(1, 4)
  for o = 0, #t - 4 do
    if t[o + 1] == a and t[o + 2] == b and t[o + 3] == c and t[o + 4] == d then return o end
  end
end

local function member(i)
  local a, b = narc.range(i)
  if b <= a then return nil end
  return nds.bytes(a, b - a)
end

-- LZ77 (types 0x10 and 0x11) as used by the DS
local function unlz(src)
  local kind = src[1]
  if kind ~= 0x10 and kind ~= 0x11 then return src end
  local size = src[2] | (src[3] << 8) | (src[4] << 16)
  local out, n, p = {}, 0, 5
  while n < size do
    local flags = src[p]; p = p + 1
    for bit = 7, 0, -1 do
      if n >= size then break end
      if (flags >> bit) & 1 == 1 then
        local b1, len, disp = src[p], nil, nil
        if kind == 0x10 then
          len = (b1 >> 4) + 3
          disp = (((b1 & 15) << 8) | src[p + 1]) + 1; p = p + 2
        else
          local ind = b1 >> 4
          if ind == 0 then
            len = (((b1 & 15) << 4) | (src[p + 1] >> 4)) + 0x11
            disp = (((src[p + 1] & 15) << 8) | src[p + 2]) + 1; p = p + 3
          elseif ind == 1 then
            len = (((b1 & 15) << 12) | (src[p + 1] << 4) | (src[p + 2] >> 4)) + 0x111
            disp = (((src[p + 2] & 15) << 8) | src[p + 3]) + 1; p = p + 4
          else
            len = ind + 1
            disp = (((b1 & 15) << 8) | src[p + 1]) + 1; p = p + 2
          end
        end
        for _ = 1, len do n = n + 1; out[n] = out[n - disp] end
      else
        n = n + 1; out[n] = src[p]; p = p + 1
      end
    end
  end
  return out
end

------------------------------------------------------------------ the puppet's files
local SIZES = {
  [0] = { { 8, 8 }, { 16, 16 }, { 32, 32 }, { 64, 64 } },
  [1] = { { 16, 8 }, { 32, 8 }, { 32, 16 }, { 64, 32 } },
  [2] = { { 8, 16 }, { 8, 32 }, { 16, 32 }, { 32, 64 } },
}

-- cells: [cell] = list of pieces { x, y, w, h, sheet x, sheet y, hflip, vflip, affine }
local function readCells(t, sheetW)
  local k = find(t, "KBEC")
  if not k then return nil end
  local ncells, attr, cdoff = U16(t, k + 8), U16(t, k + 10), U32(t, k + 12)
  local base = k + 8 + cdoff
  local esz = attr == 1 and 16 or 8
  local oamBase = base + ncells * esz
  local cells = {}
  for c = 0, ncells - 1 do
    local noam, ooff = U16(t, base + c * esz), U32(t, base + c * esz + 4)
    local list = {}
    for o = 0, noam - 1 do
      local p = oamBase + ooff + o * 6
      local a0, a1, a2 = U16(t, p), U16(t, p + 2), U16(t, p + 4)
      local aff, dbl = (a0 >> 8) & 1, (a0 >> 9) & 1
      local sz = SIZES[a0 >> 14] and SIZES[a0 >> 14][(a1 >> 14) + 1]
      if sz and (aff == 1 or dbl == 0) then
        local y = a0 & 0xFF; if y >= 128 then y = y - 256 end
        local x = a1 & 0x1FF; if x >= 256 then x = x - 512 end
        local w, h = sz[1], sz[2]
        if aff == 1 and dbl == 1 then x = x + w // 2; y = y + h // 2 end
        local tile = a2 & 0x3FF
        list[#list + 1] = {
          x = x, y = y, w = w, h = h,
          sx = (tile % (sheetW // 8)) * 8, sy = (tile // (sheetW // 8)) * 8,
          hf = aff == 0 and (a1 >> 12) & 1 == 1, vf = aff == 0 and (a1 >> 13) & 1 == 1, aff = aff == 1,
        }
      end
    end
    cells[c] = list
  end
  return cells
end

-- animations: [sequence] = list of frames { cell, rot, sx, sy, tx, ty, time }, plus each total time
local function readAnims(t)
  local k = find(t, "KNBA")
  if not k then return nil end
  local nseq = U16(t, k + 8)
  local seqOff, frOff, adOff = U32(t, k + 12), U32(t, k + 16), U32(t, k + 20)
  local b = k + 8
  local seqs = {}
  for s = 0, nseq - 1 do
    local sp = b + seqOff + s * 16
    local nf, kind, fo = U16(t, sp), U32(t, sp + 4) & 0xFFFF, U32(t, sp + 12)
    local list, total = {}, 0
    for f = 0, nf - 1 do
      local fp = b + frOff + fo + f * 8
      local e = b + adOff + U32(t, fp)
      local time = U16(t, fp + 4)
      local fr = { cell = U16(t, e), rot = 0, scx = 1, scy = 1, tx = 0, ty = 0, time = time }
      if kind == 1 then
        fr.rot = U16(t, e + 2)
        fr.scx, fr.scy = S32(t, e + 4) / 4096, S32(t, e + 8) / 4096
        fr.tx, fr.ty = S16(t, e + 12), S16(t, e + 14)
      elseif kind == 2 then
        fr.tx, fr.ty = S16(t, e + 4), S16(t, e + 6)
      end
      list[#list + 1] = fr
      total = total + time
    end
    list.total = total
    seqs[s] = list
  end
  return seqs
end

-- multi-cell 0: list of { sequence, x, y }
local function readNodes(t)
  local k = find(t, "KBCM")
  if not k then return nil end
  local b = k + 8
  local mcOff, hOff = U32(t, k + 12), U32(t, k + 16)
  local nn, ho = U16(t, b + mcOff), U32(t, b + mcOff + 4)
  local nodes = {}
  for i = 0, nn - 1 do
    local p = b + hOff + ho + i * 8
    nodes[#nodes + 1] = { seq = U16(t, p), x = S16(t, p + 2), y = S16(t, p + 4) }
  end
  return nodes
end

local function readPalette(t)
  local p = find(t, "TTLP")
  if not p then return nil end
  local data = p + 8 + U32(t, p + 0x14)
  local pal = {}
  for c = 1, 15 do
    local v = U16(t, data + c * 2)
    pal[c] = string.char((v & 31) * 255 // 31, ((v >> 5) & 31) * 255 // 31, ((v >> 10) & 31) * 255 // 31, 255)
  end
  return pal
end

local function frameAt(seq, t)
  if seq.total <= 0 then return seq[1] end
  t = t % seq.total
  for _, f in ipairs(seq) do
    if t < f.time then return f end
    t = t - f.time
  end
  return seq[#seq]
end

local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end

------------------------------------------------------------------ building a strip
local function build(sp, female, shiny, path)
  local f = sp * 20
  if f + 19 >= narc.count then return nil end
  local sheet = member(f + (female and 3 or 2))
  if not sheet then return nil end
  sheet = unlz(sheet)
  local c = find(sheet, "RAHC")
  if not c then return nil end
  local sw, sh = U16(sheet, c + 10) * 8, U16(sheet, c + 8) * 8
  local d0 = c + 0x20 + 1 -- pixel data, 4 bits per pixel, row by row (1-based index)
  local cells = readCells(member(f + 4) or {}, sw)
  local seqs = readAnims(unlz(member(f + 5) or {}))
  local nodes = readNodes(member(f + 6) or {})
  local palT = member(f + (shiny and 19 or 18))
  local pal = palT and readPalette(palT)
  if not (cells and seqs and nodes and pal) then return nil end
  pause()

  local function pix(x, y)
    if x < 0 or y < 0 or x >= sw or y >= sh then return 0 end
    local i = y * sw + x
    local b = sheet[d0 + (i >> 1)]
    if not b then return 0 end
    return (i & 1 == 1) and (b >> 4) or (b & 15)
  end

  -- how long until the whole idle animation repeats
  local period = 1
  for _, n in ipairs(nodes) do
    local s = seqs[n.seq]
    if s and s.total > 0 then period = math.min(MAX_PERIOD, period * s.total // gcd(period, s.total)) end
  end
  local nFrames = math.max(1, (period + STEP - 1) // STEP)

  local frames = {}
  local X0, Y0, X1, Y1 = 1e9, 1e9, -1e9, -1e9
  for fi = 0, nFrames - 1 do
    local px = {}
    local function put(x, y, v)
      px[(y + 512) * 2048 + x + 1024] = v
      if x < X0 then X0 = x end
      if x > X1 then X1 = x end
      if y < Y0 then Y0 = y end
      if y > Y1 then Y1 = y end
    end
    local t = fi * STEP
    -- earlier nodes and pieces are in front, so draw back to front
    for ni = #nodes, 1, -1 do
      local node = nodes[ni]
      local seq = seqs[node.seq]
      local fr = seq and frameAt(seq, t)
      local list = fr and cells[fr.cell]
      if list and fr.scx ~= 0 and fr.scy ~= 0 then
        local ox, oy = node.x + fr.tx, node.y + fr.ty
        local plain = fr.rot == 0 and fr.scx == 1 and fr.scy == 1
        local a = fr.rot * 2 * math.pi / 65536
        local ca, sa = math.cos(a), math.sin(a)
        for pi = #list, 1, -1 do
          local q = list[pi]
          local x, y, w, h = q.x, q.y, q.w, q.h
          if plain or not q.aff then
            if not plain then -- a piece that can't turn: only its place moves
              local cx, cy = (x + w / 2) * fr.scx, (y + h / 2) * fr.scy
              x = math.floor(ca * cx - sa * cy - w / 2 + 0.5)
              y = math.floor(sa * cx + ca * cy - h / 2 + 0.5)
            end
            for yy = 0, h - 1 do
              for xx = 0, w - 1 do
                local v = pix(q.sx + xx, q.sy + yy)
                if v ~= 0 then
                  put(ox + x + (q.hf and (w - 1 - xx) or xx), oy + y + (q.vf and (h - 1 - yy) or yy), v)
                end
              end
            end
          else
            -- turned/scaled: for each screen pixel, find the part pixel it shows
            local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
            for _, cn in ipairs({ { x, y }, { x + w, y }, { x, y + h }, { x + w, y + h } }) do
              local px2, py2 = cn[1] * fr.scx, cn[2] * fr.scy
              local rx, ry = ca * px2 - sa * py2, sa * px2 + ca * py2
              if rx < minX then minX = rx end
              if rx > maxX then maxX = rx end
              if ry < minY then minY = ry end
              if ry > maxY then maxY = ry end
            end
            for dy = math.floor(minY), math.ceil(maxY) - 1 do
              for dx = math.floor(minX), math.ceil(maxX) - 1 do
                local cx, cy = dx + 0.5, dy + 0.5
                local lx = (ca * cx + sa * cy) / fr.scx
                local ly = (-sa * cx + ca * cy) / fr.scy
                local xx, yy = math.floor(lx - x), math.floor(ly - y)
                if xx >= 0 and xx < w and yy >= 0 and yy < h then
                  local v = pix(q.sx + xx, q.sy + yy)
                  if v ~= 0 then put(ox + dx, oy + dy, v) end
                end
              end
            end
          end
          pause()
        end
      end
    end
    frames[fi + 1] = px
  end
  if X1 < X0 then return nil end

  -- the strip: every pose side by side, each pixel doubled
  local fw, fh = X1 - X0 + 1, Y1 - Y0 + 1
  local clear = "\0\0\0\0"
  local rows = {}
  for y = 0, fh - 1 do
    local row, n = {}, 0
    local base = (Y0 + y + 512) * 2048 + X0 + 1024
    for fi = 1, nFrames do
      local px = frames[fi]
      for x = 0, fw - 1 do
        local v = px[base + x]
        local col = v and pal[v] or clear
        row[n + 1], row[n + 2] = col, col
        n = n + 2
      end
    end
    local line = table.concat(row)
    rows[2 * y + 1], rows[2 * y + 2] = line, line
    pause()
  end
  nds.writePng(path .. ".tmp", fw * 2 * nFrames, fh * 2, rows, pause)
  os.remove(path)
  os.rename(path .. ".tmp", path)
  return { path = path, fw = fw * 2, fh = fh * 2, n = nFrames }
end

local HOP = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0 } -- which frame each pose shows

local function build4(sp, female, shiny, path)
  local f = sp * 6
  if f + 5 >= narc.count then return nil end
  -- unscramble: each 16-bit word XOR a running key (Platinum/HGSS from the first word forward,
  -- Diamond/Pearl from the last word backward); nil if the picture is empty
  local function decode(k)
    local img = member(k)
    local c = img and find(img, "RAHC")
    if not c then return nil end
    local words = U32(img, c + 24) // 2
    local d0 = c + 0x20
    local w = {}
    for i = 0, words - 1 do w[i] = U16(img, d0 + i * 2) end
    local fromEnd = gen4.battleEncrypt == "dp"
    local seed = fromEnd and w[words - 1] or w[0]
    local any = false
    for j = 0, words - 1 do
      local i = fromEnd and (words - 1 - j) or j
      w[i] = w[i] ~ (seed & 0xFFFF)
      if w[i] ~= 0 then any = true end
      seed = (seed * 0x4E6D + 0x6073) & 0xFFFFFFFF
    end
    pause()
    return any and w or nil, U16(img, c + 10) * 8
  end
  -- (species that look the same for both genders have an empty female picture)
  local w, W
  if female then w, W = decode(f + 2) end
  if not w then w, W = decode(f + 3) end
  if not w then return nil end
  local palT = member(f + (shiny and 5 or 4))
  local pal = palT and readPalette(palT)
  if not pal then return nil end
  local function pix(fr, x, y) -- W = 160: two frames side by side
    local i = y * W + fr * 80 + x
    local v = w[i >> 2]
    return (v >> ((i & 3) * 4)) & 15
  end
  local X0, Y0, X1, Y1 = 80, 80, -1, -1
  for fr = 0, 1 do
    for y = 0, 79 do
      for x = 0, 79 do
        if pix(fr, x, y) ~= 0 then
          if x < X0 then X0 = x end
          if x > X1 then X1 = x end
          if y < Y0 then Y0 = y end
          if y > Y1 then Y1 = y end
        end
      end
    end
    pause()
  end
  if X1 < X0 then return nil end
  local fw, fh = X1 - X0 + 1, Y1 - Y0 + 1
  local clear = "\0\0\0\0"
  local lines = {}
  for fr = 0, 1 do
    lines[fr] = {}
    for y = 0, fh - 1 do
      local row = {}
      for x = 0, fw - 1 do
        local v = pix(fr, X0 + x, Y0 + y)
        local col = v ~= 0 and pal[v] or clear
        row[2 * x + 1], row[2 * x + 2] = col, col
      end
      lines[fr][y] = table.concat(row)
    end
    pause()
  end
  -- the strip holds the two frames once; which one each pose shows is HOP (sprites.pose)
  local rows = {}
  for y = 0, fh - 1 do
    local line = lines[0][y] .. lines[1][y]
    rows[2 * y + 1], rows[2 * y + 2] = line, line
  end
  nds.writePng(path .. ".tmp", fw * 2 * 2, fh * 2, rows, pause)
  os.remove(path)
  os.rename(path .. ".tmp", path)
  return { path = path, fw = fw * 2, fh = fh * 2, n = 2, seq = HOP }
end

local function pngSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local head = f:read(24) or ""
  f:close()
  if #head < 24 then return nil end
  return string.unpack(">I4", head, 17), string.unpack(">I4", head, 21)
end

------------------------------------------------------------------ public
-- the strip of a species' battle sprite (shiny colours / the female look if asked for):
-- { path, fw, fh (one pose, in pixels), n (poses) }, or nil while it's still being made
-- (then it's queued; sprites.changed says when it's ready)
function sprites.get(sp, shiny, female)
  if not narc or not sp or sp <= 0 or sp > 649 then return nil end
  if female then
    if femaleSheet[sp] == nil then
      local a, b = narc.range(gen4 and sp * 6 + 2 or sp * 20 + 3)
      femaleSheet[sp] = b > a
    end
    female = femaleSheet[sp]
  end
  local key = sp .. (female and "f" or "") .. (shiny and "s" or "")
  local m = made[key]
  if m ~= nil then return m or nil end
  local path = string.format("%s/battle_%s_%s.png", cacheDir, code, key)
  local w, h = pngSize(path)
  if w and h > 0 then
    -- (how many poses the strip has is kept in a small file next to it)
    local f = io.open(path .. ".txt", "r")
    local n = f and tonumber(f:read("l") or "")
    if f then f:close() end
    if n and n > 0 then
      made[key] = { path = path, fw = w // n, fh = h, n = n, seq = (gen4 and n == 2) and HOP or nil }
      return made[key]
    end
  end
  if not queued[key] then
    queued[key] = true
    queue[#queue + 1] = { key = key, sp = sp, female = female, shiny = shiny, path = path }
  end
  return nil
end

-- the pose to show now (game frame count -> 0-based pose)
function sprites.pose(e, frame)
  if e.seq then return e.seq[(frame // STEP) % #e.seq + 1] end
  return (frame // STEP) % e.n
end
sprites.STEP = STEP

-- make queued strips, using about ms milliseconds
function sprites.work(ms)
  if not job and #queue == 0 then return end
  local stop = os.clock() + (ms or 4) / 1000
  while os.clock() < stop do
    if not job then
      local q = table.remove(queue, 1)
      if not q then return end
      job = { q = q, co = coroutine.create(gen4 and build4 or build), first = true }
    end
    deadline = stop
    local ok, res
    if job.first then
      job.first = false
      ok, res = coroutine.resume(job.co, job.q.sp, job.q.female, job.q.shiny, job.q.path)
    else
      ok, res = coroutine.resume(job.co)
    end
    if not ok or coroutine.status(job.co) == "dead" then
      local e = ok and res or false
      if not ok then sprites.lastError = tostring(res) end
      if e then
        local f = io.open(e.path .. ".txt", "w")
        if f then f:write(tostring(e.n), "\n"); f:close() end
      end
      made[job.q.key] = e
      queued[job.q.key] = nil
      job = nil
      sprites.changed = true
    end
  end
end

return sprites
