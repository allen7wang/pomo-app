import com.habitica.pomodoro.data.BlockHistoryEntry
import com.habitica.pomodoro.data.DailyBlockProgress
import com.habitica.pomodoro.data.DayHistogram
import com.habitica.pomodoro.data.FocusReview
import com.habitica.pomodoro.data.FocusReviewRange
import com.habitica.pomodoro.data.PlantDay
import java.time.Instant
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZoneId

private fun <T> JSONObject.entries(decode: (String) -> T): Map<String, T> =
    keys().asSequence().associateWith(decode)

fun main() {
    val dataset = JSONObject(parityFixture("focus_review.json").readText())
    val zone = ZoneId.of(dataset.getString("zone"))
    val today = FocusReview.today(Instant.parse(dataset.getString("instant")).toEpochMilli(), zone)
    expectEq(today, LocalDate.of(2024, 3, 12), "02:00 local is still the same calendar day")
    expectEq(FocusReview.today(Instant.parse("2024-03-12T06:30:00Z").toEpochMilli(), zone),
        LocalDate.of(2024, 3, 11), "late evening resolves to the local calendar day")

    val histogram = dataset.getJSONObject("histogram").run { entries { DayHistogram.fromJson(getJSONObject(it)) } }
    val dailyBlocks = dataset.getJSONObject("dailyBlocks").run { entries { DailyBlockProgress.fromJson(getJSONObject(it)) } }
    val blockHistory = dataset.getJSONObject("blockHistory").run {
        entries { key ->
            val blocks = getJSONArray(key)
            (0 until blocks.length()).map { BlockHistoryEntry.fromJson(blocks.getJSONObject(it)) }
        }
    }
    val plants = dataset.getJSONObject("plants").run { entries { PlantDay.fromJson(getJSONObject(it)) } }

    val windows = dataset.getJSONArray("windows")
    for (index in 0 until windows.length()) {
        val window = windows.getJSONObject(index)
        val length = window.getInt("days")
        val range = FocusReviewRange.entries.single { it.days == length }
        val report = FocusReview(range, today, histogram, dailyBlocks, blockHistory, plants)
        expectEq(report.days.size, length, "calendar days")
        expectEq(report.startKey, window.getString("start"), "window start")
        expectEq(report.endKey, window.getString("end"), "window end")
        expectEq(report.totals.pomodoros, window.getInt("pomodoros"), "window pomodoros")
        expectEq(report.totals.minutes, window.getInt("minutes"), "window minutes")
        expectEq(report.totals.activeDays, window.getInt("activeDays"), "window active days")
        expectEq(report.selectedDay(null)?.key, window.getString("defaultDay"), "default day")
        window.optJSONArray("csvRows")?.let { rows ->
            val expected = (0 until rows.length()).map(rows::getString).joinToString("\r\n") + "\r\n"
            expect(report.csv.toByteArray().contentEquals(expected.toByteArray()), "$length-day CSV bytes")
        }
    }

    val review = FocusReview(FocusReviewRange.WEEK, today, histogram, dailyBlocks, blockHistory, plants)
    expectEq(review.days.map { it.key }, (6..12).map { "2024-03-%02d".format(it) }, "7 calendar days ending today")
    expectEq(review.days.map { it.date }, (6..12).map { LocalDate.of(2024, 3, it) }, "dates match keys across the DST change")
    expectEq(review.startKey to review.endKey, "2024-03-06" to "2024-03-12", "window bounds")
    expect(review.hasRecords && !review.days[0].hasRecords && !review.days[2].hasRecords, "zero-filled days have no records")
    val t = review.totals
    expect(t.pomodoros == 3 && t.minutes == 60 && t.activeDays == 2, "histogram-only focus totals: $t")
    expectEq(t.unknownMinuteDays, 0, "no legacy minute gaps in the Apple dataset")
    println("PASS calendar-day range, zero-filled days and histogram-only focus totals")

    val legacy = review.days[1]
    expect(legacy.hasRecords && legacy.completedBlocks == 1 && legacy.shrubs == 0, "legacy block day: $legacy")
    expect(legacy.blocks.size == 1 && legacy.blocks[0].index == 4 && legacy.blocks[0].completedPomodoros == 3,
        "history-only block falls back to the max historical count: ${legacy.blocks}")
    val overlap = review.days[3]
    expectEq(overlap.blocks.map { it.index }, listOf(0, 1), "out-of-range block indices are dropped; empty block 2 hidden")
    expectEq(overlap.blocks.map { it.completedPomodoros }, listOf(0, 2), "a saved zero (reset) beats the historical count")
    expect(overlap.blocks[1].goal == "Private, focus" && overlap.completedBlocks == 2 && overlap.shrubs == 2, "goal trim + completion")
    expectEq(overlap.blocks[0].goal, "Reset", "goal kept for a reset block")
    val plantOnly = review.days[4]
    expect(plantOnly.hasRecords && plantOnly.pomodoros == 0 && plantOnly.wilted == 2 && plantOnly.trees == 1, "plant-only day: $plantOnly")
    expect(t.completedBlocks == 3 && t.shrubs == 2 && t.trees == 2 && t.wilted == 3, "block/plant totals: $t")
    println("PASS legacy block fallback, duplicate records, reset counts, and explicit plant markers")

    val rows = review.csv.split("\r\n")
    expect(rows.size == 9 && rows.last() == "", "one row per day plus header, trailing CRLF")
    expect(!review.csv.contains("Private") && !review.csv.contains("2024-03-13"), "no goals, no out-of-window rows")
    expectEq(review.csvFilename, "专注复盘-2024-03-06-2024-03-12.csv", "Apple export filename")
    val month = FocusReview(FocusReviewRange.MONTH, today, histogram, dailyBlocks, blockHistory, plants)
    expectEq(month.totals, t, "the 30-day window holds the same records")
    println("PASS CSV byte-identical to Apple for 7 and 30 days; goals and out-of-window records excluded")

    val earliest = FocusReview.earliestDate(histogram, dailyBlocks, blockHistory, plants)
    expectEq(earliest?.toString(), dataset.getString("earliest"), "earliest skips invalid date and zero record")
    val empty = FocusReview(FocusReviewRange.MONTH, today, emptyMap(), emptyMap(), emptyMap(), emptyMap())
    expect(empty.days.size == 30 && empty.startKey == "2024-02-12" && !empty.hasRecords, "30-day window start")
    expect(empty.days.any { it.key == "2024-02-29" }, "leap day included")
    val quarter = FocusReview(FocusReviewRange.QUARTER, today, emptyMap(), emptyMap(), emptyMap(), emptyMap())
    expect(quarter.days.size == 90 && quarter.startKey == "2023-12-14" && !quarter.hasRecords, "90-day window crosses the year")
    expectEq(FocusReview.earliestDate(emptyMap(), emptyMap(), emptyMap(), emptyMap()), null, "no records, no earliest date")
    expectEq(FocusReview.parseKey("2024-02-30"), null, "strict date keys")
    expectEq(FocusReview.parseKey("2024-3-09"), null, "unpadded keys are not calendar keys")
    println("PASS earliest activity excludes invalid and zero records, 30-day leap and 90-day year boundaries")
}
