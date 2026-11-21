package com.habitica.pomodoro.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.ui.theme.EmptyState
import com.habitica.pomodoro.ui.theme.LocalSkin
import com.habitica.pomodoro.ui.theme.NoticeText
import com.habitica.pomodoro.ui.theme.PageHeader
import com.habitica.pomodoro.ui.theme.SkinCard
import com.habitica.pomodoro.ui.theme.SkinChip
import com.habitica.pomodoro.ui.theme.SkinTextButton
import com.habitica.pomodoro.ui.theme.skinCheckboxColors
import com.habitica.pomodoro.ui.theme.tabular

/** Reads actual Habitica tasks; never substitutes sample records for an unconfigured account. */
@Composable
fun HabiticaListsScreen(vm: PomodoroViewModel, state: PomodoroViewModel.UiState, modifier: Modifier = Modifier) {
    var type by remember { mutableStateOf("habits") }
    val configured = state.settings.connectHabitica && state.settings.uid.isNotBlank() && state.settings.apiToken.isNotBlank()
    val skin = LocalSkin.current
    val c = skin.colors
    LaunchedEffect(type, state.settings.uid, state.settings.apiToken, state.settings.connectHabitica) {
        if (configured) vm.refreshHabiticaTasks(type)
    }
    Column(
        modifier
            .padding(horizontal = skin.spacing.pageInset)
            .padding(top = 4.dp),
        verticalArrangement = Arrangement.spacedBy(skin.spacing.rowSpacing),
    ) {
        PageHeader("打卡", subtitle = "Habitica 习惯与每日任务") {
            SkinTextButton("刷新", onClick = { vm.refreshHabiticaTasks(type) }, enabled = configured && !state.tasksLoading, icon = Icons.Filled.Refresh)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SkinChip("Habits", selected = type == "habits", onClick = { type = "habits" })
            SkinChip("Dailies", selected = type == "dailys", onClick = { type = "dailys" })
        }
        if (!configured) {
            EmptyState(Icons.Outlined.CloudOff, "未配置 Habitica", "请在设置中填写 User ID 与 API Token。")
            return@Column
        }
        state.tasksError?.let { NoticeText(it) }
        if (state.tasksLoading) LinearProgressIndicator(Modifier.fillMaxWidth(), color = c.accent, trackColor = c.subtle)
        val items = if (type == "habits") state.habits else state.dailies
        if (items.isEmpty() && !state.tasksLoading && state.tasksError == null) {
            EmptyState(Icons.Outlined.Inbox, "暂无${if (type == "habits") "习惯" else "每日任务"}", "在 Habitica 中添加后，点击刷新即可看到。")
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(skin.spacing.rowSpacing), contentPadding = PaddingValues(bottom = 20.dp)) {
            items(items, key = { it.id }) { item ->
                val busy = item.id in state.scoringIds
                SkinCard(Modifier.fillMaxWidth(), elevated = false, contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        if (type == "dailys") {
                            Checkbox(checked = item.completed, enabled = !busy, colors = skinCheckboxColors(),
                                onCheckedChange = { vm.scoreHabiticaTask(type, item, if (item.completed) "down" else "up") })
                        } else {
                            // Negative habit = danger, positive = accent.
                            ScoreButton("−", "扣分：${item.text}", c.danger, item.canDown && !busy) { vm.scoreHabiticaTask(type, item, "down") }
                        }
                        Column(Modifier.weight(1f).padding(horizontal = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(item.text, style = MaterialTheme.typography.bodyLarge, color = if (item.completed) c.muted else c.ink)
                            if (item.notes.isNotBlank()) Text(item.notes, maxLines = 2, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall, color = c.muted)
                            Text(if (type == "habits") "value %.1f".format(java.util.Locale.US, item.value) else if (!item.isDue) "今天未到期" else "今天到期",
                                style = MaterialTheme.typography.labelSmall.tabular(),
                                color = when {
                                    type == "habits" && item.value < 0 -> c.danger
                                    type == "dailys" && item.isDue && !item.completed -> c.highlight
                                    else -> c.muted
                                })
                        }
                        if (type == "habits") ScoreButton("+", "加分：${item.text}", c.accent, item.canUp && !busy) { vm.scoreHabiticaTask(type, item, "up") }
                    }
                }
            }
        }
    }
}

/** Round (square in pixel) +/− habit control with a 48dp touch target. */
@Composable
private fun ScoreButton(symbol: String, description: String, color: Color, enabled: Boolean, onClick: () -> Unit) {
    val skin = LocalSkin.current
    val shape = if (skin.isPixel) skin.controlShape else androidx.compose.foundation.shape.CircleShape
    Box(
        modifier = Modifier
            .minimumInteractiveComponentSize()
            .size(38.dp)
            .alpha(if (enabled) 1f else 0.35f)
            .clip(shape)
            .background(color.copy(alpha = if (skin.isDark) 0.18f else 0.10f))
            .border(skin.controlBorder ?: BorderStroke(1.dp, color.copy(alpha = 0.4f)), shape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = MaterialTheme.typography.titleMedium.copy(fontFamily = null), color = color)
    }
}
