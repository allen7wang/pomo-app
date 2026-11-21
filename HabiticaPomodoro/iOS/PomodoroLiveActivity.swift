import SwiftUI
import Combine
import ActivityKit
import UIKit

/// Device-only preference; deliberately not part of the synced settings JSON.
enum LiveActivityPreference {
    static let key = "ios.liveActivity.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// The current skin accent, reported by the themed view tree (the extension cannot
/// read the app's theme) and copied into the Live Activity and widget snapshot.
final class SkinAccentBridge {
    static let shared = SkinAccentBridge()
    @Published private(set) var rgb: UInt32?

    func report(_ color: Color) {
        guard let value = Self.rgb(of: color), value != rgb else { return }
        rgb = value
    }

    static func rgb(of color: Color) -> UInt32? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }
}

/// Invisible view that forwards `theme.accent` to `SkinAccentBridge`.
struct SkinAccentReporter: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { SkinAccentBridge.shared.report(theme.accent) }
            .onChange(of: theme.accent) { SkinAccentBridge.shared.report($0) }
    }
}

/// Mirrors `PomodoroEngine` into a Live Activity without the engine knowing about it.
/// The engine provides the phase, deadline and break kind. Preserve the full duration through pauses.
@available(iOS 16.2, *)
@MainActor
final class PomodoroLiveActivity {
    static let shared = PomodoroLiveActivity()
    typealias State = PomodoroActivityAttributes.ContentState

    private let engine = PomodoroEngine.shared
    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity<PomodoroActivityAttributes>?
    private var pushed: State?
    private var operations: Task<Void, Never>?

    private struct Track {
        let phase: TimerPhase
        let kind: State.Phase
        let duration: Int
        var lastRemaining: Int
    }
    private var track: Track?
    /// Phase for which no activity should be requested (dismissed, or the request failed).
    private var suppressedPhase: State.Phase?

    func start() {
        guard cancellables.isEmpty else { return }
        // The engine never restores a running phase across launches, so anything left
        // over from a previous process is stale.
        let leftovers = Activity<PomodoroActivityAttributes>.activities
        enqueue {
            for activity in leftovers { await activity.end(nil, dismissalPolicy: .immediate) }
        }

        Publishers.MergeMany(
            engine.objectWillChange.eraseToAnyPublisher(),
            BlockProgressManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SettingsManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SkinAccentBridge.shared.$rgb.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        // objectWillChange fires before the mutation and in bursts; read the settled state.
        .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
        .sink { [weak self] in self?.sync() }
        .store(in: &cancellables)

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-previewStartFocus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { PomodoroEngine.shared.startPomodoro() }
        }
        #endif
    }

    /// Called by the settings toggle.
    func preferenceChanged() {
        if !LiveActivityPreference.isEnabled { endActivity() }
        sync(forceStart: true)
    }

    // MARK: Engine → state

