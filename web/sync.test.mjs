import assert from 'node:assert/strict';
import test from 'node:test';

process.env.TZ = 'Asia/Shanghai';
const { setIdFactory } = await import('./model.mjs');
const { addTask, allTasks, freshTopThree, moveTaskToToday, removeTask, renameCategory, toggleTask, unfinishedTasks, canAddTask } = await import('./tasks.mjs');
const { createSync, parseOwnedNotes, topThreeNotes } = await import('./sync.mjs');
const { createApi, createBudget, HabiticaError } = await import('./habitica.mjs');

let serial = 0;
setIdFactory(() => `LOCAL-${String(++serial).padStart(3, '0')}`);

/** In-memory Habitica with the endpoints the sync uses. */
function fakeHabitica() {
  const server = { todos: new Map(), tags: new Map(), hidden: new Set(), calls: [], next: 1, loseCreateResponse: false, rejectCreate: null, failFetch: false };
  const id = prefix => `${prefix}-${server.next++}`;
  const copy = todo => structuredClone(todo);
  server.api = {
    async fetchTodos() {
      server.calls.push('GET todos');
      if (server.failFetch) throw new HabiticaError('网络错误');
      return [...server.todos.values()].filter(todo => !server.hidden.has(todo.id)).map(copy);
    },
    async fetchTodo(remote) {
      server.calls.push(`GET ${remote}`);
      if (!server.todos.has(remote)) throw new HabiticaError('HTTP 404', { status: 404 });
      return copy(server.todos.get(remote));
    },
    async createTodo(title, notes, tags) {
      server.calls.push(`POST ${title}`);
      if (server.rejectCreate) return { status: 'notCreated', message: server.rejectCreate };
      const todo = { id: id('todo'), title, notes, completed: false, tags: [...tags] };
      server.todos.set(todo.id, todo);
      if (server.hideCreated) server.hidden.add(todo.id);
      return server.loseCreateResponse ? { status: 'uncertain' } : { status: 'created', id: todo.id };
    },
    async updateTodo(remote, title, notes, tags) {
      server.calls.push(`PUT ${remote}`);
      if (!server.todos.has(remote)) throw new HabiticaError('HTTP 404', { status: 404 });
      Object.assign(server.todos.get(remote), { title, notes, tags: [...tags] });
    },
    async scoreTask(remote, direction) { server.calls.push(`SCORE ${remote} ${direction}`); server.todos.get(remote).completed = direction === 'up'; },
    async deleteTodo(remote) { server.calls.push(`DELETE ${remote}`); server.todos.delete(remote); return true; },
    async fetchTags() { server.calls.push('GET tags'); return Object.fromEntries(server.tags); },
    async createTag(name) { server.calls.push(`POST tag ${name}`); const tag = id('tag'); server.tags.set(tag, name); return tag; },
    async renameTag(tag, name) { server.calls.push(`PUT tag ${name}`); server.tags.set(tag, name); },
  };
  return server;
}

/** Storage round trip like the page: every read is a fresh copy of the last write. */
function harness(store = freshTopThree()) {
  let saved = JSON.stringify(store);
  return {
    read: () => JSON.parse(saved),
    write: async edit => { const next = JSON.parse(saved); edit(next); saved = JSON.stringify(next); return true; },
    edit(edit) { const next = JSON.parse(saved); const result = edit(next); saved = JSON.stringify(next); return result; },
  };
}

const today = '2024-03-12';

test('notes carry the app date and category; anything else is not imported', () => {
  assert.equal(topThreeNotes('Work', today), 'From HabiticaPomodoro Top3 · Work · 2024-03-12');
  assert.deepEqual(parseOwnedNotes('From HabiticaPomodoro Top3 · Work · 2024-03-12'), { category: 'Work', date: today });
  for (const notes of ['From HabiticaPomodoro Top3 · Work · 2024-02-30', 'From HabiticaPomodoro Top3 ·  Work · 2024-03-12', 'Work · 2024-03-12', 'From HabiticaPomodoro Top3 · A · B · 2024-03-12']) {
    assert.equal(parseOwnedNotes(notes), null, notes);
  }
});

