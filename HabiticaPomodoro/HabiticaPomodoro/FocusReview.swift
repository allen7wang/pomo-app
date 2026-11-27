import Foundation

enum FocusReviewRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var title: String { "\(rawValue) 天" }
}

struct FocusReviewBlock: Identifiable {
    let id: Int  // Zero-based index in the saved block records.
    let completedPomodoros: Int
    let isCompleted: Bool
    let goal: String?
    let shrubs: Int
    let trees: Int
    let wilted: Int
}

struct FocusReviewTask: Identifiable {
    let id: UUID
    let title: String
    let pomodoros: Int
    let minutes: Int

    static func summarize(_ sessions: [TaskFocusSession]) -> [Self] {
        Dictionary(grouping: sessions, by: \.taskId).compactMap { id, records in
            guard let latest = records.max(by: {
                ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString)
            }) else { return nil }
            return Self(id: id, title: latest.title, pomodoros: records.count,
                        minutes: records.reduce(0) { $0 + $1.minutes })
        }.sorted {
            if $0.minutes != $1.minutes { return $0.minutes > $1.minutes }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct FocusReviewDay: Identifiable {
    let id: String
    let date: Date
    let pomodoros: Int
    let minutes: Int
    let blocks: [FocusReviewBlock]
    var taskSessions: [TaskFocusSession] = []

    var tasks: [FocusReviewTask] { FocusReviewTask.summarize(taskSessions) }
    var chronologicalTaskSessions: [TaskFocusSession] {
        taskSessions.sorted { left, right in
            let leftStart = max(0, left.startedAt)
            let rightStart = max(0, right.startedAt)
            if leftStart != rightStart { return leftStart > rightStart }
            return left.id.uuidString < right.id.uuidString
        }
    }
    var hasRecords: Bool { pomodoros > 0 || minutes > 0 || !blocks.isEmpty || !taskSessions.isEmpty }
    var completedBlocks: Int { blocks.filter(\.isCompleted).count }
    var shrubs: Int { blocks.reduce(0) { $0 + $1.shrubs } }
    var trees: Int { blocks.reduce(0) { $0 + $1.trees } }
    var wilted: Int { blocks.reduce(0) { $0 + $1.wilted } }
}

struct FocusReviewTotals {
    var pomodoros = 0
    var minutes = 0
    var activeDays = 0
    var completedBlocks = 0
    var shrubs = 0
    var trees = 0
    var wilted = 0
}

/// An earlier review window. Pages are counted from a fixed anchor day, so a page
/// opened before midnight keeps showing the same dates afterwards.
struct FocusReviewWindow: Equatable {
    let anchor: Date
    let offset: Int

    static func previous(from current: FocusReviewWindow?, today: Date) -> FocusReviewWindow {
        let page = current ?? FocusReviewWindow(anchor: today, offset: 0)
        return FocusReviewWindow(anchor: page.anchor, offset: page.offset - 1)
    }

    func endDate(range: FocusReviewRange, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: offset * range.rawValue, to: anchor).map { calendar.startOfDay(for: $0) }
    }

    /// nil means the next window reaches today, i.e. return to the rolling window.
    func next(today: Date, range: FocusReviewRange, calendar: Calendar = .current) -> FocusReviewWindow? {
        let next = FocusReviewWindow(anchor: anchor, offset: offset + 1)
        guard let end = next.endDate(range: range, calendar: calendar), end < calendar.startOfDay(for: today) else { return nil }
        return next
    }
}

/// A read-only projection of the existing calendar-day stores.
struct FocusReview {
    let days: [FocusReviewDay]
    let totals: FocusReviewTotals

    var startKey: String { days.first?.id ?? "" }
    var endKey: String { days.last?.id ?? "" }
    var hasRecords: Bool { days.contains(where: \.hasRecords) }
    var tasks: [FocusReviewTask] { FocusReviewTask.summarize(days.flatMap(\.taskSessions)) }

    init(range: FocusReviewRange, now: Date, histogram: Histogram, dailyBlocks: DailyBlocksHistory,
         blockHistory: BlockHistory, plants: [String: PlantDay], calendar: Calendar = .current) {
        let formatter = Self.dateKeyFormatter(calendar: calendar)
        let today = calendar.startOfDay(for: now)

        days = (0..<range.rawValue).reversed().compactMap { offset in
            guard let offsetDate = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let date = calendar.startOfDay(for: offsetDate)
            let key = formatter.string(from: date)
            return Self.day(key: key, date: date, focus: histogram[key], daily: dailyBlocks[key],
                            history: blockHistory[key] ?? [], plants: plants[key])
        }

        totals = days.reduce(into: FocusReviewTotals()) { totals, day in
            totals.pomodoros += day.pomodoros
            totals.minutes += day.minutes
            if day.pomodoros > 0 || day.minutes > 0 { totals.activeDays += 1 }
            totals.completedBlocks += day.completedBlocks
            totals.shrubs += day.shrubs
            totals.trees += day.trees
            totals.wilted += day.wilted
        }
    }

