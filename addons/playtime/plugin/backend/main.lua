-- Persistent local ledger for Luna SLS Playtime.
-- Does not change Steam's official tracked hours or Steam Cloud data.
--
-- Schema 2 storage contract:
--   <dir>/playtime/<steamid64>.json      one ledger per Steam account
--   <dir>/playtime/<steamid64>.json.bak  previous good contents of that ledger
--   <dir>/playtime.json                  legacy shared schema-1 ledger (kept)
--   <dir>/corrupt/<name>-<stamp>          quarantined unreadable ledgers (kept)
--
-- Every save is atomic (tmp + rename) and always leaves the previous good file
-- as .bak. A ledger that cannot be decoded is quarantined, never silently
-- overwritten by the next heartbeat.
--
-- Heartbeats are idempotent. The agent sends an opaque per-session id plus a
-- monotonically increasing sequence number, and a replay of an already
-- committed sequence returns success without counting the elapsed time twice.
-- That is the response-loss case: the backend persisted the pulse but the RPC
-- reply never reached the page, so the page retried it.
local json=require('json')
local fs=require('fs')
local millennium=require('millennium')
local M={}
local HOME=os.getenv('HOME') or ''
local DIR=HOME..'/.local/share/Luna/data'
local LEGACY=DIR..'/playtime.json'
local MAX=4294967295
local SCHEMA=2
-- Ledger model (not the file schema): 1 means "the official lifetime playtime
-- from localconfig.vdf is the base for games Steam tracks". A ledger without
-- this marker predates the model and its adjustments are retired once.
local OFFICIAL_BASE=1
local MAX_EVENTS=200
local MAX_PULSE=30
local MAX_SECONDS=36000000000
local MAX_BYTES=8*1024*1024
local MAX_ACKED=64
local MAX_DAYS=400
local MAX_TITLES=2000
local DAY=86400
local function valid_id(v)
  local n=tonumber(v)
  return n and n>=1 and n<=MAX and n==math.floor(n)
end
local function finite(v,min,max)
  local n=tonumber(v)
  if not n or n~=n or n==math.huge or n==-math.huge then return nil end
  if n<min then n=min elseif n>max then n=max end
  return n
end
local function valid_day_key(k)
  local y,m,d=k:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
  if not y then return false end
  local t=os.time{year=tonumber(y),month=tonumber(m),day=tonumber(d),hour=12}
  if not t then return false end
  -- A key like 2026-13-99 matches the shape above but is not a real date;
  -- os.time normalises it, so only the round trip proves it.
  return os.date('%Y-%m-%d',t)==k
end
local function blank(account)
  return {version=SCHEMA,account=account or '',games={},events={},daily={},titles={},active={},acked={},ackOrder={},officialBase=OFFICIAL_BASE}
