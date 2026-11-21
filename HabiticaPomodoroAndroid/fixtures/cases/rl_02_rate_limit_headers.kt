// RL-02 (v2.1.2): server allowance headers. X-RateLimit-Remaining/Reset (JS
// date, epoch, server Date despite local clock skew), Retry-After (seconds,
// fractional, HTTP-date), malformed fallback, out-of-order replies, oversized
// waits without integer overflow, and a Remaining: 0 reply blocking the next
// feature before any 429.
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.HabiticaRequestBudget
import com.habitica.pomodoro.data.HabiticaRequestBudgets
import java.time.Instant

fun headers(vararg pairs: Pair<String, String>): (String) -> String? =
    { name -> pairs.firstOrNull { it.first.equals(name, ignoreCase = true) }?.second }

fun main() {
    val serverDate = "Thu, 05 Nov 2026 08:00:00 GMT"
    val wall = Instant.parse("2026-11-05T08:00:00Z").toEpochMilli()
    val day = 86_400_000L

    val remote = HabiticaRequestBudget()
    remote.observe(200, headers("Date" to serverDate, "X-RateLimit-Remaining" to "1",
        "X-RateLimit-Reset" to "Thu Nov 05 2026 08:01:00 GMT+0000 (Coordinated Universal Time)"), 100.0, wall + day)
    expectEq(remote.reserve(100.0), 0.0, "one server request left")
    expectEq(remote.reserve(100.0), 61.0, "allowance 0 waits for the JS-date reset measured from the server Date")
    expectEq(remote.reserve(161.0), 0.0, "reset reopens")

    val fractional = HabiticaRequestBudget()
    fractional.observe(429, headers("Retry-After" to "2.5"), 100.0, wall)
    expectEq(fractional.reserve(100.0), 3.5, "fractional Retry-After + 1 s margin")
    expect(fractional.received429, "429 is remembered for the message")
    expectEq(fractional.reserve(104.0), 0.0, "cooldown expires without replay")

    val dated = HabiticaRequestBudget()
    dated.observe(429, headers("Date" to serverDate, "Retry-After" to "Thu, 05 Nov 2026 08:00:10 GMT"), 100.0, wall - day)
    expectEq(dated.reserve(100.0), 11.0, "HTTP-date Retry-After uses server time")

    val epoch = HabiticaRequestBudget()
    epoch.observe(429, headers("X-RateLimit-Reset" to (wall / 1000.0 + 10).toString()), 100.0, wall)
    expectEq(epoch.reserve(100.0), 11.0, "epoch reset honoured when Retry-After is absent")

    val fallback = HabiticaRequestBudget()
    fallback.observe(429, headers("Retry-After" to "garbage", "X-RateLimit-Reset" to "garbage"), 100.0, wall)
    expectEq(fallback.reserve(100.0), 61.0, "malformed cooldown headers fall back to one minute")

    val reordered = HabiticaRequestBudget()
    reordered.observe(200, headers("X-RateLimit-Remaining" to "2"), 100.0, wall)
    reordered.observe(200, headers("X-RateLimit-Remaining" to "29"), 100.0, wall)
    expectEq(reordered.reserve(100.0), 0.0, "first of two")
    expectEq(reordered.reserve(100.0), 0.0, "second of two")
    expect(reordered.reserve(100.0) > 0, "an out-of-order reply cannot replenish the window")

    // Messages, including finite-but-absurd server waits (no overflow, cooldown still enforced).
    val clock = installManualClock(wall)
    HabiticaRequestBudgets.observe("acct-60", 429, headers("Retry-After" to "60"))
    expectEq(HabiticaRequestBudgets.rateLimitMessage("acct-60"), "Habitica 暂时限流（HTTP 429），请 61 秒后重试。", "429 wording")
    expect(HabiticaRequestBudgets.coolingDown429("acct-60"), "429 cooldown flag")
    for ((index, value) in listOf("1e30", Long.MAX_VALUE.toDouble().toString(), Double.MAX_VALUE.toString()).withIndex()) {
        HabiticaRequestBudgets.observe("acct-huge-$index", 429, headers("Retry-After" to value))
        expectEq(HabiticaRequestBudgets.rateLimitMessage("acct-huge-$index"),
            "Habitica 暂时限流（HTTP 429），请 稍后重试（服务器要求的等待时间过长）。", "oversized Retry-After $value")
        expect(HabiticaRequestBudgets.reserve("acct-huge-$index") > 0, "oversized wait still blocks")
    }
    HabiticaRequestBudgets.observe("acct-reset", 429, headers("X-RateLimit-Reset" to "1e30"))
    expect(HabiticaRequestBudgets.rateLimitMessage("acct-reset")?.contains("等待时间过长") == true, "oversized reset")
    clock.advance(61.0)
    expectEq(HabiticaRequestBudgets.rateLimitMessage("acct-60"), null, "cooldown over: no message, nothing replayed")

    // Through the engine: Remaining: 0 on a successful list blocks the next feature before a 429 happens.
    val dir = newTempDir("rl-02")
    seedSettings(dir)
    seedTopThree(dir, ownedStore())
    val vm = newVm(dir) { installManualClock(wall) }
    HabiticaAPI.taskListBodies["habits"] = taskListBody("h1" to "Read")
    HabiticaAPI.replyFor = { name -> if (name == "fetchTaskItems:habits") reply(200, "X-RateLimit-Remaining" to "0") else null }
    vm.refreshHabiticaTasks("habits")
    expectEq(vm.state.value.habits.map { it.id }, listOf("h1"), "the allowance-0 reply itself is still a valid list")
    val before = HabiticaAPI.calls.size
    vm.scoreHabiticaTask("habits", habitItem("h1"), "up")
    expectEq(HabiticaAPI.calls.size, before, "score blocked by the server allowance, never dispatched")
    expect(vm.state.value.tasksError?.contains("请求额度暂时用完") == true, "wait shown: ${vm.state.value.tasksError}")
    println("RL-02 OK")
}
