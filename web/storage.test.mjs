import assert from 'node:assert/strict';
import test from 'node:test';

process.env.TZ = 'Asia/Shanghai';
const { normalizeSettings, setIdFactory } = await import('./model.mjs');
const { freshState, legacyKey, legacyTaskId, loadState, migrateLegacy, saveState, storageKey } = await import('./storage.mjs');
const { focusReview } = await import('./review.mjs');

let serial = 0;
setIdFactory(() => `NEW-${++serial}`);
const at = text => new Date(text).getTime();

function memoryStorage(entries = {}) {
  const data = new Map(Object.entries(entries));
  return {
    data,
    getItem: key => data.has(key) ? data.get(key) : null,
    setItem: (key, value) => data.set(key, String(value)),
  };
}

// A v1 browser state as written by the previous web client.
function legacyState() {
  return {
    settings: { focus: 30, short: 6, long: 20, rounds: 3, target: 4, sound: false, ambient: 'off', ambientVolume: 0.3 },
    timer: { phase: 'focus', duration: 30 * 60_000, remaining: 12 * 60_000, end: null, id: 'b1a2c3d4-0000-4000-8000-00000000000a', task: '写周报' },
    round: 2,
    tasks: [
      { id: 'a1b2c3d4-0000-4000-8000-000000000001', title: '写周报', category: 'work', day: '2024-03-11', done: false },
      { id: 'a1b2c3d4-0000-4000-8000-000000000002', title: '跑步', category: 'personal', day: '2024-03-12', done: true },
      { id: 'a1b2c3d4-0000-4000-8000-000000000003', title: '倒垃圾', category: 'chores', day: '2024-03-12', done: false },
      { id: 'a1b2c3d4-0000-4000-8000-000000000004', title: '读书', category: 'personal', day: '2024-03-12', done: false },
      { id: 'a1b2c3d4-0000-4000-8000-000000000005', title: '读书', category: 'personal', day: '2024-03-05', done: true },
      { broken: true },
    ],
    sessions: [
      { id: 'c0000000-0000-4000-8000-000000000001', end: at('2024-03-11T09:30:00+08:00'), minutes: 25, block: 2, task: '写周报' },
      { id: 'c0000000-0000-4000-8000-000000000002', end: at('2024-03-11T10:20:00+08:00'), minutes: 25, block: 3, task: null },
      { id: 'c0000000-0000-4000-8000-000000000003', end: at('2024-03-12T09:20:00+08:00'), minutes: 50, block: 2, task: '读书' },
      { id: 'c0000000-0000-4000-8000-000000000004', end: at('2024-03-12T08:00:00+08:00'), minutes: 30, block: 2, task: '旧任务已删除' },
      { id: 'broken', end: 'yesterday', minutes: 25 },
    ],
    blocks: { 1: '早起', 3: '  深度工作 ' },
  };
}

