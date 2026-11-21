package com.habitica.pomodoro.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.ui.Alignment
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Grass
import androidx.compose.material.icons.outlined.Timer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.ui.theme.EmptyState
import com.habitica.pomodoro.ui.theme.LocalSkin
import com.habitica.pomodoro.ui.theme.PageHeader
import com.habitica.pomodoro.ui.theme.SectionTitle
import com.habitica.pomodoro.ui.theme.SkinCard
import com.habitica.pomodoro.ui.theme.SkinChip
import com.habitica.pomodoro.ui.theme.SkinDivider
import com.habitica.pomodoro.ui.theme.SkinTextButton
import com.habitica.pomodoro.ui.theme.StatTile
import com.habitica.pomodoro.ui.theme.tabular

@Composable
fun HistoryScreen(vm: PomodoroViewModel, state: PomodoroViewModel.UiState, modifier: Modifier = Modifier,
                  onOpenReview: (() -> Unit)? = null) {
    var confirmClear by remember { mutableStateOf(false) }
    var confirmHistogram by remember { mutableStateOf(false) }
    var chartDays by remember { mutableIntStateOf(7) }
    val skin = LocalSkin.current
    val c = skin.colors
    val counts = state.histogram.toSortedMap(reverseOrder())
    val total = counts.values.sumOf { it.pomodoros }; val minutes = counts.values.sumOf { it.minutes }
    val blockDays = (state.plants.mapValues { (date, plant) -> com.habitica.pomodoro.data.DailyBlockProgress(date, List(plant.attempts.size) { 0 }, emptyList()) } + state.dailyBlocks).toSortedMap(reverseOrder())
    LazyColumn(
        modifier.padding(horizontal = skin.spacing.pageInset),
        verticalArrangement = Arrangement.spacedBy(skin.spacing.rowSpacing),
        contentPadding = PaddingValues(top = 4.dp, bottom = 20.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(skin.spacing.pageSpacing)) {
                PageHeader("番茄历史", subtitle = "总专注 ${"%.2f".format(java.util.Locale.US, minutes / 60.0)} 小时 · 日均 ${"%.1f".format(java.util.Locale.US, if (counts.isEmpty()) 0.0 else total.toDouble() / counts.size)} 个 / ${"%.2f".format(java.util.Locale.US, if (counts.isEmpty()) 0.0 else minutes / 60.0 / counts.size)} 小时")
                onOpenReview?.let { SkinChip("专注复盘", selected = false, onClick = it) }
                SkinCard(Modifier.fillMaxWidth()) {
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), verticalAlignment = Alignment.CenterVertically) {
                        StatTile("${state.todayPomodoros}", "今日", Modifier.weight(1f), color = c.accent)
                        VerticalDivider(color = c.line, modifier = Modifier.padding(vertical = 4.dp))
                        StatTile("$total", "累计番茄", Modifier.weight(1f))
                        VerticalDivider(color = c.line, modifier = Modifier.padding(vertical = 4.dp))
                        StatTile("${counts.size}", "天", Modifier.weight(1f))
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(7, 30).forEach { n -> SkinChip("近 $n 条", selected = chartDays == n, onClick = { chartDays = n }) }
                        Spacer(Modifier.weight(1f))
                        SkinTextButton("清空统计", onClick = { confirmHistogram = true }, enabled = counts.isNotEmpty(), color = c.danger)
                    }
                    if (counts.isNotEmpty()) {
                        val recent = state.histogram.toSortedMap().entries.toList().takeLast(chartDays)
                        val max = state.histogram.values.maxOf { it.pomodoros }.coerceAtLeast(1)
                        val barShape = if (skin.isPixel) RoundedCornerShape(0.dp) else RoundedCornerShape(topStart = 4.dp, topEnd = 4.dp)
                        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Bottom) {
                            recent.forEach { (date, hist) ->
                                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text("${hist.pomodoros}", style = MaterialTheme.typography.labelSmall.tabular(), color = c.ink)
                                    Box(Modifier.width(24.dp).height((hist.pomodoros.toFloat() / max * 120).coerceAtLeast(2f).dp)
                                        .clip(barShape).background(if (hist.pomodoros > 0) c.accent else c.line))
                                    Text(date.takeLast(5), style = MaterialTheme.typography.labelSmall.tabular(), color = c.muted)
                                }
                            }
                        }
                    }
                    if (counts.values.any { it.weekday.isBlank() && it.pomodoros > 0 }) Text("旧版只有计数的记录保留原日期；历史分钟未知，不按当前设置补造。",
                        style = MaterialTheme.typography.bodySmall, color = c.muted)
                }
            }
        }
        if (counts.isEmpty()) item { EmptyState(Icons.Outlined.Timer, "还没有番茄记录", "暂无已完成番茄。完成计时后会记录在这里。") }
        items(counts.entries.toList()) { (day, value) ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(day, style = MaterialTheme.typography.bodyMedium.tabular(), color = c.ink)
                Text("  ${value.weekday}", style = MaterialTheme.typography.bodySmall, color = c.muted, modifier = Modifier.weight(1f))
                Text("${value.pomodoros} 🍅", style = MaterialTheme.typography.bodyMedium.tabular(), fontWeight = FontWeight.SemiBold, color = c.ink)
                Text(" · ${if (value.weekday.isBlank() && value.pomodoros > 0) "分钟未知" else "${value.minutes} 分钟"}",
                    style = MaterialTheme.typography.bodySmall.tabular(), color = c.muted)
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(skin.spacing.rowSpacing)) {
                SkinDivider(Modifier.padding(vertical = 4.dp))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    SectionTitle("时间块历史", Modifier.weight(1f))
                    SkinTextButton("清空块记录", onClick = { confirmClear = true }, enabled = blockDays.isNotEmpty() || state.plants.isNotEmpty(), color = c.danger)
                }
                if (blockDays.isEmpty()) EmptyState(Icons.Outlined.Grass, "还没有块进度", "暂无块进度。开启时间块并完成番茄后生成。")
            }
        }
        items(blockDays.entries.toList()) { (day, progress) ->
            SkinCard(Modifier.fillMaxWidth(), elevated = false, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(day, style = MaterialTheme.typography.titleSmall.tabular(), color = c.ink)
                progress.blockProgress.forEachIndexed { i, n ->
                    if (n > 0 || !state.plants[day]?.attempts?.getOrNull(i).isNullOrEmpty()) {
                        val attempts = state.plants[day]?.attempts?.getOrNull(i).orEmpty()
                        val trees = state.plants[day]?.trees?.getOrNull(i) ?: 0
                        Text("B${i + 1}: $n 番茄 · 🌿${attempts.count { it == "shrub" }} · 🥀${attempts.count { it == "wilted" }} · 🌳$trees",
                            style = MaterialTheme.typography.bodySmall.tabular(), color = c.ink)
                    }
                }
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(skin.spacing.rowSpacing)) {
                SkinDivider(Modifier.padding(vertical = 4.dp))
                SectionTitle("每日任务历史")
                if (state.store.history.isEmpty()) EmptyState(Icons.Outlined.Checklist, "还没有任务记录", "暂无本机每日任务。")
            }
        }
        items(state.store.history.toSortedMap(reverseOrder()).entries.toList()) { (day, tasks) ->
            SkinCard(Modifier.fillMaxWidth(), elevated = false, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(day, style = MaterialTheme.typography.titleSmall.tabular(), color = c.ink)
                tasks.taskGroups.forEachIndexed { index, group ->
                    if (group.isNotEmpty()) {
                        Text("${state.store.categoryNames.getOrElse(index) { "分类 ${index + 1}" }} · ${group.count { it.isCompleted }}/${group.size}",
                            style = MaterialTheme.typography.labelMedium.tabular(), color = c.accent, modifier = Modifier.padding(top = 4.dp))
                        group.forEach { task ->
                            Text("${if (task.isCompleted) "✓" else "○"} ${task.title}", style = MaterialTheme.typography.bodySmall,
                                color = if (task.isCompleted) c.ink else c.muted)
                        }
                    }
                }
            }
        }
    }
    if (confirmHistogram) AlertDialog(onDismissRequest = { confirmHistogram = false }, title = { Text("清空番茄统计？") },
        text = { Text("将清空番茄数、专注分钟和任务用时。任务、时间块和植物记录会保留。") },
        confirmButton = { TextButton(onClick = { vm.clearHistogram(); confirmHistogram = false }) { Text("确认清空", color = c.danger) } },
        dismissButton = { TextButton(onClick = { confirmHistogram = false }) { Text("取消") } })
    // Local Task records are historical snapshots, not fabricated Habitica todos.
    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false }, title = { Text("清空块历史与植物？") },
        text = { Text("不会删除番茄计数和每日任务；此操作不可撤销。") },
        confirmButton = { TextButton(onClick = { vm.clearBlockHistory(); confirmClear = false }) { Text("确认清空", color = c.danger) } },
        dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("取消") } })
}
