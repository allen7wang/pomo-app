import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// PARITY_DIR lets the suite run against another checkout of the shared scenarios.
const parity = process.env.PARITY_DIR ? new URL(`file://${process.env.PARITY_DIR.replace(/\/?$/, '/')}`) : new URL('../parity/', import.meta.url);
const fixture = JSON.parse(readFileSync(new URL('focus_review.json', parity)));
process.env.TZ = fixture.zone;
const { dayKey } = await import('./model.mjs');
const { decodeState } = await import('./storage.mjs');
const { chronologicalSessions, duration, earliestDate, focusReview, historySummary, nextPage, pageEnd } = await import('./review.mjs');

// Records go through the same lenient decoder the page uses.
const records = data => decodeState({ histogram: data.histogram ?? {}, dailyBlocks: data.dailyBlocks ?? {}, blockHistory: data.blockHistory ?? {}, plants: data.plants ?? {} });
const today = dayKey(new Date(fixture.instant).getTime());

test('review windows match the native reference dataset byte for byte', () => {
  assert.equal(today, '2024-03-12', '02:00 local is still the same calendar day');
  assert.equal(dayKey(new Date('2024-03-12T06:30:00Z').getTime()), '2024-03-11');
  const data = records(fixture);
  for (const window of fixture.windows) {
    const review = focusReview(window.days, today, data);
    assert.equal(review.days.length, window.days);
    assert.equal(review.startKey, window.start);
    assert.equal(review.endKey, window.end);
    assert.equal(review.totals.pomodoros, window.pomodoros);
    assert.equal(review.totals.minutes, window.minutes);
    assert.equal(review.totals.activeDays, window.activeDays);
    assert.equal(review.selectedDay(null).key, window.defaultDay);
    if (window.csvRows) assert.equal(review.csv, window.csvRows.join('\r\n') + '\r\n');
  }
  const week = focusReview(7, today, data);
  assert.equal(week.csvFilename, '专注复盘-2024-03-06-2024-03-12.csv');
  assert.ok(!week.csv.includes('Private') && !week.csv.includes('2024-03-13') && !week.csv.startsWith('﻿'));
  const [legacy, overlap, plantOnly] = [week.days[1], week.days[3], week.days[4]];
  assert.deepEqual(legacy.blocks.map(block => [block.index, block.completedPomodoros, block.isCompleted]), [[4, 3, true]]);
  assert.deepEqual(overlap.blocks.map(block => [block.index, block.completedPomodoros, block.goal]), [[0, 0, 'Reset'], [1, 2, 'Private, focus']]);
  assert.ok(plantOnly.hasRecords && plantOnly.wilted === 2 && plantOnly.trees === 1 && plantOnly.pomodoros === 0);
  assert.deepEqual(week.totals, { pomodoros: 3, minutes: 60, activeDays: 2, completedBlocks: 3, shrubs: 2, trees: 2, wilted: 3 });
  assert.equal(earliestDate(data), fixture.earliest);
  assert.equal(earliestDate(records({})), null);
  const empty = focusReview(30, today, records({}));
  assert.ok(empty.days.some(day => day.key === '2024-02-29') && !empty.hasRecords);
  assert.equal(focusReview(90, today, records({})).startKey, '2023-12-14');
});

test('single-day session details: start order, unknown starts last, completion-day attribution', { skip: !fixture.taskTimeline && 'parity fixture predates 3.2' }, () => {
  const timeline = fixture.taskTimeline;
  const data = records({ histogram: timeline.histogram });
  const review = focusReview(7, today, data);
  const day = review.selectedDay(timeline.day);
  const ordered = chronologicalSessions(day.taskSessions);
  assert.deepEqual(ordered.map(session => session.id), timeline.orderedIDs);
  assert.ok(ordered.slice(-4).every(session => session.startedAt <= 0), 'missing, null and negative starts are unknown');
  assert.equal(dayKey(ordered[2].startedAt), timeline.legacyDay, 'a late session started on the previous day');
  const legacy = review.selectedDay(timeline.legacyDay);
  assert.ok(legacy.taskSessions.length === 0 && legacy.pomodoros === 1);
  const sessionOnly = review.selectedDay(timeline.sessionOnlyDay);
  assert.ok(sessionOnly.hasRecords && sessionOnly.pomodoros === 0 && sessionOnly.minutes === 0);
  assert.deepEqual(day.taskSessions.length, 7);
  const tasks = focusReview(1, timeline.day, data).tasks;
  assert.deepEqual(tasks.map(task => [task.title, task.minutes, task.pomodoros]), [['定稿', 35, 2], ['校对', 35, 5]]);
  assert.deepEqual([review.totals.pomodoros, review.totals.minutes], [9, 105]);
  assert.equal(review.taskCsv, timeline.taskCSVRows.join('\r\n') + '\r\n');
  assert.equal(review.taskCsvFilename, '任务专注-2024-03-06-2024-03-12.csv');
});

test('task CSV guards formula cells and quotes', () => {
  const data = records({ histogram: { '2024-03-12': { pomodoros: 1, minutes: 5, taskSessions: [
    { id: 'A', taskId: '=cmd', title: ' -1 "x"', minutes: 5, startedAt: 1 },
  ] } } });
  assert.equal(focusReview(1, '2024-03-12', data).taskCsv.split('\r\n')[1], `2024-03-12,"'=cmd","' -1 ""x""",5`);
});

test('paging keeps a fixed anchor and returns to the rolling window', () => {
  let page = { anchor: '2024-03-12', offset: -1 };
  assert.equal(pageEnd(page, 7), '2024-03-05');
  page = { anchor: '2024-03-12', offset: -2 };
  assert.deepEqual(nextPage(page, 7, '2024-03-12'), { anchor: '2024-03-12', offset: -1 });
  assert.equal(nextPage({ anchor: '2024-03-12', offset: -1 }, 7, '2024-03-12'), null, 'the next window reaches today');
  assert.deepEqual(nextPage({ anchor: '2024-03-12', offset: -1 }, 7, '2024-03-13'), { anchor: '2024-03-12', offset: 0 }, 'after midnight the anchored page does not slide');
});

test('history summary and durations use the native wording', () => {
  const summary = historySummary({ a: { pomodoros: 3, minutes: 90 }, b: { pomodoros: 1, minutes: 25 } });
  assert.deepEqual([summary.pomodoros, summary.minutes, summary.average], [4, 115, 2]);
  assert.deepEqual([duration(45), duration(120), duration(135)], ['45 分钟', '2 小时', '2 小时 15 分']);
});
