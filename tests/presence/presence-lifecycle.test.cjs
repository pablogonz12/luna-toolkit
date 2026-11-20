/* End-to-end lifecycle tests for the injected agent.
 *
 * These drive the real bootAgent() against a fake SteamClient + a fake Luna
 * backend, so the wire contract (JSON strings over callServerMethod, the {raw}
 * argument shape, the 5 s sync loop) is exercised rather than mocked away.
 * They still prove nothing about the real client; see docs/TEST_PLAN.md.
 */
const {test} = require('node:test');
const assert = require('node:assert/strict');
const agent = require('../../addons/presence/plugin/public/agent.js');
const {PresenceController, shortcutGameId, probeCapabilities, probeContracts,
  makeHidingStrategy, readAccountKey, readAccountIdentity, planReconciliation,
  fnv1a, sessionLabel, validId, HELPER} = agent;

const GAME = 2101960;              // "Cronos: The New Dawn": manifest-managed, installed
const GAME_TITLE = 'Cronos: The New Dawn';
const OTHER_GAME = 620;            // a normal owned game: never touched

// ---------------------------------------------------------------- fake Steam
function fakeWorld(opts = {}) {
  const log = [];
  const overviews = new Map([[GAME, {display_name: GAME_TITLE, appid: GAME}]]);
  const hidden = new Set();
  const running = new Set();
  const realGames = new Set();
  const launchOptions = new Map();
  const selectionOrder = opts.selection ? [GAME] : [];
  let nextShortcut = opts.firstShortcutId || 3000000000;
  const state = {
    enabled: false, sessionTime: true, owned: {}, running: {}, cleanup: 0, account: null,
  };
  const titles = {};
  const reports = [];
  let stored = JSON.stringify(state);

  const apps = {
    // Models the verified client behaviour: the returned AppID is a unique
    // allocation, the visible name initially comes from the executable, and the
    // 3rd argument does NOT become the helper's runtime arguments.
    AddShortcut: async (name, exe, args, dir) => {
      log.push({op: 'add', name, exe, args, dir});
      if (opts.failAdd) throw new Error('AddShortcut rejected');
      const id = nextShortcut++;
      overviews.set(id, {display_name: String(exe).split('/').pop(), appid: id});
      return id;
    },
    SetShortcutName: (id, name) => {
      log.push({op: 'setName', id, name});
      if (opts.failRename) throw new Error('SetShortcutName rejected');
      const ov = overviews.get(id) || {appid: id};
      overviews.set(id, {...ov, display_name: name});
    },
    SetShortcutLaunchOptions: (id, value) => {
      log.push({op: 'setOptions', id, value});
      if (opts.failOptions) throw new Error('SetShortcutLaunchOptions rejected');
      launchOptions.set(id, value);
    },
    RemoveShortcut: async id => {
      log.push({op: 'remove', id});
      if (opts.failRemove) throw new Error('RemoveShortcut rejected');
      overviews.delete(id);
      hidden.delete(id);
    },
    RunGame: async (...args) => {
      log.push({op: 'run', gameid: args[0]});
      if (opts.failRun) throw new Error('RunGame rejected');
      running.add(args[0]);
      if (opts.selection) {
        const id = Number(BigInt(args[0]) >> 32n);
        selectionOrder.unshift(id);
      }
    },
    TerminateApp: async (...args) => {
      log.push({op: 'terminate', gameid: args[0]});
      if (opts.failTerminate) throw new Error('Steam busy');
      running.delete(args[0]);
    },
  };
  if (opts.hideApi !== 'none') {
    apps.SetShortcutHidden = async (id, value) => {
      log.push({op: 'setShortcutHidden', id, value});
      if (opts.failHide) throw new Error('cannot hide');
      if (value) hidden.add(id); else hidden.delete(id);
    };
  }
  const collections = {
    SetAppsAsHidden: async (ids, value) => {
      const list = Array.isArray(ids) ? ids : [ids];
      log.push({op: 'setAppsAsHidden', ids: list, value});
      if (opts.failHide) throw new Error('cannot hide');
      for (const id of list) { if (value) hidden.add(id); else hidden.delete(id); }
    },
    BIsHidden: id => hidden.has(id),
  };
  const steamId = opts.steamId === undefined ? '76561198000000000' : opts.steamId;

  const registry = {
    SlsPresenceGet: () => JSON.stringify({
      success: true, state: JSON.parse(stored), apps: opts.apps || [GAME], titles,
      session: opts.session,
      runtime: reports.at(-1) || {active: 0, healthy: false},
    }),
    SlsPresencePut: raw => {
      const obj = JSON.parse(raw);
      const current = JSON.parse(stored);
      // The real backend lets the UI own enabled/sessionTime/cleanup while the
      // agent only replaces the ledger; mirror that here so a persist cannot
      // reset a setting the test just changed.
      stored = JSON.stringify({...obj,
        enabled: current.enabled, sessionTime: current.sessionTime, cleanup: current.cleanup});
      return JSON.stringify({success: true});
    },
    SlsPresenceSetEnabled: value => {
      const parsed = JSON.parse(stored);
      stored = JSON.stringify({...parsed, enabled: value});
      return JSON.stringify({success: true, enabled: value});
    },
    SlsPresenceReport: raw => { reports.push(JSON.parse(raw)); return JSON.stringify({success: true}); },
    SlsPresenceProbeProcesses: () => {
      const helpers = [...running].map(gid => Number(BigInt(gid) >> 32n));
      return JSON.stringify({success: true, complete: true, games: [...realGames, ...helpers], helpers});
    },
    SlsPresenceSetTitles: raw => { Object.assign(titles, JSON.parse(raw)); return JSON.stringify({success: true}); },
    SlsPresenceRequestCleanup: () => JSON.stringify({success: true, cleanup: 1}),
    SlsPresenceAcknowledgeCleanup: () => JSON.stringify({success: true}),
  };
  const timers = [];
  const win = {
    SteamClient: {
      Apps: apps,
      GameSessions: {RegisterForAppLifetimeNotifications: cb => { win.lifetime = cb; return 1; }},
      User: {GetSteamID: typeof steamId === 'function' ? steamId : () => steamId},
    },
    appStore: {GetAppOverviewByAppID: id => {
      const o = overviews.get(id);
      return o ? {...o, app_type: o.app_type ?? (id >= 2147483648 ? 1073741824 : 1)} : null;
    }},
    collectionStore: opts.collectionStore === false ? undefined : collections,
    Millennium: {callServerMethod: async (_plugin, method, params = {}) => {
      if (!registry[method]) return JSON.stringify({success: false, error: 'unknown method: ' + method});
      return registry[method](params.raw, params);
    }},
    setInterval: (fn, ms) => { timers.push({fn, ms}); return timers.length; },
  };
  if (opts.selection) win.SteamUIStore = {
    get MainRunningAppID() { return selectionOrder[0]; },
    get RunningApps() { return selectionOrder.map(appid => overviews.get(appid) || {appid}); },
    SetRunningApp(id) {
      log.push({op: 'select', id});
      const index = selectionOrder.indexOf(id);
      if (index < 0) return;
      selectionOrder.splice(index, 1);
      selectionOrder.unshift(id);
    },
  };
  return {
    win, log, overviews, hidden, running, realGames, reports, timers, launchOptions, selectionOrder,
    get state() { return JSON.parse(stored); },
    set state(value) { stored = JSON.stringify(value); },
    deliver: notification => {
      if (notification.bRunning) realGames.add(notification.unAppID);
      else realGames.delete(notification.unAppID);
      return win.lifetime(notification);
    },
    // One periodic sync plus a bounded drain: bootAgent() already kicks a sync
    // that may still be in flight, and the storage writes are promise-chained.
    tick: async (rounds = 10) => {
      for (const t of timers) await t.fn();
      for (let i = 0; i < rounds; i++) await flushed();
    },
    gameId: id => shortcutGameId(id),
  };
}

