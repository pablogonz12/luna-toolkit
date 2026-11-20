-- Mocked Lua backend integration test: persistent state, RPC surface and guards.
-- Only run with HOME pointing to a disposable tmpdir (enforced by runner).
assert(os.getenv('SLS_TEST_HOME') == os.getenv('HOME'), 'Test must run in isolated HOME')
local contents = {}
local n = 0
package.preload['json'] = function()
  return {
    encode=function(t)
      n=n+1
      contents[n]=t
      return 'mock-json:'..tostring(n)
    end,
    decode=function(s)
      local i=tonumber((s or ''):match('^mock%-json:(%d+)$'))
      assert(i and contents[i], 'invalid fake JSON')
      return contents[i]
    end,
  }
end
package.preload['fs'] = function()
  return {
    create_directories=function(dir)
      local success=os.execute('mkdir -p '..string.format('%q',dir))
      assert(success==true or success==0)
      return true
    end,
    exists=function(path)
      return path:match('loginusers%.vdf$')~=nil
    end,
    join=function(...) return table.concat({...},'/') end,
    list=function(path)
      -- The installed-library scan: appmanifest_<appid>.acf under steamapps.
      assert(path:find('steamapps$'), 'unexpected listing: '..tostring(path))
      return { {name='appmanifest_620.acf',is_directory=false},
        {name='appmanifest_621.acf.disabled',is_directory=false},
        {name='libraryfolders.vdf',is_directory=false} }
    end,
  }
end
package.preload['millennium'] = function()
  return {steam_path=function() return os.getenv('HOME')..'/steam' end}
end
local json=require('json')
-- The account identity comes from Steam's config/loginusers.vdf. Write a
-- realistic fixture so the digests in the assertions are the real ones the JS
-- agent computes for the same SteamID64 (the two implementations must agree).
local steam_root=os.getenv('HOME')..'/steam'
assert(os.execute('mkdir -p '..string.format('%q',steam_root..'/config')))
do
  local f=assert(io.open(steam_root..'/config/loginusers.vdf','wb'))
  f:write([[
"users"
{
	"76561198000000000"
	{
		"AccountName"		"testaccount"
		"PersonaName"		"LePapot"
		"MostRecent"		"1"
		"Timestamp"		"1791884517"
	}
}
]])
  f:close()
end
local function call(registry, name, arg)
  assert(type(registry[name])=='function', 'missing RPC: '..name)
  local raw=registry[name](arg)
  return json.decode(raw)
