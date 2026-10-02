import Foundation
import Observation

/// The JARVIS pipeline:
///
///     input → CommandProcessor (stop / cancel / confirm / protected)
///           → Claude (reasoning, tool requests)
///           → SafetyEngine (allow / confirm / block)
///           → ConfirmationEngine (Level 2)
///           → tool handler
///           → result back to Claude → response
@MainActor
@Observable
public final class JarvisAgent {
    public private(set) var status: JarvisStatus = .ready
    public private(set) var transcript: [TranscriptItem] = []
    public private(set) var recentRequests: [String] = []
    public var isBusy: Bool { currentTask != nil }

    /// Called with the final reply text so the voice layer can speak it.
    @ObservationIgnored public var onReply: ((String) -> Void)?
    /// Called when JARVIS should stop all audio immediately.
    @ObservationIgnored public var onStopSpeech: (() -> Void)?
    /// Extra per-turn context (e.g. battery), appended to the context line.
    @ObservationIgnored public var contextProvider: (() -> String?)?

    public let registry: ToolRegistry
    public let safety: SafetyEngine
    public let confirmations: ConfirmationEngine
    public let emergencyStop: EmergencyStop
    private let transport: ClaudeTransport
    private let configuration: () -> ClaudeConfiguration
    private let store: ConversationStore
    @ObservationIgnored private var history: [JSONValue] = []
    private var currentTask: Task<Void, Never>?
    /// Identifies the turn allowed to change the history. A replaced or
    /// stopped turn can finish unwinding but can never write again.
    @ObservationIgnored private var activeTurn = UUID()
    private let maxToolRounds = 16

    public init(
        registry: ToolRegistry,
        confirmations: ConfirmationEngine? = nil,
        emergencyStop: EmergencyStop? = nil,
        transport: ClaudeTransport = AnthropicHTTPTransport(),
        store: ConversationStore = InMemoryConversationStore(),
        configuration: @escaping () -> ClaudeConfiguration
    ) {
        self.registry = registry
        self.safety = SafetyEngine(registry: registry)
        self.confirmations = confirmations ?? ConfirmationEngine()
        self.emergencyStop = emergencyStop ?? EmergencyStop()
        self.transport = transport
        self.store = store
        self.configuration = configuration

        let snapshot = store.load()
        history = snapshot.history
        transcript = snapshot.transcript
        recentRequests = snapshot.recentRequests
        repairHistory()

        self.emergencyStop.register("Cancel pending confirmations") { [weak self] in
            self?.confirmations.cancelAll()
        }
        self.emergencyStop.register("Cancel JARVIS task") { [weak self] in
            self?.cancelCurrentTask()
        }
        self.emergencyStop.register("Stop speech") { [weak self] in
            self?.onStopSpeech?()
        }
    }

    // MARK: Input

    /// Entry point for everything the user says or types.
    public func submit(_ input: String, images: [ImageAttachment] = []) {
        let command = CommandProcessor.classify(input, hasPendingConfirmation: !confirmations.pending.isEmpty)
        switch command {
        case .empty:
            if !images.isEmpty { startTurn(text: "", images: images) }
        case .emergencyStop:
            triggerEmergencyStop()
        case .cancel:
            if confirmations.cancelMostRecent() {
                append(.notice(text: "Cancelled.", style: .info))
            } else if isBusy {
                cancelCurrentTask()
                append(.notice(text: "Cancelled.", style: .info))
                status = .ready
            } else {
                append(.notice(text: "Nothing to cancel.", style: .info))
            }
        case .confirm:
            if !confirmations.confirmSoleAction() {
                append(.notice(text: "More than one action is waiting. Tap the one you want to confirm.", style: .info))
            }
        case .protected(let finding):
            append(.user(text: input, attachments: []))
            let message = "I can't do that. \(finding.explanation) This is a permanent JARVIS protection."
            append(.notice(text: message, style: .protected))
            status = .protected(finding.explanation)
            onReply?(message)
        case .forward(let text):
            startTurn(text: text, images: images)
        }
    }

    public func triggerEmergencyStop() {
        safety.lockDown()
        emergencyStop.trigger()
        append(.notice(text: "Emergency stop. All JARVIS actions were stopped and pending actions cancelled.", style: .stopped))
        status = .ready
        safety.resume()
        persist()
    }

    public func clearConversation() {
        cancelCurrentTask()
        confirmations.cancelAll()
        history = []
        transcript = []
        status = .ready
        persist()
    }

    public func setListening(_ listening: Bool) {
        if listening { status = .listening } else if status == .listening { status = .ready }
    }

