import Foundation
import Combine
import UIKit
import WidgetKit

/// Copies today's Top3 summary into the App Group container for the home-screen widget.
/// Observes the managers from the outside so shared code stays platform-neutral.
final class TodayTasksWidgetSync {
    static let shared = TodayTasksWidgetSync()

    private var cancellables = Set<AnyCancellable>()
    private var lastWritten: TodayTasksSnapshot?

    func start() {
        #if DEBUG
        guard PomodoroDataDir.debugDirectoryOverride == nil else { return }
        #endif
        guard cancellables.isEmpty else { return }
        // Without a shared container (e.g. a re-signer stripped App Groups) the widget shows
        // its "打开应用同步" placeholder; there is nothing to write.
        guard SharedAppGroup.containerURL != nil else { return }

        Publishers.MergeMany(
            TopThreeManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SettingsManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SkinAccentBridge.shared.$rgb.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            // Covers the logical-day rollover and edits synced from the Mac while away.
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] in self?.write() }
        .store(in: &cancellables)
        write()
    }

    private func write() {
        let snapshot = Self.makeSnapshot()
        guard snapshot != lastWritten, TodayTasksSnapshotStore.save(snapshot) else { return }
        lastWritten = snapshot
        WidgetCenter.shared.reloadTimelines(ofKind: TodayTasksSnapshotStore.widgetKind)
    }

    static func makeSnapshot() -> TodayTasksSnapshot {
        let manager = TopThreeManager.shared
        let settings = SettingsManager.shared.settings
        let key = manager.todayKey(settings: settings)
        let groups = manager.store.history[key]?.taskGroups ?? []
        let count = max(3, manager.store.categoryNames.count)
        let categories = (0..<count).map { index -> TodayTasksSnapshot.Category in
            // Rows moved to today stay behind as read-only copies; count them only once, on today.
            let tasks = (groups.indices.contains(index) ? groups[index] : []).filter {
                !$0.movedToToday && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return TodayTasksSnapshot.Category(
                id: index, name: manager.categoryName(index: index),
                done: tasks.filter(\.isCompleted).count, total: tasks.count,
                openTitles: Array(tasks.filter { !$0.isCompleted }.map(\.title).prefix(3)))
        }
        return TodayTasksSnapshot(dayKey: key,
                                  boundaryMinutes: settings.blockTimeRanges.first?.startMinutes ?? 0,
                                  categories: categories, accentRGB: SkinAccentBridge.shared.rgb)
    }
}
