import Foundation
import UserNotifications

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    print("PASS \(message)")
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
PomodoroDataDir.isolatedDirectory = folder
let snapshotURL = folder.appendingPathComponent(".active-focus.json")
let historyName = "habitica_pomodoro_histogram.json"
let historyURL = folder.appendingPathComponent(historyName)
func runChild(_ mode: String, expecting status: Int32 = 0) throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = Array(CommandLine.arguments.dropFirst()) + [mode]
    try child.run()
    child.waitUntilExit()
    precondition(child.terminationReason == .exit && child.terminationStatus == status,
                 "\(mode) exited with status \(child.terminationStatus)")
}

if CommandLine.arguments.contains("--history-blocked") {
    let engine = PomodoroEngine()
    let before = HistogramManager.shared.histogram
    engine.restoreFocusAfterLaunch()
    check(engine.focusRecoveryWarning != nil && FileManager.default.fileExists(atPath: snapshotURL.path),
          "a failed history write retains a retryable checkpoint and reports the failure")
    check(HistogramManager.shared.histogram == before && engine.pomoSetCounter == 0,
          "a failed write never publishes a provisional focus or advances the combo")
    check(UNUserNotificationCenter.current().requests.isEmpty, "a failed cold settlement sends no alert")
    exit(0)
}
if CommandLine.arguments.contains("--exit-after-history") {
    // This callback runs inside the production store, just after the atomic file write.
    PomodoroDataDir.onLocalWrite = { name in
        if name == historyName { _exit(86) }
    }
    PomodoroEngine().restoreFocusAfterLaunch()
    fatalError("expected a process exit at the histogram commit")
}
if CommandLine.arguments.contains("--finish-checkpoint") {
    let engine = PomodoroEngine()
    // The clock has rolled back to before the original deadline during the restart.
    engine.restoreFocusAfterLaunch(now: Date(timeIntervalSince1970: 1))
    engine.restoreFocusAfterLaunch()
    check(engine.phase == .manualBreak && engine.pomoSetCounter == 1 &&
          !FileManager.default.fileExists(atPath: snapshotURL.path),
          "retry finishes the pending phase once and retires its checkpoint")
    check(UNUserNotificationCenter.current().requests.isEmpty, "settlement retry sends no historical alert")
    exit(0)
}
if CommandLine.arguments.contains("--retry-in-place") {
    let engine = PomodoroEngine()
    let history = HistogramManager.shared
    let before = history.totalPomodoros
    do {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: historyURL.path)
        defer { try! FileManager.default.setAttributes([.immutable: false], ofItemAtPath: historyURL.path) }
        engine.restoreFocusAfterLaunch()
        engine.freeze()
        engine.skipToBreak()
        check(engine.phase == .pomodoro && !engine.isFrozen && engine.focusRecoveryWarning != nil &&
              history.totalPomodoros == before, "pending history waits for storage while focus controls cannot reschedule it")
    }
    let timeout = Date().addingTimeInterval(12)
    while engine.phase == .pomodoro && Date() < timeout {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check(engine.phase == .manualBreak && engine.focusRecoveryWarning == nil && history.totalPomodoros == before + 1 &&
          !FileManager.default.fileExists(atPath: snapshotURL.path),
          "a scheduled retry automatically commits once when the file becomes writable")
    check(UNUserNotificationCenter.current().requests.isEmpty, "automatic retry keeps cold settlement silent")
    exit(0)
}
if CommandLine.arguments.contains("--paused-child") {
    let childEngine = PomodoroEngine()
    childEngine.restoreFocusAfterLaunch()
    check(childEngine.isFrozen && childEngine.timerValue == 13 * 60 &&
          childEngine.taskFocus?.title == "保存原始标题", "a new process restores the paused checkpoint from disk")
    exit(0)
}
let settings = SettingsManager.shared
settings.settings.connectHabitica = false
settings.settings.apiToken = "fixture-token-must-not-be-persisted"
settings.settings.pomoDurationMins = 25
settings.settings.manualBreak = true
settings.settings.enableBlockMode = false
let manager = TopThreeManager.shared
let today = manager.todayKey(settings: settings.settings)
manager.addTask(key: today, category: 0, title: "保存原始标题", settings: settings.settings)
let task = manager.getTasks(key: today, category: 0)[0]
let history = HistogramManager.shared

