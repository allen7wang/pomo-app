import Foundation
import Combine

// MARK: - Block Progress Manager (块进度管理)
class BlockProgressManager: ObservableObject {
    static let shared = BlockProgressManager()

    @Published var blockProgress: BlockProgress
    @Published var blockHistory: BlockHistory
    @Published var dailyBlocksHistory: DailyBlocksHistory

    private let progressFileName = "habitica_pomodoro_block_progress.json"
    private let historyFileName = "habitica_pomodoro_block_history.json"
    private let dailyBlocksFileName = "habitica_pomodoro_daily_blocks.json"

    private static func getDocumentsDirectory() -> URL {
        PomodoroDataDir.url
    }

    private var progressFileURL: URL { Self.getDocumentsDirectory().appendingPathComponent(progressFileName) }
    private var historyFileURL: URL { Self.getDocumentsDirectory().appendingPathComponent(historyFileName) }
    private var dailyBlocksFileURL: URL { Self.getDocumentsDirectory().appendingPathComponent(dailyBlocksFileName) }

    private let localBackupProgressKey = "habitica_pomodoro_block_progress_backup"
    private let localBackupHistoryKey = "habitica_pomodoro_block_history_backup"
    private let localBackupDailyBlocksKey = "habitica_pomodoro_daily_blocks_backup"

