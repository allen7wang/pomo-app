import SwiftUI
import Combine

// MARK: - Top Three View
struct TopThreeView: View {
    @ObservedObject var manager = TopThreeManager.shared
    @ObservedObject var settingsManager = SettingsManager.shared
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var phase = PomodoroEngine.shared.phase

    private var settings: UserSettings { settingsManager.settings }
    private var todayKey: String { manager.todayKey(settings: settings) }
    private var yesterdayKey: String { manager.yesterdayKey(settings: settings) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            themedContent
        }
        .task { await manager.synchronize(settings: settings) }
        .onReceive(PomodoroEngine.shared.$phase.removeDuplicates()) { phase = $0 }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            manager.objectWillChange.send()
        }
    }

    private var themedContent: some View {
        VStack(alignment: .leading, spacing: theme.pageSpacing) {
            ThemedPageHeader(title: "每日任务", subtitle: "把重要的事，先做好。", symbol: "checklist")

            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: theme.checkSymbol(true)).foregroundColor(theme.accent)
                    Text("今天完成 \(todayCompleted)/\(todayTasks.count)")
                        .font(theme.numberFont(size: 11))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.muted)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button {
                    Task { await manager.synchronize(settings: settings) }
                } label: {
                    Label(manager.syncInProgress ? "同步中…" : "同步 Habitica", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(QuietButtonStyle(theme: theme))
                .disabled(manager.syncInProgress || !settings.connectHabitica || settings.uid.isEmpty || settings.apiToken.isEmpty)
            }
            if let message = manager.syncMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if theme.showsColumns(compactWidth: horizontalSizeClass == .compact) {
                HStack(alignment: .top, spacing: theme.pageSpacing) {
                    daySection(key: todayKey, editable: true)
                    daySection(key: yesterdayKey, editable: false)
                }
            } else {
                daySection(key: todayKey, editable: true)
                daySection(key: yesterdayKey, editable: false)
            }
            unfinishedSection
        }
        .padding(.horizontal, theme.pageInset)
        .padding(.top, 16)
        .padding(.bottom, 22)
    }

    private var todayTasks: [TopThreeTask] {
        (0..<manager.categoryCount).flatMap { manager.getTasks(key: todayKey, category: $0) }
    }

    private var todayCompleted: Int { todayTasks.filter { $0.isCompleted }.count }

    private func daySection(key: String, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: theme.rowSpacing) {
            HStack(spacing: 7) {
                theme.dotShape
                    .fill(editable ? theme.accent : theme.muted)
                    .frame(width: 6, height: 6)
                Text(editable ? "今天" : "昨天")
                    .font(theme.sectionFont(size: 14))
                    .foregroundColor(editable ? theme.ink : theme.muted)
                    .accessibilityAddTraits(.isHeader)
                Text(shortDate(key))
                    .font(theme.numberFont(size: 11, weight: .regular))
                    .foregroundColor(theme.muted)
                Spacer(minLength: 0)
                if !editable {
                    SkinChip(text: "已归档", tint: theme.muted, fill: theme.subtle)
                }
            }
            Text(editable ? "点击任务文字编辑，点击圆圈完成" : "已完成和已转移的任务")
                .font(.system(size: 10))
                .foregroundColor(theme.muted)
                .padding(.bottom, 3)

            ForEach(0..<manager.categoryCount, id: \.self) { cat in
                TopThreeCategorySection(dateKey: key, category: cat, editable: editable, canStartFocus: phase != .pomodoro)
                    .themeCard(theme, padding: theme.cardPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var unfinishedSection: some View {
        let today = todayKey
        let tasks = manager.unfinishedTasks(before: today)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accent)
                Text("未完成任务")
                    .font(theme.sectionFont(size: 14))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text("\(tasks.count) 件")
                    .font(theme.numberFont(size: 11, weight: .regular))
                    .foregroundStyle(unfinishedHintColor)
            }
            Text(tasks.isEmpty ? "没有跨天未完成的任务。" : "可以转到今天的原分类，也可以删除。")
                .font(.caption)
                .foregroundStyle(unfinishedHintColor)

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(tasks) { item in
                    unfinishedRow(item, today: today)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(theme.ink)
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func unfinishedRow(_ item: UnfinishedTask, today: String) -> some View {
        let canMove = manager.canAddTask(key: today, category: item.category, settings: settings)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.task.title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(item.dateKey) · \(manager.categoryName(index: item.category))")
                    .font(theme.numberFont(size: 11, weight: .regular))
                    .foregroundStyle(unfinishedHintColor)
                if !canMove {
                    Text("今日分类已满")
                        .font(.caption2)
                        .foregroundStyle(unfinishedHintColor)
                }
            }
            Spacer(minLength: 0)
            Button {
                manager.moveTaskToToday(fromKey: item.dateKey, category: item.category, id: item.id, settings: settings)
            } label: {
                Image(systemName: "arrow.uturn.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(canMove ? theme.accent : theme.muted)
                    .modifier(TaskActionTarget())
            }
            .buttonStyle(SkinPlainButtonStyle(theme: theme))
            .disabled(!canMove)
            .accessibilityLabel("转到今天")
            .help("转到今天")
            TaskDeleteButton(color: unfinishedHintColor, hoverColor: theme.danger) {
                manager.removeTask(key: item.dateKey, category: item.category, id: item.id, settings: settings, fromUnfinished: true)
            }
        }
    }

    private var unfinishedHintColor: Color { theme.muted }

    private func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        return "\(parts[1])/\(parts[2])"
    }
}

