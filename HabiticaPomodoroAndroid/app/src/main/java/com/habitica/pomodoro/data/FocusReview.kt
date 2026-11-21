package com.habitica.pomodoro.data

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * 专注复盘：对既有自然日记录（番茄统计、块进度、块达标历史、植物）的只读投影。
 * 逐项移植 Apple `FocusReview.swift` / `FocusReviewView.swift`，不写回任何存储。
 */
enum class FocusReviewRange(val days: Int) {
    WEEK(7), MONTH(30), QUARTER(90);

    val title: String get() = "$days 天"

    companion object {
        fun fromDays(days: Int): FocusReviewRange = entries.firstOrNull { it.days == days } ?: WEEK
    }
}

data class FocusReviewBlock(
    /** Zero-based index in the saved block records. */
    val index: Int,
    val completedPomodoros: Int,
    val isCompleted: Boolean,
    val goal: String?,
    val shrubs: Int,
    val trees: Int,
    val wilted: Int,
)

data class FocusReviewTask(val id: String, val title: String, val pomodoros: Int, val minutes: Int) {
    companion object {
        fun summarize(sessions: List<TaskFocusSession>): List<FocusReviewTask> =
            sessions.groupBy { it.taskId }.map { (id, records) ->
                val latest = records.maxWith(compareBy<TaskFocusSession> { it.startedAt }.thenBy { it.id })
                FocusReviewTask(id, latest.title, records.size, records.sumOf { it.minutes })
            }.sortedWith(compareByDescending<FocusReviewTask> { it.minutes }.thenBy { it.id })
    }
}

data class FocusReviewDay(
    val key: String,
    val date: LocalDate,
    val pomodoros: Int,
    val minutes: Int,
    /** Android-only: migrated count-only `pomo_count` days never had minutes. */
    val minutesUnknown: Boolean,
    val blocks: List<FocusReviewBlock>,
    val taskSessions: List<TaskFocusSession> = emptyList(),
) {
    val tasks: List<FocusReviewTask> get() = FocusReviewTask.summarize(taskSessions)
    val hasRecords: Boolean get() = pomodoros > 0 || minutes > 0 || blocks.isNotEmpty()
    val completedBlocks: Int get() = blocks.count { it.isCompleted }
    val shrubs: Int get() = blocks.sumOf { it.shrubs }
    val trees: Int get() = blocks.sumOf { it.trees }
    val wilted: Int get() = blocks.sumOf { it.wilted }
}

data class FocusReviewTotals(
    val pomodoros: Int = 0,
    /** Sum of recorded minutes only; unknown legacy minutes are excluded, never estimated. */
    val minutes: Int = 0,
    val activeDays: Int = 0,
    val completedBlocks: Int = 0,
    val shrubs: Int = 0,
    val trees: Int = 0,
    val wilted: Int = 0,
    val unknownMinuteDays: Int = 0,
)

/**
 * Legacy `pomo_count` migration writes `DayHistogram(count, 0, "")`, while every real completion
 * stamps a weekday. Recorded minutes are never hidden, so a blank weekday alone is not enough.
 */
val DayHistogram.minutesUnknown: Boolean get() = weekday.isBlank() && pomodoros > 0 && minutes == 0

