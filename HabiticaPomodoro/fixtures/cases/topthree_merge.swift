import Foundation

// Pure TopThreeMerge rules on synthetic stores, then one real TopThreeManager launch that
// recovers an unwritten local revision. No network: Habitica stays disabled with no account.
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS \(label)") } else { print("FAIL \(label)"); failures += 1 }
}

let fixture = PomodoroDataDir.resolvedURL.standardizedFileURL
let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
let d1 = "2026-11-19", d2 = "2026-11-20"
let owner = "fixture-uid|https://habitica.com/api/v3/"

func task(_ title: String, at time: Double? = 0) -> TopThreeTask {
    var task = TopThreeTask(title: title)
    task.updatedAt = time.map(at)
    return task
}
func makeStore(_ days: [String: [[TopThreeTask]]], clock: [String: Int]? = nil) -> TopThreeStore {
    var store = TopThreeStore()
    for (key, groups) in days { store.history[key] = TopThreeDay(date: key, taskGroups: groups) }
    store.writeClock = clock
    return store
}
func titles(_ store: TopThreeStore, _ day: String, _ group: Int) -> [String] {
    guard let groups = store.history[day]?.taskGroups, groups.indices.contains(group) else { return [] }
    return groups[group].map(\.title)
}
func rows(_ store: TopThreeStore, _ id: UUID) -> [TopThreeTask] {
    store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }.filter { $0.id == id }
}
func merge(_ base: TopThreeStore?, _ local: TopThreeStore, _ remote: TopThreeStore) -> TopThreeStore {
    TopThreeMerge.merge(base: base, cloudBase: base, local: local, remote: remote)
}
func mirror(_ store: inout TopThreeStore) {
    store.cloudStates[store.cloudAccount] = TopThreeCloudState(
        categoryTagIds: store.categoryTagIds, deletedCloudIds: store.deletedCloudIds,
        confirmedDeletedCloudIds: store.confirmedDeletedCloudIds,
        pendingTagRenames: store.pendingTagRenames, deletedCreateAttempts: store.deletedCreateAttempts)
}

// MARK: Both sides add
do {
    let a = task("a")
    let base = makeStore([d1: [[a], [], []]])
    let local = makeStore([d1: [[a, task("l1", at: 10)], [], []]])
    let remote = makeStore([d1: [[a, task("r1", at: 11)], [], []], d2: [[], [], [task("r2", at: 12)]]])
    let merged = merge(base, local, remote)
    check(titles(merged, d1, 0) == ["a", "r1", "l1"] && titles(merged, d2, 2) == ["r2"],
          "additions on both sides survive (disk order first, then this device's rows)")
    let adoptedElsewhere = merge(remote, remote, merged)
    check(TopThreeMerge.sameContent(adoptedElsewhere, merged),
          "the other device adopts the merged file unchanged, so neither device rewrites it again")
    check(TopThreeMerge.sameContent(merge(merged, merged, merged), merged), "merging a revision with itself is a no-op")
    let b = task("b")
    let crowded = merge(makeStore([d1: [[a, b], [], []]]), makeStore([d1: [[a, b, task("c", at: 13)], [], []]]),
                        makeStore([d1: [[a, b, task("d", at: 14)], [], []]]))
    check(titles(crowded, d1, 0) == ["a", "b", "d", "c"],
          "a fixed category over the 3-task limit after a merge keeps every task (UI add limits still apply)")
}

