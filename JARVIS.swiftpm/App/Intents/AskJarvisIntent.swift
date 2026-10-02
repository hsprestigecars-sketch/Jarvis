import AppIntents
import Foundation
import Observation

/// Siri / Shortcuts entry point: "Ask JARVIS" (or "Hey Siri, ask JARVIS").
/// This is the system-supported voice invocation; JARVIS does not run its own
/// always-on wake word.
struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask JARVIS"
    static let description = IntentDescription("Send a request to JARVIS.")
    static let openAppWhenRun = true

    @Parameter(title: "Request", requestValueDialog: "What do you need?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.pending = request
        return .result()
    }
}

struct TalkToJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to JARVIS"
    static let description = IntentDescription("Open JARVIS and start listening.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.shared.startListening = true
        return .result()
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something"],
            shortTitle: "Ask JARVIS",
            systemImageName: "waveform.circle"
        )
        AppShortcut(
            intent: TalkToJarvisIntent(),
            phrases: ["Talk to \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Talk to JARVIS",
            systemImageName: "mic.circle"
        )
    }
}

/// Hands requests from App Intents to the running app.
@MainActor
@Observable
final class IntentInbox {
    static let shared = IntentInbox()
    var pending: String?
    var startListening = false
}
