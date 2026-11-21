import com.habitica.pomodoro.data.BlockTimeRange
import com.habitica.pomodoro.data.FocusReview
import com.habitica.pomodoro.data.LocalStore
import com.habitica.pomodoro.data.UserSettings
import org.json.JSONArray
import java.time.Instant
import java.time.ZoneId
import java.util.Date

fun main() {
    val store = LocalStore(TestApp(newTempDir()))
    val scenarios = JSONArray(parityFixture("logical_day.json").readText())
    for (index in 0 until scenarios.length()) {
        val item = scenarios.getJSONObject(index)
        val name = item.getString("name")
        val zone = ZoneId.of(item.getString("zone"))
        val instant = Instant.parse(item.getString("instant"))
        val boundary = item.getInt("boundaryMinutes")
        val settings = UserSettings(blockTimeRanges = listOf(BlockTimeRange(boundary / 60, boundary % 60, 0, 0)))
        expectEq(store.logicalDateKey(settings, Date.from(instant), zone), item.getString("logicalDay"), "$name logical day")
        expectEq(FocusReview.today(instant.toEpochMilli(), zone).toString(), item.getString("calendarDay"), "$name calendar day")
    }
    println("PASS ${scenarios.length()} shared logical-day boundary scenarios")
}
