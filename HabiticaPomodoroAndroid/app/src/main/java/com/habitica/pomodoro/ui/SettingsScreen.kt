package com.habitica.pomodoro.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import com.habitica.pomodoro.service.PomoAudio
import com.habitica.pomodoro.data.HabiticaAPI
import com.habitica.pomodoro.data.isValidHabiticaUid
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.engine.PomodoroViewModel.UiState
import com.habitica.pomodoro.ui.theme.AppearanceStylePicker
import com.habitica.pomodoro.ui.theme.AppSkinState
import com.habitica.pomodoro.ui.theme.LocalSkin
import com.habitica.pomodoro.ui.theme.NoticeText
import com.habitica.pomodoro.ui.theme.PageHeader
import com.habitica.pomodoro.ui.theme.SectionTitle
import com.habitica.pomodoro.ui.theme.SettingStepperRow
import com.habitica.pomodoro.ui.theme.SettingSwitchRow
import com.habitica.pomodoro.ui.theme.SkinButton
import com.habitica.pomodoro.ui.theme.SkinCard
import com.habitica.pomodoro.ui.theme.SkinDivider
import com.habitica.pomodoro.ui.theme.SkinTextButton
import com.habitica.pomodoro.ui.theme.skinTextFieldColors
import com.habitica.pomodoro.ui.theme.tabular

/**
 * 设置页。一般选项即时保存；User ID 和自定义 API 地址校验后明确应用。
 *
 * 注意：Android 无法访问 iCloud Drive（Apple 不向非苹果平台开放），
 * 因此本机设置/历史存在应用私有目录，任务与习惯经 Habitica 云端跨端一致。
 */
