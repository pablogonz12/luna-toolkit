-- SLS Luna Graphics backend smoke test: read-only detection of the GPU, the
-- lsfg-vk layer and config, OptiScaler installs and the Steam runtime.
--
-- Everything is fixture-driven: HOME is disposable, sysfs is a fake tree and
-- os-release is a fake file, so nothing here depends on the host hardware.
assert(os.getenv('LUNA_TEST_HOME') == os.getenv('HOME'), 'Test must run in isolated HOME')

local function skip(text, pos)
  return (text:find('[^ \t\r\n]', pos) or (#text + 1))
end

local function decode_value(text, pos)
  pos = skip(text, pos)
  local c = text:sub(pos, pos)
  if c == '{' then
    local out = {}
    pos = skip(text, pos + 1)
    if text:sub(pos, pos) == '}' then return out, pos + 1 end
    while true do
      local key
      key, pos = decode_value(text, pos)
      pos = skip(text, pos) + 1 -- ':'
      local value
      value, pos = decode_value(text, pos)
      out[key] = value
      pos = skip(text, pos)
      if text:sub(pos, pos) == '}' then return out, pos + 1 end
      pos = pos + 1 -- ','
    end
  end
  if c == '[' then
    local out = {}
    pos = skip(text, pos + 1)
    if text:sub(pos, pos) == ']' then return out, pos + 1 end
    while true do
      local value
      value, pos = decode_value(text, pos)
      out[#out + 1] = value
      pos = skip(text, pos)
      if text:sub(pos, pos) == ']' then return out, pos + 1 end
      pos = pos + 1 -- ','
    end
  end
  if c == '"' then
    local out, escaped = {}, false
    pos = pos + 1
    while pos <= #text do
      local ch = text:sub(pos, pos)
      if escaped then
        if ch == 'n' then out[#out + 1] = '\n'
        elseif ch == 'r' then out[#out + 1] = '\r'
        elseif ch == 't' then out[#out + 1] = '\t'
        elseif ch == 'u' then
          out[#out + 1] = utf8.char(tonumber(text:sub(pos + 1, pos + 4), 16))
          pos = pos + 4
        else out[#out + 1] = ch end
        escaped = false
      elseif ch == '\\' then escaped = true
      elseif ch == '"' then return table.concat(out), pos + 1
      else out[#out + 1] = ch end
      pos = pos + 1
    end
    error('unterminated string')
  end
  local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
  if number then return tonumber(number), pos + #number end
  if text:sub(pos, pos + 3) == 'true' then return true, pos + 4 end
  if text:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
  if text:sub(pos, pos + 3) == 'null' then return nil, pos + 4 end
  error('unexpected byte at ' .. pos)
end

local function encode(value)
  local kind = type(value)
  if kind == 'nil' then return 'null' end
  if kind == 'boolean' then return value and 'true' or 'false' end
  if kind == 'number' then
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then return string.format('%d', value) end
    return string.format('%.10g', value)
  end
  if kind == 'string' then
    return '"' .. value:gsub('[%z\1-\31\\"]', function(ch)
      if ch == '"' then return '\\"' end
      if ch == '\\' then return '\\\\' end
      if ch == '\n' then return '\\n' end
      if ch == '\r' then return '\\r' end
      if ch == '\t' then return '\\t' end
      return string.format('\\u%04x', ch:byte())
    end) .. '"'
  end
  if kind == 'table' then
    local count, array = 0, true
    for key in pairs(value) do
      count = count + 1
      if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 then array = false end
    end
    if count > 0 and array then
      local parts = {}
      for index = 1, #value do parts[#parts + 1] = encode(value[index]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local names = {}
    for key in pairs(value) do names[#names + 1] = tostring(key) end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do parts[#parts + 1] = encode(name) .. ':' .. encode(value[name]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('cannot encode ' .. kind)
end

package.preload['json'] = function()
  return {
    encode = encode,
    decode = function(text) return decode_value(text, 1) end,
    array = function(t) return t or {} end,
  }
end
package.preload['fs'] = function()
  return {
    create_directories = function(dir)
      local ok = os.execute('mkdir -p ' .. string.format('%q', dir))
      assert(ok == true or ok == 0, 'mkdir failed')
      return true
    end,
    parent_path = function(path) return (path:match('^(.*)/[^/]*$')) or '.' end,
    exists = function(path)
      local f = io.open(path, 'rb')
      if f then f:close(); return true end
      local ok = os.execute('test -d ' .. string.format('%q', path))
      return ok == true or ok == 0
    end,
    join = function(...) return table.concat({ ... }, '/') end,
    -- Real directory listing so the detection code is exercised, not stubbed.
    list = function(dir)
      local out = {}
      local pipe = io.popen("find '" .. dir .. "' -mindepth 1 -maxdepth 1 -printf '%y %f\\n' 2>/dev/null")
      if not pipe then return out end
      for line in pipe:lines() do
        local kind, name = line:match('^(%S) (.*)$')
        if name then out[#out + 1] = { name = name, is_directory = (kind == 'd') } end
      end
      pipe:close()
      return out
    end,
  }
end

local home = os.getenv('HOME')
local repo = os.getenv('LUNA_REPO') or '.'
local json = require('json')
local sysfs = home .. '/sys'
local os_release_path = home .. '/os-release'

local function write(path, content)
  local ok = os.execute('mkdir -p ' .. string.format('%q', path:match('^(.*)/[^/]*$')))
  assert(ok == true or ok == 0)
  local f = assert(io.open(path, 'wb'))
  f:write(content)
  f:close()
end

-- ---------------------------------------------------------------- fixtures

write(os_release_path, 'NAME="Arch Linux"\nPRETTY_NAME="Arch Linux (fixture)"\nID=arch\n')

-- Two GPUs: an AMD card (amdgpu) and an NVIDIA one.
write(sysfs .. '/class/drm/card0/device/vendor', '0x1002\n')
write(sysfs .. '/class/drm/card0/device/device', '0x744c\n')
write(sysfs .. '/class/drm/card0/device/uevent', 'DRIVER=amdgpu\nPCI_ID=1002:744C\n')
write(sysfs .. '/class/drm/card0/device/product_name', 'AMD Radeon RX 7900 XTX (fixture)\n')
write(sysfs .. '/class/drm/card1/device/vendor', '0x10de\n')
write(sysfs .. '/class/drm/card1/device/device', '0x2684\n')
write(sysfs .. '/class/drm/card1/device/uevent', 'DRIVER=nvidia\nPCI_ID=10DE:2684\n')

-- A lsfg-vk layer plus an unrelated Mesa layer that must not be reported.
write(home .. '/.local/share/vulkan/implicit_layer.d/VkLayer_LSFG_vk.json',
  '{"file_format_version":"1.0.0","layer":{"name":"VK_LAYER_LSFG_vk",' ..
  '"implementation_version":2}}')
write(home .. '/.local/share/vulkan/implicit_layer.d/VkLayer_MESA_device_select.json',
  '{"file_format_version":"1.0.0","layer":{"name":"VK_LAYER_MESA_device_select"}}')
write(home .. '/.config/lsfg-vk/conf.toml', '[global]\nenabled = true\n')
write(home .. '/homebrew/plugins/decky-lsfg-vk/plugin.json', '{"name":"decky-lsfg-vk"}')

write(home .. '/.local/share/OptiScalerClient/AppRun', '#!/bin/sh\n')
write(home .. '/.config/optiscaler/settings.ini', 'version=0.9\n')

-- OptiScaler Client: an appid-named record that resolves through the
-- appmanifest, deployed files at two depths, and a manual record.
write(home .. '/.config/OptiscalerClient/games.json',
  '[{"Name":"appid_1133870","AppId":"1133870","InstallPath":"' .. home .. '/Steam/steamapps/common/SE2",'
  .. '"IsOptiscalerInstalled":true,"FsrVersion":"4.0.2.0","FsrIsNative":true,"IsFsr4DllSwapped":false,'
  .. '"DlssIsNative":false,"DlssViaOptiscaler":true},'
  .. '{"Name":"Manual Game","AppId":"","InstallPath":"","IsOptiscalerInstalled":false}]')
write(home .. '/Steam/steamapps/common/SE2/OptiScaler.ini', '[OptiScaler]\n')
write(home .. '/Steam/steamapps/common/SE2/bin/nvngx.dll', 'stub')
write(home .. '/Steam/steamapps/appmanifest_1133870.acf',
  '"AppState"\n{\n\t"appid"\t\t"1133870"\n\t"name"\t\t"Space Engineers 2 (fixture)"\n}\n')
write(home .. '/.config/OptiscalerClient/Cache/OptiScaler/1.2.3/marker', 'x')
write(home .. '/.config/OptiscalerClient/Cache/OptiScaler/2.0.0/marker', 'x')
os.execute('mkdir -p ' .. string.format('%q', home .. '/opt/optiscaler-client'))

write(home .. '/.local/share/Steam/steam.sh', '#!/bin/sh\n')
os.execute('mkdir -p ' .. string.format('%q', home .. '/.local/share/Steam/steamapps/common/SteamLinuxRuntime_sniper'))

local backend = dofile(repo .. '/addons/graphics/plugin/backend/main.lua')
local registry = {}
backend.register(registry)

local function call(name, arg)
  assert(type(registry[name]) == 'function', 'missing RPC: ' .. name)
  return json.decode(registry[name](arg))
end

-- ---------------------------------------------------------------- pure checks

local parsed = backend.parse_os_release('NAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\nID=arch\n')
assert(parsed.PRETTY_NAME == 'Arch Linux' and parsed.ID == 'arch')

local gpus = backend.gpu_report(sysfs)
assert(#gpus == 2, 'both cards must be reported, got ' .. #gpus)
assert(gpus[1].card == 'card0' and gpus[1].vendor == '0x1002' and gpus[1].vendor_name == 'AMD')
assert(gpus[1].driver == 'amdgpu' and gpus[1].product:find('7900 XTX') ~= nil)
assert(gpus[2].vendor_name == 'NVIDIA' and gpus[2].driver == 'nvidia')

local lsfg = backend.lsfg_report(home, {})
assert(#lsfg.layers == 1, 'only the lsfg layer may be reported, got ' .. #lsfg.layers)
assert(lsfg.layers[1].path:find('VkLayer_LSFG_vk.json', 1, true) ~= nil)
assert(lsfg.layers[1].version == 2, 'the layer version must come from the manifest')
assert(lsfg.config and lsfg.config.path:find('conf.toml', 1, true) ~= nil)
assert(#lsfg.decky_plugins == 1)

local opti = backend.optiscaler_report(home)
local kinds, paths = {}, {}
for _, entry in ipairs(opti) do kinds[entry.kind] = true; paths[entry.path] = true end
assert(kinds.client and kinds.files, 'both the client and file installs must be reported')
assert(paths[home .. '/.local/share/OptiScalerClient'] and paths[home .. '/.config/optiscaler'],
  'client and file installs must be listed by path')
assert(paths[home .. '/.config/OptiscalerClient'], 'the OptiScaler Client config dir must count as an install')

local client = backend.optiscaler_client(home)
assert(client and client.config == home .. '/.config/OptiscalerClient', 'the client config must be found')
assert(client.managed == 2 and client.versions_cached == 2, 'managed games and cached versions are wrong')
assert(client.app_dir == home .. '/opt/optiscaler-client', 'the app dir override must be honoured')
local se2 = client.games[1]
assert(se2.name == 'Space Engineers 2 (fixture)', 'the appmanifest name must win over appid_')
assert(se2.exists == true and se2.installed == true, 'the install path must be verified')
assert(#se2.files == 2, 'the top-level and nested OptiScaler files must be found')
assert(se2.fsr_version == '4.0.2.0' and se2.fsr_native == true and se2.dlss_via == true, 'upscaler flags are wrong')
local manual = client.games[2]
assert(manual.name == 'Manual Game' and manual.exists == false and #manual.files == 0, 'a manual record must stay as-is')
assert(backend.optiscaler_client(home .. '/missing-home') == nil, 'no config means no report')

local steam = backend.steam_report(home)
assert(steam.root == home .. '/.local/share/Steam')
assert(#steam.runtimes == 1 and steam.runtimes[1] == 'SteamLinuxRuntime_sniper')

-- Nothing-detected case: empty roots report empty lists, never errors.
assert(#backend.gpu_report(home .. '/missing-sysfs') == 0)
local empty = backend.lsfg_report(home .. '/missing-home', {})
assert(#empty.layers == 0 and empty.config == nil and #empty.decky_plugins == 0)
-- A missing home can still not invent installs; only the absolute app dir (the
-- env override in tests) lives outside it.
for _, entry in ipairs(backend.optiscaler_report(home .. '/missing-home')) do
  assert(entry.path == home .. '/opt/optiscaler-client', 'only the absolute app dir may survive a missing home')
end
assert(backend.steam_report(home .. '/missing-home').root == '')

-- ---------------------------------------------------------------- RPC

local report = call('SlsGraphicsGet')
assert(report.success == true and report.version == '0.2.0')
assert(report.system.distro == 'Arch Linux (fixture)', 'the fake os-release must be used')
assert(type(report.system.kernel) == 'string', 'the kernel must be reported')
assert(#report.gpus == 2)
assert(#report.lsfg.layers == 1 and report.lsfg.config ~= nil)
assert(#report.optiscaler >= 3, 'every install candidate must be reported')
assert(report.optiscaler_client and report.optiscaler_client.managed == 2,
  'the client report must ride along')
assert(#report.steam.runtimes == 1)

-- A refresh is served from the session cache; force rebuilds it.
local again = call('SlsGraphicsGet')
assert(again.success == true and #again.gpus == 2 and again.system.distro == report.system.distro)
local forced = call('SlsGraphicsGet', '{"force":true}')
assert(forced.success == true and #forced.gpus == 2)

-- A throw inside the report becomes a structured error, and the next call
-- recovers instead of leaving the panel on blanks.
local real_gpu = backend.gpu_report
backend.gpu_report = function() error('synthetic failure') end
local broken = call('SlsGraphicsGet', '{"force":true}')
backend.gpu_report = real_gpu
assert(broken.success == false and type(broken.error) == 'string'
  and broken.error:find('Backend error', 1, true) ~= nil, 'the report must be pcall-wrapped')
local recovered = call('SlsGraphicsGet', '{"force":true}')
assert(recovered.success == true and #recovered.gpus == 2, 'a failed report must not be cached')

print('Luna Graphics backend OK: GPU, lsfg-vk layers/config/Decky, OptiScaler + Client, Steam runtime, cache, error shape, empty roots')
