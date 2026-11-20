-- Uses the game's own 3D camera so other players are drawn at the right spot on screen.
-- The NitroSystem global state holds a projection matrix followed by the camera matrix.
-- It is only the field camera part of each frame, so the last valid one is kept.
local camera = {}

local projAddr, camAddr
local cam, proj
local lastScan = -1000

local function s32(a) return memory.read_s32_le(a) end

local function looksLikeProjection(a)
  -- perspective: [a,0,0,0, 0,b,0,0, 0,0,c,-1, 0,0,d,0] in 20.12 fixed point
  if s32(a + 44) ~= -4096 or s32(a + 60) ~= 0 then return false end
  for _, k in ipairs({ 1, 2, 3, 4, 6, 7, 8, 9, 12, 13 }) do
    if s32(a + k * 4) ~= 0 then return false end
  end
  local p00, p11 = s32(a), s32(a + 20)
  return p00 > 2000 and p00 < 40000 and p11 > 2000 and p11 < 40000
end

local function scan(from, to)
  for a = from, to, 4 do
    if looksLikeProjection(a) then return a end
  end
end

-- Gen 4 (Diamond/Pearl/Platinum/HGSS) never keeps its projection in RAM: only the camera
-- (view) matrix, a rotation about the x axis. Its projection is set up so the overworld is
-- pixel-exact at the player's depth, so points are scaled by (player depth / their depth).
local gen4, refDepth = false, nil
local function looksLikeView(a)
  if s32(a) ~= 4096 or s32(a + 4) ~= 0 or s32(a + 8) ~= 0 or s32(a + 12) ~= 0 or s32(a + 24) ~= 0 then return false end
  local c, s = s32(a + 16), s32(a + 20)
  return math.abs(c * c + s * s - 4096 * 4096) < 4096 * 64 and c ~= 4096 and math.abs(c) > 100
end
local function scanView(from, to)
  for base = from, to - 1, 0x8000 do
    local b = memory.read_bytes_as_array(base, 0x8000 + 64)
    for i = 1, 0x8000, 4 do
      if b[i] == 0 and b[i + 1] == 0x10 and b[i + 2] == 0 and b[i + 3] == 0 and looksLikeView(base + i - 1) then
        return base + i - 1
      end
    end
  end
end

function camera.find(frame)
  if projAddr or camAddr then return true end
  if frame - lastScan < 60 then return false end
  lastScan = frame
  local game = package.loaded.game
  if game and game.gen == 4 then
    gen4 = true
    local hint = game.layout and game.layout.camera
    local a = (hint and looksLikeView(hint) and hint) or scanView(0x02180000, 0x02200000)
    if a then camAddr = a; return true end
    return false
  end
  -- known spot for Black (English) first, then a wider search
  local a = (looksLikeProjection(0x02148B54) and 0x02148B54)
    or scan(0x02147000, 0x0214B000)
    or scan(0x02140000, 0x02160000)
  if a then
    projAddr, camAddr = a, a + 0x44
    return true
  end
  return false
end

-- The DS shows 3D one frame after it was set up, so the picture on screen right now was
-- drawn with the camera read on the previous frame. Drawing with that one keeps other
-- players locked to the scenery while the screen scrolls.
local latest
local history = {} -- last few frames' cameras, newest first
camera.delay = 1   -- frames between the game setting up the camera and the picture showing it (measured)
function camera.update()
  if not camAddr then return end
  local m = {}
  for i = 0, 11 do m[i] = s32(camAddr + i * 4) / 4096 end
  if gen4 then
    if looksLikeView(camAddr) then latest = m end
  elseif math.abs(m[4] - 1) > 0.001 or math.abs(m[0] - 1) > 0.001 then
    local p00, p11 = s32(projAddr) / 4096, s32(projAddr + 20) / 4096
    if p00 > 0.1 and p11 > 0.1 and s32(projAddr + 44) == -4096 then
      latest, proj = m, { p00, p11 }
    end
  end
  if latest then
    table.insert(history, 1, latest)
    if #history > 6 then history[#history] = nil end
    cam = history[math.min(#history, camera.delay + 1)]
  end
end

function camera.ready() return cam ~= nil and (not gen4 or refDepth ~= nil) end

local function view(tx, ty, tz)
  local wx, wy, wz = tx * 16, ty * 16, tz * 16
  local m = cam
  return wx * m[0] + wy * m[3] + wz * m[6] + m[9],
         wx * m[1] + wy * m[4] + wz * m[7] + m[10],
         wx * m[2] + wy * m[5] + wz * m[8] + m[11]
end

-- Gen 4: the local player's position, whose depth is drawn 1:1 (call every frame)
function camera.setReference(tx, ty, tz)
  if not gen4 or not cam then return end
  local _, _, cz = view(tx, ty, tz)
  if -cz > 1 then refDepth = -cz end
end

-- tile coordinates -> top-screen pixel coordinates + depth
function camera.project(tx, ty, tz)
  if not cam then return nil end
  local cx, cy, cz = view(tx, ty, tz)
  local w = -cz
  if w <= 1 then return nil end
  if gen4 then
    if not refDepth then return nil end
    local s = refDepth / w
    return 128 + cx * s, 96 - cy * s, w
  end
  return 128 + (cx * proj[1] / w) * 128, 96 - (cy * proj[2] / w) * 96, w
end

function camera.reset() cam, latest, history = nil, nil, {} end

function camera.info()
  local s = string.format("proj %s cam %s", projAddr and string.format("%08X", projAddr) or "-",
    camAddr and string.format("%08X", camAddr) or "-")
  if cam then
    local t = {}
    for i = 0, 11 do t[#t + 1] = string.format("%.2f", cam[i]) end
    s = s .. " m=" .. table.concat(t, " ")
  end
  return s
end

return camera
