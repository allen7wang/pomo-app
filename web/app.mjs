import {
  abandon, activate, addDays, ambientOptions, appVersion, blockIndexAt, clearBlockHistory, clearHistogram, dayKey,
  decodeBlockTask, limits, logicalDayKey, minuteOfDay, newId, normalizeSettings, phaseSettings, plantRow, rangeLabel,
  rangeStart, remainingSeconds, resetCurrentBlock, settleTimer, skipBreak, skipToBreak, soundOptions, startPomodoro,
  takeBreak, todayTotals,
} from './model.mjs';
import {
  activeTasks, addTask, canAddTask, fixedSlotCategories, fixedTaskLimit, getTasks, isUnfinished, locate,
  moveTaskToToday, pendingCount, removeTask, renameCategory, setTaskTitle, toggleTask, unfinishedTasks,
} from './tasks.mjs';
import {
  chronologicalSessions, duration, earliestDate, focusReview, historySummary, nextPage, pageEnd, reviewRanges, summarizeTasks,
} from './review.mjs';
import { legacyKey, loadState, saveState, storageKey } from './storage.mjs';
import { createApi, createBudget, isValidUserId, ownerKey, roleFigures } from './habitica.mjs';
import { createSync } from './sync.mjs';
import { createSounds, soundLabel } from './sound.mjs';
import catalog from './qishi_presets.json' with { type: 'json' };
import { createAmbient } from './qishi.mjs';

const $ = selector => document.querySelector(selector);
const icon = name => `<svg class="icon" aria-hidden="true"><use href="#i-${name}"/></svg>`;
const escape = value => String(value ?? '').replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[character]);
const pad = value => String(value).padStart(2, '0');
const dateFormatter = new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric', weekday: 'long' });
const timeFormatter = new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hour12: false });
const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
const weekdayOf = key => weekdays[new Date(`${key}T12:00:00Z`).getUTCDay()];
const dialog = $('#dialog');
const views = ['focus', 'tasks', 'review', 'habitica'];
const sounds = createSounds({ pageURL: document.baseURI });
const qishi = createAmbient({ presets: Array.isArray(catalog.presets) ? catalog.presets : [], pageURL: document.baseURI, createAudio: () => new Audio() });
const budgets = new Map();
const remindedBlocks = new Set();
let selectedTask = '';
let review = { range: 7, page: null, day: null, sessions: 0, dayTasks: false, tasks: false };
let lastCalendar = '';
let lastTimer = '';
let lastClock = '';
let settling = false;
let toastTimeout;
let syncTimeout;
let view;
let connection = null;
let account = null;
let habiticaBusy = false;
let habiticaMessage = '';
let syncBusy = false;
let syncMessage = '';
let writable = true;
let state;

// MARK: Storage
function showNotice(message) {
  const notice = $('#storage-error');
  notice.hidden = !message;
  notice.textContent = message ?? '';
}

function reload() {
  const loaded = loadState(localStorage);
  if (!loaded.writable) {
    writable = false;
    showNotice(loaded.notice);
    return loaded;
  }
  state = loaded.state;
  return loaded;
}

function persist() {
  if (!writable) return false;
  try {
    saveState(localStorage, state);
    return true;
  } catch {
    writable = false;
    showNotice('浏览器存储不可用。本页仍可计时，刷新后可能丢失本次改动。');
    return false;
  }
}

function announce(message) {
  $('#status').textContent = message;
  clearTimeout(toastTimeout);
  toastTimeout = setTimeout(() => { $('#status').textContent = ''; }, 5200);
}

/** Read the latest state, settle expired phases, apply one change and write it back atomically. */
async function changeState(change, { skipAfterSettle = false } = {}) {
  let outcome;
  const apply = () => {
    const active = document.activeElement?.dataset.focusKey;
    if (writable) reload();
    const now = Date.now();
    const settled = settleTimer(state, now);
    let result = null;
    let failure = null;
    try {
      if (change && (!settled.changed || !skipAfterSettle)) result = change(state, now) ?? null;
    } catch (error) { failure = error; }
    if (settled.changed || (change && !failure)) persist();
    renderData();
    if (active && document.activeElement === document.body) {
      document.querySelector(`[data-focus-key="${CSS.escape(active)}"]`)?.focus({ preventScroll: true });
    }
    syncAudio();
    runEffects([...settled.effects, ...(result?.effects ?? [])], now);
    const message = typeof result === 'string' ? result : result?.message;
    const toast = [...settled.messages, failure ? null : message].filter(Boolean).join(' ');
    if (toast) announce(toast);
    if (failure) throw failure;
    outcome = result;
  };
  if (navigator.locks && writable) await navigator.locks.request(storageKey, apply);
  else apply();
  return outcome;
}

// MARK: Sounds, ambience and alerts
function ambientIntent(current = state, running = current.timer.phase === 'POMODORO' && current.timer.running) {
  return {
    enabled: current.settings.ambientSource === 'qishi', running,
    phase: current.timer.phase === 'POMODORO' ? 'focus' : 'break',
    sessionId: current.timer.phase === 'POMODORO' ? current.timer.focusID ?? null : null,
    volume: current.settings.ambientSoundVolume,
  };
}

function showScene(preset) {
  const label = $('#qishi-scene');
  label.hidden = !preset?.name;
  label.textContent = preset?.name ? `栖时 · ${preset.name}` : '';
}

function syncAudio() {
  showScene(qishi.reconcile(ambientIntent()));
  const timer = state.timer;
  const focus = timer.phase === 'POMODORO';
  sounds.reconcile({
    name: state.settings.ambientSource === 'custom' ? state.settings.ambientSound : 'None', volume: state.settings.ambientSoundVolume,
    running: focus && timer.running, sessionId: focus ? timer.focusID : null,
  });
}

function notify(title, body) {
  if (document.visibilityState === 'visible' || !('Notification' in globalThis) || Notification.permission !== 'granted') return;
  try { new Notification(title, { body, icon: './icon-192.png', tag: 'pomo-web' }); } catch { /* unsupported */ }
}

function runEffects(effects, now) {
  for (const effect of effects) {
    // A phase settled long after its deadline (page closed or asleep) replays no sound or alert.
    const late = effect.at && now - effect.at > 3000;
    if (effect.kind === 'sound') { if (!late && state.settings.sound) sounds.play(effect.name, effect.volume); }
    else if (effect.kind === 'notify') { if (!late) notify(effect.title, effect.body); }
    else void habiticaEffect(effect);
  }
}

// MARK: Habitica rewards (only for the account captured when the phase began)
async function habitId(current, settings, combo) {
  const key = `${combo}/${combo ? settings.customSetTask : settings.customPomodoroTask}/${combo ? settings.pomodoroSetTaskId : settings.pomodoroTaskId}`;
  current.habits[key] ??= current.api.ensureHabit(settings, combo).catch(failure => { delete current.habits[key]; throw failure; });
  return current.habits[key];
}

async function habiticaEffect(effect) {
  const current = connection;
  if (!current || current.owner !== effect.owner) return;
  try {
    if (effect.kind === 'pm') {
      await current.api.sendPrivateMessage(effect.text);
      return;
    }
    const ids = [];
    if (effect.kind === 'penalty') ids.push([await habitId(current, effect.settings, false), 'down']);
    else {
      const pomo = effect.plus || effect.block ? await habitId(current, effect.settings, false) : null;
      if (effect.plus) ids.push([pomo, 'up']);
      if (effect.combo) ids.push([await habitId(current, effect.settings, true), 'up']);
      if (effect.block) ids.push([pomo, 'up']); // the block reward is a separate, one-time extra score
    }
    for (const [id, direction] of ids) {
      if (connection !== current) return;
      await current.api.scoreTask(id, direction);
    }
    if (connection === current) void refreshAccount({ quiet: true });
  } catch (failure) {
    if (connection === current) announce(`${failure.message} 本机记录已保留，未自动重试以免重复计分。`);
  }
}

// MARK: Timer
function timerView(now) {
  const timer = state.timer;
  const settings = phaseSettings(state);
  const idleSeconds = state.settings.pomoDurationMins * 60;
  const waiting = (timer.completedSet ? settings.longBreakDuration : settings.breakDuration) * 60;
  const seconds = timer.phase === 'IDLE' ? idleSeconds : timer.phase === 'MANUAL_BREAK' ? waiting : remainingSeconds(timer, now);
  const total = timer.phase === 'IDLE' || timer.phase === 'MANUAL_BREAK' ? seconds : timer.totalSeconds || seconds;
  return { timer, seconds, total };
}

