// UF-01 (v2.1.0, pure): the cross-day unfinished list (Apple unfinished_tasks
// vectors). Yesterday and earlier only, newest first, each UUID once from its
// latest active copy; completed, blank, archived (movedToToday) and future rows
// are excluded. Moving needs room today (Work/MyOwn 3, Chores unlimited) and
// keeps a movedToToday archive copy with the same UUID/remote ID/owner.
import com.habitica.pomodoro.data.TopThreeDay
import com.habitica.pomodoro.data.hasRoom
import com.habitica.pomodoro.data.movingUnfinishedToToday
import com.habitica.pomodoro.data.unfinishedTasks

fun main() {
    val today = "2026-11-21"
    val yesterday = "2026-11-20"
    val older = "2026-11-13"
    val oldest = "2026-11-12"
    val tomorrow = "2026-11-22"
    val work = ownedTask(id = "WORK", title = "Backlogged work", remoteId = "work-remote")
    val chore = ownedTask(id = "CHORE", title = "Yesterday chore", owner = null)
    val deleted = ownedTask(id = "DELETED", title = "Older chore", remoteId = "delete-remote")
    val complete = ownedTask(id = "COMPLETE", title = "Completed", completed = true, owner = null)
    val blank = ownedTask(id = "BLANK", title = "  ", owner = null)
    val previouslyMoved = work.copy(movedToToday = true)
    val todayWork = (1..3).map { ownedTask(id = "TODAY-$it", title = "Today $it") }
    val store = ownedStore(history = mapOf(
        today to TopThreeDay(today, listOf(todayWork, emptyList(), emptyList())),
        yesterday to TopThreeDay(yesterday, listOf(listOf(complete), emptyList(), listOf(chore))),
        older to TopThreeDay(older, listOf(listOf(work), emptyList(), listOf(deleted, blank))),
        oldest to TopThreeDay(oldest, listOf(listOf(previouslyMoved))),
        tomorrow to TopThreeDay(tomorrow, listOf(listOf(ownedTask(id = "FUTURE", title = "Future")))),
    ))

    expectEq(store.unfinishedTasks(today).map { it.task.id }, listOf("CHORE", "WORK", "DELETED"),
        "logical-day backlog, newest first, archive copies excluded")
    expectEq(store.unfinishedTasks(yesterday).map { it.task.id }, listOf("WORK", "DELETED"), "strictly before the given day")
    val first = store.unfinishedTasks(today).first()
    expect(first.dateKey == yesterday && first.category == 2, "carries its day and original category: $first")

    expect(!store.hasRoom(today, 0), "today's Work is full")
    expectEq(store.movingUnfinishedToToday(older, 0, "WORK", today), null, "full category: not moved")
    val freed = store.copy(history = store.history + (today to TopThreeDay(today, listOf(todayWork.drop(1), emptyList(), emptyList()))))
    val moved = freed.movingUnfinishedToToday(older, 0, "WORK", today) ?: throw AssertionError("move with room")
    expectEq(moved.movingUnfinishedToToday(older, 0, "WORK", today), null, "a moved task cannot be moved twice")
    val copy = moved.history.getValue(today).taskGroups[0].last()
    expect(copy.id == "WORK" && copy.habiticaTaskId == "work-remote" && copy.cloudAccount == OWNER_KEY, "stable identity: $copy")
    expect(copy.syncPending && !copy.movedToToday && !copy.isCompleted, "moved copy is active and pending: $copy")
    expect(moved.history.getValue(older).taskGroups[0].single().movedToToday, "source kept as archive")
    expectEq(moved.unfinishedTasks(today).map { it.task.id }, listOf("CHORE", "DELETED"), "moved task leaves the backlog")
    expectEq(moved.unfinishedTasks(tomorrow).count { it.task.id == "WORK" }, 1, "next logical day lists it once (today's copy)")

    // Chores are a free list: never full.
    val manyChores = freed.copy(history = freed.history + (today to TopThreeDay(today,
        listOf(todayWork.drop(1), emptyList(), (1..9).map { ownedTask(id = "C-$it", title = "chore $it") }))))
    expect(manyChores.hasRoom(today, 2), "Chores unlimited")
    expect(manyChores.movingUnfinishedToToday(yesterday, 2, "CHORE", today) != null, "chore moved despite 9 chores today")
    // Not unfinished / not from an earlier day / stale category.
    expectEq(freed.movingUnfinishedToToday(yesterday, 0, "COMPLETE", today), null, "completed task not moved")
    expectEq(freed.movingUnfinishedToToday(today, 0, "TODAY-2", today), null, "today's task is not 'unfinished'")
    expectEq(freed.movingUnfinishedToToday(older, 2, "WORK", today), null, "wrong category rejected")
    println("UF-01 OK")
}
