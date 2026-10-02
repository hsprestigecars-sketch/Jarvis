import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ClaudeConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var model: String
    /// `low`, `medium`, `high`, `xhigh` or `max`. Lower is faster, which
    /// suits a voice assistant; research and coding benefit from higher.
    public var effort: String
    public var maxTokens: Int
    /// Anthropic-hosted web search and fetch (Level 1, read-only).
    public var webResearchEnabled: Bool
    /// Server-side fallback when a safety classifier declines a request.
    public var refusalFallbackEnabled: Bool
    public var baseURL: URL

    public init(
        apiKey: String,
        model: String = "claude-opus-5-5",
        effort: String = "medium",
        maxTokens: Int = 16000,
        webResearchEnabled: Bool = true,
        refusalFallbackEnabled: Bool = true,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.webResearchEnabled = webResearchEnabled
        self.refusalFallbackEnabled = refusalFallbackEnabled
        self.baseURL = baseURL
    }
}

public enum ClaudeError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, type: String?, message: String)
    case invalidResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No Claude API key is set. Add one in Settings."
        case .http(let status, let type, let message):
            switch status {
            case 401: "Claude rejected the API key. Check it in Settings."
            case 429: "Claude is rate-limiting requests. Try again in a moment."
            case 529, 503: "Claude is temporarily overloaded. Try again shortly."
            default: "Claude API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
            }
        case .invalidResponse(let message):
            "Unexpected response from Claude: \(message)"
        case .network(let message):
            "Network problem: \(message)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .http(let status, _, _): status == 429 || status == 408 || status >= 500
        case .network: true
        default: false
        }
    }
}

/// Sends one Messages API request. Abstracted so the agent loop can be tested
/// without the network and so a future Mac relay can stand in for it.
public protocol ClaudeTransport: Sendable {
    func createMessage(_ body: JSONValue, configuration: ClaudeConfiguration) async throws -> JSONValue
}

/// Raw HTTPS client for `POST /v1/messages`. There is no official Anthropic
/// SDK for Swift, so this speaks the documented HTTP API directly.
public struct AnthropicHTTPTransport: ClaudeTransport {
    private let session: URLSession
    private let maxRetries: Int

    public init(session: URLSession = .shared, maxRetries: Int = 2) {
        self.session = session
        self.maxRetries = maxRetries
    }

    public func createMessage(_ body: JSONValue, configuration: ClaudeConfiguration) async throws -> JSONValue {
        guard !configuration.apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if configuration.refusalFallbackEnabled {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(body)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await send(request)
            } catch let error as ClaudeError where error.isRetryable && attempt < maxRetries {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 1.5))
            }
        }
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ClaudeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse("not an HTTP response")
        }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let errorObject = json?["error"]
            throw ClaudeError.http(
                status: http.statusCode,
                type: errorObject?["type"]?.stringValue,
                message: errorObject?["message"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self)
            )
        }
        guard let json else { throw ClaudeError.invalidResponse("body is not JSON") }
        return json
    }
}

/// Builds Messages API request bodies.
public enum ClaudeRequestBuilder {
    public static func body(
        configuration: ClaudeConfiguration,
        system: String,
        tools: [JSONValue],
        messages: [JSONValue]
    ) -> JSONValue {
        var allTools = tools
        if configuration.webResearchEnabled {
            allTools.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 8])
            allTools.append(["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 8])
        }
        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "max_tokens": .number(Double(configuration.maxTokens)),
            // The system prompt is stable, so it is cached; tools render before
            // it and are also covered by this breakpoint.
            "system": [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]],
            "messages": .array(messages),
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": .string(configuration.effort)],
        ]
        if !allTools.isEmpty {
            body["tools"] = .array(allTools)
        }
        if configuration.refusalFallbackEnabled {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }
}
