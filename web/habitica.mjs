// Habitica API v3 from the browser. Credentials live only in this page's memory and are never stored.
export const apiRoot = 'https://habitica.com/api/v3/';
const client = '5a8238ab-1819-4f7f-a750-f23264719a2d-HabiticaPomodoroSiteKeeper-Web';
const uidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class HabiticaError extends Error {
  /** `sent` is false when the request never left the page (budget, cooldown, invalid input). */
  constructor(message, { status = 0, sent = true } = {}) {
    super(message);
    this.status = status;
    this.sent = sent;
  }
}

export const isValidUserId = value => uidPattern.test(value);

/** Account owner key for local task ownership: a hash, so the User ID itself is never stored. */
export async function ownerKey(user) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${user.toLowerCase()}|${apiRoot}`));
  return [...new Uint8Array(bytes)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

/** Habitica allows 30 requests a minute; keep room for the user's other clients. Rejects instead of queueing. */
export function createBudget({ limit = 24, window = 60_000 } = {}) {
  let starts = [];
  let cooldownUntil = 0;
  let limited = false;
  return {
    wait(now) {
      starts = starts.filter(time => time > now - window);
      if (now >= cooldownUntil) limited = false;
      const local = starts.length >= limit ? starts[0] + window - now : 0;
      return Math.max(0, local, cooldownUntil - now);
    },
    reserve(now) {
      const wait = this.wait(now);
      if (wait <= 0) starts.push(now);
      return wait;
    },
    cooldown(now, seconds) {
      cooldownUntil = Math.max(cooldownUntil, now + (Number.isFinite(seconds) && seconds >= 0 ? seconds : 60) * 1000 + 1000);
      limited = true;
    },
    message(now) {
      const wait = this.wait(now);
      if (wait <= 0) return null;
      return `${limited ? 'Habitica 暂时限流（HTTP 429）' : 'Habitica 请求额度暂时用完'}，请 ${Math.ceil(wait / 1000)} 秒后重试。`;
    },
  };
}

const todoFrom = item => ({
  id: item.id || item._id, title: item.text, notes: typeof item.notes === 'string' ? item.notes : '',
  completed: item.completed === true, tags: Array.isArray(item.tags) ? item.tags.filter(tag => typeof tag === 'string' && tag) : [],
});

/** Malformed entries or duplicate ids fail the whole list, so the caller keeps what it already shows. */
export function parseTaskList(data) {
  if (!Array.isArray(data)) return null;
  const ids = new Set();
  const tasks = [];
  for (const item of data) {
    const id = item && (typeof item.id === 'string' && item.id ? item.id : typeof item._id === 'string' && item._id ? item._id : null);
    if (!id || typeof item.text !== 'string' || ids.has(id)) return null;
    ids.add(id);
    tasks.push({ ...item, id });
  }
  return tasks;
}

const validId = value => typeof value === 'string' && /^[\w-]+$/.test(value);

export function createApi({ user, token, budget = createBudget(), fetch = globalThis.fetch.bind(globalThis), now = Date.now }) {
  async function request(path, { method = 'GET', body } = {}) {
    const wait = budget.reserve(now());
    if (wait > 0) throw new HabiticaError(budget.message(now()), { sent: false, status: 429 });
    let response;
    try {
      response = await fetch(new URL(path, apiRoot), {
        method, credentials: 'omit', redirect: 'error', cache: 'no-store', signal: AbortSignal.timeout(15_000),
        headers: {
          'x-client': client, 'x-api-user': user, 'x-api-key': token,
          ...(body ? { 'content-type': 'application/json' } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch {
      throw new HabiticaError('无法连接 Habitica，请检查网络后重试。');
    }
    if (response.status === 429) {
      budget.cooldown(now(), Number(response.headers.get('retry-after')));
      throw new HabiticaError(budget.message(now()) ?? 'Habitica 暂时限流（HTTP 429），请稍后重试。', { status: 429 });
    }
    if (response.status === 401) throw new HabiticaError('Habitica 凭据无效，请核对 User ID 和 API Token。', { status: 401 });
    if (!response.ok) throw new HabiticaError(`Habitica 请求失败（HTTP ${response.status}）。`, { status: response.status });
    const payload = await response.json().catch(() => null);
    if (!payload?.success || payload.data === undefined) throw new HabiticaError('Habitica 返回了无法识别的结果。', { status: response.status });
    return payload.data;
  }

  const checked = (id, path, options) => {
    if (!validId(id)) throw new HabiticaError('Habitica 任务 ID 无效。', { sent: false });
    return request(path, options);
  };

  async function fetchTodos() {
    const lists = [];
    for (const type of ['todos', 'completedTodos']) {
      const data = await request(`tasks/user?type=${type}`);
      if (!Array.isArray(data)) throw new HabiticaError('Habitica todo 响应格式错误。', { status: 200 });
      lists.push(...data.filter(item => item && typeof item.text === 'string' && (item.id || item._id) && (item.type ?? 'todo') === 'todo').map(todoFrom));
    }
    return [...new Map(lists.map(todo => [todo.id, todo])).values()];
  }

  return {
    async loadAccount() {
      const [profile, data] = await Promise.all([
        request('user?userFields=profile.name,auth.local.username,stats'), request('tasks/user'),
      ]);
      const tasks = parseTaskList(data);
      if (!profile?.stats || !tasks) throw new HabiticaError('Habitica 返回了无法识别的账号数据。', { status: 200 });
      return { name: profile.profile?.name || profile.auth?.local?.username || 'Habitica 角色', stats: profile.stats, tasks };
    },
    scoreTask: (id, direction) => {
      if (!['up', 'down'].includes(direction)) throw new HabiticaError('这个 Habitica 任务无法打分。', { sent: false });
      return checked(id, `tasks/${id}/score/${direction}`, { method: 'POST' });
    },
    /** Default habits are found by alias and created only when Habitica says the alias is missing. */
    async ensureHabit(settings, combo) {
      const custom = combo ? settings.customSetTask : settings.customPomodoroTask;
      const configured = combo ? settings.pomodoroSetTaskId : settings.pomodoroTaskId;
      if (custom) {
        if (!validId(configured)) throw new HabiticaError('请填写有效的自定义 Habit ID。', { sent: false });
        const task = await request(`tasks/${configured}`);
        if (task?.type !== 'habit') throw new HabiticaError('自定义任务必须是 Habit。', { status: 200 });
        return configured;
      }
      const alias = combo ? 'sitepassPomodoroSet' : 'sitepassPomodoro';
      try {
        const found = await request(`tasks/${alias}`);
        if (found?.id || found?._id) return found.id || found._id;
        throw new HabiticaError('默认 Habit 返回格式无效。', { status: 200 });
      } catch (failure) {
        if (failure.status !== 404) throw failure; // never create on timeout, auth or server failure
      }
      const created = await request('tasks/user', { method: 'POST', body: {
        type: 'habit', text: combo ? 'Pomodoro Combo!' : 'Pomodoro', alias, up: true, down: true, priority: combo ? 1.5 : 1,
        notes: 'Habit utilized by Habitica SiteKeeper. Change the difficulty manually according to your needs.',
      } });
      if (!created?.id && !created?._id) throw new HabiticaError('默认 Habit 创建结果无效。', { status: 200 });
      return created.id || created._id;
    },
    sendPrivateMessage: message => request('members/send-private-message', { method: 'POST', body: { message, toUserId: user } }),
    fetchTodos,
    async fetchTodo(id) {
      const item = await checked(id, `tasks/${id}`);
      if (!item || typeof item.text !== 'string') throw new HabiticaError('Habitica todo 响应格式错误。', { status: 200 });
      return todoFrom({ ...item, id });
    },
    /** Distinguish "certainly not created" from an unknown outcome, which must be reconciled first. */
    async createTodo(text, notes, tags) {
      try {
        const data = await request('tasks/user', { method: 'POST', body: { type: 'todo', text, notes, tags } });
        const id = data?.id || data?._id;
        return id ? { status: 'created', id } : { status: 'uncertain' };
      } catch (failure) {
        if (!failure.sent || failure.status === 401 || failure.status === 429) return { status: 'notCreated', message: failure.message };
        return { status: 'uncertain', message: failure.message };
      }
    },
    updateTodo: (id, text, notes, tags) => checked(id, `tasks/${id}`, { method: 'PUT', body: { text, notes, tags } }),
    async deleteTodo(id) {
      try { await checked(id, `tasks/${id}`, { method: 'DELETE' }); } catch (failure) {
        if (failure.status !== 404) throw failure; // already gone counts as deleted
      }
      return true;
    },
    async fetchTags() {
      const data = await request('tags');
      if (!Array.isArray(data)) throw new HabiticaError('Habitica 标签响应格式错误。', { status: 200 });
      return Object.fromEntries(data.filter(tag => typeof tag?.id === 'string' && typeof tag.name === 'string').map(tag => [tag.id, tag.name]));
    },
    async createTag(name) {
      const data = await request('tags', { method: 'POST', body: { name } });
      if (typeof data?.id !== 'string') throw new HabiticaError('Habitica 标签创建结果无效。', { status: 200 });
      return data.id;
    },
    renameTag: (id, name) => checked(id, `tags/${id}`, { method: 'PUT', body: { name } }),
    rateLimitMessage: () => budget.message(now()),
  };
}

/** Role figures Habitica does not return directly (same formulas as the native Role page). */
export function roleFigures(stats) {
  const level = Number(stats.lvl) || 0;
  return {
    level, hp: Number(stats.hp) || 0, maxHealth: 50, mp: Number(stats.mp) || 0,
    maxMP: 30 + 3 * Math.max(0, level - 1) + (Number(stats.int) || 0) / 2,
    exp: Number(stats.exp) || 0, toNextLevel: level * level * 0.25 + 10 * level + 139.75, gp: Number(stats.gp) || 0,
    className: typeof stats.class === 'string' ? stats.class : '',
  };
}
