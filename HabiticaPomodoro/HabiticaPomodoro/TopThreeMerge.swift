import Foundation

/// Pure reconciliation of two Top3 stores (no I/O, no managers), used when this device saves or
/// adopts a file that another device changed since this device last read or wrote it.
///
/// - Base: the newest snapshot this device adopted or wrote whose write clock the remote
///   dominates, i.e. a version the remote writer provably started from. A file rewritten by an
///   older app version (no clock) uses the newest snapshot for task content and no base for cloud
///   markers. Without any base the merge is a two-way union.
/// - Rows are matched per logical day and task UUID. A field changed on one side wins; a field
///   changed on both sides takes the side with the newer `updatedAt` (the disk side on ties).
/// - Delete wins: a row present in the base but missing on one side, or an active row whose UUID
///   has a tombstone, is removed even when the other side edited it. A removal is confirmed by
///   the user and already queued an irreversible Habitica DELETE whose tombstone would leave a
///   resurrected row unsyncable (or duplicated as a new todo).
/// - Cloud state never drops a create marker or delete tombstone unless the base proves the
///   other side settled it after seeing it; deletion queues are unions.
/// - Ordering keeps the disk order and appends rows only this device has, so a second merge of
///   an already merged file is a no-op and devices stop rewriting each other's files.
enum TopThreeMerge {
    struct Key: Hashable {
        let id: UUID
        let ordinal: Int // a malformed duplicate UUID in one day is kept as a separate row
    }

    struct Row {
        var task: TopThreeTask
        var group: Int
    }

    // MARK: Base selection

    static func dominates(_ clock: [String: Int]?, _ other: [String: Int]?) -> Bool {
        (other ?? [:]).allSatisfy { (clock?[$0.key] ?? 0) >= $0.value }
    }

    /// `snapshots` are ordered oldest to newest. A clock-less (pre-upgrade) snapshot is never a
    /// base for a clocked remote: an empty clock is "seen" by anyone, even a device that wrote a
    /// fresh store before receiving this file, which would turn every row into a deletion.
    static func bases(for remote: TopThreeStore, snapshots: [TopThreeStore]) -> (content: TopThreeStore?, cloud: TopThreeStore?) {
        guard let clock = remote.writeClock else { return (snapshots.last, nil) }
        let base = snapshots.last { $0.writeClock != nil && dominates(clock, $0.writeClock) }
        return (base, base)
    }

    static func merge(local: TopThreeStore, remote: TopThreeStore, snapshots: [TopThreeStore]) -> TopThreeStore {
        let base = bases(for: remote, snapshots: snapshots)
        return merge(base: base.content, cloudBase: base.cloud, local: local, remote: remote)
    }

    /// True when the backup holds saves of this device that the disk revision never received.
    static func hasUnwrittenLocalRevision(backup: TopThreeStore, disk: TopThreeStore, device: String) -> Bool {
        guard let diskClock = disk.writeClock else { return false }
        return (backup.writeClock?[device] ?? 0) > (diskClock[device] ?? 0)
    }

    static func advancing(_ clock: [String: Int]?, device: String) -> [String: Int] {
        var clock = clock ?? [:]
        clock[device, default: 0] += 1
        return clock
    }

