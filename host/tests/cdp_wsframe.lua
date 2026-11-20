local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local ws = require("luna.wsframe")

T.test("rfc6455 handshake vector", function()
  T.eq(ws.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
end)

T.test("sha1/base64 vectors", function()
  T.eq(ws.sha1_hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  T.eq(ws.sha1_hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
  T.eq(ws.sha1_hex(string.rep("a", 1000)), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
  T.eq(ws.b64encode("f"), "Zg==")
  T.eq(ws.b64encode("fo"), "Zm8=")
  T.eq(ws.b64encode("foo"), "Zm9v")
  T.eq(ws.b64encode("foobar"), "Zm9vYmFy")
end)

T.test("handshake_ok checks accept key and status", function()
  local key = "dGhlIHNhbXBsZSBub25jZQ=="
  local good = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
  T.ok(ws.handshake_ok(good, key))
  T.ok(not ws.handshake_ok(good:gsub("s3pP", "XXXX"), key))
  T.ok(not ws.handshake_ok(good:gsub("101", "200"), key))
  T.eq(#ws.new_key(), 24)
end)

T.test("masked client frame round trip (RFC example)", function()
  -- RFC 6455 5.7: masked "Hello"
  local f = ws.encode(1, "Hello", { key = "\55\250\33\61" })
  T.eq(f, "\129\133\55\250\33\61\127\159\77\81\88")
  local p = ws.parser()
  local m = assert(p:feed(f))
  T.eq(#m, 1); T.eq(m[1].opcode, 1); T.eq(m[1].payload, "Hello")
end)

T.test("unmasked server frame, byte-by-byte feed", function()
  local f = ws.encode(1, "Hello", { mask = false })
  T.eq(f, "\129\5Hello")
  local p = ws.parser()
  local got
  for i = 1, #f do
    local m = assert(p:feed(f:sub(i, i)))
    if #m > 0 then got = m[1] end
  end
  T.eq(got.payload, "Hello")
end)

T.test("16-bit and 64-bit lengths", function()
  local mid = string.rep("x", 300)
  local f = ws.encode(2, mid, { mask = false })
  T.eq(f:byte(2), 126); T.eq(#f, 4 + 300)
  local big = string.rep("\0\255", 40000)   -- 80000 bytes -> 127 form
  local f2 = ws.encode(1, big)
  T.eq(f2:byte(2), 0x80 | 127)
  local m = assert(ws.parser():feed(f2))
  T.eq(m[1].payload, big)
  local m2 = assert(ws.parser():feed(ws.encode(1, big, { mask = false })))
  T.eq(#m2[1].payload, 80000)
end)

T.test("64-bit length header parsed and size limit enforced", function()
  local p = ws.parser({ max_message = 1000 })
  local hdr = "\129\127" .. string.pack(">I8", 5000)
  local m, err = p:feed(hdr)
  T.ok(m == nil and err, "oversized frame must fail")
  local p2 = ws.parser()
  local m2 = assert(p2:feed("\129\127" .. string.pack(">I8", 3) .. "abc"))
  T.eq(m2[1].payload, "abc")
end)

T.test("fragmentation with interleaved ping", function()
  local p = ws.parser()
  local data = ws.encode(1, "Hel", { mask = false, fin = false })
    .. ws.encode(9, "p", { mask = false })
    .. ws.encode(0, "lo ", { mask = false, fin = false })
    .. ws.encode(0, "world", { mask = false })
  local m = assert(p:feed(data))
  T.eq(#m, 2)
  T.eq(m[1].opcode, 9); T.eq(m[1].payload, "p")
  T.eq(m[2].opcode, 1); T.eq(m[2].payload, "Hello world")
end)

T.test("protocol violations", function()
  T.ok(not ws.parser():feed("\0\0"), "stray continuation")
  T.ok(not ws.parser():feed("\209\0"), "rsv bit")
  T.ok(not ws.parser():feed("\9\0"), "fragmented control (fin=0, ping)")
  T.ok(not ws.parser():feed("\137\126\0\200"), "oversize control")
  T.ok(not ws.parser():feed(ws.encode(1, "a", { mask = false, fin = false }) .. ws.encode(1, "b", { mask = false })), "new msg mid-fragment")
end)

T.test("close frame", function()
  local m = assert(ws.parser():feed(ws.encode(8, "\3\232", { mask = false })))
  T.eq(m[1].opcode, 8)
end)

T.test("split at every byte, multi-frame chunks, big payloads", function()
  local big = string.rep("x", 70000)
  local frames = ws.encode(1, "a", { mask = false }) .. ws.encode(1, string.rep("y", 300), { mask = false })
  for cut = 1, #frames - 1 do
    local p = ws.parser()
    local m1 = assert(p:feed(frames:sub(1, cut)))
    local m2 = assert(p:feed(frames:sub(cut + 1)))
    T.eq(#m1 + #m2, 2, "cut " .. cut)
  end
  local p = ws.parser()
  local m = assert(p:feed(ws.encode(1, big, { mask = false }) .. ws.encode(1, "z", { mask = false })))
  T.eq(#m, 2); T.eq(#m[1].payload, 70000)
  local mb = string.rep("q", 1048576)
  p = ws.parser()
  local data, out = ws.encode(1, mb), {}
  for i = 1, #data, 4099 do
    for _, x in ipairs(assert(p:feed(data:sub(i, i + 4098)))) do out[#out + 1] = x end
  end
  T.eq(#out, 1); T.ok(out[1].payload == mb)
end)

T.test("real socket.lua receive(n) consumes partial on timeout", function()
  package.loaded["luna_core"] = nil
  local feeds = { "abc", "def" }
  package.preload["luna_core"] = function()
    return { gettime = os.time, sleep = function() end, monotonic = os.clock,
      tcp_recv = function() local d = table.remove(feeds, 1); if d then return d end; return nil, "timeout" end,
      select = function() return nil end }
  end
  local ok, real = pcall(dofile, dir .. "/../lua/socket.lua")
  assert(ok, real)
  local s = real.tcp(); s:setfd(1); s:settimeout(0)
  local d, e, part = s:receive(65536)
  T.eq(e, "timeout"); T.eq(part, "abcdef")
  local _, _, part2 = s:receive(65536)
  T.eq(part2, "", "partial not re-delivered")
end)

T.finish("cdp_wsframe")
