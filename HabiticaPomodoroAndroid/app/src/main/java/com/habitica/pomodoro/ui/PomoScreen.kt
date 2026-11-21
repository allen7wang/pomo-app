package com.habitica.pomodoro.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.engine.PomodoroViewModel.Phase
import com.habitica.pomodoro.engine.PomodoroViewModel.UiState
import com.habitica.pomodoro.ui.theme.LocalSkin
import com.habitica.pomodoro.ui.theme.SkinButton
import com.habitica.pomodoro.ui.theme.SkinButtonKind
import com.habitica.pomodoro.ui.theme.SkinCard
import com.habitica.pomodoro.ui.theme.SkinChip
import com.habitica.pomodoro.ui.theme.SkinDivider
import com.habitica.pomodoro.ui.theme.SkinLayout
import com.habitica.pomodoro.ui.theme.SkinTextButton
import com.habitica.pomodoro.ui.theme.SkinTimerRing
import com.habitica.pomodoro.ui.theme.StatTile
import com.habitica.pomodoro.ui.theme.StatusPill
import com.habitica.pomodoro.ui.theme.tabular
import java.util.Locale

/** 番茄钟主页：圆环计时器 + 主控制按钮 + 今日统计；排布跟随皮肤的 layout token */
@Composable
fun PomoScreen(
    vm: PomodoroViewModel,
    state: UiState,
    modifier: Modifier = Modifier,
) {
    val skin = LocalSkin.current
    val sp = skin.spacing
    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val inner = maxWidth - sp.pageInset * 2
        if (skin.layout == SkinLayout.Columns && maxWidth >= 600.dp) {
            // Studio on tablets / landscape: focus on the left, numbers and blocks on the right.
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = sp.pageInset),
                horizontalArrangement = Arrangement.spacedBy(sp.pageSpacing * 2),
            ) {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState())
                        .padding(vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(sp.pageSpacing),
                ) {
                    FocusHeading(state)
                    Ring(state, vm, minOf(260.dp, (inner - sp.pageSpacing * 2) / 2))
                    ControlButtons(state, vm)
                    BreakShortcuts(state, vm)
                }
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState())
                        .padding(vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(sp.pageSpacing),
                ) {
                    StatsCard(state)
                    if (state.settings.enableBlockMode) BlockGarden(vm, state)
                }
            }
        } else {
            val ring = when (skin.layout) {
                SkinLayout.Compact -> 236.dp
                SkinLayout.Airy -> 262.dp
                SkinLayout.Columns -> 208.dp
            }
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = sp.pageInset)
                    .padding(top = 4.dp, bottom = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(sp.pageSpacing),
            ) {
                FocusHeading(state)
                Ring(state, vm, minOf(ring, inner))
                ControlButtons(state, vm)
                BreakShortcuts(state, vm)
                StatsCard(state)
                if (state.settings.enableBlockMode) BlockGarden(vm, state)
            }
        }
    }
}

private fun phaseLabel(phase: Phase): String = when (phase) {
    Phase.IDLE -> "准备开始"
    Phase.POMODORO -> "专注中"
    Phase.BREAK -> "休息中"
    Phase.LONG_BREAK -> "长休息中"
    Phase.BREAK_EXTENSION -> "休息延长：回到专注"
    Phase.MANUAL_BREAK -> "该休息了，点击开始休息"
}

private val Phase.isBreak: Boolean
    get() = this == Phase.BREAK || this == Phase.LONG_BREAK || this == Phase.MANUAL_BREAK

@Composable
private fun phaseColor(phase: Phase): Color {
    val c = LocalSkin.current.colors
    return when {
        phase == Phase.POMODORO -> c.accent
        phase.isBreak -> c.rest
        phase == Phase.BREAK_EXTENSION -> c.danger
        else -> c.muted
    }
}

/** Layout-specific heading: compact = eyebrow + line, airy = centered serif line, columns = status strip. */
@Composable
private fun FocusHeading(state: UiState) {
    val skin = LocalSkin.current
    val c = skin.colors
    val pill = @Composable { StatusPill(phaseLabel(state.phase), phaseColor(state.phase)) }
    when (skin.layout) {
        SkinLayout.Compact -> Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("你的专注", style = MaterialTheme.typography.labelMedium, color = c.muted)
                Text("把重要的事，先做好。", style = MaterialTheme.typography.titleLarge, color = c.ink)
            }
            pill()
        }
        SkinLayout.Airy -> Column(
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                "留一刻，给自己。",
                style = MaterialTheme.typography.headlineSmall,
                color = c.ink,
                textAlign = TextAlign.Center,
            )
            pill()
        }
        SkinLayout.Columns -> Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            pill()
            Spacer(Modifier.weight(1f))
            Text(
                "本组 ${state.pomoSetCounter} / ${state.settings.pomoSetNum}",
                style = MaterialTheme.typography.labelLarge.tabular(),
                color = c.muted,
            )
        }
    }
}

