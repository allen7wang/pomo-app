// RL-04 (v2.1.2/2.1.4): the budget belongs to UID + effective API root, never
// to a token or connection epoch. Token rotation, disconnect/reconnect and
// A→B→A cannot bypass A's cooldown; B has its own independent budget.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaRequestBudgets

fun main() {
    val dir = newTempDir("rl-04")
    seedSettings(dir)
    seedTopThree(dir, ownedStore())
    val vm = newVm(dir) { installManualClock() }

    HabiticaAPI.replyFor = { name -> if (name == "fetchTaskItems:habits") reply(429, "Retry-After" to "60") else null }
    vm.refreshHabiticaTasks("habits")
    expect(vm.state.value.tasksError?.contains("HTTP 429") == true, "429 shown: ${vm.state.value.tasksError}")
    HabiticaAPI.replyFor = { null }
    val afterLimit = HabiticaAPI.calls.size

    vm.updateSettings { it.copy(apiToken = "rotated-fixture-token") }
    vm.refreshHabiticaTasks("dailys")
    vm.refreshTopThreeFromCloud()
    expectEq(HabiticaAPI.calls.size, afterLimit, "token rotation does not reset the account's cooldown")

    vm.updateSettings { it.copy(connectHabitica = false) }
    vm.updateSettings { it.copy(connectHabitica = true) }
    vm.refreshHabiticaTasks("habits")
    expectEq(HabiticaAPI.calls.size, afterLimit, "disconnect/reconnect does not reset it either")

    vm.updateSettings { it.copy(uid = OTHER_UID) }
    expect(HabiticaAPI.calls.size > afterLimit, "account B has its own budget (its Top3 refresh was sent)")
    val bCalls = HabiticaAPI.calls.size
    vm.refreshHabiticaTasks("habits")
    expectEq(HabiticaAPI.calls.size, bCalls + 1, "B can load its lists")
    expectEq(HabiticaRequestBudgets.rateLimitMessage(OTHER_OWNER_KEY), null, "B is not cooling down")

    vm.updateSettings { it.copy(uid = FIXTURE_UID) }
    vm.refreshHabiticaTasks("habits")
    vm.scoreHabiticaTask("habits", habitItem("H-A"), "up")
    expectEq(HabiticaAPI.calls.size, bCalls + 1, "switching back to A keeps A's cooldown")
    expect(HabiticaRequestBudgets.rateLimitMessage(OWNER_KEY)?.contains("HTTP 429") == true, "A's 429 survives every switch")
    expect(vm.state.value.topThreeSyncError?.contains("HTTP 429") == true,
        "A's Top3 refresh after switching back explains the wait: ${vm.state.value.topThreeSyncError}")
    println("RL-04 OK")
}
