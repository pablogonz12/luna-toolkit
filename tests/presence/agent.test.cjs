const {test}=require('node:test');
const assert=require('node:assert/strict');
const {PresenceController,shortcutGameId}=require('../../addons/presence/plugin/public/agent.js');
const {makeGameSelectionRestorer}=require('../../addons/presence/plugin/public/agent.js');
function storage(){const m=new Map();let wait=Promise.resolve();return {getItem:k=>m.get(k)||null,setItem:(k,v)=>{m.set(k,v);wait=wait.then(()=>{})},flush:()=>wait};}
function harness(hidden=true){
 const calls=[],id=3000000000,names=new Map([[3000000000,'Portal 2']]);
 const apps={
  AddShortcut:async(...args)=>{calls.push(['add',...args]);names.set(id,args[0]);return id},
  RunGame:async(...args)=>{calls.push(['run',...args])},
  TerminateApp:async(...args)=>{calls.push(['terminate',...args])},
  RemoveShortcut:async(...args)=>{calls.push(['remove',...args]);names.delete(args[0])},
  SetShortcutLaunchOptions:(...args)=>{calls.push(['options',...args])}
 };
 // A created placeholder carries the real title, exactly as Steam stores it.
 const overview=appid=>appid===620?{display_name:'Portal 2'}
   :(names.has(appid)?{display_name:names.get(appid),app_type:1073741824}:null);
 const c=new PresenceController({apps,storage:storage(),overview,hideShortcut:async x=>{calls.push(['hide',x]);return hidden},delay:async()=>{},accountKey:'deadbeef'});
 c.updateInjected([620]);return {c,calls};}
test('disabled by default, no games launched',async()=>{const {c,calls}=harness();await c.onLifetime({unAppID:620,bRunning:true});assert.equal(calls.length,0)});
test('Gamescope policy blocks helper starts even when presence is enabled',async()=>{
  const {c,calls}=harness();c.setEnabled(true);
  await c.setHelperPolicy({helpersAllowed:false});
  await c.onLifetime({unAppID:620,bRunning:true});
  assert.equal(calls.length,0);assert.equal(c.state.enabled,true);
  assert.equal(c.active.has(620),true);assert.equal(c.report().helpersPaused,true);
});
test('policy is rechecked after asynchronous shortcut setup',async()=>{
  const {c,calls}=harness();c.setEnabled(true);
  const configure=c.configure.bind(c);
  c.configure=async(...args)=>{await configure(...args);await c.setHelperPolicy({helpersAllowed:false});};
  await c.onLifetime({unAppID:620,bRunning:true});
  assert.equal(calls.filter(x=>x[0]==='run').length,0);
  assert.equal(c.state.enabled,true);
});
test('policy is rechecked immediately after the final launch-ledger flush',async()=>{
  const {c,calls}=harness();c.setEnabled(true);
  let flushes=0;c.storage.flush=async()=>{if(++flushes===2)c.helpersAllowed=false;};
  await c.onLifetime({unAppID:620,bRunning:true});
  assert.equal(calls.filter(x=>x[0]==='run').length,0);
  assert.equal(c.started.size,0);assert.deepEqual(c.state.running,{});
});
test('returning to desktop policy permits the helper without toggling the preference',async()=>{
  const {c,calls}=harness();c.setEnabled(true);
  await c.setHelperPolicy({helpersAllowed:false});
  await c.onLifetime({unAppID:620,bRunning:true});
  await c.setHelperPolicy({helpersAllowed:true});
  await c.begin(620);
  assert.equal(calls.filter(x=>x[0]==='run').length,1);
  assert.equal(c.state.enabled,true);
});
test('selection restoration waits for the helper, then reorders without navigating or closing menus',async()=>{
  let selected=620, waits=0;const calls=[];
  const store={get MainRunningAppID(){return selected},RunningApps:[{appid:620},{appid:3000000000}],
    SetRunningApp:id=>{calls.push(id);selected=id}};
  const restore=makeGameSelectionRestorer({SteamUIStore:store},{delay:async()=>{waits++;selected=3000000000}});
  assert.equal(await restore.restore(620,3000000000),true);
  assert.equal(waits,1);assert.deepEqual(calls,[620]);
});
test('selection restoration respects another game or an original that already stopped',async()=>{
  const calls=[];
  const store={MainRunningAppID:777,RunningApps:[{appid:620},{appid:3000000000},{appid:777}],SetRunningApp:id=>calls.push(id)};
  const restore=makeGameSelectionRestorer({SteamUIStore:store},{delay:async()=>{}});
  assert.equal(await restore.restore(620,3000000000),false);
  store.MainRunningAppID=3000000000;
  assert.equal(await restore.restore(620,3000000000,()=>false),false);
  assert.deepEqual(calls,[]);
});
test('selection restoration is bounded when the helper never becomes selected',async()=>{
  let waits=0;
  const store={MainRunningAppID:620,RunningApps:[{appid:620}],SetRunningApp(){throw Error('must not be called')}};
  const restore=makeGameSelectionRestorer({SteamUIStore:store},{attempts:3,delay:async()=>{waits++}});
  assert.equal(await restore.restore(620,3000000000),false);assert.equal(waits,3);
});
test('hide then launch helper, stop and remove it before the next session',async()=>{const {c,calls}=harness();c.setEnabled(true);await c.onLifetime({unAppID:620,bRunning:true});assert.ok(calls.findIndex(x=>x[0]==='hide')<calls.findIndex(x=>x[0]==='run'));assert.equal(calls.filter(x=>x[0]==='add').length,1);await c.onLifetime({unAppID:620,bRunning:false});assert.ok(calls.some(x=>x[0]==='terminate'&&x[1]===shortcutGameId(3000000000)));assert.deepEqual(c.state.owned,{});await c.onLifetime({unAppID:620,bRunning:true});assert.equal(calls.filter(x=>x[0]==='add').length,2)});
test('fail closed when Steam hiding API unsupported',async()=>{const {c,calls}=harness(false);c.setEnabled(true);await c.onLifetime({unAppID:620,bRunning:true});assert.equal(calls.filter(x=>x[0]==='run').length,0);assert.equal(calls.filter(x=>x[0]==='remove').length,1)});
test('removal never removes original real Steam app',async()=>{const {c,calls}=harness();c.state.owned[620]=3000000000;await c.cleanupOwned();assert.deepEqual(calls,[['remove',3000000000]])});

