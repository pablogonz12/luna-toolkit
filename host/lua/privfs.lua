-- privfs: private (0700/0600) filesystem helpers.
local core = require("luna_core")
local M = {}

function M.mkdir_private(path)
  local fs = require("fs")
  if fs.is_directory(path) then
    core.chmod(path, 448)
    return true
  end
  local old = core.umask(63) -- 0077
  local ok, err = core.mkdir(path, 448)
  core.umask(old)
  if not ok and not fs.is_directory(path) then return nil, err end
  core.chmod(path, 448)
  return true
end

function M.write_private(path, data)
  local tmp = string.format("%s.tmp.%d", path, core.getpid())
  local old = core.umask(63)
  local f, err = io.open(tmp, "wb")
  core.umask(old)
  if not f then return nil, err end
  core.chmod(tmp, 384)
  local ok, werr = f:write(data)
  f:close()
  if not ok then core.remove(tmp); return nil, werr end
  local rok, rerr = core.rename(tmp, path)
  if not rok then core.remove(tmp); return nil, rerr end
  return true
end

function M.write_script(path, data)
  local ok, err = M.write_private(path, data)
  if not ok then return nil, err end
  core.chmod(path, 448)
  return true
end

function M.runtime_dir()
  local d = os.getenv("XDG_RUNTIME_DIR")
  if d and d ~= "" then return d end
  return "/tmp"
end

function M.temp_script_path(name)
  return string.format("%s/%s.%d.sh", M.runtime_dir(), name or "luna", core.getpid())
end

return M
