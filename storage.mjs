// Versioned browser storage. v2 keeps the native record shapes under one key so every change is
// written atomically. The v1 key is never modified or deleted: it stays as the migration source.
import {
  blockIndexAt, dayKey, idleTimer, logicalDayKey, normalizeSettings, parseDayKey, weekdayName,
} from './model.mjs';
import { defaultCategories, emptyCloudState, freshTopThree } from './tasks.mjs';

export const storageKey = 'habitica-pomodoro-web:v2';
export const legacyKey = 'habitica-pomodoro-web:v1';
export const schemaVersion = 2;

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = value => typeof value === 'string' ? value : '';
const count = value => Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : 0;
const stringList = value => Array.isArray(value) ? value.filter(item => typeof item === 'string') : [];
const stringMap = value => isObject(value) ? Object.fromEntries(Object.entries(value).filter(([, item]) => typeof item === 'string')) : {};
const dayMap = (raw, decode) => isObject(raw) ? Object.fromEntries(Object.entries(raw).flatMap(([key, value]) => {
  const decoded = decode(value, key);
  return decoded ? [[key, decoded]] : [];
})) : {};

export function freshState() {
  return {
    version: schemaVersion, settings: normalizeSettings(), timer: idleTimer(), topThree: freshTopThree(),
    histogram: {}, dailyBlocks: {}, blockHistory: {}, plants: {}, reminders: { sprint: '' },
  };
}

// MARK: Lenient decoders (missing fields take defaults like the native decodeIfPresent readers)
export function decodeSession(raw) {
  if (!isObject(raw)) return null;
  const minutes = count(raw.minutes);
  if (!text(raw.id) || !text(raw.taskId) || !text(raw.title) || minutes <= 0) return null;
  return { id: raw.id, taskId: raw.taskId, title: raw.title, minutes, startedAt: Number.isFinite(raw.startedAt) ? raw.startedAt : 0 };
}

function decodeDay(raw) {
  if (!isObject(raw)) return null;
  const day = { pomodoros: count(raw.pomodoros), minutes: count(raw.minutes), weekday: text(raw.weekday) };
  const sessions = Array.isArray(raw.taskSessions) ? raw.taskSessions.map(decodeSession).filter(Boolean) : [];
  if (sessions.length) day.taskSessions = sessions;
  const unassigned = stringList(raw.unassignedFocusIDs);
  if (unassigned.length) day.unassignedFocusIDs = unassigned;
  return day;
}

const decodeDaily = (raw, key) => isObject(raw) ? {
  date: text(raw.date) || key,
  blockProgress: Array.isArray(raw.blockProgress) ? raw.blockProgress.map(value => Number.isFinite(value) ? Math.trunc(value) : 0) : [],
  blockGoals: Array.isArray(raw.blockGoals) ? raw.blockGoals.map(text) : [],
} : null;

const decodeBlockEntries = (raw, key) => Array.isArray(raw) ? raw.filter(isObject).map(entry => ({
  date: text(entry.date) || key, blockIndex: Number.isInteger(entry.blockIndex) ? entry.blockIndex : 0,
  pomodoros: count(entry.pomodoros), isComplete: entry.isComplete === true,
  completedAt: Number.isFinite(entry.completedAt) ? entry.completedAt : null,
})) : null;

const decodePlants = raw => isObject(raw) ? {
  attempts: Array.isArray(raw.attempts) ? raw.attempts.map(list => Array.isArray(list) ? list.filter(item => item === 'shrub' || item === 'wilted') : []) : [],
  trees: Array.isArray(raw.trees) ? raw.trees.map(count) : [],
} : null;

function decodeTask(raw) {
  if (!isObject(raw) || !text(raw.id)) return null;
  const task = {
    id: raw.id, title: text(raw.title), isCompleted: raw.isCompleted === true,
    habiticaTaskId: text(raw.habiticaTaskId) || null, movedToToday: raw.movedToToday === true,
    syncPending: raw.syncPending === true, cloudAccount: text(raw.cloudAccount) || null,
  };
  const attempt = raw.cloudCreateAttempt;
  if (isObject(attempt) && typeof attempt.title === 'string' && typeof attempt.notes === 'string') {
    task.cloudCreateAttempt = { title: attempt.title, notes: attempt.notes, tags: stringList(attempt.tags) };
  }
  return task;
}

