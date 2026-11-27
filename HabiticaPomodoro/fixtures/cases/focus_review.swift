import Foundation

struct SharedFocusReviewDataset: Decodable {
    struct Window: Decodable {
        let days, pomodoros, minutes, activeDays: Int
        let start, end, defaultDay: String
        let csvRows: [String]?
    }
    struct TaskTimeline: Decodable {
        let day, legacyDay, sessionOnlyDay: String
        let histogram: Histogram
        let orderedIDs: [UUID]
        let taskCSVRows: [String]
    }
    let instant, zone, earliest: String
    let histogram: Histogram
    let dailyBlocks: DailyBlocksHistory
    let blockHistory: BlockHistory
    let plants: [String: PlantDay]
    let windows: [Window]
    let taskTimeline: TaskTimeline
}

let parityRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POMO_FIXTURE_REPO_ROOT"]!)
    .appendingPathComponent("parity")
let dataset = try JSONDecoder().decode(SharedFocusReviewDataset.self,
                                       from: Data(contentsOf: parityRoot.appendingPathComponent("focus_review.json")))
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: dataset.zone)!
let now = ISO8601DateFormatter().date(from: dataset.instant)!
let (histogram, dailyBlocks, blockHistory, plants) = (dataset.histogram, dataset.dailyBlocks, dataset.blockHistory, dataset.plants)

for window in dataset.windows {
    let report = FocusReview(range: FocusReviewRange(rawValue: window.days)!, now: now, histogram: histogram,
                             dailyBlocks: dailyBlocks, blockHistory: blockHistory, plants: plants, calendar: calendar)
    precondition(report.days.count == window.days && report.startKey == window.start && report.endKey == window.end)
    precondition(report.totals.pomodoros == window.pomodoros && report.totals.minutes == window.minutes &&
                 report.totals.activeDays == window.activeDays)
    precondition(report.selectedDay(nil)?.id == window.defaultDay)
    if let rows = window.csvRows {
        precondition(Array(report.csv.utf8) == Array((rows.joined(separator: "\r\n") + "\r\n").utf8))
    }
}
print("PASS shared 7/30/90-day metrics, selection and 7/30-day CSV bytes")

let review = FocusReview(range: .week, now: now, histogram: histogram, dailyBlocks: dailyBlocks,
                         blockHistory: blockHistory, plants: plants, calendar: calendar)
precondition(review.days.map(\.id) == (6...12).map { String(format: "2024-03-%02d", $0) })
precondition(review.days.allSatisfy { calendar.component(.hour, from: $0.date) == 0 })
precondition(review.startKey == "2024-03-06" && review.endKey == "2024-03-12")
precondition(review.hasRecords && !review.days[0].hasRecords && !review.days[2].hasRecords)
precondition(review.totals.pomodoros == 3 && review.totals.minutes == 60 && review.totals.activeDays == 2)
print("PASS calendar-day range, DST, zero-filled days and histogram-only focus totals")

let legacy = review.days[1]
precondition(legacy.hasRecords && legacy.completedBlocks == 1 && legacy.shrubs == 0)
precondition(legacy.blocks.count == 1 && legacy.blocks[0].id == 4 && legacy.blocks[0].completedPomodoros == 3)
let overlap = review.days[3]
precondition(overlap.blocks.map(\.id) == [0, 1] && overlap.blocks.map(\.completedPomodoros) == [0, 2])
precondition(overlap.blocks[1].goal == "Private, focus" && overlap.completedBlocks == 2 && overlap.shrubs == 2)
let plantOnly = review.days[4]
precondition(plantOnly.hasRecords && plantOnly.pomodoros == 0 && plantOnly.wilted == 2)
precondition(review.totals.completedBlocks == 3 && review.totals.shrubs == 2 &&
             review.totals.trees == 2 && review.totals.wilted == 3)
print("PASS legacy block fallback, duplicate records, reset counts, and explicit plant markers")

let rows = review.csv.components(separatedBy: "\r\n")
precondition(rows.count == 9 && rows.last == "")
precondition(rows[0] == "date,pomodoros,minutes,completed_blocks,shrubs,trees,wilted")
precondition(rows[1] == "2024-03-06,0,0,0,0,0,0" && rows[4] == "2024-03-09,2,35,2,2,1,1")
precondition(!review.csv.contains("Private") && !review.csv.contains("2024-03-13"))
precondition(review.csvFilename == "专注复盘-2024-03-06-2024-03-12.csv")
let emptyCSV = FocusReview(range: .week, now: now, histogram: [:], dailyBlocks: [:],
                           blockHistory: [:], plants: [:], calendar: calendar).csv
precondition(emptyCSV.components(separatedBy: "\r\n").count == 9 && emptyCSV.hasSuffix(",0,0,0,0,0,0\r\n"))
print("PASS CSV includes all selected dates and excludes goals and out-of-window records")
print("PASS CSV filename names the exported range; an empty range still exports zero rows")

