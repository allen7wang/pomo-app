// Habitica todo sync for daily tasks, ported from Apple TopThreeManager. Only todos carrying the
// app's dated notes are imported; a lost POST response is reconciled before any new POST.
import {
  allTasks, cloudState, getTasks, locate, prepareCloudAccount, queueDeletion, sameAttempt, sameSet, taskLimit,
  updateCopies,
} from './tasks.mjs';
import { newId, parseDayKey } from './model.mjs';

const notesPrefix = 'From HabiticaPomodoro Top3 · ';

export const topThreeNotes = (category, date) => `${notesPrefix}${category} · ${date}`;

export function parseOwnedNotes(notes) {
  if (typeof notes !== 'string' || !notes.startsWith(notesPrefix)) return null;
  const parts = notes.slice(notesPrefix.length).split(' · ');
  if (parts.length !== 2 || !parts[0] || parts[0] !== parts[0].trim() || !parseDayKey(parts[1])) return null;
  return { category: parts[0], date: parts[1] };
}

const ownedTasks = (store, owner) => allTasks(store).filter(task => task.cloudAccount === owner);
const signature = task => JSON.stringify([
  task.id, task.title, task.isCompleted, task.habiticaTaskId ?? null, task.movedToToday, task.syncPending, task.cloudAccount ?? null,
  task.cloudCreateAttempt ? [task.cloudCreateAttempt.title, task.cloudCreateAttempt.notes, [...task.cloudCreateAttempt.tags].sort()] : null,
]);

function attemptCandidateIds(store, attempt, owner) {
  const live = ownedTasks(store, owner).filter(task => !task.habiticaTaskId && sameAttempt(task.cloudCreateAttempt, attempt)).map(task => task.id);
  const removed = cloudState(store, owner).deletedCreateAttempts.filter(item => sameAttempt(item.attempt, attempt)).map(item => item.id);
  return new Set([...live, ...removed]);
}

function remoteIsAvailable(store, remote, id, owner) {
  return Boolean(remote) && !cloudState(store, owner).deletedCloudIds.includes(remote)
    && !ownedTasks(store, owner).some(task => task.id !== id && task.habiticaTaskId === remote);
}

const matches = (todo, attempt) => todo.title === attempt.title && todo.notes === attempt.notes && sameSet(todo.tags, attempt.tags);

function hasReservedDeletionMarker(store, attempt, id, owner) {
  return cloudState(store, owner).deletedCreateAttempts.some(item =>
    item.id !== id && item.attempt.notes === attempt.notes && sameSet(item.attempt.tags, attempt.tags));
}

/** Do not guess between identical ambiguous POSTs or steal an id already mapped to another UUID. */
function matchingAttempt(store, attempt, id, owner, todos) {
  if (hasReservedDeletionMarker(store, attempt, id, owner)) return [];
  return todos.filter(todo => remoteIsAvailable(store, todo.id, id, owner) && matches(todo, attempt));
}

function canBind(store, remote, attempt, id, owner) {
  const candidates = attemptCandidateIds(store, attempt, owner);
  return candidates.size === 1 && candidates.has(id) && !hasReservedDeletionMarker(store, attempt, id, owner)
    && remoteIsAvailable(store, remote, id, owner);
}

/** A unique unresolved removal becomes a queued deletion before any import or POST. */
export function resolveDeletedAttempts(store, todos, owner) {
  const resolved = [];
  for (const intent of cloudState(store, owner).deletedCreateAttempts) {
    const candidates = matchingAttempt(store, intent.attempt, intent.id, owner, todos);
    if (candidates.length !== 1 || !canBind(store, candidates[0].id, intent.attempt, intent.id, owner)) continue;
    queueDeletion(store, candidates[0].id, owner);
    resolved.push(intent);
  }
  store.deletedCreateAttempts = store.deletedCreateAttempts.filter(item => !resolved.includes(item));
  return resolved.length;
}