function decodeCloudState(raw) {
  const state = emptyCloudState();
  if (!isObject(raw)) return state;
  state.categoryTagIds = stringMap(raw.categoryTagIds);
  state.deletedCloudIds = stringList(raw.deletedCloudIds);
  state.confirmedDeletedCloudIds = stringList(raw.confirmedDeletedCloudIds);
  state.pendingTagRenames = stringMap(raw.pendingTagRenames);
  state.deletedCreateAttempts = Array.isArray(raw.deletedCreateAttempts) ? raw.deletedCreateAttempts.flatMap(item => {
    const task = decodeTask({ id: item?.id, cloudCreateAttempt: item?.attempt });
    return task?.cloudCreateAttempt ? [{ id: task.id, attempt: task.cloudCreateAttempt }] : [];
  }) : [];
  return state;
}

export function decodeTopThree(raw) {
  const store = freshTopThree();
  if (!isObject(raw)) return store;
  const names = stringList(raw.categoryNames);
  store.categoryNames = names.length >= defaultCategories.length ? names : [...names, ...defaultCategories.slice(names.length)];
  store.history = dayMap(raw.history, (day, key) => isObject(day) ? {
    date: text(day.date) || key,
    taskGroups: Array.isArray(day.taskGroups) ? day.taskGroups.map(group => Array.isArray(group) ? group.map(decodeTask).filter(Boolean) : []) : [],
  } : null);
  for (const day of Object.values(store.history)) while (day.taskGroups.length < store.categoryNames.length) day.taskGroups.push([]);
  store.cloudAccount = text(raw.cloudAccount);
  Object.assign(store, decodeCloudState(raw));
  store.cloudStates = dayMap(raw.cloudStates, decodeCloudState);
  return store;
}

function decodeTimer(raw, settings) {
  const phases = ['IDLE', 'POMODORO', 'BREAK', 'LONG_BREAK', 'BREAK_EXTENSION', 'MANUAL_BREAK'];
  if (!isObject(raw) || !phases.includes(raw.phase)) return idleTimer();
  const timer = {
    ...idleTimer(Math.min(12, count(raw.combo))), phase: raw.phase, phaseID: text(raw.phaseID) || null,
    endsAt: count(raw.endsAt), pausedRemaining: count(raw.pausedRemaining), totalSeconds: count(raw.totalSeconds),
    customBreak: raw.customBreak === true, completedSet: typeof raw.completedSet === 'boolean' ? raw.completedSet : count(raw.combo) >= settings.pomoSetNum,
  };
  timer.running = raw.running === true && timer.endsAt > 0;
  if (!timer.running) timer.endsAt = 0;
  // Old snapshots without captured settings keep their duration but never invent a scoring owner.
  const business = isObject(raw.phaseSnapshot?.business) ? raw.phaseSnapshot.business : null;
  if (business) timer.phaseSnapshot = { cloudAccount: text(raw.phaseSnapshot.cloudAccount) || null, business: normalizeSettings(business) };
  else if (timer.phase !== 'IDLE') timer.phaseSnapshot = { cloudAccount: null, business: structuredClone(settings) };
  if (timer.phase === 'POMODORO') {
    const focus = decodeSession(raw.taskFocus);
    if (focus) timer.taskFocus = focus;
    timer.focusID = focus?.id ?? (text(raw.focusID) || null);
  }
  if (timer.phase !== 'IDLE' && timer.phase !== 'MANUAL_BREAK' && !timer.running && timer.pausedRemaining <= 0) return idleTimer(timer.combo);
  return timer;
}

/** Top-level parts must have the right type; a malformed entry inside a part is dropped. */
export function decodeState(raw) {
  const parts = ['settings', 'timer', 'topThree', 'histogram', 'dailyBlocks', 'blockHistory', 'plants', 'reminders'];
  if (!isObject(raw) || parts.some(part => raw[part] !== undefined && !isObject(raw[part]))) throw new Error('Invalid stored state');
  const settings = normalizeSettings(raw.settings);
  const state = {
    version: schemaVersion, settings, timer: decodeTimer(raw.timer, settings), topThree: decodeTopThree(raw.topThree),
    histogram: dayMap(raw.histogram, decodeDay), dailyBlocks: dayMap(raw.dailyBlocks, decodeDaily),
    blockHistory: dayMap(raw.blockHistory, decodeBlockEntries), plants: dayMap(raw.plants, decodePlants),
    reminders: { sprint: text(raw.reminders?.sprint) },
  };
  if (isObject(raw.legacy)) state.legacy = { sessions: stringList(raw.legacy.sessions), tasks: stringList(raw.legacy.tasks) };
  return state;
}

// MARK: v1 → v2
const legacyCategory = { work: 0, personal: 1, chores: 2 };