test('a new task creates one todo with its category tag, then confirms by read-back', async () => {
  const server = fakeHabitica();
  const local = harness();
  const task = local.edit(store => addTask(store, today, 0, '写周报', null));
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  const result = await sync.run();
  const saved = allTasks(local.read())[0];
  assert.equal(saved.id, task.id);
  assert.equal(saved.cloudAccount, 'A', 'an unowned task is adopted by the first account');
  assert.equal(saved.syncPending, false);
  const todo = server.todos.get(saved.habiticaTaskId);
  assert.deepEqual([todo.title, todo.notes, todo.tags.map(tag => server.tags.get(tag))], ['写周报', topThreeNotes('Work', today), ['Work']]);
  assert.match(result.message, /已同步/);
  local.edit(store => toggleTask(store, today, today, 0, task.id));
  await sync.run();
  assert.equal(server.todos.get(saved.habiticaTaskId).completed, true);
  assert.equal(server.calls.filter(call => call.startsWith('POST 写周报')).length, 1);
});

test('a lost POST response is reconciled from the cloud, never posted twice', async () => {
  const server = fakeHabitica();
  const local = harness();
  local.edit(store => addTask(store, today, 1, '跑步', 'A'));
  local.edit(store => { store.cloudAccount = 'A'; });
  server.loseCreateResponse = true;
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  const first = await sync.run();
  assert.match(first.message, /未确认/);
  const recovered = allTasks(local.read())[0];
  assert.ok(recovered.habiticaTaskId && !recovered.cloudCreateAttempt && recovered.syncPending, 'the import step binds the unique match');
  server.loseCreateResponse = false;
  await sync.run();
  const bound = allTasks(local.read())[0];
  assert.equal(server.todos.size, 1);
  assert.equal(bound.habiticaTaskId, [...server.todos.keys()][0]);
  assert.equal(bound.syncPending, false);
  assert.equal(server.calls.filter(call => call === 'POST 跑步').length, 1);
});

test('an unresolved lost POST with no unique match is left for manual review', async () => {
  const server = fakeHabitica();
  const local = harness();
  local.edit(store => addTask(store, today, 1, '跑步', 'A'));
  local.edit(store => { store.cloudAccount = 'A'; });
  server.loseCreateResponse = true;
  server.hideCreated = true; // created, but not yet visible in the todo list
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  await sync.run();
  assert.ok(allTasks(local.read())[0].cloudCreateAttempt);
  const result = await sync.run();
  assert.match(result.message, /未重复创建/);
  assert.equal(server.calls.filter(call => call === 'POST 跑步').length, 1);
  server.hidden.clear();
  await sync.run();
  assert.equal(allTasks(local.read())[0].habiticaTaskId, [...server.todos.keys()][0]);
  assert.equal(allTasks(local.read())[0].syncPending, false);
  assert.equal(server.calls.filter(call => call === 'POST 跑步').length, 1);
});

test('a create the server refused (401/429/not sent) may be retried later', async () => {
  const server = fakeHabitica();
  const local = harness();
  local.edit(store => addTask(store, today, 2, '倒垃圾', 'A'));
  local.edit(store => { store.cloudAccount = 'A'; });
  server.rejectCreate = 'Habitica 暂时限流（HTTP 429），请 30 秒后重试。';
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  assert.match((await sync.run()).message, /限流/);
  assert.equal(allTasks(local.read())[0].cloudCreateAttempt, undefined);
  server.rejectCreate = null;
  await sync.run();
  assert.equal(server.todos.size, 1);
  assert.equal(allTasks(local.read())[0].syncPending, false);
});

test('deleting a synced task queues a confirmed delete and keeps the tombstone', async () => {
  const server = fakeHabitica();
  const local = harness();
  const task = local.edit(store => addTask(store, today, 0, '删除我', 'A'));
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  await sync.run();
  const remote = allTasks(local.read())[0].habiticaTaskId;
  local.edit(store => removeTask(store, today, today, 0, task.id));
  assert.deepEqual(local.read().deletedCloudIds, [remote]);
  const stale = structuredClone(server.todos.get(remote));
  await sync.run();
  assert.ok(!server.todos.has(remote));
  assert.deepEqual(local.read().confirmedDeletedCloudIds, [remote]);
  server.todos.set(remote, stale); // a stale list still returns it
  await sync.run();
  assert.equal(allTasks(local.read()).length, 0, 'a tombstoned id is never resurrected');
  assert.equal(server.calls.filter(call => call === `DELETE ${remote}`).length, 1, 'confirmed deletes are not re-sent');
});

