// Luna shell UI: the menubar button, the menu shell and the pages that survive
// without the private host (Playtime, Presence, Compressor, HowLongToBeat,
// SteamGridDB, Graphics, Health, Updates, Settings, About).
//
// A small DOM stub stands in for Steam's CEF document: what matters here is the
// wiring (one window, cached pages, one visible pane, bounded RPCs, clean
// teardown) and the Store/Community switch to the Library before opening.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {mount,RPC_TIMEOUT,buildRows,buildHltbRows,findMenubar,restoreMainView,prepareView,
  VIEW_REQUEST_KEY,VIEW_RESULT_KEY}=require('../addons/luna/plugin/public/panel.js');

function fakeDom(){
  const registry={};
  const created=[];
  const documentListeners={};
  const node=tag=>{
    const kids=[];
    const listeners={};
    const element={
      tagName:(tag||'div').toUpperCase(),id:'',className:'',title:'',hidden:false,
      style:{cssText:''},parentNode:null,value:'',placeholder:'',type:'',rows:0,onclick:null,
      onkeydown:null,oninput:null,onerror:null,selectedIndex:0,
      children:kids,
      append(...more){more.forEach(kid=>element.appendChild(kid));},
      appendChild(kid){kid.parentNode=element;kids.push(kid);register(kid);return kid;},
      insertBefore(kid,ref){
        const i=ref?kids.indexOf(ref):-1;
        kid.parentNode=element;
        if(i<0)kids.push(kid);else kids.splice(i,0,kid);
        register(kid);return kid;
      },
      remove(){const p=element.parentNode;
        if(p&&p.children){const i=p.children.indexOf(element);if(i>=0)p.children.splice(i,1);}
        if(registry[element.id]===element)delete registry[element.id];
        element.parentNode=null;},
      setAttribute(name,value){element['attr_'+name]=value;},
      getAttribute(name){return element['attr_'+name];},
      removeAttribute(name){delete element['attr_'+name];},
      addEventListener(type,fn){(listeners[type]=listeners[type]||[]).push(fn);},
      removeEventListener(type,fn){const list=listeners[type]||[];const i=list.indexOf(fn);
        if(i>=0)list.splice(i,1);},
      click(){(listeners.click||[]).forEach(fn=>fn({preventDefault(){},stopPropagation(){}}));
        if(typeof element.onclick==='function')element.onclick({});},
      focus(){},select(){},setSelectionRange(){},
      getBoundingClientRect(){return {top:0,left:0,width:900,height:620,right:900,bottom:620};},
      get nextSibling(){const p=element.parentNode;if(!p||!p.children)return null;
        const i=p.children.indexOf(element);return i>=0?p.children[i+1]||null:null;},
      querySelectorAll(){return [];},
    };
    let ownText='';
    let markup='';
    Object.defineProperty(element,'innerHTML',{
      get:()=>markup,
      set(value){markup=String(value);ownText=markup.replace(/<svg[\s\S]*?<\/svg>/g,'')
        .replace(/<[^>]*>/g,'');kids.length=0;},
    });
    Object.defineProperty(element,'textContent',{
      get:()=>kids.length?kids.map(child=>child.textContent).join(''):ownText,
      set(value){ownText=String(value);markup='';kids.length=0;},
    });
    Object.defineProperty(element,'innerText',{get:()=>element.textContent});
    created.push(element);
    return element;
  };
  const register=element=>{
    if(!element||typeof element!=='object')return;
    if(element.id)registry[element.id]=element;
    (element.children||[]).forEach(register);
  };
  const head=node('head');
  const body=node('body');
  return {
    registry,head,body,readyState:'complete',hidden:false,activeElement:body,
    documentElement:node('html'),
    createElement:node,
    getElementById:id=>registry[id]||null,
    querySelectorAll(selector){
      const match=String(selector||'').match(/^\[([\w-]+)\]$/);
      if(!match)return created.slice();
      return created.filter(element=>element['attr_'+match[1]]!==undefined);
    },
    addEventListener(type,fn){(documentListeners[type]=documentListeners[type]||[]).push(fn);},
    removeEventListener(type,fn){const list=documentListeners[type]||[];
      const i=list.indexOf(fn);if(i>=0)list.splice(i,1);},
    fire(type,event){(documentListeners[type]||[]).slice().forEach(fn=>fn(event||{}));},
    listenerCount:type=>(documentListeners[type]||[]).length,
  };
}

