import Foundation
import Combine

// MARK: - Histogram Manager
class HistogramManager: ObservableObject {
    static let shared = HistogramManager()

    @Published var histogram: Histogram

    private let key = "habitica_pomodoro_histogram" // keep the original backup key for migration
    private let fileName = "habitica_pomodoro_histogram.json"
    private var fileURL: URL { PomodoroDataDir.fileURL(fileName) }
    private var loadedHistogram: Histogram = [:]
    private var loadedData: Data?
    private var loadedPath: String?

    private static func backupPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func rememberBackup(_ data: Data, at url: URL) {
        let key = "habitica_pomodoro_histogram"
        let path = backupPath(url)
        var backups = PomodoroDataDir.backupDefaults?.dictionary(forKey: key + "_backupsByPath") ?? [:]
        backups[path] = data
        PomodoroDataDir.backupDefaults?.set(backups, forKey: key + "_backupsByPath")
        // Atomic (data, path) pair in ONE write: a crash between writes can never leave
        // new data paired with a stale recorded path (or vice versa).
        PomodoroDataDir.backupDefaults?.set(["path": path, "data": data], forKey: key + "_backupEntry")
        // Legacy contract for older readers (best-effort; no longer the recovery source of truth).
        PomodoroDataDir.backupDefaults?.set(data, forKey: key)
        PomodoroDataDir.backupDefaults?.set(path, forKey: key + "_backupPath")
    }

    private static func backup(at url: URL) -> Histogram? {
        let key = "habitica_pomodoro_histogram"
        let path = backupPath(url)
        var data = PomodoroDataDir.backupDefaults?.dictionary(forKey: key + "_backupsByPath")?[path] as? Data
        // Prefer the atomic entry: its data is only ever paired with its own path.
        if data == nil,
           let entry = PomodoroDataDir.backupDefaults?.dictionary(forKey: key + "_backupEntry"),
           (entry["path"] as? String) == path {
            data = entry["data"] as? Data
        }
        let legacyPath = PomodoroDataDir.backupDefaults?.string(forKey: key + "_backupPath")
        // Ownerless old backup belongs only to the original sandbox/Documents store, not a grant.
        // Require explicit proof the legacy backup matches the target path; absence of metadata
        // means unknown provenance and must not be auto-attributed.
        if data == nil, legacyPath == path {
            data = PomodoroDataDir.backupDefaults?.data(forKey: key)
        }
        return data.flatMap { try? JSONDecoder().decode(Histogram.self, from: $0) }
    }

    init() {
        let url = PomodoroDataDir.fileURL("habitica_pomodoro_histogram.json")
        if let data = try? PomodoroFileChanges.shared.readData(from: url), let decoded = try? JSONDecoder().decode(Histogram.self, from: data) {
            histogram = decoded
            loadedHistogram = decoded
            loadedData = data
            loadedPath = url.path
            PomodoroFileChanges.shared.consume(url, data: data)
            Self.rememberBackup(data, at: url)
        } else if let decoded = Self.backup(at: url) {
            histogram = decoded
            // Only migrate when absent, never overwrite an unreadable existing file.
            if !PomodoroFileChanges.shared.fileExists(at: url) { save() }
        } else { histogram = [:] }
        loadedHistogram = histogram
        loadedPath = url.path
    }

    func reload() {
        let url = fileURL
        let samePath = loadedPath == url.path
        let acknowledge = PomodoroFileChanges.shared.explicitReloadAcknowledgement(for: url)
        var replacedDirtyState = false
        if let data = try? PomodoroFileChanges.shared.readData(from: url), let decoded = try? JSONDecoder().decode(Histogram.self, from: data) {
            // Same-path reload merges unsaved deltas rather than discarding them.
            replacedDirtyState = !samePath || histogram == loadedHistogram
            histogram = samePath ? mergingUnwrittenChanges(into: decoded) : decoded
            loadedHistogram = decoded
            loadedData = data
            loadedPath = url.path
            PomodoroFileChanges.shared.consume(url, data: data)
            Self.rememberBackup(data, at: url)
        } else if samePath && PomodoroFileChanges.shared.fileExists(at: url) {
            return // Same-path corruption retains unsaved cache, without acknowledging bad bytes.
        } else {
            // A directory switch must never display or apply deltas from the previous folder.
            histogram = Self.backup(at: url) ?? [:]
            loadedHistogram = histogram
            loadedData = nil
            loadedPath = url.path
        }
        NotificationCenter.default.post(name: .histogramChanged, object: nil)
        if replacedDirtyState { acknowledge() }
    }

