-- Verify that whatever listens on 127.0.0.1:<port> is Steam's web helper
-- (same uid, comm steamwebhelper/steam) before any CDP traffic is sent.
local M = {}
M.ALLOWED_COMM = { steamwebhelper = true, steam = true }

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local LOOP4 = "0100007F"
local ANY4 = "00000000"
local LOOP6 = "00000000000000000000000001000000"
local MAPPED6 = "0000000000000000FFFF00000100007F"
local ANY6 = "00000000000000000000000000000000"

-- Returns list of {inode=, uid=, specific=bool} LISTEN sockets on port reachable via 127.0.0.1.
function M.listeners(port, proc_root)
  local root = proc_root or "/proc"
  local found = {}
  local function scan(file, loop_addrs, any_addr)
    local text = read_all(root .. "/net/" .. file)
    if not text then return end
    for line in text:gmatch("[^\n]+") do
      local addr, p, st, uid, inode =
        line:match("^%s*%d+:%s+(%x+):(%x+)%s+%x+:%x+%s+(%x%x)%s+%S+%s+%S+%s+%S+%s+(%d+)%s+%S+%s+(%d+)")
      if addr and st == "0A" and tonumber(p, 16) == port then
        addr = addr:upper()
        local specific = loop_addrs[addr]
        if specific or addr == any_addr then
          found[#found + 1] = { inode = inode, uid = tonumber(uid), specific = specific and true or false }
        end
      end
    end
  end
  scan("tcp", { [LOOP4] = true }, ANY4)
  scan("tcp6", { [LOOP6] = true, [MAPPED6] = true }, ANY6)
  -- A loopback-specific listener wins over wildcard ones for connections to 127.0.0.1.
  local specific = {}
  for _, l in ipairs(found) do if l.specific then specific[#specific + 1] = l end end
  return #specific > 0 and specific or found
end

local function my_uid(proc_root)
  local s = read_all((proc_root or "/proc") .. "/self/status")
  return s and tonumber(s:match("\nUid:%s*(%d+)"))
end

-- Default pid finder: processes holding socket inode (find -lname on /proc/*/fd).
local function find_pids(inode, proc_root)
  if not inode:match("^%d+$") then return {} end
  local root = proc_root or "/proc"
  if root:find("[^%w/%._%-]") then return {} end
  local cmd = string.format("find %s/[0-9]*/fd -maxdepth 1 -lname 'socket:\\[%s\\]' 2>/dev/null", root, inode)
  local p = io.popen(cmd)
  if not p then return {} end
  local pids, seen = {}, {}
  for line in p:lines() do
    local pid = line:match("/(%d+)/fd/")
    if pid and not seen[pid] then seen[pid] = true; pids[#pids + 1] = pid end
  end
  p:close()
  return pids
end

-- opts: proc_root, allowed (set), find_pids(inode)->pids, uid.
-- Returns true,{pid=,comm=} or false,reason.
function M.verify(port, opts)
  opts = opts or {}
  local root = opts.proc_root or "/proc"
  local allowed = opts.allowed or M.ALLOWED_COMM
  local ls = M.listeners(port, root)
  if #ls == 0 then return false, "no listener on 127.0.0.1:" .. tostring(port) end
  local uid = opts.uid or my_uid(root)
  local finder = opts.find_pids or find_pids
  local info
  for _, l in ipairs(ls) do
    if uid and l.uid ~= uid then return false, "listener owned by another uid" end
    local pids = finder(l.inode, root)
    if #pids == 0 then return false, "listener process not visible" end
    for _, pid in ipairs(pids) do
      local comm = (read_all(root .. "/" .. pid .. "/comm") or ""):gsub("%s+$", "")
      if not allowed[comm] then
        return false, "listener process is '" .. comm .. "' (pid " .. pid .. ")"
      end
      info = info or { pid = tonumber(pid), comm = comm }
    end
  end
  return true, info
end

return M
