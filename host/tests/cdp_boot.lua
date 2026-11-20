local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()

local json = require("json")
local loop = require("luna.loop")
local boot = require("luna.boot")

T.test("loop exits 0 after Steam disappears only when exit_when_gone", function()
  local t = 1000
  local alive = true
  local ticks = 0
  local inj = { sockets = function() return {} end, write_sockets = function() return {} end,
    poll_timeout = function() return 1 end, service = function() end,
    tick = function() ticks = ticks + 1 end, shutdown = function() end }
  local clock = function() t = t + 1; return t end
  local checks = 0
  local code = loop.run({ injector = inj, alive = function() checks = checks + 1; return checks <= 3 end,
    now = function() t = t + 2; return t end, grace = 20, max_iterations = 2000, exit_when_gone = true })
  T.eq(code, 0); T.ok(ticks > 0)
end)

T.test("loop never exits if Steam was never seen", function()
  local t = 0
  local inj = { sockets = function() return {} end, write_sockets = function() return {} end,
    poll_timeout = function() return 1 end, service = function() end, tick = function() end, shutdown = function() end }
  T.eq(loop.run({ injector = inj, alive = function() return false end, now = function() t = t + 5; return t end,
    max_iterations = 50 }), nil)
end)

T.test("boot --dry-run lists add-ons and RPC names, no network", function()
  local root, home = T.tmpdir(), T.tmpdir()
  T.write(root .. "/luna/backend/main.lua", "return {register=function(r) r.SlsLunaInfo=function() end end}")
  T.write(root .. "/other/backend/main.lua", "return {register=function(r) r.SlsOther=function() end end}")
  local out = {}
  local real_print = print
  print = function(s) out[#out + 1] = s end
  local code = boot.main({ "--dry-run", "--addons=" .. root, "--luna-home=" .. home })
  print = real_print
  T.eq(code, 0)
  local r = json.decode(out[1])
  T.eq(table.concat(r.addons, ","), "luna,other")
  T.eq(table.concat(r.rpc, ","), "SlsLunaInfo,SlsOther")
end)

T.test("boot.resolve_paths falls back to Luna sls-addons when Luna addons missing", function()
  local home = T.tmpdir()
  T.write(home .. "/.local/share/Luna/sls-addons/luna/backend/main.lua", "return {register=function() end}")
  local old = os.getenv
  os.getenv = function(k) if k == "HOME" then return home end if k == "LUNA_HOME" then return nil end return old(k) end
  local lh, addons = boot.resolve_paths({})
  os.getenv = old
  T.eq(lh, home .. "/.local/share/Luna")
  T.eq(addons, home .. "/.local/share/Luna/sls-addons")
  T.write(home .. "/.local/share/Luna/addons/luna/backend/main.lua", "return {register=function() end}")
  os.getenv = function(k) if k == "HOME" then return home end if k == "LUNA_HOME" then return nil end return old(k) end
  local _, a2 = boot.resolve_paths({})
  os.getenv = old
  T.eq(a2, home .. "/.local/share/Luna/addons")
end)

T.finish("cdp_boot")