let timeline = dataset.taskTimeline
let taskReview = FocusReview(range: .week, now: now, histogram: timeline.histogram, dailyBlocks: [:],
                             blockHistory: [:], plants: [:], calendar: calendar)
let detailDay = taskReview.selectedDay(timeline.day)!
let entries = detailDay.chronologicalTaskSessions
let originals = Dictionary(uniqueKeysWithValues: timeline.histogram[timeline.day]!.taskSessions!.map { ($0.id, $0) })
precondition(entries.map(\.id) == timeline.orderedIDs && entries.allSatisfy { originals[$0.id] == $0 })
precondition(entries.suffix(4).allSatisfy { $0.startedAt <= 0 })
print("PASS task timeline preserves snapshots, breaking ties and ordering unknown starts by session ID")

let aggregateOnly = taskReview.selectedDay(timeline.legacyDay)!
let previousStart = Date(timeIntervalSince1970: Double(entries[2].startedAt) / 1000)
precondition(FocusReview.dateKeyFormatter(calendar: calendar).string(from: previousStart) == aggregateOnly.id)
precondition(aggregateOnly.chronologicalTaskSessions.isEmpty && aggregateOnly.pomodoros == 1 &&
             detailDay.pomodoros == 8 && entries.count == 7)
let sessionOnly = taskReview.selectedDay(timeline.sessionOnlyDay)!
precondition(sessionOnly.hasRecords && sessionOnly.chronologicalTaskSessions.count == 1 &&
             sessionOnly.pomodoros == 0 && sessionOnly.minutes == 0)
print("PASS cross-midnight focus stays on its completion day and legacy counts and sessions are independent")

precondition(detailDay.tasks.map(\.title) == ["定稿", "校对"] && detailDay.tasks.map(\.minutes) == [35, 35] &&
             detailDay.tasks.map(\.pomodoros) == [2, 5])
precondition(taskReview.totals.pomodoros == 9 && taskReview.totals.minutes == 105)
precondition(taskReview.taskCSV == timeline.taskCSVRows.joined(separator: "\r\n") + "\r\n")
print("PASS session details preserve task totals, latest titles and the original task CSV row order")

// Earlier windows are counted from a fixed anchor, so paging survives midnight.
let today = calendar.startOfDay(for: now)
let back = FocusReviewWindow.previous(from: nil, today: today)
precondition(back.offset == -1 && back.anchor == today)
let backKeys = FocusReview(range: .week, now: back.endDate(range: .week, calendar: calendar)!, histogram: histogram,
                           dailyBlocks: dailyBlocks, blockHistory: blockHistory, plants: plants, calendar: calendar)
precondition(backKeys.startKey == "2024-02-28" && backKeys.endKey == "2024-03-05")
let twoBack = FocusReviewWindow.previous(from: back, today: today)
precondition(twoBack.offset == -2 && twoBack.next(today: today, range: .week, calendar: calendar) == back)
precondition(back.next(today: today, range: .week, calendar: calendar) == nil)
// After midnight the open page keeps its dates; paging forward visits the anchored
// window (now ending yesterday) before returning to the rolling window.
let afterMidnight = calendar.date(byAdding: .day, value: 1, to: today)!
let anchored = back.next(today: afterMidnight, range: .week, calendar: calendar)
precondition(anchored == FocusReviewWindow(anchor: today, offset: 0))
precondition(anchored?.next(today: afterMidnight, range: .week, calendar: calendar) == nil)
let monthBack = FocusReviewWindow.previous(from: nil, today: today)
precondition(monthBack.endDate(range: .month, calendar: calendar).map { calendar.component(.day, from: $0) } == 11)
print("PASS earlier windows page from a fixed anchor across midnight and return to the rolling window")

let earliest = FocusReview.earliestDate(histogram: histogram, dailyBlocks: dailyBlocks,
                                        blockHistory: blockHistory, plants: plants, calendar: calendar)
precondition(earliest == legacy.date && FocusReview.dateKeyFormatter(calendar: calendar).string(from: earliest!) == dataset.earliest)
let month = FocusReview(range: .month, now: now, histogram: [:], dailyBlocks: [:],
                        blockHistory: [:], plants: [:], calendar: calendar)
precondition(month.days.count == 30 && month.startKey == "2024-02-12" && !month.hasRecords)
precondition(month.days.contains { $0.id == "2024-02-29" })
let quarter = FocusReview(range: .quarter, now: now, histogram: [:], dailyBlocks: [:],
                          blockHistory: [:], plants: [:], calendar: calendar)
precondition(quarter.days.count == 90 && quarter.startKey == "2023-12-14" && !quarter.hasRecords)
precondition(FocusReview.earliestDate(histogram: [:], dailyBlocks: [:], blockHistory: [:], plants: [:]) == nil)
print("PASS earliest activity excludes invalid and zero records, 30-day leap and 90-day year boundaries")
