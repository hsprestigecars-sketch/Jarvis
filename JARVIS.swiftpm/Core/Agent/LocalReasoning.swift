import Foundation

/// Which model does the thinking.
public enum Brain: String, Codable, Sendable, CaseIterable {
    /// Claude through the Anthropic API (needs an API key).
    case claude
    /// A model that runs entirely on the device (free, offline, more limited).
    case onDevice
}

/// A reasoning model that runs on the device, such as Apple's on-device
/// foundation model. It gets the same JARVIS tools as Claude, and every tool
/// call it makes still goes through the SafetyEngine and ConfirmationEngine
/// via `runTool`.
@MainActor
public protocol LocalReasoningBackend: AnyObject {
    /// Nil when the model can be used; otherwise a sentence explaining why not.
    var unavailableReason: String? { get }

    /// Tools small enough for the model's context. Others are not offered.
    var allowedToolNames: Set<String> { get }

    func respond(
        to request: String,
        context: String,
        recentConversation: String,
        tools: [ToolSpec],
        runTool: @escaping @MainActor @Sendable (String, JSONValue) async -> String
    ) async throws -> String

    /// Stop any generation in progress (emergency stop).
    func cancel()
}
