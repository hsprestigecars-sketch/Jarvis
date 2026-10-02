import XCTest
@testable import JarvisCore

@MainActor
final class SafetyTests: XCTestCase {
    func testBlockedCategoriesCannotBeRegistered() {
        let registry = ToolRegistry()
        for category in ToolCategory.allCases where category.isPermanentlyBlocked {
            let spec = ToolSpec(name: "tool_\(category.rawValue)", description: "x", category: category, risk: .safe, inputSchema: Schema.object([:]))
            XCTAssertThrowsError(try registry.register(spec) { _ in ToolOutput("") }, "\(category) must be refused")
        }
    }

    func testBlockedRiskAndNamesCannotBeRegistered() {
        let registry = ToolRegistry()
        let blocked = ToolSpec(name: "anything", description: "x", category: .information, risk: .blocked, inputSchema: Schema.object([:]))
        XCTAssertThrowsError(try registry.register(blocked) { _ in ToolOutput("") })
        for name in ["bank_transfer", "get_password", "read_otp", "send_crypto", "trade_stock", "pay_invoice"] {
            let spec = ToolSpec(name: name, description: "x", category: .information, risk: .safe, inputSchema: Schema.object([:]))
            XCTAssertThrowsError(try registry.register(spec) { _ in ToolOutput("") }, name)
        }
    }

    func testUnknownToolIsBlocked() {
        let engine = SafetyEngine(registry: ToolRegistry())
        if case .block = engine.evaluate(toolName: "shell", input: [:]) {} else { XCTFail("unknown tool must be blocked") }
    }

    func testArgumentScanning() {
        let blocked: [String] = [
            "4111 1111 1111 1111",
            "My bank password is hunter2",
            "password: \"hunter22\"",
            "Your verification code is 482913",
            "OTP 123456",
            "here are my backup codes",
            "my seed phrase is apple banana",
            "GB82 WEST 1234 5698 7654 32",
            "account number: 12345678",
            "https://www.paypal.com/send",
            "https://secure.chase.com",
            "coinbase://send",
            "wire transfer to John",
        ]
        for text in blocked {
            XCTAssertNotNil(BlockedPolicy.scan(text), "should block: \(text)")
        }
        let allowed: [String] = [
            "Bring racing helmet",
            "Karting practice Saturday at 3pm",
            "let password: String = field.text",
            "Remind me to change my password",
            "Edit my racing video at 8 PM",
            "https://www.youtube.com/watch?v=abc",
            "Order number 2026-10-03",
            "Call Dad about the race on 12/10",
            "struct SwiftUIView: View {}",
            "Swift code SwiftUIView",
        ]
        for text in allowed {
            XCTAssertNil(BlockedPolicy.scan(text), "should allow: \(text)")
        }
    }

    func testRequestClassifier() {
        let blocked = [
            "JARVIS, transfer $50 to Alex",
            "send 0.1 bitcoin to my brother",
            "buy 10 shares of Apple",
            "what's my bank password",
            "read me the verification code I just got",
            "check my bank balance",
            "log into my bank",
            "what's my seed phrase",
        ]
        for text in blocked {
            XCTAssertNotNil(BlockedPolicy.classifyRequest(text), "should protect: \(text)")
        }
        let allowed = [
            "what is a good brokerage for beginners?",
            "research the best camera for karting",
            "remind me to pay rent tomorrow",
            "send Dad a message that I'll pay him back $20",
            "explain how two factor authentication works",
            "what is a strong password?",
            "are banks open on bank holidays",
        ]
        for text in allowed {
            XCTAssertNil(BlockedPolicy.classifyRequest(text), "should allow: \(text)")
        }
    }

    func testRedaction() {
        let redacted = BlockedPolicy.redact("card 4111-1111-1111-1111 ok")
        XCTAssertFalse(redacted.contains("4111"))
        XCTAssertTrue(redacted.contains("[REDACTED CARD NUMBER]"))
    }

    func testRiskOverrideOnlyTightens() throws {
        let registry = ToolRegistry()
        try registry.register(ToolSpec(name: "start_timer", description: "x", category: .device, risk: .safe, inputSchema: Schema.object([:]))) { _ in ToolOutput("") }
        let engine = SafetyEngine(registry: registry)
        XCTAssertEqual(engine.evaluate(toolName: "start_timer", input: [:]), .allow)
        engine.alwaysConfirm = ["start_timer"]
        if case .requireConfirmation = engine.evaluate(toolName: "start_timer", input: [:]) {} else { XCTFail() }
    }
}
