-- Soul Link / Nuzlocke rules: tracks your encounters, catches and deaths, links them with the
-- other players' encounters in the same area, and works out which rules are being broken.
local json = require("json")
local game = require("game")
local net = require("net")

local sl = {}

sl.DEFAULT_RULES = {
  dupes = true,        -- dupes clause: an evolution family you already have doesn't use up the area
  gifts = true,        -- gift/static Pokémon received outside battle count as that area's encounter
  partyMatch = true,   -- linked Pokémon must be in everyone's party together
  typeRule = false,    -- no two Pokémon in your party may share a primary type
}

local run, runPath, rules
local battle = { active = false }
local events = {}
local lastPos


local function hex(pid) return string.format("%08x", pid) end
-- how a Pokémon looks: shiny, female (nil when not, to keep the saved run small)
local function looks(m) return m.shiny or nil, m.female or nil end
local function now() return os.time() end

local function save()
  local f = io.open(runPath .. ".tmp", "wb")
  if not f then return end
  f:write(json.encode(run)); f:close()
  os.remove(runPath)
  os.rename(runPath .. ".tmp", runPath)
end

local function event(text, kind)
  events[#events + 1] = { text = text, kind = kind or "info", t = now() }
  if #events > 6 then table.remove(events, 1) end
  print("Soul Link: " .. text)
end
sl.events = events

function sl.init(path, ruleSettings)
  runPath = path
  rules = ruleSettings
  local f = io.open(path, "rb")
  if f then run = json.decode(f:read("a")); f:close() end
  run = run or {}
  run.encounters = run.encounters or {} -- areaKey -> { sp, pid, st, kind, t }
  run.known = run.known or {}           -- pid hex -> areaKey | "extra" | "egg"
  run.dead = run.dead or {}             -- pid hex -> true
  run.graves = run.graves or {}         -- { sp, nick, lv, area (caught), at (died), t } newest last
end

function sl.rules() return rules end
function sl.run() return run end

function sl.areaName(key)
  if key == "starter" then return "Starter" end
  return game.locationName(tonumber(key) or -1)
end

local function currentArea(pos)
  local zi = pos and game.zoneInfo(pos.zone)
  return zi and tostring(zi.loc) or nil
end

local function ownsFamily(fam)
  for _, e in pairs(run.encounters) do
    if (e.st == "caught" or e.st == "dead") and game.family(e.sp) == fam then return true end
  end
  return false
end

-- PC boxes: 24 boxes x 30 slots, 136-byte box format, starting 0x400 into the save block in RAM
local function inBoxes(pid)
  if game.inBoxes then return game.inBoxes(pid) end   -- (Gen 4 keeps its boxes differently)
  local base = game.A.boxes
  local p1, p2, p3, p4 = pid & 0xFF, (pid >> 8) & 0xFF, (pid >> 16) & 0xFF, (pid >> 24) & 0xFF
  for box = 0, 23 do
    -- one read per box (30 slots) instead of 30 separate reads
    local b = memory.read_bytes_as_array(base + box * 0x1000, 30 * 136)
    for slot = 0, 29 do
      local i = slot * 136 + 1
      if b[i] == p1 and b[i + 1] == p2 and b[i + 2] == p3 and b[i + 3] == p4 then return true end
    end
  end
  return false
end

local function onWildBattle(area, foes)
  local first = foes[1]
  if not area or not first or first.species <= 0 then return end
  if not run.started then return end -- the Nuzlocke starts once you have Poké Balls
  if run.encounters[area] then return end
  if rules.dupes and ownsFamily(game.family(first.species)) then
    event("Dupe: " .. game.speciesName(first.species) .. " on " .. sl.areaName(area) .. " doesn't count", "info")
    return
  end
  local sh, f = looks(first)
  run.encounters[area] = { sp = first.species, pid = hex(first.pid), st = "pending", kind = "wild", t = now(), sh = sh, f = f }
  event("First encounter on " .. sl.areaName(area) .. ": " .. game.speciesName(first.species), "info")
  save()
end

local function resolvePending(pos, party)
  local moved = battle.endPos and pos and (pos.zone ~= battle.endPos.zone
    or math.abs(pos.x - battle.endPos.x) + math.abs(pos.z - battle.endPos.z) >= 1)
  for area, e in pairs(run.encounters) do
    if e.st == "pending" then
      local caught = false
      for _, m in ipairs(party) do if hex(m.pid) == e.pid then caught = true end end
      if not caught and moved and inBoxes(tonumber(e.pid, 16)) then caught = true end
      if caught then
        e.st = "caught"
        run.known[e.pid] = area
        event("Caught " .. game.speciesName(e.sp) .. " on " .. sl.areaName(area), "good")
        save()
      elseif moved then
        e.st = "failed"
        event("Missed the " .. sl.areaName(area) .. " encounter (" .. game.speciesName(e.sp) .. ")", "bad")
        save()
      end
    end
  end
end

local function scanParty(pos, party)
  for _, m in ipairs(party) do
    local id = hex(m.pid)
    if m.isEgg then
      run.known[id] = run.known[id] or "egg"
    elseif not run.known[id] then
      local area = currentArea(pos)
      local pending
      for k, e in pairs(run.encounters) do if e.pid == id and e.st == "pending" then pending = k end end
      if pending then
        -- handled by resolvePending
      elseif not run.encounters.starter and next(run.known) == nil then
        local sh, f = looks(m)
        run.encounters.starter = { sp = m.species, pid = id, st = "caught", kind = "starter", t = now(), sh = sh, f = f }
        run.known[id] = "starter"
        event("Starter: " .. game.speciesName(m.species), "good")
        save()
      elseif not run.started then
        run.known[id] = "pre" -- received before the Nuzlocke started; not linked
        save()
      elseif rules.gifts and area and not run.encounters[area] then
        local sh, f = looks(m)
        run.encounters[area] = { sp = m.species, pid = id, st = "caught", kind = "gift", t = now(), sh = sh, f = f }
        run.known[id] = area
        event("Received " .. game.speciesName(m.species) .. " on " .. sl.areaName(area), "good")
        save()
      else
        run.known[id] = "extra"
        event(game.speciesName(m.species) .. " isn't a first encounter, so it isn't linked", "bad")
        save()
      end
    end
    if not m.isEgg then
      local e = run.known[id] and run.encounters[run.known[id]]
      if e and e.pid == id then
        -- (runs from before shiny/female were kept: fill them in)
        if e.f == nil and e.sh == nil then e.sh, e.f = looks(m) end
        -- it evolved: the link shows what it is now (and remembers what was caught)
        if m.species > 0 and m.species ~= e.sp then
          event(game.speciesName(e.sp) .. " evolved into " .. game.speciesName(m.species) .. "!", "good")
          e.caughtAs = e.caughtAs or e.sp
          e.sp = m.species
          save()
        end
      end
    end
    if m.hp == 0 and not m.isEgg and not run.dead[id] then
      run.dead[id] = true
      local area = run.known[id]
      local e = area and run.encounters[area]
      if e and e.pid == id then e.st = "dead" end
      run.graves[#run.graves + 1] = {
        sp = m.species, nick = m.nickname ~= "" and m.nickname or nil, lv = m.level,
        area = area, at = currentArea(pos), t = now(), sh = m.shiny or nil, f = m.female or nil,
      }
      event((m.nickname ~= "" and m.nickname or game.speciesName(m.species)) .. " fainted, it's dead", "bad")
      save()
    end
  end
end

-- call every few frames
function sl.update(frame, pos, inBattle)
  local party = game.party()
  if not party then return end
  if not run.started and not inBattle and game.hasPokeBalls() then
    run.started = true
    event("You have Poké Balls: the Nuzlocke has started!", "good")
    save()
  end
  if inBattle and not battle.active then
    battle = { active = true, start = frame, area = currentArea(lastPos or pos), read = false }
  end
  if inBattle and battle.active and not battle.read and frame - battle.start > 20 then
    local foes = game.foes()
    if #foes > 0 then
      battle.read = true
      battle.trainer = game.trainerBattle()
      if not battle.trainer then onWildBattle(battle.area, foes) end
    end
  end
  if not inBattle then
    if battle.active then
      battle.active = false
      battle.endPos = pos and { zone = pos.zone, x = pos.x, z = pos.z }
    end
    scanParty(pos, party)
    resolvePending(pos, party)
    lastPos = pos
  end
  sl.party = party
end

-- what the other players get to see
function sl.publicState(pos)
  local party = {}
  for _, m in ipairs(sl.party or {}) do
    party[#party + 1] = {
      pid = hex(m.pid), sp = m.species, lv = m.level, hp = m.hp, mhp = m.maxHp,
      nick = m.nickname, area = run.known[hex(m.pid)], egg = m.isEgg or nil,
      sh = m.shiny or nil, f = m.female or nil,
    }
  end
  local enc = {}
  for k, e in pairs(run.encounters) do
    enc[k] = { sp = e.sp, st = e.st, pid = e.pid, sh = e.sh, f = e.f, t = e.t, was = e.caughtAs }
  end
  return { party = party, enc = enc, badges = game.badgeCount(), area = currentArea(pos), started = run.started or nil,
    graves = #run.graves > 0 and run.graves or nil, game = game.version }
end

-- link groups across all players: areaKey -> { members = { {name, sp, st, inParty}... }, status }
function sl.groups(myName, remotes)
  local groups, order = {}, {}
  -- a link's time is its first encounter by anyone, so link numbers stay put as others catch
  local function add(key, member, t)
    if not groups[key] then groups[key] = { key = key, members = {}, t = math.huge }; order[#order + 1] = key end
    table.insert(groups[key].members, member)
    if t and t < groups[key].t then groups[key].t = t end
  end
  -- players from another region are left out (net.lua): mixed games aren't supported
  sl.mixed = nil
  for _, who in pairs(net.excluded) do
    sl.mixed = sl.mixed or {}
    sl.mixed[#sl.mixed + 1] = who
  end
  if sl.mixed then table.sort(sl.mixed) end
  local myParty = {}
  for _, m in ipairs(sl.party or {}) do myParty[hex(m.pid)] = true end
  for k, e in pairs(run.encounters) do
    add(k, { me = true, name = myName, sp = e.sp, st = e.st, pid = e.pid, sh = e.sh, f = e.f, was = e.caughtAs,
      inParty = myParty[e.pid] or false }, e.t)
  end
  local players = 1
  for _, p in pairs(remotes) do
    local st = p.state
    if st and st.enc and not p.test then
      players = players + 1
      local inParty = {}
      for _, m in ipairs(st.party or {}) do if m.pid then inParty[m.pid] = true end end
      for k, e in pairs(st.enc) do
        add(k, { name = p.name, sp = e.sp, st = e.st, pid = e.pid, sh = e.sh, f = e.f, was = e.was,
          inParty = inParty[e.pid] or false }, tonumber(e.t))
      end
    end
  end
  for _, k in ipairs(order) do
    local g = groups[k]
    local status = "alive"
    if #g.members < players then status = "waiting" end
    for _, m in ipairs(g.members) do
      if m.st == "pending" and status == "alive" then status = "waiting" end
    end
    for _, m in ipairs(g.members) do if m.st == "failed" then status = "broken" end end
    for _, m in ipairs(g.members) do if m.st == "dead" then status = "dead" end end
    g.status = status
  end
  table.sort(order, function(a, b)
    if a == "starter" then return true elseif b == "starter" then return false end
    local ta, tb = groups[a].t, groups[b].t
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  for _, k in ipairs(order) do if groups[k].t == math.huge then groups[k].t = nil end end -- (sent as JSON)
  local list = {}
  for _, k in ipairs(order) do list[#list + 1] = groups[k] end
  return list, players
end

-- rule problems with your current party
function sl.warnings(groups)
  local out = {}
  local byKey = {}
  for _, g in ipairs(groups) do byKey[g.key] = g end
  local seenTypes = {}
  if sl.mixed then
    -- (Black/White and Black 2/White 2 have different areas, so they can't be linked)
    out[#out + 1] = { lvl = "bad", t = "Mixed games aren't supported: " .. table.concat(sl.mixed, ", ")
      .. (#sl.mixed == 1 and " is" or " are") .. " left out." }
  end
  for _, m in ipairs(sl.party or {}) do
    if not m.isEgg then
      local id = hex(m.pid)
      local nick = m.nickname ~= "" and m.nickname or game.speciesName(m.species)
      local area = run.known[id]
      local g = area and byKey[area]
      local function bad(t) out[#out + 1] = { t = t, lvl = "bad" } end
      local function info(t) out[#out + 1] = { t = t, lvl = "info" } end
      if run.dead[id] then
        bad(nick .. " is dead: box or release it")
      elseif area == "extra" then
        bad(nick .. " isn't a linked encounter")
      elseif g then
        if g.status == "dead" then
          local who
          for _, mem in ipairs(g.members) do if mem.st == "dead" and not mem.me then who = mem.name end end
          bad(nick .. " must be boxed: " .. (who and (who .. "'s link") or "its link") .. " died")
        elseif g.status == "broken" then
          bad(nick .. " can't be used: a linked catch was missed")
        elseif g.status == "waiting" then
          info(nick .. ": waiting for the others' catch")
        elseif rules.partyMatch then
          for _, mem in ipairs(g.members) do
            if not mem.me and not mem.inParty then
              bad(mem.name .. " needs " .. game.speciesName(mem.sp) .. " in their party")
            end
          end
        end
      end
      if rules.typeRule then
        local t1 = game.types(m.species)
        if t1 then
          if seenTypes[t1] then
            bad(nick .. " shares a primary type with " .. seenTypes[t1])
          else
            seenTypes[t1] = nick
          end
        end
      end
    end
  end
  return out
end

return sl
