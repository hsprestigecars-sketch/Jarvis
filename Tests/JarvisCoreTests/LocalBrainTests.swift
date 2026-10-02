import XCTest
@testable import JarvisCore

/// A stand-in for Apple's on-device model that calls one tool, then replies.
@MainActor
final class FakeLocalBackend: LocalReasoningBackend {
    var unavailableReason: String?
    var allowedToolNames: Set<String> = ["create_reminder", "send_message"]
    var toolToCall: (String, JSONValue)?
    var offeredTools: [String] = []
    var toolResult: String?

    func respond(
        to request: String, context: String, recentConversation: String, tools: [ToolSpec],
        runTool: @escaping @MainActor @Sendable (String, JSONValue) async -> String
    ) async throws -> String {
        offeredTools = tools.map(\.name)
        if let (name, input) = toolToCall {
            toolResult = await runTool(name, input)
        }
        return "Done: \(toolResult ?? "no tool")"
    }

    func cancel() {}
}

@MainActor
final class LocalBrainTests: XCTestCase {
    func testOnDeviceBrainNeedsNoAPIAndOnlySeesAllowedTools() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(responses: [], spy: spy)
        let backend = FakeLocalBackend()
        backend.toolToCall = ("create_reminder", ["title": "Bring racing helmet"])
        agent.localBackend = backend
        agent.brainSelector = { .onDevice }

        agent.submit("remind me to bring my racing helmet")
        await waitUntil { !agent.isBusy }

        XCTAssertEqual(transport.requestCount, 0, "Claude must not be called")
        XCTAssertEqual(Set(backend.offeredTools), ["create_reminder", "send_message"])
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(agent.status, .ready)
        XCTAssertEqual(agent.lastBrain, .onDevice)
    }

    func testOnDeviceToolCallsStillNeedConfirmation() async throws {
        let spy = ToolSpy()
        let (agent, _) = try makeAgent(responses: [], spy: spy)
        let backend = FakeLocalBackend()
        backend.toolToCall = ("send_message", ["recipient": "Dad", "message": "Home later"])
        agent.localBackend = backend
        agent.brainSelector = { .onDevice }

        agent.submit("tell dad I'll be home later")
        await waitUntil { !agent.confirmations.pending.isEmpty }
        XCTAssertTrue(spy.calls.isEmpty)
        agent.submit("Cancel")
        await waitUntil { !agent.isBusy }
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertTrue(backend.toolResult?.hasPrefix("ERROR:") ?? false)
    }

    func testOnDeviceBlockedArguments() async throws {
        let spy = ToolSpy()
        let (agent, _) = try makeAgent(responses: [], spy: spy)
        let backend = FakeLocalBackend()
        backend.toolToCall = ("create_reminder", ["title": "card 4111 1111 1111 1111"])
        agent.localBackend = backend
        agent.brainSelector = { .onDevice }

        agent.submit("remind me of something")
        await waitUntil { !agent.isBusy }
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertTrue(backend.toolResult?.contains("BLOCKED") ?? false)
    }

    func testUnavailableModelShowsError() async throws {
        let spy = ToolSpy()
        let (agent, _) = try makeAgent(responses: [], spy: spy)
        let backend = FakeLocalBackend()
        backend.unavailableReason = "Apple Intelligence is turned off."
        agent.localBackend = backend
        agent.brainSelector = { .onDevice }

        agent.submit("hello")
        await waitUntil { !agent.isBusy }
        if case .error(let message) = agent.status {
            XCTAssertTrue(message.contains("Apple Intelligence is turned off."))
        } else {
            XCTFail("expected error status")
        }
    }
}
