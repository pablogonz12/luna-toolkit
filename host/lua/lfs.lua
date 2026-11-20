-- lfs: LuaFileSystem-compatible subset.
local core = require("luna_core")
local M = { _VERSION = "luna-lfs 1.0" }

function M.attributes(path, aname)
  local st, err = core.stat(path)
  if not st then return nil, path .. ": " .. tostring(err), 2 end
  if type(aname) == "string" then return st[aname] end
  if type(aname) == "table" then for k, v in pairs(st) do aname[k] = v end; return aname end
  return st
end

function M.symlinkattributes(path, aname)
  local st, err = core.stat(path, true)
  if not st then return nil, path .. ": " .. tostring(err), 2 end
  if st.mode == "link" then st.target = core.readlink(path) end
  if type(aname) == "string" then return st[aname] end
  return st
end

function M.dir(path)
  local names, err = core.listdir(path)
  if not names then error("cannot open " .. tostring(path) .. ": " .. tostring(err), 2) end
  table.sort(names)
  table.insert(names, 1, "..")
  table.insert(names, 1, ".")
  local i = 0
  return function()
    i = i + 1
    return names[i]
  end
end

function M.mkdir(path)
  local ok, err = core.mkdir(path, 493)
  if ok then return true end
  return nil, path .. ": " .. tostring(err), 2
end

function M.rmdir(path)
  local ok, err = core.rmdir(path)
  if ok then return true end
  return nil, path .. ": " .. tostring(err), 2
end

function M.currentdir() return core.getcwd() end
function M.chdir() return nil, "chdir not supported" end
function M.touch(path)
  local f, err = io.open(path, "ab")
  if not f then return nil, err end
  f:close()
  return true
end

return M
