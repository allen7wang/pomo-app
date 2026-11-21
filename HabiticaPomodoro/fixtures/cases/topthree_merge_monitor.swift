import Foundation
import Darwin

// Real managers + real seven-file monitor + native 1.2 s reads of the synthetic Top3 file.
// "Remote" revisions are written by this probe as another device would (its own clock entry);
// no FileProvider/iCloud transport, account, or network is involved.
let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
guard let rootPath = ProcessInfo.processInfo.environment["POMO_FIXTURE_RUN_ROOT"] else {
    fatalError("Run this case through fixtures/run.py with an isolated scratch root")
}
precondition(fixture.path.hasPrefix(URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path + "/"),
             "fixture must be inside this unique run root")
precondition(PomodoroDataDir.resolvedURL.standardizedFileURL == fixture, "DEBUG data directory isolation failed")
precondition(geteuid() != 0, "permission-based failed-save probe requires a non-root user")
let handle = dlopen(nil, RTLD_NOW)!
guard let counterSymbol = dlsym(handle, "pomo_slow_read_count") else { fatalError("native slow-read interposer is not loaded") }
let delayedReadCount = unsafeBitCast(counterSymbol, to: (@convention(c) () -> UInt64).self)

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS \(label)") } else { print("FAIL \(label)"); failures += 1 }
}
let encoder = JSONEncoder()
func write<T: Encodable>(_ name: String, _ value: T) {
    try! encoder.encode(value).write(to: fixture.appendingPathComponent(name), options: .atomic)
}
var configuration = UserSettings()
configuration.connectHabitica = false
configuration.uid = ""
configuration.apiToken = ""
write("habitica_pomodoro_settings.json", configuration)
write("habitica_pomodoro_block_progress.json", BlockProgress())
write("habitica_pomodoro_block_history.json", BlockHistory())
write("habitica_pomodoro_daily_blocks.json", DailyBlocksHistory())
write("habitica_pomodoro_top_three.json", TopThreeStore())
write("habitica_pomodoro_plants.json", [String: PlantDay]())
write("habitica_pomodoro_histogram.json", Histogram())

let settings = SettingsManager.shared
let top = TopThreeManager.shared
_ = BlockProgressManager.shared
_ = PlantJournal.shared
_ = HistogramManager.shared
let monitor = PomodoroFileChanges.shared
let topURL = fixture.appendingPathComponent("habitica_pomodoro_top_three.json")
check(!settings.settings.connectHabitica && settings.settings.uid.isEmpty && settings.settings.apiToken.isEmpty,
      "fixture settings contain no account and disable Habitica")
let today = top.todayKey(settings: settings.settings)
let peer = "fixture-peer-device"

var maxGap = 0.0
var windowGap = 0.0 // per scenario, so a stall is attributed to the scenario that caused it
var lastBeat = Date()
var beats = 0
let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
    let now = Date()
    maxGap = max(maxGap, now.timeIntervalSince(lastBeat))
    windowGap = max(windowGap, now.timeIntervalSince(lastBeat))
    lastBeat = now
    beats += 1
}
func checkResponsive(_ label: String) {
    check(windowGap < fixtureMaxMainGap, label + String(format: " (max gap %.3fs)", windowGap))
    windowGap = 0
}
func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) }
}
func pumpUntil(_ label: String, _ done: () -> Bool) {
    let end = Date().addingTimeInterval(30) // hang guard only; utility-QoS reads starve first under load
    while !done() && Date() < end { pump(0.01) }
    precondition(done(), "timed out: \(label)")
}
func sync() {
    var done = false
    monitor.syncFromDiskIfNeeded { done = true }
    pumpUntil("background scan") { done }
}
func slowTopReads(_ enabled: Bool) {
    if enabled { setenv("POMO_SLOW_READ_PATH", topURL.path, 1) } else { unsetenv("POMO_SLOW_READ_PATH") }
}
/// Only called with slow reads disabled: a main-thread read here is the probe, not the app.
func disk() -> TopThreeStore {
    precondition(getenv("POMO_SLOW_READ_PATH") == nil)
    return try! JSONDecoder().decode(TopThreeStore.self, from: Data(contentsOf: topURL))
}
func titles(_ store: TopThreeStore) -> Set<String> {
    let rows: [TopThreeTask] = (store.history[today]?.taskGroups ?? []).flatMap { $0 }
    return Set(rows.map { $0.title })
}
func titles(_ names: String...) -> Set<String> { Set(names) }
func row(_ store: TopThreeStore, _ title: String) -> TopThreeTask? {
    store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }.first { $0.title == title }
}
/// Another device's save: edit a revision it read, stamp its edits and advance its own clock.
func peerWrite(from start: TopThreeStore, _ edit: (inout TopThreeStore) -> Void) {
    var next = start
    edit(&next)
    TopThreeMerge.stampLocalChanges(&next, since: start, at: Date())
    next.writeClock = TopThreeMerge.advancing(next.writeClock, device: peer)
    write("habitica_pomodoro_top_three.json", next)
}
func peerTask(_ title: String) -> TopThreeTask { TopThreeTask(title: title, syncPending: true) }
func add(_ title: String, category: Int = 0) {
    top.addTask(key: today, category: category, title: title, settings: settings.settings)
}

