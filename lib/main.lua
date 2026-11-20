-- Soul Link for Pokémon Black/White (BizHawk).
-- See other players walking around in your game and play linked Nuzlockes together.
-- Load this script in BizHawk (Tools > Lua Console) with Black or White running,
-- or start everything with "Soul Link.exe".

local ROOT = _G.SOULLINK_ROOT
package.path = ROOT .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "json", "nds", "pkm", "gen4", "game", "camera", "net", "players", "actors", "actors4", "soullink", "icons", "sprites", "progress", "hud" }) do package.loaded[m] = nil end

local json = require("json")
local game = require("game")
local camera = require("camera")
local net = require("net")
local players = require("players")
local actors -- chosen once the game is known (Gen 4 and Gen 5 keep their characters differently)
local sl = require("soullink")
local hud = require("hud")

local PROFILE = os.getenv("SOULLINK_PROFILE") or "default"
local RUNTIME = ROOT .. "/runtime/" .. PROFILE
SOULLINK_MKDIR(RUNTIME)
SOULLINK_MKDIR(ROOT .. "/runtime/cache")

console.clear()
print("Soul Link: profile '" .. PROFILE .. "'")

-- wait for a Black/White game to be running
local ok, err
repeat
  ok, err = game.detect()
  if not ok then
    gui.text(4, 4, "Soul Link: " .. err)
    emu.frameadvance()
  end
until ok
actors = require(game.gen == 4 and "actors4" or "actors")
-- Gen 4 heroes are drawn smaller inside their 32 px picture: name tags sit lower
if game.gen == 4 then players.labelHeight = 24 end

game.loadRomData(ROOT .. "/runtime/cache")
require("icons").init(ROOT .. "/runtime/cache", game.code)
require("sprites").init(ROOT .. "/runtime/cache", game.code)
require("progress").init()
print("Soul Link: " .. game.title .. " (" .. game.code .. ") ready")

------------------------------------------------------------------ profile
local profilePath = ROOT .. "/profiles/" .. PROFILE .. ".json"
local profileUnreadable = false
local function loadProfile()
  local f = io.open(profilePath, "rb")
  if not f then return {} end
  local text = f:read("a"):gsub("^\239\187\191", "") -- tolerate a UTF-8 byte-order mark
  f:close()
  local p = json.decode(text)
  if type(p) ~= "table" then profileUnreadable = true; return {} end
  return p
end
local function saveProfile(p)
  if profileUnreadable then return end -- never overwrite settings we couldn't read
  SOULLINK_MKDIR(ROOT .. "/profiles")
  local f = io.open(profilePath, "wb")
  f:write(json.encode(p)); f:close()
end
local profile = loadProfile()
if not profile.id then
  math.randomseed(os.time() + math.floor(os.clock() * 1000))
  profile.id = string.format("%08x", math.random(0, 0x7FFFFFFF))
  saveProfile(profile)
end

-- your in-game trainer name (falls back to the profile name before a save is loaded)
local function myName()
  local n = game.trainerName()
  if n ~= "" then return n end
  if profile.name and profile.name ~= "" then return profile.name end
  return "Player"
end

-- the character your save actually uses (what this game has loaded)
local function realSprite()
  local g = memory.read_u8(game.A.gender)
  return g == 1 and "girl" or "boy"
end

-- the character the others see (can be overridden in the profile)
local function mySprite()
  if profile.sprite == "boy" or profile.sprite == "girl" then return profile.sprite end
  return realSprite()
end

local identity = { id = profile.id, name = myName() }
net.init(RUNTIME, identity)

local rules = {}
for k, v in pairs(sl.DEFAULT_RULES) do rules[k] = v end
for k, v in pairs(profile.rules or {}) do rules[k] = v end
sl.init(RUNTIME .. "/run.json", rules)
hud.title = myName()
hud.setup(profile.panel)

------------------------------------------------------------------ main loop
local frame = 0
local last = nil
local speed = 0
local view = { groups = {}, warnings = {}, players = 1 }
local lastZone, zoneChangedAt = nil, 0

event.onexit(function()
  os.remove(RUNTIME .. "/out_pos.txt")
  pcall(actors.clearAll)
  hud.teardown()
end)

