import SwiftUI

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
                Text("\(tasks.reduce(0) { $0 + $1.pomodoros }) / \(totalPomodoros) 个番茄关联了任务")
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
