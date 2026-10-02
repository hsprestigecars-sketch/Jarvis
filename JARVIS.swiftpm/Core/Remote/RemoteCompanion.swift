import Foundation

/// Future Mac companion support.
///
///     iPad JARVIS ── authenticated, encrypted channel ──▶ JARVIS Mac Companion ──▶ Mac tools
///
/// Design rules (enforced by `RemoteToolBridge`):
/// - Pairing is explicit and per device. Being on the same network grants nothing.
/// - The Mac advertises its tools with their own risk levels. The iPad registers
///   them through the normal `ToolRegistry`, so blocked categories and blocked
///   names are refused exactly as for local tools.
/// - The effective risk is never lower than `confirmationRequired` unless the
///   Mac marks a tool `safe` *and* the user has allowed safe remote tools.
/// - Every remote call still passes the iPad's `SafetyEngine` and
///   `ConfirmationEngine`; the Mac re-checks with its own safety layer.

public struct RemoteDeviceIdentity: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Public key fingerprint verified by the user during pairing.
    public var keyFingerprint: String

    public init(id: UUID, name: String, keyFingerprint: String) {
        self.id = id
        self.name = name
        self.keyFingerprint = keyFingerprint
    }
}

/// A tool as advertised by a paired device.
public struct RemoteToolDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var category: ToolCategory
    public var risk: RiskLevel
    public var inputSchema: JSONValue

    public init(name: String, description: String, category: ToolCategory, risk: RiskLevel, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.category = category
        self.risk = risk
        self.inputSchema = inputSchema
    }
}

/// Transport to a paired device. A concrete implementation (for example
/// Network.framework with TLS and a pinned key from pairing) is added with
/// the Mac companion; nothing in the iPad app depends on which one is used.
public protocol RemoteCompanionChannel: Sendable {
    var device: RemoteDeviceIdentity { get }
    func listTools() async throws -> [RemoteToolDescriptor]
    /// `approvalID` proves to the Mac that the iPad user confirmed this exact
    /// call; the Mac verifies it against its own policy before running.
    func invoke(tool: String, input: JSONValue, approvalID: UUID?) async throws -> ToolOutput
    func emergencyStop() async
}

@MainActor
public enum RemoteToolBridge {
    /// Registers a paired device's tools under the `mac_` prefix.
    /// Returns the names that were registered and the ones that were refused.
    @discardableResult
    public static func register(
        channel: RemoteCompanionChannel,
        tools: [RemoteToolDescriptor],
        in registry: ToolRegistry,
        allowSafeRemoteTools: Bool = false
    ) -> (registered: [String], refused: [String]) {
        var registered: [String] = []
        var refused: [String] = []
        for descriptor in tools {
            let name = "mac_" + descriptor.name
            let risk: RiskLevel = (descriptor.risk == .safe && allowSafeRemoteTools) ? .safe : max(descriptor.risk, .confirmationRequired)
            let deviceName = channel.device.name
            let spec = ToolSpec(
                name: name,
                description: "[On \(deviceName)] " + descriptor.description,
                category: descriptor.category,
                risk: risk,
                inputSchema: descriptor.inputSchema,
                returnsUntrustedContent: true,
                describe: { args in
                    ConfirmationDetails(
                        action: "Run \(descriptor.name) on \(deviceName)",
                        target: deviceName,
                        content: args.raw.canonicalString,
                        risk: risk
                    )
                }
            )
            do {
                try registry.register(spec) { args in
                    try await channel.invoke(tool: descriptor.name, input: args.raw, approvalID: risk == .safe ? nil : UUID())
                }
                registered.append(name)
            } catch {
                refused.append(name)
            }
        }
        return (registered, refused)
    }
}