-- Solo test mode ("Try it alone" in the launcher): a Test Buddy who walks your own path a
-- second and a half behind you, as the other character, through the same code as a real friend.
local TEST = os.getenv("SOULLINK_TEST") == "1" or profile.test == true
-- (it only walks around in the game; the panel and the links leave it out)
local buddy = TEST and { id = "test-buddy", name = "Test Buddy", samples = {}, offset = 80, test = true } or nil
local function updateBuddy(frame, me, battling)
  if not buddy then return end
  if me and frame % 6 == 0 then
    local S = buddy.samples
    S[#S + 1] = {
      t = frame, x = me.x, y = me.y, z = me.z, f = me.facing, s = speed, zone = me.zone,
      bike = me.bike or nil, g = game.inGrass(me) or nil, battle = battling or nil,
      sprite = profile.buddySprite or (realSprite() == "boy" and "girl" or "boy"),
    }
    if #S > 40 then table.remove(S, 1) end
    buddy.pos = S[#S]
  end
  if me and frame % 30 == 0 then buddy.state = sl.publicState(me) end
  net.players[buddy.id] = buddy -- the network poll drops unknown players; keep it in
end
if TEST then net.status = "testing alone" end

-- Linked play assumes every game runs at normal speed (positions are replayed by frame number),
-- so start at 100% with a frame limiter on. Fast-forward still works while held.
if not os.getenv("SOULLINK_DEV") then
  pcall(function()
    local c = client.getconfig()
    if not (c.ClockThrottle or c.SoundThrottle or c.VSyncThrottle) then c.ClockThrottle = true end
    client.speedmode(100)
    emu.limitframerate(true)
  end)
end

-- developer test hook (not used in normal play)
local devTick = nil
if os.getenv("SOULLINK_DEV") then
  devTick = dofile(os.getenv("SOULLINK_DEV_LIB"))(os.getenv("SOULLINK_DEV"))
  pcall(function() client.SetSoundOn(false) end)
end

-- optional timing of each part of the frame ("perf": true in the profile) -> runtime/<profile>/perf.txt
local PERF = profile.perf == true or os.getenv("SOULLINK_PERF") == "1"
local perf, perfOrder, tmark = {}, {}, 0
local function lap(name)
  if not PERF then return end
  local now = os.clock()
  local d = (now - tmark) * 1000
  tmark = now
  local s = perf[name]
  if not s then s = { sum = 0, max = 0, n = 0, slow = 0 }; perf[name] = s; perfOrder[#perfOrder + 1] = name end
  s.sum, s.n = s.sum + d, s.n + 1
  if d > s.max then s.max = d end
  if d > 4 then s.slow = s.slow + 1 end
end
local function perfReport(frame)
  if not PERF or frame % 300 ~= 0 then return end
  local out = { string.format("frame %d  (ms per frame: avg / worst / frames over 4 ms)", frame) }
  for _, name in ipairs(perfOrder) do
    local s = perf[name]
    out[#out + 1] = string.format("%-8s %6.2f / %6.1f / %d", name, s.sum / math.max(1, s.n), s.max, s.slow)
  end
  local f = io.open(RUNTIME .. "/perf.txt", "a")
  if f then f:write(table.concat(out, "\n"), "\n\n"); f:close() end
  perf, perfOrder = {}, {}
end

while true do
  frame = frame + 1
  lap("emulator")
  gui.clearGraphics() -- BizHawk keeps script drawings until cleared
  camera.find(frame)
  camera.update()
  lap("camera")

  if not game.located then game.locate(frame) end -- versions without known addresses
  local loaded = game.trainerName() ~= ""
  local me = loaded and game.position() or nil
  if me then
    camera.setReference(me.x, me.y, me.z)
    if last and last.zone == me.zone then
      local d = math.sqrt((me.x - last.x) ^ 2 + (me.z - last.z) ^ 2)
      if d < 2 then speed = speed * 0.7 + d * 0.3 else speed = 0 end
    end
    last = me
  end

  if frame % 60 == 0 and identity.name ~= myName() then
    identity.name = myName()
    hud.setTitle(identity.name)
  end
  lap("position")

  if me and frame % 6 == 0 then
    net.sendPos(frame, {
      zone = me.zone, x = me.x, y = me.y, z = me.z, f = me.facing,
      bike = me.bike or nil, battle = game.inBattle() or nil, g = game.inGrass(me) or nil,
      s = speed > 0.005 and math.floor(speed * 1000 + 0.5) / 1000 or 0,
      sprite = mySprite(),
    })
  end
  if frame % 6 == 3 then net.poll(frame) end
  lap("network")

  local battling = loaded and game.inBattle()
  updateBuddy(frame, me, battling)
  if TEST and net.status == "link helper not running" then net.status = "testing alone" end
  if me and frame % 10 == 5 then sl.update(frame, me, battling) end
  lap("nuzlocke")
  if me and frame % 30 == 15 then
    local pub = sl.publicState(me)
    net.sendState(pub)
    view.me = { name = myName(), state = pub }
    view.groups, view.players = sl.groups(myName(), net.players)
    view.warnings = sl.warnings(view.groups)
  end
  lap("state")

  -- right after a map change the screen is still fading in; don't draw anyone yet
  if me and me.zone ~= lastZone then lastZone, zoneChangedAt = me.zone, frame end
  if me and not battling and camera.ready() then
    me.sprite, me.s, me.grass = mySprite(), speed, game.inGrass(me)
    local realOk = false
    if profile.players ~= "drawn" then
      -- other players as real characters drawn by the game; name tags on top
      local list = players.collect(frame, me, net.players, game)
      realOk = actors.update(frame, me, list, players.sheetName(realSprite(), me.bike))
      if realOk and frame - zoneChangedAt > 45 then players.drawLabels(list, me) end
    end
    if not realOk and frame - zoneChangedAt > 45 then
      players.draw(frame, me, net.players, game, game.sprites, game.spriteSpans)
    end
  end
  lap("players")

  -- the pop-out window only needs a few redraws a second; the docked panel is per frame
  if profile.panel == "docked" or frame % 15 == 0 then
    hud.draw({
      status = net.status, remotes = net.players, groups = view.groups, me = view.me,
      players = view.players, warnings = view.warnings, events = sl.events,
      started = sl.run().started,
    })
  elseif profile.panel ~= "docked" then
    hud.tick(frame) -- the Pokémon's battle animations
  end
  if hud.closed then
    gui.pixelText(2, 2, "Soul Link panel closed - press P to reopen", 0xFFFFFFFF, 0xA0000000)
    if input.get()["P"] then hud.reopen() end
  end
  lap("panel")

  if devTick then devTick() end
  perfReport(frame)
  lap("dev")
  emu.frameadvance()
end
