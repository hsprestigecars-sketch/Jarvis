import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showChatOnCompact = false
    private let inbox = IntentInbox.shared

    var body: some View {
        @Bindable var presenter = model.presenter
        ZStack {
            Theme.background.ignoresSafeArea()
            GridBackdrop().ignoresSafeArea().opacity(0.35)

            VStack(spacing: 12) {
                topBar
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        HomePanel()
                            .frame(width: 360)
                        ChatView()
                    }
                } else if showChatOnCompact {
                    ChatView()
                } else {
                    HomePanel(onOpenChat: { showChatOnCompact = true })
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $presenter.sheet, onDismiss: { model.presenter.finish(.dismissed) }) { sheet in
            SystemSheetView(sheet: sheet, presenter: model.presenter)
                .ignoresSafeArea()
        }
        .onAppear {
            if model.needsAPIKey { showSettings = true }
            handleIntents()
        }
        .onChange(of: inbox.pending) { _, _ in handleIntents() }
        .onChange(of: inbox.startListening) { _, _ in handleIntents() }
        .onChange(of: scenePhase) { _, phase in
            // Never keep the microphone open in the background.
            if phase != .active, model.voiceInput.isListening { model.voiceInput.stop(submit: false) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if sizeClass != .regular, showChatOnCompact {
                Button { showChatOnCompact = false } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Home")
            }
            StatusBadge(status: model.agent.status)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("Settings")
            EmergencyStopButton { model.emergencyStop() }
        }
    }

    private func handleIntents() {
        if let request = inbox.pending {
            inbox.pending = nil
            showChatOnCompact = true
            model.send(request)
        }
        if inbox.startListening {
            inbox.startListening = false
            Task { await model.startListening() }
        }
    }
}

/// Faint blueprint grid behind everything.
struct GridBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 40
            var path = Path()
            var x: CGFloat = 0
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y: CGFloat = 0
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            context.stroke(path, with: .color(Theme.cyan.opacity(0.08)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

struct HomePanel: View {
    @Environment(AppModel.self) private var model
    var onOpenChat: (() -> Void)?

    private let quickActions: [(String, String)] = [
        ("Plan my day", "calendar.day.timeline.left"),
        ("Briefing", "sun.max"),
        ("Night mode", "moon.stars"),
        ("What's on my calendar today?", "calendar"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ReactorView(status: model.agent.status, size: 220)
                    .padding(.top, 8)
                Text(prompt)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Button { model.toggleListening() } label: {
                    Label(model.voiceInput.isListening ? "Listening… tap to send" : "Talk to JARVIS",
                          systemImage: model.voiceInput.isListening ? "waveform" : "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(Theme.background)
                        .background(model.voiceInput.isListening ? Theme.color(for: .listening) : Theme.cyan, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Theme.cyan.opacity(0.5), radius: 10)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("j", modifiers: .command)

                if model.voiceInput.isListening || !model.voiceInput.transcript.isEmpty {
                    Text(model.voiceInput.transcript.isEmpty ? "…" : model.voiceInput.transcript)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .jarvisPanel()
                }
                if let error = model.voiceInput.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("QUICK").font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(quickActions, id: \.0) { action in
                            Button {
                                model.send(action.0)
                                onOpenChat?()
                            } label: {
                                Label(action.0, systemImage: action.1)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(10)
                                    .jarvisPanel()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }

                if !model.agent.recentRequests.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RECENT").font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
                        ForEach(model.agent.recentRequests.prefix(6), id: \.self) { request in
                            Button {
                                model.send(request)
                                onOpenChat?()
                            } label: {
                                Text("“\(request)”")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textPrimary)
                            Divider().overlay(Theme.panelBorder)
                        }
                    }
                }

                if let onOpenChat {
                    Button("Open chat", action: onOpenChat)
                        .buttonStyle(.bordered)
                        .tint(Theme.cyan)
                }
            }
            .padding(20)
        }
        .jarvisPanel()
    }

    private var prompt: String {
        switch model.agent.status {
        case .listening: "I'm listening."
        case .thinking: "Thinking…"
        case .working(let detail): detail + "…"
        case .waitingForConfirmation: "Waiting for your confirmation."
        case .speaking: "Speaking…"
        case .protected: "That one is protected."
        case .error: "Something went wrong."
        case .ready: "How can I help?"
        }
    }
}
