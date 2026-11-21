// UF-02 (v2.1.0): moving unfinished tasks through the engine. The engine's
// logical today (04:00 boundary) decides the backlog; a full Work/MyOwn today
// keeps the task in the list and returns a hint; with room it moves to the
// ORIGINAL category, keeps the archive copy, persists, and syncs the existing
// Habitica todo to today's dated notes. The old yesterday-only entry point
// shares the same path.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.TopThreeDay
import com.habitica.pomodoro.data.topThreeNotes

fun main() {
    val dir = newTempDir("uf-02")
    seedSettings(dir)
    val today = logicalTodayKey()
    val yesterday = shiftedDay(today, -1)
    val older = shiftedDay(today, -8)
    val work = ownedTask(id = "WORK", title = "Backlogged work", remoteId = "RID-W")
    val chore = ownedTask(id = "CHORE", title = "Yesterday chore")
    val myOwn = ownedTask(id = "MINE", title = "Yesterday mine")
    seedTopThree(dir, ownedStore(history = mapOf(
        today to TopThreeDay(today, listOf((1..3).map { ownedTask(id = "TODAY-$it", title = "Today $it") }, emptyList(),
            (1..4).map { ownedTask(id = "TC-$it", title = "today chore $it") })),
        yesterday to TopThreeDay(yesterday, listOf(emptyList(), listOf(myOwn), listOf(chore))),
        older to TopThreeDay(older, listOf(listOf(work), emptyList(), emptyList())),
    )).copy(categoryTagIds = mapOf("Work" to "TAG-W")))
    val vm = newVm(dir) {
        HabiticaAPI.tags["Work"] = "TAG-W"
        HabiticaAPI.cloud += cloudTodo("RID-W", "Backlogged work", date = older, tags = listOf("TAG-W"))
    }
    expectEq(vm.todayKey(), today, "engine uses the logical day")
    expectEq(vm.unfinishedTasks().map { it.task.id }, listOf("MINE", "CHORE", "WORK"), "backlog from yesterday and earlier")

    expect(!vm.canMoveToToday(0), "today's Work is full")
    val hint = vm.moveUnfinishedToToday(older, 0, "WORK")
    expect(hint?.contains("已满") == true, "full category explains why: $hint")
    expect(vm.unfinishedTasks().any { it.task.id == "WORK" }, "task stays in the unfinished list")
    expectEq(dispatched("updateTodo:"), 0, "nothing synced for a refused move")

    vm.deleteTask(0, 0) // free a Work slot today
    expectEq(vm.moveUnfinishedToToday(older, 0, "WORK"), null, "moved once there is room")
    val s = vm.state.value.store
    val moved = s.history.getValue(today).taskGroups[0].first { it.id == "WORK" }
    expect(moved.habiticaTaskId == "RID-W" && !moved.movedToToday && moved.cloudAccount == OWNER_KEY, "same identity: $moved")
    expect(s.history.getValue(older).taskGroups[0].single().let { it.id == "WORK" && it.movedToToday }, "archive copy stays visible")
    expectEq(dispatched("updateTodo:RID-W"), 1, "existing todo re-dated, not re-created")
    expectEq(HabiticaAPI.cloud.single { it.id == "RID-W" }.notes, topThreeNotes("Work", today), "remote notes now carry today")
    expect(!moved.syncPending, "move verified remotely: $moved")
    expectEq(dispatched("createTodo:"), 0, "no duplicate create")
    expect(vm.moveUnfinishedToToday(older, 0, "WORK") != null, "cannot move the same task twice")
    expect(readTopThreeDisk(dir).history.getValue(today).taskGroups[0].any { it.id == "WORK" }, "move persisted")

    // Chores are unlimited; MyOwn has room. The yesterday-only entry point uses the same path.
    expect(vm.canMoveToToday(2), "Chores unlimited")
    vm.moveTaskToToday(2, 0)
    expect(vm.state.value.store.history.getValue(today).taskGroups[2].any { it.id == "CHORE" }, "yesterday chore moved via the old entry point")
    expectEq(vm.moveUnfinishedToToday(yesterday, 1, "MINE"), null, "MyOwn moved into its original category")
    expect(vm.state.value.store.history.getValue(today).taskGroups[1].single().id == "MINE", "original category kept")
    expectEq(vm.unfinishedTasks(), emptyList(), "backlog empty")
    println("UF-02 OK")
}