end
local function reply(data) return json.encode(data) end
-- Rebuild a trusted in-memory ledger from decoded JSON. Anything unusable is
-- dropped here, once, instead of throwing in the middle of a later heartbeat.
local function sanitize(obj,account,keep_sessions)
  local data=blank(account)
  -- A ledger only belongs to the official-base model when it says so; anything
  -- older is migrated by the caller once a localconfig.vdf is available. The
  -- default from blank() must not be inherited here, or an old ledger would
  -- look migrated without its adjustments ever being retired.
  if tonumber(obj.officialBase)==OFFICIAL_BASE then data.officialBase=OFFICIAL_BASE else data.officialBase=nil end
  for k,v in pairs(type(obj.games)=='table' and obj.games or {}) do
    if valid_id(k) and type(v)=='table' then
      local key=tostring(tonumber(k))
      data.games[key]={
        title=type(v.title)=='string' and v.title:sub(1,160) or ('App '..key),
        trackedSeconds=finite(v.trackedSeconds,0,MAX_SECONDS) or 0,
        adjustmentSeconds=finite(v.adjustmentSeconds,-MAX_SECONDS,MAX_SECONDS) or 0,
        lastPlayed=finite(v.lastPlayed,0,1e12) or 0,
      }
    end
  end
  -- Display-name cache. The Steam shell window has no appStore, so only the
  -- SharedJSContext agent can resolve a name; it reports them here. Purely
  -- cosmetic and rebuildable, so it is bounded and never trusted as data.
  local names={}
  for k,v in pairs(type(obj.titles)=='table' and obj.titles or {}) do
    if valid_id(k) and type(v)=='string' and v~='' then names[#names+1]=tostring(tonumber(k)) end
  end
  table.sort(names)
  for i=math.max(1,#names-MAX_TITLES+1),#names do
    data.titles[names[i]]=obj.titles[names[i]]:sub(1,160)
  end
  for _,e in ipairs(type(obj.events)=='table' and obj.events or {}) do
    if type(e)=='table' and valid_id(e.id) then
      local seconds=finite(e.seconds,0,MAX_PULSE)
      local ended=finite(e.endedAt,0,1e12)
      if seconds and ended then
        data.events[#data.events+1]={id=tonumber(e.id),seconds=seconds,endedAt=ended}
        if #data.events>MAX_EVENTS then table.remove(data.events,1) end
      end
    end
  end
  -- Daily buckets. The bounded pulse ring above only spans a few hours of
  -- pulses, so it can never answer a 7- or 30-day question; the buckets can.
  local days={}
  for k in pairs(type(obj.daily)=='table' and obj.daily or {}) do
    if type(k)=='string' and valid_day_key(k) then days[#days+1]=k end
  end
  table.sort(days)
  for i=math.max(1,#days-MAX_DAYS+1),#days do
    local v=finite(obj.daily[days[i]],0,MAX_SECONDS)
    if v then data.daily[days[i]]=v end
  end
  -- Ack records for finished sessions survive a restart on purpose: a stop
  -- whose response was lost can still be replayed after the page reconnects.
  local order={}
  for sid in pairs(type(obj.acked)=='table' and obj.acked or {}) do
    if type(sid)=='string' and #sid>=1 and #sid<=64 then order[#order+1]=sid end
  end
  table.sort(order)
  for i=math.max(1,#order-MAX_ACKED+1),#order do
    local seq=finite(obj.acked[order[i]],0,1e15)
    if seq then data.acked[order[i]]=seq;data.ackOrder[#data.ackOrder+1]=order[i] end
  end
  -- Session bookkeeping is deliberately not restored from disk: a session from
  -- a previous process cannot be verified. It IS restored from an in-process
  -- rollback snapshot, where it is our own state and dropping it would stop
  -- recording until the game was relaunched.
  if keep_sessions then
    for k,v in pairs(type(obj.active)=='table' and obj.active or {}) do
      if valid_id(k) and type(v)=='table' and type(v.sid)=='string' and #v.sid<=64 then
        data.active[tostring(tonumber(k))]={sid=v.sid,seq=finite(v.seq,0,1e15) or 0,
          timestamp=finite(v.timestamp,0,1e12) or 0}
      end
    end
  end
  return data
end
local function read_file(path)
  local f=io.open(path,'rb')
  if not f then return nil,'missing' end
  local raw=f:read(MAX_BYTES+1)
  f:close()
  if not raw then return nil,'unreadable' end
  if #raw==0 then return nil,'empty file' end
  if #raw>MAX_BYTES then return nil,'oversized file' end
  return raw
end
-- Valve's binary KeyValues, as used by shortcuts.vdf. Only the value types that
-- file actually contains are decoded, and an unknown type byte stops the walk
-- instead of guessing: a format change must degrade to "no shortcuts", never to
-- invented entries.
local function vdf_parse(raw,pos,depth)
  local out={}
  if depth>8 then return out,#raw+1 end
  while pos<=#raw do
    local kind=raw:byte(pos);pos=pos+1
    if kind==0x08 then return out,pos end
    local stop=raw:find('\0',pos,true)
    if not stop then return out,#raw+1 end
    local name=raw:sub(pos,stop-1);pos=stop+1
    if kind==0x00 then
      local child,nextpos=vdf_parse(raw,pos,depth+1)
      out[name]=child;pos=nextpos
    elseif kind==0x01 then
      local entry=raw:find('\0',pos,true)
      if not entry then return out,#raw+1 end
      out[name]=raw:sub(pos,entry-1);pos=entry+1
    elseif kind==0x02 then
      if pos+3>#raw then return out,#raw+1 end
      local b1,b2,b3,b4=raw:byte(pos,pos+3)
      -- Read as unsigned: a shortcut AppID has the high bit set, and the file
      -- stores it as the matching negative int32.
      out[name]=b1+b2*256+b3*65536+b4*16777216
      pos=pos+4
    elseif kind==0x03 or kind==0x04 then
      pos=pos+4
    elseif kind==0x07 or kind==0x0a or kind==0x0b then
      pos=pos+8
    else
      return out,#raw+1
    end
  end
  return out,#raw+1
end

-- Steam's text KeyValues (localconfig.vdf and friends). The binary parser above
-- covers shortcuts.vdf; this one walks the text form into nested tables, with
-- '//' comments skipped and quoted escapes kept simple on purpose. Only the
-- shape the official playtime needs is guaranteed; junk degrades to {}.
local function text_vdf_parse(raw)
  local pos,length=1,#raw
  local function skip()
    while pos<=length do
      local ch=raw:sub(pos,pos)
      if ch==' ' or ch=='\t' or ch=='\r' or ch=='\n' then
        pos=pos+1
      elseif ch=='/' and raw:sub(pos+1,pos+1)=='/' then
        local nl=raw:find('\n',pos,true)
        pos=nl and nl+1 or length+1
      else
        return
      end
    end
  end
  local function read_string()
    local out={}
    pos=pos+1
    while pos<=length do
      local ch=raw:sub(pos,pos)
      if ch=='\\' then
        out[#out+1]=raw:sub(pos+1,pos+1)
        pos=pos+2
      elseif ch=='"' then
        pos=pos+1
        return table.concat(out)
      else
        out[#out+1]=ch
        pos=pos+1
      end
    end
    return table.concat(out)
  end
  local parse_object
  parse_object=function()
    local out={}
    while true do
      skip()
      if pos>length then return out end
      if raw:sub(pos,pos)=='}' then
        pos=pos+1
        return out
      end
      if raw:sub(pos,pos)=='"' then
        local key=read_string()
        skip()
        local nextch=raw:sub(pos,pos)
        if nextch=='{' then
          pos=pos+1
          out[key]=parse_object()
        elseif nextch=='"' then
          out[key]=read_string()
        else
          out[key]=''
        end
      else
        pos=pos+1
      end
    end
  end
  local out={}
  while true do
    skip()
    if pos>length then return out end
    if raw:sub(pos,pos)=='"' then
      local key=read_string()
      skip()
      local nextch=raw:sub(pos,pos)
      if nextch=='{' then
        pos=pos+1
        out[key]=parse_object()
      elseif nextch=='"' then
        out[key]=read_string()
      end
    else
      pos=pos+1
    end
  end
end

local function copy_file(src,dst)
  local raw=read_file(src)
  if not raw then return false end
  local f=io.open(dst,'wb')
  if not f then return false end
  local written=f:write(raw)
  local closed=f:close()
  if not written or not closed then os.remove(dst); return false end
  return true
end

-- Official lifetime playtime per app, straight from Steam's own localconfig.vdf
-- (`Playtime`, minutes). For a game Steam tracks, this - not the ledger's own
-- since-inception count - is the number the user sees in the library, so it is
-- the base every surface must agree with. Cached by file size with a slow TTL:
-- the panel polls once a second and must not re-parse half a megabyte each time.
local official_cache={path='',size=-1,at=0,map={}}
local function official_playtimes(root,account)
  if root=='' or account=='' then return {} end
  -- Steam's userdata directory is named after the 32-bit account id, while the
  -- ledger is keyed by the steamid64.
  local account_number=tonumber(account)
  if not account_number or account_number<=76561197960265728 then return {} end
  local path=root..'/userdata/'..(account_number-76561197960265728)..'/config/localconfig.vdf'
  local now=os.time()
  local size=-1
  local handle=io.open(path,'rb')
  if handle then size=handle:seek('end') or -1; handle:close() end
  if path==official_cache.path and size==official_cache.size and now-official_cache.at<300 then
    return official_cache.map
  end
  local map={}
  local raw=read_file(path)
  if raw then
    local ok,store=pcall(text_vdf_parse,raw)
    if ok and type(store)=='table' then
      local node=store.UserLocalConfigStore
      node=type(node)=='table' and node.Software or nil
      node=type(node)=='table' and node.Valve or nil
      node=type(node)=='table' and node.Steam or nil
      node=type(node)=='table' and node.apps or nil
      if type(node)=='table' then
        for key,value in pairs(node) do
          if type(value)=='table' then
            local id=tonumber(key)
            local minutes=tonumber(value.Playtime)
            if id and valid_id(id) and minutes and minutes>0 then
              map[tostring(math.floor(id))]=math.floor(minutes*60)
            end
          end
        end
      end
    end
  end
  official_cache={path=path,size=size,at=now,map=map}
  return map
end
local function account_id(steamid64)
  local n=tonumber(steamid64)
  if not n then return nil end
  return tostring(n-76561197960265728)
end
-- Non-Steam games (library shortcuts) have no numeric manifest, but Steam
-- still sends lifetime notifications for their 32-bit AppID. shortcuts.vdf is
-- the only local source that lists them together with their names.
local function shortcut_inventory(root,steamid64)
  local dirs={}
  if account_id(steamid64) then
    dirs[1]=root..'/userdata/'..account_id(steamid64)
  else
    local userdata=root..'/userdata'
    if fs.exists(userdata) then
      local ok,items=pcall(fs.list,userdata)
      if ok and type(items)=='table' then
        for _,entry in ipairs(items) do
          local name=tostring(entry.name)
          if entry.is_directory and name~='0' and name:match('^%d+$') then
            dirs[#dirs+1]=fs.join(userdata,name)
          end
        end
      end
    end
  end
  local names={}
  for _,dir in ipairs(dirs) do
    local raw=read_file(fs.join(dir,'config','shortcuts.vdf'))
    if raw then
      local parsed=vdf_parse(raw,1,1)
      local bucket=type(parsed)=='table' and parsed.shortcuts or nil
      if type(bucket)=='table' then
        for _,entry in pairs(bucket) do
          if type(entry)=='table' then
            local id=valid_id(entry.appid) and tonumber(entry.appid) or nil
            if id then
              local label=entry.appname
              if type(label)=='string' and label~='' then names[tostring(id)]=label:sub(1,160) end
            end
          end
        end
      end
    end
  end
  return names
end
-- Steam-native game inventory: the installed Steam library, read from Steam's
-- own files only. Library roots come from steamapps/libraryfolders.vdf (plus
-- the Steam root itself); each root's steamapps/appmanifest_<appid>.acf
-- declares one installed app. Entry fields: appid, name, size (SizeOnDisk),
-- lastPlayed (LastPlayed, 0 when absent). A missing root or an unparseable
-- file yields the entries that could be read plus an `error` note; this
-- function never throws and never shells out.
local function steam_library(root)
  local entries, err = {}, nil
  if type(root) ~= 'string' or root == '' then return entries, 'Steam root not found' end
  local libraries, seen = { root }, { [root] = true }
  local folders = read_file(root .. '/steamapps/libraryfolders.vdf')
    or read_file(root .. '/config/libraryfolders.vdf')
  if folders then
    local ok, store = pcall(text_vdf_parse, folders)
    local bucket = ok and type(store) == 'table'
      and (store.libraryfolders or store.LibraryFolders) or nil
    if type(bucket) == 'table' then
      for _, value in pairs(bucket) do
        local path = type(value) == 'table' and tostring(value.path or '') or ''
        if path ~= '' and not seen[path] then
          seen[path] = true
          libraries[#libraries + 1] = path
        end
      end
    else
      err = 'libraryfolders.vdf could not be parsed'
    end
  end
  local installed = {}
  for _, library in ipairs(libraries) do
    local steamapps = library:gsub('/+$', '') .. '/steamapps'
    local ok, items = pcall(fs.list, steamapps)
    if ok and type(items) == 'table' then
      for _, item in ipairs(items) do
        if not item.is_directory then
          local appid = tostring(item.name):match('^appmanifest_(%d+)%.acf$')
          -- One entry per AppID: a stale manifest can sit in a second library.
          if appid and valid_id(appid) and not installed[tonumber(appid)] then
            local raw = read_file(steamapps .. '/appmanifest_' .. appid .. '.acf')
            local app = nil
            if raw then
              local parsed, store = pcall(text_vdf_parse, raw)
              app = parsed and type(store) == 'table'
                and (store.AppState or store.appstate) or nil
            end
            if type(app) ~= 'table' then
              err = err or ('appmanifest_' .. appid .. '.acf could not be parsed')
            end
            local name = type(app) == 'table' and app.name or ''
            installed[tonumber(appid)] = true
            entries[#entries + 1] = {
              appid = tonumber(appid),
              name = type(name) == 'string' and name:sub(1, 160) or '',
              size = type(app) == 'table' and (tonumber(app.SizeOnDisk) or 0) or 0,
              lastPlayed = type(app) == 'table' and (tonumber(app.LastPlayed) or 0) or 0,
            }
          end
        end
      end
    elseif #libraries == 1 or library == root then
      err = err or ('steamapps directory could not be listed under ' .. library)
    end
  end
  table.sort(entries, function(a, b) return a.appid < b.appid end)
  return entries, err
end
-- Exposed for tests and diagnostics: the Steam-native installed library.
M.steam_library = steam_library
local function decode_ledger(raw)
  local ok,obj=pcall(json.decode,raw)
  if not ok then return nil,'not valid JSON' end
  if type(obj)~='table' then return nil,'not a JSON object' end
  if type(obj.version)~='number' then return nil,'missing schema version' end
  if obj.version~=1 and obj.version~=SCHEMA then return nil,'unsupported schema version '..tostring(obj.version) end
  if type(obj.games)~='table' then return nil,'missing game table' end
  if obj.events~=nil and type(obj.events)~='table' then return nil,'invalid event table' end
  if obj.daily~=nil and type(obj.daily)~='table' then return nil,'invalid daily table' end
  return obj
end
local function quarantine(path)
  if not fs.exists(path) then return nil end
  local dir=DIR..'/corrupt'
  fs.create_directories(dir)
  local target=dir..'/'..(path:match('[^/]+$') or 'ledger')..'-'..os.date('%Y%m%d-%H%M%S')
  if fs.exists(target) then target=target..'-'..tostring(os.time()%1000) end
  local ok=os.rename(path,target)
  return ok and target or nil
end
local function read_state(path,account)
  local raw=read_file(path)
  if raw then
    local obj,err=decode_ledger(raw)
    if obj then return sanitize(obj,account),'' end
    -- Keep the bytes, never overwrite them with a blank ledger.
    local moved=quarantine(path)
    local backup=read_file(path..'.bak')
    if backup then
      local restored=decode_ledger(backup)
      if restored then
        return sanitize(restored,account),('ledger was %s; restored the previous good backup (%s)'):format(err,tostring(moved))
      end
    end
    return blank(account),('ledger was %s and no usable backup existed%s'):format(err,moved and ('; quarantined as '..moved) or '')
  end
  -- No ledger at all, but a .bak means a crash landed between the two renames
  -- that keep the previous good copy.
  local backup=read_file(path..'.bak')
  if backup then
    local restored=decode_ledger(backup)
    if restored then return sanitize(restored,account),'recovered the previous good backup' end
  end
  return blank(account),''
end
local function persist(data,path)
  fs.create_directories(fs.parent_path(path))
  local ok,text=pcall(json.encode,data)
  if not ok then return false,tostring(text) end
  local tmp=path..'.tmp'
  local f,why=io.open(tmp,'wb')
  if not f then return false,why end
  local written,werr=f:write(text)
  local closed,cerr=f:close()
  if not written or not closed then os.remove(tmp);return false,werr or cerr or 'write failed' end
  if fs.exists(path) then
    local moved,merr=os.rename(path,path..'.bak')
    if not moved then os.remove(tmp);return false,merr or 'backup rename failed' end
  end
  local done,err=os.rename(tmp,path)
  if not done then
    -- Put the previous good ledger back instead of leaving the user with none.
    if fs.exists(path..'.bak') then os.rename(path..'.bak',path) end
    os.remove(tmp)
    return false,err or 'atomic replace failed'
  end
  return true
end
-- loginusers.vdf is Valve's own account list; "MostRecent" marks the account
-- Steam will sign in next. It is the only account identity a local add-on can
-- read without touching credentials. Ambiguity is reported as "unknown" rather
-- than guessed: guessing would file one account's hours under another.
local function read_login_users(root)
  local raw=read_file(root..'/config/loginusers.vdf')
  if not raw then return {} end
  local users,current={},nil
  for line in raw:gmatch('[^\r\n]+') do
    local id=line:match('^%s*"(%d+)"%s*$')
    if id and #id>=16 and #id<=20 then
      current={id=id,recent=false}
      users[#users+1]=current
    elseif current and line:match('"MostRecent"%s*"1"') then
      current.recent=true
    end
  end
  return users
end
local function resolve_account(root)
  local override=os.getenv('SLS_PLAYTIME_ACCOUNT')
  if override and override:match('^%d+$') and #override>=16 and #override<=20 then
    return override,'SLS_PLAYTIME_ACCOUNT'
  end
  local users=read_login_users(root)
  if #users==0 then return nil,'no Steam accounts recorded on this machine' end
  local recent=nil
  for _,u in ipairs(users) do
    if u.recent then
      if recent then return nil,'several accounts are marked MostRecent' end
      recent=u.id
    end
  end
  if recent then return recent,'loginusers.vdf MostRecent' end
  if #users==1 then return users[1].id,'the only recorded Steam account' end
  return nil,('ambiguous: %d Steam accounts recorded and none marked MostRecent'):format(#users)
end
-- Copy (never move) the legacy shared ledger into the account ledger so the
-- original stays on disk as a backup. Only done when the account is known.
local function migrate_legacy(path,account,note)
  if account=='' or fs.exists(path) then return note end
  local raw=read_file(LEGACY)
  if not raw then return note end
  local obj,err=decode_ledger(raw)
  if not obj then return note..'; shared ledger was not migrated ('..tostring(err)..')' end
  local ok,perr=persist(sanitize(obj,account),path)
  if not ok then return note..'; shared ledger migration failed: '..tostring(perr) end
  return note..'; migrated the shared schema-1 ledger into this account (original kept)'
end
local function remember_ack(data,sid,seq)
  if not data.acked[sid] then
    data.ackOrder[#data.ackOrder+1]=sid
    while #data.ackOrder>MAX_ACKED do
      local oldest=table.remove(data.ackOrder,1)
      data.acked[oldest]=nil
    end
  end
  data.acked[sid]=seq
end
local function day_key(offset)
  return os.date('%Y-%m-%d',os.time()-offset*DAY)
end
local function stats(data)
  local cut7,cut30=day_key(6),day_key(29)
  local out={last7d=0,last30d=0,today=data.daily[day_key(0)] or 0}
  for k,v in pairs(data.daily) do
    if k>=cut7 then out.last7d=out.last7d+v end
    if k>=cut30 then out.last30d=out.last30d+v end
  end
  return out
end
local function recent_events(data,limit)
  local out={}
  for i=math.max(1,#data.events-limit+1),#data.events do out[#out+1]=data.events[i] end
  return json.array(out)
end
function M.register(registry)
  local root=millennium.steam_path()
  local account,source=resolve_account(root)
  local ledger=LEGACY
  local note='Ledger account resolved from '..tostring(source)
  if account then
    ledger=DIR..'/playtime/'..account..'.json'
    note=migrate_legacy(ledger,account,note)
  else
    note=tostring(source)..'; using the shared legacy ledger'
  end
  local data,loadnote=read_state(ledger,account or '')
  if loadnote~='' then note=note..'. '..loadnote end
  -- Ledger model change (2026-10-15): for games Steam itself tracks, the base
  -- is now the official lifetime playtime from localconfig.vdf, so any old
  -- since-inception adjustment is retired once. The pre-change bytes are kept
  -- beside the ledger; a fresh ledger is born on the new model already.
  local official=official_playtimes(root,data.account)
  local hasOfficial=false
  for _ in pairs(official) do hasOfficial=true; break end
  if hasOfficial and tonumber(data.officialBase or 0)~=OFFICIAL_BASE then
    local retired=0
    for key,record in pairs(data.games) do
      if (official[key] or 0)>0 and math.abs(record.adjustmentSeconds or 0)>1 then
        record.adjustmentSeconds=0
        retired=retired+1
      end
    end
    data.officialBase=OFFICIAL_BASE
    if retired>0 then
      if not fs.exists(ledger..'.pre-official') then copy_file(ledger,ledger..'.pre-official') end
      note=note..('. Retired '..retired..' legacy adjustment(s) where Steam owns the total')
    end
    local saved,migerr=persist(data,ledger)
    if not saved then note=note..'. Could not persist the official-base migration: '..tostring(migerr) end
  end
  local runtime={healthy=false,error='',reportedAt=0,note=note,
    file=(ledger:match('[^/]+$') or ledger)}
  -- Two different questions, so two different sets:
  --   * trackable - non-Steam library shortcuts. Nothing else records their
  --     playtime, so the agent must count sessions while they run.
  --   * editable  - every game the panel may show and edit: shortcuts plus the
  --     installed Steam library (steamapps/appmanifest_*.acf across every
  --     steamapps/libraryfolders.vdf root; see steam_library above). Steam
  --     itself already records playtime for those apps, so they are
  --     deliberately edit-only and are never auto-counted.
  --     SLS_PLAYTIME_TRACK_MANIFESTS=1 restores counting them.
  -- Counted: installed Steam manifests + non-Steam shortcuts. Nothing else.
  local inventory={ts=0,ids={},trackIds={},trackSet={},editSet={},
    manifestCount=0,shortcutCount=0,shortcutNames={},libraryError=''}
  local function refresh_inventory()
    local now=os.time()
    if now-inventory.ts<30 then return inventory end
    local editset,trackids={},{}
    local libraryError=''
    if root~='' then
      local installed,why=steam_library(root)
      libraryError=why or ''
      for _,entry in ipairs(installed) do
        local id=tonumber(entry.appid)
        if valid_id(id) then editset[id]=true end
      end
    end
    local shortcutNames={}
    if root~='' then shortcutNames=shortcut_inventory(root,data.account) end
    local shortcutCount=0
    local trackset={}
    for key in pairs(shortcutNames) do
      local id=tonumber(key)
      -- A numeric manifest always wins: an AppID cannot be both a Steam game
      -- and a non-Steam shortcut, and the manifest is the authoritative one.
      if id and not editset[id] then
        shortcutCount=shortcutCount+1
        editset[id]=true
        trackset[id]=true
        trackids[#trackids+1]=id
      end
    end
    local manifestCount=0
    for id in pairs(editset) do
      if not trackset[id] then manifestCount=manifestCount+1 end
    end
    if os.getenv('SLS_PLAYTIME_TRACK_MANIFESTS')=='1' then
      trackids={}
      trackset={}
      for id in pairs(editset) do trackset[id]=true;trackids[#trackids+1]=id end
      manifestCount=0
    end
    local ids={}
    for id in pairs(editset) do ids[#ids+1]=id end
    inventory={ts=now,ids=ids,trackIds=trackids,trackSet=trackset,editSet=editset,
      manifestCount=manifestCount,shortcutCount=shortcutCount,shortcutNames=shortcutNames,
      libraryError=libraryError}
    return inventory
  end
  local function manifests()
    -- The Steam manifest ids on their own; used for reporting and by tests.
    local snap=refresh_inventory()
    local ids={}
    for id in pairs(snap.editSet) do
      if not snap.trackSet[id] then ids[#ids+1]=id end
    end
    return ids
  end
  -- Auto-counting is limited to what nothing else records.
  local function allowed(id)
    return refresh_inventory().trackSet[id]==true
  end
  -- Editing and naming are offered for every trackable or manifest game.
  local function editable(id)
    return refresh_inventory().editSet[id]==true
  end
  local function game(id)
    local k=tostring(id)
    data.games[k]=data.games[k] or {title='App '..k,trackedSeconds=0,adjustmentSeconds=0,lastPlayed=0}
    return data.games[k]
  end
  -- A failed atomic rename must not count playtime in RAM. Otherwise the client
  -- retries a failed pulse and the next successful save counts it twice.
  -- Snapshot before mutation; the ledger is bounded, and durable correctness is
  -- worth more than the encode/decode of a few hundred kilobytes per pulse.
  local function transaction(fn)
    local ok,snapshot=pcall(json.encode,data)
    if not ok then return false,snapshot end
    local success,err=pcall(fn)
    if success then
      local executed,saved,why=pcall(persist,data,ledger)
      if executed and saved then return true end
      err=executed and why or saved
    end
    -- Restore even when the callback or the underlying fs shim throws.
    local restored,original=pcall(json.decode,snapshot)
    if restored and type(original)=='table' then data=sanitize(original,data.account,true) end
    return false,err
  end
  registry.SlsPlaytimeReport=function(raw)
    if type(raw)~='string' or #raw>2000 then return reply({success=false,error='Invalid report'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' then return reply({success=false,error='Malformed report'}) end
    runtime.healthy=obj.healthy==true
    runtime.error=tostring(obj.error or ''):sub(1,250)
    runtime.reportedAt=os.time()
    -- Reject a report from a different account instead of filing its time here.
    local reported=obj.account
    if type(reported)=='string' and reported:match('^%d+$') and #reported>=16 and #reported<=20
      and data.account~='' and reported~=data.account then
      runtime.healthy=false
      runtime.error='Account mismatch: Steam reports '..reported..', this ledger belongs to '..data.account
      return reply({success=false,error=runtime.error})
    end
    return reply({success=true})
  end
  -- JS side sends elapsed seconds computed from monotonic+wall time on each
  -- heartbeat. Persist at most 30s at a time and never treat a missing
  -- heartbeat as playing forever.
  registry.SlsPlaytimeHeartbeat=function(raw)
    if type(raw)~='string' or #raw>10000 then return reply({success=false,error='Invalid heartbeat'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' or not valid_id(obj.id) then return reply({success=false,error='Invalid AppID'}) end
    local id=tonumber(obj.id);local k=tostring(id)
    if obj.kind~='start' and obj.kind~='pulse' and obj.kind~='stop' then
      return reply({success=false,error='Invalid heartbeat kind'})
    end
    local sid=obj.sid
    if type(sid)~='string' or #sid<1 or #sid>64 or not sid:match('^[%w%-%._]+$') then
      return reply({success=false,error='Invalid session identifier'})
    end
    local seq=0
    if obj.kind~='start' then
      seq=tonumber(obj.seq)
      if not seq or seq~=math.floor(seq) or seq<1 or seq>1e15 then
        return reply({success=false,error='Invalid heartbeat sequence'})
      end
    end
    if obj.kind=='start' and not allowed(id) then
      return reply({success=false,error='Not a manifest game'})
    end
    local elapsed=0
    if obj.kind~='start' then
      elapsed=tonumber(obj.elapsed)
      if not elapsed or elapsed<0 or elapsed>MAX_PULSE or elapsed~=elapsed then
        return reply({success=false,error='Invalid heartbeat duration'})
      end
    end
    -- Idempotent replay. The ledger already committed this sequence, so the
    -- response was lost on the way back to the page; report success and do not
    -- count the interval a second time.
    if obj.kind~='start' then
      local current=data.active[k]
      if not current then
        if data.acked[sid] then return reply({success=true,replayed=true}) end
        return reply({success=false,error='No active session',code='no_session'})
      end
      if current.sid~=sid then
        if data.acked[sid] then return reply({success=true,replayed=true}) end
        return reply({success=false,error='Session was replaced',code='no_session'})
      end
      if seq<=current.seq then return reply({success=true,replayed=true}) end
    end
    local saved,err=transaction(function()
      if obj.kind=='start' then
        local current=data.active[k]
        -- Keep the committed sequence on a replayed start. Resetting it would
        -- make the next pulse look new and count an already counted interval.
        if not current or current.sid~=sid then data.active[k]={sid=sid,seq=0,timestamp=os.time()} end
        local entry=game(id)
        if type(obj.title)=='string' and #obj.title<=160 and obj.title~='' then entry.title=obj.title end
        entry.lastPlayed=os.time()
        return
      end
      local current=data.active[k]
      local entry=game(id)
      entry.trackedSeconds=math.min(MAX_SECONDS,entry.trackedSeconds+elapsed)
      entry.lastPlayed=os.time()
      local day=day_key(0)
      data.daily[day]=math.min(MAX_SECONDS,(data.daily[day] or 0)+elapsed)
      if elapsed>0 then
        data.events[#data.events+1]={id=id,endedAt=os.time(),seconds=elapsed}
        if #data.events>MAX_EVENTS then table.remove(data.events,1) end
      end
      current.seq=seq
      if obj.kind=='stop' then
        data.active[k]=nil
        remember_ack(data,sid,seq)
      end
    end)
    return reply({success=saved,error=err})
  end
  registry.SlsPlaytimeTitles=function(raw)
    if type(raw)~='string' or #raw>400000 then return reply({success=false,error='Invalid name list'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' or type(obj.titles)~='table' then
      return reply({success=false,error='Malformed name list'})
    end
    local incoming,count={},0
    for k,v in pairs(obj.titles) do
      count=count+1
      if count>MAX_TITLES then return reply({success=false,error='Too many names'}) end
      -- Names are accepted for anything the panel can show and edit.
      if not valid_id(k) or type(v)~='string' or v=='' or #v>160 or not editable(tonumber(k)) then
        return reply({success=false,error='Invalid name entry'})
      end
      incoming[tostring(tonumber(k))]=v
    end
    if next(incoming)==nil then return reply({success=true,unchanged=true}) end
    local changed=false
    for k,v in pairs(incoming) do
      if data.titles[k]~=v then changed=true;break end
    end
    if not changed then return reply({success=true,unchanged=true}) end
    local saved,err=transaction(function()
      for k,v in pairs(incoming) do data.titles[k]=v end
    end)
    return reply({success=saved,error=err})
  end
  registry.SlsPlaytimeGet=function()
    -- `events` is deliberately not part of this payload: a full pulse history
    -- is megabytes, and the panel only needs totals plus a short diagnostic
    -- tail. SlsPlaytimeExport still returns the complete record for backups.
    local snap=refresh_inventory()
    -- Wire copy: officialSeconds rides along for display only and is never
    -- persisted, so the ledger stays the source of truth for our own counts
    -- while every surface can agree with Steam's own number.
    local official=official_playtimes(root,data.account)
    local wire={}
    for key,record in pairs(data.games) do
      local copy={title=record.title,trackedSeconds=record.trackedSeconds,
        adjustmentSeconds=record.adjustmentSeconds,lastPlayed=record.lastPlayed}
      if official[key] then copy.officialSeconds=official[key] end
      wire[key]=copy
    end
    return reply({success=true,games=wire,active=data.active,
      apps=json.array(snap.ids),trackedApps=json.array(snap.trackIds),
      stats=stats(data),account=data.account,
      runtime=runtime,schema=SCHEMA,recent=recent_events(data,20),titles=data.titles,
      manifestCount=snap.manifestCount,shortcutCount=snap.shortcutCount,
      shortcutNames=snap.shortcutNames,libraryError=snap.libraryError,
      policy={trackManifests=os.getenv('SLS_PLAYTIME_TRACK_MANIFESTS')=='1'}})
  end
  registry.SlsPlaytimeEdit=function(raw)
    if type(raw)~='string' then return reply({success=false,error='Invalid value'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' or not valid_id(obj.id) then return reply({success=false,error='Invalid AppID'}) end
    if not editable(tonumber(obj.id)) then return reply({success=false,error='Not a manifest game or non-Steam shortcut'}) end
    local hours=tonumber(obj.hours)
    if not hours or hours<0 or hours>10000000 or hours~=hours then return reply({success=false,error='Invalid hours'}) end
    local saved,err=transaction(function()
      local entry=game(tonumber(obj.id))
      -- For games Steam tracks itself the correction is anchored to Steam's
      -- own lifetime number: the edit sets the displayed total, Steam's
      -- counter keeps running underneath, and both stay in agreement.
      local official=official_playtimes(root,data.account)[tostring(math.floor(tonumber(obj.id)))]
      local base=official or entry.trackedSeconds
      entry.adjustmentSeconds=hours*3600-base
    end)
    return reply({success=saved,error=err})
  end
  registry.SlsPlaytimeExport=function()
    return reply({success=true,data={version=SCHEMA,account=data.account,games=data.games,
      events=json.array(data.events),daily=data.daily,titles=data.titles,stats=stats(data)}})
  end
  registry.SlsPlaytimeImport=function(raw)
    -- Never replace the ledger while an agent is accumulating sessions; the
    -- agent and the backend would disagree about what is already counted.
    if next(data.active)~=nil then
      return reply({success=false,error='Stop all tracked games before importing a backup'})
    end
    if type(raw)~='string' or #raw>5000000 then return reply({success=false,error='Oversized or invalid backup'}) end
    local ok,obj=pcall(json.decode,raw)
    if not ok or type(obj)~='table' then return reply({success=false,error='Unsupported backup schema'}) end
    if obj.version~=1 and obj.version~=SCHEMA then return reply({success=false,error='Unsupported backup schema'}) end
    if type(obj.games)~='table' then return reply({success=false,error='Backup has no game records'}) end
    if obj.events~=nil and type(obj.events)~='table' then return reply({success=false,error='Backup has an invalid event list'}) end
    if obj.daily~=nil and type(obj.daily)~='table' then return reply({success=false,error='Backup has an invalid daily list'}) end
    -- Refuse to mix two accounts by accident. Copying hours between accounts is
    -- possible, but it has to be asked for explicitly.
    local declared=obj.account
    if type(declared)=='string' and declared~='' and data.account~='' and declared~=data.account
      and obj.allowAccountMismatch~=true then
      return reply({success=false,error='Backup belongs to Steam account '..declared
        ..', this ledger belongs to '..data.account..'. Import it with allowAccountMismatch to copy it deliberately.'})
    end
    -- A backup is a point-in-time snapshot: it must never resurrect a session.
    local replacement=sanitize(obj,data.account)
    replacement.version=SCHEMA
    if data.account~='' then replacement.account=data.account end
    local saved,err=persist(replacement,ledger)
    if saved then
      data=replacement
      runtime.error=''
      return reply({success=true})
    end
    return reply({success=false,error=err})
  end
  return M
end
return M
