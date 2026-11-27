import SwiftUI

struct TaskFocusDayDetails: View {
    @Environment(\.appTheme) private var theme
    @State private var visibleCount = 0

    let day: FocusReviewDay
    private static let pageSize = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskFocusBreakdown(tasks: day.tasks, totalPomodoros: day.pomodoros)
            Divider()
            Button {
                visibleCount = visibleCount == 0 ? Self.pageSize : 0
            } label: {
                HStack(spacing: 8) {
                    Text("专注明细")
                        .font(theme.sectionFont(size: 14))
                        .foregroundStyle(theme.ink)
                    Spacer(minLength: 4)
                    Text("\(day.taskSessions.count) 条")
                        .font(.caption)
                        .foregroundStyle(theme.muted)
                    Image(systemName: visibleCount == 0 ? "chevron.right" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("专注明细")
            .accessibilityValue("\(day.taskSessions.count) 条，\(visibleCount == 0 ? "已收起" : "已展开")")
            .accessibilityIdentifier("focus-review-session-toggle")
            if visibleCount > 0 {
                let sessions = day.chronologicalTaskSessions
                let dateKey = FocusReview.dateKeyFormatter(calendar: .current)
                ForEach(sessions.prefix(visibleCount)) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.subheadline)
                            .foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(startLabel(session, dateKey: dateKey)) · \(session.minutes) 分钟")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
                if visibleCount < sessions.count {
                    Button("再显示 \(min(Self.pageSize, sessions.count - visibleCount)) 条") {
                        visibleCount += Self.pageSize
                    }
                    .buttonStyle(QuietButtonStyle(theme: theme))
                    .accessibilityIdentifier("focus-review-more-sessions")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startLabel(_ session: TaskFocusSession, dateKey: DateFormatter) -> String {
        guard session.startedAt > 0 else { return "开始时间未知" }
        let start = Date(timeIntervalSince1970: Double(session.startedAt) / 1000)
        let sameDay = dateKey.string(from: start) == day.id
        return start.formatted(date: sameDay ? .omitted : .numeric, time: .shortened) + " 开始"
    }
}

struct TaskFocusBreakdown: View {
    @Environment(\.appTheme) private var theme
    @State private var expanded = false

    let tasks: [FocusReviewTask]
    let totalPomodoros: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("任务用时")
                .font(theme.sectionFont(size: 14))
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            if tasks.isEmpty {
                Text("从今日任务开始并完成一个番茄，即可看到任务用时。")
                    .font(.caption)
                    .foregroundStyle(theme.muted)
            } else {
                let linkedCount = tasks.reduce(0) { $0 + $1.pomodoros }
                Text(linkedCount > totalPomodoros ? "\(linkedCount) 个番茄关联了任务" : "\(linkedCount) / \(totalPomodoros) 个番茄关联了任务")
                    .font(.caption)
                    .foregroundStyle(theme.muted)
                ForEach(tasks.prefix(expanded ? tasks.count : 5)) { task in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            title(task).fixedSize()
                            Spacer(minLength: 0)
                            metrics(task).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            title(task)
                            metrics(task)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if tasks.count > 5 {
                    Button(expanded ? "收起任务" : "查看全部 \(tasks.count) 项任务") { expanded.toggle() }
                        .buttonStyle(QuietButtonStyle(theme: theme))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ task: FocusReviewTask) -> some View {
        Text(task.title)
            .font(.subheadline)
            .foregroundStyle(theme.ink)
    }

    private func metrics(_ task: FocusReviewTask) -> some View {
        Text("\(task.minutes) 分钟 · \(task.pomodoros) 个番茄")
            .font(theme.numberFont(size: 11))
            .foregroundStyle(theme.muted)
    }
}
