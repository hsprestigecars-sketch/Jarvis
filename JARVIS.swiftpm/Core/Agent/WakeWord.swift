import Foundation

/// Finds "JARVIS" in a running speech transcript and extracts what follows.
///
/// Used by hands-free mode, which recognises speech on the device only. The
/// transcript is scanned for the *last* mention of the name, so "…blah blah.
/// Jarvis, what's on my calendar" yields "what's on my calendar".
public enum WakeWord {
    public enum Match: Equatable, Sendable {
        case none
        /// The name was said with nothing after it yet ("Jarvis…").
        case wakeOnly
        /// The name followed by a request.
        case command(String)
    }

    /// Common on-device spellings of the name. "Travis" is deliberately
    /// excluded to avoid waking on a real person's name.
    static let pattern = #"(?i)\b(?:(?:hey|hi|ok|okay|yo)[\s,]+)?(?:jarvis|jarvys|jarviss|jervis|jarves|j\.?\s?a\.?\s?r\.?\s?v\.?\s?i\.?\s?s)\b\.?"#

    public static func match(_ transcript: String) -> Match {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .none }
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let last = regex.matches(in: transcript, range: range).last,
              let matchRange = Range(last.range, in: transcript) else { return .none }
        let separators = CharacterSet(charactersIn: ",.!?:;-–—").union(.whitespacesAndNewlines)
        let rest = transcript[matchRange.upperBound...]
            .drop { $0.unicodeScalars.allSatisfy(separators.contains) }
        let command = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? .wakeOnly : .command(command)
    }
}
