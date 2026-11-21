// FOCUS REVIEW (c): legacy count-only Android data through the REAL LocalStore
// migration (habitica_pomodoro_pomo_count.json → histogram with minutes 0 and a
// blank weekday). Review totals keep those minutes unknown — excluded from the
// focus time, never estimated from the current pomodoro length — and the CSV
// leaves the minutes cell empty for those days only. Also pins the footer
// summary (全部历史/记录日均) and Apple's duration wording.
import com.habitica.pomodoro.data.DayHistogram
import com.habitica.pomodoro.data.FocusReview
import com.habitica.pomodoro.data.FocusReviewHistorySummary
import com.habitica.pomodoro.data.FocusReviewRange
import com.habitica.pomodoro.data.LocalStore
import com.habitica.pomodoro.data.focusReviewDuration
import com.habitica.pomodoro.data.minutesUnknown
import org.json.JSONObject
import java.io.File
import java.time.LocalDate

fun main() {
    val app = newTempDir("fr03")
    dataDir(app).mkdirs()
    File(dataDir(app), "habitica_pomodoro_pomo_count.json")
        .writeText(JSONObject().put("2024-03-08", 4).put("2024-03-11", 2).put("2024-03-09", 0).toString())
    val store = LocalStore(TestApp(app))
    val migrated = store.loadHistogram()
    expectEq(migrated["2024-03-08"], DayHistogram(4, 0, ""), "migration keeps the count, has no minutes")
    expect(migrated.getValue("2024-03-08").minutesUnknown, "legacy day minutes are unknown")
    expect(!migrated.getValue("2024-03-09").minutesUnknown, "a zero legacy count is not an unknown-minutes day")
    // A real completion after migration stamps weekday + recorded minutes.
    val histogram = migrated + ("2024-03-12" to DayHistogram(1, 25, "Tuesday"))
    expect(!histogram.getValue("2024-03-12").minutesUnknown, "recorded day is known")
    expect(!DayHistogram(2, 35, "").minutesUnknown, "recorded minutes are never hidden, even with a blank weekday")

    val review = FocusReview(FocusReviewRange.WEEK, LocalDate.of(2024, 3, 12), histogram, emptyMap(), emptyMap(), emptyMap())
    val t = review.totals
    expectEq(t.pomodoros, 7, "legacy pomodoro counts are real and included")
    expectEq(t.minutes, 25, "only recorded minutes are summed (no 6 × 25 fabricated)")
    expectEq(t.unknownMinuteDays, 2, "two days with unknown minutes in the window")
    expectEq(t.activeDays, 3, "legacy days count as focus days")
    val legacy = review.days.first { it.key == "2024-03-08" }
    expect(legacy.minutesUnknown && legacy.minutes == 0 && legacy.hasRecords, "legacy day: $legacy")
    expectEq(review.selectedDay(null)?.key, "2024-03-12", "default day")

    val rows = review.csv.split("\r\n")
    expectEq(rows[0], FocusReview.CSV_HEADER, "Apple header")
    expectEq(rows[3], "2024-03-08,4,,0,0,0,0", "unknown minutes → empty cell, not 0")
    expectEq(rows[4], "2024-03-09,0,0,0,0,0,0", "zero legacy count is an ordinary empty day")
    expectEq(rows[6], "2024-03-11,2,,0,0,0,0", "second legacy day")
    expectEq(rows[7], "2024-03-12,1,25,0,0,0,0", "recorded day unchanged")
    expect(!review.csv.contains(",100,") && !review.csv.contains(",50,"), "no minutes derived from a pomodoro length")

    val summary = FocusReviewHistorySummary.from(histogram)
    expect(summary.totalPomodoros == 7 && summary.totalMinutes == 25 && summary.unknownMinuteDays == 2, "summary: $summary")
    expectEq(summary.recordedDays, 4, "average divides by stored days like Apple's histogram.count")
    expectEq(String.format(java.util.Locale.US, "%.1f", summary.avgPomodoros), "1.8", "记录日均")
    expectEq(FocusReviewHistorySummary.from(emptyMap()).avgPomodoros, 0.0, "empty history average")

    expectEq(focusReviewDuration(0), "0 分钟", "duration < 1h")
    expectEq(focusReviewDuration(59), "59 分钟", "duration < 1h")
    expectEq(focusReviewDuration(120), "2 小时", "whole hours")
    expectEq(focusReviewDuration(125), "2 小时 5 分", "hours and minutes")
    println("FR-03 OK")
}