function phaseText(timer) {
  const paused = !timer.running && !['IDLE', 'MANUAL_BREAK'].includes(timer.phase);
  if (paused) return '已暂停';
  return {
    IDLE: '准备就绪', POMODORO: '专注中', BREAK: '短休息', LONG_BREAK: timer.customBreak ? '自选休息' : '长休息',
    BREAK_EXTENSION: '休息延长', MANUAL_BREAK: '该休息了',
  }[timer.phase];
}

function renderTimer(now) {
  const { timer, seconds, total } = timerView(now);
  const time = `${pad(Math.floor(seconds / 60))}:${pad(seconds % 60)}`;
  const clockKey = `${time}/${total}`;
  if (lastClock !== clockKey) {
    lastClock = clockKey;
    $('#clock').textContent = time;
    $('#clock-progress').setAttribute('stroke-dashoffset', String(100 * (1 - seconds / Math.max(1, total))));
    document.title = timer.running ? `${time} · ${phaseText(timer)} · 专注番茄钟` : '专注番茄钟 · Habitica Pomodoro';
  }
  const key = JSON.stringify([timer.phase, timer.running, timer.combo, timer.customBreak, timer.completedSet, timer.taskFocus?.title, state.settings.pomoSetNum, state.settings.sound]);
  if (lastTimer === key) return;
  lastTimer = key;
  const phase = timer.phase;
  const paused = !timer.running && !['IDLE', 'MANUAL_BREAK'].includes(phase);
  const resting = ['BREAK', 'LONG_BREAK', 'BREAK_EXTENSION', 'MANUAL_BREAK'].includes(phase);
  $('#timer-state').textContent = phaseText(timer);
  $('#timer-state').toggleAttribute('data-running', timer.running);
  const task = timer.taskFocus?.title;
  $('#clock-caption').textContent = phase === 'POMODORO' ? `${paused ? '已暂停' : '专注中'}${task ? ` · ${task}` : ''}`
    : phase === 'IDLE' ? `准备开始第 ${timer.combo + 1} 个番茄`
    : phase === 'MANUAL_BREAK' ? `点击开始${timer.completedSet ? '长' : '短'}休息`
    : phase === 'BREAK_EXTENSION' ? '休息延长：回到专注'
    : paused ? '休息已暂停' : '放松一下';
  const primary = phase === 'MANUAL_BREAK' ? ['play', '开始休息']
    : phase === 'BREAK_EXTENSION' || phase === 'IDLE' ? ['play', '开始专注']
    : timer.running ? ['pause', '暂停'] : ['play', resting ? '继续休息' : '继续专注'];
  $('#timer-primary').innerHTML = `${icon(primary[0])} ${primary[1]}`;
  const skip = $('#timer-skip');
  skip.hidden = !(phase === 'POMODORO' || resting) || phase === 'BREAK_EXTENSION';
  skip.title = phase === 'POMODORO' ? '跳到短休息（不计完成）' : '跳过休息，开始专注';
  skip.setAttribute('aria-label', skip.title);
  const stop = $('#timer-abandon');
  stop.disabled = phase === 'IDLE';
  stop.title = phase === 'POMODORO' ? '放弃本次番茄' : '结束当前阶段';
  stop.setAttribute('aria-label', stop.title);
  for (const button of document.querySelectorAll('[data-break]')) button.disabled = phase !== 'IDLE' || timer.running;
  const sound = $('#sound-toggle');
  sound.innerHTML = icon(state.settings.sound ? 'volume' : 'mute');
  sound.title = state.settings.sound ? '关闭结束提示音' : '开启结束提示音';
  sound.setAttribute('aria-label', '结束提示音');
  sound.setAttribute('aria-pressed', String(state.settings.sound));
  const rounds = state.settings.pomoSetNum;
  const dots = Array.from({ length: rounds }, (_, index) => `<span${index < timer.combo ? ' class="filled"' : ''}></span>`).join('');
  $('#round-progress').innerHTML = `<span class="round-dots" aria-hidden="true">${dots}</span> 本组 ${Math.min(timer.combo, rounds)} / ${rounds}`;
}

function picker(day) {
  const field = $('#focus-task');
  const timer = state.timer;
  const choosing = timer.phase === 'IDLE' || timer.phase === 'BREAK_EXTENSION';
  $('#focus-task-label').hidden = !choosing;
  const choices = state.topThree.categoryNames.flatMap((_, category) => activeTasks(state.topThree, day, category)).filter(isUnfinished);
  if (!choices.some(task => task.id === selectedTask)) selectedTask = '';
  field.replaceChildren(new Option('自由专注（不关联任务）', ''), ...choices.map(task => new Option(task.title, task.id)));
  field.value = selectedTask;
}

function timerAction(action) {
  const expected = state.timer;
  const owner = connection?.owner ?? null;
  sounds.unlock();
  if (action === 'timer') {
    const startsFocus = ['IDLE', 'BREAK_EXTENSION'].includes(expected.phase) || (expected.phase === 'POMODORO' && !expected.running);
    // Start audio inside the click so the browser allows it; the scene follows the focus id.
    if (startsFocus) showScene(qishi.prepare(ambientIntent(state, true)));
    return changeState((current, now) => {
      if (current.timer.phaseID !== expected.phaseID || current.timer.running !== expected.running) return null;
      const task = locateTodayTask(current, now, selectedTask);
      return activate(current, now, { task, owner });
    }, { skipAfterSettle: true });
  }
  if (action === 'skip') {
    return changeState((current, now) => {
      if (current.timer.phaseID !== expected.phaseID) return '计时已在另一个页面更新。';
      return current.timer.phase === 'POMODORO' ? skipToBreak(current, now) : skipBreak(current, now, { owner });
    }, { skipAfterSettle: true });
  }
  if (action === 'abandon' && expected.phase !== 'IDLE') {
    const run = () => changeState((current, now) => {
      if (current.timer.phaseID !== expected.phaseID) return '计时已在另一个页面更新。';
      return abandon(current, now);
    }, { skipAfterSettle: true });
    if (expected.phase !== 'POMODORO') return run();
    confirm('放弃本次番茄', '未完成的专注不计数，本组组合清零；开启时间块时这株植物会枯萎。', '放弃番茄', run);
  }
}

function locateTodayTask(current, now, id) {
  if (!id) return null;
  const day = logicalDayKey(current.settings, now);
  const found = locate(current.topThree, id);
  return found && found.key === day && isUnfinished(found.task) ? found.task : null;
}

function startTaskFocus(id) {
  const owner = connection?.owner ?? null;
  sounds.unlock();
  if (state.timer.phase === 'POMODORO') return announce('请先结束正在进行或暂停的番茄，再开始另一项任务。');
  showScene(qishi.prepare(ambientIntent(state, true)));
  void changeState((current, now) => {
    if (current.timer.phase === 'POMODORO') return '请先结束正在进行或暂停的番茄。';
    const task = locateTodayTask(current, now, id);
    if (!task) return '这个任务已完成、已转移或不属于今天。';
    return startPomodoro(current, now, { task, owner });
  }).then(() => { if (state.timer.taskFocus?.taskId === id) location.hash = '#focus'; });
}

// MARK: Rendering
function empty(title, copy, name = 'sprout') {
  return `<div class="empty">${icon(name)}<div><strong>${title}</strong>${copy}</div></div>`;
}

function taskRow(task, key, category, place, { editable = false, focusable = false, pending = false } = {}) {
  const name = escape(task.title);
  const attrs = `data-id="${escape(task.id)}" data-key="${key}" data-category="${category}"`;
  const check = `<button class="task-check" type="button" data-action="check" ${attrs} data-focus-key="${place}-${escape(task.id)}" aria-label="${name}" aria-pressed="${task.isCompleted}">${task.isCompleted ? icon('check') : ''}</button>`;
  const focus = focusable && isUnfinished(task)
    ? `<button class="icon-button" type="button" data-action="focus" ${attrs} aria-label="专注「${name}」" ${state.timer.phase === 'POMODORO' ? 'disabled' : ''}>${icon('play')}</button>` : '';
  const actions = editable ? `<button class="icon-button" type="button" data-action="edit" ${attrs} aria-label="编辑 ${name}">${icon('edit')}</button>
    <button class="icon-button" type="button" data-action="delete" ${attrs} aria-label="删除 ${name}">${icon('trash')}</button>` : '';
  const badge = pending && task.syncPending ? '<small class="sync-tag">待同步</small>' : '';
  return `<li class="task-row${task.isCompleted ? ' done' : ''}">${check}<span class="task-name">${name}${badge}</span>${focus}${actions}</li>`;
}

