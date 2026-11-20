-- utils: helpers used by backends.
local core = require("luna_core")
local json = require("json")
local M = {}

local backend_override
-- The legacy-plugin loader points this at the plugin's own backend/ directory.
function M.set_backend_path(p) backend_override = p end
function M.get_backend_path()
  if backend_override then return backend_override end
  local d = os.getenv("LUNA_BACKEND_DIR")
  if d and d ~= "" then return d end
  return (os.getenv("HOME") or "") .. "/.local/share/Luna/addons"
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end
M.read_text = M.read_file

function M.write_file(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end
M.write_text = M.write_file

function M.append_file(path, text)
  local f = io.open(path, "ab")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

function M.exec(cmd)
  local p = io.popen(cmd .. " 2>&1", "r")
  if not p then return nil end
  local out = p:read("a")
  p:close()
  return out
end

function M.getenv(name) return os.getenv(name) end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.base64_encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2, c3, c4 = (n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

function M.decode_json(text) return json.decode(text) end
function M.encode_json(t) return json.encode(t) end

function M.read_json(path)
  local d = M.read_file(path)
  if not d then return nil end
  local ok, v = pcall(json.decode, d)
  if ok then return v end
  return nil
end

function M.write_json(path, t) return M.write_file(path, json.encode(t)) end

function M.write_json_atomic(path, t)
  local tmp = path .. ".tmp"
  if not M.write_file(tmp, json.encode(t)) then return false end
  if core.stat(path) then
    local bak = path .. ".bak"
    local old = M.read_file(path)
    if old then M.write_file(bak, old) end
  end
  local ok = core.rename(tmp, path)
  if not ok then core.remove(tmp); return false end
  return true
end

function M.parse_version(s)
  local out = {}
  for n in tostring(s or ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
  return out
end

function M.get_plugin_version()
  local p = M.get_backend_path() .. "/../plugin.json"
  local d = M.read_json(p)
  return d and d.version or "0.0.0"
end

function M.count_apis(...)
  local n = 0
  for _, t in ipairs({ ... }) do
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
  end
  return n
end

function M.normalize_manifest_text(text)
  text = tostring(text or ""):gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  return text
end

function M.ensure_temp_download_dir()
  local base = os.getenv("XDG_RUNTIME_DIR")
  if not base or base == "" then base = "/tmp" end
  local d = base .. "/luna-downloads"
  require("fs").create_directories(d)
  return d
end

return M
