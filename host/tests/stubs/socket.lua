-- In-memory socket stub (luasocket-like subset) with scriptable loopback servers.
local M = { servers = {}, clock = 0 }

function M.listen(port, on_connect) M.servers[port] = { on_connect = on_connect } end
function M.reset() M.servers = {} end
function M.gettime() return os.time() + (os.clock() % 1) + M.clock end
function M.sleep(s) M.clock = M.clock + (s or 0) end

local Tcp = {}
Tcp.__index = Tcp
function M.tcp() return setmetatable({ inbuf = "", timeout = nil, closed = false, peer_closed = false }, Tcp) end
function Tcp:settimeout(t) self.timeout = t end
function Tcp:getfd() return self end

function Tcp:connect(host, port)
  local srv = M.servers[port]
  if not srv then return nil, "connection refused" end
  local client = self
  self.conn = {
    push = function(_, data) client.inbuf = client.inbuf .. data end,
    close = function() client.peer_closed = true end,
    client = client,
  }
  srv.on_connect(self.conn)
  return 1
end

function Tcp:send(data)
  if self.closed or self.peer_closed then return nil, "closed", 0 end
  if self.conn.on_data then self.conn.on_data(self.conn, data) end
  return #data
end

function Tcp:receive(pat)
  if self.closed then return nil, "closed" end
  local function empty_err(partial)
    if self.peer_closed then return nil, "closed", partial end
    return nil, "timeout", partial
  end
  if pat == "*l" then
    local s, e = self.inbuf:find("\n", 1, true)
    if not s then return empty_err("") end
    local line = self.inbuf:sub(1, s - 1)
    self.inbuf = self.inbuf:sub(e + 1)
    return (line:gsub("\r$", ""))
  elseif pat == "*a" then
    local d = self.inbuf; self.inbuf = ""; return d
  else
    if #self.inbuf >= pat then
      local d = self.inbuf:sub(1, pat); self.inbuf = self.inbuf:sub(pat + 1); return d
    end
    local partial = self.inbuf; self.inbuf = ""
    if self.timeout == 0 or self.peer_closed then return empty_err(partial) end
    return nil, "timeout", partial
  end
end

function Tcp:close() self.closed = true end

function M.select(r, w, t)
  local rr = {}
  for _, s in ipairs(r or {}) do if #s.inbuf > 0 or s.peer_closed then rr[#rr + 1] = s end end
  return rr, w or {}, nil
end

return M
