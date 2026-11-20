-- SLS Luna SteamGridDB backend smoke test: key storage, search, asset
-- filtering, applying with backup, restore, and the refusal paths.
--
-- The network is a fake http module and HOME is disposable, so this never
-- talks to SteamGridDB and never touches real Steam artwork.
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
      return false
    end,
    join = function(...) return table.concat({ ... }, '/') end,
    list = function() return {} end,
  }
end

local json = require('json')
local home = os.getenv('HOME')
local repo = os.getenv('LUNA_REPO') or '.'

-- A disposable, bootstrapped Steam root with one MostRecent account.
local STEAMID = '76561198000000000'
local ACCOUNT_ID = 39734272
local steam_root = home .. '/.local/share/Steam'
local grid_dir = steam_root .. '/userdata/' .. ACCOUNT_ID .. '/config/grid'
do
  assert(os.execute('mkdir -p ' .. string.format('%q', steam_root .. '/config')))
  local marker = assert(io.open(steam_root .. '/steam.sh', 'wb')); marker:write('#!/bin/sh\n'); marker:close()
  local users = assert(io.open(steam_root .. '/config/loginusers.vdf', 'wb'))
  users:write('"users"\n{\n\t"' .. STEAMID .. '"\n\t{\n\t\t"MostRecent" "1"\n\t}\n}\n')
  users:close()
end

-- Fake SteamGridDB.
local wire = { calls = {}, handles = {}, hang = false, down = false, throw = false }
function wire.get(url, options)
  if wire.throw then error('synthetic network failure') end
  if wire.down then return nil, 'connection refused' end
  table.insert(wire.calls, { url = url, headers = options and options.headers })
  local authorization = options and options.headers and options.headers['Authorization'] or ''
  if url:find('/search/autocomplete/', 1, true) then
    if authorization ~= 'Bearer good-key' then return { status = 401, body = '{"success":false}' } end
    return { status = 200, body = '{"success":true,"data":[{"id":1,"name":"Hades"},{"id":2,"name":"Hades II"}]}' }
  end
  if url:find('dimensions=920x430', 1, true) then
    if authorization ~= 'Bearer good-key' then return { status = 401, body = '{"success":false}' } end
    return { status = 200, body = '{"success":true,"data":[' ..
      '{"id":31,"url":"https://cdn.example/wide1.png","thumb":"https://cdn.example/tw.png",' ..
      '"width":920,"height":430,"mime":"image/png","author":{"name":"artistW"}}]}' }
  end
  if url:find('/heroes/game/1', 1, true) then
    if authorization ~= 'Bearer good-key' then return { status = 401, body = '{"success":false}' } end
    return { status = 200, body = '{"success":true,"data":[' ..
      '{"id":21,"url":"https://cdn.example/hero1.jpg","thumb":"https://cdn.example/th.jpg",' ..
      '"width":1920,"height":620,"mime":"image/jpeg","author":{"name":"artistH"}}]}' }
  end
  if url:find('/logos/game/1', 1, true) then
    if authorization ~= 'Bearer good-key' then return { status = 401, body = '{"success":false}' } end
    return { status = 200, body = '{"success":true,"data":[' ..
      '{"id":41,"url":"https://cdn.example/logo1.png","thumb":"https://cdn.example/tl.png",' ..
      '"width":800,"height":310,"mime":"image/png","author":{"name":"artistL"}}]}' }
  end
  if url:find('/icons/game/1', 1, true) then
    if authorization ~= 'Bearer good-key' then return { status = 401, body = '{"success":false}' } end
    return { status = 200, body = '{"success":true,"data":[' ..
      '{"id":51,"url":"https://cdn.example/icon1.png","thumb":"https://cdn.example/ti.png",' ..
      '"width":256,"height":256,"mime":"image/png","author":{"name":"artistI"}}]}' }
  end
  if url:find('/grids/game/1', 1, true) then
    if authorization ~= 'Bearer good-key' then return { status = 401, body = '{"success":false}' } end
    return { status = 200, body = '{"success":true,"data":[' ..
      '{"id":11,"url":"https://cdn.example/grid1.png","thumb":"https://cdn.example/t1.png",' ..
      '"width":600,"height":900,"style":"alternate","mime":"image/png","author":{"name":"artist1"}},' ..
      '{"id":12,"url":"https://cdn.example/grid2.jpg","thumb":"https://cdn.example/t2.jpg",' ..
      '"width":600,"height":900,"style":"alternate","mime":"image/jpeg","author":{"name":"artist2"}},' ..
      '{"id":13,"url":"https://cdn.example/grid3.webp","width":600,"height":900,"mime":"image/webp"},' ..
      '{"id":14,"url":"https://cdn.example/grid4.png","width":600,"height":900,"mime":"image/png","nsfw":true}' ..
      ']}' }
  end
  if url == 'https://cdn.example/grid1.png' then return { status = 200, body = 'PNG1DATA' } end
  if url == 'https://cdn.example/grid2.jpg' then return { status = 200, body = 'JPG2DATA' } end
  if url == 'https://cdn.example/wide1.png' then return { status = 200, body = 'WIDEDATA' } end
  if url == 'https://cdn.example/hero1.jpg' then return { status = 200, body = 'HERODATA' } end
  if url == 'https://cdn.example/logo1.png' then return { status = 200, body = 'LOGODATA' } end
  if url == 'https://cdn.example/icon1.png' then return { status = 200, body = 'ICONDATA' } end
  return { status = 404, body = '{"success":false}' }
