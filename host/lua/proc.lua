-- proc: /proc-based process checks.
local core = require("luna_core")
local M = {}

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

local function each_pid(comm, root)
  root = root or "/proc"
  local pids = {}
  for _, n in ipairs(core.listdir(root) or {}) do
    if n:match("^%d+$") then
      local c = read(root .. "/" .. n .. "/comm")
      if c and c:gsub("\n$", "") == comm then pids[#pids + 1] = n end
    end
  end
  return pids
end

function M.is_alive(comm, root)
  return #each_pid(comm, root) > 0
end

function M.lib_mapped(comm, needle, root)
  root = root or "/proc"
  for _, pid in ipairs(each_pid(comm, root)) do
    local maps = read(root .. "/" .. pid .. "/maps")
    if maps and maps:find(needle, 1, true) then return true end
  end
  return false
end

function M.pids(comm, root) return each_pid(comm, root) end
return M