// MARK: Edit vs edit
do {
    let x = task("x", at: 0)
    let base = makeStore([d1: [[x], [], []]])
    var lx = x; lx.title = "x local"; lx.updatedAt = at(20)
    var rx = x; rx.isCompleted = true; rx.updatedAt = at(10)
    let mx = merge(base, makeStore([d1: [[lx], [], []]]), makeStore([d1: [[rx], [], []]])).history[d1]!.taskGroups[0][0]
    check(mx.title == "x local" && mx.isCompleted && mx.updatedAt == at(20),
          "edits to different fields of one task both survive; updatedAt is the newer edit")
    func bothTitled(local: Double, remote: Double) -> String {
        var l = x; l.title = "L"; l.updatedAt = at(local)
        var r = x; r.title = "R"; r.updatedAt = at(remote)
        return merge(base, makeStore([d1: [[l], [], []]]), makeStore([d1: [[r], [], []]])).history[d1]!.taskGroups[0][0].title
    }
    check(bothTitled(local: 30, remote: 20) == "L" && bothTitled(local: 20, remote: 30) == "R",
          "the same field edited on both sides takes the newer edit (field-level newest wins)")
    check(bothTitled(local: 20, remote: 20) == "R", "an exact timestamp tie keeps the disk revision")
    var moved = x; moved.updatedAt = at(40)
    var done = x; done.isCompleted = true; done.updatedAt = at(41)
    let category = merge(base, makeStore([d1: [[], [moved], []]]), makeStore([d1: [[done], [], []]]))
    check(titles(category, d1, 0).isEmpty && category.history[d1]!.taskGroups[1].first?.isCompleted == true,
          "a category move on one side and a completion on the other both apply")
    let legacyLocal = TopThreeTask(id: x.id, title: "old local")
    let legacyRemote = TopThreeTask(id: x.id, title: "old remote")
    let unstamped = merge(nil, makeStore([d1: [[legacyLocal], [], []]]), makeStore([d1: [[legacyRemote], [], []]]))
    check(titles(unstamped, d1, 0) == ["old remote"], "old rows without timestamps and without a base keep the disk value")
}

// Concurrent carry-overs of one UUID must leave a single active task.
do {
    let original = task("carry over")
    var archive = original; archive.movedToToday = true
    var localMove = original; localMove.updatedAt = at(10)
    var remoteMove = original; remoteMove.updatedAt = at(20)
    let later = "2026-11-21"
    let base = makeStore([d1: [[original], [], []]])
    let local = makeStore([d1: [[archive], [], []], d2: [[localMove], [], []]])
    let remote = makeStore([d1: [[archive], [], []], later: [[remoteMove], [], []]])
    let merged = merge(base, local, remote)
    check(merged.history[d2]?.taskGroups[0].first?.movedToToday == true &&
          merged.history[later]?.taskGroups[0].first?.movedToToday == false &&
          rows(merged, original.id).filter { !$0.movedToToday }.count == 1,
          "concurrent carry-overs leave the newest move active and keep both older rows in history")
}

// MARK: Delete vs edit (delete wins)
do {
    let x = task("x"), y = task("y")
    let base = makeStore([d1: [[x, y], [], []]])
    var deleted = base
    deleted.history[d1]!.taskGroups[0].removeAll { $0.id == x.id }
    TopThreeMerge.stampLocalChanges(&deleted, since: base, at: at(5))
    check(deleted.taskTombstones[x.id.uuidString] == at(5), "a local removal records a timestamped tombstone")
    var edited = base
    edited.history[d1]!.taskGroups[0][0].title = "x edited after the delete"
    edited.history[d1]!.taskGroups[0][0].updatedAt = at(50)
    check(rows(merge(base, deleted, edited), x.id).isEmpty && rows(merge(base, edited, deleted), x.id).isEmpty,
          "delete wins over a newer concurrent edit, whichever device merges")
    check(rows(merge(nil, edited, deleted), x.id).isEmpty, "a tombstone deletes the row even without a common base")
    check(titles(merge(base, edited, deleted), d1, 0) == ["y"], "other rows of the day are untouched by the delete")

    var archived = x; archived.movedToToday = true
    let history = makeStore([d1: [[archived], [], []], d2: [[x], [], []]])
    var removedToday = history
    removedToday.history[d2]!.taskGroups[0] = []
    TopThreeMerge.stampLocalChanges(&removedToday, since: history, at: at(6))
    let afterRemoval = merge(history, history, removedToday)
    check(rows(afterRemoval, x.id).map(\.movedToToday) == [true],
          "deleting today's row keeps the archived history copy (same as a local delete)")
    var movedToToday = base
    movedToToday.history[d1]!.taskGroups[0][0].movedToToday = true
    movedToToday.history[d2] = TopThreeDay(date: d2, taskGroups: [[x], [], []])
    TopThreeMerge.stampLocalChanges(&movedToToday, since: base, at: at(7))
    check(rows(merge(base, movedToToday, deleted), x.id).isEmpty,
          "delete wins over a concurrent move to today: no active or archived copy survives")
}