    private func sync(forceStart: Bool = false) {
        let desired = desiredState()
        guard let desired, LiveActivityPreference.isEnabled,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            endActivity()
            suppressedPhase = nil
            return
        }
        if forceStart || suppressedPhase != desired.phase { suppressedPhase = nil }
        if let activity, activity.activityState != .active {
            // Dismissed by the user or the system: do not resurrect it until the phase changes.
            self.activity = nil
            pushed = nil
            suppressedPhase = desired.phase
        }
        if activity == nil {
            if suppressedPhase == nil { request(desired) }
        } else if needsUpdate(from: pushed, to: desired) {
            update(desired)
        }
    }

    private func desiredState() -> State? {
        let settings = SettingsManager.shared.settings
        let combo = (engine.pomoSetCounter, max(1, settings.pomoSetNum))
        let block = blockLabel(settings)

        if engine.phase == .manualBreak {
            track = nil
            return State(phase: .awaitingBreak, endsAt: Date(), duration: 1, pausedRemaining: nil,
                         blockLabel: block, comboDone: combo.0, comboTotal: combo.1)
        }
        guard engine.phase == .pomodoro || engine.phase == .breakTime || engine.phase == .breakExtension,
              engine.isRunning || engine.isFrozen else {
            track = nil
            return nil
        }

        let remaining = max(0, engine.timerValue)
        let kind = kind(for: engine.phase)
        if var current = track, current.phase == engine.phase, current.kind == kind,
           remaining <= current.lastRemaining + 2 {
            current.lastRemaining = remaining
            track = current
        } else {
            track = Track(phase: engine.phase, kind: kind,
                          duration: max(1, engine.phaseDuration), lastRemaining: remaining)
        }
        guard let track else { return nil }

        let duration = max(track.duration, remaining, 1)
        if engine.isFrozen {
            return State(phase: track.kind, endsAt: Date().addingTimeInterval(TimeInterval(remaining)), duration: duration,
                         pausedRemaining: remaining, blockLabel: block, comboDone: combo.0, comboTotal: combo.1)
        }
        let endsAt = engine.phaseEndsAt ?? Date().addingTimeInterval(TimeInterval(remaining))
        return State(phase: track.kind, endsAt: endsAt, duration: duration, pausedRemaining: nil,
                     blockLabel: block, comboDone: combo.0, comboTotal: combo.1)
    }

    private func kind(for phase: TimerPhase) -> State.Phase {
        switch phase {
        case .pomodoro: return .focus
        case .breakExtension: return .breakExtension
        default:
            if engine.customBreak { return .customBreak }
            return engine.completedSet ? .longBreak : .shortBreak
        }
    }

    private func blockLabel(_ settings: UserSettings) -> String? {
        guard settings.enableBlockMode, settings.blockCount > 0 else { return nil }
        let index = min(max(0, BlockProgressManager.shared.blockProgress.currentBlockIndex), settings.blockCount - 1)
        let goal = settings.blockGoals.indices.contains(index)
            ? settings.blockGoals[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return goal.isEmpty ? "时间块 B\(index + 1)" : "B\(index + 1) · \(goal)"
    }

    private func needsUpdate(from old: State?, to new: State) -> Bool {
        guard let old else { return true }
        if old.phase != new.phase || old.pausedRemaining != new.pausedRemaining || old.duration != new.duration
            || old.blockLabel != new.blockLabel || old.comboDone != new.comboDone || old.comboTotal != new.comboTotal {
            return true
        }
        // Running countdowns render themselves; only a moved deadline (resume, rebase) matters.
        return !new.isPaused && new.hasCountdown && abs(old.endsAt.timeIntervalSince(new.endsAt)) > 1.5
    }

    // MARK: ActivityKit

    private func content(_ state: State) -> ActivityContent<State> {
        // Past the deadline while suspended, the extension shows "时间到" until the app catches up.
        let stale = state.hasCountdown && !state.isPaused ? state.endsAt.addingTimeInterval(1) : nil
        return ActivityContent(state: state, staleDate: stale)
    }

    private func request(_ state: State) {
        do {
            activity = try Activity.request(attributes: PomodoroActivityAttributes(accentRGB: SkinAccentBridge.shared.rgb),
                                            content: content(state), pushType: nil)
            pushed = state
        } catch {
            // Not fatal (too many activities, app not frontmost); retry on the next phase.
            activity = nil
            pushed = nil
            suppressedPhase = state.phase
        }
    }

    private func update(_ state: State) {
        guard let activity else { return }
        pushed = state
        let content = content(state)
        enqueue { await activity.update(content) }
    }

    private func endActivity() {
        track = nil
        pushed = nil
        guard let activity else { return }
        self.activity = nil
        enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// ActivityKit calls are async; keep them in order so an end never overtakes an update.
    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = operations
        operations = Task {
            await previous?.value
            await operation()
        }
    }
}

/// Settings rows for the lock-screen activity and the widget data link. Self-contained so
/// MobileSettingsView only needs one line.
struct LiveActivitySettingsSection: View {
    @Environment(\.appTheme) private var theme
    @AppStorage(LiveActivityPreference.key) private var enabled = true

    var body: some View {
        Section {
            Toggle("锁屏实时活动", isOn: $enabled)
                .onChange(of: enabled) { _ in
                    if #available(iOS 16.2, *) { PomodoroLiveActivity.shared.preferenceChanged() }
                }
            Text(activityNote)
                .font(.caption)
                .foregroundColor(theme.muted)
            LabeledContent("主屏「今日任务」小组件") {
                Text(SharedAppGroup.containerURL == nil ? "无法读取数据" : "可用")
                    .foregroundColor(theme.muted)
            }
            if SharedAppGroup.containerURL == nil {
                Text("当前签名没有 App Group，小组件只显示「打开应用同步」。用 Xcode 或 AltStore 重签可启用。")
                    .font(.caption)
                    .foregroundColor(theme.muted)
            }
        } header: {
            Text("锁屏与小组件")
        }
    }

    private var activityNote: String {
        guard #available(iOS 16.2, *) else { return "实时活动需要 iOS 16.2 及以上。" }
        if !ActivityAuthorizationInfo().areActivitiesEnabled {
            return "系统设置中已关闭本应用的实时活动（设置 → Habitica Pomodoro → 实时活动）。"
        }
        return "计时时在锁屏和灵动岛显示阶段、倒计时、时间块与组合进度。"
    }
}
