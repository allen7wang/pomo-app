// Daily Top Three tasks: Apple TopThreeStore JSON shape and rules (logical days, per-owner cloud state).
import { newId } from './model.mjs';

export const defaultCategories = ['Work', 'MyOwn', 'Chores'];
export const fixedSlotCategories = 2;
export const fixedTaskLimit = 3;

export function emptyCloudState() {
  return { categoryTagIds: {}, deletedCloudIds: [], confirmedDeletedCloudIds: [], pendingTagRenames: {}, deletedCreateAttempts: [] };
}

export function freshTopThree() {
  return { categoryNames: [...defaultCategories], history: {}, cloudAccount: '', cloudStates: {}, ...emptyCloudState() };
}

export const isUnfinished = task => !task.isCompleted && !task.movedToToday && task.title.trim() !== '';
export const taskLimit = category => category < fixedSlotCategories ? fixedTaskLimit : null;
export const getTasks = (store, key, category) => store.history[key]?.taskGroups?.[category] ?? [];
export const activeTasks = (store, key, category) => getTasks(store, key, category).filter(task => !task.movedToToday);
export const allTasks = store => Object.values(store.history).flatMap(day => day.taskGroups.flat());

/** Archived moved copies do not occupy one of the three slots. */
export function canAddTask(store, key, category) {
  if (category < 0 || category >= store.categoryNames.length) return false;
  const limit = taskLimit(category);
  return limit === null || activeTasks(store, key, category).length < limit;
}

function ensureDay(store, key) {
  const day = store.history[key] ?? { date: key, taskGroups: [] };
  while (day.taskGroups.length < store.categoryNames.length) day.taskGroups.push([]);
  store.history[key] = day;
  return day;
}

/** The authoritative copy of a UUID: the latest day, never an archived moved copy. */
export function locate(store, id) {
  for (const key of Object.keys(store.history).sort().reverse()) {
    const groups = store.history[key].taskGroups;
    for (let category = 0; category < groups.length; category += 1) {
      const task = groups[category].find(item => item.id === id && !item.movedToToday);
      if (task) return { key, category, task };
    }
  }
  return null;
}

/** Resolve the UUID again at action time so a stale row cannot edit its replacement. */
function current(store, key, category, id) {
  const found = locate(store, id);
  return found && found.key === key && found.category === category ? found.task : null;
}

export function addTask(store, key, category, title, owner) {
  const trimmed = String(title ?? '').trim();
  if (!trimmed) throw new Error('请填写任务名称。');
  if (!canAddTask(store, key, category)) throw new Error(`「${store.categoryNames[category]}」今天已有 ${fixedTaskLimit} 件任务。`);
  const task = {
    id: newId(), title: trimmed, isCompleted: false, habiticaTaskId: null, movedToToday: false,
    syncPending: true, cloudAccount: owner || null,
  };
  ensureDay(store, key).taskGroups[category].push(task);
  return task;
}

export function setTaskTitle(store, today, key, category, id, title) {
  const trimmed = String(title ?? '').trim();
  const task = key === today ? current(store, key, category, id) : null;
  if (!task || !trimmed) return null;
  task.title = trimmed;
  task.syncPending = true;
  return task;
}

export function toggleTask(store, today, key, category, id) {
  const task = key === today ? current(store, key, category, id) : null;
  if (!task) return null;
  task.isCompleted = !task.isCompleted;
  task.syncPending = true;
  return task;
}

/** Today's task, or an unfinished one from an earlier day. A synced todo is queued for deletion. */
export function removeTask(store, today, key, category, id, fromUnfinished = false) {
  if (fromUnfinished ? !(key < today) : key !== today) return null;
  const task = current(store, key, category, id);
  if (!task || (fromUnfinished && !isUnfinished(task))) return null;
  const group = store.history[key].taskGroups[category];
  group.splice(group.indexOf(task), 1);
  if (task.cloudAccount) {
    if (task.habiticaTaskId) queueDeletion(store, task.habiticaTaskId, task.cloudAccount);
    else if (task.cloudCreateAttempt) queueDeletedAttempt(store, task.id, task.cloudCreateAttempt, task.cloudAccount);
  }
  return task;
}

/** The source day keeps an archived copy with the same UUID and remote id. */
export function moveTaskToToday(store, today, fromKey, category, id) {
  if (!(fromKey < today) || !canAddTask(store, today, category)) return null;
  const task = current(store, fromKey, category, id);
  if (!task || !isUnfinished(task)) return null;
  const moved = { ...task, syncPending: true };
  const destination = ensureDay(store, today).taskGroups[category];
  const archived = destination.findIndex(item => item.id === id && item.movedToToday);
  if (archived >= 0) destination[archived] = moved;
  else destination.push(moved);
  task.movedToToday = true;
  return moved;
}

