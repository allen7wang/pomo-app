import SwiftUI

/// Chronological horizontal timeline with a Current anchor; uses the desktop's block arrays.
struct MobileBlockTimelineView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var blocks = BlockProgressManager.shared
    @Environment(\.appTheme) private var theme
    @State private var selection: Int?
    private var settings: UserSettings { settingsManager.settings }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("时间线")
                        .font(theme.sectionFont(size: 14))
                        .foregroundColor(theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button {
                        blocks.updateBlockIndexFromTime(settings: settings)
                        withAnimation { proxy.scrollTo(blocks.blockProgress.currentBlockIndex, anchor: .center) }
                    } label: {
                        Label("当前", systemImage: "location.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accent)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .background(theme.chipShape.fill(theme.accentSoft))
                    }
                    .buttonStyle(.plain)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<settings.blockCount, id: \.self) { index in
                            let counts = blocks.getTodayBlockProgress(settings: settings)
                            let completed = counts.indices.contains(index) ? counts[index] : 0
                            let tasks = settings.blockTasks.indices.contains(index) ? settings.blockTasks[index] : []
                            let isCurrent = index == blocks.blockProgress.currentBlockIndex
                            let muted = isCurrent ? theme.onAccent.opacity(0.8) : theme.muted
                            Button { selection = index } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("B\(index + 1)").font(theme.numberFont(size: 15, weight: .semibold))
                                        Spacer(minLength: 0)
                                        if settings.blockTimeRanges.indices.contains(index) {
                                            Text(settings.blockTimeRanges[index].displayString)
                                                .font(theme.numberFont(size: 11, weight: .regular))
                                                .foregroundColor(muted)
                                        }
                                    }
                                    SkinProgressBar(value: Double(min(completed, settings.blockPomoCount)),
                                                    total: Double(max(settings.blockPomoCount, 1)),
                                                    tint: isCurrent ? theme.onAccent : theme.accent)
                                    Text("\(completed)/\(settings.blockPomoCount) 🍅").font(theme.numberFont(size: 12))
                                    ForEach(tasks.prefix(2)) { task in
                                        Label(task.title, systemImage: theme.checkSymbol(task.isCompleted))
                                            .font(.caption2).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Text("任务 \(tasks.filter(\.isCompleted).count)/\(tasks.count)")
                                        .font(theme.numberFont(size: 11, weight: .regular))
                                        .foregroundColor(muted)
                                }
                                .foregroundColor(isCurrent ? theme.onAccent : theme.ink)
                                .frame(width: 142, height: 152, alignment: .topLeading)
                                .padding(12)
                                .background(
                                    SkinSurface(theme: theme, fill: isCurrent ? theme.accent : theme.surface,
                                                radius: min(theme.cardRadius, 14),
                                                stroke: isCurrent ? (theme.squareCorners ? theme.ink : nil) : (theme.cardStroke ?? theme.line),
                                                strokeWidth: max(1, theme.borderWidth), elevated: isCurrent)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("B\(index + 1)，完成 \(completed)/\(settings.blockPomoCount)\(isCurrent ? "，当前时间块" : "")")
                            .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                }
                .onAppear {
                    blocks.updateBlockIndexFromTime(settings: settings)
                    proxy.scrollTo(blocks.blockProgress.currentBlockIndex, anchor: .center)
                }
            }
        }
        .sheet(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let index = selection { NavigationStack { MobileBlockEditorView(blockIndex: index) } }
        }
    }
}
