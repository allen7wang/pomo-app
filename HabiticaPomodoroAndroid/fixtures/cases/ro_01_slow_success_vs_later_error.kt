// RO-01 (v2.1.4): a slower success never clears an error reported after it was
// dispatched; an older failure never overwrites a newer error; a newly
// dispatched successful refresh still clears an old error. Checked on the
// Habits/Dailies channel and on the Task page (Top3 refresh vs a later failed
// delete, which no FIX3 guard would otherwise protect).
import com.habitica.pomodoro.data.HabiticaAPI

fun main() {
    val dir = newTempDir("ro-01")
    seedSettings(dir)
    val today = logicalTodayKey()
    seedTopThree(dir, ownedStore(history = mapOf(today to dayWith(today, 0, listOf(
        ownedTask(id = "LOCAL-Q", title = "tq", remoteId = "RID-Q"))))))
    lateinit var clock: ManualClock
    val vm = newVm(dir) {
        clock = installManualClock()
        HabiticaAPI.cloud += cloudTodo("RID-Q", "tq")
    }
    HabiticaAPI.taskListBodies["habits"] = taskListBody("kept" to "Valid habit")

    for ((label, failure) in listOf("HTTP 500" to reply(500), "offline" to HabiticaAPI.StubReply(lost = true))) {
        clock.advance(61.0)
        val slowList = HabiticaAPI.hold("fetchTaskItems:habits")
        vm.refreshHabiticaTasks("habits")
        HabiticaAPI.replyFor = { name -> if (name.startsWith("scoreTask:")) failure else null }
        vm.scoreHabiticaTask("habits", habitItem("newer-score"), "up")
        val newerError = vm.state.value.tasksError
        expect(newerError != null, "$label: score failure reported")
        slowList.complete(Unit)
        expectEq(vm.state.value.habits.single().id, "kept", "$label: the slow list success is still applied")
        expectEq(vm.state.value.tasksError, newerError, "$label: the slow success did not clear the newer error")
        HabiticaAPI.replyFor = { null }
    }

    // An older failure cannot replace the newer error.
    clock.advance(61.0)
    val olderFailure = HabiticaAPI.hold("fetchTaskItems:habits")
    HabiticaAPI.replyFor = { name ->
        when {
            name == "fetchTaskItems:habits" -> reply(503)
            name.startsWith("scoreTask:") -> reply(500)
            else -> null
        }
    }
    vm.refreshHabiticaTasks("habits")
    vm.scoreHabiticaTask("habits", habitItem("newest"), "up")
    expect(vm.state.value.tasksError?.contains("HTTP 500") == true, "newest error shown")
    olderFailure.complete(Unit)
    expect(vm.state.value.tasksError?.contains("HTTP 500") == true, "older 503 did not overwrite it: ${vm.state.value.tasksError}")
    expectEq(vm.state.value.habits.single().id, "kept", "failed load keeps the list")

    // A request dispatched after the error may clear it.
    HabiticaAPI.replyFor = { null }
    vm.refreshHabiticaTasks("habits")
    expectEq(vm.state.value.tasksError, null, "a newly dispatched successful refresh clears the older error")

    // Task page: a slow Top3 refresh success vs a delete failure reported later.
    clock.advance(61.0)
    val slowRefresh = HabiticaAPI.hold("fetchTopThreeTodos")
    vm.refreshTopThreeFromCloud()
    HabiticaAPI.deleteOutcome = { HabiticaAPI.Result.Error("Habitica 请求失败 (HTTP 500)", 500) }
    vm.deleteTask(0, 0)
    val deleteError = vm.state.value.topThreeSyncError
    expect(deleteError?.contains("远端删除尚未确认") == true, "delete failure reported: $deleteError")
    slowRefresh.complete(Unit)
    expectEq(vm.state.value.topThreeSyncing, false, "slow refresh finished")
    expectEq(vm.state.value.topThreeSyncError, deleteError, "the slower refresh success keeps the newer delete error")
    expectEq(vm.state.value.store.deletedCloudIds, setOf("RID-Q"), "delete intent retained")
    vm.refreshTopThreeFromCloud()
    expectEq(vm.state.value.topThreeSyncError, null, "a refresh dispatched afterwards may clear it")
    expect(vm.state.value.store.history.getValue(today).taskGroups[0].isEmpty(), "tombstone keeps the task deleted")
    println("RO-01 OK")
}
