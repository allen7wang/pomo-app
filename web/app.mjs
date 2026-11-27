import {
  categories, currentTasks, dayKey, defaults, emptyTimer, freshState, phases, previousDay,
  recentDays, remainingTime, resetTimer, settleTimer, storageKey, summarize, taskLimitReached,
  timeBlock, toggleTimer,
} from './model.mjs';
import { loadAccount, scoreTask } from './habitica.mjs';
import catalog from './qishi_presets.json' with { type: 'json' };
import { createAmbient } from './qishi.mjs';

const $ = selector => document.querySelector(selector);
const icon = name => `<svg class="icon" aria-hidden="true"><use href="#i-${name}"/></svg>`;
const escape = value => String(value ?? '').replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[character]);
const dateFormatter = new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric', weekday: 'long' });
const sessionFormatter = new Intl.DateTimeFormat('zh-CN', { dateStyle: 'short', timeStyle: 'short' });
const limits = { focus: [1, 120], short: [1, 60], long: [1, 120], rounds: [1, 12], target: [1, 12] };
const dialog = $('#dialog');
const views = ['focus', 'tasks', 'review', 'habitica'];
let selectedTask = '';
let range = 7;
let lastCalendar = '';
let lastTimer = '';
let lastClock = '';
let settling = false;
let toastTimeout;
let audio;
let view;
let connection = null;
let account = null;
let habiticaBusy = false;
let habiticaMessage = '';
let storageAvailable = true;
let state = readState(freshState());
const qishi = createAmbient({
  presets: Array.isArray(catalog.presets) ? catalog.presets : [],
  pageURL: document.baseURI,
  createAudio: () => new Audio(),
});

function ambientVolume(current = state) {
  const value = Number(current.settings.ambientVolume);
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0.45;
}

function ambientEnabled(current = state) {
  return current.settings.ambient !== 'off';
}

function qishiIntent(current = state, running = current.timer.phase === 'focus' && current.timer.end !== null) {
  return {
    enabled: ambientEnabled(current),
    running,
    phase: current.timer.phase,
    sessionId: current.timer.phase === 'focus' ? current.timer.id : null,
    volume: ambientVolume(current),
  };
}

function showScene(preset) {
  const label = $('#qishi-scene');
  if (!label) return;
  const name = preset?.name || '';
  label.hidden = !name;
  label.textContent = name ? `栖时 · ${name}` : '';
}

function syncQishi(current = state) {
  showScene(qishi.reconcile(qishiIntent(current)));
}

function storageIssue() {
  storageAvailable = false;
  const notice = $('#storage-error');
  notice.hidden = false;
  notice.textContent = '浏览器存储不可用。本页仍可计时，刷新后可能丢失本次改动。';
}

function readState(fallback) {
  try {
    const raw = localStorage.getItem(storageKey);
    if (!raw) return freshState();
    const saved = JSON.parse(raw);
    if (!saved?.timer || !saved.settings || !saved.blocks || !Array.isArray(saved.tasks) || !Array.isArray(saved.sessions)) {
      throw new Error('Invalid stored state');
    }
    return saved;
  } catch {
    storageIssue();
    return fallback;
  }
}

function announce(message) {
  $('#status').textContent = message;
  clearTimeout(toastTimeout);
  toastTimeout = setTimeout(() => { $('#status').textContent = ''; }, 4200);
}

async function changeState(change, { skipAfterFinish = false } = {}) {
  const apply = () => {
    const active = document.activeElement?.dataset.focusKey;
    if (storageAvailable) state = readState(state);
    const now = Date.now();
    const end = state.timer.end;
    const completed = settleTimer(state, now);
    let message;
    try {
      if (!completed || !skipAfterFinish) message = change?.(state, now);
    } finally {
      if (storageAvailable && (change || completed)) {
        try { localStorage.setItem(storageKey, JSON.stringify(state)); } catch { storageIssue(); }
      }
      renderData();
      if (active && document.activeElement === document.body) {
        document.querySelector(`[data-focus-key="${CSS.escape(active)}"]`)?.focus({ preventScroll: true });
      }
      if (completed && now - end < 2000 && state.settings.sound) playChime();
      syncQishi();
      if (message || completed) announce([completed, message].filter(Boolean).join(' '));
    }
  };
  if (navigator.locks && storageAvailable) await navigator.locks.request(storageKey, apply);
  else apply();
}

