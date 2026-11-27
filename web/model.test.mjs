import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

process.env.TZ = 'Asia/Shanghai';
const {
  abandon, activate, appVersion, blockIndexAt, currentBlockIndex, dayKey, logicalDayKey, normalizeSettings, plantRow,
  rangeContains, recordFocus, resetCurrentBlock, setIdFactory, settleTimer, skipBreak, skipToBreak, startPomodoro,
  takeBreak,
} = await import('./model.mjs');
const { freshState } = await import('./storage.mjs');

let serial = 0;
setIdFactory(() => `ID-${String(++serial).padStart(4, '0')}`);
const at = text => new Date(text).getTime();
const minute = 60_000;

function state(settings = {}) {
  const value = freshState();
  value.settings = normalizeSettings({ ...value.settings, ...settings });
  return value;
}

test('version is one constant', () => assert.equal(appVersion, '3.2.0'));

test('shared logical-day scenarios match the native fixtures', () => {
  const parity = process.env.PARITY_DIR ? new URL(`file://${process.env.PARITY_DIR.replace(/\/?$/, '/')}`) : new URL('../parity/', import.meta.url);
  const scenarios = JSON.parse(readFileSync(new URL('logical_day.json', parity)));
  for (const item of scenarios) {
    process.env.TZ = item.zone;
    const settings = normalizeSettings({ blockTimeRanges: [{ startHour: Math.floor(item.boundaryMinutes / 60), startMinute: item.boundaryMinutes % 60, endHour: 0, endMinute: 0 }] });
    const instant = at(item.instant);
    assert.equal(logicalDayKey(settings, instant), item.logicalDay, `${item.name} logical day`);
    assert.equal(dayKey(instant), item.calendarDay, `${item.name} calendar day`);
  }
  process.env.TZ = 'Asia/Shanghai';
});

test('block ranges: minutes, midnight spans and equal endpoints', () => {
  const range = (sh, sm, eh, em) => ({ startHour: sh, startMinute: sm, endHour: eh, endMinute: em });
  assert.ok(rangeContains(range(22, 30, 1, 15), 23 * 60) && rangeContains(range(22, 30, 1, 15), 60) && !rangeContains(range(22, 30, 1, 15), 75));
  assert.ok(rangeContains(range(9, 0, 9, 0), 0) && rangeContains(range(9, 0, 9, 0), 1439), 'equal endpoints cover the day');
  assert.ok(rangeContains(range(10, 5, 11, 0), 605) && !rangeContains(range(10, 5, 11, 0), 604) && !rangeContains(range(10, 5, 11, 0), 660));
  const settings = normalizeSettings({ blockCount: 2, blockTimeRanges: [range(9, 0, 10, 0), range(13, 0, 14, 0)] });
  assert.equal(currentBlockIndex(settings, at('2024-03-12T11:30:00+08:00')), null);
  assert.equal(blockIndexAt(settings, at('2024-03-12T11:30:00+08:00')), 0, 'a gap stays with the block that just ended');
  assert.equal(blockIndexAt(settings, at('2024-03-12T13:30:00+08:00')), 1);
  const grown = normalizeSettings({ blockCount: 10, blockGoals: ['a'], blockTimeRanges: [range(4, 0, 7, 0)] });
  assert.equal(grown.blockTimeRanges.length, 10);
  assert.equal(grown.blockGoals.length, 10);
  const lowered = normalizeSettings({ ...grown, blockCount: 3 });
  assert.equal(lowered.blockGoals.length, 10, 'surplus block settings survive a lower count');
  assert.deepEqual(normalizeSettings({ pomoDurationMins: 500, breakExtention: -4, pomoSetNum: 0 }).pomoDurationMins, 120);
  assert.equal(normalizeSettings({ breakExtention: -4 }).breakExtention, 0);
});

test('a focus records the minutes it started with, at its own deadline', () => {
  const value = state({ manualBreak: true });
  const start = at('2024-03-12T09:00:00+08:00');
  startPomodoro(value, start);
  value.settings = normalizeSettings({ ...value.settings, pomoDurationMins: 50, breakDuration: 9 });
  const settled = settleTimer(value, start + 26 * minute);
  assert.ok(settled.changed);
  assert.deepEqual(value.histogram['2024-03-12'], { pomodoros: 1, minutes: 25, weekday: '星期二', unassignedFocusIDs: [value.histogram['2024-03-12'].unassignedFocusIDs[0]] });
  assert.equal(value.timer.phase, 'MANUAL_BREAK');
  assert.equal(value.timer.combo, 1);
  activate(value, start + 30 * minute);
  assert.equal(value.timer.phase, 'BREAK');
  assert.equal(value.timer.totalSeconds, 5 * 60, 'the break keeps the configuration captured at focus start');
});