@Composable
fun SettingsScreen(
    vm: PomodoroViewModel,
    state: UiState,
    skins: AppSkinState,
    modifier: Modifier = Modifier,
) {
    val s = state.settings
    val skin = LocalSkin.current
    val c = skin.colors
    var showToken by remember { mutableStateOf(false) }
    var uidDraft by remember(s.uid) { mutableStateOf(s.uid) }
    var uidError by remember(s.uid) { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val preview = remember { PomoAudio(context.applicationContext) }
    DisposableEffect(preview) { onDispose { preview.stopAll(); vm.refreshRuntimeAudio() } }
    var serverDraft by remember(s.developerServerUrl) { mutableStateOf(s.developerServerUrl) }
    var confirmServer by remember { mutableStateOf(false) }
    var serverError by remember { mutableStateOf<String?>(null) }
    var confirmMarkerCleanup by remember { mutableStateOf(false) }
    if (confirmServer) AlertDialog(onDismissRequest = { confirmServer = false }, title = { Text("确认自定义 API 服务") },
        text = { Text("User ID 和 API Token 会发送给此 HTTPS 服务器。仅使用你控制或信任的服务；HTTPS 不代表服务可信。不跟随重定向，也不接受 HTTP 地址。") },
        confirmButton = { TextButton(onClick = { vm.updateSettings { it.copy(developerServerUrl = serverDraft.trim()) }; confirmServer = false }) { Text("确认使用") } },
        dismissButton = { TextButton(onClick = { confirmServer = false }) { Text("取消") } })
    if (confirmMarkerCleanup) AlertDialog(onDismissRequest = { confirmMarkerCleanup = false }, title = { Text("清理隔离中的创建标记") },
        text = { Text("将清空当前账号的 ${state.store.deletedCreateMarkers.size} 个待处理创建标记与 ${state.store.deletedCloudIdMarkers.size} 个远端 ID 关联，之后同签名的云端任务会恢复正常合并。" +
                "删除队列（${state.store.deletedCloudIds.size}）与已删除任务的原始关联不会改动，其他账号分区不受影响。仅当你确认云端没有仍需核对的同签名任务时继续。") },
        confirmButton = { TextButton(onClick = { vm.clearQuarantinedCreateMarkers(); confirmMarkerCleanup = false }) { Text("确认清理", color = c.danger) } },
        dismissButton = { TextButton(onClick = { confirmMarkerCleanup = false }) { Text("取消") } })

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = skin.spacing.pageInset)
            .padding(top = 4.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(skin.spacing.pageSpacing),
    ) {
        PageHeader("设置", subtitle = "即时保存在本机；User ID 与 API 地址需确认后应用")

        SettingsCard(title = "外观") {
            AppearanceStylePicker(skins)
        }

        // MARK: Habitica
        SettingsCard(title = "Habitica") {
            SwitchRow(
                label = "连接 Habitica",
                checked = s.connectHabitica,
                onCheckedChange = { v -> vm.updateSettings { it.copy(connectHabitica = v) } },
            )
            if (s.connectHabitica) {
                OutlinedTextField(
                    value = uidDraft,
                    onValueChange = { v ->
                        uidDraft = v
                        uidError = if (isValidHabiticaUid(v)) null else "User ID 必须是完整 UUID，不能包含空白"
                    },
                    label = { Text("User ID") },
                    singleLine = true,
                    isError = uidError != null,
                    supportingText = { uidError?.let { Text(it) } },
                    modifier = Modifier.fillMaxWidth(),
                    shape = skin.controlShape,
                    colors = skinTextFieldColors(),
                )
                SkinTextButton("应用 User ID", onClick = {
                    if (!isValidHabiticaUid(uidDraft)) uidError = "User ID 必须是完整 UUID，不能包含空白；原账号未改变"
                    else {
                        vm.updateSettings { it.copy(uid = uidDraft) }
                        uidError = null
                    }
                })
                OutlinedTextField(
                    value = s.apiToken,
                    onValueChange = { v -> vm.updateSettings { it.copy(apiToken = v) } },
                    label = { Text("API Token") },
                    singleLine = true,
                    visualTransformation = if (showToken) VisualTransformation.None else PasswordVisualTransformation(),
                    supportingText = {
                        Text(
                            if (showToken) "点击隐藏 Token" else "点击右侧按钮可临时显示",
                        )
                    },
                    trailingIcon = {
                        SkinTextButton(if (showToken) "隐藏" else "显示", onClick = { showToken = !showToken })
                    },
                    modifier = Modifier.fillMaxWidth(),
                    shape = skin.controlShape,
                    colors = skinTextFieldColors(),
                )
                Text(
                    text = "获取方式：Habitica 网站 → Settings → API",
                    style = MaterialTheme.typography.bodySmall,
                    color = c.muted,
                )
                OutlinedTextField(serverDraft, onValueChange = { serverDraft = it; serverError = null },
                    label = { Text("自定义 HTTPS API 根地址（留空使用官方）") }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                    supportingText = { Text("例如 https://your-server.example/api/v3/；凭据将发送给该服务") },
                    shape = skin.controlShape, colors = skinTextFieldColors())
                SkinTextButton("应用 API 地址", onClick = {
                    if (!HabiticaAPI.validServerUrl(serverDraft)) serverError = "仅支持不含账号、查询参数和片段的 HTTPS 地址"
                    else if (serverDraft.isBlank()) vm.updateSettings { it.copy(developerServerUrl = "") }
                    else confirmServer = true
                })
                serverError?.let { NoticeText(it) }
                SkinButton(
                    text = "测试连接并刷新角色",
                    onClick = { vm.refreshProfile(); vm.ensureDefaultHabits() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = isValidHabiticaUid(s.uid) && s.apiToken.isNotBlank(),
                )
                state.profileError?.let { NoticeText(it) }
                state.profile?.let { p ->
                    Text(
                        text = "✓ 已连接：${p.username.ifEmpty { "—" }} (Lv.${p.level})",
                        style = MaterialTheme.typography.bodySmall,
                        color = c.accent,
                    )
                }
            }
        }

        // MARK: 番茄钟
        SettingsCard(title = "番茄钟") {
            StepperRow(
                label = "番茄时长",
                value = s.pomoDurationMins,
                range = 1..120,
                suffix = "分钟",
                onChange = { v -> vm.updateSettings { it.copy(pomoDurationMins = v) } },
            )
            StepperRow(
                label = "短休息",
                value = s.breakDuration,
                range = 1..60,
                suffix = "分钟",
                onChange = { v -> vm.updateSettings { it.copy(breakDuration = v) } },
            )
            StepperRow(
                label = "长休息",
                value = s.longBreakDuration,
                range = 1..120,
                suffix = "分钟",
                onChange = { v -> vm.updateSettings { it.copy(longBreakDuration = v) } },
            )
            StepperRow(
                label = "长休息间隔",
                value = s.pomoSetNum,
                range = 1..12,
                suffix = "个番茄",
                onChange = { v -> vm.updateSettings { it.copy(pomoSetNum = v) } },
            )
            StepperRow("休息延长", s.breakExtention, 0..30, "分钟") { v -> vm.updateSettings { it.copy(breakExtention = v) } }
            SwitchRow("延长结束后清空连击", s.resetPomoAfterBreak) { v -> vm.updateSettings { it.copy(resetPomoAfterBreak = v) } }
            SkinDivider()
            SettingSwitchRow(
                label = "手动开始休息",
                checked = s.manualBreak,
                onCheckedChange = { v -> vm.updateSettings { it.copy(manualBreak = v) } },
                hint = if (s.manualBreak) "番茄结束后等你点击才开始休息" else "番茄结束后自动进入休息",
            )
        }

        SettingsCard(title = "种植与时间块") { BlockSettings(vm, state) }

        SettingsCard(title = "Habitica 番茄打分") {
            SwitchRow("完成番茄时给习惯加分", s.pomoHabitPlus) { v -> vm.updateSettings { it.copy(pomoHabitPlus = v) } }
            SwitchRow("中途放弃时扣分", s.pomoHabitMinus) { v -> vm.updateSettings { it.copy(pomoHabitMinus = v) } }
            SwitchRow("休息延长超时扣分", s.breakExtentionFails) { v -> vm.updateSettings { it.copy(breakExtentionFails = v) } }
            SwitchRow("使用自定义番茄 Habit", s.customPomodoroTask) { v -> vm.updateSettings { it.copy(customPomodoroTask = v) } }
            if (s.customPomodoroTask) OutlinedTextField(value = s.pomodoroTaskId.orEmpty(), onValueChange = { v -> vm.updateSettings { it.copy(pomodoroTaskId = v.trim().ifBlank { null }) } },
                label = { Text("番茄 Habit 任务 ID") }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                shape = skin.controlShape, colors = skinTextFieldColors())
            SwitchRow("完成一组时给习惯加分", s.pomoSetHabitPlus) { v -> vm.updateSettings { it.copy(pomoSetHabitPlus = v) } }
            SwitchRow("使用自定义 Combo Habit", s.customSetTask) { v -> vm.updateSettings { it.copy(customSetTask = v) } }
            if (s.customSetTask) OutlinedTextField(value = s.pomodoroSetTaskId.orEmpty(), onValueChange = { v -> vm.updateSettings { it.copy(pomodoroSetTaskId = v.trim().ifBlank { null }) } },
                label = { Text("一组 Habit 任务 ID") }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                shape = skin.controlShape, colors = skinTextFieldColors())
            SwitchRow("块达标时奖励一次", s.blockRewardEnabled) { v -> vm.updateSettings { it.copy(blockRewardEnabled = v) } }
            Text("默认自动查找/创建 Pomodoro 与 Pomodoro Combo!；自定义模式使用填写的 Habit ID。块奖励为独立的一次额外加分。",
                style = MaterialTheme.typography.bodySmall, color = c.muted)
            SkinTextButton("确认/初始化番茄习惯", onClick = vm::ensureDefaultHabits, enabled = !state.habiticaBusy)
            SwitchRow("短休息结束发 Habitica 私信", s.breakExtentionNotify) { v -> vm.updateSettings { it.copy(breakExtentionNotify = v) } }
            SwitchRow("长休息结束发 Habitica 私信", s.longBreakNotify) { v -> vm.updateSettings { it.copy(longBreakNotify = v) } }
        }

        // MARK: 提醒声音
        SettingsCard(title = "阶段提醒") {
            SoundSetting("番茄结束音", s.pomoEndSound, s.pomoEndSoundVolume, PomoAudio.soundOptions,
                { v -> vm.updateSettings { it.copy(pomoEndSound = v) } }, { v -> vm.updateSettings { it.copy(pomoEndSoundVolume = v) } }) { preview.effect(s.pomoEndSound, s.pomoEndSoundVolume, true) }
            SoundSetting("休息结束音", s.breakEndSound, s.breakEndSoundVolume, PomoAudio.soundOptions,
                { v -> vm.updateSettings { it.copy(breakEndSound = v) } }, { v -> vm.updateSettings { it.copy(breakEndSoundVolume = v) } }) { preview.effect(s.breakEndSound, s.breakEndSoundVolume, true) }
            // 环境音来源（与 Apple 端 ambientSource 一致）：自定义单轨 / 栖时随机场景混音
            Text("环境音来源", style = MaterialTheme.typography.bodyLarge, color = c.ink)
            val segmentColors = SegmentedButtonDefaults.colors(
                activeContainerColor = c.accentSoft, activeContentColor = c.ink, activeBorderColor = c.accent,
                inactiveContainerColor = Color.Transparent, inactiveContentColor = c.muted, inactiveBorderColor = MaterialTheme.colorScheme.outline,
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                SegmentedButton(
                    shape = segmentShape(0, skin.controlRadius),
                    selected = s.ambientSource != "qishi",
                    onClick = { vm.updateSettings { it.copy(ambientSource = "custom") } },
                    colors = segmentColors,
                ) { Text("自定义") }
                SegmentedButton(
                    shape = segmentShape(1, skin.controlRadius),
                    selected = s.ambientSource == "qishi",
                    onClick = { vm.updateSettings { it.copy(ambientSource = "qishi") } },
                    colors = segmentColors,
                ) { Text("栖时随机") }
            }
            if (s.ambientSource == "qishi") {
                Text(
                    text = "每个番茄随机播放一个栖时场景混音（共 ${vm.qishiSceneCount()} 个场景，需联网流式播放）",
                    style = MaterialTheme.typography.bodySmall,
                    color = c.muted,
                )
                VolumeSlider(s.ambientSoundVolume) { v -> vm.updateSettings { it.copy(ambientSoundVolume = v) } }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SkinTextButton("试听随机场景", onClick = {
                        vm.randomQishiPreviewScene()?.let { preset -> preview.playQishiScene(preset, s.ambientSoundVolume) }
                    })
                    SkinTextButton("停止试听", onClick = { preview.stopQishi(); vm.refreshRuntimeAudio() }, color = c.muted)
                }
            } else {
                SoundSetting("环境音", s.ambientSound, s.ambientSoundVolume, PomoAudio.ambientOptions,
                    { v -> vm.updateSettings { it.copy(ambientSound = v) } }, { v -> vm.updateSettings { it.copy(ambientSoundVolume = v) } }) { preview.previewAmbient(s.ambientSound, s.ambientSoundVolume) }
                SkinTextButton("停止预听", onClick = { preview.stopAll(); vm.refreshRuntimeAudio() }, color = c.muted)
            }
            Text("预听最多 8 秒。环境音仅专注时循环，暂停/休息/放弃会停止。系统通知是否显示受通知权限和渠道设置控制。",
                style = MaterialTheme.typography.bodySmall, color = c.muted)
        }

        // MARK: 数据
        SettingsCard(title = "数据") {
            Text(
                text = "存储位置：应用私有目录",
                style = MaterialTheme.typography.bodyMedium,
                color = c.ink,
            )
            Text(
                text = vm.dataDirectoryPath(),
                style = MaterialTheme.typography.bodySmall,
                color = c.muted,
            )
            SkinDivider()
            SectionTitle("跨端同步说明")
            Text(
                text = "Android 不访问 iCloud Drive。Habits/Dailies 从 Habitica 读取并打分；本机创建的 Task 可同步为 todo。" +
                    "Mac/iPhone 已上传且带专用日期/分类备注的 Top3 todo 会保守合并；普通 todo 不导入。本机未上传修改保留。设置、番茄/块/植物历史不跨端同步。",
                style = MaterialTheme.typography.bodySmall,
                color = c.muted,
            )
            SkinDivider()
            SectionTitle("Top3 同步队列")
            Text(
                text = "待处理创建标记：${state.store.deletedCreateMarkers.size} · 删除队列：${state.store.deletedCloudIds.size}",
                style = MaterialTheme.typography.bodySmall.tabular(),
                color = c.ink,
            )
            Text(
                text = "创建标记用于隔离结果不明的云端创建请求；历史版本遗留的孤儿标记无法自动核对时，可在确认后手动清理。" +
                    "清理不会改动你的显式删除记录（删除队列），也不影响其他账号分区。",
                style = MaterialTheme.typography.bodySmall,
                color = c.muted,
            )
            SkinTextButton("清理隔离中的创建标记", onClick = { confirmMarkerCleanup = true }, color = c.danger)
            state.persistenceError?.let { NoticeText(it) }
        }

        // MARK: 关于
        SettingsCard(title = "关于") {
            Text("Habitica Pomodoro for Android · v1.2.2", style = MaterialTheme.typography.bodyMedium, color = c.ink)
            Text(
                text = "与 macOS / iOS 版同一套业务规则：逻辑日以第一个时间块起点（默认 04:00）为界，" +
                    "Work/MyOwn 各限 3 条、Chores 自由列表，昨天未完成任务可顺延到今天。",
                style = MaterialTheme.typography.bodySmall,
                color = c.muted,
            )
        }
    }
}