// MARK: - Category Section (一个分类：Work / MyOwn / 琐事)
struct TopThreeCategorySection: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var manager = TopThreeManager.shared
    @ObservedObject var settingsManager = SettingsManager.shared

    let dateKey: String
    let category: Int
    let editable: Bool
    let canStartFocus: Bool

    @State private var editingUUID: UUID? = nil
    @State private var draftTitle: String = ""
    @State private var renamingCategory = false
    @State private var draftCategoryName: String = ""
    @State private var newTaskTitle: String = ""

    private var settings: UserSettings { settingsManager.settings }
    private var tasks: [TopThreeTask] {
        let all = manager.getTasks(key: dateKey, category: category)
        return editable ? all : all.filter { !$0.isUnfinished }
    }
    private var completedCount: Int { tasks.filter { $0.isCompleted }.count }
    private var isFreeList: Bool { manager.isFreeList(category: category) }

    private var categoryColor: Color { theme.accent }

    private var mutedColor: Color { theme.muted }

    private var completionColor: Color { theme.accent }

    private var hintColor: Color { theme.muted.opacity(0.8) }

    private var sectionSpacing: CGFloat { theme.rowSpacing }

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            // 分类标题行（今天可点击重命名）
            HStack(spacing: 6) {
                if renamingCategory {
                    TextField("分类名", text: $draftCategoryName, onCommit: {
                        manager.setCategoryName(index: category, name: draftCategoryName.isEmpty ? manager.categoryName(index: category) : draftCategoryName, settings: settings)
                        renamingCategory = false
                    })
                    .modifier(TaskInputStyle())
                    .font(.caption.bold())
                    .frame(width: 120)
                    .cancelOnExitCommand { renamingCategory = false }
                } else {
                    HStack(spacing: 4) {
                        Text(manager.categoryName(index: category))
                            .font(theme.sectionFont(size: 13))
                            .foregroundColor(categoryColor)
                        if editable {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundColor(hintColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard editable else { return }
                        draftCategoryName = manager.categoryName(index: category)
                        renamingCategory = true
                    }

                    Text("\(completedCount)/\(tasks.count)")
                        .font(theme.numberFont(size: 11))
                        .foregroundColor(!tasks.isEmpty && completedCount == tasks.count ? completionColor : mutedColor)
                }
                Spacer()
            }
            .padding(.leading, 2)

            if tasks.isEmpty && !editable {
                Text("没有归档任务")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
                    .padding(.vertical, 8)
            }

            // 任务列表
            ForEach(tasks) { task in
                TaskRow(
                    task: task,
                    editable: editable,
                    isEditing: editable && editingUUID == task.id,
                    draftTitle: $draftTitle,
                    onToggle: {
                        manager.toggleTask(key: dateKey, category: category, id: task.id, settings: settings)
                    },
                    onStartEdit: {
                        guard editable, manager.isEditable(key: dateKey, settings: settings),
                              tasks.contains(where: { $0.id == task.id && !$0.movedToToday }) else { return }
                        editingUUID = task.id
                        draftTitle = task.title
                    },
                    onCommitEdit: {
                        guard editable, editingUUID == task.id else { return }
                        manager.setTaskTitle(key: dateKey, category: category, id: task.id, title: draftTitle, settings: settings)
                        editingUUID = nil
                    },
                    onCancelEdit: { editingUUID = nil },
                    onFocus: editable && task.isUnfinished ? {
                        if PomodoroEngine.shared.startPomodoro(taskId: task.id, category: category, dateKey: dateKey) {
                            AppTabState.shared.selectedTab = 0
                        }
                    } : nil,
                    canStartFocus: canStartFocus,
                    onDelete: editable ? {
                        manager.removeTask(key: dateKey, category: category, id: task.id, settings: settings)
                    } : nil
                )
            }

            // 统一添加输入行（所有分类一致；有上限的分类满 3 条后隐藏）
            if manager.canAddTask(key: dateKey, category: category, settings: settings) {
                HStack(spacing: 8) {
                    Image(systemName: theme.squareCorners ? "plus.square" : "plus.circle")
                        .foregroundColor(categoryColor)
                        .font(.system(size: 15))
                        .accessibilityHidden(true)
                    TextField(placeholder, text: $newTaskTitle, onCommit: {
                        manager.addTask(key: dateKey, category: category, title: newTaskTitle, settings: settings)
                        newTaskTitle = ""
                    })
                    .modifier(TaskInputStyle())
                    .font(.callout)
                }
                .padding(.vertical, 1)
                .padding(.leading, 8)
            } else if editable && manager.taskLimit(category: category) != nil {
                // 固定分类已满 3 条
                Text("已满 3 件，删除后可再添加")
                    .font(.caption2)
                    .foregroundColor(hintColor)
                    .padding(.leading, 8)
                    .padding(.vertical, 1)
            }
        }
        .onChange(of: tasks.filter { !$0.movedToToday }.map(\.id)) { ids in
            if let id = editingUUID, !ids.contains(id) { cancelEditing() }
        }
        .onChange(of: dateKey) { _ in cancelEditing() }
        .onChange(of: category) { _ in cancelEditing() }
        .onChange(of: editable) { value in if !value { cancelEditing() } }
        .onDisappear { cancelEditing() }
    }

    private func cancelEditing() {
        editingUUID = nil
        draftTitle = ""
    }

    private var placeholder: String {
        if let limit = manager.taskLimit(category: category) {
            return "添加任务（最多 \(limit) 件），回车确认..."
        }
        return "添加任务，回车确认..."
    }
}

