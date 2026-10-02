import Foundation

public enum SocialPlatform: String, Codable, CaseIterable, Sendable {
    case instagram, tiktok

    public var displayName: String {
        switch self {
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        }
    }

    /// Constraints JARVIS checks when preparing a post.
    public var captionLimit: Int {
        switch self {
        case .instagram: 2200
        case .tiktok: 2200
        }
    }

    public var hashtagLimit: Int {
        switch self {
        case .instagram: 30
        case .tiktok: 30
        }
    }
}

public struct SocialAccount: Codable, Equatable, Sendable {
    public var platform: SocialPlatform
    public var handle: String
    public init(platform: SocialPlatform, handle: String) {
        self.platform = platform
        self.handle = handle
    }
}

public struct SocialPostDraft: Codable, Equatable, Sendable {
    public var platform: SocialPlatform
    public var caption: String
    public var hashtags: [String]
    public var mediaFiles: [String]
    public var visibility: String

    public init(platform: SocialPlatform, caption: String, hashtags: [String], mediaFiles: [String], visibility: String) {
        self.platform = platform
        self.caption = caption
        self.hashtags = hashtags
        self.mediaFiles = mediaFiles
        self.visibility = visibility
    }

    public var fullCaption: String {
        let tags = hashtags.map { $0.hasPrefix("#") ? $0 : "#" + $0 }.joined(separator: " ")
        return tags.isEmpty ? caption : caption + "\n\n" + tags
    }

    /// Problems that would make the official platform reject the post.
    public var validationIssues: [String] {
        var issues: [String] = []
        if fullCaption.count > platform.captionLimit {
            issues.append("Caption is \(fullCaption.count) characters; \(platform.displayName) allows \(platform.captionLimit).")
        }
        if hashtags.count > platform.hashtagLimit {
            issues.append("\(hashtags.count) hashtags; \(platform.displayName) allows \(platform.hashtagLimit).")
        }
        if mediaFiles.isEmpty, platform == .tiktok {
            issues.append("TikTok posts need a video or photo.")
        }
        return issues
    }
}

/// An official API integration (OAuth, tokens in the Keychain). JARVIS never
/// asks for passwords or 2FA codes; authorization happens in the platform's
/// own sign-in page via ASWebAuthenticationSession.
public protocol SocialConnector: Sendable {
    var platform: SocialPlatform { get }
    func connectedAccount() async -> SocialAccount?
    func publish(_ draft: SocialPostDraft) async throws -> String
}
