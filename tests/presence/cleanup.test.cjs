const {test} = require('node:test');
const assert = require('node:assert/strict');
const {PresenceController, shortcutGameId} = require('../../addons/presence/plugin/public/agent.js');

const GAME = 620, USER_SHORTCUT = 3100000000, TYPE = 1073741824;
function world() {
  const calls = [], helpers = new Set();
  const overviews = new Map([[GAME, {display_name: 'Portal 2', app_type: 1}],
    [USER_SHORTCUT, {display_name: 'My shortcut', app_type: TYPE}]]);
  let next = 3000000000;
  const c = new PresenceController({
    apps: {
      AddShortcut: async () => { const id = next++; overviews.set(id, {display_name: 'Portal 2', app_type: TYPE}); return id; },
      SetShortcutLaunchOptions() {}, SetShortcutName() {},
      RunGame: async gid => { const id = Number(BigInt(gid) >> 32n); helpers.add(id); calls.push(['run', id]); },
      TerminateApp: async gid => { const id = Number(BigInt(gid) >> 32n); helpers.delete(id); calls.push(['stop', id]); },
      RemoveShortcut: async id => { overviews.delete(id); calls.push(['remove', id]); },
    },
    storage: {getItem: () => null, setItem() {}, flush: async () => {}},
    overview: id => overviews.get(id), hideShortcut: async () => true, delay: async () => {},
    accountKey: 'deadbeef', accountSource: 'loginusers',
    probeProcesses: async () => ({games: [...c.active], helpers: [...helpers]}),
  });
  c.updateInjected([GAME]); c.setEnabled(true);
  return {c, calls, helpers, overviews};
}

for (const mode of ['desktop', 'gamescope']) test(`${mode}: closing the game removes only its helper shortcut`, async () => {
  const {c, calls, overviews} = world();
  if (mode === 'gamescope') c.restoreGameSelection = async () => true;
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  await Promise.all([c.onLifetime({unAppID: GAME, bRunning: false}), c.end(GAME)]);
  assert.deepEqual(calls.filter(x => x[0] === 'stop'), [['stop', helper]]);
  assert.deepEqual(calls.filter(x => x[0] === 'remove'), [['remove', helper]]);
  assert.equal(overviews.has(helper), false);
  assert.equal(overviews.has(GAME), true); assert.equal(overviews.has(USER_SHORTCUT), true);
  assert.deepEqual(c.state.owned, {}); assert.deepEqual(c.state.running, {});
  await c.onLifetime({unAppID: GAME, bRunning: true});
  assert.notEqual(c.state.owned[GAME], helper, 'the next session gets a fresh temporary helper');
});

test('startup removes legacy idle shortcuts even when no helper process remains', async () => {
  const {c, calls, overviews} = world();
  c.state.owned[GAME] = 3000000000;
  c.state.running[GAME] = 3000000000;
  overviews.set(3000000000, {display_name: 'Portal 2', app_type: TYPE});
  await c.reconcile({games: {}, helpers: {}});
  assert.deepEqual(calls, [['remove', 3000000000]]);
  assert.deepEqual(c.state.owned, {});
});

test('periodic reconciliation repairs a missed stop but tolerates one transient missing process', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  await c.reconcile({games: [], helpers: [helper]});
  assert.equal(calls.some(x => x[0] === 'remove'), false);
  await c.reconcile({games: [], helpers: [helper]});
  assert.equal(calls.some(x => x[0] === 'remove'), true);
  assert.deepEqual(c.state.running, {});
});

test('unknown or truncated process snapshots never imply that a running game stopped', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  await c.reconcile(null);
  await c.reconcile({games: [], helpers: [], complete: false});
  assert.equal(calls.some(x => x[0] === 'stop' || x[0] === 'remove'), false);
});

test('an acknowledged TerminateApp is not proof that the helper stopped', async () => {
  const {c, calls, helpers} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  c.apps.TerminateApp = async () => calls.push(['stop', helper]);
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(calls.some(x => x[0] === 'remove'), false);
  assert.equal(c.state.running[GAME], helper);
  helpers.clear();
  await c.end(GAME);
  assert.deepEqual(c.state.owned, {});
});

