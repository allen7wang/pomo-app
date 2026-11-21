import Foundation
import Combine
#if os(macOS)
import WidgetKit
#endif

// MARK: - Top Three Manager (当天最重要的三件事 + 琐事，同步 Habitica)
#if os(macOS)
/// 主 App（非沙箱）→ 沙箱 widget 的数据桥。
/// macOS 强制 app extension 沙箱（pkd: "plug-ins must be sandboxed"），widget 无法直读
/// ~/Documents；主 App 把 Top3 快照写入 widget 容器的 Application Support/widget-data.json，
/// widget 在自己沙箱内读取合法。只写 widget 自己的容器，不影响任何其他数据。
enum WidgetBridge {
    static let widgetBundleId = "com.hermes.habitica-pomodoro.TodayTasksWidget"

    static func writeSnapshot(store: TopThreeStore) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(widgetBundleId)/Data/Library/Application Support")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let storeData = try JSONEncoder().encode(store)
            let storeObj = try JSONSerialization.jsonObject(with: storeData)
            let snapshot: [String: Any] = [
                "updatedAt": Date().timeIntervalSince1970,
                "boundaryMinutes": SettingsManager.shared.settings.blockTimeRanges.first?.startMinutes ?? 0,
                "store": storeObj,
            ]
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            try data.write(to: dir.appendingPathComponent("widget-data.json"), options: .atomic)
        } catch {
            print("WidgetBridge snapshot failed: \(error)")
        }
    }
}
#endif

struct UnfinishedTask: Identifiable {
    let dateKey: String
    let category: Int
    let task: TopThreeTask

    var id: UUID { task.id }
}

class TopThreeManager: ObservableObject {
    static let shared = TopThreeManager()

    @Published var store: TopThreeStore { didSet { mutationGeneration += 1 } }
    @Published private(set) var syncInProgress = false
    @Published private(set) var syncMessage: String?
    private var mutationGeneration = 0
    private var syncingTasks = Set<UUID>()
    private var hasDeletionConflict = false

    // 前 2 个分类（Work/MyOwn）固定 3 槽位；第 3 个及以后（琐事）为自由列表
    static let fixedSlotCategories = 2

    private let fileName = "habitica_pomodoro_top_three.json"
    private var fileURL: URL { PomodoroDataDir.fileURL(fileName) }
    private let localBackupKey = "habitica_pomodoro_top_three_backup"
    static let backupDirectoryKey = "habitica_pomodoro_top_three_backup_directory"

    // Concurrent-edit merge (TopThreeMerge). Snapshots are disk revisions this device adopted or
    // wrote in `snapshotsDirectory`, oldest first; a merge uses the newest one the remote has seen.
    private var snapshots: [TopThreeStore] = []
    private var snapshotsDirectory: String?
    private var stampedStore: TopThreeStore?
    private var deferredSave = false
    private var flushRequested = false

    static let deviceID: String = {
        let key = "habitica_pomodoro_device_id"
        if let id = PomodoroDataDir.backupDefaults?.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString
        PomodoroDataDir.backupDefaults?.set(id, forKey: key)
        return id
    }()

    init() {
        let url = PomodoroDataDir.fileURL(fileName)
        var recovered = false
        if let loaded = Self.loadFile(TopThreeStore.self, from: url) {
            store = loaded
            snapshots = [loaded]
            if let backup = Self.unwrittenBackup(over: loaded, in: url.deletingLastPathComponent()) {
                // A deferred or conflict-lost save never reached this revision: merge, don't drop it.
                store = TopThreeMerge.merge(base: nil, cloudBase: nil, local: backup, remote: loaded)
                recovered = true
            }
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: "habitica_pomodoro_top_three_backup"),
                  let decoded = try? JSONDecoder().decode(TopThreeStore.self, from: data) {
            store = decoded
        } else {
            store = TopThreeStore()
        }
        snapshotsDirectory = url.deletingLastPathComponent().standardizedFileURL.path
        stampedStore = store
        var upgraded = store
        if Self.migrate(&upgraded) || recovered {
            store = upgraded
            save()
        }
        #if os(macOS)
        // 首启即写 widget 快照（save() 未触发时 widget 也有数据）
        WidgetBridge.writeSnapshot(store: store)
        #endif
    }

    private static func loadFile<T: Codable>(_ type: T.Type, from url: URL) -> T? {
        do {
            let jsonData = try PomodoroFileChanges.shared.readData(from: url)
            let decoded = try JSONDecoder().decode(type, from: jsonData)
            PomodoroFileChanges.shared.consume(url, data: jsonData)
            return decoded
        } catch {
            return nil
        }
    }