    /// Equality ignoring dictionary order and the write clock.
    static func sameContent(_ lhs: TopThreeStore, _ rhs: TopThreeStore) -> Bool {
        var lhs = lhs, rhs = rhs
        lhs.writeClock = nil
        rhs.writeClock = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    // MARK: Local change stamps

    /// Stamp every user-visible change made since `previous` and tombstone removed active rows.
    /// Centralized here so every mutation path (UI, Habitica import, migrations) is covered.
    static func stampLocalChanges(_ store: inout TopThreeStore, since previous: TopThreeStore, at now: Date) {
        for index in store.categoryNames.indices
        where index >= previous.categoryNames.count || previous.categoryNames[index] != store.categoryNames[index] {
            while store.categoryNamesUpdatedAt.count <= index { store.categoryNamesUpdatedAt.append(.distantPast) }
            store.categoryNamesUpdatedAt[index] = now
        }
        var removed = Set<UUID>()
        for dayKey in Set(store.history.keys).union(previous.history.keys) {
            let before = previous.history[dayKey]
            guard before?.taskGroups != store.history[dayKey]?.taskGroups else { continue }
            let old = rows(of: before).rows
            let current = rows(of: store.history[dayKey])
            if var day = store.history[dayKey] {
                for (group, keys) in current.order.enumerated() {
                    for (position, key) in keys.enumerated() {
                        let task = day.taskGroups[group][position]
                        if let prior = old[key], prior.group == group, prior.task.title == task.title,
                           prior.task.isCompleted == task.isCompleted, prior.task.movedToToday == task.movedToToday { continue }
                        day.taskGroups[group][position].updatedAt = now
                    }
                }
                store.history[dayKey] = day
            }
            for (key, row) in old where current.rows[key] == nil && !row.task.movedToToday { removed.insert(key.id) }
        }
        guard !removed.isEmpty else { return }
        // A move or category change keeps an active row with the same UUID; only true removals tombstone.
        let active = Set(store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }.filter { !$0.movedToToday }.map(\.id))
        for id in removed.subtracting(active) where store.taskTombstones[id.uuidString] == nil {
            store.taskTombstones[id.uuidString] = now
        }
    }

    // MARK: Merge

    static func merge(base: TopThreeStore?, cloudBase: TopThreeStore?, local: TopThreeStore, remote: TopThreeStore) -> TopThreeStore {
        var result = TopThreeStore()
        (result.categoryNames, result.categoryNamesUpdatedAt) = mergeCategoryNames(base: base, local: local, remote: remote)
        result.taskTombstones = local.taskTombstones.merging(remote.taskTombstones) { max($0, $1) }
        for dayKey in Set(local.history.keys).union(remote.history.keys) {
            result.history[dayKey] = mergeDay(
                dayKey, base: base?.history[dayKey], cloudBase: cloudBase?.history[dayKey],
                local: local.history[dayKey], remote: remote.history[dayKey],
                tombstones: result.taskTombstones,
                names: (local.categoryNames, remote.categoryNames, result.categoryNames))
        }
        archiveDuplicateMoves(in: &result)
        mergeCloudState(into: &result, base: base, cloudBase: cloudBase, local: local, remote: remote)
        result.writeClock = (local.writeClock ?? [:]).merging(remote.writeClock ?? [:]) { max($0, $1) }
        return result
    }

    /// Concurrent carry-overs can place one UUID on different days. Keep the most
    /// recently moved copy active and retain the others as read-only history.
    private static func archiveDuplicateMoves(in store: inout TopThreeStore) {
        var active: [UUID: (date: String, stamp: Date)] = [:]
        var duplicates = Set<UUID>()
        for (date, day) in store.history {
            for task in day.taskGroups.joined() where !task.movedToToday {
                let stamp = task.updatedAt ?? .distantPast
                if let current = active[task.id] {
                    if current.date != date { duplicates.insert(task.id) }
                    if current.stamp > stamp || (current.stamp == stamp && current.date >= date) { continue }
                }
                active[task.id] = (date, stamp)
            }
        }
        guard !duplicates.isEmpty else { return }
        for (date, var day) in store.history {
            for category in day.taskGroups.indices {
                for index in day.taskGroups[category].indices {
                    let id = day.taskGroups[category][index].id
                    if duplicates.contains(id), active[id]?.date != date {
                        day.taskGroups[category][index].movedToToday = true
                    }
                }
            }
            store.history[date] = day
        }
    }

    /// Rows of one day in layout order. Active rows claim ordinal 0, so archiving a row keeps its key.
    static func rows(of day: TopThreeDay?) -> (rows: [Key: Row], order: [[Key]]) {
        guard let day = day else { return ([:], []) }
        var keys = day.taskGroups.map { [Key?](repeating: nil, count: $0.count) }
        var seen: [UUID: Int] = [:]
        for archived in [false, true] {
            for (group, tasks) in day.taskGroups.enumerated() {
                for (position, task) in tasks.enumerated() where task.movedToToday == archived {
                    keys[group][position] = Key(id: task.id, ordinal: seen[task.id, default: 0])
                    seen[task.id, default: 0] += 1
                }
            }
        }
        var rows: [Key: Row] = [:]
        for (group, tasks) in day.taskGroups.enumerated() {
            for (position, task) in tasks.enumerated() { rows[keys[group][position]!] = Row(task: task, group: group) }
        }
        return (rows, keys.map { $0.map { $0! } })
    }