const textOf=node=>node?node.textContent:'';
function findNode(node,predicate){
  if(!node)return null;
  if(predicate(node))return node;
  for(const child of node.children||[]){const hit=findNode(child,predicate);if(hit)return hit;}
  return null;
}
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms||40));

function menubarFixture(document){
  const bar=document.createElement('div');
  ['Steam','View','Friends','Games','Help'].forEach(label=>{
    const item=document.createElement('div');
    item.textContent=label;
    bar.appendChild(item);
  });
  document.body.appendChild(bar);
  return bar;
}

const NOW=Date.now()/1000;
function fixtures(){
  return {
    SlsPlaytimeGet:{success:true,apps:[620,3212112756],
      titles:{620:'Portal 2'},shortcutNames:{'3212112756':'Minecraft'},
      games:{'620':{title:'Portal 2',trackedSeconds:7200,adjustmentSeconds:0,lastPlayed:NOW}},
      stats:{today:7200,last7d:7200,last30d:7200},
      runtime:{healthy:true,reportedAt:NOW},account:'76561198000000000',manifestCount:1},
    SlsPresenceGet:{success:true,state:{enabled:false,owned:{}},
      runtime:{activeIds:[],contracts:{}},apps:[],tool:{found:true}},
    SlsCompressorGet:{success:true,tool:{found:false},status:{games:[],summary:{}},
      plan:{},settings:{},statusAt:0,job:null},
    SlsHltbGet:{success:true,games:{},library:[]},
    SlsSgdbGet:{success:true,hasKey:false,keyMasked:'',gridDir:''},
    SlsGraphicsGet:{success:true,gpus:[],lsfg:{layers:[]},optiscaler:[],
      steam:{root:'/steam',runtimes:[]}},
    SlsLunaInfo:{success:true,version:'0.14.18',data:'/data',
      account:{name:'tester',id:'76561198000000000'},prefs:{version:1,beta:true,lang:'en'}},
    SlsLunaHealth:{success:true,health:{version:'0.14.18',generatedAt:NOW,
      install:{versions:{luna:'0.14.18'},drift:[]},addons:[{name:'playtime',version:'0.6.1',files:4}],
      host:{running:'luna',configured:'luna',binary:true},
      steam:{root:'/steam',exists:true,localconfigConflicts:0,
        client:{build:'1791918634',pinned:'1791918634',match:true,updatesBlocked:true}},
      data:{dir:'/data',prefs:{version:1,beta:true,lang:'en'},hltb:{cached:0},sgdb:{hasKey:false},files:[]}}},
    SlsLunaUpdate:{success:true,update:{installed:'0.14.18',latest:'0.14.18',
      autoUpdate:'off',timerUnits:true,checking:false}},
    SlsLunaSteam:{success:true,steam:{build:'1791918634',pinned:'1791918634',
      match:true,updatesBlocked:true,pending:''}},
    SlsLunaHost:{success:true,host:{running:'luna',configured:'luna',binary:true}},
    SlsLunaRefresh:{success:true,refreshPending:false},
    SlsLunaGradient:{success:true,enabled:false,available:false,colors:{}},
    SlsLunaPrefsSet:{success:true,prefs:{version:1}},
  };
}