    /// 旧数据升级：补齐琐事分类；清除固定槽位模式遗留的空标题占位任务。
    private static func migrate(_ store: inout TopThreeStore) -> Bool {
        var migrated = false
        if store.categoryNames.count < 3 {
            store.categoryNames.append("Chores")
            migrated = true
        }
        for (key, var day) in store.history {
            var dayChanged = false
            for g in 0..<day.taskGroups.count {
                let before = day.taskGroups[g].count
                day.taskGroups[g].removeAll { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
                if day.taskGroups[g].count != before { dayChanged = true }
            }
            if dayChanged {
                store.history[key] = day
                migrated = true
            }
        }
        return migrated
    }

    private static func unwrittenBackup(over disk: TopThreeStore, in directory: URL) -> TopThreeStore? {
        guard PomodoroDataDir.backupDefaults?.string(forKey: backupDirectoryKey) == directory.standardizedFileURL.path,
              let data = PomodoroDataDir.backupDefaults?.data(forKey: "habitica_pomodoro_top_three_backup"),
              let backup = try? JSONDecoder().decode(TopThreeStore.self, from: data),
              TopThreeMerge.hasUnwrittenLocalRevision(backup: backup, disk: disk, device: deviceID) else { return nil }
        return backup
    }

    private func rememberSnapshot(_ snapshot: TopThreeStore, directory: URL) {
        let path = directory.standardizedFileURL.path
        if snapshotsDirectory != path {
            snapshots = []
            snapshotsDirectory = path
        }
        snapshots.append(snapshot)
        if snapshots.count > 16 { snapshots.removeFirst(snapshots.count - 16) }
    }

    /// Returns false when nothing reached disk, including a save deferred until an unseen disk
    /// revision is merged; the in-memory state and UserDefaults backup already hold the edit.
    @discardableResult
    func save() -> Bool {
        PomodoroFileChanges.shared.noteLocalMutation(fileURL)
        rememberCloudState()
        var next = store
        TopThreeMerge.stampLocalChanges(&next, since: stampedStore ?? next, at: Date())
        next.writeClock = TopThreeMerge.advancing(next.writeClock, device: Self.deviceID)
        store = next
        stampedStore = next
        do {
            let url = fileURL
            let jsonData = try JSONEncoder().encode(store)
            PomodoroDataDir.backupDefaults?.set(jsonData, forKey: localBackupKey)
            let directory = url.deletingLastPathComponent()
            PomodoroDataDir.backupDefaults?.set(directory.standardizedFileURL.path, forKey: Self.backupDirectoryKey)
            if PomodoroFileChanges.shared.diskHasUnseenRevision(at: url) {
                // Another device's revision landed since our last read/write. Overwriting it would
                // lose its edits; let the background scan read it, merge, and write the result.
                deferSave()
                return false
            }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try jsonData.write(to: url, options: .atomic)
            PomodoroDataDir.noteLocalWrite(url.lastPathComponent, data: jsonData)
            deferredSave = false
            rememberSnapshot(store, directory: directory)
            #if os(macOS)
            // 立即刷新桌面小组件（今日任务完成情况）；无 widget 时为空操作
            WidgetBridge.writeSnapshot(store: store)
            WidgetCenter.shared.reloadTimelines(ofKind: "TodayTasks")
            #endif
            print("TopThree saved to: \(url.path)")
            return true
        } catch {
            print("Error saving TopThree: \(error)")
            return false
        }
    }

    private func deferSave() {
        deferredSave = true
        guard !flushRequested else { return }
        flushRequested = true
        PomodoroFileChanges.shared.syncFromDiskIfNeeded { [weak self] in
            guard let self = self else { return }
            guard self.deferredSave else {
                self.flushRequested = false
                return
            }
            guard PomodoroFileChanges.shared.diskHasUnseenRevision(at: self.fileURL) else {
                self.flushRequested = false
                self.save()
                return
            }
            // The scan could not read the revision (e.g. an evicted file while offline). Keep the
            // edit in memory and backup, and retry on a timer instead of spinning on the reader.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self else { return }
                self.flushRequested = false
                if self.deferredSave { self.deferSave() }
            }
        }
    }

    /// A scanned revision of the same folder: merge it with local edits (saved or not) rather than
    /// replace them, then write the result if it holds anything the disk revision lacks.
    private func mergeDiskRevision() {
        let url = fileURL
        guard let data = try? PomodoroFileChanges.shared.readData(from: url) else { return }
        guard let remote = try? JSONDecoder().decode(TopThreeStore.self, from: data) else {
            // Keep an undecodable cloud revision pending as before, without blocking local saves.
            PomodoroFileChanges.shared.noteUnmergeableRevision(url)
            return
        }
        PomodoroFileChanges.shared.consume(url, data: data)
        var local = store
        TopThreeMerge.stampLocalChanges(&local, since: stampedStore ?? local, at: Date())
        var merged = TopThreeMerge.merge(local: local, remote: remote, snapshots: snapshots)
        rememberSnapshot(remote, directory: url.deletingLastPathComponent())
        let migrated = Self.migrate(&merged)
        let needsWrite = deferredSave || migrated || !TopThreeMerge.sameContent(merged, remote)
        store = merged
        stampedStore = merged
        if needsWrite { save() }
    }

    /// 数据目录变化后（如 iOS 授权 iCloud 文件夹）重新加载；同一目录的后台扫描改为合并。
    func reload() {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL.path
        if PomodoroFileChanges.shared.isApplyingSnapshot {
            if snapshotsDirectory == directory {
                mergeDiskRevision()
                refreshWidget()
                return
            }
            // Another folder's file is never merged into this one; keep unsaved edits as before.
            if PomodoroFileChanges.shared.hasDirtyLocalEdit(fileURL) { return }
        }
        let acknowledge = PomodoroFileChanges.shared.explicitReloadAcknowledgement(for: fileURL)
        if let loaded = Self.loadFile(TopThreeStore.self, from: fileURL) {
            store = loaded
            acknowledge()
            snapshots = [loaded]
        } else if PomodoroFileChanges.shared.fileExists(at: fileURL) {
            return // Keep an undecodable cloud revision pending rather than upgrade/write a backup over it.
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupKey),
                  let decoded = try? JSONDecoder().decode(TopThreeStore.self, from: data) {
            store = decoded
            snapshots = []
        } else {
            store = TopThreeStore()
            snapshots = []
        }
        // An explicit replacement discards unsaved edits, like the dirty epoch it acknowledges.
        snapshotsDirectory = directory
        stampedStore = store
        deferredSave = false
        // 与 init 相同的旧数据升级
        var upgraded = store
        if Self.migrate(&upgraded) {
            store = upgraded
            save()
        }
        refreshWidget()
    }

    private func refreshWidget() {
        #if os(macOS)
        // iCloud 同步/目录切换重载后同步刷新 widget 快照
        WidgetBridge.writeSnapshot(store: store)
        WidgetCenter.shared.reloadTimelines(ofKind: "TodayTasks")
        #endif
        print("TopThree reloaded from: \(fileURL.path)")
    }

    // MARK: 逻辑日：一天的开始 = 第一个 time block 的启动时间
    func logicalDateKey(settings: UserSettings, date: Date = Date(), calendar cal: Calendar = .current) -> String {
        let boundaryMinutes = settings.blockTimeRanges.first?.startMinutes ?? 0
        let minuteOfDay = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        var logical = date
        if minuteOfDay < boundaryMinutes {
            logical = cal.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return FocusReview.dateKeyFormatter(calendar: cal).string(from: logical)
    }

    func todayKey(settings: UserSettings) -> String {
        return logicalDateKey(settings: settings)
    }

    func yesterdayKey(settings: UserSettings) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = todayKey(settings: settings)
        if let d = f.date(from: today),
           let prev = Calendar.current.date(byAdding: .day, value: -1, to: d) {
            return f.string(from: prev)
        }
        return today
    }