// 1. A remote revision lands while a failed local save keeps Top3 dirty.
add("local-1")
check(titles(disk()) == titles("local-1"), "baseline local task saved")
try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.path)
add("local-dirty")
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
check(titles(disk()) == titles("local-1") && titles(top.store).contains("local-dirty") && monitor.hasDirtyLocalEdit(topURL),
      "local save really failed and stays dirty")
peerWrite(from: disk()) { store in
    store.history[today]!.taskGroups[1].append(peerTask("remote-1"))
    store.history[today]!.taskGroups[0][0].isCompleted = true
}
var reads = delayedReadCount()
slowTopReads(true)
sync()
slowTopReads(false)
check(delayedReadCount() > reads, "native slow read of the Top3 file was actually injected")
check(titles(top.store) == titles("local-1", "local-dirty", "remote-1") && row(top.store, "local-1")?.isCompleted == true,
      "dirty local edit and remote revision are merged in memory, not skipped or replaced")
check(titles(disk()) == titles("local-1", "local-dirty", "remote-1") && !monitor.hasDirtyLocalEdit(topURL),
      "merged result is written, which releases the dirty ownership")
checkResponsive("dirty-merge scan leaves the main run loop responsive")

// 2. A remote revision lands before a local save, with no scan in between.
peerWrite(from: disk()) { $0.history[today]!.taskGroups[2].append(peerTask("remote-2")) }
let remoteStamp = PomodoroFileChanges.diskStamp(at: topURL)
reads = delayedReadCount()
slowTopReads(true)
add("local-2", category: 2)
check(PomodoroFileChanges.diskStamp(at: topURL) == remoteStamp && titles(top.store).contains("local-2"),
      "a save that would overwrite an unseen revision is deferred, keeping the edit in memory")
check(!top.save(), "the deferred save reports that nothing reached disk yet")
pumpUntil("deferred merge write") { PomodoroFileChanges.diskStamp(at: topURL) != remoteStamp }
check(delayedReadCount() > reads, "the unseen revision was read on the background reader")
slowTopReads(false)
sync() // drain the rescan that follows the merge write
check(titles(disk()) == titles("local-1", "local-dirty", "remote-1", "remote-2", "local-2") &&
      titles(top.store) == titles(disk()), "deferred save merges the remote revision before writing: no loss on either side")
checkResponsive("deferred save never reads on the main thread")

