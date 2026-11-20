-- Minimal JSON encode/decode (enough for Soul Link state exchange).
local json = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

local function enc(v, out)
  local tv = type(v)
  if tv == "nil" then out[#out + 1] = "null"
  elseif tv == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "0"
    elseif math.type(v) == "integer" then out[#out + 1] = tostring(v)
    else out[#out + 1] = string.format("%.4f", v):gsub("%.?0+$", "") end
  elseif tv == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
      return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif tv == "table" then
    local arr, n = isArray(v)
    if arr and (n > 0 or next(v) == nil) then
      out[#out + 1] = "["
      for i = 1, n do
        if i > 1 then out[#out + 1] = "," end
        enc(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        if not first then out[#out + 1] = "," end
        first = false
        enc(k, out); out[#out + 1] = ":"; enc(val, out)
      end
      out[#out + 1] = "}"
    end
  else out[#out + 1] = "null" end
end

function json.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or #s + 1
end

local decodeValue

local function decodeString(s, i)
  local parts, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("unterminated string") end
    if c == '"' then return table.concat(parts), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j + 6, j + 7) == "\\u" then
          local lo = tonumber(s:sub(j + 8, j + 11), 16)
          cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
          j = j + 6
        end
        parts[#parts + 1] = utf8.char(cp)
        j = j + 6
      else
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        parts[#parts + 1] = map[e] or e
        j = j + 2
      end
    else
      local k = s:find('[\\"]', j)
      if not k then error("unterminated string") end
      parts[#parts + 1] = s:sub(j, k - 1)
      j = k
    end
  end
end

decodeValue = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      local k
      k, i = decodeString(s, skip(s, i))
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
      t[k], i = decodeValue(s, i + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return t, i + 1 end
      if d ~= "," then error("expected , at " .. i) end
      i = i + 1
    end
  elseif c == "[" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      t[#t + 1], i = decodeValue(s, i)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return t, i + 1 end
      if d ~= "," then error("expected , at " .. i) end
      i = i + 1
    end
  elseif c == '"' then return decodeString(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then error("bad value at " .. i) end
    return tonumber(num), i + #num
  end
end

function json.decode(s)
  local ok, v = pcall(decodeValue, s, 1)
  if ok then return v end
  return nil, v
end

return json