    // 只有"今天"（逻辑日）的任务可以修改
    func isEditable(key: String, settings: UserSettings) -> Bool {
        return key == todayKey(settings: settings)
    }

    // MARK: 分类名（可自定义）
    var categoryCount: Int { store.categoryNames.count }

    func categoryName(index: Int) -> String {
        guard index < store.categoryNames.count else { return "Category \(index + 1)" }
        return store.categoryNames[index]
    }

    func isFreeList(category: Int) -> Bool {
        return category >= Self.fixedSlotCategories
    }

    func setCategoryName(index: Int, name: String, settings: UserSettings) {
        prepareCloudAccount(settings: settings)
        guard index >= 0, index < store.categoryNames.count else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(" · "), !store.categoryNames.enumerated().contains(where: { $0.offset != index && $0.element == name }) else { return }
        let oldName = store.categoryNames[index]
        store.categoryNames[index] = name
        for (date, var day) in store.history where day.taskGroups.indices.contains(index) {
            for i in day.taskGroups[index].indices { day.taskGroups[index][i].syncPending = true }
            store.history[date] = day
        }
        rememberCloudState()
        for owner in Array(store.cloudStates.keys) {
            var state = store.cloudStates[owner]!
            if let tagId = state.categoryTagIds.removeValue(forKey: oldName) {
                state.categoryTagIds[name] = tagId
                state.pendingTagRenames[tagId] = name
            }
            store.cloudStates[owner] = state
        }
        if let state = store.cloudStates[store.cloudAccount] {
            store.categoryTagIds = state.categoryTagIds
            store.pendingTagRenames = state.pendingTagRenames
        }
        save()
        Task { @MainActor in await synchronize(settings: settings) }
    }

    // MARK: 任务读写（按分类，统一为自由列表式交互；Work/MyOwn 上限 3 条）
    private func dayWithCategories(key: String) -> TopThreeDay {
        var day = store.history[key] ?? TopThreeDay(date: key)
        while day.taskGroups.count < categoryCount {
            day.taskGroups.append([])
        }
        return day
    }

    private func ensureDay(key: String) {
        store.history[key] = dayWithCategories(key: key)
    }

    // 任务上限：固定分类（Work/MyOwn）最多 3 条，琐事不限
    func taskLimit(category: Int) -> Int? {
        return isFreeList(category: category) ? nil : 3
    }

    func canAddTask(key: String, category: Int, settings: UserSettings) -> Bool {
        guard store.categoryNames.indices.contains(category), isEditable(key: key, settings: settings) else { return false }
        if let limit = taskLimit(category: category) {
            return getTasks(key: key, category: category).count < limit
        }
        return true
    }

    // 统一添加任务（所有分类相同交互）
    func addTask(key: String, category: Int, title: String, settings: UserSettings) {
        prepareCloudAccount(settings: settings)
        guard canAddTask(key: key, category: category, settings: settings) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ensureDay(key: key)
        var day = store.history[key]!
        let task = TopThreeTask(title: trimmed, syncPending: true, cloudAccount: HabiticaAPI.shared.cloudAccount(settings: settings))
        day.taskGroups[category].append(task)
        store.history[key] = day
        save()
        syncTaskToHabitica(task: task, category: category, key: key, settings: settings)
    }

    /// Resolve the UUID again at action time; a stale row may not edit its replacement.
    private func taskIndex(id: UUID, key: String, category: Int) -> Int? {
        guard category >= 0, let location = locate(id), location.key == key,
              location.category == category, let day = store.history[key],
              day.taskGroups.indices.contains(category) else { return nil }
        return day.taskGroups[category].firstIndex { $0.id == id && !$0.movedToToday }
    }

    func setTaskTitle(key: String, category: Int, id: UUID, title: String, settings: UserSettings) {
        prepareCloudAccount(settings: settings)
        guard isEditable(key: key, settings: settings),
              let index = taskIndex(id: id, key: key, category: category),
              var day = store.history[key] else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        day.taskGroups[category][index].title = trimmed
        day.taskGroups[category][index].syncPending = true
        store.history[key] = day
        save()
        let task = day.taskGroups[category][index]
        if !trimmed.isEmpty {
            syncTaskToHabitica(task: task, category: category, key: key, settings: settings)
        }
    }

    func toggleTask(key: String, category: Int, id: UUID, settings: UserSettings) {
        prepareCloudAccount(settings: settings)
        guard isEditable(key: key, settings: settings),
              let index = taskIndex(id: id, key: key, category: category),
              var day = store.history[key] else { return }
        day.taskGroups[category][index].isCompleted.toggle()
        day.taskGroups[category][index].syncPending = true
        store.history[key] = day
        save()
        let task = day.taskGroups[category][index]
        syncTaskToHabitica(task: task, category: category, key: key, settings: settings)
    }

    func getTasks(key: String, category: Int) -> [TopThreeTask] {
        if let day = store.history[key],
           day.taskGroups.indices.contains(category) {
            return day.taskGroups[category]
        }
        return []
    }

    func unfinishedTasks(before today: String) -> [UnfinishedTask] {
        var seen: Set<UUID> = []
        var tasks: [UnfinishedTask] = []
        for key in store.history.keys.sorted(by: >) {
            guard let day = store.history[key] else { continue }
            for (category, group) in day.taskGroups.enumerated() {
                for task in group where !task.movedToToday && seen.insert(task.id).inserted {
                    if key < today, category < categoryCount, task.isUnfinished {
                        tasks.append(UnfinishedTask(dateKey: key, category: category, task: task))
                    }
                }
            }
        }
        return tasks
    }

