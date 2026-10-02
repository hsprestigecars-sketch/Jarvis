import Foundation

/// What JARVIS is doing right now. Always visible in the UI.
public enum JarvisStatus: Equatable, Sendable {
    case ready
    case listening
    case thinking
    case working(String)
    case speaking
    case waitingForConfirmation
    case protected(String)
    case error(String)

    public var label: String {
        switch self {
        case .ready: "READY"
        case .listening: "LISTENING"
        case .thinking: "THINKING"
        case .working: "WORKING"
        case .speaking: "SPEAKING"
        case .waitingForConfirmation: "WAITING FOR CONFIRMATION"
        case .protected: "PROTECTED"
        case .error: "ERROR"
        }
    }

    public var detail: String? {
        switch self {
        case .working(let detail), .protected(let detail), .error(let detail): detail
        default: nil
        }
    }
}
