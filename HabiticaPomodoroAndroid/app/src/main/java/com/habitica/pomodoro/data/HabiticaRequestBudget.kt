package com.habitica.pomodoro.data

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * One rolling request budget for a single UID + effective API root (Apple HabiticaRequestBudget, v2.1.2).
 * Admission rejects instead of queueing: a delayed write would outlive the caller's identity/revision
 * checks, and nothing here is ever replayed. `uptime` is monotonic seconds; wall-clock time is only
 * used to interpret server headers.
 */
class HabiticaRequestBudget {
    private val starts = ArrayDeque<Double>()
    private var serverRemaining: Int? = null
    private var serverReset = 0.0
    private var cooldownUntil = 0.0
    var received429 = false
        private set

    fun delay(uptime: Double): Double {
        while (starts.isNotEmpty() && starts.first() <= uptime - WINDOW_SECONDS) starts.removeFirst()
        if (uptime >= serverReset) serverRemaining = null
        if (uptime >= cooldownUntil) received429 = false
        val local = if (starts.size >= LOCAL_LIMIT) starts.first() + WINDOW_SECONDS - uptime else 0.0
        val server = if (serverRemaining == 0) serverReset - uptime else 0.0
        return maxOf(0.0, local, server, cooldownUntil - uptime)
    }

    /** 0 when the request may be sent now (and is counted), otherwise the wait in seconds. */
    fun reserve(uptime: Double): Double {
        val wait = delay(uptime)
        if (wait > 0) return wait
        starts.addLast(uptime)
        serverRemaining?.let { serverRemaining = max(0, it - 1) }
        return 0.0
    }

    fun observe(status: Int, header: (String) -> String?, uptime: Double, wallMillis: Long) {
        // Prefer the server's Date so a skewed device clock cannot shorten a reset.
        val reference = header("Date")?.let(::parseHttpDate)?.toEpochMilli() ?: wallMillis
        val resetDelay = header("X-RateLimit-Reset")?.let { value ->
            val resetMillis = value.trim().toDoubleOrNull()?.takeIf { it.isFinite() }?.let { it * 1000 }
                ?: parseHttpDate(value)?.toEpochMilli()?.toDouble()
            resetMillis?.let { max(0.0, (it - reference) / 1000.0) }
        }
        header("X-RateLimit-Remaining")?.trim()?.toIntOrNull()?.let { value ->
            if (uptime >= serverReset) serverRemaining = null
            val remaining = max(0, value)
            // Out-of-order responses may lower the allowance, never replenish it mid-window.
            serverRemaining = min(serverRemaining ?: remaining, remaining)
            serverReset = max(serverReset, uptime + (resetDelay ?: WINDOW_SECONDS) + 1)
        }
        if (status == 429) {
            val retryDelay = header("Retry-After")?.let { value ->
                value.trim().toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
                    ?: parseHttpDate(value)?.let { max(0.0, (it.toEpochMilli() - reference) / 1000.0) }
            }
            cooldownUntil = max(cooldownUntil, uptime + max(retryDelay ?: resetDelay ?: WINDOW_SECONDS, resetDelay ?: 0.0) + 1)
            serverRemaining = 0
            serverReset = max(serverReset, cooldownUntil)
            received429 = true
        }
    }

    companion object {
        /** Habitica allows 30/minute; leave room for the user's other clients. */
        const val LOCAL_LIMIT = 24
        const val WINDOW_SECONDS = 60.0

        private val rfc1123: DateTimeFormatter = DateTimeFormatter.RFC_1123_DATE_TIME
        // Habitica's X-RateLimit-Reset is a JavaScript Date#toString value.
        private val javascriptDate: DateTimeFormatter = DateTimeFormatter.ofPattern("EEE MMM dd yyyy HH:mm:ss 'GMT'Z", Locale.US)

        fun parseHttpDate(value: String): Instant? {
            val clean = value.trim().substringBefore(" (")
            runCatching { return ZonedDateTime.parse(clean, rfc1123).toInstant() }
            runCatching { return OffsetDateTime.parse(clean, javascriptDate).toInstant() }
            return runCatching { OffsetDateTime.parse(clean).toInstant() }.getOrNull()
        }
    }
}

/**
 * Process-wide budgets keyed by [UserSettings.cloudAccount] (UID + canonical API root, never a token), so
 * token rotation, reconnecting or switching accounts and back cannot bypass a cooldown.
 * Clocks are injectable for the offline fixtures.
 */
object HabiticaRequestBudgets {
    private val defaultUptime: () -> Double = { System.nanoTime() / 1_000_000_000.0 }
    private val defaultWallClock: () -> Long = { System.currentTimeMillis() }

    @Volatile var uptimeSeconds: () -> Double = defaultUptime
    @Volatile var wallClockMillis: () -> Long = defaultWallClock
    private val budgets = HashMap<String, HabiticaRequestBudget>()

    @Synchronized
    fun reserve(account: String): Double =
        budgets.getOrPut(account) { HabiticaRequestBudget() }.reserve(uptimeSeconds())

    @Synchronized
    fun observe(account: String, status: Int, header: (String) -> String?) =
        budgets.getOrPut(account) { HabiticaRequestBudget() }.observe(status, header, uptimeSeconds(), wallClockMillis())

    /** Chinese wait message (Apple wording) while this account may not send, else null. */
    @Synchronized
    fun rateLimitMessage(account: String?): String? {
        val budget = account?.let { budgets[it] } ?: return null
        val wait = budget.delay(uptimeSeconds())
        if (wait <= 0) return null
        val reason = if (budget.received429) "Habitica 暂时限流（HTTP 429）" else "Habitica 请求额度暂时用完"
        // A finite server delay can still exceed any integer range; keep the cooldown, avoid overflow.
        val seconds = ceil(wait)
        val retry = if (seconds <= Int.MAX_VALUE) "${seconds.toLong()} 秒后重试。" else "稍后重试（服务器要求的等待时间过长）。"
        return "$reason，请 $retry"
    }

    /** True while a server 429 cooldown is running; a success must not hide that feedback. */
    @Synchronized
    fun coolingDown429(account: String?): Boolean {
        val budget = account?.let { budgets[it] } ?: return false
        return budget.delay(uptimeSeconds()) > 0 && budget.received429
    }

    /** Fixtures only: forget every budget and restore the real clocks. */
    @Synchronized
    fun reset() {
        budgets.clear()
        uptimeSeconds = defaultUptime
        wallClockMillis = defaultWallClock
    }
}
