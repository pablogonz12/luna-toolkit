-- Every add-on in the toolset must load and answer its main RPC on a bare
-- machine: temp HOME (so no Steam tree) and a temp LUNA_HOME. This is the "standalone on luna-host" contract,
-- checked against the real payloads with luna-host's own modules.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/stubs/?.lua;" .. package.path
local T = require("testlib"); T.setup()
-- Production modules (fs, json, millennium, http), not the cdp stubs.
local lua_dir = dir .. "/../lua"
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path
local fs = require("fs")
local json = require("json")

local repo = dir .. "/../.."
local home, luna_home = T.tmpdir(), T.tmpdir() .. "/luna"
T.write(luna_home .. "/addons/.keep", "")

-- Add-ons read HOME/LUNA_HOME at load; point both at empty trees.
local real_getenv = os.getenv
os.getenv = function(key)
  if key == "HOME" then return home end
  if key == "LUNA_HOME" then return luna_home end
  if key == "SLS_PLAYTIME_TRACK_MANIFESTS" or key == "LUNA_REPO" then return nil end
  return real_getenv(key)
end

local ADDONS = {
  { name = "playtime", rpc = "SlsPlaytimeGet" },
  { name = "presence", rpc = "SlsPresenceGet" },
  { name = "compressor", rpc = "SlsCompressorGet" },
  { name = "graphics", rpc = "SlsGraphicsGet" },
  { name = "sgdb", rpc = "SlsSgdbGet" },
}

local registry = {}
local plugins = {}

T.test("every add-on loads with no Steam tree", function()
  T.ok(not fs.exists(home .. "/.local/share/Luna"), "temp HOME must start bare")
  for _, addon in ipairs(ADDONS) do
    local path = repo .. "/addons/" .. addon.name .. "/plugin/backend/main.lua"
    local loaded, plugin = pcall(dofile, path)
    T.ok(loaded, addon.name .. " failed to load: " .. tostring(plugin))
    T.eq(type(plugin), "table", addon.name .. " has no module table")
    T.eq(type(plugin.register), "function", addon.name .. " has no register()")
    local ok, err = pcall(plugin.register, registry)
    T.ok(ok, addon.name .. " register failed: " .. tostring(err))
    plugins[addon.name] = plugin
  end
end)

T.test("every add-on answers its main RPC", function()
  for _, addon in ipairs(ADDONS) do
    local fn = registry[addon.rpc]
    T.eq(type(fn), "function", addon.rpc .. " is not registered")
    local ok, raw = pcall(fn)
    T.ok(ok, addon.rpc .. " raised: " .. tostring(raw))
    T.eq(type(raw), "string", addon.rpc .. " must answer JSON")
    local decoded, value = pcall(json.decode, raw)
    T.ok(decoded and type(value) == "table", addon.rpc .. " answered invalid JSON")
    if addon.name == "playtime" or addon.name == "presence" or addon.name == "sgdb"
      or addon.name == "compressor" then
      T.eq(value.success, true, addon.rpc .. " reported a failure")
    end
  end
end)

T.test("add-on JSON answers stay well formed", function()
  local presence = json.decode(assert(registry.SlsPresenceGet)())
  T.eq(presence.success, true)
  T.eq(type(presence), "table")
end)

os.getenv = real_getenv
T.finish("rt_addons_standalone")
