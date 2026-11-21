// UF-03 (v2.1.0): deleting from the unfinished list honours cloud delete
// semantics (tombstone persisted before the DELETE, confirmed by read-back,
// kept against stale reads) and rejects stale targets: completed tasks,
// archive copies, today's rows. A failed DELETE keeps the intent queued.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.TopThreeDay

fun main() {
    val dir = newTempDir("uf-03")
    seedSettings(dir)
    val today = logicalTodayKey()
    val yesterday = shiftedDay(today, -1)
    val older = shiftedDay(today, -8)
    val moved = ownedTask(id = "MOVED", title = "Moved", remoteId = "RID-M")
    seedTopThree(dir, ownedStore(history = mapOf(
        today to TopThreeDay(today, listOf(listOf(moved), emptyList(), emptyList())),
        yesterday to TopThreeDay(yesterday, listOf(listOf(ownedTask(id = "DONE", title = "Done", completed = true)), emptyList(),
            listOf(ownedTask(id = "LOCAL-ONLY", title = "Never uploaded", syncPending = true)))),
        older to TopThreeDay(older, listOf(listOf(moved.copy(movedToToday = true)), emptyList(), listOf(
            ownedTask(id = "DEL", title = "Delete me", remoteId = "RID-D"),
            ownedTask(id = "FAIL", title = "Delete fails", remoteId = "RID-F")))),
    )))
    val vm = newVm(dir) {
        HabiticaAPI.cloud += cloudTodo("RID-D", "Delete me", category = "Chores", date = older)
        HabiticaAPI.cloud += cloudTodo("RID-F", "Delete fails", category = "Chores", date = older)
        HabiticaAPI.deleteOutcome = { id -> if (id == "RID-F") HabiticaAPI.Result.Error("Habitica 请求失败 (HTTP 500)", 500) else HabiticaAPI.Result.Success(true) }
    }
    expectEq(vm.unfinishedTasks().map { it.task.id }.toSet(), setOf("LOCAL-ONLY", "DEL", "FAIL"), "precondition backlog")

    // Stale or ineligible targets are refused and kept.
    expect(!vm.deleteUnfinishedTask(yesterday, 0, "DONE"), "completed task is not deletable from the backlog")
    expect(!vm.deleteUnfinishedTask(older, 0, "MOVED"), "archive copy is not deletable")
    expect(!vm.deleteUnfinishedTask(today, 0, "MOVED"), "today's row is not part of the backlog")
    expect(!vm.deleteUnfinishedTask(older, 0, "DEL"), "wrong category rejected")
    expectEq(dispatched("deleteTodo:"), 0, "no DELETE for refused targets")

    expect(vm.deleteUnfinishedTask(older, 2, "DEL"), "unfinished task deleted")
    var s = vm.state.value.store
    expect(s.history.getValue(older).taskGroups[2].none { it.id == "DEL" }, "removed locally")
    expectEq(dispatched("deleteTodo:RID-D"), 1, "remote todo deleted")
    expectEq(s.confirmedDeletedCloudIds, setOf("RID-D"), "confirmed tombstone kept")

    expect(vm.deleteUnfinishedTask(yesterday, 2, "LOCAL-ONLY"), "local-only task deleted")
    expectEq(dispatched("deleteTodo:"), 1, "nothing remote to delete for a never-uploaded task")

    expect(vm.deleteUnfinishedTask(older, 2, "FAIL"), "deleted locally even if the server fails")
    s = vm.state.value.store
    expectEq(s.deletedCloudIds, setOf("RID-F"), "failed DELETE stays queued")
    expect(vm.state.value.topThreeSyncError?.contains("远端删除尚未确认") == true, "failure surfaced: ${vm.state.value.topThreeSyncError}")

    // Stale responses cannot bring either back; the backlog stays empty after a restart.
    HabiticaAPI.cloud += cloudTodo("RID-D", "Delete me", category = "Chores", date = older)
    vm.refreshTopThreeFromCloud()
    expectEq(vm.unfinishedTasks(), emptyList(), "no resurrection from a stale read")
    val restarted = newVm(dir) {
        HabiticaAPI.cloud += cloudTodo("RID-D", "Delete me", category = "Chores", date = older)
        HabiticaAPI.cloud += cloudTodo("RID-F", "Delete fails", category = "Chores", date = older)
    }
    expectEq(restarted.unfinishedTasks(), emptyList(), "deletions persisted across restart")
    expect(restarted.state.value.store.history.getValue(today).taskGroups[0].single().id == "MOVED", "today's copy untouched")
    println("UF-03 OK")
}
