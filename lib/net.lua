-- Talks to the link helper ("Soul Link.exe -Mode host|join") through small files in the runtime folder.
-- The game never waits on the network: it writes its own state and reads whatever
-- the helper last received, so a slow connection can't make the emulator stutter.
local json = require("json")
local game = require("game")

local net = {}
local dir, me
local lastPosLine, lastStateLine = nil, nil
local lastPosWrite = -1000
local inboxRaw = nil
net.status = "link helper not running"
net.players = {} -- id -> { name, pos, state, seen }
-- players from another region, left out: id -> "Name (Black 2)". Only games whose areas line up can
-- be linked (Black/White, Black 2/White 2, Diamond/Pearl/Platinum, HeartGold/SoulSilver), so mixed
-- games aren't supported (the host's link turns them away too; this is for anything that gets past it).
net.excluded = {}
local GAME_NAMES = { B = "Black", W = "White", B2 = "Black 2", W2 = "White 2",
  D = "Diamond", P = "Pearl", Pt = "Platinum", HG = "HeartGold", SS = "SoulSilver" }
local REGION = { B = "unova1", W = "unova1", B2 = "unova2", W2 = "unova2",   -- (same as game.region)
  D = "sinnoh", P = "sinnoh", Pt = "sinnoh", HG = "johto", SS = "johto" }
local function myRegion() return game.region or REGION[game.version] end

