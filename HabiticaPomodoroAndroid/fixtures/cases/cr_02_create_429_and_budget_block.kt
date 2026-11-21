// CR-02 (v2.1.3): (A) a create refused with HTTP 429 releases its marker and
// keeps the shared cooldown; after it, a manual sync creates once. (B) a
// create whose POST is blocked at dispatch by the server allowance (marker
// already written) is released too: never sent, never stranded.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaRequestBudgets

fun main() {
    val today = logicalTodayKey()

    // (A) HTTP 429 on the POST.
    val dirA = newTempDir("cr-02a")
    seedSettings(dirA)
    seedTopThree(dirA, ownedStore())
    lateinit var clockA: ManualClock
    val vmA = newVm(dirA) {
        clockA = installManualClock()
        HabiticaAPI.replyFor = { name -> if (name.startsWith("createTodo:")) reply(429, "Retry-After" to "0") else null }
    }
    vmA.addTask(0, "t429")
    var row = vmA.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(row.syncPending && row.habiticaTaskId == null && row.pendingCreateTitle == null, "429 releases the marker: $row")
    expect(HabiticaRequestBudgets.rateLimitMessage(OWNER_KEY)?.contains("HTTP 429") == true, "the shared cooldown is kept")
    expect(row.syncError?.contains("HTTP 429") == true, "row explains the cooldown: ${row.syncError}")
    expectEq(vmA.state.value.profile != null, true, "429 is not an authentication failure")
    clockA.advance(2.0)
    HabiticaAPI.replyFor = { null }
    vmA.retryPendingTasks()
    expectEq(dispatched("createTodo:t429"), 2, "one refused POST, then exactly one retry after the cooldown")
    row = vmA.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(row.habiticaTaskId != null && !row.syncPending, "created after cooldown: $row")
    expectEq(HabiticaAPI.cloud.count { it.title == "t429" }, 1, "single remote todo")

    // (B) Blocked at dispatch: the todo reads leave the server allowance at 0, so the POST never goes out.
    val dirB = newTempDir("cr-02b")
    seedSettings(dirB)
    seedTopThree(dirB, ownedStore().copy(categoryTagIds = mapOf("Work" to "TAG-W")))
    lateinit var clockB: ManualClock
    val vmB = newVm(dirB) {
        clockB = installManualClock()
        HabiticaAPI.tags["Work"] = "TAG-W"
    }
    HabiticaAPI.replyFor = { name -> if (name == "fetchCompletedTodos") reply(200, "X-RateLimit-Remaining" to "0") else null }
    vmB.addTask(0, "blocked")
    expectEq(dispatched("createTodo:"), 0, "POST blocked before dispatch")
    row = vmB.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(row.syncPending && row.habiticaTaskId == null, "kept locally: $row")
    expectEq(row.pendingCreateTitle, null, "the marker written just before the blocked POST is released")
    expect(row.syncError?.contains("请求额度暂时用完") == true, "row explains the wait: ${row.syncError}")
    expectEq(readTopThreeDisk(dirB).history.getValue(today).taskGroups[0].single().pendingCreateTitle, null, "release persisted")

    HabiticaAPI.replyFor = { null }
    clockB.advance(62.0)
    vmB.retryPendingTasks()
    expectEq(dispatched("createTodo:blocked"), 1, "created once after the server window")
    expect(vmB.state.value.store.history.getValue(today).taskGroups[0].single().habiticaTaskId != null, "bound")
    println("CR-02 OK")
}
