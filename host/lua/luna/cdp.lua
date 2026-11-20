-- Non-blocking Chrome DevTools Protocol session over a WebSocket.
-- Usage:  s = cdp.open(ws_url, expected_port)
--         s:on("Page.loadEventFired", fn(params, session))
--         s:send("Runtime.evaluate", {expression="1"}, function(result, err) end)
--         s:pump(); s:tick(now)   -- from the main loop after socket.select
local socket = require("socket")
local json = require("json")
local wsframe = require("luna.wsframe")

local M = {}
M.REQUEST_TIMEOUT = 20

local Session = {}
Session.__index = Session

-- Parse ws://127.0.0.1:port/path. Only loopback on the verified port is allowed.
function M.parse_ws_url(url, expected_port)
  local host, port, path = tostring(url):match("^ws://([^/:]+):(%d+)(/.*)$")
  if not host then return nil, "unsupported websocket url" end
  port = tonumber(port)
  if host ~= "127.0.0.1" and host ~= "localhost" then return nil, "non-loopback websocket host" end
  if expected_port and port ~= expected_port then return nil, "websocket port mismatch" end
  if path:find("[%s\r\n]") then return nil, "bad websocket path" end
  return { host = "127.0.0.1", port = port, path = path }
end

local function read_response_head(sock)
  local lines = {}
  while true do
    local line, err = sock:receive("*l")
    if not line then return nil, err end
    line = line:gsub("\r$", "")
    if line == "" then break end
    lines[#lines + 1] = line
    if #lines > 100 then return nil, "response head too long" end
  end
  return table.concat(lines, "\r\n")
end

function M.open(url, expected_port, opts)
  opts = opts or {}
  local u, perr = M.parse_ws_url(url, expected_port)
  if not u then return nil, perr end
  local sock = socket.tcp()
  sock:settimeout(opts.timeout or 3)
  local ok, err = sock:connect(u.host, u.port)
  if not ok then sock:close(); return nil, "connect: " .. tostring(err) end
  local key = wsframe.new_key()
  local sent, serr = sock:send(wsframe.handshake_request(u.host, u.port, u.path, key))
  if not sent then sock:close(); return nil, "handshake send: " .. tostring(serr) end
  local head, herr = read_response_head(sock)
  if not head then sock:close(); return nil, "handshake read: " .. tostring(herr) end
  local good, why = wsframe.handshake_ok(head, key)
  if not good then sock:close(); return nil, "handshake: " .. tostring(why) end
  sock:settimeout(0)
  return M.wrap(sock, { url = url, port = u.port })
end

-- Wrap an already-upgraded socket (also used by tests).
function M.wrap(sock, info)
  info = info or {}
  return setmetatable({
    sock = sock, url = info.url, port = info.port,
    parser = wsframe.parser(), out = "", nextid = 0,
    pending = {}, handlers = {}, closed = false, close_reason = nil,
    data = {},                 -- free-form per-session storage for the injector
  }, Session)
end

function Session:on(event, fn)
  local list = self.handlers[event]
  if not list then list = {}; self.handlers[event] = list end
  list[#list + 1] = fn
end

function Session:wants_write() return not self.closed and #self.out > 0 end

function Session:flush()
  if self.closed or #self.out == 0 then return end
  local r, err, last = self.sock:send(self.out)
  local n
  if r then n = r
  elseif err == "timeout" then n = last or 0
  else self:_closed("send: " .. tostring(err)); return end
  self.out = self.out:sub(n + 1)
end

function Session:_queue(opcode, payload)
  if self.closed then return false end
  self.out = self.out .. wsframe.encode(opcode, payload)
  self:flush()
  return true
end

-- Send a CDP command. cb(result, err) is optional; err is the CDP error table
-- or a string ("timeout", "closed"). Returns the command id.
function Session:send(method, params, cb, now)
  if self.closed then
    if cb then cb(nil, "closed") end
    return nil
  end
  self.nextid = self.nextid + 1
  local id = self.nextid
  local text = '{"id":' .. id .. ',"method":' .. json.encode(method) ..
    ',"params":' .. (params and json.encode(params) or "{}") .. "}"
  self.pending[id] = { cb = cb, deadline = (now or socket.gettime()) + M.REQUEST_TIMEOUT }
  self:_queue(wsframe.OP_TEXT, text)
  return id
end

function Session:evaluate(expression, cb, extra)
  local p = { expression = expression, returnByValue = true, awaitPromise = false,
              userGesture = true }
  if extra then for k, v in pairs(extra) do p[k] = v end end
  return self:send("Runtime.evaluate", p, cb)
end

function Session:_closed(reason)
  if self.closed then return end
  self.closed = true
  self.close_reason = reason
  local pend = self.pending
  self.pending = {}
  for _, p in pairs(pend) do
    if p.cb then pcall(p.cb, nil, "closed") end
  end
  pcall(self.sock.close, self.sock)
  local list = self.handlers["close"]
  if list then for _, fn in ipairs(list) do pcall(fn, reason, self) end end
end

function Session:close(reason)
  if self.closed then return end
  pcall(function()
    self.out = self.out .. wsframe.encode(wsframe.OP_CLOSE, "\3\232")
    self:flush()
  end)
  self:_closed(reason or "closed locally")
end

function Session:_dispatch(text)
  local ok, msg = pcall(json.decode, text)
  if not ok or type(msg) ~= "table" then return end
  if msg.id ~= nil then
    local p = self.pending[msg.id]
    if p then
      self.pending[msg.id] = nil
      if p.cb then
        local ok2, e = pcall(p.cb, msg.result, msg.error)
        if not ok2 then self:_log_error("callback", e) end
      end
    end
  elseif type(msg.method) == "string" then
    for _, name in ipairs({ msg.method, "*" }) do
      local list = self.handlers[name]
      if list then
        for _, fn in ipairs(list) do
          local ok2, e = pcall(fn, msg.params or {}, self, msg.method)
          if not ok2 then self:_log_error(msg.method, e) end
        end
      end
    end
  end
end

function Session:_log_error(what, e)
  local ok, log = pcall(require, "luna.log")
  if ok then log.error("cdp handler " .. tostring(what) .. ": " .. tostring(e)) end
end

-- Read everything currently available and dispatch. Returns false once closed.
function Session:pump()
  if self.closed then return false end
  for _ = 1, 32 do
    local data, err, partial = self.sock:receive(65536)
    data = data or partial
    if data and #data > 0 then
      local msgs, perr = self.parser:feed(data)
      if not msgs then self:close("protocol: " .. tostring(perr)); return false end
      for _, m in ipairs(msgs) do
        if m.opcode == wsframe.OP_TEXT then self:_dispatch(m.payload)
        elseif m.opcode == wsframe.OP_PING then self:_queue(wsframe.OP_PONG, m.payload)
        elseif m.opcode == wsframe.OP_CLOSE then
          self:_queue(wsframe.OP_CLOSE, m.payload:sub(1, 2))
          self:_closed("closed by peer")
          return false
        end
      end
      if self.closed then return false end
    end
    if not data or #data == 0 then
      if err == "timeout" or err == nil then break end
      self:_closed(tostring(err)); return false
    end
    if err and err ~= "timeout" then self:_closed(tostring(err)); return false end
  end
  self:flush()
  return not self.closed
end

-- Expire timed-out requests.
function Session:tick(now)
  now = now or socket.gettime()
  for id, p in pairs(self.pending) do
    if p.deadline <= now then
      self.pending[id] = nil
      if p.cb then pcall(p.cb, nil, "timeout") end
    end
  end
  self:flush()
end

return M
