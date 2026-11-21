// RL-05 (v2.1.2): a deletion the server confirmed is never sent again, yet its
// tombstone stays (per owner, persisted) so a stale cloud response cannot
// re-import the task. A failed deletion stays pending and is the only one the
// next manual retry sends.
import com.habitica.pomodoro.data.HabiticaAPI

fun main() {
    val dir = newTempDir("rl-05")
    seedSettings(dir)
    val today = logicalTodayKey()
    seedTopThree(dir, ownedStore(history = mapOf(today to dayWith(today, 0, listOf(
        ownedTask(id = "LOCAL-X", title = "tx", remoteId = "RID-X"),
        ownedTask(id = "LOCAL-Y", title = "ty", remoteId = "RID-Y"))))))
    val vm = newVm(dir) {
        HabiticaAPI.cloud += cloudTodo("RID-X", "tx")
        HabiticaAPI.cloud += cloudTodo("RID-Y", "ty")
        HabiticaAPI.deleteOutcome = { id -> if (id == "RID-Y") HabiticaAPI.Result.Error("Habitica 请求失败 (HTTP 500)", 500) else HabiticaAPI.Result.Success(true) }
    }
    vm.deleteTask(0, 0) // RID-X: confirmed
    vm.deleteTask(0, 0) // RID-Y: server error, still visible remotely
    var s = vm.state.value.store
    expectEq(s.confirmedDeletedCloudIds, setOf("RID-X"), "confirmed deletion tombstoned")
    expectEq(s.deletedCloudIds, setOf("RID-Y"), "failed deletion stays pending")

    HabiticaAPI.deleteOutcome = { HabiticaAPI.Result.Success(true) }
    vm.retryPendingTasks()
    expectEq(HabiticaAPI.calls.filter { it.startsWith("deleteTodo:") }, listOf("deleteTodo:RID-X", "deleteTodo:RID-Y", "deleteTodo:RID-Y"),
        "the next retry sends only the previously failed deletion")
    s = vm.state.value.store
    expectEq(s.deletedCloudIds, emptySet(), "queue drained")
    expectEq(s.confirmedDeletedCloudIds, setOf("RID-X", "RID-Y"), "both tombstones kept")
    vm.retryPendingTasks()
    expectEq(dispatched("deleteTodo:"), 3, "later retries never re-delete acknowledged tombstones")

    // A stale read still lists both: neither is re-imported, now or after a restart.
    HabiticaAPI.cloud += cloudTodo("RID-X", "tx")
    HabiticaAPI.cloud += cloudTodo("RID-Y", "ty")
    vm.refreshTopThreeFromCloud()
    expect(vm.state.value.store.history[today]?.taskGroups?.flatten()?.isEmpty() != false, "stale response cannot resurrect")
    expectEq(readTopThreeDisk(dir).confirmedDeletedCloudIds, setOf("RID-X", "RID-Y"), "tombstones persisted")

    val restarted = newVm(dir) {
        HabiticaAPI.cloud += cloudTodo("RID-X", "tx")
        HabiticaAPI.cloud += cloudTodo("RID-Y", "ty")
    }
    restarted.retryPendingTasks()
    expectEq(dispatched("deleteTodo:"), 0, "a restart does not re-send acknowledged deletes")
    expect(restarted.state.value.store.history[today]?.taskGroups?.flatten()?.isEmpty() != false, "restart cannot resurrect either")

    // Tombstones are scoped to their owner partition.
    restarted.updateSettings { it.copy(uid = OTHER_UID) }
    expectEq(restarted.state.value.store.confirmedDeletedCloudIds, emptySet(), "other owner has its own tombstones")
    restarted.updateSettings { it.copy(uid = FIXTURE_UID) }
    expectEq(restarted.state.value.store.confirmedDeletedCloudIds, setOf("RID-X", "RID-Y"), "switching back restores them")
    println("RL-05 OK")
}
