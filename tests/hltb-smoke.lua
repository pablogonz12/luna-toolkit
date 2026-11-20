-- SLS Luna HLTB backend smoke test: the local store, the user-triggered fetch
-- (token dance, expiry retry, rate limiting) and the name matching.
--
-- The network is replaced by a fake `http` module injected through
-- package.preload, so this test never talks to HowLongToBeat.
assert(os.getenv('LUNA_TEST_HOME') == os.getenv('HOME'), 'Test must run in isolated HOME')

-- A small real JSON codec: the backend round-trips its own payloads, so the
-- stub must encode and parse like the real one.
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

-- Fake HowLongToBeat: it echoes the query back as the exact match, which is
-- what the site's ranking does for an unambiguous title. `mode` drives the
-- failure scenarios; the wire is recorded so the token dance can be asserted.
local wire = {
  mode = 'ok',
  expired_armed = false,
  get_calls = 0,
  post_calls = 0,
  last_token = nil,
}
function wire.get(url)
  wire.get_calls = wire.get_calls + 1
  assert(url:find('/api/search/site/init?t=', 1, true), 'init URL shape changed: ' .. tostring(url))
  return { status = 200, body = '{"token":"tok-' .. wire.get_calls .. '"}' }
end
function wire.post(url, body, options)
  wire.post_calls = wire.post_calls + 1
  wire.last_token = options and options.headers and options.headers['x-auth-token']
  assert(url == 'https://howlongtobeat.com/api/search/site', 'search URL shape changed: ' .. tostring(url))
  assert(type(body) == 'string' and body:find('"searchTerms"', 1, true), 'search payload shape changed')
  if wire.mode == 'expired' and wire.expired_armed then
    wire.expired_armed = false
    return { status = 403, body = '{"error":"forbidden"}' }
  end
  if wire.mode == 'ratelimit' then
    return { status = 429, body = '{"error":"slow down"}' }
  end
  if wire.mode == 'noname' then
    return { status = 200, body = '{"count":1,"data":[{"game_id":1,"game_name":"Orion Drift",' ..
      '"comp_main":3600,"comp_plus":7200,"comp_100":10800,"comp_all":4000}]}' }
  end
  if wire.mode == 'garbage' then
    return { status = 200, body = 'not json at all' }
  end
  if wire.mode == 'capture' then
    -- Verbatim rows captured from a real HowLongToBeat search for "Hades"
    -- (three of the five results), so the parser is exercised against the
    -- live response shape and its noise rows, not only against fixtures.
    return { status = 200, body = '{"count":5,"data":[' ..
      '{"game_id":37527,"game_name":"Hades","comp_main":84940,"comp_plus":175028,"comp_100":343055,"comp_all":159766},' ..
      '{"game_id":118387,"game_name":"Hades II","comp_main":115073,"comp_plus":192059,"comp_100":377989,"comp_all":201415},' ..
      '{"game_id":8328,"game_name":"Might & Magic Heroes VI: Shades of Darkness","comp_main":62520,' ..
      '"comp_plus":77940,"comp_100":0,"comp_all":68015}]}' }
  end
  local payload = json.decode(body)
  local query = table.concat(payload.searchTerms, ' ')
  return { status = 200, body = '{"count":1,"data":[{"game_id":1,"game_name":' .. json.encode(query) ..
    ',"comp_main":84940,"comp_plus":175028,"comp_100":343055,"comp_all":159766}]}' }
end
package.preload['http'] = function() return wire end

local home = os.getenv('HOME')
local repo = os.getenv('LUNA_REPO') or '.'
local luna_home = os.getenv('LUNA_HOME') or (home .. '/.local/share/Luna')
local store_path = luna_home .. '/data/hltb.json'

local backend = dofile(repo .. '/addons/luna/plugin/backend/main.lua')
local registry = {}
backend.register(registry)
-- The rate limiter is exercised explicitly below; keep it out of the way for
-- the rest of the scenarios.
backend.min_fetch_interval = 0

-- The host turns an args object into positional arguments ordered by sorted
-- key; RPCs are written for that.
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

local function read_store()
  local f = io.open(store_path, 'rb')
  if not f then return nil end
  local raw = f:read('*a'); f:close()
  return json.decode(raw)
end

-- ---------------------------------------------------------------- matching

