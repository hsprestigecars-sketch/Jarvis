import Foundation
import JarvisCore
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// JARVIS notes are Markdown files in JARVIS/Notes. Apple Notes has no public
/// API on iPadOS, so JARVIS keeps its own notes and can hand any of them to
/// Apple Notes (or anywhere else) through the Share Sheet.
@MainActor
enum NoteTools {
    static func noteURL(for title: String) throws -> URL {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { throw ToolError.invalidArguments("Note title is empty.") }
        return try JarvisFiles.resolve("Notes/\(safe).md")
    }

    static func existingNote(_ title: String) throws -> URL {
        let exact = try noteURL(for: title)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        let notes = (try? FileManager.default.contentsOfDirectory(at: JarvisFiles.notes, includingPropertiesForKeys: nil)) ?? []
        if let match = notes.first(where: { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare(title) == .orderedSame })
            ?? notes.first(where: { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(title) }) {
            return match
        }
        throw ToolError.failed("No note called '\(title)'.")
    }

    static func register(in registry: ToolRegistry, presenter: Presenter) throws {
        try registry.register(
            ToolSpec(
                name: "create_note",
                description: "Create a JARVIS note (Markdown) with a title and optional body. Fails if a note with that title exists; use append_to_note instead.",
                category: .notes, risk: .safe,
                inputSchema: Schema.object(["title": Schema.string("Note title"), "body": Schema.string("Initial text")], required: ["title"])
            )
        ) { args in
            let title = try args.string("title")
            let url = try noteURL(for: title)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw ToolError.failed("A note called '\(title)' already exists.") }
            let text = "# \(title)\n\n" + (args.optionalString("body") ?? "") + "\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput("Created note '\(title)'.", summary: "Note created")
        }

        try registry.register(
            ToolSpec(
                name: "append_to_note",
                description: "Add text to the end of an existing JARVIS note.",
                category: .notes, risk: .safe,
                inputSchema: Schema.object(["title": Schema.string("Note title"), "text": Schema.string("Text to add")], required: ["title", "text"])
            )
        ) { args in
            let url = try existingNote(try args.string("title"))
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n" + (try args.string("text")) + "\n").utf8))
            return ToolOutput("Added to '\(url.deletingPathExtension().lastPathComponent)'.", summary: "Note updated")
        }

        try registry.register(
            ToolSpec(
                name: "list_notes",
                description: "List JARVIS notes with their last-modified dates.",
                category: .notes, risk: .safe, inputSchema: Schema.object([:])
            )
        ) { _ in
            let notes = try FileManager.default.contentsOfDirectory(at: JarvisFiles.notes, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "md" }
            if notes.isEmpty { return ToolOutput("No notes yet.", summary: "No notes") }
            let lines = notes.map { url -> String in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                return "- \(url.deletingPathExtension().lastPathComponent) (modified \(Format.iso(date)))"
            }
            return ToolOutput(lines.sorted().joined(separator: "\n"), summary: "\(notes.count) note(s)")
        }

        try registry.register(
            ToolSpec(
                name: "read_note",
                description: "Read the full text of a JARVIS note.",
                category: .notes, risk: .safe,
                inputSchema: Schema.object(["title": Schema.string("Note title")], required: ["title"]),
                returnsUntrustedContent: true
            )
        ) { args in
            let url = try existingNote(try args.string("title"))
            return ToolOutput(try String(contentsOf: url, encoding: .utf8), summary: "Read \(url.deletingPathExtension().lastPathComponent)")
        }