class FocusReview(
    range: FocusReviewRange,
    end: LocalDate,
    histogram: Map<String, DayHistogram>,
    dailyBlocks: Map<String, DailyBlockProgress>,
    blockHistory: Map<String, List<BlockHistoryEntry>>,
    plants: Map<String, PlantDay>,
) {
    val days: List<FocusReviewDay> = (range.days - 1 downTo 0).map { offset ->
        val date = end.minusDays(offset.toLong())
        val key = dateKey(date)
        day(key, date, histogram[key], dailyBlocks[key], blockHistory[key].orEmpty(), plants[key])
    }

    val totals: FocusReviewTotals = days.fold(FocusReviewTotals()) { t, day ->
        t.copy(
            pomodoros = t.pomodoros + day.pomodoros,
            minutes = t.minutes + day.minutes,
            activeDays = t.activeDays + if (day.pomodoros > 0 || day.minutes > 0) 1 else 0,
            completedBlocks = t.completedBlocks + day.completedBlocks,
            shrubs = t.shrubs + day.shrubs,
            trees = t.trees + day.trees,
            wilted = t.wilted + day.wilted,
            unknownMinuteDays = t.unknownMinuteDays + if (day.minutesUnknown) 1 else 0,
        )
    }

    val startKey: String get() = days.firstOrNull()?.key.orEmpty()
    val endKey: String get() = days.lastOrNull()?.key.orEmpty()
    val hasRecords: Boolean get() = days.any { it.hasRecords }
    val tasks: List<FocusReviewTask> = FocusReviewTask.summarize(days.flatMap { it.taskSessions })

    /** An explicit pick wins while it is in the window; otherwise the most recent day with records. */
    fun selectedDay(selectedKey: String?): FocusReviewDay? =
        selectedKey?.let { key -> days.firstOrNull { it.key == key } }
            ?: days.lastOrNull { it.hasRecords } ?: days.lastOrNull()

    /**
     * Byte-for-byte the Apple format: fixed header, one row per day, CRLF line endings
     * (including the last row), UTF-8 without BOM, goals never exported.
     * Android-only: a legacy day whose minutes are unknown leaves the minutes cell empty
     * rather than writing a fabricated 0; Apple data never has such days.
     */
    val csv: String
        get() {
            val rows = days.map { day ->
                val minutes = if (day.minutesUnknown) "" else day.minutes.toString()
                "${day.key},${day.pomodoros},$minutes,${day.completedBlocks},${day.shrubs},${day.trees},${day.wilted}"
            }
            return (listOf(CSV_HEADER) + rows).joinToString("\r\n") + "\r\n"
        }

    val csvFilename: String get() = "专注复盘-$startKey-$endKey.csv"

    val taskCsv: String get() {
        val rows = days.flatMap { day ->
            day.taskSessions.sortedBy { it.id }.map { session ->
                "${day.key},${csvCell(session.taskId)},${csvCell(session.title)},${session.minutes}"
            }
        }
        return (listOf("date,task_id,task_title,minutes") + rows).joinToString("\r\n") + "\r\n"
    }

    val taskCsvFilename: String get() = "任务专注-$startKey-$endKey.csv"

    companion object {
        const val CSV_HEADER = "date,pomodoros,minutes,completed_blocks,shrubs,trees,wilted"

        private fun csvCell(value: String): String {
            val first = value.trimStart().firstOrNull()
            val formula = first != null && first in "=+-@＝＋－＠"
            val control = value.firstOrNull()?.let { it in "\t\r\n" } == true
            return "\"" + (if (formula || control) "'" else "") + value.replace("\"", "\"\"") + "\""
        }

        /** UserSettings supports up to 24 blocks, including blocks from older configurations. */
        private const val MAX_BLOCKS = 24

        fun dateKey(date: LocalDate): String = date.toString()

        /** Strict `yyyy-MM-dd`: rejects impossible dates such as 2024-02-30 like Apple's round-trip check. */
        fun parseKey(key: String): LocalDate? =
            runCatching { LocalDate.parse(key) }.getOrNull()?.takeIf { dateKey(it) == key }

        fun today(nowMillis: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): LocalDate =
            Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()

        fun earliestDate(
            histogram: Map<String, DayHistogram>,
            dailyBlocks: Map<String, DailyBlockProgress>,
            blockHistory: Map<String, List<BlockHistoryEntry>>,
            plants: Map<String, PlantDay>,
        ): LocalDate? {
            val keys = (histogram.keys + dailyBlocks.keys + blockHistory.keys + plants.keys).sorted()
            for (key in keys) {
                val date = parseKey(key) ?: continue
                if (day(key, date, histogram[key], dailyBlocks[key], blockHistory[key].orEmpty(), plants[key]).hasRecords) {
                    return date
                }
            }
            return null
        }

        private fun day(
            key: String, date: LocalDate, focus: DayHistogram?, daily: DailyBlockProgress?,
            history: List<BlockHistoryEntry>, plants: PlantDay?,
        ) = FocusReviewDay(
            key = key, date = date,
            pomodoros = maxOf(0, focus?.pomodoros ?: 0),
            minutes = maxOf(0, focus?.minutes ?: 0),
            minutesUnknown = focus?.minutesUnknown == true,
            blocks = blocks(daily, history, plants),
            taskSessions = focus?.taskSessions.orEmpty(),
        )

        private fun blocks(daily: DailyBlockProgress?, history: List<BlockHistoryEntry>, plants: PlantDay?): List<FocusReviewBlock> {
            val progress = daily?.blockProgress.orEmpty()
            val goals = daily?.blockGoals.orEmpty()
            val attempts = plants?.attempts.orEmpty()
            val treeCounts = plants?.trees.orEmpty()
            val historyByBlock = history.filter { it.blockIndex in 0 until MAX_BLOCKS }.groupBy { it.blockIndex }
            val storedBlockCount = minOf(MAX_BLOCKS, maxOf(progress.size, attempts.size, treeCounts.size))
            val indices = ((0 until storedBlockCount).toSet() + historyByBlock.keys).sorted()

            return indices.mapNotNull { index ->
                val entries = historyByBlock[index].orEmpty()
                val historicalCount = entries.maxOfOrNull { it.pomodoros } ?: 0
                // A saved zero can be an explicit reset. Use the historical count only when absent.
                val count = maxOf(0, progress.getOrNull(index) ?: historicalCount)
                val isCompleted = entries.any { it.isComplete }
                val outcomes = attempts.getOrNull(index).orEmpty()
                val shrubs = outcomes.count { it == "shrub" }
                val wilted = outcomes.count { it == "wilted" }
                val trees = maxOf(0, treeCounts.getOrNull(index) ?: 0)
                if (count <= 0 && !isCompleted && shrubs <= 0 && trees <= 0 && wilted <= 0) return@mapNotNull null
                val goal = goals.getOrNull(index)?.trim().orEmpty()
                FocusReviewBlock(index, count, isCompleted, goal.ifEmpty { null }, shrubs, trees, wilted)
            }
        }
    }
}