const flushed = () => new Promise(resolve => setImmediate(resolve));

test('unsupported Gamescope selection controls pause helpers without changing the preference', async () => {
  const w = fakeWorld({session: {helpersAllowed: true, requiresGameSelection: true}});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  await w.tick();
  assert.equal(w.log.filter(x => ['add', 'run', 'remove'].includes(x.op)).length, 0);
  assert.equal(w.state.enabled, true, 'desktop preference must be preserved');
  assert.equal(w.reports.at(-1).helpersPaused, true);
  assert.match(w.reports.at(-1).helperPauseReason, /selection control is unavailable/);
  assert.equal(w.reports.at(-1).active, 1, 'the real game remains tracked');
});

test('stable running helpers do not repeat native hide mutations or ledger writes', async () => {
  const w = fakeWorld();
  let writes = 0;
  const inner = w.win.Millennium.callServerMethod;
  w.win.Millennium.callServerMethod = async (...args) => {
    if (args[1] === 'SlsPresencePut') writes++;
    return inner(...args);
  };
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win); await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  const hides = () => w.log.filter(x => x.op === 'setAppsAsHidden').length;
  const before = {hides: hides(), writes};
  for (let i = 0; i < 6; i++) await w.tick();
  assert.equal(hides(), before.hides, 'read-back avoids repeated Steam collection writes');
  assert.equal(writes, before.writes, 'no unchanged ledger is rewritten');
  w.hidden.clear();
  await w.tick();
  assert.equal(hides(), before.hides + 1, 'a genuinely lost hidden state is repaired');
});

test('wire stop tombstones allow a later session recovered without its start notification', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win); await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  await w.deliver({unAppID: GAME, bRunning: false});
  await w.tick();
  w.realGames.add(GAME);
  await w.tick();
  assert.equal(w.log.filter(x => x.op === 'run').length, 2);
});

test('Steam Machine keeps the real game first and the live presence helper second', async () => {
  const w = fakeWorld({selection: true, session: {helpersAllowed: true, requiresGameSelection: true}});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  await w.tick();
  const helper = w.state.owned[GAME];
  assert.deepEqual(w.selectionOrder, [GAME, helper]);
  assert.equal(w.running.has(shortcutGameId(helper)), true, 'presence must keep running');
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 0);
  assert.equal(w.state.enabled, true);
  assert.equal(w.reports.at(-1).helpersPaused, false);
});

test('Steam Machine startup stops a previously recorded helper but never the real game', async () => {
  const helper = 3000000000;
  const w = fakeWorld({session: {helpersAllowed: false}});
  w.state = {...w.state, enabled: true, owned: {[GAME]: helper}, running: {[GAME]: helper}};
  w.overviews.set(helper, {display_name: GAME_TITLE, appid: helper});
  w.running.add(shortcutGameId(helper));
  agent.bootAgent(w.win);
  await w.tick();
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 1);
  assert.equal(w.log.find(x => x.op === 'terminate').gameid, shortcutGameId(helper));
  assert.equal(w.log.filter(x => x.op === 'run').length, 0);
  assert.equal(w.state.enabled, true);
  assert.deepEqual(w.state.running, {});
});

test('a session policy change stops only the helper and prevents its recreation', async () => {
  const session = {helpersAllowed: true};
  const w = fakeWorld({session});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  assert.equal(w.log.filter(x => x.op === 'run').length, 1);
  session.helpersAllowed = false;
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 1);
  assert.equal(w.log.filter(x => x.op === 'run').length, 1);
  assert.equal(w.state.enabled, true);
});

// ---------------------------------------------------- 1. normal Steam launch
test('a normal Steam launch creates exactly one hidden placeholder and one helper', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed(); await flushed();

  const adds = w.log.filter(x => x.op === 'add');
  const runs = w.log.filter(x => x.op === 'run');
  const hides = w.log.filter(x => x.op === 'setAppsAsHidden');
  assert.equal(adds.length, 1, 'exactly one placeholder shortcut');
  assert.equal(runs.length, 1, 'exactly one helper launch');
  assert.equal(hides.length, 1, 'the placeholder is hidden');
  // The placeholder is a hidden sleep process, never the game executable, and
  // it is configured the way this Steam build actually honours.
  assert.equal(adds[0].exe, HELPER.exe);
  assert.equal(adds[0].args, '', 'the 3rd AddShortcut argument is not a launch argument');
  assert.equal(adds[0].dir, HELPER.dir, 'the start directory is the one that is applied');
  assert.deepEqual(w.launchOptions.get(3000000000), HELPER.args,
    'the duration is applied through SetShortcutLaunchOptions');
  const renamed = w.log.filter(x => x.op === 'setName');
  assert.equal(renamed.at(-1).name, GAME_TITLE, 'the visible title is applied explicitly');
  assert.equal(w.overviews.get(3000000000).display_name, GAME_TITLE);
  // The helper is launched by the Non-Steam GameID, not the store AppID.
  assert.equal(runs[0].gameid, shortcutGameId(3000000000));
  assert.notEqual(runs[0].gameid, String(GAME));
  assert.equal(w.hidden.size, 1);
  // The real game is never launched by us.
  assert.ok(!w.log.some(x => x.gameid === String(GAME)), 'the real AppID is never launched');
});

test('a game without a manifest is ignored', async () => {
  const w = fakeWorld({apps: [GAME]});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: OTHER_GAME, bRunning: true});
  await flushed();
  assert.equal(w.log.length, 0);
});

// ------------------------------------------------- 2. AppID -> title resolution
test('an unresolvable title fails closed and leaves no visible shortcut', async () => {
  const w = fakeWorld();
  w.overviews.clear();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed(); await flushed();
  assert.equal(w.log.filter(x => x.op === 'add').length, 0, 'no placeholder without a name');
  assert.equal(w.log.filter(x => x.op === 'run').length, 0);
});

