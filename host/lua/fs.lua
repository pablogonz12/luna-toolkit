-- fs: filesystem helpers.
local core = require("luna_core")
local M = {}

function M.exists(path)
  return path ~= nil and core.stat(path) ~= nil
end

function M.is_directory(path)
  local st = core.stat(path)
  return st ~= nil and st.mode == "directory"
end

function M.is_file(path)
  local st = core.stat(path)
  return st ~= nil and st.mode == "file"
end

function M.join(...)
  local parts = { ... }
  local out = ""
  for _, p in ipairs(parts) do
    p = tostring(p)
    if p ~= "" then
      if p:sub(1, 1) == "/" then out = p
      elseif out == "" then out = p
      elseif out:sub(-1) == "/" then out = out .. p
      else out = out .. "/" .. p end
    end
  end
  return out
end

function M.parent_path(path)
  local p = path:gsub("/+$", "")
  if p == "" then return path:sub(1, 1) == "/" and "/" or "" end
  local d = p:match("^(.*)/[^/]*$")
  if d == nil then return "" end
  if d == "" then return "/" end
  return d
end

function M.current_path() return core.getcwd() end

function M.absolute(path)
  if path:sub(1, 1) ~= "/" then path = M.join(core.getcwd(), path) end
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then parts[#parts] = nil
    elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  return "/" .. table.concat(parts, "/")
end

function M.create_directories(path)
  if path == "" then return true end
  if M.is_directory(path) then return true end
  local parent = M.parent_path(path)
  if parent ~= "" and parent ~= path then M.create_directories(parent) end
  local ok, err = core.mkdir(path, 493)
  if not ok and not M.is_directory(path) then return nil, err end
  return true
end

function M.list(dir)
  local names, err = core.listdir(dir)
  if not names then return nil, err end
  table.sort(names)
  local out = {}
  for _, n in ipairs(names) do
    local full = M.join(dir, n)
    out[#out + 1] = { name = n, is_directory = M.is_directory(full), path = full }
  end
  return out
end

function M.list_recursive(dir)
  local out = {}
  local function walk(d)
    local items = M.list(d) or {}
    for _, it in ipairs(items) do
      out[#out + 1] = it
      local st = core.stat(it.path, true)
      if it.is_directory and st and st.mode ~= "link" then walk(it.path) end
    end
  end
  walk(dir)
  return out
end

function M.remove(path)
  local st = core.stat(path, true)
  if not st then return false end
  local ok
  if st.mode == "directory" then ok = core.rmdir(path) else ok = core.remove(path) end
  return ok and true or false
end

function M.remove_all(path)
  local st = core.stat(path, true)
  if not st then return 0 end
  local n = 0
  if st.mode == "directory" then
    for _, name in ipairs(core.listdir(path) or {}) do
      n = n + M.remove_all(M.join(path, name))
    end
  end
  if M.remove(path) then n = n + 1 end
  return n
end

function M.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local d = f:read("a")
  f:close()
  return d
end

function M.write(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

M.read_file = M.read
M.write_file = M.write
function M.size(path) local st = core.stat(path); return st and st.size end
function M.rename(a, b) return core.rename(a, b) end

return M
