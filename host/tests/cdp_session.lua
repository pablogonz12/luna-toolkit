local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local json = require("json")
local socket = require("socket")
local ws = require("luna.wsframe")
local injector = require("luna.injector")
local polyfill = require("luna.polyfill")

local PORT = 9222
local targets = {
  { id = "1", title = "Steam", type = "page", url = "https://steamloopback.host/index.html" },
  { id = "2", title = "SharedJSContext", type = "page", url = "https://steamloopback.host/index.html?x" },
  { id = "3", title = "Store", type = "page", url = "https://store.steampowered.com/app/10" },
  { id = "4", title = "Unrelated", type = "page", url = "https://example.com/" },
  { id = "5", title = "store.steampowered.com", type = "page", url = "https://evil.example/https://store.steampowered.com" },
  { id = "6", title = "worker", type = "service_worker", url = "https://store.steampowered.com/sw.js" },
  { id = "7", title = "Community", type = "page", url = "https://steamcommunity.com/id/x" },
}

-- Fake Steam CDP server. State per target id: commands log, live connection, page "done" keys.
local function start_server()
  local S = { log = {}, conns = {}, json_hits = 0, done = {}, evals = {} }
  socket.reset()
  socket.listen(PORT, function(conn)
    local buf, upgraded, parser = "", false, nil
    local tid
    conn.on_data = function(c, data)
      if not upgraded then
        buf = buf .. data
        local head = buf:match("^(.-)\r\n\r\n")
        if not head then return end
        local path = head:match("^GET (%S+)")
        if path == "/json" then
          S.json_hits = S.json_hits + 1
          local list = {}
          for _, t in ipairs(targets) do
            local e = { id = t.id, title = t.title, type = t.type, url = t.url }
            if not S.hide or not S.hide[t.id] then
              e.webSocketDebuggerUrl = "ws://127.0.0.1:" .. PORT .. "/devtools/page/" .. t.id .. (S.gen or "")
              list[#list + 1] = e
            end
          end
          local body = json.encode(json.array(list))
          c:push("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
          c:close()
          return
        end
        tid = path:match("/devtools/page/(%d+)")
        local key = head:match("Sec%-WebSocket%-Key: (%S+)")
        c:push("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " .. ws.accept_key(key) .. "\r\n\r\n")
        upgraded, parser = true, ws.parser()
        S.conns[tid] = c
        S.log[tid] = S.log[tid] or {}
        S.done[tid] = {}
        data = buf:sub(#head + 5)
        if data == "" then return end
      end
      local msgs = assert(parser:feed(data))
      for _, m in ipairs(msgs) do
        if m.opcode == 1 then
          local req = json.decode(m.payload)
          S.log[tid][#S.log[tid] + 1] = req
          local result = {}
          if req.method == "Runtime.evaluate" then
            local ex = req.params.expression
            if ex:find("Object.keys(window.__lunaDone", 1, true) then
              local keys = json.array()
              for k in pairs(S.done[tid]) do keys[#keys + 1] = k end
              result = { result = { type = "object", value = keys } }
            else
              local mk = ex:match('^%(window%.__lunaDone=window%.__lunaDone||{}%)%["(.-)"%]=1$')
              mk = mk or ex:match('^%(window%.__lunaDone=window%.__lunaDone%|%|{}%)%["(.-)"%]=1$')
              if mk then S.done[tid][mk] = true end
              result = { result = { type = "undefined" } }
            end
          end
          c:push(ws.encode(1, json.encode({ id = req.id, result = result }), { mask = false }))
        elseif m.opcode == 8 then
          S.closed_by_client = (S.closed_by_client or 0) + 1
        end
      end
    end
  end)
  function S.event(tid, method, params)
    S.conns[tid]:push(ws.encode(1, json.encode({ method = method, params = params }), { mask = false }))
  end
  function S.methods(tid, method)
    local n = {}
    for _, r in ipairs(S.log[tid] or {}) do if r.method == method then n[#n + 1] = r end end
    return n
  end
  function S.evals_of(tid)
    local out = {}
    for _, r in ipairs(S.methods(tid, "Runtime.evaluate")) do out[#out + 1] = r.params.expression end
    return out
  end
  return S
end

local function make_injector(S, registry)
  local assets = {
    menu = { js = { { id = "luna/panel.js", text = "MENU_JS" } }, css = { { id = "t/menu.css", text = "body{color:red}" } } },
    agent = { js = { { id = "luna/agent.js", text = "AGENT_JS" } }, css = {} },
    web = { js = { { id = "leg/web.js", text = "WEB_JS" } }, css = {} },
  }
  return injector.new({
    port = function() return PORT, "test" end,
    verify = function() return true, { comm = "steamwebhelper" } end,
    registry = registry or {}, assets = assets,
  })
end

local function step(inj, now)
  inj:tick(now)
  inj:service(inj:sockets(), inj:write_sockets())
  inj:tick(now + 0.0001)
end

local function count(list, needle)
  local n = 0
  for _, e in ipairs(list) do if e:find(needle, 1, true) then n = n + 1 end end
  return n
end

T.test("classify: channels by title/origin; never by title for web", function()
  local c = injector.classify
  T.eq(c(targets[1]), "menu"); T.eq(c(targets[2]), "agent"); T.eq(c(targets[3]), "web")
  T.eq(c(targets[4]), nil); T.eq(c(targets[5]), nil); T.eq(c(targets[6]), nil); T.eq(c(targets[7]), "web")
  T.eq(c({ type = "page", title = "SharedJSContext", url = "https://store.steampowered.com/" }), "agent",
    "SharedJSContext never gets web scripts")
  T.eq(injector.origin("https://store.steampowered.com:443/a?b"), "https://store.steampowered.com")
  T.eq(c({ type = "page", title = "x", url = "http://store.steampowered.com/" }), nil, "http is not https")
  T.eq(c({ type = "page", title = "x", url = "https://store.steampowered.com.evil.com/" }), nil)
  T.eq(c({ type = "page", title = "x", url = "https://user@evil.com/store.steampowered.com" }), nil)
end)

T.test("list_targets is read-only and reports channels", function()
  local S = start_server()
  local list = assert(injector.list_targets(PORT))
  T.eq(#list, 7); T.eq(list[1].channel, "menu")
  T.eq(S.json_hits, 1); T.eq(next(S.conns), nil, "no websocket opened")
end)

T.test("attach, inject per channel in order, dedupe", function()
  local S = start_server()
  local inj = make_injector(S)
  step(inj, 100)
  local n = 0
  for _ in pairs(inj.sessions) do n = n + 1 end
  T.eq(n, 4, "Steam, SharedJSContext, Store, Community")
  step(inj, 101)
  step(inj, 101.5)
  T.ok(S.conns["4"] == nil and S.conns["5"] == nil and S.conns["6"] == nil)
  -- menu target
  T.eq(#S.methods("1", "Page.enable"), 1); T.eq(#S.methods("1", "Runtime.enable"), 1)
  local ab = S.methods("1", "Runtime.addBinding")
  T.eq(#ab, 1); T.eq(ab[1].params.name, "__lunaSend")
  local ev = S.evals_of("1")
  T.ok(ev[1]:find("callServerMethod", 1, true), "polyfill first")
  T.ok(ev[2]:find("Object.keys", 1, true))
  T.eq(count(ev, "MENU_JS"), 1); T.eq(count(ev, "AGENT_JS"), 0); T.eq(count(ev, "WEB_JS"), 0)
  T.eq(count(ev, "data-luna-css"), 1)
  local css_i, js_i
  for i, e in ipairs(ev) do
    if e:find("data-luna-css", 1, true) then css_i = i end
    if e == "MENU_JS" then js_i = i end
  end
  T.ok(css_i < js_i, "css before js")
  -- agent only agent, web only web
  T.eq(count(S.evals_of("2"), "AGENT_JS"), 1); T.eq(count(S.evals_of("2"), "WEB_JS"), 0)
  T.eq(count(S.evals_of("3"), "WEB_JS"), 1); T.eq(count(S.evals_of("3"), "AGENT_JS"), 0)
  T.eq(count(S.evals_of("7"), "WEB_JS"), 1)
  -- different tokens per connection
  local t1 = S.evals_of("1")[1]:match('var key = "(%x+)"')
  local t3 = S.evals_of("3")[1]:match('var key = "(%x+)"')
  T.ok(t1 and t3 and t1 ~= t3)
  for _, tid in ipairs({ "1", "2", "3", "7" }) do
    for _, e in ipairs(S.evals_of(tid)) do
      if tid ~= "1" and not e:find("callServerMethod", 1, true) then T.ok(not e:find(t1, 1, true)) end
    end
  end
  -- repeated discovery does not duplicate sessions or injections
  step(inj, 110); step(inj, 112)
  n = 0; for _ in pairs(inj.sessions) do n = n + 1 end
  T.eq(n, 4); T.eq(count(S.evals_of("1"), "MENU_JS"), 1)
  inj:shutdown()
end)

T.test("RPC round trip over the binding", function()
  local S = start_server()
  local inj = make_injector(S, { Hello = function(name, greet) return { msg = greet .. " " .. name } end,
                                  Boom = function() error("bad plugin") end })
  step(inj, 100); step(inj, 101)
  local tok = S.evals_of("1")[1]:match('var key = "(%x+)"')
  local function call(tid, payload, ctx)
    S.event(tid, "Runtime.bindingCalled", { name = "__lunaSend", payload = payload, executionContextId = ctx or 3 })
    step(inj, 102)
  end
  call("1", json.encode({ id = "1", fn = "Hello", args = { name = "Bob", greet = "hi" }, k = tok }))
  local last = S.evals_of("1")
  T.eq(last[#last], 'window.__lunaResolve("1","{\\"msg\\":\\"Bob hi\\"}")')
  local evs = S.methods("1", "Runtime.evaluate")
  T.eq(evs[#evs].params.contextId, 3)
  local before = #S.evals_of("1")
  call("1", json.encode({ id = "2", fn = "Hello", args = {}, k = "wrongtoken" }))
  T.eq(#S.evals_of("1"), before, "bad token: silent drop")
  -- a token from another connection is invalid here
  local tok3 = S.evals_of("3")[1]:match('var key = "(%x+)"')
  call("1", json.encode({ id = "3", fn = "Hello", args = {}, k = tok3 }))
  T.eq(#S.evals_of("1"), before, "cross-connection token rejected")
  call("1", json.encode({ id = "4", fn = "Boom", k = tok }))
  T.ok(S.evals_of("1")[before + 1]:find("success", 1, true))
  call("1", json.encode({ id = "5", fn = "Nope", k = tok }))
  T.ok(S.evals_of("1")[before + 2]:find("unknown function", 1, true))
  -- a binding with another name is ignored
  S.event("1", "Runtime.bindingCalled", { name = "other", payload = json.encode({ id = "6", fn = "Hello", k = tok }) })
  step(inj, 103)
  T.eq(#S.evals_of("1"), before + 2)
  inj:shutdown()
end)

T.test("re-inject on navigation, idempotent on load events", function()
  local saved = injector.RECHECK_INTERVAL
  injector.RECHECK_INTERVAL = 1e9   -- periodic self-heal is covered in cdp_restart.lua
  local S = start_server()
  local inj = make_injector(S)
  step(inj, 100); step(inj, 101)
  local base = count(S.evals_of("3"), "WEB_JS")
  T.eq(base, 1)
  S.event("3", "Page.loadEventFired", {})
  step(inj, 102); step(inj, 102.5)
  T.eq(count(S.evals_of("3"), "WEB_JS"), 1, "already marked done -> not duplicated")
  T.ok(count(S.evals_of("3"), "callServerMethod") >= 2, "polyfill refreshed")
  -- navigation wipes the document: page state reset
  S.done["3"] = {}
  S.event("3", "Page.frameNavigated", { frame = { id = "f", url = "https://store.steampowered.com/x" } })
  step(inj, 103); step(inj, 103.5)
  T.eq(count(S.evals_of("3"), "WEB_JS"), 2)
  -- subframe navigation does not retrigger
  local n = #S.evals_of("3")
  S.event("3", "Page.frameNavigated", { frame = { id = "g", parentId = "f", url = "https://ads.example/" } })
  step(inj, 104); step(inj, 104.5)
  T.eq(#S.evals_of("3"), n)
  S.done["2"] = {}
  S.event("2", "Runtime.executionContextsCleared", {})
  step(inj, 105); step(inj, 105.5)
  T.eq(count(S.evals_of("2"), "AGENT_JS"), 2)
  injector.RECHECK_INTERVAL = saved
  inj:shutdown()
end)

T.test("reconnect after close; Steam restart (new ws urls); target gone", function()
  local S = start_server()
  local inj = make_injector(S)
  step(inj, 100); step(inj, 101)
  T.eq(#S.methods("2", "Runtime.addBinding"), 1)
  -- peer closes the socket
  S.conns["2"]:close()
  step(inj, 102)
  T.ok(inj.sessions["ws://127.0.0.1:" .. PORT .. "/devtools/page/2"] == nil)
  step(inj, 103); step(inj, 104)
  T.eq(#S.methods("2", "Runtime.addBinding"), 2, "re-attached")
  T.eq(count(S.evals_of("2"), "AGENT_JS"), 2, "re-injected into fresh page state")
  -- Steam restart: all targets get new websocket URLs
  S.gen = "-b"
  step(inj, 106); step(inj, 107)
  local n = 0
  for ws_url in pairs(inj.sessions) do n = n + 1; T.ok(ws_url:find("-b", 1, true)) end
  T.eq(n, 4)
  -- target disappears
  S.hide = { ["3"] = true }
  step(inj, 110)
  n = 0; for _ in pairs(inj.sessions) do n = n + 1 end
  T.eq(n, 3)
  inj:shutdown()
end)

T.test("discovery cadence and rejection of untrusted port / bad ws", function()
  local S = start_server()
  local verified = false
  local inj = injector.new({
    port = function() return PORT, "t" end, verify = function() return verified, "nope" end,
    registry = {}, assets = {},
  })
  inj:tick(100)
  T.eq(S.json_hits, 0, "no /json traffic to an unverified port")
  inj:tick(100.1); T.eq(S.json_hits, 0)
  verified = true
  inj.verified_port = nil
  inj:tick(100.2)   -- next_discover was 100.3
  T.eq(S.json_hits, 0)
  inj:tick(100.31); T.eq(S.json_hits, 1)
  T.ok(inj.attached)
  T.ok(inj:poll_timeout(100.32) <= 1.0)
  -- websocket URL pointing elsewhere is refused before any connect
  local cdp = require("luna.cdp")
  T.ok(not cdp.open("ws://10.0.0.5:9222/devtools/page/1", PORT))
  T.ok(not cdp.open("ws://127.0.0.1:9999/devtools/page/1", PORT))
  T.ok(not cdp.open("wss://127.0.0.1:9222/x", PORT))
  inj:shutdown()
end)

T.test("request timeout and close callbacks", function()
  local S = start_server()
  local cdp = require("luna.cdp")
  local sess = assert(cdp.open("ws://127.0.0.1:" .. PORT .. "/devtools/page/9", PORT))
  local got = {}
  sess:send("Some.method", {}, function(r, e) got.r = r; got.e = e end)
  sess:pump()
  T.ok(got.r ~= nil and got.e == nil)
  local t = {}
  sess:send("Never.answered", nil, function(r, e) t.e = e end, 0)
  -- fake server answers every request, so exercise timeout path directly
  sess.pending[sess.nextid] = { cb = function(_, e) t.e = e end, deadline = 0 }
  sess:tick(1)
  T.eq(t.e, "timeout")
  local closed
  sess:on("close", function(r) closed = r end)
  sess:close("bye")
  T.eq(closed, "bye"); T.ok(sess.closed)
  local cb_err
  sess:send("After.close", {}, function(_, e) cb_err = e end)
  T.eq(cb_err, "closed")
end)

T.test("ping gets pong; close frame closes", function()
  local S = start_server()
  local cdp = require("luna.cdp")
  local sess = assert(cdp.open("ws://127.0.0.1:" .. PORT .. "/devtools/page/8", PORT))
  local pongs = {}
  local conn = S.conns["8"]
  local old = conn.on_data
  conn.on_data = function(c, data)
    local m = ws.parser():feed(data)
    if m and m[1] and m[1].opcode == 10 then pongs[#pongs + 1] = m[1].payload else old(c, data) end
  end
  conn:push(ws.encode(9, "pp", { mask = false }))
  sess:pump()
  T.eq(pongs[1], "pp")
  conn:push(ws.encode(8, "\3\232", { mask = false }))
  T.ok(not sess:pump()); T.ok(sess.closed)
end)

T.finish("cdp_session")