    func removeTask(key: String, category: Int, id: UUID, settings: UserSettings, fromUnfinished: Bool = false) {
        let today = todayKey(settings: settings)
        guard fromUnfinished ? key < today : key == today else { return }
        prepareCloudAccount(settings: settings)
        guard let index = taskIndex(id: id, key: key, category: category),
              var day = store.history[key],
              !fromUnfinished || day.taskGroups[category][index].isUnfinished else { return }
        let task = day.taskGroups[category].remove(at: index)
        if let owner = task.cloudAccount {
            if let remoteId = task.habiticaTaskId { queueDeletion(remoteId, account: owner) }
            else if let attempt = task.cloudCreateAttempt { queueDeletedAttempt(id: task.id, attempt: attempt, owner: owner) }
        }
        store.history[key] = day
        save()
        // Only the active owner may dispatch a deletion; other owners retain their tombstone.
        if task.cloudAccount == accountSignature(settings) {
            Task { @MainActor in await synchronize(settings: settings) }
        }
    }

    @discardableResult
    func moveTaskToToday(fromKey: String, category: Int, id: UUID, settings: UserSettings) -> Bool {
        let today = todayKey(settings: settings)
        guard fromKey < today, canAddTask(key: today, category: category, settings: settings) else { return false }
        prepareCloudAccount(settings: settings)
        guard let index = taskIndex(id: id, key: fromKey, category: category),
              var source = store.history[fromKey] else { return false }
        var moved = source.taskGroups[category][index]
        guard moved.isUnfinished else { return false }

        var destination = dayWithCategories(key: today)
        moved.syncPending = true
        if let archivedIndex = destination.taskGroups[category].firstIndex(where: { $0.id == id && $0.movedToToday }) {
            destination.taskGroups[category][archivedIndex] = moved
        } else {
            destination.taskGroups[category].append(moved)
        }

        source.taskGroups[category][index].movedToToday = true
        store.history.merge([fromKey: source, today: destination]) { _, updated in updated }
        save()
        syncTaskToHabitica(task: moved, category: category, key: today, settings: settings)
        return true
    }

    // MARK: - Habitica 同步

    /// Ownership is independent of token/connection state. Keep every owner's mappings and queues.
    func prepareCloudAccount(settings: UserSettings) {
        guard let account = HabiticaAPI.shared.cloudAccount(settings: settings) else { return }
        var changed = false
        // Old versions kept raw host case/default ports/trailing slashes in the store-level owner.
        // Canonicalize those keys as well, so upgrading is not mistaken for an account switch.
        if let normalized = canonicalOwner(store.cloudAccount), normalized != store.cloudAccount {
            store.cloudAccount = normalized
            changed = true
        }
        for rawOwner in Array(store.cloudStates.keys) {
            guard let normalized = canonicalOwner(rawOwner), normalized != rawOwner,
                  let old = store.cloudStates.removeValue(forKey: rawOwner) else { continue }
            var state = store.cloudStates[normalized] ?? TopThreeCloudState()
            state.categoryTagIds.merge(old.categoryTagIds) { current, _ in current }
            state.pendingTagRenames.merge(old.pendingTagRenames) { current, _ in current }
            state.deletedCloudIds = Array(Set(state.deletedCloudIds + old.deletedCloudIds)).sorted()
            state.confirmedDeletedCloudIds = Array(Set(state.confirmedDeletedCloudIds + old.confirmedDeletedCloudIds)).sorted()
            for intent in old.deletedCreateAttempts where !state.deletedCreateAttempts.contains(intent) {
                state.deletedCreateAttempts.append(intent)
            }
            store.cloudStates[normalized] = state
            changed = true
        }
        let legacyOwner = store.cloudAccount.isEmpty ? account : store.cloudAccount
        for (key, var day) in store.history {
            for g in day.taskGroups.indices {
                for t in day.taskGroups[g].indices {
                    let old = day.taskGroups[g][t].cloudAccount
                    let owner = old.flatMap(canonicalOwner) ?? old ?? legacyOwner
                    if old != owner {
                        day.taskGroups[g][t].cloudAccount = owner
                        changed = true
                    }
                }
            }
            if changed { store.history[key] = day }
        }
        if store.cloudAccount != account {
            if store.cloudAccount.isEmpty {
                store.cloudStates[account] = TopThreeCloudState(categoryTagIds: store.categoryTagIds,
                    deletedCloudIds: store.deletedCloudIds, confirmedDeletedCloudIds: store.confirmedDeletedCloudIds,
                    pendingTagRenames: store.pendingTagRenames,
                    deletedCreateAttempts: store.deletedCreateAttempts)
            } else { rememberCloudState() }
            let state = store.cloudStates[account] ?? TopThreeCloudState()
            store.categoryTagIds = state.categoryTagIds
            store.deletedCloudIds = state.deletedCloudIds
            store.confirmedDeletedCloudIds = state.confirmedDeletedCloudIds
            store.pendingTagRenames = state.pendingTagRenames
            store.deletedCreateAttempts = state.deletedCreateAttempts
            store.cloudAccount = account
            changed = true
        }
        if changed { save() }
    }

    private func canonicalOwner(_ value: String) -> String? {
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let root = HabiticaAPI.shared.configure(serverUrlOverride: String(parts[1]))
        return root.isEmpty ? nil : "\(parts[0])|\(root)"
    }

    private func rememberCloudState() {
        guard !store.cloudAccount.isEmpty else { return }
        store.cloudStates[store.cloudAccount] = TopThreeCloudState(categoryTagIds: store.categoryTagIds,
            deletedCloudIds: store.deletedCloudIds, confirmedDeletedCloudIds: store.confirmedDeletedCloudIds,
            pendingTagRenames: store.pendingTagRenames,
            deletedCreateAttempts: store.deletedCreateAttempts)
    }

    private func queueDeletion(_ remote: String, account: String) {
        if account == store.cloudAccount {
            if !store.deletedCloudIds.contains(remote) { store.deletedCloudIds.append(remote) }
        } else {
            var state = store.cloudStates[account] ?? TopThreeCloudState()
            if !state.deletedCloudIds.contains(remote) { state.deletedCloudIds.append(remote) }
            store.cloudStates[account] = state
        }
    }

    private func cloudState(owner: String) -> TopThreeCloudState {
        if owner == store.cloudAccount {
            return TopThreeCloudState(categoryTagIds: store.categoryTagIds, deletedCloudIds: store.deletedCloudIds,
                confirmedDeletedCloudIds: store.confirmedDeletedCloudIds,
                pendingTagRenames: store.pendingTagRenames, deletedCreateAttempts: store.deletedCreateAttempts)
        }
        return store.cloudStates[owner] ?? TopThreeCloudState()
    }

