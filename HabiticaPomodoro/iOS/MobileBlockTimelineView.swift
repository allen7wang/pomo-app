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
                    Text("时间线").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.ink)
                    Spacer()
                    Button {
                        blocks.updateBlockIndexFromTime(settings: settings)
                        withAnimation { proxy.scrollTo(blocks.blockProgress.currentBlockIndex, anchor: .center) }
                    } label: { Label("当前", systemImage: "location.fill") }
                        .font(.caption)
                        .foregroundColor(theme.accent)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<settings.blockCount, id: \.self) { index in
                            let counts = blocks.getTodayBlockProgress(settings: settings)
                            let completed = counts.indices.contains(index) ? counts[index] : 0
                            let tasks = settings.blockTasks.indices.contains(index) ? settings.blockTasks[index] : []
                            let isCurrent = index == blocks.blockProgress.currentBlockIndex
                            Button { selection = index } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("B\(index + 1)").font(.subheadline.bold())
                                    if settings.blockTimeRanges.indices.contains(index) {
                                        Text(settings.blockTimeRanges[index].displayString).font(.caption2.monospacedDigit())
                                    }
                                    ProgressView(value: Double(min(completed, settings.blockPomoCount)), total: Double(settings.blockPomoCount))
                                    Text("\(completed)/\(settings.blockPomoCount) 🍅").font(.caption)
                                    ForEach(tasks.prefix(2)) { task in
                                        Label(task.title, systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                            .font(.caption2).lineLimit(1)
                                    }
                                    Text("任务 \(tasks.filter(\.isCompleted).count)/\(tasks.count)")
                                        .font(.caption2)
                                }
                                .foregroundColor(isCurrent ? theme.onAccent : theme.ink)
                                .tint(isCurrent ? theme.onAccent : theme.accent)
                                .frame(width: 142, height: 152, alignment: .topLeading)
                                .padding(12)
                                .background(isCurrent ? theme.accent : theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? theme.accent : theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                }
                .onAppear {
                    blocks.updateBlockIndexFromTime(settings: settings)
                    proxy.scrollTo(blocks.blockProgress.currentBlockIndex, anchor: .center)
                }
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let index = selection { NavigationStack { MobileBlockEditorView(blockIndex: index) } }
        }
    }
}
