import Foundation

public enum RegistrationError: Error, LocalizedError, Equatable {
    case blockedCategory(String, ToolCategory)
    case blockedRisk(String)
    case blockedName(String)
    case duplicate(String)
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .blockedCategory(let name, let category):
            "Tool '\(name)' is in the permanently blocked category '\(category.rawValue)'."
        case .blockedRisk(let name):
            "Tool '\(name)' is marked BLOCKED and can never be registered."
        case .blockedName(let name):
            "Tool '\(name)' looks like a financial or credential capability and is refused."
        case .duplicate(let name):
            "Tool '\(name)' is already registered."
        case .invalidName(let name):
            "Tool name '\(name)' is not a valid API tool name."
        }
    }
}

/// The only set of capabilities Claude can ever see or invoke.
///
/// Claude gets no device access of its own: it can request a tool by name and
/// JARVIS decides whether it runs. Anything not registered here does not exist
/// as far as Claude is concerned.
@MainActor
public final class ToolRegistry {
    private var tools: [String: RegisteredTool] = [:]
    private var order: [String] = []

    public init() {}

    public func register(_ tool: RegisteredTool) throws {
        let spec = tool.spec
        guard spec.name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw RegistrationError.invalidName(spec.name)
        }
        guard spec.risk != .blocked else { throw RegistrationError.blockedRisk(spec.name) }
        guard !spec.category.isPermanentlyBlocked else {
            throw RegistrationError.blockedCategory(spec.name, spec.category)
        }
        guard !BlockedPolicy.isBlockedToolName(spec.name) else { throw RegistrationError.blockedName(spec.name) }
        guard tools[spec.name] == nil else { throw RegistrationError.duplicate(spec.name) }
        tools[spec.name] = tool
        order.append(spec.name)
    }

    public func register(_ spec: ToolSpec, handler: @escaping ToolHandler) throws {
        try register(RegisteredTool(spec: spec, handler: handler))
    }

    public func unregister(_ name: String) {
        tools[name] = nil
        order.removeAll { $0 == name }
    }

    public func tool(named name: String) -> RegisteredTool? { tools[name] }

    public var specs: [ToolSpec] { order.compactMap { tools[$0]?.spec } }

    /// Deterministic tool list for the API (stable order keeps prompt caching effective).
    public var apiDefinitions: [JSONValue] { specs.map(\.apiDefinition) }
}
