#if DEBUG
import SwiftUI

/// DEBUG-only (`-previewWidgets`): renders the Live Activity and home-screen widget views
/// in-process, since simctl cannot add widgets or lock the simulator.
struct WidgetPreviewGallery: View {
    var body: some View {
        if #available(iOS 16.2, *) {
            WidgetPreviewGalleryContent()
        }
    }
}

@available(iOS 16.2, *)
private struct WidgetPreviewGalleryContent: View {
    private typealias State = PomodoroActivityAttributes.ContentState
    @Environment(\.appTheme) private var theme
    private var accent: Color { theme.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if ProcessInfo.processInfo.arguments.contains("-previewWidgetsHome") {
                    homeWidgets
                } else {
                    activities
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private var activities: some View {
        let now = Date()
        let focus = State(phase: .focus, endsAt: now.addingTimeInterval(18 * 60 + 42), duration: 25 * 60,
                          pausedRemaining: nil, blockLabel: "B2 · 写论文第三节", comboDone: 1, comboTotal: 4)
        var paused = focus
        paused.pausedRemaining = 9 * 60 + 5
        let longBreak = State(phase: .longBreak, endsAt: now.addingTimeInterval(12 * 60), duration: 15 * 60,
                              pausedRemaining: nil, blockLabel: nil, comboDone: 4, comboTotal: 4)
        let waiting = State(phase: .awaitingBreak, endsAt: now, duration: 1, pausedRemaining: nil,
                            blockLabel: "B2 · 写论文第三节", comboDone: 2, comboTotal: 4)
        return VStack(alignment: .leading, spacing: 14) {
            caption("锁屏 · 专注中 / 已暂停 / 长休息 / 等待休息 / 已过期")
            lockScreen(focus)
            lockScreen(paused)
            lockScreen(longBreak)
            lockScreen(waiting)
            lockScreen(focus, stale: true)
            caption("灵动岛 · 展开 / 紧凑 / 最小")
            island(focus)
            island(paused)
            HStack(spacing: 14) {
                compact(focus)
                compact(paused)
                PomodoroIslandParts.minimal(focus, accent: accent)
                    .frame(width: 26, height: 26)
                    .padding(5)
                    .background(Circle().fill(Color.black))
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private var homeWidgets: some View {
        let snapshot = TodayTasksSnapshot(
            dayKey: TodayTasksSnapshot.logicalDayKey(boundaryMinutes: 0), boundaryMinutes: 0,
            categories: [
                .init(id: 0, name: "Work", done: 2, total: 3, openTitles: ["整理周报"]),
                .init(id: 1, name: "MyOwn", done: 1, total: 3, openTitles: ["读完第 4 章"]),
                .init(id: 2, name: "Chores", done: 4, total: 4, openTitles: []),
            ], accentRGB: SkinAccentBridge.rgb(of: theme.accent))
        let live = TodayTasksWidgetState.current()
        return VStack(alignment: .leading, spacing: 14) {
            caption("主屏 · 本机快照：\(describe(live))")
            HStack(spacing: 14) {
                widget(live, compact: true)
                widget(.ready(snapshot), compact: true)
            }
            widget(live, compact: false)
            widget(.ready(snapshot), compact: false)
            caption("占位 · 无 App Group / 未同步 / 过期")
            HStack(spacing: 14) {
                widget(.noSharedContainer, compact: true)
                widget(.stale(snapshot), compact: true)
            }
            widget(.noSharedContainer, compact: false)
            widget(.notSynced, compact: false)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func lockScreen(_ state: State, stale: Bool = false) -> some View {
        PomodoroLockScreenView(state: state, accent: accent, isStale: stale)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.thinMaterial))
    }

    private func island(_ state: State) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                PomodoroIslandParts.leading(state, accent: accent)
                Spacer()
                PomodoroIslandParts.trailing(state, isStale: false)
            }
            PomodoroIslandParts.center(state)
            PomodoroIslandParts.bottom(state, accent: accent)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Color.black))
        .environment(\.colorScheme, .dark)
    }

    private func compact(_ state: State) -> some View {
        HStack(spacing: 70) {
            PomodoroIslandParts.compactLeading(state, accent: accent)
            PomodoroIslandParts.compactTrailing(state, accent: accent, isStale: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Capsule().fill(Color.black))
    }

    private func widget(_ state: TodayTasksWidgetState, compact: Bool) -> some View {
        TodayTasksWidgetContent(state: state, compact: compact)
            .padding(16)
            .frame(width: compact ? 170 : 360, height: 170)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .systemBackground)))
    }

    private func describe(_ state: TodayTasksWidgetState) -> String {
        switch state {
        case .ready: return "今天"
        case .stale: return "过期"
        case .notSynced: return "未写入"
        case .noSharedContainer: return "无 App Group"
        }
    }
}
#endif
