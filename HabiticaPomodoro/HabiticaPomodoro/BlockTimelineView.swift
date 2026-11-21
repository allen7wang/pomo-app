import SwiftUI
import Combine

// MARK: - Notification names
extension Notification.Name {
    static let scrollToCurrentBlock = Notification.Name("scrollToCurrentBlock")
}

// MARK: - Block Timeline View (可视化时间轴)
struct BlockTimelineView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var draggedBlock: Int?
    @State private var selectedBlockIndex: Int = 0
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Block Timeline")
                    .font(theme.sectionFont(size: 13))
                    .foregroundColor(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                
                Spacer()
                
                // Scroll to current block button
                Button(action: {
                    NotificationCenter.default.post(name: .scrollToCurrentBlock, object: nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill").foregroundColor(theme.accent)
                        Text("Current")
                    }
                }
                .buttonStyle(QuietButtonStyle(theme: theme, height: 26, fontSize: 11))
            }
            
            // Horizontal timeline
            ScrollViewReader { proxy in
                ScrollView([.horizontal], showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<settingsManager.settings.blockCount, id: \.self) { blockIndex in
                            BlockCardView(
                                blockIndex: blockIndex,
                                isDragging: draggedBlock == blockIndex,
                                onDrag: { draggedBlock = blockIndex },
                                onDrop: { newIndex in reorderBlocks(from: blockIndex, to: newIndex) },
                                onTap: { selectedBlockIndex = blockIndex; showTaskEditorWindow(blockIndex: blockIndex) }
                            )
                            .id("block_\(blockIndex)")
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .frame(height: 186)
                .onAppear {
                    // Initial scroll to current block
                    let currentBlockIdx = BlockProgressManager.shared.blockProgress.currentBlockIndex
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("block_\(currentBlockIdx)", anchor: .center)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .scrollToCurrentBlock)) { _ in
                    let currentBlockIdx = BlockProgressManager.shared.blockProgress.currentBlockIndex
                    proxy.scrollTo("block_\(currentBlockIdx)", anchor: .center)
                }
            }
        }
    }
    
    private func showTaskEditorWindow(blockIndex: Int) {
        let contentView = BlockTaskEditorView(blockIndex: blockIndex).appSkin()
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Block \(blockIndex + 1) Tasks"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 550, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    private func reorderBlocks(from: Int, to: Int) {
        var ranges = settingsManager.settings.blockTimeRanges
        var goals = settingsManager.settings.blockGoals
        var tasks = settingsManager.settings.blockTasks
        
        // Reorder each array
        let movedRange = ranges.remove(at: from)
        ranges.insert(movedRange, at: to)
        
        let movedGoal = goals.remove(at: from)
        goals.insert(movedGoal, at: to)
        
        while tasks.count <= max(from, to) {
            tasks.append([])
        }
        let movedTasks = tasks.remove(at: from)
        tasks.insert(movedTasks, at: to)
        
        settingsManager.settings.blockTimeRanges = ranges
        settingsManager.settings.blockGoals = goals
        settingsManager.settings.blockTasks = tasks
    }
}

// MARK: - Block Card View (单个块卡片)
struct BlockCardView: View {
    let blockIndex: Int
    let isDragging: Bool
    let onDrag: () -> Void
    let onDrop: (Int) -> Void
    let onTap: () -> Void
    
    @Environment(\.appTheme) private var theme
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject var blockManager = BlockProgressManager.shared
    @State private var hovering = false
    
