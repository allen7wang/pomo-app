import SwiftUI

/// What the home-screen widget can show. Built from the App Group snapshot.
enum TodayTasksWidgetState: Equatable {
    case ready(TodayTasksSnapshot)
    /// The snapshot belongs to an earlier logical day; the app has not run since.
    case stale(TodayTasksSnapshot)
    /// Container exists but the app has not written a snapshot yet.
    case notSynced
    /// No App Group under this signature (e.g. a free re-signer stripped it).
    case noSharedContainer

    static func current(now: Date = Date()) -> TodayTasksWidgetState {
        guard SharedAppGroup.containerURL != nil else { return .noSharedContainer }
        guard let snapshot = TodayTasksSnapshotStore.load() else { return .notSynced }
        let today = TodayTasksSnapshot.logicalDayKey(boundaryMinutes: snapshot.boundaryMinutes, now: now)
        return snapshot.dayKey == today ? .ready(snapshot) : .stale(snapshot)
    }

    var accent: Color {
        switch self {
        case .ready(let snapshot), .stale(let snapshot): return Color(pomodoroRGB: snapshot.accentRGB)
        case .notSynced, .noSharedContainer: return .accentColor
        }
    }
}

struct TodayTasksWidgetContent: View {
    let state: TodayTasksWidgetState
    /// systemSmall uses the compact layout.
    let compact: Bool

    var body: some View {
        switch state {
        case .ready(let snapshot):
            if compact { small(snapshot) } else { medium(snapshot) }
        case .stale(let snapshot):
            placeholder("上次同步：\(Self.dayLabel(snapshot.dayKey))")
        case .notSynced:
            placeholder("还没有今天的任务数据")
        case .noSharedContainer:
            placeholder(compact ? "当前安装方式不支持小组件读取数据" : "当前安装方式未开启 App Group，小组件读不到应用数据")
        }
    }

    private var accent: Color { state.accent }

    private func small(_ snapshot: TodayTasksSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Text(snapshot.total == 0 ? "—" : "\(snapshot.done)/\(snapshot.total)")
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(summary(snapshot))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            ForEach(snapshot.categories.prefix(3)) { category in
                HStack(spacing: 6) {
                    Circle()
                        .fill(category.total > 0 && category.done >= category.total ? accent : accent.opacity(0.28))
                        .frame(width: 6, height: 6)
                    Text(category.name).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(category.total == 0 ? "—" : "\(category.done)/\(category.total)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ snapshot: TodayTasksSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                header
                Spacer(minLength: 4)
                Text(summary(snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.categories.prefix(3)) { category in
                HStack(spacing: 8) {
                    Text(category.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(width: 58, alignment: .leading)
                    ProgressView(value: Double(category.done), total: Double(max(category.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(accent)
                    Text(category.total == 0 ? "—" : "\(category.done)/\(category.total)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if let next = snapshot.categories.lazy.compactMap(\.openTitles.first).first {
                Text("下一件：\(next)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        Label("今日任务", systemImage: "checklist")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(accent)
            .lineLimit(1)
    }

    private func summary(_ snapshot: TodayTasksSnapshot) -> String {
        if snapshot.total == 0 { return "今天还没有任务" }
        return snapshot.done >= snapshot.total ? "全部完成" : "还剩 \(snapshot.total - snapshot.done) 件"
    }

    private func placeholder(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 2)
            Text("打开应用同步")
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return key }
        return "\(month)月\(day)日"
    }
}
