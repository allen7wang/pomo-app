// CR-03 (v2.1.3): a create that WAS dispatched but whose outcome is unknown
// (HTTP 400/500, transport loss, 2xx without an id) keeps its durable marker
// and is never blindly re-POSTed: the retry reconciles against the cloud first
// (D1 path). A legacy undecidable removal marker is never auto-cleared.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.topThreeNotes

fun main() {
    val today = logicalTodayKey()
    val outcomes = listOf(
        "HTTP 400" to reply(400),
        "HTTP 500" to reply(500),
        "transport loss" to HabiticaAPI.StubReply(lost = true),
        "201 without id" to reply(201, body = "{\"data\":{}}"),
    )
    for ((label, outcome) in outcomes) {
        val dir = newTempDir("cr-03")
        seedSettings(dir)
        val legacy = "${topThreeNotes("MyOwn", today)}\nlegacy"
        seedTopThree(dir, ownedStore().copy(deletedCreateMarkers = setOf(legacy)))
        val vm = newVm(dir) {
            HabiticaAPI.replyFor = { name -> if (name.startsWith("createTodo:")) outcome else null }
        }
        vm.addTask(0, "uncertain")
        var row = vm.state.value.store.history.getValue(today).taskGroups[0].single()
        expectEq(row.pendingCreateTitle, "uncertain", "$label: marker kept")
        expect(row.syncPending && row.habiticaTaskId == null, "$label: still pending")

        HabiticaAPI.replyFor = { null }
        vm.retryPendingTasks()
        vm.refreshTopThreeFromCloud()
        expectEq(dispatched("createTodo:"), 1, "$label: never blindly re-POSTed")
        row = vm.state.value.store.history.getValue(today).taskGroups[0].single()
        expectEq(row.pendingCreateTitle, "uncertain", "$label: marker survives the retry")
        expect(row.syncError?.contains("未重复 POST") == true, "$label: asks for review: ${row.syncError}")
        expect(legacy in vm.state.value.store.deletedCreateMarkers, "$label: legacy marker not auto-cleared")

        // Once the lost create becomes visible remotely, the retry binds it instead of creating again.
        HabiticaAPI.cloud += cloudTodo("RID-LATE", "uncertain", tags = listOf(vm.state.value.store.categoryTagIds.getValue("Work")))
        vm.retryPendingTasks()
        row = vm.state.value.store.history.getValue(today).taskGroups[0].single()
        expectEq(row.habiticaTaskId, "RID-LATE", "$label: reconciled with the unique remote match")
        expectEq(dispatched("createTodo:"), 1, "$label: still exactly one POST")
    }
    println("CR-03 OK")
}
