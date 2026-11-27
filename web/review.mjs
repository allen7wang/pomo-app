// Focus review: a read-only projection of the calendar-day records, ported from FocusReview.kt/.swift.
import { addDays, parseDayKey } from './model.mjs';

export const reviewRanges = [7, 30, 90];
const maxBlocks = 24;

export function summarizeTasks(sessions) {
  const groups = new Map();
  for (const session of sessions) groups.set(session.taskId, [...(groups.get(session.taskId) ?? []), session]);
  return [...groups].map(([id, records]) => {
    const latest = records.reduce((best, item) =>
      item.startedAt > best.startedAt || (item.startedAt === best.startedAt && item.id > best.id) ? item : best);
    return { id, title: latest.title, pomodoros: records.length, minutes: records.reduce((sum, item) => sum + item.minutes, 0) };
  }).sort((a, b) => b.minutes - a.minutes || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/** Newest start first; a missing start (0 or negative) sorts last; ties by id. */
export function chronologicalSessions(sessions) {
  return [...sessions].sort((a, b) => Math.max(0, b.startedAt) - Math.max(0, a.startedAt) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

function blocks(daily, history, plants) {
  const progress = daily?.blockProgress ?? [];
  const goals = daily?.blockGoals ?? [];
  const attempts = plants?.attempts ?? [];
  const trees = plants?.trees ?? [];
  const byBlock = new Map();
  for (const entry of history) {
    if (Number.isInteger(entry.blockIndex) && entry.blockIndex >= 0 && entry.blockIndex < maxBlocks) {
      byBlock.set(entry.blockIndex, [...(byBlock.get(entry.blockIndex) ?? []), entry]);
    }
  }
  const stored = Math.min(maxBlocks, Math.max(progress.length, attempts.length, trees.length));
  const indices = [...new Set([...Array(stored).keys(), ...byBlock.keys()])].sort((a, b) => a - b);
  return indices.flatMap(index => {
    const entries = byBlock.get(index) ?? [];
    const historical = entries.reduce((max, entry) => Math.max(max, entry.pomodoros), 0);
    // A saved zero can be an explicit reset; the historical count applies only when absent.
    const count = Math.max(0, index < progress.length ? progress[index] : historical);
    const isCompleted = entries.some(entry => entry.isComplete);
    const outcomes = attempts[index] ?? [];
    const shrubs = outcomes.filter(outcome => outcome === 'shrub').length;
    const wilted = outcomes.filter(outcome => outcome === 'wilted').length;
    const treeCount = Math.max(0, trees[index] ?? 0);
    if (count <= 0 && !isCompleted && shrubs <= 0 && treeCount <= 0 && wilted <= 0) return [];
    const goal = (goals[index] ?? '').trim();
    return [{ index, completedPomodoros: count, isCompleted, goal: goal || null, shrubs, trees: treeCount, wilted }];
  });
}

function reviewDay(key, records) {
  const focus = records.histogram[key];
  const dayBlocks = blocks(records.dailyBlocks[key], records.blockHistory[key] ?? [], records.plants[key]);
  const taskSessions = focus?.taskSessions ?? [];
  const day = {
    key, pomodoros: Math.max(0, focus?.pomodoros ?? 0), minutes: Math.max(0, focus?.minutes ?? 0), blocks: dayBlocks, taskSessions,
    completedBlocks: dayBlocks.filter(block => block.isCompleted).length,
    shrubs: dayBlocks.reduce((sum, block) => sum + block.shrubs, 0),
    trees: dayBlocks.reduce((sum, block) => sum + block.trees, 0),
    wilted: dayBlocks.reduce((sum, block) => sum + block.wilted, 0),
  };
  day.hasRecords = day.pomodoros > 0 || day.minutes > 0 || dayBlocks.length > 0 || taskSessions.length > 0;
  return day;
}

function csvCell(value) {
  const first = value.trimStart()[0];
  const guarded = (first && '=+-@＝＋－＠'.includes(first)) || /^[\t\r\n]/.test(value);
  return `"${guarded ? "'" : ''}${value.replaceAll('"', '""')}"`;
}

/** `records` holds the histogram, dailyBlocks, blockHistory and plants maps keyed by calendar day. */
export function focusReview(range, end, records) {
  const days = Array.from({ length: range }, (_, index) => reviewDay(addDays(end, index - range + 1), records));
  const totals = days.reduce((sum, day) => ({
    pomodoros: sum.pomodoros + day.pomodoros, minutes: sum.minutes + day.minutes,
    activeDays: sum.activeDays + (day.pomodoros > 0 || day.minutes > 0 ? 1 : 0),
    completedBlocks: sum.completedBlocks + day.completedBlocks, shrubs: sum.shrubs + day.shrubs,
    trees: sum.trees + day.trees, wilted: sum.wilted + day.wilted,
  }), { pomodoros: 0, minutes: 0, activeDays: 0, completedBlocks: 0, shrubs: 0, trees: 0, wilted: 0 });
  const startKey = days[0]?.key ?? '';
  const endKey = days.at(-1)?.key ?? '';
  return {
    days, totals, startKey, endKey,
    hasRecords: days.some(day => day.hasRecords),
    tasks: summarizeTasks(days.flatMap(day => day.taskSessions)),
    /** An explicit pick wins inside the window; otherwise the latest day with records. */
    selectedDay: key => days.find(day => day.key === key) ?? days.findLast(day => day.hasRecords) ?? days.at(-1),
    // Apple's bytes: fixed header, one row per day, CRLF after every row, UTF-8 without BOM, no goals.
    csv: ['date,pomodoros,minutes,completed_blocks,shrubs,trees,wilted', ...days.map(day =>
      `${day.key},${day.pomodoros},${day.minutes},${day.completedBlocks},${day.shrubs},${day.trees},${day.wilted}`)].join('\r\n') + '\r\n',
    csvFilename: `专注复盘-${startKey}-${endKey}.csv`,
    taskCsv: ['date,task_id,task_title,minutes', ...days.flatMap(day => [...day.taskSessions]
      .sort((a, b) => (a.id.toUpperCase() < b.id.toUpperCase() ? -1 : a.id.toUpperCase() > b.id.toUpperCase() ? 1 : 0))
      .map(session => `${day.key},${csvCell(session.taskId)},${csvCell(session.title)},${session.minutes}`))].join('\r\n') + '\r\n',
    taskCsvFilename: `任务专注-${startKey}-${endKey}.csv`,
  };
}

export function earliestDate(records) {
  const keys = [...new Set([records.histogram, records.dailyBlocks, records.blockHistory, records.plants].flatMap(Object.keys))].sort();
  return keys.find(key => parseDayKey(key) && reviewDay(key, records).hasRecords) ?? null;
}

/** An earlier window counted from a fixed anchor day, so it does not slide across midnight. */
export const pageEnd = (page, range) => addDays(page.anchor, page.offset * range);

export function nextPage(page, range, today) {
  const next = { ...page, offset: page.offset + 1 };
  return pageEnd(next, range) < today ? next : null;
}

export function historySummary(histogram) {
  const days = Object.values(histogram);
  const pomodoros = days.reduce((sum, day) => sum + day.pomodoros, 0);
  const minutes = days.reduce((sum, day) => sum + day.minutes, 0);
  return { pomodoros, minutes, hours: minutes / 60, average: days.length ? pomodoros / days.length : 0, days: days.length };
}

export function duration(minutes) {
  if (minutes < 60) return `${minutes} 分钟`;
  if (minutes % 60 === 0) return `${minutes / 60} 小时`;
  return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
}
