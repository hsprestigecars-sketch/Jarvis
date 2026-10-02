import Foundation

public enum SafetyDecision: Equatable, Sendable {
    case allow
    case requireConfirmation(ConfirmationDetails)
    case block(reason: String)
}

/// Decides whether a tool request from Claude may execute.
///
/// Order of checks:
/// 1. The tool must be registered (Claude cannot invent capabilities).
/// 2. Permanently blocked categories never run (defence in depth; the registry
///    already refuses them).
/// 3. Every string argument is scanned for Level 3 material (cards, bank
///    details, keys, passwords, codes, financial destinations).
/// 4. The tool's risk level (or a stricter user override) decides between
///    immediate execution and confirmation.
///
/// The engine can only make a decision stricter than the tool's declared
/// level, never looser.
@MainActor
public final class SafetyEngine {
    private let registry: ToolRegistry
    /// Tools the user has chosen to always confirm, even if they are Level 1.
    public var alwaysConfirm: Set<String> = []
    /// While true (e.g. after an emergency stop), nothing executes.
    public private(set) var isLockedDown = false

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    public func evaluate(toolName: String, input: JSONValue) -> SafetyDecision {
        if isLockedDown {
            return .block(reason: "JARVIS is stopped. Nothing runs until you resume.")
        }
        guard let tool = registry.tool(named: toolName) else {
            return .block(reason: "'\(toolName)' is not a JARVIS tool.")
        }
        let spec = tool.spec
        if spec.category.isPermanentlyBlocked || spec.risk == .blocked || BlockedPolicy.isBlockedToolName(spec.name) {
            return .block(reason: "This capability is permanently blocked.")
        }
        for text in input.allStrings {
            if let finding = BlockedPolicy.scan(text) {
                return .block(reason: finding.explanation)
            }
        }
        let effectiveRisk = alwaysConfirm.contains(toolName) ? max(spec.risk, .confirmationRequired) : spec.risk
        switch effectiveRisk {
        case .safe:
            return .allow
        case .confirmationRequired:
            var details = spec.describe(ToolArguments(input))
            details.risk = .confirmationRequired
            return .requireConfirmation(details)
        case .blocked:
            return .block(reason: "This capability is permanently blocked.")
        }
    }

    public func lockDown() { isLockedDown = true }
    public func resume() { isLockedDown = false }
}