assert(backend.normalize('Hades™') == 'hades', 'trademark noise must be stripped')
assert(backend.normalize('  Pokémon   Legends: Arceus ') == 'pokemon legends arceus',
  'accents must fold and spacing must collapse')
assert(backend.normalize('Ori & the Blind Forest') == 'ori the blind forest')
assert(backend.normalize('') == '')

local score, quality = backend.name_score('Hades', 'Hades')
assert(score == 1 and quality == 'exact')
score, quality = backend.name_score('Hades', 'Hades II')
assert(quality == 'strong' and score > 0.5, 'a prefix match must be strong, not exact')
score, quality = backend.name_score('The Witcher 3', 'The Witcher 3: Wild Hunt')
assert(quality == 'strong')
local weak, weak_quality = backend.name_score('Hades', 'Saint Seiya: The Hades')
assert(weak_quality == 'weak' and weak < 0.6, 'a token coincidence must stay below the trust floor')
assert(backend.pick_match({ { game_name = 'Saint Seiya: The Hades' } }, 'Hades') == nil,
  'a shared common word must not be stored')
assert(backend.pick_match({ { game_name = 'Hades II' }, { game_name = 'Hades' } }, 'Hades').game_name == 'Hades',
  'the exact title must win')
assert(backend.pick_match({ { game_name = 'Orion Drift' } }, 'Hades') == nil,
  'no confident match must return nil')
assert(backend.pick_match({ { game_name = 'Pokémon Legends: Arceus' } }, 'Pokemon Legends Arceus').game_name
  == 'Pokémon Legends: Arceus', 'accent-folded titles must still match')

-- ---------------------------------------------------------------- storage

local state = call('SlsHltbGet')
assert(state.success == true and state.count == 0 and next(state.games) == nil, 'the store must start empty')

local out = call('SlsHltbFetch', { appid = 1145360, name = 'Hades' })
assert(out.success == true, 'fetch failed: ' .. tostring(out.error))
assert(out.record.match == 'exact' and out.record.name == 'Hades')
assert(out.record.main == 84940 and out.record.extra == 175028 and out.record.completionist == 343055)
assert(out.record.source == 'hltb-search' and out.record.fetchedAt > 0)
assert(wire.get_calls == 1 and wire.post_calls == 1, 'one init and one search per fetch')

local stored = read_store()
assert(stored and stored.games['1145360'] and stored.games['1145360'].main == 84940,
  'the fetch must persist to hltb.json')

state = call('SlsHltbGet')
assert(state.count == 1 and state.games['1145360'].name == 'Hades')

-- A second backend instance (Steam restart) must see the same store.
local second = dofile(repo .. '/addons/luna/plugin/backend/main.lua')
local second_registry = {}
second.register(second_registry)
local second_state = json.decode(second_registry.SlsHltbGet())
assert(second_state.count == 1, 'the store must survive an add-on reload')

-- ---------------------------------------------------------------- fetch failure modes

wire.mode = 'expired'
wire.expired_armed = true
out = call('SlsHltbFetch', { appid = 1091500, name = 'Cyberpunk 2077' })
assert(out.success == true, 'a 403 must refresh the token and retry: ' .. tostring(out.error))
assert(wire.get_calls == 3 and wire.post_calls == 3, 'retry must fetch a fresh token and POST once more')
assert(wire.last_token == 'tok-3', 'the retry must use the refreshed token, got ' .. tostring(wire.last_token))

wire.mode = 'ratelimit'
local before = call('SlsHltbGet').count
out = call('SlsHltbFetch', { appid = 367520, name = 'Hollow Knight' })
assert(out.success == false and out.code == 'rate_limit' and out.error:find('rate%-limit') ~= nil,
  '429 must surface as a retryable rate-limit code')
assert(call('SlsHltbGet').count == before, 'a rate-limited fetch must not change the store')

wire.mode = 'noname'
out = call('SlsHltbFetch', { appid = 367520, name = 'Hollow Knight' })
assert(out.success == false and out.code == 'no_match', 'a weak match must be refused')
assert(out.error:find('No confident', 1, true) ~= nil)
local refused = call('SlsHltbGet')
assert(refused.count == before + 1, 'the refusal must be remembered once')
assert(refused.games['367520'] and refused.games['367520'].match == 'none')
assert(refused.games['367520'].main == nil, 'a no-match record carries no times')