    /// Changes made on one side win. Without a base, or when both sides changed, `conflict` decides.
    private static func resolve<T: Equatable>(_ local: T, _ remote: T, base: T?, conflict: (T, T) -> T) -> T {
        if local == remote { return local }
        if let base = base {
            if base == local { return remote }
            if base == remote { return local }
        }
        return conflict(local, remote)
    }

    private static func mergeDay(
        _ dayKey: String, base: TopThreeDay?, cloudBase: TopThreeDay?, local: TopThreeDay?, remote: TopThreeDay?,
        tombstones: [String: Date], names: (local: [String], remote: [String], merged: [String])
    ) -> TopThreeDay {
        let l = rows(of: local), r = rows(of: remote)
        let b = rows(of: base).rows, cb = rows(of: cloudBase).rows
        var merged: [Key: Row] = [:]
        for key in Set(l.rows.keys).union(r.rows.keys) {
            let row: Row
            switch (l.rows[key], r.rows[key]) {
            case let (lv?, rv?):
                row = mergeRow(lv, rv, base: b[key], cloudBase: cb[key], names: names)
            case let (lv?, nil):
                guard b[key] == nil else { continue } // the disk side deleted it after seeing it
                row = lv
            case let (nil, rv?):
                guard b[key] == nil else { continue } // this device deleted it after seeing it
                row = rv
            default:
                continue
            }
            if !row.task.movedToToday, tombstones[key.id.uuidString] != nil { continue }
            merged[key] = row
        }
        let needed = (merged.values.map(\.group).max() ?? -1) + 1
        var groups = [[TopThreeTask]](repeating: [], count: max(local?.taskGroups.count ?? 0, remote?.taskGroups.count ?? 0, needed))
        var placed = Set<Key>()
        func place(_ key: Key) {
            guard let row = merged[key], placed.insert(key).inserted else { return }
            groups[row.group].append(row.task)
        }
        for (group, keys) in r.order.enumerated() { keys.filter { merged[$0]?.group == group }.forEach(place) }
        l.order.joined().forEach(place)
        r.order.joined().forEach(place)
        return TopThreeDay(date: local?.date ?? remote?.date ?? dayKey, taskGroups: groups)
    }

    private static func mergeRow(_ l: Row, _ r: Row, base b: Row?, cloudBase cb: Row?,
                                 names: (local: [String], remote: [String], merged: [String])) -> Row {
        let localNewer = (l.task.updatedAt ?? .distantPast) > (r.task.updatedAt ?? .distantPast)
        func field<T: Equatable>(_ value: (Row) -> T) -> T {
            resolve(value(l), value(r), base: b.map(value)) { localNewer ? $0 : $1 }
        }
        var task = l.task
        task.title = field { $0.task.title }
        task.isCompleted = field { $0.task.isCompleted }
        task.movedToToday = field { $0.task.movedToToday }
        let group = field { $0.group }
        task.updatedAt = [l.task.updatedAt, r.task.updatedAt].compactMap { $0 }.max()

        // Keep a cloud ID and its owner together, so an edit from another account
        // cannot redirect a later update or deletion to the wrong owner.
        let owner = resolve(l.task.cloudAccount, r.task.cloudAccount, base: cb.map { $0.task.cloudAccount }) { $0 ?? $1 }
        let bindings = [r.task, l.task].filter { $0.habiticaTaskId != nil }
        if let bound = bindings.first(where: { $0.cloudAccount == owner }) ?? bindings.first {
            task.habiticaTaskId = bound.habiticaTaskId
            task.cloudAccount = bound.cloudAccount
            task.cloudCreateAttempt = nil
        } else {
            task.cloudAccount = owner
            let localAttempt = l.task.cloudAccount == owner ? l.task.cloudCreateAttempt : nil
            let remoteAttempt = r.task.cloudAccount == owner ? r.task.cloudCreateAttempt : nil
            let baseAttempt = cb.flatMap { $0.task.cloudAccount == owner ? Optional($0.task.cloudCreateAttempt) : nil }
            task.cloudCreateAttempt = resolve(localAttempt, remoteAttempt, base: baseAttempt) { $0 ?? $1 }
        }

        // Pending unless one side already verified exactly this content (title, completion, ID,
        // category name) on Habitica; pushing it again would be redundant, skipping it would not.
        func name(_ list: [String], _ index: Int) -> String? { list.indices.contains(index) ? list[index] : nil }
        func verified(_ side: Row, _ sideNames: [String]) -> Bool {
            !side.task.syncPending && side.task.title == task.title && side.task.isCompleted == task.isCompleted &&
                side.task.habiticaTaskId == task.habiticaTaskId && side.task.cloudAccount == task.cloudAccount && name(sideNames, side.group) == name(names.merged, group)
        }
        task.syncPending = !(verified(l, names.local) || verified(r, names.remote))
        return Row(task: task, group: group)
    }

