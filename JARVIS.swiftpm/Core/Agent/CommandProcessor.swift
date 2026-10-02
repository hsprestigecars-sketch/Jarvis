import Foundation

/// Commands JARVIS handles itself, deterministically, before Claude sees
/// anything. Stop and cancel must work even with no network, and blocked
/// financial requests are refused without ever reaching the model.
public enum LocalCommand: Equatable, Sendable {
    case emergencyStop
    case cancel
    case confirm
    case protected(BlockedPolicy.Finding)
    /// Not a local command: send `text` (wake phrase removed) to Claude.
    case forward(String)
    case empty
}

public enum CommandProcessor {
    private static let wakePrefixes = ["hey jarvis", "ok jarvis", "okay jarvis", "jarvis"]

    private static let stopPhrases: Set<String> = [
        "stop", "stop stop", "stop now", "stop it", "stop everything", "emergency stop", "abort", "halt",
        "shut up", "be quiet", "stop talking",
    ]

    private static let cancelPhrases: Set<String> = [
        "cancel", "cancel that", "cancel it", "cancel this", "never mind", "nevermind", "forget it", "dont do it",
        "don't do it", "no cancel", "no",
    ]

    private static let confirmPhrases: Set<String> = [
        "confirm", "confirm it", "confirm that", "yes confirm", "i confirm", "confirmed",
    ]

    public static func classify(_ input: String, hasPendingConfirmation: Bool) -> LocalCommand {
        let stripped = stripWakeWord(input)
        if stripped.isEmpty { return .empty }
        let normalized = normalize(stripped)

        if stopPhrases.contains(normalized) { return .emergencyStop }
        if cancelPhrases.contains(normalized) {
            // A bare "no" only means cancel when something is waiting.
            return normalized == "no" && !hasPendingConfirmation ? .forward(stripped) : .cancel
        }
        if hasPendingConfirmation, confirmPhrases.contains(normalized) { return .confirm }
        if let finding = BlockedPolicy.classifyRequest(stripped) { return .protected(finding) }
        return .forward(stripped)
    }

    /// Removes a leading "Hey JARVIS," so "JARVIS, STOP." becomes "STOP.".
    public static func stripWakeWord(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        for prefix in wakePrefixes where lower.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count)
            // Only strip whole words ("jarvis," yes; "jarvisx" no).
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            // Drop the punctuation after the wake word only ("JARVIS, …").
            let separators = CharacterSet(charactersIn: ",.!?:;").union(.whitespacesAndNewlines)
            text = String(rest.drop { $0.unicodeScalars.allSatisfy(separators.contains) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let kept = lowered.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " || $0 == "'" }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ")
            .joined(separator: " ")
    }
}
