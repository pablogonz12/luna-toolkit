-- SLS Presence backend extension for Luna.
-- Runs within the existing Luna process; no extra network listener.
local json = require('json')
local fs = require('fs')
local millennium = require('millennium')
local M = {}
local HOME = os.getenv('HOME') or ''
local DIR = HOME .. '/.local/share/Luna/data'
local FILE = DIR .. '/presence.json'
local MAX = 4294967295
local function valid_id(v)
  local n = tonumber(v)
  return n and n >= 1 and n <= MAX and n == math.floor(n)
end
local function blank() return {enabled=false, sessionTime=true, discordEnabled=true, discordAppId='', owned={}, running={}, cleanup=0, account=nil, accountSource=nil} end
-- Only the 8-hex FNV digest of an account identity is ever persisted; the raw
-- SteamID or account name must never reach this file or a log line.
local function valid_account(v)
  return type(v)=='string' and v:match('^[0-9a-f]+$')~=nil and #v<=16
end
local function valid_source(v)
  return type(v)=='string' and v:match('^[a-z%-]+$')~=nil and #v>=4 and #v<=16
end
local function read_file()
  local f = io.open(FILE, 'rb')
  if not f then return blank() end
  local s=f:read('*a'); f:close()
  local ok,value=pcall(json.decode,s)
  if not ok or type(value)~='table' then return blank() end
  local data=blank()
  data.enabled=value.enabled==true
  data.cleanup=tonumber(value.cleanup) or 0
  -- Enrichment: while a game runs, its hidden placeholder gains a session-time
  -- suffix (e.g. "(42m)"). On by default; only false disables it.
  data.sessionTime=value.sessionTime~=false
  data.discordEnabled=value.discordEnabled~=false
  if type(value.discordAppId)=='string' and value.discordAppId:match('^%d+$') and #value.discordAppId<=25 then
    data.discordAppId=value.discordAppId
  end
  if valid_account(value.account) then data.account=value.account end
  if valid_source(value.accountSource) then data.accountSource=value.accountSource end
  for original,shortcut in pairs(type(value.owned)=='table' and value.owned or {}) do
    if valid_id(original) and valid_id(shortcut) and tostring(original)~=tostring(shortcut) then
      data.owned[tostring(original)]=tonumber(shortcut)
    end
  end
  for original,shortcut in pairs(type(value.running)=='table' and value.running or {}) do
    if valid_id(original) and tonumber(shortcut)==data.owned[tostring(original)] then
      data.running[tostring(original)]=tonumber(shortcut)
    end
  end
  return data
end
local function save_file(state)
  fs.create_directories(DIR)
  local tmp=FILE..'.tmp'
  local f,err=io.open(tmp,'wb')
  if not f then return false,err end
  local ok,body=pcall(json.encode,state)
  if not ok then f:close(); os.remove(tmp); return false,body end
  local written,werr=f:write(body)
  local closed,cerr=f:close()
  if not written or not closed then os.remove(tmp);return false,werr or cerr or 'write failed' end
  local done,why=os.rename(tmp,FILE)
  if not done then os.remove(tmp);return false,why end
  return true
end
local function response(o) return json.encode(o) end
-- A windowless RunGame shortcut still becomes Big Picture's active game. In
-- Gamescope this leaves its loading screen selected instead of the real game.
-- Require a verified selection-restoration capability in this process. The
-- agent keeps the helper but puts the real game first; only unsupported builds
-- pause helpers, without overwriting the user's setting.
local function helper_policy(getenv)
  getenv = getenv or os.getenv
  local display = getenv('GAMESCOPE_WAYLAND_DISPLAY') or ''
  local limiter = getenv('GAMESCOPE_LIMITER_FILE') or ''
  local desktop = (getenv('XDG_CURRENT_DESKTOP') or ''):lower()
  local gamescope = display ~= '' or limiter ~= '' or desktop:find('gamescope', 1, true) ~= nil
  return {helpersAllowed=true, requiresGameSelection=gamescope,
    mode=gamescope and 'gamescope' or 'desktop', reason=''}