test('a stop event still closes a helper after its Lua manifest is removed',async()=>{
  const {c,calls}=harness();
  c.setEnabled(true);
  await c.onLifetime({unAppID:620,bRunning:true});
  c.updateInjected([]);
  await c.onLifetime({unAppID:620,bRunning:false});
  assert.equal(calls.filter(x=>x[0]==='terminate').length,1);
  assert.equal(c.state.running[620],undefined);
});

test('reconciliation lists deleted manifests for immediate helper shutdown',async()=>{
  const {c,calls}=harness();
  c.setEnabled(true);
  await c.onLifetime({unAppID:620,bRunning:true});
  assert.deepEqual(c.updateInjected([]),[620]);
  await c.end(620);
  assert.equal(calls.filter(x=>x[0]==='terminate').length,1);
});

test('no new helper is created after a manifest disappears',async()=>{
  const {c,calls}=harness();
  c.setEnabled(true);
  c.updateInjected([]);
  await c.begin(620);
  await c.onLifetime({unAppID:620,bRunning:true});
  assert.equal(calls.length,0);
});

test('unknown original non-manifest stop does not terminate shortcuts',async()=>{
  const {c,calls}=harness();
  c.setEnabled(true);
  await c.onLifetime({unAppID:1234,bRunning:false});
  assert.equal(calls.length,0);
});

const {probeCapabilities}=require('../../addons/presence/plugin/public/agent.js');
test('startup fails closed and reports missing Steam APIs',()=>{
  const result=probeCapabilities({SteamClient:{Apps:{},GameSessions:{}},Millennium:{callServerMethod(){}}});
  assert.equal(result.ok,false);
  assert.ok(result.missing.includes('Apps.RunGame'));
  assert.ok(result.missing.includes('Library hiding API'));
});
test('startup accepts complete Luna SharedJSContext APIs',()=>{
  // A real client also needs the two setup calls: without them the placeholder
  // would run with no duration and present the executable name ("sleep").
  const noop=()=>{};
  const result=probeCapabilities({SteamClient:{Apps:{AddShortcut:noop,RemoveShortcut:noop,RunGame:noop,TerminateApp:noop,SetAppHidden:noop,SetShortcutName:noop,SetShortcutLaunchOptions:noop},GameSessions:{RegisterForAppLifetimeNotifications:noop}},Millennium:{callServerMethod:noop}});
  assert.equal(result.ok,true);
});
test('startup reports the two setup APIs a placeholder cannot work without',()=>{
  const noop=()=>{};
  const incomplete=probeCapabilities({SteamClient:{Apps:{AddShortcut:noop,RemoveShortcut:noop,RunGame:noop,TerminateApp:noop,SetAppHidden:noop},GameSessions:{RegisterForAppLifetimeNotifications:noop}},Millennium:{callServerMethod:noop}});
  assert.equal(incomplete.ok,false);
  assert.ok(incomplete.missing.includes('Apps.SetShortcutName'));
  assert.ok(incomplete.missing.includes('Apps.SetShortcutLaunchOptions'));
});

test('Lua JSON empty-table encoding cannot break the injected manifest allowlist',()=>{
  const {c}=harness();
  assert.deepEqual(c.updateInjected({}),[]);
  assert.equal(c.injected.size,0);
});


test('a stop during the helper RunGame handshake waits for launch before termination', async () => {
  const {c,calls}=harness();
  let unblock;
  const gate=new Promise(resolve => {unblock=resolve});
  c.apps.RunGame=async (...args)=>{calls.push(['run',...args]);await gate};
  c.setEnabled(true);
  const start=c.onLifetime({unAppID:620,bRunning:true});
  for(let i=0;i<100 && !calls.some(x=>x[0]==='run');i++) await Promise.resolve();
  assert.equal(calls.some(x=>x[0]==='run'),true);
  const stop=c.onLifetime({unAppID:620,bRunning:false});
  await Promise.resolve();
  assert.equal(calls.some(x=>x[0]==='terminate'),false);
  unblock();
  await Promise.all([start,stop]);
  assert.equal(calls.filter(x=>x[0]==='terminate').length,1);
  assert.equal(c.state.running[620],undefined);
});


test('failed helper termination prevents destructive shortcut cleanup and remains retryable',async()=>{
  const {c,calls}=harness();c.setEnabled(true);
  await c.onLifetime({unAppID:620,bRunning:true});
  let fail=true;
  c.apps.TerminateApp=async (...args)=>{calls.push(['terminate',...args]);if(fail)throw Error('Steam busy');};
  await c.cleanupOwned();
  assert.equal(calls.filter(x=>x[0]==='remove').length,0);
  assert.equal(c.state.owned[620],3000000000);
  assert.equal(c.state.running[620],3000000000);
  fail=false;
  await c.cleanupOwned();
  assert.equal(calls.filter(x=>x[0]==='remove').length,1);
});
