import Foundation
import Combine

// MARK: - Settings Manager (persisted via iCloud)
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// In-memory identity epoch: A→B→A must differ from the original A session.
    private(set) var habiticaAccountGeneration: UInt64 = 0

    @Published var settings: UserSettings {
        didSet {
            guard !isNormalizing else { return }
            isNormalizing = true
            var normalized = settings
            normalized.normalize()
            if Self.habiticaIdentity(oldValue) != Self.habiticaIdentity(normalized) {
                habiticaAccountGeneration &+= 1
            }
            settings = normalized
            isNormalizing = false
            if !isReloading { save() }
        }
    }

    /// Match the API's effective root without initializing HabiticaAPI.shared during startup.
    private static func habiticaIdentity(_ settings: UserSettings) -> [String] {
        let rootOverride = settings.developerServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = rootOverride.isEmpty ? HabiticaConsts.serverUrl : rootOverride
        var root = ""
        if var parts = URLComponents(string: configured), parts.scheme?.lowercased() == "https",
           let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
           parts.query == nil, parts.fragment == nil {
            parts.scheme = "https"
            parts.host = host.lowercased()
            if parts.port == 443 { parts.port = nil }
            while parts.path.hasSuffix("/") { parts.path.removeLast() }
            parts.path += "/"
            root = parts.string ?? ""
        }
        return [settings.connectHabitica ? "1" : "0", settings.uid, settings.apiToken, root]
    }

    private var isNormalizing = false
    private var isReloading = false
    private let fileName = "habitica_pomodoro_settings.json"
    private var fileURL: URL {
        PomodoroDataDir.fileURL(fileName)
    }

    private let localBackupKey = "habitica_pomodoro_settings_backup"

    init() {
        // 迁移旧文件到隐藏文件夹
        PomodoroDataDir.migrateOldFiles()

        // Initialize settings first
        self.settings = UserSettings()

        // Load from iCloud or local fallback
        if let loadedSettings = Self.loadFile(UserSettings.self, from: fileURL) {
            self.settings = loadedSettings
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupKey),
                  let decoded = try? JSONDecoder().decode(UserSettings.self, from: data) {
            self.settings = decoded
        }
    }

    private static func getDocumentsDirectory() -> URL {
        PomodoroDataDir.url
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

    private static func saveFile(_ data: Data, to url: URL) -> Bool {
        do {
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
            PomodoroDataDir.noteLocalWrite(url.lastPathComponent, data: data)
            print("Saved to: \(url.path)")
            return true
        } catch {
            print("Error saving to \(url.path): \(error)")
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        PomodoroFileChanges.shared.noteLocalMutation(fileURL)
        var saved = false
        if let data = try? JSONEncoder().encode(settings) {
            // Save to file
            saved = Self.saveFile(data, to: fileURL)
            if saved {
                print("Settings saved to: \(fileURL.path)")
            }

            // Also save to UserDefaults as backup
            PomodoroDataDir.backupDefaults?.set(data, forKey: localBackupKey)
        }
        #if os(iOS)
        BlockNotificationManager.shared.refreshScheduledReminders(settings: settings)
        #endif
        return saved
    }

    /// 数据目录变化后（如 iOS 授权 iCloud 文件夹）重新加载
    func reload() {
        isReloading = true
        defer { isReloading = false }
        let acknowledge = PomodoroFileChanges.shared.explicitReloadAcknowledgement(for: fileURL)
        if let loaded = Self.loadFile(UserSettings.self, from: fileURL) {
            settings = loaded
            acknowledge()
        } else if let data = PomodoroDataDir.backupDefaults?.data(forKey: localBackupKey),
                  let decoded = try? JSONDecoder().decode(UserSettings.self, from: data) {
            settings = decoded
        }
        print("Settings reloaded from: \(fileURL.path)")
    }
}
