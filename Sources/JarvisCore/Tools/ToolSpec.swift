import Foundation

/// Safety level of a tool. Assigned in code by JARVIS, never by Claude.
public enum RiskLevel: String, Codable, Sendable, Comparable {
    /// Level 1 — executes immediately.
    case safe
    /// Level 2 — never executes until the user confirms the exact action.
    case confirmationRequired
    /// Level 3 — can never execute. Tools at this level cannot even be registered.
    case blocked

    private var rank: Int {
        switch self {
        case .safe: 0
        case .confirmationRequired: 1
        case .blocked: 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .safe: "SAFE"
        case .confirmationRequired: "CONFIRMATION REQUIRED"
        case .blocked: "BLOCKED"
        }
    }
}

/// What a tool touches. Some categories are permanently blocked by policy.
public enum ToolCategory: String, Codable, Sendable, CaseIterable {
    // Permitted categories
    case information, calendar, reminders, notes, files, photos, camera
    case device, communication, social, web, coding, planning, remote

    // Permanently blocked categories (Level 3). Listed so that the registry can
    // refuse them explicitly; no tool in these categories can ever be registered.
    case banking, payments, trading, cryptocurrency, credentials, authenticationCodes
    case businessFinancialSystems, sensitiveCustomerData

    public var isPermanentlyBlocked: Bool {
        switch self {
        case .banking, .payments, .trading, .cryptocurrency, .credentials,
             .authenticationCodes, .businessFinancialSystems, .sensitiveCustomerData:
            true
        default:
            false
        }
    }
}

/// The human-readable summary shown on a confirmation card. Built by JARVIS
/// from the frozen arguments, not written by Claude.
public struct ConfirmationDetails: Equatable, Sendable {
    public var action: String
    public var target: String?
    public var content: String?
    public var account: String?
    public var settings: [Setting]
    public var risk: RiskLevel

    public struct Setting: Equatable, Sendable {
        public var name: String
        public var value: String
        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public init(
        action: String, target: String? = nil, content: String? = nil,
        account: String? = nil, settings: [Setting] = [], risk: RiskLevel = .confirmationRequired
    ) {
        self.action = action
        self.target = target
        self.content = content
        self.account = account
        self.settings = settings
        self.risk = risk
    }
}

/// The interface definition of a tool.
public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let category: ToolCategory
    public let risk: RiskLevel
    public let inputSchema: JSONValue
    /// Whether the tool's output contains third-party content (web pages,
    /// file contents, notes) that must be treated as untrusted data.
    public let returnsUntrustedContent: Bool
    /// Builds the confirmation card for Level 2 tools.
    public let describe: @MainActor @Sendable (ToolArguments) -> ConfirmationDetails

    public init(
        name: String,
        description: String,
        category: ToolCategory,
        risk: RiskLevel,
        inputSchema: JSONValue,
        returnsUntrustedContent: Bool = false,
        describe: (@MainActor @Sendable (ToolArguments) -> ConfirmationDetails)? = nil
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.risk = risk
        self.inputSchema = inputSchema
        self.returnsUntrustedContent = returnsUntrustedContent
        self.describe = describe ?? { args in
            ConfirmationDetails(action: name, content: args.raw.canonicalString, risk: risk)
        }
    }

    /// The tool definition sent to the Claude API.
    public var apiDefinition: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema,
        ]
    }
}

/// The result of running a tool.
public struct ToolOutput: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    /// Short line shown in the chat's tool-status row.
    public var summary: String

    public init(_ text: String, summary: String? = nil, isError: Bool = false) {
        self.text = text
        self.isError = isError
        self.summary = summary ?? String(text.prefix(120))
    }

    public static func error(_ text: String) -> ToolOutput {
        ToolOutput(text, summary: text, isError: true)
    }
}

public enum ToolError: Error, LocalizedError, Equatable {
    case invalidArguments(String)
    case permissionDenied(String)
    case unavailable(String)
    case notConnected(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): "Invalid arguments: \(message)"
        case .permissionDenied(let message): "Permission denied: \(message)"
        case .unavailable(let message): "Not available on this iPad: \(message)"
        case .notConnected(let message): "Not connected: \(message)"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

public typealias ToolHandler = @MainActor @Sendable (ToolArguments) async throws -> ToolOutput

/// A tool spec paired with the code that runs it.
public struct RegisteredTool: Sendable {
    public let spec: ToolSpec
    public let handler: ToolHandler

    public init(spec: ToolSpec, handler: @escaping ToolHandler) {
        self.spec = spec
        self.handler = handler
    }
}
