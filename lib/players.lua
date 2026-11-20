-- Draws the other players walking around in your game.
--  * sprites come from your own game's player sprites
--  * walking frames follow the actual tile steps, like the game's own animation
--  * players further back than you are hidden behind your character (row-by-row outline)
--  * players standing in tall grass have their legs hidden by the grass
local camera = require("camera")

local players = {}

-- sheet columns: Up, Down, Left, Right (stand, step A, step B); facing: 0 up,1 left,2 down,3 right
local SHEET_DIR = { [0] = 0, [1] = 2, [2] = 1, [3] = 3 }
local GRASS_ROW = 21 -- rows below this are covered by tall grass

local function sameSpace(a, b, game)
  if not a or not b then return false end
  if a.zone == b.zone then return true end
  local za, zb = game.zoneInfo(a.zone), game.zoneInfo(b.zone)
  if not za or not zb or za.matrix ~= zb.matrix then return false end
  -- the main overworld map is shared; other maps (e.g. every Pokémon Center) reuse
  -- a matrix in different towns, so they also need the same area name
  return za.matrix == 0 or za.loc == zb.loc
end
players.sameSpace = sameSpace

-- frame from position: stepping pose between tile centres, standing pose on them
local function frameFor(facing, x, z, speed, bike)
  local col = SHEET_DIR[facing or 2] * 3
  local row = 0
  local t = (facing == 1 or facing == 3) and x or z
  local frac = (t - 0.5) % 1
  if frac > 0.12 and frac < 0.88 then
    col = col + 1 + (math.floor(t - 0.5) % 2)
    if (speed or 0) > 0.09 and not bike then row = 1 end
  end
  return col, row
end

local function sheetName(sprite, bike)
  return (sprite or "boy") .. (bike and "_bike" or "")
end

-- integer screen rectangle for a sprite whose feet are at (sx, sy)
local function rect(sx, sy, scale)
  local size = 32 * scale
  return { left = sx - size / 2, top = sy - size * 0.94, size = size, s = scale }
end

local function rowY(r, ry) return math.floor(r.top + ry * r.s + 0.5) end

local function drawRows(r, from, to)
  if to <= from then return end
  local y0, y1 = rowY(r, from), rowY(r, to)
  if y1 <= y0 then return end
  gui.drawImageRegion(r.sheet, r.col * 32, r.row * 32 + from, 32, to - from,
    math.floor(r.left + 0.5), y0, math.floor(r.size + 0.5), y1 - y0)
end

local function drawRowPart(r, ry, x0, x1)
  if x1 <= x0 then return end
  local y0, y1 = rowY(r, ry), rowY(r, ry + 1)
  if y1 <= y0 then return end
  local dx0 = math.floor(r.left + x0 * r.s + 0.5)
  local dx1 = math.floor(r.left + x1 * r.s + 0.5)
  if dx1 <= dx0 then return end
  gui.drawImageRegion(r.sheet, r.col * 32 + x0, r.row * 32 + ry, x1 - x0, 1, dx0, y0, dx1 - dx0, y1 - y0)
end

-- draw a remote sprite, skipping the pixels your own character covers (when `me` is given)
local function drawSprite(r, me)
  local last = r.grass and GRASS_ROW or 32
  if not me then drawRows(r, 0, last); return end
  local blockStart = 0
  for ry = 0, last - 1 do
    local cy = r.top + (ry + 0.5) * r.s
    local myRow = math.floor((cy - me.top) / me.s)
    local span = me.spans and me.spans[myRow]
    if span and (myRow < 0 or myRow >= (me.grass and GRASS_ROW or 32)) then span = nil end
    if span then
      drawRows(r, blockStart, ry)
      blockStart = ry + 1
      -- hidden screen range -> remote source columns
      local hl = me.left + span[1] * me.s
      local hr = me.left + (span[2] + 1) * me.s
      local sl = math.max(0, math.min(32, math.floor((hl - r.left) / r.s)))
      local sr = math.max(0, math.min(32, math.ceil((hr - r.left) / r.s)))
      drawRowPart(r, ry, 0, sl)
      drawRowPart(r, ry, sr, 32)
    end
  end
  drawRows(r, blockStart, last)
end

-- where a remote player should be drawn right now: replay their recorded path a few frames
-- behind real time, interpolating between updates so movement is smooth and steady
local REPLAY_DELAY = 10
local function replay(p, frame)
  local S = p.samples
  if not S or #S == 0 or not p.offset then return p.pos end
  local rt = frame - p.offset - REPLAY_DELAY
  local a, b
  for i = #S, 1, -1 do
    if S[i].t <= rt then a, b = S[i], S[i + 1]; break end
  end
  if not a then return S[1] end
  if not b or b.zone ~= a.zone then return a end
  -- after standing still, movement starts at most one update interval before the next sample
  local ta = math.max(a.t, b.t - 6)
  if rt <= ta then return a end
  local k = math.min(1, (rt - ta) / (b.t - ta))
  if math.abs(b.x - a.x) + math.abs(b.z - a.z) > 3 then return a end -- warp: no sliding
  return { x = a.x + (b.x - a.x) * k, y = a.y + (b.y - a.y) * k, z = a.z + (b.z - a.z) * k,
           f = a.f, s = b.s, zone = a.zone, bike = b.bike, g = b.g, battle = a.battle, sprite = b.sprite }
