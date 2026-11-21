import Foundation

// MARK: - Data Directory (配置文件统一存放在 Documents 下的隐藏文件夹)
// ~/Documents 由 iCloud Drive（桌面与文稿同步）自动同步，
// 因此 .habitica-pomodoro 文件夹及其中的 JSON 文件会随 iCloud 同步到其他设备。
enum PomodoroDataDir {
    static let folderName = ".habitica-pomodoro"
    static let dataFileNames = [
        "habitica_pomodoro_settings.json", "habitica_pomodoro_block_progress.json",
        "habitica_pomodoro_block_history.json", "habitica_pomodoro_daily_blocks.json",
        "habitica_pomodoro_top_three.json", "habitica_pomodoro_plants.json",
        "habitica_pomodoro_histogram.json"
    ]
    #if DEBUG
    static var isolatedDirectory: URL? {
        didSet {
            if oldValue?.standardizedFileURL != isolatedDirectory?.standardizedFileURL {
                PomodoroFileChanges.shared.noteDirectoryChange()
            }
        }
    }

    static var debugDirectoryOverride: URL? {
        // UI verification only: never used by release builds.
        if let override = ProcessInfo.processInfo.environment["POMODORO_ISOLATED_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return isolatedDirectory
    }
    #endif

    /// Device previews use only the fixture files, including when a file is missing.
    static var backupDefaults: UserDefaults? {
        #if DEBUG && os(iOS)
        if debugDirectoryOverride != nil { return nil }
        #endif
        return .standard
    }

    /// Select the data location separately from Mac directory creation during polling.
    static var resolvedURL: URL {
        #if DEBUG
        if let override = debugDirectoryOverride { return override }
        #endif
        #if os(iOS)
        // iOS：用户通过文件选择器授权 iCloud Drive 目录后，数据落在
        // <授权目录>/.habitica-pomodoro（与 macOS 端 ~/Documents/.habitica-pomodoro 同一批文件）。
        // 未授权时回退 App 沙箱本地目录，保证 App 始终可用。
        if let iCloudDir = ICloudFolderGrant.shared.dataFolderURL { return iCloudDir }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(folderName)
    }

    static var url: URL {
        // Reloads must use the captured directory without a second FileProvider access.
        if let directory = PomodoroFileChanges.shared.prefetchedDirectory { return directory }
        let dir = resolvedURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func resolveDataFolder(under root: URL, fm: FileManager) -> URL {
        let folder = folderName
        let inRoot = root.appendingPathComponent(folder)
        let inDocuments = root.appendingPathComponent("Documents").appendingPathComponent(folder)

        func hasData(_ url: URL) -> Bool {
            dataFileNames.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        }
        // 1. 已有数据者优先
        if hasData(inRoot) { return inRoot }
        if hasData(inDocuments) { return inDocuments }
        // 2. 父级本身就是 Documents
        if root.lastPathComponent == "Documents" { return inRoot }
        // 3. 父级是 iCloud Drive 根且含 Documents 子目录 → 对齐 macOS 路径
        var isDir: ObjCBool = false
        let docsDir = root.appendingPathComponent("Documents")
        if fm.fileExists(atPath: docsDir.path, isDirectory: &isDir), isDir.boolValue {
            return inDocuments
        }
        // 4. 兜底
        return inRoot
    }

    static func fileURL(_ fileName: String) -> URL {
        url.appendingPathComponent(fileName)
    }

    static var onLocalWrite: ((String) -> Void)?

    /// Consume only the bytes actually written, never snapshot unrelated/unloaded cloud files.
    static func noteLocalWrite(_ fileName: String, data: Data) {
        PomodoroFileChanges.shared.noteLocalWrite(fileURL(fileName), data: data)
        onLocalWrite?(fileName)
    }

    // 一次性迁移：把旧的散落在 Documents 根目录的文件移入隐藏文件夹
    static func migrateOldFiles() {
        if PomodoroFileChanges.shared.prefetchedDirectory != nil { return }
        #if DEBUG
        if debugDirectoryOverride != nil { return }
        #endif
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let oldNames = dataFileNames
        for name in oldNames {
            let oldURL = docs.appendingPathComponent(name)
            let newURL = fileURL(name)
            if FileManager.default.fileExists(atPath: oldURL.path),
               !FileManager.default.fileExists(atPath: newURL.path) {
                try? FileManager.default.moveItem(at: oldURL, to: newURL)
            }
        }
    }
}

/// The same seven-file inventory on both platforms. Baselines mean consumed bytes, not observed
/// mtimes: a failed decode stays detectable, including same-size updates within the same second.
final class PomodoroFileChanges {
    static let shared = PomodoroFileChanges()
    // Mutable monitor state and manager publication stay on the main thread. Only immutable
    // URLs/results cross to the reader queue; a cloud download must never stall the UI run loop.
    private var consumed: [String: Data] = [:]
    private var revision = 0
    private var localMutationRevision = 0
    private var dirtyPaths: [String: Int] = [:]
    private var pollTimer: Timer?
    private let readerQueue = DispatchQueue(label: "com.hermes.habitica-pomodoro.file-reader", qos: .utility)
    private var reading = false
    private var completions: [() -> Void] = []
    private var observedDirectory: String?
    private var directoryGeneration = 0
    private var prefetched: [String: Result<Data, Error>]?
    private(set) var prefetchedDirectory: URL?
    // Metadata of the consumed bytes, captured BEFORE each read so a later replacement always
    // looks unseen. Lets a save detect an unmerged revision without reading on the main thread.
    private var consumedStamps: [String: DiskStamp] = [:]
    private var prefetchedStamps: [String: DiskStamp] = [:]
    private var explicitReadStamps: [String: DiskStamp] = [:]
    /// Stores that merge a scanned revision into unsaved edits instead of skipping it while dirty.
    static let mergingFileNames: Set<String> = ["habitica_pomodoro_top_three.json"]
    #if os(macOS)
    private var preparingMacLaunch = false
    #endif

    struct DirectoryIdentity: Equatable {
        let url: URL
        let generation: Int
    }

    /// stat(2) only: never materializes a dataless cloud file.
    struct DiskStamp: Equatable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }

    static func diskStamp(at url: URL) -> DiskStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return DiskStamp(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }

    private static func diskStamps(in directory: URL) -> [String: DiskStamp] {
        var stamps: [String: DiskStamp] = [:]
        for name in PomodoroDataDir.dataFileNames {
            let url = directory.appendingPathComponent(name)
            stamps[url.path] = diskStamp(at: url)
        }
        return stamps
    }

    /// Selection events invalidate A-B-A recovery too, even without an intervening scan.
    func noteDirectoryChange() { directoryGeneration += 1 }

    func directoryIdentity() -> DirectoryIdentity {
        let directory = PomodoroDataDir.resolvedURL.standardizedFileURL
        if observedDirectory != directory.path {
            observedDirectory = directory.path
            directoryGeneration += 1
        }
        return DirectoryIdentity(url: directory, generation: directoryGeneration)
    }

    func consume(_ url: URL, data: Data) {
        let path = url.standardizedFileURL.path
        consumed[path] = data
        consumedStamps[path] = prefetched != nil ? prefetchedStamps[path] : explicitReadStamps.removeValue(forKey: path)
        revision += 1
    }

    /// Mark before attempting disk I/O. A failed save must keep newer in-memory state dirty.
    func noteLocalMutation(_ url: URL) {
        localMutationRevision += 1
        dirtyPaths[url.standardizedFileURL.path] = localMutationRevision
        revision += 1
    }

    func noteLocalWrite(_ url: URL, data: Data) {
        dirtyPaths.removeValue(forKey: url.standardizedFileURL.path)
        localMutationRevision += 1
        consume(url, data: data)
        consumedStamps[url.standardizedFileURL.path] = Self.diskStamp(at: url)
    }

    /// True when the file may hold a revision this process never read or wrote. A save must not
    /// replace it before merging; the background scan reads it instead of the main thread.
    func diskHasUnseenRevision(at url: URL) -> Bool {
        guard let current = Self.diskStamp(at: url) else { return false }
        return consumedStamps[url.standardizedFileURL.path] != current
    }

    /// An undecodable scanned revision holds nothing to merge; a later save may replace it as before.
    func noteUnmergeableRevision(_ url: URL) {
        let path = url.standardizedFileURL.path
        if prefetched != nil, let stamp = prefetchedStamps[path] { consumedStamps[path] = stamp }
    }

    var isApplyingSnapshot: Bool { prefetched != nil }

    func hasDirtyLocalEdit(_ url: URL) -> Bool { dirtyPaths[url.standardizedFileURL.path] != nil }

    /// Only a successful explicit replacement may discard the failed edit it replaced.
    /// Capture before reading/publication; a synchronous subscriber can create a newer
    /// failed save before acknowledgement. Scans/consume never clear dirty ownership.
    func explicitReloadAcknowledgement(for url: URL) -> () -> Void {
        let path = url.standardizedFileURL.path
        let dirtyRevision = dirtyPaths[path]
        let explicit = prefetched == nil
        return {
            guard explicit, self.dirtyPaths[path] == dirtyRevision,
                  PomodoroDataDir.resolvedURL.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL else { return }
            self.dirtyPaths.removeValue(forKey: path)
        }
    }

    /// A reload consumes the exact background-read bytes, not a second synchronous cloud read.
    /// Failed/absent entries stay failed: never fall through to disk while applying a snapshot.
    func readData(from url: URL) throws -> Data {
        if let prefetched = prefetched {
            guard let result = prefetched[url.standardizedFileURL.path] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try result.get()
        }
        explicitReadStamps[url.standardizedFileURL.path] = Self.diskStamp(at: url)
        return try Data(contentsOf: url)
    }

    func fileExists(at url: URL) -> Bool {
        if let result = prefetched?[url.standardizedFileURL.path] {
            switch result {
            case .success: return true
            case .failure(let error): return !Self.isMissingFile(error)
            }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)) ||
               (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
    }

    #if os(macOS)
    /// Call after showing the launch window. Warm the shared managers synchronously inside a
    /// successful completion so their initial reads consume the accepted snapshot on main.
    func prepareForMacLaunch(completion: @escaping (Result<Void, Error>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.prepareForMacLaunch(completion: completion) }
            return
        }
        guard !preparingMacLaunch, !reading else {
            completion(.failure(CocoaError(.fileLocking)))
            return
        }
        preparingMacLaunch = true
        let identity = directoryIdentity()
        #if DEBUG
        let migrateLegacy = PomodoroDataDir.debugDirectoryOverride == nil
        #else
        let migrateLegacy = true
        #endif
        readerQueue.async {
            let stamps = Self.diskStamps(in: identity.url)
            let result = Result { try Self.readMacLaunchSnapshot(directory: identity.url, migrateLegacy: migrateLegacy) }
            DispatchQueue.main.async {
                guard self.directoryIdentity() == identity else {
                    self.preparingMacLaunch = false
                    completion(.failure(CocoaError(.userCancelled)))
                    return
                }
                switch result {
                case .success(let snapshot):
                    self.prefetched = snapshot
                    self.prefetchedStamps = stamps
                    self.prefetchedDirectory = identity.url
                    defer {
                        self.prefetched = nil
                        self.prefetchedStamps = [:]
                        self.prefetchedDirectory = nil
                        self.preparingMacLaunch = false
                    }
                    completion(.success(()))
                case .failure(let error):
                    self.preparingMacLaunch = false
                    completion(.failure(error))
                }
            }
        }
    }

