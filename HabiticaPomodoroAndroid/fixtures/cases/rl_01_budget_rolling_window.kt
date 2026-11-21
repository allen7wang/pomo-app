// RL-01 (v2.1.2): one rolling budget of 24 requests / 60 s per UID + API root,
// shared by every feature. The 25th request is not dispatched (no HTTP), the
// user sees the Apple wait wording, and the window reopens after 60 s.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaRequestBudget
import com.habitica.pomodoro.data.HabiticaRequestBudgets

fun main() {
    // Pure window arithmetic (Apple habitica_rate_limit vector 1). The ceiling is pinned literally.
    val limit = 24
    expectEq(HabiticaRequestBudget.LOCAL_LIMIT, limit, "local ceiling")
    val budget = HabiticaRequestBudget()
    repeat(limit) { expectEq(budget.reserve(100.0), 0.0, "reserve #$it within the window") }
    expectEq(budget.reserve(100.0), 60.0, "25th request waits for the oldest start to leave the window")
    expectEq(budget.reserve(159.0), 1.0, "still one second short at t+59")
    expectEq(budget.reserve(160.0), 0.0, "window reopens 60 s after the burst")

    // Through the real gate + engine: every feature draws from the same budget.
    val dir = newTempDir("rl-01")
    seedSettings(dir)
    seedTopThree(dir, ownedStore())
    lateinit var clock: ManualClock
    val vm = newVm(dir) { clock = installManualClock() }
    val initial = HabiticaAPI.calls.size
    expect(initial in 1 until limit, "init dispatched a few reads, was $initial")
    // A successful score also refreshes the role, so count dispatches rather than actions.
    var n = 0
    while (HabiticaAPI.calls.size < limit) vm.scoreHabiticaTask("habits", habitItem("H-${n++}"), "up")
    expectEq(HabiticaAPI.calls.size, limit, "exactly the local allowance was dispatched")
    expectEq(vm.state.value.tasksError, null, "no error while within the allowance")

    vm.scoreHabiticaTask("habits", habitItem("H-over"), "up")
    expectEq(HabiticaAPI.calls.size, limit, "overflow score is never dispatched")
    val error = vm.state.value.tasksError.orEmpty()
    expect(error.startsWith("Habitica 请求额度暂时用完，请 ") && error.endsWith(" 秒后重试。"), "Apple wait wording, was: $error")
    expectEq(HabiticaRequestBudgets.rateLimitMessage(OWNER_KEY), "Habitica 请求额度暂时用完，请 60 秒后重试。", "seconds until the window reopens")

    // Other features are blocked by the same account budget, without HTTP and without losing state.
    val profile = vm.state.value.profile
    vm.refreshProfile()
    vm.refreshTopThreeFromCloud()
    vm.refreshHabiticaTasks("dailys")
    expectEq(HabiticaAPI.calls.size, limit, "profile/Top3/list reads share the exhausted budget")
    expectEq(vm.state.value.profile, profile, "blocked profile refresh keeps the shown role")
    expect(vm.state.value.profileError?.contains("秒后重试") == true, "profile shows the wait: ${vm.state.value.profileError}")
    expect(vm.state.value.topThreeSyncError?.contains("秒后重试") == true, "Task page shows the wait: ${vm.state.value.topThreeSyncError}")

    clock.advance(60.0)
    vm.scoreHabiticaTask("habits", habitItem("H-after"), "up")
    expectEq(dispatched("scoreTask:H-after:up"), 1, "window reopened after 60 s")
    expectEq(dispatched("scoreTask:H-over"), 0, "the rejected score was never replayed")
    expectEq(vm.state.value.tasksError, null, "a newer successful request clears the old budget error")
    println("RL-01 OK")
}
