import Foundation
import UserNotifications

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    print("PASS \(message)")
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
PomodoroDataDir.isolatedDirectory = folder
let snapshotURL = folder.appendingPathComponent(".active-focus.json")
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
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = Array(CommandLine.arguments.dropFirst()) + ["--paused-child"]
try child.run()
child.waitUntilExit()
check(child.terminationStatus == 0, "the separate process recovered without any in-memory state")
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
