-- Test stub of the `json` module (encode/decode/array/null).
local M = {}
M.null = setmetatable({}, { __tostring = function() return "null" end })
local ARR = { __is_array = true }
function M.array(t) return setmetatable(t or {}, ARR) end

local esc = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }
local function str(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return esc[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function enc(v)
  local t = type(v)
  if v == M.null or v == nil then return "null"
  elseif t == "string" then return str(v)
  elseif t == "number" then
    if math.type(v) == "integer" then return tostring(v) end
    return string.format("%.14g", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    local mt = getmetatable(v)
    if v[1] ~= nil or (mt and mt.__is_array) then
      local o = {}
      for i = 1, #v do o[i] = enc(v[i]) end
      return "[" .. table.concat(o, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local o = {}
    for _, k in ipairs(keys) do o[#o + 1] = str(k) .. ":" .. enc(v[k]) end
    return "{" .. table.concat(o, ",") .. "}"
  end
  error("cannot encode " .. t)
end
function M.encode(v) return enc(v) end
M.dumps = M.encode

function M.decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local val
  local function err(m) error("json: " .. m .. " at " .. pos, 0) end
  local function pstr()
    local out = {}
    pos = pos + 1
    while true do
      local c = s:sub(pos, pos)
      if c == "" then err("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local n = s:sub(pos + 1, pos + 1)
        local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
        if n == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or err("bad escape")
          pos = pos + 6
          if cp >= 0xD800 and cp < 0xDC00 and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); pos = pos + 6
          end
          out[#out + 1] = utf8.char(cp)
        else out[#out + 1] = map[n] or err("bad escape"); pos = pos + 2 end
      else
        local e = s:find('["\\]', pos) or #s + 1
        out[#out + 1] = s:sub(pos, e - 1); pos = e
      end
    end
    return table.concat(out)
  end
  function val()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}; pos = pos + 1; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        ws(); if s:sub(pos, pos) ~= '"' then err("key expected") end
        local k = pstr(); ws()
        if s:sub(pos, pos) ~= ":" then err("colon expected") end
        pos = pos + 1; t[k] = val(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return t elseif d ~= "," then err("comma expected") end
      end
    elseif c == "[" then
      local t = M.array(); pos = pos + 1; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        t[#t + 1] = val(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return t elseif d ~= "," then err("comma expected") end
      end
    elseif c == '"' then return pstr()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return M.null
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if not num or num == "" then err("unexpected character") end
      pos = pos + #num
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end
  local r = val(); ws()
  if pos <= #s then err("trailing data") end
  return r
end
return M