test('failed removal is journalled and retried instead of forgotten', async () => {
  const {c, overviews} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME], remove = c.apps.RemoveShortcut;
  c.apps.RemoveShortcut = async () => { throw Error('Steam busy'); };
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(c.state.owned[GAME], helper);
  assert.equal(c.report().healthy, false);
  c.apps.RemoveShortcut = remove;
  await c.reconcile({games: [], helpers: []});
  assert.equal(overviews.has(helper), false);
  assert.equal(c.report().healthy, true);
});

test('a no-op RemoveShortcut cannot falsely clear ownership', async () => {
  const {c, overviews} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  c.apps.RemoveShortcut = async () => {};
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(c.state.owned[GAME], helper);
  overviews.delete(helper);
  await c.end(GAME);
  assert.deepEqual(c.state.owned, {});
});

test('a mapped real game is never terminated or removed', async () => {
  const {c, calls, overviews} = world();
  c.state.owned[GAME] = 730; c.state.running[GAME] = 730;
  overviews.set(730, {display_name: 'Real Steam game', app_type: 1});
  await c.end(GAME);
  assert.deepEqual(calls, []);
  assert.equal(c.state.owned[GAME], 730);
});

test('ambiguous identity blocks legacy cleanup', async () => {
  const {c, calls, overviews} = world();
  c.state.owned[GAME] = 3000000000; c.identityAmbiguous = true;
  overviews.set(3000000000, {display_name: 'Portal 2', app_type: TYPE});
  await c.reconcile({games: [], helpers: []});
  assert.deepEqual(calls, []);
});

test('cancelled asynchronous creation leaves neither a helper nor a shortcut', async () => {
  const {c, calls, overviews} = world();
  const add = c.apps.AddShortcut;
  let release; const gate = new Promise(r => { release = r; });
  c.apps.AddShortcut = async () => { const id = await add(); await gate; return id; };
  const start = c.onLifetime({unAppID: GAME, bRunning: true});
  await Promise.resolve();
  const stop = c.onLifetime({unAppID: GAME, bRunning: false});
  release(); await Promise.all([start, stop]);
  assert.equal(calls.some(x => x[0] === 'run'), false);
  assert.deepEqual(c.state.owned, {});
  assert.equal(overviews.size, 2);
});

test('a failed stop never loses the running record, even after the retry limit', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  c.apps.TerminateApp = async () => { calls.push(['stop-failed']); throw Error('busy'); };
  let now = 1; c.now = () => now;
  for (let i = 0; i < 5; i++) await c.end(GAME);
  assert.equal(calls.filter(x => x[0] === 'stop-failed').length, 3);
  assert.equal(c.state.running[GAME], helper);
  now += 31000;
  await c.end(GAME);
  assert.equal(calls.filter(x => x[0] === 'stop-failed').length, 4);
});

test('a restart during asynchronous removal waits and allocates a fresh helper', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const old = c.state.owned[GAME], remove = c.apps.RemoveShortcut;
  let release, entered;
  const gate = new Promise(r => { release = r; });
  const ready = new Promise(r => { entered = r; });
  c.apps.RemoveShortcut = async id => { entered(); await gate; return remove(id); };
  const stop = c.onLifetime({unAppID: GAME, bRunning: false});
  await ready;
  const start = c.onLifetime({unAppID: GAME, bRunning: true});
  release(); await Promise.all([start, stop]);
  assert.notEqual(c.state.owned[GAME], old);
  assert.equal(c.active.has(GAME), true);
  assert.equal(calls.filter(x => x[0] === 'run').length, 2);
  assert.equal(calls.filter(x => x[0] === 'remove').length, 1);
});

test('a saved mapping onto a real app cannot be configured or launched', async () => {
  const {c, calls, overviews} = world();
  c.state.owned[GAME] = 730;
  overviews.set(730, {display_name: 'Real game', app_type: 1});
  await c.onLifetime({unAppID: GAME, bRunning: true});
  assert.deepEqual(calls, []);
  assert.equal(c.report().healthy, false);
});

test('changing identity domains cannot adopt a nonempty foreign ledger', async () => {
  const {c, calls, overviews} = world();
  c.state.owned[GAME] = 3000000000;
  c.state.account = 'feedface'; c.state.accountSource = 'account-name';
  overviews.set(3000000000, {display_name: 'Portal 2', app_type: TYPE});
  await c.reconcile({games: [], helpers: []});
  assert.deepEqual(calls, []);
  assert.equal(c.state.account, 'feedface');
  assert.equal(c.report().healthy, false);
});