function openAudio() {
  try {
    const Audio = window.AudioContext || window.webkitAudioContext;
    if (Audio) {
      audio ??= new Audio();
      if (audio.state === 'suspended') void audio.resume().catch(() => {});
    }
  } catch { /* A browser may disable audio. */ }
}

function playChime() {
  if (audio?.state !== 'running') return;
  for (const [index, pitch] of [659, 880].entries()) {
    const start = audio.currentTime + index * 0.16;
    const tone = audio.createOscillator();
    const volume = audio.createGain();
    tone.frequency.value = pitch;
    volume.gain.setValueAtTime(0.0001, start);
    volume.gain.exponentialRampToValueAtTime(0.13, start + 0.04);
    volume.gain.exponentialRampToValueAtTime(0.0001, start + 0.38);
    tone.connect(volume).connect(audio.destination);
    tone.start(start);
    tone.stop(start + 0.4);
  }
}

function renderTimer(now) {
  const timer = state.timer;
  const running = timer.end !== null;
  const started = timer.id !== null;
  const seconds = Math.ceil(remainingTime(timer, now) / 1000);
  const time = [Math.floor(seconds / 60), seconds % 60].map(value => String(value).padStart(2, '0')).join(':');
  const clockKey = `${time}/${timer.duration}`;
  if (lastClock !== clockKey) {
    lastClock = clockKey;
    $('#clock').textContent = time;
    $('#clock-progress').setAttribute('stroke-dashoffset', String(100 * (1 - seconds * 1000 / timer.duration)));
    document.title = running ? `${time} · ${phases[timer.phase]} · 专注番茄钟` : '专注番茄钟 · Habitica Pomodoro';
  }
  const key = `${timer.phase}/${running}/${started}/${state.round}/${state.settings.rounds}/${state.settings.sound}`;
  if (lastTimer === key) return;
  lastTimer = key;
  document.title = running ? `${time} · ${phases[timer.phase]} · 专注番茄钟` : '专注番茄钟 · Habitica Pomodoro';
  for (const button of document.querySelectorAll('[data-phase]')) {
    button.setAttribute('aria-pressed', String(button.dataset.phase === timer.phase));
  }
  $('#timer-state').textContent = running ? '正在计时' : started ? '已暂停' : '准备就绪';
  $('#timer-state').toggleAttribute('data-running', running);
  $('#clock-caption').textContent = running ? phases[timer.phase] + '中' : started ? '随时可以继续' : `准备${phases[timer.phase]}`;
  $('#timer-primary').innerHTML = `${icon(running ? 'pause' : 'play')} ${running ? '暂停' : started ? '继续计时' : `开始${phases[timer.phase]}`}`;
  $('#timer-reset').disabled = !started;
  const sound = $('#sound-toggle');
  sound.innerHTML = icon(state.settings.sound ? 'volume' : 'mute');
  sound.title = state.settings.sound ? '关闭结束提示音' : '开启结束提示音';
  sound.setAttribute('aria-label', '结束提示音');
  sound.setAttribute('aria-pressed', String(state.settings.sound));
  const dots = Array.from({ length: state.settings.rounds }, (_, index) =>
    `<span${index < state.round ? ' class="filled"' : ''}></span>`).join('');
  $('#round-progress').innerHTML = `<span class="round-dots" aria-hidden="true">${dots}</span> 本组 ${Math.min(state.round, state.settings.rounds)} / ${state.settings.rounds}`;
}

function picker(day) {
  const field = $('#focus-task');
  const timer = state.timer;
  $('#focus-task-label').hidden = timer.phase !== 'focus';
  field.disabled = timer.id !== null;
  const choices = currentTasks(state, day).filter(task => !task.done);
  if (!choices.some(task => task.id === selectedTask)) selectedTask = '';
  field.replaceChildren(new Option(timer.id ? timer.task || '自由专注' : '选择本次任务', ''));
  if (timer.id === null) {
    for (const task of choices) field.add(new Option(task.title, task.id));
    field.value = selectedTask;
  }
}

function empty(title, copy, name = 'sprout') {
  return `<div class="empty">${icon(name)}<div><strong>${title}</strong>${copy}</div></div>`;
}