function plantRail(key, index, target) {
  const { outcomes, trees } = plantRow(state, key, index);
  const visible = outcomes.slice(-target);
  const slots = Array.from({ length: target }, (_, slot) => visible[slot] === 'shrub' ? `<span class="planted" title="灌木">${icon('sprout')}</span>`
    : visible[slot] === 'wilted' ? `<span class="wilted" title="枯萎">${icon('wilted')}</span>` : '<span></span>').join('');
  return `${slots}<span class="tree${trees ? ' grown' : ''}" title="一组完成种下的树">${icon('tree')}${trees > 1 ? `<b>×${trees}</b>` : ''}</span>`;
}

function renderFocus(now, day, today) {
  const totals = todayTotals(state, now);
  $('#daily-total').innerHTML = `${icon('sprout')} 今日 ${totals.pomodoros} 个番茄 · ${totals.minutes} 分钟`;
  const store = state.topThree;
  const todays = store.categoryNames.flatMap((_, category) => activeTasks(store, day, category).map(task => ({ task, category })));
  const preview = todays.filter(item => !item.task.isCompleted).slice(0, 3);
  const taskCopy = todays.length ? empty('今日任务已完成', '可以添加下一件要做的事。', 'check') : empty('今天还没有任务', '从一件想完成的事开始。', 'task');
  $('#task-preview').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">TODAY</p><h2>今日要事</h2></div><a class="text-button" href="#tasks">全部 ${icon('arrow')}</a></div>
    ${preview.length ? `<ul class="task-list">${preview.map(item => taskRow(item.task, day, item.category, 'preview', { focusable: true })).join('')}</ul>` : taskCopy}
    <button class="text-button add-line" type="button" data-action="add" data-category="0">${icon('plus')} 添加任务</button>`;
  const settings = state.settings;
  if (!settings.enableBlockMode) {
    $('#current-block').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">TIME BLOCK</p><h2>时间块未开启</h2></div></div>
      <p class="panel-copy">开启后按时段记录番茄、达标和种植。</p><button class="text-button add-line" type="button" data-action="settings">${icon('settings')} 在设置中开启</button>`;
    $('#block-garden').hidden = true;
  } else {
    const index = blockIndexAt(settings, now);
    const range = settings.blockTimeRanges[index];
    const count = state.dailyBlocks[today]?.blockProgress?.[index] ?? 0;
    const tasks = settings.blockTasks[index] ?? [];
    $('#current-block').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">TIME BLOCK</p><h2>当前时间块</h2></div><div class="integration-actions"><button class="text-button" type="button" data-action="block" data-index="${index}">${icon('edit')} 编辑</button><button class="text-button" type="button" data-action="reset-block">${icon('reset')} 重置</button></div></div>
      <div class="block-label"><span class="block-number">B${index + 1}</span><div class="block-info"><strong>${escape(settings.blockGoals[index] || '为这段时间定个目标')}</strong><small>${rangeLabel(range)}${tasks.length ? ` · ${tasks.filter(task => task.isCompleted).length}/${tasks.length} 项块任务` : ''}</small></div><span class="block-count">${count} / ${settings.blockPomoCount}</span></div>
      <div class="plant-rail" aria-label="B${index + 1} 今日种植">${plantRail(today, index, settings.blockPomoCount)}</div>`;
    const rows = Array.from({ length: settings.blockCount }, (_, block) => {
      const done = state.dailyBlocks[today]?.blockProgress?.[block] ?? 0;
      return `<li><button type="button" class="garden-row" data-action="block" data-index="${block}"${block === index ? ' aria-current="true"' : ''}>
        <span class="block-number">B${block + 1}</span><span class="garden-info"><strong>${escape(settings.blockGoals[block] || '设置目标与块任务')}</strong><small>${rangeLabel(settings.blockTimeRanges[block])}</small></span>
        <span class="plant-rail" aria-hidden="true">${plantRail(today, block, settings.blockPomoCount)}</span><span class="block-count">${done} / ${settings.blockPomoCount}</span></button></li>`;
    }).join('');
    $('#block-garden').hidden = false;
    $('#block-garden').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">GARDEN</p><h2>时间块 · 种植</h2></div><span class="muted">完成种灌木 · 放弃或跳过枯萎 · 一组完成种树</span></div><ul class="garden-list">${rows}</ul>`;
  }
  $('#week-preview').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">LAST 7 DAYS</p><h2>最近七天</h2></div><a class="text-button" href="#review">查看复盘 ${icon('arrow')}</a></div>${chart(focusReview(7, today, state).days, null)}`;
  picker(day);
}

function chart(days, selected) {
  const peak = Math.max(1, ...days.map(day => day.minutes));
  const labelEvery = days.length <= 7 ? 1 : days.length <= 30 ? 5 : 15;
  const columns = days.map((day, index) => {
    const label = days.length <= 7 ? day.key.slice(5).replace('-', '/') : day.key.slice(8);
    const shown = (days.length - 1 - index) % labelEvery === 0;
    const body = `<span>${shown ? day.minutes : ''}</span><div class="bar-slot"><div class="bar" data-height="${100 * day.minutes / peak}"></div></div><time datetime="${day.key}">${shown ? label : ''}</time>`;
    const title = `${day.key}，专注 ${day.minutes} 分钟，完成 ${day.pomodoros} 个番茄`;
    return selected === null
      ? `<div class="chart-col" role="listitem" aria-label="${title}" title="${title}">${body}</div>`
      : `<button type="button" class="chart-col" data-action="review-day" data-day="${day.key}" aria-pressed="${day.key === selected}" aria-label="${title}" title="${title}">${body}</button>`;
  }).join('');
  return `<div class="chart" data-range="${days.length}" ${selected === null ? 'role="list" aria-label="每日专注分钟数"' : 'role="group" aria-label="专注趋势，点选日期查看当日明细"'}>${columns}</div>`;
}

function renderTasks(day) {
  const store = state.topThree;
  const connected = Boolean(connection);
  const yesterday = addDays(day, -1);
  const categoryPanels = store.categoryNames.map((name, category) => {
    const items = activeTasks(store, day, category);
    const limit = category < fixedSlotCategories ? fixedTaskLimit : null;
    return `<article class="panel"><div class="panel-heading"><h2>${escape(name)}</h2><div class="integration-actions"><span class="badge">今天 ${items.length}${limit ? ` / ${limit}` : ''}</span><button class="icon-button" type="button" data-action="rename" data-category="${category}" aria-label="重命名分类「${escape(name)}」">${icon('edit')}</button></div></div>
      ${items.length ? `<ul class="task-list">${items.map(task => taskRow(task, day, category, 'board', { editable: true, focusable: true, pending: connected })).join('')}</ul>` : empty('暂无任务', '添加一件今天想做的事。')}
      <button class="text-button add-line" type="button" data-action="add" data-category="${category}" ${canAddTask(store, day, category) ? '' : 'disabled'}>${icon('plus')} ${limit && items.length >= limit ? `已满 ${limit} 件` : `添加到${escape(name)}`}</button></article>`;
  }).join('');
  const yesterdayGroups = store.categoryNames.map((name, category) => {
    const items = getTasks(store, yesterday, category);
    if (!items.length) return '';
    return `<li class="group-label">${escape(name)}</li>${items.map(task => `<li class="task-row${task.isCompleted ? ' done' : ''}"><span class="status-dot" aria-label="${task.isCompleted ? '已完成' : '未完成'}">${task.isCompleted ? icon('check') : ''}</span><span class="task-name">${escape(task.title)}${task.movedToToday ? ' <small class="muted">已移到今天</small>' : ''}</span>
      ${isUnfinished(task) ? `<button class="text-button" type="button" data-action="carry" data-id="${escape(task.id)}" data-key="${yesterday}" data-category="${category}" ${canAddTask(store, day, category) ? '' : 'disabled'}>移到今天 ${icon('arrow')}</button>` : ''}</li>`).join('')}`;
  }).join('');
  const older = unfinishedTasks(store, day);
  const carryRows = older.map(({ key, category, task }) => {
    const full = !canAddTask(store, day, category);
    return `<li class="task-row"><span class="task-name">${escape(task.title)} <small class="muted">${key} · ${escape(store.categoryNames[category])}${full ? ` · 今天「${escape(store.categoryNames[category])}」已满` : ''}</small></span>
    <button class="text-button" type="button" data-action="carry" data-id="${escape(task.id)}" data-key="${key}" data-category="${category}" ${full ? 'disabled' : ''}>转到今天 ${icon('arrow')}</button>
    <button class="icon-button" type="button" data-action="delete-unfinished" data-id="${escape(task.id)}" data-key="${key}" data-category="${category}" aria-label="删除 ${escape(task.title)}">${icon('trash')}</button></li>`;
  }).join('');
  const pending = connected ? pendingCount(store, connection.owner) : 0;
  $('#task-actions').innerHTML = `${connected ? `<button class="button button-quiet" type="button" data-action="sync" ${syncBusy ? 'disabled' : ''}>${icon('sync')} ${syncBusy ? '同步中…' : '同步 Habitica'}</button>` : ''}<button class="button button-primary" type="button" data-action="add" data-category="0">${icon('plus')} 添加任务</button>`;
  const syncNotice = connected && (pending || syncMessage)
    ? `<p class="notice sync-notice" role="status">${pending ? `本机有 ${pending} 项修改待同步到 Habitica。` : ''}${escape(syncMessage)}</p>` : '';
  $('#task-board').innerHTML = `${syncNotice}<div class="category-grid">${categoryPanels}</div>
    <article class="panel later-panel"><div class="panel-heading"><h2>昨天 · ${yesterday}</h2><span class="badge">只读</span></div>
      ${yesterdayGroups ? `<ul class="task-list">${yesterdayGroups}</ul>` : empty('昨天没有任务', '昨天的任务会在这里只读显示。')}</article>
    <article class="panel later-panel"><div class="panel-heading"><h2>未完成任务</h2><span class="badge">${older.length} 件</span></div>
      ${older.length ? `<ul class="task-list">${carryRows}</ul>` : empty('没有跨天未完成的任务', '昨天及更早未完成的任务会显示在这里。')}</article>`;
}