// MARK: Category rename + addition, and cloud tag state
do {
    var a = TopThreeTask(title: "a", habiticaTaskId: "h-a", cloudAccount: owner)
    a.updatedAt = at(0)
    var base = makeStore([d1: [[a], [], []]])
    base.cloudAccount = owner
    base.categoryTagIds = ["Work": "tag-1"]
    mirror(&base)
    var renamed = base
    renamed.categoryNames[0] = "Job"
    renamed.history[d1]!.taskGroups[0][0].syncPending = true
    renamed.categoryTagIds = ["Job": "tag-1"]
    renamed.pendingTagRenames = ["tag-1": "Job"]
    mirror(&renamed)
    TopThreeMerge.stampLocalChanges(&renamed, since: base, at: at(30))
    var added = base
    var r = TopThreeTask(title: "r", syncPending: true, cloudAccount: owner)
    r.updatedAt = at(31)
    added.history[d1]!.taskGroups[0].append(r)
    let merged = merge(base, renamed, added)
    check(merged.categoryNames[0] == "Job" && titles(merged, d1, 0) == ["a", "r"],
          "a category rename on one side and an addition on the other both apply")
    check(merged.categoryTagIds == ["Job": "tag-1"] && merged.pendingTagRenames == ["tag-1": "Job"] &&
          merged.cloudStates[owner]?.categoryTagIds == ["Job": "tag-1"],
          "the renamed category keeps a single tag mapping and its pending Habitica rename")
    check(merged.history[d1]!.taskGroups[0].allSatisfy(\.syncPending),
          "rows verified under the old category name stay pending for re-upload")
    var office = base
    office.categoryNames[0] = "Office"
    office.categoryTagIds = ["Office": "tag-1"]
    office.pendingTagRenames = ["tag-1": "Office"]
    mirror(&office)
    TopThreeMerge.stampLocalChanges(&office, since: base, at: at(40))
    let both = merge(base, renamed, office)
    check(both.categoryNames[0] == "Office" && both.categoryTagIds == ["Office": "tag-1"] &&
          both.pendingTagRenames == ["tag-1": "Office"],
          "concurrent renames of one category keep the newer name with one consistent tag mapping")
    var home1 = base
    home1.categoryNames[1] = "Home"
    TopThreeMerge.stampLocalChanges(&home1, since: base, at: at(50))
    var home2 = base
    home2.categoryNames[2] = "Home"
    TopThreeMerge.stampLocalChanges(&home2, since: base, at: at(60))
    check(merge(base, home1, home2).categoryNames == ["Work", "MyOwn", "Home"],
          "two categories renamed to one name keep the newer claim; the other keeps its previous name")
}

