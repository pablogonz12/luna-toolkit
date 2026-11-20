-- RFC 6455 client-side framing: handshake helpers, SHA-1, base64, frame
-- encoder and incremental decoder. Pure Lua 5.4, no dependencies.
local M = {}

M.OP_CONT, M.OP_TEXT, M.OP_BINARY = 0, 1, 2
M.OP_CLOSE, M.OP_PING, M.OP_PONG = 8, 9, 10
M.GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
M.MAX_MESSAGE = 64 * 1024 * 1024

local spack, sunpack, srep = string.pack, string.unpack, string.rep

---------------------------------------------------------------- randomness
function M.random_bytes(n)
  local f = io.open("/dev/urandom", "rb")
  if not f then error("wsframe: /dev/urandom unavailable") end
  local s = f:read(n)
  f:close()
  if not s or #s ~= n then error("wsframe: short read from /dev/urandom") end
  return s
end

---------------------------------------------------------------- sha1
local MASK = 0xffffffff
local function rol(x, n) return ((x << n) | (x >> (32 - n))) & MASK end

function M.sha1(msg)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local ml = #msg
  msg = msg .. "\128" .. srep("\0", (55 - ml) % 64) .. spack(">I8", ml * 8)
  local fmt = ">" .. srep("I4", 16)
  local w = {}
  for pos = 1, #msg, 64 do
    local t = { sunpack(fmt, msg, pos) }
    for i = 1, 16 do w[i] = t[i] end
    for i = 17, 80 do w[i] = rol(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1) end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 1, 80 do
      local f, k
      if i <= 20 then f = (b & c) | ((~b & MASK) & d); k = 0x5A827999
      elseif i <= 40 then f = b ~ c ~ d; k = 0x6ED9EBA1
      elseif i <= 60 then f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
      else f = b ~ c ~ d; k = 0xCA62C1D6 end
      local tmp = (rol(a, 5) + f + e + k + w[i]) & MASK
      e, d, c, b, a = d, c, rol(b, 30), a, tmp
    end
    h0 = (h0 + a) & MASK; h1 = (h1 + b) & MASK; h2 = (h2 + c) & MASK
    h3 = (h3 + d) & MASK; h4 = (h4 + e) & MASK
  end
  return spack(">I4I4I4I4I4", h0, h1, h2, h3, h4)
end

function M.hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function M.sha1_hex(s) return M.hex(M.sha1(s)) end

---------------------------------------------------------------- base64
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local c1, c2 = (n >> 18) & 63, (n >> 12) & 63
    local c3, c4 = (n >> 6) & 63, n & 63
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

---------------------------------------------------------------- handshake
function M.new_key() return M.b64encode(M.random_bytes(16)) end
function M.accept_key(key) return M.b64encode(M.sha1(key .. M.GUID)) end

function M.handshake_request(host, port, path, key)
  return table.concat({
    "GET " .. path .. " HTTP/1.1",
    "Host: " .. host .. ":" .. tostring(port),
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "", "",
  }, "\r\n")
end

-- `head` is the raw response head (status line + headers). Returns true or nil,reason.
function M.handshake_ok(head, key)
  local status = head:match("^HTTP/1%.[01]%s+(%d+)")
  if status ~= "101" then return nil, "status " .. tostring(status) end
  local accept, upgrade
  for line in head:gmatch("[^\r\n]+") do
    local k, v = line:match("^([%w%-]+):%s*(.-)%s*$")
    if k then
      k = k:lower()
      if k == "sec-websocket-accept" then accept = v
      elseif k == "upgrade" then upgrade = v:lower() end
    end
  end
  if upgrade ~= "websocket" then return nil, "no websocket upgrade" end
  if accept ~= M.accept_key(key) then return nil, "bad accept key" end
  return true
end

---------------------------------------------------------------- encode
local function apply_mask(payload, key)
  local n = #payload
  local k = sunpack(">I4", key)
  local out, o = {}, 0
  local last = n - (n % 4)
  for i = 1, last, 4 do
    o = o + 1
    out[o] = spack(">I4", sunpack(">I4", payload, i) ~ k)
  end
  for i = last + 1, n do
    o = o + 1
    out[o] = string.char(payload:byte(i) ~ key:byte(((i - 1) % 4) + 1))
  end
  return table.concat(out)