    /// Narrow read-before-write protection, not a distributed conflict-resolution protocol.
    /// Untouched days come from disk; unsaved local increments are applied as deltas to that file.
    private func mergingUnwrittenChanges(into remote: Histogram) -> Histogram {
        var merged = remote
        for date in Set(loadedHistogram.keys).union(histogram.keys) {
            let local = histogram[date]
            let base = loadedHistogram[date]
            guard local != base else { continue }
            guard let local = local else { merged.removeValue(forKey: date); continue }
            var day = remote[date] ?? DayHistogram(pomodoros: 0, minutes: 0, weekday: local.weekday)
            day.pomodoros = max(0, day.pomodoros + local.pomodoros - (base?.pomodoros ?? 0))
            day.minutes = max(0, day.minutes + local.minutes - (base?.minutes ?? 0))
            if day.weekday.isEmpty { day.weekday = local.weekday }
            merged[date] = day
        }
        return merged
    }
    func todayKey(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    func weekday(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
    func getToday() -> DayHistogram? { histogram[todayKey()] }
    func incrementToday(pomodoros: Int, minutes: Int, date: Date = Date()) {
        let dateKey = todayKey(date: date)
        var day = histogram[dateKey] ?? DayHistogram(pomodoros: 0, minutes: 0, weekday: weekday(date: date))
        day.pomodoros += pomodoros
        day.minutes += minutes
        histogram[dateKey] = day
        save()
    }
    func clear() {
        reload() // Consume any arrived file before the user's explicit destructive clear.
        histogram = [:]
        save(replacingAll: true)
        // Update the timer's cached Today count too.
        NotificationCenter.default.post(name: .histogramChanged, object: nil)
    }
    @discardableResult
    func save(replacingAll: Bool = false) -> Bool {
        PomodoroFileChanges.shared.noteLocalMutation(fileURL)
        if loadedPath != fileURL.path {
            reload()
            // The explicit path replacement may acknowledge the previous dirty value;
            // this save attempt must still own dirty protection if its write fails.
            PomodoroFileChanges.shared.noteLocalMutation(fileURL)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let disk = try? Data(contentsOf: fileURL),
                  let remote = try? JSONDecoder().decode(Histogram.self, from: disk) else {
                if let data = try? JSONEncoder().encode(histogram) { Self.rememberBackup(data, at: fileURL) }
                return false
            }
            if disk != loadedData || loadedPath != fileURL.path {
                if !replacingAll {
                    histogram = loadedPath == fileURL.path ? mergingUnwrittenChanges(into: remote) : remote
                }
                loadedHistogram = remote
                loadedData = disk
                loadedPath = fileURL.path
                PomodoroFileChanges.shared.consume(fileURL, data: disk)
            }
        }
        guard let data = try? JSONEncoder().encode(histogram) else { return false }
        Self.rememberBackup(data, at: fileURL)
        do {
            try data.write(to: fileURL, options: .atomic)
            loadedHistogram = histogram
            loadedData = data
            loadedPath = fileURL.path
            PomodoroDataDir.noteLocalWrite(fileName, data: data)
            NotificationCenter.default.post(name: .histogramChanged, object: nil)
            return true
        } catch {
            print("Error saving histogram: \(error)")
            return false
        }
    }

    // Statistics
    var totalPomodoros: Int { histogram.values.reduce(0) { $0 + $1.pomodoros } }
    var totalHours: Double { Double(histogram.values.reduce(0) { $0 + $1.minutes }) / 60.0 }
    var avgPomodoros: Double { histogram.isEmpty ? 0 : Double(totalPomodoros) / Double(histogram.count) }
    var avgHours: Double { histogram.isEmpty ? 0 : totalHours / Double(histogram.count) }

    // Sorted entries for chart
    var sortedEntries: [(date: String, day: DayHistogram)] {
        histogram.sorted { $0.key < $1.key }.map { (date: $0.key, day: $0.value) }
    }
}