// MARK: Cloud markers, tombstones and owner partitions
do {
    let other = "other-uid|https://habitica.com/api/v3/"
    func attempt(_ title: String) -> CloudCreateAttempt {
        CloudCreateAttempt(title: title, notes: "From HabiticaPomodoro Top3 · Work · \(d1)", tags: ["tag-1"])
    }
    let m1 = DeletedCloudCreateAttempt(id: UUID(), attempt: attempt("m1"))
    let m2 = DeletedCloudCreateAttempt(id: UUID(), attempt: attempt("m2"))
    let m3 = DeletedCloudCreateAttempt(id: UUID(), attempt: attempt("m3"))
    var base = makeStore([d1: [[], [], []]], clock: ["me": 1])
    base.cloudAccount = owner
    base.deletedCreateAttempts = [m3]
    mirror(&base)
    var local = base
    local.deletedCloudIds = ["d1"]
    local.confirmedDeletedCloudIds = ["d1"]
    local.deletedCreateAttempts = [m3, m1]
    local.taskTombstones = ["local-tomb": at(1)]
    local.writeClock = ["me": 2]
    mirror(&local)
    var remote = base
    remote.deletedCloudIds = ["d2", "d3"] // d3: the other device resolved m3 into a delete tombstone
    remote.deletedCreateAttempts = [m2]
    remote.taskTombstones = ["remote-tomb": at(2)]
    remote.cloudStates[other] = TopThreeCloudState(deletedCloudIds: ["other-gone"])
    remote.writeClock = ["me": 1, "peer": 1]
    mirror(&remote)
    let merged = TopThreeMerge.merge(local: local, remote: remote, snapshots: [base])
    check(Set(merged.deletedCloudIds) == ["d1", "d2", "d3"] && merged.confirmedDeletedCloudIds == ["d1"] &&
          Set(merged.taskTombstones.keys) == ["local-tomb", "remote-tomb"],
          "delete tombstones, acknowledgements and task tombstones are unions")
    check(merged.deletedCreateAttempts.contains(m1) && merged.deletedCreateAttempts.contains(m2) &&
          !merged.deletedCreateAttempts.contains(m3),
          "unresolved create markers from both sides survive; one the other device settled after seeing it retires")
    check(merged.cloudStates[other]?.deletedCloudIds == ["other-gone"] &&
          merged.cloudStates[owner]?.deletedCreateAttempts == merged.deletedCreateAttempts,
          "another owner's partition is preserved and the active owner mirror matches")
    var legacyRemote = remote
    legacyRemote.writeClock = nil
    let legacy = TopThreeMerge.merge(local: local, remote: legacyRemote, snapshots: [base])
    check([m1, m2, m3].allSatisfy(legacy.deletedCreateAttempts.contains),
          "a file rewritten by an older app version cannot retire a create marker")

    var t = TopThreeTask(title: "t", syncPending: true, cloudAccount: owner)
    t.updatedAt = at(0)
    var marked = t
    marked.cloudCreateAttempt = attempt("t")
    var bound = t
    bound.habiticaTaskId = "h-t"
    let plain = makeStore([d1: [[t], [], []]])
    let withMarker = makeStore([d1: [[marked], [], []]])
    check(merge(plain, withMarker, plain).history[d1]!.taskGroups[0][0].cloudCreateAttempt == attempt("t") &&
          merge(plain, plain, withMarker).history[d1]!.taskGroups[0][0].cloudCreateAttempt == attempt("t"),
          "a pending create marker the other side never saw is kept")
    let binding = merge(withMarker, withMarker, makeStore([d1: [[bound], [], []]])).history[d1]!.taskGroups[0][0]
    check(binding.habiticaTaskId == "h-t" && binding.cloudCreateAttempt == nil, "a remote binding settles the create marker")
    check(merge(withMarker, withMarker, plain).history[d1]!.taskGroups[0][0].cloudCreateAttempt == nil &&
          merge(nil, withMarker, plain).history[d1]!.taskGroups[0][0].cloudCreateAttempt == attempt("t"),
          "a marker cleared after being seen is not resurrected; without a base it is kept")
    var elsewhere = t
    elsewhere.cloudAccount = other
    let crossAccount = merge(plain, makeStore([d1: [[bound], [], []]]),
                             makeStore([d1: [[elsewhere], [], []]])).history[d1]!.taskGroups[0][0]
    check(crossAccount.habiticaTaskId == "h-t" && crossAccount.cloudAccount == owner,
          "a concurrent owner edit cannot reassign a bound ID to another account")
    var verified = bound
    verified.syncPending = false
    var stale = bound
    stale.syncPending = true
    check(!merge(nil, makeStore([d1: [[verified], [], []]]), makeStore([d1: [[stale], [], []]])).history[d1]!.taskGroups[0][0].syncPending,
          "identical content already verified on one side is not pushed again")
}

