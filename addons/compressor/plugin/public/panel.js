/* SLS Compressor lightweight panel for Luna desktop shell + store webview. */
(function (w) {
  if (!w.document || w.__SlsCompressorPanel) return;
  // SLS Luna hosts this add-on's settings in its own menubar menu; the floating
  // panel is only for a standalone install.
  if (w.__SlsLunaUi) return;
  // No host (Luna stopped or restarting) must reject, never throw a TypeError
  // from the refresh interval. Same guard the add-on agents use.
  const offline = e => /bridge unavailable/i.test(String((e && e.message) || e));
  const atend = (status, detail, e) => {
    if (offline(e)) {
      status.textContent = 'Waiting for the host (Luna bridge unavailable).';
      detail.textContent = '';
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
  const BTN = 'position:fixed;right:205px;bottom:16px;z-index:99999;background:#224f6b;color:white;padding:8px;border:1px solid #62829a;border-radius:6px;cursor:pointer';
  const PANE = 'position:fixed;right:14px;bottom:56px;z-index:99999;width:360px;padding:14px;border-radius:8px;background:#192734;color:white;box-shadow:0 7px 20px #000b';
  // Returns true when the panel is (or already was) in the DOM; the published
  // flag only exists after a successful mount, so a retry stays possible.
  function mount() {
    if (!document.body) return false;
    if (document.getElementById('sls-compressor-panel-button')) return true;
    const btn = document.createElement('button');
    btn.id = 'sls-compressor-panel-button';
    btn.textContent = 'Compressor';
    btn.style.cssText = BTN;
    const pane = document.createElement('section');
    pane.id = 'sls-compressor-panel';
    pane.hidden = true;
    pane.style.cssText = PANE;
    const header = document.createElement('h3');
    header.textContent = 'SLS Compressor';
    const status = document.createElement('p');
    const detail = document.createElement('p');
    detail.style.cssText = 'font-size:11px;opacity:.85;white-space:pre-wrap';
    const note = document.createElement('p');
    note.style.cssText = 'font-size:11px;opacity:.75';
    note.textContent = 'Checks here are read-only. A compaction is irreversible and can take hours; '
      + 'it never touches a running game.';
    const check = document.createElement('button');
    check.textContent = 'Check now';
    const preview = document.createElement('button');
    preview.textContent = 'Preview (dry-run)';
    for (const b of [check, preview]) {
      b.style.cssText = 'padding:7px;margin:4px;background:#315a75;color:white;border:0;border-radius:5px;cursor:pointer';
    }
    pane.append(header, status, detail, note, check, preview);
    document.body.append(btn, pane);
    async function refresh() {
      try {
        const result = await rpc('SlsCompressorGet');
        if (pane.hidden) return;
        const summary = (result.status && result.status.summary) || {};
        const job = result.job || {};
        status.textContent = result.tool.found
          ? `${summary.pending || 0} pending, ${summary.compacted || 0} compacted.`
          : 'btrfs-game-compressor was not found.';
        detail.textContent = [
          job.running ? `Running ${job.action}.` : (job.action ? `Last job: ${job.action}.` : 'No job yet.'),
          job.log ? job.log.split('\n').slice(-6).join('\n') : '',
        ].filter(Boolean).join('\n');
      } catch (e) { atend(status, detail, e); }
    }
    const start = action => async () => {
      try { await rpc('SlsCompressorRun', { raw: JSON.stringify({ action }) }); await refresh(); }
      catch (e) { atend(status, detail, e); }
    };
    check.onclick = start('scan');
    preview.onclick = start('preview');
    btn.onclick = () => { pane.hidden = !pane.hidden; if (!pane.hidden) refresh(); };
    w.setInterval(refresh, 6000);
    w.__SlsCompressorPanel = true;
    return true;
  }
  // A fast Steam start can run this script before document.body exists. Retry a
  // few times (bounded, then give up quietly) instead of losing the panel.
  let attempts = 0;
  function attempt() {
    if (w.__SlsCompressorPanel || mount()) return;
    if (++attempts > 20) return;
    w.setTimeout(attempt, attempts < 10 ? 100 : 500);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', attempt, {once: true});
  else attempt();
})(window);