export function isLegacyState(raw) {
  return isObject(raw) && isObject(raw.timer) && isObject(raw.settings) && isObject(raw.blocks)
    && Array.isArray(raw.tasks) && Array.isArray(raw.sessions);
}

/** Stable UUID-shaped id for a v1 task known only by its title (FNV-1a, deterministic). */
export function legacyTaskId(title) {
  let hex = '';
  for (let seed = 0; seed < 4; seed += 1) {
    let hash = 0x811c9dc5 ^ seed;
    for (const unit of `pomo-web-legacy-task:${title}`) hash = Math.imul(hash ^ unit.codePointAt(0), 0x01000193) >>> 0;
    hex += hash.toString(16).padStart(8, '0');
  }
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-8${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`.toUpperCase();
}

const legacyTasks = raw => raw.tasks.filter(task => isObject(task) && text(task.id) && typeof task.title === 'string'
  && parseDayKey(task.day) && Object.hasOwn(legacyCategory, task.category));
const legacySessions = raw => raw.sessions.filter(item => isObject(item) && text(item.id) && Number.isFinite(item.end) && Number.isFinite(item.minutes) && item.minutes > 0);

/** v1 recorded the title of the task picked for a focus; link it to that task's id when unambiguous. */
function resolveLegacyTask(raw, title, settings, ...times) {
  const tasks = legacyTasks(raw).filter(task => task.title === title);
  const days = new Set(times.map(time => logicalDayKey(settings, time)));
  const sameDay = tasks.filter(task => days.has(task.day));
  const unique = sameDay.length === 1 ? sameDay[0] : tasks.length === 1 ? tasks[0] : null;
  return unique ? unique.id.toUpperCase() : legacyTaskId(title);
}

function importLegacySessions(state, raw, sessions) {
  for (const item of sessions) {
    const id = item.id.toUpperCase();
    const minutes = Math.max(1, Math.round(item.minutes));
    const key = dayKey(item.end);
    const day = state.histogram[key] ?? { pomodoros: 0, minutes: 0, weekday: weekdayName(item.end) };
    if (typeof item.task === 'string' && item.task.trim()) {
      // v1 kept no start time; the review shows these as "开始时间未知".
      const taskId = resolveLegacyTask(raw, item.task, state.settings, item.end - minutes * 60_000, item.end);
      day.taskSessions = [...(day.taskSessions ?? []), { id, taskId, title: item.task, minutes, startedAt: 0 }];
    } else day.unassignedFocusIDs = [...(day.unassignedFocusIDs ?? []), id];
    day.pomodoros += 1;
    day.minutes += minutes;
    state.histogram[key] = day;
    // v1 counted every focus in a fixed 3-hour block from 04:00, the native default ranges.
    const index = Number.isInteger(item.block) && item.block >= 1 && item.block <= 8 ? item.block - 1 : blockIndexAt(state.settings, item.end);
    const daily = state.dailyBlocks[key] ?? { date: key, blockProgress: [], blockGoals: [] };
    while (daily.blockProgress.length <= index || daily.blockProgress.length < 8) daily.blockProgress.push(0);
    daily.blockProgress[index] += 1;
    state.dailyBlocks[key] = daily;
    state.legacy.sessions.push(id);
  }
}

function importLegacyTasks(state, tasks) {
  for (const item of tasks) {
    const id = item.id.toUpperCase();
    const store = state.topThree;
    const day = store.history[item.day] ?? { date: item.day, taskGroups: store.categoryNames.map(() => []) };
    day.taskGroups[legacyCategory[item.category]].push({
      id, title: item.title, isCompleted: item.done === true, habiticaTaskId: null, movedToToday: false,
      syncPending: false, cloudAccount: null,
    });
    store.history[item.day] = day;
    state.legacy.tasks.push(id);
  }
}

function legacyTimer(raw, settings, now) {
  const timer = raw.timer;
  const round = Math.min(12, count(raw.round));
  const started = text(timer.id);
  if (!['focus', 'short', 'long'].includes(timer.phase)) return idleTimer(round);
  const total = Math.max(60, Math.round(count(timer.duration) / 1000));
  const snapshot = { cloudAccount: null, business: structuredClone(settings) };
  if (!started) {
    // v1 offered the next break after a finished focus; that is a native manual break.
    if (timer.phase === 'focus' || round === 0) return idleTimer(round);
    return { ...idleTimer(round), phase: 'MANUAL_BREAK', completedSet: round >= settings.pomoSetNum, phaseSnapshot: snapshot };
  }
  const running = Number.isFinite(timer.end) && timer.end > 0;
  const next = {
    ...idleTimer(round), phaseID: started.toUpperCase(), totalSeconds: total, running,
    endsAt: running ? timer.end : 0, pausedRemaining: running ? 0 : Math.max(1, Math.ceil(count(timer.remaining) / 1000)),
    phaseSnapshot: snapshot,
  };
  if (timer.phase === 'focus') {
    next.phase = 'POMODORO';
    next.focusID = started.toUpperCase();
    snapshot.business.pomoDurationMins = Math.max(1, Math.round(total / 60));
    if (typeof timer.task === 'string' && timer.task.trim()) {
      next.taskFocus = { id: next.focusID, taskId: resolveLegacyTask(raw, timer.task, settings, now), title: timer.task, minutes: Math.max(1, Math.round(total / 60)), startedAt: 0 };
    }
  } else if (timer.phase === 'long') {
    next.phase = 'LONG_BREAK';
    next.completedSet = round >= settings.pomoSetNum;
    next.customBreak = !next.completedSet;
  } else next.phase = 'BREAK';
  return next;
}

export function migrateLegacy(raw, now = Date.now()) {
  if (!isLegacyState(raw)) throw new Error('Invalid v1 state');
  const state = freshState();
  const old = raw.settings;
  const value = (key, fallback) => Number.isFinite(old[key]) ? old[key] : fallback;
  const goals = Array.from({ length: 8 }, (_, index) => text(raw.blocks[index + 1]).trim());
  state.settings = normalizeSettings({
    ...state.settings,
    pomoDurationMins: value('focus', 25), breakDuration: value('short', 5), longBreakDuration: value('long', 15),
    pomoSetNum: value('rounds', 4), blockPomoCount: value('target', 6),
    sound: old.sound !== false,
    ambientSource: old.ambient === 'off' ? 'custom' : 'qishi',
    ambientSoundVolume: value('ambientVolume', 0.45),
    blockGoals: goals,
  });
  state.legacy = { sessions: [], tasks: [] };
  state.timer = legacyTimer(raw, state.settings, now);
  importLegacyTasks(state, legacyTasks(raw));
  importLegacySessions(state, raw, legacySessions(raw));
  return state;
}

/** Records an older open tab wrote to v1 after the migration; ids already imported are skipped. */
export function mergeLegacy(state, raw) {
  if (!state.legacy || !isLegacyState(raw)) return 0;
  const sessions = new Set(state.legacy.sessions);
  const tasks = new Set(state.legacy.tasks);
  const newSessions = legacySessions(raw).filter(item => !sessions.has(item.id.toUpperCase()));
  const newTasks = legacyTasks(raw).filter(item => !tasks.has(item.id.toUpperCase()));
  importLegacyTasks(state, newTasks);
  importLegacySessions(state, raw, newSessions);
  return newSessions.length + newTasks.length;
}

/**
 * Read the stored state. Anything that cannot be decoded is left untouched and the page runs
 * read-only, so no write can replace data this version does not understand.
 */
export function loadState(storage, now = Date.now()) {
  let current;
  let legacy;
  try {
    current = storage.getItem(storageKey);
    legacy = storage.getItem(legacyKey);
  } catch {
    return { state: freshState(), writable: false, notice: '浏览器存储不可用。本页仍可计时，刷新后可能丢失本次改动。' };
  }
  const readOnly = message => ({ state: freshState(), writable: false, notice: message });
  let legacyRaw = null;
  if (legacy !== null) {
    try { legacyRaw = JSON.parse(legacy); } catch { legacyRaw = undefined; }
  }
  if (current !== null) {
    let raw;
    try { raw = JSON.parse(current); } catch { return readOnly('浏览器中保存的数据无法读取。为避免覆盖，本页不会保存改动。'); }
    if (isObject(raw) && Number.isFinite(raw.version) && raw.version > schemaVersion) {
      return readOnly('数据由更新版本的专注番茄钟保存。为避免覆盖，本页不会保存改动，请使用最新版本。');
    }
    let state;
    try { state = decodeState(raw); } catch { return readOnly('浏览器中保存的数据无法读取。为避免覆盖，本页不会保存改动。'); }
    const merged = legacyRaw ? mergeLegacy(state, legacyRaw) : 0;
    return { state, writable: true, dirty: merged > 0, merged };
  }
  if (legacy === null) return { state: freshState(), writable: true };
  if (!isLegacyState(legacyRaw)) return readOnly('旧版保存的数据无法读取。为避免覆盖，本页不会保存改动。');
  return { state: migrateLegacy(legacyRaw, now), writable: true, dirty: true, migrated: true };
}

export function saveState(storage, state) {
  storage.setItem(storageKey, JSON.stringify(state));
}