@Composable
private fun SettingsCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    SkinCard(modifier = Modifier.fillMaxWidth()) {
        SectionTitle(title)
        content()
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) =
    SettingSwitchRow(label, checked, onCheckedChange)

@Composable
private fun StepperRow(
    label: String,
    value: Int,
    range: IntRange,
    suffix: String,
    onChange: (Int) -> Unit,
) = SettingStepperRow(
    label = label,
    value = "$value $suffix",
    onMinus = { if (value > range.first) onChange(value - 1) },
    onPlus = { if (value < range.last) onChange(value + 1) },
    minusEnabled = value > range.first,
    plusEnabled = value < range.last,
)

/** Two-piece segmented control corners that follow controlRadius (square in pixel). */
private fun segmentShape(index: Int, radius: androidx.compose.ui.unit.Dp) = if (index == 0) {
    RoundedCornerShape(topStart = radius, bottomStart = radius)
} else {
    RoundedCornerShape(topEnd = radius, bottomEnd = radius)
}

@Composable
private fun VolumeSlider(volume: Double, onVolume: (Double) -> Unit) {
    val c = LocalSkin.current.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            "音量 ${(volume * 100).toInt()}%",
            style = MaterialTheme.typography.labelMedium.tabular(),
            color = c.muted,
            modifier = Modifier.widthIn(min = 64.dp),
        )
        Slider(
            volume.toFloat(),
            onValueChange = { onVolume(it.toDouble()) },
            modifier = Modifier.weight(1f),
            colors = SliderDefaults.colors(thumbColor = c.accent, activeTrackColor = c.accent, inactiveTrackColor = c.subtle),
        )
    }
}

@Composable
private fun SoundSetting(label: String, value: String, volume: Double, options: List<String>, onChoice: (String) -> Unit, onVolume: (Double) -> Unit, preview: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val c = LocalSkin.current.colors
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = c.ink)
            androidx.compose.foundation.layout.Box {
                SkinTextButton(if (value in options) value else "None", onClick = { expanded = true }, color = c.ink)
                DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
                    options.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option, color = if (option == value) c.accent else c.ink) },
                            onClick = { onChoice(option); expanded = false },
                        )
                    }
                }
            }
            SkinTextButton("预听", onClick = preview, enabled = value in options && value != "None")
        }
        VolumeSlider(volume, onVolume)
    }
}