    private func queueDeletedAttempt(id: UUID, attempt: CloudCreateAttempt, owner: String) {
        let intent = DeletedCloudCreateAttempt(id: id, attempt: attempt)
        if owner == store.cloudAccount {
            if !store.deletedCreateAttempts.contains(intent) { store.deletedCreateAttempts.append(intent) }
        } else {
            var state = cloudState(owner: owner)
            if !state.deletedCreateAttempts.contains(intent) { state.deletedCreateAttempts.append(intent) }
            store.cloudStates[owner] = state
        }
    }

    /// Checking settings alone misses A→B→A while the active store still belongs to B.
    private func isActiveOwner(_ owner: String) -> Bool {
        !owner.isEmpty && store.cloudAccount == owner && accountSignature(SettingsManager.shared.settings) == owner
    }

    // 确保分类对应的 Habitica tag 存在，返回 tag id
    @MainActor
    func ensureTagId(category: Int, settings: UserSettings) async -> String? {
        let owner = accountSignature(settings)
        guard settings.connectHabitica, !settings.uid.isEmpty, !settings.apiToken.isEmpty,
              isActiveOwner(owner), store.categoryNames.indices.contains(category) else { return nil }
        let name = categoryName(index: category)
        if let cached = cloudState(owner: owner).categoryTagIds[name], !cached.isEmpty {
            if cloudState(owner: owner).pendingTagRenames[cached] != nil {
                await retryTagRenames(owner: owner, settings: settings)
                guard isActiveOwner(owner), categoryName(index: category) == name,
                      cloudState(owner: owner).pendingTagRenames[cached] == nil else { return nil }
            }
            return cached
        }
        let fetched = await HabiticaAPI.shared.fetchTags(settings: settings)
        guard isActiveOwner(owner), categoryName(index: category) == name, let tags = fetched else { return nil }
        let tagId: String?
        if let existing = tags.first(where: { $0.value == name }) {
            tagId = existing.key
        } else {
            // Keep the owner check between lookup and POST instead of hiding that await
            // inside ensureTag(), where the active task store cannot be checked.
            tagId = await HabiticaAPI.shared.createTag(name: name, settings: settings)
            guard isActiveOwner(owner), categoryName(index: category) == name else { return nil }
        }
        guard let tagId = tagId else { return nil }
        store.categoryTagIds[name] = tagId
        save()
        return tagId
    }

    @MainActor
    private func retryTagRenames(owner: String, settings: UserSettings) async {
        guard isActiveOwner(owner), accountSignature(settings) == owner else { return }
        for (id, desired) in cloudState(owner: owner).pendingTagRenames {
            guard isActiveOwner(owner), cloudState(owner: owner).pendingTagRenames[id] == desired else { return }
            let tags = await HabiticaAPI.shared.fetchTags(settings: settings)
            guard isActiveOwner(owner), let tags = tags else { return }
            if tags[id] != desired {
                let renamed = await HabiticaAPI.shared.renameTag(tagId: id, name: desired, settings: settings)
                guard isActiveOwner(owner) else { return }
                guard renamed else { continue }
                let verified = await HabiticaAPI.shared.fetchTags(settings: settings)
                guard isActiveOwner(owner) else { return }
                guard verified?[id] == desired else { continue }
            }
            if cloudState(owner: owner).pendingTagRenames[id] == desired {
                store.pendingTagRenames.removeValue(forKey: id)
                save()
            }
        }
    }

    private func accountSignature(_ settings: UserSettings) -> String {
        HabiticaAPI.shared.cloudAccount(settings: settings) ?? ""
    }
    private func locate(_ id: UUID) -> (key: String, category: Int, task: TopThreeTask)? {
        // Prefer the latest moved copy, whose completion state is authoritative.
        for key in store.history.keys.sorted().reversed() {
            guard let day = store.history[key] else { continue }
            for (category, tasks) in day.taskGroups.enumerated() {
                if let task = tasks.first(where: { $0.id == id && !$0.movedToToday }) { return (key, category, task) }
            }
        }
        return nil
    }

    private func syncTaskToHabitica(task: TopThreeTask, category: Int, key: String, settings: UserSettings) {
        guard settings.connectHabitica, !settings.uid.isEmpty, !settings.apiToken.isEmpty else { return }
        Task { @MainActor in await pushTask(id: task.id, settings: settings) }
    }

    private func updateCopies(id: UUID, owner: String, _ update: (inout TopThreeTask) -> Void) {
        for (key, var day) in store.history {
            for g in day.taskGroups.indices {
                for t in day.taskGroups[g].indices where day.taskGroups[g][t].id == id && day.taskGroups[g][t].cloudAccount == owner {
                    update(&day.taskGroups[g][t])
                }
            }
            store.history[key] = day
        }
    }

    private func sameAttempt(_ lhs: CloudCreateAttempt, _ rhs: CloudCreateAttempt) -> Bool {
        lhs.title == rhs.title && lhs.notes == rhs.notes && Set(lhs.tags) == Set(rhs.tags)
    }

    /// A request known not to have created a remote task needs no ambiguous-POST marker.
    /// Reconcile the original owner's state even if its row was removed or the account changed.
    private func clearRejectedCreateAttempt(id: UUID, attempt: CloudCreateAttempt, owner: String) {
        var changed = false
        for (key, var day) in store.history {
            var dayChanged = false
            for group in day.taskGroups.indices {
                for index in day.taskGroups[group].indices {
                    let task = day.taskGroups[group][index]
                    guard task.id == id, task.cloudAccount == owner, task.habiticaTaskId == nil,
                          task.cloudCreateAttempt.map({ sameAttempt($0, attempt) }) == true else { continue }
                    day.taskGroups[group][index].cloudCreateAttempt = nil
                    dayChanged = true
                    changed = true
                }
            }
            if dayChanged { store.history[key] = day }
        }
        var state = cloudState(owner: owner)
        let before = state.deletedCreateAttempts.count
        state.deletedCreateAttempts.removeAll { $0.id == id && sameAttempt($0.attempt, attempt) }
        if state.deletedCreateAttempts.count != before {
            if owner == store.cloudAccount { store.deletedCreateAttempts = state.deletedCreateAttempts }
            else { store.cloudStates[owner] = state }
            changed = true
        }
        if changed { save() }
    }

