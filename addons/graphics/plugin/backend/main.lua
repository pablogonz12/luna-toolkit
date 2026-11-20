-- SLS Luna Graphics backend (read-only).
--
-- Reports what the machine has for frame generation and upscaling management:
-- the GPU and driver, the Vulkan layers present (lsfg-vk), its user config, the
-- Decky plugins that overlap with this area, OptiScaler / OptiScaler Client
-- installs, and the Steam runtime facts. Nothing here installs, downloads or
-- changes anything - installers come later, behind their own gates.
local fs = require('fs')
local json = require('json')
local M = {}
local VERSION = '0.2.0'
local home = os.getenv('HOME') or ''
local sysfs_root = os.getenv('SLS_GRAPHICS_SYSFS') or '/sys'

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local raw = f:read('*a')
  f:close()
  return raw
end

local function trim(text)
  return tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function file_info(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local size = f:seek('end')
  f:close()
  return { path = path, size = size or 0 }
end

-- Lua tables with no entries encode as objects, so every list that crosses the
-- RPC boundary is marked as a real array (the panel tolerates both).
local function as_array(value)
  return json.array(value or {})
end

-- ------------------------------------------------------------------ system

function M.parse_os_release(text)
  local out = {}
  for line in tostring(text or ''):gmatch('[^\r\n]+') do
    local key, value = line:match('^([%w_]+)=(.*)$')
    if key then out[key] = trim((value:gsub('^"', ''):gsub('"$', ''))) end
  end
  return out
end

local VENDOR_NAMES = {
  ['0x1002'] = 'AMD',
  ['0x10de'] = 'NVIDIA',
  ['0x8086'] = 'Intel',
  ['0x13b5'] = 'ARM',
  ['0x5143'] = 'Qualcomm',
}

-- "0x1002" -> "0x1002"; strips whitespace/newlines from sysfs values.
local function clean_hex(value)
  local cleaned = trim(value):lower()
  if cleaned == '' then return nil end
  if not cleaned:match('^0x%x+$') then cleaned = '0x' .. cleaned:gsub('^0x', '') end
  return cleaned
end

-- scan(root, home) -> array of { card, vendor, vendor_name, device, driver, product }
-- `root` is a sysfs root (overridable for tests).
function M.gpu_report(root)
  root = root or sysfs_root
  local drm = root .. '/class/drm'
  local cards = {}
  if fs.exists(drm) then
    local ok, items = pcall(fs.list, drm)
    if ok and type(items) == 'table' then
      for _, item in ipairs(items) do
        local name = tostring(item.name or '')
        if item.is_directory and name:match('^card%d+$') then cards[#cards + 1] = name end
      end
    end
  end
  table.sort(cards)
  local out = {}
  for _, card in ipairs(cards) do
    local device_dir = drm .. '/' .. card .. '/device'
    local vendor = clean_hex(read_file(device_dir .. '/vendor'))
    if vendor then
      local uevent = read_file(device_dir .. '/uevent') or ''
      local driver = uevent:match('DRIVER=([^\n]+)')
      out[#out + 1] = {
        card = card,
        vendor = vendor,
        vendor_name = VENDOR_NAMES[vendor] or 'unknown',
        device = clean_hex(read_file(device_dir .. '/device')) or '',
        driver = trim(driver or ''),
        product = trim(read_file(device_dir .. '/product_name') or ''),
      }
    end
  end
  return as_array(out)
end

-- ------------------------------------------------------------------ lsfg-vk

-- System layer directories are overridable so the detection stays testable on
-- hosts that already have lsfg-vk installed.
local function system_layer_dirs()
  local override = os.getenv('SLS_GRAPHICS_SYSTEM_LAYER_DIRS')
  if override ~= nil then
    local out = {}
    for dir in override:gmatch('[^:]+') do out[#out + 1] = dir end
    return out
  end
  return {
    '/usr/share/vulkan/implicit_layer.d',
    '/usr/local/share/vulkan/implicit_layer.d',
    '/etc/vulkan/implicit_layer.d',
  }
end

-- A layer belongs to lsfg-vk when its file name or manifest mentions it.
local function layer_is_lsfg(name, content)
  if tostring(name):lower():find('lsfg', 1, true) then return true end
  return tostring(content or ''):lower():find('lsfg', 1, true) ~= nil
end

-- lsfg(home_dir, system_dirs) -> { layers = {...}, config = {...} | nil,
-- decky_plugins = {...} }.
function M.lsfg_report(home_dir, system_dirs)
  home_dir = home_dir or home
  local report = { layers = {}, config = nil, decky_plugins = {} }
  local dirs = { home_dir .. '/.local/share/vulkan/implicit_layer.d' }
  for _, dir in ipairs(system_dirs or system_layer_dirs()) do dirs[#dirs + 1] = dir end
  for _, dir in ipairs(dirs) do
    local ok, items = pcall(fs.list, dir)
    if ok and type(items) == 'table' then
      for _, item in ipairs(items) do
        local name = tostring(item.name or '')
        if item.is_directory == false and name ~= '' then
          local content = read_file(dir .. '/' .. name)
          if content and layer_is_lsfg(name, content) then
            local version = content:match('"implementation_version"%s*:%s*(%d+)')
            report.layers[#report.layers + 1] = {
              path = dir .. '/' .. name,
              version = version and tonumber(version) or nil,
            }
          end
        end
      end
    end
  end
  local configCandidates = {
    home_dir .. '/.config/lsfg-vk/conf.toml',
    home_dir .. '/.config/lsfg-vk/config.toml',
  }
  for _, path in ipairs(configCandidates) do
    local info = file_info(path)
    if info then report.config = info; break end
  end
  local pluginCandidates = {
    home_dir .. '/homebrew/plugins/decky-lsfg-vk',
    home_dir .. '/homebrew/plugins/Decky-Framegen',
  }
  for _, path in ipairs(pluginCandidates) do
    if fs.exists(path) then report.decky_plugins[#report.decky_plugins + 1] = path end
  end
  report.layers = as_array(report.layers)
  report.decky_plugins = as_array(report.decky_plugins)
  return report
end

-- ------------------------------------------------------------------ optiscaler

-- OptiScaler is deployed per game (next to the game's executable) and managed
-- by OptiScaler Client; Luna can only look for the management installs and the
-- known user directories. Per-game detection is a later, larger job.
function M.optiscaler_report(home_dir)
  home_dir = home_dir or home
  local app_dir = os.getenv('SLS_GRAPHICS_OPTISCALER_APP') or '/opt/optiscaler-client'
  local candidates = {
    { kind = 'client', path = home_dir .. '/.local/share/OptiScalerClient' },
    { kind = 'client', path = home_dir .. '/Applications/OptiScalerClient' },
    { kind = 'client', path = home_dir .. '/.local/bin/OptiScalerClient' },
    { kind = 'client', path = home_dir .. '/opt/OptiScalerClient' },
    { kind = 'client', path = home_dir .. '/.config/OptiscalerClient' },
    { kind = 'client', path = app_dir },
    { kind = 'files', path = home_dir .. '/.local/share/OptiScaler' },
    { kind = 'files', path = home_dir .. '/.config/optiscaler' },
    { kind = 'files', path = home_dir .. '/.config/OptiScaler' },
  }
  local found = {}
  for _, candidate in ipairs(candidates) do
    if fs.exists(candidate.path) then
      found[#found + 1] = { kind = candidate.kind, path = candidate.path }
    end
  end
  -- A Flatpak install keeps its data under ~/.var/app/<id>; only an id that
  -- names the project is reported.
  local ok_apps, apps = pcall(fs.list, home_dir .. '/.var/app')
  if ok_apps and type(apps) == 'table' then
    for _, item in ipairs(apps) do
      local name = tostring(item.name or '')
      if item.is_directory and name:lower():find('optiscaler', 1, true) then
        found[#found + 1] = { kind = 'client', path = home_dir .. '/.var/app/' .. name }
      end
    end
  end
  return as_array(found)
end

-- ---------------------------------------------------- OptiScaler Client (read)
--
-- The first, read-only step of the Luna port: the client's own database says
-- which games it manages and what it installed there; Luna re-checks the paths
-- so a stale record cannot be presented as a live install. Nothing here writes
-- or downloads anything.

local CLIENT_DIRS = function(home_dir)
  return {
    home_dir .. '/.config/OptiscalerClient',
    home_dir .. '/.config/OptiScalerClient',
  }
end

local function client_game_name(entry, fallback_id)
  local name = tostring(entry.Name or '')
  local appid = tostring(entry.AppId or '')
  if name == '' or name:match('^appid_%d+$') then
    local install = tostring(entry.InstallPath or '')
    local root = install:match('^(.*)/steamapps/common/[^/]+/?$')
    if root and appid:match('^%d+$') then
      local acf = read_file(root .. '/steamapps/appmanifest_' .. appid .. '.acf')
      local resolved = acf and acf:match('"name"%s*"%s*([^"]+)"')
      if resolved and resolved ~= '' then return resolved end
    end
  end
  if name ~= '' then return name end
  if appid ~= '' then return 'App ' .. appid end
  return 'Game ' .. tostring(fallback_id or '?')
end

-- OptiScaler files are deployed next to the game: the top level and one level
-- of subdirectories are enough to see them, and the walk is capped so a huge
-- tree cannot turn one page load into a full disk scan.
local function deployed_files(install)
  local found = {}
  if type(install) ~= 'string' or install == '' then return found end
  local scanned = 0
  local function scan(dir, level)
    if scanned > 60 or #found >= 6 then return end
    scanned = scanned + 1
    local ok, items = pcall(fs.list, dir)
    if not ok or type(items) ~= 'table' then return end
    for _, item in ipairs(items) do
      local name = tostring(item.name or '')
      local lower = name:lower()
      if lower:find('optiscaler', 1, true) ~= nil or lower == 'nvngx.dll' then
        found[#found + 1] = dir .. '/' .. name
      elseif item.is_directory and level < 1 and name ~= '' and name:sub(1, 1) ~= '.' then
        scan(dir .. '/' .. name, level + 1)
      end
    end
  end
  scan(install, 0)
  return found
end

-- optiscaler_client(home_dir) -> nil when the client left no config behind,
-- otherwise a compact read-only report of its managed games.
function M.optiscaler_client(home_dir)
  home_dir = home_dir or home
  local config_dir = nil
  for _, candidate in ipairs(CLIENT_DIRS(home_dir)) do
    if fs.exists(candidate) then config_dir = candidate; break end
  end
  if not config_dir then return nil end
  local raw = read_file(config_dir .. '/games.json')
  local games = {}
  local ok, decoded = pcall(json.decode, raw or '')
  if ok and type(decoded) == 'table' then
    local index = 0
    for _, entry in ipairs(decoded) do
      if type(entry) == 'table' then
        index = index + 1
        if index > 200 then break end
        local install = tostring(entry.InstallPath or '')
        games[#games + 1] = {
          name = client_game_name(entry, index),
          appid = tostring(entry.AppId or ''),
          path = install,
          exists = install ~= '' and fs.exists(install),
          installed = entry.IsOptiscalerInstalled == true,
          files = as_array(deployed_files(install)),
          fsr_version = tostring(entry.FsrVersion or ''),
          fsr_native = entry.FsrIsNative == true,
          fsr_swapped = entry.IsFsr4DllSwapped == true,
          dlss_native = entry.DlssIsNative == true,
          dlss_via = entry.DlssViaOptiscaler == true,
          xess_native = entry.XessIsNative == true,
          xess_via = entry.XessViaOptiscaler == true,
        }
      end
    end
  end
  local ok_cache, cache_versions = pcall(fs.list, config_dir .. '/Cache/OptiScaler')
  local app_dir = os.getenv('SLS_GRAPHICS_OPTISCALER_APP') or '/opt/optiscaler-client'
  return {
    config = config_dir,
    app_dir = fs.exists(app_dir) and app_dir or '',
    managed = #games,
    versions_cached = (ok_cache and type(cache_versions) == 'table') and #cache_versions or 0,
    games = as_array(games),
  }
end

-- ------------------------------------------------------------------ steam

function M.steam_root(home_dir)
  for _, candidate in ipairs({
    home_dir .. '/.steam/steam',
    home_dir .. '/.local/share/Steam',
    home_dir .. '/.steam/debian-installation',
  }) do
    if fs.exists(candidate .. '/steam.sh') then return candidate end
  end
  return nil
end

local SLR_TREES = {
  'SteamLinuxRuntime_sniper',
  'SteamLinuxRuntime_soldier',
  'SteamLinuxRuntime',
}

function M.steam_report(home_dir)
  home_dir = home_dir or home
  local root = M.steam_root(home_dir)
  local report = { root = root or '', runtimes = {}, gamescope = false }
  if root then
    for _, name in ipairs(SLR_TREES) do
      if fs.exists(root .. '/steamapps/common/' .. name) then
        report.runtimes[#report.runtimes + 1] = name
      end
    end
  end
  report.gamescope = fs.exists('/usr/bin/gamescope') or fs.exists('/usr/local/bin/gamescope')
  report.runtimes = as_array(report.runtimes)
  return report
end

-- ------------------------------------------------------------------ registry

local function reply(data) return json.encode(data) end

-- The report walks sysfs, the Vulkan layer dirs, the OptiScaler installs and
-- ~/.var/app. The page asks for it on every refresh, so a successful report is
-- reused for this many seconds and a throw becomes a structured error instead
-- of an empty answer the panel would keep showing as blanks.
local REPORT_TTL = tonumber(os.getenv('SLS_GRAPHICS_CACHE_TTL') or '') or 30
local report_cache = nil

local function build_report()
  local os_release = M.parse_os_release(read_file(
    os.getenv('SLS_GRAPHICS_OS_RELEASE') or '/etc/os-release'))
  local kernel = trim(read_file('/proc/sys/kernel/osrelease') or '')
  return {
    success = true,
    version = VERSION,
    system = {
      distro = os_release.PRETTY_NAME or os_release.NAME or '',
      kernel = kernel,
    },
    gpus = M.gpu_report(),
    lsfg = M.lsfg_report(home),
    optiscaler = M.optiscaler_report(home),
    optiscaler_client = M.optiscaler_client(home),
    steam = M.steam_report(home),
  }
end

function M.register(registry)
  registry.SlsGraphicsGet = function(raw)
    local force = false
    if raw ~= nil then
      local ok, entry = pcall(json.decode, tostring(raw))
      if ok and type(entry) == 'table' and entry.force == true then force = true end
    end
    local now = os.time()
    if not force and report_cache and now - report_cache.at < REPORT_TTL then
      return report_cache.json
    end
    local done, report = pcall(build_report)
    if not done then
      return reply({ success = false,
        error = 'Backend error: ' .. tostring(report):gsub('^.-:%d+: ', '') })
    end
    local ok_encode, encoded = pcall(json.encode, report)
    if not ok_encode or type(encoded) ~= 'string' then
      return reply({ success = false, error = 'The graphics report could not be encoded.' })
    end
    report_cache = { at = now, json = encoded }
    return encoded
  end
end

return M