/**
 * A fixed earlier window. The anchor is the day the user first paged back, so the
 * window does not slide when the clock crosses midnight (Apple v2.0.1).
 */
data class FocusReviewPage(val anchor: LocalDate, val offset: Int) {
    fun endDate(range: FocusReviewRange): LocalDate = anchor.plusDays(offset.toLong() * range.days)

    /** Keep paging from the fixed anchor until the rolling window is next or overlaps it. */
    fun next(today: LocalDate, range: FocusReviewRange): FocusReviewPage? {
        val next = copy(offset = offset + 1)
        return next.takeIf { it.endDate(range) < today }
    }
}

/** Screen navigation state, kept pure so midnight/paging behavior is testable off-device. */
data class FocusReviewNavigation(
    val range: FocusReviewRange = FocusReviewRange.WEEK,
    val page: FocusReviewPage? = null,
    val selectedKey: String? = null,
) {
    val isPaged: Boolean get() = page != null

    fun endDate(today: LocalDate): LocalDate = page?.endDate(range) ?: today

    fun withRange(newRange: FocusReviewRange): FocusReviewNavigation =
        if (newRange == range) this else FocusReviewNavigation(range = newRange)

    fun previous(today: LocalDate): FocusReviewNavigation {
        val current = page ?: FocusReviewPage(today, 0)
        return copy(page = current.copy(offset = current.offset - 1), selectedKey = null)
    }

    fun next(today: LocalDate): FocusReviewNavigation =
        copy(page = page?.next(today, range), selectedKey = null)

    fun returnToToday(): FocusReviewNavigation = copy(page = null, selectedKey = null)

    fun select(key: String): FocusReviewNavigation = copy(selectedKey = key)

    fun canPageBack(review: FocusReview, earliest: LocalDate?): Boolean {
        val first = review.days.firstOrNull() ?: return false
        return earliest != null && earliest < first.date
    }
}

/** Footer figures over the whole histogram, as on Apple ("全部历史" / "记录日均"). */
data class FocusReviewHistorySummary(
    val totalPomodoros: Int,
    val totalMinutes: Int,
    val unknownMinuteDays: Int,
    val recordedDays: Int,
) {
    val totalHours: Double get() = totalMinutes / 60.0
    val avgPomodoros: Double get() = if (recordedDays == 0) 0.0 else totalPomodoros.toDouble() / recordedDays

    companion object {
        fun from(histogram: Map<String, DayHistogram>) = FocusReviewHistorySummary(
            totalPomodoros = histogram.values.sumOf { it.pomodoros },
            totalMinutes = histogram.values.sumOf { it.minutes },
            unknownMinuteDays = histogram.values.count { it.minutesUnknown },
            recordedDays = histogram.size,
        )
    }
}

/** Same wording as Apple's `duration(_:)`. */
fun focusReviewDuration(minutes: Int): String = when {
    minutes < 60 -> "$minutes 分钟"
    minutes % 60 == 0 -> "${minutes / 60} 小时"
    else -> "${minutes / 60} 小时 ${minutes % 60} 分"
}