var beforeExit: PomodoroEngine? = PomodoroEngine()
check(beforeExit!.startPomodoro(taskId: task.id, category: 0, dateKey: today), "the task starts a checkpointed focus")
let session = beforeExit!.taskFocus!
let runningBytes = try Data(contentsOf: snapshotURL)
try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
beforeExit!.freeze()
let blockedBytes = try Data(contentsOf: snapshotURL)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
check(!beforeExit!.isFrozen && beforeExit!.focusRecoveryWarning != nil && blockedBytes == runningBytes,
      "a failed pause write keeps the running phase consistent with disk")
beforeExit!.freeze()
let bytes = try Data(contentsOf: snapshotURL)
check(!String(decoding: bytes, as: UTF8.self).contains("fixture-token-must-not-be-persisted"),
      "the local checkpoint excludes the API token")
var checkpoint = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
checkpoint["secondsRemaining"] = 13 * 60
try JSONSerialization.data(withJSONObject: checkpoint).write(to: snapshotURL, options: .atomic)
beforeExit = nil

settings.settings.pomoDurationMins = 90
manager.setTaskTitle(key: today, category: 0, id: task.id, title: "修改后的标题", settings: settings.settings)
try runChild("--paused-child")
let paused = PomodoroEngine()
paused.restoreFocusAfterLaunch()
check(paused.isFrozen && paused.timerValue == 13 * 60 && paused.phaseDuration == 25 * 60 &&
      paused.taskFocus == session, "process restart restores the paused phase, task and original duration")
paused.unfreeze()
check(!paused.isFrozen && paused.timerValue == 13 * 60 && paused.phaseDuration == 25 * 60 &&
      paused.phaseProgress > 0.47, "resume keeps the original progress scale")

let sameDeadline = paused.phaseEndsAt!
let running = PomodoroEngine()
running.restoreFocusAfterLaunch(now: sameDeadline.addingTimeInterval(-90))
check(running.phaseEndsAt == sameDeadline && running.timerValue == 90 && running.taskFocus == session,
      "process restart preserves the absolute running deadline")

// Model a relaunch after midnight using the checkpoint's original completion day.
let now = Date()
let deadline = Calendar.current.startOfDay(for: now).addingTimeInterval(-90)
var expired = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Any]
expired["deadline"] = deadline.timeIntervalSinceReferenceDate
let expiredBytes = try JSONSerialization.data(withJSONObject: expired)
try expiredBytes.write(to: snapshotURL, options: .atomic)

let sibling = folder.appendingPathComponent("another-store", isDirectory: true)
try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
try expiredBytes.write(to: sibling.appendingPathComponent(snapshotURL.lastPathComponent))
PomodoroDataDir.isolatedDirectory = sibling
let wrongDirectory = PomodoroEngine()
wrongDirectory.restoreFocusAfterLaunch(now: now)
check(wrongDirectory.phase == .idle && history.totalPomodoros == 0,
      "a checkpoint cannot settle against another directory")
PomodoroDataDir.isolatedDirectory = folder

let notifications = UNUserNotificationCenter.current().requests.count
let expiredEngine = PomodoroEngine()
expiredEngine.restoreFocusAfterLaunch(now: now)
let entry = history.histogram[history.todayKey(date: deadline)]
check(entry?.pomodoros == 1 && entry?.minutes == 25 && entry?.taskSessions == [session],
      "expired focus is attributed once using its original completion day and snapshot")
check(expiredEngine.phase == .manualBreak && expiredEngine.pomoSetCounter == 1,
      "recovery restores combo and enters the configured manual break")
check(notifications == UNUserNotificationCenter.current().requests.count, "cold recovery suppresses historical notifications")
let anotherProcess = PomodoroEngine()
anotherProcess.restoreFocusAfterLaunch()
check(anotherProcess.phase == .idle && history.totalPomodoros == 1 &&
      !FileManager.default.fileExists(atPath: snapshotURL.path), "later restarts cannot repeat the completed checkpoint")