/** 圆环计时器：点击圆环即启动/暂停（与 iOS 端交互一致） */
@Composable
private fun Ring(state: UiState, vm: PomodoroViewModel, size: Dp) {
    val progress = if (state.totalSeconds > 0) 1f - state.remainingSeconds.toFloat() / state.totalSeconds else 0f
    // Idle shows the configured focus length, as on Mac/iOS, instead of 00:00.
    val time = if (state.phase == Phase.IDLE && state.remainingSeconds == 0) {
        String.format(Locale.US, "%02d:00", state.settings.pomoDurationMins)
    } else {
        formatTime(state.remainingSeconds)
    }
    val caption = when {
        state.isRunning -> "点击圆环暂停"
        state.remainingSeconds > 0 -> "点击圆环继续"
        else -> "点击圆环开始"
    }
    SkinTimerRing(
        progress = progress,
        tint = phaseColor(state.phase).takeIf { state.phase != Phase.IDLE } ?: LocalSkin.current.colors.accent,
        timeText = time,
        caption = caption,
        ringSize = size,
        onClick = { vm.activate() },
    )
}

@Composable
private fun ControlButtons(state: UiState, vm: PomodoroViewModel) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
    ) {
        SkinButton(
            text = when {
                !state.isRunning && state.phase == Phase.IDLE -> "开始番茄"
                !state.isRunning && state.phase == Phase.MANUAL_BREAK -> "开始休息"
                state.isRunning -> "暂停"
                else -> "继续"
            },
            onClick = { vm.activate() },
            modifier = Modifier.weight(1f),
            kind = if (state.phase.isBreak) SkinButtonKind.Rest else SkinButtonKind.Primary,
            icon = if (state.isRunning) Icons.Filled.Pause else Icons.Filled.PlayArrow,
        )

        if (state.phase.isBreak || state.phase == Phase.BREAK_EXTENSION) {
            SkinButton(
                text = "跳过休息",
                onClick = { vm.skipBreak() },
                modifier = Modifier.weight(0.7f),
                kind = SkinButtonKind.Quiet,
            )
        }

        if (state.phase != Phase.IDLE) {
            SkinButton(
                text = "放弃",
                onClick = { vm.stop() },
                modifier = Modifier.weight(0.5f),
                kind = SkinButtonKind.Danger,
            )
        }
    }
}

@Composable
private fun BreakShortcuts(state: UiState, vm: PomodoroViewModel) {
    val c = LocalSkin.current.colors
    Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("休息", style = MaterialTheme.typography.labelLarge, color = c.muted)
            Spacer(Modifier.weight(1f))
            listOf(1, 5, 15, 30).forEach { minutes ->
                SkinChip(
                    label = "${minutes}m",
                    selected = false,
                    onClick = { vm.takeBreak(minutes) },
                    enabled = state.phase == Phase.IDLE && !state.isRunning,
                    color = c.rest,
                    idleColor = c.rest,
                )
            }
        }
        if (state.phase == Phase.POMODORO) {
            SkinTextButton("跳到短休息（不计完成）", onClick = vm::skipToBreak, color = c.rest)
        }
    }
}

@Composable
private fun StatsCard(state: UiState) {
    val skin = LocalSkin.current
    val c = skin.colors
    val minutes = state.histogram[com.habitica.pomodoro.data.calendarDayKey()]?.minutes ?: 0
    SkinCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            StatTile("${state.todayPomodoros}", "今日番茄", Modifier.weight(1f))
            VerticalDivider(color = c.line, modifier = Modifier.padding(vertical = 4.dp))
            StatTile("$minutes", "专注分钟", Modifier.weight(1f))
            VerticalDivider(color = c.line, modifier = Modifier.padding(vertical = 4.dp))
            StatTile(
                "${state.pomoSetCounter}/${state.settings.pomoSetNum}",
                "本组进度",
                Modifier.weight(1f),
                color = if (state.pomoSetCounter > 0) c.highlight else c.ink,
            )
        }
        state.profile?.let { p ->
            SkinDivider()
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Habitica", style = MaterialTheme.typography.bodyMedium, color = c.muted, modifier = Modifier.weight(1f))
                val numbers = MaterialTheme.typography.bodyMedium.tabular()
                Text("Lv.${p.level}", style = numbers, fontWeight = FontWeight.SemiBold, color = c.ink)
                Text("♥ ${p.hp.toInt()}", style = numbers, fontWeight = FontWeight.SemiBold, color = c.danger)
                Text("✦ ${p.gp.toInt()}", style = numbers, fontWeight = FontWeight.SemiBold, color = c.highlight)
            }
        }
        if (state.habiticaBusy) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 2.dp, color = c.accent)
                Text("正在同步 Habitica…", style = MaterialTheme.typography.bodySmall, color = c.muted)
            }
        }
        state.message?.let { msg ->
            Text(text = msg, style = MaterialTheme.typography.bodySmall, color = c.accent)
        }
    }
}

fun formatTime(totalSeconds: Int): String {
    val safe = totalSeconds.coerceAtLeast(0)
    val m = safe / 60
    val s = safe % 60
    return String.format(Locale.US, "%02d:%02d", m, s)
}
