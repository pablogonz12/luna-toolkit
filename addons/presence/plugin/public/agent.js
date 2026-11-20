/* SLS Presence shared SteamClient control agent, injected by Luna into SharedJSContext only. */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root && root.SteamClient) api.bootAgent(root);
})(typeof window !== 'undefined' ? window : null, function () {
  'use strict';
  const KEY = 'sls-presence-v1';
  const MAX_APPID = 4294967295;
  // The helper is a local placeholder that keeps a "playing" entry alive while
  // the real game runs. It must never be the game itself and must never be
  // user-visible. `/usr/bin/sleep <seconds>` is guaranteed to exist on the
  // target (CachyOS/Arch, coreutils) and holds no resources.
  const HELPER = {exe: '/usr/bin/sleep', args: '86400', dir: '/usr/bin'};
  // Verified on Steam buildid 1788652215 (see docs/COMPATIBILITY.md):
  //   * AddShortcut(name, exe, args, startDir) applies the START DIR (the client
  //     chdir's into it) but does NOT make its 3rd parameter the launch
  //     arguments, and it does NOT set the visible title: the app overview
  //     shows the executable's basename instead. Passing a non-empty 3rd
  //     parameter also trips a client-side assertion
  //     ("Unexpected: browse button exe ... has arguments").
  //   * SetShortcutLaunchOptions(appid, args) is what Steam actually launches.
  //   * SetShortcutName(appid, title) is required, or friends would see "sleep".
  //   * The returned AppID is a fresh unique allocation, not a hash of the
  //     inputs: two identical calls return different ids, so it must be stored.
  const SHORTCUT_SETUP = ['SetShortcutLaunchOptions', 'SetShortcutName'];
  // Steam's IClientShortcuts has a native SetShortcutHidden, but the JS surface
  // differs per client build, so every hide strategy is probed, never assumed.
  const HIDE_STRATEGIES = ['shortcutHidden', 'appHidden', 'collectionHidden'];
  const MAX_STOP_RETRIES = 3;
  const SHORTCUT_TYPE = 1073741824;
  const STOP_RETRY_BACKOFF = 30000;
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  function parseRpc(value) {
    if (typeof value === 'string') return JSON.parse(value);
    if (typeof value?.data === 'string') return JSON.parse(value.data);
    return value;
  }
  function makeGameSelectionRestorer(w, {delay = sleep, attempts = 30} = {}) {
    const available = typeof w?.SteamUIStore?.SetRunningApp === 'function';
    return {
      available,
      async restore(original, helper, stillRunning = () => true) {
        if (!available) return false;
        // This is Steam's own "select running game" action. It reorders the
        // composition queue without raising windows, navigating, or closing the
        // Steam/QAM menus. Never install a perpetual focus-forcing timer.
        for (let attempt = 0; attempt < attempts; attempt++) {
          if (!stillRunning()) return false;
          const store = w.SteamUIStore;
          const selected = validId(store.MainRunningAppID);
          const running = Array.from(store.RunningApps || []).map(app => validId(app?.appid));
          if (selected === helper && running.includes(original)) {
            store.SetRunningApp(original);
            return validId(store.MainRunningAppID) === original;
          }
          // Do not override another game the user selected/launched meanwhile.
          if (selected && selected !== original && selected !== helper) return false;
          await delay(100);
        }
        return false;
      },
    };
  }
  function validId(value) {
    const n = Number(value);
    return Number.isSafeInteger(n) && n > 0 && n <= MAX_APPID ? n : null;
  }
  function infoIsShortcut(info) {
    return info?.app_type === SHORTCUT_TYPE;
  }
  function shortcutGameId(shortAppId) {
    const id = validId(shortAppId);
    if (!id) throw new Error('Invalid shortcut AppID');
    // Steam encodes a Non-Steam shortcut as (appid << 32) | 0x02000000. That
    // marker bit is what Steam's games-played notification skips, so a
    // placeholder is never rewritten into a store AppID.
    return ((BigInt(id) << 32n) | 0x02000000n).toString();
  }
  function cleanName(name) {
    const v = String(name || '').replace(/[\x00-\x1f\x7f]/g, '').trim();
    return v.length > 0 && v.length <= 160 ? v : null;
  }
  // Session-time label for the placeholder-name enrichment. Sessions shorter
  // than five minutes stay plain so a quick launch is not noisy.
  function sessionLabel(elapsedMs) {
    const minutes = Math.floor((Number(elapsedMs) || 0) / 60000);
    if (minutes < 5) return '';
    if (minutes < 60) return minutes + 'm';
    const hours = Math.floor(minutes / 60), rest = minutes % 60;
    return rest ? hours + 'h ' + rest + 'm' : hours + 'h';
  }
  // Non-reversible account fingerprint (FNV-1a). The SteamID64 itself must never
  // reach our state file or any log; only this 8-hex digest is stored.
  function fnv1a(value) {
    let h = 0x811c9dc5;
    const s = String(value == null ? '' : value);
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h.toString(16).padStart(8, '0');
  }
  function readAccountKey(w) {
    const identity = readAccountIdentity(w);
    return identity ? identity.key : null;
  }
  // Which account is Steam signed into? On the tested build (Steam buildid
  // 1788652215) SharedJSContext exposes no SteamID at all:
  // SteamClient.User.GetSteamID is undefined, loginStore.m_vecLoginUsers entries
  // carry only account/persona names, and a shallow scan of all 362 window
  // properties finds no 64-bit id. The account *name* is therefore the only
  // usable signal, hashed with a domain prefix so the two sources can never be
  // confused. The digest is stored locally and never logged; it is an
  // account-scope fingerprint, not a credential.
  function readAccountIdentity(w) {
    try {
      const raw = w?.SteamClient?.User?.GetSteamID?.();
      const text = typeof raw === 'string' ? raw : raw?.ConvertTo64BitString?.() ?? raw?.steamID ?? null;
      const value = text == null ? null : String(text);
      if (value && /^\d{17,20}$/.test(value)) {
        return {key: fnv1a('steamid:' + value), source: 'steamid'};
      }
    } catch (_) { /* API absent or threw */ }
    try {
      const name = w?.loginStore?.m_strAccountName;
      if (typeof name === 'string' && name.length >= 2 && name.length <= 64) {
        return {key: fnv1a('account:' + name), source: 'account-name'};
      }
    } catch (_) { /* not available */ }
    return null;
  }
  function readState(storage) {
    try {
      const state = JSON.parse(storage.getItem(KEY) || '{}');
      const owned = {};
      const running = {};
      const source = state.owned && typeof state.owned === 'object' ? state.owned : {};
      const used = new Set();
      // A hand-edited or corrupted ledger must never map a game onto itself,
      // nor let two games claim the same placeholder: that would let a stop or
      // a cleanup target a shortcut belonging to something else.
      for (const [original, shortcut] of Object.entries(source)) {
        const game = validId(original);
        const placeholder = validId(shortcut);
        if (!game || !placeholder || game === placeholder || used.has(placeholder)) continue;
        used.add(placeholder);
        owned[game] = placeholder;
      }
      const active = state.running && typeof state.running === 'object' ? state.running : {};
      for (const [original, shortcut] of Object.entries(active)) {
        const game = validId(original);
        if (game && owned[game] === validId(shortcut)) running[game] = owned[game];
      }
      return {
        enabled: state.enabled === true,
        owned,
        running,
        account: typeof state.account === 'string' && /^[0-9a-f]{8}$/.test(state.account) ? state.account : null,
        accountSource: typeof state.accountSource === 'string' && /^[a-z-]{4,16}$/.test(state.accountSource)
          ? state.accountSource : null,
      };
    } catch (_) { return {enabled: false, owned: {}, running: {}, account: null, accountSource: null}; }
  }

  // ---- capability probing -------------------------------------------------
  // Everything below only inspects, never invokes. Steam's client APIs are
  // undocumented and drift between builds, so a missing method must be a
  // reported gap, not a runtime TypeError.
  function probeCapabilities(w) {
    const apps = w?.SteamClient?.Apps;
    const sessions = w?.SteamClient?.GameSessions;
    const missing = [];
    for (const method of ['AddShortcut', 'RemoveShortcut', 'RunGame', 'TerminateApp']) {
      if (typeof apps?.[method] !== 'function') missing.push('Apps.' + method);
    }
    // Without these two the placeholder would run without a duration or show up
    // in the friends list under the executable's name ("sleep").
    for (const method of SHORTCUT_SETUP) {
      if (typeof apps?.[method] !== 'function') missing.push('Apps.' + method);
    }
    if (typeof sessions?.RegisterForAppLifetimeNotifications !== 'function')
      missing.push('GameSessions.RegisterForAppLifetimeNotifications');
    const hide = makeHidingStrategy(w);
    if (!hide.available) missing.push('Library hiding API');
    if (typeof w?.Millennium?.callServerMethod !== 'function')
      missing.push('Luna RPC');
    return {ok: missing.length === 0, missing, hide: hide.strategy, hideVerified: hide.verified};
  }
  // Contract probe: arity and shape of the calls we depend on. `length` is the
  // declared parameter count of a JS function and is the only contract signal a
  // client bundle exposes before the call itself. It is reported, never trusted
  // blindly: call sites still pass a superset of the documented arguments.
  function probeContracts(w) {
    const apps = w?.SteamClient?.Apps;
    const collections = w?.collectionStore || w?.SteamUIStore?.collectionStore;
    const arity = fn => (typeof fn === 'function' ? fn.length : null);
    return {
      addShortcut: arity(apps?.AddShortcut),
      removeShortcut: arity(apps?.RemoveShortcut),
      runGame: arity(apps?.RunGame),
      terminateApp: arity(apps?.TerminateApp),
      setShortcutHidden: arity(apps?.SetShortcutHidden),
      setShortcutName: arity(apps?.SetShortcutName),
      setShortcutLaunchOptions: arity(apps?.SetShortcutLaunchOptions),
      setAppHidden: arity(apps?.SetAppHidden),
      setAppsAsHidden: arity(collections?.SetAppsAsHidden),
      isHidden: arity(collections?.BIsHidden),
      overview: arity((w?.appStore || w?.SteamUIStore?.AppStore)?.GetAppOverviewByAppID),
      steamId: arity(w?.SteamClient?.User?.GetSteamID),
    };
  }
  // Chooses, and reports, the hide path actually used for this client build.
  // `collectionHidden` is preferred when a read-back exists because hidden-ness
  // is then *verifiable* (BIsHidden) instead of merely assumed.
  function makeHidingStrategy(w) {
    const apps = w?.SteamClient?.Apps;
    const collections = w?.collectionStore || w?.SteamUIStore?.collectionStore;
    const canReadBack = typeof collections?.BIsHidden === 'function';
    const strategies = {
      shortcutHidden: typeof apps?.SetShortcutHidden === 'function'
        ? async id => { await apps.SetShortcutHidden(id, true); return true; } : null,
      appHidden: typeof apps?.SetAppHidden === 'function'
        ? async id => { await apps.SetAppHidden(id, true); return true; } : null,
        collectionHidden: typeof collections?.SetAppsAsHidden === 'function'
         ? async id => {
          // Read-back also makes steady-state reconciliation read-only. Do not
          // rewrite Steam's collections every five seconds for an already hidden helper.
          if (canReadBack && collections.BIsHidden(id) === true) return true;
          // Steam's own library calls this with an array; older builds took a
          // scalar. Try the documented shape first, then the tolerant one.
          try { await collections.SetAppsAsHidden([id], true); }
          catch (e) {
            if (typeof collections.SetAppsAsHidden !== 'function') throw e;
            await collections.SetAppsAsHidden(id, true);
          }
          if (canReadBack && collections.BIsHidden(id) !== true)
            throw new Error('Steam did not confirm the placeholder as hidden');
          return true;
        } : null,
    };
    const order = canReadBack
      ? ['collectionHidden', 'shortcutHidden', 'appHidden']
      : ['shortcutHidden', 'appHidden', 'collectionHidden'];
    const name = order.find(k => strategies[k]);
    if (!name) return {available: false, strategy: null, verified: false, hide: async () => false};
    return {
      available: true,
      strategy: name,
      verified: name === 'collectionHidden' && canReadBack,
      hide: strategies[name],
    };
  }

  // Decides what a recreated SharedJSContext should do with the facts it can
  // still observe. Pure, so it is fully testable: no Steam and no /proc here.
  //   activate: a manifest game is running and must (re)gain its placeholder
  //   orphaned: a placeholder helper is alive but its game is gone
  // Lua has no distinct empty-array type: an empty table crosses the RPC as
  // `{}`, so every list must be normalised before it is iterated. Getting this
  // wrong turns "no games are running" into a thrown TypeError.
  function asIdList(value) {
    return Array.isArray(value) ? value.map(validId).filter(Boolean) : [];
  }
  function validSnapshot(value) {
    const list = v => Array.isArray(v) ? v.every(id => validId(id) !== null)
      : v && typeof v === 'object' && Object.keys(v).length === 0;
    return !!value && value.success !== false && value.complete !== false && list(value.games) && list(value.helpers);
  }
  function planReconciliation({games, helpers, injected, owned} = {}) {
    const liveGames = new Set(asIdList(games));
    const liveHelpers = new Set(asIdList(helpers));
    const injectedSet = new Set(asIdList(injected));
    const ownedMap = owned && typeof owned === 'object' ? owned : {};
    const managed = new Set(asIdList(Object.values(ownedMap)));
    const activate = [...liveGames].filter(id => injectedSet.has(id) && !managed.has(id));
    const orphaned = [];
    for (const [original, raw] of Object.entries(ownedMap)) {
      const game = validId(original);
      const placeholder = validId(raw);
      // Only a helper we recorded AND that is still alive can be an orphan. A
      // missing marker means the process is gone; Steam already cleaned up.
      if (!game || !placeholder || !liveHelpers.has(placeholder)) continue;
      if (!liveGames.has(game)) orphaned.push(game);
    }
    return {activate, orphaned};
  }
  class PresenceController {
    constructor({apps, storage, overview, hideShortcut, delay = sleep, accountKey = null, accountSource = null,
                 helpersAllowed = true, helperPauseReason = '',
                  restoreGameSelection = null, probeProcesses = null,
                 now = () => Date.now()}) {
      this.apps = apps;
      this.storage = storage;
      this.overview = overview;
      this.hideShortcut = hideShortcut || (() => false);
      this.delay = delay;
      this.now = now;
      this.accountKey = accountKey;
      this.accountSource = accountSource;
      this.state = readState(storage);
      this.injected = new Set();
      this.active = new Set();
      this.inflight = new Set();
      this.pendingStarts = new Map();
      this.pendingStops = new Map();
      this.createdHere = new Set();
      this.missingGames = new Map();
      this.stopRetryAt = new Map();
      this.cleanupErrors = new Map();
      this.snapshotError = null;
      this.probeProcesses = probeProcesses;
      this.started = new Set();
      this.stopRequested = new Set();
      this.stopFailures = new Map();
      this.accountMismatch = false;
      this.error = null;
      this.helpersAllowed = helpersAllowed !== false;
      this.helperPauseReason = this.helpersAllowed ? '' : String(helperPauseReason);
      this.restoreGameSelection = restoreGameSelection;
      this.selectionRestores = new Map();
      this.restoredSelections = 0;
      // Shortcut enrichment: while a game runs, its hidden placeholder's name
      // gains a session-time suffix like "(42m)". The backend owns the toggle;
      // sync() applies it. startedAt/nameApplied limit Steam calls to actual
      // text changes and allow restoring the plain title on stop.
      this.sessionTime = true;
      this.startedAt = new Map();
      this.nameApplied = new Map();
      this.onchange = () => {};
    }
    persist() {
      this.storage.setItem(KEY, JSON.stringify(this.state));
      this.onchange();
    }
    updateInjected(appids) {
      this.injected = new Set((Array.isArray(appids) ? appids : []).map(validId).filter(Boolean));
      // A manifest can be removed while a game is running. That must not
      // strand a helper, even if Steam never emits another event for its AppID.
      const expired = [...this.active].filter(id => !this.injected.has(id));
      for (const id of expired) this.active.delete(id);
      this.onchange();
      return expired;
    }
    setEnabled(enabled) {
      this.state.enabled = enabled === true;
      this.persist();
    }
    async setHelperPolicy(session) {
      const missingSelection = session?.requiresGameSelection === true && typeof this.restoreGameSelection !== 'function';
      this.helpersAllowed = session?.helpersAllowed !== false && !missingSelection;
      this.helperPauseReason = this.helpersAllowed ? '' : String(session?.reason || (missingSelection
        ? 'Presence helper paused: Steam game-selection control is unavailable in this Gamescope session.'
        : 'Presence helpers paused for this session.'));
      // Includes recorded helpers from an old context, not only new starts.
      // end() targets the owned helper GameID, never the original game.
      if (!this.helpersAllowed) await this.stopAll();
    }
    async restoreSelection(appid, helper) {
      if (typeof this.restoreGameSelection !== 'function') return false;
      if (this.selectionRestores.has(appid)) return this.selectionRestores.get(appid);
      const pending = Promise.resolve().then(() => this.restoreGameSelection(appid, helper,
        () => this.helpersAllowed && this.active.has(appid) && this.state.enabled && this.state.running[appid] === helper));
      this.selectionRestores.set(appid, pending);
      try {
        const restored = await pending;
        if (restored) this.restoredSelections++;
        return restored;
      } catch (error) {
        this.error = 'Could not restore the real game selection: ' + String(error?.message || error);
        return false;
      } finally {
        if (this.selectionRestores.get(appid) === pending) this.selectionRestores.delete(appid);
      }
    }
    isManagedShortcut(id) {
      return Object.values(this.state.owned).some(v => validId(v) === validId(id));
    }
    titleOf(appid) {
      const info = this.overview(appid);
      return info?.display_name || info?.name || info?.strDisplayName || null;
    }
    // The placeholder must by definition be a different AppID than the game it
    // stands in for. Enforced at action time, not only when the ledger loads.
    placeholderFor(appid) {
      const id = validId(this.state.owned[appid]);
      return id && id !== validId(appid) ? id : null;
    }
    // Fail closed when the Steam account changed: shortcut AppIDs are only
    // unique per account, so acting on a foreign ledger could target an
    // unrelated shortcut. Records are preserved for the account that owns them.
    guardAccount() {
      if (this.identityAmbiguous === true) {
        this.error = 'Steam account identity is ambiguous; refusing to modify presence shortcuts.';
        return false;
      }
      if (!this.accountKey) {
        if (Object.values(this.state.owned).some(id => !this.createdHere.has(id))) {
          this.error = 'Cannot verify the account owning saved presence shortcuts; cleanup deferred.';
          return false;
        }
        return true;
      }
      // Different identity domains cannot prove ownership of a saved ledger.
      // Only an empty ledger can safely adopt a new source automatically.
      if (this.state.account && this.state.accountSource !== this.accountSource) {
        if (Object.keys(this.state.owned).length) {
          this.accountMismatch = true;
          this.error = 'Steam account identity source changed; shortcut ownership cannot be verified.';
          return false;
        }
        this.state.account = this.accountKey;
        this.state.accountSource = this.accountSource;
        this.persist();
        return true;
      }
      if (!this.state.account) {
        this.state.account = this.accountKey;
        this.state.accountSource = this.accountSource;
        this.persist();
        return true;
      }
      if (this.state.account !== this.accountKey) {
        this.accountMismatch = true;
        this.error = 'Steam account changed since these shortcuts were created; '
          + 'refusing to reuse, stop or remove them.';
        return false;
      }
      return true;
    }
    async awaitOverview(appid) {
      for (let i = 0; i < 25; i++) {
        try { if (this.overview(appid)) return true; } catch (_) { /* Steam store not ready */ }
        await this.delay(100);
      }
      throw new Error('Steam shortcut is not registered in the app store: ' + appid);
    }
    async onLifetime(notification) {
      const appid = validId(notification?.unAppID);
      if (!appid) return;
      if (this.isManagedShortcut(appid)) {
        if (notification.bRunning === true) {
          const original = Object.keys(this.state.running).map(validId)
            .find(id => this.state.running[id] === appid);
          if (original) await this.restoreSelection(original, appid);
        }
        return;
      }
      // Stop events are authoritative even after the manifest disappears.
      // The previous filter silently ignored those stops, leaving helpers alive.
      if (notification.bRunning === true) {
        if (!this.injected.has(appid)) return;
        this.stopRequested.delete(appid);
        this.active.add(appid);
        if (this.state.enabled) await this.begin(appid);
      } else if (notification.bRunning === false) {
        if (!this.injected.has(appid) && !this.active.has(appid) &&
            !this.state.running[appid]) return;
        // Remember the stop even if no helper exists yet: a start whose
        // AddShortcut is still in flight must not launch afterwards.
        this.stopRequested.add(appid);
        this.active.delete(appid);
        await this.end(appid);
      }
      this.onchange();
    }
    async hide(id) {
      // This is library hiding, NOT Steam's "Mark as private" feature.
      // Fail closed: do not run a visible activity shortcut if hiding fails.
      await this.awaitOverview(id);
      if (!this.guardAccount()) throw new Error(this.error);
      const info = this.overview(id);
      if (!infoIsShortcut(info) && !(this.createdHere.has(id) && info?.app_type === undefined))
        throw new Error('Cannot hide an unverified Non-Steam shortcut');
      const ok = await this.hideShortcut(id);
      if (ok !== true) throw new Error('Cannot hide the internal placeholder. Activity launch cancelled.');
    }
    // Make the placeholder actually launch our helper and actually present the
    // game's name. Both are re-applied on every reuse, so a shortcut that Steam
    // or the user edited is repaired instead of trusted.
    async configure(id, name) {
      const apps = this.apps;
      if (!this.guardAccount()) throw new Error(this.error);
      if (typeof apps.SetShortcutLaunchOptions === 'function') {
        try { await apps.SetShortcutLaunchOptions(id, HELPER.args); }
        catch (e) { throw new Error('Cannot set helper launch options: ' + String(e?.message || e)); }
      } else {
        throw new Error('Apps.SetShortcutLaunchOptions is unavailable; the helper would start with no duration');
      }
      if (typeof apps.SetShortcutName === 'function') {
        if (!this.guardAccount()) throw new Error(this.error);
        try { await apps.SetShortcutName(id, name || ''); } catch (_) { /* verified below */ }
      }
      // Verify what Steam will actually publish: the title is the whole point of
      // this addon, so a placeholder Steam refuses to rename must not be used.
      for (let attempt = 0; attempt < 20; attempt++) {
        const actual = cleanName(this.titleOf(id));
        if (!name || actual === name) return true;
        if (attempt === 0 && typeof apps.SetShortcutName === 'function') {
          if (!this.guardAccount()) throw new Error(this.error);
          try { await apps.SetShortcutName(id, name); } catch (_) { /* reported below */ }
        }
        await this.delay(100);
      }
      throw new Error('Steam did not adopt the placeholder title "' + String(name)
        + '" (it reports "' + String(cleanName(this.titleOf(id))) + '")');
    }
    async begin(appid) {
      const stopping = this.pendingStops.get(appid);
      if (stopping) await stopping;
      if (this.stopFailures.has(appid)) return;
      if (!this.state.enabled || !this.active.has(appid) || this.stopRequested.has(appid) ||
          !this.helpersAllowed || this.inflight.has(appid) || this.started.has(appid) || !this.injected.has(appid)) return;
      if (!this.guardAccount()) return;
      // Publish the pending launch so a concurrent stop cannot run before RunGame.
      const pending = this._begin(appid);
      this.pendingStarts.set(appid, pending);
      try { await pending; }
      finally { if (this.pendingStarts.get(appid) === pending) this.pendingStarts.delete(appid); }
      // Creation can finish after a stop/disable or fail before RunGame. The
      // allocation is journalled already, so retire it instead of leaving it
      // hidden (or visible in Recent Games) for an unrelated future session.
      if (!this.started.has(appid) || this.stopRequested.has(appid) ||
          !this.active.has(appid) || !this.helpersAllowed || !this.state.enabled) await this.end(appid);
    }
    async _begin(appid) {
      this.inflight.add(appid);
      let newId = null;
      try {
        // Reuse an existing hidden shortcut first. An already-created
        // placeholder carries the right name, so the title lookup is only
        // needed when a new shortcut really has to be created.
        let id = this.placeholderFor(appid);
        if (this.state.owned[appid] && !id) throw new Error('Invalid helper ownership mapping');
        if (id) {
          // Reuse an existing hidden shortcut so the Library stays uncluttered.
          // Steam allocates shortcut AppIDs uniquely and at random (verified:
          // two identical AddShortcut calls returned different ids), so a live
          // AppID recorded in our own ledger cannot plausibly be an unrelated
          // entry. If Steam no longer knows it, the record is dropped and a
          // fresh placeholder is created; if it does, it is repaired in
          // configure() rather than replaced, so no orphan is ever left behind.
          try { await this.awaitOverview(id); }
          catch (_) {
            // The previous shortcut no longer exists (e.g. deleted manually).
            delete this.state.owned[appid];
            this.persist();
            id = null;
          }
          if (id && !infoIsShortcut(this.overview(id)))
            throw new Error('Saved AppID is not a verified Non-Steam shortcut');
        }
        if (!id) {
          const name = cleanName(this.titleOf(appid));
          if (!name) throw new Error('No valid Steam title for AppID ' + appid);
          // Steam creates a Library shortcut first. It can briefly appear before
          // the Steam client registers the overview and accepts the hide call.
          // There is no guaranteed invisible shortcut-creation API.
          //
          // The 3rd argument is deliberately empty; the helper's duration is
          // applied through SetShortcutLaunchOptions in configure() below.
          newId = validId(await this.apps.AddShortcut(name, HELPER.exe, '', HELPER.dir));
          if (!newId || newId === appid) throw new Error('Steam did not create a valid shortcut');
          id = newId;
          this.createdHere.add(id);
          this.state.owned[appid] = id;
          this.persist();
          if (this.storage.flush) await this.storage.flush();
        }
        await this.configure(id, cleanName(this.titleOf(appid)));
        await this.hide(id);
        if (!this.state.owned[appid]) {
          this.state.owned[appid] = id;
          this.persist();
        }
        // A stop arrived while the shortcut was being created: the game is
        // already gone, so the placeholder must not be launched at all.
        if (this.stopRequested.has(appid)) {
          return;
        }
        if (!this.helpersAllowed || !this.active.has(appid) || !this.state.enabled || !this.guardAccount()) return;
        // Ensure the ownership record is durable before any helper launch.
        if (this.storage.flush) await this.storage.flush();
        // A policy change can arrive during the storage/configuration awaits.
        if (!this.helpersAllowed || !this.active.has(appid) || !this.state.enabled) return;
        // The real app was started by Steam already. Never start it again.
        this.started.add(appid);
        this.state.running[appid] = id;
        this.persist();
        try {
          if (this.storage.flush) await this.storage.flush();
          if (!this.helpersAllowed || !this.active.has(appid) || !this.state.enabled || !this.guardAccount()) {
            this.started.delete(appid);
            delete this.state.running[appid];
            this.persist();
            return;
          }
          await this.apps.RunGame(shortcutGameId(id), '', -1, 100);
          this.startedAt.set(appid, this.now());
          this.nameApplied.delete(appid);
          await this.restoreSelection(appid, id);
        } catch (e) {
          this.started.delete(appid);
          // RunGame may have started the process before its reply failed. Keep
          // the durable running record until stop confirmation, not just a reply.
          throw e;
        }
      } catch (err) {
        this.error = String(err?.message || err);
        // begin() retires failed allocations after pendingStarts is released.
        // Never discard ownership merely because rollback itself can fail.
      } finally {
        this.inflight.delete(appid);
        this.onchange();
      }
    }
    async end(appid) {
      appid = validId(appid);
      if (!appid) return false;
      if (this.pendingStops.has(appid)) return this.pendingStops.get(appid);
      if ((this.stopRetryAt.get(appid) || 0) > this.now()) return false;
      const pending = this._end(appid);
      this.pendingStops.set(appid, pending);
      try { return await pending; }
      finally { if (this.pendingStops.get(appid) === pending) this.pendingStops.delete(appid); }
    }
    async _end(appid) {
      // If a lifetime stop arrives while AddShortcut/RunGame is in flight,
      // wait until it completes. Otherwise TerminateApp can run too early.
      const pending = this.pendingStarts.get(appid);
      if (pending) { try { await pending; } catch (_) { /* _begin reports its own error */ } }
      const id = this.placeholderFor(appid);
      if (!id) return true;
      if (!this.guardAccount()) return false;
      if (!this.createdHere.has(id) && !this.accountKey) {
        this.error = 'Cannot verify the account owning a saved presence shortcut; cleanup deferred.';
        return false;
      }
      let removedOwnership = false;
      try {
        const info = this.overview(id);
        if (info && !infoIsShortcut(info) && !(this.createdHere.has(id) && info.app_type === undefined))
          throw new Error('Saved AppID is not a verified Non-Steam shortcut');
        const snapshot = this.probeProcesses ? await this.probeProcesses({
          fresh: !!pending || this.started.has(appid) || this.state.running[appid] === id,
        }) : null;
        const known = validSnapshot(snapshot);
        if (this.probeProcesses && !known) throw new Error('Complete process snapshot unavailable; cleanup deferred');
        const verifiedLive = known && asIdList(snapshot.helpers).includes(id);
        if (known && !verifiedLive && asIdList(snapshot.games).includes(id))
          throw new Error('Mapped shortcut is running an unverified process; cleanup deferred');
        // RunGame can acknowledge before its reaper appears in /proc. A local
        // launch intent still needs termination and fresh exit confirmation.
        const localLaunch = this.started.has(appid) ||
          (this.createdHere.has(id) && this.state.running[appid] === id);
        const alive = known ? verifiedLive || localLaunch : !!(localLaunch || this.state.running[appid]);
        if (alive) {
          if (!this.guardAccount()) return false;
          const target = this.overview(id);
          if (target && !infoIsShortcut(target) && !(this.createdHere.has(id) && target.app_type === undefined))
            throw new Error('Shortcut type changed during cleanup; termination deferred');
          if (this.state.running[appid] !== id) {
            this.state.running[appid] = id;
            this.persist();
          }
          await this.apps.TerminateApp(shortcutGameId(id), false);
        }
        // A complete snapshot that already proves absence is confirmation. A
        // termination, however, always needs a fresh post-TerminateApp probe.
        if (this.probeProcesses && alive) {
          let stopped = false;
          for (let attempt = 0; attempt < 10; attempt++) {
            const current = await this.probeProcesses({fresh: true});
            if (!validSnapshot(current)) break;
            if (!asIdList(current.helpers).includes(id) && !asIdList(current.games).includes(id)) {
              stopped = true;
              break;
            }
            await this.delay(100);
          }
          if (!stopped) throw new Error('Helper exit could not be confirmed; shortcut retained');
        }
        this.started.delete(appid);
        if (this.state.running[appid] !== undefined) {
          delete this.state.running[appid];
          this.persist();
        }
        this.startedAt.delete(appid);
        if (info) {
          if (!this.guardAccount()) return false;
          const current = this.overview(id);
          if (current && !infoIsShortcut(current) && !(this.createdHere.has(id) && current.app_type === undefined))
            throw new Error('Shortcut type changed during cleanup; removal deferred');
          await this.apps.RemoveShortcut(id);
          for (let attempt = 0; attempt < 10 && this.overview(id); attempt++) await this.delay(100);
          if (this.overview(id)) throw new Error('Steam did not confirm shortcut removal');
        }
        delete this.state.owned[appid];
        removedOwnership = true;
        this.persist();
        if (this.storage.flush) await this.storage.flush();
        // Only clear retry/error state once the removal intent is durable.
        this.nameApplied.delete(appid);
        this.createdHere.delete(id);
        this.stopFailures.delete(appid);
        this.stopRetryAt.delete(appid);
        const previous = this.cleanupErrors.get(appid);
        this.cleanupErrors.delete(appid);
        if (this.error === previous) this.error = this.cleanupErrors.values().next().value || null;
        this.onchange();
        return true;
      } catch (err) {
        if (removedOwnership) this.state.owned[appid] = id;
        // Back off, but NEVER forget a possibly live process or an allocation
        // whose removal failed. The periodic sweep can retry it after recovery.
        const attempts = (this.stopFailures.get(appid) || 0) + 1;
        this.stopFailures.set(appid, attempts);
        if (attempts >= MAX_STOP_RETRIES) {
          this.stopRetryAt.set(appid, this.now() + STOP_RETRY_BACKOFF);
        }
        this.error = 'Presence cleanup deferred for helper ' + id + ' (attempt ' + attempts + '): '
          + String(err?.message || err);
        this.cleanupErrors.set(appid, this.error);
        // A fallback while native removal is unavailable, never a substitute
        // for removal (the hidden collection does not cover every Recent shelf).
        if (infoIsShortcut(this.overview(id))) {
          try { await this.hide(id); } catch (_) { /* keep the original failure */ }
        }
        this.onchange();
        return false;
      }
    }
    // Cosmetic: put the plain game title back after an enriched run. Failures
    // are ignored on purpose; a display name is not worth marking the agent
    // unwell, and the next launch repairs it anyway.
    async restoreName(appid, id) {
      if (!this.sessionTime || !this.nameApplied.has(appid)) return;
      this.nameApplied.delete(appid);
      const base = cleanName(this.titleOf(appid));
      if (!base) return;
      try { await this.apps.SetShortcutName(id, base); } catch (_) { /* cosmetic */ }
    }
    async stopAll() {
      for (const original of Object.keys(this.state.owned).map(Number)) {
        // An in-flight allocation retires itself when begin() unwinds. Awaiting
        // its own pending start here would deadlock a policy change in setup.
        if (this.inflight.has(original) && !this.state.running[original]) continue;
        await this.end(original);
      }
    }
    async recoverUncleanExit() {
      // A previous SteamUI instance can die without seeing the game's stop.
      // Stop only previously recorded helper GameIDs, never the original game.
      await this.stopAll();
      // Make the cleared records durable before we start acting on new events.
      if (this.storage.flush) await this.storage.flush();
    }
    async cleanupOwned() {
      if (!this.guardAccount()) return;
      await this.stopAll();
    }
    async reconcile(snapshot) {
      if (!validSnapshot(snapshot)) {
        this.missingGames.clear();
        this.snapshotError = 'Complete process snapshot unavailable; automatic cleanup deferred.';
        this.onchange();
        return;
      }
      this.snapshotError = null;
      if (!this.guardAccount()) return;
      const games = new Set(asIdList(snapshot.games));
      const helpers = new Set(asIdList(snapshot.helpers));
      const managed = new Set(Object.values(this.state.owned).map(validId));
      for (const original of new Set([...this.active, ...Object.keys(this.state.owned).map(Number)])) {
        if (this.inflight.has(original) || this.pendingStops.has(original)) continue;
        if (games.has(original) && this.injected.has(original) && !this.stopRequested.has(original)) {
          this.missingGames.delete(original);
          this.active.add(original);
          if (!this.state.enabled || !this.helpersAllowed) {
            await this.end(original);
            continue;
          }
          if (this.cleanupErrors.has(original) && !await this.end(original)) continue;
          const id = this.placeholderFor(original);
          if (id && helpers.has(id)) {
            if (!infoIsShortcut(this.overview(id))) {
              await this.end(original); // reports the type guard without modifying the app
              continue;
            }
            // Adopt an existing live helper, do not RunGame it a second time.
            this.started.add(original);
            if (this.state.running[original] !== id) { this.state.running[original] = id; this.persist(); }
            await this.hide(id);
          } else {
            this.started.delete(original);
            if (this.state.running[original] !== undefined) {
              delete this.state.running[original];
              this.persist();
            }
            await this.begin(original);
          }
        } else {
          // Start notifications can precede the reaper's /proc entry. Require
          // two negative snapshots for a tracked game; explicit stop is immediate.
          if (!games.has(original) && this.active.has(original) && !this.stopRequested.has(original)) {
            const missing = (this.missingGames.get(original) || 0) + 1;
            this.missingGames.set(original, missing);
            if (missing < 2) continue;
          }
          this.active.delete(original);
          await this.end(original);
        }
      }
      for (const original of games) {
        if (managed.has(original) || !this.injected.has(original) || this.stopRequested.has(original)) continue;
        this.active.add(original);
        if (this.state.enabled && this.helpersAllowed) await this.begin(original);
      }
      // A stop marker protects against a stale positive snapshot immediately
      // after a stop event. Once absence is observed it must not block every
      // future session whose start notification happens to be lost.
      for (const original of this.stopRequested) {
        if (!games.has(original) && !this.pendingStarts.has(original) && !this.pendingStops.has(original))
          this.stopRequested.delete(original);
      }
      for (const original of this.missingGames.keys()) {
        if (!this.active.has(original)) this.missingGames.delete(original);
      }
      this.onchange();
    }
    // Enrichment: stamp running placeholders with the session time. Only text
    // that actually changed is sent to Steam; failures are cosmetic.
    async refreshNames() {
      if (!this.sessionTime || !this.state.enabled || !this.guardAccount()) return;
      for (const original of new Set([...this.started, ...Object.keys(this.state.running).map(Number)])) {
        const id = this.placeholderFor(original);
        if (!id || !this.state.running[original]) continue;
        const started = this.startedAt.get(original);
        if (!started) continue;
        const label = sessionLabel(this.now() - started);
        if (!label) continue;
        const base = cleanName(this.titleOf(original));
        if (!base) continue;
        const next = cleanName(base + ' (' + label + ')');
        if (!next || this.nameApplied.get(original) === next) continue;
        try {
          await this.apps.SetShortcutName(id, next);
          this.nameApplied.set(original, next);
        } catch (e) {
          console.warn('[SLS Presence] could not enrich name for ' + original + ':', e);
        }
      }
    }
    // Compact, log-safe snapshot for the backend/panel. No SteamIDs, no paths.
    report() {
      return {
        active: this.active.size,
        healthy: !this.error && !this.snapshotError && this.cleanupErrors.size === 0,
        helpersPaused: !this.helpersAllowed,
        helperPauseReason: this.helperPauseReason,
        restoredSelections: this.restoredSelections,
        error: this.error || this.snapshotError || this.cleanupErrors.values().next().value || '',
        activeIds: [...this.active].slice(0, 12),
        accountMismatch: this.accountMismatch,
        accountSource: this.accountSource || '',
        identityAmbiguous: this.identityAmbiguous === true,
        reconciledActivate: this.reconciled?.activate || 0,
        reconciledOrphaned: this.reconciled?.orphaned || 0,
        owned: Object.keys(this.state.owned).length,
        running: Object.keys(this.state.running).length,
      };
    }
  }

  function bootAgent(w) {
    if (w.__SlsPresenceAgent) return;
    const probe = probeCapabilities(w);
    if (!probe.ok) {
      const message = 'Missing Steam/Luna APIs: ' + probe.missing.join(', ');
      console.warn('[SLS Presence]', message);
      if (typeof w?.Millennium?.callServerMethod === 'function') {
        Promise.resolve(w.Millennium.callServerMethod('luna', 'SlsPresenceReport',
          {raw: JSON.stringify({healthy: false, error: message, active: 0})})).catch(() => {});
      }
      return;
    }
    w.__SlsPresenceAgent = true;
    const contracts = probeContracts(w);
    const hiding = makeHidingStrategy(w);
    const selection = makeGameSelectionRestorer(w);
    const identity = readAccountIdentity(w);
    const rpc = async (method, params = {}) => {
      if (!w.Millennium?.callServerMethod) throw new Error('Luna RPC unavailable in SharedJSContext');
      const raw = await w.Millennium.callServerMethod('luna', method, params);
      const parsed = parseRpc(raw);
      if (parsed?.success === false) throw new Error(parsed.error || method + ' failed');
      return parsed;
    };
    const steam = w.SteamClient;
    if (!steam.Apps || !steam.GameSessions?.RegisterForAppLifetimeNotifications) return;
    const overview = id => w.appStore?.GetAppOverviewByAppID?.(id) ||
      w.SteamUIStore?.AppStore?.GetAppOverviewByAppID?.(id) ||
      (titles.has(String(id)) ? {display_name: titles.get(String(id))} : null);
    let controller, lastReport = 0, lastSignature = '';
    const titles = new Map();
    let pending = Promise.resolve(), writeError = null, probing = null;
    // Process snapshot from the backend: the only way to learn what is still
    // running after a context recreation (Steam exposes no snapshot API).
    const probeProcesses = async () => {
      try {
        const snapshot = await rpc('SlsPresenceProbeProcesses');
        if (!snapshot || snapshot.success === false || !validSnapshot(snapshot)) return null;
        return {games: snapshot.games, helpers: snapshot.helpers, complete: true};
      } catch (_) { return null; }
    };
    const readProcesses = ({fresh = false} = {}) => {
      // Share simultaneous read-only requests, never settled results. Exit
      // confirmation bypasses sharing so a pre-termination scan cannot be used.
      if (fresh) return probeProcesses();
      if (!probing) probing = probeProcesses().finally(() => { probing = null; });
      return probing;
    };
    const storage = {
      raw: null,
      getItem(k) { return this.raw; },
      setItem(k, value) {
        this.raw = value;
        pending = pending.catch(() => {}).then(() => rpc('SlsPresencePut', {raw: value})).then(
          result => { writeError = null; return result; },
          error => { writeError = error; throw error; });
        // Observe asynchronous failure immediately without swallowing it for
        // flush(): allocation/removal acknowledgements must still reject.
        pending.catch(() => {});
      },
      flush() { return pending; }
    };
    let syncing = null;
    function sync() {
      // Boot and the interval can overlap while RPCs/cleanup are pending.
      // Share one sync so the same recorded helper is never stopped twice.
      if (!syncing) syncing = syncOnce().finally(() => { syncing = null; });
      return syncing;
    }
    async function syncOnce() {
      try {
        const status = await rpc('SlsPresenceGet');
        // A transient disk/RPC failure must recover even if no game event ever
        // causes another persist. Retry only the latest serialized ledger.
        if (writeError) storage.setItem(KEY, storage.raw);
        for (const [id, name] of Object.entries(status.titles || {})) titles.set(id, name);
        // The Lua backend derives the account from Steam's own loginusers.vdf,
        // which is the only reliable signal on this client build. It takes
        // precedence over the in-page fallback and is re-read every sync.
        const account = status.identity?.key
          ? {key: String(status.identity.key), source: String(status.identity.source || 'loginusers')}
          : identity;
        if (!controller) {
          storage.raw = JSON.stringify(status.state || {});
          controller = new PresenceController({
            apps: steam.Apps,
            storage,
            overview,
            hideShortcut: hiding.hide,
            accountKey: account ? account.key : null,
            accountSource: account ? account.source : null,
            helpersAllowed: status.session?.helpersAllowed !== false,
            helperPauseReason: status.session?.reason || '',
            restoreGameSelection: selection.available ? selection.restore : null,
            probeProcesses: readProcesses,
          });
          controller.updateInjected(status.apps);
          controller.identityAmbiguous = status.identity?.ambiguous === true;
          controller.sessionTime = status.state?.sessionTime !== false;
          await controller.setHelperPolicy(status.session);
          // Recover what the destroyed context could not carry over: a game that
          // is still running (its presence is re-established through the existing
          // hidden placeholder) and a helper whose game is already gone. Without
          // this, any mid-session SharedJSContext recreation silently loses
          // presence for a game that is still being played.
          const alive = await readProcesses();
          if (alive) {
            const plan = planReconciliation({
              games: alive.games, helpers: alive.helpers,
              injected: [...controller.injected], owned: controller.state.owned,
            });
            await controller.reconcile(alive);
            controller.reconciled = {activate: plan.activate.length, orphaned: plan.orphaned.length};
          } else await controller.reconcile(null);
        } else {
          if (account && (controller.accountKey !== account.key || controller.accountSource !== account.source)) {
            controller.accountKey = account.key;
            controller.accountSource = account.source;
          }
          controller.identityAmbiguous = status.identity?.ambiguous === true;
          await controller.setHelperPolicy(status.session);
          const removed = controller.updateInjected(status.apps);
          for (const id of removed) await controller.end(id);
          if (controller.state.enabled !== status.state.enabled) {
            controller.setEnabled(status.state.enabled);
            if (!status.state.enabled) await controller.stopAll();
          }
          controller.sessionTime = status.state.sessionTime !== false;
          // A missed lifetime notification must not leave shortcuts behind until
          // the next Steam restart. Only complete snapshots permit a sweep.
          const alive = await readProcesses();
          await controller.reconcile(alive);
          if (controller.state.enabled) {
            for (const id of controller.active) {
              if (!controller.started.has(id)) await controller.begin(id);
            }
          }
        }
        if ((status.state.cleanup || 0) > 0) {
          await controller.cleanupOwned();
          await storage.flush();
          if (!Object.keys(controller.state.owned).length) {
            await rpc('SlsPresenceAcknowledgeCleanup');
          }
        }
        await storage.flush();
        const report = controller.report();
        // A health *change* (new error, account guard tripped, a recovery) is
        // reported immediately; the 5 s cadence only bounds the steady-state
        // heartbeat.
        const signature = JSON.stringify(report);
        if (Date.now() - lastReport > 5000 || signature !== lastSignature) {
          await rpc('SlsPresenceReport', {raw: JSON.stringify({
            ...report, contracts, hideStrategy: hiding.strategy, hideVerified: hiding.verified,
          })});
          lastReport = Date.now();
          lastSignature = signature;
        }
      } catch (e) {
        lastSignature = ''; // ensure recovery is reported even within a heartbeat
        console.warn('[SLS Presence] sync failed:', e);
        try {
          await rpc('SlsPresenceReport', {raw: JSON.stringify({
            active: controller?.active?.size || 0,
            healthy: false,
            error: String(e?.message || e).slice(0, 250)
          })});
        } catch (_) { /* Luna transport may itself be down */ }
      }
    }
    // Register notifications as soon as the controller is ready. The returned
    // promise is handed back so a caller (and tests) can await one full
    // start/stop cycle instead of polling.
    const sub = steam.GameSessions.RegisterForAppLifetimeNotifications(n => {
      if (!controller) return Promise.resolve();
      return Promise.resolve(controller.onLifetime(n)).catch(e => console.error('[SLS Presence]', e));
    });
    if (!sub) console.warn('[SLS Presence] App lifetime subscription unavailable');
    sync();
    w.setInterval(sync, 5000);
    // Session-time enrichment runs on its own slower cadence so a rename never
    // waits on (or blocks) the status sync.
    w.setInterval(() => {
      if (controller) controller.refreshNames().catch(e => console.warn('[SLS Presence] name refresh failed', e));
    }, 60000);
  }
  return {
    PresenceController, validId, shortcutGameId, cleanName, parseRpc, makeGameSelectionRestorer,
    probeCapabilities, probeContracts, makeHidingStrategy, readAccountKey,
    readAccountIdentity, planReconciliation, fnv1a, sessionLabel, HELPER, HIDE_STRATEGIES, bootAgent,
  };
});
