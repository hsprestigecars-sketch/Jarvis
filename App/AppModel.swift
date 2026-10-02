import Foundation
import JarvisCore
import Observation
import UIKit

/// Wires the JARVIS pipeline together: UI + voice → agent → safety →
/// confirmation → tools.
@MainActor
@Observable
final class AppModel {
    let settings: JarvisSettings
    let presenter: Presenter
    let voiceInput = VoiceInput()
    let voiceOutput = VoiceOutput()
    let agent: JarvisAgent
    /// Last turn came from voice, so the reply is spoken.
    @ObservationIgnored private var replyBySpeech = false
    private(set) var registrationProblems: [String] = []

    init() {
        JarvisFiles.bootstrap()
        let registry = ToolRegistry()
        let settings = JarvisSettings()
        let presenter = Presenter()
        self.settings = settings
        self.presenter = presenter
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JARVIS/conversation.json")
        agent = JarvisAgent(
            registry: registry,
            store: FileConversationStore(url: storeURL),
            configuration: { settings.claudeConfiguration }
        )

        let emergencyStop = agent.emergencyStop
        let registrations: [(String, () throws -> Void)] = [
            ("Calendar", { try CalendarTools.register(in: registry) }),
            ("Reminders", { try ReminderTools.register(in: registry) }),
            ("Notes", { try NoteTools.register(in: registry, presenter: presenter) }),
            ("Files", { try FileTools.register(in: registry, presenter: presenter) }),
            ("Device", { try DeviceTools.register(in: registry, emergencyStop: emergencyStop) }),
            ("Communication", { try CommunicationTools.register(in: registry, presenter: presenter) }),
            ("Apps", { try AppLinkTools.register(in: registry, presenter: presenter) }),
            ("Social & media", { try SocialAndMediaTools.register(in: registry, presenter: presenter) }),
        ]
        for (name, register) in registrations {
            do { try register() } catch { registrationProblems.append("\(name): \(error.localizedDescription)") }
        }
        applySafetyPreferences()

        agent.emergencyStop.register("Stop microphone") { [weak self] in self?.voiceInput.stop(submit: false) }
        agent.emergencyStop.register("Dismiss system sheets") { [weak self] in self?.presenter.finish(.dismissed) }
        agent.onStopSpeech = { [weak self] in self?.voiceOutput.stop() }
        agent.onReply = { [weak self] reply in
            guard let self, self.replyBySpeech, self.settings.speakReplies else { return }
            self.voiceOutput.voiceIdentifier = self.settings.voiceIdentifier
            self.voiceOutput.speak(reply)
        }
        agent.contextProvider = {
            let device = UIDevice.current
            guard device.batteryLevel >= 0 else { return nil }
            return "battery: \(Int(device.batteryLevel * 100))%"
        }
        voiceOutput.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.agent.setSpeaking(speaking)
            if !speaking, self.replyBySpeech, self.settings.continuousConversation, !self.agent.isBusy {
                Task { await self.startListening() }
            }
        }
        voiceInput.onFinal = { [weak self] text in
            guard let self else { return }
            self.agent.setListening(false)
            self.replyBySpeech = true
            self.agent.submit(text)
        }
    }

    func applySafetyPreferences() {
        agent.safety.alwaysConfirm = settings.confirmReminders ? ["create_reminder", "complete_reminder"] : []
    }

    // MARK: Actions

    func send(_ text: String, images: [ImageAttachment] = []) {
        replyBySpeech = false
        agent.submit(text, images: images)
    }

    func startListening() async {
        voiceOutput.stop() // voice interruption: talking over JARVIS stops it
        await voiceInput.start()
        agent.setListening(voiceInput.isListening)
    }

    func toggleListening() {
        if voiceInput.isListening {
            voiceInput.stop(submit: true)
            agent.setListening(false)
        } else {
            Task { await startListening() }
        }
    }

    func emergencyStop() {
        agent.triggerEmergencyStop()
    }

    var needsAPIKey: Bool { settings.apiKey.isEmpty }
}
