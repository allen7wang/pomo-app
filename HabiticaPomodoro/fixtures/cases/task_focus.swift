import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    print("PASS \(message)")
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
PomodoroDataDir.isolatedDirectory = folder
let file = folder.appendingPathComponent("habitica_pomodoro_histogram.json")
let day = FocusReview.dateKeyFormatter(calendar: .current).string(from: Date())
// A plain legacy histogram decodes and is preserved when upgrading the day.
try Data("{\"\(day)\":{\"pomodoros\":2,\"minutes\":50,\"weekday\":\"Fixture\"}}".utf8).write(to: file)

let manager = TopThreeManager.shared
let settings = SettingsManager.shared
settings.settings.connectHabitica = false
settings.settings.enableBlockMode = false
settings.settings.pomoDurationMins = 25
settings.settings.manualBreak = true
let today = manager.todayKey(settings: settings.settings)
let originalTitle = " =1+\"任务,续\""
manager.addTask(key: today, category: 0, title: originalTitle, settings: settings.settings)
let task = manager.getTasks(key: today, category: 0)[0]
let engine = PomodoroEngine.shared
let histogram = HistogramManager.shared

check(!engine.startPomodoro(taskId: task.id, category: 0, dateKey: "2000-01-01"), "archived rows cannot start focus")
check(engine.startPomodoro(taskId: task.id, category: 0, dateKey: today), "unfinished today task starts focus")
let first = engine.taskFocus!
engine.freeze()
check(engine.isFrozen && engine.taskFocus == first, "pause keeps the task snapshot")
check(!engine.startPomodoro(taskId: task.id, category: 0, dateKey: today), "starting again cannot replace paused focus")
engine.unfreeze()
check(engine.taskFocus == first, "resume retains focus attribution")
engine.skipToBreak()
check(engine.taskFocus == nil && histogram.histogram[day]?.pomodoros == 2, "skip clears attribution without incrementing")

check(engine.startPomodoro(taskId: task.id, category: 0, dateKey: today), "a new focus has a new snapshot")
let session = engine.taskFocus!
manager.setTaskTitle(key: today, category: 0, id: task.id, title: "新版标题", settings: settings.settings)
settings.settings.pomoDurationMins = 42
let remote = TaskFocusSession(id: UUID(), taskId: task.id, title: "另一端记录", minutes: 10, startedAt: session.startedAt - 1)
let arrived: Histogram = [day: DayHistogram(pomodoros: 3, minutes: 60, weekday: "Fixture", taskSessions: [remote])]
try JSONEncoder().encode(arrived).write(to: file, options: .atomic)

var finished = false
Task { @MainActor in
    await engine.pomodoroEnds()
    await engine.pomodoroEnds()
    finished = true
}
let timeout = Date().addingTimeInterval(4)
while !finished && Date() < timeout { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(finished && engine.taskFocus == nil, "completion settles the phase exactly once")
histogram.reload()
let saved = histogram.histogram[day]!
check(saved.pomodoros == 4 && saved.minutes == 85 && saved.taskSessions == [remote, session],
      "real data store merges arrived completion and preserves old totals")
check(session.title == originalTitle.trimmingCharacters(in: .whitespaces) && session.minutes == 25,
      "completion retains the title and duration captured at start")
check(manager.getTasks(key: today, category: 0).first?.isCompleted == false, "focus completion leaves the task open")
let review = FocusReview(range: .week, now: Date(), histogram: histogram.histogram, dailyBlocks: [:], blockHistory: [:], plants: [:])
check(review.tasks.count == 1 && review.tasks[0].minutes == 35 && review.tasks[0].pomodoros == 2,
      "review groups different title snapshots by stable task identity")
check(review.taskCSV.contains("\"'=1+\"\"任务,续\"\"\""), "task CSV safely quotes titles with formulas, commas and quotes")

histogram.clear()
check(histogram.histogram.isEmpty && !manager.getTasks(key: today, category: 0).isEmpty, "clearing focus history preserves tasks")
