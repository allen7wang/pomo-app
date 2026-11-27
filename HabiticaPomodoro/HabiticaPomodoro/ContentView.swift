import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

// MARK: - Main App
@main
struct HabiticaPomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            MacDataGate(appDelegate: appDelegate) { SettingsView() }
        }
        .commands {
            MacPomodoroCommands(appDelegate: appDelegate)
        }
    }
}

private struct MacPomodoroCommands: Commands {
    @ObservedObject var appDelegate: AppDelegate

    var body: some Commands {
        CommandMenu("Pomodoro") {
            Button("Start/Pause Pomodoro") {
                guard appDelegate.dataStatus == .ready else { return }
                PomodoroEngine.shared.togglePomodoro()
            }
            .disabled(appDelegate.dataStatus != .ready)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            ForEach(MacAppTab.allCases) { tab in
                Button(tab.menuTitle) {
                    AppTabState.shared.selectedTab = tab.rawValue
                    appDelegate.ensureTimerWindowVisible()
                }
                .keyboardShortcut(KeyEquivalent(Character("\(tab.rawValue + 1)")), modifiers: [.command])
            }
        }
    }
}

private struct MacDataGate<Content: View>: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject private var styleStore = UIStyleStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        if appDelegate.dataStatus == .ready {
            content()
        } else {
            let theme = AppTheme(style: styleStore.style, dark: colorScheme == .dark)
            let failed = appDelegate.dataStatus == .unavailable
            VStack(spacing: 14) {
                Image(systemName: failed ? "folder.badge.questionmark" : "folder")
                    .font(.system(size: 30))
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)
                Text(failed ? "暂时无法读取记录" : "正在读取专注记录")
                    .font(theme.titleFont(size: 17))
                    .foregroundStyle(theme.ink)
                Text(failed
                     ? "请检查 Habitica Pomodoro 的「文稿」访问权限和 iCloud Drive 状态，然后重试。"
                     : "记录保存在「文稿」中。如果 macOS 询问访问权限，请允许 Habitica Pomodoro 读取原有记录。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: 310)
                if failed {
                    Button("重试", action: appDelegate.loadStartupData)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("正在读取专注记录")
                }
            }
            .padding(24)
            .frame(minWidth: 360, minHeight: 240)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.pageBackground)
            .tint(theme.accent)
        }
    }
}