// 3. A remote revision lands, a scan is reading it slowly, and a local save happens meanwhile.
peerWrite(from: disk()) { $0.history[today]!.taskGroups[2].append(peerTask("remote-3")) }
slowTopReads(true)
var raceDone = false
monitor.syncFromDiskIfNeeded { raceDone = true }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { add("local-3", category: 2) }
pumpUntil("racing scan") { raceDone }
slowTopReads(false)
sync()
check(titles(disk()).isSuperset(of: titles("remote-3", "local-3", "remote-2", "local-2")) && titles(top.store) == titles(disk()),
      "a local save racing an in-flight scan keeps both the remote and the local addition")
checkResponsive("racing scan and deferred save leave the main run loop responsive")

// 4. iCloud keeps a concurrent peer revision that never saw this device's last two saves.
let peerStart = disk()
top.toggleTask(key: today, category: 2, id: row(top.store, "local-2")!.id, settings: settings.settings)
top.removeTask(key: today, category: 1, id: row(top.store, "remote-1")!.id, settings: settings.settings)
check(row(disk(), "remote-1") == nil && row(disk(), "local-2")?.isCompleted == true, "local completion and deletion were written")
peerWrite(from: peerStart) { store in
    let day = store.history[today]!
    let index = day.taskGroups[1].firstIndex { $0.title == "remote-1" }!
    store.history[today]!.taskGroups[1][index].title = "remote-1 renamed later"
    store.history[today]!.taskGroups[0].append(peerTask("remote-4"))
}
slowTopReads(true)
sync()
slowTopReads(false)
let afterConflict = disk()
check(row(afterConflict, "local-2")?.isCompleted == true && row(afterConflict, "remote-4") != nil,
      "this device's edits the peer never saw survive alongside the peer's addition")
check(row(afterConflict, "remote-1") == nil && row(afterConflict, "remote-1 renamed later") == nil &&
      row(top.store, "remote-1 renamed later") == nil, "delete wins over the peer's later rename of the deleted task")
checkResponsive("concurrent-revision merge leaves the main run loop responsive")

// 5. An older app version rewrites the file without merge fields (clock, stamps, tombstones).
var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: topURL)) as! [String: Any]
for key in ["writeClock", "taskTombstones", "categoryNamesUpdatedAt"] { legacy[key] = nil }
var history = legacy["history"] as! [String: Any]
var day = history[today] as! [String: Any]
var groups: [[[String: Any]]] = day["taskGroups"] as! [[[String: Any]]]
for g in groups.indices {
    for r in groups[g].indices {
        groups[g][r]["updatedAt"] = nil
        if groups[g][r]["title"] as? String == "local-1" { groups[g][r]["title"] = "local-1 edited by old app" }
    }
}
groups[2].removeAll { $0["title"] as? String == "remote-3" }
day["taskGroups"] = groups
history[today] = day
legacy["history"] = history
try JSONSerialization.data(withJSONObject: legacy).write(to: topURL, options: .atomic)
add("local-5", category: 2)
slowTopReads(true)
sync()
slowTopReads(false)
sync()
let afterLegacy = disk()
check(row(afterLegacy, "local-1 edited by old app") != nil && row(afterLegacy, "remote-3") == nil &&
      row(afterLegacy, "local-5") != nil && afterLegacy.writeClock != nil,
      "an old-format rewrite's edit and delete apply, the local addition survives, and merge fields are restored")
let backupData: Data? = UserDefaults.standard.data(forKey: "habitica_pomodoro_top_three_backup")
let backup: TopThreeStore? = backupData.flatMap { try? JSONDecoder().decode(TopThreeStore.self, from: $0) }
check(backup.flatMap { row($0, "local-5") } != nil, "UserDefaults backup still receives every local save")
checkResponsive("old-format merge leaves the main run loop responsive")

heartbeat.invalidate()
check(beats > 0 && maxGap < fixtureMaxMainGap, "all delayed-read merge scenarios leave the main run loop responsive")
print(String(format: "TOPTHREE_MERGE_MONITOR_SUITE %@ failures=%d main_max_gap=%.3fs beats=%d delayed_reads=%llu",
             failures == 0 ? "PASS" : "FAIL", failures, maxGap, beats, delayedReadCount()))
exit(failures == 0 ? 0 : 1)