// MARK: Old-format files and base selection
do {
    let id = UUID()
    let legacyJSON = """
    {"categoryNames":["Work","MyOwn","Chores"],"categoryTagIds":{},"deletedCloudIds":[],"cloudAccount":"",
     "history":{"\(d1)":{"date":"\(d1)","taskGroups":[[{"id":"\(id.uuidString)","title":"old","isCompleted":false,
     "movedToToday":false,"syncPending":true}],[],[]]}}}
    """
    let legacy = try! JSONDecoder().decode(TopThreeStore.self, from: Data(legacyJSON.utf8))
    check(legacy.writeClock == nil && legacy.taskTombstones.isEmpty && legacy.categoryNamesUpdatedAt.isEmpty &&
          legacy.history[d1]?.taskGroups[0][0].updatedAt == nil && legacy.history[d1]?.taskGroups[0][0].id == id,
          "an old-format file without merge fields decodes (missing timestamps = distant past)")
    var modern = legacy
    modern.history[d1]!.taskGroups[0][0].updatedAt = at(3)
    modern.taskTombstones = [UUID().uuidString: at(4)]
    modern.categoryNamesUpdatedAt = [at(5)]
    modern.writeClock = ["me": 7]
    let encoded = try! JSONEncoder().encode(modern)
    let decoded = try! JSONDecoder().decode(TopThreeStore.self, from: encoded)
    let object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let row = (((object["history"] as! [String: Any])[d1] as! [String: Any])["taskGroups"] as! [[[String: Any]]])[0][0]
    check(TopThreeMerge.sameContent(decoded, modern) && decoded.writeClock == ["me": 7] &&
          row["title"] as? String == "old" && row["isCompleted"] as? Bool == false && row["movedToToday"] as? Bool == false,
          "merge fields round-trip while the widget's title/isCompleted/movedToToday keys stay unchanged")

    let keep = task("keep"), edit = task("edit", at: 1), drop = task("drop")
    let ours = makeStore([d1: [[keep, edit, drop], [], []]], clock: ["me": 3])
    var oldApp = ours
    oldApp.writeClock = nil
    // The old app drops every field it does not know, including the timestamps.
    oldApp.history[d1]!.taskGroups[0] = [TopThreeTask(id: keep.id, title: "keep"), TopThreeTask(id: edit.id, title: "edited by old app")]
    var local = ours
    local.history[d1]!.taskGroups[0].append(task("mine", at: 9))
    let mergedLegacy = TopThreeMerge.merge(local: local, remote: oldApp, snapshots: [ours])
    check(titles(mergedLegacy, d1, 0) == ["keep", "edited by old app", "mine"],
          "an older app version's edit and delete apply while this device's unsaved row survives")

    let s1 = makeStore([:], clock: ["A": 1]), s2 = makeStore([:], clock: ["A": 2, "B": 1]), s3 = makeStore([:], clock: ["A": 3, "B": 1])
    let snapshots = [s1, s2, s3]
    check(TopThreeMerge.bases(for: makeStore([:], clock: ["A": 2, "B": 2]), snapshots: snapshots).content?.writeClock == s2.writeClock &&
          TopThreeMerge.bases(for: makeStore([:], clock: ["A": 3, "B": 2]), snapshots: snapshots).content?.writeClock == s3.writeClock,
          "the base is the newest snapshot the remote writer has provably seen")
    check(TopThreeMerge.bases(for: makeStore([:], clock: ["B": 5]), snapshots: snapshots).content == nil,
          "a remote that saw none of the snapshots merges without a base")
    let legacyBases = TopThreeMerge.bases(for: makeStore([:]), snapshots: snapshots)
    check(legacyBases.content?.writeClock == s3.writeClock && legacyBases.cloud == nil,
          "an old-format remote uses the newest snapshot for content and no base for cloud markers")
    let preUpgrade = makeStore([d1: [[keep, drop], [], []]])
    let freshDevice = makeStore([d1: [[], [], []]], clock: ["new-phone": 1])
    check(titles(TopThreeMerge.merge(local: preUpgrade, remote: freshDevice, snapshots: [preUpgrade]), d1, 0) == ["keep", "drop"],
          "a device that wrote a fresh store before receiving this file cannot delete rows it never saw")
}

