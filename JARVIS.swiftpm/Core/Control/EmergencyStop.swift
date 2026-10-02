import Foundation

/// The emergency stop. Every component that can do work on the user's
/// behalf registers a handler here. Triggering the stop runs all handlers
/// synchronously on the main actor: speech stops, pending confirmations are
/// cancelled, the agent task is cancelled and queued JARVIS work is removed.
///
/// It only stops work that JARVIS itself started. It never touches iPadOS
/// security or settings.
@MainActor
public final class EmergencyStop {
    public typealias Handler = @MainActor () -> Void

    private var handlers: [(name: String, run: Handler)] = []
    public private(set) var lastTriggered: Date?

    public init() {}

    public func register(_ name: String, _ handler: @escaping Handler) {
        handlers.append((name, handler))
    }

    /// Returns the names of the handlers that ran, for the activity log.
    @discardableResult
    public func trigger() -> [String] {
        lastTriggered = Date()
        for handler in handlers { handler.run() }
        return handlers.map(\.name)
    }
}