test('the shell-published title map is used when the app store has no overview', async () => {
  const w = fakeWorld();
  w.overviews.clear();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  // The panel resolves names in the webview and pushes them to the backend.
  w.overviews.set(GAME, undefined);
  const viaTitles = new PresenceController({
    apps: w.win.SteamClient.Apps,
    storage: {getItem: () => null, setItem: () => {}},
    overview: id => (String(id) === String(GAME) ? {display_name: GAME_TITLE} : null),
    hideShortcut: async () => true,
  });
  assert.equal(viaTitles.overview(GAME).display_name, GAME_TITLE);
});

// ------------------------------------------------- 3. creation and reuse
test('every completed session removes its placeholder before another is allocated', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed(); await flushed();
  await w.deliver({unAppID: GAME, bRunning: false});
  await flushed(); await flushed();
  await w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed(); await flushed();
  assert.equal(w.log.filter(x => x.op === 'add').length, 2, 'fresh temporary shortcut per session');
  assert.equal(w.log.filter(x => x.op === 'run').length, 2, 'helper started per session');
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 1);
  assert.equal(w.hidden.size, 1, 'only the current session helper remains');
});

test('a placeholder Steam no longer knows is replaced, not trusted', async () => {
  // Controller level: a short injected delay makes the reuse-miss retry loop
  // deterministic instead of waiting out the production 2.5 s backoff.
  const overviews = new Map([[GAME, {display_name: GAME_TITLE}]]);
  const log = [];
  let next = 3000000000;
  const c = new PresenceController({
    apps: {
      AddShortcut: async (name, exe, args, dir) => {
        const id = next++;
        log.push({op: 'add', id, name, exe, args, dir});
        overviews.set(id, {display_name: String(exe).split('/').pop()});
        return id;
      },
      SetShortcutName: (id, name) => {
        log.push({op: 'setName', id, name});
        overviews.set(id, {...(overviews.get(id) || {}), display_name: name});
      },
      SetShortcutLaunchOptions: () => {},
      RunGame: async (...a) => log.push({op: 'run', gameid: a[0]}),
      TerminateApp: async () => {},
      RemoveShortcut: async () => {},
    },
    storage: {getItem: () => null, setItem: () => {}, flush: async () => {}},
    overview: id => overviews.get(id) || null,
    hideShortcut: async () => true,
    delay: async () => {},
  });
  c.updateInjected([GAME]);
  c.setEnabled(true);
  await c.onLifetime({unAppID: GAME, bRunning: true});
  assert.equal(log.filter(x => x.op === 'add').length, 1);
  // The user deletes the shortcut in Steam; the record is now a lie.
  overviews.delete(3000000000);
  await c.onLifetime({unAppID: GAME, bRunning: false});
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const adds = log.filter(x => x.op === 'add');
  assert.equal(adds.length, 2, 'a missing placeholder is replaced');
  assert.equal(adds[1].args, '', 'the replacement keeps the verified argument contract');
  assert.equal(c.state.owned[GAME], 3000000001);
  assert.equal(overviews.get(3000000001).display_name, GAME_TITLE);
});

test('a saved idle placeholder is retired before the next session, even if renamed', async () => {
  // Steam allocates shortcut AppIDs uniquely and at random, so a live AppID in
  // our own ledger is our own shortcut. Renaming it back keeps the Library free
  // of orphans, and no removal or termination is ever attempted on it.
  const w = fakeWorld();
  w.state = {enabled: true, owned: {[GAME]: 3000000000}, running: {}, cleanup: 0, account: null};
  w.overviews.set(3000000000, {display_name: 'Renamed By Hand', appid: 3000000000});
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  for (let i = 0; i < 8; i++) await flushed();
  assert.equal(w.log.filter(x => x.op === 'add').length, 1, 'the next session creates a temporary placeholder');
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 0);
  assert.equal(w.log.filter(x => x.op === 'remove').length, 1, 'the legacy entry is removed');
  assert.equal(w.overviews.get(w.state.owned[GAME]).display_name, GAME_TITLE, 'the current helper title is correct');
  assert.equal(w.state.owned[GAME], 3000000000, 'the record is unchanged');
  assert.equal(w.log.filter(x => x.op === 'run').length, 1);
});

test('a placeholder Steam refuses to rename is never launched', async () => {
  // The title is the entire point of the addon: if Steam keeps reporting the
  // executable name, publishing that as activity would be worse than nothing.
  const w = fakeWorld({failRename: true, apps: [GAME]});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  assert.equal(w.log.filter(x => x.op === 'run').length, 0, 'no activity under the wrong name');
  assert.equal(w.log.filter(x => x.op === 'remove').length, 1, 'the unusable shortcut is rolled back');
  assert.deepEqual(w.state.owned, {}, 'nothing is recorded as owned');
});

// ------------------------------------------------- 4. hidden state
test('hiding is verified through the collection read-back when available', async () => {
  const strategy = makeHidingStrategy({
    SteamClient: {Apps: {SetShortcutHidden: () => {}}},
    collectionStore: {SetAppsAsHidden: async () => {}, BIsHidden: () => false},
  });
  assert.equal(strategy.strategy, 'collectionHidden');
  assert.equal(strategy.verified, true);
  await assert.rejects(() => strategy.hide(42), /did not confirm/);

  const confirmed = makeHidingStrategy({
    SteamClient: {Apps: {}},
    collectionStore: {SetAppsAsHidden: async () => {}, BIsHidden: () => true},
  });
  assert.equal(await confirmed.hide(42), true);
});

test('the native per-shortcut hide is used when the collection store is absent', async () => {
  let seen = null;
  const strategy = makeHidingStrategy({
    SteamClient: {Apps: {SetShortcutHidden: (id, value) => { seen = [id, value]; }}},
  });
  assert.equal(strategy.strategy, 'shortcutHidden');
  assert.equal(strategy.verified, false);
  assert.equal(await strategy.hide(7), true);
  assert.deepEqual(seen, [7, true]);
});

test('the collection API is called with an array first, then a scalar', async () => {
  const calls = [];
  let hidden = false;
  const strategy = makeHidingStrategy({
    SteamClient: {Apps: {}},
    collectionStore: {
      SetAppsAsHidden: async (ids) => {
        calls.push(ids);
        if (Array.isArray(ids)) throw new Error('wrong shape');
        hidden = true;
      },
      BIsHidden: () => hidden,
    },
  });
  await strategy.hide(9);
  assert.deepEqual(calls, [[9], 9]);
});