        try registry.register(
            ToolSpec(
                name: "search_notes",
                description: "Search JARVIS notes for text. Returns matching notes with the matching lines.",
                category: .notes, risk: .safe,
                inputSchema: Schema.object(["query": Schema.string("Text to find")], required: ["query"]),
                returnsUntrustedContent: true
            )
        ) { args in
            let query = try args.string("query")
            let notes = (try? FileManager.default.contentsOfDirectory(at: JarvisFiles.notes, includingPropertiesForKeys: nil)) ?? []
            var results: [String] = []
            for url in notes where url.pathExtension == "md" {
                let title = url.deletingPathExtension().lastPathComponent
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let lines = text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(query) }
                if title.localizedCaseInsensitiveContains(query) || !lines.isEmpty {
                    results.append("## \(title)\n" + lines.prefix(5).map { "  " + $0 }.joined(separator: "\n"))
                }
            }
            return results.isEmpty
                ? ToolOutput("No notes match '\(query)'.", summary: "No matches")
                : ToolOutput(results.joined(separator: "\n"), summary: "\(results.count) matching note(s)")
        }

        try registry.register(
            ToolSpec(
                name: "delete_note",
                description: "Delete a JARVIS note. The user confirms first.",
                category: .notes, risk: .confirmationRequired,
                inputSchema: Schema.object(["title": Schema.string("Note title")], required: ["title"]),
                describe: { args in
                    let preview = (try? existingNote(args.optionalString("title") ?? "")).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    return ConfirmationDetails(action: "Delete note", target: args.optionalString("title"), content: preview.map { String($0.prefix(300)) })
                }
            )
        ) { args in
            let url = try existingNote(try args.string("title"))
            try FileManager.default.removeItem(at: url)
            return ToolOutput("Deleted note '\(url.deletingPathExtension().lastPathComponent)'.", summary: "Note deleted")
        }

        try registry.register(
            ToolSpec(
                name: "share_note",
                description: "Open the Share Sheet for a JARVIS note so the user can send it to Apple Notes or another app. The user chooses the destination.",
                category: .notes, risk: .safe,
                inputSchema: Schema.object(["title": Schema.string("Note title")], required: ["title"])
            )
        ) { args in
            let url = try existingNote(try args.string("title"))
            let text = try String(contentsOf: url, encoding: .utf8)
            let outcome = await presenter.present(.share(items: [text]))
            return ToolOutput(outcome == .completed ? "The user shared the note." : "The user closed the Share Sheet without sharing.", summary: "Share Sheet")
        }
    }
}