function taskBreakdown(tasks, totalPomodoros, expanded, action) {
  if (!tasks.length) return `<p class="muted">从今日任务开始并完成一个番茄，即可看到任务用时。</p>`;
  const linked = tasks.reduce((sum, task) => sum + task.pomodoros, 0);
  const rows = (expanded ? tasks : tasks.slice(0, 5)).map(task => `<li class="task-row"><span class="task-name">${escape(task.title)}</span><span class="badge">${task.minutes} 分钟 · ${task.pomodoros} 个番茄</span></li>`).join('');
  return `<p class="muted">${linked > totalPomodoros ? linked : `${linked} / ${totalPomodoros}`} 个番茄关联了任务</p><ul class="task-list">${rows}</ul>
    ${tasks.length > 5 ? `<button class="text-button" type="button" data-action="${action}">${expanded ? '收起任务' : `查看全部 ${tasks.length} 项任务`}</button>` : ''}`;
}

function sessionDetails(day) {
  const expanded = review.sessions > 0;
  const sessions = chronologicalSessions(day.taskSessions);
  const rows = sessions.slice(0, review.sessions).map(session => {
    let start = '开始时间未知';
    if (session.startedAt > 0) {
      const startDay = dayKey(session.startedAt);
      start = `${startDay === day.key ? '' : `${startDay} `}${timeFormatter.format(session.startedAt)} 开始`;
    }
    return `<li class="session-row"><strong>${escape(session.title)}</strong><small>${start} · ${session.minutes} 分钟</small></li>`;
  }).join('');
  const more = Math.min(5, sessions.length - review.sessions);
  return `<button class="disclosure" type="button" data-action="sessions" aria-expanded="${expanded}">专注明细<span class="muted">${sessions.length} 条</span>${icon(expanded ? 'minus' : 'plus')}</button>
    ${expanded ? `<ul class="session-list">${rows}</ul>${more > 0 ? `<button class="text-button" type="button" data-action="more-sessions">再显示 ${more} 条</button>` : ''}` : ''}`;
}

function metric(value, caption) {
  return `<div class="metric"><strong>${value}</strong><small>${caption}</small></div>`;
}

function renderReview(today) {
  const end = review.page ? pageEnd(review.page, review.range) : today;
  const report = focusReview(review.range, end, state);
  const earliest = earliestDate(state);
  const canPageBack = Boolean(earliest && earliest < report.startKey);
  const day = report.hasRecords ? report.selectedDay(review.day) : null;
  const summary = historySummary(state.histogram);
  const ranges = reviewRanges.map(value => `<button class="button button-quiet" type="button" data-action="range" data-range="${value}" data-focus-key="range-${value}" aria-pressed="${value === review.range}">${value} 天</button>`).join('');
  const recorded = report.days.filter(item => item.hasRecords).reverse();
  const detail = day ? `<article class="panel later-panel" id="review-day"><div class="panel-heading"><h2>当日明细</h2><span class="badge">${day.key} ${weekdayOf(day.key)}</span></div>
      ${day.hasRecords ? `<div class="metric-row">${metric(duration(day.minutes), '专注时长')}${metric(day.pomodoros, '完成番茄')}${metric(day.completedBlocks, '达标时间块')}</div>
      ${day.taskSessions.length ? `<h3 class="section-title">任务用时</h3>${taskBreakdown(summarizeTasks(day.taskSessions), day.pomodoros, review.dayTasks, 'day-tasks')}${sessionDetails(day)}` : ''}
      <h3 class="section-title">时间块</h3>${day.blocks.length ? `<ul class="task-list">${day.blocks.map(block => `<li class="task-row"><span class="block-number small">B${block.index + 1}</span><span class="task-name">${escape(block.goal ?? '')}</span><span class="badge">${block.completedPomodoros} 个番茄${block.isCompleted ? ' · 曾达标' : ''}</span></li>`).join('')}</ul>` : '<p class="muted">当天没有时间块记录</p>'}
      <h3 class="section-title">种植</h3>${day.shrubs || day.trees || day.wilted ? `<div class="metric-row">${metric(day.shrubs, '灌木')}${metric(day.trees, '树')}${metric(day.wilted, '枯萎')}</div>` : '<p class="muted">当天没有种植记录</p>'}`
      : '<p class="muted">当天没有专注、时间块或种植记录。</p>'}</article>` : '';
  $('#review-body').innerHTML = `<div class="stats-grid"><div class="panel"><small>专注时长</small><strong>${duration(report.totals.minutes)}</strong></div><div class="panel"><small>完成番茄</small><strong>${report.totals.pomodoros}</strong></div><div class="panel"><small>专注天数</small><strong>${report.totals.activeDays} 天</strong></div></div>
    <article class="panel later-panel"><div class="panel-heading"><h2>专注趋势</h2><div class="review-range" aria-label="复盘范围">${ranges}</div></div>
      <div class="period-nav"><button class="icon-button" type="button" data-action="page-back" aria-label="上一个日期区间" ${canPageBack ? '' : 'disabled'}>${icon('left')}</button><span>${report.startKey} 至 ${report.endKey}</span><button class="icon-button" type="button" data-action="page-next" aria-label="下一个日期区间" ${review.page ? '' : 'disabled'}>${icon('right')}</button>${review.page ? '<button class="text-button" type="button" data-action="page-today">回到今天</button>' : ''}</div>
      ${report.hasRecords ? `${chart(report.days, day?.key ?? '')}<p class="muted">按完成的专注分钟计，点选日期查看当日明细。</p>` : empty('这段时间还没有专注记录', '所选日期内没有番茄、时间块或种植记录。', 'review')}</article>
    ${detail}
    ${recorded.length ? `<article class="panel later-panel"><div class="panel-heading"><h2>有记录的日期</h2><span class="badge">${recorded.length} 天</span></div><ul class="task-list">${recorded.map(item => `<li><button type="button" class="day-row" data-action="review-day" data-day="${item.key}" aria-pressed="${item.key === day?.key}"><span>${item.key.slice(5).replace('-', '/')} ${weekdayOf(item.key)}</span><small>${item.pomodoros} 个番茄 · ${item.minutes} 分钟${item.completedBlocks ? ` · 达标 ${item.completedBlocks} 块` : ''}</small></button></li>`).join('')}</ul></article>` : ''}
    <article class="panel later-panel"><div class="panel-heading"><h2>任务用时</h2><span class="badge">${report.startKey.slice(5)} 至 ${report.endKey.slice(5)}</span></div>${taskBreakdown(report.tasks, report.totals.pomodoros, review.tasks, 'range-tasks')}</article>
    <div class="review-foot"><div class="integration-actions">${report.tasks.length ? `<button class="button button-quiet" type="button" data-action="export-tasks">${icon('download')} 导出任务用时</button>` : ''}
      <button class="button button-quiet danger" type="button" data-action="clear-stats" ${Object.keys(state.histogram).length ? '' : 'disabled'}>清空番茄统计</button>
      <button class="button button-quiet danger" type="button" data-action="clear-blocks" ${Object.keys(state.dailyBlocks).length || Object.keys(state.plants).length || Object.keys(state.blockHistory).length ? '' : 'disabled'}>清空块记录与植物</button></div>
      <p class="muted">全部历史 · ${summary.pomodoros} 个番茄 · ${summary.hours.toFixed(1)} 小时<br>记录日均 ${summary.average.toFixed(1)} 个番茄</p></div>`;
}

