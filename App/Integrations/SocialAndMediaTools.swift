import AVFoundation
import Foundation
import JarvisCore
import UIKit

/// Media inspection and social posting.
///
/// Publishing goes only through official APIs with OAuth:
/// - Instagram: Instagram Graph API content publishing (Business/Creator
///   accounts; media must be at a public URL the API can fetch).
/// - TikTok: Content Posting API (requires an approved developer app).
/// Until an account is connected in Settings, JARVIS prepares a complete
/// post package and hands it to the official app through the Share Sheet.
@MainActor
enum SocialAndMediaTools {
    /// Official connectors, keyed by platform. Empty until OAuth is configured.
    static var connectors: [SocialPlatform: SocialConnector] = [:]

    static func register(in registry: ToolRegistry, presenter: Presenter) throws {
        try registry.register(
            ToolSpec(
                name: "inspect_media",
                description: "Get technical details of a photo or video in JARVIS's folder: duration, resolution, orientation, frame rate, file size. Use to check a video against platform requirements.",
                category: .photos, risk: .safe,
                inputSchema: Schema.object(["path": Schema.string("File path, e.g. Content/race.mov")], required: ["path"])
            )
        ) { args in
            let url = try JarvisFiles.resolve(try args.string("path"))
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.failed("File not found.") }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            var lines = ["File: \(JarvisFiles.relativePath(of: url))", "Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"]
            if let image = UIImage(contentsOfFile: url.path) {
                lines.append("Type: image, \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)) px")
            } else {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                lines.append("Type: video, duration \(String(format: "%.1f", duration.seconds)) s")
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let (naturalSize, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                    let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
                    let width = Int(abs(rect.width)), height = Int(abs(rect.height))
                    lines.append("Resolution: \(width)×\(height) (\(height > width ? "vertical" : height == width ? "square" : "horizontal")), \(Int(fps.rounded())) fps")
                }
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                lines.append("Has audio: \(audioTracks.isEmpty ? "no" : "yes")")
            }
            return ToolOutput(lines.joined(separator: "\n"), summary: "Media details")
        }

        try registry.register(
            ToolSpec(
                name: "prepare_social_post",
                description: "Prepare an Instagram or TikTok post: validates the caption and hashtags against platform limits and saves a post package (caption + media copies) in 'Social Media/'. Does not publish.",
                category: .social, risk: .safe,
                inputSchema: Schema.object([
                    "platform": Schema.enumeration(SocialPlatform.allCases.map(\.rawValue), "Platform"),
                    "caption": Schema.string("Caption text without hashtags"),
                    "hashtags": Schema.stringArray("Hashtags"),
                    "media_paths": Schema.stringArray("Media files in JARVIS's folder"),
                    "visibility": Schema.enumeration(["public", "friends", "private"], "Intended visibility"),
                ], required: ["platform", "caption"])
            )
        ) { args in
            guard let platform = SocialPlatform(rawValue: try args.string("platform")) else { throw ToolError.invalidArguments("Unknown platform.") }
            let draft = SocialPostDraft(
                platform: platform, caption: try args.string("caption"), hashtags: args.stringArray("hashtags"),
                mediaFiles: args.stringArray("media_paths"), visibility: args.optionalString("visibility") ?? "public"
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let stamp = formatter.string(from: Date())
            let folder = try JarvisFiles.resolve("Social Media/\(stamp) \(platform.displayName)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var copied: [String] = []
            for path in draft.mediaFiles {
                let source = try JarvisFiles.resolve(path)
                guard FileManager.default.fileExists(atPath: source.path) else { throw ToolError.failed("Media file not found: \(path)") }
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                copied.append(JarvisFiles.relativePath(of: destination))
            }
            try draft.fullCaption.write(to: folder.appendingPathComponent("caption.txt"), atomically: true, encoding: .utf8)
            let json = try JSONEncoder().encode(draft)
            try json.write(to: folder.appendingPathComponent("post.json"))
            var text = "Post package saved at '\(JarvisFiles.relativePath(of: folder))' with \(copied.count) media file(s).\nCaption (\(draft.fullCaption.count) chars):\n\(draft.fullCaption)"
            let issues = draft.validationIssues
            text += issues.isEmpty ? "\nNo platform issues found." : "\nIssues:\n" + issues.map { "- " + $0 }.joined(separator: "\n")
            text += connectors[platform] == nil
                ? "\n\(platform.displayName) is not connected, so this can't be published from JARVIS. Use share_social_package to hand it to the \(platform.displayName) app."
                : "\nReady to publish with publish_social_post after the user confirms."
            return ToolOutput(text, summary: "Prepared \(platform.displayName) post")
        }

        try registry.register(
            ToolSpec(
                name: "share_social_package",
                description: "Hand a prepared post package to the official app via the Share Sheet. The caption is copied to the clipboard so the user can paste it. The user posts it themselves.",
                category: .social, risk: .safe,
                inputSchema: Schema.object(["package_path": Schema.string("Folder from prepare_social_post")], required: ["package_path"])
            )
        ) { args in
            let folder = try JarvisFiles.resolve(try args.string("package_path"))
            let caption = (try? String(contentsOf: folder.appendingPathComponent("caption.txt"), encoding: .utf8)) ?? ""
            let media = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { !["txt", "json"].contains($0.pathExtension.lowercased()) }
            guard !media.isEmpty else { throw ToolError.failed("The package has no media to share.") }
            UIPasteboard.general.string = caption
            let outcome = await presenter.present(.share(items: media))
            return ToolOutput(
                outcome == .completed
                    ? "The user passed the media to another app. The caption is on the clipboard to paste."
                    : "The user closed the Share Sheet. The caption is still on the clipboard.",
                summary: "Handed off post"
            )
        }

        try registry.register(
            ToolSpec(
                name: "publish_social_post",
                description: "Publish a prepared post package through the platform's official API. Only works for a connected account. The user confirms the exact post first.",
                category: .social, risk: .confirmationRequired,
                inputSchema: Schema.object([
                    "package_path": Schema.string("Folder from prepare_social_post"),
                    "visibility": Schema.enumeration(["public", "friends", "private"], "Visibility"),
                ], required: ["package_path"]),
                describe: { args in
                    let folder = try? JarvisFiles.resolve(args.optionalString("package_path") ?? "")
                    let draft = folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("post.json")) }
                        .flatMap { try? JSONDecoder().decode(SocialPostDraft.self, from: $0) }
                    return ConfirmationDetails(
                        action: "Publish \(draft?.platform.displayName ?? "post")",
                        target: draft?.mediaFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                        content: draft?.fullCaption,
                        account: draft.map { connectors[$0.platform] == nil ? "Not connected — nothing will be posted" : "Connected \($0.platform.displayName) account" },
                        settings: [.init("Visibility", args.optionalString("visibility") ?? draft?.visibility ?? "public")]
                    )
                }
            )
        ) { args in
            let folder = try JarvisFiles.resolve(try args.string("package_path"))
            let data = try Data(contentsOf: folder.appendingPathComponent("post.json"))
            var draft = try JSONDecoder().decode(SocialPostDraft.self, from: data)
            if let visibility = args.optionalString("visibility") { draft.visibility = visibility }
            guard let connector = connectors[draft.platform], await connector.connectedAccount() != nil else {
                throw ToolError.notConnected(
                    "\(draft.platform.displayName) publishing needs an account connected through the official API (Settings › Social accounts). Nothing was posted. Offer share_social_package instead."
                )
            }
            let id = try await connector.publish(draft)
            return ToolOutput("Published to \(draft.platform.displayName). Post id: \(id).", summary: "Published")
        }
    }
}