wire.mode = 'garbage'
out = call('SlsHltbFetch', { appid = 70, name = 'Half-Life' })
assert(out.success == false and out.code == 'unavailable', 'a broken response is a hard failure')
assert(out.error:find('unexpected response', 1, true) ~= nil)
assert(call('SlsHltbGet').count == before + 1, 'a hard failure must not write a record')

wire.mode = 'ok'
out = call('SlsHltbFetch', { appid = 0, name = 'Hades' })
assert(out.success == false and out.code == 'invalid' and out.error:find('Invalid app id', 1, true) ~= nil)
out = call('SlsHltbFetch', { appid = 1145360, name = '   ' })
assert(out.success == false and out.code == 'invalid' and out.error:find('no name', 1, true) ~= nil)

-- ---------------------------------------------------------------- rate limiting

local posts_before = wire.post_calls
backend.min_fetch_interval = 600
out = call('SlsHltbFetch', { appid = 1091500, name = 'Cyberpunk 2077' })
assert(out.success == false and out.code == 'throttled' and out.error:find('Wait a moment', 1, true) ~= nil,
  'back-to-back fetches must be refused politely')
assert(wire.post_calls == posts_before, 'a refused fetch must not reach the network')
backend.min_fetch_interval = 0

-- ---------------------------------------------------------------- manual overrides

out = call('SlsHltbPut', { raw = json.encode({ appid = 367520, name = 'Hollow Knight',
  main = 26.5, extra = 39, completionist = 62 }) })
assert(out.success == true and out.record.match == 'manual' and out.record.source == 'manual')
assert(out.record.main == 95400 and out.record.extra == 140400 and out.record.completionist == 223200,
  'manual hours must be stored as seconds')
assert(out.record.all == nil)

out = call('SlsHltbPut', { raw = json.encode({ appid = 367520 }) })
assert(out.success == false and out.error:find('at least one', 1, true) ~= nil)
out = call('SlsHltbPut', { raw = 'not json' })
assert(out.success == false)

out = call('SlsHltbForget', { appid = 367520 })
assert(out.success == true and out.removed == true)
assert(call('SlsHltbGet').count == before, 'forget must remove exactly one record')
out = call('SlsHltbForget', { appid = 367520 })
assert(out.success == true and out.removed == false)

-- Real captured response shape: "Hades" must win over "Hades II" and the
-- unrelated noise row, and the seconds must map to the right buckets.
wire.mode = 'capture'
out = call('SlsHltbFetch', { appid = 1091500, name = 'Hades' })
assert(out.success == true, 'capture fetch failed: ' .. tostring(out.error))
assert(out.record.match == 'exact' and out.record.name == 'Hades')
assert(out.record.main == 84940 and out.record.extra == 175028 and out.record.completionist == 343055)
assert(out.record.all == 159766)

-- ---------------------------------------------------------------- library

local pushed = call('SlsHltbLibrary', { raw = json.encode({ games = {
  { appid = 1145360, name = 'Hades' },
  { appid = 620, name = 'Portal 2', shortcut = false },
  { appid = 3212112756, name = 'Minecraft', shortcut = true },
  { appid = 1145360, name = 'Hades again' },
  { appid = 0, name = 'bad' },
  { appid = 70, name = '' },
} }) })
assert(pushed.success == true and pushed.count == 3,
  'the inventory must dedupe and validate, got ' .. tostring(pushed.count))