test('concurrent active stops require independent fresh pre/post-termination scans', async () => {
  const w = fakeWorld({apps: [GAME, OTHER_GAME]});
  w.overviews.set(OTHER_GAME, {display_name: 'Portal 2', appid: OTHER_GAME});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win); await w.tick();
  await Promise.all([w.deliver({unAppID: GAME, bRunning: true}),
    w.deliver({unAppID: OTHER_GAME, bRunning: true})]);
  const inner = w.win.Millennium.callServerMethod;
  let release, scans = 0;
  const gate = new Promise(r => { release = r; });
  w.win.Millennium.callServerMethod = async (...args) => {
    if (args[1] === 'SlsPresenceProbeProcesses' && ++scans === 1) await gate;
    return inner(...args);
  };
  const stops = [w.deliver({unAppID: GAME, bRunning: false}),
    w.deliver({unAppID: OTHER_GAME, bRunning: false})];
  await flushed();
  const initial = scans;
  release(); await Promise.all(stops);
  assert.equal(initial, 3, 'active stops bypass sharing and one can finish while the other probe waits');
  assert.equal(scans, 4, 'each active stop has fresh pre/post-termination scans');
  assert.deepEqual(w.state.owned, {});
  await w.tick();
  assert.equal(scans, 5, 'settled snapshots are not cached for later syncs');
});

test('concurrent idle cleanup shares only its in-flight read-only scan', async () => {
  const w = fakeWorld({apps: [GAME, OTHER_GAME]});
  const owned = {[GAME]: 3000000000, [OTHER_GAME]: 3000000001};
  w.state = {...w.state, owned};
  for (const id of Object.values(owned)) w.overviews.set(id, {display_name: 'Old helper'});
  const inner = w.win.Millennium.callServerMethod;
  let unavailable = true, release, scans = 0;
  const gate = new Promise(r => { release = r; });
  w.win.Millennium.callServerMethod = async (...args) => {
    if (args[1] === 'SlsPresenceProbeProcesses') {
      if (unavailable) return JSON.stringify({success: false});
      if (++scans === 1) await gate;
    }
    return inner(...args);
  };
  agent.bootAgent(w.win); await w.tick();
  unavailable = false;
  const stops = [w.deliver({unAppID: GAME, bRunning: false}),
    w.deliver({unAppID: OTHER_GAME, bRunning: false})];
  await flushed();
  const initial = scans;
  release(); await Promise.all(stops);
  assert.equal(initial, 1);
  assert.equal(scans, 1);
  assert.deepEqual(w.state.owned, {});
  await w.tick();
  assert.equal(scans, 2, 'a subsequent sync takes a new snapshot');
});

test('a failed health report does not suppress the next successful healthy report', async () => {
  const w = fakeWorld();
  const inner = w.win.Millennium.callServerMethod;
  let fail = true;
  w.win.Millennium.callServerMethod = async (...args) => {
    if (args[1] === 'SlsPresenceReport' && JSON.parse(args[2].raw).healthy && fail) {
      fail = false;
      throw Error('temporary reporting failure');
    }
    return inner(...args);
  };
  agent.bootAgent(w.win);
  for (let i = 0; i < 10; i++) await flushed();
  assert.equal(w.reports.at(-1).healthy, false);
  await w.tick();
  assert.equal(w.reports.at(-1).healthy, true);
});

test('transient asynchronous journal failures are reported and retried without a new game event', async () => {
  const w = fakeWorld();
  const inner = w.win.Millennium.callServerMethod;
  let fail = true, attempts = 0;
  w.win.Millennium.callServerMethod = async (...args) => {
    if (args[1] === 'SlsPresencePut') {
      attempts++;
      if (fail) throw Error('temporary journal failure');
    }
    return inner(...args);
  };
  agent.bootAgent(w.win);
  for (let i = 0; i < 10; i++) await flushed();
  assert.equal(w.reports.at(-1).healthy, false);
  fail = false;
  await w.tick();
  assert.equal(w.reports.at(-1).healthy, true);
  assert.equal(w.state.account, fnv1a('steamid:76561198000000000'));
  assert.equal(attempts, 2);
});

test('no hiding API at all is a reported gap', () => {
  const probe = probeCapabilities({
    SteamClient: {Apps: {}, GameSessions: {}},
    Millennium: {callServerMethod() {}},
  });
  assert.equal(probe.ok, false);
  assert.ok(probe.missing.includes('Library hiding API'));
});

// ------------------------------------------------- 5. failed creation / hiding
test('a failed hide removes the new placeholder and never launches a helper', async () => {
  const w = fakeWorld({failHide: true});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed(); await flushed();
  assert.equal(w.log.filter(x => x.op === 'add').length, 1);
  assert.equal(w.log.filter(x => x.op === 'run').length, 0, 'no visible activity is published');
  assert.equal(w.log.filter(x => x.op === 'remove').length, 1, 'the visible shortcut is rolled back');
  assert.deepEqual(w.state.owned, {}, 'nothing is recorded as owned');
});

test('a failed AddShortcut is reported without touching other shortcuts', async () => {
  const w = fakeWorld({failAdd: true});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed();
  assert.equal(w.log.filter(x => x.op === 'remove').length, 0);
  const report = await w.reports;
  assert.ok(report.length > 0);
});

// ------------------------------------------------- 6. immediate closure
test('closing the game during the placeholder handshake never launches a helper', async () => {
  const w = fakeWorld();
  let releaseAdd;
  const gate = new Promise(resolve => { releaseAdd = resolve; });
  const originalAdd = w.win.SteamClient.Apps.AddShortcut;
  w.win.SteamClient.Apps.AddShortcut = async (...args) => {
    const id = await originalAdd(...args);
    await gate;
    return id;
  };
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed();
  w.deliver({unAppID: GAME, bRunning: false});
  releaseAdd();
  await flushed(); await flushed(); await flushed();
  assert.equal(w.log.filter(x => x.op === 'run').length, 0, 'no helper for an already closed game');
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 0, 'nothing to terminate');
  assert.equal(w.hidden.size, 0, 'the cancelled allocation is removed');
});

// ------------------------------------------------- 7. concurrent launches
test('two concurrent game launches each get their own placeholder', async () => {
  const w = fakeWorld({apps: [GAME, 377160]});
  w.overviews.set(377160, {display_name: 'Fallout 4', appid: 377160});
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  await Promise.all([
    (async () => { w.deliver({unAppID: GAME, bRunning: true}); })(),
    (async () => { w.deliver({unAppID: 377160, bRunning: true}); })(),
  ]);
  for (let i = 0; i < 8; i++) await flushed();
  assert.equal(w.log.filter(x => x.op === 'add').length, 2);
  assert.equal(w.log.filter(x => x.op === 'run').length, 2);
  const state = w.state;
  assert.notEqual(state.owned[GAME], state.owned[377160], 'shortcuts are distinct');
});

// ------------------------------------------------- 8. Luna reconnect
test('a second agent boot in the same context is a no-op', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  await flushed(); await flushed(); await flushed();
  assert.equal(w.log.filter(x => x.op === 'run').length, 1);
});

