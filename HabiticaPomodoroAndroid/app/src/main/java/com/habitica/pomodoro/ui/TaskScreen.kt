package com.habitica.pomodoro.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.habitica.pomodoro.data.isValidHabiticaUid
import com.habitica.pomodoro.engine.PomodoroViewModel
import com.habitica.pomodoro.engine.PomodoroViewModel.UiState
import com.habitica.pomodoro.ui.theme.LocalSkin
import com.habitica.pomodoro.ui.theme.NoticeText
import com.habitica.pomodoro.ui.theme.PageHeader
import com.habitica.pomodoro.ui.theme.SkinButton
import com.habitica.pomodoro.ui.theme.SkinButtonKind
import com.habitica.pomodoro.ui.theme.SkinCard
import com.habitica.pomodoro.ui.theme.SkinDivider
import com.habitica.pomodoro.ui.theme.SkinTextButton
import com.habitica.pomodoro.ui.theme.SkinTone
import com.habitica.pomodoro.ui.theme.skinCheckboxColors
import com.habitica.pomodoro.ui.theme.skinTextFieldColors
import com.habitica.pomodoro.ui.theme.tabular

/** 前 2 个分类（Work/MyOwn）上限 3 条，其余（Chores）为自由列表 */
private const val FIXED_SLOT_CATEGORIES = 2
private const val MAX_FIXED_TASKS = 3
/** Pending-upload notice; rendered muted, unlike real sync errors. */
private const val PENDING_SYNC = "本机修改待同步"

/**
 * Task 页：每日三件事 + 琐事。
 * 今天（逻辑日）可增删改与勾选；昨天只读，未完成的可用 ➡️ 移动到今天。
 */
@Composable
fun TaskScreen(
    vm: PomodoroViewModel,
    state: UiState,
    modifier: Modifier = Modifier,
) {
    val store = state.store
    val todayKey = vm.todayKey()
    val yesterdayKey = vm.yesterdayKey()
    var renamingIndex by remember { mutableStateOf<Int?>(null) }
    var renameText by remember { mutableStateOf("") }
    val skin = LocalSkin.current

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = skin.spacing.pageInset),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Spacer(Modifier.height(4.dp))
        PageHeader("Task", subtitle = "今天可编辑 · 昨天只读（未完成的可以移动到今天）") {
            SkinTextButton(if (state.topThreeSyncing) "同步中…" else "同步 Habitica", onClick = vm::refreshTopThreeFromCloud,
                enabled = !state.topThreeSyncing && state.settings.connectHabitica &&
                    isValidHabiticaUid(state.settings.uid) && state.settings.apiToken.isNotBlank(),
                icon = Icons.Filled.Sync)
        }
        if (store.history.values.any { day -> day.taskGroups.flatten().any { it.syncPending } } || store.deletedCloudIds.isNotEmpty() || store.deletedCreateMarkers.isNotEmpty()) {
            SkinCard(
                modifier = Modifier.fillMaxWidth(),
                tone = SkinTone.Subtle,
                contentPadding = PaddingValues(start = 14.dp, end = 4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.CloudUpload, contentDescription = null, tint = skin.colors.highlight, modifier = Modifier.size(18.dp))
                    Text("本机有修改尚未同步", style = MaterialTheme.typography.bodySmall, color = skin.colors.muted,
                        modifier = Modifier.weight(1f).padding(start = 10.dp))
                    SkinTextButton("重试待同步操作", onClick = vm::retryPendingTasks)
                }
            }
        }
        state.topThreeSyncError?.let { error -> NoticeText("云端同步失败（本地任务保留）：$error") }
        state.persistenceError?.let { error -> NoticeText(error) }
        Spacer(Modifier.height(skin.spacing.rowSpacing))

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(skin.spacing.rowSpacing),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp),
        ) {
            store.categoryNames.forEachIndexed { index, categoryName ->
                item(key = "header-$index-$categoryName") {
                    CategoryHeader(
                        name = categoryName,
                        index = index,
                        isRenaming = renamingIndex == index,
                        renameText = renameText,
                        todayCount = dayGroupSize(store, todayKey, index),
                        onStartRename = {
                            renamingIndex = index
                            renameText = categoryName
                        },
                        onRenameTextChanged = { renameText = it },
                        onCommitRename = {
                            vm.renameCategory(index, renameText)
                            renamingIndex = null
                        },
                        onCancelRename = { renamingIndex = null },
                    )
                }

                item(key = "today-$index") {
                    SectionLabel(text = "今天 · ${todayKey}")
                }

                val todayDay = store.history[todayKey]
                val todayTasks = todayDay?.taskGroups?.getOrNull(index).orEmpty().withIndex().filterNot { it.value.movedToToday }
                itemsIndexed(
                    items = todayTasks,
                    key = { _, entry -> "today-$index-${entry.value.id}" },
                ) { _, entry ->
                    val taskIndex = entry.index // Keep the original index after filtering archived rows.
                    val task = entry.value
                    TaskRow(
                        title = task.title,
                        completed = task.isCompleted,
                        editable = true,
                        showMoveButton = false,
                        onToggle = { vm.toggleTask(index, taskIndex) },
                        onDelete = { vm.deleteTask(index, taskIndex) },
                        onMove = { },
                        onEdit = { vm.editTask(index, taskIndex, it) },
                        syncError = task.syncError ?: if (task.syncPending) PENDING_SYNC else null,
                    )
                }

                item(key = "add-$index") {
                    AddTaskRow(
                        enabled = true,
                        hint = if (index < FIXED_SLOT_CATEGORIES) {
                            val used = todayTasks.size
                            if (used >= MAX_FIXED_TASKS) "已达上限 $MAX_FIXED_TASKS 条" else "添加任务…"
                        } else {
                            "添加琐事…"
                        },
                        atLimit = index < FIXED_SLOT_CATEGORIES && todayTasks.size >= MAX_FIXED_TASKS,
                        onAdd = { title -> vm.addTask(index, title) },
                    )
                }

                // 昨天（只读 + 未完成的可以移动到今天）
                val yesterdayDay = store.history[yesterdayKey]
                val yesterdayTasks = yesterdayDay?.taskGroups?.getOrNull(index).orEmpty()
                if (yesterdayTasks.isNotEmpty()) {
                    item(key = "yesterday-label-$index") {
                        SectionLabel(text = "昨天 · ${yesterdayDay?.date ?: yesterdayKey}", muted = true)
                    }
                    itemsIndexed(
                        items = yesterdayTasks,
                        key = { _, task -> "yst-$index-${task.id}" },
                    ) { taskIndex, task ->
                        TaskRow(
                            title = task.title,
                            completed = task.isCompleted,
                            editable = false,
                            showMoveButton = !task.isCompleted && !task.movedToToday,
                            onToggle = { },
                            onDelete = { },
                            onMove = { vm.moveTaskToToday(index, taskIndex) },
                        )
                    }
                }

                item(key = "divider-$index") {
                    SkinDivider(modifier = Modifier.padding(top = skin.spacing.rowSpacing, bottom = 4.dp))
                }
            }
            item(key = "unfinished") { UnfinishedTasksSection(vm, state) }
        }
    }
}