/** Imports dated todos; never infers a deletion from an incomplete list. Pending local edits win. */
export function mergeOwnedTodos(store, todos, owner) {
  resolveDeletedAttempts(store, todos, owner);
  let imported = 0;
  let conflict = false;
  for (const todo of todos) {
    const marker = parseOwnedNotes(todo.notes);
    if (!todo.id || !todo.title.trim() || cloudState(store, owner).deletedCloudIds.includes(todo.id) || !marker) continue;
    let tasks = ownedTasks(store, owner);
    if (!tasks.some(task => task.habiticaTaskId === todo.id)) {
      // Notes/tags of an unresolved removed POST quarantine an unknown id; they never establish identity.
      if (cloudState(store, owner).deletedCreateAttempts.some(item => item.attempt.notes === todo.notes && sameSet(item.attempt.tags, todo.tags))) {
        conflict = true;
        continue;
      }
      // Recover a response-lost POST without importing a second UUID.
      const candidates = [...new Set(tasks.filter(task => {
        if (task.habiticaTaskId || !task.cloudCreateAttempt) return false;
        const found = matchingAttempt(store, task.cloudCreateAttempt, task.id, owner, todos);
        return found.length === 1 && found[0].id === todo.id;
      }).map(task => task.id))];
      const attempt = tasks.find(task => task.id === candidates[0])?.cloudCreateAttempt;
      if (candidates.length === 1 && attempt && canBind(store, todo.id, attempt, candidates[0], owner)) {
        updateCopies(store, candidates[0], owner, task => { task.habiticaTaskId = todo.id; delete task.cloudCreateAttempt; });
      } else if (tasks.some(task => !task.habiticaTaskId && task.cloudCreateAttempt && matches(todo, task.cloudCreateAttempt))) continue;
      tasks = ownedTasks(store, owner);
    }
    const tagged = store.categoryNames.map((name, index) => [index, store.categoryTagIds[name]])
      .filter(([, tag]) => tag && todo.tags.includes(tag)).map(([index]) => index);
    const named = store.categoryNames.indexOf(marker.category);
    const category = named >= 0 ? named : tagged.length === 1 ? tagged[0] : -1;
    if (category < 0) continue;
    const known = tasks.find(task => task.habiticaTaskId === todo.id && !task.movedToToday);
    if (known?.syncPending) continue;
    // A deleted active row may still have archived copies: never resurrect it.
    if (!known && tasks.some(task => task.habiticaTaskId === todo.id)) continue;
    const source = known ? locate(store, known.id) : null;
    const limit = taskLimit(category);
    if ((source?.key !== marker.date || source?.category !== category) && limit !== null
      && getTasks(store, marker.date, category).filter(task => task.id !== known?.id && !task.movedToToday).length >= limit) continue;
    const merged = known
      ? { ...known, title: todo.title, isCompleted: todo.completed, movedToToday: false }
      : { id: newId(), title: todo.title, isCompleted: todo.completed, habiticaTaskId: todo.id, movedToToday: false, syncPending: false, cloudAccount: owner };
    if (source && (source.key !== marker.date || source.category !== category)) {
      const group = store.history[source.key].taskGroups[source.category];
      const index = group.findIndex(task => task.id === merged.id && !task.movedToToday);
      if (source.key !== marker.date) group[index].movedToToday = true; // the old day keeps its archive
      else group.splice(index, 1);
    }
    const day = store.history[marker.date] ?? { date: marker.date, taskGroups: [] };
    while (day.taskGroups.length < store.categoryNames.length) day.taskGroups.push([]);
    store.history[marker.date] = day;
    const group = day.taskGroups[category];
    const existing = group.findIndex(task => task.id === merged.id);
    if (existing >= 0) group[existing] = merged;
    else group.push(merged);
    if (!known) imported += 1;
  }
  return { imported, conflict };
}

const pendingIds = (store, owner) => [...new Set(ownedTasks(store, owner).filter(task => task.syncPending && !task.movedToToday).map(task => task.id))];
// Authentication, rate limits and a lost connection affect every request: stop the pass.
const fatal = failure => !failure.sent || failure.status === 401 || failure.status === 429 || failure.status === 0;

/**
 * One sync pass for the connected owner: resolve removed lost POSTs, retry tag renames, push pending
 * tasks, send queued deletes, then import. `read()` returns the latest stored task state and
 * `write(edit)` applies `edit(store)` atomically, resolving false when storage refused the change.
 */
