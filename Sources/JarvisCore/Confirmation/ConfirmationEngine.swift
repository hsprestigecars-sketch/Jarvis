import Foundation
import Observation

/// An action waiting for the user. The tool name and arguments are frozen when
/// the card is created; the executor runs exactly these, so neither Claude nor
/// any other component can change the action after the user sees it.
public struct PendingAction: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let toolName: String
    public let frozenInput: JSONValue
    public let fingerprint: String
    public let details: ConfirmationDetails
    public let createdAt: Date

    init(toolName: String, input: JSONValue, details: ConfirmationDetails) {
        self.id = UUID()
        self.toolName = toolName
        self.frozenInput = input
        self.fingerprint = PendingAction.fingerprint(toolName: toolName, input: input)
        self.details = details
        self.createdAt = Date()
    }

    public static func fingerprint(toolName: String, input: JSONValue) -> String {
        toolName + "|" + input.canonicalString
    }
}

public enum ConfirmationDecision: Equatable, Sendable {
    /// Confirmed. Carries the frozen input that must be executed.
    case confirmed(JSONValue)
    case cancelled
    case expired
}

/// Holds Level 2 actions until the user confirms or cancels them.
@MainActor
@Observable
public final class ConfirmationEngine {
    public private(set) var pending: [PendingAction] = []
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<ConfirmationDecision, Never>] = [:]
    private let timeout: Duration

    public init(timeout: Duration = .seconds(600)) {
        self.timeout = timeout
    }

    /// Suspends until the user decides. Returns `.confirmed` only for this
    /// exact action.
    public func request(toolName: String, input: JSONValue, details: ConfirmationDetails) async -> ConfirmationDecision {
        let action = PendingAction(toolName: toolName, input: input, details: details)
        pending.append(action)
        let timeout = self.timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resolve(action.id, with: .expired)
        }
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if pending.contains(where: { $0.id == action.id }) {
                    continuations[action.id] = continuation
                } else {
                    continuation.resume(returning: .cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(action.id, with: .cancelled) }
        }
        timeoutTask.cancel()
        return decision
    }

    /// Confirms an action. `fingerprint` must match what the card displayed,
    /// which guarantees the user approved this exact action.
    @discardableResult
    public func confirm(id: UUID, fingerprint: String) -> Bool {
        guard let action = pending.first(where: { $0.id == id }), action.fingerprint == fingerprint else {
            return false
        }
        resolve(id, with: .confirmed(action.frozenInput))
        return true
    }

    public func cancel(id: UUID) {
        resolve(id, with: .cancelled)
    }

    /// Cancels the most recent pending action (voice "Cancel").
    @discardableResult
    public func cancelMostRecent() -> Bool {
        guard let last = pending.last else { return false }
        resolve(last.id, with: .cancelled)
        return true
    }

    /// Confirms the only pending action (voice "Confirm"). Refuses when more
    /// than one action is waiting so a voice command can never approve the
    /// wrong thing.
    @discardableResult
    public func confirmSoleAction() -> Bool {
        guard pending.count == 1, let action = pending.first else { return false }
        return confirm(id: action.id, fingerprint: action.fingerprint)
    }

    public func cancelAll() {
        for action in pending { resolve(action.id, with: .cancelled) }
    }

    private func resolve(_ id: UUID, with decision: ConfirmationDecision) {
        pending.removeAll { $0.id == id }
        continuations.removeValue(forKey: id)?.resume(returning: decision)
    }
}
