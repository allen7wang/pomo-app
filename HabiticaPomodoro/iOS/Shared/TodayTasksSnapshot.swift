import Foundation

// Shared by the app (writer) and the widget extension (reader). The extension cannot
// see the app's sandbox or its iCloud folder bookmark, so the app copies a small
// summary of today's Top3 into the App Group container.

struct TodayTasksSnapshot: Codable, Equatable {
    struct Category: Codable, Equatable, Identifiable {
        var id: Int
        var name: String
        var done: Int
        var total: Int
        /// First unfinished titles, for the medium widget.
        var openTitles: [String]
    }

    /// Logical day (first block start is the day boundary, same as the Task tab).
    var dayKey: String
    var boundaryMinutes: Int
    var categories: [Category]
    /// Skin accent (0xRRGGBB) so the widget follows the app's palette.
    var accentRGB: UInt32?

    var done: Int { categories.reduce(0) { $0 + $1.done } }
    var total: Int { categories.reduce(0) { $0 + $1.total } }

    static func logicalDayKey(boundaryMinutes: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let minuteOfDay = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let logical = minuteOfDay < boundaryMinutes ? (calendar.date(byAdding: .day, value: -1, to: now) ?? now) : now
        // Same formatter configuration as TopThreeManager.logicalDateKey, which wrote dayKey.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: logical)
    }

    /// Next moment the logical day flips, so the widget stops showing yesterday's list.
    static func nextBoundary(after now: Date, boundaryMinutes: Int, calendar: Calendar = .current) -> Date {
        let boundary = DateComponents(hour: boundaryMinutes / 60, minute: boundaryMinutes % 60)
        return calendar.nextDate(after: now, matching: boundary, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86_400)
    }
}

/// Locates the App Group container under whichever signing route installed the app.
///
/// Xcode signing keeps `group.com.hermes.habitica-pomodoro`; AltStore/SideStore register
/// `<group>.<TEAMID>` and list it in `ALTAppGroups`; other re-signers may only expose the
/// granted group in `embedded.mobileprovision`; some free re-signers drop it entirely,
/// in which case the widget shows a placeholder instead of data.
enum SharedAppGroup {
    static let baseIdentifier = "group.com.hermes.habitica-pomodoro"

    static let containerURL: URL? = {
        for identifier in candidates() {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return url
            }
        }
        return nil
    }()

    static func candidates(bundle: Bundle = .main) -> [String] {
        var identifiers = (bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? []
        identifiers += provisionedGroups(bundle: bundle)
        identifiers.append(baseIdentifier)
        var seen = Set<String>()
        return identifiers.filter {
            ($0 == baseIdentifier || $0.hasPrefix(baseIdentifier + ".")) && seen.insert($0).inserted
        }
    }

    /// The signed profile is a CMS envelope around a plain XML plist; reading the plist
    /// slice is enough to learn which groups this signature actually grants.
    static func provisionedGroups(bundle: Bundle = .main) -> [String] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound],
                                                                      format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }
}

enum TodayTasksSnapshotStore {
    static let widgetKind = "TodayTasksHome"
    private static let fileName = "today-tasks.json"

    static var fileURL: URL? {
        SharedAppGroup.containerURL?.appendingPathComponent(fileName)
    }

    static func load() -> TodayTasksSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TodayTasksSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: TodayTasksSnapshot) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            // Readable by the widget while the phone is locked after the first unlock.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}