test('pause keeps the remaining time; resuming a paused break never completes a focus', () => {
  const value = state({ manualBreak: false, breakExtention: 0 });
  const start = at('2024-03-12T10:00:00+08:00');
  startPomodoro(value, start);
  activate(value, start + 10 * minute);
  assert.equal(value.timer.running, false);
  assert.equal(value.timer.pausedRemaining, 15 * 60);
  settleTimer(value, start + 60 * minute);
  assert.equal(value.histogram['2024-03-12'], undefined, 'a paused focus does not expire');
  activate(value, start + 60 * minute);
  settleTimer(value, start + 75 * minute);
  assert.equal(value.timer.phase, 'BREAK');
  activate(value, start + 76 * minute);
  activate(value, start + 90 * minute);
  settleTimer(value, start + 120 * minute);
  assert.equal(value.histogram['2024-03-12'].pomodoros, 1);
  assert.equal(value.timer.phase, 'IDLE');
  assert.equal(value.timer.combo, 1);
});

test('catch-up settles focus → break → grace once and never starts a focus', () => {
  const value = state({ manualBreak: false, breakExtention: 2, resetPomoAfterBreak: true });
  const start = at('2024-03-12T23:50:00+08:00');
  startPomodoro(value, start);
  const settled = settleTimer(value, start + 5 * 60 * minute);
  assert.equal(value.histogram['2024-03-13'].pomodoros, 1, 'a cross-midnight focus belongs to its deadline day');
  assert.equal(value.timer.phase, 'IDLE');
  assert.equal(value.timer.combo, 0, 'grace timed out with resetPomoAfterBreak');
  assert.ok(settled.messages.some(message => message.includes('休息延长结束')));
});

test('zero extension is not a timeout and keeps the combo', () => {
  const value = state({ manualBreak: false, breakExtention: 0, resetPomoAfterBreak: true, breakExtentionFails: true });
  const start = at('2024-03-12T10:00:00+08:00');
  startPomodoro(value, start, { owner: 'owner' });
  const settled = settleTimer(value, start + 40 * minute);
  assert.equal(value.timer.phase, 'IDLE');
  assert.equal(value.timer.combo, 1);
  assert.ok(!settled.effects.some(effect => effect.kind === 'penalty'));
});

test('grace timeout scores a failure only when that option is on', () => {
  const value = state({ manualBreak: false, breakExtention: 3, breakExtentionFails: true, breakExtentionNotify: true });
  const start = at('2024-03-12T10:00:00+08:00');
  startPomodoro(value, start, { owner: 'owner' });
  const settled = settleTimer(value, start + 40 * minute);
  assert.ok(settled.effects.some(effect => effect.kind === 'penalty' && effect.owner === 'owner'));
  assert.ok(settled.effects.some(effect => effect.kind === 'pm' && effect.text.includes('3 minutes')));
  assert.equal(value.timer.combo, 1, 'without resetPomoAfterBreak the combo is kept');
});

test('abandon and skip never complete or extend the combo; plants wilt', () => {
  const value = state({ pomoHabitMinus: true });
  const start = at('2024-03-12T10:00:00+08:00');
  value.timer.combo = 2;
  startPomodoro(value, start, { owner: 'owner' });
  const result = abandon(value, start + 5 * minute);
  assert.equal(value.timer.phase, 'IDLE');
  assert.equal(value.timer.combo, 0);
  assert.deepEqual(result.effects.map(effect => effect.kind), ['penalty']);
  assert.equal(value.histogram['2024-03-12'], undefined);
  assert.deepEqual(value.plants['2024-03-12'].attempts[2], ['wilted']);

  value.timer.combo = 1;
  startPomodoro(value, start + 10 * minute);
  skipToBreak(value, start + 12 * minute);
  assert.equal(value.timer.phase, 'BREAK');
  assert.equal(value.timer.combo, 0);
  assert.equal(value.histogram['2024-03-12'], undefined);
  assert.deepEqual(value.plants['2024-03-12'].attempts[2], ['wilted', 'wilted']);
  assert.equal(abandon(value, start + 13 * minute).effects.length, 0, 'ending a break is not a focus failure');
});

test('custom breaks are idle-only, keep the combo and have no grace period', () => {
  const value = state({ breakExtention: 5 });
  const start = at('2024-03-12T10:00:00+08:00');
  value.timer.combo = 3;
  assert.equal(takeBreak(value, start, 7), null);
  takeBreak(value, start, 15);
  assert.equal(value.timer.phase, 'LONG_BREAK');
  assert.equal(value.timer.customBreak, true);
  assert.equal(takeBreak(value, start, 5), null, 'only from idle');
  settleTimer(value, start + 16 * minute);
  assert.equal(value.timer.phase, 'IDLE');
  assert.equal(value.timer.combo, 3);
});