end
-- Which Steam-launched processes are alive right now.
--
-- Steam's reaper tags every process it starts with `AppId=<id>`, so a scan of
-- /proc gives the two facts a recreated SharedJSContext cannot otherwise recover:
-- which manifest games are still running, and which of our helper shortcuts are
-- still alive. Pure input functions are injected so tests never read /proc.
local MAX_PIDS = 8192
local MAX_CMDLINE = 4096
local function collect_running(list_dir, read_file)
  local games, helpers = {}, {}
  local seen_games, seen_helpers, seen_pids = {}, {}, {}
  local ok, entries = pcall(list_dir, '/proc')
  if not ok or type(entries) ~= 'table' then return games, helpers, false end
  local scanned, complete = 0, true
  for _, entry in ipairs(entries) do
    local name = type(entry)=='table' and entry.name or (type(entry)=='string' and entry or nil)
    if type(name)=='string' and name:match('^%d+$') and not seen_pids[name] then
      if scanned >= MAX_PIDS then return games, helpers, false end
      seen_pids[name] = true
      scanned = scanned + 1
      local ok_read, raw = pcall(read_file, '/proc/' .. name .. '/cmdline')
      if not ok_read then complete = false end
      if ok_read and type(raw) == 'string' and #raw > 0 and #raw <= MAX_CMDLINE then
        -- Match a complete argv token, not FakeAppId= or AppId=123suffix.
        -- Avoid copying every cmdline just to replace its NUL separators.
        local id = raw:match('^AppId=(%d+)%z') or raw:match('%zAppId=(%d+)%z')
        if id then
          local value = tonumber(id)
          if value and value >= 1 and value <= MAX then
            if not seen_games[value] then
              games[#games + 1] = value
              seen_games[value] = true
            end
            if raw:find('\0/usr/bin/sleep\00086400\0', 1, true) and not seen_helpers[value] then
              helpers[#helpers + 1] = value
              seen_helpers[value] = true
            end
          end
        end
      end
    end
  end
  return games, helpers, complete
end
-- FNV-1a/32, byte-identical to the JS implementation in plugin/public/agent.js
-- (verified by tests/probe-roundtrip assertions). Used to reduce a SteamID64 to
-- an account-scope fingerprint so the raw id never reaches disk or a log.
local function fnv1a(text)
  local h = 0x811c9dc5
  for i = 1, #text do
    h = (h ~ text:byte(i)) & 0xffffffff
    h = (h * 0x01000193) & 0xffffffff
  end
  return string.format('%08x', h)
end
-- Parse the account blocks out of Steam's config/loginusers.vdf. The file is a
-- plain keyvalues document; each account is a "<steamid64>" { ... } block. This
-- is the same source Luna's own settings tab uses, and it is the only reliable
-- account signal on a client whose SharedJSContext exposes no SteamID.
local function login_users(text)
  local users = {}
  if type(text) ~= 'string' then return users end
  local pos = 1
  while true do
    local s, e, id = text:find('"(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)"%s*{', pos)
    if not s then break end
    local depth, i = 1, e + 1
    while depth > 0 and i <= #text do
      local ch = text:sub(i, i)
      if ch == '{' then depth = depth + 1
      elseif ch == '}' then depth = depth - 1 end
      i = i + 1
    end
    local body = text:sub(e + 1, i - 2)
    users[#users + 1] = {
      id = id,
      most_recent = body:match('"MostRecent"%s*"([01])"') == '1',
      timestamp = tonumber(body:match('"Timestamp"%s*"(%d+)"')) or 0,
      account_name = body:match('"AccountName"%s*"([^"]*)"'),
    }
    pos = i
  end
  return users
end
local identity_cache = {at = 0, value = nil}local function identity()
  local now = os.time()
  if now - identity_cache.at < 60 then return identity_cache.value end
  local value = nil
  local root = millennium.steam_path()
  local path = root ~= '' and fs.join(root, 'config', 'loginusers.vdf') or ''
  local text = nil
  if path ~= '' and fs.exists(path) then
    local f = io.open(path, 'rb')
    if f then text = f:read('*a'); f:close() end
  end
  local users = login_users(text)
  if #users > 0 then
    local chosen, ambiguous = users[1], false
    if #users > 1 then
      local most = nil
      for _, user in ipairs(users) do
        if user.most_recent then most = user end
      end
      if most then chosen = most
      else
        -- No MostRecent flag: the newest Timestamp is the best available guess,
        -- but the scope is no longer certain, so it is reported as ambiguous and
        -- the guard stays advisory rather than locking the ledger.
        ambiguous = true
        for _, user in ipairs(users) do
          if user.timestamp > chosen.timestamp then chosen = user end
        end
      end
    end
    value = {
      key = fnv1a('steamid:' .. chosen.id),
      source = 'loginusers',
      known = #users,
      ambiguous = ambiguous,
    }
  end
  identity_cache = {at = now, value = value}
  return value
end
-- Discord Rich Presence (pure helpers; no socket is opened here).
-- Discord names an undetected game after its executable ("megabonk.x86_64").
-- A SET_ACTIVITY over discord-ipc-N needs a registered Discord application ID
-- (client_id); its application name is what Discord displays. Without one nothing
-- can be sent, so the RPC below only plans the payload.
local function acf_name(text)
  if type(text) ~= 'string' then return nil end
  local name = text:match('"name"%s*"([^"]+)"')
  if name then name = name:gsub('\\(.)', '%1') end
  return name
end
-- Name for a Steam app: add-on titles map first, then appmanifest_<id>.acf in
-- each library dir. read_file(path) is injected so tests never touch disk.
local function resolve_game_name(appid, titles, dirs, read)
  if not valid_id(appid) then return nil end
  local id = tostring(math.floor(tonumber(appid)))
  if type(titles) == 'table' and type(titles[id]) == 'string' and #titles[id] > 0 then return titles[id] end
  for _, dir in ipairs(dirs or {}) do
    local ok, text = pcall(read, dir .. '/appmanifest_' .. id .. '.acf')
    local name = ok and acf_name(text)
    if name and #name > 0 then return name end
  end
  return nil
end
local function discord_socket_paths(getenv)
  getenv = getenv or os.getenv
  local base = getenv('XDG_RUNTIME_DIR') or ''
  local out = {}
  if base == '' then return out end
  for n = 0, 9 do
    for _, sub in ipairs({'', 'app/com.discordapp.Discord/', 'snap.discord/', '.flatpak/com.discordapp.Discord/xdg-run/'}) do
      out[#out + 1] = base .. '/' .. sub .. 'discord-ipc-' .. n
    end
  end
  return out
end
-- IPC frame: int32le opcode, int32le length, UTF-8 JSON. Opcode 0 = handshake, 1 = frame.
local function discord_frame(op, body) return string.pack('<I4I4', op, #body) .. body end
local function discord_handshake(client_id)
  return discord_frame(0, json.encode({v = 1, client_id = tostring(client_id)}))
end
-- activity = nil clears the activity (send when the game stops).
local function discord_set_activity(pid, name, started, nonce)
  local activity = nil
  if name then
    activity = {name = name, details = name, type = 0, timestamps = {start = started}}
  end
  return discord_frame(1, json.encode({cmd = 'SET_ACTIVITY', nonce = tostring(nonce),
    args = {pid = pid, activity = activity}}))
end

-- Discord Rich Presence session manager. The transport is injected (a
-- luasocket-like unix client), so tests run against a fake. step() is called from
-- the host's plugin tick; it never raises. Status: needs_app_id | no_discord |
-- idle | connected.
local RETRY_SECONDS = 15
local function new_discord_session(deps)
  local S = {conn = nil, status = 'idle', appid = nil, name = nil, started = nil,
    sent = nil, next_try = 0, nonce = 0, path = nil}
  local function close()
    if S.conn then pcall(S.conn.close, S.conn) end
    S.conn, S.sent, S.path = nil, nil, nil
  end
  local function send(frame)
    if not S.conn then return false end
    local ok, n = pcall(S.conn.send, S.conn, frame)
    if not ok or not n then close(); return false end
    return true
  end
  -- Reads one frame; nil, err on timeout or a dead connection.
  local function read_frame(timeout)
    local c = S.conn
    c:settimeout(timeout)
    local h, err = c:receive(8)
    if not h then return nil, err end
    local op, len = string.unpack('<I4I4', h)
    if len > 65536 then return nil, 'oversized' end
    local body = ''
    if len > 0 then
      c:settimeout(1)
      body, err = c:receive(len)
      if not body then return nil, err end
    end
    return op, body
  end
  local function try_connect(app_id)
    for _, path in ipairs(deps.paths()) do
      local c = deps.unix()
      if not c then return false end
      c:settimeout(0.5)
      local ok = pcall(function() return c:connect(path) end) and c:getfd() >= 0
      if ok then
        S.conn, S.path = c, path
        if send(discord_handshake(app_id)) then
          local op, body = read_frame(2)
          local okj, msg = pcall(json.decode, body or '')
          if op == 1 and okj and type(msg) == 'table' and msg.evt == 'READY' then return true end
        end
        close()
      else
        pcall(c.close, c)
      end
    end
    return false
  end
  local function pump()
    while S.conn do
      local op, body = read_frame(0)
      if not op then
        if body ~= 'timeout' then close() end
        return
      end
      if op == 3 then send(discord_frame(4, body))
      elseif op == 2 then close() end
    end
  end
  local function clear()
    if S.conn and S.sent then
      S.nonce = S.nonce + 1
      send(discord_set_activity(deps.pid(), nil, nil, S.nonce))
    end
    close()
  end
  -- settings = {enabled, app_id}; game = {appid, name} or nil. Returns status.
  function S.step(settings, game, now)
    local ok, err = pcall(function()
      if type(settings.app_id) ~= 'string' or not settings.app_id:match('^%d+$') then
        clear(); S.status = 'needs_app_id'; S.appid, S.name = nil, nil; return
      end
      if not settings.enabled or not game or not game.name then
        clear(); S.status = 'idle'; S.appid, S.name = game and game.appid or nil, game and game.name or nil
        S.started = nil; return
      end
      if S.appid ~= game.appid then S.started = now end
      S.appid, S.name = game.appid, game.name
      if S.conn then pump() end
      if S.conn and S.sent and S.sent ~= game.appid then clear() end
      if not S.conn then
        if now < S.next_try then S.status = 'no_discord'; return end
        if not deps.unix or not deps.unix() then S.status = 'no_discord'; return end
        if not try_connect(settings.app_id) then
          S.next_try = now + RETRY_SECONDS
          S.status = 'no_discord'; return
        end
      end
      if S.sent ~= game.appid then
        S.nonce = S.nonce + 1
        if send(discord_set_activity(deps.pid(), game.name, S.started, S.nonce)) then
          S.sent = game.appid
          pcall(read_frame, 0.5) -- consume the SET_ACTIVITY reply
        end
      end
      S.status = S.conn and S.sent and 'connected' or 'no_discord'
    end)
    if not ok then close(); S.status = 'no_discord'; S.error = tostring(err) end
    return S.status
  end
  function S.shutdown() pcall(clear) end
  return S
end
local function proc_pid()
  local f = io.open('/proc/self/stat', 'rb')
  local line = f and f:read('*l'); if f then f:close() end
  return tonumber(line and line:match('^(%d+)')) or 0
end
local function default_unix()
  local ok, socket = pcall(require, 'socket')
  if ok and type(socket) == 'table' and type(socket.unix) == 'function' then return socket.unix() end
  return nil
end
-- Steam's text KeyValues (libraryfolders.vdf, appmanifest_*.acf). Only
-- quoted keys with string or object values are needed; junk degrades to {}.
local function kv_parse(text)
  local pos, length = 1, #text
  local function skip()
    while pos <= length do
      local ch = text:sub(pos, pos)
      if ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' then pos = pos + 1
      elseif ch == '/' and text:sub(pos + 1, pos + 1) == '/' then
        local nl = text:find('\n', pos, true)
        pos = nl and nl + 1 or length + 1
      else return end
    end
  end
  local function read_string()
    local out = {}
    pos = pos + 1
    while pos <= length do
      local ch = text:sub(pos, pos)
      if ch == '\\' then out[#out + 1] = text:sub(pos + 1, pos + 1); pos = pos + 2
      elseif ch == '"' then pos = pos + 1; return table.concat(out)
      else out[#out + 1] = ch; pos = pos + 1 end
    end
    return table.concat(out)
  end
  local parse_object
  parse_object = function()
    local out = {}
    while true do
      skip()
      if pos > length then return out end
      if text:sub(pos, pos) == '}' then pos = pos + 1; return out end
      if text:sub(pos, pos) == '"' then
        local key = read_string()
        skip()
        local nextch = text:sub(pos, pos)
        if nextch == '{' then pos = pos + 1; out[key] = parse_object()
        elseif nextch == '"' then out[key] = read_string()
        else out[key] = '' end
      else pos = pos + 1 end
    end
  end
  local ok, out = pcall(parse_object)
  return ok and type(out) == 'table' and out or {}
end
-- The installed Steam library, from Steam's own files: every library root in
-- steamapps/libraryfolders.vdf plus the Steam root, then one AppID per
-- steamapps/appmanifest_<appid>.acf. A missing or corrupt file is reported as
-- an `error` note next to the ids that could be read, never thrown.
local function library_apps(root)
  local apps, err, seen = {}, nil, {}
  if type(root) ~= 'string' or root == '' then return apps, 'Steam root not found' end
  local libraries = { root }
  seen[root] = true
  local folders = nil
  for _, rel in ipairs({ '/steamapps/libraryfolders.vdf', '/config/libraryfolders.vdf' }) do
    local f = io.open(root .. rel, 'rb')
    if f then folders = f:read('*a'); f:close(); break end
  end
  if folders then
    local bucket = kv_parse(folders)
    bucket = type(bucket.libraryfolders) == 'table' and bucket.libraryfolders
      or (type(bucket.LibraryFolders) == 'table' and bucket.LibraryFolders or nil)
    if bucket then
      for _, value in pairs(bucket) do
        local path = type(value) == 'table' and tostring(value.path or '') or ''
        if path ~= '' and not seen[path] then seen[path] = true; libraries[#libraries + 1] = path end
      end
    else
      err = 'libraryfolders.vdf could not be parsed'
    end
  end
  for _, library in ipairs(libraries) do
    local steamapps = library:gsub('/+$', '') .. '/steamapps'
    local ok, items = pcall(fs.list, steamapps)
    if ok and type(items) == 'table' then
      for _, entry in ipairs(items) do
        if not entry.is_directory then
          local id = tostring(entry.name):match('^appmanifest_(%d+)%.acf$')
          if valid_id(id) and not seen['#' .. id] then
            seen['#' .. id] = true
            apps[#apps + 1] = tonumber(id)
          end
        end
      end
    elseif library == root then
      err = err or ('steamapps directory could not be listed under ' .. library)
    end
  end
  table.sort(apps)
  return apps, err
end
M.library_apps = library_apps
local manifest_cache={at=0,apps={},error=''}
local function manifests()
  local now=os.time()
  if now-manifest_cache.at<30 then return manifest_cache.apps end
  local apps,err=library_apps(millennium.steam_path())
  manifest_cache={at=now,apps=apps,error=err or ''}
  return apps
end
local live = {}
function M.register(registry)
  local state=read_file()
  local runtime={active=0,healthy=false,error='',activeIds={},reportedAt=0,
    owned=0,running=0,accountMismatch=false,identityAmbiguous=false,accountSource='',
    reconciledActivate=0,reconciledOrphaned=0,hideStrategy='',hideVerified=false,contracts={},
    helpersPaused=false,helperPauseReason='',restoredSelections=0}
  local titles={}
  registry.SlsPresenceGet=function()
    local apps=manifests()
    return response({success=true, state=state, apps=apps, libraryError=manifest_cache.error,
      runtime=runtime,
      titles=titles, identity=identity(), session=helper_policy()})
  end
  -- Read-only contract probe: proves the wire shape Luna actually delivers
  -- (alphabetical-key positional args, one serialized string) without changing
  -- any state. Used by scripts/probe-live-apis.js and the report.
  registry.SlsPresenceContractProbe=function(raw)
    local ok,obj=pcall(json.decode,raw or '')
    return response({success=true, argType=type(raw), argLength=type(raw)=='string' and #raw or -1,
      decoded=(ok and type(obj)=='table')==true})
  end
  -- Read-only process snapshot. Used at boot and every five seconds to recover state that a
  -- recreated SharedJSContext lost: which manifest games are actually running and
  -- which of our helpers are still alive.
  registry.SlsPresenceProbeProcesses=function()
    local games, helpers, complete = collect_running(fs.list, function(path)
      local f = io.open(path, 'rb')
      if not f then return nil end
      local data = f:read('*a'); f:close(); return data
    end)
    return response({success=complete, complete=complete, games=games, helpers=helpers, scannedAt=os.time()})
  end
  -- Read-only plan for a Discord activity: resolved name and socket candidates.
  -- Reports needsClientId because no Discord application ID is configured.
  registry.SlsPresenceDiscordPlan=function(raw)
    local ok,obj=pcall(json.decode,raw or '')
    if not ok or type(obj)~='table' then return response({success=false,error='Invalid payload'}) end
    local root=millennium.steam_path()
    local dirs=root~='' and {fs.join(root,'steamapps')} or {}
    local name=resolve_game_name(obj.appid,titles,dirs,function(path)
      local f=io.open(path,'rb'); if not f then return nil end
      local s=f:read('*a'); f:close(); return s
    end)
    local cid=type(obj.clientId)=='string' and obj.clientId:match('^%d+$') or nil
    return response({success=name~=nil,name=name,needsClientId=cid==nil,
      status=state.discordAppId=='' and 'needs_app_id' or (live.session and live.session.status or 'idle'),
      sockets=discord_socket_paths()})
  end
  -- Discord session: driven by M.tick (host plugin tick, ~5 s). Inert when the
  -- host has no tick or socket.unix.
  local session = new_discord_session({unix=default_unix, paths=function() return discord_socket_paths() end, pid=proc_pid})
  local function read_text(path)
    local f=io.open(path,'rb'); if not f then return nil end
    local data=f:read('*a'); f:close(); return data
  end
  local function current_game()
    local games,helpers=collect_running(fs.list,read_text)
    local skip={}
    for _,id in ipairs(helpers) do skip[id]=true end
    local appid
    for _,id in ipairs(games) do
      if not skip[id] and (appid==nil or id==session.appid) then appid=id end
    end
    if not appid and runtime.reportedAt and os.time()-runtime.reportedAt<=20 then
      appid=runtime.activeIds[1]
    end
    if not appid then return nil end
    local root=millennium.steam_path()
    local dirs=root~='' and {fs.join(root,'steamapps')} or {}
    return {appid=appid,name=resolve_game_name(appid,titles,dirs,read_text)}
  end
  live.tick=function(now)
    session.step({enabled=state.discordEnabled~=false,app_id=state.discordAppId},current_game(),now)
  end
  live.shutdown=function() session.shutdown() end
  live.session=session
  registry.SlsPresenceDiscordStatus=function()
    local game=current_game()
    return response({success=true,status=session.status,name=game and game.name or session.name,
      appid=game and game.appid or nil,enabled=state.discordEnabled~=false,hasAppId=state.discordAppId~=''})
  end
  registry.SlsPresenceSetDiscord=function(raw)
    if type(raw)~='string' or #raw>500 then return response({success=false,error='Invalid payload'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' then return response({success=false,error='Invalid payload'}) end
    local updated=read_file()
    if obj.enabled~=nil then
      if type(obj.enabled)~='boolean' then return response({success=false,error='Expected boolean'}) end
      updated.discordEnabled=obj.enabled
    end
    if obj.appId~=nil then
      if type(obj.appId)~='string' or (obj.appId~='' and (not obj.appId:match('^%d+$') or #obj.appId<5 or #obj.appId>25)) then
        return response({success=false,error='Application ID must be numeric'})
      end
      updated.discordAppId=obj.appId
    end
    local saved,err=save_file(updated)
    if saved then state=updated end
    return response({success=saved,error=err,discordEnabled=state.discordEnabled,discordAppId=state.discordAppId})
  end
  registry.SlsPresencePut=function(raw)
    if type(raw)~='string' or #raw>1000000 then return response({success=false,error='Invalid payload'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' or type(obj.owned)~='table' or type(obj.running)~='table' then
      return response({success=false,error='Invalid presence state'})
    end
    local next_state=blank()
    next_state.enabled=state.enabled -- UI owns enabled setting, not agent
    next_state.cleanup=state.cleanup
    next_state.sessionTime=state.sessionTime -- UI owns the enrichment toggle too
    next_state.discordEnabled=state.discordEnabled
    next_state.discordAppId=state.discordAppId
    next_state.account=valid_account(obj.account) and obj.account or state.account
    next_state.accountSource=valid_source(obj.accountSource) and obj.accountSource or state.accountSource
    local count=0
    local usedShortcuts={}
    for original,shortcut in pairs(obj.owned) do
      count=count+1
      if count>4096 or not valid_id(original) or not valid_id(shortcut) or tostring(original)==tostring(shortcut) then
        return response({success=false,error='Invalid shortcut mapping'})
      end
      local sid=tostring(math.floor(tonumber(shortcut)))
      if usedShortcuts[sid] then
        return response({success=false,error='A shortcut cannot belong to two original games'})
      end
      usedShortcuts[sid]=true
      next_state.owned[tostring(original)]=tonumber(shortcut)
    end
    for original,shortcut in pairs(obj.running) do
      if tonumber(shortcut)~=next_state.owned[tostring(original)] then
        return response({success=false,error='Invalid active shortcut'})
      end
      next_state.running[tostring(original)]=tonumber(shortcut)
    end
    local saved,err=save_file(next_state)
    if saved then state=next_state end
    return response({success=saved,error=err})
  end
  registry.SlsPresenceSetEnabled=function(value)
    if type(value)~='boolean' then return response({success=false,error='Expected boolean'}) end
    local updated=read_file();updated.enabled=value
    local ok,err=save_file(updated)
    if ok then state=updated end
    return response({success=ok,error=err,enabled=state.enabled})
  end
  -- Enrichment toggle: when on, a running placeholder's name gains a session
  -- time suffix like "(42m)" and is restored to the plain title on stop.
  registry.SlsPresenceSetSessionTime=function(value)
    if type(value)~='boolean' then return response({success=false,error='Expected boolean'}) end
    local updated=read_file();updated.sessionTime=value
    local saved,err=save_file(updated)
    if saved then state=updated end
    return response({success=saved,error=err,sessionTime=state.sessionTime})
  end
  registry.SlsPresenceRequestCleanup=function()
    local updated=read_file();updated.enabled=false;updated.cleanup=updated.cleanup+1
    local ok,err=save_file(updated)
    if ok then state=updated end
    return response({success=ok,error=err,cleanup=state.cleanup})
  end
  registry.SlsPresenceAcknowledgeCleanup=function()
    local updated=read_file();updated.cleanup=0
    local ok,err=save_file(updated)
    if ok then state=updated end
    return response({success=ok,error=err})
  end
  registry.SlsPresenceSetTitles=function(raw)
    if type(raw)~='string' or #raw>3000 then return response({success=false,error='Invalid titles'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' then return response({success=false,error='Invalid titles'}) end
    for id,title in pairs(obj) do
      if valid_id(id) and type(title)=='string' and #title>0 and #title<=160 then
        titles[tostring(id)]=title
      end
    end
    return response({success=true})
  end
  registry.SlsPresenceReport=function(raw)
    if type(raw)~='string' or #raw>4000 then return response({success=false}) end
    local ok,obj=pcall(json.decode,raw)
    if ok and type(obj)=='table' then
      runtime={active=tonumber(obj.active) or 0,healthy=obj.healthy==true,error=tostring(obj.error or ''):sub(1,300),activeIds={},reportedAt=os.time(),
        owned=math.max(0,math.min(4096,tonumber(obj.owned) or 0)),
        running=math.max(0,math.min(4096,tonumber(obj.running) or 0)),
        accountMismatch=obj.accountMismatch==true,
        identityAmbiguous=obj.identityAmbiguous==true,
        reconciledActivate=math.max(0,math.min(4096,tonumber(obj.reconciledActivate) or 0)),
        reconciledOrphaned=math.max(0,math.min(4096,tonumber(obj.reconciledOrphaned) or 0)),
        accountSource=tostring(obj.accountSource or ''):sub(1,16),
        hideStrategy=tostring(obj.hideStrategy or ''):sub(1,32),
        hideVerified=obj.hideVerified==true,
        helpersPaused=obj.helpersPaused==true,
        helperPauseReason=tostring(obj.helperPauseReason or ''):sub(1,250),
        restoredSelections=math.max(0,tonumber(obj.restoredSelections) or 0),
        contracts={}}
      if type(obj.contracts)=='table' then
        for name,arity in pairs(obj.contracts) do
          if type(name)=='string' and #name<=40 and (arity==nil or type(arity)=='number') then
            runtime.contracts[name]=arity
          end
        end
      end
      if type(obj.activeIds)=='table' then
        for _,id in ipairs(obj.activeIds) do
          if valid_id(id) and #runtime.activeIds<12 then runtime.activeIds[#runtime.activeIds+1]=tonumber(id) end
        end
      end
    end
    return response({success=true})
  end
end
function M.tick(now) if live.tick then pcall(live.tick, now or os.time()) end end
function M.on_unload() if live.shutdown then pcall(live.shutdown) end end
M.new_discord_session = new_discord_session
M.collect_running = collect_running
M.login_users = login_users
M.fnv1a = fnv1a
M.acf_name = acf_name
M.resolve_game_name = resolve_game_name
M.discord_socket_paths = discord_socket_paths
M.discord_handshake = discord_handshake
M.discord_set_activity = discord_set_activity
M.helper_policy = helper_policy
return M
