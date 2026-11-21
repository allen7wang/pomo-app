// CR-04 (v2.1.3): a POST refused with 401 while in flight. (A) The task was
// deleted meanwhile: the removal marker added for it is taken back, so a later
// different task in the same day/category is not blocked. (B) The account was
// switched meanwhile: only the ORIGINAL owner's row/attempt is released (in its
// parked partition); the active owner's coincident marker and other UUIDs stay.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaGate
import com.habitica.pomodoro.data.topThreeNotes

fun main() {
    val today = logicalTodayKey()

    // (A) deleted during the refused POST
    val dirA = newTempDir("cr-04a")
    seedSettings(dirA)
    seedTopThree(dirA, ownedStore())
    val vmA = newVm(dirA) { HabiticaAPI.replyFor = { name -> if (name == "createTodo:doomed") reply(401) else null } }
    val postA = HabiticaAPI.hold("createTodo:doomed")
    vmA.addTask(0, "doomed")
    expectEq(dispatched("createTodo:doomed"), 1, "POST dispatched and in flight")
    val marker = "${topThreeNotes("Work", today)}\ndoomed"
    vmA.deleteTask(0, 0)
    expect(marker in vmA.state.value.store.deletedCreateMarkers, "removal marker protects the in-flight POST")
    postA.complete(Unit)
    expectEq(vmA.state.value.store.deletedCreateMarkers, emptySet(), "a refused POST leaves no unresolvable removal marker")
    expectEq(readTopThreeDisk(dirA).deletedCreateMarkers, emptySet(), "persisted")
    expect(vmA.state.value.store.history.getValue(today).taskGroups[0].isEmpty(), "deleted task stays deleted")

    HabiticaAPI.replyFor = { null }
    vmA.addTask(0, "replacement")
    val replacement = vmA.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(replacement.habiticaTaskId != null && !replacement.syncPending, "same day/category task is not blocked: $replacement")
    vmA.refreshTopThreeFromCloud()
    expect(vmA.state.value.topThreeSyncError == null, "no lingering quarantine/marker error: ${vmA.state.value.topThreeSyncError}")

    // (B) account switched during the refused POST
    val dirB = newTempDir("cr-04b")
    seedSettings(dirB)
    val coincident = "${topThreeNotes("Work", today)}\nswitched"
    val otherMarker = "${topThreeNotes("MyOwn", today)}\nother"
    val partitionB = ownedStore(OTHER_OWNER_KEY).copy(deletedCreateMarkers = setOf(coincident))
    seedTopThree(dirB, ownedStore(history = mapOf(today to dayWith(today, 1, listOf(
        ownedTask(id = "OTHER-UUID", title = "other", pendingTitle = "other", pendingNotes = topThreeNotes("MyOwn", today), syncPending = true)))))
        .copy(accountStores = mapOf(OTHER_OWNER_KEY to partitionB)))
    val vmB = newVm(dirB) { HabiticaAPI.replyFor = { name -> if (name == "createTodo:switched") reply(401) else null } }
    val postB = HabiticaAPI.hold("createTodo:switched")
    vmB.addTask(0, "switched")
    val localId = vmB.state.value.store.history.getValue(today).taskGroups[0].single().id
    expectEq(vmB.state.value.store.history.getValue(today).taskGroups[0].single().pendingCreateTitle, "switched", "marker written before POST")
    vmB.updateSettings { it.copy(uid = OTHER_UID) }
    postB.complete(Unit)
    val s = vmB.state.value.store
    expectEq(s.cloudAccount, OTHER_OWNER_KEY, "account B stays active")
    expectEq(s.deletedCreateMarkers, setOf(coincident), "B's coincident payload marker untouched")
    val parked = s.accountStores.getValue(OWNER_KEY)
    val aRow = parked.history.getValue(today).taskGroups[0].single()
    expect(aRow.id == localId && aRow.pendingCreateTitle == null && aRow.syncPending, "A's row released in its parked partition: $aRow")
    val other = parked.history.getValue(today).taskGroups[1].single()
    expectEq(other.pendingCreateTitle, "other", "another UUID's attempt is untouched")
    expect(otherMarker !in parked.deletedCreateMarkers, "sanity")
    expect(vmB.state.value.profileError != HabiticaGate.AUTH_FAILED, "a retired account's 401 does not revoke B's role")
    expectEq(readTopThreeDisk(dirB).accountStores.getValue(OWNER_KEY).history.getValue(today).taskGroups[0].single().pendingCreateTitle,
        null, "parked release persisted")

    HabiticaAPI.replyFor = { null }
    vmB.updateSettings { it.copy(uid = FIXTURE_UID) }
    vmB.retryPendingTasks()
    expectEq(dispatched("createTodo:switched"), 2, "after switching back, the refused create is retried once")
    val back = vmB.state.value.store.history.getValue(today).taskGroups[0].single()
    expect(back.id == localId && back.habiticaTaskId != null, "created for the original owner: $back")
    println("CR-04 OK")
}
