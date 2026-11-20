-- Plugin loading: Luna add-ons (backend/main.lua with register(registry)) and
-- optional legacy "Millennium-style" plugins listed in $LUNA_HOME/legacy-plugins.json.
local json = require("json")
local log = require("luna.log")

local M = {}

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function list_dirs(dir)
  local out = {}
  local ok, fs = pcall(require, "fs")
  if ok and type(fs) == "table" and type(fs.list) == "function" then
    local ok2, items = pcall(fs.list, dir)
    if ok2 and type(items) == "table" then
      for _, it in ipairs(items) do
        if it.is_directory then out[#out + 1] = tostring(it.name) end
      end
      return out
    end
  end
  local p = io.popen("ls -1p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
  if p then
    for line in p:lines() do
      if line:sub(-1) == "/" then out[#out + 1] = line:sub(1, -2) end
    end
    p:close()
  end
  return out
end

local function new_assets()
  local t = {}
  for _, ch in ipairs({ "menu", "agent", "web" }) do t[ch] = { js = {}, css = {} } end
  return t
end

local function add_asset(assets, channel, kind, id, text)
  local ch = assets[channel]
  if not ch or not text then return end
  ch[kind][#ch[kind] + 1] = { id = id, text = text }
end

-- Names of directories under addons_dir that ship backend/main.lua; "luna" first, rest sorted.
function M.discover_addons(addons_dir)
  local names = {}
  for _, name in ipairs(list_dirs(addons_dir)) do
    if name:sub(1, 1) ~= "." and not name:find("/", 1, true) and read(addons_dir .. "/" .. name .. "/backend/main.lua") then
      names[#names + 1] = name
    end
  end
  table.sort(names, function(a, b)
    if a == "luna" then return b ~= "luna" end
    if b == "luna" then return false end
    return a < b
  end)
  return names
end

local function load_addon(state, registry, addons_dir, name)
  local root = addons_dir .. "/" .. name
  local ok, plugin = pcall(dofile, root .. "/backend/main.lua")
  if not ok or type(plugin) ~= "table" or type(plugin.register) ~= "function" then
    log.warn("add-on " .. name .. " failed to load: " .. tostring(ok and "no register()" or plugin))
    return
  end
  local before = {}
  for k in pairs(registry) do before[k] = true end
  local reg_ok, err = pcall(plugin.register, registry)
  if not reg_ok then
    log.warn("add-on " .. name .. " register failed: " .. tostring(err))
    for k in pairs(registry) do if not before[k] then registry[k] = nil end end
    return
  end
  local ui, control = read(root .. "/public/panel.js"), read(root .. "/public/agent.js")
  add_asset(state.assets, "menu", "js", name .. "/panel.js", ui)
  add_asset(state.assets, "agent", "js", name .. "/agent.js", control)
  state.addons[#state.addons + 1] = { name = name, root = root, plugin = plugin }
  log.info("add-on loaded: " .. name)
end

---------------------------------------------------------------- legacy plugins
local VALID_CHANNELS = { menu = true, agent = true, web = true }

local function safe_rel(p)
  return type(p) == "string" and p ~= "" and not p:find("..", 1, true) and p:sub(1, 1) ~= "/"
end

-- Read asset list from the plugin root: explicit luna.assets or every public/*.js|css.
local function legacy_assets(root, manifest)
  local lunacfg = type(manifest.luna) == "table" and manifest.luna or {}
  local files = {}
  if type(lunacfg.assets) == "table" then
    for _, a in ipairs(lunacfg.assets) do
      if safe_rel(a) then files[#files + 1] = (a:gsub("^webkit/", "")) end
    end
  else
    local pub = root .. "/public"
    local p = io.popen("ls -1p '" .. pub:gsub("'", "'\\''") .. "' 2>/dev/null")
    if p then
      for line in p:lines() do
        if line:sub(-1) ~= "/" and (line:match("%.js$") or line:match("%.css$")) then files[#files + 1] = line end
      end
      p:close()
    end
    table.sort(files)
    -- css first so styles exist before scripts run
    table.sort(files, function(a, b)
      local ac, bc = a:match("%.css$") ~= nil, b:match("%.css$") ~= nil
      if ac ~= bc then return ac end
      return a < b
    end)
  end
  return files
end

local function snapshot_globals()
  local snap = {}
  for k, v in pairs(_G) do snap[k] = v end
  return snap
end

local function exposed_globals(registry_meta, baseline)
  return function(_, name)
    if type(name) ~= "string" then return nil end
    local base, rest = name:match("^([%w_]+)%.([%w_]+)$")
    local v
    if base then
      if baseline[base] ~= nil and baseline[base] == _G[base] then return nil end
      local t = rawget(_G, base)
      if type(t) == "table" then v = t[rest] end
    else
      if baseline[name] ~= nil and baseline[name] == rawget(_G, name) then return nil end
      v = rawget(_G, name)
    end
    if type(v) == "function" then return v end
    return nil
  end
end

local function load_legacy(state, registry, entry)
  local root, channels = entry.path, entry.channels
  if type(root) ~= "string" or root == "" then return end
  local manifest = json.decode(read(root .. "/plugin.json") or "{}")
  if type(manifest) ~= "table" then manifest = {} end
  local mainpath = root .. "/backend/main.lua"
  if not read(mainpath) then
    log.warn("legacy plugin " .. root .. ": backend/main.lua missing")
    return
  end
  if not channels and type(manifest.luna) == "table" then channels = manifest.luna.channels end
  if type(channels) ~= "table" or #channels == 0 then channels = { "web" } end
  local chset = {}
  for _, c in ipairs(channels) do if VALID_CHANNELS[c] then chset[#chset + 1] = c end end

  local base = root .. "/backend/"
  package.path = base .. "?.lua;" .. base .. "?/init.lua;" .. package.path
  local uok, U = pcall(require, "utils") -- absent in plain-Lua unit tests
  if uok and type(U) == "table" and U.set_backend_path then U.set_backend_path(root .. "/backend") end
  local baseline = snapshot_globals()
  local ok, lifecycle = pcall(dofile, mainpath)
  if not ok then
    log.warn("legacy plugin " .. tostring(manifest.name or root) .. " failed to load: " .. tostring(lifecycle))
    return
  end
  local name = tostring(manifest.name or root:match("([^/]+)/*$") or "legacy")
  local resolver = exposed_globals(nil, baseline)
  -- Lazy lookup at call time; only functions the plugin itself defined are reachable.
  local lazy = setmetatable({}, { __index = resolver })
  state.legacy[#state.legacy + 1] = {
    name = name, root = root, lifecycle = type(lifecycle) == "table" and lifecycle or {},
    channels = chset, lazy = lazy,
  }
  for _, f in ipairs(legacy_assets(root, manifest)) do
    local text = read(root .. "/public/" .. f) or read(root .. "/" .. f)
    local kind = f:match("%.css$") and "css" or "js"
    for _, ch in ipairs(chset) do add_asset(state.assets, ch, kind, name .. "/" .. f, text) end
  end
  local entry_state = state.legacy[#state.legacy]
  entry_state.names = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and baseline[k] ~= v then
      if type(v) == "function" then entry_state.names[#entry_state.names + 1] = k
      elseif type(v) == "table" and baseline[k] == nil then
        for k2, v2 in pairs(v) do
          if type(k2) == "string" and type(v2) == "function" then
            entry_state.names[#entry_state.names + 1] = k .. "." .. k2
          end
        end
      end
    end
  end
  local lc = entry_state.lifecycle
  if type(lc.on_load) == "function" then
    local lok, lerr = pcall(lc.on_load)
    if not lok then log.warn("legacy plugin " .. name .. " on_load failed: " .. tostring(lerr)) end
  end
  log.info("legacy plugin loaded: " .. name)
end

-- Chain: the registry falls back to legacy plugins' lazily resolved globals.
local function install_legacy_fallback(registry, state)
  if #state.legacy == 0 then return end
  local mt = getmetatable(registry) or {}
  local prev = mt.__index
  mt.__index = function(t, k)
    if type(prev) == "function" then local v = prev(t, k); if v ~= nil then return v end
    elseif type(prev) == "table" and prev[k] ~= nil then return prev[k] end
    for _, p in ipairs(state.legacy) do
      local v = p.lazy[k]
      if v ~= nil then return v end
    end
    return nil
  end
  setmetatable(registry, mt)
end

local function read_legacy_list(luna_home)
  local text = read(luna_home .. "/legacy-plugins.json")
  if not text then return {} end
  local ok, list = pcall(json.decode, text)
  if not ok or type(list) ~= "table" then
    log.warn("legacy-plugins.json is not valid JSON")
    return {}
  end
  local out = {}
  for _, e in ipairs(list) do
    if type(e) == "string" then out[#out + 1] = { path = e }
    elseif type(e) == "table" and type(e.path) == "string" then out[#out + 1] = { path = e.path, channels = e.channels } end
  end
  return out
end

-- opts: luna_home, addons_dir, registry. Returns state.
function M.load(opts)
  local registry = opts.registry
  local state = { addons = {}, legacy = {}, assets = new_assets(), registry = registry }
  if opts.addons_dir then
    for _, name in ipairs(M.discover_addons(opts.addons_dir)) do
      load_addon(state, registry, opts.addons_dir, name)
    end
  end
  if opts.luna_home then
    for _, entry in ipairs(read_legacy_list(opts.luna_home)) do
      load_legacy(state, registry, entry)
    end
  end
  install_legacy_fallback(registry, state)
  return state
end

-- Names callable over RPC: registered keys (legacy globals are resolved lazily, so listed per plugin).
function M.rpc_names(state)
  local names = {}
  for k, v in pairs(state.registry) do
    if type(v) == "function" then names[#names + 1] = tostring(k) end
  end
  for _, p in ipairs(state.legacy) do
    for _, n in ipairs(p.names or {}) do names[#names + 1] = n end
  end
  table.sort(names)
  return names
end

function M.frontend_loaded(state, channel)
  for _, p in ipairs(state.legacy) do
    for _, c in ipairs(p.channels) do
      if c == channel and type(p.lifecycle.on_frontend_loaded) == "function" then
        local ok, err = pcall(p.lifecycle.on_frontend_loaded)
        if not ok then log.warn("legacy plugin " .. p.name .. " on_frontend_loaded: " .. tostring(err)) end
        break
      end
    end
  end
end

function M.tick(state, now, injector)
  for _, a in ipairs(state.addons) do
    local f = a.plugin.tick or a.plugin.background
    if type(f) == "function" then
      local ok, err = pcall(f, now, injector)
      if not ok then log.warn("add-on " .. a.name .. " tick: " .. tostring(err)) end
    end
  end
  for _, p in ipairs(state.legacy) do
    local f = p.lifecycle.on_tick or p.lifecycle.background
    if type(f) == "function" then
      local ok, err = pcall(f, now, injector)
      if not ok then log.warn("legacy plugin " .. p.name .. " tick: " .. tostring(err)) end
    end
  end
end

function M.unload(state)
  for _, p in ipairs(state.legacy) do
    if type(p.lifecycle.on_unload) == "function" then pcall(p.lifecycle.on_unload) end
  end
  for _, a in ipairs(state.addons) do
    if type(a.plugin.on_unload) == "function" then pcall(a.plugin.on_unload) end
  end
end

return M
