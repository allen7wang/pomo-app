// RL-03 (v2.1.2): an HTTP 429 stops the rest of a manual sync batch, keeps
// every deletion intent and pending local edit, sends nothing during the
// cooldown (Top3, role, lists, scores, creates), never replays the refused
// score/create automatically, and a manual retry after the cooldown continues.
import com.habitica.pomodoro.data.HabiticaAPI

fun main() {
    val dir = newTempDir("rl-03")
    seedSettings(dir)
    seedTopThree(dir, ownedStore().copy(deletedCloudIds = setOf("RID-a", "RID-b", "RID-c")))
    lateinit var clock: ManualClock
    val vm = newVm(dir) {
        clock = installManualClock()
        listOf("RID-a", "RID-b", "RID-c").forEach { HabiticaAPI.cloud += cloudTodo(it, "old $it") }
    }
    val profile = vm.state.value.profile
    expect(profile != null, "precondition: role loaded")
    val initial = HabiticaAPI.calls.size

    HabiticaAPI.replyFor = { name -> if (name.startsWith("deleteTodo:")) reply(429, "Retry-After" to "60") else null }
    vm.retryPendingTasks()
    expectEq(HabiticaAPI.calls.drop(initial), listOf("deleteTodo:RID-a"), "the 429 stops the remaining batch")
    val s = vm.state.value.store
    expectEq(s.deletedCloudIds, setOf("RID-a", "RID-b", "RID-c"), "no deletion intent dropped")
    expectEq(s.confirmedDeletedCloudIds, emptySet(), "nothing confirmed")
    val error = vm.state.value.topThreeSyncError.orEmpty()
    expect(error.contains("Habitica 暂时限流（HTTP 429）") && error.contains("秒后重试"), "cooldown wording: $error")

    // Cooldown: every feature is refused locally; nothing is queued for later.
    HabiticaAPI.replyFor = { null }
    vm.retryPendingTasks()
    vm.refreshTopThreeFromCloud()
    vm.refreshProfile()
    vm.refreshHabiticaTasks("habits")
    vm.scoreHabiticaTask("habits", habitItem("H-1"), "up")
    vm.addTask(0, "made during cooldown")
    expectEq(HabiticaAPI.calls.size, initial + 1, "no request dispatched during the cooldown")
    expectEq(vm.state.value.profile, profile, "a 429 does not revoke the role (not an authentication failure)")
    expect(vm.state.value.tasksError?.contains("HTTP 429") == true, "score shows the cooldown: ${vm.state.value.tasksError}")
    val pending = vm.state.value.store.history.getValue(logicalTodayKey()).taskGroups[0].single()
    expect(pending.syncPending && pending.habiticaTaskId == null, "new task kept locally as pending")
    expectEq(pending.pendingCreateTitle, null, "no create marker stranded by a refused-before-dispatch create")
    expect(pending.syncError?.contains("HTTP 429") == true, "row explains the wait: ${pending.syncError}")

    // Cooldown over, still no automatic replay until the user acts.
    clock.advance(61.0)
    expectEq(HabiticaAPI.calls.size, initial + 1, "nothing replays on its own")
    vm.retryPendingTasks()
    val after = vm.state.value.store
    expectEq(after.deletedCloudIds, emptySet(), "manual retry after cooldown drains the deletion queue")
    expectEq(after.confirmedDeletedCloudIds, setOf("RID-a", "RID-b", "RID-c"), "confirmed tombstones retained")
    expectEq(dispatched("createTodo:made during cooldown"), 1, "the pending create is sent once by the manual retry")
    expectEq(dispatched("scoreTask:H-1"), 0, "the refused score is never replayed")
    val created = after.history.getValue(logicalTodayKey()).taskGroups[0].single()
    expect(created.habiticaTaskId != null && !created.syncPending, "create verified: $created")
    expectEq(readTopThreeDisk(dir).confirmedDeletedCloudIds, setOf("RID-a", "RID-b", "RID-c"), "progress persisted")
    println("RL-03 OK")
}