local library_state = call('SlsHltbGet')
assert(type(library_state.library) == 'table' and #library_state.library == 3)
assert(library_state.libraryAt > 0)
local seen_names = {}
for _, entry in ipairs(library_state.library) do seen_names[entry.name] = entry end
assert(seen_names['Hades'] and seen_names['Hades'].name == 'Hades', 'the first duplicate must win')
assert(seen_names['Minecraft'] and seen_names['Minecraft'].shortcut == true)
assert(seen_names['Minecraft'].appid == 3212112756)
assert(seen_names['Portal 2'].shortcut == false)

local fourth = dofile(repo .. '/addons/luna/plugin/backend/main.lua')
local fourth_registry = {}
fourth.register(fourth_registry)
assert(#(json.decode(fourth_registry.SlsHltbGet()).library) == 3,
  'the inventory must survive an add-on reload')

out = call('SlsHltbLibrary', { raw = json.encode({ games = { { appid = 0, name = 'x' } } }) })
assert(out.success == false and out.error:find('No valid games', 1, true) ~= nil)
out = call('SlsHltbLibrary', { raw = 'not json' })
assert(out.success == false)
out = call('SlsHltbLibrary', { raw = json.encode({ games = 'nope' }) })
assert(out.success == false)

out = call('SlsLunaInfo')
-- The expected version is read from the payload itself: releases bump it and
-- the test must not need a matching edit.
local plugin_file = io.open(repo .. '/addons/luna/plugin/plugin.json', 'rb')
local plugin_json = plugin_file and plugin_file:read('*a') or ''
if plugin_file then plugin_file:close() end
local pinned = plugin_json:match('"version"%s*:%s*"([^"]+)"')
assert(pinned, 'the luna payload has no version to pin the test to')
assert(out.success == true and out.version == pinned and type(out.addons) == 'table')
assert(out.prefs and out.prefs.store_hide_followed == nil, 'prefs must start empty')

-- Preferences: the store switch writes here (the store page runs on another
-- origin and cannot read localStorage), values are whitelisted and typed.
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'store_hide_followed', value = true }) })
assert(out.success == true and out.prefs.store_hide_followed == true,
  'the preference was not saved: ' .. tostring(out.error))
out = call('SlsLunaInfo')
assert(out.prefs.store_hide_followed == true, 'the preference did not persist')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'store_hide_followed', value = false }) })
assert(out.success == true and out.prefs.store_hide_followed == false)
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'store_hide_followed', value = 'yes' }) })
assert(out.success == false, 'a wrongly typed preference was accepted')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'nonsense', value = true }) })
assert(out.success == false, 'an unknown preference was accepted')
out = call('SlsLunaPrefsSet', { raw = json.encode({ value = true }) })
assert(out.success == false, 'a keyless preference was accepted')
-- The bridge may hand the payload over already decoded; both shapes work.
out = call('SlsLunaPrefsSet', { payload = { key = 'store_hide_followed', value = true } })
assert(out.success == true and out.prefs.store_hide_followed == true,
  'a decoded table payload must be accepted too')

-- The client settings (beta switch, HLTB order) live here too: boolean and
-- string keys with a value whitelist.
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'beta', value = true }) })
assert(out.success == true and out.prefs.beta == true, 'the beta switch was not saved')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'hltb_order', value = 'long' }) })
assert(out.success == true and out.prefs.hltb_order == 'long', 'the HLTB order was not saved')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'hltb_order', value = 'sideways' }) })
assert(out.success == false, 'an unknown order value was accepted')
out = call('SlsLunaInfo')
assert(out.prefs.beta == true and out.prefs.hltb_order == 'long', 'the client settings did not persist')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'beta', value = 'yes' }) })
assert(out.success == false, 'a wrongly typed beta value was accepted')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'lang', value = 'es' }) })
assert(out.success == true and out.prefs.lang == 'es', 'the language preference was not saved')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'lang', value = 'fr' }) })
assert(out.success == false, 'an unknown language was accepted')
out = call('SlsLunaPrefsSet', { raw = json.encode({ key = 'lang', value = 'en' }) })
assert(out.success == true and out.prefs.lang == 'en', 'the language preference did not switch back')

-- Health: read-only diagnostics, tolerant of a bare environment.
out = call('SlsLunaHealth')
assert(out.success == true and type(out.health) == 'table', 'the health report was not returned')
assert(out.health.version == pinned, 'the health report has no version')
assert(type(out.health.addons) == 'table', 'the add-on list is missing')
assert(type(out.health.account) == 'table', 'the account block is missing')
assert(out.health.steam.localconfigConflicts == 0,
  'the bare harness has no sync conflicts to report')
assert(type(out.health.data) == 'table' and type(out.health.data.prefs) == 'table',
  'the data block is missing')
assert(out.health.data.prefs.beta == true, 'the health report does not carry the preferences')
assert(type(out.health.steam.client) == 'table', 'the Steam client block is missing')

-- Steam client detection: a zero report carries no information, and the
-- installed package manifest wins when runtime logs are stale or missing.
local fake_steam = os.getenv('HOME') .. '/.local/share/Steam'
assert(os.execute('mkdir -p ' .. string.format('%q', fake_steam .. '/package')))
assert(os.execute('mkdir -p ' .. string.format('%q', fake_steam .. '/logs')))
local function steam_build()
  return call('SlsLunaHealth').health.steam.client.build
