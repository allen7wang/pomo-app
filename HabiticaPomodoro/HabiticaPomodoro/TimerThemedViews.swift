import SwiftUI

// MARK: - Skin-driven Mac layouts (compact / airy / columns; each skin picks one)

extension TimerView {

    var theme: AppTheme { AppTheme(style: styleStore.style, dark: colorScheme == .dark) }

    var sideSettings: UserSettings { settingsManager.settings }
    var selectedMacTab: MacAppTab { MacAppTab(rawValue: tabState.selectedTab) ?? .focus }

    var isResting: Bool {
        engine.phase == .breakTime || engine.phase == .breakExtension || engine.phase == .manualBreak
    }

    // MARK: Shared header / navigation

    var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: Date())
    }

    func headerBar(showsTitle: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 4) {
            if showsTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text("专注好这一刻。")
                        .font(theme.titleFont(size: theme.layout == .columns ? 18 : 20))
                        .foregroundColor(theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(dateLine)
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
            }
            Spacer(minLength: 0)
            headerTools
        }
        .padding(.horizontal, theme.layout == .columns ? theme.pageInset : 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    var headerTools: some View {
        HStack(spacing: 2) {
            SkinPaletteButton()
            headerIcon("clock.arrow.circlepath", title: "专注复盘") { showFocusReview() }
            headerIcon("gearshape", title: "设置") { showSettings() }
        }
    }

    func headerIcon(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.muted)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(SkinPlainButtonStyle(theme: theme))
        .accessibilityLabel(title)
        .help(title)
    }

    var compactNav: some View {
        let inner = max(0, theme.controlRadius - 3)
        return HStack(spacing: 2) {
            ForEach(MacAppTab.allCases) { tab in
                let selected = selectedMacTab == tab
                Button { tabState.selectedTab = tab.rawValue } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? theme.accent : theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            selected ? SkinSurface(theme: theme, fill: theme.surface, radius: inner,
                                                   stroke: theme.squareCorners ? theme.ink : nil,
                                                   strokeWidth: theme.borderWidth, elevated: false) : nil
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(SkinPlainButtonStyle(theme: theme, radius: inner))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(theme.controlShape.fill(theme.subtle))
        .overlay(theme.squareCorners ? theme.controlShape.strokeBorder(theme.line, lineWidth: 1) : nil)
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    var bottomNav: some View {
        HStack(spacing: 0) {
            ForEach(MacAppTab.allCases) { tab in
                let selected = selectedMacTab == tab
                Button { tabState.selectedTab = tab.rawValue } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        Text(tab.title).font(.system(size: 9, weight: selected ? .semibold : .regular))
                    }
                    .foregroundColor(selected ? theme.accent : theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .overlay(alignment: .top) {
                        theme.chipShape
                            .fill(selected ? theme.accent : Color.clear)
                            .frame(width: 18, height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SkinPlainButtonStyle(theme: theme, radius: 0))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.squareCorners ? theme.ink : theme.line)
                .frame(height: theme.squareCorners ? theme.borderWidth : 1)
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: theme.style.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accent)
                Text("专注")
                    .font(theme.sectionFont(size: 13))
                    .foregroundColor(theme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            ForEach(MacAppTab.allCases) { tab in
                let selected = selectedMacTab == tab
                Button { tabState.selectedTab = tab.rawValue } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                        Text(tab.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(selected ? theme.accent : theme.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(theme.smallShape().fill(selected ? theme.accentSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(SkinPlainButtonStyle(theme: theme))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Text("今天 \(engine.todayPomodoros) 次专注")
                .font(theme.numberFont(size: 10, weight: .regular))
                .foregroundColor(theme.muted)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .frame(width: 150)
        .background(theme.subtle.opacity(theme.dark ? 0.7 : 0.8))
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.line).frame(width: 1)
        }
    }

    // MARK: Layouts

    @ViewBuilder var compactLayout: some View {
        VStack(spacing: 0) {
            headerBar()
            compactNav
            if selectedMacTab == .focus {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: theme.pageSpacing) {
                        focusHeading
                        focusCore(ringSize: 210)
                        statsLine
                        blockCard
                        tasksCard
                        soundRow
                    }
                    .padding(.horizontal, theme.pageInset)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                }
            } else {
                themedTabContent
            }
        }
    }

    @ViewBuilder var airyLayout: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                headerTools
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if selectedMacTab == .focus {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: theme.pageSpacing) {
                        VStack(spacing: 6) {
                            Text("留一刻，给自己。")
                                .font(theme.titleFont(size: 24))
                                .foregroundColor(theme.ink)
                                .accessibilityAddTraits(.isHeader)
                            Text(dateLine)
                                .font(.system(size: 11))
                                .tracking(0.5)
                                .foregroundColor(theme.muted)
                        }
                        .padding(.top, 2)

                        phaseMenu
                        RingTimer(progress: engine.phaseProgress,
                                  text: timerDisplay,
                                  caption: timerCaption,
                                  theme: theme,
                                  size: 228,
                                  resting: isResting)
                        controlsRow(fullWidth: true)
                        Text("今天已完成 \(engine.todayPomodoros) 次专注")
                            .font(theme.numberFont(size: 11, weight: .regular))
                            .foregroundColor(theme.muted)
                        blockCard
                        tasksCard
                        soundRow
                    }
                    .padding(.horizontal, theme.pageInset)
                    .padding(.bottom, 20)
                }
            } else {
                themedTabContent
            }
            bottomNav
        }
    }

    @ViewBuilder var columnsLayout: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                headerBar()
                if selectedMacTab == .focus {
                    ScrollView(showsIndicators: false) {
                        HStack(alignment: .top, spacing: 22) {
                            VStack(spacing: 14) {
                                phaseMenu
                                RingTimer(progress: engine.phaseProgress,
                                          text: timerDisplay,
                                          caption: timerCaption,
                                          theme: theme,
                                          size: 205,
                                          resting: isResting)
                                controlsRow(fullWidth: true)
                                statsLine
                                habiticaStrip
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: theme.pageSpacing) {
                                blockCard
                                tasksCard
                                soundRow
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, theme.pageInset)
                        .padding(.vertical, 16)
                    }
                } else {
                    themedTabContent
                }
            }
        }
    }

    @ViewBuilder var themedTabContent: some View {
        switch selectedMacTab {
        case .tasks:
            TopThreeView()
        case .habits:
            HabiticaHabitsView()
        case .dailies:
            HabiticaDailiesView()
        case .role:
            HabiticaProfileView()
        case .review:
            FocusReviewView()
        case .focus:
            EmptyView()
        }
    }

    // MARK: Focus composition

    var focusHeading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("你的专注")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundColor(theme.muted)
                Text("把重要的事，先做好。")
                    .font(theme.titleFont(size: 17))
                    .foregroundColor(theme.ink)
            }
            Spacer(minLength: 0)
            phaseMenu
        }
    }

    var timerDisplay: String {
        if engine.phase == .idle && engine.timerString == "00:00" {
            return String(format: "%02d:00", sideSettings.pomoDurationMins)
        }
        return engine.timerString
    }

    var timerCaption: String {
        if let task = engine.taskFocus { return "\(engine.isFrozen ? "已暂停" : "专注中") · \(task.title)" }
        if engine.isFrozen { return "已暂停 · 随时继续" }
        switch engine.phase {
        case .pomodoro: return "专注中 · 让时间慢慢发生"
        case .breakTime, .breakExtension, .manualBreak: return "休息中 · 放松一下"
        default: return "准备开始第 \(engine.pomoSetCounter + 1) 次专注"
        }
    }

    var phaseLabel: String {
        switch engine.phase {
        case .pomodoro: return engine.isRunning ? "专注" : "专注已暂停"
        case .breakTime, .breakExtension, .manualBreak: return "休息"
        default: return "专注"
        }
    }

    var phaseMenu: some View {
        let tint = theme.phaseTint(resting: isResting)
        return Menu {
            Button(engine.isRunning ? "暂停" : "开始 / 继续") { engine.togglePomodoro() }
            Divider()
            ForEach([1, 5, 15, 30], id: \.self) { minutes in
                Button("休息 \(minutes) 分钟") { engine.takeBreak(duration: minutes) }
            }
            .disabled(engine.phase != .idle || engine.isRunning || engine.isFrozen)
        } label: {
            HStack(spacing: 5) {
                theme.dotShape.fill(tint).frame(width: 6, height: 6)
                Text(phaseLabel).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(theme.chipShape.fill(theme.phaseSoft(resting: isResting)))
            .contentShape(theme.chipShape)
        }
        // The button menu style keeps the custom chip label; borderlessButton redraws it as plain text.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换阶段或开始休息")
        .accessibilityLabel("当前阶段：\(phaseLabel)")
    }

    func focusCore(ringSize: CGFloat) -> some View {
        VStack(spacing: 14) {
            RingTimer(progress: engine.phaseProgress,
                      text: timerDisplay,
                      caption: timerCaption,
                      theme: theme,
                      size: ringSize,
                      resting: isResting)
            controlsRow(fullWidth: true)
        }
        .frame(maxWidth: .infinity)
    }

    func controlsRow(fullWidth: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                engine.togglePomodoro()
            } label: {
                Label(primaryTitle, systemImage: primarySymbol)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryActionStyle(theme: theme))

            Button {
                resetTapped()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20)
            }
            .buttonStyle(QuietButtonStyle(theme: theme, height: 42))
            .help(engine.phase == .pomodoro ? "放弃本次番茄" : "结束当前阶段")
            .accessibilityLabel(engine.phase == .pomodoro ? "放弃本次番茄" : "结束当前阶段")

            if engine.phase == .pomodoro {
                Button {
                    engine.skipToBreak()
                } label: {
                    Image(systemName: "forward.end")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20)
                }
                .buttonStyle(QuietButtonStyle(theme: theme, height: 42))
                .help("跳到休息")
                .accessibilityLabel("跳到休息")
            }
        }
        .frame(maxWidth: fullWidth ? .infinity : nil)
    }

    var primaryTitle: String {
        if engine.isFrozen { return "继续专注" }
        if engine.isRunning && engine.phase == .pomodoro { return "暂停专注" }
        if engine.isRunning && (engine.phase == .breakTime || engine.phase == .breakExtension || engine.phase == .manualBreak) {
            return "暂停休息"
        }
        return "开始专注"
    }

    var primarySymbol: String {
        (engine.isRunning && !engine.isFrozen) ? "pause.fill" : "play.fill"
    }

    func resetTapped() {
        if engine.phase == .pomodoro {
            showAbandonConfirm = true
        } else {
            engine.reset()
        }
    }

    var statsLine: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: theme.checkSymbol(true)).foregroundColor(theme.accent)
                Text("\(engine.todayPomodoros) 次")
            }
            Text("·").foregroundColor(theme.line)
            Text("\(engine.todayFocusMinutes) 分钟")
            Text("·").foregroundColor(theme.line)
            Text("第 \(engine.pomoSetCounter + 1) / \(sideSettings.pomoSetNum) 个")
            Spacer(minLength: 0)
        }
        .font(theme.numberFont(size: 11, weight: .regular))
        .foregroundColor(theme.muted)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var habiticaStrip: some View {
        if sideSettings.connectHabitica {
            HStack(spacing: 12) {
                statLabel(String(format: "%.1f", engine.habiticaMonies), symbol: "circle.fill", tint: theme.highlight, name: "金币")
                statLabel(String(format: "%.0f", engine.habiticaExp), symbol: "star.fill", tint: theme.accent, name: "经验")
                statLabel(String(format: "%.0f", engine.habiticaHp), symbol: "heart.fill", tint: theme.danger, name: "生命")
                Button {
                    Task { await engine.refreshHabitica() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.muted)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(SkinPlainButtonStyle(theme: theme))
                .help("刷新 Habitica 状态")
                .accessibilityLabel("刷新 Habitica 状态")
            }
        }
    }

    func statLabel(_ value: String, symbol: String, tint: Color, name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundColor(tint)
            Text(value).font(theme.numberFont(size: 11, weight: .regular)).foregroundColor(theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(value)")
    }

    // MARK: Cards

    struct FocusTaskRow: Identifiable {
        let id: UUID
        let title: String
        let category: String
        let isCompleted: Bool
    }

    var todaysFocusTasks: [FocusTaskRow] {
        let key = topThree.todayKey(settings: sideSettings)
        guard let day = topThree.store.history[key] else { return [] }
        var rows: [FocusTaskRow] = []
        for (index, group) in day.taskGroups.enumerated() {
            for task in group where !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(FocusTaskRow(id: task.id,
                                         title: task.title,
                                         category: topThree.categoryName(index: index),
                                         isCompleted: task.isCompleted))
            }
        }
        return Array(rows.prefix(4))
    }

    func cardHeader(_ title: String, link: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(theme.sectionFont(size: 12))
                .foregroundColor(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 2) {
                    Text(link)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .buttonStyle(SkinPlainButtonStyle(theme: theme))
        }
    }

    var blockCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardHeader("当前时间块", link: "查看全部") { showBlocksSheet = true }

            if sideSettings.enableBlockMode {
                let index = min(max(0, blockManager.blockProgress.currentBlockIndex),
                                max(0, sideSettings.blockCount - 1))
                let pair = blockManager.getCurrentBlockCompletion(settings: sideSettings)
                HStack(spacing: 11) {
                    Text("B\(index + 1)")
                        .font(theme.numberFont(size: 11, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .frame(width: 32, height: 32)
                        .background(theme.smallShape().fill(theme.accentSoft))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(blockGoal(index) ?? "第 \(index + 1) 个时间块")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(pair.completed) / \(pair.total)")
                                .font(theme.numberFont(size: 11))
                                .foregroundColor(pair.total > 0 && pair.completed >= pair.total ? theme.accent : theme.muted)
                        }
                        SkinProgressBar(value: Double(pair.completed), total: Double(max(pair.total, 1)))
                        Text(blockTimeText(index) ?? "未设置时间范围")
                            .font(theme.numberFont(size: 9, weight: .regular))
                            .foregroundColor(theme.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("时间块模式未启用，可在设置中开启。")
                    .font(.system(size: 10))
                    .foregroundColor(theme.muted)
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    func blockGoal(_ index: Int) -> String? {
        guard sideSettings.blockGoals.indices.contains(index) else { return nil }
        let value = sideSettings.blockGoals[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func blockTimeText(_ index: Int) -> String? {
        guard sideSettings.blockTimeRanges.indices.contains(index) else { return nil }
        let range = sideSettings.blockTimeRanges[index]
        return String(format: "%02d:%02d – %02d:%02d",
                      range.startHour, range.startMinute, range.endHour, range.endMinute)
    }

    var tasksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader("今日要事", link: "全部任务") { tabState.selectedTab = MacAppTab.tasks.rawValue }

            if todaysFocusTasks.isEmpty {
                Text("还没有添加今天最重要的三件事。")
                    .font(.system(size: 10))
                    .foregroundColor(theme.muted)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 2) {
                    ForEach(todaysFocusTasks) { row in
                        Button { tabState.selectedTab = MacAppTab.tasks.rawValue } label: {
                            HStack(spacing: 8) {
                                Image(systemName: theme.checkSymbol(row.isCompleted))
                                    .font(.system(size: 12))
                                    .foregroundColor(row.isCompleted ? theme.accent : theme.muted.opacity(0.7))
                                Text(row.title)
                                    .font(.system(size: 11))
                                    .foregroundColor(row.isCompleted ? theme.muted : theme.ink)
                                    .strikethrough(row.isCompleted, color: theme.muted)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(row.category)
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.muted)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SkinPlainButtonStyle(theme: theme))
                        .accessibilityLabel("\(row.isCompleted ? "已完成" : "未完成")：\(row.title)，\(row.category)")
                    }
                }
                .padding(.horizontal, -6)
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    var soundRow: some View {
        Button { showSettings() } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accent)
                    .frame(width: 30, height: 30)
                    .background(theme.smallShape().fill(theme.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ambientLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.ink)
                    Text("跟随专注 · 在设置中更换")
                        .font(.system(size: 9))
                        .foregroundColor(theme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.muted)
            }
            .themeCard(theme, padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SkinCardButtonStyle(theme: theme))
        .accessibilityLabel("背景音：\(ambientLabel)，在设置中更换")
    }

    var ambientLabel: String {
        if sideSettings.ambientSource == "qishi" {
            return "栖时 · 随机场景"
        }
        let name = sideSettings.ambientSound
        return name.isEmpty ? "无背景音" : "自定义 · \(name)"
    }

    var blocksSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("今天的时间块")
                    .font(theme.titleFont(size: 16))
                    .foregroundColor(theme.ink)
                Spacer()
                Button("完成") { showBlocksSheet = false }
                    .buttonStyle(QuietButtonStyle(theme: theme, height: 28))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle().fill(theme.line).frame(height: 1)

            ScrollView {
                VStack(spacing: 16) {
                    BlockTimeBlockView().environmentObject(engine)
                        .themeCard(theme, padding: 8)
                    BlockTimelineView().frame(height: 216)
                }
                .padding(20)
            }
        }
        .frame(width: 470, height: 640)
        .background(theme.pageBackground)
        .environment(\.appTheme, theme)
        .tint(theme.accent)
    }
}
