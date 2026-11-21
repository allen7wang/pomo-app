import Foundation
import ActivityKit

// Compiled into both the app (which starts/updates/ends the activity) and the
// widget extension (which renders it). Keep it free of app-only types.

@available(iOS 16.1, *)
struct PomodoroActivityAttributes: ActivityAttributes {
    /// Skin accent (0xRRGGBB) captured when the activity starts; nil falls back to the system tint.
    var accentRGB: UInt32?

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case focus, shortBreak, longBreak, breakExtension, customBreak, awaitingBreak
        }

        var phase: Phase
        /// Meaningful only while running; the countdown renders itself from this date.
        var endsAt: Date
        /// Whole phase length in seconds, kept across pauses so progress does not restart.
        var duration: Int
        /// Seconds left while paused; nil while counting down.
        var pausedRemaining: Int?
        var blockLabel: String?
        var comboDone: Int
        var comboTotal: Int

        var isPaused: Bool { pausedRemaining != nil }
        var hasCountdown: Bool { phase != .awaitingBreak }
        var startedAt: Date { endsAt.addingTimeInterval(-TimeInterval(max(1, duration))) }
        var timerRange: ClosedRange<Date> { min(startedAt, endsAt)...endsAt }

        var pausedProgress: Double {
            guard let pausedRemaining, duration > 0 else { return 0 }
            return min(1, max(0, 1 - Double(pausedRemaining) / Double(duration)))
        }

        var title: String {
            switch phase {
            case .focus: return "专注"
            case .shortBreak: return "短休息"
            case .longBreak: return "长休息"
            case .breakExtension: return "休息延长"
            case .customBreak: return "自选休息"
            case .awaitingBreak: return "专注完成"
            }
        }

        var symbol: String {
            switch phase {
            case .focus: return "timer"
            case .shortBreak, .customBreak: return "cup.and.saucer.fill"
            case .longBreak: return "leaf.fill"
            case .breakExtension: return "hourglass"
            case .awaitingBreak: return "checkmark.circle.fill"
            }
        }

        var comboText: String { "组合 \(min(comboDone, comboTotal))/\(comboTotal)" }

        static func clock(_ seconds: Int) -> String {
            let value = max(0, seconds)
            return value >= 3600
                ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                : String(format: "%02d:%02d", value / 60, value % 60)
        }
    }
}
