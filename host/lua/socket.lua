-- socket: luasocket-compatible subset over luna_core (TCP client only).
local core = require("luna_core")
local M = { _VERSION = "luna-socket 1.0" }

M.gettime = core.gettime
M.sleep = core.sleep
M._DEBUG = false

local Tcp = {}
Tcp.__index = Tcp
Tcp.__name = "tcp{client}"

function M.tcp()
  return setmetatable({ fd = nil, timeout = nil, buf = "" }, Tcp)
end
M.tcp4 = M.tcp

function Tcp:settimeout(t)
  if t ~= nil and t < 0 then t = nil end
  self.timeout = t
  return 1
end

function Tcp:getfd() return self.fd or -1 end
function Tcp:setoption() return 1 end
function Tcp:setfd(fd) self.fd = fd end
function Tcp:dirty() return #self.buf > 0 end

function Tcp:connect(host, port)
  if self.fd then return nil, "already connected" end
  if host == "localhost" then host = "127.0.0.1" end
  local fd, err = core.tcp_connect(tonumber(port), self.timeout or 5, host)
  if not fd then return nil, err end
  self.fd = fd
  return 1
end

-- AF_UNIX stream client: same I/O methods as tcp, connect(path) instead.
local Unix = setmetatable({ __name = "unix{client}" }, { __index = Tcp })
Unix.__index = Unix

function M.unix()
  return setmetatable({ fd = nil, timeout = nil, buf = "" }, Unix)
end

function Unix:connect(path)
  if self.fd then return nil, "already connected" end
  local fd, err = core.unix_connect(tostring(path), self.timeout or 5)
  if not fd then return nil, err end
  self.fd = fd
  return 1
end

function Tcp:close()
  if self.fd then core.close(self.fd); self.fd = nil end
  return 1
end

function Tcp:shutdown() return 1 end

-- wait until fd readable (r) or writable; honours timeout. returns true or nil,'timeout'
local function wait(self, write, deadline)
  local left
  if deadline then
    left = deadline - core.monotonic()
    if left <= 0 then return nil, "timeout" end
  end
  local r, w
  if write then r, w = core.select(nil, { self.fd }, left) else r, w = core.select({ self.fd }, nil, left) end
  if not r then return nil, "timeout" end
  return true
end

function Tcp:send(data, i, j)
  if not self.fd then return nil, "closed" end
  data = tostring(data)
  if i or j then data = data:sub(i or 1, j or -1) end
  local deadline = self.timeout and core.monotonic() + self.timeout or nil
  local pos = 1
  while pos <= #data do
    local n, err = core.tcp_send(self.fd, data, pos)
    if n then
      pos = pos + n
    elseif err == "timeout" then
      if self.timeout == 0 then return nil, "timeout", pos - 1 end
      local ok = wait(self, true, deadline)
      if not ok then return nil, "timeout", pos - 1 end
    else
      return nil, err, pos - 1
    end
  end
  return #data
end

-- fill buffer once; returns true | nil,err
local function fill(self, deadline)
  while true do
    local d, err = core.tcp_recv(self.fd, 8192)
    if d then self.buf = self.buf .. d; return true end
    if err ~= "timeout" then return nil, err end
    if self.timeout == 0 then return nil, "timeout" end
    local ok = wait(self, false, deadline)
    if not ok then return nil, "timeout" end
  end
end

function Tcp:receive(pattern, prefix)
  if not self.fd then return nil, "closed" end
  pattern = pattern or "*l"
  prefix = prefix or ""
  local deadline = self.timeout and core.monotonic() + self.timeout or nil
  if type(pattern) == "number" then
    while #self.buf < pattern do
      local ok, err = fill(self, deadline)
      if not ok then
        if err == "closed" then
          local part = self.buf; self.buf = ""
          return nil, err, prefix .. part
        end
        -- luasocket semantics: partial data is returned AND consumed
        local part = self.buf; self.buf = ""
        return nil, err, prefix .. part
      end
    end
    local out = self.buf:sub(1, pattern)
    self.buf = self.buf:sub(pattern + 1)
    return prefix .. out
  end
  pattern = pattern:gsub("^%*", "")
  if pattern == "a" then
    while true do
      local ok, err = fill(self, deadline)
      if not ok then
        if err == "closed" then
          local all = self.buf; self.buf = ""
          return prefix .. all
        end
        return nil, err, prefix .. self.buf
      end
    end
  elseif pattern == "l" then
    while true do
      local nl = self.buf:find("\n", 1, true)
      if nl then
        local line = self.buf:sub(1, nl - 1):gsub("\r$", "")
        self.buf = self.buf:sub(nl + 1)
        return prefix .. line
      end
      local ok, err = fill(self, deadline)
      if not ok then
        if err == "closed" then
          local rest = self.buf; self.buf = ""
          return nil, err, prefix .. rest
        end
        return nil, err, prefix .. self.buf
      end
    end
  end
  error("bad argument #1 to 'receive' (invalid receive pattern)", 2)
end

function Tcp:getpeername() return "127.0.0.1", 0 end
function Tcp:getsockname() return "127.0.0.1", 0 end

local function fds_of(list)
  local fds, map = {}, {}
  for _, s in ipairs(list or {}) do
    local fd = type(s) == "number" and s or (s.getfd and s:getfd())
    if fd and fd >= 0 then fds[#fds + 1] = fd; map[fd] = s end
  end
  return fds, map
end

function M.select(recvt, sendt, timeout)
  local rfds, rmap = fds_of(recvt)
  local wfds, wmap = fds_of(sendt)
  local ready_r, ready_w = {}, {}
  -- sockets with buffered data are readable immediately
  local buffered = false
  for _, s in ipairs(recvt or {}) do
    if type(s) == "table" and s.dirty and s:dirty() then
      ready_r[#ready_r + 1] = s; ready_r[s] = true; buffered = true
    end
  end
  if #rfds == 0 and #wfds == 0 then
    if not buffered and timeout and timeout > 0 then core.sleep(timeout) end
    if buffered then return ready_r, ready_w end
    return ready_r, ready_w, "timeout"
  end
  local r, w = core.select(rfds, wfds, buffered and 0 or timeout)
  if not r then
    if buffered then return ready_r, ready_w end
    return ready_r, ready_w, "timeout"
  end
  for _, fd in ipairs(r) do
    local s = rmap[fd]
    if not ready_r[s] then ready_r[#ready_r + 1] = s; ready_r[s] = true end
  end
  for _, fd in ipairs(w) do
    local s = wmap[fd]
    ready_w[#ready_w + 1] = s; ready_w[s] = true
  end
  return ready_r, ready_w
end

return M