end
local reg={}
local plugin=assert(loadfile('addons/presence/plugin/backend/main.lua'))()
assert(type(plugin)=='table' and type(plugin.register)=='function')
plugin.register(reg)
local get=call(reg,os.getenv('SLS_KIND')=='presence' and 'SlsPresenceGet' or 'SlsPlaytimeGet')
assert(get.success and #get.apps==1 and get.apps[1]==620, 'manifest filtering failed')
if os.getenv('SLS_KIND')=='presence' then
  local init=get.state
  assert(init.enabled==false, 'presence must start disabled')
  assert(type(get.session)=='table' and type(get.session.helpersAllowed)=='boolean', 'session helper policy missing')
  local desktop_policy=plugin.helper_policy(function() return nil end)
  assert(desktop_policy.helpersAllowed==true and desktop_policy.mode=='desktop', 'desktop helpers must stay available')
  for _,key in ipairs({'GAMESCOPE_WAYLAND_DISPLAY','GAMESCOPE_LIMITER_FILE','XDG_CURRENT_DESKTOP'}) do
    local policy=plugin.helper_policy(function(name) return name==key and 'gamescope' or nil end)
    assert(policy.helpersAllowed==true and policy.requiresGameSelection==true and policy.mode=='gamescope',
      'Gamescope must require selection restoration: '..key)
  end
  local rejected=call(reg,'SlsPresencePut',json.encode({owned={['620']=3000000001,['621']=3000000001},running={}}))
  assert(rejected.success==false, 'shortcut ownership collision not rejected')
  local selfmap=call(reg,'SlsPresencePut',json.encode({owned={['620']=620},running={}}))
  assert(selfmap.success==false, 'a shortcut cannot be the game itself')
  local admitted=call(reg,'SlsPresencePut',json.encode({owned={['620']=3000000001},running={}}))
  assert(admitted.success==true, 'valid owned shortcut rejected')
  assert(call(reg,'SlsPresenceSetEnabled',true).enabled==true)
  assert(call(reg,'SlsPresenceGet').state.enabled==true)
  assert(call(reg,'SlsPresenceReport',json.encode({healthy=false,error='API missing'})).success)
  assert(call(reg,'SlsPresenceGet').runtime.error=='API missing')
  -- The account digest is persisted but only in its validated 8-hex form.
  assert(call(reg,'SlsPresencePut',json.encode({owned={['620']=3000000001},running={},account='a1b2c3d4'})).success)
  assert(call(reg,'SlsPresenceGet').state.account=='a1b2c3d4', 'account digest not stored')
  assert(call(reg,'SlsPresencePut',json.encode({owned={['620']=3000000001},running={},account='NOT-HEX!'})).success)
  assert(call(reg,'SlsPresenceGet').state.account=='a1b2c3d4', 'invalid account digest overwrote the ledger')
  -- The raw SteamID must never be accepted into the ledger.
  assert(call(reg,'SlsPresencePut',json.encode({owned={},running={},account='76561198000000000'})).success)
  assert(call(reg,'SlsPresenceGet').state.account=='a1b2c3d4', 'raw SteamID was stored')
  -- Name enrichment: defaults on, persists, and survives agent ledger saves.
  assert(call(reg,'SlsPresenceGet').state.sessionTime==true, 'session time must default on')
  assert(call(reg,'SlsPresenceSetSessionTime','nonsense').success==false, 'non-boolean accepted')
  assert(call(reg,'SlsPresenceSetSessionTime',false).sessionTime==false)
  assert(call(reg,'SlsPresenceGet').state.sessionTime==false)
  assert(call(reg,'SlsPresencePut',json.encode({owned={['620']=3000000001},running={}})).success)
  assert(call(reg,'SlsPresenceGet').state.sessionTime==false, 'agent ledger save dropped the enrichment toggle')
  assert(call(reg,'SlsPresenceSetSessionTime',true).sessionTime==true)
  -- Runtime capability diagnostics surface to the panel.
  local diag=call(reg,'SlsPresenceReport',json.encode({healthy=true,active=1,owned=1,running=0,
    accountMismatch=true,hideStrategy='collectionHidden',hideVerified=true,
    contracts={addShortcut=4,setShortcutHidden=nil},activeIds={620}}))
  assert(diag.success)
  local rt=call(reg,'SlsPresenceGet').runtime
  assert(rt.hideStrategy=='collectionHidden' and rt.hideVerified==true, 'hide diagnostics lost')
  assert(rt.accountMismatch==true, 'account mismatch flag lost')
  assert(rt.contracts.addShortcut==4, 'contract arity lost')
  assert(rt.contracts.setShortcutHidden==json.null or rt.contracts.setShortcutHidden==nil, 'absent API must stay absent')
  assert(rt.owned==1 and rt.running==0, 'ledger counts lost')
  -- The account identity is derived from loginusers.vdf and must match the JS
  -- FNV-1a implementation byte for byte (see tests/presence-lifecycle.test.cjs).
  local ident=call(reg,'SlsPresenceGet').identity
  assert(ident, 'identity missing')
  assert(ident.key=='5bda05e3', 'identity digest mismatch: '..tostring(ident.key))
  assert(ident.source=='loginusers', 'identity source must be reported')
  assert(ident.known==1 and ident.ambiguous==false, 'single account must not be ambiguous')
  -- Discord Rich Presence: name resolution and IPC framing (no socket opened).
  assert(plugin.acf_name('"AppState"\n{\n\t"appid"\t\t"3405340"\n\t"name"\t\t"Megabonk"\n}')=='Megabonk', 'acf name')
  local function reader(path)
    return path=='/lib/appmanifest_3405340.acf' and '"name"\t"Megabonk"' or nil
  end
  assert(plugin.resolve_game_name(3405340,{},{'/nope','/lib'},reader)=='Megabonk', 'manifest name')
  assert(plugin.resolve_game_name(3405340,{['3405340']='Custom'},{'/lib'},reader)=='Custom', 'titles map wins')
  assert(plugin.resolve_game_name(1,{},{'/lib'},reader)==nil and plugin.resolve_game_name('x',{},{},reader)==nil, 'unknown app')
  local paths=plugin.discord_socket_paths(function(k) return k=='XDG_RUNTIME_DIR' and '/run/user/1000' or nil end)
  assert(paths[1]=='/run/user/1000/discord-ipc-0' and paths[2]=='/run/user/1000/app/com.discordapp.Discord/discord-ipc-0', 'socket paths')
  assert(#plugin.discord_socket_paths(function() return nil end)==0, 'no runtime dir')
  local function unframe(frame)
    local op,len=string.unpack('<I4I4',frame)
    assert(#frame==8+len, 'frame length')
    return op,json.decode(frame:sub(9))
  end
  local op,hs=unframe(plugin.discord_handshake(123456789012345678))
  assert(op==0 and hs.v==1 and hs.client_id=='123456789012345678', 'handshake')
  local op2,act=unframe(plugin.discord_set_activity(4242,'Megabonk',1700000000,'n1'))
  assert(op2==1 and act.cmd=='SET_ACTIVITY' and act.args.pid==4242 and act.nonce=='n1', 'set activity')
  assert(act.args.activity.name=='Megabonk' and act.args.activity.type==0
    and act.args.activity.timestamps.start==1700000000, 'activity payload')
  local _,cleared=unframe(plugin.discord_set_activity(4242,nil,nil,'n2'))
  assert(cleared.args.activity==nil, 'clear activity')
  local plan=call(reg,'SlsPresenceDiscordPlan',json.encode({appid=620}))
  assert(plan.needsClientId==true and type(plan.sockets)=='table', 'plan must report the missing client id')
  -- Read-only contract probe: proves the {raw: string} argument shape.
  local probe=call(reg,'SlsPresenceContractProbe',json.encode({a=1}))
  assert(probe.success and probe.argType=='string' and probe.decoded==true, 'contract probe failed')
  local noarg=call(reg,'SlsPresenceContractProbe')
  assert(noarg.success and noarg.argType=='nil' and noarg.decoded==false, 'missing arg must not decode')
  -- Read-only process snapshot used to recover state after a context recreation.
  local function list_proc(path)
    assert(path=='/proc')
    return { {name='1',is_directory=true}, {name='999',is_directory=true},
             {name='not-a-pid',is_directory=true}, {name='self',is_directory=true},
             {name='2222',is_directory=true} }
  end
  local function read_proc(path)
    if path=='/proc/1/cmdline' then return 'systemd\0--user\0' end
    if path=='/proc/999/cmdline' then
      return table.concat({'/home/x/Steam/ubuntu12_32/reaper','SteamLaunch','AppId=620',
        '--','/usr/bin/sleep','86400'}, string.char(0)) .. string.char(0)
    end
    if path=='/proc/2222/cmdline' then
      return table.concat({'/home/x/reaper','AppId=2101960','--','/game/Cronos.exe'}, string.char(0))
    end
    return nil
  end
  local games,helpers,complete=plugin.collect_running(list_proc,read_proc)
  assert(complete==true, 'complete scan must be marked complete')
  assert(#games==2 and #helpers==1, 'process scan did not separate games from helpers')
  local has={}
  for _,id in ipairs(games) do has[id]=true end
  assert(has[620] and has[2101960], 'AppId markers not parsed')
  assert(helpers[1]==620, 'the sleep helper was not identified')
  -- A reader that throws must not take the backend down.
  local safe_games,safe_helpers,safe_complete=plugin.collect_running(list_proc,function() error('denied') end)
  assert(#safe_games==0 and #safe_helpers==0, 'scan must fail closed, not raise')
  assert(safe_complete==false, 'failed readers must not produce an authoritative empty snapshot')
  local none_games,none_helpers,none_complete=plugin.collect_running(function() return nil end,read_proc)
  assert(#none_games==0 and #none_helpers==0, 'missing /proc must not raise')
  assert(none_complete==false, 'missing /proc must be marked incomplete')
  local pids={}
  for i=1,8193 do pids[i]={name=tostring(i)} end
  local _,_,truncated=plugin.collect_running(function() return pids end,read_proc)
  assert(truncated==false, 'PID cap must not masquerade as a complete snapshot')
  local duplicates=function() return {{name='10'},{name='11'}} end
  local duplicate_games,duplicate_helpers=plugin.collect_running(duplicates,function()
    return '/reaper\0AppId=620\0--\0/usr/bin/sleep\00086400\0'
  end)
  assert(#duplicate_games==1 and #duplicate_helpers==1, 'snapshots must deduplicate AppIDs, not just PIDs')
  local single=function() return {{name='10'}} end
  for _,raw in ipairs({'/tool\0FakeAppId=620\0', '/tool\0AppId=620invalid\0'}) do
    local spoofed=plugin.collect_running(single,function() return raw end)
    assert(#spoofed==0, 'AppId must occupy an entire cmdline token')
  end
  local _,not_helpers=plugin.collect_running(single,function()
    return '/reaper\0AppId=620\0--\0/usr/bin/sleep-other\00086400\0'
  end)
  assert(#not_helpers==0, 'helper executable matching must not accept a substring')
  local string_games,_,string_complete=plugin.collect_running(function() return {'10'} end,function()
    return '/reaper\0AppId=620\0/game\0'
  end)
  assert(#string_games==1 and string_complete, 'string-shaped directory entries remain supported')
  -- The loginusers parser drives the account guard; it must not be fooled by
  -- numeric keys that are not SteamIDs.
  local users=plugin.login_users('"shortkey"{ "AccountName" "x" }\n"76561198000000000"{ "MostRecent" "1" }')
  assert(#users==1, 'only 17+ digit keys are accounts')
  assert(users[1].id=='76561198000000000' and users[1].most_recent==true, 'SteamID block not parsed')
  assert(users[1].account_name==nil, 'fields must not leak between account blocks')
  -- A stop on a shortcut the ledger cannot confirm is refused by the backend too.
  assert(call(reg,'SlsPresencePut',json.encode({owned={['620']=3000000001},running={['620']=3000000002}})).success==false,
    'running entry for an unowned shortcut accepted')
  -- Discord session state machine against an injected fake transport.
  do
    local sent_ops, alive_conn = {}, nil
    local function frame(op, tbl) local b=json.encode(tbl); return string.pack('<I4I4',op,#b)..b end
    local function mkconn(up, readyframe)
      local c={fd=-1,queue={},closed=false,timeout=0}
      function c:settimeout(t) self.timeout=t end
      function c:getfd() return self.fd end
      function c:connect() if not up.on then return nil,'refused' end self.fd=7 return 1 end
      function c:close() self.closed=true self.fd=-1 end
      function c:send(data)
        if self.closed then return nil,'closed' end
        local op,len=string.unpack('<I4I4',data)
        local body=json.decode(data:sub(9,8+len))
        sent_ops[#sent_ops+1]={op=op,body=body}
        if op==0 then self.queue[#self.queue+1]=readyframe end
        return #data
      end
      function c:receive(n)
        local q=self.queue
        if self.dead then return nil,'closed' end
        if #q==0 then return nil,'timeout' end
        local cur=q[1]
        if #cur<n then return nil,'timeout' end
        q[1]=cur:sub(n+1); local out=cur:sub(1,n)
        if #q[1]==0 then table.remove(q,1) end
        return out
      end
      return c
    end
    local up={on=false}
    local ready=frame(1,{cmd='DISPATCH',evt='READY'})
    local deps={paths=function() return {'/fake/ipc-0'} end, pid=function() return 4242 end,
      unix=function() alive_conn=mkconn(up,ready); return alive_conn end}
    local S=plugin.new_discord_session(deps)
    local game={appid=620,name='Portal 2'}
    assert(S.step({enabled=true,app_id=''},game,100)=='needs_app_id', 'empty app id must report needs_app_id')
    assert(#sent_ops==0, 'nothing may be sent without an app id')
    assert(S.step({enabled=true,app_id='123456789012345678'},nil,100)=='idle', 'no game is idle')
    assert(S.step({enabled=true,app_id='123456789012345678'},game,100)=='no_discord', 'unreachable Discord')
    assert(S.step({enabled=true,app_id='123456789012345678'},game,105)=='no_discord' and #sent_ops==0, 'backoff must hold')
    up.on=true
    assert(S.step({enabled=true,app_id='123456789012345678'},game,120)=='connected', 'must connect after backoff')
    assert(sent_ops[1].op==0 and sent_ops[1].body.client_id=='123456789012345678', 'handshake with app id')
    assert(sent_ops[2].op==1 and sent_ops[2].body.cmd=='SET_ACTIVITY', 'activity sent')
    local act=sent_ops[2].body.args
    assert(act.pid==4242 and act.activity.name=='Portal 2' and act.activity.details=='Portal 2'
      and act.activity.type==0 and act.activity.timestamps.start==100, 'activity payload')
    local n=#sent_ops
    assert(S.step({enabled=true,app_id='123456789012345678'},game,125)=='connected' and #sent_ops==n, 'steady state sends nothing')
    alive_conn.queue[#alive_conn.queue+1]=frame(3,{nonce='x'})
    S.step({enabled=true,app_id='123456789012345678'},game,130)
    assert(sent_ops[#sent_ops].op==4, 'ping must be answered with pong')
    alive_conn.dead=true -- Discord restarted
    up.on=false
    assert(S.step({enabled=true,app_id='123456789012345678'},game,135)=='no_discord', 'dead connection detected')
    up.on=true
    assert(S.step({enabled=true,app_id='123456789012345678'},game,160)=='connected', 'reconnects and resends')
    assert(sent_ops[#sent_ops].body.cmd=='SET_ACTIVITY' and sent_ops[#sent_ops].body.args.activity, 'activity resent')
    local conn=alive_conn
    assert(S.step({enabled=true,app_id='123456789012345678'},nil,170)=='idle', 'game stop is idle')
    assert(sent_ops[#sent_ops].body.args.activity==nil and conn.closed, 'clear activity then close')
    assert(S.step({enabled=false,app_id='123456789012345678'},game,200)=='idle' and #sent_ops>0, 'disabled never connects')
    -- RPCs and the host tick hook
    local st=call(reg,'SlsPresenceDiscordStatus')
    assert(st.success and st.hasAppId==false and st.status=='idle', 'status RPC before configuration')
    assert(call(reg,'SlsPresenceSetDiscord',json.encode({appId='abc'})).success==false, 'non numeric app id rejected')
    local set=call(reg,'SlsPresenceSetDiscord',json.encode({enabled=false,appId='123456789012345678'}))
    assert(set.success and set.discordEnabled==false and set.discordAppId=='123456789012345678', 'settings saved')
    assert(call(reg,'SlsPresenceGet').state.discordAppId=='123456789012345678', 'settings exposed in state')
    assert(call(reg,'SlsPresencePut',json.encode({owned={},running={}})).success)
    assert(call(reg,'SlsPresenceGet').state.discordEnabled==false, 'Put must keep discord settings')
    assert(type(plugin.tick)=='function' and plugin.tick(1)==nil, 'tick hook never raises')
  end
else
  assert(call(reg,'SlsPlaytimeHeartbeat',json.encode({id=999,kind='start'})).success==false)
  assert(call(reg,'SlsPlaytimeHeartbeat',json.encode({id=620,kind='start',title='Portal 2'})).success)
  local backup=call(reg,'SlsPlaytimeExport').data
  assert(call(reg,'SlsPlaytimeImport',json.encode(backup)).success==false, 'import while active accepted')
  assert(call(reg,'SlsPlaytimeHeartbeat',json.encode({id=620,kind='pulse',elapsed=10})).success)
  assert(call(reg,'SlsPlaytimeHeartbeat',json.encode({id=620,kind='stop',elapsed=3})).success)
  assert(call(reg,'SlsPlaytimeEdit',json.encode({id=620,hours=2})).success)
  local item=call(reg,'SlsPlaytimeGet').games['620']
  assert(math.abs(item.trackedSeconds+item.adjustmentSeconds-7200)<0.001)
  assert(call(reg,'SlsPlaytimeImport',json.encode(backup)).success)
  assert(call(reg,'SlsPlaytimeReport',json.encode({healthy=true})).success)
  assert(call(reg,'SlsPlaytimeGet').runtime.healthy==true)
end
print('Lua backend smoke OK ('..os.getenv('SLS_KIND')..')')
