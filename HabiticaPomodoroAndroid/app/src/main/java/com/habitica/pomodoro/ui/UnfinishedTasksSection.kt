package com.habitica.pomodoro.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.data.TOP_THREE_MAX_FIXED_TASKS
import com.habitica.pomodoro.data.UnfinishedTask
import com.habitica.pomodoro.data.hasRoom
import com.habitica.pomodoro.data.unfinishedTasks
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.engine.PomodoroViewModel.UiState

/**
 * 「未完成任务」：昨天及更早（逻辑日）仍未完成的任务。可转到今天的原分类，或确认后删除（已同步的
 * Habitica todo 一并删除）；今日分类已满时任务留在这里并说明原因。只用 MaterialTheme 的颜色、字体与
 * 形状，由当前皮肤统一着色。
 */
@Composable
fun UnfinishedTasksSection(
    vm: PomodoroViewModel,
    state: UiState,
    modifier: Modifier = Modifier,
) {
    val today = vm.todayKey()
    val store = state.store
    val tasks = remember(store, today) { store.unfinishedTasks(today) }
    var pendingDelete by remember { mutableStateOf<UnfinishedTask?>(null) }
    // A move can still be refused at action time (row changed meanwhile); show why on that row.
    var hints by remember { mutableStateOf(emptyMap<String, String>()) }

    Card(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "未完成任务",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f).semantics { heading() },
                )
                Text(
                    text = "${tasks.size} 件",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(
                text = if (tasks.isEmpty()) "没有跨天未完成的任务。" else "可以转到今天的原分类，也可以删除。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            tasks.forEach { item ->
                key(item.task.id) {
                    val category = store.categoryNames.getOrElse(item.category) { "分类 ${item.category + 1}" }
                    UnfinishedRow(
                        item = item,
                        category = category,
                        fullHint = if (store.hasRoom(today, item.category)) null
                            else "今日「$category」已满 $TOP_THREE_MAX_FIXED_TASKS 条，完成或删除今天的任务后再转入",
                        hint = hints[item.task.id],
                        onMove = {
                            val refused = vm.moveUnfinishedToToday(item.dateKey, item.category, item.task.id)
                            hints = if (refused == null) hints - item.task.id else hints + (item.task.id to refused)
                        },
                        onDelete = { pendingDelete = item },
                    )
                }
            }
        }
    }

    pendingDelete?.let { item ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("删除任务") },
            text = { Text("「${item.task.title}」（${item.dateKey}）将被删除，同时从 Habitica 移除对应的 todo。") },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    vm.deleteUnfinishedTask(item.dateKey, item.category, item.task.id)
                }) { Text("删除", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun UnfinishedRow(
    item: UnfinishedTask,
    category: String,
    fullHint: String?,
    hint: String?,
    onMove: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = item.task.title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "${item.dateKey} · $category",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            (fullHint ?: hint)?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            item.task.syncError?.let {
                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
            }
        }
        TextButton(onClick = onMove, enabled = fullHint == null) { Text("转到今天") }
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Outlined.Delete,
                contentDescription = "删除任务",
                modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