function renderData() {
  const now = Date.now();
  const day = logicalDayKey(state.settings, now);
  const today = dayKey(now);
  lastCalendar = `${day}/${today}/${blockIndexAt(state.settings, now)}/${minuteOfDay(now)}`;
  $('#current-date').dateTime = today;
  $('#current-date').textContent = dateFormatter.format(now);
  lastTimer = '';
  renderTimer(now);
  renderFocus(now, day, today);
  renderTasks(day);
  renderReview(today);
  for (const bar of document.querySelectorAll('.bar')) bar.style.height = `${bar.dataset.height}%`;
}

function showView() {
  const candidate = location.hash.slice(1);
  if (candidate === 'content') return;
  const next = views.includes(candidate) ? candidate : 'focus';
  for (const name of views) $(`#view-${name}`).hidden = name !== next;
  for (const link of document.querySelectorAll('[data-view]')) {
    if (link.dataset.view === next) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
  if (view && view !== next) {
    $('#content').focus({ preventScroll: true });
    window.scrollTo(0, 0);
  }
  view = next;
}

// MARK: Dialogs
function showDialog(title, fields, submit, handleSubmit, { wide = false } = {}) {
  dialog.classList.toggle('wide', wide);
  dialog.innerHTML = `<div class="panel-heading"><h2 id="dialog-title">${title}</h2><button class="icon-button" type="button" data-action="close" aria-label="关闭">${icon('close')}</button></div>
    <form class="form">${fields}<p class="form-error" role="alert" hidden></p><div class="form-actions"><button type="button" class="button button-quiet" data-action="close">取消</button><button class="button button-primary" type="submit">${submit}</button></div></form>`;
  const form = dialog.querySelector('form');
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const button = form.querySelector('[type="submit"]');
    const error = form.querySelector('.form-error');
    button.disabled = true;
    error.hidden = true;
    try {
      await handleSubmit(new FormData(form));
      if (dialog.contains(form) && dialog.open) dialog.close();
    } catch (failure) {
      error.textContent = failure.message;
      error.hidden = false;
    } finally { button.disabled = false; }
  });
  dialog.showModal();
  (form.querySelector('input:not([type="checkbox"]):not([type="radio"])') ?? form.querySelector('[type="submit"]')).focus();
}

dialog.addEventListener('close', () => {
  sounds.stopPreview();
  if (!dialog.open) dialog.replaceChildren();
});

function confirm(title, message, submit, callback) {
  showDialog(title, `<p class="muted">${message}</p>`, submit, callback);
}

const checkbox = (name, label, checked) => `<label class="inline-field"><input name="${name}" type="checkbox" ${checked ? 'checked' : ''}> ${label}</label>`;
const numberField = (name, label, value) => `<label>${label}<input type="number" name="${name}" min="${limits[name][0]}" max="${limits[name][1]}" value="${value}" required></label>`;
const soundSelect = (name, value, options) => `<select name="${name}">${options.map(option => `<option value="${escape(option)}" ${option === value ? 'selected' : ''}>${escape(soundLabel(option))}</option>`).join('')}</select>`;
const volume = (name, value) => `<input type="range" name="${name}" min="0" max="1" step="0.05" value="${value}" aria-label="音量">`;

function settingsDialog() {
  const s = state.settings;
  const labels = {
    pomoDurationMins: '专注（分钟）', breakDuration: '短休息（分钟）', longBreakDuration: '长休息（分钟）', breakExtention: '休息延长（分钟）',
    pomoSetNum: '每组番茄数', blockCount: '时间块数量', blockPomoCount: '每块目标番茄', blockReminderMinutes: '提前提醒（分钟）',
  };
  const notifications = 'Notification' in globalThis && Notification.permission === 'default'
    ? '<button class="button button-quiet" type="button" data-action="notifications">允许浏览器通知</button>' : '';
  const fields = `<fieldset><legend>番茄钟</legend><div class="form-grid">${['pomoDurationMins', 'breakDuration', 'longBreakDuration', 'breakExtention', 'pomoSetNum'].map(key => numberField(key, labels[key], s[key])).join('')}</div>
      ${checkbox('manualBreak', '番茄结束后手动开始休息', s.manualBreak)}${checkbox('resetPomoAfterBreak', '休息延长超时后清空本组', s.resetPomoAfterBreak)}
      <p class="muted">任务日从第一个时间块开始（当前 ${rangeLabel(s.blockTimeRanges[0]).slice(0, 5)}），统计按自然日。</p></fieldset>
    <fieldset><legend>时间块与种植</legend>${checkbox('enableBlockMode', '启用时间块（1–24 块）', s.enableBlockMode)}
      <div class="form-grid">${['blockCount', 'blockPomoCount', 'blockReminderMinutes'].map(key => numberField(key, labels[key], s[key])).join('')}</div>
      ${checkbox('blockStartReminder', '块开始前提醒（本页打开时）', s.blockStartReminder)}${checkbox('blockSprintReminder', '冲刺提醒（完成约三分之二时）', s.blockSprintReminder)}
      <p class="muted">各块时段、目标和块任务在专注页的「时间块 · 种植」中编辑。</p></fieldset>
    <fieldset><legend>声音</legend>
      <label>番茄结束音<span class="sound-line">${soundSelect('pomoEndSound', s.pomoEndSound, soundOptions)}${volume('pomoEndSoundVolume', s.pomoEndSoundVolume)}<button class="button button-quiet" type="button" data-action="preview-sound" data-sound="pomoEnd">试听</button></span></label>
      <label>休息结束音<span class="sound-line">${soundSelect('breakEndSound', s.breakEndSound, soundOptions)}${volume('breakEndSoundVolume', s.breakEndSoundVolume)}<button class="button button-quiet" type="button" data-action="preview-sound" data-sound="breakEnd">试听</button></span></label>
      ${checkbox('sound', '播放结束提示音（计时卡片上可快速静音）', s.sound)}
      <div class="radio-line" role="radiogroup" aria-label="环境音来源"><label class="inline-field"><input type="radio" name="ambientSource" value="qishi" ${s.ambientSource === 'qishi' ? 'checked' : ''}> 栖时随机场景</label><label class="inline-field"><input type="radio" name="ambientSource" value="custom" ${s.ambientSource === 'custom' ? 'checked' : ''}> 自定义环境音</label></div>
      <label>环境音（自定义）<span class="sound-line">${soundSelect('ambientSound', s.ambientSound, ambientOptions)}${volume('ambientSoundVolume', s.ambientSoundVolume)}<button class="button button-quiet" type="button" data-action="preview-sound" data-sound="ambient">试听</button></span></label>
      <p class="muted">环境音只在专注时循环，暂停、休息或放弃时停止。栖时每个番茄随机一个场景，不与上一个重复；试听最多 8 秒。</p></fieldset>
    <fieldset><legend>Habitica 番茄打分</legend>
      ${checkbox('pomoHabitPlus', '完成番茄时给 Pomodoro 习惯加分', s.pomoHabitPlus)}${checkbox('pomoSetHabitPlus', '完成一组时给 Pomodoro Combo! 加分', s.pomoSetHabitPlus)}
      ${checkbox('pomoHabitMinus', '中途放弃时扣分', s.pomoHabitMinus)}${checkbox('breakExtentionFails', '休息延长超时扣分', s.breakExtentionFails)}
      ${checkbox('blockRewardEnabled', '时间块达标时额外奖励一次', s.blockRewardEnabled)}
      ${checkbox('customPomodoroTask', '使用自定义番茄 Habit', s.customPomodoroTask)}<label>番茄 Habit ID<input name="pomodoroTaskId" value="${escape(s.pomodoroTaskId ?? '')}" spellcheck="false" autocomplete="off"></label>
      ${checkbox('customSetTask', '使用自定义 Combo Habit', s.customSetTask)}<label>Combo Habit ID<input name="pomodoroSetTaskId" value="${escape(s.pomodoroSetTaskId ?? '')}" spellcheck="false" autocomplete="off"></label>
      ${checkbox('breakExtentionNotify', '短休息结束时发 Habitica 私信', s.breakExtentionNotify)}${checkbox('longBreakNotify', '长休息结束时发 Habitica 私信', s.longBreakNotify)}
      <p class="muted">只对开始该阶段时已在本页连接的账号计分；断开、刷新或换账号后不会补发。默认自动查找或创建 Pomodoro 与 Pomodoro Combo! 习惯。</p></fieldset>
    <fieldset><legend>关于</legend><p class="muted">专注番茄钟 Web ${appVersion} · 与 macOS / iOS / Android ${appVersion} 使用同一套业务规则。数据保存在当前浏览器。</p>${notifications}</fieldset>`;
  showDialog('设置', fields, '保存', values => changeState(current => {
    const next = { ...current.settings };
    for (const [key, label] of Object.entries(labels)) {
      const number = Number(values.get(key));
      const [min, max] = limits[key];
      if (!Number.isInteger(number) || number < min || number > max) throw new Error(`${label}需在 ${min}–${max} 之间。`);
      next[key] = number;
    }
    for (const key of ['manualBreak', 'resetPomoAfterBreak', 'enableBlockMode', 'blockStartReminder', 'blockSprintReminder', 'sound',
      'pomoHabitPlus', 'pomoSetHabitPlus', 'pomoHabitMinus', 'breakExtentionFails', 'blockRewardEnabled', 'customPomodoroTask',
      'customSetTask', 'breakExtentionNotify', 'longBreakNotify']) next[key] = values.has(key);
    for (const key of ['pomoEndSound', 'breakEndSound', 'ambientSound', 'ambientSource', 'pomodoroTaskId', 'pomodoroSetTaskId']) next[key] = String(values.get(key) ?? '');
    for (const key of ['pomoEndSoundVolume', 'breakEndSoundVolume', 'ambientSoundVolume']) next[key] = Number(values.get(key));
    if (next.customPomodoroTask && !/^[\w-]+$/.test(next.pomodoroTaskId.trim())) throw new Error('请填写有效的自定义番茄 Habit ID。');
    if (next.customSetTask && !/^[\w-]+$/.test(next.pomodoroSetTaskId.trim())) throw new Error('请填写有效的自定义 Combo Habit ID。');
    current.settings = normalizeSettings(next);
    return '已保存设置。';
  }), { wide: true });
}

