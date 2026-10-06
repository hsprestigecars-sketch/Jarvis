import Foundation

/// Shared helpers for JARVIS countdown timers. Timers themselves are local
/// notifications scheduled by the app; this keeps their naming and wording
/// in one testable place.
public enum TimerText {
    /// Identifier prefix of every JARVIS timer notification.
    public static let notificationPrefix = "jarvis.timer."
    /// Key in the notification's userInfo that holds the user's label.
    public static let labelKey = "label"
    /// Key in the notification's userInfo that holds the end time (seconds since 1970).
    public static let endsKey = "ends"
    public static let maxSeconds = 24 * 3600

    /// Total seconds from optional hours, minutes and seconds.
    public static func totalSeconds(hours: Int?, minutes: Int?, seconds: Int?) -> Int {
        (hours ?? 0) * 3600 + (minutes ?? 0) * 60 + (seconds ?? 0)
    }

    /// "1 h 5 min", "10 min", "45 s", "2 min 30 s".
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 || parts.isEmpty { parts.append("\(s) s") }
        return parts.joined(separator: " ")
    }

    /// What JARVIS says when a timer goes off.
    public static func finishedAnnouncement(label: String?) -> String {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return "Your timer is done."
        }
        return "Timer done: \(label)."
    }

    /// Whether a timer's label matches what the user asked to cancel.
    public static func label(_ label: String?, matches query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let label else { return false }
        return label.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
