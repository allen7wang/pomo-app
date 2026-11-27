// Business rules shared with the native apps (Android PomodoroViewModel / Apple PomodoroEngine).
// Record shapes follow the native JSON files; every function takes `now` so tests can pin time.
export const appVersion = '3.2.0';

export const phaseLabels = {
  IDLE: '准备就绪', POMODORO: '专注', BREAK: '短休息', LONG_BREAK: '长休息',
  BREAK_EXTENSION: '休息延长', MANUAL_BREAK: '该休息了',
};
export const breakChoices = [1, 5, 15, 30];
export const soundOptions = ['None', 'Chime', ...Array.from({ length: 9 }, (_, i) => `Sound${i + 1}.mp3`), 'clockTicking.mp3'];
export const ambientOptions = ['None', 'Ambient Clock.mp3', 'Ambient Rain.mp3', 'Ambient Crickets.mp3', 'Ambient Birds.mp3'];
export const limits = {
  pomoDurationMins: [1, 120], breakDuration: [1, 60], longBreakDuration: [1, 120], breakExtention: [0, 30],
  pomoSetNum: [1, 12], blockCount: [1, 24], blockPomoCount: [1, 12], blockReminderMinutes: [1, 60],
};
const appleEpoch = 978_307_200_000; // Swift Codable dates count seconds from 2001-01-01.

let makeId = () => crypto.randomUUID().toUpperCase();
export const newId = () => makeId();
export function setIdFactory(factory) { makeId = factory; }

const pad = value => String(value).padStart(2, '0');
const clamp = (value, [min, max]) => Math.min(max, Math.max(min, value));

