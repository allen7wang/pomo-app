// FOCUS REVIEW (b): navigation state as driven by FocusReviewScreen, mirroring
// Apple FocusReviewView/FocusReviewHistoryPage: window paging from a fixed anchor,
// back-paging only while older records exist, range change returns to today,
// default selection = most recent day with records, and an opened earlier
// window (plus the picked day) survives crossing midnight (macOS v2.0.1).
import com.habitica.pomodoro.data.DayHistogram
import com.habitica.pomodoro.data.FocusReview
import com.habitica.pomodoro.data.FocusReviewNavigation
import com.habitica.pomodoro.data.FocusReviewRange
import com.habitica.pomodoro.data.PlantDay
import java.time.LocalDate

private fun d(day: String) = LocalDate.parse(day)
private val histogram = mapOf(
    "2024-02-20" to DayHistogram(3, 75, "Tuesday"),
    "2024-03-04" to DayHistogram(2, 50, "Monday"),
    "2024-03-10" to DayHistogram(1, 25, "Sunday"),
)
private val plants = mapOf("2024-03-11" to PlantDay(listOf(listOf("wilted")), listOf(0)))

private fun review(nav: FocusReviewNavigation, today: LocalDate) =
    FocusReview(nav.range, nav.endDate(today), histogram, emptyMap(), emptyMap(), plants)

private fun window(r: FocusReview) = r.startKey to r.endKey

fun main() {
    val earliest = FocusReview.earliestDate(histogram, emptyMap(), emptyMap(), plants)
    expectEq(earliest, d("2024-02-20"), "earliest record")
    var today = d("2024-03-12")
    var nav = FocusReviewNavigation()
    expect(!nav.isPaged, "opens on the live window")
    var r = review(nav, today)
    expectEq(window(r), "2024-03-06" to "2024-03-12", "live 7-day window")
    expectEq(r.selectedDay(nav.selectedKey)?.key, "2024-03-11", "default = most recent day with records (plant-only counts)")
    expect(nav.canPageBack(r, earliest), "older records exist → back enabled")

    // Paging back walks whole windows from the anchor.
    nav = nav.select("2024-03-10").previous(today)
    expectEq(nav.selectedKey, null, "paging clears the pick")
    r = review(nav, today)
    expectEq(window(r), "2024-02-28" to "2024-03-05", "one window back")
    expectEq(r.selectedDay(nav.selectedKey)?.key, "2024-03-04", "default day inside the earlier window")
    nav = nav.previous(today)
    r = review(nav, today)
    expectEq(window(r), "2024-02-21" to "2024-02-27", "two windows back")
    expect(nav.canPageBack(r, earliest), "2024-02-20 is still older")
    expect(!r.hasRecords && r.selectedDay(null)?.key == "2024-02-27", "empty window → empty state, last day as fallback")
    nav = nav.previous(today)
    r = review(nav, today)
    expectEq(window(r), "2024-02-14" to "2024-02-20", "three windows back")
    expect(!nav.canPageBack(r, earliest), "nothing older → back disabled")
    expectEq(FocusReviewNavigation().canPageBack(r, null), false, "no records at all → back disabled")

    // Forward returns to live only when the next window would reach today.
    nav = nav.next(today).next(today)
    expectEq(window(review(nav, today)), "2024-02-28" to "2024-03-05", "forward steps keep the anchor")
    nav = nav.next(today)
    expect(!nav.isPaged, "the window ending today is the live window again")
    expectEq(nav.next(today), nav, "forward on the live window is a no-op")

    // Midnight while an earlier window is open: window and pick survive.
    nav = FocusReviewNavigation().previous(today).select("2024-03-04")
    today = d("2024-03-13")
    r = review(nav, today)
    expectEq(window(r), "2024-02-28" to "2024-03-05", "opened earlier window is fixed across midnight")
    expectEq(r.selectedDay(nav.selectedKey)?.key, "2024-03-04", "picked day survives midnight")
    // Apple semantics after midnight: the anchored window ending on the old today is no longer live.
    nav = nav.next(today)
    expect(nav.isPaged, "window ending yesterday stays an earlier window")
    expectEq(window(review(nav, today)), "2024-03-06" to "2024-03-12", "anchored window after midnight")
    nav = nav.next(today)
    expect(!nav.isPaged, "then live")
    expectEq(window(review(nav, today)), "2024-03-07" to "2024-03-13", "live window follows the new day")

    // Live window across midnight: the range and a still-visible pick are kept.
    nav = FocusReviewNavigation().withRange(FocusReviewRange.MONTH).select("2024-03-04")
    r = review(nav, d("2024-03-12"))
    expectEq(window(r), "2024-02-12" to "2024-03-12", "live 30-day window")
    r = review(nav, d("2024-03-13"))
    expect(nav.range == FocusReviewRange.MONTH && window(r) == ("2024-02-13" to "2024-03-13"), "range kept, window rolls")
    expectEq(r.selectedDay(nav.selectedKey)?.key, "2024-03-04", "pick still in the window survives")
    expectEq(r.selectedDay("2024-01-01")?.key, "2024-03-11", "pick outside the window falls back to the default")

    // Changing range returns to today and clears the pick; re-selecting the same range is a no-op.
    val paged = FocusReviewNavigation().previous(today).select("2024-03-01")
    expectEq(paged.withRange(FocusReviewRange.WEEK), paged, "same range keeps state")
    expectEq(paged.withRange(FocusReviewRange.QUARTER), FocusReviewNavigation(FocusReviewRange.QUARTER), "range change resets")
    expectEq(paged.returnToToday(), FocusReviewNavigation(), "回到今天 resets page and pick")
    expectEq(FocusReviewRange.fromDays(30), FocusReviewRange.MONTH, "saved range restores")
    expectEq(FocusReviewRange.fromDays(12), FocusReviewRange.WEEK, "unknown saved range falls back to 7 days")
    expectEq(FocusReviewRange.entries.map { it.title }, listOf("7 天", "30 天", "90 天"), "range titles")
    println("FR-02 OK")
}
