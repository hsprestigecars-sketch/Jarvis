import Foundation

/// JARVIS's own folder. Lives in the app's Documents directory, which the
/// Files app shows under "On My iPad › JARVIS" (UIFileSharingEnabled and
/// LSSupportsOpeningDocumentsInPlace are set). JARVIS file tools can only
/// reach paths inside this folder.
enum JarvisFiles {
    static let folders = ["Projects", "Racing", "Prestige Culture", "Content", "Documents", "Social Media", "Ideas", "Exports", "Notes", "Imports"]

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var notes: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    static var imports: URL { root.appendingPathComponent("Imports", isDirectory: true) }

    static func bootstrap() {
        for folder in folders {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    enum PathError: LocalizedError {
        case outsideSandbox(String)
        var errorDescription: String? {
            switch self {
            case .outsideSandbox(let path): "'\(path)' is outside JARVIS's folder. JARVIS can only work with its own files and files you import."
            }
        }
    }

    /// Resolves a user/Claude-supplied relative path and guarantees it stays
    /// inside the JARVIS folder (no `..`, no absolute paths, no symlink escape).
    static func resolve(_ relativePath: String) throws -> URL {
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = root.appendingPathComponent(cleaned).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.path == base || candidate.path.hasPrefix(base + "/") else {
            throw PathError.outsideSandbox(relativePath)
        }
        return candidate
    }

    static func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
    }
}
