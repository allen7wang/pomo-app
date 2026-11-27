export const defaults = { focus: 25, short: 5, long: 15, rounds: 4, target: 6, sound: true };
export const phases = { focus: '专注', short: '短休息', long: '长休息' };
export const categories = { work: '工作', personal: '个人', chores: '琐事' };
export const storageKey = 'habitica-pomodoro-web:v1';

export function emptyTimer(phase, settings) {
  const duration = settings[phase] * 60_000;
  return { phase, duration, remaining: duration, end: null, id: null, task: null };
}

export function freshState() {
  return {
    settings: { ...defaults }, timer: emptyTimer('focus', defaults), round: 0,
    tasks: [], sessions: [], blocks: {},
  };
}

export function dayKey(time, boundary = 0) {
  const date = new Date(time);
  if (date.getHours() < boundary) date.setDate(date.getDate() - 1);
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()]
    .map(value => String(value).padStart(2, '0')).join('-');
}

export function previousDay(day, offset = 1) {
  const date = new Date(`${day}T12:00:00`);
  date.setDate(date.getDate() - offset);
  return dayKey(date);
}

export function timeBlock(time) {
  const hour = new Date(time).getHours();
  const number = Math.floor(((hour + 20) % 24) / 3) + 1;
  const start = (4 + (number - 1) * 3) % 24;
  const label = hour => `${String(hour).padStart(2, '0')}:00`;
  return { number, label: `${label(start)} – ${label((start + 3) % 24)}` };
}

export function remainingTime(timer, now) {
  return Math.max(0, timer.end === null ? timer.remaining : timer.end - now);
}

export function settleTimer(state, now) {
  const timer = state.timer;
  if (timer.end === null || timer.end > now) return null;

  if (timer.phase === 'focus') {
    state.sessions.push({
      id: timer.id, end: timer.end, minutes: timer.duration / 60_000,
      block: timeBlock(timer.end).number, task: timer.task,
    });
    state.round += 1;
    const next = state.round >= state.settings.rounds ? 'long' : 'short';
    state.timer = emptyTimer(next, state.settings);
    return next === 'long' ? '完成一组专注，准备长休息。' : '完成一个番茄，准备短休息。';
  }

  if (timer.phase === 'long') state.round = 0;
  state.timer = emptyTimer('focus', state.settings);
  return '休息结束，可以开始下一次专注。';
}

export function toggleTimer(state, now, selectedTask) {
  const timer = state.timer;
  if (timer.end !== null) {
    timer.remaining = remainingTime(timer, now);
    timer.end = null;
    return '计时已暂停。';
  }
  if (timer.id === null) {
    timer.id = crypto.randomUUID();
    timer.task = timer.phase === 'focus' ? selectedTask : null;
  }
  timer.end = now + timer.remaining;
  return `${phases[timer.phase]}计时已开始。`;
}

export function resetTimer(state, phase = state.timer.phase) {
  if ((state.timer.phase === 'long' && phase !== 'long') || (phase === 'focus' && state.round >= state.settings.rounds)) {
    state.round = 0;
  }
  state.timer = emptyTimer(phase, state.settings);
}

export function currentTasks(state, day) {
  return state.tasks.filter(task => task.day === day);
}

export function taskLimitReached(state, day, category) {
  return category !== 'chores' && currentTasks(state, day)
    .filter(task => task.category === category).length >= 3;
}

export function summarize(sessions) {
  return { count: sessions.length, minutes: sessions.reduce((total, item) => total + item.minutes, 0) };
}

export function recentDays(day, count) {
  return Array.from({ length: count }, (_, index) => previousDay(day, count - 1 - index));
}