// MARK: - Task Row (单条任务)
struct TaskRow: View {
    @Environment(\.appTheme) private var theme
    let task: TopThreeTask
    let editable: Bool
    let isEditing: Bool
    @Binding var draftTitle: String
    let onToggle: () -> Void
    let onStartEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onFocus: (() -> Void)?
    let canStartFocus: Bool
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if editable {
                Button(action: onToggle) {
                    Image(systemName: theme.checkSymbol(task.isCompleted))
                        .foregroundColor(task.isCompleted ? completionColor : mutedColor)
                        .font(.system(size: 15))
                        .modifier(TaskActionTarget())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(task.isCompleted ? "取消完成" : "完成")
            } else {
                Image(systemName: task.isCompleted ? theme.checkSymbol(true) : (task.movedToToday ? "arrow.right.circle.fill" : theme.checkSymbol(false)))
                    .foregroundColor(task.isCompleted ? completionColor : (task.movedToToday ? movedColor : mutedColor))
                    .font(.system(size: 15))
                    .opacity(0.55)
            }

            if isEditing {
                TextField("输入任务...", text: $draftTitle, onCommit: onCommitEdit)
                    .modifier(TaskInputStyle())
                    .font(.callout)
                    .cancelOnExitCommand { onCancelEdit() }
            } else {
                Text(displayTitle)
                    .font(.callout)
                    .foregroundColor(titleColor)
                    .strikethrough(task.isCompleted, color: mutedColor)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard editable else { return }
                        onStartEdit()
                    }
                Spacer(minLength: 0)
            }

            // 已移动标记
            if task.movedToToday {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(movedColor.opacity(0.7))
                    .help("已移动到今日")
            }

            if let onFocus, !isEditing {
                Button(action: onFocus) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(canStartFocus ? theme.accent : theme.muted)
                        .modifier(TaskActionTarget())
                }
                .buttonStyle(.borderless)
                .disabled(!canStartFocus)
                .help(canStartFocus ? "为这项任务开始番茄" : "请先结束当前番茄")
                .accessibilityLabel("专注「\(task.title)」")
                .accessibilityIdentifier("start-task-focus")
            }

            // 删除按钮
            if let onDelete = onDelete {
                TaskDeleteButton(color: mutedColor, hoverColor: theme.danger, onDelete: onDelete)
            }
        }
        .padding(.vertical, rowPadding)
        .padding(.leading, 8)
        .opacity(task.movedToToday ? 0.55 : 1)
    }

    private var displayTitle: String {
        if task.title.isEmpty {
            return editable ? "点击添加..." : "—"
        }
        return task.title
    }

    private var titleColor: Color {
        if task.title.isEmpty || task.isCompleted || !editable { return theme.muted }
        return theme.ink
    }

    private var mutedColor: Color { theme.muted }

    private var completionColor: Color { theme.accent }

    private var movedColor: Color { theme.accent }

    private var rowPadding: CGFloat { theme.layout == .airy ? 4 : 2 }
}

private struct TaskDeleteButton: View {
    let color: Color
    var hoverColor: Color? = nil
    let onDelete: () -> Void
    @State private var showConfirm = false
    @State private var hovering = false

    var body: some View {
        Button { showConfirm = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(hovering ? (hoverColor ?? color) : color.opacity(0.7))
                .modifier(TaskActionTarget())
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .accessibilityLabel("删除任务")
        .help("删除任务")
        .confirmationDialog("确定删除这条任务？", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        }
    }
}

private struct TaskInputStyle: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundColor(theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(theme.smallShape().fill(theme.subtle))
            .overlay(theme.smallShape().strokeBorder(theme.controlStroke, lineWidth: theme.controlStrokeWidth))
            .tint(theme.accent)
    }
}

private struct TaskActionTarget: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 24, minHeight: 26).contentShape(Rectangle())
        #else
        content.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #endif
    }
}
