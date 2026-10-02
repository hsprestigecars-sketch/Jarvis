import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var images: [ImageAttachment] = []
    @State private var attachmentNotes: [String] = []
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var attachmentError: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.panelBorder)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.agent.transcript.isEmpty {
                            EmptyChatHint()
                        }
                        ForEach(model.agent.transcript) { item in
                            TranscriptRow(item: item).id(item.id)
                        }
                        ForEach(model.agent.confirmations.pending) { action in
                            ConfirmationCard(action: action, engine: model.agent.confirmations).id(action.id)
                        }
                        if model.agent.isBusy, model.agent.confirmations.pending.isEmpty {
                            ThinkingRow(status: model.agent.status).id("thinking")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.agent.transcript.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: model.agent.confirmations.pending.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            Divider().overlay(Theme.panelBorder)
            inputBar
        }
        .jarvisPanel()
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, maxSelectionCount: 4, matching: .any(of: [.images, .videos]))
        .onChange(of: photoSelection) { _, items in
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { result in
                showCamera = false
                if let result { addCaptured(result) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
    }

    private var header: some View {
        HStack {
            Text("Conversation").font(.headline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Menu {
                Button("New conversation", systemImage: "square.and.pencil") { model.agent.clearConversation() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("Conversation options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty || !attachmentNotes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(images.indices, id: \.self) { index in
                            AttachmentChip(label: images[index].label, systemImage: "photo") { images.remove(at: index) }
                        }
                        ForEach(attachmentNotes.indices, id: \.self) { index in
                            AttachmentChip(label: attachmentNotes[index], systemImage: "doc") { attachmentNotes.remove(at: index) }
                        }
                    }
                }
            }
            if let attachmentError {
                Text(attachmentError).font(.caption).foregroundStyle(Theme.danger)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Camera", systemImage: "camera") { showCamera = true }
                    }
                    Button("Import File", systemImage: "folder") { showFileImporter = true }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Theme.cyan)
                }
                .accessibilityLabel("Attach")

                TextField("Message JARVIS", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    .focused($inputFocused)
                    .onSubmit(send)
                    .submitLabel(.send)

                Button { model.toggleListening() } label: {
                    Image(systemName: model.voiceInput.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(model.voiceInput.isListening ? Theme.color(for: .listening) : Theme.cyan)
                        .symbolEffect(.pulse, isActive: model.voiceInput.isListening)
                }
                .accessibilityLabel(model.voiceInput.isListening ? "Stop listening" : "Talk")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundStyle(canSend ? Theme.cyan : Theme.textSecondary)
                }
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
        }
        .padding(12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !attachmentNotes.isEmpty
    }

    private func send() {
        guard canSend else { return }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachmentNotes.isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + attachmentNotes.map { "[Attached: \($0)]" }.joined(separator: "\n")
        }
        model.send(text, images: images)
        draft = ""
        images = []
        attachmentNotes = []
        attachmentError = nil
    }

    // MARK: Attachments — only what the user explicitly picks.

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                do {
                    if let movie = try await item.loadTransferable(type: MovieFile.self) {
                        attachmentNotes.append("video saved to \(movie.relativePath)")
                    }
                } catch {
                    attachmentError = "Couldn't import the video: \(error.localizedDescription)"
                }
            } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                appendImage(image, label: "Photo \(images.count + 1)", original: data)
            }
        }
        photoSelection = []
    }

    private func addCaptured(_ result: CameraPicker.Result) {
        switch result {
        case .image(let image):
            appendImage(image, label: "Camera photo", original: nil)
        case .video(let url):
            if let saved = try? MediaImport.copyIntoJarvis(url, folder: "Content") {
                attachmentNotes.append("video saved to \(saved)")
            }
        }
    }

    private func appendImage(_ image: UIImage, label: String, original: Data?) {
        guard images.count < 8, let attachment = MediaImport.imageAttachment(image, label: label) else { return }
        images.append(attachment)
        // Keep a copy in JARVIS's folder so it can be used for posts.
        if let data = original ?? image.jpegData(compressionQuality: 0.9) {
            let name = "Content/\(label.replacingOccurrences(of: " ", with: "-"))-\(Int(Date().timeIntervalSince1970)).jpg"
            if let url = try? JarvisFiles.resolve(name) { try? data.write(to: url) }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let saved = try MediaImport.copyIntoJarvis(url, folder: "Imports")
                    attachmentNotes.append("file imported to \(saved)")
                } catch {
                    attachmentError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            attachmentError = error.localizedDescription
        }
    }
}

private struct AttachmentChip: View {
    let label: String
    let systemImage: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(label).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Remove attachment")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.cyan.opacity(0.15), in: Capsule())
        .foregroundStyle(Theme.textPrimary)
    }
}

private struct EmptyChatHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try").font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
            ForEach([
                "Remind me to bring my racing helmet tomorrow.",
                "Research the best camera for karting.",
                "Take a note called Racing Ideas.",
                "Prepare this video for TikTok.",
                "Help me with this code.",
            ], id: \.self) { example in
                Text("“\(example)”").font(.callout).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 24)
    }
}

private struct ThinkingRow: View {
    let status: JarvisStatus

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Theme.amber)
            Text(status.detail ?? status.label.capitalized).font(.callout).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Imports the user's chosen media into JARVIS's folder.
enum MediaImport {
    static func copyIntoJarvis(_ source: URL, folder: String) throws -> String {
        let directory = try JarvisFiles.resolve(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = source.deletingPathExtension().lastPathComponent
            destination = directory.appendingPathComponent("\(base) \(counter).\(source.pathExtension)")
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return JarvisFiles.relativePath(of: destination)
    }

    /// Downscales to the size Claude uses and encodes as JPEG.
    static func imageAttachment(_ image: UIImage, label: String) -> ImageAttachment? {
        let maxSide: CGFloat = 1568
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }
        return ImageAttachment(mediaType: "image/jpeg", base64Data: data.base64EncodedString(), label: label)
    }
}

/// A picked video, copied into JARVIS/Content.
struct MovieFile: Transferable {
    let relativePath: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(try JarvisFiles.resolve(movie.relativePath))
        } importing: { received in
            MovieFile(relativePath: try MediaImport.copyIntoJarvis(received.file, folder: "Content"))
        }
    }
}
