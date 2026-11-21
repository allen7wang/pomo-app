import Foundation
import SwiftUI
import Combine
import AVFoundation
import UserNotifications

extension Notification.Name {
    static let badgeUpdate = Notification.Name("badgeUpdate")
}

enum TimerPhase: String { case idle, pomodoro, breakTime, breakExtension, manualBreak }
enum TomatoState { case wait, progress, freeze, breakTime, win, warning }

private struct FocusCheckpoint: Codable {
    let directory: String
    let deadline: Date?
    let secondsRemaining: Int
    let combo: Int
    let task: TaskFocusSession?
    let settings: UserSettings

    static var location: URL? {
        #if DEBUG
        if let directory = PomodoroDataDir.debugDirectoryOverride {
            return directory.appendingPathComponent(".active-focus.json")
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HabiticaPomodoro", isDirectory: true)
            .appendingPathComponent("active-focus.json")
    }

    func save(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #if os(iOS)
        #if DEBUG
        if PomodoroDataDir.debugDirectoryOverride == nil {
            try excludeFromBackup(parent)
        }
        #else
        try excludeFromBackup(parent)
        #endif
        #endif
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    #if os(iOS)
    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = url
        try directory.setResourceValues(values)
    }
    #endif
}

/// One phase machine on both platforms. Local completion is synchronous; network work never owns transitions.
class PomodoroEngine: ObservableObject {
    static let shared = PomodoroEngine()
    @Published var timerString = "00:00"
    @Published var timerValue = 0
    @Published var isRunning = false
    @Published var isFrozen = false
    @Published var phase: TimerPhase = .idle
    @Published var pomoSetCounter = 0
    @Published var tomatoState: TomatoState = .wait
    @Published var todayPomodoros = 0
    @Published private(set) var todayFocusMinutes = 0
    @Published var habiticaMonies: Double = 0
    @Published var habiticaExp: Double = 0
    @Published var habiticaHp: Double = 0
    @Published var habiticaConnected = false
    @Published var lastNotification = ""
    @Published private(set) var taskFocus: TaskFocusSession?
    @Published private(set) var focusRecoveryWarning: String?

    private var timer: Timer?
    private var phaseRevision = 0
    private var foregroundRecovery: UUID?
    private var endHandler: ((Date) -> Void)?
    private(set) var phaseEndsAt: Date?
    private(set) var phaseDuration = 0

