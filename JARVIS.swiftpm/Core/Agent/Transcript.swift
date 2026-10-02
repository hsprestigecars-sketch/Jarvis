import Foundation

public struct Citation: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var url: String
}

/// An image the user attached (photo picker or camera), sent to Claude
/// together with their message. Nothing is attached without the user choosing it.
public struct ImageAttachment: Codable, Equatable, Sendable {
    public var mediaType: String
    public var base64Data: String
    public var label: String

    public init(mediaType: String, base64Data: String, label: String) {
        self.mediaType = mediaType
        self.base64Data = base64Data
        self.label = label
    }
}

/// What the chat shows. Separate from the API history so the UI can show tool
/// status, notices and protections that are not part of the model's context.
public struct TranscriptItem: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case user(text: String, attachments: [String])
        case assistant(text: String, citations: [Citation])
        case tool(name: String, summary: String, state: ToolState)
        case notice(text: String, style: NoticeStyle)
    }

    public enum ToolState: String, Codable, Sendable {
        case running, succeeded, failed, blocked, cancelled, awaitingConfirmation
    }

    public enum NoticeStyle: String, Codable, Sendable {
        case info, protected, error, stopped
    }

    public let id: UUID
    public var kind: Kind
    public let date: Date

    public init(_ kind: Kind, id: UUID = UUID(), date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.date = date
    }
}

/// Persisted conversation: the exact API history plus the visible transcript.
public struct ConversationSnapshot: Codable, Sendable {
    public var history: [JSONValue]
    public var transcript: [TranscriptItem]
    public var recentRequests: [String]

    public init(history: [JSONValue] = [], transcript: [TranscriptItem] = [], recentRequests: [String] = []) {
        self.history = history
        self.transcript = transcript
        self.recentRequests = recentRequests
    }
}

public protocol ConversationStore: Sendable {
    func load() -> ConversationSnapshot
    func save(_ snapshot: ConversationSnapshot)
}

/// Stores the conversation as a file protected by iOS Data Protection.
public struct FileConversationStore: ConversationStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> ConversationSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ConversationSnapshot.self, from: data)
        else { return ConversationSnapshot() }
        return snapshot
    }

    public func save(_ snapshot: ConversationSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}

public struct InMemoryConversationStore: ConversationStore {
    public init() {}
    public func load() -> ConversationSnapshot { ConversationSnapshot() }
    public func save(_ snapshot: ConversationSnapshot) {}
}
