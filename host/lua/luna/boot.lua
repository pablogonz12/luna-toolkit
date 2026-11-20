-- luna-host entry point: boot.main(argv)
local json = require("json")
local log = require("luna.log")
local cefport = require("luna.cefport")
local peer = require("luna.peer")
local plugins = require("luna.plugins")
local injector = require("luna.injector")
local loop = require("luna.loop")

local M = {}

local function parse_args(argv)
  local o = {}
  for _, a in ipairs(argv or {}) do
    if a == "--once-list" then o.once_list = true
    elseif a == "--discover-port" then o.discover_port = true
    elseif a == "--dry-run" then o.dry_run = true
    elseif a == "--quiet" then o.quiet = true
    elseif a:match("^%-%-addons=") then o.addons = a:match("^%-%-addons=(.*)$")
    elseif a:match("^%-%-luna%-home=") then o.luna_home = a:match("^%-%-luna%-home=(.*)$")
    elseif a == "--help" or a == "-h" then o.help = true
    else log.warn("ignoring unknown argument: " .. tostring(a)) end
  end
  return o
end

local USAGE = "usage: luna-host [--once-list] [--discover-port] [--dry-run] [--addons=DIR] [--luna-home=DIR]"

function M.resolve_paths(o)
  local home = os.getenv("HOME") or ""
  local luna_home = o.luna_home or os.getenv("LUNA_HOME")
  if not luna_home or luna_home == "" then luna_home = home .. "/.local/share/Luna" end
  local addons = o.addons or (luna_home .. "/addons")
  if not o.addons and #plugins.discover_addons(addons) == 0 then
    local legacy = home .. "/.local/share/Luna/sls-addons"
    if #plugins.discover_addons(legacy) > 0 then addons = legacy end
  end
  return luna_home, addons, home
end

local function arr(t)
  if json.array then return json.array(t) end
  return t
end

function M.once_list(luna_home, home)
  local opts = { luna_home = luna_home, home = home }
  -- Steam's own cmdline outranks the file; the file then outranks the default.
  local port, source, pid, notes = cefport.discover(opts)
  local out = { port = port, source = source, notes = arr(notes) }
  local ok, info = peer.verify(port)
  out.verified = ok and true or false
  if not ok then
    out.error = tostring(info)
    print(json.encode(out))
    return 1
  end
  -- The port answered: record it as the contract the rest of the host reads,
  -- so nothing outside luna-host has to supply cef_port. Best effort only.
  local wrote = cefport.write(port, { luna_home = luna_home, home = home,
    pid = pid, start = pid and cefport.starttime(pid) or nil })
  out.recorded = wrote == true
  out.peer = info
  local targets, err = injector.list_targets(port)
  if not targets then
    out.error = tostring(err)
    print(json.encode(out))
    return 1
  end
  local list = {}
  for _, t in ipairs(targets) do
    list[#list + 1] = { title = t.title, url = t.url, type = t.type, ws = t.ws,
      channel = t.channel or json.null }
  end
  out.targets = arr(list)
  print(json.encode(out))
  return 0
end

function M.main(argv)
  local o = parse_args(argv)
  if o.help then print(USAGE); return 0 end
  if o.quiet then log.quiet = true end
  local luna_home, addons_dir, home = M.resolve_paths(o)
  if o.discover_port then
    local port, source, wrote, err = cefport.record({ luna_home = luna_home, home = home })
    print(json.encode({ port = port, source = source, written = wrote == true,
      error = err and tostring(err) or json.null }))
    return wrote and 0 or 1
  end
  if o.once_list then return M.once_list(luna_home, home) end

  local registry = {}
  local state = plugins.load({ luna_home = luna_home, addons_dir = addons_dir, registry = registry })
  if o.dry_run then
    local addons, legacy = {}, {}
    for _, a in ipairs(state.addons) do addons[#addons + 1] = a.name end
    for _, p in ipairs(state.legacy) do legacy[#legacy + 1] = p.name end
    print(json.encode({ luna_home = luna_home, addons_dir = addons_dir, addons = arr(addons),
      legacy = arr(legacy), rpc = arr(plugins.rpc_names(state)) }))
    return 0
  end

  -- Own the CEF port: record the one this host will attach to (Steam's cmdline
  -- first, then the existing file, then 8080). No wrapper and no Luna needed.
  local recorded_port, recorded_source, recorded, record_err =
    cefport.record({ luna_home = luna_home, home = home })
  log.info("cef port " .. tostring(recorded_port) .. " (" .. tostring(recorded_source) .. ")"
    .. (recorded and ", recorded in $LUNA_HOME/cef_port" or (", not recorded: " .. tostring(record_err))))
  log.info("luna-host starting; home=" .. luna_home .. " addons=" .. addons_dir)
  local inj = injector.new({
    port = function() local p, s = cefport.read({ luna_home = luna_home, home = home }); return p, s end,
    registry = registry, assets = state.assets, plugins = state,
  })
  local code = loop.run({ injector = inj, plugins = state })
  return code or 0
end

return M