end

players.replay = replay
players.frameFor = frameFor
players.sheetName = sheetName

-- remote players to show right now: replayed position, sheet and walking frame
function players.collect(frame, me, remotes, game)
  local list = {}
  for id, p in pairs(remotes) do
    local v = replay(p, frame)
    if v and v.zone and not v.battle and sameSpace(me, v, game) then
      local col, row = frameFor(v.f, v.x, v.z, v.s, v.bike)
      list[#list + 1] = {
        id = id, name = p.name or "?", x = v.x, y = v.y or 0, z = v.z, f = v.f,
        frame = row * 12 + col, sheet = sheetName(v.sprite, v.bike),
        hidden = me.zone == v.zone and math.abs(v.x - me.x) < 0.6 and math.abs(v.z - me.z) < 0.6,
      }
    end
  end
  return list
end

-- name tags above remote players (used with real in-game characters)
function players.drawLabels(list, me)
  local _, _, myDepth = camera.project(me.x, me.y, me.z)
  if not myDepth then return end
  for _, it in ipairs(list) do
    if not it.hidden then
      local sx, sy, depth = camera.project(it.x, it.y, it.z)
      if sx and sx > -32 and sx < 288 and sy > -16 and sy < 230 then
        local scale = math.max(0.5, math.min(1.6, myDepth / depth))
        local label = it.name
        local w = #label * 4
        local ly = math.max(0, math.floor(sy - (players.labelHeight or 30) * scale) - 8)
        gui.drawBox(sx - w / 2 - 2, ly - 1, sx + w / 2 + 1, ly + 7, 0x00000000, 0x90000000)
        gui.pixelText(sx - w / 2, ly, label, 0xFFFFFFFF, 0x00000000)
      end
    end
  end
end

local function overlaps(a, b)
  return a.left < b.left + b.size and b.left < a.left + a.size
     and a.top < b.top + b.size and b.top < a.top + a.size
end

function players.draw(frame, me, remotes, game, sprites, spans)
  local items = {}
  local _, _, myDepth = camera.project(me.x, me.y, me.z)
  if not myDepth then return end
  local mx, my = camera.project(me.x, me.y, me.z)
  local mine = rect(mx, my, 1)
  do
    local col, row = frameFor(me.facing, me.x, me.z, me.s, me.bike)
    local sp = spans[sheetName(me.sprite, me.bike)]
    mine.spans = sp and sp[row * 12 + col + 1]
    mine.grass = me.grass
  end

  for _, p in pairs(remotes) do
    local v = replay(p, frame)
    if v and v.zone and not v.battle and sameSpace(me, v, game) then
      local onMyTile = me.zone == v.zone and math.abs(v.x - me.x) < 0.6 and math.abs(v.z - me.z) < 0.6
      local sx, sy, depth = camera.project(v.x, v.y, v.z)
      if sx and not onMyTile and sx > -32 and sx < 288 and sy > -16 and sy < 230 then
        local r = rect(sx, sy, math.max(0.5, math.min(1.6, myDepth / depth)))
        r.col, r.row = frameFor(v.f, v.x, v.z, v.s, v.bike)
        r.sheet = sprites[sheetName(v.sprite, v.bike)] or sprites.boy
        -- legs hidden only once they're standing in the grass (not while stepping in or out)
        local frac = (((v.f == 1 or v.f == 3) and v.x or v.z) - 0.5) % 1
        r.grass = v.g and (frac < 0.12 or frac > 0.88)
        r.depth, r.sx, r.sy, r.name = depth, sx, sy, p.name or "?"
        items[#items + 1] = r
      end
    end
  end

  table.sort(items, function(a, b) return a.depth > b.depth end) -- far first
  for _, r in ipairs(items) do
    local sw, sh = 14 * r.s, 5 * r.s
    if not r.grass then
      gui.drawEllipse(r.sx - sw / 2, r.sy - sh / 2 - r.s, sw, sh, 0x00000000, 0x50000000)
    end
    local behindMe = r.depth > myDepth + 1 and overlaps(r, mine)
    drawSprite(r, behindMe and mine or nil)
  end
  for _, r in ipairs(items) do
    local label = r.name
    local w = #label * 4
    local ly = math.max(0, math.floor(r.top) - 8)
    gui.drawBox(r.sx - w / 2 - 2, ly - 1, r.sx + w / 2 + 1, ly + 7, 0x00000000, 0x90000000)
    gui.pixelText(r.sx - w / 2, ly, label, 0xFFFFFFFF, 0x00000000)
  end
end

return players
