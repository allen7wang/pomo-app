// EP-02 (v2.1.4): already-sent writes keep their real outcome, attributed to
// the account that sent them. (A) API boundary: a POST dispatched before a
// switch returns its real created id, sent once. (B) Engine: that create is
// never adopted into the new account nor re-POSTed; back on A the unique
// remote match is bound. (C) A retired request's 429 still lands in A's budget
// but cannot replace the current connection's feedback.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaRequestBudgets

fun main() {
    val today = logicalTodayKey()

    // (A)
    val dirA = newTempDir("ep-02a")
    seedSettings(dirA)
    seedTopThree(dirA, ownedStore())
    val vmA = newVm(dirA)
    val post = HabiticaAPI.hold("createTodo:Create once")
    val settingsA = vmA.state.value.settings
    val create = startCall { HabiticaAPI.createTodo(settingsA, "Create once", "Synthetic fixture", emptyList()) }
    vmA.updateSettings { it.copy(uid = OTHER_UID) }
    post.complete(Unit)
    val outcome = create.done("sent create")
    expect(outcome is HabiticaAPI.Result.Success && outcome.value?.startsWith("RID-") == true, "real created id returned: $outcome")
    expectEq(dispatched("createTodo:"), 1, "one POST, no replay")

    // (B)
    val dirB = newTempDir("ep-02b")
    seedSettings(dirB)
    seedTopThree(dirB, ownedStore())
    val vmB = newVm(dirB)
    val enginePost = HabiticaAPI.hold("createTodo:engine-create")
    vmB.addTask(0, "engine-create")
    val localId = vmB.state.value.store.history.getValue(today).taskGroups[0].single().id
    vmB.updateSettings { it.copy(uid = OTHER_UID) }
    enginePost.complete(Unit)
    val active = vmB.state.value.store
    expectEq(active.cloudAccount, OTHER_OWNER_KEY, "B active")
    expect(active.history.values.all { day -> day.taskGroups.flatten().isEmpty() }, "B never adopts A's created todo")
    val parked = active.accountStores.getValue(OWNER_KEY).history.getValue(today).taskGroups[0].single()
    expect(parked.habiticaTaskId == null && parked.pendingCreateTitle == "engine-create", "A keeps its reconcile marker: $parked")
    vmB.updateSettings { it.copy(uid = FIXTURE_UID) }
    val bound = vmB.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(bound.id == localId && bound.habiticaTaskId?.startsWith("RID-") == true && bound.pendingCreateTitle == null,
        "back on A the unique remote match is bound, not re-created: $bound")
    vmB.retryPendingTasks()
    expectEq(dispatched("createTodo:"), 1, "still exactly one POST")

    // (C)
    val dirC = newTempDir("ep-02c")
    seedSettings(dirC)
    seedTopThree(dirC, ownedStore())
    val vmC = newVm(dirC) { installManualClock() }
    HabiticaAPI.replyFor = { name -> if (name == "fetchTaskItems:habits") reply(429, "Retry-After" to "60") else null }
    val oldRead = HabiticaAPI.hold("fetchTaskItems:habits")
    vmC.refreshHabiticaTasks("habits")
    vmC.updateSettings { it.copy(uid = OTHER_UID) }
    vmC.updateSettings { it.copy(uid = FIXTURE_UID) }
    HabiticaAPI.profile = HabiticaAPI.profile.copy(level = 19)
    vmC.refreshProfile()
    expectEq(vmC.state.value.profile?.level, 19, "current profile loaded on the new connection")
    oldRead.complete(Unit)
    expectEq(vmC.state.value.tasksError, null, "a retired 429 does not replace current feedback")
    expectEq(vmC.state.value.profile?.level, 19, "nor the current role")
    expectEq(vmC.state.value.profileError, null, "nor the current role's status")
    expect(HabiticaRequestBudgets.rateLimitMessage(OWNER_KEY)?.contains("HTTP 429") == true, "but it still updates A's budget")
    val calls = HabiticaAPI.calls.size
    vmC.refreshHabiticaTasks("dailys")
    expectEq(HabiticaAPI.calls.size, calls, "and the next current request honours that cooldown")
    println("EP-02 OK")
}