end
-- The async half of the same wire: a handle, and a poll that never waits.
-- `hang` models a dead network (poll never completes), `down` a refused one.
function wire.start(url, options)
  if wire.throw then error('synthetic network failure') end
  table.insert(wire.calls, { url = url, headers = options and options.headers })
  wire.handles[#wire.handles + 1] = { url = url, options = options }
  return { index = #wire.handles }
end
function wire.poll(handle, wait)
  if wire.hang then return false end
  local job = wire.handles[handle.index]
  if not job then return true, nil, 'unknown handle' end
  if wire.down then return true, nil, 'connection refused' end
  return true, wire.get(job.url, job.options)
end
package.preload['http'] = function() return wire end

local backend = dofile(repo .. '/addons/sgdb/plugin/backend/main.lua')
local registry = {}
backend.register(registry)

local function call(name, arg)
  assert(type(registry[name]) == 'function', 'missing RPC: ' .. name)
  if type(arg) ~= 'table' then return json.decode(registry[name](arg)) end
  local keys = {}
  for key in pairs(arg) do
    if type(key) == 'string' then keys[#keys + 1] = key end
  end
  table.sort(keys)
  local vals = {}
  for index, key in ipairs(keys) do vals[index] = arg[key] end
  return json.decode(registry[name](table.unpack(vals, 1, #keys)))
end

local function file_text(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local raw = f:read('*a'); f:close()
  return raw
end

-- ---------------------------------------------------------------- config

local state = call('SlsSgdbGet')
assert(state.success == true and state.hasKey == false and state.apiKey == nil,
  'the key must start unset and never be echoed back')
assert(state.gridDir == grid_dir, 'the grid directory must resolve from loginusers: ' .. tostring(state.gridDir))
assert(state.gridError == '')

local saved = call('SlsSgdbSetKey', { raw = json.encode({ key = 'good-key' }) })
assert(saved.success == true and saved.hasKey == true)
local after = call('SlsSgdbGet')
assert(after.hasKey == true and after.apiKey == nil, 'the full key must never leave the backend')
assert(after.keyMasked == '••••-key', 'the masked hint must show the tail: ' .. tostring(after.keyMasked))

local tested = call('SlsSgdbTest')
assert(tested.success == true, 'a good key must validate: ' .. tostring(tested.error))

call('SlsSgdbSetKey', { raw = json.encode({ key = 'bad-key' }) })
local rejected = call('SlsSgdbTest')
assert(rejected.success == false and rejected.code == 'bad_key', 'a bad key must be reported as such')
local refused = call('SlsSgdbSearch', { raw = json.encode({ term = 'hades' }) })
assert(refused.success == false and refused.code == 'bad_key')
call('SlsSgdbSetKey', { raw = json.encode({ key = 'good-key' }) })

-- ---------------------------------------------------------------- search & assets

local search = call('SlsSgdbSearch', { raw = json.encode({ term = 'hades' }) })
assert(search.success == true and #search.games == 2 and search.games[1].name == 'Hades')
assert(search.games[1].id == 1)

local assets = call('SlsSgdbAssets', { raw = json.encode({ gameId = 1, kind = 'grid' }) })
assert(assets.success == true and #assets.assets == 2, 'webp and nsfw must be filtered out')
assert(assets.assets[1].mime == 'image/png' and assets.assets[1].author == 'artist1')
assert(assets.total == 4)

-- ---------------------------------------------------------------- apply, undo & reset

local applied = call('SlsSgdbApply', { raw = json.encode({ appid = 1145360, kind = 'grid',
  url = 'https://cdn.example/grid1.png', mime = 'image/png' }) })
assert(applied.success == true and applied.backedUp == false, tostring(applied.error))
assert(file_text(grid_dir .. '/1145360p.png') == 'PNG1DATA', 'the image must land in the grid folder')

local replaced = call('SlsSgdbApply', { raw = json.encode({ appid = 1145360, kind = 'grid',
  url = 'https://cdn.example/grid2.jpg', mime = 'image/jpeg' }) })
assert(replaced.success == true and replaced.backedUp == true, 'the previous file must be stashed')
assert(file_text(grid_dir .. '/1145360p.jpg') == 'JPG2DATA')
assert(file_text(grid_dir .. '/1145360p.png') == nil, 'only one extension may remain')
assert(file_text(grid_dir .. '/.sls-luna-history/1145360p/') == nil, 'history is a directory, not a file')

local history = call('SlsSgdbHistory', { raw = json.encode({ appid = 1145360 }) })
assert(history.success == true and history.history.grid == 1, 'one undo step must be recorded')

local undone = call('SlsSgdbUndo', { raw = json.encode({ appid = 1145360, kind = 'grid' }) })
assert(undone.success == true and undone.undone == true, tostring(undone.error))
assert(file_text(grid_dir .. '/1145360p.png') == 'PNG1DATA', 'undo must bring the previous file back')
assert(file_text(grid_dir .. '/1145360p.jpg') == nil)

local empty = call('SlsSgdbUndo', { raw = json.encode({ appid = 1145360, kind = 'wide' }) })
assert(empty.success == false and empty.code == 'empty', 'undo with no history must fail closed')

-- Reset removes the custom file so Steam shows its own art; history survives.
call('SlsSgdbApply', { raw = json.encode({ appid = 620, kind = 'hero',
  url = 'https://cdn.example/grid1.png', mime = 'image/png' }) })
assert(file_text(grid_dir .. '/620_hero.png') == 'PNG1DATA')
local reset = call('SlsSgdbReset', { raw = json.encode({ appid = 620, kind = 'hero' }) })
assert(reset.success == true and reset.removed == true)
assert(file_text(grid_dir .. '/620_hero.png') == nil)
local reset_again = call('SlsSgdbReset', { raw = json.encode({ appid = 620, kind = 'hero' }) })
assert(reset_again.success == true and reset_again.removed == false)

-- ---------------------------------------------------------------- refusals

local bad_mime = call('SlsSgdbApply', { raw = json.encode({ appid = 1145360, kind = 'grid',
  url = 'https://cdn.example/grid3.webp', mime = 'image/webp' }) })
assert(bad_mime.success == false and bad_mime.code == 'mime')
local bad_appid = call('SlsSgdbApply', { raw = json.encode({ appid = 0, kind = 'grid',
  url = 'https://cdn.example/grid1.png', mime = 'image/png' }) })
assert(bad_appid.success == false and bad_appid.code == 'invalid')
local bad_kind = call('SlsSgdbApply', { raw = json.encode({ appid = 1, kind = 'banner',
  url = 'https://cdn.example/grid1.png', mime = 'image/png' }) })
assert(bad_kind.success == false and bad_kind.code == 'invalid')
local missing = call('SlsSgdbApply', { raw = json.encode({ appid = 1, kind = 'grid',
  url = 'https://cdn.example/nope.png', mime = 'image/png' }) })
assert(missing.success == false and missing.code == 'http')
local no_search = call('SlsSgdbSearch', { raw = json.encode({ term = '   ' }) })
assert(no_search.success == false)

-- ---------------------------------------------------------------- accounts

do
  local users = assert(io.open(steam_root .. '/config/loginusers.vdf', 'wb'))
  users:write('"users"\n{\n\t"' .. STEAMID .. '"\n\t{\n\t}\n\t"76561198000000001"\n\t{\n\t}\n}\n')
  users:close()
  local ambiguous = call('SlsSgdbGet')
  assert(ambiguous.gridDir == '' and ambiguous.gridError:find('ambiguous', 1, true) ~= nil,
    'two accounts without MostRecent must be refused: ' .. tostring(ambiguous.gridError))
  -- The override environment variable resolves it anyway.
  local account, note = backend.resolve_account(steam_root)
  assert(account == nil and note:find('ambiguous', 1, true) ~= nil)
end

assert(backend.kind_suffix('grid') == 'p' and backend.kind_suffix('hero') == '_hero'
  and backend.kind_suffix('logo') == '_logo' and backend.kind_suffix('icon') == '_icon'
  and backend.kind_suffix('wide') == '')
assert(backend.account_id(STEAMID) == ACCOUNT_ID)
assert(backend.account_id('123') == nil)

-- ---------------------------------------------------------------- base64

assert(backend.base64('') == '')
assert(backend.base64('a') == 'YQ==')
assert(backend.base64('ab') == 'YWI=')
assert(backend.base64('abc') == 'YWJj')
assert(backend.base64('PNG1DATA') == 'UE5HMURBVEE=')

-- ---------------------------------------------------------------- wide assets

do
  -- The accounts section below poisons loginusers.vdf on purpose; restore a
  -- single MostRecent account for the artwork sections.
  local users = assert(io.open(steam_root .. '/config/loginusers.vdf', 'wb'))
  users:write('"users"\n{\n\t"' .. STEAMID .. '"\n\t{\n\t\t"MostRecent" "1"\n\t}\n}\n')
  users:close()
end

local wide = call('SlsSgdbAssets', { raw = json.encode({ gameId = 1, kind = 'wide' }) })
assert(wide.success == true and #wide.assets == 1 and wide.assets[1].width == 920
  and wide.assets[1].author == 'artistW', 'the wide grid must use the dimension filter')

-- ---------------------------------------------------------------- auto picker

-- The pass must return at once and do its work on the status polls.
local before_auto = #wire.calls
local started = call('SlsSgdbAuto', { raw = json.encode({ appid = 620, gameId = 1 }) })
assert(started.success == true and started.pending == true and started.state == 'running',
  'Auto must return a running job, not wait for the pass')
assert(#wire.calls - before_auto <= 1, 'Auto must not fire every request before replying')
assert(started.job and tonumber(started.job.id) and started.job.total == 5)
assert(#started.results == 5, 'the page needs one row per slot from the first reply')

local auto, polls = started, 0
while auto.state == 'running' and polls < 40 do
  auto = call('SlsSgdbAutoStatus', { raw = json.encode({ id = started.job.id }) })
  polls = polls + 1
end
assert(auto.state == 'done', 'the auto pass must finish, got ' .. tostring(auto.state))
assert(#auto.results == 5, 'the auto picker must cover five slots')
local by_kind = {}
for _, result in ipairs(auto.results) do by_kind[result.kind] = result end
for _, kind in ipairs({ 'grid', 'wide', 'hero', 'logo', 'icon' }) do
  assert(by_kind[kind] and by_kind[kind].ok == true, 'auto must fill ' .. kind .. ': '
    .. tostring(by_kind[kind] and by_kind[kind].error))
end
assert(by_kind.grid.live == true and by_kind.wide.live == true and by_kind.hero.live == true
  and by_kind.logo.live == true and by_kind.icon.live == false,
  'icons have no live update, the other slots do')
assert(file_text(grid_dir .. '/620p.png') == 'PNG1DATA')
assert(file_text(grid_dir .. '/620.png') == 'WIDEDATA')
assert(file_text(grid_dir .. '/620_hero.jpg') == 'HERODATA')
assert(file_text(grid_dir .. '/620_logo.png') == 'LOGODATA')
assert(file_text(grid_dir .. '/620_icon.png') == 'ICONDATA')

-- ---------------------------------------------------------------- live payload

local live = call('SlsSgdbLive', { raw = json.encode({ appid = 620, kind = 'grid' }) })
assert(live.success == true and live.type == 0 and live.extension == 'png'
  and live.base64 == 'UE5HMURBVEE=', 'the live payload must carry the applied file')
local live_wide = call('SlsSgdbLive', { raw = json.encode({ appid = 620, kind = 'wide' }) })
assert(live_wide.success == true and live_wide.type == 3 and live_wide.extension == 'png')
local live_icon = call('SlsSgdbLive', { raw = json.encode({ appid = 620, kind = 'icon' }) })
assert(live_icon.success == false and live_icon.code == 'no_live')
local live_none = call('SlsSgdbLive', { raw = json.encode({ appid = 1145360, kind = 'logo' }) })
assert(live_none.success == false and live_none.code == 'none')

-- ---------------------------------------------------------------- slow & failing network

-- A dead network: Auto still answers at once and the status poll stays cheap
-- (the request is in flight, so it reports pending rather than waiting).
wire.hang = true
local slow = call('SlsSgdbAuto', { raw = json.encode({ appid = 777, gameId = 1 }) })
assert(slow.success == true and slow.state == 'running' and slow.pending == true,
  'Auto must not wait for a request that never answers')
local slow_poll = call('SlsSgdbAutoStatus', { raw = json.encode({ id = slow.job.id }) })
assert(slow_poll.state == 'running' and slow_poll.pending == true and slow_poll.job.done == 0,
  'a hung request must leave the pass pending, not block or fail it')
wire.hang = false

-- A refused connection: every slot reports its own error and the pass still ends.
wire.down = true
local refused = call('SlsSgdbAuto', { raw = json.encode({ appid = 778, gameId = 1 }) })
local failed, tries = refused, 0
while failed.state == 'running' and tries < 30 do
  failed = call('SlsSgdbAutoStatus', { raw = json.encode({ id = refused.job.id }) })
  tries = tries + 1
end
assert(failed.state == 'done', 'a failing pass must end, not hang')
assert(#failed.results == 5)
for _, result in ipairs(failed.results) do
  assert(result.ok == false and type(result.error) == 'string' and result.error ~= '',
    'every failed slot must say why (got ' .. tostring(result.kind) .. ')')
end
assert(failed.results[1].code == 'unavailable', 'the failure code must reach the page')
wire.down = false

-- A synchronous call that throws is reported, never ignored.
wire.throw = true
local threw = call('SlsSgdbApply', { raw = json.encode({ appid = 1, kind = 'grid',
  url = 'https://cdn.example/grid1.png', mime = 'image/png' }) })
assert(threw.success == false and threw.code == 'unavailable'
  and threw.error:find('request failed', 1, true) ~= nil, 'a throwing http.get must become an error reply')
wire.throw = false

-- Any handler that throws at all answers with the shared error shape.
local real_root = backend.steam_root
backend.steam_root = function() error('synthetic failure') end
local guarded = call('SlsSgdbGet')
backend.steam_root = real_root
assert(guarded.success == false and type(guarded.error) == 'string'
  and guarded.error:find('Backend error', 1, true) ~= nil, 'handlers must be pcall-wrapped')

-- Only https artwork URLs are fetched from the RPC path.
local insecure = call('SlsSgdbApply', { raw = json.encode({ appid = 1, kind = 'grid',
  url = 'http://127.0.0.1/secret.png', mime = 'image/png' }) })
assert(insecure.success == false and insecure.code == 'invalid')

-- Without http.start/http.poll the pass falls back to one bounded request per
-- status poll; Auto still returns at once and no single poll runs the pass.
local real_start, real_poll = wire.start, wire.poll
wire.start, wire.poll = nil, nil
local sync_started = call('SlsSgdbAuto', { raw = json.encode({ appid = 779, gameId = 1 }) })
assert(sync_started.success == true and sync_started.state == 'running'
  and sync_started.job.done == 0, 'the blocking fallback must still start as a job')
local calls_before = #wire.calls
local sync_poll = call('SlsSgdbAutoStatus', { raw = json.encode({ id = sync_started.job.id }) })
assert(#wire.calls - calls_before <= 1, 'one poll must not chain requests: '
  .. tostring(#wire.calls - calls_before))
assert(sync_poll.state == 'running', 'one request per poll cannot finish five slots')
wire.start, wire.poll = real_start, real_poll

print('Luna SteamGridDB backend OK: key gate, search, asset filtering, apply/backup/restore, wide, auto job (async, slow, failing), live, refusals, accounts')