private fun dayGroupSize(store: com.habitica.pomodoro.data.TopThreeStore, key: String, index: Int): Int =
    store.history[key]?.taskGroups?.getOrNull(index)?.count { !it.movedToToday } ?: 0

@Composable
private fun CategoryHeader(
    name: String,
    index: Int,
    isRenaming: Boolean,
    renameText: String,
    todayCount: Int,
    onStartRename: () -> Unit,
    onRenameTextChanged: (String) -> Unit,
    onCommitRename: () -> Unit,
    onCancelRename: () -> Unit,
) {
    val skin = LocalSkin.current
    val c = skin.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = if (index == 0) 0.dp else 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (isRenaming) {
            OutlinedTextField(
                value = renameText,
                onValueChange = onRenameTextChanged,
                modifier = Modifier.weight(1f),
                singleLine = true,
                label = { Text("分类名称") },
                shape = skin.controlShape,
                colors = skinTextFieldColors(),
            )
            SkinTextButton("保存", onClick = onCommitRename)
            SkinTextButton("取消", onClick = onCancelRename, color = c.muted)
        } else {
            Text(
                text = name,
                style = MaterialTheme.typography.titleMedium,
                color = c.ink,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
            val full = index < FIXED_SLOT_CATEGORIES && todayCount >= MAX_FIXED_TASKS
            Text(
                text = if (index < FIXED_SLOT_CATEGORIES) "今天 $todayCount/$MAX_FIXED_TASKS" else "今天 $todayCount",
                style = MaterialTheme.typography.labelMedium.tabular(),
                color = if (full) c.accent else c.muted,
                modifier = Modifier
                    .clip(skin.chipShape)
                    .background(if (full) c.accentSoft else c.subtle)
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            )
            IconButton(onClick = onStartRename) {
                Icon(Icons.Filled.Edit, contentDescription = "重命名分类「$name」", modifier = Modifier.size(18.dp), tint = c.muted)
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String, muted: Boolean = false) {
    val c = LocalSkin.current.colors
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium.tabular(),
        fontWeight = FontWeight.SemiBold,
        color = if (muted) c.muted else c.accent,
        modifier = Modifier.padding(top = 2.dp),
    )
}

@Composable
private fun TaskRow(
    title: String,
    completed: Boolean,
    editable: Boolean,
    showMoveButton: Boolean,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
    onMove: () -> Unit,
    onEdit: (String) -> Unit = {},
    syncError: String? = null,
) {
    var showDeleteConfirm by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var draft by remember(title) { mutableStateOf(title) }
    val skin = LocalSkin.current
    val c = skin.colors

    SkinCard(
        modifier = Modifier.fillMaxWidth(),
        tone = if (completed) SkinTone.Accent else SkinTone.Surface,
        contentPadding = PaddingValues(start = 4.dp, end = 4.dp),
        elevated = false,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 52.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(
                checked = completed,
                onCheckedChange = { if (editable) onToggle() },
                enabled = editable,
                colors = skinCheckboxColors(),
            )
            Text(
                text = title,
                modifier = Modifier
                    .weight(1f)
                    .padding(vertical = 10.dp),
                style = MaterialTheme.typography.bodyLarge,
                textDecoration = if (completed) TextDecoration.LineThrough else null,
                color = if (completed) c.muted else c.ink,
            )
            if (showMoveButton) {
                SkinTextButton("移到今天", onClick = onMove, icon = Icons.AutoMirrored.Filled.ArrowForward)
            }
            if (editable) {
                IconButton(onClick = { editing = true }) {
                    Icon(Icons.Filled.Edit, contentDescription = "编辑任务「$title」", modifier = Modifier.size(20.dp), tint = c.muted)
                }
                IconButton(onClick = { showDeleteConfirm = true }) {
                    Icon(
                        Icons.Filled.Delete,
                        contentDescription = "删除任务「$title」",
                        modifier = Modifier.size(20.dp),
                        tint = c.danger,
                    )
                }
            } else {
                Spacer(Modifier.width(12.dp))
            }
        }
    }

    syncError?.let {
        Text(
            it,
            style = MaterialTheme.typography.labelSmall,
            color = if (it == PENDING_SYNC) c.muted else c.danger,
            modifier = Modifier.padding(start = 12.dp, top = 2.dp),
        )
    }
    if (editing) androidx.compose.material3.AlertDialog(onDismissRequest = { editing = false }, title = { Text("编辑任务标题") },
        text = { OutlinedTextField(draft, onValueChange = { draft = it }, label = { Text("任务标题") }, singleLine = true,
            shape = skin.controlShape, colors = skinTextFieldColors()) },
        confirmButton = { TextButton(onClick = { onEdit(draft); editing = false }, enabled = draft.isNotBlank()) { Text("保存") } },
        dismissButton = { TextButton(onClick = { editing = false }) { Text("取消") } })
    if (showDeleteConfirm) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("删除任务") },
            text = { Text("「$title」将被删除，同时从 Habitica 移除对应的 todo。") },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirm = false
                    onDelete()
                }) { Text("删除", color = c.danger) }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text("取消") }
            },
        )
    }
}

/** 统一的添加输入行：输入后点添加（回车由单行 TextField 的 keyboard action 处理） */
@Composable
private fun AddTaskRow(
    enabled: Boolean,
    hint: String,
    atLimit: Boolean,
    onAdd: (String) -> Unit,
) {
    var text by remember { mutableStateOf("") }
    val skin = LocalSkin.current

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            modifier = Modifier.weight(1f),
            enabled = enabled && !atLimit,
            placeholder = { Text(hint) },
            singleLine = true,
            shape = skin.controlShape,
            colors = skinTextFieldColors(),
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                imeAction = androidx.compose.ui.text.input.ImeAction.Done,
            ),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                onDone = {
                    if (text.isNotBlank()) {
                        onAdd(text)
                        text = ""
                    }
                },
            ),
        )
        Spacer(Modifier.width(8.dp))
        SkinButton(
            text = "添加",
            onClick = {
                onAdd(text)
                text = ""
            },
            enabled = enabled && !atLimit && text.isNotBlank(),
            kind = SkinButtonKind.Tonal,
            icon = Icons.Filled.Add,
            compact = true,
        )
    }
}