end
M.apply_mask = apply_mask

-- opts: mask (default true), fin (default true), key (4 byte string, tests only)
function M.encode(opcode, payload, opts)
  opts = opts or {}
  payload = payload or ""
  local mask = opts.mask ~= false
  local fin = opts.fin ~= false
  local n = #payload
  local b1 = (fin and 0x80 or 0) | opcode
  local mbit = mask and 0x80 or 0
  local head
  if n < 126 then head = spack("B B", b1, mbit | n)
  elseif n < 65536 then head = spack(">B B I2", b1, mbit | 126, n)
  else head = spack(">B B I8", b1, mbit | 127, n) end
  if not mask then return head .. payload end
  local key = opts.key or M.random_bytes(4)
  return head .. key .. apply_mask(payload, key)
end

---------------------------------------------------------------- decode
local Parser = {}
Parser.__index = Parser

function M.parser(opts)
  opts = opts or {}
  return setmetatable({
    buf = "", frag_op = nil, frag = {}, frag_len = 0,
    max = opts.max_message or M.MAX_MESSAGE, dead = nil,
  }, Parser)
end

-- Feed bytes. Returns list of messages {opcode=, payload=} (control frames
-- included, data frames reassembled) or nil,err on protocol violation.
function Parser:feed(data)
  if self.dead then return nil, self.dead end
  self.buf = self.buf .. data
  local msgs = {}
  local pos = 1
  local buf = self.buf
  while true do
    if #buf - pos + 1 < 2 then break end
    local b1, b2 = buf:byte(pos, pos + 1)
    local fin, rsv, op = (b1 & 0x80) ~= 0, b1 & 0x70, b1 & 0x0f
    local masked, len = (b2 & 0x80) ~= 0, b2 & 0x7f
    local hlen = 2
    if len == 126 then
      hlen = 4
      if #buf - pos + 1 < hlen then break end
      len = sunpack(">I2", buf, pos + 2)
    elseif len == 127 then
      hlen = 10
      if #buf - pos + 1 < hlen then break end
      len = sunpack(">I8", buf, pos + 2)
      if len < 0 or len > self.max then self.dead = "frame too large"; return nil, self.dead end
    end
    if masked then hlen = hlen + 4 end
    if len > self.max then self.dead = "frame too large"; return nil, self.dead end
    if rsv ~= 0 then self.dead = "reserved bits set"; return nil, self.dead end
    local is_ctrl = op >= 8
    if is_ctrl and (not fin or len > 125) then self.dead = "bad control frame"; return nil, self.dead end
    if #buf - pos + 1 < hlen + len then break end
    local payload = buf:sub(pos + hlen, pos + hlen + len - 1)
    if masked then payload = apply_mask(payload, buf:sub(pos + hlen - 4, pos + hlen - 1)) end
    pos = pos + hlen + len
    if is_ctrl then
      if op ~= 8 and op ~= 9 and op ~= 10 then self.dead = "unknown control opcode"; return nil, self.dead end
      msgs[#msgs + 1] = { opcode = op, payload = payload }
    elseif op == 0 then
      if not self.frag_op then self.dead = "unexpected continuation"; return nil, self.dead end
      self.frag[#self.frag + 1] = payload
      self.frag_len = self.frag_len + #payload
      if self.frag_len > self.max then self.dead = "message too large"; return nil, self.dead end
      if fin then
        msgs[#msgs + 1] = { opcode = self.frag_op, payload = table.concat(self.frag) }
        self.frag_op, self.frag, self.frag_len = nil, {}, 0
      end
    elseif op == 1 or op == 2 then
      if self.frag_op then self.dead = "new message inside fragmented one"; return nil, self.dead end
      if fin then
        msgs[#msgs + 1] = { opcode = op, payload = payload }
      else
        self.frag_op, self.frag, self.frag_len = op, { payload }, #payload
      end
    else
      self.dead = "unknown opcode"; return nil, self.dead
    end
  end
  self.buf = pos > 1 and buf:sub(pos) or buf
  return msgs
end

return M