    init() {
        let docsDir = Self.getDocumentsDirectory()

        // Load block progress
        if let loadedProgress = Self.loadFile(BlockProgress.self, from: docsDir.appendingPathComponent(progressFileName)) {
            blockProgress = loadedProgress
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupProgressKey),
                  let decoded = try? JSONDecoder().decode(BlockProgress.self, from: data) {
            blockProgress = decoded
        } else {
            blockProgress = BlockProgress()
        }

        // Load block history
        if let loadedHistory = Self.loadFile([String: [BlockHistoryEntry]].self, from: docsDir.appendingPathComponent(historyFileName)) {
            blockHistory = loadedHistory
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupHistoryKey),
                  let decoded = try? JSONDecoder().decode([String: [BlockHistoryEntry]].self, from: data) {
            blockHistory = decoded
        } else {
            blockHistory = [:]
        }

        // Load daily blocks history
        if let loadedDaily = Self.loadFile(DailyBlocksHistory.self, from: docsDir.appendingPathComponent(dailyBlocksFileName)) {
            dailyBlocksHistory = loadedDaily
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupDailyBlocksKey),
                  let decoded = try? JSONDecoder().decode(DailyBlocksHistory.self, from: data) {
            dailyBlocksHistory = decoded
        } else {
            dailyBlocksHistory = [:]
        }

        // 检查是否需要重置新一天的块
        resetIfNeeded()
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

    private static func saveFile<T: Codable>(_ data: T, to url: URL) -> Bool {
        PomodoroFileChanges.shared.noteLocalMutation(url)
        do {
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let jsonData: Data
            if let dataAsData = data as? Data {
                jsonData = dataAsData
            } else {
                jsonData = try JSONEncoder().encode(data)
            }
            try jsonData.write(to: url, options: .atomic)
            PomodoroDataDir.noteLocalWrite(url.lastPathComponent, data: jsonData)
            print("Saved to: \(url.path)")
            return true
        } catch {
            print("Error saving to \(url.path): \(error)")
            return false
        }
    }

    @discardableResult
    func saveProgress() -> Bool {
        let saved = Self.saveFile(blockProgress, to: progressFileURL)

        if let data = try? JSONEncoder().encode(blockProgress) {
            PomodoroDataDir.backupDefaults?.set(data, forKey: localBackupProgressKey)
        }
        return saved
    }

    @discardableResult
    func saveHistory() -> Bool {
        let saved = Self.saveFile(blockHistory, to: historyFileURL)

        if let data = try? JSONEncoder().encode(blockHistory) {
            PomodoroDataDir.backupDefaults?.set(data, forKey: localBackupHistoryKey)
        }
        return saved
    }

    @discardableResult
    func saveDailyBlocks() -> Bool {
        let saved = Self.saveFile(dailyBlocksHistory, to: dailyBlocksFileURL)

        if let data = try? JSONEncoder().encode(dailyBlocksHistory) {
            PomodoroDataDir.backupDefaults?.set(data, forKey: localBackupDailyBlocksKey)
        }
        return saved
    }

    /// 数据目录变化后（如 iOS 授权 iCloud 文件夹）重新加载全部三类数据
    func reload() {
        let acknowledgeProgress = PomodoroFileChanges.shared.explicitReloadAcknowledgement(for: progressFileURL)
        let acknowledgeHistory = PomodoroFileChanges.shared.explicitReloadAcknowledgement(for: historyFileURL)
        let acknowledgeDaily = PomodoroFileChanges.shared.explicitReloadAcknowledgement(for: dailyBlocksFileURL)
        if let loaded = Self.loadFile(BlockProgress.self, from: progressFileURL) {
            blockProgress = loaded
            acknowledgeProgress()
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupProgressKey),
                  let decoded = try? JSONDecoder().decode(BlockProgress.self, from: data) {
            blockProgress = decoded
        } else {
            blockProgress = BlockProgress()
        }

        if let loaded = Self.loadFile([String: [BlockHistoryEntry]].self, from: historyFileURL) {
            blockHistory = loaded
            acknowledgeHistory()
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupHistoryKey),
                  let decoded = try? JSONDecoder().decode([String: [BlockHistoryEntry]].self, from: data) {
            blockHistory = decoded
        } else {
            blockHistory = [:]
        }

        if let loaded = Self.loadFile(DailyBlocksHistory.self, from: dailyBlocksFileURL) {
            dailyBlocksHistory = loaded
            acknowledgeDaily()
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupDailyBlocksKey),
                  let decoded = try? JSONDecoder().decode(DailyBlocksHistory.self, from: data) {
            dailyBlocksHistory = decoded
        } else {
            dailyBlocksHistory = [:]
        }

        resetIfNeeded()
        print("BlockProgress reloaded from: \(progressFileURL.path)")
    }

    private func todayKey(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // 检查是否需要重置新一天的块
    private func resetIfNeeded() {
        let today = todayKey()
        if let lastEntry = getLatestBlockEntry(),
           lastEntry.date != today {
            // 新的一天，重置块进度
            blockProgress.resetBlock()
            saveProgress()
        }
    }

    private func getLatestBlockEntry() -> BlockHistoryEntry? {
        guard !blockHistory.isEmpty else { return nil }
        let sortedDates = blockHistory.keys.sorted()
        if let lastDate = sortedDates.last,
           let entries = blockHistory[lastDate],
           let lastEntry = entries.last {
            return lastEntry
        }
        return nil
    }

    // Cached count is always derived from the owning calendar day's durable daily store.
    func updateBlockIndexFromTime(settings: UserSettings, date: Date = Date()) {
        let ranges = Array(settings.blockTimeRanges.prefix(settings.blockCount))
        let index = BlockProgress.getCurrentBlockIndex(timeRanges: ranges, date: date)
            ?? min(max(0, blockProgress.currentBlockIndex), settings.blockCount - 1)
        let key = todayKey(date: date)
        let saved = dailyBlocksHistory[key]?.blockProgress ?? []
        let count = saved.indices.contains(index) ? saved[index] : 0
        if blockProgress.currentBlockIndex != index || blockProgress.progressDate != key || blockProgress.blockPomoCounter != count {
            blockProgress.currentBlockIndex = index
            blockProgress.progressDate = key
            blockProgress.blockPomoCounter = count
            saveProgress()
        }
    }

    func recordPomoInCurrentBlock(settings: UserSettings, comboCompleted: Bool = false, date: Date = Date()) {
        updateBlockIndexFromTime(settings: settings, date: date)
        let key = todayKey(date: date)
        let index = blockProgress.currentBlockIndex
        var daily = dailyBlocksHistory[key] ?? DailyBlockProgress(
            date: key, blockProgress: Array(repeating: 0, count: settings.blockCount), blockGoals: settings.blockGoals
        )
        while daily.blockProgress.count <= index { daily.blockProgress.append(0) }
        daily.blockProgress[index] += 1
        daily.blockGoals = settings.blockGoals
        blockProgress.blockPomoCounter = daily.blockProgress[index]
        dailyBlocksHistory[key] = daily
        saveProgress()
        saveDailyBlocks()
        PlantJournal.shared.recordCompletion(blockIndex: index, completed: daily.blockProgress[index], comboCompleted: comboCompleted, date: date)
    }

    /// Reset the active block in both stores so the next completion cannot restore its old count.
    func resetCurrentBlockProgress(settings: UserSettings) {
        updateBlockIndexFromTime(settings: settings)
        let index = blockProgress.currentBlockIndex
        blockProgress.blockPomoCounter = 0
        saveProgress()
        let today = todayKey()
        if var daily = dailyBlocksHistory[today], daily.blockProgress.indices.contains(index) {
            daily.blockProgress[index] = 0
            dailyBlocksHistory[today] = daily
            saveDailyBlocks()
        }
    }

    // 放弃进行中的 pomo：只记枯萎，不增加完成数。
    func recordAbandonedPomo(settings: UserSettings) {
        updateBlockIndexFromTime(settings: settings)
        let index = blockProgress.currentBlockIndex
        let progress = dailyBlocksHistory[todayKey()]?.blockProgress ?? []
        let completed = progress.indices.contains(index) ? progress[index] : 0
        PlantJournal.shared.recordAbandonment(blockIndex: index, completed: completed)
    }

    /// Claim a block completion once per calendar date/index, including after reset/relaunch.
    @discardableResult
    func recordBlockComplete(settings: UserSettings, date: Date = Date()) -> Bool {
        let key = todayKey(date: date)
        let index = blockProgress.currentBlockIndex
        guard !(blockHistory[key] ?? []).contains(where: { $0.blockIndex == index && $0.isComplete }) else { return false }
        let counts = progress(settings: settings, date: date)
        let count = counts.indices.contains(index) ? counts[index] : 0
        guard count >= settings.blockPomoCount else { return false }
        let entry = BlockHistoryEntry(date: key, blockIndex: index, pomodoros: count, isComplete: true, completedAt: date)
        blockHistory[key, default: []].append(entry)
        saveHistory()
        return true
    }

    func getTodayBlockProgress(settings: UserSettings) -> [Int] { progress(settings: settings) }
    func progress(settings: UserSettings, date: Date = Date()) -> [Int] {
        var counts = dailyBlocksHistory[todayKey(date: date)]?.blockProgress ?? []
        while counts.count < settings.blockCount { counts.append(0) }
        return Array(counts.prefix(settings.blockCount))
    }

    // 获取当前块完成进度（基于时间）
    func getCurrentBlockCompletion(settings: UserSettings) -> (completed: Int, total: Int) {
        updateBlockIndexFromTime(settings: settings)
        let progress = getTodayBlockProgress(settings: settings)
        if blockProgress.currentBlockIndex < progress.count {
            return (progress[blockProgress.currentBlockIndex], settings.blockPomoCount)
        }
        return (0, settings.blockPomoCount)
    }

    // 清空历史
    func clearHistory() {
        blockHistory = [:]
        dailyBlocksHistory = [:]
        blockProgress.resetBlock()
        saveProgress()
        saveHistory()
        saveDailyBlocks()
        PlantJournal.shared.clear()
    }

    // 获取今天的块历史
    func getTodayBlocks() -> [BlockHistoryEntry] {
        return blockHistory[todayKey()] ?? []
    }
}
