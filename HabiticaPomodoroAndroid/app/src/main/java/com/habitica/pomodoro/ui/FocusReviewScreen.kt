package com.habitica.pomodoro.ui

import android.content.ActivityNotFoundException
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.outlined.Insights
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.data.FocusReview
import com.habitica.pomodoro.data.FocusReviewBlock
import com.habitica.pomodoro.data.FocusReviewDay
import com.habitica.pomodoro.data.FocusReviewHistorySummary
import com.habitica.pomodoro.data.FocusReviewNavigation
import com.habitica.pomodoro.data.FocusReviewPage
import com.habitica.pomodoro.data.FocusReviewRange
import com.habitica.pomodoro.data.focusReviewDuration
import com.habitica.pomodoro.engine.PomodoroViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.Locale

/** Read-only review of the local calendar-day stores; all aggregation lives in data/FocusReview.kt. */
@Composable
fun FocusReviewScreen(state: PomodoroViewModel.UiState, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    // Polling keeps "today" correct across midnight, sleep and time-zone changes; equal dates don't recompose.
    val today by produceState(FocusReview.today()) {
        while (isActive) {
            delay(30_000)
            value = FocusReview.today()
        }
    }
    var nav by rememberSaveable(stateSaver = navigationSaver) { mutableStateOf(FocusReviewNavigation()) }
    val review = remember(nav.range, nav.page, today, state.histogram, state.dailyBlocks, state.blockHistory, state.plants) {
        FocusReview(nav.range, nav.endDate(today), state.histogram, state.dailyBlocks, state.blockHistory, state.plants)
    }
    val earliest = remember(state.histogram, state.dailyBlocks, state.blockHistory, state.plants) {
        FocusReview.earliestDate(state.histogram, state.dailyBlocks, state.blockHistory, state.plants)
    }
    val summary = remember(state.histogram) { FocusReviewHistorySummary.from(state.histogram) }
    val selected = review.selectedDay(nav.selectedKey)
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val export = rememberCsvExport()
    val recordedDays = review.days.filter { it.hasRecords }.asReversed()

    LazyColumn(
        modifier = modifier,
        state = listState,
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { Header(onBack) }
        item {
            PeriodCard(
                review = review, nav = nav, canPageBack = nav.canPageBack(review, earliest),
                onRange = { nav = nav.withRange(it) },
                onPrevious = { nav = nav.previous(today) },
                onNext = { nav = nav.next(today) },
                onToday = { nav = nav.returnToToday() },
            )
        }
        if (review.hasRecords && selected != null) {
            item { TrendCard(review.days, selected) { nav = nav.select(it) } }
            item(key = "detail") { DayDetailCard(selected) }
            item {
                Text("有记录的日期 · ${recordedDays.size} 天", style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.semantics { heading() })
            }
            items(recordedDays, key = { it.key }) { day ->
                DayRow(day, selected = day.key == selected.key) {
                    nav = nav.select(day.key)
                    // The detail card sits above the list; bring it into view after a pick.
                    scope.launch { listState.animateScrollToItem(DETAIL_ITEM_INDEX) }
                }
            }
        } else {
            item { EmptyState() }
        }
        item { Footer(review, summary, export) }
    }

    export.error?.let { message ->
        AlertDialog(
            onDismissRequest = { export.error = null },
            title = { Text("无法导出 CSV") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { export.error = null }) { Text("好") } },
        )
    }
}

/** Header, period card, trend card come first; keep in sync with the LazyColumn order above. */
private const val DETAIL_ITEM_INDEX = 3

private val navigationSaver = listSaver<FocusReviewNavigation, Any>(
    save = { nav ->
        listOf(nav.range.days, nav.page?.anchor?.toString().orEmpty(), nav.page?.offset ?: 0, nav.selectedKey.orEmpty())
    },
    restore = { saved ->
        val anchor = (saved[1] as String).takeIf { it.isNotEmpty() }?.let(FocusReview::parseKey)
        FocusReviewNavigation(
            range = FocusReviewRange.fromDays(saved[0] as Int),
            page = anchor?.let { FocusReviewPage(it, saved[2] as Int) },
            selectedKey = (saved[3] as String).ifEmpty { null },
        )
    },
)