test('a reconnected context removes saved idle entries and starts one fresh helper', async () => {
  const w = fakeWorld();
  w.state = {enabled: true, owned: {[GAME]: 3000000000}, running: {}, cleanup: 0, account: null};
  w.overviews.set(3000000000, {display_name: GAME_TITLE, appid: 3000000000});
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  for (let i = 0; i < 6; i++) await flushed();
  assert.equal(w.log.filter(x => x.op === 'add').length, 1, 'legacy idle placeholder was retired');
  assert.equal(w.log.filter(x => x.op === 'run').length, 1);
  assert.equal(w.log.filter(x => x.op === 'run')[0].gameid, shortcutGameId(3000000000));
});

// ------------------------------------------------- 9. Steam restart
test('after a Steam restart a stale record with no process is removed without relaunching the game', async () => {
  const w = fakeWorld();
  w.state = {enabled: true, owned: {[GAME]: 3000000000}, running: {[GAME]: 3000000000}, cleanup: 0, account: null};
  w.overviews.set(3000000000, {display_name: GAME_TITLE, appid: 3000000000});
  agent.bootAgent(w.win);
  await w.tick();
  assert.deepEqual(w.log.filter(x => x.op === 'terminate'), [], 'the process was already gone');
  assert.equal(w.log.filter(x => x.op === 'remove').length, 1);
  assert.equal(w.log.filter(x => x.op === 'run').length, 0, 'the real game is never relaunched');
  assert.equal(w.state.running[GAME], undefined, 'the stale record is cleared');
});

// ------------------------------------------------- 10. manifest deleted mid-game
test('deleting the manifest while the game runs stops the helper', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  for (let i = 0; i < 4; i++) await flushed();
  // The user removes config/<manifest>/2101960.lua; the backend stops listing it.
  w.win.Millennium.callServerMethod = (() => {
    const inner = w.win.Millennium.callServerMethod;
    return async (plugin, method, params = {}) => {
      if (method === 'SlsPresenceGet') {
        const payload = JSON.parse(await inner(plugin, method, params));
        payload.apps = [];
        return JSON.stringify(payload);
      }
      return inner(plugin, method, params);
    };
  })();
  await w.tick();
  for (let i = 0; i < 4; i++) await flushed();
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 1, 'helper stopped with the game');
  assert.equal(w.state.running[GAME], undefined);
});

// ------------------------------------------------- 11. orphaned helper cleanup
test('a stop that keeps failing is retried a bounded number of times and reported', async () => {
  const calls = [];
  const c = new PresenceController({
    apps: {
      TerminateApp: async (...args) => { calls.push(args); throw new Error('Steam busy'); },
      RemoveShortcut: async () => {},
    },
    storage: {getItem: () => null, setItem: () => {}, flush: async () => {}},
    overview: () => ({display_name: GAME_TITLE, app_type: 1073741824}),
    accountKey: 'deadbeef',
    hideShortcut: async () => true,
    delay: async () => {},
  });
  c.state.owned = {[GAME]: 3000000000};
  c.state.running = {[GAME]: 3000000000};
  c.started.add(GAME);
  for (let i = 0; i < 6; i++) await c.end(GAME);
  assert.equal(calls.length, 3, 'retries stop at the bound');
  assert.equal(c.state.running[GAME], 3000000000, 'a retry limit never forgets a possibly live helper');
  assert.match(c.error, /cleanup deferred/);
  assert.equal(c.state.owned[GAME], 3000000000, 'ownership is kept for manual review');
});

test('cleanup never removes a shortcut whose helper may still run', async () => {
  const removed = [];
  const c = new PresenceController({
    apps: {TerminateApp: async () => { throw new Error('Steam busy'); }, RemoveShortcut: async id => removed.push(id)},
    storage: {getItem: () => null, setItem: () => {}, flush: async () => {}},
    overview: () => ({}),
    hideShortcut: async () => true,
    delay: async () => {},
  });
  c.state.owned = {[GAME]: 3000000000};
  c.state.running = {[GAME]: 3000000000};
  c.started.add(GAME);
  await c.cleanupOwned();
  assert.deepEqual(removed, []);
  assert.equal(c.state.owned[GAME], 3000000000);
});

// ------------------------------------------------- 12. incorrect shortcut IDs
test('malformed shortcut AppIDs are rejected everywhere', () => {
  for (const bad of [0, -1, 1.5, 2 ** 32, MAXID + 1, 'abc', null, undefined, '', NaN, Infinity]) {
    assert.equal(validId(bad), null, 'rejected: ' + String(bad));
  }
  assert.equal(validId('2101960'), 2101960);
});
const MAXID = 4294967295;

test('a helper GameID is always a Non-Steam shortcut ID, never a store AppID', () => {
  const gameid = shortcutGameId(GAME);
  assert.equal(BigInt(gameid) & 0x02000000n, 0x02000000n, 'shortcut marker bit set');
  assert.equal(BigInt(gameid) >> 32n, BigInt(GAME));
  assert.throws(() => shortcutGameId(0), /Invalid shortcut AppID/);
});

test('the ledger is sanitised on load: no self-mapping, no id collisions', () => {
  const c = new PresenceController({
    apps: {},
    storage: {
      getItem: () => JSON.stringify({
        owned: {[GAME]: GAME, 620: 3000000001, 730: 3000000001},
        running: {[GAME]: GAME, 620: 3000000001},
      }),
      setItem: () => {},
    },
    overview: () => null,
    hideShortcut: async () => true,
  });
  // A game mapped onto its own AppID would let us terminate the real game.
  assert.equal(c.state.owned[GAME], undefined, 'self-mapping dropped');
  assert.equal(c.state.owned[620], 3000000001);
  assert.equal(c.state.owned[730], undefined, 'colliding shortcut id dropped');
  assert.equal(c.state.running[GAME], undefined);
  assert.equal(c.state.running[620], 3000000001);
});

test('a self-mapping can never reach TerminateApp or RemoveShortcut', async () => {
  const terminated = [];
  const removed = [];
  const c = new PresenceController({
    apps: {
      TerminateApp: async gid => terminated.push(gid),
      RemoveShortcut: async id => removed.push(id),
    },
    storage: {getItem: () => null, setItem: () => {}, flush: async () => {}},
    overview: () => ({display_name: GAME_TITLE}),
    hideShortcut: async () => true,
    delay: async () => {},
  });
  c.state.owned = {[GAME]: GAME};
  c.state.running = {[GAME]: GAME};
  c.started.add(GAME);
  await c.end(GAME);
  await c.cleanupOwned();
  assert.deepEqual(terminated, [], 'refuses to terminate the real game');
  assert.deepEqual(removed, [], 'refuses to remove the real game');
});

test('a corrupted ledger is discarded rather than trusted', () => {
  const storage = {getItem: () => '{not json', setItem: () => {}};
  const c = new PresenceController({
    apps: {}, storage, overview: () => null, hideShortcut: async () => true,
  });
  assert.equal(c.state.enabled, false);
  assert.deepEqual(c.state.owned, {});
  assert.equal(c.state.account, null);
  const weird = new PresenceController({
    apps: {},
    storage: {getItem: () => JSON.stringify({enabled: 'yes', owned: 7, running: null, account: 'zzz'}), setItem: () => {}},
    overview: () => null,
    hideShortcut: async () => true,
  });
  assert.equal(weird.state.enabled, false);
  assert.deepEqual(weird.state.owned, {});
  assert.equal(weird.state.account, null);
});