    var body: some View {
        let timeRange = blockIndex < settingsManager.settings.blockTimeRanges.count 
            ? settingsManager.settings.blockTimeRanges[blockIndex] 
            : nil
        let goal = blockIndex < settingsManager.settings.blockGoals.count 
            ? settingsManager.settings.blockGoals[blockIndex] 
            : ""
        let tasks = blockIndex < settingsManager.settings.blockTasks.count 
            ? settingsManager.settings.blockTasks[blockIndex] 
            : []
        let progress = blockManager.getTodayBlockProgress(settings: settingsManager.settings)
        let completed = blockIndex < progress.count ? progress[blockIndex] : 0
        let total = settingsManager.settings.blockPomoCount
        let isCurrent = blockManager.blockProgress.currentBlockIndex == blockIndex
        // Current block inverts to the accent; every label then reads in onAccent.
        let ink = isCurrent ? theme.onAccent : theme.ink
        let muted = isCurrent ? theme.onAccent.opacity(0.8) : theme.muted
        
        return VStack(alignment: .leading, spacing: 7) {
            // Block header
            HStack(spacing: 6) {
                Text("B\(blockIndex + 1)")
                    .font(theme.numberFont(size: 12, weight: .semibold))
                    .foregroundColor(ink)
                
                if let range = timeRange {
                    Text(range.displayString)
                        .font(theme.numberFont(size: 10, weight: .regular))
                        .foregroundColor(muted)
                }
                Spacer(minLength: 0)
            }
            
            // Progress bar
            HStack(spacing: 6) {
                SkinProgressBar(value: Double(completed), total: Double(max(total, 1)),
                                tint: isCurrent ? theme.onAccent : theme.accent)
                Text("\(completed)/\(total)")
                    .font(theme.numberFont(size: 10))
                    .foregroundColor(completed >= total ? ink : muted)
            }
            
            // Goal
            if !goal.isEmpty {
                Text(goal)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            // Tasks list (show first 2 tasks, or all if few)
            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(tasks.prefix(2)), id: \.id) { task in
                        HStack(spacing: 4) {
                            Image(systemName: theme.checkSymbol(task.isCompleted))
                                .font(.system(size: 8))
                                .foregroundColor(task.isCompleted ? (isCurrent ? theme.onAccent : theme.accent) : muted)
                            Text(task.title)
                                .font(.system(size: 10))
                                .foregroundColor(ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    
                    if tasks.count > 2 {
                        Text("+\(tasks.count - 2) more")
                            .font(.system(size: 10))
                            .foregroundColor(muted)
                    }
                }
            }
            
            Spacer(minLength: 0)

            // Tasks count
            if !tasks.isEmpty {
                Text("\(tasks.filter { $0.isCompleted }.count)/\(tasks.count)")
                    .font(theme.numberFont(size: 10, weight: .regular))
                    .foregroundColor(muted)
            }
        }
        .padding(10)
        .frame(width: 130, height: 170, alignment: .topLeading)
        .background(
            SkinSurface(theme: theme, fill: isCurrent ? theme.accent : theme.surface,
                        radius: min(theme.cardRadius, 14),
                        stroke: isCurrent ? (theme.squareCorners ? theme.ink : nil) : (theme.cardStroke ?? theme.line),
                        strokeWidth: max(1, theme.borderWidth))
        )
        .overlay(theme.cardShape.fill(theme.ink.opacity(hovering && !isCurrent ? 0.03 : 0)).allowsHitTesting(false))
        .scaleEffect(isDragging ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .onDrag {
            onDrag()
            return NSItemProvider(object: "block_\(blockIndex)" as NSString)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .help("编辑 B\(blockIndex + 1) 的任务")
    }
}

// MARK: - Block Task Editor View (块任务编辑器)
struct BlockTaskEditorView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var settingsManager = SettingsManager.shared
    let blockIndex: Int
    
    @State private var newTaskTitle: String = ""
    @State private var newTaskPomo: Int = 1
    @State private var taskToDelete: UUID?
    
    var body: some View {
        let tasks = blockIndex < settingsManager.settings.blockTasks.count 
            ? settingsManager.settings.blockTasks[blockIndex] 
            : []
        
        return VStack(spacing: 16) {
            // Header with goal
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Block \(blockIndex + 1)")
                        .font(theme.titleFont(size: 17))
                        .foregroundColor(theme.ink)
                    
                    TextField("Block Goal", text: Binding(
                        get: { blockIndex < settingsManager.settings.blockGoals.count ? settingsManager.settings.blockGoals[blockIndex] : "" },
                        set: { newValue in
                            while settingsManager.settings.blockGoals.count <= blockIndex {
                                settingsManager.settings.blockGoals.append("")
                            }
                            settingsManager.settings.blockGoals[blockIndex] = newValue
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                }
                
                Spacer()
                
                Button("Done") {
                    if let window = NSApp.keyWindow {
                        window.close()
                    }
                }
                .buttonStyle(QuietButtonStyle(theme: theme, height: 28))
            }
            
            Rectangle().fill(theme.line).frame(height: 1)
            
            // Tasks list
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tasks")
                        .font(theme.sectionFont(size: 13))
                        .foregroundColor(theme.ink)
                    Spacer()
                    if !tasks.isEmpty {
                        Text("\(tasks.filter { $0.isCompleted }.count)/\(tasks.count) completed")
                            .font(theme.numberFont(size: 11, weight: .regular))
                            .foregroundColor(theme.muted)
                    }
                }
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tasks) { task in
                            HStack(spacing: 8) {
                                Button(action: {
                                    toggleTask(task: task)
                                }) {
                                    Image(systemName: theme.checkSymbol(task.isCompleted))
                                        .font(.title3)
                                        .foregroundColor(task.isCompleted ? theme.accent : theme.muted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(task.isCompleted ? "取消完成" : "完成")
                                
                                TextField("Task title", text: taskBinding(task.id, \.title, fallback: task.title))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body)
                                    .strikethrough(task.isCompleted)
                                    .foregroundColor(task.isCompleted ? theme.muted : theme.ink)
                                
                                Spacer()
                                
                                Stepper("\(task.estimatedPomo)p", value: taskBinding(task.id, \.estimatedPomo, fallback: 1), in: 1...12)
                                    .font(.caption)
                                    .fixedSize()
                                
                                Button(action: {
                                    taskToDelete = task.id
                                }) {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundColor(theme.danger)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除任务")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
            .themeCard(theme, padding: theme.cardPadding)
            
            // Add new task
            VStack(alignment: .leading, spacing: 4) {
                Text("Add New Task")
                    .font(theme.sectionFont(size: 13))
                    .foregroundColor(theme.ink)
                
                HStack(spacing: 8) {
                    TextField("Task title", text: $newTaskTitle)
                        .textFieldStyle(.roundedBorder)
                    
                    Stepper("\(newTaskPomo)p", value: $newTaskPomo, in: 1...12)
                    
                    Button(action: addTask) {
                        Image(systemName: theme.squareCorners ? "plus.square.fill" : "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加任务")
                }
            }
            .themeCard(theme, padding: theme.cardPadding)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 600)
        .background(theme.pageBackground)
        .confirmationDialog("删除这条块任务？", isPresented: Binding(
            get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let id = taskToDelete, settingsManager.settings.blockTasks.indices.contains(blockIndex) {
                    settingsManager.settings.blockTasks[blockIndex].removeAll { $0.id == id }
                }
                taskToDelete = nil
            }
            Button("取消", role: .cancel) { taskToDelete = nil }
        }
    }
    
    private func addTask() {
        guard !newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        let task = BlockTask(title: newTaskTitle, isCompleted: false, estimatedPomo: newTaskPomo)
        
        while settingsManager.settings.blockTasks.count <= blockIndex {
            settingsManager.settings.blockTasks.append([])
        }
        settingsManager.settings.blockTasks[blockIndex].append(task)
        
        newTaskTitle = ""
        newTaskPomo = 1
    }
    
    private func toggleTask(task: BlockTask) {
        guard let index = settingsManager.settings.blockTasks[blockIndex].firstIndex(where: { $0.id == task.id }) else { return }
        settingsManager.settings.blockTasks[blockIndex][index].isCompleted.toggle()
    }
    
    private func taskBinding<Value>(_ id: UUID, _ key: WritableKeyPath<BlockTask, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
            guard settingsManager.settings.blockTasks.indices.contains(blockIndex) else { return fallback }
            return settingsManager.settings.blockTasks[blockIndex].first(where: { $0.id == id })?[keyPath: key] ?? fallback
        }, set: { value in
            guard settingsManager.settings.blockTasks.indices.contains(blockIndex),
                  let index = settingsManager.settings.blockTasks[blockIndex].firstIndex(where: { $0.id == id }) else { return }
            settingsManager.settings.blockTasks[blockIndex][index][keyPath: key] = value
        })
    }
}