function previewSound(kind) {
  const form = dialog.querySelector('form');
  if (!form) return;
  sounds.unlock();
  const value = name => form.elements[name]?.value;
  if (kind === 'ambient' && form.elements.ambientSource.value === 'qishi') {
    const preset = qishi.preview(Number(value('ambientSoundVolume')));
    return announce(preset ? `正在试听「${preset.name}」。` : '栖时场景库暂时不可用。');
  }
  const name = value(`${kind}Sound`);
  if (name === 'None') return announce('未选择声音。');
  sounds.play(name, Number(value(`${kind}SoundVolume`)), 8000);
}

function taskDialog(category, existing) {
  const store = state.topThree;
  const choices = store.categoryNames.map((name, index) =>
    `<option value="${index}" ${index === category ? 'selected' : ''}>${escape(name)}</option>`).join('');
  const fields = `<label>任务名称<input name="title" maxlength="120" value="${escape(existing?.task.title)}" required></label>${existing ? '' : `<label>分类<select name="category">${choices}</select></label>`}`;
  showDialog(existing ? '编辑任务' : '添加任务', fields, '保存任务', async values => {
    await changeState((current, now) => {
      const day = logicalDayKey(current.settings, now);
      if (existing) {
        if (!setTaskTitle(current.topThree, day, existing.key, existing.category, existing.task.id, values.get('title'))) {
          throw new Error(String(values.get('title')).trim() ? '这个任务已经移走，或已进入下一任务日。' : '请填写任务名称。');
        }
        return '已更新任务。';
      }
      // Ownership follows the account, not the connection: offline additions belong to the last account.
      addTask(current.topThree, day, Number(values.get('category')), values.get('title'), connection?.owner || current.topThree.cloudAccount || null);
      return '已添加任务。';
    });
    scheduleSync();
  });
}

function renameDialog(category) {
  const name = state.topThree.categoryNames[category];
  showDialog('重命名分类', `<label>分类名称<input name="name" maxlength="40" value="${escape(name)}" required></label><p class="muted">已同步的 Habitica 标签和 todo 备注会在下次同步时跟着改名；离线时会保留并重试。</p>`, '保存', async values => {
    await changeState(current => renameCategory(current.topThree, category, values.get('name')) ? '已重命名分类。' : null);
    scheduleSync();
  });
}

function blockTasksMarkup(index) {
  const tasks = state.settings.blockTasks[index] ?? [];
  const rows = tasks.map(task => `<li class="block-task" data-task="${escape(task.id)}"><button class="task-check" type="button" data-action="block-task-toggle" data-index="${index}" data-id="${escape(task.id)}" aria-pressed="${task.isCompleted}" aria-label="${escape(task.title)}">${task.isCompleted ? icon('check') : ''}</button>
    <input aria-label="块任务标题" value="${escape(task.title)}" data-field="title" maxlength="120"><input aria-label="预计番茄" type="number" min="1" max="12" value="${task.estimatedPomo}" data-field="estimate">
    <button class="text-button" type="button" data-action="block-task-save" data-index="${index}" data-id="${escape(task.id)}">保存</button>
    <button class="icon-button" type="button" data-action="block-task-delete" data-index="${index}" data-id="${escape(task.id)}" aria-label="删除 ${escape(task.title)}">${icon('trash')}</button></li>`).join('');
  return `${rows ? `<ul class="block-tasks">${rows}</ul>` : '<p class="muted">这个时间块还没有任务。</p>'}
    <div class="block-task add"><input aria-label="新块任务" placeholder="添加块任务" maxlength="120" data-field="new-title"><input aria-label="预计番茄" type="number" min="1" max="12" value="1" data-field="new-estimate"><button class="button button-quiet" type="button" data-action="block-task-add" data-index="${index}">${icon('plus')} 添加</button></div>`;
}

function blockDialog(index) {
  const s = state.settings;
  const range = s.blockTimeRanges[index];
  const time = (hour, minute) => `${pad(hour)}:${pad(minute)}`;
  showDialog(`B${index + 1} 时间块`, `<label>目标<input name="goal" maxlength="80" value="${escape(s.blockGoals[index])}" placeholder="这一时间块的目标"></label>
    <div class="form-grid"><label>开始<input type="time" name="start" value="${time(range.startHour, range.startMinute)}" required></label><label>结束<input type="time" name="end" value="${time(range.endHour, range.endMinute)}" required></label></div>
    <p class="muted">可以跨午夜；开始与结束相同表示全天。第一个时间块的开始时间也是任务日的分界。</p>
    <fieldset><legend>块任务</legend><div id="block-tasks">${blockTasksMarkup(index)}</div></fieldset>`, '保存时段与目标', values => changeState(current => {
    const parse = value => /^(\d{2}):(\d{2})$/.exec(String(value ?? ''));
    const start = parse(values.get('start'));
    const end = parse(values.get('end'));
    if (!start || !end) throw new Error('请输入有效的开始和结束时间。');
    const next = structuredClone(current.settings);
    next.blockTimeRanges[index] = { startHour: Number(start[1]), startMinute: Number(start[2]), endHour: Number(end[1]), endMinute: Number(end[2]) };
    next.blockGoals[index] = String(values.get('goal')).trim();
    current.settings = normalizeSettings(next);
    return `已保存 B${index + 1}。`;
  }), { wide: true });
}