end
assert(steam_build() == '', 'no logs or manifest must mean no reported build')
local manifest = io.open(fake_steam .. '/package/steam_client_ubuntu12.manifest', 'wb')
manifest:write('"ubuntu12"\n{\n\t"version"\t\t"1792618285"\n}\n')
manifest:close()
assert(steam_build() == '1792618285', 'the installed manifest is ground truth without logs')
local clog = io.open(fake_steam .. '/logs/console_log.txt', 'wb')
clog:write('[x] Client version: 0\n')
clog:close()
assert(steam_build() == '1792618285', 'a zero report must not override the manifest')
clog = io.open(fake_steam .. '/logs/console_log.txt', 'wb')
clog:write('[x] Client version: 111\n[x] Client version: 222\n')
clog:close()
assert(steam_build() == '222', 'the newest nonzero runtime report still wins')

-- Steam client queue: status, queue, cancel round-trip in disposable HOME.
out = call('SlsLunaSteam', { raw = json.encode({ action = 'status' }) })
assert(out.success == true and type(out.steam) == 'table', 'the Steam status was not returned')
assert(out.steam.pending == '', 'nothing may be queued in a fresh harness')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'queue-update' }) })
assert(out.success == true and out.queued == 'update', 'queueing must report the job')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'status' }) })
assert(out.steam.pending == 'update', 'the queued job must be visible')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'queue-cache' }) })
assert(out.success == false, 'a second queue must be refused while one stands')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'cancel' }) })
assert(out.success == true and out.steam.pending == '', 'cancel must clear the queue')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'status' }) })
assert(out.steam.hardLock == false and out.steam.job == '', 'a fresh harness is neither locked nor busy')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'lock; rm -rf /' }) })
assert(out.success == false, 'unknown actions must be refused, never reach a shell')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'lock' }) })
assert(out.success == false, 'without an installed updater the lock must refuse instead of spawning')
out = call('SlsLunaRefresh')
assert(out.success == true and out.refreshPending == false, 'a fresh harness has no refresh queued')
out = call('SlsLunaRefresh', { raw = json.encode({ action = 'queue' }) })
assert(out.success == true and out.refreshPending == true, 'queueing must report the refresh')
out = call('SlsLunaRefresh', { raw = json.encode({ action = 'queue' }) })
assert(out.success == false, 'a second refresh queue must be refused while one stands')
out = call('SlsLunaRefresh', { raw = json.encode({ action = 'cancel' }) })
assert(out.success == true and out.refreshPending == false, 'cancel must clear the refresh')
out = call('SlsLunaRefresh', { raw = json.encode({ action = 'nonsense' }) })
assert(out.success == false, 'an unknown refresh action must be refused')
out = call('SlsLunaSteam', { raw = json.encode({ action = 'pin' }) })
assert(out.success == false, 'pin with no updater copy and no Steam log must fail closed')
out = call('SlsLunaLaunchers')
assert(out.success == true and out.helper == false, 'a fresh harness has no launcher helper')
out = call('SlsLunaLaunchers', { raw = json.encode({ action = 'create' }) })
assert(out.success == false, 'creation with no updater copy must fail closed, not shell out')
out = call('SlsLunaLaunchers', { raw = json.encode({ action = 'nonsense' }) })
assert(out.success == false, 'an unknown launchers action must be refused')
-- Non-blocking fetch: with http.start/http.poll available, SlsHltbFetch never
-- waits on the network. The fake answers each request after two empty polls,
-- reusing the blocking fake's responses so both paths see the same site.
local started = 0
wire.start = function(url, options)
  started = started + 1
  return { url = url, options = options or {}, polls = 2 }
end
wire.poll = function(handle, timeout)
  assert(timeout == 0, 'polling must never wait')
  handle.polls = handle.polls - 1
  if handle.polls > 0 then return false end
  if handle.options.method == 'POST' then
    return true, wire.post(handle.url, handle.options.data, handle.options)
  end
  return true, wire.get(handle.url, handle.options)
end
local function fetch_async(appid, name)
  local pending = 0
  for _ = 1, 40 do
    local result = call('SlsHltbFetch', { appid = appid, name = name })
    if result.code ~= 'pending' then return result, pending end
    assert(result.pending == true and result.success == false, 'a pending fetch must say so')
    pending = pending + 1
  end
  error('the non-blocking fetch never finished')
