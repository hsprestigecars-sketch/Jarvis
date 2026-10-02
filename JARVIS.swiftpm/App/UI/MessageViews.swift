import SwiftUI
import UIKit

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.cyan.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
                    }
                    ForEach(attachments, id: \.self) { label in
                        Label(label, systemImage: "paperclip").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .foregroundStyle(Theme.textPrimary)
            }
        case .assistant(let text, let citations):
            VStack(alignment: .leading, spacing: 10) {
                MarkdownView(markdown: text)
                if !citations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SOURCES").font(.caption2.weight(.bold)).foregroundStyle(Theme.textSecondary)
                        ForEach(citations, id: \.self) { citation in
                            if let url = URL(string: citation.url) {
                                Link(destination: url) {
                                    Label(citation.title, systemImage: "link").font(.caption).lineLimit(1)
                                }
                                .tint(Theme.cyan)
                            }
                        }
                    }
                    .padding(10)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let name, let summary, let state):
            ToolStatusRow(name: name, summary: summary, state: state)
        case .notice(let text, let style):
            NoticeRow(text: text, style: style)
        }
    }
}

struct ToolStatusRow: View {
    let name: String
    let summary: String
    let state: TranscriptItem.ToolState

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(name.replacingOccurrences(of: "_", with: " ")).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
            Text(summary).font(.caption).foregroundStyle(color).lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .running: ProgressView().controlSize(.mini).tint(Theme.amber)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        case .blocked: Image(systemName: "lock.shield.fill").foregroundStyle(Theme.protected)
        case .cancelled: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
        case .awaitingConfirmation: Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber)
        }
    }

    private var color: Color {
        switch state {
        case .running, .awaitingConfirmation: Theme.amber
        case .succeeded: Theme.cyan
        case .failed: Theme.danger
        case .blocked: Theme.protected
        case .cancelled: Theme.textSecondary
        }
    }
}

struct NoticeRow: View {
    let text: String
    let style: TranscriptItem.NoticeStyle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
            Text(text).font(.callout)
        }
        .foregroundStyle(color)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.35)))
    }

    private var icon: String {
        switch style {
        case .info: "info.circle"
        case .protected: "lock.shield.fill"
        case .error: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    private var color: Color {
        switch style {
        case .info: Theme.textSecondary
        case .protected: Theme.protected
        case .error: Theme.danger
        case .stopped: Theme.danger
        }
    }
}

/// Renders the Markdown Claude produces: paragraphs, headings, lists, code
/// blocks and tables. Inline styling (bold, italics, code, links) uses
/// Foundation's Markdown parser.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text)).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inline(text))
        case .bullet(let text, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(Theme.cyan).monospacedDigit()
                Text(inline(text))
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(language.isEmpty ? "code" : language).font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                    }
                    .tint(Theme.cyan)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(.footnote, design: .monospaced))
                }
            }
            .padding(10)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell)).font(index == 0 ? .footnote.bold() : .footnote)
                            }
                        }
                        if index == 0 { Divider().overlay(Theme.panelBorder) }
                    }
                }
                .padding(10)
            }
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        case .rule:
            Divider().overlay(Theme.panelBorder)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String, marker: String)
    case code(language: String, code: String)
    case table([[String]])
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var index = 0

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, code: code.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                flush()
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|"), row.hasSuffix("|") else { break }
                    let cells = row.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.append(cells) }
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
                      trimmed[hashes] == " ", trimmed.distance(from: trimmed.startIndex, to: hashes) <= 6 {
                flush()
                blocks.append(.heading(trimmed.distance(from: trimmed.startIndex, to: hashes), String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2)), marker: "•"))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                      trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.bullet(String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces), marker: String(trimmed[...dot])))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }
}