// MARK: Days. Statistics, blocks and plants use calendar days; tasks use the logical day.
export function dayKey(time) {
  const date = new Date(time);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

export function addDays(key, offset) {
  const [year, month, day] = key.split('-').map(Number);
  const date = new Date(Date.UTC(year, month - 1, day + offset));
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`;
}

export function parseDayKey(key) {
  if (typeof key !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(key)) return null;
  return addDays(key, 0) === key ? key : null;
}

export function minuteOfDay(time) {
  const date = new Date(time);
  return date.getHours() * 60 + date.getMinutes();
}

export function weekdayName(time) {
  return new Intl.DateTimeFormat('zh-CN', { weekday: 'long' }).format(time);
}

/** Task day: the first block start is the boundary (default 04:00). */
export function logicalDayKey(settings, time) {
  const first = settings.blockTimeRanges[0];
  const boundary = first ? rangeStart(first) : 0;
  return minuteOfDay(time) < boundary ? addDays(dayKey(time), -1) : dayKey(time);
}

// MARK: Blocks
export function defaultRanges() {
  return [[4, 7], [7, 10], [10, 13], [13, 16], [16, 19], [19, 22], [22, 1], [1, 4]]
    .map(([start, end]) => ({ startHour: start, startMinute: 0, endHour: end, endMinute: 0 }));
}
export const rangeStart = range => range.startHour * 60 + range.startMinute;
export const rangeEnd = range => range.endHour * 60 + range.endMinute;
export const rangeLabel = range => `${pad(range.startHour)}:${pad(range.startMinute)}–${pad(range.endHour)}:${pad(range.endMinute)}`;

/** Spans midnight when start > end; equal endpoints mean the whole day. */
export function rangeContains(range, minute) {
  const start = rangeStart(range);
  const end = rangeEnd(range);
  if (start > end) return minute >= start || minute < end;
  return start === end || (minute >= start && minute < end);
}

export function currentBlockIndex(settings, time) {
  const minute = minuteOfDay(time);
  for (let index = 0; index < settings.blockCount; index += 1) {
    if (rangeContains(settings.blockTimeRanges[index], minute)) return index;
  }
  return null;
}

/** Between configured ranges, stay with the block that ended most recently. */
export function blockIndexAt(settings, time) {
  const current = currentBlockIndex(settings, time);
  if (current !== null) return current;
  const minute = minuteOfDay(time);
  let best = 0;
  let gap = Infinity;
  for (let index = 0; index < settings.blockCount; index += 1) {
    const since = (minute - rangeEnd(settings.blockTimeRanges[index]) + 1440) % 1440;
    if (since < gap) { gap = since; best = index; }
  }
  return best;
}

// MARK: Settings (native UserSettings field names; credentials never stored on the web)
export function defaultSettings() {
  return {
    pomoDurationMins: 25, breakDuration: 5, longBreakDuration: 30, breakExtention: 2, pomoSetNum: 4,
    manualBreak: true, resetPomoAfterBreak: false,
    pomoHabitPlus: false, pomoHabitMinus: false, pomoSetHabitPlus: false, breakExtentionFails: false,
    breakExtentionNotify: false, longBreakNotify: false,
    customPomodoroTask: false, pomodoroTaskId: null, customSetTask: false, pomodoroSetTaskId: null,
    pomoEndSound: 'Chime', pomoEndSoundVolume: 0.5, breakEndSound: 'Chime', breakEndSoundVolume: 0.5,
    ambientSource: 'qishi', ambientSound: 'None', ambientSoundVolume: 0.5,
    enableBlockMode: true, blockCount: 8, blockPomoCount: 6, blockGoals: [], blockTimeRanges: defaultRanges(),
    blockTasks: [], blockRewardEnabled: true, blockSprintReminder: true, blockStartReminder: true, blockReminderMinutes: 5,
    sound: true, // Web only: quick mute for the two end sounds.
  };
}

function decodeRange(raw) {
  const part = (value, max, fallback) => Number.isInteger(value) ? clamp(value, [0, max]) : fallback;
  return {
    startHour: part(raw?.startHour, 23, 4), startMinute: part(raw?.startMinute, 59, 0),
    endHour: part(raw?.endHour, 23, 7), endMinute: part(raw?.endMinute, 59, 0),
  };
}

export function decodeBlockTask(raw) {
  if (!raw || typeof raw !== 'object') return null;
  return {
    id: typeof raw.id === 'string' && raw.id ? raw.id : newId(),
    title: typeof raw.title === 'string' ? raw.title : '',
    isCompleted: raw.isCompleted === true,
    estimatedPomo: Number.isInteger(raw.estimatedPomo) ? clamp(raw.estimatedPomo, [1, 12]) : 1,
  };
}

/** Missing or invalid fields take defaults; surplus block arrays survive a lower block count. */
export function normalizeSettings(raw = {}) {
  const settings = defaultSettings();
  const source = raw && typeof raw === 'object' ? raw : {};
  for (const [key, fallback] of Object.entries(settings)) {
    const value = source[key];
    if (typeof fallback === 'boolean' && typeof value === 'boolean') settings[key] = value;
    else if (typeof fallback === 'number' && typeof value === 'number' && Number.isFinite(value)) settings[key] = value;
  }
  for (const [key, range] of Object.entries(limits)) {
    settings[key] = clamp(Math.round(settings[key]), range);
  }
  for (const key of ['pomoEndSoundVolume', 'breakEndSoundVolume', 'ambientSoundVolume']) {
    settings[key] = clamp(settings[key], [0, 1]);
  }
  for (const key of ['pomoEndSound', 'breakEndSound']) {
    if (soundOptions.includes(source[key])) settings[key] = source[key];
  }
  if (ambientOptions.includes(source.ambientSound)) settings.ambientSound = source.ambientSound;
  if (source.ambientSource === 'qishi' || source.ambientSource === 'custom') settings.ambientSource = source.ambientSource;
  for (const key of ['pomodoroTaskId', 'pomodoroSetTaskId']) {
    settings[key] = typeof source[key] === 'string' && source[key].trim() ? source[key].trim() : null;
  }
  if (Array.isArray(source.blockGoals)) settings.blockGoals = source.blockGoals.map(goal => typeof goal === 'string' ? goal : '');
  if (Array.isArray(source.blockTimeRanges)) settings.blockTimeRanges = source.blockTimeRanges.map(decodeRange);
  if (Array.isArray(source.blockTasks)) {
    settings.blockTasks = source.blockTasks.map(list => Array.isArray(list) ? list.map(decodeBlockTask).filter(Boolean) : []);
  }
  while (settings.blockGoals.length < settings.blockCount) settings.blockGoals.push('');
  while (settings.blockTasks.length < settings.blockCount) settings.blockTasks.push([]);
  while (settings.blockTimeRanges.length < settings.blockCount) {
    const start = (4 * 60 + settings.blockTimeRanges.length * 180) % 1440;
    const end = (start + 180) % 1440;
    settings.blockTimeRanges.push({ startHour: Math.floor(start / 60), startMinute: start % 60, endHour: Math.floor(end / 60), endMinute: end % 60 });
  }
  return settings;
}

// MARK: Timer (Android timer snapshot shape)
export function idleTimer(combo = 0) {
  return {
    phase: 'IDLE', phaseID: null, endsAt: 0, pausedRemaining: 0, totalSeconds: 0, combo,
    running: false, customBreak: false, completedSet: false, phaseSnapshot: null,
  };
}

export function remainingSeconds(timer, now) {
  if (!timer.endsAt) return timer.pausedRemaining;
  return Math.max(0, Math.ceil((timer.endsAt - now) / 1000));
}

/** The business configuration of a phase: captured at focus start, never the live settings. */
export function phaseSettings(state) {
  const business = state.timer.phaseSnapshot?.business;
  return business ? normalizeSettings({ ...state.settings, ...business }) : state.settings;
}

function capture(settings, owner) {
  return { cloudAccount: owner || null, business: structuredClone(settings) };
}

function begin(timer, phase, seconds, at) {
  Object.assign(timer, {
    phase, phaseID: newId(), endsAt: at + seconds * 1000, pausedRemaining: 0, totalSeconds: seconds, running: true,
  });
  if (phase !== 'POMODORO') { delete timer.taskFocus; delete timer.focusID; }
}

function resetTimer(state, resetCombo) {
  const combo = resetCombo ? 0 : state.timer.combo;
  const completedSet = resetCombo ? false : state.timer.completedSet;
  state.timer = { ...idleTimer(combo), completedSet };
}

export function startPomodoro(state, now, { task = null, owner = null } = {}) {
  const timer = state.timer;
  if (timer.phase === 'POMODORO') return null;
  timer.customBreak = false;
  if (timer.completedSet) timer.combo = 0;
  timer.completedSet = false;
  const settings = state.settings;
  timer.phaseSnapshot = capture(settings, owner);
  begin(timer, 'POMODORO', settings.pomoDurationMins * 60, now);
  const focus = task && {
    id: newId(), taskId: task.id, title: task.title, minutes: settings.pomoDurationMins, startedAt: now,
  };
  if (focus) timer.taskFocus = focus;
  else delete timer.taskFocus;
  timer.focusID = focus ? focus.id : newId();
  return focus ? `开始专注「${task.title}」。` : '专注计时已开始。';
}

function startBreak(state, at) {
  const timer = state.timer;
  const settings = phaseSettings(state);
  const long = timer.completedSet;
  begin(timer, long ? 'LONG_BREAK' : 'BREAK', (long ? settings.longBreakDuration : settings.breakDuration) * 60, at);
  return long ? '长休息已开始。' : '短休息已开始。';
}

export function pauseTimer(state, now) {
  const timer = state.timer;
  if (!timer.running) return null;
  timer.pausedRemaining = Math.max(1, remainingSeconds(timer, now));
  timer.endsAt = 0;
  timer.running = false;
  return '计时已暂停。';
}

export function resumeTimer(state, now) {
  const timer = state.timer;
  if (timer.running || timer.phase === 'IDLE' || timer.phase === 'MANUAL_BREAK' || timer.pausedRemaining <= 0) return null;
  timer.endsAt = now + timer.pausedRemaining * 1000;
  timer.pausedRemaining = 0;
  timer.running = true;
  return '计时已继续。';
}

/** Main control: pause or resume a phase, start the waiting break, or start focus. */
export function activate(state, now, options = {}) {
  const timer = state.timer;
  if (timer.phase === 'MANUAL_BREAK') return startBreak(state, now);
  if (timer.phase === 'BREAK_EXTENSION') return startPomodoro(state, now, options);
  if (timer.running) return pauseTimer(state, now);
  if (timer.phase === 'IDLE') return startPomodoro(state, now, options);
  return resumeTimer(state, now);
}

/** Idle-only custom break: never completes a set or clears the earned combo. */
export function takeBreak(state, now, minutes, owner = null) {
  const timer = state.timer;
  if (!breakChoices.includes(minutes) || timer.phase !== 'IDLE' || timer.running) return null;
  timer.customBreak = true;
  timer.phaseSnapshot = capture(state.settings, owner);
  begin(timer, 'LONG_BREAK', minutes * 60, now);
  return `休息 ${minutes} 分钟。`;
}

/** Explicit abandon: no completion, resets the combo; a focus wilts its plant. */
export function abandon(state, now) {
  const timer = state.timer;
  if (timer.phase === 'IDLE') return null;
  const interrupted = timer.phase === 'POMODORO';
  const settings = phaseSettings(state);
  const owner = timer.phaseSnapshot?.cloudAccount ?? null;
  if (interrupted && settings.enableBlockMode) recordAbandonedPlant(state, settings, now);
  resetTimer(state, true);
  const effects = interrupted && settings.pomoHabitMinus && owner ? [{ kind: 'penalty', owner, settings: habitIds(settings) }] : [];
  return { message: interrupted ? '已放弃本次番茄，组合已中断。' : '已结束当前阶段。', effects };
}

/** Skip to a short break: no completion and no penalty, but the combo restarts. */
export function skipToBreak(state, now) {
  const timer = state.timer;
  if (timer.phase !== 'POMODORO') return null;
  const settings = phaseSettings(state);
  if (settings.enableBlockMode) recordAbandonedPlant(state, settings, now);
  timer.combo = 0;
  timer.completedSet = false;
  startBreak(state, now);
  return '已跳到短休息，本次不计完成。';
}

export function skipBreak(state, now, options = {}) {
  const timer = state.timer;
  if (!['BREAK', 'LONG_BREAK', 'BREAK_EXTENSION', 'MANUAL_BREAK'].includes(timer.phase)) return null;
  resetTimer(state, !timer.customBreak && timer.completedSet);
  return startPomodoro(state, now, options);
}

const habitIds = settings => ({
  customPomodoroTask: settings.customPomodoroTask, pomodoroTaskId: settings.pomodoroTaskId,
  customSetTask: settings.customSetTask, pomodoroSetTaskId: settings.pomodoroSetTaskId,
});

/** Settle expired phases at their own deadlines: focus → break → grace, never a new focus. */
export function settleTimer(state, now) {
  const result = { changed: false, messages: [], effects: [] };
  for (let step = 0; step < 6; step += 1) {
    const timer = state.timer;
    if (!timer.running || !timer.endsAt || timer.endsAt > now) break;
    result.changed = true;
    const deadline = timer.endsAt;
    if (timer.phase === 'POMODORO') pomodoroEnds(state, deadline, result);
    else if (timer.phase === 'BREAK' || timer.phase === 'LONG_BREAK') breakEnds(state, deadline, result);
    else if (timer.phase === 'BREAK_EXTENSION') extensionEnds(state, deadline, result);
    else resetTimer(state, false);
  }
  return result;
}

function pomodoroEnds(state, deadline, result) {
  const timer = state.timer;
  const settings = phaseSettings(state);
  const owner = timer.phaseSnapshot?.cloudAccount ?? null;
  const minutes = Math.floor(timer.totalSeconds / 60);
  const session = timer.taskFocus && minutes > 0 ? { ...timer.taskFocus, minutes } : null;
  recordFocus(state.histogram, { id: session?.id ?? timer.focusID ?? newId(), minutes, at: deadline, session });
  const combo = timer.combo + 1;
  const setComplete = combo >= settings.pomoSetNum;
  let block = null;
  if (settings.enableBlockMode) block = recordBlockPomodoro(state, settings, deadline, setComplete);
  let message = setComplete ? '一组番茄完成！' : '番茄完成！';
  if (block?.completed) {
    message = `时间块 B${block.index + 1} 完成！${settings.blockGoals[block.index] ? ` ${settings.blockGoals[block.index]}。` : ''}${breakSuggestion(block.index, settings, deadline)}`;
  } else if (block) message += ` B${block.index + 1}：${block.count} / ${settings.blockPomoCount}`;
  result.messages.push(message);
  if (block?.sprint) {
    result.messages.push(`冲刺时间：B${block.index + 1} 已完成 ${block.count} / ${settings.blockPomoCount} 个番茄。`);
  }
  result.effects.push({ kind: 'sound', name: settings.pomoEndSound, volume: settings.pomoEndSoundVolume, at: deadline });
  result.effects.push({ kind: 'notify', title: setComplete ? '一组番茄完成' : '番茄结束', body: message, at: deadline });
  const plus = settings.pomoHabitPlus;
  const comboReward = setComplete && settings.pomoSetHabitPlus;
  const blockReward = Boolean(block?.completed && settings.blockRewardEnabled);
  if (owner && (plus || comboReward || blockReward)) {
    result.effects.push({ kind: 'reward', owner, settings: habitIds(settings), plus, combo: comboReward, block: blockReward });
  }
  Object.assign(timer, { combo, completedSet: setComplete, phase: settings.manualBreak ? 'MANUAL_BREAK' : 'IDLE', running: false, endsAt: 0, pausedRemaining: 0, totalSeconds: 0 });
  delete timer.taskFocus;
  delete timer.focusID;
  if (!settings.manualBreak) result.messages.push(startBreak(state, deadline));
}

function breakEnds(state, deadline, result) {
  const timer = state.timer;
  const settings = phaseSettings(state);
  const snapshot = timer.phaseSnapshot;
  const owner = snapshot?.cloudAccount ?? null;
  const long = timer.phase === 'LONG_BREAK';
  resetTimer(state, long && !timer.customBreak);
  result.messages.push(long ? '休息结束，可以开始下一个番茄。' : '短休息结束，回到专注。');
  result.effects.push({ kind: 'sound', name: settings.breakEndSound, volume: settings.breakEndSoundVolume, at: deadline });
  result.effects.push({ kind: 'notify', title: long ? '休息结束' : '短休息结束', body: '开始下一个番茄吧', at: deadline });
  // The short-break reminder does not depend on the grace period.
  if (owner && (long ? settings.longBreakNotify : settings.breakExtentionNotify)) {
    const text = long ? 'Long Break is over'
      : settings.breakExtention > 0 ? `Back to work! ${settings.breakExtention} minutes left for Break Extension.` : 'Back to work!';
    result.effects.push({ kind: 'pm', owner, text });
  }
  if (!long && settings.breakExtention > 0) {
    state.timer.phaseSnapshot = snapshot;
    begin(state.timer, 'BREAK_EXTENSION', settings.breakExtention * 60, deadline);
  }
  // A zero extension ends the break directly: no timeout, penalty or combo reset.
}

function extensionEnds(state, deadline, result) {
  const settings = phaseSettings(state);
  const owner = state.timer.phaseSnapshot?.cloudAccount ?? null;
  resetTimer(state, settings.resetPomoAfterBreak);
  result.messages.push(settings.resetPomoAfterBreak ? '休息延长结束，本组已重置。' : '休息延长结束，组合保留，开始专注吧。');
  if (settings.breakExtention > 0 && settings.breakExtentionFails && owner) {
    result.effects.push({ kind: 'penalty', owner, settings: habitIds(settings) });
  }
}

export function breakSuggestion(index, settings, time) {
  const next = settings.blockTimeRanges[(index + 1) % settings.blockCount];
  const until = next ? (rangeStart(next) - minuteOfDay(time) + 1440) % 1440 : null;
  if (until !== null && until >= 1 && until <= 10) return '建议短休息 2 分钟：下一块即将开始。';
  return (index + 1) % 2 === 0 ? '建议长休息 15–20 分钟。' : '建议普通休息 5–10 分钟。';
}

// MARK: History (DayHistogram per calendar day; ids make a retried completion count once)
export function containsFocus(day, id) {
  return Boolean(day?.taskSessions?.some(session => session.id === id) || day?.unassignedFocusIDs?.includes(id));
}

export function recordFocus(histogram, { id, minutes, at, session = null }) {
  if (Object.values(histogram).some(day => containsFocus(day, id))) return false;
  const key = dayKey(at);
  const day = histogram[key] ?? { pomodoros: 0, minutes: 0, weekday: weekdayName(at) };
  if (session) day.taskSessions = [...(day.taskSessions ?? []), session];
  else day.unassignedFocusIDs = [...(day.unassignedFocusIDs ?? []), id];
  day.pomodoros += 1;
  day.minutes += minutes;
  if (!day.weekday) day.weekday = weekdayName(at);
  histogram[key] = day;
  return true;
}

// MARK: Blocks and plants (separate records, calendar days)
const alignedAttempts = (attempts, completed) => {
  const missing = Math.max(0, completed - attempts.filter(outcome => outcome === 'shrub').length);
  return [...Array(missing).fill('shrub'), ...attempts];
};

export function blockCount(state, key, index) {
  return state.dailyBlocks[key]?.blockProgress?.[index] ?? 0;
}

/** Completed shrubs are filled in for counts recorded before planting existed. */
export function plantRow(state, key, index) {
  const attempts = state.plants[key]?.attempts?.[index] ?? [];
  return { outcomes: alignedAttempts(attempts, blockCount(state, key, index)), trees: state.plants[key]?.trees?.[index] ?? 0 };
}

function plantDay(state, key, index) {
  const day = state.plants[key] ?? { attempts: [], trees: [] };
  while (day.attempts.length <= index) day.attempts.push([]);
  while (day.trees.length <= index) day.trees.push(0);
  state.plants[key] = day;
  return day;
}

function recordBlockPomodoro(state, settings, time, comboCompleted) {
  const key = dayKey(time);
  const index = blockIndexAt(settings, time);
  const daily = state.dailyBlocks[key] ?? { date: key, blockProgress: Array(settings.blockCount).fill(0), blockGoals: [] };
  while (daily.blockProgress.length <= index) daily.blockProgress.push(0);
  daily.blockProgress[index] += 1;
  daily.blockGoals = [...settings.blockGoals];
  state.dailyBlocks[key] = daily;
  const count = daily.blockProgress[index];
  const plants = plantDay(state, key, index);
  plants.attempts[index] = [...alignedAttempts(plants.attempts[index], count - 1), 'shrub'];
  if (comboCompleted) plants.trees[index] += 1;
  // A block completion is claimed once per calendar day and index, even after a reset.
  const history = state.blockHistory[key] ?? [];
  let completed = false;
  if (count >= settings.blockPomoCount && !history.some(entry => entry.blockIndex === index && entry.isComplete)) {
    state.blockHistory[key] = [...history, { date: key, blockIndex: index, pomodoros: count, isComplete: true, completedAt: (time - appleEpoch) / 1000 }];
    completed = true;
  }
  const threshold = Math.max(1, Math.floor((settings.blockPomoCount * 2 + 2) / 3));
  const sprintKey = `${key}-${index}`;
  const sprint = settings.blockSprintReminder && count >= threshold && count < settings.blockPomoCount && state.reminders.sprint !== sprintKey;
  if (sprint) state.reminders.sprint = sprintKey;
  return { index, count, completed, sprint };
}

function recordAbandonedPlant(state, settings, now) {
  const key = dayKey(now);
  const index = blockIndexAt(settings, now);
  const plants = plantDay(state, key, index);
  plants.attempts[index] = [...alignedAttempts(plants.attempts[index], blockCount(state, key, index)), 'wilted'];
}

/** Reset today's count of the current block; plants and the completion claim stay. */
export function resetCurrentBlock(state, now) {
  const key = dayKey(now);
  const index = blockIndexAt(state.settings, now);
  const daily = state.dailyBlocks[key];
  if (daily && index < daily.blockProgress.length) daily.blockProgress[index] = 0;
  return `B${index + 1} 今日计数已重置；植物与达标记录保留，不会重复奖励。`;
}

export function clearBlockHistory(state) {
  state.dailyBlocks = {};
  state.blockHistory = {};
  state.plants = {};
  return '已清空时间块与种植记录。';
}

export function clearHistogram(state) {
  state.histogram = {};
  return '已清空番茄统计和任务用时。';
}

export function todayTotals(state, now) {
  const day = state.histogram[dayKey(now)];
  return { pomodoros: day?.pomodoros ?? 0, minutes: day?.minutes ?? 0 };
}