// MARK: Local change stamps
do {
    let x = task("x", at: nil), y = task("y", at: nil), z = task("z", at: nil)
    let before = makeStore([d1: [[x, y], [], [z]]])
    var after = before
    after.history[d1]!.taskGroups[0][0].title = "x2"
    after.history[d1]!.taskGroups[0][1].syncPending = true
    after.history[d1]!.taskGroups[0][1].habiticaTaskId = "h-y"
    after.history[d1]!.taskGroups[2][0].movedToToday = true
    after.history[d2] = TopThreeDay(date: d2, taskGroups: [[], [], [z]])
    after.categoryNames[1] = "Me"
    TopThreeMerge.stampLocalChanges(&after, since: before, at: at(70))
    check(after.history[d1]!.taskGroups[0][0].updatedAt == at(70) && after.history[d1]!.taskGroups[0][1].updatedAt == nil,
          "a title edit is stamped; Habitica sync bookkeeping is not a user edit")
    check(after.history[d1]!.taskGroups[2][0].updatedAt == at(70) && after.history[d2]!.taskGroups[2][0].updatedAt == at(70) &&
          after.taskTombstones.isEmpty && after.categoryNamesUpdatedAt == [.distantPast, at(70)],
          "a move to today is stamped without a tombstone; a rename stamps its category")
    check(TopThreeMerge.hasUnwrittenLocalRevision(backup: makeStore([:], clock: ["me": 5]), disk: makeStore([:], clock: ["me": 4]), device: "me") &&
          !TopThreeMerge.hasUnwrittenLocalRevision(backup: makeStore([:], clock: ["me": 4]), disk: makeStore([:], clock: ["me": 4, "p": 9]), device: "me") &&
          !TopThreeMerge.hasUnwrittenLocalRevision(backup: makeStore([:], clock: ["me": 5]), disk: makeStore([:]), device: "me"),
          "launch recovery triggers only when the disk lacks this device's latest save")
}

// MARK: Real launch recovers a save that never reached disk
do {
    var configuration = UserSettings()
    configuration.connectHabitica = false
    configuration.uid = ""
    configuration.apiToken = ""
    try! JSONEncoder().encode(configuration).write(to: fixture.appendingPathComponent("habitica_pomodoro_settings.json"), options: .atomic)
    let me = TopThreeManager.deviceID
    let shared = task("on disk")
    let disk = makeStore([d1: [[shared, task("other device", at: 20)], [], []]], clock: [me: 4, "peer": 2])
    let backup = makeStore([d1: [[shared, task("deferred local", at: 21)], [], []]], clock: [me: 5])
    let topURL = fixture.appendingPathComponent("habitica_pomodoro_top_three.json")
    try! JSONEncoder().encode(disk).write(to: topURL, options: .atomic)
    UserDefaults.standard.set(try! JSONEncoder().encode(backup), forKey: "habitica_pomodoro_top_three_backup")
    UserDefaults.standard.set(fixture.path, forKey: TopThreeManager.backupDirectoryKey)
    let manager = TopThreeManager.shared
    let written = try! JSONDecoder().decode(TopThreeStore.self, from: Data(contentsOf: topURL))
    check(Set(titles(manager.store, d1, 0)) == ["on disk", "other device", "deferred local"] &&
          Set(titles(written, d1, 0)) == Set(titles(manager.store, d1, 0)) && (written.writeClock?[me] ?? 0) > 5,
          "launch merges a backup save the disk never received and writes the result")
}

print("TOPTHREE_MERGE_SUITE \(failures == 0 ? "PASS" : "FAIL") failures=\(failures)")
exit(failures == 0 ? 0 : 1)