test('malformed and failed snapshots never trigger automatic cleanup', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  for (const snapshot of [{}, {games: [], helpers: null}, {games: ['bad'], helpers: []},
    {success: false, games: [], helpers: []}]) {
    await c.reconcile(snapshot); await c.reconcile(snapshot);
  }
  assert.equal(calls.some(x => x[0] === 'stop' || x[0] === 'remove'), false);
});

test('account changes during an asynchronous process probe block native mutations', async () => {
  const {c, calls, helpers} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  c.probeProcesses = async () => {
    c.accountKey = 'feedface';
    return {games: [], helpers: [...helpers]};
  };
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(calls.some(x => x[0] === 'stop' || x[0] === 'remove'), false);
  assert.equal(Object.keys(c.state.owned).length, 1);
});

test('idle cleanup needs one complete process scan, not two', async () => {
  const {c, overviews} = world();
  c.state.owned[GAME] = 3000000000;
  overviews.set(3000000000, {display_name: 'Portal 2', app_type: TYPE});
  let scans = 0;
  c.probeProcesses = async () => { scans++; return {games: [], helpers: []}; };
  await c.end(GAME);
  assert.equal(scans, 1);
  assert.deepEqual(c.state.owned, {});
});

test('an already stopped helper needs no redundant journal update before removal', async () => {
  const {c, overviews} = world();
  c.guardAccount();
  c.state.owned[GAME] = 3000000000;
  overviews.set(3000000000, {display_name: 'Portal 2', app_type: TYPE});
  let writes = 0;
  c.storage.setItem = () => { writes++; };
  await c.end(GAME);
  assert.equal(writes, 1, 'only the confirmed removal needs a durable state change');
});

test('failed final journal flush preserves ownership and can recover on the next sweep', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  c.storage.flush = async () => { throw Error('disk unavailable'); };
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(c.state.owned[GAME], helper, 'keep the journal intent until durable acknowledgement');
  assert.equal(c.report().healthy, false);
  c.storage.flush = async () => {};
  await c.reconcile({games: [], helpers: []});
  assert.deepEqual(c.state.owned, {});
  assert.equal(c.report().healthy, true);
  assert.equal(calls.filter(x => x[0] === 'remove').length, 1, 'no duplicate native removal');
});

test('an explicit stop does not permanently suppress a later lost start event', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  await c.onLifetime({unAppID: GAME, bRunning: false});
  await c.reconcile({games: [], helpers: []});
  assert.equal(c.stopRequested.size, 0, 'a complete absent snapshot retires the stop tombstone');
  assert.equal(c.missingGames.size, 0);
  await c.reconcile({games: [GAME], helpers: []});
  assert.equal(calls.filter(x => x[0] === 'run').length, 2);
});

test('a live mapped process without the sleep-helper identity is never terminated or removed', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  c.probeProcesses = async () => ({games: [helper], helpers: []});
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(calls.some(x => x[0] === 'stop' || x[0] === 'remove'), false);
  assert.equal(c.state.owned[GAME], helper);
  assert.equal(c.report().healthy, false);
});

test('exit confirmation also checks processes no longer classified as sleep helpers', async () => {
  const {c, calls, helpers} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const helper = c.state.owned[GAME];
  c.probeProcesses = async () => ({games: [helper], helpers: [...helpers]});
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(calls.filter(x => x[0] === 'stop').length, 1);
  assert.equal(calls.some(x => x[0] === 'remove'), false);
  assert.equal(c.state.owned[GAME], helper);
});

test('a locally acknowledged launch is terminated even before its process becomes observable', async () => {
  const {c, calls} = world();
  await c.onLifetime({unAppID: GAME, bRunning: true});
  const probeOptions = [];
  c.probeProcesses = async options => {
    probeOptions.push(options);
    return {games: [], helpers: []};
  };
  await c.onLifetime({unAppID: GAME, bRunning: false});
  assert.equal(calls.filter(x => x[0] === 'stop').length, 1);
  assert.equal(calls.filter(x => x[0] === 'remove').length, 1);
  assert.deepEqual(probeOptions, [{fresh: true}, {fresh: true}]);
});
