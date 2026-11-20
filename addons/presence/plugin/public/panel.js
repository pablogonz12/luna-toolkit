/* SLS Presence lightweight panel for Luna desktop shell + store webview. */
(function (w) {
  if (!w.document || w.__SlsPresencePanel) return;
  // SLS Luna hosts this add-on's settings in its own menubar menu; the floating
  // panel is only for a standalone install.
  if (w.__SlsLunaUi) return;
  // No host (Luna stopped or restarting) must reject, never throw a TypeError
  // from the refresh interval. Same guard the add-on agents use.
  const offline = e => /bridge unavailable/i.test(String((e && e.message) || e));
  const atend = (status, detail, e) => {
    if (offline(e)) {
      status.textContent = 'Waiting for the host (Luna bridge unavailable).';
      if (detail) detail.textContent = '';
      return;
    }
    status.textContent = String(e);
  };
  const rpc = async (method, args = {}) => {
    if (!w.Millennium || typeof w.Millennium.callServerMethod !== 'function') throw Error('bridge unavailable');
    const raw = await w.Millennium.callServerMethod('luna', method, args);
    const out = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (out?.success === false) throw Error(out.error || 'RPC failed');
    return out;
  };
  const BTN = 'position:fixed;right:15px;bottom:16px;z-index:99999;background:#224f6b;color:white;padding:8px;border:1px solid #62829a;border-radius:6px;cursor:pointer';
  const PANE = 'position:fixed;right:14px;bottom:56px;z-index:99999;width:340px;padding:14px;border-radius:8px;background:#192734;color:white;box-shadow:0 7px 20px #000b';
  // Returns true when the panel is (or already was) in the DOM. The published
  // flag only exists after a successful mount, so a fast Steam start that runs
  // this before document.body is ready can still retry.
  function mount() {
    if (!document.body) return false;
    if (document.getElementById('sls-presence-panel-button')) return true;
    const btn = document.createElement('button');
    btn.id = 'sls-presence-panel-button';
    btn.textContent = 'Presence';
    btn.style.cssText = BTN;
    const pane = document.createElement('section');
    pane.id = 'sls-presence-panel';
    pane.hidden = true;
    pane.style.cssText = PANE;
    const header = document.createElement('h3');
    header.textContent = 'SLS Presence';
    const status = document.createElement('p');
    const detail = document.createElement('p');
    detail.style.cssText = 'font-size:11px;opacity:.85;white-space:pre-wrap';
    const warning = document.createElement('p');
    warning.style.cssText = 'font-size:11px;color:#f0b26b';
    warning.textContent = 'Experimental: friend visibility is NOT validated. A shortcut can appear briefly before being hidden.';
    const enable = document.createElement('button');
    const clear = document.createElement('button');
    clear.textContent = 'Remove managed shortcuts';
    for (const b of [enable, clear]) b.style.cssText = 'padding:7px;margin:4px;background:#315a75;color:white;border:0;border-radius:5px;cursor:pointer';
    pane.append(header, status, detail, warning, enable, clear);
    document.body.append(btn, pane);

    function report(health, contracts, extras) {
      const age = Number(health.reportedAt || 0);
      const ready = health.healthy && age > 0 && (Date.now() / 1000 - age) < 30;
      const lines = [
        'Agent: ' + (ready ? 'connected' : 'not ready'),
        'Hide API: ' + (extras.hideStrategy || 'unknown')
          + (extras.hideVerified ? ' (verified)' : ' (unverified)'),
        'Account scope: ' + (extras.accountSource ? extras.accountSource : 'unavailable'),
      ];
      if (extras.identityAmbiguous) lines.push('Multiple Steam accounts known: scope is a guess.');
      if (extras.accountMismatch) lines.push('ACCOUNT CHANGED: actions are blocked.');
      if (extras.owned) lines.push('Managed shortcuts: ' + extras.owned
        + ', active helpers: ' + (extras.running || 0));
      if (contracts && typeof contracts === 'object') {
        const missing = Object.entries(contracts).filter(([, v]) => v === null).map(([k]) => k);
        lines.push('Unavailable APIs: ' + (missing.length ? missing.join(', ') : 'none'));
      }
      if (health.error) lines.push('Last error: ' + health.error);
      if (extras.helperPauseReason) lines.push(extras.helperPauseReason);
      detail.textContent = lines.join('\n');
    }
    async function refresh() {
      try {
        const result = await rpc('SlsPresenceGet');
        const names = {};
        for (const id of (Array.isArray(result.runtime.activeIds) ? result.runtime.activeIds : [])) {
          const overview = w.appStore?.GetAppOverviewByAppID?.(id) || w.SteamUIStore?.AppStore?.GetAppOverviewByAppID?.(id);
          const name = overview?.display_name || overview?.name;
          if (typeof name === 'string' && name.length <= 160 && name.length) names[id] = name;
        }
        if (Object.keys(names).length) await rpc('SlsPresenceSetTitles', {raw: JSON.stringify(names)});
        if (pane.hidden) return;
        const s = result.state;
        enable.textContent = s.enabled ? 'Disable experimental bridge' : 'Enable experimental bridge';
        const health = result.runtime;
        const age = Number(health.reportedAt || 0);
        const ready = health.healthy && age > 0 && (Date.now() / 1000 - age) < 30;
        status.textContent = `${Array.isArray(result.apps) ? result.apps.length : 0} manifest games, `
          + `${Object.keys(s.owned).length} shortcuts, ${health.active} active. `
          + `Agent: ${ready ? 'connected' : 'not ready'}. ${health.error || ''}`;
        report(health, health.contracts, {
          hideStrategy: health.hideStrategy, hideVerified: health.hideVerified,
          accountMismatch: health.accountMismatch, owned: health.owned, running: health.running,
          accountSource: health.accountSource, identityAmbiguous: health.identityAmbiguous,
          helperPauseReason: result.session?.helpersAllowed === false ? result.session.reason : '',
        });
      } catch (e) { atend(status, detail, e); }
    }
    btn.onclick = () => { pane.hidden = !pane.hidden; if (!pane.hidden) refresh(); };
    enable.onclick = async () => {
      try {
        const s = (await rpc('SlsPresenceGet')).state;
        await rpc('SlsPresenceSetEnabled', {value: !s.enabled});
        await refresh();
      } catch (e) { atend(status, detail, e); }
    };
    clear.onclick = async () => {
      // Only ever removes shortcuts this addon created and still owns.
      let confirmed = false;
      try {
        confirmed = w.confirm('Remove ONLY shortcuts managed by SLS Presence? '
          + 'Games and unrelated shortcuts are never touched.');
      } catch (_) { confirmed = true; }
      if (!confirmed) return;
      try {
        await rpc('SlsPresenceRequestCleanup');
        status.textContent = 'Cleanup requested; SharedJSContext will process it.';
      } catch (e) { atend(status, detail, e); }
    };
    w.setInterval(refresh, 6000);
    w.__SlsPresencePanel = true;
    return true;
  }
  // A fast Steam start can run this script before document.body exists. Retry a
  // few times (bounded, then give up quietly) instead of losing the panel for
  // the whole session.
  let attempts = 0;
  function attempt() {
    if (w.__SlsPresencePanel || mount()) return;
    if (++attempts > 20) return;
    w.setTimeout(attempt, attempts < 10 ? 100 : 500);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', attempt, {once: true});
  else attempt();
})(window);
