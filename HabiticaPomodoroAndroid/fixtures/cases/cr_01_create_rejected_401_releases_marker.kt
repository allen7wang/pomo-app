// CR-01 (v2.1.3): a create explicitly refused with HTTP 401 produced nothing
// remotely. The local task is kept pending, only this attempt's create marker
// is released (persisted), and after a restart a healthy manual sync creates
// it exactly once and verifies it.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaGate

fun main() {
    val dir = newTempDir("cr-01")
    seedSettings(dir)
    val today = logicalTodayKey()
    seedTopThree(dir, ownedStore())
    val vm = newVm(dir) {
        HabiticaAPI.replyFor = { name -> if (name.startsWith("createTodo:")) reply(401) else null }
    }
    vm.addTask(0, "t401")
    expectEq(dispatched("createTodo:t401"), 1, "the POST was sent once")
    val row = vm.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(row.syncPending && row.habiticaTaskId == null, "local task kept pending: $row")
    expectEq(row.pendingCreateTitle, null, "marker title released")
    expectEq(row.pendingCreateNotes, null, "marker notes released")
    expect(row.syncError?.contains("认证失败") == true, "row explains the refusal: ${row.syncError}")
    expectEq(vm.state.value.store.deletedCreateMarkers, emptySet(), "no removal marker involved")
    expectEq(vm.state.value.profile, null, "a current 401 revokes the shown role")
    expectEq(vm.state.value.profileError, HabiticaGate.AUTH_FAILED, "authentication failure surfaced")
    val disk = readTopThreeDisk(dir).history.getValue(today).taskGroups[0].single()
    expect(disk.pendingCreateTitle == null && disk.syncPending, "release persisted: $disk")

    // Restart with healthy credentials: the manual sync retries the create once.
    val restarted = newVm(dir) { HabiticaAPI.tags["Work"] = vm.state.value.store.categoryTagIds.getValue("Work") }
    expectEq(dispatched("createTodo:"), 0, "no automatic replay on restart")
    restarted.retryPendingTasks()
    expectEq(dispatched("createTodo:t401"), 1, "created exactly once")
    val created = restarted.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(created.habiticaTaskId != null && !created.syncPending && created.syncError == null, "created and verified: $created")
    expectEq(created.id, row.id, "same local UUID")
    expectEq(HabiticaAPI.cloud.count { it.title == "t401" }, 1, "one remote todo")
    println("CR-01 OK")
}