function taskRow(task, place, editable = false) {
  const name = escape(task.title);
  const id = escape(task.id);
  const attrs = `data-id="${id}"`;
  const check = `<button class="task-check" type="button" data-action="check" ${attrs} data-focus-key="${place}-${id}" aria-label="${name}" aria-pressed="${task.done}">${task.done ? icon('check') : ''}</button>`;
  const actions = `<button class="icon-button" type="button" data-action="edit" ${attrs} aria-label="编辑 ${name}">${icon('edit')}</button>
    <button class="icon-button" type="button" data-action="delete" ${attrs} aria-label="删除 ${name}">${icon('trash')}</button>`;
  return `<li class="task-row${task.done ? ' done' : ''}">${check}<span class="task-name">${name}</span>${editable ? actions : ''}</li>`;
}

function renderFocus(now, day, today) {
  const completed = state.sessions.filter(item => dayKey(item.end) === today);
  $('#daily-total').innerHTML = `${icon('sprout')} 今日 ${completed.length} 个番茄`;
  const todayTasks = currentTasks(state, day);
  const preview = todayTasks.filter(task => !task.done).slice(0, 3);
  const taskCopy = todayTasks.length
    ? empty('今日任务已完成', '可以添加下一件要做的事。', 'check')
    : empty('今天还没有任务', '从一件想完成的事开始。', 'task');
  $('#task-preview').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">TODAY</p><h2>今日要事</h2></div><a class="text-button" href="#tasks">全部 ${icon('arrow')}</a></div>
    ${preview.length ? `<ul class="task-list">${preview.map(task => taskRow(task, 'preview')).join('')}</ul>` : taskCopy}
    <button class="text-button add-line" type="button" data-action="add" data-category="work">${icon('plus')} 添加任务</button>`;
  const block = timeBlock(now);
  const goal = state.blocks[block.number] || '为这段时间定个目标';
  const count = completed.filter(item => item.block === block.number).length;
  const plants = Array.from({ length: state.settings.target }, (_, index) => index < count
    ? `<span class="planted">${icon('sprout')}</span>` : '<span></span>').join('');
  $('#current-block').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">TIME BLOCK</p><h2>当前时间块</h2></div><button class="text-button" type="button" data-action="goal" data-block="${block.number}">${icon('edit')} 目标</button></div>
    <div class="block-label"><span class="block-number">B${block.number}</span><div class="block-info"><strong>${escape(goal)}</strong><small>${block.label}</small></div><span class="block-count">${count} / ${state.settings.target}</span></div><div class="plant-rail" aria-hidden="true">${plants}</div>`;
  $('#week-preview').innerHTML = `<div class="panel-heading"><div><p class="eyebrow">LAST 7 DAYS</p><h2>最近七天</h2></div><a class="text-button" href="#review">查看复盘 ${icon('arrow')}</a></div>${chart(today, 7)}`;
  picker(day);
}

function renderTasks(day) {
  const all = currentTasks(state, day);
  const older = state.tasks.filter(task => task.day < day && !task.done)
    .sort((a, b) => b.day.localeCompare(a.day));
  const panels = Object.entries(categories).map(([key, label]) => {
    const items = all.filter(task => task.category === key);
    const badge = key === 'chores' ? items.length : `${items.length} / 3`;
    return `<article class="panel"><div class="panel-heading"><h2>${label}</h2><span class="badge">${badge}</span></div>
      ${items.length ? `<ul class="task-list">${items.map(task => taskRow(task, 'board', true)).join('')}</ul>` : empty('暂无任务', '添加一件今天想做的事。')}
      <button class="text-button add-line" type="button" data-action="add" data-category="${key}" ${taskLimitReached(state, day, key) ? 'disabled' : ''}>${icon('plus')} 添加${label}任务</button></article>`;
  }).join('');
  const carryRows = older.map(task => `<li class="task-row"><span class="task-name">${escape(task.title)} <small class="muted">${escape(task.day)} · ${categories[task.category]}</small></span>
    <button class="text-button" type="button" data-action="carry" data-id="${escape(task.id)}">移到今天 ${icon('arrow')}</button>
    <button class="icon-button" type="button" data-action="delete" data-id="${escape(task.id)}" aria-label="删除 ${escape(task.title)}">${icon('trash')}</button></li>`).join('');
  $('#task-board').innerHTML = `<div class="category-grid">${panels}</div><article class="panel later-panel"><div class="panel-heading"><h2>未完成任务</h2><span class="badge">${older.length}</span></div>
    ${older.length ? `<ul class="task-list">${carryRows}</ul>` : empty('没有待顺延的任务', '过去未完成的任务会显示在这里。')}</article>`;
}