function blockTaskAction(action, button) {
  const index = Number(button.dataset.index);
  const row = button.closest('.block-task');
  const read = field => row?.querySelector(`[data-field="${field}"]`)?.value ?? '';
  if (action === 'block-task-delete' && button.dataset.confirm !== 'yes') {
    button.dataset.confirm = 'yes';
    button.classList.add('danger');
    button.innerHTML = '确认删除';
    return;
  }
  void changeState(current => {
    const settings = structuredClone(current.settings);
    const list = settings.blockTasks[index] ?? [];
    const task = list.find(item => item.id === button.dataset.id);
    if (action === 'block-task-add') {
      const title = read('new-title').trim();
      if (!title) return '请填写块任务名称。';
      list.push(decodeBlockTask({ id: newId(), title, estimatedPomo: Number(read('new-estimate')) || 1 }));
    } else if (!task) return null;
    else if (action === 'block-task-toggle') task.isCompleted = !task.isCompleted;
    else if (action === 'block-task-save') {
      const title = read('title').trim();
      const estimate = Number(read('estimate'));
      if (!title || !Number.isInteger(estimate) || estimate < 1 || estimate > 12) return '块任务需要标题，预计番茄为 1–12。';
      Object.assign(task, { title, estimatedPomo: estimate });
    } else if (action === 'block-task-delete') list.splice(list.indexOf(task), 1);
    settings.blockTasks[index] = list;
    current.settings = normalizeSettings(settings);
    return null;
  }).then(() => {
    const container = dialog.querySelector('#block-tasks');
    if (container) container.innerHTML = blockTasksMarkup(index);
  });
}

// MARK: Tasks
function changeTask(action, dataset) {
  const { id, key } = dataset;
  const category = Number(dataset.category);
  const store = state.topThree;
  const found = locate(store, id);
  if (action === 'edit') return found ? taskDialog(found.category, found) : null;
  if (action === 'focus') return startTaskFocus(id);
  if (action === 'delete' || action === 'delete-unfinished') {
    if (!found) return;
    const remote = found.task.habiticaTaskId ? '已同步的 Habitica todo 会一并删除。' : '';
    return confirm('删除任务', `删除「${escape(found.task.title)}」${action === 'delete-unfinished' ? `（${key}）` : ''}？${remote}`, '删除任务', async () => {
      await changeState((current, now) => removeTask(current.topThree, logicalDayKey(current.settings, now), key, category, id, action === 'delete-unfinished')
        ? '已删除任务。' : '任务已变化，未删除。');
      scheduleSync();
    });
  }
  void changeState((current, now) => {
    const day = logicalDayKey(current.settings, now);
    if (action === 'check') {
      const task = toggleTask(current.topThree, day, key, category, id);
      return task ? (task.isCompleted ? '已完成任务。' : '已恢复任务。') : null;
    }
    if (action === 'carry') {
      if (!canAddTask(current.topThree, day, category)) return `今天的「${current.topThree.categoryNames[category]}」已满 ${fixedTaskLimit} 件，任务保留在未完成列表。`;
      return moveTaskToToday(current.topThree, day, key, category, id) ? '已转到今天。' : '任务已完成、已转移或已变化，未转到今天。';
    }
    return null;
  }).then(scheduleSync);
}