function fakeWindow(document,{overrides={},hang=[],hostname='',route='',onSetItem=null,initialTimeout=0,realTimers=false}={}){
  const calls=[];
  const storage={};
  const intervals=new Map();
  const timeouts=new Map();
  const winListeners={};
  let seq=0;
  const table=Object.assign(fixtures(),overrides);
  const w={
    document,console,location:{hostname:hostname},navigator:{userAgent:'test'},
    MainWindowBrowserManager:{m_history:{location:{pathname:route}}},
    SteamUIStore:{Navigate(target){w.navigated=(w.navigated||[]).concat([target]);}},
    __SlsLunaRpcTimeout:initialTimeout||undefined,
    Millennium:{
      callServerMethod(plugin,fn,payload){
        calls.push({plugin,fn,payload});
        if(hang.indexOf(fn)>=0)return new Promise(()=>{});
        const out=Object.prototype.hasOwnProperty.call(table,fn)?table[fn]:{success:true};
        return Promise.resolve(JSON.stringify(out));
      },
    },
    localStorage:{
      getItem:key=>Object.prototype.hasOwnProperty.call(storage,key)?storage[key]:null,
      setItem(key,value){storage[key]=String(value);if(onSetItem)onSetItem(key,String(value),storage);},
      removeItem(key){delete storage[key];},
    },
    open(){w.opened=(w.opened||0)+1;},
    setInterval(fn,ms){seq+=1;intervals.set(seq,fn);return seq;},
    clearInterval(id){intervals.delete(id);},
    setTimeout(fn){seq+=1;timeouts.set(seq,fn);return seq;},
    clearTimeout(id){timeouts.delete(id);},
    addEventListener(type,fn){(winListeners[type]=winListeners[type]||[]).push(fn);},
    removeEventListener(type,fn){const list=winListeners[type]||[];
      const i=list.indexOf(fn);if(i>=0)list.splice(i,1);},
    fire(type,event){(winListeners[type]||[]).slice().forEach(fn=>fn(event||{}));},
    listenerCount:type=>(winListeners[type]||[]).length,
  };
  if(realTimers){
    w.setInterval=(fn,ms)=>setInterval(fn,ms);
    w.clearInterval=id=>clearInterval(id);
    w.setTimeout=(fn,ms)=>setTimeout(fn,ms);
    w.clearTimeout=id=>clearTimeout(id);
  }
  return {w,calls,storage,intervals,timeouts,winListeners};
}

async function openMenu(document,options){
  menubarFixture(document);
  const made=fakeWindow(document,options||{});
  mount(made.w);
  document.getElementById('sls-luna-btn').click();
  await wait(120);
  return {made,overlay:document.getElementById('sls-luna-overlay')};
}

const tabNamed=(document,label)=>findNode(document.getElementById('sls-luna-overlay'),
  node=>(node.className||'').startsWith('sls-luna-tab')
    &&(node.textContent||'').startsWith(label));

test('the menubar is found by shape, not by localized labels',()=>{
  const document=fakeDom();
  const bar=menubarFixture(document);
  assert.equal(findMenubar(document),bar);
  const other=fakeDom();
  const notAMenu=other.createElement('div');
  ['uno','dos','tres'].forEach(text=>{const item=other.createElement('div');
    item.textContent=text;notAMenu.appendChild(item);});
  other.body.appendChild(notAMenu);
  assert.equal(findMenubar(other),null,'a row without the Steam brand is not the menubar');
});

test('mount adds the Luna button to the menubar and retires the floating panels',()=>{
  const document=fakeDom();
  const bar=menubarFixture(document);
  ['sls-playtime-panel-button','sls-playtime-panel','sls-presence-panel'].forEach(id=>{
    const node=document.createElement('div');node.id=id;document.body.appendChild(node);});
  const {w}=fakeWindow(document);
  mount(w);
  assert.equal(w.__SlsLunaUi,true,'the flag the add-ons check must be set');
  const button=document.getElementById('sls-luna-btn');
  assert.ok(button,'the Luna button was not created');
  assert.equal(button.parentNode,bar,'the button must live in the native menubar');
  assert.equal(bar.children[bar.children.length-1],button,'the button goes at the end of the menubar');
  assert.match(button.textContent,/Luna/);
  assert.equal(document.getElementById('sls-playtime-panel'),null,'the floating panel must be gone');
});

