import Foundation

struct LogicalDayFixture: Decodable {
    let name, zone, instant, logicalDay, calendarDay: String
    let boundaryMinutes: Int
}

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POMO_FIXTURE_REPO_ROOT"]!)
let data = try Data(contentsOf: root.appendingPathComponent("parity/logical_day.json"))
let scenarios = try JSONDecoder().decode([LogicalDayFixture].self, from: data)
for item in scenarios {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: item.zone)!
    let date = ISO8601DateFormatter().date(from: item.instant)!
    var settings = UserSettings()
    settings.blockTimeRanges = [BlockTimeRange(startHour: item.boundaryMinutes / 60,
                                                startMinute: item.boundaryMinutes % 60,
                                                endHour: 0, endMinute: 0)]
    let logical = TopThreeManager.shared.logicalDateKey(settings: settings, date: date, calendar: calendar)
    let natural = FocusReview.dateKeyFormatter(calendar: calendar).string(from: date)
    precondition(logical == item.logicalDay && natural == item.calendarDay,
                 "\(item.name) logical \(logical), calendar \(natural)")
}
print("PASS \(scenarios.count) shared logical-day boundary scenarios")
