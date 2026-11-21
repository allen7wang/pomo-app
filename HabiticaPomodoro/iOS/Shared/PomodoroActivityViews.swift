import SwiftUI

// Live Activity presentations. They take plain values (not ActivityViewContext) so the
// extension renders them and DEBUG builds of the app can preview them in-process.

extension Color {
    /// Runtime colour handed over from the app's skin; nil keeps the system tint.
    init(pomodoroRGB: UInt32?) {
        guard let rgb = pomodoroRGB else { self = .accentColor; return }
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

@available(iOS 16.1, *)
struct PomodoroCountdownText: View {
    let state: PomodoroActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        if let remaining = state.pausedRemaining {
            Text(PomodoroActivityAttributes.ContentState.clock(remaining))
        } else if !state.hasCountdown || isStale {
            Text("00:00")
        } else {
            Text(timerInterval: state.timerRange, countsDown: true)
        }
    }
}

@available(iOS 16.1, *)
struct PomodoroProgressBar: View {
    let state: PomodoroActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        Group {
            if state.isPaused {
                ProgressView(value: state.pausedProgress)
            } else if state.hasCountdown {
                ProgressView(timerInterval: state.timerRange, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: 1)
            }
        }
        .progressViewStyle(.linear)
        .tint(accent)
    }
}

@available(iOS 16.1, *)
struct PomodoroProgressRing: View {
    let state: PomodoroActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        Group {
            if state.isPaused {
                ProgressView(value: state.pausedProgress) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: "pause.fill")
                }
            } else if state.hasCountdown {
                ProgressView(timerInterval: state.timerRange, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: state.symbol)
                }
            } else {
                ProgressView(value: 1) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: state.symbol)
                }
            }
        }
        .progressViewStyle(.circular)
        .tint(accent)
        .foregroundColor(accent)
    }
}

/// Lock screen / banner presentation.
@available(iOS 16.1, *)
struct PomodoroLockScreenView: View {
    let state: PomodoroActivityAttributes.ContentState
    let accent: Color
    var isStale = false

    private var subtitle: String {
        if state.phase == .awaitingBreak { return "打开应用开始休息" }
        if isStale && !state.isPaused { return "时间到 · 打开应用继续" }
        return state.blockLabel ?? "Habitica Pomodoro"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: state.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(accent.opacity(0.18)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(state.title)
                            .font(.system(size: 16, weight: .semibold))
                        if state.isPaused {
                            Text("已暂停")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.2)))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(state.comboText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                PomodoroCountdownText(state: state, isStale: isStale)
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120, alignment: .trailing)
                    .foregroundColor(state.isPaused ? .secondary : .primary)
            }
            PomodoroProgressBar(state: state, accent: accent)
        }
        .padding(16)
    }
}

/// Dynamic Island regions, shared so DEBUG builds can lay them out without WidgetKit.
@available(iOS 16.1, *)
enum PomodoroIslandParts {
    static func leading(_ state: PomodoroActivityAttributes.ContentState, accent: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbol).foregroundColor(accent)
            Text(state.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        }
        .padding(.leading, 4)
    }

    static func trailing(_ state: PomodoroActivityAttributes.ContentState, isStale: Bool) -> some View {
        PomodoroCountdownText(state: state, isStale: isStale)
            .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 96, alignment: .trailing)
            .foregroundColor(state.isPaused ? .secondary : .primary)
            .padding(.trailing, 4)
    }

    static func center(_ state: PomodoroActivityAttributes.ContentState) -> some View {
        Text(state.blockLabel ?? (state.isPaused ? "已暂停" : " "))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    static func bottom(_ state: PomodoroActivityAttributes.ContentState, accent: Color) -> some View {
        VStack(spacing: 6) {
            PomodoroProgressBar(state: state, accent: accent)
            HStack {
                Text(state.comboText)
                Spacer()
                if state.isPaused { Label("已暂停", systemImage: "pause.fill") }
                else if state.phase == .awaitingBreak { Text("打开应用开始休息") }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    static func compactLeading(_ state: PomodoroActivityAttributes.ContentState, accent: Color) -> some View {
        Image(systemName: state.isPaused ? "pause.fill" : state.symbol)
            .foregroundColor(accent)
    }

    static func compactTrailing(_ state: PomodoroActivityAttributes.ContentState, accent: Color, isStale: Bool) -> some View {
        PomodoroCountdownText(state: state, isStale: isStale)
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 46, alignment: .trailing)
            .foregroundColor(state.isPaused ? .secondary : accent)
    }

    static func minimal(_ state: PomodoroActivityAttributes.ContentState, accent: Color) -> some View {
        PomodoroProgressRing(state: state, accent: accent)
    }
}
