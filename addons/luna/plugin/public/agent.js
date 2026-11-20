/* SLS Luna shared game-menu agent (SharedJSContext).
 *
 * Adds Luna's game actions to Steam's native right-click menu and publishes a
 * small registry (`window.__SlsLunaMenu`) so other Luna add-ons can contribute
 * their own per-game actions (artwork, graphics, ...) without each one having
 * to hook Steam's jsx layer on its own.
 *
 * The hook technique is the one already proven by the Playtime add-on: watch
 * the game context menu prototype while it renders, remember the focused game
 * from the outer submenu, and insert real menu-item children into the inner
 * menu. Nothing here touches game files; every action decides its own behavior
 * through the backend contract.
 *
 * Action: HowLongToBeat (opens the game's search page in the browser through
 * Steam's own URL handlers). Fetching and the cached times live in the Luna
 * menu's HowLongToBeat page; this agent only reports the local game inventory
 * so that page can show what is still missing. Nothing is fetched
 * automatically and no library data leaves the machine.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root && root.SteamClient) api.bootLunaMenu(root);
})(typeof window !== 'undefined' ? window : null, function () {
  'use strict';
  const ITEM_PREFIX = 'sls-luna-';
  const HLTB_SEARCH = 'https://howlongtobeat.com/?q=';
  const valid = id => Number.isSafeInteger(Number(id)) && Number(id) > 0 && Number(id) <= 4294967295;

  /* One throw inside Steam's React render path blanks the whole library, so
     every third-party hook and every patch Luna applies goes through
     safeHook(): the failure is logged once with the stable prefix, kept in the
     small ring the Health page reads, and rendering continues untouched. */
  const DIAG_KEY = 'slsLunaDiag';
  const DIAG_LIMIT = 20;
  const diagSeen = new Set();

  function agentDiag(w, text) {
    try {
      const store = w && w.localStorage;
      if (!store || typeof store.getItem !== 'function') return;
      let list = [];
      try { list = JSON.parse(store.getItem(DIAG_KEY) || '[]'); } catch (_) { list = []; }
      if (!Array.isArray(list)) list = [];
      list.push({ at: Date.now(), text: String(text).slice(0, 200) });
      store.setItem(DIAG_KEY, JSON.stringify(list.slice(-DIAG_LIMIT)));
    } catch (_) { /* a diagnostic must never throw */ }
  }

  function reportAgentFailure(w, area, error) {
    const key = String(area || 'agent');
    const detail = error && error.message ? error.message : String(error);
    if (!diagSeen.has(key)) {
      diagSeen.add(key);
      try { console.warn('[sls-luna] ' + key + ' failed: ' + detail); } catch (_) { /* no console */ }
      agentDiag(w, '[sls-luna] ' + key + ' failed: ' + detail);
    }
    return undefined;
  }

  function safeHook(w, area, fn) {
    try { return fn(); } catch (error) { return reportAgentFailure(w, area, error); }
  }

  // A search query, never a scrape: HowLongToBeat has no supported public API,
  // so the browser does the lookup in the user's own session.
  function searchUrlFor(name) {
    return HLTB_SEARCH + encodeURIComponent(String(name == null ? '' : name).trim());
  }

  // Luna backend call through the host's plugin bridge.
  function rpc(w, method, args) {
    if (!w || !w.Millennium || typeof w.Millennium.callServerMethod !== 'function') {
      return Promise.reject(Error('The plugin bridge is unavailable.'));
    }
    return Promise.resolve(w.Millennium.callServerMethod('sls-luna', method, args || {}))
      .then(raw => (typeof raw === 'string' ? JSON.parse(raw) : raw));
  }

  // A per-game artwork request: the Luna panel (which owns the window's DOM)
  // listens for this localStorage key and opens the SteamGridDB picker on the
  // game. SharedJSContext has no DOM access, so localStorage is the hand-off.
  const ARTWORK_REQUEST_KEY = 'slsLunaArtworkRequest';
  // The panel asks for a live refresh after applying artwork; the agent is the
  // only context with SteamClient.Apps, so it performs the call and reports the
  // outcome back through another key.
  const ARTWORK_LIVE_KEY = 'slsLunaArtworkLive';
  const ARTWORK_LIVE_RESULT_KEY = 'slsLunaArtworkLiveResult';
  const SORT_LIVE_KEY = 'slsLunaSortLive';
  let lastArtworkLive = '';

  function publishArtworkRequest(w, app) {
    const appid = Number(app && app.appid);
    if (!valid(appid)) return false;
    const payload = JSON.stringify({ appid, name: nameOf(app), at: Date.now(),
      nonce: Math.floor(Math.random() * 1e9) });
    try {
      const storage = storageOf(w);
      if (!storage) return false;
      storage.setItem(ARTWORK_REQUEST_KEY, payload);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Apply the already-written artwork through Steam's own API so the library
  // updates without a restart: the backend hands over the file's bytes, and
  // SetCustomArtworkForApp (confirmed live for types 0..3) does the rest.
  // One-shot: the live key is claimed (removed) on first read so a restart
  // never replays it; stale requests past the TTL are ignored.
  const ARTWORK_LIVE_TTL_MS = 5 * 60 * 1000;
  async function handleArtworkLive(w) {
    const storage = storageOf(w);
    if (!storage) return false;
    let raw = null;
    try { raw = storage.getItem(ARTWORK_LIVE_KEY); } catch (_) { return false; }
    if (!raw || raw === lastArtworkLive) return false;
    lastArtworkLive = raw;
    try { storage.removeItem(ARTWORK_LIVE_KEY); } catch (_) {}
    let request = null;
    try { request = JSON.parse(raw); } catch (_) { return false; }
    if (request && typeof request.at === 'number' && Number.isFinite(request.at)
      && Date.now() - request.at > ARTWORK_LIVE_TTL_MS) return false;
    const appid = Number(request && request.appid);
    const kinds = Array.isArray(request && request.kinds) ? request.kinds : [];
    if (!valid(appid) || !kinds.length) return false;
    const apps = w.SteamClient && w.SteamClient.Apps;
    const results = [];
    for (const kind of kinds) {
      try {
        if (!apps || typeof apps.SetCustomArtworkForApp !== 'function') {
          throw Error('Steam artwork API unavailable');
        }
        const live = await rpc(w, 'SlsSgdbLive', { raw: JSON.stringify({ appid, kind }) });
        if (!live || live.success !== true) {
          throw Error((live && live.error) || 'No live payload for this slot.');
        }
        await apps.SetCustomArtworkForApp(appid, live.base64, live.extension, Number(live.type));
        results.push({ kind, ok: true });
      } catch (error) {
        results.push({ kind, ok: false, error: String((error && error.message) || error) });
      }
    }
    try {
      storage.setItem(ARTWORK_LIVE_RESULT_KEY,
        JSON.stringify({ at: request.at || Date.now(), appid, results }));
    } catch (_) { /* the panel just will not see the outcome */ }
    return true;
  }

  // Beta pages live behind the Luna Settings switch; the same localStorage key
  // keeps the context menu honest (no artwork action while beta is off).
  function betaEnabled(w) {
    try {
      const storage = storageOf(w);
      return Boolean(storage && storage.getItem('slsLunaBeta') === '1');
    } catch (_) {
      return false;
    }
  }

  function defaultActions() {
    return [{
      id: 'hltb',
      label: 'HowLongToBeat',
      isEnabled: app => Boolean(nameOf(app)),
      run: (app, w) => openExternalUrl(w, searchUrlFor(nameOf(app))).then(opened => {
        if (!opened) throw Error('Steam could not open the browser for the HowLongToBeat search.');
        return true;
      }),
    }, {
      id: 'artwork',
      label: 'Change artwork',
      isEnabled: (app, w) => valid(app && app.appid) && betaEnabled(w),
      run: (app, w) => {
        if (!publishArtworkRequest(w, app)) {
          throw Error('Could not open the Luna artwork picker.');
        }
        return true;
      },
    }];
  }

  /* The owned games and non-Steam shortcuts this context can see, for the
     Luna panel's HowLongToBeat page. Only appid, display name and a shortcut
     flag leave this function; the list stays local. */
  function collectLibrary(w) {
    const store = w && (w.appStore || (w.SteamUIStore && w.SteamUIStore.AppStore));
    let overviews = [];
    try {
      if (store && Array.isArray(store.allApps)) overviews = store.allApps;
      else if (store && store.m_mapApps && typeof store.m_mapApps.values === 'function') {
        overviews = [...store.m_mapApps.values()];
      }
    } catch (_) { overviews = []; }
    const out = [];
    const seen = new Set();
    for (const overview of overviews) {
      if (!overview) continue;
      const appid = Number(overview.appid);
      if (!valid(appid) || seen.has(appid)) continue;
      const type = Number(overview.app_type);
      if (type !== 1 && type !== 1073741824) continue;
      const name = nameOf(overview);
      if (!name) continue;
      seen.add(appid);
      out.push({ appid, name: name.slice(0, 200), shortcut: type === 1073741824 });
      if (out.length >= 5000) break;
    }
    out.sort((a, b) => a.name.localeCompare(b.name));
    return out;
  }

  let lastLibraryPayload = '';

  function pushLibrary(w) {
    let payload;
    try {
      const games = collectLibrary(w);
      if (!games.length) return Promise.resolve(false);
      payload = JSON.stringify({ games });
    } catch (error) {
      reportAgentFailure(w, 'library inventory', error);
      return Promise.resolve(false);
    }
    if (payload === lastLibraryPayload) return Promise.resolve(false);
    return rpc(w, 'SlsHltbLibrary', { raw: payload })
      .then(out => {
        if (out && out.success === true) {
          lastLibraryPayload = payload;
          return true;
        }
        return false;
      })
      .catch(error => {
        reportAgentFailure(w, 'library inventory push', error);
        return false;
      });
  }

  function nameOf(app) {
    const name = app && (app.display_name || app.name);
    return typeof name === 'string' ? name.trim() : '';
  }

  /* Open an external URL in the user's default browser. Steam itself is the
     focused GUI app, so routing through its handlers raises the browser under
     Wayland too. Tries the client APIs first. Resolves true when a handler
     accepted the URL. */
  function openExternalUrl(w, url) {
    const target = String(url || '');
    if (!target) return Promise.resolve(false);
    try {
      const client = w && w.SteamClient;
      if (client && client.System && typeof client.System.OpenInSystemBrowser === 'function') {
        client.System.OpenInSystemBrowser(target);
        return Promise.resolve(true);
      }
      if (client && client.URL && typeof client.URL.ExecuteSteamURL === 'function') {
        client.URL.ExecuteSteamURL('steam://openurl_external/' + target);
        return Promise.resolve(true);
      }
    } catch (error) {
      reportAgentFailure(w, 'Steam browser handler', error);
    }
    return Promise.resolve(false);
  }

  /* Same discovery contract as Playtime's agent: push into the library webpack
     chunk, read the third (minified) require parameter of the native game-menu
     module, and inspect only that module's already-loaded dependencies. The
     lookups are independent per add-on on purpose: each payload stays
     standalone and keeps working whatever else is installed. Steam used to
     expose React as `window.SP_REACT`; a client update stopped doing that in
     SharedJSContext, which silently killed every jsx-based hook. When it is
     missing, React is resolved from the same module graph. */
  function reactFromModules(require) {
    try {
      for (const id of Object.keys(require.m)) {
        let exports;
        try { exports = require(id); } catch (_) { continue; }
        if (exports && typeof exports === 'object' && typeof exports.createElement === 'function'
            && typeof exports.isValidElement === 'function' && typeof exports.useState === 'function') {
          return exports;
        }
      }
    } catch (_) { /* no usable module graph */ }
    return null;
  }
  function discoverMenuTools(w) {
    const chunks = w.webpackChunksteamui;
    if (!chunks || !chunks.push) return null;
    let require;
    chunks.push([['sls-luna-menu-' + Date.now()], {}, r => { require = r; }]);
    if (!require || !require.m) return null;
    const factory = Object.values(require.m).find(f => String(f).includes('BuildManageSubmenu'));
    if (!factory) return null;
    const factorySource = String(factory);
    const signature = factorySource.match(/^\s*(?:function(?:\s+[\w$]+)?\s*)?\(([^)]*)\)/);
    const requireName = signature && signature[1].split(',')[2] && signature[1].split(',')[2].trim();
    if (!requireName || !/^[A-Za-z_$][\w$]*$/.test(requireName)) return null;
    const escapedRequire = requireName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const dependencyPattern = new RegExp('\\b' + escapedRequire + '\\s*\\(\\s*(\\d+(?:e\\d+)?)\\s*\\)', 'g');
    const dependencies = [...factorySource.matchAll(dependencyPattern)].map(m => Number(m[1]));
    let jsx, item, React = w.SP_REACT;
    for (const id of new Set(dependencies)) {
      const exports = require(id);
      if (exports && exports.jsx && exports.jsxs) jsx = exports;
      for (const value of Object.values(exports || {})) {
        if (typeof value !== 'function') continue;
        const source = String(value);
        if (value.prototype && value.prototype.OnClick && source.includes('contextMenuItem') && source.includes('onSelected')) item = value;
      }
    }
    if (!React) React = reactFromModules(require);
    return jsx && item && React ? { React, jsx, item } : null;
  }

  /* ---- HowLongToBeat as a library sort option --------------------------
   * Steam's unknown enum fallback is alphabetical. Sort each HLTB view's own
   * collection/sections instead: never rewrite appStore.sort_as, infer a view's
   * selection from another dropdown, or fight Steam with a global stored sort.
   * Both home shelves and collection grids subscribe to cache/order changes. */
  const SORT_VALUE = 12;
  const SORT_LABEL = 'HowLongToBeat';
  const SORT_ENUM_FINGERPRINT = [1, 4, 9, 11]; // alphabetical, hours, metacritic, review
  const HLTB_ORDER_KEY = 'slsLunaHltbOrder';   // 'short' (default) or 'long'
  let hltbRecords = {};
  let currentOrder = 'short';
  let sortSeen = 0;
  let liveSortValue;
  let hltbRevision = 0;
  const hltbViews = new Set();
  let refreshPending = false;

  function notifyHltbViews(w) {
    if (refreshPending || !hltbViews.size) return;
    refreshPending = true;
    const schedule = (w && w.setTimeout) || setTimeout;
    schedule(() => {
      refreshPending = false;
      for (const refresh of [...hltbViews]) {
        try { refresh(); } catch (_) { /* closing view */ }
      }
    }, 0);
  }

  // One small record of the last decision, published for the Health page and
  // for diagnosing "the order looks wrong" reports without a debugger.
  const SORT_DIAG_KEY = 'slsLunaSortDiag';
  function noteSortDiag(w, event) {
    try {
      const storage = storageOf(w);
      if (!storage) return;
      storage.setItem(SORT_DIAG_KEY, JSON.stringify({
        event: event,
        at: Math.round(Date.now() / 1000),
        seen: sortSeen,
        live: liveSortValue === undefined ? null : liveSortValue,
        engine: 'view-local',
        revision: hltbRevision,
        views: hltbViews.size,
        order: currentOrder,
      }));
    } catch (_) { /* diagnostics only */ }
  }

  function setHltbRecords(records, w) {
    const before = Object.keys(hltbRecords).sort().map(id => [id, hltbSecondsFor(id)]);
    hltbRecords = records || {};
    const after = Object.keys(hltbRecords).sort().map(id => [id, hltbSecondsFor(id)]);
    if (JSON.stringify(before) !== JSON.stringify(after)) {
      hltbRevision += 1;
      notifyHltbViews(w);
    }
  }

  function hltbSecondsFor(appid) {
    const record = hltbRecords[String(appid)];
    if (!record || record.match === 'none') return null;
    const main = Number(record.main) || 0;
    const fallback = Number(record.all) || Number(record.extra) || 0;
    const value = main || fallback;
    return Number.isFinite(value) && value > 0 ? value : null;
  }

  function hltbMinutesFor(appid) {
    const seconds = hltbSecondsFor(appid);
    return seconds ? Math.round(seconds / 60) : 0;
  }

  function compareHltb(a, b, order = currentOrder) {
    const left = hltbSecondsFor(a.appid), right = hltbSecondsFor(b.appid);
    if (left == null && right != null) return 1;
    if (right == null && left != null) return -1;
    if (left != null && right != null && left !== right) {
      return order === 'long' ? right - left : left - right;
    }
    return String(a.display_name || a.name || '').localeCompare(String(b.display_name || b.name || ''))
      || Number(a.appid) - Number(b.appid);
  }

  function storageOf(w) {
    try {
      if (w && w.localStorage) return w.localStorage;
      if (typeof localStorage !== 'undefined') return localStorage;
    } catch (_) { /* blocked */ }
    return null;
  }

  /* ---- Steam main view control (this context only) ------------------------
     Store, Community and the built-in browser are drawn by a separate CEF view
     composited above Steam's shell document. Steam's own modals hide it with
     MainWindowBrowserManager.m_browser.SetVisible(false); the manager lives in
     this context, not in the shell document where the Luna panel runs. The
     panel therefore asks through localStorage: one request key, one result
     key. Nothing about the hidden state is written to disk, so a Steam restart
     always starts with the view visible. */
  const VIEW_REQUEST_KEY = 'slsLunaViewRequest';
  const VIEW_RESULT_KEY = 'slsLunaViewResult';
  const VIEW_REQUEST_TTL_MS = 5000;
  let viewHiddenByLuna = false;
  let viewChannelInstalled = false;
  let lastViewRequest = '';

  function viewManager(w) {
    try { return w && w.MainWindowBrowserManager; } catch (_) { return null; }
  }

  function viewRoute(w) {
    const manager = viewManager(w);
    const history = manager && manager.m_history;
    const location = history && history.location;
    return location && typeof location.pathname === 'string' ? location.pathname : null;
  }

  function viewBrowser(w) {
    const manager = viewManager(w);
    const browser = manager && manager.m_browser;
    return browser && typeof browser.SetVisible === 'function' ? browser : null;
  }

  // {ok, route, browserVisible} or {ok:false, error}. Never throws.
  function viewStatus(w) {
    const browser = viewBrowser(w);
    const route = viewRoute(w);
    if (!browser) return { ok: false, error: 'The Steam view API is unavailable.' };
    return { ok: true, route, browserVisible: !viewHiddenByLuna };
  }

  // Hide/show is idempotent: repeated hides do not call SetVisible twice, and a
  // show only ever restores a view this context hid.
  function viewSetVisible(w, visible) {
    const browser = viewBrowser(w);
    if (!browser) return { ok: false, error: 'The Steam view API is unavailable.' };
    const want = visible !== false;
    try {
      if (want && viewHiddenByLuna) {
        viewHiddenByLuna = false;
        browser.SetVisible(true);
      } else if (!want && !viewHiddenByLuna) {
        viewHiddenByLuna = true;
        browser.SetVisible(false);
      }
    } catch (error) {
      return { ok: false, error: String(error && error.message ? error.message : error) };
    }
    return { ok: true, route: viewRoute(w), browserVisible: !viewHiddenByLuna };
  }

  // Asking Steam's router for the Library. Hiding the browser view is not
  // enough on its own: a hidden Store/Community view keeps taking input, so the
  // menu is only reachable after Steam itself moved off that route. Bounded to
  // ~1.5 s, and the route reported is the one Steam actually shows.
  const VIEW_NAVIGATE_TIMEOUT_MS = 1500;

  function viewNavigate(w, done) {
    let navigate = null;
    try {
      const ui = w && w.SteamUIStore;
      navigate = ui && typeof ui.Navigate === 'function' ? ui.Navigate : null;
    } catch (_) { navigate = null; }
    if (!navigate) { done({ ok: false, error: 'The Steam router is unavailable.' }); return; }
    try {
      navigate.call(w.SteamUIStore, '/library/home');
    } catch (error) {
      done({ ok: false, error: String(error && error.message ? error.message : error) });
      return;
    }
    const timer = (w && w.setTimeout) || setTimeout;
    const started = Date.now();
    const check = () => {
      const route = viewRoute(w);
      if (!route || !/^\/(browser|store|community)(\/|$)/.test(route)) {
        done({ ok: true, route: route, browserVisible: !viewHiddenByLuna });
        return;
      }
      if (Date.now() - started >= VIEW_NAVIGATE_TIMEOUT_MS) {
        done({ ok: false, route: route, error: 'Steam stayed on ' + route + ' after the Library switch.' });
        return;
      }
      timer(check, 50);
    };
    timer(check, 50);
  }

  // Publishes one answer body on the result key.
  function viewPublish(w, body) {
    try {
      const storage = storageOf(w);
      if (!storage) return null;
      storage.setItem(VIEW_RESULT_KEY, JSON.stringify(body));
    } catch (_) { return null; }
    return body;
  }

  function viewReply(w, id, action, result) {
    return viewPublish(w, {
      id, action, at: Date.now(), ok: result.ok === true,
      route: typeof result.route === 'string' ? result.route : null,
      browserVisible: result.browserVisible !== false,
      error: result.error ? String(result.error) : '',
    });
  }

  // Handles one panel request ({id, action, at}) and publishes the answer.
  // Unknown actions and malformed ids are dropped, never guessed at.
  function viewHandleRequest(w, raw) {
    let request = null;
    try { request = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (_) { return null; }
    if (!request || typeof request !== 'object') return null;
    const id = typeof request.id === 'string' ? request.id.slice(0, 64) : '';
    const action = request.action;
    if (!id || (action !== 'status' && action !== 'hide' && action !== 'show'
        && action !== 'navigate')) return null;
    const at = Number(request.at);
    if (Number.isFinite(at) && at > 0 && Date.now() - at > VIEW_REQUEST_TTL_MS) return null;
    if (action === 'navigate') {
      // Asynchronous: the answer lands on the result key when the route moves.
      viewNavigate(w, result => viewReply(w, id, action, result));
      return null;
    }
    const result = action === 'status' ? viewStatus(w) : viewSetVisible(w, action !== 'hide');
    return viewReply(w, id, action, result);
  }

  /* Installs the request listener in SharedJSContext. Also publishes the
     current state once, so a panel that mounts later already knows the route
     (its own document cannot read it) before the user clicks anything. */
  function installViewControl(w) {
    if (!w || viewChannelInstalled || w.__SlsLunaViewInstalled) return false;
    if (typeof w.addEventListener !== 'function' || !storageOf(w)) return false;
    viewChannelInstalled = true;
    try { w.__SlsLunaViewInstalled = true; } catch (_) { /* read-only window */ }
    const publish = () => {
      const state = viewStatus(w);
      try {
        const storage = storageOf(w);
        if (storage) {
          storage.setItem(VIEW_RESULT_KEY, JSON.stringify({
            id: '', action: 'status', at: Date.now(), ok: state.ok === true,
            route: typeof state.route === 'string' ? state.route : null,
            browserVisible: state.browserVisible !== false,
            error: state.error ? String(state.error) : '',
          }));
        }
      } catch (_) { /* a state push is best effort */ }
    };
    const consume = () => {
      try {
        const storage = storageOf(w);
        const raw = storage && storage.getItem(VIEW_REQUEST_KEY);
        if (!raw || raw === lastViewRequest) return;
        lastViewRequest = raw;
        viewHandleRequest(w, raw);
      } catch (_) { /* never throw from a menu helper */ }
    };
    w.addEventListener('storage', event => {
      const key = event && typeof event.key === 'string' ? event.key : '';
      if (key !== VIEW_REQUEST_KEY) return;
      consume();
    });
    consume();
    publish();
    return true;
  }

  function readHltbOrder(w) {
    const storage = storageOf(w);
    try {
      return storage && storage.getItem(HLTB_ORDER_KEY) === 'long' ? 'long' : 'short';
    } catch (_) {
      return 'short';
    }
  }

  // Only direction is global. Each view's eSortBy is authoritative; another
  // shelf's dropdown/localStorage must never reset it or change its comparator.
  function syncSortAs(w) {
    const order = readHltbOrder(w);
    if (order === currentOrder) return false;
    currentOrder = order;
    hltbRevision += 1;
    notifyHltbViews(w);
    noteSortDiag(w, 'direction');
    return true;
  }

  // The sort dropdown is recognized by its option values, not its labels, so
  // this works in every language. Other dropdowns never match the fingerprint.
  function isSortDropdown(props) {
    if (!props || !Array.isArray(props.rgOptions) || props.rgOptions.length < 8) return false;
    const seen = new Set();
    for (const option of props.rgOptions) {
      const data = option && option.data;
      if (typeof data !== 'number') return false;
      seen.add(data);
    }
    return SORT_ENUM_FINGERPRINT.every(value => seen.has(value));
  }

  function withSortOption(props, w) {
    if (!isSortDropdown(props)) return null;
    sortSeen += 1;
    // Publish Steam's live sort value so the panel's label work reflects the
    // truth (Steam's own label lookup has no case for Luna's value, and other
    // views keep their own local sort state).
    if (props.selectedOption !== undefined && props.selectedOption !== liveSortValue) {
      liveSortValue = props.selectedOption;
      try {
        const storage = storageOf(w);
        if (storage) storage.setItem(SORT_LIVE_KEY, String(liveSortValue));
      } catch (_) { /* diagnostics only */ }
    }
    const appended = props.rgOptions.some(option => option && option.data === SORT_VALUE)
      ? props.rgOptions
      : props.rgOptions.concat([{ data: SORT_VALUE, label: SORT_LABEL }]);
    if (appended === props.rgOptions && props.selectedOption !== SORT_VALUE) return null;
    return { ...props, rgOptions: appended,
      ...(props.selectedOption === SORT_VALUE ? { strDefaultLabel: SORT_LABEL } : {}) };
  }

  // Home uses a class with a memoized collection sorter; collections use a
  // functional section grid. Handle both at their actual rendering boundaries.
  const shelfRefreshers = new WeakMap();
  const hookedShelfPrototypes = new WeakSet();

  function hookHltbShelf(type, props, w) {
    const proto = type && type.prototype;
    if (!props || !props.showcase || props.collectionId === undefined
        || !proto || typeof proto.render !== 'function'
        || typeof proto.ComputeChildSizes !== 'function') return false;
    if (hookedShelfPrototypes.has(proto)) return true;
    const render = proto.render;
    const unmount = proto.componentWillUnmount;
    proto.render = function (...args) {
      if (!shelfRefreshers.has(this) && typeof this.forceUpdate === 'function') {
        const refresh = () => {
          if (this.props?.showcase?.eSortBy === SORT_VALUE) this.forceUpdate();
        };
        shelfRefreshers.set(this, refresh);
        hltbViews.add(refresh);
      }
      if (this.props?.showcase?.eSortBy !== SORT_VALUE || typeof this.m_fnSort !== 'function') {
        return render.apply(this, args);
      }
      // Do not use Steam's memoized alphabetical fallback or write shared app
      // objects. Replace only this instance's sorter for this render.
      const original = this.m_fnSort;
      const order = readHltbOrder(w);
      this.m_fnSort = collection => collection.visibleApps.slice().sort((a, b) => compareHltb(a, b, order));
      noteSortDiag(w, 'home');
      try { return render.apply(this, args); }
      finally { this.m_fnSort = original; }
    };
    proto.componentWillUnmount = function (...args) {
      hltbViews.delete(shelfRefreshers.get(this));
      shelfRefreshers.delete(this);
      if (typeof unmount === 'function') return unmount.apply(this, args);
    };
    hookedShelfPrototypes.add(proto);
    return true;
  }

  function withHltbSections(props, w) {
    if (!props || props.eSortBy !== SORT_VALUE || !Array.isArray(props.childSections)
        || !props.childSections.length) return null;
    const sections = props.childSections;
    if (sections.some(section => !Array.isArray(section.children))) return null;
    const children = sections.flatMap(section => section.children);
    const overview = child => child && (child.m_overview || child);
    if (children.some(child => !valid(overview(child)?.appid))) return null;
    const order = readHltbOrder(w);
    children.sort((a, b) => compareHltb(overview(a), overview(b), order));
    noteSortDiag(w, 'collection');
    return { ...props, childSections: [{ ...sections[0], subSectionName: '', children }] };
  }

  const gridTypes = new WeakMap();
  function hltbGridType(type, props, w, React) {
    if (!props || !Array.isArray(props.childSections) || props.eSortBy === undefined
        || !type || (typeof type !== 'function' && typeof type !== 'object')
        || typeof React.useReducer !== 'function' || typeof React.useEffect !== 'function'
        || typeof React.useRef !== 'function') return type;
    if (gridTypes.has(type)) return gridTypes.get(type);
    function SlsLunaHltbGrid(input) {
      const [, refresh] = React.useReducer(value => value + 1, 0);
      const latest = React.useRef(input);
      latest.current = input;
      React.useEffect(() => {
        const update = () => { if (latest.current.eSortBy === SORT_VALUE) refresh(); };
        hltbViews.add(update);
        update(); // Catch data that arrived between render and effect registration.
        return () => hltbViews.delete(update);
      }, []);
      return React.createElement(type, withHltbSections(input, w) || input);
    }
    gridTypes.set(type, SlsLunaHltbGrid);
    return SlsLunaHltbGrid;
  }

  // Steam's capsule overlay (the little value box on each library game) shows
  // the active sort's value, but returns null for unknown sort values. When
  // HowLongToBeat is active, re-point that overlay at Steam's own hours-played
  // rendering with the cached minutes, so each capsule reads like
  // "23.6 hours". Games without times keep Steam's default (nothing shown).
  // Diagnostics (which decisions were taken, and why one was skipped) land in
  // localStorage so a live client can be inspected without guessing.
  const OVERLAY_DIAG_KEY = 'slsLunaOverlayDiag';
  const overlayDiag = { rewrites: 0, misses: 0, seen: {}, reasons: {}, samples: [] };
  let overlayDiagAt = 0;

  function noteOverlayDiag(hit, props, reason) {
    if (hit) overlayDiag.rewrites += 1;
    else {
      overlayDiag.misses += 1;
      overlayDiag.reasons[reason] = (overlayDiag.reasons[reason] || 0) + 1;
      if (overlayDiag.samples.length < 5) {
        overlayDiag.samples.push(Object.keys(props || {}).sort().join(','));
      }
    }
    const key = String(props && props.sortByType);
    overlayDiag.seen[key] = (overlayDiag.seen[key] || 0) + 1;
    const now = Date.now();
    if (now - overlayDiagAt > 2000) {
      overlayDiagAt = now;
      try {
        const storage = storageOf();
        if (storage) storage.setItem(OVERLAY_DIAG_KEY, JSON.stringify(overlayDiag));
      } catch (_) { /* diagnostics only */ }
    }
  }

  function withHltbOverlay(props) {
    const decision = hltbOverlayDecision(props);
    noteOverlayDiag(decision.ok, props, decision.reason);
    return decision.ok ? decision.props : null;
  }

  function hltbOverlayDecision(props) {
    if (!props || props.sortByType !== SORT_VALUE) return { ok: false, reason: 'other_sort' };
    if (!props.app) return { ok: false, reason: 'no_app' };
    if (props.id === undefined) return { ok: false, reason: 'no_id' };
    if (props.strCollectionId !== undefined) return { ok: false, reason: 'has_collection' };
    const minutes = hltbMinutesFor(props.app.appid);
    if (!minutes) return { ok: false, reason: 'no_minutes' };
    const clone = Object.assign(Object.create(Object.getPrototypeOf(props.app)), props.app);
    clone.minutes_playtime_forever = minutes;
    return { ok: true, props: { ...props, sortByType: 4, app: clone } }; // 4 = Steam's hours-played sort
  }

  function refreshHltbData(w) {
    return rpc(w, 'SlsHltbGet').then(out => {
      if (out && out.success !== false) setHltbRecords(out.games || {}, w);
      return true;
    }).catch(() => false);
  }

  /* Install the Luna game-menu hook. Returns the registry (or null while the
     library module is still loading). `providedTools` lets tests inject the
     jsx/item pair instead of a live webpack module. */
  function installLunaMenu(w, providedTools) {
    if (w.__SlsLunaMenu) return w.__SlsLunaMenu;
    const tools = providedTools || discoverMenuTools(w);
    if (!tools) return null;
    const React = tools.React;
    const MenuItem = tools.item;
    const h = React.createElement;
    let jsx = tools.jsx;
    let slot = null;
    const actions = [];
    const originals = {};
    const wrappers = {};

    function register(action) {
      if (!action || typeof action.id !== 'string' || action.id === '') return false;
      if (typeof action.label !== 'string' || action.label === '') return false;
      if (typeof action.run !== 'function') return false;
      const entry = { id: action.id, label: action.label, run: action.run, isEnabled: action.isEnabled };
      const index = actions.findIndex(existing => existing.id === action.id);
      if (index >= 0) actions[index] = entry; else actions.push(entry);
      return true;
    }

    function unregister(id) {
      const index = actions.findIndex(existing => existing.id === id);
      if (index < 0) return false;
      actions.splice(index, 1);
      return true;
    }

    const overviewOf = id => (w.appStore || (w.SteamUIStore && w.SteamUIStore.AppStore))
      ?.GetAppOverviewByAppID?.(Number(id)) || { appid: Number(id) };
    const isOuter = proto => Boolean(proto && proto.GetTargetApps && proto.BuildManageSubmenu && proto.render);
    const isInner = proto => Boolean(proto && proto.HideIfSubmenu && proto.HideMenu && proto.render);

    function scanIds(children, depth) {
      const ids = new Set();
      if ((depth || 0) > 12 || children == null) return ids;
      if (Array.isArray(children)) {
        for (const child of children) for (const id of scanIds(child, (depth || 0) + 1)) ids.add(id);
        return ids;
      }
      if (!React.isValidElement(children) || !children.props) return ids;
      const props = children.props;
      if (props.app && props.app.appid) ids.add(Number(props.app.appid));
      if (Array.isArray(props.rgApps)) for (const app of props.rgApps) if (app && app.appid) ids.add(Number(app.appid));
      for (const id of scanIds(props.children, (depth || 0) + 1)) ids.add(id);
      return ids;
    }

    function targetFor(props) {
      const ids = [...scanIds(props && props.children)];
      // A focused game names itself in the menu label; that is authoritative
      // even when child actions mention DLC or other apps. Bulk menus carry no
      // label and more than one app, so they get no per-game actions.
      const labeled = slot && Date.now() - slot.ts < 10000 && props && props.label && slot.app
        && slot.app.display_name === props.label;
      if (labeled) return slot;
      if (ids.length === 1) return { app: overviewOf(ids[0]), instance: slot && slot.instance };
      return null;
    }

    function enabledActions(app) {
      return actions.filter(action => {
        if (typeof action.isEnabled !== 'function') return true;
        try {
          return action.isEnabled(app, w) === true;
        } catch (error) {
          reportAgentFailure(w, 'action eligibility ' + action.id, error);
          return false;
        }
      });
    }

    function itemKey(child) {
      if (!child) return '';
      if (typeof child.key === 'string') return child.key;
      if (child.props && typeof child.props.key === 'string') return child.props.key;
      return '';
    }

    function actionItems(app) {
      return enabledActions(app).map(action => h(MenuItem, {
        key: ITEM_PREFIX + action.id,
        onSelected: () => Promise.resolve()
          .then(() => action.run(app, w))
          .catch(error => reportAgentFailure(w, 'action ' + action.id, error)),
      }, action.label));
    }

    function insertActions(children, items) {
      const clean = (Array.isArray(children) ? children : [children])
        .filter(child => !itemKey(child).startsWith(ITEM_PREFIX));
      let placed = false;
      function afterPrimary(value) {
        if (Array.isArray(value)) {
          const out = [];
          for (const child of value) {
            if (!placed && Array.isArray(child)) out.push(afterPrimary(child));
            else {
              out.push(child);
              if (!placed && React.isValidElement(child)) {
                for (const item of items) out.push(item);
                placed = true;
              }
            }
          }
          return out;
        }
        if (React.isValidElement(value)) {
          placed = true;
          return [value].concat(items);
        }
        return value;
      }
      const ordered = afterPrimary(clean);
      return placed ? ordered : items.concat(Array.isArray(clean) ? clean : [clean]);
    }

    function restore() {
      for (const key of ['jsx', 'jsxs']) if (jsx[key] === wrappers[key]) jsx[key] = originals[key];
    }

    // Two add-ons hooking the same jsx module must not fight, and a Steam
    // rebuild may replace the hooked functions in place or with a new module.
    // The wrapper therefore stamps the module it wrapped (`__slsSeen.luna`)
    // every time it runs; ensure() probes the live chain with an inert element
    // and treats a fresh stamp as "we are still in the chain" (someone else may
    // sit on top - fine) while a stale one means a real rebuild. `base` is the
    // leaf function of the chain at install time; the re-entry guard uses it so
    // a wrapper cycle can never recurse without bound.
    let wrappedModule = null;
    let inRender = false;
    const base = {};

    function stampSeen() {
      if (!jsx || typeof jsx !== 'object') return;
      const seen = jsx.__slsSeen || (jsx.__slsSeen = {});
      seen.luna = Date.now();
    }

    for (const key of ['jsx', 'jsxs']) {
      originals[key] = jsx[key];
      base[key] = jsx[key];
      wrappers[key] = function (type, ...args) {
        stampSeen();
        // Re-entry means another wrapper called us while we were already
        // rendering (a cycle created by two add-ons re-arming). Fall back to
        // the leaf so rendering still completes, without inserting twice.
        const next = inRender && base[key] ? base[key] : originals[key];
        if (!inRender) {
          // Each hook is isolated: one throwing third-party patch must not take
          // the others (or Steam's render) down with it. The outer catch is the
          // net for everything this wrapper reads or builds; Steam's own call
          // below is left alone so a real render error still reaches it.
          try {
          const props = args[0];
          safeHook(w, 'hltb shelf hook', () => hookHltbShelf(type, props, w));
          // Sort each view independently and subscribe mounted grids to data.
          if (props && Array.isArray(props.rgOptions)) {
            const withSort = safeHook(w, 'sort option', () => withSortOption(props, w));
            if (withSort) args[0] = withSort;
          }
          if (props && Array.isArray(props.childSections)) {
            const grid = safeHook(w, 'hltb grid', () => hltbGridType(type, props, w, React));
            if (grid !== undefined && grid !== type) type = grid;
            else {
              const sorted = safeHook(w, 'hltb sections', () => withHltbSections(props, w));
              if (sorted) args[0] = sorted;
            }
          }
          // While that option is active, each capsule shows its cached hours.
          if (args[0] && args[0].sortByType === SORT_VALUE) {
            const overlay = safeHook(w, 'hltb overlay', () => withHltbOverlay(args[0]));
            if (overlay) args[0] = overlay;
          }
          const proto = type && type.prototype;
          if (isOuter(proto) && props && props.overview) {
            // Fresh build of the game menu: remember the exact target before
            // its contents elements are created inside the same render pass.
            slot = { app: props.overview, instance: props.instance, ts: Date.now() };
          } else if (isInner(proto) && props && props.children != null) {
            try {
              const target = targetFor(props);
              if (target && target.app && valid(target.app.appid)) {
                const items = actionItems(target.app);
                if (items.length) args[0] = { ...props, children: insertActions(props.children, items) };
              }
            } catch (error) {
              reportAgentFailure(w, 'game menu actions', error);
            }
          }
          } catch (error) {
            reportAgentFailure(w, 'menu render', error);
          }
        }
        inRender = true;
        try {
          return next.call(this, type, ...args);
        } finally {
          inRender = false;
        }
      };
      jsx[key] = wrappers[key];
    }
    wrappedModule = jsx;

    const api = {
      version: 1,
      register,
      unregister,
      list: () => actions.map(entry => ({ id: entry.id, label: entry.label })),
      get sort() {
        return { value: SORT_VALUE, seen: sortSeen, games: Object.keys(hltbRecords).length,
          engine: 'view-local', views: hltbViews.size, revision: hltbRevision,
          order: currentOrder };
      },
      get attached() { return wrappedModule !== null && jsx === wrappedModule; },
      ensure() {
        // The library UI can rebuild its bundle: sometimes with a new jsx
        // module object, sometimes by replacing the hooked functions in place
        // on the same object. Probe the live chain with an inert element: if
        // Luna's wrapper runs it stamps the module, proving it is still in the
        // chain (possibly under another add-on's wrapper - that is fine). A
        // stale stamp means the functions were replaced and we must re-arm.
        let fresh = null;
        try {
          fresh = discoverMenuTools(w);
        } catch (_) { /* keep waiting for the next beat */ }
        if (!fresh) return false;
        const module = fresh.jsx;
        if (module.jsx === wrappers.jsx || module.jsxs === wrappers.jsxs) return false;
        try {
          module.jsx(function SlsLunaProbe() {}, {});
        } catch (_) { /* a broken chain still means we are not in it */ }
        const seen = module.__slsSeen && Number(module.__slsSeen.luna || 0);
        if (seen && Date.now() - seen < 5000) return false;
        jsx = module;
        restore();
        for (const key of ['jsx', 'jsxs']) {
          if (jsx[key] === wrappers[key]) jsx[key] = originals[key];
          originals[key] = jsx[key];
          base[key] = jsx[key];
          jsx[key] = wrappers[key];
        }
        wrappedModule = jsx;
        stampSeen();
        return true;
      },
      dispose() {
        restore();
        delete w.__SlsLunaMenu;
      },
    };
    for (const action of defaultActions()) register(action);
    w.__SlsLunaMenu = api;
    return api;
  }

  /* Boot in SharedJSContext: arm the menu now, retry while the library module
     is still loading, and re-arm on a slow beat so a Steam UI reload cannot
     leave the menu without Luna's actions. The game inventory is reported to
     the backend at boot (again after a minute, so a late Steam start still
     fills it) and refreshed on a slow beat. */
  function bootLunaMenu(w) {
    if (w.__SlsLunaAgent) return;
    w.__SlsLunaAgent = true;
    // The Luna panel cannot reach the main window's browser manager from the
    // shell document; this context answers its requests.
    safeHook(w, 'view control', () => installViewControl(w));
    const arm = () => {
      try {
        if (!w.__SlsLunaMenu) installLunaMenu(w);
        if (w.__SlsLunaMenu) w.__SlsLunaMenu.ensure();
      } catch (error) {
        reportAgentFailure(w, 'menu install', error);
      }
    };
    arm();
    const beat = () => {
      arm();
      pushLibrary(w);
      refreshHltbData(w)
        .then(() => safeHook(w, 'sort sync', () => syncSortAs(w)))
        .catch(error => reportAgentFailure(w, 'hltb refresh', error));
    };
    if (typeof w.setInterval === 'function') w.setInterval(beat, 30000);
    if (typeof w.setTimeout === 'function') w.setTimeout(() => pushLibrary(w), 60000);
    // The panel writes the sort order and artwork requests in localStorage;
    // the storage event tells this context to react right away.
    if (typeof w.addEventListener === 'function') {
      w.addEventListener('storage', () => {
        syncSortAs(w);
        handleArtworkLive(w);
      });
    }
    pushLibrary(w);
    refreshHltbData(w)
      .then(() => safeHook(w, 'sort sync', () => syncSortAs(w)))
      .catch(error => reportAgentFailure(w, 'hltb refresh', error));
    handleArtworkLive(w);
  }

  return { HLTB_SEARCH, SORT_VALUE, SORT_LABEL, ARTWORK_REQUEST_KEY, ARTWORK_LIVE_KEY,
    ARTWORK_LIVE_RESULT_KEY, SORT_LIVE_KEY, VIEW_REQUEST_KEY, VIEW_RESULT_KEY,
    viewStatus, viewSetVisible, viewNavigate, viewHandleRequest, installViewControl,
    discoverMenuTools, openExternalUrl,
    searchUrlFor, nameOf, betaEnabled, defaultActions, publishArtworkRequest, handleArtworkLive,
    collectLibrary, pushLibrary, rpc, setHltbRecords, hltbSecondsFor, hltbMinutesFor, compareHltb,
    readHltbOrder, syncSortAs, isSortDropdown, withSortOption,
    withHltbSections, hltbGridType, hookHltbShelf, withHltbOverlay, refreshHltbData, installLunaMenu, bootLunaMenu };
});