/** Yesterday and earlier, newest first, each UUID once from its latest active copy. */
export function unfinishedTasks(store, today) {
  const seen = new Set();
  const result = [];
  for (const key of Object.keys(store.history).sort().reverse()) {
    store.history[key].taskGroups.forEach((group, category) => {
      for (const task of group) {
        if (task.movedToToday || seen.has(task.id)) continue;
        seen.add(task.id);
        if (key < today && category < store.categoryNames.length && isUnfinished(task)) result.push({ key, category, task });
      }
    });
  }
  return result;
}

/** Rename locally; synced todos and the category tag follow on the next sync (an offline rename is retried). */
export function renameCategory(store, index, name) {
  const trimmed = String(name ?? '').trim();
  if (!trimmed) throw new Error('请填写分类名称。');
  if (trimmed.includes(' · ')) throw new Error('分类名称不能包含「 · 」。');
  if (store.categoryNames.some((item, other) => other !== index && item === trimmed)) throw new Error('已有同名分类。');
  const old = store.categoryNames[index];
  if (old === undefined || old === trimmed) return false;
  store.categoryNames[index] = trimmed;
  // Only todos that already exist remotely need their notes/tag rewritten; never upload old local history.
  for (const day of Object.values(store.history)) {
    for (const task of day.taskGroups[index] ?? []) if (task.habiticaTaskId) task.syncPending = true;
  }
  rememberCloudState(store);
  for (const state of Object.values(store.cloudStates)) {
    const tagId = state.categoryTagIds[old];
    if (tagId === undefined) continue;
    delete state.categoryTagIds[old];
    state.categoryTagIds[trimmed] = tagId;
    state.pendingTagRenames[tagId] = trimmed;
  }
  const active = store.cloudStates[store.cloudAccount];
  if (active) {
    store.categoryTagIds = { ...active.categoryTagIds };
    store.pendingTagRenames = { ...active.pendingTagRenames };
  }
  return true;
}

// MARK: Per-owner cloud state (owner = hashed Habitica UID + API root; never a credential)
const cloudKeys = Object.keys(emptyCloudState());

export function rememberCloudState(store) {
  if (!store.cloudAccount) return;
  store.cloudStates[store.cloudAccount] = structuredClone(Object.fromEntries(cloudKeys.map(key => [key, store[key]])));
}

export function cloudState(store, owner) {
  if (owner === store.cloudAccount) return Object.fromEntries(cloudKeys.map(key => [key, store[key]]));
  return store.cloudStates[owner] ?? emptyCloudState();
}

function editCloudState(store, owner, edit) {
  if (owner === store.cloudAccount) return edit(store);
  const state = store.cloudStates[owner] ?? emptyCloudState();
  edit(state);
  store.cloudStates[owner] = state;
}

export function queueDeletion(store, remoteId, owner) {
  editCloudState(store, owner, state => {
    if (!state.deletedCloudIds.includes(remoteId)) state.deletedCloudIds.push(remoteId);
  });
}

export function queueDeletedAttempt(store, id, attempt, owner) {
  editCloudState(store, owner, state => {
    if (!state.deletedCreateAttempts.some(item => item.id === id && sameAttempt(item.attempt, attempt))) {
      state.deletedCreateAttempts.push({ id, attempt: structuredClone(attempt) });
    }
  });
}

export function sameAttempt(left, right) {
  return Boolean(left && right) && left.title === right.title && left.notes === right.notes && sameSet(left.tags, right.tags);
}

export function sameSet(left = [], right = []) {
  const a = new Set(left);
  const b = new Set(right);
  return a.size === b.size && [...a].every(value => b.has(value));
}

export function updateCopies(store, id, owner, update) {
  for (const day of Object.values(store.history)) {
    for (const group of day.taskGroups) for (const task of group) if (task.id === id && task.cloudAccount === owner) update(task);
  }
}

/** Adopt unowned tasks once, then swap the active owner's mappings and queues. */
export function prepareCloudAccount(store, account) {
  if (!account) return false;
  let changed = false;
  const legacyOwner = store.cloudAccount || account;
  for (const task of allTasks(store)) {
    if (!task.cloudAccount) { task.cloudAccount = legacyOwner; changed = true; }
  }
  if (store.cloudAccount !== account) {
    if (store.cloudAccount) rememberCloudState(store);
    else store.cloudStates[account] = structuredClone(cloudState(store, ''));
    Object.assign(store, structuredClone(store.cloudStates[account] ?? emptyCloudState()));
    store.cloudAccount = account;
    changed = true;
  }
  return changed;
}

export function pendingCount(store, owner = store.cloudAccount) {
  const state = cloudState(store, owner);
  const tasks = allTasks(store).filter(task => task.syncPending && !task.movedToToday && (!owner || task.cloudAccount === owner || !task.cloudAccount));
  return new Set(tasks.map(task => task.id)).size + Object.keys(state.pendingTagRenames).length + state.deletedCreateAttempts.length
    + state.deletedCloudIds.filter(id => !state.confirmedDeletedCloudIds.includes(id)).length;
}
