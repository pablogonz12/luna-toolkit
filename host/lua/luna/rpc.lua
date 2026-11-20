-- RPC dispatch: validated page requests -> registry functions -> JSON string replies.
local json = require("json")
local polyfill = require("luna.polyfill")
local log = require("luna.log")

local M = {}

local function is_null(v) return json.null ~= nil and v == json.null end

local function is_array(t)
  if t[1] ~= nil then return true end
  local mt = getmetatable(t)
  return type(mt) == "table" and (mt.__is_array == true or mt.array == true)
end

-- Object args: values ordered by alphabetically sorted keys. Arrays pass through.
-- Returns table with explicit n.
function M.args_to_positional(args)
  local out = { n = 0 }
  if type(args) ~= "table" then return out end
  if is_array(args) then
    local n = #args
    for i = 1, n do
      local v = args[i]
      if is_null(v) then v = nil end
      out[i] = v
    end
    out.n = n
    return out
  end
  local keys = {}
  for k in pairs(args) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  for i, k in ipairs(keys) do
    local v = args[k]
    if v == nil then v = args[tonumber(k)] end
    if is_null(v) then v = nil end
    out[i] = v
  end
  out.n = #keys
  return out
end

local function error_body(msg)
  return json.encode({ success = false, error = tostring(msg) })
end
M.error_body = error_body

local function to_json_string(v)
  if type(v) == "string" then return v end
  local ok, s = pcall(json.encode, v == nil and json.null or v)
  if ok and type(s) == "string" then return s end
  return error_body("result not serializable")
end

-- Call registry[fn] safely. Always returns a JSON string.
function M.call(registry, fn, args)
  local f = registry[fn]
  if type(f) ~= "function" then return error_body("unknown function: " .. tostring(fn)) end
  local pos = M.args_to_positional(args)
  local res = table.pack(xpcall(f, function(e)
    if type(e) == "string" then
      log.warn("rpc " .. tostring(fn) .. " failed: " .. debug.traceback(e, 2):gsub("\n.*", ""))
    end
    return e
  end, table.unpack(pos, 1, pos.n)))
  if not res[1] then
    local e = res[2]
    if type(e) == "table" and e.message then e = e.message end
    return error_body(e)
  end
  return to_json_string(res[2])
end

-- JS string literal safe for Runtime.evaluate (valid UTF-8, no raw line separators).
function M.js_literal(s)
  s = tostring(s)
  if not utf8.len(s) then
    local parts = {}
    for ch in s:gmatch(utf8.charpattern) do
      parts[#parts + 1] = utf8.len(ch) and ch or "\239\191\189"
    end
    s = table.concat(parts)
  end
  local enc = json.encode(s)
  return (enc:gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029"))
end

-- Handle one Runtime.bindingCalled payload for a session. ctx: {registry, token}.
function M.handle(session, ctx, payload, context_id)
  local req = polyfill.parse_request(payload, ctx.token)
  if not req then return false end
  local out = M.call(ctx.registry, req.fn, req.args)
  local expr = "window.__lunaResolve(" .. M.js_literal(req.id) .. "," .. M.js_literal(out) .. ")"
  local extra = context_id and { contextId = context_id } or nil
  session:evaluate(expr, nil, extra)
  return true
end

return M