    private func matches(_ todo: HabiticaAPI.CloudTodo, attempt: CloudCreateAttempt) -> Bool {
        todo.title == attempt.title && todo.notes == attempt.notes && Set(todo.tags) == Set(attempt.tags)
    }

    private func attemptCandidateIds(_ attempt: CloudCreateAttempt, owner: String) -> Set<UUID> {
        let tasks = store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }
        let live = tasks.filter { task in
            task.cloudAccount == owner && task.habiticaTaskId == nil &&
                task.cloudCreateAttempt.map { sameAttempt($0, attempt) } == true
        }.map(\.id)
        let removed = cloudState(owner: owner).deletedCreateAttempts.filter { sameAttempt($0.attempt, attempt) }.map(\.id)
        return Set(live + removed)
    }

    private func remoteIsAvailable(_ remote: String, id: UUID, owner: String) -> Bool {
        !remote.isEmpty && !cloudState(owner: owner).deletedCloudIds.contains(remote) &&
            !store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }.contains {
                $0.cloudAccount == owner && $0.id != id && $0.habiticaTaskId == remote
            }
    }

    /// Do not guess between identical ambiguous POSTs or steal an ID already mapped to another UUID.
    private func matchingAttempt(_ attempt: CloudCreateAttempt, id: UUID, owner: String, todos: [HabiticaAPI.CloudTodo]) -> [HabiticaAPI.CloudTodo] {
        guard !hasReservedDeletionMarker(attempt, id: id, owner: owner) else { return [] }
        return todos.filter { remoteIsAvailable($0.id, id: id, owner: owner) && matches($0, attempt: attempt) }
    }

    private func hasReservedDeletionMarker(_ attempt: CloudCreateAttempt, id: UUID, owner: String) -> Bool {
        cloudState(owner: owner).deletedCreateAttempts.contains {
            $0.id != id && $0.attempt.notes == attempt.notes && Set($0.attempt.tags) == Set(attempt.tags)
        }
    }

    /// Called only in a non-suspending MainActor segment, immediately before binding or deleting.
    @MainActor
    private func canBind(_ remote: String, attempt: CloudCreateAttempt, id: UUID, owner: String) -> Bool {
        isActiveOwner(owner) && attemptCandidateIds(attempt, owner: owner) == Set([id]) &&
            !hasReservedDeletionMarker(attempt, id: id, owner: owner) &&
            remoteIsAvailable(remote, id: id, owner: owner)
    }

    /// A unique unresolved removal becomes an owner tombstone before any import or task POST.
    @MainActor
    private func resolveDeletedAttempts(_ todos: [HabiticaAPI.CloudTodo], owner: String) -> Bool {
        guard isActiveOwner(owner) else { return false }
        var resolved: [DeletedCloudCreateAttempt] = []
        for intent in cloudState(owner: owner).deletedCreateAttempts {
            let candidates = matchingAttempt(intent.attempt, id: intent.id, owner: owner, todos: todos)
            guard candidates.count == 1, let remote = candidates.first?.id,
                  canBind(remote, attempt: intent.attempt, id: intent.id, owner: owner) else { continue }
            queueDeletion(remote, account: owner)
            resolved.append(intent)
        }
        guard !resolved.isEmpty else { return true }
        store.deletedCreateAttempts.removeAll { resolved.contains($0) }
        return save()
    }

    @MainActor
    private func pushTask(id: UUID, settings: UserSettings) async {
        let owner = accountSignature(settings)
        guard isActiveOwner(owner), !syncingTasks.contains(id), let location = locate(id),
              location.task.syncPending, location.task.cloudAccount == owner else { return }
        syncingTasks.insert(id)
        defer {
            syncingTasks.remove(id)
            if isActiveOwner(owner), let message = HabiticaAPI.shared.rateLimitMessage(settings: settings) {
                syncMessage = message + " 本机修改已保留。"
            }
        }
        for _ in 0..<4 {
            guard isActiveOwner(owner), let current = locate(id), current.task.syncPending,
                  current.task.cloudAccount == owner else { return }
            let task = current.task
            let categoryName = categoryName(index: current.category)
            let tagResult = await ensureTagId(category: current.category, settings: settings)
            guard isActiveOwner(owner), let tag = tagResult, let afterTag = locate(id),
                  afterTag.task.cloudAccount == owner else { return }
            guard afterTag.task == task, afterTag.key == current.key, afterTag.category == current.category,
                  self.categoryName(index: current.category) == categoryName else { continue }
            let notes = "From HabiticaPomodoro Top3 · \(categoryName) · \(current.key)"
            var remoteId = task.habiticaTaskId
            if remoteId == nil {
                let attempt: CloudCreateAttempt
                if let original = task.cloudCreateAttempt {
                    attempt = original
                    let fetched = await HabiticaAPI.shared.fetchTopThreeTodos(settings: settings)
                    guard isActiveOwner(owner), let todos = fetched else { return }
                    // Recompute after the fetch: a second local UUID may have acquired this attempt.
                    guard attemptCandidateIds(original, owner: owner) == Set([id]) else { return }
                    let candidates = matchingAttempt(original, id: id, owner: owner, todos: todos)
                    // Absence is not proof that a response-lost POST failed. Never blindly re-POST.
                    guard candidates.count == 1 else { return }
                    remoteId = candidates.first?.id
                } else {
                    attempt = CloudCreateAttempt(title: task.title, notes: notes, tags: [tag])
                    // Removed attempts with this marker also reserve it until uniquely resolved.
                    guard !hasReservedDeletionMarker(attempt, id: id, owner: owner) else { return }
                    guard attemptCandidateIds(attempt, owner: owner).subtracting([id]).isEmpty else { return }
                    updateCopies(id: id, owner: owner) { $0.cloudCreateAttempt = attempt }
                    guard save() else { // Durable exact version BEFORE dispatch.
                        // Nothing was sent: a marker persisted later (e.g. by a deferred merge write)
                        // would wrongly block this task as an ambiguous POST forever.
                        clearRejectedCreateAttempt(id: id, attempt: attempt, owner: owner)
                        return
                    }
                    let result = await HabiticaAPI.shared.createTodo(text: task.title, notes: notes, tagIds: [tag], settings: settings)
                    switch result {
                    case .created(let id): remoteId = id
                    case .notCreated:
                        clearRejectedCreateAttempt(id: id, attempt: attempt, owner: owner)
                        return
                    case .uncertain: return
                    }
                    guard isActiveOwner(owner) else { return }
                }
                guard let created = remoteId,
                      canBind(created, attempt: attempt, id: id, owner: owner) else { return }
                // The occupancy check and binding/deletion have no intervening await.
                guard let latest = locate(id), latest.task.cloudAccount == owner else {
                    guard cloudState(owner: owner).deletedCreateAttempts.contains(where: { $0.id == id && sameAttempt($0.attempt, attempt) }) else { return }
                    queueDeletion(created, account: owner)
                    store.deletedCreateAttempts.removeAll { $0.id == id && sameAttempt($0.attempt, attempt) }
                    save()
                    return
                }
                guard latest.task.habiticaTaskId == nil,
                      latest.task.cloudCreateAttempt.map({ sameAttempt($0, attempt) }) == true else { return }
                updateCopies(id: id, owner: owner) { $0.habiticaTaskId = created; $0.cloudCreateAttempt = nil }
                guard save() else { return }
            }
            guard let remote = remoteId else { return }
            var expected = task
            expected.habiticaTaskId = remote
            expected.cloudCreateAttempt = nil
            // Identity loss is terminal; a changed revision instead restarts from the current row.
            // These checks and each following dispatch share a non-suspending MainActor segment.
            func hasIdentity() -> Bool {
                guard isActiveOwner(owner), remoteIsAvailable(remote, id: id, owner: owner),
                      let latest = locate(id) else { return false }
                return latest.task.cloudAccount == owner && latest.task.habiticaTaskId == remote
            }
            func hasRevision(_ generation: Int) -> Bool {
                guard generation == mutationGeneration, let latest = locate(id) else { return false }
                return latest.task == expected && latest.key == current.key && latest.category == current.category &&
                    self.categoryName(index: latest.category) == categoryName && store.categoryTagIds[categoryName] == tag
            }
            guard hasIdentity() else { return }
            let revision = mutationGeneration
            guard hasRevision(revision) else { continue }
            let updated = await HabiticaAPI.shared.updateTodo(taskId: remote, text: task.title, tagIds: [tag], notes: notes, settings: settings)
            guard hasIdentity(), updated else { return }
            guard hasRevision(revision) else { continue }
            let fetched = await HabiticaAPI.shared.fetchTopThreeTodos(settings: settings)
            guard hasIdentity(), let todos = fetched,
                  let todo = todos.first(where: { $0.id == remote }) else { return }
            guard hasRevision(revision) else { continue }
            var confirmation = todo
            if todo.completed != task.isCompleted {
                let scored = await HabiticaAPI.shared.scoreTodo(taskId: remote, completed: task.isCompleted, settings: settings)
                guard hasIdentity(), scored else { return }
                guard hasRevision(revision) else { continue }
                let verified = await HabiticaAPI.shared.fetchTopThreeTodos(settings: settings)
                guard hasIdentity(), let scoredTodo = verified?.first(where: { $0.id == remote }) else { return }
                confirmation = scoredTodo
            }
            // The post-PUT read already verifies unchanged completion; only a score needs another read.
            guard hasRevision(revision) else { continue }
            guard confirmation.title == task.title, confirmation.completed == task.isCompleted,
                  confirmation.notes == notes, Set(confirmation.tags) == Set([tag]) else { return }
            updateCopies(id: id, owner: owner) { $0.syncPending = false }
            save()
            return
        }
    }

    static func parseOwnedNotes(_ notes: String) -> (category: String, date: String)? {
        let prefix = "From HabiticaPomodoro Top3 · "
        guard notes.hasPrefix(prefix) else { return nil }
        let parts = String(notes.dropFirst(prefix.count)).components(separatedBy: " · ")
        guard parts.count == 2, !parts[0].isEmpty,
              parts[0] == parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
              parts[1].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: parts[1]), formatter.string(from: date) == parts[1] else { return nil }
        return (parts[0], parts[1])
    }

    /// No deletes inferred from an incomplete list. Dirty records, quotas and owner tombstones win.
    @MainActor
    @discardableResult
    func mergeOwnedTodos(_ todos: [HabiticaAPI.CloudTodo], owner: String) -> Int {
        guard isActiveOwner(owner), resolveDeletedAttempts(todos, owner: owner) else { return 0 }
        hasDeletionConflict = false
        var imported = 0
        for todo in todos {
            guard !todo.id.isEmpty, !todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cloudState(owner: owner).deletedCloudIds.contains(todo.id),
                  let marker = Self.parseOwnedNotes(todo.notes) else { continue }
            var tasks = store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }.filter { $0.cloudAccount == owner }
            // Title is mutable: notes/tags quarantine an unknown ID, never establish identity.
            // Already-bound lawful tasks remain protected by UUID/ID and may still merge.
            if !tasks.contains(where: { $0.habiticaTaskId == todo.id }),
               cloudState(owner: owner).deletedCreateAttempts.contains(where: {
                   todo.notes == $0.attempt.notes && Set(todo.tags) == Set($0.attempt.tags)
               }) {
                hasDeletionConflict = true
                continue
            }
            // Recover a response-lost POST without importing a second UUID. Pending local version wins.
            if !tasks.contains(where: { $0.habiticaTaskId == todo.id }) {
                let candidates = Set(tasks.filter {
                    guard $0.habiticaTaskId == nil, let attempt = $0.cloudCreateAttempt else { return false }
                    return matchingAttempt(attempt, id: $0.id, owner: owner, todos: todos).count == 1 &&
                        matchingAttempt(attempt, id: $0.id, owner: owner, todos: todos).first?.id == todo.id
                }.map(\.id))
                if candidates.count == 1, let id = candidates.first,
                   let attempt = tasks.first(where: { $0.id == id })?.cloudCreateAttempt,
                   canBind(todo.id, attempt: attempt, id: id, owner: owner) {
                    updateCopies(id: id, owner: owner) { $0.habiticaTaskId = todo.id; $0.cloudCreateAttempt = nil }
                } else if tasks.contains(where: {
                    guard $0.habiticaTaskId == nil, let attempt = $0.cloudCreateAttempt else { return false }
                    return todo.title == attempt.title && todo.notes == attempt.notes && Set(todo.tags) == Set(attempt.tags)
                }) { continue }
                tasks = store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }.filter { $0.cloudAccount == owner }
            }
            let matchingTags = store.categoryNames.indices.filter { i in
                store.categoryTagIds[store.categoryNames[i]].map { todo.tags.contains($0) } ?? false
            }
            guard let category = store.categoryNames.firstIndex(of: marker.category) ?? (matchingTags.count == 1 ? matchingTags.first : nil) else { continue }
            let known = tasks.first(where: { $0.habiticaTaskId == todo.id && !$0.movedToToday })
            if let known = known, known.syncPending { continue }
            // A deleted active row may still have archived moved copies: never resurrect it.
            if known == nil && tasks.contains(where: { $0.habiticaTaskId == todo.id }) { continue }
            let source = known.flatMap { locate($0.id) }
            let targetTasks = getTasks(key: marker.date, category: category)
            if source?.key != marker.date || source?.category != category {
                if let limit = taskLimit(category: category), targetTasks.filter({ $0.id != known?.id }).count >= limit { continue }
            }
            var merged = known ?? TopThreeTask(title: todo.title, habiticaTaskId: todo.id, cloudAccount: owner)
            merged.title = todo.title
            merged.isCompleted = todo.completed
            merged.movedToToday = false
            if let source = source, source.key != marker.date || source.category != category,
               var oldDay = store.history[source.key],
               let index = oldDay.taskGroups[source.category].firstIndex(where: { $0.id == merged.id && !$0.movedToToday }) {
                if source.key != marker.date {
                    // Keep the old day's row as a moved archive with its original UUID and values.
                    oldDay.taskGroups[source.category][index].movedToToday = true
                } else { oldDay.taskGroups[source.category].remove(at: index) }
                store.history[source.key] = oldDay
            }
            ensureDay(key: marker.date)
            var destination = store.history[marker.date]!
            if let index = destination.taskGroups[category].firstIndex(where: { $0.id == merged.id }) {
                destination.taskGroups[category][index] = merged
            } else { destination.taskGroups[category].append(merged) }
            store.history[marker.date] = destination
            if known == nil { imported += 1 }
        }
        save()
        if hasDeletionConflict { syncMessage = "云端任务与未解决的删除意图冲突，已隔离；请人工核对。" }
        return imported
    }

    @MainActor
    func synchronize(settings: UserSettings) async {
        let owner = accountSignature(settings)
        guard settings.connectHabitica, !settings.uid.isEmpty, !settings.apiToken.isEmpty,
              !owner.isEmpty, accountSignature(SettingsManager.shared.settings) == owner else { return }
        prepareCloudAccount(settings: settings)
        guard isActiveOwner(owner), !syncInProgress else { return }
        syncInProgress = true
        defer { syncInProgress = false }
        func canContinue() -> Bool {
            guard isActiveOwner(owner) else { return false }
            if let message = HabiticaAPI.shared.rateLimitMessage(settings: settings) {
                syncMessage = message + " 本机修改已保留。"
                return false
            }
            return true
        }
        guard canContinue() else { return }
        // Resolve removed response-lost POSTs first; unresolved markers reserve their UUIDs.
        if !cloudState(owner: owner).deletedCreateAttempts.isEmpty {
            let generation = mutationGeneration
            let fetched = await HabiticaAPI.shared.fetchTopThreeTodos(settings: settings)
            guard isActiveOwner(owner), let todos = fetched, generation == mutationGeneration,
                  resolveDeletedAttempts(todos, owner: owner) else { return }
        }
        await retryTagRenames(owner: owner, settings: settings)
        guard canContinue() else { return }
        let pending = Set(store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }
            .filter { $0.syncPending && $0.cloudAccount == owner }.map(\.id))
        for id in pending {
            guard canContinue() else { return }
            await pushTask(id: id, settings: settings)
            guard canContinue() else { return }
        }
        let confirmed = Set(cloudState(owner: owner).confirmedDeletedCloudIds)
        for id in cloudState(owner: owner).deletedCloudIds where !confirmed.contains(id) {
            guard canContinue() else { return }
            let deleted = await HabiticaAPI.shared.deleteTodo(taskId: id, settings: settings)
            guard isActiveOwner(owner) else { return }
            if deleted, store.deletedCloudIds.contains(id), !store.confirmedDeletedCloudIds.contains(id) {
                // Keep the tombstone for stale reads, persist the acknowledgement to retire HTTP work.
                store.confirmedDeletedCloudIds.append(id)
                guard save() else { return }
            }
            guard canContinue() else { return }
        }
        guard canContinue() else { return }
        let generation = mutationGeneration
        let fetched = await HabiticaAPI.shared.fetchTopThreeTodos(settings: settings)
        guard isActiveOwner(owner) else { return }
        guard let todos = fetched else {
            syncMessage = (HabiticaAPI.shared.rateLimitMessage(settings: settings)
                ?? "同步失败，稍后可重试。") + " 本机任务已保留。"
            return
        }
        guard generation == mutationGeneration else {
            syncMessage = "同步期间本机任务有修改，未采用旧响应，请再刷新。"
            return
        }
        let count = mergeOwnedTodos(todos, owner: owner)
        if hasDeletionConflict { return } // Do not overwrite manual-review feedback with success.
        let state = cloudState(owner: owner)
        let stillPending = !state.pendingTagRenames.isEmpty || !state.deletedCreateAttempts.isEmpty ||
            !Set(state.deletedCloudIds).isSubset(of: Set(state.confirmedDeletedCloudIds)) ||
            store.history.values.flatMap { $0.taskGroups.flatMap { $0 } }.contains { $0.syncPending && $0.cloudAccount == owner }
        syncMessage = stillPending ? "已合并云端任务；本机仍有待上传修改。" : "已同步 · 新导入 \(count) 个任务"
    }

}

extension Notification.Name {
    static let histogramChanged = Notification.Name("histogramChanged")
}