test('a completed set takes the long break and the combo resets afterwards', () => {
  const value = state({ pomoSetNum: 2, manualBreak: false, pomoHabitPlus: true, pomoSetHabitPlus: true, breakExtention: 0 });
  let now = at('2024-03-12T10:00:00+08:00');
  startPomodoro(value, now, { owner: 'owner' });
  now += 25 * minute;
  let settled = settleTimer(value, now);
  assert.deepEqual(settled.effects.filter(effect => effect.kind === 'reward').map(effect => [effect.plus, effect.combo]), [[true, false]]);
  now += 5 * minute;
  settleTimer(value, now);
  startPomodoro(value, now, { owner: 'owner' });
  now += 25 * minute;
  settled = settleTimer(value, now);
  assert.deepEqual(settled.effects.filter(effect => effect.kind === 'reward').map(effect => [effect.plus, effect.combo]), [[true, true]]);
  assert.equal(value.timer.phase, 'LONG_BREAK');
  assert.equal(value.timer.totalSeconds, 30 * 60);
  settleTimer(value, now + 31 * minute);
  assert.equal(value.timer.combo, 0);
  assert.equal(value.plants['2024-03-12'].trees[2], 1, 'a completed set plants a tree');
});

test('skipping a break keeps the combo unless the set was complete', () => {
  const value = state({ pomoSetNum: 4 });
  const now = at('2024-03-12T10:00:00+08:00');
  Object.assign(value.timer, { phase: 'MANUAL_BREAK', combo: 2, completedSet: false });
  skipBreak(value, now);
  assert.equal(value.timer.phase, 'POMODORO');
  assert.equal(value.timer.combo, 2);
  Object.assign(value.timer, { phase: 'MANUAL_BREAK', combo: 4, completedSet: true });
  skipBreak(value, now);
  assert.equal(value.timer.combo, 0);
});

test('a block completes once per day even after its count is reset', () => {
  const value = state({ blockPomoCount: 2, manualBreak: true, blockRewardEnabled: true, pomoHabitPlus: false });
  let now = at('2024-03-12T10:30:00+08:00');
  const complete = () => {
    if (value.timer.phase === 'MANUAL_BREAK') skipBreak(value, now, { owner: 'owner' });
    else startPomodoro(value, now, { owner: 'owner' });
    now += 25 * minute;
    return settleTimer(value, now);
  };
  complete();
  const second = complete();
  assert.equal(value.blockHistory['2024-03-12'].length, 1);
  assert.ok(second.effects.some(effect => effect.kind === 'reward' && effect.block && !effect.plus));
  assert.ok(second.messages[0].startsWith('时间块 B3 完成'));
  const third = complete();
  assert.ok(!third.effects.some(effect => effect.kind === 'reward'), 'exceeding the target does not reward again');
  resetCurrentBlock(value, now);
  assert.equal(value.dailyBlocks['2024-03-12'].blockProgress[2], 0);
  complete();
  const again = complete();
  assert.equal(value.blockHistory['2024-03-12'].length, 1);
  assert.ok(!again.effects.some(effect => effect.kind === 'reward'));
  const row = plantRow(value, '2024-03-12', 2);
  assert.equal(row.outcomes.filter(item => item === 'shrub').length, 5, 'plants are kept when the count resets');
});

test('sprint reminder fires once at two thirds of the block target', () => {
  const value = state({ blockPomoCount: 6, manualBreak: true });
  let now = at('2024-03-12T10:30:00+08:00');
  const messages = [];
  for (let index = 0; index < 5; index += 1) {
    if (value.timer.phase === 'MANUAL_BREAK') skipBreak(value, now); else startPomodoro(value, now);
    now += 25 * minute;
    messages.push(...settleTimer(value, now).messages);
  }
  assert.equal(messages.filter(message => message.startsWith('冲刺时间')).length, 1);
  assert.equal(value.reminders.sprint, '2024-03-12-2');
});

test('task focus snapshots the title and minutes; history counts it once', () => {
  const value = state({ manualBreak: true });
  const start = at('2024-03-12T23:40:00+08:00');
  startPomodoro(value, start, { task: { id: 'TASK-1', title: '初稿' } });
  assert.equal(value.timer.taskFocus.title, '初稿');
  assert.equal(value.timer.taskFocus.startedAt, start);
  settleTimer(value, start + 25 * minute);
  const day = value.histogram['2024-03-13'];
  assert.equal(day.taskSessions.length, 1);
  assert.deepEqual({ ...day.taskSessions[0], id: undefined }, { id: undefined, taskId: 'TASK-1', title: '初稿', minutes: 25, startedAt: start });
  assert.equal(recordFocus(value.histogram, { id: day.taskSessions[0].id, minutes: 25, at: start + 25 * minute, session: day.taskSessions[0] }), false);
  assert.equal(value.histogram['2024-03-13'].pomodoros, 1);
});

test('rewards need the owner captured at focus start', () => {
  const value = state({ pomoHabitPlus: true, manualBreak: true });
  const start = at('2024-03-12T10:00:00+08:00');
  startPomodoro(value, start);
  assert.ok(!settleTimer(value, start + 25 * minute).effects.some(effect => effect.kind === 'reward'));
});