local function writeAtomic(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(text); f:close()
  os.remove(path)
  return os.rename(tmp, path)
end

function net.init(runtimeDir, identity)
  dir, me = runtimeDir, identity
end

-- position: written ~10x/second while it changes, once a second otherwise (keepalive).
-- Each update carries this game's frame number so the others can replay the movement smoothly.
function net.sendPos(frame, d)
  local key = json.encode({ name = me.name, d = d })
  if key ~= lastPosLine or frame - lastPosWrite >= 60 then
    d.fr = frame
    local line = json.encode({ t = "pos", id = me.id, name = me.name, d = d })
    d.fr = nil
    writeAtomic(dir .. "/out_pos.txt", "pos " .. me.id .. " " .. line .. "\n")
    lastPosLine, lastPosWrite = key, frame
  end
end

-- keep a short history of positions per player, stamped with the sender's frame number
local function addSample(p, d, frame)
  if not d.fr then return end
  local S = p.samples
  if not S or (S[#S] and d.fr < S[#S].t - 30) then -- first sample, or the sender restarted
    S = {}; p.samples = S; p.offset = nil
  end
  if S[#S] and S[#S].t == d.fr then return end
  S[#S + 1] = { t = d.fr, x = d.x, y = d.y, z = d.z, f = d.f, s = d.s, zone = d.zone,
                bike = d.bike, g = d.g, battle = d.battle, sprite = d.sprite }
  if #S > 16 then table.remove(S, 1) end
  local delay = frame - d.fr
  if not p.offset or delay < p.offset then p.offset = delay else p.offset = p.offset + 0.05 end
end

-- full state (party, encounters...): written only when it changes
function net.sendState(d)
  local line = json.encode({ t = "state", id = me.id, name = me.name, d = d })
  if line ~= lastStateLine then
    writeAtomic(dir .. "/out_state.txt", "state " .. me.id .. " " .. line .. "\n")
    lastStateLine = line
  end
end

------------------------------------------------------------------ checking what others send
-- Everything from other players is checked before it's used: only known fields, of the right type
-- and in a sane range. A broken or hostile message can't crash the script, slow the panel down,
-- or put odd values into the game's memory (positions and frames end up there).
local MAX_PLAYERS = 16
local function num(v, lo, hi)
  if type(v) ~= "number" or v ~= v or v < lo or v > hi then return nil end
  return v
end
local function int(v, lo, hi)
  v = num(v, lo, hi)
  return v and math.floor(v) or nil
end
local function bool(v) return v == true or nil end
-- printable text, at most n characters (bad UTF-8 becomes "?")
local function text(v, n)
  if type(v) ~= "string" then return nil end
  local s = v:sub(1, n * 4):gsub("%c", "")
  if not utf8.len(s) then s = s:gsub("[\128-\255]", "?") end
  if utf8.len(s) > n then s = s:sub(1, utf8.offset(s, n + 1) - 1) end
  return s
end
local function key(v, n)
  if type(v) ~= "string" or #v > (n or 16) or not v:match("^[%w_%-]+$") then return nil end
  return v
end
local function oneOf(v, set) return set[v] and v or nil end
local SPRITES = { boy = true, girl = true }
local STATES = { pending = true, caught = true, failed = true, dead = true }
local GAMES = {}
for v in pairs(GAME_NAMES) do GAMES[v] = true end

local function cleanPos(d)
  if type(d) ~= "table" then return nil end
  local p = {
    zone = int(d.zone, 0, 65535), x = num(d.x, -100000, 100000), y = num(d.y, -100000, 100000),
    z = num(d.z, -100000, 100000), f = int(d.f, 0, 3) or 2, s = num(d.s, 0, 10) or 0,
    bike = bool(d.bike), battle = bool(d.battle), g = bool(d.g), sprite = oneOf(d.sprite, SPRITES) or "boy",
    fr = int(d.fr, 0, 2 ^ 40),
  }
  if not (p.zone and p.x and p.y and p.z) then return nil end
  return p
end

local function cleanMon(m)
  if type(m) ~= "table" then return nil end
  return { pid = key(m.pid), sp = int(m.sp, 0, 1023) or 0, lv = int(m.lv, 0, 255), hp = int(m.hp, 0, 65535) or 0,
    mhp = int(m.mhp, 0, 65535) or 0, nick = text(m.nick, 12), area = key(m.area), egg = bool(m.egg),
    sh = bool(m.sh), f = bool(m.f) }
end

local function cleanState(d)
  if type(d) ~= "table" then return nil end
  local s = { badges = int(d.badges, 0, 8) or 0, area = key(d.area), started = bool(d.started),
    game = oneOf(d.game, GAMES), party = {}, enc = {}, graves = nil }
  if type(d.party) == "table" then
    for i = 1, 6 do
      local m = d.party[i] and cleanMon(d.party[i])
      if m then s.party[#s.party + 1] = m end
    end
  end
  if type(d.enc) == "table" then
    local n = 0
    for k, e in pairs(d.enc) do
      k = key(k)
      if k and type(e) == "table" and STATES[e.st] and n < 300 then
        s.enc[k] = { sp = int(e.sp, 0, 1023) or 0, st = e.st, pid = key(e.pid), sh = bool(e.sh), f = bool(e.f),
          t = int(e.t, 0, 2 ^ 40), was = int(e.was, 0, 1023) }
        n = n + 1
      end
    end
  end
  if type(d.graves) == "table" then
    s.graves = {}
    local first = math.max(1, #d.graves - 299)
    for i = first, #d.graves do
      local gv = d.graves[i]
      if type(gv) == "table" then
        s.graves[#s.graves + 1] = { sp = int(gv.sp, 0, 1023) or 0, nick = text(gv.nick, 12), lv = int(gv.lv, 0, 255),
          area = key(gv.area), at = key(gv.at), t = int(gv.t, 0, 2 ^ 40) or 0, sh = bool(gv.sh), f = bool(gv.f) }
      end
    end
  end
  return s
end
net.cleanPos, net.cleanState = cleanPos, cleanState

-- read what the helper has received; returns true when something changed
function net.poll(frame)
  local f = io.open(dir .. "/in.json", "rb")
  if not f then
    -- the helper swaps the file in place several times a second; only give up after a while
    net.missing = (net.missing or 0) + 1
    if net.missing > 20 then net.status = "link helper not running" end
    return false
  end
  net.missing = 0
  local raw = f:read("a"); f:close()
  if raw == inboxRaw then return false end
  inboxRaw = raw
  local inbox = json.decode(raw)
  if type(inbox) ~= "table" then return false end
  net.status = text(inbox.status, 60) or ""
  local alive, count, out = {}, 0, {}
  for _, m in ipairs(type(inbox.msgs) == "table" and inbox.msgs or {}) do
    local id = type(m) == "table" and key(m.id, 32)
    local st = id and m.t == "state" and cleanState(m.d) or nil
    if st and st.game and myRegion() then
      if REGION[st.game] ~= myRegion() then
        local nm = text(m.name, 16)
        net.excluded[id] = ((nm and nm ~= "") and nm or "?") .. " (" .. GAME_NAMES[st.game] .. ")"
        net.players[id] = nil
      else
        net.excluded[id] = nil
      end
    end
    if id and net.excluded[id] then
      out[id] = true
    elseif id and id ~= me.id and (m.t == "pos" or m.t == "state") then
      local p = net.players[id]
      if not p and count < MAX_PLAYERS then
        p = { id = id }
        net.players[id] = p
      end
      if p then
        if not alive[id] then count = count + 1 end
        p.name = text(m.name, 16) or p.name or "?"
        if p.name == "" then p.name = "?" end
        if m.t == "pos" then
          local d = cleanPos(m.d)
          if d then
            p.pos = d; p.seen = frame
            addSample(p, d, frame)
          end
        else
          p.state = st or p.state
        end
        alive[id] = true
      end
    end
  end
  for id in pairs(net.players) do
    if not alive[id] then net.players[id] = nil end
  end
  for id in pairs(net.excluded) do
    if not out[id] then net.excluded[id] = nil end
  end
  return true
end

return net