anotherProcess.startPomodoro()
anotherProcess.skipToBreak()
check(!FileManager.default.fileExists(atPath: snapshotURL.path), "skipping removes the active checkpoint")
anotherProcess.startPomodoro()
anotherProcess.pomodoroInterrupted(breakStreak: true)
check(!FileManager.default.fileExists(atPath: snapshotURL.path), "abandoning removes the active checkpoint")
anotherProcess.startPomodoro()
anotherProcess.reset()
check(!FileManager.default.fileExists(atPath: snapshotURL.path), "reset removes the active checkpoint")

history.incrementToday(pomodoros: 1, minutes: 12)
anotherProcess.loadTodayCount()
check(anotherProcess.todayFocusMinutes == 12 && anotherProcess.todayPomodoros == 1,
      "the timer uses saved minutes instead of the current duration setting")

// Reproduce two interruptions of the same expired 3.1.0 checkpoint. The first
// process cannot write history. The second dies before it can retire the timer.
settings.settings.enableBlockMode = true
settings.settings.blockCount = 1
settings.settings.pomoSetNum = 1
settings.settings.pomoDurationMins = 17
for withTask in [false, true] {
    let engine = PomodoroEngine()
    if withTask {
        let key = manager.todayKey(settings: settings.settings)
        manager.addTask(key: key, category: 2, title: "跨进程补记", settings: settings.settings)
        let retryTask = manager.getTasks(key: key, category: 2).last!
        check(engine.startPomodoro(taskId: retryTask.id, category: 2, dateKey: key),
              "a new task focus starts before the retry test")
    } else {
        engine.startPomodoro()
    }
    let originalTask = engine.taskFocus
    let end = Calendar.current.date(byAdding: .day, value: withTask ? -3 : -2, to: now)!
    let day = history.todayKey(date: end)
    var old = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Any]
    old.removeValue(forKey: "focusID")
    old["deadline"] = end.timeIntervalSinceReferenceDate
    try JSONSerialization.data(withJSONObject: old).write(to: snapshotURL, options: .atomic)

    // Only block histogram writes. The checkpoint must remain writable for migration.
    let originalHistory = try Data(contentsOf: historyURL)
    if withTask {
        let corrupt = Data("unreadable store".utf8)
        try corrupt.write(to: historyURL, options: .atomic)
        try runChild("--history-blocked")
        let blockedHistory = try Data(contentsOf: historyURL)
        check(blockedHistory == corrupt, "blocked settlement preserves unreadable history bytes")
        try originalHistory.write(to: historyURL, options: .atomic)
    } else {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: historyURL.path)
        defer { try! FileManager.default.setAttributes([.immutable: false], ofItemAtPath: historyURL.path) }
        try runChild("--history-blocked")
        let blockedHistory = try Data(contentsOf: historyURL)
        check(blockedHistory == originalHistory, "a failed atomic replacement keeps valid history intact")
    }
    try runChild("--exit-after-history", expecting: 86)

    func readDay() throws -> DayHistogram? {
        try JSONDecoder().decode(Histogram.self, from: Data(contentsOf: historyURL))[day]
    }
    let committed = try readDay()
    check(committed?.pomodoros == 1 && committed?.minutes == 17 &&
          FileManager.default.fileExists(atPath: snapshotURL.path),
          "the process exits with the completed day on disk and the checkpoint still present")
    try runChild("--finish-checkpoint")
    let final = try readDay()
    check(final == committed && (final?.taskSessions ?? []) == (originalTask.map { [$0] } ?? []),
          "repeat settlement preserves the original totals and task attribution on the deadline day")
    let blocks = try JSONDecoder().decode(DailyBlocksHistory.self, from:
        Data(contentsOf: folder.appendingPathComponent("habitica_pomodoro_daily_blocks.json")))
    let plants = try JSONDecoder().decode([String: PlantDay].self, from:
        Data(contentsOf: folder.appendingPathComponent("habitica_pomodoro_plants.json")))
    check(blocks[day]?.blockProgress == [1] && plants[day]?.attempts == [[.shrub]] && plants[day]?.trees == [1],
          "repeated settlement awards one block completion, shrub and combo tree")
}

let retry = PomodoroEngine()
retry.startPomodoro()
var pending = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Any]
pending["deadline"] = now.addingTimeInterval(-60).timeIntervalSinceReferenceDate
try JSONSerialization.data(withJSONObject: pending).write(to: snapshotURL, options: .atomic)
try runChild("--retry-in-place")