    func selectedDay(_ key: String?) -> FocusReviewDay? {
        if let key, let day = days.first(where: { $0.id == key }) { return day }
        return days.last(where: \.hasRecords) ?? days.last
    }

    static func earliestDate(histogram: Histogram, dailyBlocks: DailyBlocksHistory, blockHistory: BlockHistory,
                             plants: [String: PlantDay], calendar: Calendar = .current) -> Date? {
        let formatter = dateKeyFormatter(calendar: calendar)
        let keys = Set(histogram.keys).union(dailyBlocks.keys).union(blockHistory.keys).union(plants.keys)
        for key in keys.sorted() {
            guard let date = formatter.date(from: key), formatter.string(from: date) == key else { continue }
            if day(key: key, date: date, focus: histogram[key], daily: dailyBlocks[key],
                   history: blockHistory[key] ?? [], plants: plants[key]).hasRecords {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    var csv: String {
        let header = "date,pomodoros,minutes,completed_blocks,shrubs,trees,wilted"
        let rows = days.map { day in
            "\(day.id),\(day.pomodoros),\(day.minutes),\(day.completedBlocks),\(day.shrubs),\(day.trees),\(day.wilted)"
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    /// macOS and iOS name the same exported range identically.
    var csvFilename: String { "专注复盘-\(startKey)-\(endKey).csv" }

    var taskCSV: String {
        let rows = days.flatMap { day in
            day.taskSessions.sorted { $0.id.uuidString < $1.id.uuidString }.map { session in
                "\(day.id),\(Self.csvCell(session.taskId.uuidString)),\(Self.csvCell(session.title)),\(session.minutes)"
            }
        }
        return (["date,task_id,task_title,minutes"] + rows).joined(separator: "\r\n") + "\r\n"
    }

    var taskCSVFilename: String { "任务专注-\(startKey)-\(endKey).csv" }

    private static func csvCell(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let formula = first.map { "=+-@＝＋－＠".contains($0) } == true
        let control = value.first.map { $0.isNewline || $0 == "\t" } == true
        return "\"" + (formula || control ? "'" : "") + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func dateKeyFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func day(key: String, date: Date, focus: DayHistogram?, daily: DailyBlockProgress?,
                            history: [BlockHistoryEntry], plants: PlantDay?) -> FocusReviewDay {
        FocusReviewDay(id: key, date: date, pomodoros: max(0, focus?.pomodoros ?? 0),
                       minutes: max(0, focus?.minutes ?? 0), blocks: blocks(daily: daily, history: history, plants: plants),
                       taskSessions: focus?.taskSessions ?? [])
    }

    private static func blocks(daily: DailyBlockProgress?, history: [BlockHistoryEntry],
                               plants: PlantDay?) -> [FocusReviewBlock] {
        let progress = daily?.blockProgress ?? []
        let goals = daily?.blockGoals ?? []
        let attempts = plants?.attempts ?? []
        let treeCounts = plants?.trees ?? []
        // UserSettings supports up to 24 blocks, including blocks from older configurations.
        let validIndices = 0..<24
        let historyByBlock = Dictionary(grouping: history.filter { validIndices.contains($0.blockIndex) }, by: \.blockIndex)
        let storedBlockCount = min(validIndices.count, max(progress.count, attempts.count, treeCounts.count))
        let indices = Set(0..<storedBlockCount).union(historyByBlock.keys)

        return indices.sorted().compactMap { index in
            let entries = historyByBlock[index] ?? []
            let historicalCount = entries.map(\.pomodoros).max() ?? 0
            // A saved zero can be an explicit reset. Use the historical count only when absent.
            let count = max(0, progress.indices.contains(index) ? progress[index] : historicalCount)
            let isCompleted = entries.contains(where: \.isComplete)
            let outcomes = attempts.indices.contains(index) ? attempts[index] : []
            let shrubs = outcomes.filter { $0 == .shrub }.count
            let trees = treeCounts.indices.contains(index) ? max(0, treeCounts[index]) : 0
            let wilted = outcomes.count - shrubs
            guard count > 0 || isCompleted || shrubs > 0 || trees > 0 || wilted > 0 else { return nil }
            let goal = goals.indices.contains(index) ? goals[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return FocusReviewBlock(id: index, completedPomodoros: count, isCompleted: isCompleted,
                                    goal: goal.isEmpty ? nil : goal, shrubs: shrubs, trees: trees, wilted: wilted)
        }
    }
}
