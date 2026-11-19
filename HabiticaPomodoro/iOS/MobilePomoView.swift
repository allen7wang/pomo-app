import SwiftUI

// MARK: - Mobile Pomo View (与 Mac 同一套皮肤，竖屏重排)

struct MobilePomoView: View {
    @ObservedObject var engine = PomodoroEngine.shared
    @ObservedObject var blockManager = BlockProgressManager.shared
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject private var topThree = TopThreeManager.shared
    @ObservedObject private var api = HabiticaAPI.shared
    @ObservedObject private var tabState = AppTabState.shared
    @Environment(\.appTheme) private var theme

    @State private var refreshingHabitica = false
    @State private var confirmAbandon = false
    @State private var previewHistory = false
    @State private var previewBlock: Int?

    private var settings: UserSettings { settingsManager.settings }

    var body: some View {
        ScrollView(showsIndicators: false) {
            Group {
                switch theme.style {
                case .mint: mintFocus
                case .garden: gardenFocus
                case .studio: studioFocus
                }
            }
            .padding(.horizontal, theme.pageInset)
            .padding(.top, theme.style == .garden ? 12 : 6)
            .padding(.bottom, 28)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SkinPaletteButton() }
        }
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .confirmationDialog("放弃当前番茄？未完成不计数，并中断组合。时间块中的植物将记为枯萎。",
                            isPresented: $confirmAbandon, titleVisibility: .visible) {
            Button("放弃番茄", role: .destructive) { engine.pomodoroInterrupted(breakStreak: true) }
        }
        .onAppear {
            blockManager.updateBlockIndexFromTime(settings: settings)
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-previewHistory") { previewHistory = true }
            if let i = args.firstIndex(of: "-previewBlock"), i + 1 < args.count,
               let block = Int(args[i + 1]), block >= 0, block < settings.blockCount {
                previewBlock = block
            }
            #endif
        }
        .navigationDestination(isPresented: $previewHistory) { MobileHistoryView() }
        .sheet(isPresented: Binding(get: { previewBlock != nil }, set: { if !$0 { previewBlock = nil } })) {
            if let index = previewBlock { NavigationStack { MobileBlockEditorView(blockIndex: index) } }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            blockManager.updateBlockIndexFromTime(settings: settings)
            engine.loadTodayCount()
        }
    }

    // MARK: Layouts

    private var mintFocus: some View {
        VStack(alignment: .leading, spacing: theme.pageSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("你的专注")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.9)
                        .foregroundColor(theme.muted)
                    Text("把重要的事，先做好。")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(theme.ink)
                }
                Spacer(minLength: 0)
                phaseChip
            }
            focusCore(ringSize: 210)
            statsLine
            supportingCards
        }
    }

    private var gardenFocus: some View {
        VStack(spacing: theme.pageSpacing) {
            VStack(spacing: 5) {
                Text("留一刻，给自己。")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundColor(theme.ink)
                Text(dateLine)
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            phaseChip
            RingTimer(progress: engine.phaseProgress, text: timerDisplay, caption: timerCaption, theme: theme, size: 236)
                .frame(maxWidth: .infinity)
                .onTapGesture { engine.togglePomodoro() }
            controlsRow
            Text("今天已完成 \(engine.todayPomodoros) 次专注")
                .font(.system(size: 11))
                .foregroundColor(theme.muted)
            supportingCards
        }
    }

    private var studioFocus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                RingTimer(progress: engine.phaseProgress, text: timerDisplay, caption: phaseLabel, theme: theme, size: 148)
                    .onTapGesture { engine.togglePomodoro() }
                VStack(alignment: .leading, spacing: 6) {
                    phaseChip
                    Text("今天 \(engine.todayPomodoros) 次 · \(engine.todayPomodoros * settings.pomoDurationMins) 分钟")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("第 \(engine.pomoSetCounter + 1) / \(settings.pomoSetNum) 个")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            controlsRow
            tasksCard
            blockSection
            soundRow
            habiticaStrip
            historyLink
        }
    }

    private var supportingCards: some View {
        VStack(alignment: .leading, spacing: theme.pageSpacing) {
            blockSection
            tasksCard
            soundRow
            habiticaStrip
            historyLink
        }
    }

    // MARK: Focus pieces

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: Date())
    }

    private var timerDisplay: String {
        if engine.phase == .idle && engine.timerString == "00:00" {
            return String(format: "%02d:00", settings.pomoDurationMins)
        }
        return engine.timerString
    }

    private var timerCaption: String {
        if engine.isFrozen { return "已暂停 · 随时继续" }
        switch engine.phase {
        case .pomodoro: return "专注中 · 让时间慢慢发生"
        case .breakTime, .breakExtension, .manualBreak: return "休息中 · 放松一下"
        default: return "准备开始第 \(engine.pomoSetCounter + 1) 次专注"
        }
    }

    private var phaseLabel: String {
        switch engine.phase {
        case .pomodoro: return engine.isRunning ? "专注" : "专注已暂停"
        case .breakTime, .breakExtension, .manualBreak: return "休息"
        default: return "专注"
        }
    }

    private var phaseChip: some View {
        Menu {
            Button(engine.isRunning ? "暂停" : "开始 / 继续") { engine.togglePomodoro() }
            Divider()
            ForEach([1, 5, 15, 30], id: \.self) { minutes in
                Button("休息 \(minutes) 分钟") { engine.takeBreak(duration: minutes) }
            }
            .disabled(engine.phase != .idle || engine.isRunning || engine.isFrozen)
        } label: {
            HStack(spacing: 5) {
                Circle().fill(theme.accent).frame(width: 5, height: 5)
                Text(phaseLabel).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundColor(theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(theme.accentSoft))
        }
    }

    private func focusCore(ringSize: CGFloat) -> some View {
        VStack(spacing: 12) {
            RingTimer(progress: engine.phaseProgress, text: timerDisplay, caption: timerCaption, theme: theme, size: ringSize)
                .frame(maxWidth: .infinity)
                .onTapGesture { engine.togglePomodoro() }
            controlsRow
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button { engine.togglePomodoro() } label: {
                Label(primaryTitle, systemImage: primarySymbol)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(MobilePrimaryActionStyle(theme: theme))

            Button(action: resetTapped) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(MobileQuietButtonStyle(theme: theme))
            .accessibilityLabel(engine.phase == .pomodoro ? "放弃本次番茄" : "结束当前阶段")

            if engine.phase == .pomodoro {
                Button { engine.skipToBreak() } label: {
                    Image(systemName: "forward.end")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(MobileQuietButtonStyle(theme: theme))
                .accessibilityLabel("跳到休息")
            }
        }
    }

    private var primaryTitle: String {
        if engine.isFrozen { return "继续专注" }
        if engine.isRunning && engine.phase == .pomodoro { return "暂停专注" }
        if engine.isRunning && (engine.phase == .breakTime || engine.phase == .breakExtension || engine.phase == .manualBreak) {
            return "暂停休息"
        }
        return "开始专注"
    }

    private var primarySymbol: String {
        (engine.isRunning && !engine.isFrozen) ? "pause.fill" : "play.fill"
    }

    private func resetTapped() {
        if engine.phase == .pomodoro {
            confirmAbandon = true
        } else {
            engine.reset()
        }
    }

    private var statsLine: some View {
        HStack(spacing: 8) {
            Label("\(engine.todayPomodoros) 次", systemImage: "checkmark.circle")
            Text("·").foregroundColor(theme.line)
            Text("\(engine.todayPomodoros * settings.pomoDurationMins) 分钟")
            Text("·").foregroundColor(theme.line)
            Text("第 \(engine.pomoSetCounter + 1) / \(settings.pomoSetNum) 个")
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundColor(theme.muted)
    }

    @ViewBuilder private var habiticaStrip: some View {
        if settings.connectHabitica {
            HStack(spacing: 12) {
                Label(String(format: "%.1f", engine.habiticaMonies), systemImage: "circle.fill")
                Label(String(format: "%.0f", engine.habiticaExp), systemImage: "star.fill")
                Label(String(format: "%.0f", engine.habiticaHp), systemImage: "heart.fill")
                Spacer(minLength: 0)
                Button {
                    refreshingHabitica = true
                    Task { @MainActor in
                        await engine.refreshHabitica()
                        refreshingHabitica = false
                    }
                } label: {
                    if refreshingHabitica {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .disabled(refreshingHabitica)
            }
            .font(.system(size: 12))
            .foregroundColor(theme.muted)
            if let error = api.lastError {
                Text(error).font(.caption).foregroundColor(.orange)
            }
        }
    }

    // MARK: Cards

    private struct FocusTaskRow: Identifiable {
        let id: UUID
        let title: String
        let category: String
        let isCompleted: Bool
    }

    private var todaysFocusTasks: [FocusTaskRow] {
        let key = topThree.todayKey(settings: settings)
        guard let day = topThree.store.history[key] else { return [] }
        var rows: [FocusTaskRow] = []
        for (index, group) in day.taskGroups.enumerated() {
            for task in group where !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(FocusTaskRow(id: task.id, title: task.title,
                                         category: topThree.categoryName(index: index),
                                         isCompleted: task.isCompleted))
            }
        }
        return Array(rows.prefix(4))
    }

    @ViewBuilder private var blockSection: some View {
        if settings.enableBlockMode {
            VStack(alignment: .leading, spacing: theme.pageSpacing) {
                blockCard
                MobileBlockTimelineView()
                MobileBlockProgressView()
            }
        }
    }

    private var blockCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("当前时间块")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.ink)
            let index = min(max(0, blockManager.blockProgress.currentBlockIndex), max(0, settings.blockCount - 1))
            let pair = blockManager.getCurrentBlockCompletion(settings: settings)
            HStack(spacing: 11) {
                Text("B\(index + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentSoft))
                VStack(alignment: .leading, spacing: 3) {
                    Text(blockGoal(index) ?? "第 \(index + 1) 个时间块")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.ink)
                        .lineLimit(1)
                    Text(blockTimeText(index) ?? "未设置时间范围")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 0)
                Text("\(pair.completed) / \(pair.total)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.muted)
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func blockGoal(_ index: Int) -> String? {
        guard settings.blockGoals.indices.contains(index) else { return nil }
        let value = settings.blockGoals[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func blockTimeText(_ index: Int) -> String? {
        guard settings.blockTimeRanges.indices.contains(index) else { return nil }
        let range = settings.blockTimeRanges[index]
        return String(format: "%02d:%02d – %02d:%02d", range.startHour, range.startMinute, range.endHour, range.endMinute)
    }

    private var tasksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日要事")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.ink)
                Spacer(minLength: 0)
                Button("全部任务") { tabState.selectedTab = 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            }
            if todaysFocusTasks.isEmpty {
                Text("还没有添加今天最重要的三件事。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            } else {
                ForEach(todaysFocusTasks) { row in
                    Button { tabState.selectedTab = 1 } label: {
                        HStack(spacing: 8) {
                            Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14))
                                .foregroundColor(row.isCompleted ? theme.accent : theme.line)
                            Text(row.title)
                                .font(.system(size: 13))
                                .foregroundColor(row.isCompleted ? theme.muted : theme.ink)
                                .strikethrough(row.isCompleted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(row.category)
                                .font(.system(size: 10))
                                .foregroundColor(theme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    private var soundRow: some View {
        Button { tabState.selectedTab = 9 } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundColor(theme.accent)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.subtle))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ambientLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.ink)
                    Text("跟随专注 · 在设置中更换")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ambientLabel: String {
        if settings.ambientSource == "qishi" { return "栖时 · 随机场景" }
        let name = settings.ambientSound.replacingOccurrences(of: ".mp3", with: "")
        return name.isEmpty ? "无背景音" : "自定义 · \(name)"
    }

    private var historyLink: some View {
        NavigationLink {
            MobileHistoryView()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundColor(theme.accent)
                Text("专注统计与历史")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct MobilePrimaryActionStyle: ButtonStyle {
    let theme: AppTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.accent.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

private struct MobileQuietButtonStyle: ButtonStyle {
    let theme: AppTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(theme.ink)
            .frame(minWidth: 48, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? theme.subtle : theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1)
            )
    }
}

// MARK: - Mobile Block Progress (时间块进度，紧凑列表)

struct MobileBlockProgressView: View {
    @ObservedObject var blockManager = BlockProgressManager.shared
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject var plantJournal = PlantJournal.shared
    @Environment(\.appTheme) private var theme
    @State private var selectedBlock: Int?

    private var settings: UserSettings { settingsManager.settings }

    var body: some View {
        let progress = blockManager.getTodayBlockProgress(settings: settings)
        let currentIdx = blockManager.blockProgress.currentBlockIndex

        return VStack(alignment: .leading, spacing: 8) {
            Text("时间块")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.ink)

            ForEach(0..<settings.blockCount, id: \.self) { i in
                let isCurrent = (i == currentIdx)
                Button { selectedBlock = i } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("B\(i + 1)")
                                .font(.caption.monospaced())
                                .frame(width: 28, alignment: .leading)
                                .foregroundColor(isCurrent ? theme.onAccent : theme.muted)
                            Text(timeRange(i))
                                .font(.caption2.monospaced())
                                .foregroundColor(isCurrent ? theme.onAccent.opacity(0.85) : theme.muted)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(isCurrent ? theme.onAccent : theme.muted)
                        }
                        Text(goal(i).isEmpty ? "未设置目标" : goal(i))
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundColor(isCurrent ? theme.onAccent : theme.ink)
                        plantRow(i, progress: progress, isCurrent: isCurrent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isCurrent ? theme.accent : theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isCurrent ? theme.accent : theme.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: Binding(get: { selectedBlock != nil }, set: { if !$0 { selectedBlock = nil } })) {
            if let index = selectedBlock {
                NavigationStack { MobileBlockEditorView(blockIndex: index) }
            }
        }
    }

    private func plantRow(_ i: Int, progress: [Int], isCurrent: Bool) -> some View {
        let stroke = isCurrent ? theme.onAccent.opacity(0.7) : theme.muted.opacity(0.45)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let attempts = plantJournal.plants(blockIndex: i, completed: pomoCount(progress, i))
                let visible = Array(attempts.suffix(settings.blockPomoCount))
                ForEach(0..<settings.blockPomoCount, id: \.self) { d in
                    if d < visible.count {
                        Text(visible[d] == .shrub ? "🌿" : "🥀")
                            .accessibilityLabel(visible[d] == .shrub ? "灌木" : "枯萎")
                    } else {
                        Circle().strokeBorder(stroke, lineWidth: 1)
                            .frame(width: 7, height: 7)
                            .frame(width: 14, height: 16)
                            .accessibilityLabel("空种植位")
                    }
                }
                Rectangle().fill(stroke).frame(width: 1, height: 12)
                let trees = plantJournal.treeCount(blockIndex: i)
                if trees > 0 {
                    Text("🌳" + (trees > 1 ? "×\(trees)" : ""))
                        .accessibilityLabel("种树 \(trees) 棵")
                } else {
                    Circle().strokeBorder(stroke, lineWidth: 1)
                        .frame(width: 7, height: 7).frame(width: 14, height: 16)
                        .accessibilityLabel("空 combo 位")
                }
            }
            .font(.system(size: 11))
        }
    }

    private func pomoCount(_ progress: [Int], _ i: Int) -> Int {
        i < progress.count ? progress[i] : 0
    }

    private func timeRange(_ i: Int) -> String {
        guard i < settings.blockTimeRanges.count else { return "" }
        return settings.blockTimeRanges[i].displayString
    }

    private func goal(_ i: Int) -> String {
        guard i < settings.blockGoals.count else { return "" }
        return settings.blockGoals[i]
    }
}