/// File tools. Everything is confined to the JARVIS folder; files from
/// elsewhere enter only when the user imports them with the document picker.
@MainActor
enum FileTools {
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "xml", "html", "css", "js", "ts", "tsx", "jsx", "swift", "py", "rb",
        "go", "rs", "java", "kt", "c", "h", "cpp", "m", "sh", "yml", "yaml", "toml", "ini", "log", "sql", "srt", "vtt",
    ]

    static func register(in registry: ToolRegistry, presenter: Presenter) throws {

        try registry.register(
            ToolSpec(
                name: "list_files",
                description: "List files and folders inside JARVIS's folder. Paths are relative to the JARVIS folder; '' is the top level.",
                category: .files, risk: .safe,
                inputSchema: Schema.object(["path": Schema.string("Folder path, e.g. 'Racing' or ''")])
            )
        ) { args in
            let url = try JarvisFiles.resolve(args.optionalString("path") ?? "")
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if items.isEmpty { return ToolOutput("(empty folder)", summary: "Empty folder") }
            let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { item -> String in
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                if values?.isDirectory == true { return "- \(JarvisFiles.relativePath(of: item))/" }
                let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
                return "- \(JarvisFiles.relativePath(of: item)) (\(size), modified \(Format.iso(values?.contentModificationDate)))"
            }
            return ToolOutput(lines.joined(separator: "\n"), summary: "\(items.count) item(s)")
        }

        try registry.register(
            ToolSpec(
                name: "search_files",
                description: "Search JARVIS's folder by file name and, for text files, contents.",
                category: .files, risk: .safe,
                inputSchema: Schema.object(["query": Schema.string("Text to find")], required: ["query"])
            )
        ) { args in
            let query = try args.string("query")
            var hits: [String] = []
            let enumerator = FileManager.default.enumerator(at: JarvisFiles.root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let item = enumerator?.nextObject() as? URL, hits.count < 50 {
                let relative = JarvisFiles.relativePath(of: item)
                if item.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    hits.append("- \(relative) (name match)")
                } else if textExtensions.contains(item.pathExtension.lowercased()),
                          (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 2_000_000,
                          let text = try? String(contentsOf: item, encoding: .utf8),
                          text.localizedCaseInsensitiveContains(query) {
                    hits.append("- \(relative) (content match)")
                }
            }
            return hits.isEmpty ? ToolOutput("No files match '\(query)'.", summary: "No matches") : ToolOutput(hits.joined(separator: "\n"), summary: "\(hits.count) match(es)")
        }

        try registry.register(
            ToolSpec(
                name: "read_file",
                description: "Read a text, code or PDF file from JARVIS's folder (up to about 200 KB of text).",
                category: .files, risk: .safe,
                inputSchema: Schema.object(["path": Schema.string("File path")], required: ["path"]),
                returnsUntrustedContent: true
            )
        ) { args in
            let url = try JarvisFiles.resolve(try args.string("path"))
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.failed("File not found.") }
            var text: String
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url) else { throw ToolError.failed("Couldn't open the PDF.") }
                text = document.string ?? ""
            } else if let content = try? String(contentsOf: url, encoding: .utf8) {
                text = content
            } else {
                throw ToolError.unavailable("This file is not text. JARVIS can read text, code and PDF files.")
            }
            let limit = 200_000
            if text.count > limit { text = String(text.prefix(limit)) + "\n[… truncated: file is \(text.count) characters …]" }
            return ToolOutput(text, summary: "Read \(url.lastPathComponent)")
        }

        try registry.register(
            ToolSpec(
                name: "create_folder",
                description: "Create a folder inside JARVIS's folder.",
                category: .files, risk: .safe,
                inputSchema: Schema.object(["path": Schema.string("Folder path")], required: ["path"])
            )
        ) { args in
            let url = try JarvisFiles.resolve(try args.string("path"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return ToolOutput("Created folder \(JarvisFiles.relativePath(of: url)).", summary: "Folder created")
        }

        try registry.register(
            ToolSpec(
                name: "create_text_file",
                description: "Create a new text, Markdown or code file in JARVIS's folder. Fails if the file exists (use overwrite_file).",
                category: .files, risk: .safe,
                inputSchema: Schema.object(["path": Schema.string("File path including extension"), "content": Schema.string("File contents")], required: ["path", "content"])
            )
        ) { args in
            let url = try JarvisFiles.resolve(try args.string("path"))
            guard !FileManager.default.fileExists(atPath: url.path) else { throw ToolError.failed("That file already exists.") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (args.optionalString("content") ?? "").write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput("Created \(JarvisFiles.relativePath(of: url)).", summary: "File created")
        }

        try registry.register(
            ToolSpec(
                name: "overwrite_file",
                description: "Replace the contents of an existing text or code file. The user confirms first.",
                category: .files, risk: .confirmationRequired,
                inputSchema: Schema.object(["path": Schema.string("File path"), "content": Schema.string("New contents")], required: ["path", "content"]),
                describe: { args in
                    ConfirmationDetails(action: "Overwrite file", target: args.optionalString("path"), content: args.optionalString("content").map { String($0.prefix(600)) })
                }
            )
        ) { args in
            let url = try JarvisFiles.resolve(try args.string("path"))
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.failed("File not found.") }
            try (args.optionalString("content") ?? "").write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput("Overwrote \(JarvisFiles.relativePath(of: url)).", summary: "File updated")
        }

        try registry.register(
            ToolSpec(
                name: "move_file",
                description: "Move or rename a file or folder inside JARVIS's folder. The user confirms first.",
                category: .files, risk: .confirmationRequired,
                inputSchema: Schema.object(["from": Schema.string("Current path"), "to": Schema.string("New path")], required: ["from", "to"]),
                describe: { args in
                    ConfirmationDetails(action: "Move / rename", target: args.optionalString("from"), settings: [.init("New location", args.optionalString("to") ?? "?")])
                }
            )
        ) { args in
            let from = try JarvisFiles.resolve(try args.string("from")), to = try JarvisFiles.resolve(try args.string("to"))
            guard from.path != JarvisFiles.root.standardizedFileURL.resolvingSymlinksInPath().path else { throw ToolError.invalidArguments("Can't move the JARVIS folder itself.") }
            guard !FileManager.default.fileExists(atPath: to.path) else { throw ToolError.failed("Something already exists at the destination.") }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: from, to: to)
            return ToolOutput("Moved to \(JarvisFiles.relativePath(of: to)).", summary: "Moved")
        }

        try registry.register(
            ToolSpec(
                name: "copy_file",
                description: "Copy a file inside JARVIS's folder.",
                category: .files, risk: .safe,
                inputSchema: Schema.object(["from": Schema.string("Source path"), "to": Schema.string("Destination path")], required: ["from", "to"])
            )
        ) { args in
            let from = try JarvisFiles.resolve(try args.string("from")), to = try JarvisFiles.resolve(try args.string("to"))
            guard !FileManager.default.fileExists(atPath: to.path) else { throw ToolError.failed("Something already exists at the destination.") }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
            return ToolOutput("Copied to \(JarvisFiles.relativePath(of: to)).", summary: "Copied")
        }

        try registry.register(
            ToolSpec(
                name: "delete_file",
                description: "Delete a file or folder inside JARVIS's folder. The user confirms first.",
                category: .files, risk: .confirmationRequired,
                inputSchema: Schema.object(["path": Schema.string("Path to delete")], required: ["path"]),
                describe: { args in
                    let path = args.optionalString("path") ?? ""
                    var isDirectory: ObjCBool = false
                    let url = try? JarvisFiles.resolve(path)
                    let exists = url.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) } ?? false
                    let count = isDirectory.boolValue ? ((try? FileManager.default.subpathsOfDirectory(atPath: url!.path).count) ?? 0) : 0
                    return ConfirmationDetails(
                        action: isDirectory.boolValue ? "Delete folder" : "Delete file", target: path,
                        settings: exists ? (isDirectory.boolValue ? [.init("Contains", "\(count) item(s)")] : []) : [.init("Note", "Path does not exist")]
                    )
                }
            )
        ) { args in
            let url = try JarvisFiles.resolve(try args.string("path"))
            guard url.path != JarvisFiles.root.standardizedFileURL.resolvingSymlinksInPath().path else { throw ToolError.invalidArguments("Can't delete the JARVIS folder itself.") }
            guard JarvisFiles.folders.allSatisfy({ (try? JarvisFiles.resolve($0))?.path != url.path }) else {
                throw ToolError.invalidArguments("JARVIS's standard folders can't be deleted.")
            }
            try FileManager.default.removeItem(at: url)
            return ToolOutput("Deleted \(JarvisFiles.relativePath(of: url)).", summary: "Deleted")
        }

        try registry.register(
            ToolSpec(
                name: "share_file",
                description: "Open the Share Sheet for a file in JARVIS's folder (export to Files, AirDrop, another app). The user picks the destination.",
                category: .files, risk: .safe,
                inputSchema: Schema.object(["path": Schema.string("File path")], required: ["path"])
            )
        ) { args in
            let url = try JarvisFiles.resolve(try args.string("path"))
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.failed("File not found.") }
            let outcome = await presenter.present(.share(items: [url]))
            return ToolOutput(outcome == .completed ? "The user shared \(url.lastPathComponent)." : "The user closed the Share Sheet without sharing.", summary: "Share Sheet")
        }
    }
}
