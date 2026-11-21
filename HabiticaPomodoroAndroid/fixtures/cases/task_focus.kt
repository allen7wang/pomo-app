import com.habitica.pomodoro.data.FocusReview
import com.habitica.pomodoro.data.FocusReviewRange
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.LocalStore
import com.habitica.pomodoro.data.UserSettings
import java.time.LocalDate
import java.time.ZoneId

fun main() {
    val folder = newTempDir("task-focus")
    val store = LocalStore(TestApp(folder))
    val settings = UserSettings(connectHabitica = false, enableBlockMode = false, manualBreak = true, pomoDurationMins = 25)
    store.saveSettings(settings)
    val today = store.logicalDateKey(settings)
    val task = ownedTask(title = "=1+\"任务,续\"", owner = null)
    seedTopThree(folder, ownedStore(owner = null, history = mapOf(today to dayWith(today, 0, listOf(task)))))
    val source = newVm(folder)
    expect(!source.startTaskFocus("2000-01-01", 0, task.id), "archived rows cannot start focus")
    expect(source.startTaskFocus(today, 0, task.id), "unfinished task starts focus")
    val snapshot = source.state.value.taskFocus!!
    source.skipToBreak()
    expect(source.state.value.taskFocus == null && store.loadHistogram().isEmpty(), "skip creates no focus record")
    expect(source.startTaskFocus(today, 0, task.id), "another focus can start after skip")
    val active = source.state.value.taskFocus!!
    expect(active.id != snapshot.id, "each focus gets an independent identity")
    source.pause()
    expect(!source.startTaskFocus(today, 0, task.id), "cannot replace paused focus")
    source.editTask(0, 0, "新版标题")
    source.updateSettings { it.copy(pomoDurationMins = 42) }

    val restored = newVm(folder)
    expectEq(restored.state.value.taskFocus, active, "paused focus snapshot survives process restart")
    restored.resume()
    val end = LocalDate.now().minusDays(1).atTime(23, 59).atZone(ZoneId.systemDefault())
    val expired = store.loadTimer()!!.put("endsAt", end.toInstant().toEpochMilli())
    restored.pause()
    store.saveTimer(expired)
    val completed = newVm(folder)
    val day = end.toLocalDate().toString()
    val saved = store.loadHistogram().getValue(day)
    expectEq(saved.taskSessions.single(), active, "completion uses original task title and duration, on the deadline day")
    expectEq(saved.minutes, 25, "day total uses the captured duration")
    expectEq(completed.state.value.taskFocus, null, "completion clears the running task")
    expectEq(completed.state.value.store.history[today]?.taskGroups?.get(0)?.first()?.isCompleted,
        false, "time logging leaves the task open")
    store.saveTimer(expired)
    val replayed = newVm(folder)
    expectEq(store.loadHistogram().getValue(day), saved, "replaying a persisted deadline does not count twice")
    val review = FocusReview(FocusReviewRange.WEEK, LocalDate.now(), replayed.state.value.histogram, emptyMap(), emptyMap(), emptyMap())
    expectEq(review.tasks.single().minutes, 25, "date-window review uses persisted sessions")
    expect(review.taskCsv.contains("\"'=1+\"\"任务,续\"\"\""), "task CSV quotes formulas, commas and quotes")
    replayed.clearHistogram()
    expect(store.loadHistogram().isEmpty() && replayed.state.value.store.history.containsKey(today),
        "clearing focus history keeps task data")
    expect(HabiticaAPI.calls.isEmpty(), "scenario is fully offline")
    println("TASK FOCUS OK")
}
