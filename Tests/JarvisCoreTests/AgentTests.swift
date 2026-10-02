import XCTest
@testable import JarvisCore

@MainActor
final class AgentTests: XCTestCase {
    func testSafeToolRunsImmediately() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(
            responses: [ScriptedTransport.toolUse("create_reminder", ["title": "Bring racing helmet"]), ScriptedTransport.text("Done.")],
            spy: spy
        )
        agent.submit("remind me to bring my racing helmet tomorrow")
        await waitUntil { !agent.isBusy && transport.requestCount == 2 }
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(agent.status, .ready)

        // The assistant turn (with its thinking block) is replayed unchanged.
        let secondMessages = transport.requests[1]["messages"]?.arrayValue ?? []
        XCTAssertEqual(secondMessages.count, 3)
        XCTAssertEqual(secondMessages[1]["content"]?.arrayValue?.first?["type"]?.stringValue, "thinking")
        XCTAssertEqual(secondMessages[2]["content"]?.arrayValue?.first?["type"]?.stringValue, "tool_result")
    }

    func testConfirmationRequiredToolWaitsAndRunsFrozenArguments() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(
            responses: [ScriptedTransport.toolUse("send_message", ["recipient": "Dad", "message": "I'll be home later."]), ScriptedTransport.text("Sent.")],
            spy: spy
        )
        agent.submit("tell dad I'll be home later")
        await waitUntil { !agent.confirmations.pending.isEmpty }
        XCTAssertEqual(agent.status, .waitingForConfirmation)
        XCTAssertTrue(spy.calls.isEmpty, "must not run before confirmation")

        let action = try XCTUnwrap(agent.confirmations.pending.first)
        XCTAssertEqual(action.details.target, "Dad")
        XCTAssertFalse(agent.confirmations.confirm(id: action.id, fingerprint: "send_message|{}"), "a different action must not be confirmable")
        XCTAssertTrue(agent.confirmations.confirm(id: action.id, fingerprint: action.fingerprint))

        await waitUntil { !agent.isBusy && transport.requestCount == 2 }
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.1["message"]?.stringValue, "I'll be home later.")
    }

    func testCancelPreventsExecution() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(
            responses: [ScriptedTransport.toolUse("send_message", ["recipient": "Dad", "message": "Hi"]), ScriptedTransport.text("Okay, not sent.")],
            spy: spy
        )
        agent.submit("message dad hi")
        await waitUntil { !agent.confirmations.pending.isEmpty }
        agent.submit("Cancel")
        await waitUntil { !agent.isBusy && transport.requestCount == 2 }
        XCTAssertTrue(spy.calls.isEmpty)
        let lastRequest = transport.requests[1]["messages"]?.arrayValue?.last
        XCTAssertEqual(lastRequest?["content"]?.arrayValue?.first?["is_error"]?.boolValue, true)
    }

    func testEmergencyStopCancelsEverythingAndRepairsHistory() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(
            responses: [ScriptedTransport.toolUse("send_message", ["recipient": "Dad", "message": "Hi"]), ScriptedTransport.text("Hello again.")],
            spy: spy
        )
        var speechStopped = false
        agent.onStopSpeech = { speechStopped = true }
        agent.submit("message dad hi")
        await waitUntil { !agent.confirmations.pending.isEmpty }
        agent.submit("JARVIS, STOP!")
        XCTAssertTrue(agent.confirmations.pending.isEmpty)
        XCTAssertTrue(speechStopped)
        XCTAssertFalse(agent.isBusy)
        XCTAssertTrue(spy.calls.isEmpty)

        // The next turn must still produce a valid history (tool_use answered).
        agent.submit("hello")
        await waitUntil { !agent.isBusy && transport.requestCount == 2 }
        let messages = transport.requests[1]["messages"]?.arrayValue ?? []
        let roles = messages.compactMap { $0["role"]?.stringValue }
        XCTAssertEqual(roles, ["user", "assistant", "user", "user"])
        XCTAssertEqual(messages[2]["content"]?.arrayValue?.first?["type"]?.stringValue, "tool_result")
    }

    func testBlockedArgumentsNeverReachTool() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(
            responses: [ScriptedTransport.toolUse("create_reminder", ["title": "Card 4111 1111 1111 1111"]), ScriptedTransport.text("I can't do that.")],
            spy: spy
        )
        agent.submit("remind me about something")
        await waitUntil { !agent.isBusy && transport.requestCount == 2 }
        XCTAssertTrue(spy.calls.isEmpty)
        let result = transport.requests[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue?.first
        XCTAssertTrue(result?["content"]?.stringValue?.contains("BLOCKED") ?? false)
    }

    func testProtectedRequestNeverReachesClaude() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(responses: [], spy: spy)
        agent.submit("JARVIS, transfer $500 to my savings")
        XCTAssertEqual(transport.requestCount, 0)
        if case .protected = agent.status {} else { XCTFail("status should be PROTECTED") }
    }

    func testUntrustedToolOutputIsWrappedAndRedacted() async throws {
        let spy = ToolSpy()
        let (agent, transport) = try makeAgent(
            responses: [ScriptedTransport.toolUse("read_file", ["path": "notes.txt"]), ScriptedTransport.text("Here it is.")],
            spy: spy
        )
        agent.submit("read notes.txt")
        await waitUntil { !agent.isBusy && transport.requestCount == 2 }
        let content = transport.requests[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue?.first?["content"]?.stringValue ?? ""
        XCTAssertTrue(content.hasPrefix("<untrusted_content"))
        XCTAssertFalse(content.contains("4111"))
    }

    func testRequestBodyShape() {
        let body = ClaudeRequestBuilder.body(configuration: ClaudeConfiguration(apiKey: "k"), system: "s", tools: [], messages: [])
        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5-5")
        XCTAssertEqual(body["thinking"]?["type"]?.stringValue, "adaptive")
        XCTAssertEqual(body["fallbacks"]?.stringValue, "default")
        let toolTypes = body["tools"]?.arrayValue?.compactMap { $0["type"]?.stringValue } ?? []
        XCTAssertEqual(toolTypes, ["web_search_20260209", "web_fetch_20260209"])
    }
}