test('removing a task while its POST is in flight deletes the todo it created', async () => {
  const server = fakeHabitica();
  const local = harness();
  const task = local.edit(store => addTask(store, today, 0, '马上删', 'A'));
  local.edit(store => { store.cloudAccount = 'A'; });
  const create = server.api.createTodo;
  server.api.createTodo = async (...args) => {
    local.edit(store => removeTask(store, today, today, 0, task.id));
    return create(...args);
  };
  await createSync({ ...local, api: server.api, owner: 'A' }).run();
  assert.equal(server.todos.size, 0);
  assert.equal(local.read().deletedCreateAttempts.length, 0);
  assert.equal(local.read().confirmedDeletedCloudIds.length, 1);
});

test('import: dated todos only, pending local edits win, the category limit holds', async () => {
  const server = fakeHabitica();
  const local = harness();
  local.edit(store => { store.cloudAccount = 'A'; });
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  await sync.run();
  const add = (title, notes, completed = false) => server.todos.set(`r-${title}`, { id: `r-${title}`, title, notes, completed, tags: [] });
  add('手机上的任务', topThreeNotes('Work', today), true);
  add('普通 todo', 'no marker');
  add('昨天的', topThreeNotes('Chores', '2024-03-11'));
  for (const n of [1, 2, 3]) add(`工作${n}`, topThreeNotes('MyOwn', today));
  const result = await sync.run();
  const store = local.read();
  assert.deepEqual(store.history[today].taskGroups[0].map(task => [task.title, task.isCompleted, task.syncPending]), [['手机上的任务', true, false]]);
  assert.equal(store.history['2024-03-11'].taskGroups[2][0].title, '昨天的');
  assert.equal(store.history[today].taskGroups[1].length, 3);
  assert.ok(!allTasks(store).some(task => task.title === '普通 todo'));
  assert.match(result.message, /新导入 5 个任务/);
  add('工作4', topThreeNotes('MyOwn', today));
  await sync.run();
  assert.equal(local.read().history[today].taskGroups[1].length, 3, 'never more than three in a fixed category');
  const mobile = local.read().history[today].taskGroups[0][0];
  local.edit(store => { store.history[today].taskGroups[0][0].title = '本机改名'; store.history[today].taskGroups[0][0].syncPending = true; });
  server.todos.get(mobile.habiticaTaskId).title = '云端改名';
  local.edit(store => { store.categoryTagIds.Work = 'tag-work'; });
  server.tags.set('tag-work', 'Work');
  await sync.run();
  assert.equal(local.read().history[today].taskGroups[0][0].title, '本机改名');
  assert.equal(server.todos.get(mobile.habiticaTaskId).title, '本机改名', 'the local edit is pushed and wins');
});

test('owners are isolated: another account never receives or reuses this account’s tasks', async () => {
  const serverA = fakeHabitica();
  const serverB = fakeHabitica();
  const local = harness();
  local.edit(store => addTask(store, today, 0, 'A 的任务', null));
  await createSync({ ...local, api: serverA.api, owner: 'A' }).run();
  local.edit(store => addTask(store, today, 0, '断开后新建', local.read().cloudAccount));
  const syncB = createSync({ ...local, api: serverB.api, owner: 'B' });
  await syncB.run();
  assert.equal(serverB.todos.size, 0, 'B does not upload A-owned tasks');
  assert.equal(local.read().cloudAccount, 'B');
  assert.deepEqual(local.read().categoryTagIds, {}, 'B starts with its own tag mappings');
  await createSync({ ...local, api: serverA.api, owner: 'A' }).run();
  assert.equal(serverA.todos.size, 2, 'switching back to A uploads the pending task once');
  assert.equal(serverA.calls.filter(call => call.startsWith('POST tag')).length, 1, 'A keeps its tag mapping');
});

