// EP-01 (v2.1.4): changing UID, token, the connect toggle or the effective API
// root retires in-flight reads. Switching away and back re-reads with a new
// request (never joins or adopts the retired one); the retired response is
// refused even at the API boundary. Ordinary preferences and an equivalent API
// root keep the connection, so identical reads stay coalesced and usable.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaGate
import com.habitica.pomodoro.data.UserSettings

fun main() {
    val dir = newTempDir("ep-01")
    seedSettings(dir)
    seedTopThree(dir, ownedStore())
    lateinit var clock: ManualClock
    val vm = newVm(dir) { clock = installManualClock() }

    val cycles: List<Pair<String, (UserSettings) -> UserSettings>> = listOf(
        "A-B-A" to { s -> s.copy(uid = OTHER_UID) },
        "disconnect-reconnect" to { s -> s.copy(connectHabitica = false) },
        "token-away-and-back" to { s -> s.copy(apiToken = "temporary-fixture-token") },
        "API-root-away-and-back" to { s -> s.copy(developerServerUrl = "https://alternate.fixture.invalid/api/v3/") },
    )
    for ((name, away) in cycles) {
        clock.advance(61.0)
        val original = vm.state.value.settings
        HabiticaAPI.taskListBodies["habits"] = taskListBody("task" to "Before switch")
        val oldUiRead = HabiticaAPI.hold("fetchTaskItems:habits")
        vm.refreshHabiticaTasks("habits")
        val before = dispatched("fetchTaskItems:habits")
        // The same read issued directly at the API boundary joins the in-flight request (one dispatch).
        val oldApiRead = startCall { HabiticaAPI.fetchTaskItems(original, "habits") }
        expectEq(dispatched("fetchTaskItems:habits"), before, "$name: identical read coalesced before the switch")

        vm.updateSettings(away)
        vm.updateSettings { original }
        HabiticaAPI.taskListBodies["habits"] = taskListBody("task" to "After switch")
        vm.refreshHabiticaTasks("habits")
        expectEq(dispatched("fetchTaskItems:habits"), before + 1, "$name: refresh starts a new request instead of joining the retired one")
        expectEq(vm.state.value.habits.single().text, "After switch", "$name: current read applied")

        oldUiRead.complete(Unit)
        expectEq(vm.state.value.habits.single().text, "After switch", "$name: retired response not adopted by the UI")
        val retired = oldApiRead.done("$name retired read")
        expect(retired is HabiticaAPI.Result.Error && retired.message == HabiticaGate.STALE_CONNECTION,
            "$name: retired response refused at the API boundary: $retired")
    }

    // Unrelated preference: same connection, one shared dispatch, both usable.
    clock.advance(61.0)
    HabiticaAPI.taskListBodies["habits"] = taskListBody("same" to "Shared")
    val hold = HabiticaAPI.hold("fetchTaskItems:habits")
    val start = dispatched("fetchTaskItems:habits")
    val first = startCall { HabiticaAPI.fetchTaskItems(vm.state.value.settings, "habits") }
    vm.updateSettings { it.copy(pomoDurationMins = it.pomoDurationMins + 1) }
    val second = startCall { HabiticaAPI.fetchTaskItems(vm.state.value.settings, "habits") }
    hold.complete(Unit)
    expectEq(dispatched("fetchTaskItems:habits"), start + 1, "preference edit keeps reads coalesced")
    expect(first.done("first") is HabiticaAPI.Result.Success && second.done("second") is HabiticaAPI.Result.Success, "both usable")

    // Equivalent spelling of the same API root: same connection and owner, no interruption.
    val equivalentHold = HabiticaAPI.hold("fetchTaskItems:habits")
    val canonical = startCall { HabiticaAPI.fetchTaskItems(vm.state.value.settings, "habits") }
    val generationBefore = vm.state.value.store
    vm.updateSettings { it.copy(developerServerUrl = "https://HABITICA.com:443/api/v3////") }
    val equivalent = startCall { HabiticaAPI.fetchTaskItems(vm.state.value.settings, "habits") }
    equivalentHold.complete(Unit)
    expectEq(dispatched("fetchTaskItems:habits"), start + 2, "equivalent root keeps reads coalesced")
    expect(canonical.done("canonical") is HabiticaAPI.Result.Success && equivalent.done("equivalent") is HabiticaAPI.Result.Success,
        "equivalent root does not discard the accepted response")
    expectEq(vm.state.value.store, generationBefore, "equivalent root is the same owner partition")

    // A composite Top3 read never sends (or adopts) a second leg across an epoch change.
    clock.advance(61.0)
    vm.updateSettings { it.copy(developerServerUrl = "") }
    val firstLeg = HabiticaAPI.hold("fetchTopThreeTodos")
    val settingsA = vm.state.value.settings
    val composite = startCall { HabiticaAPI.fetchTopThreeTodos(settingsA) }
    vm.updateSettings { it.copy(uid = OTHER_UID) }
    vm.updateSettings { it.copy(uid = FIXTURE_UID) }
    val legs = dispatched("fetchCompletedTodos") // includes the engine's own refreshes for B and A
    firstLeg.complete(Unit)
    expect(composite.done("composite") is HabiticaAPI.Result.Error, "composite result discarded across the epoch")
    expectEq(dispatched("fetchCompletedTodos"), legs, "second leg never dispatched for the retired connection")
    // The pin itself: a request bound to an old epoch is refused before dispatch even though the
    // connection (A) matches again — this is what keeps a late second leg from being sent.
    val pinned = HabiticaGate.epochOf(vm.state.value.settings) ?: throw AssertionError("active epoch")
    vm.updateSettings { it.copy(uid = OTHER_UID) }
    vm.updateSettings { it.copy(uid = FIXTURE_UID) }
    var lateLegSent = false
    val lateLeg = startCall {
        HabiticaGate.exchange(vm.state.value.settings, "GET", "late-second-leg", pinned) {
            lateLegSent = true
            com.habitica.pomodoro.data.HabiticaReply(200, "{\"data\":[]}")
        }
    }.done("late leg")
    expect(lateLeg is HabiticaGate.Exchange.NotSent && !lateLegSent, "epoch-pinned leg not sent after A-B-A: $lateLeg")
    val legsBeforeFresh = dispatched("fetchCompletedTodos")
    val fresh = startCall { HabiticaAPI.fetchTopThreeTodos(vm.state.value.settings) }.done("fresh")
    expect(fresh is HabiticaAPI.Result.Success, "a new composite read after A-B-A performs both legs")
    expectEq(dispatched("fetchCompletedTodos"), legsBeforeFresh + 1, "fresh second leg sent")
    println("EP-01 OK")
}