function chart(today, count) {
  const byDay = new Map(recentDays(today, count).map(day => [day, 0]));
  for (const item of state.sessions) {
    const day = dayKey(item.end);
    if (byDay.has(day)) byDay.set(day, byDay.get(day) + item.minutes);
  }
  const peak = Math.max(1, ...byDay.values());
  const columns = [...byDay].map(([day, minutes]) => {
    const label = count === 7 ? day.slice(5).replace('-', '/') : day.slice(8);
    return `<div class="chart-col" role="listitem" aria-label="${day}，${minutes} 分钟" title="${day} · ${minutes} 分钟"><span>${minutes}</span><div class="bar-slot"><div class="bar" data-height="${100 * minutes / peak}"></div></div><time datetime="${day}">${label}</time></div>`;
  }).join('');
  return `<div class="chart" data-range="${count}" role="list" aria-label="每日专注分钟数">${columns}</div>`;
}

function rangeSessions(today) {
  const start = previousDay(today, range - 1);
  return state.sessions.filter(item => dayKey(item.end) >= start && dayKey(item.end) <= today)
    .sort((a, b) => b.end - a.end);
}

function renderReview(today) {
  const items = rangeSessions(today);
  const { count, minutes } = summarize(items);
  const activeDays = new Set(items.map(item => dayKey(item.end))).size;
  const rangeButtons = [7, 30].map(value => `<button class="button button-quiet" type="button" data-action="range" data-range="${value}" data-focus-key="range-${value}" aria-pressed="${value === range}">${value} 天</button>`).join('');
  const rows = items.map(item => `<li class="task-row"><span class="task-name">${escape(item.task || '自由专注')} <small class="muted">${sessionFormatter.format(item.end)}</small></span><span class="badge">B${item.block} · ${item.minutes} 分钟</span></li>`).join('');
  $('#review-body').innerHTML = `<div class="stats-grid"><div class="panel"><small>完成番茄</small><strong>${count}</strong></div><div class="panel"><small>专注分钟</small><strong>${minutes}</strong></div><div class="panel"><small>有记录的天数</small><strong>${activeDays}</strong></div></div>
    <article class="panel later-panel"><div class="panel-heading"><h2>每日专注</h2><div class="review-range" aria-label="复盘范围">${rangeButtons}</div></div>${chart(today, range)}</article>
    <article class="panel later-panel"><div class="panel-heading"><h2>专注明细</h2></div>${rows ? `<ul class="task-list">${rows}</ul>` : empty('暂无专注记录', '完成一个番茄后，这里会显示时长和时间块。')}</article>`;
}

