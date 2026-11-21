import WidgetKit
import SwiftUI
import ActivityKit

// Built by Xcode as a real app-extension target (see project.yml). Hand-wrapped
// executables crash in the WidgetKit bootstrap; see TodayTasksWidget's notes.

@main
struct HabiticaPomodoroWidgets: WidgetBundle {
    var body: some Widget {
        TodayTasksHomeWidget()
        PomodoroLiveActivityWidget()
    }
}

// MARK: - Live Activity (lock screen + Dynamic Island)

struct PomodoroLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomodoroActivityAttributes.self) { context in
            let accent = Color(pomodoroRGB: context.attributes.accentRGB)
            PomodoroLockScreenView(state: context.state, accent: accent, isStale: context.isStale)
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            let state = context.state
            let accent = Color(pomodoroRGB: context.attributes.accentRGB)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PomodoroIslandParts.leading(state, accent: accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PomodoroIslandParts.trailing(state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    PomodoroIslandParts.center(state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PomodoroIslandParts.bottom(state, accent: accent)
                }
            } compactLeading: {
                PomodoroIslandParts.compactLeading(state, accent: accent)
            } compactTrailing: {
                PomodoroIslandParts.compactTrailing(state, accent: accent, isStale: context.isStale)
            } minimal: {
                PomodoroIslandParts.minimal(state, accent: accent)
            }
            .keylineTint(accent)
        }
    }
}

// MARK: - Home screen: today's Top3

struct TodayTasksEntry: TimelineEntry {
    let date: Date
    let state: TodayTasksWidgetState
}

struct TodayTasksProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayTasksEntry {
        TodayTasksEntry(date: Date(), state: .ready(TodayTasksSnapshot(
            dayKey: TodayTasksSnapshot.logicalDayKey(boundaryMinutes: 0), boundaryMinutes: 0,
            categories: [
                .init(id: 0, name: "Work", done: 2, total: 3, openTitles: []),
                .init(id: 1, name: "MyOwn", done: 1, total: 3, openTitles: []),
                .init(id: 2, name: "Chores", done: 3, total: 3, openTitles: []),
            ], accentRGB: nil)))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayTasksEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TodayTasksEntry(date: Date(), state: .current()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayTasksEntry>) -> Void) {
        let now = Date()
        var entries = [TodayTasksEntry(date: now, state: .current(now: now))]
        var refresh = now.addingTimeInterval(60 * 60)
        if case .ready(let snapshot) = entries[0].state {
            // At the logical day boundary yesterday's list turns into the "open the app" hint.
            let boundary = TodayTasksSnapshot.nextBoundary(after: now, boundaryMinutes: snapshot.boundaryMinutes)
            entries.append(TodayTasksEntry(date: boundary, state: .stale(snapshot)))
            refresh = max(boundary, now.addingTimeInterval(60))
        }
        // The app also reloads this kind whenever it saves tasks.
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

struct TodayTasksHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TodayTasksSnapshotStore.widgetKind, provider: TodayTasksProvider()) { entry in
            TodayTasksHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("今日任务")
        .description("今天 Top3 任务（Work / MyOwn / Chores）的完成进度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TodayTasksHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayTasksEntry

    var body: some View {
        TodayTasksWidgetContent(state: entry.state, compact: family == .systemSmall)
            .widgetSurface()
    }
}

private extension View {
    /// iOS 17 requires the container background API; iOS 16 keeps the system padding.
    @ViewBuilder func widgetSurface() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        } else {
            padding()
        }
    }
}