test('the menu opens with every category and the Steam account in the footer',async()=>{
  const document=fakeDom();
  const {made}=await openMenu(document);
  const overlay=document.getElementById('sls-luna-overlay');
  assert.ok(overlay,'the menu did not open');
  const text=textOf(overlay);
  ['Playtime','Presence','Compressor','HowLongToBeat','SteamGridDB','Graphics','Health',
    'Updates','Settings','About'].forEach(label=>assert.match(text,new RegExp(label),'missing '+label));
  assert.ok(!new RegExp('Lu'+'men').test(text),'no private host category or label');
  assert.match(text,/tester/,'the footer shows the Steam account name');
  assert.match(text,/76561198000000000/,'the footer shows the Steam account id');
  assert.equal(findNode(overlay,node=>node.tagName==='IMG'),null,'no avatar images');
  assert.ok(made.calls.some(c=>c.fn==='SlsPlaytimeGet'),'opening must load playtime');
  assert.ok(made.calls.some(c=>c.fn==='SlsPresenceGet'),'opening must load presence');
  assert.ok(made.calls.some(c=>c.fn==='SlsLunaInfo'),'opening must load the Luna info');
});

test('every category renders without throwing',async()=>{
  const document=fakeDom();
  await openMenu(document);
  for(const label of ['Playtime','Presence','Compressor','HowLongToBeat','SteamGridDB','Graphics',
    'Health','Updates','Settings','About']){
    const tab=tabNamed(document,label);
    assert.ok(tab,'missing tab '+label);
    tab.onclick();
    await wait(25);
    const overlay=document.getElementById('sls-luna-overlay');
    const pane=findNode(overlay,node=>node.className==='sls-luna-pane'&&node.style.display!=='none');
    assert.ok(pane,'no pane for '+label);
    assert.ok((pane.textContent||'').length>0,label+' rendered nothing');
  }
});

test('pages are built once and only one pane is visible at a time',async()=>{
  const document=fakeDom();
  await openMenu(document);
  const panes=()=>Array.from(document.getElementById('sls-luna-overlay').children)
    .filter(node=>node.className==='sls-luna-main')
    .map(node=>node.children)
    .reduce((all,list)=>all.concat(Array.from(list||[])),[])
    .filter(node=>node.className==='sls-luna-pane');
  const body=()=>findNode(document.getElementById('sls-luna-overlay'),
    node=>node.className==='sls-luna-body');
  const first=tabNamed(document,'Presence');
  first.onclick();
  await wait(30);
  const panesAfter=Array.from(body().children).filter(node=>node.className==='sls-luna-pane');
  const visible=panesAfter.filter(node=>node.style.display!=='none');
  assert.equal(visible.length,1,'exactly one pane may be on screen');
  const presencePane=visible[0];
  assert.ok(textOf(presencePane).length>0,'the Presence page rendered');
  tabNamed(document,'Playtime').onclick();
  await wait(30);
  assert.equal(Array.from(body().children).filter(node=>node.style.display!=='none').length,1,
    'switching tabs never stacks panes');
  tabNamed(document,'Presence').onclick();
  await wait(30);
  assert.equal(Array.from(body().children).filter(node=>node.style.display!=='none')[0],
    presencePane,'the cached Presence pane is reused');
});

test('an RPC past the timeout rejects, is reported in Problems and does not wedge the menu',async()=>{
  const document=fakeDom();
  const {made}=await openMenu(document,{hang:['SlsPresenceGet'],initialTimeout:40});
  await wait(220);
  tabNamed(document,'Health').onclick();
  await wait(80);
  const overlay=document.getElementById('sls-luna-overlay');
  const text=textOf(overlay);
  assert.match(text,/Problems/,'the Health page keeps the Problems block');
  assert.match(text,/SlsPresenceGet/,'the timed-out call is named');
  assert.match(text,/did not answer/,'the timeout is reported in plain words');
  assert.ok(RPC_TIMEOUT>0);
});