function renderData() {
  const now = Date.now();
  const day = dayKey(now, 4);
  const today = dayKey(now);
  lastCalendar = `${day}/${today}/${timeBlock(now).number}`;
  $('#current-date').dateTime = today;
  $('#current-date').textContent = dateFormatter.format(now);
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

function showDialog(title, fields, submit, handleSubmit) {
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
  (form.querySelector('input') ?? form.querySelector('[type="submit"]')).focus();
}

dialog.addEventListener('close', () => {
  if (!dialog.open) dialog.replaceChildren();
});

function settingsDialog() {
  const labels = { focus: '专注（分钟）', short: '短休息（分钟）', long: '长休息（分钟）', rounds: '每组番茄数', target: '每块目标番茄数' };
  const fields = Object.entries(labels).map(([key, label]) => {
    const [min, max] = limits[key];
    return `<label>${label}<input type="number" name="${key}" min="${min}" max="${max}" value="${state.settings[key]}" required></label>`;
  }).join('');
  showDialog('设置', `<p class="muted">任务日从 04:00 开始，专注记录按自然日统计。</p><div class="form-grid">${fields}</div><label class="inline-field"><input name="sound" type="checkbox" ${state.settings.sound ? 'checked' : ''}> 计时结束提示音</label><label class="inline-field"><input name="ambient" type="checkbox" ${ambientEnabled() ? 'checked' : ''}> 专注时播放栖时随机场景</label><label>场景音量<input name="ambientVolume" type="range" min="0" max="1" step="0.05" value="${ambientVolume()}"></label><button class="button button-quiet" type="button" data-action="qishi-preview">试听随机场景</button>`, '保存', values => changeState(current => {
    const settings = { ...defaults, sound: values.has('sound'), ambient: values.has('ambient') ? 'qishi' : 'off', ambientVolume: ambientVolume({ settings: { ambientVolume: values.get('ambientVolume') } }) };
    for (const [key, [min, max]] of Object.entries(limits)) {
      const number = Number(values.get(key));
      if (!Number.isInteger(number) || number < min || number > max) throw new Error(`${labels[key]}超出范围。`);
      settings[key] = number;
    }
    current.settings = settings;
    if (current.timer.id === null) current.timer = emptyTimer(current.timer.phase, settings);
    return '已保存设置。';
  }));
}

function taskDialog(category, existing) {
  const choices = Object.entries(categories).map(([key, label]) =>
    `<option value="${key}" ${key === category ? 'selected' : ''}>${label}</option>`).join('');
  showDialog(existing ? '编辑任务' : '添加任务', `<label>任务名称<input name="title" maxlength="120" value="${escape(existing?.title)}" required></label><label>分类<select name="category">${choices}</select></label>`, '保存任务', values => changeState((current, now) => {
    const title = String(values.get('title')).trim();
    const nextCategory = String(values.get('category'));
    if (!title || !Object.hasOwn(categories, nextCategory)) throw new Error('请填写任务名称并选择分类。');
    const day = dayKey(now, 4);
    const task = existing && current.tasks.find(item => item.id === existing.id && item.day === day);
    if (existing && !task) throw new Error('这个任务已经移走，或已进入下一任务日。');
    if ((!task || task.category !== nextCategory) && taskLimitReached(current, day, nextCategory)) {
      throw new Error(`${categories[nextCategory]}分类今天已添加三件任务。`);
    }
    if (task) Object.assign(task, { title, category: nextCategory });
    else current.tasks.push({ id: crypto.randomUUID(), title, category: nextCategory, day, done: false });
    return task ? '已更新任务。' : '已添加任务。';
  }));
}

function goalDialog(block) {
  showDialog(`B${block} 时间块目标`, `<label>目标<input name="goal" maxlength="80" value="${escape(state.blocks[block])}" placeholder="输入这一时间块的目标"></label><p class="muted">该目标会在每天相同的时段显示。</p>`, '保存目标', values => changeState(current => {
    current.blocks[block] = String(values.get('goal')).trim();
    return '已保存时间块目标。';
  }));
}

function confirm(title, message, submit, callback) {
  showDialog(title, `<p class="muted">${message}</p>`, submit, callback);
}

function changePhase(phase) {
  if (state.timer.phase === phase) return;
  const expected = state.timer;
  const update = () => changeState(current => {
    if (!sameTimer(current.timer, expected)) return '计时已在另一个页面更新。';
    resetTimer(current, phase);
  }, { skipAfterFinish: true });
  if (state.timer.id) confirm('切换计时阶段', '当前这次计时将结束，未完成的专注不会写入记录。', '切换阶段', update);
  else void update();
}

function changeTask(action, id) {
  const task = state.tasks.find(item => item.id === id);
  if (!task) return;
  if (action === 'edit') return taskDialog(task.category, task);
  if (action === 'delete') return confirm('删除任务', `删除「${escape(task.title)}」？`, '删除任务', () => changeState(current => {
    current.tasks = current.tasks.filter(item => item.id !== id);
    return '已删除任务。';
  }));
  void changeState((current, now) => {
    const item = current.tasks.find(candidate => candidate.id === id);
    if (!item) return null;
    const day = dayKey(now, 4);
    if (action === 'check' && item.day === day) {
      item.done = !item.done;
      return item.done ? '已完成任务。' : '已恢复任务。';
    }
    if (action === 'carry' && !item.done && item.day < day) {
      if (taskLimitReached(current, day, item.category)) return `${categories[item.category]}分类今天已添加三件任务。`;
      item.day = day;
      return '已移到今天。';
    }
    return null;
  });
}

function csvCell(value) {
  let text = String(value ?? '');
  if (/^[\s\u0000-\u001f]*[=+@-]/.test(text)) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}

function exportCsv() {
  const today = dayKey(Date.now());
  const records = rangeSessions(today);
  const rows = [['结束时间', '任务', '专注分钟', '时间块'], ...records.map(item =>
    [sessionFormatter.format(item.end), item.task, item.minutes, `B${item.block}`])];
  const url = URL.createObjectURL(new Blob(['\ufeff', rows.map(row => row.map(csvCell).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = `focus-${today}-${range}d.csv`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  announce(`已导出 ${records.length} 条专注记录。`);
}

function renderHabitica() {
  const notice = habiticaMessage ? `<p class="notice" role="status">${escape(habiticaMessage)}</p>` : '';
  if (!account) {
    $('#habitica-body').innerHTML = `<article class="panel"><div class="panel-heading"><h2>连接你的 Habitica 账号</h2>${icon('habitica')}</div><p class="panel-copy">输入 Habitica 的 User ID 与 API Token。网页直接连接 habitica.com，凭据仅在当前页面打开期间保留。</p><button class="button button-primary add-line" type="button" data-action="connect">连接账号</button>${notice}</article>`;
    return;
  }
  const disabled = habiticaBusy ? 'disabled' : '';
  const lists = [['habit', '习惯'], ['daily', '每日打卡']].map(([type, label]) => {
    const tasks = account.tasks.filter(task => task.type === type);
    const rows = tasks.map(task => {
      const name = escape(task.text);
      const score = (direction, label, nameIcon) => `<button class="button button-quiet" type="button" data-action="score" data-id="${escape(task.id || task._id)}" data-direction="${direction}" aria-label="${name} ${label}" ${disabled}>${icon(nameIcon)}</button>`;
      const actions = type === 'habit'
        ? `${task.down ? score('down', '减分', 'minus') : ''}${task.up ? score('up', '加分', 'plus') : ''}`
        : score(task.completed ? 'down' : 'up', task.completed ? '取消打卡' : '完成打卡', task.completed ? 'reset' : 'check');
      return `<li><strong${type === 'daily' && task.completed ? ' class="scored"' : ''}>${name}</strong>${actions}</li>`;
    }).join('');
    return `<article class="panel"><div class="panel-heading"><h2>${label}</h2><span class="badge">${tasks.length}</span></div>${rows ? `<ul class="integration-list">${rows}</ul>` : empty('列表为空', '在 Habitica 添加后可刷新查看。')}</article>`;
  }).join('');
  const { lvl, hp, gp } = account.stats;
  $('#habitica-body').innerHTML = `<article class="panel integration-top"><div class="panel-heading"><h2>${escape(account.name)}</h2><div class="integration-actions"><button type="button" class="button button-quiet" data-action="refresh" ${disabled}>${habiticaBusy ? '正在请求…' : '刷新'}</button><button type="button" class="button button-quiet" data-action="disconnect" ${disabled}>断开</button></div></div><p class="panel-copy">等级 ${escape(lvl)} · 生命 ${Math.round(hp)} · 金币 ${Math.round(gp)}</p>${notice}</article><div class="integration-grid">${lists}</div>`;
}

function connectDialog() {
  showDialog('连接 Habitica', `<p class="muted">可在 <a class="link" href="https://habitica.com/user/settings/api" target="_blank" rel="noopener noreferrer">Habitica API 设置</a> 找到凭据。关闭或刷新本页后需要重新连接。</p><label>User ID<input name="user" required autocomplete="off" maxlength="128" spellcheck="false"></label><label>API Token<input name="token" required type="password" autocomplete="off" maxlength="128"></label>`, '连接', async values => {
    const next = { user: String(values.get('user')).trim(), token: String(values.get('token')).trim() };
    if (!next.user || !next.token) throw new Error('请填写 User ID 和 API Token。');
    const form = dialog.querySelector('form');
    const data = await loadAccount(next);
    if (!dialog.open || dialog.querySelector('form') !== form) return;
    account = data;
    connection = next;
    habiticaMessage = '';
    renderHabitica();
    announce('已连接 Habitica。');
  });
}

async function updateHabitica(action, dataset) {
  if (habiticaBusy || !connection) return;
  habiticaBusy = true;
  habiticaMessage = '';
  renderHabitica();
  let scored = false;
  try {
    if (action === 'score') {
      await scoreTask(connection, dataset.id, dataset.direction);
      scored = true;
      // Disable writes until the next successful refresh so stale Daily states cannot be reused.
      account.tasks = [];
    }
    account = await loadAccount(connection);
    if (scored) announce('已记录 Habitica 打分。');
  } catch (failure) {
    if (scored) habiticaMessage = `打分已提交，列表刷新失败。${failure.message}`;
    else if (action === 'score') {
      account.tasks = [];
      habiticaMessage = `打分结果待确认。${failure.message} 请先刷新列表。`;
    } else habiticaMessage = failure.message;
  } finally {
    habiticaBusy = false;
    renderHabitica();
  }
}

function sameTimer(timer, expected) {
  return timer.id === expected.id && timer.phase === expected.phase && timer.end === expected.end;
}

function timerAction(action) {
  const expected = state.timer;
  if (action === 'timer') {
    openAudio();
    const starting = expected.phase === 'focus' && expected.end === null;
    if (qishi && expected.phase === 'focus') {
      showScene(qishi.prepare(qishiIntent(state, starting)));
    }
    return changeState((current, now) => {
      if (!sameTimer(current.timer, expected)) return null;
      const task = currentTasks(current, dayKey(now, 4)).find(item => item.id === selectedTask && !item.done);
      return toggleTimer(current, now, task?.title ?? null);
    }, { skipAfterFinish: true });
  }
  if (action === 'reset' && expected.id) {
    confirm('重置计时', '当前这次计时将结束，未完成的专注不会写入记录。', '重置', () => changeState(current => {
      if (!sameTimer(current.timer, expected)) return '计时已在另一个页面更新。';
      resetTimer(current);
      return '已重置计时。';
    }, { skipAfterFinish: true }));
  }
}

document.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (!button || button.disabled) return;
  const { action, category, id, block, phase } = button.dataset;
  if (phase) return changePhase(phase);
  switch (action) {
    case 'timer': case 'reset': return timerAction(action);
    case 'sound':
      openAudio();
      return changeState(current => { current.settings.sound = !current.settings.sound; });
    case 'add': return taskDialog(category);
    case 'check': case 'edit': case 'delete': case 'carry': return changeTask(action, id);
    case 'goal': return goalDialog(block);
    case 'settings': return settingsDialog();
    case 'qishi-preview': {
      const volume = Number(dialog.querySelector('[name="ambientVolume"]')?.value);
      const preset = qishi?.preview(Number.isFinite(volume) ? volume : ambientVolume());
      return announce(preset ? `正在试听「${preset.name}」。` : '栖时场景库暂时不可用。');
    }
    case 'close': return dialog.close();
    case 'export': return exportCsv();
    case 'range':
      range = Number(button.dataset.range);
      renderData();
      return $(`[data-range="${range}"][data-action="range"]`).focus();
    case 'connect': return connectDialog();
    case 'refresh': case 'score': return updateHabitica(action, button.dataset);
    case 'disconnect':
      connection = null;
      account = null;
      habiticaMessage = '';
      renderHabitica();
      return announce('已断开 Habitica。');
  }
});

$('#focus-task').addEventListener('change', event => { selectedTask = event.target.value; });
window.addEventListener('hashchange', showView);
window.addEventListener('storage', event => {
  if ((event.key === storageKey || event.key === null) && storageAvailable) {
    state = readState(state);
    renderData();
  }
});
document.addEventListener('keydown', event => {
  if (event.code === 'Space' && !event.repeat && !event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey && view === 'focus' && !dialog.open && !event.target.closest('button, a, input, select, textarea, [contenteditable]')) {
    event.preventDefault();
    timerAction('timer');
  }
});

function tick() {
  const now = Date.now();
  if (state.timer.end !== null && state.timer.end <= now && !settling) {
    settling = true;
    void changeState().finally(() => { settling = false; });
  } else if (lastCalendar !== `${dayKey(now, 4)}/${dayKey(now)}/${timeBlock(now).number}`) renderData();
  else renderTimer(now);
}

$('#hub-return').hidden = !location.pathname.startsWith('/habitica-pomodoro-web/');
showView();
renderData();
renderHabitica();
tick();
setInterval(tick, 250);
document.addEventListener('visibilitychange', tick);
window.addEventListener('pageshow', tick);
