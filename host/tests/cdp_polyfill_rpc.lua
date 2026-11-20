local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local json = require("json")
local polyfill = require("luna.polyfill")
local rpc = require("luna.rpc")

T.test("tokens are random, 32 hex, no leak across connections", function()
  local a, b = polyfill.new_token(), polyfill.new_token()
  T.ok(a ~= b); T.eq(#a, 32); T.ok(a:match("^%x+$"))
  local ja, jb = polyfill.build(a), polyfill.build(b)
  T.ok(ja:find(a, 1, true)); T.ok(not ja:find(b, 1, true))
  T.ok(jb:find(b, 1, true)); T.ok(not jb:find(a, 1, true))
  -- token is only a closure variable, never assigned to window
  T.ok(not ja:find("w%.__lunaKey")); T.ok(not ja:find("window%.__lunaKey"))
  T.eq(select(2, ja:gsub(a, "")), 1, "token appears exactly once")
  -- masked texts are identical -> nothing else is per-connection
  T.eq((ja:gsub(a, "TOKEN")), (jb:gsub(b, "TOKEN")))
end)

T.test("polyfill shape and idempotency guards", function()
  local js = polyfill.build(polyfill.new_token())
  T.ok(js:find("callServerMethod", 1, true)); T.ok(js:find("__lunaSend", 1, true))
  T.ok(js:find("__lunaResolve", 1, true)); T.ok(js:find("configurable: true", 1, true))
  T.ok(js:find("w.__lunaPending", 1, true), "pending map reused on reinjection")
  T.ok(not pcall(polyfill.build, "short"))
  T.ok(not pcall(polyfill.build, string.rep('"', 20)))
end)

T.test("parse_request validation", function()
  local tok = polyfill.new_token()
  local function req(t) return json.encode(t) end
  local r = polyfill.parse_request(req({ id = "1", fn = "Foo", args = { a = 1 }, k = tok }), tok)
  T.eq(r.id, "1"); T.eq(r.fn, "Foo"); T.eq(r.args.a, 1)
  T.ok(not polyfill.parse_request(req({ id = "1", fn = "Foo", k = "wrong" }), tok))
  T.ok(not polyfill.parse_request(req({ id = "1", fn = "Foo" }), tok))
  T.ok(not polyfill.parse_request(req({ id = "1", fn = "", k = tok }), tok))
  T.ok(not polyfill.parse_request(req({ id = "1", fn = 5, k = tok }), tok))
  T.ok(not polyfill.parse_request(req({ fn = "Foo", k = tok }), tok))
  T.ok(not polyfill.parse_request("not json{", tok))
  T.ok(not polyfill.parse_request(req({ id = "1", fn = "Foo", k = "" }), ""))
  T.ok(not polyfill.parse_request(nil, tok))
end)

T.test("args sorted alphabetically -> positional", function()
  local p = rpc.args_to_positional({ zeta = 3, alpha = 1, mid = 2 })
  T.eq(p.n, 3); T.eq(p[1], 1); T.eq(p[2], 2); T.eq(p[3], 3)
  local q = rpc.args_to_positional(json.decode('{"b":null,"a":"x","c":true}'))
  T.eq(q.n, 3); T.eq(q[1], "x"); T.eq(q[2], nil); T.eq(q[3], true)
  T.eq(rpc.args_to_positional(nil).n, 0)
  T.eq(rpc.args_to_positional({}).n, 0)
  local arr = rpc.args_to_positional({ "x", "y" })
  T.eq(arr.n, 2); T.eq(arr[2], "y")
end)

T.test("results are always JSON strings; errors contained", function()
  local reg = {
    Str = function(s) return s end,
    Tbl = function(a, b) return { sum = a + b } end,
    Num = function() return 42 end,
    Nil = function() end,
    Boom = function() error("kaboom") end,
    Obj = function() error({ message = "structured" }) end,
    Order = function(a, b) return a .. b end,
  }
  T.eq(rpc.call(reg, "Str", { raw = '{"a":1}' }), '{"a":1}')
  T.eq(rpc.call(reg, "Tbl", { x = 1, y = 2 }), '{"sum":3}')
  T.eq(rpc.call(reg, "Num", {}), "42")
  T.eq(rpc.call(reg, "Nil", {}), "null")
  T.eq(rpc.call(reg, "Order", { b = "B", a = "A" }), "AB")
  local e = json.decode(rpc.call(reg, "Boom", {}))
  T.eq(e.success, false); T.ok(e.error:find("kaboom"))
  T.eq(json.decode(rpc.call(reg, "Obj", {})).error, "structured")
  local u = json.decode(rpc.call(reg, "Missing", {}))
  T.eq(u.success, false); T.ok(u.error:find("unknown function"))
  T.eq(json.decode(rpc.call({ A = 1 }, "A", {})).success, false, "non-function entry")
end)

T.test("js_literal is safe", function()
  T.eq(rpc.js_literal('a"b\\c\n'), '"a\\"b\\\\c\\n"')
  T.ok(not rpc.js_literal("\226\128\168"):find("\226\128\168", 1, true))
  T.ok(utf8.len(rpc.js_literal("bad\255byte")), "invalid utf-8 replaced")
end)

T.test("handle() replies via Runtime.evaluate in the calling context; bad token gets nothing", function()
  local sent = {}
  local sess = { evaluate = function(_, expr, _, extra) sent[#sent + 1] = { expr = expr, extra = extra } end }
  local tok = polyfill.new_token()
  local ctx = { registry = { Echo = function(x) return x end }, token = tok }
  T.ok(rpc.handle(sess, ctx, json.encode({ id = "7", fn = "Echo", args = { v = "hi" }, k = tok }), 5))
  T.eq(sent[1].expr, 'window.__lunaResolve("7","hi")'); T.eq(sent[1].extra.contextId, 5)
  T.ok(not rpc.handle(sess, ctx, json.encode({ id = "8", fn = "Echo", k = "nope" }), 5))
  T.eq(#sent, 1)
  -- a raising handler still replies, with an error body
  ctx.registry.Bad = function() error("x") end
  T.ok(rpc.handle(sess, ctx, json.encode({ id = "9", fn = "Bad", k = tok }), 5))
  T.ok(sent[2].expr:find("success", 1, true))
end)

T.finish("cdp_polyfill_rpc")
