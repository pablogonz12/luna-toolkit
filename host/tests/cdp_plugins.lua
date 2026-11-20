local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local json = require("json")
local plugins = require("luna.plugins")
local rpc = require("luna.rpc")

local function addon(root, name, body, panel, agent)
  T.write(root .. "/" .. name .. "/backend/main.lua", body)
  if panel then T.write(root .. "/" .. name .. "/public/panel.js", panel) end
  if agent then T.write(root .. "/" .. name .. "/public/agent.js", agent) end
end

T.test("add-on discovery order: luna first, then sorted; skips non-addons", function()
  local root = T.tmpdir()
  for _, n in ipairs({ "zeta", "alpha", "luna", "compressor" }) do addon(root, n, "return {register=function() end}") end
  T.write(root .. "/notanaddon/readme.txt", "x")
  T.write(root .. "/.hidden/backend/main.lua", "return {}")
  local names = plugins.discover_addons(root)
  T.eq(table.concat(names, ","), "luna,alpha,compressor,zeta")
end)

T.test("add-ons register RPC and contribute menu/agent assets", function()
  local root = T.tmpdir()
  addon(root, "luna", "return {register=function(r) r.SlsLunaInfo=function(raw) return '{\"ok\":true}' end end}",
    "PANEL_LUNA", "AGENT_LUNA")
  addon(root, "feat", "return {register=function(r) r.SlsFeat=function() return {x=1} end end}", "PANEL_FEAT", nil)
  addon(root, "broken", "error('boom at load')")
  addon(root, "noreg", "return {}")
  addon(root, "badreg", "return {register=function(r) r.Leaked=function() end; error('nope') end}", "PANEL_BAD")
  local registry = {}
  local st = plugins.load({ addons_dir = root, registry = registry })
  T.eq(#st.addons, 2)
  T.eq(st.addons[1].name, "luna")
  T.ok(registry.SlsLunaInfo and registry.SlsFeat)
  T.eq(registry.Leaked, nil, "failed register is rolled back")
  T.eq(#st.assets.menu.js, 2); T.eq(st.assets.menu.js[1].text, "PANEL_LUNA")
  T.eq(st.assets.menu.js[2].text, "PANEL_FEAT")
  T.eq(#st.assets.agent.js, 1); T.eq(st.assets.agent.js[1].text, "AGENT_LUNA")
  T.eq(#st.assets.web.js, 0, "add-ons never go to web channel")
  T.eq(rpc.call(registry, "SlsFeat", {}), '{"x":1}')
  T.eq(table.concat(plugins.rpc_names(st), ","), "SlsFeat,SlsLunaInfo")
end)

T.test("add-on tick receives (now, injector); errors are contained", function()
  local root = T.tmpdir()
  addon(root, "a", "return {register=function() end, tick=function(now, inj) _G.__TICKED = {now, inj} end}")
  addon(root, "b", "return {register=function() end, tick=function() error('x') end}")
  local st = plugins.load({ addons_dir = root, registry = {} })
  plugins.tick(st, 12.5, "INJ")
  T.eq(_G.__TICKED[1], 12.5); T.eq(_G.__TICKED[2], "INJ")
end)

T.test("legacy plugins: lazy globals, lifecycle, assets, channels", function()
  local home, plug = T.tmpdir(), T.tmpdir()
  T.write(plug .. "/plugin.json", '{"name":"fakeleg","luna":{"channels":["web","agent"]}}')
  T.write(plug .. "/backend/helper.lua", "return {twice=function(x) return x*2 end}")
  T.write(plug .. "/backend/main.lua", [[
local helper = require("helper")
Calls = 0
function Double(a) Calls = Calls + 1; return helper.twice(a) end
function Join(b, a) return a .. b end
Logger = { log = function(m) return "logged:" .. m end }
return { on_load = function() _G.__LEG_LOADED = true end,
         on_frontend_loaded = function() _G.__LEG_FE = (_G.__LEG_FE or 0) + 1 end,
         on_unload = function() _G.__LEG_UNLOADED = true end }
]])
  T.write(plug .. "/public/fake.js", "LEGACY_JS")
  T.write(plug .. "/public/fake.css", "LEGACY_CSS")
  T.write(plug .. "/public/notes.txt", "ignore")
  T.write(home .. "/legacy-plugins.json", json.encode({ plug }))
  local registry = {}
  local st = plugins.load({ luna_home = home, registry = registry })
  T.ok(_G.__LEG_LOADED); T.eq(#st.legacy, 1)
  T.eq(rpc.call(registry, "Double", { n = 21 }), "42")
  T.eq(rpc.call(registry, "Join", { a = "1", b = "2" }), "21")
  T.eq(rpc.call(registry, "Logger.log", { m = "hi" }), "logged:hi")
  -- base functions are not reachable
  for _, bad in ipairs({ "dofile", "print", "require", "setmetatable", "os.execute", "io.open", "Calls" }) do
    T.eq(json.decode(rpc.call(registry, bad, { "x" })).success, false, bad)
  end
  -- assets: css first, then js; only for declared channels
  T.eq(st.assets.web.css[1].text, "LEGACY_CSS"); T.eq(st.assets.web.js[1].text, "LEGACY_JS")
  T.eq(st.assets.agent.js[1].text, "LEGACY_JS"); T.eq(#st.assets.menu.js, 0)
  plugins.frontend_loaded(st, "web"); plugins.frontend_loaded(st, "menu")
  T.eq(_G.__LEG_FE, 1)
  local names = table.concat(plugins.rpc_names(st), ",")
  T.ok(names:find("Double") and names:find("Logger.log") and not names:find("dofile"), names)
  plugins.unload(st); T.ok(_G.__LEG_UNLOADED)
end)

T.test("legacy plugin defaults to web channel; broken plugin skipped", function()
  local home, p1, p2 = T.tmpdir(), T.tmpdir(), T.tmpdir()
  T.write(p1 .. "/plugin.json", '{"name":"w"}'); T.write(p1 .. "/backend/main.lua", "function W() return 1 end")
  T.write(p1 .. "/public/a.js", "A")
  T.write(p2 .. "/plugin.json", '{"name":"bad"}'); T.write(p2 .. "/backend/main.lua", "error('no')")
  T.write(home .. "/legacy-plugins.json", json.encode({ { path = p1 }, p2, "/nonexistent" }))
  local registry = {}
  local st = plugins.load({ luna_home = home, registry = registry })
  T.eq(#st.legacy, 1); T.eq(#st.assets.web.js, 1); T.eq(#st.assets.menu.js, 0)
  T.eq(rpc.call(registry, "W", {}), "1")
end)

T.finish("cdp_plugins")
