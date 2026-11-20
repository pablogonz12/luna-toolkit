-- Resolve the Steam CEF remote-debugging port from the contract file.
--   $LUNA_HOME/cef_port, then legacy ~/.local/share/Luna/cef_port, then 8080.
-- Format: line 1 = port; optional line 2 = "owner <pid> <starttime_ticks>".
-- An owner line is only trusted when /proc/<pid>/stat field 22 still matches.
local M = {}
M.DEFAULT_PORT = 8080
M.MIN_PORT, M.MAX_PORT = 1024, 65535

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Field 22 of /proc/<pid>/stat. comm may contain spaces/parens, so split after the last ')'.
function M.starttime(pid, proc_root)
  local stat = read_all((proc_root or "/proc") .. "/" .. tostring(pid) .. "/stat")
  if not stat then return nil end
  local rest = stat:match("^.*%)%s+(.*)$")
  if not rest then return nil end
  local n = 0
  for field in rest:gmatch("%S+") do
    n = n + 1
    if n == 20 then return tonumber(field) end   -- stat field 22 (state is field 3)
  end
  return nil
end

-- Parse file text. Returns {port=, owner_pid=, owner_start=} or nil,reason.
function M.parse(text)
  if type(text) ~= "string" then return nil, "empty" end
  local line1, rest = text:match("^%s*([^\r\n]*)[\r\n]*(.*)$")
  local port = tonumber(line1 and line1:match("^%s*(%d+)%s*$"))
  if not port then return nil, "bad port line" end
  if port < M.MIN_PORT or port > M.MAX_PORT then return nil, "port out of range" end
  local res = { port = port }
  for line in (rest or ""):gmatch("[^\r\n]+") do
    local pid, start = line:match("^%s*owner%s+(%d+)%s+(%d+)%s*$")
    if pid then res.owner_pid, res.owner_start = tonumber(pid), tonumber(start); break end
  end
  return res
end

local function try_file(path, proc_root)
  local text = read_all(path)
  if not text then return nil, "missing" end
  local res, why = M.parse(text)
  if not res then return nil, why end
  if res.owner_pid then
    local st = M.starttime(res.owner_pid, proc_root)
    if not st or st ~= res.owner_start then return nil, "stale owner" end
  end
  return res.port
end

function M.candidates(opts)
  opts = opts or {}
  local home = opts.home or os.getenv("HOME") or ""
  local luna_home = opts.luna_home or os.getenv("LUNA_HOME")
  if not luna_home or luna_home == "" then luna_home = home .. "/.local/share/Luna" end
  return {
    { path = luna_home .. "/cef_port", source = "luna" },
    { path = home .. "/.local/share/Luna/cef_port", source = "legacy" },
  }
end

-- opts: luna_home, home, proc_root. Returns port, source, notes(table of strings).
function M.read(opts)
  opts = opts or {}
  local notes = {}
  for _, c in ipairs(M.candidates(opts)) do
    local port, why = try_file(c.path, opts.proc_root)
    if port then return port, c.source, notes end
    if why ~= "missing" then notes[#notes + 1] = c.path .. ": " .. why end
  end
  return M.DEFAULT_PORT, "default", notes
end

-- The port Steam actually serves, taken from its own command line. Steam's
-- client/webhelper processes carry `--remote-debugging-port=<port>`; this is
-- the only source that needs no third-party wrapper and no file.
function M.port_in_cmdline(raw)
  if type(raw) ~= "string" then return nil end
  local port = tonumber(raw:match("%-%-remote%-debugging%-port=(%d+)"))
  if port and port >= M.MIN_PORT and port <= M.MAX_PORT then return port end
  return nil
end

local function list_pids(dir)
  local out = {}
  local ok, fs = pcall(require, "fs")
  if ok and type(fs) == "table" and type(fs.list) == "function" then
    local listed, names = pcall(fs.list, dir)
    if listed and type(names) == "table" then
      for _, item in ipairs(names) do
        local name = type(item) == "table" and tostring(item.name) or tostring(item)
        if name:match("^%d+$") then out[#out + 1] = tonumber(name) end
      end
      return out
    end
  end
  -- Single ls, only when the fs shim is unavailable (bare Lua interpreter).
  local p = io.popen("ls -1 '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
  if p then
    for line in p:lines() do
      if line:match("^%d+$") then out[#out + 1] = tonumber(line) end
    end
    p:close()
  end
  return out
end

-- port, pid from the first Steam process that exposes the debug flag.
function M.from_process(opts)
  opts = opts or {}
  local proc_root = opts.proc_root or "/proc"
  local best, best_pid
  for _, pid in ipairs(list_pids(proc_root)) do
    local raw = read_all(proc_root .. "/" .. pid .. "/cmdline")
    if raw and raw:lower():find("steam", 1, true) then
      local port = M.port_in_cmdline(raw)
      if port then
        -- steamwebhelper is the process that owns the CEF socket; prefer it
        -- when several Steam processes carry the flag.
        if raw:find("steamwebhelper", 1, true) then return port, pid end
        if not best then best, best_pid = port, pid end
      end
    end
  end
  return best, best_pid
end

-- Resolve a port without depending on any wrapper: Steam's command line first,
-- then the contract file ($LUNA_HOME, then the legacy path), then 8080.
-- Returns port, source ("process"|"luna"|"legacy"|"default"), pid, notes.
function M.discover(opts)
  opts = opts or {}
  local port, pid = M.from_process(opts)
  if port then return port, "process", pid, {} end
  local file_port, source, notes = M.read(opts)
  return file_port, source, nil, notes
end

local function contract_path(opts)
  opts = opts or {}
  local home = opts.home or os.getenv("HOME") or ""
  local luna_home = opts.luna_home or os.getenv("LUNA_HOME")
  if not luna_home or luna_home == "" then luna_home = home .. "/.local/share/Luna" end
  return luna_home .. "/cef_port"
end

-- Record the port this host attaches to, atomically (tmp + rename), in the
-- same format cefport.parse reads. An `owner` line is written only when a
-- process and its start time are known, so a recycled pid is never trusted.
-- Never throws: a read-only LUNA_HOME degrades to nil, err.
function M.write(port, opts)
  opts = opts or {}
  port = tonumber(port)
  if not port or port < M.MIN_PORT or port > M.MAX_PORT then return nil, "port out of range" end
  local path = contract_path(opts)
  local ok, fs = pcall(require, "fs")
  if ok and type(fs) == "table" and type(fs.create_directories) == "function" then
    pcall(fs.create_directories, path:match("^(.*)/[^/]*$") or "")
  end
  local body = tostring(math.floor(port)) .. "\n"
  if opts.pid and opts.start then
    body = body .. "owner " .. tostring(math.floor(opts.pid)) .. " " .. tostring(math.floor(opts.start)) .. "\n"
  end
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return nil, "cannot write " .. tmp end
  local written = f:write(body)
  local closed = f:close()
  if not written or not closed then os.remove(tmp); return nil, "cannot write " .. tmp end
  local done, why = os.rename(tmp, path)
  if not done then os.remove(tmp); return nil, why or "rename failed" end
  return true
end

-- Discover and record in one step. Returns port, source, wrote(bool), err.
function M.record(opts)
  opts = opts or {}
  local port, source, pid = M.discover(opts)
  local out = { home = opts.home, luna_home = opts.luna_home }
  if pid then
    out.pid = pid
    out.start = opts.start or M.starttime(pid, opts.proc_root)
  end
  local ok, err = M.write(port, out)
  return port, source, ok == true, err
end

return M