// ------------------------------------------------- 13. account isolation
test('the account fingerprint is a one-way digest, never the SteamID', () => {
  const key = readAccountKey({SteamClient: {User: {GetSteamID: () => '76561198000000000'}}});
  assert.equal(key, fnv1a('steamid:76561198000000000'));
  assert.match(key, /^[0-9a-f]{8}$/);
  assert.ok(!key.includes('76561198'), 'the raw account id is not recoverable');
  assert.equal(readAccountKey({SteamClient: {User: {GetSteamID: () => 'nonsense'}}}), null);
  assert.equal(readAccountKey({SteamClient: {User: {GetSteamID: () => { throw new Error('nope'); }}}}), null);
  assert.equal(readAccountKey({}), null);
});

test('the guard falls back to the account name and records its source', () => {
  // Steam buildid 1788652215 exposes no SteamID in SharedJSContext, so the
  // account name is the only identity signal available.
  const identity = readAccountIdentity({SteamClient: {User: {}}, loginStore: {m_strAccountName: 'someuser'}});
  assert.equal(identity.source, 'account-name');
  assert.equal(identity.key, fnv1a('account:someuser'));
  assert.notEqual(identity.key, fnv1a('someuser'), 'the source is part of the digest domain');
  assert.equal(readAccountIdentity({SteamClient: {User: {}}, loginStore: {m_strAccountName: 'x'}}), null,
    'implausibly short names are ignored');
  assert.equal(readAccountIdentity({}), null);
  // The SteamID wins when a build does expose it.
  const both = readAccountIdentity({
    SteamClient: {User: {GetSteamID: () => '76561198000000000'}},
    loginStore: {m_strAccountName: 'someuser'},
  });
  assert.equal(both.source, 'steamid');
});

test('an empty ledger can safely adopt a different identity source', () => {
  const c = new PresenceController({
    apps: {}, storage: {getItem: () => null, setItem: () => {}, flush: async () => {}},
    overview: () => null, hideShortcut: async () => true,
    accountKey: fnv1a('steamid:76561198000000000'), accountSource: 'steamid',
  });
  c.state.account = fnv1a('account:someuser');
  c.state.accountSource = 'account-name';
  assert.equal(c.guardAccount(), true, 'a different digest domain is not a mismatch');
  assert.equal(c.state.accountSource, 'steamid');
  assert.equal(c.accountMismatch, false);
});

test('a changed Steam account blocks every mutating action', async () => {
  const w = fakeWorld({steamId: '76561198000000002'});
  w.state = {
    enabled: true, owned: {[GAME]: 3000000000}, running: {}, cleanup: 0,
    // same identity source, different account: a real mismatch
    account: fnv1a('steamid:76561198000000001'), accountSource: 'steamid',
  };
  w.overviews.set(3000000000, {display_name: GAME_TITLE, appid: 3000000000});
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  for (let i = 0; i < 6; i++) await flushed();
  assert.equal(w.log.filter(x => x.op === 'run').length, 0, 'no helper for a foreign ledger');
  assert.equal(w.log.filter(x => x.op === 'remove').length, 0, 'no foreign shortcut removal');
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 0);
  assert.equal(w.state.owned[GAME], 3000000000, 'the other account keeps its records');
  // The guard is surfaced through the next periodic report.
  await w.tick();
  for (let i = 0; i < 4; i++) await flushed();
  const report = w.reports.at(-1);
  assert.equal(report.accountMismatch, true);
  assert.match(report.error, /account changed/);
});

test('the filesystem identity from the backend takes precedence over the page', async () => {
  const w = fakeWorld({steamId: '76561198000000002'});
  w.state = {
    enabled: true, owned: {}, running: {}, cleanup: 0,
    account: fnv1a('steamid:76561198000000001'), accountSource: 'loginusers',
  };
  const inner = w.win.Millennium.callServerMethod;
  w.win.Millennium.callServerMethod = async (plugin, method, params = {}) => {
    if (method === 'SlsPresenceGet') {
      const payload = JSON.parse(await inner(plugin, method, params));
      // loginusers.vdf still says account 1: the page-side fallback must not win.
      payload.identity = {key: fnv1a('steamid:76561198000000001'), source: 'loginusers', known: 1};
      return JSON.stringify(payload);
    }
    return inner(plugin, method, params);
  };
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  for (let i = 0; i < 6; i++) await flushed();
  assert.equal(w.log.filter(x => x.op === 'run').length, 1, 'the authoritative identity keeps the ledger valid');
  assert.equal(w.reports.at(-1).accountMismatch, false);
});

test('an ambiguous multi-account identity is surfaced in the report', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  const inner = w.win.Millennium.callServerMethod;
  w.win.Millennium.callServerMethod = async (plugin, method, params = {}) => {
    if (method === 'SlsPresenceGet') {
      const payload = JSON.parse(await inner(plugin, method, params));
      payload.identity = {key: fnv1a('steamid:76561198000000000'), source: 'loginusers', known: 3, ambiguous: true};
      return JSON.stringify(payload);
    }
    return inner(plugin, method, params);
  };
  agent.bootAgent(w.win);
  await w.tick();
  assert.equal(w.reports.at(-1).identityAmbiguous, true);
});

test('an unknown account keeps the guard inactive instead of blocking the addon', async () => {
  const w = fakeWorld({steamId: undefined});
  delete w.win.SteamClient.User;
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  for (let i = 0; i < 5; i++) await flushed();
  assert.equal(w.log.filter(x => x.op === 'run').length, 1, 'a single-account machine still works');
  assert.equal(w.reports.at(-1).accountSource, '', 'the report says identity was unavailable');
});

test('the first observed account is adopted without breaking reuse', async () => {
  const c = new PresenceController({
    apps: {AddShortcut: async () => 3000000001},
    storage: {getItem: () => null, setItem: () => {}, flush: async () => {}},
    overview: () => ({display_name: GAME_TITLE}),
    hideShortcut: async () => true,
    delay: async () => {},
    accountKey: 'deadbeef',
  });
  assert.equal(c.guardAccount(), true);
  assert.equal(c.state.account, 'deadbeef');
  c.accountKey = 'feedface';
  assert.equal(c.guardAccount(), false);
  assert.equal(c.accountMismatch, true);
});

