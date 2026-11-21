package com.habitica.pomodoro.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.data.HabiticaProfile
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.engine.PomodoroViewModel.UiState
import com.habitica.pomodoro.ui.theme.EmptyState
import com.habitica.pomodoro.ui.theme.KeyValueRow
import com.habitica.pomodoro.ui.theme.LocalSkin
import com.habitica.pomodoro.ui.theme.NoticeText
import com.habitica.pomodoro.ui.theme.PageHeader
import com.habitica.pomodoro.ui.theme.SectionTitle
import com.habitica.pomodoro.ui.theme.SkinButton
import com.habitica.pomodoro.ui.theme.SkinButtonKind
import com.habitica.pomodoro.ui.theme.SkinCard
import com.habitica.pomodoro.ui.theme.SkinTone
import com.habitica.pomodoro.ui.theme.StatTile
import com.habitica.pomodoro.ui.theme.tabular
import java.util.Locale

/** Role 页：Habitica 角色面板（HP/MP/EXP/GP、四维属性、成就） */
@Composable
fun RoleScreen(
    vm: PomodoroViewModel,
    state: UiState,
    modifier: Modifier = Modifier,
) {
    val skin = LocalSkin.current
    val c = skin.colors
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = skin.spacing.pageInset)
            .padding(top = 4.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(skin.spacing.pageSpacing),
    ) {
        PageHeader("Role", subtitle = "Habitica 角色面板") {
            SkinButton("刷新", onClick = { vm.refreshProfile() }, kind = SkinButtonKind.Tonal, icon = Icons.Filled.Refresh, compact = true)
        }

        when {
            state.profileLoading && state.profile == null -> {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = c.accent)
                    Text("正在加载角色信息…", style = MaterialTheme.typography.bodyMedium, color = c.muted)
                }
            }
            state.profile == null -> {
                EmptyState(
                    icon = Icons.Outlined.Person,
                    title = state.profileError ?: "无法获取角色信息",
                    message = "请在「设置」中填写 Habitica User ID 与 API Token",
                )
            }
            else -> {
                val p = state.profile!!
                ProfileHeader(p)
                VitalBars(p)
                AttributesCard(p)
                AchievementsCard(p)
                state.profileError?.let { NoticeText(it) }
            }
        }
    }
}

@Composable
private fun ProfileHeader(p: HabiticaProfile) {
    val c = LocalSkin.current.colors
    SkinCard(modifier = Modifier.fillMaxWidth(), tone = SkinTone.Accent, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = p.username.ifEmpty { "—" },
            style = MaterialTheme.typography.titleLarge,
            color = c.ink,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "Lv.${p.level}",
                style = MaterialTheme.typography.titleMedium.tabular(),
                color = c.accent,
            )
            if (p.className.isNotEmpty()) {
                Text(text = p.className, style = MaterialTheme.typography.titleMedium, color = c.muted)
            }
        }
        if (p.lastLoginAt.isNotEmpty()) Text("最近登录 ${p.lastLoginAt}", style = MaterialTheme.typography.bodySmall, color = c.muted)
        if (p.registeredAt.isNotEmpty()) Text("注册于 ${p.registeredAt}", style = MaterialTheme.typography.bodySmall, color = c.muted)
    }
}

/** HP / MP / EXP / GP 四条数值；上限用公式计算（与 Swift 端一致） */
@Composable
private fun VitalBars(p: HabiticaProfile) {
    val c = LocalSkin.current.colors
    SkinCard(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        VitalBar(label = "HP", value = p.hp, max = p.maxHealth, color = c.danger)
        VitalBar(label = "MP", value = p.mp, max = p.maxMP, color = c.rest)
        // EXP 用当前等级内的进度（Swift 端同一公式）
        VitalBar(label = "EXP", value = p.exp, max = p.expToNextLevel, color = c.accent)
        KeyValueRow("金币 (GP)", String.format(Locale.US, "%.2f", p.gp), valueColor = c.highlight)
    }
}

@Composable
private fun VitalBar(label: String, value: Double, max: Double, color: Color) {
    val skin = LocalSkin.current
    val safeMax = if (max <= 0) 1.0 else max
    val fraction = (value / safeMax).toFloat().coerceIn(0f, 1f)
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, style = MaterialTheme.typography.labelLarge, color = skin.colors.ink)
            Text(
                text = "${value.toInt()} / ${max.toInt()}",
                style = MaterialTheme.typography.labelMedium.tabular(),
                color = skin.colors.muted,
            )
        }
        val barShape = if (skin.isPixel) RoundedCornerShape(0.dp) else RoundedCornerShape(50)
        Box(
            Modifier
                .fillMaxWidth()
                .height(8.dp)
                .clip(barShape)
                .background(skin.colors.subtle),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(fraction)
                    .fillMaxHeight()
                    .clip(barShape)
                    .background(color),
            )
        }
    }
}

@Composable
private fun AttributesCard(p: HabiticaProfile) {
    val c = LocalSkin.current.colors
    SkinCard(modifier = Modifier.fillMaxWidth()) {
        SectionTitle("属性")
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            StatTile("${p.str}", "STR", Modifier.weight(1f), color = c.danger)
            StatTile("${p.con}", "CON", Modifier.weight(1f), color = c.accent)
            StatTile("${p.int}", "INT", Modifier.weight(1f), color = c.rest)
            StatTile("${p.per}", "PER", Modifier.weight(1f), color = c.highlight)
        }
    }
}

@Composable
private fun AchievementsCard(p: HabiticaProfile) {
    val c = LocalSkin.current.colors
    SkinCard(modifier = Modifier.fillMaxWidth()) {
        SectionTitle("成就")
        KeyValueRow("连续打卡 (streak)", "${p.streak}", valueColor = c.highlight)
        KeyValueRow("完美天数", "${p.perfectDays}")
        KeyValueRow("完成任务 (Quests)", "${p.questsTotal}")
    }
}
