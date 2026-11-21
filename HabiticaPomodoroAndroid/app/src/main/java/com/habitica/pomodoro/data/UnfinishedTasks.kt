package com.habitica.pomodoro.data

/** Work/MyOwn (the first two categories) hold at most 3 tasks a day; later categories are free lists. */
const val TOP_THREE_FIXED_SLOT_CATEGORIES = 2
const val TOP_THREE_MAX_FIXED_TASKS = 3

/** An open task from an earlier logical day (Apple UnfinishedTask). */
data class UnfinishedTask(val dateKey: String, val category: Int, val task: TopThreeTask)

val TopThreeTask.isUnfinished: Boolean get() = !isCompleted && !movedToToday && title.isNotBlank()

fun topThreeTaskLimit(category: Int): Int? = if (category < TOP_THREE_FIXED_SLOT_CATEGORIES) TOP_THREE_MAX_FIXED_TASKS else null

/** Archive copies (movedToToday) do not occupy a slot. */
fun TopThreeStore.hasRoom(dateKey: String, category: Int): Boolean {
    val limit = topThreeTaskLimit(category) ?: return true
    return history[dateKey]?.taskGroups?.getOrNull(category).orEmpty().count { !it.movedToToday } < limit
}

/** The authoritative (latest, non-archived) copy of a local UUID: date, category, task. */
fun TopThreeStore.latestActiveCopy(id: String): Triple<String, Int, TopThreeTask>? =
    history.entries.sortedByDescending { it.key }.firstNotNullOfOrNull { (date, day) ->
        day.taskGroups.withIndex().firstNotNullOfOrNull { (index, group) ->
            group.firstOrNull { it.id == id && !it.movedToToday }?.let { Triple(date, index, it) }
        }
    }

/**
 * Yesterday and earlier, newest day first. Each UUID is listed once, from its latest active copy, so a task
 * already moved forward (or still present on a later day) is not offered again from an old archive.
 */
fun TopThreeStore.unfinishedTasks(today: String): List<UnfinishedTask> {
    val seen = HashSet<String>()
    val result = mutableListOf<UnfinishedTask>()
    for (key in history.keys.sortedDescending()) {
        history.getValue(key).taskGroups.forEachIndexed { category, group ->
            for (task in group) {
                if (task.movedToToday || !seen.add(task.id)) continue
                if (key < today && category < categoryNames.size && task.isUnfinished) result += UnfinishedTask(key, category, task)
            }
        }
    }
    return result
}

/**
 * Move one unfinished task into today's original category, or null when it is not allowed (stale row,
 * not unfinished, not from an earlier day, or that category is full today). The source row stays as a
 * movedToToday archive copy with the same UUID and cloud identity, like Apple.
 */
fun TopThreeStore.movingUnfinishedToToday(fromKey: String, category: Int, id: String, today: String): TopThreeStore? {
    if (fromKey >= today || category !in categoryNames.indices || !hasRoom(today, category)) return null
    val (date, index, task) = latestActiveCopy(id) ?: return null
    if (date != fromKey || index != category || !task.isUnfinished) return null
    val moved = task.copy(movedToToday = false, syncPending = true, syncError = null, syncVersion = task.syncVersion + 1)
    val source = history.getValue(fromKey)
    val sourceGroups = source.taskGroups.mapIndexed { i, group ->
        if (i == category) group.map { if (it.id == id && !it.movedToToday) it.copy(movedToToday = true) else it } else group
    }
    val target = history[today] ?: TopThreeDay(today)
    val groups = List(maxOf(categoryNames.size, target.taskGroups.size)) { i ->
        val group = target.taskGroups.getOrElse(i) { emptyList() }
        if (i != category) group else {
            val archived = group.indexOfFirst { it.id == id && it.movedToToday }
            if (archived >= 0) group.mapIndexed { j, t -> if (j == archived) moved else t } else group + moved
        }
    }
    return copy(history = history + (fromKey to source.copy(taskGroups = sourceGroups)) + (today to target.copy(taskGroups = groups)))
}