    /// Display-only progress of the current phase (0...1). Never used for scheduling.
    var phaseProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, 1 - Double(timerValue) / Double(phaseDuration)))
    }
    private var lastTickAt: Date?
    private var activePomodoroSettings: UserSettings?
    private var focusDirectory: String?
    private var savedFocusURL: URL?
    private var attemptedFocusRestore = false
    private var catchingUpRestoredFocus = false
    private var activeBreakSettings: UserSettings?
    private var activeBreakExtensionSettings: UserSettings?
    private(set) var completedSet = false
    private(set) var customBreak = false
    private var pendingBreakSeconds = 0
    private var pomodoroTaskId: String?
    private var pomodoroSetTaskId: String?
    private var taskAccountSignature = ""
    private var settingsSubscription: AnyCancellable?
    private let api = HabiticaAPI.shared
    private let settingsManager = SettingsManager.shared
    private let audioManager = AudioManager.shared
    private let histogramManager = HistogramManager.shared

    #if os(iOS)
    static let backgroundEndNotificationId = "pomo-phase-end"
    #endif
    var settings: UserSettings { settingsManager.settings }

    init() {
        settingsSubscription = settingsManager.$settings
            .map { [weak self] in "\(self?.accountSignature($0) ?? "")|\($0.connectHabitica)" }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.pomodoroTaskId = nil
                self.pomodoroSetTaskId = nil
                self.taskAccountSignature = ""
                self.habiticaMonies = 0
                self.habiticaExp = 0
                self.habiticaHp = 0
                self.habiticaConnected = false
                self.api.monies = 0
                self.api.exp = 0
                self.api.hp = 0
                self.api.isAuthenticated = false
                self.api.lastError = nil
            }
        NotificationCenter.default.addObserver(forName: .histogramChanged, object: nil, queue: .main) { [weak self] _ in
            self?.loadTodayCount()
        }
    }

    func activate() {
        if isFrozen { unfreeze() }
        else if phase == .manualBreak { startBreak() }
        else if !isRunning || phase == .breakTime || phase == .breakExtension { startPomodoro() }
        else { pomodoroInterrupted(breakStreak: true) }
    }

    func togglePomodoro() {
        if isFrozen { unfreeze() }
        else if isRunning && phase == .pomodoro { freeze() }
        else { activate() }
        notifyBadge()
    }

    func startPomodoro() {
        startPomodoro(task: nil)
    }

    @discardableResult
    func startPomodoro(taskId: UUID, category: Int, dateKey: String) -> Bool {
        guard phase != .pomodoro, foregroundRecovery == nil else { return false }
        let manager = TopThreeManager.shared
        guard manager.isEditable(key: dateKey, settings: settings),
              let task = manager.getTasks(key: dateKey, category: category)
                .first(where: { $0.id == taskId && $0.isUnfinished }) else { return false }
        startPomodoro(task: task)
        return true
    }

    private func startPomodoro(task: TopThreeTask?) {
        guard phase != .pomodoro else { return }
        #if os(iOS)
        requestNotificationPermissionIfNeeded()
        #endif
        if completedSet { pomoSetCounter = 0 }
        completedSet = false
        customBreak = false
        let configuration = phaseSnapshot(settings)
        focusDirectory = PomodoroDataDir.resolvedURL.standardizedFileURL.path
        activePomodoroSettings = configuration
        activeBreakSettings = nil
        activeBreakExtensionSettings = nil
        taskFocus = task.map {
            TaskFocusSession(id: UUID(), taskId: $0.id, title: $0.title,
                             minutes: configuration.pomoDurationMins,
                             startedAt: Int64(Date().timeIntervalSince1970 * 1000))
        }
        beginPhase(.pomodoro, duration: configuration.pomoDurationMins * 60, end: focusEndHandler)
        audioManager.playAmbientFor(settings: configuration, newSession: true)
    }

    private var focusEndHandler: (Date) -> Void {
        { [weak self] date in self?.completePomodoro(at: date) }
    }

    /// Called once after the app has selected and loaded its data directory.
    func restoreFocusAfterLaunch(now: Date = Date()) {
        guard !attemptedFocusRestore else { return }
        attemptedFocusRestore = true
        guard phase == .idle,
              let url = FocusCheckpoint.location,
              let bytes = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(FocusCheckpoint.self, from: bytes),
              checkpoint.directory == PomodoroDataDir.resolvedURL.standardizedFileURL.path,
              (1...120).contains(checkpoint.settings.pomoDurationMins),
              (1...checkpoint.settings.pomoDurationMins * 60).contains(checkpoint.secondsRemaining),
              (0...12).contains(checkpoint.combo) else { return }

        savedFocusURL = url
        var configuration = phaseSnapshot(checkpoint.settings)
        let deadline = checkpoint.deadline.map { min($0, now.addingTimeInterval(TimeInterval(checkpoint.secondsRemaining))) }
        let isExpired = deadline.map { $0 <= now } ?? false
        if isExpired && !retireActiveFocus() {
            savedFocusURL = nil
            focusRecoveryWarning = "暂时无法清除计时恢复记录，请重新打开应用重试"
            return
        }
        focusDirectory = checkpoint.directory
        // A cold recovery can settle local history. The previous process may already have
        // delivered its local alert, and unattended time never replays Habitica writes.
        if isExpired { configuration.connectHabitica = false }
        activePomodoroSettings = configuration
        taskFocus = checkpoint.task
        pomoSetCounter = checkpoint.combo
        phase = .pomodoro
        isRunning = true
        isFrozen = deadline == nil
        phaseDuration = configuration.pomoDurationMins * 60
        timerValue = deadline.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } ?? checkpoint.secondsRemaining
        timerString = formatTime(timerValue)
        endHandler = focusEndHandler
        phaseEndsAt = deadline
        lastTickAt = now

        if isExpired {
            catchingUpRestoredFocus = true
            catchUpElapsedPhases(at: now)
            catchingUpRestoredFocus = false
        } else if let deadline {
            if deadline != checkpoint.deadline { saveFocusCheckpoint(deadline: deadline, secondsRemaining: timerValue) }
            schedulePhaseTimer()
            audioManager.playAmbientFor(settings: configuration, newSession: true)
        }
        updateTomato()
        notifyBadge()
    }

    @discardableResult
    private func saveFocusCheckpoint(deadline: Date?, secondsRemaining: Int) -> Bool {
        guard let directory = focusDirectory, let configuration = activePomodoroSettings else { return true }
        guard let url = savedFocusURL ?? FocusCheckpoint.location else {
            focusRecoveryWarning = "暂时无法保存计时恢复记录"
            return true
        }
        let checkpoint = FocusCheckpoint(directory: directory, deadline: deadline,
                                         secondsRemaining: max(1, secondsRemaining), combo: pomoSetCounter,
                                         task: taskFocus, settings: configuration)
        do {
            try checkpoint.save(to: url)
            savedFocusURL = url
            focusRecoveryWarning = nil
            return true
        } catch {
            focusRecoveryWarning = "暂时无法保存计时恢复记录"
            // A failed transition must not leave a previously saved running timer
            // on disk while memory claims it is paused, or the reverse.
            return savedFocusURL == nil
        }
    }

    /// Retire the checkpoint before updating history or scoring. Recovery after
    /// a process exit in the middle of settlement can therefore never repeat it.
    private func retireActiveFocus() -> Bool {
        if let url = savedFocusURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already absent.
            } catch {
                focusRecoveryWarning = "暂时无法清除计时恢复记录，请重试"
                return false
            }
        }
        savedFocusURL = nil
        focusDirectory = nil
        focusRecoveryWarning = nil
        return true
    }

    /// Compatibility entry point; duplicate callbacks after a transition cannot count twice.
    func pomodoroEnds() async {
        await MainActor.run { self.completePomodoro(at: self.phaseEndsAt ?? Date()) }
    }

    private func completePomodoro(at date: Date) {
        guard foregroundRecovery == nil, phase == .pomodoro, !isFrozen,
              let configuration = activePomodoroSettings else { return }
        guard focusUsesCurrentDirectory else {
            pauseTimer()
            focusRecoveryWarning = "请切回原数据目录后继续本次专注"
            return
        }
        guard retireActiveFocus() else { return }
        let session = taskFocus
        activePomodoroSettings = nil
        stopTimer()
        audioManager.stopAmbient()
        histogramManager.incrementToday(pomodoros: 1, minutes: configuration.pomoDurationMins, date: date, taskSession: session)
        loadTodayCount()
        pomoSetCounter += 1
        completedSet = pomoSetCounter >= configuration.pomoSetNum
        pendingBreakSeconds = (completedSet ? configuration.longBreakDuration : configuration.breakDuration) * 60
        activeBreakSettings = configuration
        var message = "Pomodoro ended.\nYou have done \(todayPomodoros) today!"
        var rewardBlock: Int?
        var rewardGoal = ""
        if configuration.enableBlockMode {
            let manager = BlockProgressManager.shared
            manager.recordPomoInCurrentBlock(settings: configuration, comboCompleted: completedSet, date: date)
            let index = manager.blockProgress.currentBlockIndex
            let progress = manager.progress(settings: configuration, date: date)
            let count = progress.indices.contains(index) ? progress[index] : 0
            rewardGoal = manager.blockProgress.getBlockGoal(goals: configuration.blockGoals)
            if count >= configuration.blockPomoCount && manager.recordBlockComplete(settings: configuration, date: date) {
                rewardBlock = index
                message = "Block \(index + 1) Complete! 🎉\nGoal: \(rewardGoal)\n\(BlockRewardManager.shared.suggestBreakType(settings: configuration, blockIndex: index))"
            } else {
                message = "Pomodoro ended.\nCurrent Block (\(index + 1)): \(count)/\(configuration.blockPomoCount)\nGoal: \(rewardGoal)"
            }
            if !catchingUpRestoredFocus {
                BlockNotificationManager.shared.checkReminders(settings: configuration)
            }
        }
        if !catchingUpRestoredFocus {
            sendNotification(title: completedSet ? "Pomodoro Set Complete!" : "Time's Up", body: message)
            audioManager.playSound(configuration.pomoEndSound, volume: configuration.pomoEndSoundVolume)
        }
        let setComplete = completedSet
        // Advance before awaiting anything: offline/slow scoring must never delay the break or resurrect a reset.
        if configuration.manualBreak { manualBreak() }
        else { startBreak(at: date) }
        Task {
            guard var requestSettings = self.phaseRequestSettings(configuration) else { return }
            let signature = self.accountSignature(configuration)
            let pomoId = signature == self.taskAccountSignature ? self.pomodoroTaskId : nil
            let setId = signature == self.taskAccountSignature ? self.pomodoroSetTaskId : nil
            let needsPomo = configuration.pomoHabitPlus || (rewardBlock != nil && configuration.blockRewardEnabled)
            var resolvedPomo: String? = pomoId
            if needsPomo && resolvedPomo == nil { resolvedPomo = await self.api.ensurePomodoroHabit(settings: requestSettings) }
            if configuration.pomoHabitPlus, let id = resolvedPomo {
                guard let refreshed = self.phaseRequestSettings(configuration) else { return }
                requestSettings = refreshed
                _ = await self.api.scoreHabit(taskId: id, direction: "up", settings: requestSettings)
            }
            if setComplete && configuration.pomoSetHabitPlus {
                guard let refreshed = self.phaseRequestSettings(configuration) else { return }
                requestSettings = refreshed
                var resolved = setId
                if resolved == nil { resolved = await self.api.ensurePomodoroSetHabit(settings: requestSettings) }
                if let id = resolved, let refreshed = self.phaseRequestSettings(configuration) {
                    _ = await self.api.scoreHabit(taskId: id, direction: "up", settings: refreshed)
                }
            }
            if let index = rewardBlock, let refreshed = self.phaseRequestSettings(configuration) {
                await BlockRewardManager.shared.sendBlockReward(settings: refreshed, blockIndex: index, blockGoal: rewardGoal, habitId: resolvedPomo)
            }
            await self.refreshHabitica()
        }
    }

    private func startBreak() { startBreak(at: Date()) }
    private func startBreak(at date: Date) {
        let configuration = activeBreakSettings ?? phaseSnapshot(settings)
        activeBreakSettings = configuration
        activeBreakExtensionSettings = nil
        audioManager.stopAmbient()
        let duration = pendingBreakSeconds > 0 ? pendingBreakSeconds : (completedSet ? configuration.longBreakDuration : configuration.breakDuration) * 60
        beginPhase(.breakTime, duration: duration, startingAt: date) { [weak self] date in
            self?.finishBreak(at: date)
        }
    }

    private func manualBreak() {
        stopTimer()
        phase = .manualBreak
        timerString = "GOOD!"
        updateTomato()
        notifyBadge()
    }

    func breakEnds() { finishBreak(at: phaseEndsAt ?? Date()) }
    private func finishBreak(at date: Date) {
        guard foregroundRecovery == nil, phase == .breakTime else { return }
        let isLong = completedSet || customBreak
        let breakConfiguration = activeBreakSettings ?? phaseSnapshot(settings)
        activeBreakSettings = nil
        stopTimer()
        if isLong {
            if completedSet { pomoSetCounter = 0 }
            completedSet = false
            customBreak = false
            pendingBreakSeconds = 0
            if breakConfiguration.longBreakNotify {
                Task {
                    guard let configuration = self.phaseRequestSettings(breakConfiguration) else { return }
                    await api.sendPrivateMessage("Long Break is over", settings: configuration)
                }
            }
        } else {
            // Remind once at short-break completion, including zero grace. Not at grace startup.
            if breakConfiguration.breakExtentionNotify {
                let minutes = breakConfiguration.breakExtention
                Task {
                    guard let configuration = self.phaseRequestSettings(breakConfiguration) else { return }
                    let message = minutes > 0 ? "Back to work! \(minutes) minutes left for Break Extension." : "Back to work!"
                    await api.sendPrivateMessage(message, settings: configuration)
                }
            }
            if breakConfiguration.breakExtention > 0 {
                startBreakExtension(duration: breakConfiguration.breakExtention * 60, at: date, configuration: breakConfiguration)
            } else {
                // No grace countdown and no failure: preserve the earned combo.
                timerString = "GO!"
                pendingBreakSeconds = 0
            }
        }
        if !catchingUpRestoredFocus {
            sendNotification(title: "Time's Up", body: isLong ? "Break is over" : "Back to work")
            audioManager.playSound(breakConfiguration.breakEndSound, volume: breakConfiguration.breakEndSoundVolume)
        }
        updateTomato()
        notifyBadge()
    }

    func startBreakExtension(duration: Int) {
        guard phase != .pomodoro else { return }
        startBreakExtension(duration: duration, at: Date(), configuration: phaseSnapshot(settings))
    }
    private func startBreakExtension(duration: Int, at date: Date, configuration: UserSettings) {
        guard duration > 0 else {
            activeBreakExtensionSettings = nil
            stopTimer()
            timerString = "GO!"
            return
        }
        activeBreakExtensionSettings = configuration
        pendingBreakSeconds = 0
        beginPhase(.breakExtension, duration: duration, startingAt: date) { [weak self] _ in
            guard let self = self else { return }
            self.pomodoroInterrupted(breakStreak: configuration.resetPomoAfterBreak)
        }

    }

    func pomodoroInterrupted(breakStreak: Bool) {
        let interruptedFocus = phase == .pomodoro
        guard interruptedFocus || phase == .breakExtension else { return }
        let sameDirectory = !interruptedFocus || focusUsesCurrentDirectory
        if interruptedFocus && !retireActiveFocus() { return }
        let configuration = (interruptedFocus ? activePomodoroSettings : activeBreakExtensionSettings) ?? phaseSnapshot(settings)
        let failedExtension = phase == .breakExtension && configuration.breakExtentionFails
        if interruptedFocus && sameDirectory && configuration.enableBlockMode {
            BlockProgressManager.shared.recordAbandonedPomo(settings: configuration)
        }
        activePomodoroSettings = nil
        activeBreakSettings = nil
        activeBreakExtensionSettings = nil
        audioManager.stopAmbient()
        stopTimer()
        pendingBreakSeconds = 0
        if breakStreak { pomoSetCounter = 0; completedSet = false }
        else { timerString = "GO!" }
        if (interruptedFocus && sameDirectory && configuration.pomoHabitMinus) || failedExtension {
            Task {
                guard let requestSettings = self.phaseRequestSettings(configuration) else { return }
                if let id = await api.ensurePomodoroHabit(settings: requestSettings),
                   let refreshed = self.phaseRequestSettings(configuration) {
                    _ = await api.scoreHabit(taskId: id, direction: "down", settings: refreshed)
                    await refreshHabitica()
                }
            }
        }
        updateTomato()
        notifyBadge()
    }

    func freeze() {
        guard isRunning, !isFrozen, phaseEndsAt != nil else { return }
        let revision = phaseRevision
        tick(at: Date())
        guard revision == phaseRevision, isRunning, phaseEndsAt != nil else { return }
        pauseTimer()
    }

    private func pauseTimer() {
        if phase == .pomodoro && !saveFocusCheckpoint(deadline: nil, secondsRemaining: timerValue) { return }
        phaseRevision += 1
        timer?.invalidate()
        timer = nil
        phaseEndsAt = nil
        isFrozen = true
        audioManager.pauseAmbient()
        #if os(iOS)
        cancelBackgroundEndNotification()
        #endif
        updateTomato()
        notifyBadge()
    }

    func unfreeze() {
        guard isFrozen, let handler = endHandler else { return }
        if phase == .pomodoro && !focusUsesCurrentDirectory {
            focusRecoveryWarning = "请切回原数据目录后继续本次专注"
            return
        }
        // Preserve the handler belonging to the paused phase; a break must never complete a pomodoro.
        guard beginPhase(phase, duration: phaseDuration, remaining: max(1, timerValue), end: handler) else { return }
        if phase == .pomodoro, let configuration = activePomodoroSettings {
            audioManager.playAmbientFor(settings: configuration, newSession: false)
        }
    }

    func skipToBreak() {
        guard phase == .pomodoro else { return }
        let sameDirectory = focusUsesCurrentDirectory
        guard retireActiveFocus() else { return }
        let skippedConfiguration = activePomodoroSettings ?? phaseSnapshot(settings)
        if sameDirectory && skippedConfiguration.enableBlockMode {
            BlockProgressManager.shared.recordAbandonedPomo(settings: skippedConfiguration)
        }
        activePomodoroSettings = nil
        audioManager.stopAmbient()
        pomoSetCounter = 0
        completedSet = false
        customBreak = false
        pendingBreakSeconds = skippedConfiguration.breakDuration * 60
        activeBreakSettings = sameDirectory ? skippedConfiguration : phaseSnapshot(settings)
        startBreak()
        sendNotification(title: "Time's Up", body: "Take a break")
    }

    /// Idle-only custom breaks do not fabricate a completed set or clear earned combo progress.
    func takeBreak(duration: Int) {
        guard phase == .idle, !isRunning, !isFrozen, duration > 0 else { return }
        #if os(iOS)
        requestNotificationPermissionIfNeeded()
        #endif
        customBreak = true
        pendingBreakSeconds = duration * 60
        activeBreakSettings = phaseSnapshot(settings)
        startBreak()
    }

    func reset() {
        if phase == .pomodoro && !retireActiveFocus() { return }
        audioManager.stopAmbient()
        stopTimer()
        activePomodoroSettings = nil
        activeBreakSettings = nil
        activeBreakExtensionSettings = nil
        pomoSetCounter = 0
        completedSet = false
        customBreak = false
        pendingBreakSeconds = 0
        notifyBadge()
    }

    @discardableResult
    private func beginPhase(_ next: TimerPhase, duration: Int, remaining: Int? = nil,
                            startingAt date: Date = Date(), end: @escaping (Date) -> Void) -> Bool {
        let total = max(1, duration)
        let seconds = remaining ?? total
        let deadline = date.addingTimeInterval(TimeInterval(seconds))
        if next == .pomodoro && !saveFocusCheckpoint(deadline: deadline, secondsRemaining: seconds) { return false }
        phaseRevision += 1
        timer?.invalidate()
        timer = nil
        if next != .pomodoro { taskFocus = nil }
        phase = next
        isRunning = true
        isFrozen = false
        phaseDuration = total
        timerValue = seconds
        timerString = formatTime(timerValue)
        endHandler = end
        phaseEndsAt = deadline
        lastTickAt = date
        schedulePhaseTimer()
        updateTomato()
        notifyBadge()
        return true
    }

    private func schedulePhaseTimer() {
        #if os(iOS)
        if let phaseEndsAt, phaseEndsAt > Date() {
            scheduleBackgroundEndNotification(after: phaseEndsAt.timeIntervalSinceNow)
        }
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick(at: Date()) }
    }

    private func tick(at date: Date) {
        guard isRunning, !isFrozen, let deadline = phaseEndsAt else { return }
        let raw = Int(ceil(deadline.timeIntervalSince(date)))
        if (lastTickAt.map { date < $0 } ?? false) || raw > phaseDuration {
            // Any observed wall-clock rollback rebases to the already displayed remaining time.
            // Checking only the configured duration would still permit smaller rollbacks to add time.
            let rebased = date.addingTimeInterval(TimeInterval(timerValue))
            if phase == .pomodoro && !saveFocusCheckpoint(deadline: rebased, secondsRemaining: timerValue) { return }
            phaseEndsAt = rebased
            lastTickAt = date
            #if os(iOS)
            scheduleBackgroundEndNotification(after: TimeInterval(timerValue))
            #endif
            return
        }
        lastTickAt = date
        timerValue = max(0, raw)
        timerString = formatTime(timerValue)
        if timerValue == 0 {
            // Keep displaying elapsed time, but even a real scheduled Timer may not
            // settle against stale stores while foreground reads own recovery.
            guard foregroundRecovery == nil else { updateTomato(); notifyBadge(); return }
            endHandler?(deadline)
        } else if phase == .pomodoro, let configuration = activePomodoroSettings {
            audioManager.playAmbientFor(settings: configuration, newSession: false)
        }
        updateTomato()
        notifyBadge()
    }

    /// One foreground boundary for both platforms: accept the asynchronous snapshot
    /// before any elapsed phase can write. Production samples the clock at completion;
    /// an explicit `now` is only a deterministic caller clock (used by CLI fixtures).
    func resyncAfterForeground(chain: Int = 0, now: Date? = nil, completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.resyncAfterForeground(chain: chain, now: now, completion: completion) }
            return
        }
        let monitor = PomodoroFileChanges.shared
        let directory = monitor.directoryIdentity()
        let phaseRevision = self.phaseRevision
        let recovery = UUID()
        foregroundRecovery = recovery
        monitor.syncFromDiskIfNeeded { [weak self] in
            defer { completion?() }
            guard let self = self, self.foregroundRecovery == recovery else { return }
            let samePhase = self.phaseRevision == phaseRevision
            let sameDirectory = monitor.directoryIdentity() == directory
            if samePhase && !sameDirectory {
                // Never let the next scheduled tick settle the old folder's elapsed
                // phase into the new folder. Resume is available in the original folder.
                self.freeze()
            }
            self.foregroundRecovery = nil
            guard samePhase, sameDirectory else { return }
            self.catchUpElapsedPhases(at: now ?? Date())
        }
    }

    /// Catch up elapsed work → break → grace, never invent unattended focus sessions.
    private func catchUpElapsedPhases(at now: Date) {
        for _ in 0..<6 {
            guard isRunning, !isFrozen, let deadline = phaseEndsAt else { break }
            tick(at: now)
            if deadline > now || phaseEndsAt == deadline { break }
        }
        loadTodayCount()
    }

    private func stopTimer() {
        phaseRevision += 1
        timer?.invalidate()
        timer = nil
        phaseEndsAt = nil
        endHandler = nil
        taskFocus = nil
        lastTickAt = nil
        timerString = "00:00"
        timerValue = 0
        isRunning = false
        phase = .idle
        isFrozen = false
        #if os(iOS)
        cancelBackgroundEndNotification()
        #endif
        updateTomato()
    }

    private func updateTomato() {
        if isFrozen { tomatoState = .freeze }
        else if phase == .breakExtension { tomatoState = .warning }
        else if phase == .manualBreak { tomatoState = .win }
        else if phase == .breakTime { tomatoState = .breakTime }
        else if phase == .pomodoro { tomatoState = .progress }
        else { tomatoState = .wait }
    }
    private var focusUsesCurrentDirectory: Bool {
        focusDirectory == PomodoroDataDir.resolvedURL.standardizedFileURL.path
    }
    private func formatTime(_ seconds: Int) -> String { String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60) }
    private func notifyBadge() { NotificationCenter.default.post(name: .badgeUpdate, object: nil) }
    private func sendNotification(title: String, body: String) {
        lastNotification = "\(title): \(body)"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func accountSignature(_ settings: UserSettings) -> String {
        "\(api.cloudAccount(settings: settings) ?? "")|\(settings.customPomodoroTask)|\(settings.pomodoroTaskId ?? "")|\(settings.customSetTask)|\(settings.pomodoroSetTaskId ?? "")"
    }

    /// Business snapshots retain connection intent and owner/IDs, never credentials.
    private func phaseSnapshot(_ configuration: UserSettings) -> UserSettings {
        var snapshot = configuration
        snapshot.apiToken = ""
        return snapshot
    }

    /// Both captured and current connection intent must allow the same UID/API owner's current key.
    private func phaseRequestSettings(_ phaseSettings: UserSettings) -> UserSettings? {
        let current = settings
        guard phaseSettings.connectHabitica, current.connectHabitica, !current.apiToken.isEmpty,
              let owner = api.cloudAccount(settings: phaseSettings), owner == api.cloudAccount(settings: current) else { return nil }
        var request = phaseSettings
        request.apiToken = current.apiToken
        request.developerServerUrl = current.developerServerUrl
        return request
    }
    func initHabiticaTasks() async {
        let configuration = settings
        let signature = accountSignature(configuration)
        guard configuration.connectHabitica, !configuration.uid.isEmpty, !configuration.apiToken.isEmpty else {
            await MainActor.run { self.habiticaConnected = false }
            return
        }
        await api.fetchUserData(settings: configuration)
        let pomo = await api.ensurePomodoroHabit(settings: configuration)
        let combo = await api.ensurePomodoroSetHabit(settings: configuration)
        await MainActor.run {
            guard self.accountSignature(self.settings) == signature else { return }
            self.pomodoroTaskId = pomo
            self.pomodoroSetTaskId = combo
            self.taskAccountSignature = signature
            self.updateHabiticaState()
        }
    }
    func refreshHabitica() async {
        let configuration = settings
        let signature = accountSignature(configuration)
        await api.fetchUserData(settings: configuration)
        await MainActor.run {
            guard self.accountSignature(self.settings) == signature else { return }
            self.updateHabiticaState()
        }
    }
    private func updateHabiticaState() {
        habiticaMonies = api.monies
        habiticaExp = api.exp
        habiticaHp = api.hp
        habiticaConnected = api.isAuthenticated
    }
    func loadTodayCount() {
        let today = histogramManager.getToday()
        todayPomodoros = today?.pomodoros ?? 0
        todayFocusMinutes = today?.minutes ?? 0
    }

    #if os(iOS)
    private static var permissionRequested = false
    private func requestNotificationPermissionIfNeeded() {
        guard !Self.permissionRequested else { return }
        Self.permissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    BlockNotificationManager.shared.startReminderTimer(settings: SettingsManager.shared.settings)
                }
            }
        }
    }
    private func scheduleBackgroundEndNotification(after interval: TimeInterval) {
        cancelBackgroundEndNotification()
        let content = UNMutableNotificationContent()
        content.title = "Time's Up"
        content.body = phase == .pomodoro ? "番茄钟结束，休息一下 🍅" : "休息结束，回到工作"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.backgroundEndNotificationId, content: content, trigger: trigger))
    }
    private func cancelBackgroundEndNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.backgroundEndNotificationId])
    }
    #endif
}