    // MARK: Category names

    private static func mergeCategoryNames(base: TopThreeStore?, local: TopThreeStore, remote: TopThreeStore) -> ([String], [Date]) {
        func value(_ store: TopThreeStore?, _ index: Int) -> String? {
            guard let store = store, store.categoryNames.indices.contains(index) else { return nil }
            return store.categoryNames[index]
        }
        func stamp(_ store: TopThreeStore, _ index: Int) -> Date {
            store.categoryNamesUpdatedAt.indices.contains(index) ? store.categoryNamesUpdatedAt[index] : .distantPast
        }
        let count = max(local.categoryNames.count, remote.categoryNames.count)
        var names: [String] = []
        var stamps: [Date] = []
        for index in 0..<count {
            let lv = value(local, index), rv = value(remote, index)
            let newerLocal = stamp(local, index) > stamp(remote, index)
            names.append(resolve(lv, rv, base: value(base, index)) { newerLocal ? $0 ?? $1 : $1 ?? $0 } ?? "")
            stamps.append(max(stamp(local, index), stamp(remote, index)))
        }
        // Two devices may rename different categories to one name. The newer claim keeps it; the
        // other falls back to a previous name, as setCategoryName would have refused the duplicate.
        var claimed = Set<String>()
        for index in names.indices.sorted(by: { stamps[$0] != stamps[$1] ? stamps[$0] > stamps[$1] : $0 < $1 }) {
            var name = names[index]
            if claimed.contains(name) {
                let others = Set(names.enumerated().filter { $0.offset != index }.map(\.element)).union(claimed)
                let fallback = [value(base, index), value(local, index), value(remote, index)].compactMap { $0 }
                    .first { !$0.isEmpty && !others.contains($0) }
                var suffix = 2
                name = fallback ?? names[index]
                while others.contains(name) { name = "\(names[index]) \(suffix)"; suffix += 1 }
                names[index] = name
            }
            claimed.insert(name)
        }
        while stamps.last == .distantPast { stamps.removeLast() }
        return (names, stamps)
    }

    // MARK: Cloud state

    /// Owner partitions. The store-level fields are authoritative for the active owner ("" = unowned legacy).
    private static func partitions(_ store: TopThreeStore) -> [String: TopThreeCloudState] {
        var states = store.cloudStates
        states[store.cloudAccount] = TopThreeCloudState(
            categoryTagIds: store.categoryTagIds, deletedCloudIds: store.deletedCloudIds,
            confirmedDeletedCloudIds: store.confirmedDeletedCloudIds,
            pendingTagRenames: store.pendingTagRenames, deletedCreateAttempts: store.deletedCreateAttempts)
        return states
    }

    private static func union<T: Equatable>(_ first: [T], _ second: [T]) -> [T] {
        var out: [T] = []
        for item in first + second where !out.contains(item) { out.append(item) }
        return out
    }