export function createSync({ read, write, api, owner, isActive = () => true }) {
  let running = null;
  let problems = [];
  const active = () => isActive() && read().cloudAccount === owner;
  const historySignature = () => JSON.stringify(read().history);
  const report = message => { if (message) problems.push(message); };

  async function ensureTagId(category) {
    const name = read().categoryNames[category];
    const cached = cloudState(read(), owner).categoryTagIds[name];
    if (cached) {
      if (cloudState(read(), owner).pendingTagRenames[cached] !== undefined) {
        await retryTagRenames();
        if (!active() || read().categoryNames[category] !== name || cloudState(read(), owner).pendingTagRenames[cached] !== undefined) return null;
      }
      return cached;
    }
    const tags = await api.fetchTags();
    if (!active() || read().categoryNames[category] !== name) return null;
    const tagId = Object.entries(tags).find(([, tagName]) => tagName === name)?.[0] ?? await api.createTag(name);
    if (!tagId || !active() || read().categoryNames[category] !== name) return null;
    return await write(store => { store.categoryTagIds[name] = tagId; }) ? tagId : null;
  }

  async function retryTagRenames() {
    for (const [id, desired] of Object.entries(cloudState(read(), owner).pendingTagRenames)) {
      if (!active() || cloudState(read(), owner).pendingTagRenames[id] !== desired) return;
      const tags = await api.fetchTags();
      if (!active()) return;
      if (tags[id] !== desired) {
        await api.renameTag(id, desired);
        const verified = await api.fetchTags();
        if (!active()) return;
        if (verified[id] !== desired) { report('分类标签改名尚未确认，稍后会再试。'); continue; }
      }
      await write(store => { if (store.pendingTagRenames[id] === desired) delete store.pendingTagRenames[id]; });
    }
  }

  async function pushTask(id) {
    for (let round = 0; round < 4; round += 1) {
      const start = locate(read(), id);
      if (!active() || !start?.task.syncPending || start.task.cloudAccount !== owner) return;
      const task = structuredClone(start.task);
      const name = read().categoryNames[start.category];
      const tag = await ensureTagId(start.category);
      if (!tag || !active()) return;
      const after = locate(read(), id);
      if (!after || after.task.cloudAccount !== owner) return;
      if (signature(after.task) !== signature(task) || after.key !== start.key || after.category !== start.category
        || read().categoryNames[start.category] !== name) continue;
      const notes = topThreeNotes(name, start.key);
      let remote = task.habiticaTaskId;
      if (!remote) {
        let attempt;
        if (task.cloudCreateAttempt) {
          attempt = task.cloudCreateAttempt;
          const todos = await api.fetchTodos();
          if (!active()) return;
          const candidates = attemptCandidateIds(read(), attempt, owner);
          if (candidates.size !== 1 || !candidates.has(id)) return;
          const found = matchingAttempt(read(), attempt, id, owner, todos);
          // Absence is not proof that a response-lost POST failed: never blindly POST again.
          if (found.length !== 1) { report(`「${task.title}」上次的创建结果不明，云端没有唯一匹配；未重复创建。`); return; }
          remote = found[0].id;
        } else {
          attempt = { title: task.title, notes, tags: [tag] };
          const store = read();
          if (hasReservedDeletionMarker(store, attempt, id, owner)) return;
          if ([...attemptCandidateIds(store, attempt, owner)].some(other => other !== id)) return;
          // Persist the exact attempt before dispatch so a lost response is reconciled, not re-sent.
          if (!await write(store => updateCopies(store, id, owner, item => { item.cloudCreateAttempt = attempt; }))) return;
          const result = await api.createTodo(task.title, notes, [tag]);
          if (result.status === 'notCreated') {
            await write(store => updateCopies(store, id, owner, item => {
              if (!item.habiticaTaskId && sameAttempt(item.cloudCreateAttempt, attempt)) delete item.cloudCreateAttempt;
            }));
            report(result.message);
            return;
          }
          if (result.status !== 'created') { report(`「${task.title}」的创建结果未确认；下次同步会先核对云端，不会重复创建。`); return; }
          remote = result.id;
          if (!active()) return;
        }
        let bound = false;
        await write(store => {
          if (!canBind(store, remote, attempt, id, owner)) return;
          const latest = locate(store, id);
          if (!latest || latest.task.cloudAccount !== owner) {
            const index = store.deletedCreateAttempts.findIndex(item => item.id === id && sameAttempt(item.attempt, attempt));
            if (index >= 0) { queueDeletion(store, remote, owner); store.deletedCreateAttempts.splice(index, 1); }
            return;
          }
          if (latest.task.habiticaTaskId || !sameAttempt(latest.task.cloudCreateAttempt, attempt)) return;
          updateCopies(store, id, owner, item => { item.habiticaTaskId = remote; delete item.cloudCreateAttempt; });
          bound = true;
        });
        if (!bound) return;
      }
      const expected = { ...task, habiticaTaskId: remote };
      delete expected.cloudCreateAttempt;
      // Identity loss ends this task; any other local edit restarts from the current row.
      const identity = () => {
        const store = read();
        const latest = locate(store, id);
        return active() && remoteIsAvailable(store, remote, id, owner) && latest?.task.cloudAccount === owner && latest.task.habiticaTaskId === remote;
      };
      const unchanged = () => {
        const store = read();
        const latest = locate(store, id);
        return Boolean(latest) && signature(latest.task) === signature(expected) && latest.key === start.key
          && latest.category === start.category && store.categoryNames[start.category] === name && store.categoryTagIds[name] === tag;
      };
      if (!identity()) return;
      if (!unchanged()) continue;
      await api.updateTodo(remote, task.title, notes, [tag]);
      if (!identity()) return;
      if (!unchanged()) continue;
      let todo = await api.fetchTodo(remote);
      if (!identity()) return;
      if (!unchanged()) continue;
      if (todo.completed !== task.isCompleted) {
        await api.scoreTask(remote, task.isCompleted ? 'up' : 'down');
        if (!identity()) return;
        if (!unchanged()) continue;
        todo = await api.fetchTodo(remote);
        if (!identity()) return;
      }
      if (!unchanged()) continue;
      if (todo.title !== task.title || todo.completed !== task.isCompleted || todo.notes !== notes || !sameSet(todo.tags, [tag])) {
        report(`「${task.title}」的云端结果与本机不一致，修改保留待下次同步。`);
        return;
      }
      await write(store => updateCopies(store, id, owner, item => { item.syncPending = false; }));
      return;
    }
  }

  async function attempt(step) {
    try { await step(); return true; } catch (failure) {
      report(failure.message);
      if (fatal(failure)) throw failure;
      return false;
    }
  }

  async function pass() {
    if (!await write(store => { prepareCloudAccount(store, owner); }) || !active()) return null;
    if (cloudState(read(), owner).deletedCreateAttempts.length) {
      const before = historySignature();
      const todos = await api.fetchTodos();
      if (!active() || before !== historySignature()) return null;
      await write(store => { resolveDeletedAttempts(store, todos, owner); });
    }
    await attempt(retryTagRenames);
    for (const id of pendingIds(read(), owner)) {
      if (!active()) return null;
      await attempt(() => pushTask(id));
    }
    const state = cloudState(read(), owner);
    for (const remote of state.deletedCloudIds.filter(id => !state.confirmedDeletedCloudIds.includes(id))) {
      if (!active()) return null;
      // Keep the tombstone against stale reads; the acknowledgement retires the HTTP request.
      if (await attempt(() => api.deleteTodo(remote))) {
        await write(store => { if (store.deletedCloudIds.includes(remote) && !store.confirmedDeletedCloudIds.includes(remote)) store.confirmedDeletedCloudIds.push(remote); });
      }
    }
    if (!active()) return null;
    const before = historySignature();
    const todos = await api.fetchTodos();
    if (!active()) return null;
    if (before !== historySignature()) return { message: '同步期间本机任务有修改，未采用这次的云端列表，请再同步一次。' };
    let outcome = { imported: 0, conflict: false };
    await write(store => { outcome = mergeOwnedTodos(store, todos, owner); });
    if (outcome.conflict) return { message: '云端任务与未解决的删除记录冲突，已隔离，请在 Habitica 人工核对。', error: true };
    const store = read();
    const cloud = cloudState(store, owner);
    const pending = pendingIds(store, owner).length || Object.keys(cloud.pendingTagRenames).length || cloud.deletedCreateAttempts.length
      || cloud.deletedCloudIds.some(id => !cloud.confirmedDeletedCloudIds.includes(id));
    return { message: pending ? '已合并云端任务；本机仍有待上传的修改。' : `已同步 Habitica · 新导入 ${outcome.imported} 个任务。`, imported: outcome.imported };
  }

  return {
    /** Single flight: a request during a pass runs one more pass afterwards. */
    run() {
      if (running) { running.again = true; return running.promise; }
      const job = { again: false };
      job.promise = (async () => {
        let result = null;
        try {
          do {
            job.again = false;
            problems = [];
            try { result = await pass(); } catch (failure) { report(failure.message); result = { message: '同步已中止，本机任务已保留。', error: true }; }
            if (result && problems.length) result = { ...result, message: `${result.message} ${problems.at(-1)}`, error: true };
          } while (job.again && active() && !result?.error);
        } finally { running = null; }
        return result;
      })();
      running = job;
      return job.promise;
    },
  };
}
