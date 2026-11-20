-- json: pure-Lua JSON codec (decode/encode/array/dumps/null/empty_array).
local M = {}

local null = setmetatable({}, { __tostring = function() return "null" end, __name = "json.null" })
M.null = null

local array_mt = { __jsontype = "array", __name = "json.array" }
M.array_mt = array_mt
M.empty_array = setmetatable({}, array_mt)

function M.array(t)
  return setmetatable(t or {}, array_mt)
end

local esc = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_str(s)
  return '"' .. s:gsub('[%c"\\\127]', function(c)
    return esc[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local mt = getmetatable(t)
  if mt == array_mt or (mt and mt.__jsontype == "array") then return true end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return false end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local encode_value

local function encode_table(t, out, seen)
  if t == null then out[#out + 1] = "null"; return end
  if seen[t] then error("cannot encode circular reference") end
  seen[t] = true
  if is_array(t) then
    out[#out + 1] = "["
    for i = 1, #t do
      if i > 1 then out[#out + 1] = "," end
      encode_value(t[i], out, seen)
    end
    out[#out + 1] = "]"
  else
    local keys = {}
    for k in pairs(t) do
      local tk = type(k)
      if tk ~= "string" and tk ~= "number" then error("cannot encode table key of type " .. tk) end
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
      if i > 1 then out[#out + 1] = "," end
      out[#out + 1] = escape_str(tostring(k))
      out[#out + 1] = ":"
      encode_value(t[k], out, seen)
    end
    out[#out + 1] = "}"
  end
  seen[t] = nil
end

encode_value = function(v, out, seen)
  local tv = type(v)
  if tv == "nil" then out[#out + 1] = "null"
  elseif tv == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("cannot encode non-finite number") end
    if math.type(v) == "integer" then out[#out + 1] = string.format("%d", v)
    elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.14g", v) end
  elseif tv == "string" then out[#out + 1] = escape_str(v)
  elseif tv == "table" then encode_table(v, out, seen)
  else error("cannot encode value of type " .. tv) end
end

function M.encode(v)
  local out = {}
  encode_value(v, out, {})
  return table.concat(out)
end
M.dumps = M.encode

-- decoding ------------------------------------------------------------
local function derr(s, i, msg)
  error(string.format("json: %s at position %d", msg, i), 0)
end

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or #s + 1
end

local decode_value

local function decode_string(s, i)
  local out, j = {}, i + 1
  while true do
    local a, b = s:find('["\\%c]', j)
    if not a then derr(s, i, "unterminated string") end
    local c = s:sub(a, a)
    if a > j then out[#out + 1] = s:sub(j, a - 1) end
    if c == '"' then return table.concat(out), a + 1 end
    if c ~= "\\" then derr(s, a, "control character in string") end
    local e = s:sub(a + 1, a + 1)
    local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
    if map[e] then
      out[#out + 1] = map[e]; j = a + 2
    elseif e == "u" then
      local h = s:match("^%x%x%x%x", a + 2)
      if not h then derr(s, a, "bad unicode escape") end
      local cp = tonumber(h, 16)
      j = a + 6
      if cp >= 0xD800 and cp <= 0xDBFF then
        local l = s:match("^\\u(%x%x%x%x)", j)
        local lo = l and tonumber(l, 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          j = j + 6
        else
          derr(s, a, "unpaired surrogate")
        end
      elseif cp >= 0xDC00 and cp <= 0xDFFF then
        derr(s, a, "unpaired surrogate")
      end
      out[#out + 1] = utf8.char(cp)
    else
      derr(s, a, "bad escape")
    end
  end
end

decode_value = function(s, i, depth)
  if depth > 200 then derr(s, i, "nesting too deep") end
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then derr(s, i, "expected string key") end
      local k
      k, i = decode_string(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then derr(s, i, "expected ':'") end
      local v
      v, i = decode_value(s, i + 1, depth + 1)
      t[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return t, i + 1 end
      if d ~= "," then derr(s, i, "expected ',' or '}'") end
      i = skip(s, i + 1)
    end
  elseif c == "[" then
    local t, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return setmetatable(t, array_mt), i + 1 end
    while true do
      local v
      v, i = decode_value(s, i, depth + 1)
      n = n + 1
      t[n] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return t, i + 1 end
      if d ~= "," then derr(s, i, "expected ',' or ']'") end
      i = i + 1
    end
  elseif c == '"' then
    return decode_string(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return null, i + 4
  else
    local num = s:match("^-?%d+%.%d+[eE][+-]?%d+", i) or s:match("^-?%d+[eE][+-]?%d+", i)
      or s:match("^-?%d+%.%d+", i) or s:match("^-?%d+", i)
    if num then
      if num:match("^-?0%d") then derr(s, i, "bad number") end
      local v
      if num:match("^-?%d+$") then v = math.tointeger(tonumber(num)) or tonumber(num) else v = tonumber(num) end
      return v, i + #num
    end
    derr(s, i, i > #s and "unexpected end of input" or "unexpected character")
  end
end

function M.decode(s)
  if type(s) ~= "string" then error("json: decode expects a string", 2) end
  local v, i = decode_value(s, 1, 0)
  i = skip(s, i)
  if i <= #s then derr(s, i, "trailing garbage") end
  return v
end

return M