    private static func readMacLaunchSnapshot(directory: URL, migrateLegacy: Bool) throws -> [String: Result<Data, Error>] {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        // A throwing directory read distinguishes denial from absence and may prompt for access.
        // Do it before any destination creation or legacy migration, on the reader queue.
        let parentEntries = Set(try fm.contentsOfDirectory(atPath: parent.path))
        do {
            _ = try fm.contentsOfDirectory(atPath: directory.path)
        } catch where isMissingFile(error) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch where isExistingFile(error) {
                _ = try fm.contentsOfDirectory(atPath: directory.path)
            }
        }

        let urls = PomodoroDataDir.dataFileNames.map { directory.appendingPathComponent($0) }
        var snapshot = try Dictionary(uniqueKeysWithValues: urls.map { url in
            (url.path, try readMacLaunchFile(at: url))
        })
        if migrateLegacy {
            for url in urls where parentEntries.contains(url.lastPathComponent) {
                guard case .failure = snapshot[url.path] else { continue }
                let oldURL = parent.appendingPathComponent(url.lastPathComponent)
                if case .success = try readMacLaunchFile(at: oldURL) {
                    do {
                        // moveItem fails if another writer creates the destination first.
                        try fm.moveItem(at: oldURL, to: url)
                    } catch where isMissingFile(error) || isExistingFile(error) {
                        // A concurrent move/create can change either path. Read the destination again.
                    }
                }
                snapshot[url.path] = try readMacLaunchFile(at: url)
            }
        }
        return snapshot
    }

    private static func readMacLaunchFile(at url: URL) throws -> Result<Data, Error> {
        do { return .success(try Data(contentsOf: url)) }
        catch let readError where isMissingFile(readError) {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch where isMissingFile(error) {
                return .failure(readError)
            }
            // A path that exists may have become readable or point at unavailable data.
            // A second missing read here is a startup error, not a signal to use defaults.
            return .success(try Data(contentsOf: url))
        }
    }

    private static func isExistingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError) ||
               (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.EEXIST.rawValue))
    }
    #endif

    /// Single-flight asynchronous polling, also used at launch and foreground activation.
    /// Explicit save-all callers wait for completion before writing their in-memory state.
    func syncFromDiskIfNeeded(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.syncFromDiskIfNeeded(completion: completion) }
            return
        }
        let directory = directoryIdentity().url
        if let completion = completion { completions.append(completion) }
        guard !reading else { return } // A slow download cannot queue an unbounded backlog.
        reading = true
        let requestedRevision = revision
        let requestedDirectoryGeneration = directoryGeneration
        readerQueue.async {
            let stamps = Self.diskStamps(in: directory)
            let snapshot = Dictionary(uniqueKeysWithValues: PomodoroDataDir.dataFileNames.map { name in
                let url = directory.appendingPathComponent(name)
                return (url.path, Result { try Data(contentsOf: url) })
            })
            DispatchQueue.main.async {
                // Keep the request in flight through publication, including synchronous subscribers.
                // A write/reload or a folder switch while reading invalidates the entire batch,
                // including grouped block files. An A→B→A switch is not the original generation.
                guard self.revision == requestedRevision,
                      self.directoryGeneration == requestedDirectoryGeneration,
                      PomodoroDataDir.resolvedURL.standardizedFileURL == directory else {
                    self.reading = false
                    self.syncFromDiskIfNeeded()
                    return
                }
                let changed = Set(PomodoroDataDir.dataFileNames.filter { name in
                    let path = directory.appendingPathComponent(name).path
                    guard self.dirtyPaths[path] == nil || Self.mergingFileNames.contains(name),
                          case .success(let data) = snapshot[path] else { return false }
                    return self.consumed[path] != data
                })
                for (path, stamp) in stamps {
                    // Same bytes under new metadata (e.g. a re-download) are not an unseen revision.
                    if case .success(let data) = snapshot[path], self.consumed[path] == data { self.consumedStamps[path] = stamp }
                }
                self.prefetched = snapshot
                self.prefetchedStamps = stamps
                self.prefetchedDirectory = directory
                let applyingMutationRevision = self.localMutationRevision
                let isCurrent = {
                    self.localMutationRevision == applyingMutationRevision &&
                        self.directoryGeneration == requestedDirectoryGeneration &&
                        PomodoroDataDir.resolvedURL.standardizedFileURL == directory
                }
                self.reload(changed: changed, isCurrent: isCurrent)
                let invalidatedDuringPublication = !isCurrent()
                self.prefetched = nil
                self.prefetchedStamps = [:]
                self.prefetchedDirectory = nil
                self.reading = false
                if invalidatedDuringPublication {
                    self.syncFromDiskIfNeeded()
                    return
                }
                let callbacks = self.completions
                self.completions.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }

    private func reload(changed: Set<String>, isCurrent: () -> Bool) {
        if isCurrent(), changed.contains("habitica_pomodoro_settings.json") { SettingsManager.shared.reload() }
        if isCurrent(),
           !changed.isDisjoint(with: ["habitica_pomodoro_block_progress.json", "habitica_pomodoro_block_history.json", "habitica_pomodoro_daily_blocks.json"]),
           canReloadBlocks() {
            BlockProgressManager.shared.reload()
        }
        if isCurrent(), changed.contains("habitica_pomodoro_top_three.json") { TopThreeManager.shared.reload() }
        if isCurrent(), changed.contains("habitica_pomodoro_plants.json") { PlantJournal.shared.reload() }
        if isCurrent(), changed.contains("habitica_pomodoro_histogram.json") { HistogramManager.shared.reload() }
        // Only successful manager decodes consume bytes; corrupt revisions remain retryable.
    }

    /// Block reload has migration/write side effects. A failed/corrupt or dirty companion must
    /// not trigger its backup fallback and overwrite another member of the three-file group.
    private func canReloadBlocks() -> Bool {
        guard let directory = prefetchedDirectory, let prefetched = prefetched else { return false }
        for name in ["habitica_pomodoro_block_progress.json", "habitica_pomodoro_block_history.json", "habitica_pomodoro_daily_blocks.json"] {
            let path = directory.appendingPathComponent(name).path
            guard dirtyPaths[path] == nil, let result = prefetched[path] else { return false }
            switch result {
            case .failure(let error):
                guard Self.isMissingFile(error) else { return false }
            case .success(let data):
                let decoder = JSONDecoder()
                switch name {
                case "habitica_pomodoro_block_progress.json":
                    if (try? decoder.decode(BlockProgress.self, from: data)) == nil { return false }
                case "habitica_pomodoro_block_history.json":
                    if (try? decoder.decode(BlockHistory.self, from: data)) == nil { return false }
                default:
                    if (try? decoder.decode(DailyBlocksHistory.self, from: data)) == nil { return false }
                }
            }
        }
        return true
    }

    func startMonitoring() {
        guard pollTimer == nil else { return }
        syncFromDiskIfNeeded()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.syncFromDiskIfNeeded() }
        pollTimer?.tolerance = 3
    }
}
