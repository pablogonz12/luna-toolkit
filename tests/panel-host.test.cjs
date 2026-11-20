// Standalone panels when the host is missing or late.
//
// Two failure modes are covered here. (1) Luna is down or restarting: the rpc
// helper must reject cleanly ("bridge unavailable") instead of throwing a
// TypeError from the refresh interval, and the panel must say it is waiting.
// (2) A fast Steam start runs the script before document.body exists: the panel
// must retry a bounded number of times and only publish its __Sls*Panel flag
// once it really mounted, never mounting twice.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

const PRESENCE=path.join(__dirname,'..','addons','presence','plugin','public','panel.js');
const COMPRESSOR=path.join(__dirname,'..','addons','compressor','plugin','public','panel.js');
const PLAYTIME=require('../addons/playtime/plugin/public/panel.js');

function fakeWindow({body=true,millennium='ok'}={}){
  const registry={};
  const timers=[];
  const makeNode=tag=>{
    const element={
      tagName:(tag||'div').toUpperCase(),id:'',style:{cssText:''},hidden:true,textContent:'',
      value:'',children:[],
      append(...kids){kids.forEach(kid=>{element.children.push(kid);if(kid.id)registry[kid.id]=kid;});},
      appendChild(kid){element.append(kid);return kid;},
      replaceChildren(){element.children.length=0;},
      get nextSibling(){return null;},
    };
    return element;
  };
  const document={
    readyState:'complete',
    body:body?makeNode('body'):null,
    createElement:makeNode,
    getElementById:id=>registry[id]||null,
    addEventListener(){},
  };
  const host={callServerMethod:async()=>JSON.stringify({success:true,state:{enabled:false,owned:{}},
    runtime:{activeIds:[],contracts:{}},apps:[],tool:{found:true},status:{summary:{}},job:{},
    titles:{},shortcutNames:{},games:{},stats:null})};
  const w={
    document,
    Millennium:millennium==='ok'?host:undefined,
    setInterval:()=>1,
    clearInterval:()=>{},
    setTimeout:(fn,ms)=>{timers.push({fn,ms});return timers.length;},
    clearTimeout:()=>{},
  };
  return {w,document,registry,timers,makeNode};
}

function loadScript(file,w){
  const code=fs.readFileSync(file,'utf8');
  const sandbox={window:w,document:w.document,console,JSON,Date,Error,Promise,
    setTimeout,clearTimeout,setInterval:(...a)=>w.setInterval(...a),clearInterval(){}};
  vm.runInNewContext(code,sandbox,{filename:file});
}

const tick=()=>new Promise(resolve=>setTimeout(resolve,0));

const PANELS=[
  {name:'presence',file:PRESENCE,flag:'__SlsPresencePanel',button:'sls-presence-panel-button',
    status:el=>el.children.find(child=>child.tagName==='P')},
  {name:'compressor',file:COMPRESSOR,flag:'__SlsCompressorPanel',button:'sls-compressor-panel-button',
    status:el=>el.children.find(child=>child.tagName==='P')},
];

for(const panel of PANELS){
  test(`${panel.name}: missing host API rejects and the panel waits quietly`,async()=>{
    const {w,registry}=fakeWindow({millennium:'missing'});
    loadScript(panel.file,w);
    const button=registry[panel.button];
    assert.ok(button,'panel did not mount');
    button.onclick();
    await tick();
    const status=panel.status(registry[button.id==='sls-presence-panel-button'
      ?'sls-presence-panel':'sls-compressor-panel']);
    assert.match(status.textContent,/Waiting for the host/);
    assert.doesNotMatch(status.textContent,/TypeError|Cannot read/);
  });

  test(`${panel.name}: flag is published only after a successful mount, then retries once`,()=>{
    const {w,document,registry,timers,makeNode}=fakeWindow({body:false});
    loadScript(panel.file,w);
    assert.equal(w[panel.flag],undefined,'a failed mount must not publish the flag');
    assert.ok(timers.length>0,'a failed mount must schedule a retry');
    document.body=makeNode('body');
    // Run the queued retries, including any they queue in turn.
    for(let i=0;i<5&&timers.length;i++) timers.shift().fn();
    assert.equal(w[panel.flag],true,'the flag must be set once the mount succeeds');
    assert.ok(registry[panel.button],'the panel was not mounted by the retry');
    const mounted=registry[panel.button];
    for(let i=0;i<5&&timers.length;i++) timers.shift().fn();
    assert.equal(document.body.children.filter(c=>c===mounted).length,1,
      'a second mount must not duplicate the panel');
    assert.equal(registry[panel.button],mounted);
  });
}

test('playtime: missing host API rejects and the panel waits quietly',async()=>{
  const {w,registry}=fakeWindow({millennium:'missing'});
  PLAYTIME.mount(w);
  const button=registry['sls-playtime-panel-button'];
  assert.ok(button,'panel did not mount');
  button.onclick();
  await tick();
  const pane=registry['sls-playtime-panel'];
  const status=pane.children.find(child=>child.style.cssText.includes('#9fd0ff'));
  assert.match(status.textContent,/Waiting for the host/);
  assert.doesNotMatch(status.textContent,/Luna RPC not ready|Cannot read/);
});

test('playtime: flag is published only after a successful mount, then retries once',()=>{
  const {w,document,registry,timers,makeNode}=fakeWindow({body:false});
  PLAYTIME.mount(w);
  assert.equal(w.__SlsPlaytimePanel,undefined,'a failed mount must not publish the flag');
  assert.ok(timers.length>0,'a failed mount must schedule a retry');
  document.body=makeNode('body');
  for(let i=0;i<5&&timers.length;i++) timers.shift().fn();
  assert.equal(w.__SlsPlaytimePanel,true);
  assert.ok(registry['sls-playtime-panel-button']);
  const mounted=registry['sls-playtime-panel-button'];
  for(let i=0;i<5&&timers.length;i++) timers.shift().fn();
  assert.equal(document.body.children.filter(c=>c===mounted).length,1,
    'a second mount must not duplicate the panel');
});

test('playtime: a rejecting host shows its error rather than waiting forever',async()=>{
  const {w,registry}=fakeWindow();
  w.Millennium.callServerMethod=async()=>JSON.stringify({success:false,error:'backend stopped'});
  PLAYTIME.mount(w);
  registry['sls-playtime-panel-button'].onclick();
  await tick();
  const pane=registry['sls-playtime-panel'];
  const status=pane.children.find(child=>child.style.cssText.includes('#9fd0ff'));
  assert.match(status.textContent,/backend stopped/);
});