// ------------------------------------------------- 16. context recreation
test('a recreated context re-establishes presence for a game still running', async () => {
  // Recreates exactly what was observed live: SharedJSContext is destroyed
  // mid-game, so the new agent has no in-memory knowledge of the running game.
  const w = fakeWorld({apps: [GAME]});
  w.state = {enabled: true, owned: {[GAME]: 3000000000}, running: {}, cleanup: 0, account: null};
  w.overviews.set(3000000000, {display_name: GAME_TITLE, appid: 3000000000});
  const inner = w.win.Millennium.callServerMethod;
  w.win.Millennium.callServerMethod = async (plugin, method, params = {}) => {
    if (method === 'SlsPresenceProbeProcesses') {
      // The real game is alive; its helper was killed with the old context.
      return JSON.stringify({success: true, games: [GAME], helpers: []});
    }
    return inner(plugin, method, params);
  };
  agent.bootAgent(w.win);
  await w.tick();
  assert.equal(w.log.filter(x => x.op === 'add').length, 0, 'the hidden placeholder is reused');
  assert.equal(w.log.filter(x => x.op === 'run').length, 1, 'presence is republished');
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 0, 'nothing is stopped');
  assert.ok(w.reports.some(r => r.reconciledActivate === 1), 'the recovery is reported');
});

test('a helper whose game is gone is stopped even if no event was ever seen', async () => {
  const w = fakeWorld({apps: []});
  w.state = {enabled: true, owned: {[GAME]: 3000000000}, running: {[GAME]: 3000000000}, cleanup: 0, account: null};
  const inner = w.win.Millennium.callServerMethod;
  w.win.Millennium.callServerMethod = async (plugin, method, params = {}) => {
    if (method === 'SlsPresenceProbeProcesses') {
      // The helper survived, the game did not.
      return JSON.stringify({success: true, games: [], helpers: w.log.some(x => x.op === 'terminate') ? [] : [3000000000]});
    }
    return inner(plugin, method, params);
  };
  agent.bootAgent(w.win);
  await w.tick();
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 1, 'the orphan is stopped');
  assert.equal(w.log.filter(x => x.op === 'run').length, 0);
  assert.equal(w.state.running[GAME], undefined);
});

test('reconciliation is purely additive when both game and helper are alive', async () => {
  const w = fakeWorld({apps: [GAME]});
  w.state = {enabled: true, owned: {[GAME]: 3000000000}, running: {[GAME]: 3000000000}, cleanup: 0, account: null};
  w.overviews.set(3000000000, {display_name: GAME_TITLE, appid: 3000000000});
  const inner = w.win.Millennium.callServerMethod;
  w.win.Millennium.callServerMethod = async (plugin, method, params = {}) => {
    if (method === 'SlsPresenceProbeProcesses')
      return JSON.stringify({success: true, games: [GAME], helpers: [3000000000]});
    return inner(plugin, method, params);
  };
  agent.bootAgent(w.win);
  await w.tick();
  assert.equal(w.log.filter(x => x.op === 'terminate').length, 0, 'a healthy helper is left alone');
  assert.equal(w.log.filter(x => x.op === 'add').length, 0);
  assert.equal(w.log.filter(x => x.op === 'run').length, 0, 'an existing live helper is adopted, not launched twice');
  assert.equal(w.state.running[GAME], 3000000000);
});

test('a placeholder GameID is never mistaken for a manifest game', () => {
  // Steam tags both real games and shortcut helpers with AppId=; the helper id
  // appears in the game list too, and must not be activated as a game.
  const plan = planReconciliation({
    games: [GAME, 3000000000], helpers: [3000000000],
    injected: [GAME, 3000000000], owned: {[GAME]: 3000000000},
  });
  assert.deepEqual(plan.activate, [GAME]);
});

test('an uninstalled game no longer activates even if a process lingers', () => {
  const plan = planReconciliation({games: [GAME, 620], helpers: [], injected: [620], owned: {}});
  assert.deepEqual(plan.activate, [620], 'only manifest-backed ids are considered');
});

test('reconciliation ignores garbage ids from the process scan', () => {
  const plan = planReconciliation({games: [0, -5, 1.5, 'x', GAME], helpers: ['y', 3000000000], injected: [GAME], owned: {[GAME]: 3000000000}});
  assert.deepEqual(plan.activate, [GAME], 'only valid injected ids activate');
  assert.deepEqual(plan.orphaned, [], 'its game is alive, so the helper is not an orphan');
  const orphan = planReconciliation({
    games: [0, -5, 1.5, 'x'], helpers: ['y', 3000000000],
    injected: [GAME], owned: {[GAME]: 3000000000},
  });
  assert.deepEqual(orphan.orphaned, [GAME], 'a live helper without its game is an orphan');
  assert.deepEqual(orphan.activate, []);
  // A helper id that we do not own is never touched.
  const foreign = planReconciliation({games: [], helpers: [3000000000], injected: [GAME], owned: {}});
  assert.deepEqual(foreign.orphaned, []);
});

test('the empty Lua table shape cannot turn an idle snapshot into an error', () => {
  // Live-observed shape: the backend returns games/helpers as {} when nothing is
  // running, because Lua has no empty array. .map() on that throws.
  const idle = planReconciliation({games: {}, helpers: {}, injected: {}});
  assert.deepEqual(idle, {activate: [], orphaned: []});
  const noArgs = planReconciliation();
  assert.deepEqual(noArgs, {activate: [], orphaned: []});
  const oddOwned = planReconciliation({games: {}, helpers: {}, injected: {}, owned: 'nonsense'});
  assert.deepEqual(oddOwned, {activate: [], orphaned: []});
  // And a real id mixed with the {} shape still works.
  const mixed = planReconciliation({games: GAME, helpers: GAME, injected: [GAME], owned: {}});
  assert.deepEqual(mixed, {activate: [], orphaned: []}, 'non-array lists are ignored, never partial');
});

test('with no process snapshot startup defers cleanup and reports unhealthy', async () => {
  const w = fakeWorld();
  w.state = {enabled: true, owned: {[GAME]: 3000000000}, running: {[GAME]: 3000000000}, cleanup: 0, account: null};
  const inner = w.win.Millennium.callServerMethod;
  w.win.Millennium.callServerMethod = async (plugin, method, params = {}) => {
    if (method === 'SlsPresenceProbeProcesses') return JSON.stringify({success: false, error: 'unavailable'});
    return inner(plugin, method, params);
  };
  agent.bootAgent(w.win);
  await w.tick();
  assert.equal(w.log.filter(x => ['terminate', 'remove'].includes(x.op)).length, 0);
  assert.equal(w.state.running[GAME], 3000000000);
  assert.equal(w.reports.at(-1).healthy, false);
  assert.match(w.reports.at(-1).error, /snapshot unavailable/);
});

test('the five-second wire loop repairs a lost stop notification after two complete snapshots', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win); await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  const helper = w.state.owned[GAME];
  w.realGames.delete(GAME); // no lifetime callback
  const sync = w.timers.find(t => t.ms === 5000).fn;
  await sync();
  assert.equal(w.overviews.has(helper), true, 'one missing process observation is tolerated');
  await sync();
  assert.equal(w.overviews.has(helper), false);
  assert.deepEqual(w.state.owned, {});
  assert.deepEqual(w.log.filter(x => x.op === 'terminate').map(x => x.gameid), [shortcutGameId(helper)]);
  w.realGames.add(GAME); // the next start event is lost too
  await sync();
  assert.equal(w.log.filter(x => x.op === 'run').length, 2, 'a new observed session is recovered');
});

