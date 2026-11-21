import Foundation

/// One rolling budget per UID/API root, shared by every feature. Admission is synchronous:
/// delaying a write here would invalidate the caller's identity/revision check before dispatch.
struct HabiticaRequestBudget {
    static let localLimit = 24 // Habitica allows 30/minute; leave room for other clients.
    private var starts: [TimeInterval] = []
    private var serverRemaining: Int?
    private var serverReset: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0
    private(set) var received429 = false

    mutating func delay(at uptime: TimeInterval) -> TimeInterval {
        starts.removeAll { $0 <= uptime - 60 }
        if uptime >= serverReset { serverRemaining = nil }
        if uptime >= cooldownUntil { received429 = false }
        let localDelay = starts.count >= Self.localLimit ? (starts.first! + 60 - uptime) : 0
        let serverDelay = serverRemaining == 0 ? serverReset - uptime : 0
        return max(0, localDelay, serverDelay, cooldownUntil - uptime)
    }

    /// Reject instead of queueing/replaying writes. Unacknowledged local edits stay pending.
    mutating func reserve(at uptime: TimeInterval) -> TimeInterval {
        let wait = delay(at: uptime)
        guard wait <= 0 else { return wait }
        starts.append(uptime)
        if let remaining = serverRemaining { serverRemaining = max(0, remaining - 1) }
        return 0
    }

    mutating func observe(_ response: HTTPURLResponse, at uptime: TimeInterval, date: Date) {
        // Use the server's Date when available so a skewed local clock cannot shorten a reset.
        let reference = response.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate) ?? date
        let resetDelay = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { value -> TimeInterval? in
            let reset = Double(value).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                ?? Self.httpDate(value)
            return reset.map { max(0, $0.timeIntervalSince(reference)) }
        }
        if let value = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"), let remaining = Int(value) {
            if uptime >= serverReset { serverRemaining = nil }
            // Out-of-order responses may lower the allowance, never replenish it mid-window.
            serverRemaining = min(serverRemaining ?? max(0, remaining), max(0, remaining))
            serverReset = max(serverReset, uptime + (resetDelay ?? 60) + 1)
        }
        if response.statusCode == 429 {
            let retryDelay = response.value(forHTTPHeaderField: "Retry-After").flatMap { value -> TimeInterval? in
                if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
                return Self.httpDate(value).map { max(0, $0.timeIntervalSince(reference)) }
            }
            cooldownUntil = max(cooldownUntil, uptime + max(retryDelay ?? resetDelay ?? 60, resetDelay ?? 0) + 1)
            serverRemaining = 0
            serverReset = max(serverReset, cooldownUntil)
            received429 = true
        }
    }

    private static func httpDate(_ value: String) -> Date? {
        let clean = value.components(separatedBy: " (")[0]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE MMM dd yyyy HH:mm:ss 'GMT'Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: clean) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
