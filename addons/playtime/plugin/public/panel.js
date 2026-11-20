/* Luna Steam shell SLS Playtime panel: local stats, not official Steam playtime. */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root && root.document) api.mount(root);
})(typeof window !== 'undefined' ? window : null, function () {
  'use strict';
  const hours=seconds=>((Number(seconds)||0)/3600).toFixed(2);
  // Same rule as the agent: an official Steam playtime, when the backend has
  // one, is the base; a manual edit is a correction on top of it.
  const lifetimeSeconds=record=>{
    const official=Number(record&&record.officialSeconds)||0;
    const base=official>0?official:(Number(record&&record.trackedSeconds)||0);
    return Math.max(0,base+(Number(record&&record.adjustmentSeconds)||0));
  };
  /* Pure list building, kept separate from the DOM so it can be tested. Every
     trackable id is listed - manifests and shortcuts alike - because the panel is
     the only way to edit either. */
  function buildRows(snapshot, options){
    const opts=options||{};
    const needle=String(opts.needle||'').trim().toLowerCase();
    const titles=(snapshot&&snapshot.titles)||{};
    const shortcuts=(snapshot&&snapshot.shortcutNames)||{};
    const games=(snapshot&&snapshot.games)||{};
    const overview=opts.overview||(()=>undefined);
    const ids=new Set([...((snapshot&&Array.isArray(snapshot.apps))?snapshot.apps:[]).map(String),...Object.keys(games)]);
    const rows=[...ids].map(id=>{
      const record=games[id]||{trackedSeconds:0,adjustmentSeconds:0,lastPlayed:0};
      const live=overview(Number(id));
      const resolved=(live&&(live.display_name||live.name))||record.title||titles[id]||shortcuts[id]||'';
      const name=resolved||('App '+id);
      // shortcutNames is exactly the non-Steam set, so one lookup classifies the row.
      return {id,record,name,shortcut:Boolean(shortcuts[id]),
        total:lifetimeSeconds(record),
        known:Boolean(resolved)};
    });
    const filtered=rows.filter(row=>(row.name+' '+row.id).toLowerCase().includes(needle));
    filtered.sort((a,b)=>(b.total>0)-(a.total>0)||(b.known?1:0)-(a.known?1:0)
      ||(b.record.lastPlayed||0)-(a.record.lastPlayed||0)||a.name.localeCompare(b.name));
    return {rows:filtered,hours};
  }
  function mount(w){
  const document=w.document;
  if(!document||w.__SlsPlaytimePanel)return;
  // SLS Luna hosts this add-on's settings in its own menubar menu; the floating
  // panel is only for a standalone install.
  if(w.__SlsLunaUi)return;
  // No host (Luna stopped or restarting) must reject, not throw a TypeError
  // from the refresh interval. Same guard the add-on agents use.
  const offline=e=>/bridge unavailable/i.test(String((e&&e.message)||e));
  const atend=(status,detail,e)=>{
    if(offline(e)){status.textContent='Waiting for the host (Luna bridge unavailable).';if(detail)detail.textContent='';return}
    status.textContent=String(e);
  };
  const parse=raw=>typeof raw==='string'?JSON.parse(raw):raw;
  const rpc=async(method,args={})=>{
    if(!w.Millennium?.callServerMethod)throw Error('bridge unavailable');
    const out=parse(await w.Millennium.callServerMethod('luna',method,args));
    if(out?.success===false)throw Error(out.error||method+' failed');
    return out;
  };
  // Returns true when the panel is (or already was) in the DOM; the published
  // flag only exists after a successful mount, so a retry stays possible.
  function mount(){
    if(!document.body)return false;
    if(document.getElementById('sls-playtime-panel-button'))return true;
    const button=document.createElement('button');button.id='sls-playtime-panel-button';button.textContent='Playtime';
    button.style.cssText='position:fixed;right:110px;bottom:16px;z-index:99998;background:#224f6b;color:white;padding:8px;border:1px solid #62829a;border-radius:6px;cursor:pointer';
    const panel=document.createElement('section');panel.id='sls-playtime-panel';panel.hidden=true;
    panel.style.cssText='position:fixed;right:14px;bottom:56px;z-index:99998;max-height:75vh;overflow:auto;width:min(560px,95vw);padding:15px;border-radius:8px;background:#192734;color:white;box-shadow:0 7px 20px #000b';
    const title=document.createElement('h3');title.textContent='SLS Playtime (local)';
    const caution=document.createElement('p');
    caution.textContent='Non-Steam games are counted while you play. Steam manifest games are edit-only, because Steam already records those hours. Edits are local and never change official Steam hours.';
    const info=document.createElement('p');const status=document.createElement('p');
    status.style.cssText='color:#9fd0ff;font-size:12px';
    const query=document.createElement('input');
    query.placeholder='Filter game / AppID';query.style.cssText='padding:8px;width:95%;background:#203447;color:white';
    const exportButton=document.createElement('button');exportButton.textContent='Export JSON';
    const importButton=document.createElement('button');importButton.textContent='Import JSON';
    const page=document.createElement('button');page.textContent='Show 50 more';
    const list=document.createElement('div');
    for(const b of [exportButton,importButton,page])b.style.cssText='padding:7px;margin:4px;background:#315a75;color:white;border:0;border-radius:5px;cursor:pointer';
    panel.append(title,caution,status,info,query,exportButton,importButton,list,page);document.body.append(button,panel);
    let snapshot=null, visible=50;
    const overview=id=>w.appStore?.GetAppOverviewByAppID?.(id)||w.SteamUIStore?.AppStore?.GetAppOverviewByAppID?.(id);
    const named=id=>{
      const live=overview(Number(id));
      return (live&&(live.display_name||live.name))||(snapshot.games||{})[id]?.title
        ||(snapshot.titles||{})[id]||(snapshot.shortcutNames||{})[id]||'';
    };
    function paint(){
      if(!snapshot)return;
      const result=buildRows(snapshot,{needle:query.value,overview}).rows;
      const live=snapshot.runtime||{};
      const active=snapshot.active||{};
      const activeIds=Object.keys(active);
      const connected=live.healthy && Number(live.reportedAt||0)>0 &&
        Date.now()/1000-Number(live.reportedAt)<45;
      // Prefer the backend-computed daily buckets. Scanning a raw pulse list
      // cannot answer a 30-day question, because only a few hours of pulses fit
      // in the bounded ledger.
      const stats=snapshot.stats||null;
      const days=stats?[stats.last7d,stats.last30d]:[null,null];
      status.textContent=`Agent ${connected?'connected':'not ready'}${live.healthy===true?'':' (heartbeat problem)'}. `+
        (live.error?`${live.error} `:'')+
        (activeIds.length?`Recording now: ${activeIds.map(id=>`${named(id)||('App '+id)} (${hours((snapshot.games||{})[id]?.trackedSeconds)}h)`).join(', ')}. `:'');
      info.textContent=`Account ${snapshot.account||'shared (unscoped)'} | ledger ${live.file||'playtime.json'}. `+
        `${snapshot.manifestCount??0} installed Steam games (edit-only) + `+
        `${snapshot.shortcutCount??0} non-Steam shortcuts (tracked)`+
        `${snapshot.policy?.trackManifests?(', manifest tracking forced on'):''}, `+
        `${Object.keys(snapshot.games||{}).length} with records, ${result.length} listed. `+
        (stats?`Today ${hours(stats.today)}h; last 7d ${hours(days[0])}h; 30d ${hours(days[1])}h.`
             :'Daily totals unavailable.');
      page.hidden=visible>=result.length;
      page.textContent=`Show 50 more (${Math.max(0,result.length-visible)} left)`;
      list.replaceChildren();
      for(const g of result.slice(0,visible)) {
        const line=document.createElement('div');line.style.cssText='display:flex;gap:7px;align-items:center;padding:8px 2px;border-bottom:1px solid #47617a';
        const label=document.createElement('span');label.style.cssText='flex:1;min-width:0;overflow-wrap:anywhere';label.textContent=g.name+' (#'+g.id+')'+(g.shortcut?' [non-Steam]':'');
        if(active[g.id])label.textContent+=' ●';
        label.title=`Local playtime only. Recorded ${hours(g.record.trackedSeconds)}h, manual adjustment ${hours(g.record.adjustmentSeconds)}h.`;
        const input=document.createElement('input');input.type='number';input.min='0';input.max='10000000';input.step='0.01';input.value=hours(g.total);
        input.style.cssText='width:100px;color:white;background:#263d50;border:1px solid #66849d;padding:5px';
        const save=document.createElement('button');save.textContent='Save';
        save.onclick=async()=>{try{await rpc('SlsPlaytimeEdit',{raw:JSON.stringify({id:Number(g.id),hours:Number(input.value)})});await refresh();}catch(e){atend(status,null,e)}};
        line.append(label,input,save);list.appendChild(line);
      }
    }
    async function refresh(){if(panel.hidden)return;try{snapshot=await rpc('SlsPlaytimeGet');paint();}catch(e){atend(status,null,e)}}
    button.onclick=()=>{panel.hidden=!panel.hidden;if(!panel.hidden)refresh()};
    query.oninput=()=>{visible=50;paint()};page.onclick=()=>{visible+=50;paint()};
    exportButton.onclick=async()=>{try{const out=await rpc('SlsPlaytimeExport');
      const textarea=document.createElement('textarea');textarea.rows=10;textarea.style.width='100%';
      textarea.value=JSON.stringify(out.data,null,2);panel.append(textarea);textarea.focus();textarea.select();
    }catch(e){atend(status,null,e)}};
    importButton.onclick=async()=>{const raw=w.prompt('Paste a trusted SLS Playtime backup (replaces local records).');
      if(!raw||!w.confirm('Replace ALL locally recorded playtime?'))return;
      try{await rpc('SlsPlaytimeImport',{raw});await refresh()}catch(e){atend(status,null,e)}};
    w.setInterval(refresh,10000);
    w.__SlsPlaytimePanel=true;
    return true;
  }
  // A fast Steam start can run this script before document.body exists. Retry a
  // few times (bounded, then give up quietly) instead of losing the panel.
  let attempts=0;
  function attempt(){
    if(w.__SlsPlaytimePanel||mount())return;
    if(++attempts>20)return;
    w.setTimeout(attempt,attempts<10?100:500);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',attempt,{once:true});else attempt();
  }
  return {buildRows,hours,lifetimeSeconds,mount};
});