    private static func mergeMap(_ l: [String: String], _ r: [String: String], base: [String: String]?,
                                 conflict: (String?, String?) -> String?) -> [String: String] {
        var out: [String: String] = [:]
        for key in Set(l.keys).union(r.keys) {
            out[key] = resolve(l[key], r[key], base: base.map { $0[key] }, conflict: conflict)
        }
        return out
    }

    private static func mergePartition(_ l: TopThreeCloudState?, _ r: TopThreeCloudState?, base: TopThreeCloudState?,
                                       names: [String]) -> TopThreeCloudState {
        guard let l = l else { return r ?? TopThreeCloudState() }
        guard let r = r else { return l }
        var state = TopThreeCloudState()
        state.categoryTagIds = mergeMap(l.categoryTagIds, r.categoryTagIds, base: base?.categoryTagIds) { $0 ?? $1 }
        state.pendingTagRenames = mergeMap(l.pendingTagRenames, r.pendingTagRenames, base: base?.pendingTagRenames) {
            [$0, $1].compactMap { $0 }.first(where: names.contains) ?? $0 ?? $1
        }
        state.deletedCloudIds = union(r.deletedCloudIds, l.deletedCloudIds)
        state.confirmedDeletedCloudIds = union(r.confirmedDeletedCloudIds, l.confirmedDeletedCloudIds)
        // Drop a marker only when the base proves the other side settled it after seeing it.
        let settledBy = { (side: [DeletedCloudCreateAttempt], marker: DeletedCloudCreateAttempt) in
            !side.contains(marker) && (base?.deletedCreateAttempts.contains(marker) ?? false)
        }
        state.deletedCreateAttempts = union(r.deletedCreateAttempts.filter { !settledBy(l.deletedCreateAttempts, $0) },
                                            l.deletedCreateAttempts.filter { !settledBy(r.deletedCreateAttempts, $0) })
        return state
    }

    private static func mergeCloudState(into result: inout TopThreeStore, base: TopThreeStore?, cloudBase: TopThreeStore?,
                                        local: TopThreeStore, remote: TopThreeStore) {
        result.cloudAccount = resolve(local.cloudAccount, remote.cloudAccount, base: base?.cloudAccount) { $0.isEmpty ? $1 : $0 }
        let l = partitions(local), r = partitions(remote)
        let b = cloudBase.map(partitions)
        var states: [String: TopThreeCloudState] = [:]
        for owner in Set(l.keys).union(r.keys) {
            // A partition missing from an existing base was never seen there: merge as additions.
            let ownerBase = b.map { $0[owner] ?? TopThreeCloudState() }
            states[owner] = mergePartition(l[owner], r[owner], base: ownerBase, names: result.categoryNames)
        }
        let unowned = states.removeValue(forKey: "")
        if !result.cloudAccount.isEmpty, let unowned = unowned {
            // Same claim prepareCloudAccount makes for pre-ownership state.
            states[result.cloudAccount] = mergePartition(states[result.cloudAccount], unowned, base: nil, names: result.categoryNames)
        }
        let current = Set(result.categoryNames)
        for owner in Array(states.keys) {
            var state = states[owner]!
            // After both sides renamed one category, drop the losing name that still maps to the same tag.
            for (name, tag) in state.categoryTagIds where !current.contains(name) &&
                current.contains(where: { state.categoryTagIds[$0] == tag }) {
                state.categoryTagIds[name] = nil
            }
            for (tag, desired) in state.pendingTagRenames {
                if let name = result.categoryNames.first(where: { state.categoryTagIds[$0] == tag }), name != desired {
                    state.pendingTagRenames[tag] = name
                }
            }
            states[owner] = state
        }
        let active = result.cloudAccount.isEmpty ? (unowned ?? TopThreeCloudState()) : (states[result.cloudAccount] ?? TopThreeCloudState())
        result.categoryTagIds = active.categoryTagIds
        result.deletedCloudIds = active.deletedCloudIds
        result.confirmedDeletedCloudIds = active.confirmedDeletedCloudIds
        result.pendingTagRenames = active.pendingTagRenames
        result.deletedCreateAttempts = active.deletedCreateAttempts
        result.cloudStates = states
    }
}