test('v1 data migrates into the native record shapes without losing records', () => {
  const v1 = legacyState();
  const state = migrateLegacy(v1, at('2024-03-12T09:00:00+08:00'));
  const s = state.settings;
  assert.deepEqual([s.pomoDurationMins, s.breakDuration, s.longBreakDuration, s.pomoSetNum, s.blockPomoCount], [30, 6, 20, 3, 4]);
  assert.deepEqual([s.sound, s.ambientSource, s.ambientSoundVolume, s.manualBreak, s.enableBlockMode], [false, 'custom', 0.3, true, true]);
  assert.deepEqual(s.blockGoals.slice(0, 3), ['早起', '', '深度工作']);
  // Sessions: totals per completion calendar day, task links by id, the rest as unassigned focus ids.
  assert.deepEqual(Object.keys(state.histogram).sort(), ['2024-03-11', '2024-03-12']);
  const monday = state.histogram['2024-03-11'];
  assert.deepEqual([monday.pomodoros, monday.minutes, monday.weekday], [2, 50, '星期一']);
  assert.deepEqual(monday.taskSessions, [{ id: 'C0000000-0000-4000-8000-000000000001', taskId: 'A1B2C3D4-0000-4000-8000-000000000001', title: '写周报', minutes: 25, startedAt: 0 }]);
  assert.deepEqual(monday.unassignedFocusIDs, ['C0000000-0000-4000-8000-000000000002']);
  const tuesday = state.histogram['2024-03-12'];
  assert.deepEqual([tuesday.pomodoros, tuesday.minutes], [2, 80]);
  assert.equal(tuesday.taskSessions[0].taskId, 'A1B2C3D4-0000-4000-8000-000000000004', 'same-title tasks resolve to the one on the focus day');
  assert.equal(tuesday.taskSessions[1].taskId, legacyTaskId('旧任务已删除'), 'an unknown title gets a stable id');
  assert.match(legacyTaskId('x'), /^[0-9A-F]{8}-[0-9A-F]{4}-8[0-9A-F]{3}-A[0-9A-F]{3}-[0-9A-F]{12}$/);
  // Block counts come from the fixed v1 blocks; no plants or completions are invented.
  assert.deepEqual(state.dailyBlocks['2024-03-11'].blockProgress, [0, 1, 1, 0, 0, 0, 0, 0]);
  assert.deepEqual(state.dailyBlocks['2024-03-12'].blockProgress, [0, 2, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(state.plants, {});
  assert.deepEqual(state.blockHistory, {});
  // Tasks keep their logical day, category slot, completion and UUID.
  const store = state.topThree;
  assert.deepEqual(store.categoryNames, ['Work', 'MyOwn', 'Chores']);
  assert.deepEqual(store.history['2024-03-12'].taskGroups.map(group => group.map(task => [task.title, task.isCompleted])), [[], [['跑步', true], ['读书', false]], [['倒垃圾', false]]]);
  assert.equal(store.history['2024-03-11'].taskGroups[0][0].id, 'A1B2C3D4-0000-4000-8000-000000000001');
  assert.ok(Object.values(store.history).flatMap(day => day.taskGroups.flat()).every(task => !task.syncPending && task.cloudAccount === null),
    'migrated history is never uploaded on its own');
  // The paused v1 focus continues with its remaining time and task.
  assert.deepEqual([state.timer.phase, state.timer.running, state.timer.pausedRemaining, state.timer.totalSeconds, state.timer.combo],
    ['POMODORO', false, 720, 1800, 2]);
  assert.equal(state.timer.taskFocus.taskId, 'A1B2C3D4-0000-4000-8000-000000000001');
  // The review sees the migrated history.
  const review = focusReview(7, '2024-03-12', state);
  assert.deepEqual([review.totals.pomodoros, review.totals.minutes], [4, 130]);
  assert.equal(review.tasks.length, 3);
});

test('loading migrates once, keeps the v1 key untouched and is idempotent', () => {
  const raw = JSON.stringify(legacyState());
  const storage = memoryStorage({ [legacyKey]: raw });
  const first = loadState(storage, at('2024-03-12T09:00:00+08:00'));
  assert.ok(first.migrated && first.writable && first.dirty);
  saveState(storage, first.state);
  assert.equal(storage.getItem(legacyKey), raw, 'v1 stays byte-identical');
  const second = loadState(storage);
  assert.ok(!second.migrated && second.writable && !second.dirty);
  assert.deepEqual(second.state, JSON.parse(storage.getItem(storageKey)));
});

test('records an older tab adds to v1 after migration are merged once; cleared data stays cleared', () => {
  const v1 = legacyState();
  const storage = memoryStorage({ [legacyKey]: JSON.stringify(v1) });
  const loaded = loadState(storage, at('2024-03-12T09:00:00+08:00'));
  loaded.state.histogram = {}; // the user cleared statistics in the new version
  saveState(storage, loaded.state);
  v1.sessions.push({ id: 'c0000000-0000-4000-8000-000000000009', end: at('2024-03-12T11:00:00+08:00'), minutes: 25, block: 3, task: null });
  v1.tasks.push({ id: 'a1b2c3d4-0000-4000-8000-000000000009', title: '新任务', category: 'work', day: '2024-03-12', done: false });
  storage.setItem(legacyKey, JSON.stringify(v1));
  const merged = loadState(storage);
  assert.equal(merged.merged, 2);
  assert.deepEqual(Object.keys(merged.state.histogram), ['2024-03-12']);
  assert.equal(merged.state.histogram['2024-03-12'].pomodoros, 1);
  assert.equal(merged.state.topThree.history['2024-03-12'].taskGroups[0][0].title, '新任务');
  saveState(storage, merged.state);
  assert.equal(loadState(storage).merged, 0);
});

test('unreadable or newer data is never overwritten', () => {
  const corrupt = memoryStorage({ [legacyKey]: '{"settings":' });
  const legacy = loadState(corrupt);
  assert.equal(legacy.writable, false);
  assert.match(legacy.notice, /旧版/);
  const shape = memoryStorage({ [legacyKey]: JSON.stringify({ settings: {}, tasks: 'nope' }) });
  assert.equal(loadState(shape).writable, false);
  assert.equal(loadState(memoryStorage({ [storageKey]: 'not json' })).writable, false);
  assert.equal(loadState(memoryStorage({ [storageKey]: JSON.stringify({ version: 2, histogram: [] }) })).writable, false);
  const newer = loadState(memoryStorage({ [storageKey]: JSON.stringify({ version: 3 }) }));
  assert.ok(!newer.writable && /更新版本/.test(newer.notice));
  const broken = memoryStorage();
  broken.getItem = () => { throw new Error('SecurityError'); };
  assert.equal(loadState(broken).writable, false);
});

test('missing fields take defaults and malformed entries are dropped, not the whole state', () => {
  const storage = memoryStorage({ [storageKey]: JSON.stringify({
    version: 2,
    settings: { pomoDurationMins: 40, blockCount: 'x', pomoEndSound: 'Missing.mp3', ambientSource: 'qishi' },
    histogram: { '2024-03-12': { pomodoros: 2, minutes: 50, taskSessions: [{ id: 'S', taskId: 'T', title: '标题', minutes: 25 }, { id: '', minutes: 3 }] }, bad: 3 },
    topThree: { categoryNames: ['工作'], history: { '2024-03-12': { date: '2024-03-12', taskGroups: [[{ id: 'X', title: '标题' }, 7]] } } },
    timer: { phase: 'POMODORO', running: false, pausedRemaining: 0 },
  }) });
  const { state, writable } = loadState(storage);
  assert.ok(writable);
  assert.equal(state.settings.pomoDurationMins, 40);
  assert.equal(state.settings.blockCount, 8);
  assert.equal(state.settings.pomoEndSound, 'Chime');
  assert.equal(state.settings.breakExtention, 2);
  assert.deepEqual(state.histogram['2024-03-12'].taskSessions, [{ id: 'S', taskId: 'T', title: '标题', minutes: 25, startedAt: 0 }]);
  assert.equal(state.histogram.bad, undefined);
  assert.deepEqual(state.topThree.categoryNames, ['工作', 'MyOwn', 'Chores']);
  assert.equal(state.topThree.history['2024-03-12'].taskGroups[0].length, 1);
  assert.equal(state.timer.phase, 'IDLE', 'a paused phase without remaining time cannot resume');
});

test('a fresh state uses the native defaults', () => {
  const state = freshState();
  const s = state.settings;
  assert.deepEqual([s.pomoDurationMins, s.breakDuration, s.longBreakDuration, s.breakExtention, s.pomoSetNum, s.manualBreak],
    [25, 5, 30, 2, 4, true]);
  assert.deepEqual(normalizeSettings(JSON.parse(JSON.stringify(s))), s, 'settings round-trip unchanged');
});
