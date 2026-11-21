import com.habitica.pomodoro.data.HabiticaAPI
import java.io.File

fun main() {
    val dir = newTempDir("cr-05")
    val day = logicalTodayKey()
    seedSettings(dir)
    seedTopThree(dir, ownedStore(history = mapOf(day to dayWith(day, 0,
        listOf(ownedTask(title = "existing", remoteId = "existing-id"))))))
    val vm = newVm(dir) { installManualClock() }

    val pending = File(dataDir(dir), "habitica_pomodoro_top_three.json.pending")
    expect(pending.mkdir(), "block the atomic temp file")
    vm.addTask(1, "new")
    vm.deleteTask(0, 0)
    expectEq(dispatched("createTodo:new"), 0, "a failed marker save blocks the create")
    expectEq(dispatched("deleteTodo:existing-id"), 0, "a failed tombstone save blocks the delete")
    expect(vm.state.value.persistenceError != null, "write failure remains visible")
    expectEq(vm.state.value.store.history.getValue(day).taskGroups[1].single().pendingCreateTitle,
        null, "a create that never dispatched leaves no uncertain marker")

    expect(pending.delete(), "unblock the atomic temp file")
    HabiticaAPI.cloud.add(cloudTodo("existing-id", "existing"))
    vm.retryPendingTasks()
    expectEq(dispatched("createTodo:new"), 1, "a manual retry sends the now-durable create once")
    expectEq(dispatched("deleteTodo:existing-id"), 1, "a manual retry sends the now-durable delete once")
    expect(vm.state.value.persistenceError == null, "successful save clears the write failure")
    println("CR-05 OK")
}