end
wire.mode = 'ok'
local gets, posts = wire.get_calls, wire.post_calls
out, pending = fetch_async(413150, 'Stardew Valley')
assert(out.success == true and out.record.name == 'Stardew Valley', 'the non-blocking fetch must store a record')
assert(pending >= 2, 'the RPC must return while requests are in flight')
assert(started == 2 and wire.get_calls == gets + 1 and wire.post_calls == posts + 1,
  'one token request and one search, through http.start only')
wire.mode = 'expired'
wire.expired_armed = true
out = fetch_async(504230, 'Celeste')
assert(out.success == true, 'an expired token is refreshed on the non-blocking path too')
assert(started == 6, 'token, rejected search, new token and the retried search')
wire.mode = 'ratelimit'
out = fetch_async(250900, 'The Binding of Isaac')
assert(out.success == false and out.code == 'rate_limit', 'rate limiting is reported, not hidden')
wire.mode = 'ok'
-- An abandoned job expires instead of pinning the game forever.
local first = call('SlsHltbFetch', { appid = 105600, name = 'Terraria' })
assert(first.code == 'pending', 'the first call starts the job')
local before = started
backend.fetch_job_ttl = -1
assert(call('SlsHltbFetch', { appid = 105600, name = 'Terraria' }).code == 'pending')
assert(started == before + 1, 'a stale job is dropped and a fresh token request starts')
backend.fetch_job_ttl = 60
out = fetch_async(105600, 'Terraria')
assert(out.success == true, 'the restarted job completes')
wire.start, wire.poll = nil, nil

-- The update check runs detached: a slow GitHub must not hold the RPC (the
-- host runs every RPC on its single injector thread). The fake updater takes two
-- seconds; the RPC has to answer before it finishes, and the result shows up
-- in the status afterwards.
local tools = luna_home .. '/state'
assert(os.execute('mkdir -p ' .. string.format('%q', tools)))
local fake = io.open(tools .. '/luna.py', 'wb')
fake:write([[
import json, os, sys, time
tools = os.path.dirname(os.path.abspath(__file__))
if sys.argv[1:2] == ['check']:
    time.sleep(2)
    with open(os.path.join(tools, 'update-check.json'), 'w') as out:
        json.dump({'latest': '9.9.9', 'checkedAt': int(time.time()), 'checkError': '',
                   'available': True}, out)
elif sys.argv[1:2] == ['timer']:
    print('unattended updates: ' + sys.argv[2])
]])
fake:close()
out = call('SlsLunaUpdate', { raw = json.encode({ action = 'check', force = true }) })
assert(out.success == true and out.update.checking == true, 'a started check must report checking')
assert(out.update.latest == '', 'the RPC must return before the check has finished')
out = call('SlsLunaUpdate', { raw = json.encode({ action = 'check', force = true }) })
assert(out.success == true and out.update.checking == true, 'a second request joins the running check')
local finished = false
for _ = 1, 50 do
  os.execute('sleep 0.2')
  out = call('SlsLunaUpdate', { raw = json.encode({ action = 'status' }) })
  if not out.update.checking then finished = true; break end
end
assert(finished and out.update.latest == '9.9.9', 'the detached check result must reach the status')
out = call('SlsLunaUpdate', { raw = json.encode({ action = 'timer', value = 'on' }) })
assert(out.success == true and type(out.job) == 'table', 'the timer job returns at once')
local timer_state = out.job.state
for _ = 1, 50 do
  if timer_state ~= 'running' and timer_state ~= 'finishing' then break end
  os.execute('sleep 0.1')
  out = call('SlsLunaUpdate', { raw = json.encode({ action = 'status' }) })
  timer_state = (type(out.job) == 'table' and out.job.state) or timer_state
end
assert(timer_state == 'ok', 'the detached timer job must finish cleanly, got ' .. tostring(timer_state))
local timer_log = io.open(luna_home .. '/state/timer-job.log', 'rb')
assert(timer_log, 'a detached job keeps its output in a log file')
local logged = timer_log:read('*a'); timer_log:close()
assert(logged:find('unattended updates: on'), 'bounded updater runs keep their output')

print('Luna HLTB backend OK: matching, token refresh, rate limits, manual overrides, persistence, prefs, health')