    public func setSpeaking(_ speaking: Bool) {
        if speaking { status = .speaking } else if status == .speaking { status = .ready }
    }

    // MARK: Turn

    private func startTurn(text: String, images: [ImageAttachment]) {
        cancelCurrentTask()
        repairHistory()
        let turn = UUID()
        activeTurn = turn
        if !text.isEmpty {
            recentRequests.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
            recentRequests.insert(text, at: 0)
            recentRequests = Array(recentRequests.prefix(12))
        }
        append(.user(text: text, attachments: images.map(\.label)))

        var content: [JSONValue] = images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64Data)]]
        }
        let userText = text.isEmpty ? "(The user attached the content above without a message.)" : text
        content.append(["type": "text", "text": .string(userText)])
        content.append(["type": "text", "text": .string(SystemPrompt.contextLine(extra: contextProvider?()))])
        history.append(["role": "user", "content": .array(content)])

        currentTask = Task { [weak self] in
            await self?.runLoop(turn: turn)
            if self?.activeTurn == turn { self?.currentTask = nil }
        }
    }

    /// Throws `CancellationError` if this turn was cancelled or replaced.
    private func ensureActive(_ turn: UUID) throws {
        if Task.isCancelled || turn != activeTurn { throw CancellationError() }
    }

    private func runLoop(turn: UUID) async {
        status = .thinking
        do {
            for _ in 0..<maxToolRounds {
                try ensureActive(turn)
                let config = configuration()
                let body = ClaudeRequestBuilder.body(
                    configuration: config, system: SystemPrompt.text,
                    tools: registry.apiDefinitions, messages: history
                )
                let response = try await transport.createMessage(body, configuration: config)
                try ensureActive(turn)

                let stopReason = response["stop_reason"]?.stringValue
                let content = response["content"]?.arrayValue ?? []

                if stopReason == "refusal" {
                    // Drop the declined turn so the conversation stays usable.
                    if let last = history.last, last["role"]?.stringValue == "user" { history.removeLast() }
                    finish(reply: "I can't help with that request.", citations: [])
                    return
                }

                // Append the assistant content unchanged (thinking blocks included).
                history.append(["role": "assistant", "content": .array(content)])

                if stopReason == "pause_turn" {
                    // A server tool (web search) paused a long turn; resend to continue.
                    continue
                }

                let toolUses = content.filter { $0["type"]?.stringValue == "tool_use" }
                let (text, citations) = Self.extractText(content)

                if toolUses.isEmpty {
                    let reply = stopReason == "max_tokens" ? text + "\n\n_(Reply cut short.)_" : text
                    finish(reply: reply, citations: citations)
                    return
                }

                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    append(.assistant(text: text, citations: citations))
                }

                var results: [JSONValue] = []
                for toolUse in toolUses {
                    results.append(await runTool(toolUse))
                }
                try ensureActive(turn)
                history.append(["role": "user", "content": .array(results)])
                persist()
                status = .thinking
            }
            finish(reply: "I stopped after too many steps. Tell me how you'd like to continue.", citations: [])
        } catch is CancellationError {
            if turn == activeTurn {
                repairHistory()
                persist()
            }
        } catch {
            guard turn == activeTurn else { return }
            repairHistory()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            append(.notice(text: message, style: .error))
            status = .error(message)
            persist()
        }
    }

    private func finish(reply: String, citations: [Citation]) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            append(.assistant(text: trimmed, citations: citations))
            onReply?(trimmed)
        }
        status = .ready
        persist()
    }

    // MARK: Tools

    private func runTool(_ toolUse: JSONValue) async -> JSONValue {
        let id = toolUse["id"]?.stringValue ?? ""
        let name = toolUse["name"]?.stringValue ?? ""
        let input = toolUse["input"] ?? [:]

        func result(_ text: String, isError: Bool) -> JSONValue {
            ["type": "tool_result", "tool_use_id": .string(id), "content": .string(text), "is_error": .bool(isError)]
        }

        if Task.isCancelled {
            return result("Cancelled by the user.", isError: true)
        }

        let executableInput: JSONValue
        switch safety.evaluate(toolName: name, input: input) {
        case .block(let reason):
            append(.tool(name: name, summary: reason, state: .blocked))
            status = .protected(reason)
            return result(
                "BLOCKED BY JARVIS SAFETY POLICY: \(reason) This is enforced in code. Do not retry or attempt the same outcome another way; tell the user it is a permanent protection.",
                isError: true
            )
        case .requireConfirmation(let details):
            let itemID = append(.tool(name: name, summary: details.action, state: .awaitingConfirmation))
            status = .waitingForConfirmation
            let decision = await confirmations.request(toolName: name, input: input, details: details)
            switch decision {
            case .confirmed(let frozen):
                // Re-check after the wait: an emergency stop may have happened.
                guard !Task.isCancelled, !safety.isLockedDown else {
                    update(itemID, state: .cancelled, summary: "Stopped")
                    return result("Cancelled by the user.", isError: true)
                }
                update(itemID, state: .running, summary: details.action)
                executableInput = frozen
            case .cancelled, .expired:
                update(itemID, state: .cancelled, summary: "Cancelled: \(details.action)")
                status = .thinking
                return result("The user did not confirm this action. It was not performed. Do not retry unless the user asks again.", isError: true)
            }
            return await execute(name: name, input: executableInput, existingItem: itemID, wrap: result)
        case .allow:
            executableInput = input
        }
        return await execute(name: name, input: executableInput, existingItem: nil, wrap: result)
    }

    private func execute(
        name: String, input: JSONValue, existingItem: UUID?,
        wrap: (String, Bool) -> JSONValue
    ) async -> JSONValue {
        guard let tool = registry.tool(named: name) else { return wrap("Unknown tool.", true) }
        guard !Task.isCancelled else { return wrap("Cancelled by the user.", true) }
        let itemID = existingItem ?? append(.tool(name: name, summary: tool.spec.description.components(separatedBy: ".").first ?? name, state: .running))
        status = .working(Self.workingLabel(for: tool.spec))
        do {
            let output = try await tool.handler(ToolArguments(input))
            var text = BlockedPolicy.redact(output.text)
            if tool.spec.returnsUntrustedContent {
                text = UntrustedContent.wrap(text, source: "tool:\(name)")
            }
            update(itemID, state: output.isError ? .failed : .succeeded, summary: output.summary)
            status = .thinking
            return wrap(text, output.isError)
        } catch is CancellationError {
            update(itemID, state: .cancelled, summary: "Stopped")
            return wrap("Cancelled by the user.", true)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(itemID, state: .failed, summary: message)
            status = .thinking
            return wrap(message, true)
        }
    }

    static func workingLabel(for spec: ToolSpec) -> String {
        switch spec.category {
        case .calendar: "Checking your calendar"
        case .reminders: "Working on reminders"
        case .notes: "Working on notes"
        case .files: "Working with files"
        case .photos, .camera: "Working with media"
        case .web: "Researching"
        case .social: "Preparing social content"
        case .communication: "Preparing message"
        case .remote: "Talking to your Mac"
        default: "Working"
        }
    }

    // MARK: History

    /// Ensures every `tool_use` has a matching `tool_result`, so an interrupted
    /// turn never leaves the conversation in a state the API rejects.
    private func repairHistory() {
        guard let last = history.last, last["role"]?.stringValue == "assistant" else { return }
        let ids = (last["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "tool_use" }
            .compactMap { $0["id"]?.stringValue }
        guard !ids.isEmpty else { return }
        let results: [JSONValue] = ids.map {
            ["type": "tool_result", "tool_use_id": .string($0), "content": "Cancelled by the user (emergency stop).", "is_error": true]
        }
        history.append(["role": "user", "content": .array(results)])
    }

    private func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        if status != .ready, !isProtectedOrError { status = .ready }
    }

    private var isProtectedOrError: Bool {
        switch status {
        case .protected, .error: true
        default: false
        }
    }

    static func extractText(_ content: [JSONValue]) -> (String, [Citation]) {
        var text = ""
        var citations: [Citation] = []
        for block in content where block["type"]?.stringValue == "text" {
            text += block["text"]?.stringValue ?? ""
            for citation in block["citations"]?.arrayValue ?? [] {
                guard let url = citation["url"]?.stringValue else { continue }
                let item = Citation(title: citation["title"]?.stringValue ?? url, url: url)
                if !citations.contains(item) { citations.append(item) }
            }
        }
        return (text, citations)
    }

    // MARK: Transcript

    @discardableResult
    private func append(_ kind: TranscriptItem.Kind) -> UUID {
        let item = TranscriptItem(kind)
        transcript.append(item)
        if transcript.count > 400 { transcript.removeFirst(transcript.count - 400) }
        return item.id
    }

    private func update(_ id: UUID, state: TranscriptItem.ToolState, summary: String) {
        guard let index = transcript.firstIndex(where: { $0.id == id }),
              case .tool(let name, _, _) = transcript[index].kind else { return }
        transcript[index].kind = .tool(name: name, summary: summary, state: state)
    }

    private func persist() {
        store.save(ConversationSnapshot(history: history, transcript: transcript, recentRequests: recentRequests))
    }
}