private class CsvExport {
    var error by mutableStateOf<String?>(null)
    var status by mutableStateOf<String?>(null)
    var launch: (text: String, filename: String) -> Unit = { _, _ -> }
}

/** Storage Access Framework export; the text is captured at tap time, like Apple's fileExporter document. */
@Composable
private fun rememberCsvExport(): CsvExport {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val export = remember { CsvExport() }
    // Saveable so the captured text survives activity recreation while the system picker is in front.
    var pendingText by rememberSaveable { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { uri: Uri? ->
        val text = pendingText
        pendingText = null
        if (uri == null || text == null) return@rememberLauncherForActivityResult
        scope.launch {
            val written = withContext(Dispatchers.IO) {
                runCatching {
                    val stream = context.contentResolver.openOutputStream(uri, "w") ?: throw java.io.IOException("no stream")
                    stream.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                }.isSuccess
            }
            if (written) export.status = "已导出 CSV" else export.error = "写入所选文件失败，请换个位置重试。"
        }
    }
    export.launch = { text, filename ->
        pendingText = text
        try {
            launcher.launch(filename)
        } catch (_: ActivityNotFoundException) {
            pendingText = null
            export.error = "此设备没有可用的文件选择器。"
        }
    }
    return export
}

@Composable
private fun Header(onBack: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回历史")
        }
        Column(Modifier.padding(start = 4.dp)) {
            Text("专注复盘", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
            Text("回看每天的番茄、时间块和种植记录。", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PeriodCard(
    review: FocusReview, nav: FocusReviewNavigation, canPageBack: Boolean,
    onRange: (FocusReviewRange) -> Unit, onPrevious: () -> Unit, onNext: () -> Unit, onToday: () -> Unit,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val ranges = FocusReviewRange.entries
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                ranges.forEachIndexed { index, range ->
                    SegmentedButton(
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = ranges.size),
                        selected = nav.range == range,
                        onClick = { onRange(range) },
                    ) { Text(range.title) }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onPrevious, enabled = canPageBack) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "上一个日期区间")
                }
                Text("${review.startKey} 至 ${review.endKey}", Modifier.weight(1f), textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelMedium)
                IconButton(onClick = onNext, enabled = nav.isPaged) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "下一个日期区间")
                }
            }
            if (nav.isPaged) {
                TextButton(onClick = onToday, modifier = Modifier.align(Alignment.End)) { Text("回到今天") }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            val totals = review.totals
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val allUnknown = totals.unknownMinuteDays > 0 && totals.minutes == 0
                Metric(if (allUnknown) "未知" else focusReviewDuration(totals.minutes),
                    if (totals.unknownMinuteDays > 0 && !allUnknown) "专注时长 · ${totals.unknownMinuteDays} 天未知" else "专注时长",
                    Modifier.weight(1f))
                Metric("${totals.pomodoros}", "完成番茄", Modifier.weight(1f))
                Metric("${totals.activeDays} 天", "专注天数", Modifier.weight(1f))
            }
            if (totals.unknownMinuteDays > 0) {
                Text("旧版只有计数的记录分钟未知，不计入时长，也不按当前设置补造。",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun TrendCard(days: List<FocusReviewDay>, selected: FocusReviewDay, onSelect: (String) -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionTitle("专注趋势")
                Spacer(Modifier.weight(1f))
                Text("按完成的专注分钟计", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            TrendBars(days, selected.key, onSelect)
            val hint = if (days.any { it.minutesUnknown }) "点选日期查看当日明细 · ? 表示分钟未知" else "点选日期查看当日明细"
            Text(hint, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Canvas bars for every range; per-day labels only fit the 7-day window. */
@Composable
private fun TrendBars(days: List<FocusReviewDay>, selectedKey: String, onSelect: (String) -> Unit) {
    val colors = MaterialTheme.colorScheme
    val labeled = days.size <= 7
    val peak = maxOf(1, days.maxOfOrNull { it.minutes } ?: 0)
    val currentOnSelect by rememberUpdatedState(onSelect)
    val labelStyle = MaterialTheme.typography.labelSmall
    val selectedIndex = days.indexOfFirst { it.key == selectedKey }
    // Highlight and hit-testing span the whole column (labels included), like Apple's day buttons.
    Column(
        Modifier
            .fillMaxWidth()
            .drawBehind {
                if (selectedIndex < 0) return@drawBehind
                val slot = size.width / days.size
                drawRoundRect(colors.primaryContainer, topLeft = Offset(slot * selectedIndex, 0f), size = Size(slot, size.height),
                    cornerRadius = CornerRadius(minOf(6.dp.toPx(), slot / 2)))
            }
            .pointerInput(days) {
                detectTapGestures { offset ->
                    val index = (offset.x / size.width * days.size).toInt().coerceIn(0, days.lastIndex)
                    currentOnSelect(days[index].key)
                }
            },
    ) {
        if (labeled) {
            Row(Modifier.fillMaxWidth()) {
                days.forEach { day ->
                    val active = day.key == selectedKey
                    Text(if (day.minutesUnknown) "?" else "${day.minutes}", Modifier.weight(1f), textAlign = TextAlign.Center,
                        style = labelStyle, maxLines = 1,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (active) colors.primary else colors.onSurfaceVariant)
                }
            }
        }
        Canvas(
            Modifier
                .fillMaxWidth()
                .height(if (labeled) 64.dp else 88.dp)
                .semantics { contentDescription = "专注趋势图，${days.first().key} 至 ${days.last().key}；点选日期查看当日明细" },
        ) {
            val slot = size.width / days.size
            val barWidth = minOf(slot * 0.62f, 15.dp.toPx())
            val radius = CornerRadius(minOf(3.dp.toPx(), barWidth / 2))
            val minBar = 3.dp.toPx()
            val maxBar = size.height - 6.dp.toPx()
            days.forEachIndexed { index, day ->
                val active = index == selectedIndex
                val left = slot * index
                val height = if (day.minutes > 0) maxOf(minBar, maxBar * day.minutes / peak) else minBar
                val color = when {
                    day.minutes > 0 -> colors.primary.copy(alpha = if (active) 1f else 0.6f)
                    day.minutesUnknown -> colors.primary.copy(alpha = 0.3f)
                    else -> colors.outlineVariant
                }
                drawRoundRect(color, topLeft = Offset(left + (slot - barWidth) / 2, size.height - 3.dp.toPx() - height),
                    size = Size(barWidth, height), cornerRadius = radius)
            }
        }
        Row(Modifier.fillMaxWidth()) {
            if (labeled) {
                days.forEach { day ->
                    val active = day.key == selectedKey
                    Text(shortDate(day.key), Modifier.weight(1f), textAlign = TextAlign.Center, style = labelStyle, maxLines = 1,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (active) colors.primary else colors.onSurface)
                }
            } else {
                Text(shortDate(days.first().key), style = labelStyle, color = colors.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Text(shortDate(days.last().key), style = labelStyle, color = colors.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun DayDetailCard(day: FocusReviewDay) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionTitle("当日明细")
                Spacer(Modifier.weight(1f))
                Text("${day.key} ${weekdayName(day.date)}", style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary)
            }
            if (day.hasRecords) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Metric(if (day.minutesUnknown) "未知" else focusReviewDuration(day.minutes), "专注时长", Modifier.weight(1f))
                    Metric("${day.pomodoros}", "完成番茄", Modifier.weight(1f))
                    Metric("${day.completedBlocks}", "达标时间块", Modifier.weight(1f))
                }
                BlockDetails(day.blocks)
                PlantDetails(day)
            } else {
                Text("当天没有专注、时间块或种植记录。", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun BlockDetails(blocks: List<FocusReviewBlock>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionTitle("时间块")
        if (blocks.isEmpty()) {
            Text("当天没有时间块记录", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        blocks.forEach { block ->
            Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.small) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("B${block.index + 1}", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                    Text(block.goal.orEmpty(), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text("${block.completedPomodoros} 个番茄", style = MaterialTheme.typography.bodySmall)
                    if (block.isCompleted) {
                        Icon(Icons.Filled.CheckCircle, contentDescription = null, Modifier.size(16.dp),
                            tint = MaterialTheme.colorScheme.primary)
                        Text("曾达标", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
        }
    }
}

@Composable
private fun PlantDetails(day: FocusReviewDay) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionTitle("种植")
        if (day.shrubs > 0 || day.trees > 0 || day.wilted > 0) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Metric("${day.shrubs}", "灌木", Modifier.weight(1f))
                Metric("${day.trees}", "树", Modifier.weight(1f))
                Metric("${day.wilted}", "枯萎", Modifier.weight(1f))
            }
        } else {
            Text("当天没有种植记录", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun DayRow(day: FocusReviewDay, selected: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val shape = MaterialTheme.shapes.small
    val minutes = if (day.minutesUnknown) "分钟未知" else "${day.minutes} 分钟"
    val blocks = if (day.completedBlocks > 0) " · 达标 ${day.completedBlocks} 块" else ""
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .then(if (selected) Modifier.background(colors.primaryContainer) else Modifier)
            .selectable(selected = selected, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("${shortDate(day.key)} ${weekdayName(day.date)}", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) colors.primary else colors.onSurface)
        Text("${day.pomodoros} 个番茄 · $minutes$blocks", Modifier.padding(start = 12.dp),
            style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
    }
}

@Composable
private fun EmptyState() {
    Card(Modifier.fillMaxWidth()) {
        Column(
            Modifier.fillMaxWidth().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Outlined.Insights, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("这段时间还没有专注记录", style = MaterialTheme.typography.titleSmall)
            Text("所选日期内没有番茄、时间块或种植记录。", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun Footer(review: FocusReview, summary: FocusReviewHistorySummary, export: CsvExport) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FilledTonalButton(
                onClick = { export.status = null; export.launch(review.csv, review.csvFilename) },
                enabled = review.days.isNotEmpty(),
            ) {
                Icon(Icons.Filled.FileDownload, contentDescription = null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("导出 CSV")
            }
            export.status?.let {
                Spacer(Modifier.width(12.dp))
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            }
        }
        val muted = MaterialTheme.colorScheme.onSurfaceVariant
        Text("全部历史 · ${summary.totalPomodoros} 个番茄 · ${oneDecimal(summary.totalHours)} 小时",
            style = MaterialTheme.typography.bodySmall, color = muted)
        if (summary.unknownMinuteDays > 0) {
            Text("其中 ${summary.unknownMinuteDays} 天为旧版计数记录，分钟未知，未计入小时。",
                style = MaterialTheme.typography.bodySmall, color = muted)
        }
        Text("记录日均 ${oneDecimal(summary.avgPomodoros)} 个番茄", style = MaterialTheme.typography.bodySmall, color = muted)
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
}

@Composable
private fun Metric(value: String, caption: String, modifier: Modifier = Modifier) {
    Column(modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1,
            overflow = TextOverflow.Ellipsis)
        Text(caption, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun shortDate(key: String): String = key.takeLast(5).replace('-', '/')

private fun weekdayName(date: LocalDate): String =
    "周" + "一二三四五六日"[date.dayOfWeek.value - 1]

private fun oneDecimal(value: Double): String = String.format(Locale.US, "%.1f", value)