test('Escape closes the menu and teardown removes every trace',async()=>{
  const document=fakeDom();
  const {made}=await openMenu(document);
  const overlay=document.getElementById('sls-luna-overlay');
  assert.ok(overlay);
  document.fire('keydown',{key:'Escape'});
  await wait(20);
  assert.equal(document.getElementById('sls-luna-overlay'),null,'Escape closes the window');
  document.getElementById('sls-luna-btn').click();
  await wait(80);
  assert.ok(document.getElementById('sls-luna-overlay'),'the menu opens again');
  made.w.__SlsLunaTeardown();
  assert.equal(document.getElementById('sls-luna-overlay'),null,'teardown removes the overlay');
  made.w.__SlsLunaTeardown();
});

test('opening from the Store asks Steam for the Library first, then shows the menu',async()=>{
  const document=fakeDom();
  menubarFixture(document);
  const seen=[];
  const {w}=fakeWindow(document,{route:'/store/app/620',
    onSetItem(key,value,storage){
      if(key!==VIEW_REQUEST_KEY)return;
      const req=JSON.parse(value);
      seen.push(req.action);
      const route=req.action==='status'?'/store/app/620':'/library/home';
      storage[VIEW_RESULT_KEY]=JSON.stringify({id:req.id,ok:true,route:route,browserVisible:true});
      setTimeout(()=>w.fire('storage',{key:VIEW_RESULT_KEY}),0);
    }});
  mount(w);
  document.getElementById('sls-luna-btn').click();
  await wait(200);
  assert.ok(seen.indexOf('navigate')>=0,'Steam is asked to move to the Library');
  assert.ok(document.getElementById('sls-luna-overlay'),'the menu opens after the switch');
  assert.equal(w.viewNoteChecked,undefined);
});

test('prepareView is a no-op when Steam already shows the Library',async()=>{
  const document=fakeDom();
  const {w}=fakeWindow(document,{route:'/library/home',realTimers:true});
  assert.equal(await prepareView(w),true);
  assert.equal(w.navigated,undefined,'no navigation from the Library');
  assert.equal(await prepareView(w),true);
});

test('the Updates page keeps the Steam client section and no mixed-in update queue',async()=>{
  const document=fakeDom();
  await openMenu(document);
  tabNamed(document,'Updates').onclick();
  await wait(60);
  const overlay=document.getElementById('sls-luna-overlay');
  const text=textOf(overlay);
  assert.match(text,/Steam client/,'the Steam client section stays');
  assert.match(text,/Pin this build as known-good/,'the pin action stays');
  assert.match(text,/Luna 0\.14\.18/,'the Luna release section stays');
  assert.ok(!/Update everything|Update in terminal|Channels|Millennium/.test(text),
    'no private host queue, terminal or channel controls');
  const latest=findNode(overlay,node=>node.tagName==='BUTTON'
    &&(node.textContent||'').indexOf('Move to Valve')>=0);
  assert.ok(latest,'the latest-client action is behind a first click');
  latest.onclick();
  await wait(20);
  assert.match(textOf(document.getElementById('sls-luna-overlay')),/Risk:/,'the confirm explains the risk');
});

test('buildRows and buildHltbRows keep their pure behaviour',()=>{
  const rows=buildRows({apps:[620,999],titles:{620:'Portal 2'},
    games:{'620':{title:'Portal 2',trackedSeconds:7200,adjustmentSeconds:60,lastPlayed:5}}},'');
  assert.deepEqual(rows.map(r=>r.id),['620','999']);
  assert.ok(rows[0].total>7199);
  const hltb=buildHltbRows({'1145360':{name:'Hades'}},[
    {appid:1145360,name:'Hades'},{appid:620,name:'Portal 2'}],'');
  assert.deepEqual(hltb.map(r=>r.id),['620','1145360']);
});
