local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local json = require("json")
local injector = require("luna.injector")
local loop = require("luna.loop")

-- Fake Steam: a set of ports, each with a list of targets; fake CDP sessions record injections.
local steam = { ports = {}, cur = 8080, sessions = {}, opens = 0 }

local function fake_open(url, port)
  local p = steam.ports[port]
  local id = url:match("/(%w+)$")
  if not p or not p[id] then return nil, "refused" end
  steam.opens = steam.opens + 1
  local sess = { closed = false, handlers = {}, pending = {}, sock = {}, id = id, port = port,
    inj = 0, done = {} }
  function sess:on(ev, fn) self.handlers[ev] = fn end
  function sess:wants_write() return false end
  function sess:tick() end
  function sess:pump() end
  function sess:flush() end
  function sess:send(_, _, cb) if cb then cb({}, nil) end end
  function sess:evaluate(ex, cb)
    if ex:find("Object.keys(window.__lunaDone", 1, true) then
      self.inj = self.inj + 1
      if cb then cb({ result = { value = {} } }, nil) end
    elseif cb then cb({}, nil) end
  end
  function sess:close(reason)
    if self.closed then return end
    self.closed = true
    if self.handlers.close then self.handlers.close(reason) end
  end
  steam.sessions[#steam.sessions + 1] = sess
  return sess
end

local function make()
  return injector.new({
    port = function() return steam.cur, "test" end,
    verify = function(port) if steam.ports[port] then return true, {} end return false, "no listener" end,
    get = function(port, _)
      local p = steam.ports[port]
      if not p then return nil, "refused" end
      local list = {}
      for id, t in pairs(p) do
        list[#list + 1] = { title = t.title, type = "page", url = t.url,
          webSocketDebuggerUrl = "ws://127.0.0.1:" .. port .. "/devtools/page/" .. id }
      end
      return json.encode(json.array(list)), 200
    end,
    open = fake_open, registry = {},
    assets = { menu = { js = { { id = "luna/panel.js", text = "M" } }, css = {} },
               agent = { js = {}, css = {} }, web = { js = {}, css = {} } },
  })
end

local function live(id, port)
  local n = 0
  for _, s in ipairs(steam.sessions) do
    if s.id == id and s.port == port and not s.closed and s.inj > 0 then n = n + 1 end
  end
  return n
end

local function run(inj, t0, t1)
  local t = t0
  while t < t1 do inj:tick(t); t = t + 0.1 end
  return t
end

T.test("host re-attaches and re-injects across Steam restarts without exiting", function()
  local inj = make()
  local t = 100
  -- no Steam: idle, no error, nothing attached
  t = run(inj, t, 110)
  T.ok(not inj.attached)
  -- Steam appears on a new port, only SharedJSContext at first
  steam.ports[40001] = { a = { title = "SharedJSContext", url = "https://steamloopback.host/x" } }
  steam.cur = 40001
  t = run(inj, t, 116)
  T.eq(live("a", 40001), 1)
  -- the menu target appears later
  steam.ports[40001].m = { title = "Steam", url = "https://steamloopback.host/index.html" }
  t = run(inj, t, 122)
  T.eq(live("m", 40001), 1, "late menu target injected")
  -- menu navigates: new url/title, same ws; session stays and is re-injected on event
  local before = 0
  for _, s in ipairs(steam.sessions) do if s.id == "m" then before = s.inj end end
  for _, s in ipairs(steam.sessions) do if s.id == "m" and s.handlers["Page.frameNavigated"] then
    s.handlers["Page.frameNavigated"]({ frame = {} }) end end
  t = run(inj, t, 123)
  local after = 0
  for _, s in ipairs(steam.sessions) do if s.id == "m" then after = s.inj end end
  T.ok(after > before, "re-injected after navigation")
  -- periodic self-heal re-inject even without any event
  t = run(inj, t, 123 + injector.RECHECK_INTERVAL + 1)
  local healed = 0
  for _, s in ipairs(steam.sessions) do if s.id == "m" then healed = s.inj end end
  T.ok(healed > after, "periodic recheck")
  -- Steam closes: port vanishes, file falls back to 8080 (no listener)
  steam.ports[40001] = nil
  steam.cur = 8080
  t = run(inj, t, t + 20)
  T.ok(not inj.attached)
  -- a new Steam on another port, menu first this time
  steam.ports[51234] = { m = { title = "Steam", url = "https://steamloopback.host/index.html" } }
  steam.cur = 51234
  t = run(inj, t, t + 5)
  T.eq(live("m", 51234), 1)
  steam.ports[51234].a = { title = "SharedJSContext", url = "https://steamloopback.host/x" }
  t = run(inj, t, t + 5)
  T.eq(live("a", 51234), 1)
  -- target replaced under the same port (new ws id): old session dropped, new one injected
  steam.ports[51234].m = nil
  steam.ports[51234].m2 = { title = "Steam", url = "https://steamloopback.host/index.html" }
  t = run(inj, t, t + 5)
  T.eq(live("m2", 51234), 1)
  inj:shutdown()
end)

T.test("loop keeps running with Steam gone (never exits by default)", function()
  local t = 0
  local ticks = 0
  local inj = { sockets = function() return {} end, write_sockets = function() return {} end,
    poll_timeout = function() return 1 end, service = function() end,
    tick = function() ticks = ticks + 1 end, shutdown = function() end }
  local checks = 0
  local code = loop.run({ injector = inj, alive = function() checks = checks + 1; return checks <= 2 end,
    now = function() t = t + 2; return t end, max_iterations = 5000 })
  T.eq(code, nil, "no exit")
  T.ok(ticks > 1000)
end)

T.finish("cdp_restart")