function exportCsv(tasks = false) {
  const today = dayKey(Date.now());
  const report = focusReview(review.range, review.page ? pageEnd(review.page, review.range) : today, state);
  const [text, filename] = tasks ? [report.taskCsv, report.taskCsvFilename] : [report.csv, report.csvFilename];
  const url = URL.createObjectURL(new Blob([text], { type: 'text/csv;charset=utf-8' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  announce(`已导出 ${filename}。`);
}

// MARK: Habitica
function renderHabitica() {
  const notice = habiticaMessage ? `<p class="notice" role="status">${escape(habiticaMessage)}</p>` : '';
  if (!account) {
    $('#habitica-body').innerHTML = `<article class="panel"><div class="panel-heading"><h2>连接你的 Habitica 账号</h2>${icon('habitica')}</div><p class="panel-copy">输入 Habitica 的 User ID 与 API Token。网页直接连接 habitica.com，凭据只在当前页面打开期间保留。连接后可以同步每日任务、为番茄计分。</p><button class="button button-primary add-line" type="button" data-action="connect">连接账号</button>${notice}</article>`;
    return;
  }
  const disabled = habiticaBusy ? 'disabled' : '';
  const lists = [['habit', '习惯'], ['daily', '每日打卡']].map(([type, label]) => {
    const tasks = account.tasks.filter(task => task.type === type);
    const rows = tasks.map(task => {
      const name = escape(task.text);
      const score = (direction, title, nameIcon) => `<button class="button button-quiet" type="button" data-action="score" data-id="${escape(task.id)}" data-direction="${direction}" aria-label="${name} ${title}" ${disabled}>${icon(nameIcon)}</button>`;
      const actions = type === 'habit'
        ? `${task.down !== false ? score('down', '减分', 'minus') : ''}${task.up !== false ? score('up', '加分', 'plus') : ''}`
        : score(task.completed ? 'down' : 'up', task.completed ? '取消打卡' : '完成打卡', task.completed ? 'reset' : 'check');
      return `<li><strong${type === 'daily' && task.completed ? ' class="scored"' : ''}>${name}</strong>${actions}</li>`;
    }).join('');
    return `<article class="panel"><div class="panel-heading"><h2>${label}</h2><span class="badge">${tasks.length}</span></div>${rows ? `<ul class="integration-list">${rows}</ul>` : empty('列表为空', '在 Habitica 添加后可刷新查看。')}</article>`;
  }).join('');
  const role = roleFigures(account.stats);
  const bar = (label, value, max, kind) => `<div class="role-bar ${kind}"><span>${label}</span><div><i style="width:${Math.min(100, Math.max(0, 100 * value / (max || 1)))}%"></i></div><small>${Math.round(value)} / ${Math.round(max)}</small></div>`;
  $('#habitica-body').innerHTML = `<article class="panel integration-top"><div class="panel-heading"><h2>${escape(account.name)}</h2><div class="integration-actions"><button type="button" class="button button-quiet" data-action="refresh" ${disabled}>${habiticaBusy ? '正在请求…' : '刷新'}</button><button type="button" class="button button-quiet" data-action="disconnect" ${disabled}>断开</button></div></div>
    <p class="panel-copy">${role.className ? `${escape(role.className)} · ` : ''}等级 ${role.level} · 金币 ${Math.round(role.gp)}</p>
    <div class="role-bars">${bar('生命', role.hp, role.maxHealth, 'hp')}${bar('魔法', role.mp, role.maxMP, 'mp')}${bar('经验', role.exp, role.toNextLevel, 'exp')}</div>${notice}</article>
    <div class="integration-grid">${lists}</div>
    <article class="panel later-panel"><div class="panel-heading"><h2>番茄习惯</h2><button type="button" class="button button-quiet" data-action="habits" ${disabled}>确认 / 初始化</button></div><p class="panel-copy">完成、放弃和组合计分使用 Pomodoro 与 Pomodoro Combo! 习惯；在设置中可改用自定义 Habit ID。</p></article>`;
}

async function refreshAccount({ quiet = false } = {}) {
  const current = connection;
  if (!current || habiticaBusy) return;
  if (!quiet) { habiticaBusy = true; habiticaMessage = ''; renderHabitica(); }
  try {
    const data = await current.api.loadAccount();
    if (connection === current) account = data;
  } catch (failure) {
    if (connection === current) habiticaMessage = failure.message;
  } finally {
    if (!quiet) habiticaBusy = false;
    if (connection === current) renderHabitica();
  }
}

async function updateHabitica(action, dataset) {
  const current = connection;
  if (habiticaBusy || !current) return;
  if (action === 'refresh') return refreshAccount();
  habiticaBusy = true;
  habiticaMessage = '';
  renderHabitica();
  try {
    if (action === 'habits') {
      const settings = state.settings;
      await habitId(current, settings, false);
      await habitId(current, settings, true);
      if (connection === current) habiticaMessage = '番茄习惯已就绪。';
    } else if (action === 'score') {
      await current.api.scoreTask(dataset.id, dataset.direction);
      if (connection !== current) return;
      // Scored once and never replayed; the list is read again before the next write.
      account.tasks = [];
      const data = await current.api.loadAccount().catch(failure => { habiticaMessage = `打分已提交，列表刷新失败。${failure.message}`; return null; });
      if (connection === current && data) account = data;
      announce('已记录 Habitica 打分。');
    }
  } catch (failure) {
    if (connection === current) {
      habiticaMessage = failure.message;
      if (action === 'score') { account.tasks = []; habiticaMessage += ' 请先刷新列表确认结果。'; }
    }
  } finally {
    if (connection === current) { habiticaBusy = false; renderHabitica(); }
  }
}

function connectDialog() {
  showDialog('连接 Habitica', `<p class="muted">可在 <a class="link" href="https://habitica.com/user/settings/api" target="_blank" rel="noopener noreferrer">Habitica API 设置</a> 找到凭据。关闭或刷新本页后需要重新连接。</p><label>User ID<input name="user" required autocomplete="off" maxlength="64" spellcheck="false"></label><label>API Token<input name="token" required type="password" autocomplete="off" maxlength="128"></label>`, '连接', async values => {
    const user = String(values.get('user')).trim();
    const token = String(values.get('token')).trim();
    if (!isValidUserId(user)) throw new Error('User ID 必须是完整的 UUID。');
    if (!token) throw new Error('请填写 API Token。');
    const form = dialog.querySelector('form');
    const owner = await ownerKey(user);
    if (!budgets.has(owner)) budgets.set(owner, createBudget());
    const api = createApi({ user, token, budget: budgets.get(owner) });
    const data = await api.loadAccount();
    if (!dialog.open || dialog.querySelector('form') !== form) return;
    const current = { owner, api, habits: {} };
    current.sync = createSync({
      api, owner, isActive: () => connection === current,
      read: () => (writable ? loadState(localStorage).state : state).topThree,
      write: async edit => {
        let saved = false;
        await changeState(next => { edit(next.topThree); saved = writable; return null; });
        return saved && writable;
      },
    });
    connection = current;
    account = data;
    habiticaMessage = '';
    syncMessage = '';
    renderHabitica();
    renderData();
    announce('已连接 Habitica，正在同步每日任务。');
    void runSync();
  });
}

function disconnect() {
  connection = null;
  account = null;
  habiticaMessage = '';
  syncMessage = '';
  syncBusy = false;
  renderHabitica();
  renderData();
  announce('已断开 Habitica。本机任务和记录保留。');
}

function scheduleSync() {
  if (!connection) return;
  clearTimeout(syncTimeout);
  syncTimeout = setTimeout(() => void runSync(), 600);
}

async function runSync() {
  const current = connection;
  if (!current) return;
  if (!writable) { syncMessage = '浏览器存储不可写，暂不同步。'; return renderData(); }
  syncBusy = true;
  renderData();
  const result = await current.sync.run();
  if (connection !== current) return;
  syncBusy = false;
  syncMessage = result?.message ?? '';
  renderData();
}

// MARK: Events
document.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (!button || button.disabled) return;
  const { action } = button.dataset;
  if (button.dataset.break) {
    const owner = connection?.owner ?? null;
    return changeState((current, now) => takeBreak(current, now, Number(button.dataset.break), owner));
  }
  switch (action) {
    case 'timer': case 'skip': case 'abandon': return timerAction(action);
    case 'sound':
      sounds.unlock();
      return changeState(current => { current.settings.sound = !current.settings.sound; });
    case 'add': return taskDialog(Number(button.dataset.category) || 0);
    case 'check': case 'edit': case 'delete': case 'delete-unfinished': case 'carry': case 'focus': return changeTask(action, button.dataset);
    case 'rename': return renameDialog(Number(button.dataset.category));
    case 'block': return blockDialog(Number(button.dataset.index));
    case 'block-task-add': case 'block-task-toggle': case 'block-task-save': case 'block-task-delete': return blockTaskAction(action, button);
    case 'reset-block': return confirm('重置当前块计数', '只把当前时间块今天的番茄数清零；已有植物和达标奖励记录保留，不会重复奖励，也不会删除其他块或任务。', '重置', () => changeState((current, now) => resetCurrentBlock(current, now)));
    case 'settings': return settingsDialog();
    case 'preview-sound': return previewSound(button.dataset.sound);
    case 'notifications': return void Notification.requestPermission().then(result => announce(result === 'granted' ? '已允许浏览器通知。' : '浏览器未允许通知。'));
    case 'close': return dialog.close();
    case 'export': return exportCsv(false);
    case 'export-tasks': return exportCsv(true);
    case 'clear-stats': return confirm('清空番茄统计', '清空所有日期的番茄数、专注分钟和任务用时。任务、时间块和种植记录会保留。此操作不可撤销。', '清空番茄统计', () => changeState(current => clearHistogram(current)));
    case 'clear-blocks': return confirm('清空块记录与植物', '清空所有日期的时间块进度、达标记录和种植。番茄统计和每日任务会保留。此操作不可撤销。', '清空块记录', () => changeState(current => clearBlockHistory(current)));
    case 'range':
      review = { ...review, range: Number(button.dataset.range), page: null, day: null, sessions: 0 };
      renderData();
      return $(`[data-range="${review.range}"][data-action="range"]`).focus();
    case 'page-back': {
      const page = review.page ?? { anchor: dayKey(Date.now()), offset: 0 };
      review = { ...review, page: { ...page, offset: page.offset - 1 }, day: null, sessions: 0 };
      return renderData();
    }
    case 'page-next':
      review = { ...review, page: review.page && nextPage(review.page, review.range, dayKey(Date.now())), day: null, sessions: 0 };
      return renderData();
    case 'page-today':
      review = { ...review, page: null, day: null, sessions: 0 };
      return renderData();
    case 'review-day':
      review = { ...review, day: button.dataset.day, sessions: 0, dayTasks: false };
      renderData();
      return $('#review-day')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    case 'sessions':
      review.sessions = review.sessions ? 0 : 5;
      return renderData();
    case 'more-sessions':
      review.sessions += 5;
      return renderData();
    case 'day-tasks': review.dayTasks = !review.dayTasks; return renderData();
    case 'range-tasks': review.tasks = !review.tasks; return renderData();
    case 'connect': return connectDialog();
    case 'refresh': case 'score': case 'habits': return updateHabitica(action, button.dataset);
    case 'disconnect': return disconnect();
    case 'sync': return runSync();
  }
});

$('#focus-task').addEventListener('change', event => { selectedTask = event.target.value; });
window.addEventListener('hashchange', showView);
window.addEventListener('storage', event => {
  if (![storageKey, legacyKey, null].includes(event.key) || !writable) return;
  // An older open tab wrote v1: merge its new records once, under the lock.
  if (event.key === legacyKey) return void changeState(() => null);
  reload();
  renderData();
  syncAudio();
});
document.addEventListener('keydown', event => {
  if (event.code === 'Space' && !event.repeat && !event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey && view === 'focus' && !dialog.open && !event.target.closest('button, a, input, select, textarea, [contenteditable]')) {
    event.preventDefault();
    timerAction('timer');
  }
});

function checkBlockReminders(now) {
  const s = state.settings;
  if (!s.enableBlockMode || !s.blockStartReminder) return;
  const minute = minuteOfDay(now);
  for (let index = 0; index < s.blockCount; index += 1) {
    const range = s.blockTimeRanges[index];
    const key = `${dayKey(now)}-${index}`;
    if ((rangeStart(range) - s.blockReminderMinutes + 1440) % 1440 !== minute || remindedBlocks.has(key)) continue;
    remindedBlocks.add(key);
    const message = `B${index + 1} 将在 ${s.blockReminderMinutes} 分钟后开始（${rangeLabel(range)}）${s.blockGoals[index] ? `，目标：${s.blockGoals[index]}` : ''}。`;
    announce(message);
    notify(`B${index + 1} 即将开始`, message);
  }
}

function tick() {
  const now = Date.now();
  if (state.timer.running && state.timer.endsAt <= now) {
    if (!settling) {
      settling = true;
      void changeState().finally(() => { settling = false; });
    }
    return;
  }
  if (lastCalendar !== `${logicalDayKey(state.settings, now)}/${dayKey(now)}/${blockIndexAt(state.settings, now)}/${minuteOfDay(now)}`) {
    renderData();
    checkBlockReminders(now);
  } else renderTimer(now);
}

// MARK: Start
for (const element of document.querySelectorAll('[data-version]')) element.textContent = `v${appVersion}`;
$('#hub-return').hidden = !location.pathname.startsWith('/habitica-pomodoro-web/');
const initial = (() => {
  const loaded = reload();
  writable = loaded.writable;
  if (!loaded.writable) state = loaded.state;
  return loaded;
})();
showView();
renderData();
renderHabitica();
syncAudio();
if (initial.writable && initial.dirty) {
  void changeState(() => (initial.migrated ? '已把旧版本的本机数据迁移到 3.2 格式，原数据保留未动。' : null));
}
tick();
setInterval(tick, 250);
document.addEventListener('visibilitychange', tick);
window.addEventListener('pageshow', tick);
