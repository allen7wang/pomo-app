// TL-01 (v2.1.3): Habits/Dailies. Malformed JSON, a wrong envelope, entries
// missing id/text, empty or duplicate ids, HTTP errors and transport loss are
// FAILURES: the list already shown for this account stays. A legal empty list
// is a success and clears it. Valid optional fields are preserved.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaGate
import com.habitica.pomodoro.data.parseHabiticaTaskList

fun main() {
    val malformed = listOf(
        "{\"data\":{\"unexpected\":true}}",
        "{\"success\":true}",
        "[]",
        "<html>temporarily unavailable</html>",
        "{\"data\":[{\"text\":\"Missing ID\"}]}",
        "{\"data\":[{\"id\":\"\",\"text\":\"Empty ID\"}]}",
        "{\"data\":[{\"id\":\"missing-text\"}]}",
        "{\"data\":[{\"id\":\"dup\",\"text\":\"First\"},{\"id\":\"dup\",\"text\":\"Second\"}]}",
        "{\"data\":[{\"id\":\"valid\",\"text\":\"Valid\"},{\"id\":\"invalid\"}]}",
        "{\"data\":[\"not an object\"]}",
    )
    malformed.forEachIndexed { i, body -> expectEq(parseHabiticaTaskList("habits", body), null, "parser rejects malformed body $i") }
    expectEq(parseHabiticaTaskList("dailys", "{\"data\":[]}"), emptyList(), "legal empty list parses")

    val dir = newTempDir("tl-01")
    seedSettings(dir)
    seedTopThree(dir, ownedStore())
    lateinit var clock: ManualClock
    val vm = newVm(dir) { clock = installManualClock() }
    fun load(type: String) { clock.advance(61.0); vm.refreshHabiticaTasks(type) }

    HabiticaAPI.taskListBodies["dailys"] = "{\"data\":[{\"_id\":\"d1\",\"id\":\"d1\",\"text\":\"Read\",\"notes\":\"One chapter\",\"value\":-2.5," +
        "\"completed\":true,\"up\":false,\"down\":true,\"isDue\":false}]}"
    load("dailys")
    val daily = vm.state.value.dailies.single()
    expect(daily.id == "d1" && daily.text == "Read" && daily.notes == "One chapter" && daily.value == -2.5 &&
        daily.completed && !daily.canUp && daily.canDown && !daily.isDue, "valid list keeps optional fields: $daily")

    HabiticaAPI.taskListBodies["habits"] = taskListBody("h1" to "Walk", "h2" to "Water")
    load("habits")
    val shown = vm.state.value.habits
    expectEq(shown.map { it.id }.toSet(), setOf("h1", "h2"), "habits loaded")

    for ((i, body) in malformed.withIndex()) {
        HabiticaAPI.taskListBodies["habits"] = body
        load("habits")
        expectEq(vm.state.value.habits, shown, "malformed body $i keeps the shown list")
        expectEq(vm.state.value.tasksError, HabiticaGate.TASK_LIST_MALFORMED, "malformed body $i reported")
    }
    HabiticaAPI.taskListBodies["habits"] = taskListBody("h1" to "Walk", "h2" to "Water")
    for ((label, scripted) in listOf("HTTP 500" to reply(500), "HTTP 401" to reply(401), "offline" to HabiticaAPI.StubReply(lost = true))) {
        HabiticaAPI.replyFor = { name -> if (name == "fetchTaskItems:habits") scripted else null }
        load("habits")
        expectEq(vm.state.value.habits, shown, "$label keeps the shown list")
        expect(vm.state.value.tasksError != null, "$label reported")
    }
    expectEq(vm.state.value.profile, null, "the 401 load also revoked the role")
    HabiticaAPI.replyFor = { null }

    HabiticaAPI.taskListBodies["habits"] = "{\"data\":[]}"
    load("habits")
    expectEq(vm.state.value.habits, emptyList(), "a legal empty list clears it")
    expectEq(vm.state.value.tasksError, null, "and a fresh success clears the older error")
    expectEq(vm.state.value.dailies.single().id, "d1", "the other list is independent")

    vm.updateSettings { it.copy(uid = OTHER_UID) }
    expect(vm.state.value.dailies.isEmpty(), "another account never sees the previous account's list")
    println("TL-01 OK")
}
