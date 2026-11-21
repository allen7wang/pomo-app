import SwiftUI
import Charts
import UniformTypeIdentifiers

/// iOS counterpart of the macOS 专注复盘 page. Reads the same stores through the shared,
/// fixture-tested `FocusReview` projection and exports the identical CSV.
///
/// Deliberately stateless: NavigationStack re-creates a pushed destination whenever the
/// links inside it are redeclared. A destination holding state never compares equal, so
/// the page re-rendered in an endless loop; an empty struct always does.
struct MobileFocusReviewView: View {
    var body: some View { FocusReviewPage() }
}

private struct FocusReviewPage: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject private var histogram = HistogramManager.shared
    @ObservedObject private var blockManager = BlockProgressManager.shared
    @ObservedObject private var plants = PlantJournal.shared

    @State private var range: FocusReviewRange = .week
    @State private var window: FocusReviewWindow?
    @State private var selectedKey: String?

    var body: some View {
        // Re-evaluated every minute so the rolling window follows midnight; an opened
        // earlier window is anchored and keeps its dates.
        TimelineView(.everyMinute) { timeline in
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: timeline.date)
            let review = report(today: today, calendar: calendar)
            let selected = review.hasRecords ? review.selectedDay(selectedKey) : nil
            ScrollView {
                VStack(alignment: .leading, spacing: theme.pageSpacing) {
                    ThemedPageHeader(title: "专注复盘", subtitle: "回看每天的番茄、时间块和种植记录。",
                                     symbol: "chart.bar.xaxis")
                    rangeCard(review, today: today, calendar: calendar)
                    if let day = selected {
                        trendCard(review, selected: day)
                    } else {
                        ThemedEmptyState(symbol: "chart.bar.xaxis", title: "这段时间还没有专注记录",
                                         message: "所选日期内没有番茄、时间块或种植记录。")
                    }
                    TaskFocusBreakdown(tasks: review.tasks, totalPomodoros: review.totals.pomodoros)
                        .themeCard(theme, padding: theme.cardPadding)
                    if let day = selected {
                        dayList(review, selected: day)
                    }
                    exportCard(review)
                }
                .padding(.horizontal, theme.pageInset)
                .padding(.vertical, theme.pageSpacing)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(theme.accent)
        #if DEBUG
        .navigationDestination(isPresented: $previewDetail) {
            if let day = previewDetailDay { MobileFocusReviewDayView(day: day) }
        }
        .onAppear(perform: applyPreviewArguments)
        #endif
    }

    #if DEBUG
    // Simulator verification only: -previewReviewRange 30|90, -previewReviewPage -1,
    // -previewReviewDetail (opens the default selected day).
    @State private var previewDetail = false
    @State private var previewDetailDay: FocusReviewDay?

    private func applyPreviewArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> Int? {
            args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
        }
        if let days = value("-previewReviewRange"), let preset = FocusReviewRange(rawValue: days) { range = preset }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // After the range's onChange has reset paging.
        DispatchQueue.main.async {
            if let page = value("-previewReviewPage"), page < 0 { window = FocusReviewWindow(anchor: today, offset: page) }
            if args.contains("-previewReviewDetail") {
                previewDetailDay = report(today: today, calendar: calendar).selectedDay(selectedKey)
                previewDetail = previewDetailDay != nil
            }
        }
    }
    #endif

    // MARK: Data

    private func report(today: Date, calendar: Calendar) -> FocusReview {
        let end = window?.endDate(range: range, calendar: calendar) ?? today
        return FocusReview(range: range, now: end, histogram: histogram.histogram,
                           dailyBlocks: blockManager.dailyBlocksHistory, blockHistory: blockManager.blockHistory,
                           plants: plants.days, calendar: calendar)
    }

    private func canPageBack(_ review: FocusReview, calendar: Calendar) -> Bool {
        let earliest = FocusReview.earliestDate(histogram: histogram.histogram, dailyBlocks: blockManager.dailyBlocksHistory,
                                               blockHistory: blockManager.blockHistory, plants: plants.days, calendar: calendar)
        guard let first = review.days.first, let earliest else { return false }
        return earliest < first.date
    }

    // MARK: Range

    private func rangeCard(_ review: FocusReview, today: Date, calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("日期范围", selection: $range) {
                ForEach(FocusReviewRange.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: range) { _ in
                window = nil
                selectedKey = nil
            }

            HStack(spacing: 8) {
                Button {
                    window = FocusReviewWindow.previous(from: window, today: today)
                    selectedKey = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(QuietButtonStyle(theme: theme))
                .accessibilityLabel("上一个日期区间")
                .disabled(!canPageBack(review, calendar: calendar))

                VStack(spacing: 2) {
                    Text("\(shortDate(review.days.first?.date)) – \(shortDate(review.days.last?.date))")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundColor(theme.ink)
                    Text(window == nil ? "截至今天" : "更早的区间")
                        .font(.system(size: 10))
                        .foregroundColor(theme.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)

                Button {
                    window = window?.next(today: today, range: range, calendar: calendar)
                    selectedKey = nil
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(QuietButtonStyle(theme: theme))
                .accessibilityLabel("下一个日期区间")
                .disabled(window == nil)
            }

            if window != nil {
                Button("回到今天") {
                    window = nil
                    selectedKey = nil
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(maxWidth: .infinity)
            }

            Rectangle().fill(theme.line).frame(height: 1).accessibilityHidden(true)
            HStack(spacing: 10) {
                metric(duration(review.totals.minutes), caption: "专注时长")
                metric("\(review.totals.pomodoros)", caption: "完成番茄")
                metric("\(review.totals.activeDays) 天", caption: "专注天数")
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    // MARK: Trend

    private func trendCard(_ review: FocusReview, selected: FocusReviewDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("专注趋势")
                Spacer(minLength: 0)
                Text("每天完成的专注分钟")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
            }
            chart(review.days, selected: selected)
                .frame(height: 168)
            NavigationLink {
                MobileFocusReviewDayView(day: selected)
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(theme.accent).frame(width: 8, height: 8).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(longDate(selected.date))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.ink)
                        Text(selected.hasRecords
                             ? "\(duration(selected.minutes)) · \(selected.pomodoros) 个番茄 · 达标 \(selected.completedBlocks) 块"
                             : "当天没有记录")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(theme.muted)
                    }
                    Spacer(minLength: 0)
                    Text("明细")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accentSoft))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("点按柱形切换日期")
                .font(.system(size: 10))
                .foregroundColor(theme.muted)
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func chart(_ days: [FocusReviewDay], selected: FocusReviewDay) -> some View {
        // Thin bars, single series: no legend; only the selected bar is labelled.
        let barWidth: MarkDimension = days.count <= 7 ? .fixed(18) : .ratio(0.62)
        let stride = days.count <= 7 ? 1 : (days.count <= 30 ? 7 : 21)
        return Chart(days) { day in
            BarMark(x: .value("日期", day.date, unit: .day),
                    y: .value("分钟", day.minutes),
                    width: barWidth)
                .cornerRadius(days.count <= 30 ? 4 : 2)
                .foregroundStyle(day.id == selected.id ? theme.accent : theme.accent.opacity(0.38))
                .annotation(position: .top, spacing: 3) {
                    if day.id == selected.id && day.minutes > 0 {
                        Text("\(day.minutes)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(theme.ink)
                    }
                }
                .accessibilityLabel(longDate(day.date))
                .accessibilityValue("专注 \(day.minutes) 分钟，完成 \(day.pomodoros) 个番茄")
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: stride)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: days.count <= 7)
                    .foregroundStyle(theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(theme.line)
                AxisValueLabel().foregroundStyle(theme.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let origin = geometry[proxy.plotAreaFrame].origin
                        guard let date: Date = proxy.value(atX: value.location.x - origin.x) else { return }
                        let calendar = Calendar.current
                        let nearest = days.min { lhs, rhs in
                            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
                        }
                        // Bars are centred on noon of their day; snap the tapped instant to that day first.
                        let tapped = days.first { calendar.isDate($0.date, inSameDayAs: date) } ?? nearest
                        if let tapped { selectedKey = tapped.id }
                    })
            }
        }
    }

    // MARK: Day list

    private func dayList(_ review: FocusReview, selected: FocusReviewDay) -> some View {
        let recorded = review.days.filter(\.hasRecords).reversed()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("每日记录")
                Spacer(minLength: 0)
                Text("\(recorded.count) 天有记录")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
            }
            LazyVStack(spacing: 6) {
                ForEach(Array(recorded)) { day in
                    NavigationLink {
                        MobileFocusReviewDayView(day: day)
                    } label: {
                        dayRow(day, selected: day.id == selected.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func dayRow(_ day: FocusReviewDay, selected: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(longDate(day.date))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(theme.ink)
                Text(rowCaption(day))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(duration(day.minutes))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(day.minutes > 0 ? theme.ink : theme.muted)
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundColor(theme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? theme.accentSoft : theme.subtle))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func rowCaption(_ day: FocusReviewDay) -> String {
        var parts = ["\(day.pomodoros) 个番茄"]
        if !day.blocks.isEmpty { parts.append("达标 \(day.completedBlocks)/\(day.blocks.count) 块") }
        if day.shrubs + day.trees + day.wilted > 0 { parts.append("🌿\(day.shrubs + day.trees) 🥀\(day.wilted)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Export + legacy history

    private func exportCard(_ review: FocusReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShareLink(item: FocusReviewCSVExport(text: review.csv, filename: review.csvFilename),
                      preview: SharePreview(review.csvFilename)) {
                Label("导出 CSV（当前日期范围）", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle(theme: theme))
            .disabled(review.days.isEmpty)

            if !review.tasks.isEmpty {
                ShareLink(item: FocusReviewCSVExport(text: review.taskCSV, filename: review.taskCSVFilename),
                          preview: SharePreview(review.taskCSVFilename)) {
                    Label("导出任务用时", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle(theme: theme))
            }

            Text("全部历史 · \(histogram.totalPomodoros) 个番茄 · \(String(format: "%.1f", histogram.totalHours)) 小时 · 记录日均 \(String(format: "%.1f", histogram.avgPomodoros)) 个番茄")
                .font(.system(size: 11))
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                MobileHistoryView()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundColor(theme.accent)
                    Text("累计统计与历史记录")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .themeCard(theme, padding: theme.cardPadding)
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func metric(_ value: String, caption: String) -> some View {
        FocusReviewMetric(value: value, caption: caption)
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return FocusReviewFormat.short.string(from: date)
    }

    private func longDate(_ date: Date) -> String { FocusReviewFormat.long.string(from: date) }

    private func duration(_ minutes: Int) -> String { FocusReviewFormat.duration(minutes) }
}

// MARK: - Day detail

struct MobileFocusReviewDayView: View {
    @Environment(\.appTheme) private var theme
    let day: FocusReviewDay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.pageSpacing) {
                ThemedPageHeader(title: FocusReviewFormat.long.string(from: day.date), subtitle: "当日明细",
                                 symbol: "calendar", detail: day.id)
                if day.hasRecords {
                    HStack(spacing: 10) {
                        FocusReviewMetric(value: FocusReviewFormat.duration(day.minutes), caption: "专注时长")
                        FocusReviewMetric(value: "\(day.pomodoros)", caption: "完成番茄")
                        FocusReviewMetric(value: "\(day.completedBlocks)", caption: "达标时间块")
                    }
                    .themeCard(theme, padding: theme.cardPadding)
                    if !day.taskSessions.isEmpty {
                        TaskFocusBreakdown(tasks: day.tasks, totalPomodoros: day.pomodoros)
                            .themeCard(theme, padding: theme.cardPadding)
                    }
                    blocksCard
                    plantsCard
                } else {
                    ThemedEmptyState(symbol: "calendar", title: "当天没有记录",
                                     message: "当天没有专注、时间块或种植记录。")
                }
            }
            .padding(.horizontal, theme.pageInset)
            .padding(.vertical, theme.pageSpacing)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var blocksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("时间块")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.ink)
                .accessibilityAddTraits(.isHeader)
            if day.blocks.isEmpty {
                Text("当天没有时间块记录")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            }
            ForEach(day.blocks) { block in
                HStack(alignment: .center, spacing: 10) {
                    Text("B\(block.id + 1)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(block.isCompleted ? theme.onAccent : theme.accent)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(block.isCompleted ? theme.accent : theme.accentSoft))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.goal ?? "未记录目标")
                            .font(.system(size: 13))
                            .foregroundColor(block.goal == nil ? theme.muted : theme.ink)
                            .lineLimit(2)
                        Text(plantLine(block))
                            .font(.system(size: 11))
                            .foregroundColor(theme.muted)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(block.completedPomodoros) 个番茄")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundColor(theme.ink)
                        if block.isCompleted {
                            Label("曾达标", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(theme.accent)
                        }
                    }
                    .fixedSize()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.subtle))
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(theme, padding: theme.cardPadding)
    }

    private var plantsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("种植")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.ink)
                .accessibilityAddTraits(.isHeader)
            if day.shrubs + day.trees + day.wilted > 0 {
                HStack(spacing: 10) {
                    FocusReviewMetric(value: "🌿 \(day.shrubs)", caption: "灌木")
                    FocusReviewMetric(value: "🌳 \(day.trees)", caption: "树")
                    FocusReviewMetric(value: "🥀 \(day.wilted)", caption: "枯萎")
                }
            } else {
                Text("当天没有种植记录")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(theme, padding: theme.cardPadding)
    }

    private func plantLine(_ block: FocusReviewBlock) -> String {
        guard block.shrubs + block.trees + block.wilted > 0 else { return "没有种植记录" }
        return "灌木 \(block.shrubs) · 树 \(block.trees) · 枯萎 \(block.wilted)"
    }
}

// MARK: - Shared pieces

private struct FocusReviewMetric: View {
    @Environment(\.appTheme) private var theme
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundColor(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 11))
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private enum FocusReviewFormat {
    static let short: DateFormatter = formatter("M月d日")
    static let long: DateFormatter = formatter("M月d日 EEE")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

/// Written lazily to a temporary file when the share sheet asks for it, so the
/// recipient sees the same filename as the macOS exporter.
private struct FocusReviewCSVExport: Transferable {
    let text: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FocusReviewExport", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(export.filename)
            try Data(export.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