test('an offline category rename is retried against the same tag id', async () => {
  const server = fakeHabitica();
  const local = harness();
  local.edit(store => addTask(store, today, 0, '任务', 'A'));
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  await sync.run();
  const tag = local.read().categoryTagIds.Work;
  local.edit(store => renameCategory(store, 0, '工作'));
  assert.deepEqual(local.read().pendingTagRenames, { [tag]: '工作' });
  await sync.run();
  assert.equal(server.tags.get(tag), '工作');
  assert.equal(server.tags.size, 1, 'no second tag is created');
  assert.deepEqual(local.read().pendingTagRenames, {});
  const todo = [...server.todos.values()][0];
  assert.equal(todo.notes, topThreeNotes('工作', today));
  assert.throws(() => renameCategory(local.read(), 1, '工作'), /同名/);
  assert.throws(() => renameCategory(local.read(), 1, 'A · B'), /不能包含/);
});

test('moving an unfinished task keeps an archive copy and updates the todo date', async () => {
  const server = fakeHabitica();
  const local = harness();
  const task = local.edit(store => addTask(store, '2024-03-11', 0, '昨天没做完', 'A'));
  const sync = createSync({ ...local, api: server.api, owner: 'A' });
  await sync.run();
  assert.deepEqual(unfinishedTasks(local.read(), today).map(item => item.task.id), [task.id]);
  local.edit(store => moveTaskToToday(store, today, '2024-03-11', 0, task.id));
  const store = local.read();
  assert.equal(store.history['2024-03-11'].taskGroups[0][0].movedToToday, true);
  assert.equal(store.history[today].taskGroups[0][0].id, task.id);
  assert.equal(unfinishedTasks(store, today).length, 0);
  await sync.run();
  assert.equal([...server.todos.values()][0].notes, topThreeNotes('Work', today));
  for (const n of [1, 2]) local.edit(next => addTask(next, today, 0, `新${n}`, 'A'));
  assert.equal(canAddTask(local.read(), today, 0), false, 'the moved task occupies a slot, the archive does not');
});

test('API client: budget rejects without sending, 429 starts a cooldown, creates classify outcomes', async () => {
  let now = 0;
  const sent = [];
  const reply = (status, body = { success: true, data: { id: 'x' } }, headers = {}) => ({
    status, ok: status >= 200 && status < 300, headers: new Headers(headers), json: async () => body,
  });
  let next = () => reply(200);
  const api = createApi({ user: 'u', token: 't', budget: createBudget({ limit: 2 }), now: () => now,
    fetch: async (url, options) => { sent.push([options.method, String(url), options.redirect, options.credentials]); return next(); } });
  await api.scoreTask('abc', 'up');
  assert.deepEqual(sent[0], ['POST', 'https://habitica.com/api/v3/tasks/abc/score/up', 'error', 'omit']);
  await api.scoreTask('abc', 'up');
  await assert.rejects(api.scoreTask('abc', 'up'), error => !error.sent && /额度/.test(error.message));
  assert.equal(sent.length, 2);
  assert.deepEqual(await api.createTodo('t', 'n', []), { status: 'notCreated', message: 'Habitica 请求额度暂时用完，请 60 秒后重试。' });
  now += 61_000;
  next = () => reply(429, {}, { 'retry-after': '30' });
  assert.equal((await api.createTodo('t', 'n', [])).status, 'notCreated');
  assert.match(api.rateLimitMessage(), /429/);
  now += 32_000;
  next = () => reply(500, {});
  assert.equal((await api.createTodo('t', 'n', [])).status, 'uncertain');
  now += 61_000;
  next = () => { throw new TypeError('Failed to fetch'); };
  assert.equal((await api.createTodo('t', 'n', [])).status, 'uncertain');
  next = () => reply(404, {});
  assert.equal(await api.deleteTodo('gone'), true);
  now += 61_000;
  next = () => reply(401, {});
  assert.equal((await api.createTodo('t', 'n', [])).status, 'notCreated');
  assert.throws(() => api.scoreTask('../user', 'up'), /无效/);
});