// MARK: - App Delegate (status bar + window management)
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    enum DataStatus { case waiting, loading, unavailable, ready }

    @Published private(set) var dataStatus: DataStatus = .waiting
    var statusItem: NSStatusItem?
    var timerWindow: NSWindow?
    var settingsWindow: NSWindow?
    var badgeTimer: Timer?
    var badgeDisplayMode: BadgeDisplayMode = .timer

    enum BadgeDisplayMode {
        case timer
        case count
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Start with icon
            if let icon = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "Pomodoro") {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.title = "🍅"
            }
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            button.action = #selector(toggleTimerWindow)
            button.target = self
        }

        UIStyleStore.shared.applyForcedAppearance()
        showTimerWindow()
        loadStartupData()
    }

    func loadStartupData() {
        guard dataStatus == .waiting || dataStatus == .unavailable else { return }
        dataStatus = .loading
        PomodoroFileChanges.shared.prepareForMacLaunch { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                self.dataStatus = .unavailable
                return
            }

            // Initialize readers while the background snapshot is available on the main thread.
            _ = SettingsManager.shared
            _ = BlockProgressManager.shared
            _ = TopThreeManager.shared
            _ = PlantJournal.shared
            _ = HistogramManager.shared
            let engine = PomodoroEngine.shared
            engine.loadTodayCount()
            engine.restoreFocusAfterLaunch()
            self.dataStatus = .ready
            DispatchQueue.main.async { self.startRuntimeServices() }
        }
    }

    private func startRuntimeServices() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Register for badge update notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBadgeUpdate),
            name: .badgeUpdate,
            object: nil
        )

        // Start habitica sync
        Task { await PomodoroEngine.shared.initHabiticaTasks() }
        PomodoroFileChanges.shared.startMonitoring()

        // Setup global hotkey via Carbon (Alt+Shift+P)
        HotKeyManager.shared.register()

        // Start badge alternating display
        startBadgeAlternating()

        // Start block notification timer
        BlockNotificationManager.shared.startReminderTimer(settings: SettingsManager.shared.settings)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard dataStatus == .ready else { return }
        PomodoroEngine.shared.resyncAfterForeground {
            BlockNotificationManager.shared.startReminderTimer(settings: SettingsManager.shared.settings)
        }
    }

    // 供快捷键使用：确保主窗口可见
    func ensureTimerWindowVisible() {
        if timerWindow?.isVisible != true {
            showTimerWindow()
        } else {
            timerWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func handleBadgeUpdate() {
        updateBadge()
    }

    @objc func toggleTimerWindow() {
        if timerWindow?.isVisible == true {
            timerWindow?.orderOut(nil)
        } else {
            showTimerWindow()
        }
    }

    func showTimerWindow() {
        if timerWindow == nil {
            let contentView = MacDataGate(appDelegate: self) { TimerView() }
            let hostingController = NSHostingController(rootView: contentView)
            timerWindow = NSWindow(contentViewController: hostingController)
            timerWindow?.title = "Habitica Pomodoro"
            timerWindow?.styleMask = [.titled, .closable, .miniaturizable]
            timerWindow?.setFrameAutosaveName("TimerWindowV8")
            timerWindow?.setContentSize(UIStyleStore.shared.style.windowSize)
        }
        timerWindow?.center()
        timerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Alternate badge display between timer and count
    private func startBadgeAlternating() {
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.badgeDisplayMode = self.badgeDisplayMode == .timer ? .count : .timer
            self.updateBadge()
        }
    }

    // Update badge text and color
    private func updateBadge() {
        guard dataStatus == .ready, let button = statusItem?.button else { return }

        let engine = PomodoroEngine.shared

        if !engine.isRunning {
            // Show icon when not running
            if let icon = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "Pomodoro") {
                icon.isTemplate = true
                button.image = icon
            } else {
                // Fallback: use text
                button.title = "🍅"
                button.image = nil
            }
            return
        }

        // Clear icon when running, show text
        button.image = nil

        let settings = SettingsManager.shared.settings

        if badgeDisplayMode == .timer {
            // Show countdown
            button.title = engine.timerString
        } else {
            // Show progress based on mode
            if settings.enableBlockMode {
                // Block mode: show current block progress (based on time)
                BlockProgressManager.shared.updateBlockIndexFromTime(settings: settings)
                let (completed, total) = BlockProgressManager.shared.getCurrentBlockCompletion(settings: settings)
                let bp = BlockProgressManager.shared.blockProgress
                // 番茄进行中时，展示"正在进行的第几个"（completed + 1）
                let inProgress = engine.isRunning && engine.phase == .pomodoro
                let display = min(inProgress ? completed + 1 : completed, total)
                button.title = "B\(bp.currentBlockIndex + 1):\(display)/\(total)"
            } else {
                // Regular mode: show pomo set progress
                button.title = "\(engine.pomoSetCounter)/\(engine.settings.pomoSetNum)"
            }
        }

        // Set color based on phase
        switch engine.phase {
        case .pomodoro:
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.foregroundColor: NSColor.systemGreen]
            )
        case .breakTime:
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.foregroundColor: NSColor.systemBlue]
            )
        case .breakExtension:
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        default:
            button.attributedTitle = NSAttributedString(string: button.title)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Timer View (main window)
struct TimerView: View {
    @ObservedObject var engine = PomodoroEngine.shared
    @ObservedObject var blockManager = BlockProgressManager.shared
    @ObservedObject var tabState = AppTabState.shared
    @ObservedObject var settingsManager = SettingsManager.shared
    @ObservedObject var topThree = TopThreeManager.shared
    @ObservedObject var styleStore = UIStyleStore.shared
    @Environment(\.colorScheme) var colorScheme

    @State var showAbandonConfirm = false
    @State var showBlocksSheet = false