test('startup migrates all fifteen legacy idle helpers without touching an unrelated shortcut', async () => {
  const w = fakeWorld();
  const owned = Object.fromEntries(Array.from({length: 15}, (_, i) => [GAME + i, 3000000000 + i]));
  for (const id of Object.values(owned)) w.overviews.set(id, {display_name: 'Legacy helper'});
  w.overviews.set(3100000000, {display_name: 'My unrelated shortcut'});
  w.state = {...w.state, enabled: true, owned, running: {[GAME]: owned[GAME], [GAME + 1]: owned[GAME + 1]}};
  agent.bootAgent(w.win); await w.tick();
  assert.deepEqual(w.state.owned, {});
  assert.deepEqual(w.state.running, {});
  assert.equal(w.log.filter(x => x.op === 'remove').length, 15);
  assert.equal(w.overviews.has(3100000000), true);
  assert.equal(w.overviews.has(GAME), true);
  assert.equal(w.reports.at(-1).healthy, true);
});

test('incomplete wire snapshots neither remove helpers nor count towards a missed stop', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win); await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  const inner = w.win.Millennium.callServerMethod;
  let incomplete = false;
  w.win.Millennium.callServerMethod = async (plugin, method, params) => {
    if (method === 'SlsPresenceProbeProcesses' && incomplete)
      return JSON.stringify({success: true, complete: false, games: [], helpers: []});
    return inner(plugin, method, params);
  };
  w.realGames.delete(GAME);
  const sync = w.timers.find(t => t.ms === 5000).fn;
  await sync(); incomplete = true; await sync(); await sync();
  assert.equal(w.reports.at(-1).healthy, false);
  incomplete = false; await sync();
  assert.equal(w.log.filter(x => x.op === 'remove').length, 0);
  await sync();
  assert.equal(w.log.filter(x => x.op === 'remove').length, 1);
  assert.equal(w.reports.at(-1).healthy, true);
});

test('a no-op native removal stays unhealthy and the wire loop retries it', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true};
  agent.bootAgent(w.win); await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  const remove = w.win.SteamClient.Apps.RemoveShortcut;
  w.win.SteamClient.Apps.RemoveShortcut = async () => {};
  await w.deliver({unAppID: GAME, bRunning: false});
  await w.tick();
  assert.equal(Object.keys(w.state.owned).length, 1);
  assert.equal(w.reports.at(-1).healthy, false);
  w.win.SteamClient.Apps.RemoveShortcut = remove;
  await w.tick();
  assert.deepEqual(w.state.owned, {});
  assert.equal(w.reports.at(-1).healthy, true);
});

// ------------------------------------------------- 17. default-off guarantee
test('nothing at all happens while the bridge stays disabled', async () => {
  const w = fakeWorld();
  agent.bootAgent(w.win);
  await w.tick();
  w.deliver({unAppID: GAME, bRunning: true});
  for (let i = 0; i < 5; i++) await flushed();
  assert.equal(w.log.length, 0, 'disabled by default means zero Steam calls');
  assert.equal(w.reports.at(-1).healthy, true, 'but the agent still reports healthy');
});

// ------------------------------------------------- 15. contract reporting
test('the capability probe reports arity without invoking anything', () => {
  let invoked = 0;
  const niladic = () => { invoked++; };
  const unary = id => { invoked++; return id; };
  const binary = (a, b) => { invoked++; return [a, b]; };
  const contracts = probeContracts({
    SteamClient: {
      Apps: {
        AddShortcut: binary, RemoveShortcut: unary, RunGame: binary, TerminateApp: binary,
        SetShortcutHidden: binary, SetAppHidden: binary,
      },
      User: {GetSteamID: niladic},
    },
    collectionStore: {SetAppsAsHidden: binary, BIsHidden: unary},
    appStore: {GetAppOverviewByAppID: unary},
  });
  assert.equal(invoked, 0, 'probing must not call the client');
  assert.equal(contracts.addShortcut, 2);
  assert.equal(contracts.setShortcutHidden, 2);
  assert.equal(contracts.overview, 1);
  assert.equal(contracts.steamId, 0);
  assert.equal(contracts.setAppHidden, 2);
  assert.equal(probeContracts({}).setAppHidden, null, 'absent APIs report null');
});

test('bootAgent refuses to run when a required API is missing', async () => {
  const w = fakeWorld({hideApi: 'none', collectionStore: false});
  agent.bootAgent(w.win);
  await flushed();
  const report = w.reports.at(-1);
  assert.equal(report.healthy, false);
  assert.match(report.error, /Library hiding API/);
  assert.equal(w.log.length, 0);
});

// ------------------------------------------------- 18. name enrichment
test('the session-time label stays plain under five minutes and formats hours', () => {
  assert.equal(sessionLabel(0), '');
  assert.equal(sessionLabel(4 * 60000 + 59000), '', 'four minutes fifty-nine seconds is still plain');
  assert.equal(sessionLabel(5 * 60000), '5m');
  assert.equal(sessionLabel(59 * 60000), '59m');
  assert.equal(sessionLabel(60 * 60000), '1h');
  assert.equal(sessionLabel(65 * 60000), '1h 5m');
  assert.equal(sessionLabel(25 * 3600000), '25h', 'long sessions keep counting');
  assert.equal(sessionLabel(undefined), '');
});

test('the running placeholder gains a session-time suffix and is removed on stop', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true, sessionTime: true};
  agent.bootAgent(w.win);
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  await w.tick();
  const names = () => w.log.filter(x => x.op === 'setName').map(x => x.name);
  assert.ok(names().includes(GAME_TITLE), 'the plain title is applied at launch');
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 6 * 60 * 1000;
    await w.tick();
  } finally { Date.now = realNow; }
  assert.ok(names().includes(GAME_TITLE + ' (6m)'), 'after six minutes the name carries the session time');
  await w.deliver({unAppID: GAME, bRunning: false});
  await w.tick();
  assert.deepEqual(w.state.owned, {}, 'no enriched placeholder survives the session');
  assert.equal(w.log.filter(x => x.op === 'remove').length, 1);
});

test('with session time disabled the placeholder keeps its plain title', async () => {
  const w = fakeWorld();
  w.state = {...w.state, enabled: true, sessionTime: false};
  agent.bootAgent(w.win);
  await w.tick();
  await w.deliver({unAppID: GAME, bRunning: true});
  await w.tick();
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 10 * 60 * 1000;
    await w.tick();
  } finally { Date.now = realNow; }
  assert.equal(w.log.some(x => x.op === 'setName' && /\(\d/.test(x.name)), false,
    'no suffix may be added while the toggle is off');
  await w.deliver({unAppID: GAME, bRunning: false});
  await w.tick();
});