    var body: some View {
        let theme = self.theme
        Group {
            switch theme.layout {
            case .compact: compactLayout
            case .airy: airyLayout
            case .columns: columnsLayout
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let warning = engine.focusRecoveryWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(theme.surface)
            }
        }
        .frame(width: theme.macWindowSize.width,
               height: theme.macWindowSize.height)
        .environment(\.appTheme, theme)
        .tint(theme.accent)
        .background(theme.pageBackground)
        .background(WindowSizeConfigurator(size: theme.macWindowSize))
        .confirmationDialog("放弃当前番茄？时间块中的植物将记为枯萎。",
                            isPresented: $showAbandonConfirm, titleVisibility: .visible) {
            Button("放弃番茄", role: .destructive) {
                engine.pomodoroInterrupted(breakStreak: true)
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showBlocksSheet) { blocksSheet }
    }

    func showSettings() {
        if let settingsWindow = NSApp.windows.first(where: { $0.title == "Settings" }) {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 550, height: 650))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func showFocusReview() {
        tabState.selectedTab = MacAppTab.review.rawValue
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var sm = SettingsManager.shared
    @ObservedObject var am = AudioManager.shared
    @ObservedObject private var blockManager = BlockProgressManager.shared
    @ObservedObject private var styleStore = UIStyleStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showResetBlockConfirm = false
    @State private var showClearBlocksConfirm = false

    private var theme: AppTheme { AppTheme(style: styleStore.style, dark: colorScheme == .dark) }

    var body: some View {
        TabView {
            appearanceSettingsTab.tabItem { Label("外观", systemImage: "paintpalette") }
            timerSettingsTab.tabItem { Label("Timer", systemImage: "timer") }
            blockSettingsTab.tabItem { Label("Blocks", systemImage: "square.grid.3x3") }
            habiticaSettingsTab.tabItem { Label("Habitica", systemImage: "link") }
            dataSettingsTab.tabItem { Label("Data", systemImage: "doc") }
        }
        .frame(width: 530, height: 630)
        .environment(\.appTheme, theme)
        .tint(theme.accent)
        .onAppear { styleStore.applyForcedAppearance() }
        .onDisappear { am.stopPreview() }
        .onChange(of: sm.settings.ambientSource) { _ in am.stopPreview() }
        .confirmationDialog("重置当前块的完成数？历史种植记录保留。",
                            isPresented: $showResetBlockConfirm, titleVisibility: .visible) {
            Button("重置当前块", role: .destructive) {
                blockManager.resetCurrentBlockProgress(settings: sm.settings)
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清空全部时间块及植物历史？此操作不可撤销。",
                            isPresented: $showClearBlocksConfirm, titleVisibility: .visible) {
            Button("清空时间块历史", role: .destructive) { blockManager.clearHistory() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: Page furniture

    private func settingsPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.pageBackground)
        .foregroundColor(theme.ink)
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String? = nil,
                                                @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
                Text(title)
                    .font(theme.sectionFont(size: 13))
                    .foregroundColor(theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(theme, padding: 14)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func divider() -> some View {
        Rectangle().fill(theme.line).frame(height: 1).accessibilityHidden(true)
    }

    func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: Tabs

    var timerSettingsTab: some View {
        settingsPage {
            settingsSection("Pomodoro Settings", symbol: "timer") {
                stepperRow("Pomodoro duration", value: $sm.settings.pomoDurationMins, range: 1...120, suffix: "min")
                stepperRow("Short break", value: $sm.settings.breakDuration, range: 1...60, suffix: "min")
                stepperRow("Break extension", value: $sm.settings.breakExtention, range: 0...30, suffix: "min")
                stepperRow("Long break", value: $sm.settings.longBreakDuration, range: 1...120, suffix: "min")
                stepperRow("Long break after", value: $sm.settings.pomoSetNum, range: 1...12, suffix: "pomodoros")
                divider()
                toggleRow("Start breaks manually", isOn: $sm.settings.manualBreak)
                toggleRow("Reset timer after break extension", isOn: $sm.settings.resetPomoAfterBreak)
            }
            settingsSection("Sounds", symbol: "speaker.wave.2") {
                pickerRow("Pomodoro end sound", selection: $sm.settings.pomoEndSound, options: AudioManager.allSoundOptions)
                sliderRow("Volume", value: $sm.settings.pomoEndSoundVolume)
                pickerRow("Break end sound", selection: $sm.settings.breakEndSound, options: AudioManager.allSoundOptions)
                sliderRow("Volume", value: $sm.settings.breakEndSoundVolume)
                divider()
                HStack {
                    Text("Ambient source")
                    Spacer()
                    Picker("Ambient source", selection: $sm.settings.ambientSource) {
                        Text("Custom").tag("custom")
                        Text("Qishi Random").tag("qishi")
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                if sm.settings.ambientSource == "qishi" {
                    note("每个番茄随机播放一个栖时场景混音（共 \(QishiSceneStore.presets.count) 个场景，暂停恢复自动延续，不与上个番茄重复）")
                    sliderRow("Volume", value: $sm.settings.ambientSoundVolume)
                    HStack(spacing: 8) {
                        Button("试听随机场景") {
                            if let preset = QishiSceneStore.randomPreset(excluding: nil) {
                                am.playQishiPreview(preset, volume: sm.settings.ambientSoundVolume)
                            }
                        }
                        Button("停止试听") { am.stopPreview() }
                    }
                    .buttonStyle(QuietButtonStyle(theme: theme, height: 28))
                } else {
                    pickerRow("Ambient sound", selection: $sm.settings.ambientSound, options: AudioManager.allAmbientOptions)
                    sliderRow("Volume", value: $sm.settings.ambientSoundVolume)
                }
            }
            note("HotKey: ⌥⌘P (Option+Command+P)")
        }
    }

    var blockSettingsTab: some View {
        settingsPage {
            settingsSection("Block Mode", symbol: "square.grid.3x3") {
                toggleRow("Enable Block Mode", isOn: $sm.settings.enableBlockMode)
                if sm.settings.enableBlockMode {
                    divider()
                    stepperRow("Blocks per day", value: $sm.settings.blockCount, range: 1...24, suffix: "blocks")
                    stepperRow("Pomodoros per block", value: $sm.settings.blockPomoCount, range: 1...12, suffix: "pomodoros")
                    toggleRow("Reward when block complete", isOn: $sm.settings.blockRewardEnabled)
                    toggleRow("Sprint reminder", isOn: $sm.settings.blockSprintReminder)
                    toggleRow("Remind before block starts", isOn: $sm.settings.blockStartReminder)
                    if sm.settings.blockStartReminder {
                        stepperRow("Reminder lead time", value: $sm.settings.blockReminderMinutes,
                                   range: 1...60, suffix: "min")
                    }
                }
            }

            if sm.settings.enableBlockMode {
                settingsSection("Block Time Ranges & Goals", symbol: "clock") {
                    note("Set time range and goal for each block")
                    ForEach(0..<sm.settings.blockCount, id: \.self) { index in
                        blockEditor(index)
                    }
                }

                settingsSection("Reset", symbol: "arrow.counterclockwise") {
                    HStack(spacing: 8) {
                        Button("Reset Block Progress") { showResetBlockConfirm = true }
                        Button("Clear Block History") { showClearBlocksConfirm = true }
                    }
                    .buttonStyle(QuietButtonStyle(theme: theme, height: 28))
                    .foregroundColor(theme.danger)
                }
            }
        }
    }

    private func blockEditor(_ blockIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Block \(blockIndex + 1)")
                .font(theme.numberFont(size: 12, weight: .semibold))
                .foregroundColor(theme.accent)

            HStack(spacing: 8) {
                Text("Time:")
                    .foregroundColor(theme.muted)
                Picker("Start Hour", selection: Binding(
                    get: { blockIndex < sm.settings.blockTimeRanges.count ? sm.settings.blockTimeRanges[blockIndex].startHour : 4 },
                    set: { newValue in
                        while sm.settings.blockTimeRanges.count <= blockIndex {
                            sm.settings.blockTimeRanges.append(BlockTimeRange(startHour: 4, startMinute: 0, endHour: 7, endMinute: 0))
                        }
                        sm.settings.blockTimeRanges[blockIndex].startHour = newValue
                    }
                )) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }

                Picker("Start Minute", selection: Binding(
                    get: { blockIndex < sm.settings.blockTimeRanges.count ? sm.settings.blockTimeRanges[blockIndex].startMinute : 0 },
                    set: { newValue in
                        while sm.settings.blockTimeRanges.count <= blockIndex {
                            sm.settings.blockTimeRanges.append(BlockTimeRange(startHour: 4, startMinute: 0, endHour: 7, endMinute: 0))
                        }
                        sm.settings.blockTimeRanges[blockIndex].startMinute = newValue
                    }
                )) {
                    ForEach(0..<60, id: \.self) { minute in
                        Text(String(format: ":%02d", minute)).tag(minute)
                    }
                }

                Text("-")
                    .foregroundColor(theme.muted)

                Picker("End Hour", selection: Binding(
                    get: { blockIndex < sm.settings.blockTimeRanges.count ? sm.settings.blockTimeRanges[blockIndex].endHour : 7 },
                    set: { newValue in
                        while sm.settings.blockTimeRanges.count <= blockIndex {
                            sm.settings.blockTimeRanges.append(BlockTimeRange(startHour: 4, startMinute: 0, endHour: 7, endMinute: 0))
                        }
                        sm.settings.blockTimeRanges[blockIndex].endHour = newValue
                    }
                )) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }

                Picker("End Minute", selection: Binding(
                    get: { blockIndex < sm.settings.blockTimeRanges.count ? sm.settings.blockTimeRanges[blockIndex].endMinute : 0 },
                    set: { newValue in
                        while sm.settings.blockTimeRanges.count <= blockIndex {
                            sm.settings.blockTimeRanges.append(BlockTimeRange(startHour: 4, startMinute: 0, endHour: 7, endMinute: 0))
                        }
                        sm.settings.blockTimeRanges[blockIndex].endMinute = newValue
                    }
                )) {
                    ForEach(0..<60, id: \.self) { minute in
                        Text(String(format: ":%02d", minute)).tag(minute)
                    }
                }
            }
            .font(.caption)

            // Goal input
            let goalText: Binding<String> = Binding(
                get: {
                    if blockIndex < sm.settings.blockGoals.count {
                        return sm.settings.blockGoals[blockIndex]
                    }
                    return ""
                },
                set: { newValue in
                    if blockIndex < sm.settings.blockGoals.count {
                        sm.settings.blockGoals[blockIndex] = newValue
                    } else {
                        sm.settings.blockGoals.append(newValue)
                    }
                }
            )
            TextField("Optional goal", text: goalText)
                .textFieldStyle(.roundedBorder)
        }
        .themeWell(theme, padding: 10)
    }

    var habiticaSettingsTab: some View {
        settingsPage {
            settingsSection("Habitica", symbol: "link") {
                toggleRow("Connect to Habitica", isOn: $sm.settings.connectHabitica)
                if sm.settings.connectHabitica {
                    divider()
                    Text("Habitica User ID:")
                    TextField("User ID", text: $sm.settings.uid)
                        .textFieldStyle(.roundedBorder)
                    Text("Habitica API Token:")
                    SecureField("API Token", text: $sm.settings.apiToken)
                        .textFieldStyle(.roundedBorder)
                    Link("Get credentials at habitica.com/user/settings/api",
                         destination: URL(string: "https://habitica.com/user/settings/api")!)
                        .font(.caption)
                        .foregroundColor(theme.accent)
                }
            }
            if sm.settings.connectHabitica {
                settingsSection("Pomodoro Habit", symbol: "plusminus") {
                    toggleRow("+ habit when pomodoro done", isOn: $sm.settings.pomoHabitPlus)
                    toggleRow("- habit if stopped early", isOn: $sm.settings.pomoHabitMinus)
                    toggleRow("- habit if break extension over", isOn: $sm.settings.breakExtentionFails)
                    toggleRow("Use custom Pomodoro Habit ID", isOn: $sm.settings.customPomodoroTask)
                    if sm.settings.customPomodoroTask {
                        TextField("Pomodoro Habit ID", text: Binding(
                            get: { sm.settings.pomodoroTaskId ?? "" },
                            set: { sm.settings.pomodoroTaskId = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                settingsSection("Pomodoro Combo Habit", symbol: "flame") {
                    toggleRow("+ habit for set complete", isOn: $sm.settings.pomoSetHabitPlus)
                    toggleRow("Use custom Combo Habit ID", isOn: $sm.settings.customSetTask)
                    if sm.settings.customSetTask {
                        TextField("Combo Habit ID", text: Binding(
                            get: { sm.settings.pomodoroSetTaskId ?? "" },
                            set: { sm.settings.pomodoroSetTaskId = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                settingsSection("Notifications", symbol: "bell") {
                    toggleRow("Mobile notification - short break over", isOn: $sm.settings.breakExtentionNotify)
                    toggleRow("Mobile notification - long break over", isOn: $sm.settings.longBreakNotify)
                }
                settingsSection("Developer", symbol: "server.rack") {
                    Text("Developer Server URL (leave empty for default):")
                    TextField("https://habitica.com/api/v3/", text: $sm.settings.developerServerUrl)
                        .textFieldStyle(.roundedBorder)
                    note("自定义服务会收到 User ID 和 API Token；只使用你信任的 HTTPS 地址。")
                }
            }
        }
    }

    var dataSettingsTab: some View {
        settingsPage {
            settingsSection("Data Storage", symbol: "externaldrive") {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(theme.accent)
                        .frame(width: 30, height: 30)
                        .background(theme.smallShape().fill(theme.accentSoft))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved to Documents/.habitica-pomodoro")
                            .font(.system(size: 12, weight: .medium))
                        Text(PomodoroDataDir.resolvedURL.path)
                            .font(.caption2)
                            .foregroundColor(theme.muted)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button("Save Now") {
                        syncAllData()
                    }
                    .buttonStyle(QuietButtonStyle(theme: theme, height: 28))
                }

                note("隐藏文件夹，随 Documents 由 iCloud Drive 自动同步")
            }

            settingsSection("Block History", symbol: "calendar") {
                Text("Days: \(BlockProgressManager.shared.blockHistory.count)")
                    .font(theme.numberFont(size: 12))

                let sortedDates = BlockProgressManager.shared.blockHistory.keys.sorted().reversed()
                ForEach(Array(sortedDates.prefix(5)), id: \.self) { date in
                    HStack {
                        Text(date)
                            .font(theme.numberFont(size: 11, weight: .regular))
                            .foregroundColor(theme.muted)
                        Spacer()
                        if let entries = BlockProgressManager.shared.blockHistory[date] {
                            Text("Entries: \(entries.count)")
                                .font(theme.numberFont(size: 11, weight: .regular))
                        }
                    }
                    .padding(.vertical, 2)
                }

                if BlockProgressManager.shared.blockHistory.count > 5 {
                    note("... and \(BlockProgressManager.shared.blockHistory.count - 5) more days")
                }
            }
        }
    }

    var appearanceSettingsTab: some View {
        settingsPage {
            settingsSection("界面风格", symbol: "paintpalette") {
                note("\(AppUIStyle.allCases.count) 套皮肤可随时切换；选择保存在本机，不影响任务、计时或同步数据。")
                SkinPickerList()
                note("当前：\(styleStore.style.title)。也可以用主窗口右上角的调色板按钮快速切换。")
            }
        }
    }

    private func syncAllData() {
        PomodoroFileChanges.shared.syncFromDiskIfNeeded { saveAllDataAfterSync() }
    }

    private func saveAllDataAfterSync() {
        var failedFiles: [String] = []
        if !SettingsManager.shared.save() { failedFiles.append("habitica_pomodoro_settings.json") }
        if !BlockProgressManager.shared.saveProgress() { failedFiles.append("habitica_pomodoro_block_progress.json") }
        if !BlockProgressManager.shared.saveHistory() { failedFiles.append("habitica_pomodoro_block_history.json") }
        if !BlockProgressManager.shared.saveDailyBlocks() { failedFiles.append("habitica_pomodoro_daily_blocks.json") }
        if !TopThreeManager.shared.save() { failedFiles.append("habitica_pomodoro_top_three.json") }
        if !HistogramManager.shared.save() { failedFiles.append("habitica_pomodoro_histogram.json") }
        if !PlantJournal.shared.save() { failedFiles.append("habitica_pomodoro_plants.json") }
        
        let alert = NSAlert()
        if failedFiles.isEmpty {
            alert.messageText = "Saved"
            alert.informativeText = "All data saved to \(PomodoroDataDir.url.path)"
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Save Failed"
            alert.informativeText = "The following files were not saved:\n" + failedFiles.joined(separator: "\n")
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value.wrappedValue) \(suffix)")
                .font(theme.numberFont(size: 12, weight: .regular))
                .foregroundColor(theme.muted)
            Stepper(label, value: value, in: range)
                .labelsHidden()
        }
    }

    func pickerRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { Text($0.replacingOccurrences(of: ".mp3", with: "")) }
            }
            .labelsHidden()
            .frame(width: 140)
            Button {
                let volume: Double
                if label == "Pomodoro end sound" { volume = sm.settings.pomoEndSoundVolume }
                else if label == "Break end sound" { volume = sm.settings.breakEndSoundVolume }
                else { volume = sm.settings.ambientSoundVolume }
                am.playSound(selection.wrappedValue, volume: volume)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 14))
                    .foregroundColor(theme.accent)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(SkinPlainButtonStyle(theme: theme))
            .disabled(selection.wrappedValue == "None")
            .help("Preview sound")
            .accessibilityLabel("Preview sound")
        }
    }

    func sliderRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Slider(value: value, in: 0...1)
                .frame(width: 200)
                .accessibilityLabel(label)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(theme.numberFont(size: 11, weight: .regular))
                .foregroundColor(theme.muted)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Block Time Block View (块进度视图)
struct BlockTimeBlockView: View {
    @EnvironmentObject var engine: PomodoroEngine
    @ObservedObject var blockManager = BlockProgressManager.shared

    var body: some View {
        BlockTimeBlockViewContent()
    }
}

private struct BlockTimeBlockViewContent: View {
    @EnvironmentObject var engine: PomodoroEngine
    @Environment(\.appTheme) private var theme
    @ObservedObject var blockManager = BlockProgressManager.shared
    @ObservedObject var plantJournal = PlantJournal.shared

    var body: some View {
        let progress = blockManager.getTodayBlockProgress(settings: engine.settings)
        let totalPomoPerBlock = engine.settings.blockPomoCount
        let current = blockManager.blockProgress.currentBlockIndex

        VStack(spacing: 2) {
            ForEach(0..<engine.settings.blockCount, id: \.self) { blockIndex in
                HStack(spacing: 8) {
                    // Block index label
                    Text("B\(blockIndex + 1)")
                        .font(theme.numberFont(size: 11, weight: .semibold))
                        .foregroundColor(blockIndex == current ? theme.accent : theme.ink)
                        .frame(width: 25, alignment: .leading)

                    // Show time range if available
                    if blockIndex < engine.settings.blockTimeRanges.count {
                        Text(engine.settings.blockTimeRanges[blockIndex].displayString)
                            .font(theme.numberFont(size: 10, weight: .regular))
                            .foregroundColor(theme.muted)
                    }
                    
                    // Show block goal if available
                    if blockIndex < engine.settings.blockGoals.count {
                        let goal = engine.settings.blockGoals[blockIndex]
                        if !goal.isEmpty {
                            Text(goal)
                                .font(.system(size: 11))
                                .foregroundColor(theme.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    
                    Spacer()

                    // 同一排种植槽：空圆点 / 灌木 / 枯萎；末尾独立的 combo 树。
                    HStack(spacing: 2) {
                        let completed = blockIndex < progress.count ? progress[blockIndex] : 0
                        let attempts = plantJournal.plants(blockIndex: blockIndex, completed: completed)
                        let visible = Array(attempts.suffix(totalPomoPerBlock))
                        ForEach(0..<totalPomoPerBlock, id: \.self) { pomoIndex in
                            PlantMarkerView(outcome: pomoIndex < visible.count ? visible[pomoIndex] : nil)
                        }
                        .help("完成 \(attempts.filter { $0 == .shrub }.count) · 放弃 \(attempts.filter { $0 == .wilted }.count)")

                        Rectangle().fill(theme.line)
                            .frame(width: 1, height: 10)
                            .padding(.horizontal, 2)
                        let trees = plantJournal.treeCount(blockIndex: blockIndex)
                        PlantMarkerView(treeCount: trees)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.smallShape(6).fill(blockIndex == current ? theme.accentSoft.opacity(0.7) : Color.clear))
            }
        }
        .padding(.vertical, 4)
    }
}

// 与原小圆点共用一行；固定尺寸，不撑大时间块布局。
private struct PlantMarkerView: View {
    @Environment(\.appTheme) private var theme
    var outcome: PlantOutcome? = nil
    var treeCount: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            if treeCount > 0 {
                Text("🌳")
                    .font(.system(size: 11))
                    .help("完成 \(treeCount) 个 combo")
                if treeCount > 1 {
                    Text("×\(treeCount)")
                        .font(theme.numberFont(size: 9, weight: .semibold))
                        .foregroundColor(theme.highlight)
                }
            } else if let outcome = outcome {
                Text(outcome == .shrub ? "🌿" : "🥀")
                    .font(.system(size: 11))
                    .help(outcome == .shrub ? "完成 Pomo：灌木" : "中途放弃：枯萎")
            } else {
                theme.dotShape
                    .stroke(theme.muted.opacity(0.5), lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .help("尚未种植")
            }
        }
        .frame(minWidth: 12, minHeight: 14)
        .accessibilityLabel(treeCount > 0 ? "种树 \(treeCount) 棵" :
            outcome == .shrub ? "灌木" : outcome == .wilted ? "枯萎" : "空种植位")
    }
}
