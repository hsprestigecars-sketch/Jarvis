import Foundation
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
    let handsFree = HandsFreeListener()
    let agent: JarvisAgent
    /// Last turn came from voice, so the reply is spoken.
    @ObservationIgnored private var replyBySpeech = false
    private(set) var registrationProblems: [String] = []
    @ObservationIgnored private var localBrain: LocalReasoningBackend?

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

        let localBrain = OnDeviceBrain.make()
        self.localBrain = localBrain
        agent.localBackend = localBrain
        agent.brainSelector = { [weak self] in self?.activeBrain ?? .claude }

        agent.emergencyStop.register("Stop microphone") { [weak self] in
            self?.voiceInput.stop(submit: false)
            // Hands-free keeps listening for the name, but drops any half-heard request.
            self?.handsFree.reset()
        }
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
            guard !speaking else { return }
            // Don't treat JARVIS's own reply as something the user said.
            self.handsFree.clearBuffer()
            if self.replyBySpeech, self.settings.continuousConversation, !self.agent.isBusy {
                if self.handsFree.isOn {
                    self.handsFree.wakeManually()
                } else {
                    Task { await self.startListening() }
                }
            }
        }
        handsFree.onWake = { [weak self] in
            guard let self else { return }
            self.voiceOutput.stop() // talking over JARVIS interrupts it
            self.agent.setListening(true)
        }
        handsFree.onGiveUp = { [weak self] in self?.agent.setListening(false) }
        handsFree.onCommand = { [weak self] text in
            guard let self else { return }
            self.agent.setListening(false)
            self.replyBySpeech = true
            self.agent.submit(text)
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
        if handsFree.isOn {
            voiceOutput.stop()
            handsFree.wakeManually()
            return
        }
        if voiceInput.isListening {
            voiceInput.stop(submit: true)
            agent.setListening(false)
        } else {
            Task { await startListening() }
        }
    }

    /// Starts or stops hands-free listening to match the setting. Called when
    /// the app comes on screen, leaves it, or the setting changes.
    func updateHandsFree(appActive: Bool) {
        if appActive, settings.handsFree, canThink {
            if !handsFree.isOn {
                voiceInput.stop(submit: false)
                Task { await handsFree.start() }
            }
        } else {
            handsFree.stop()
        }
    }

    func emergencyStop() {
        agent.triggerEmergencyStop()
    }

    var needsAPIKey: Bool { settings.apiKey.isEmpty }

    /// Why free on-device mode can't be used right now, or nil if it can.
    var onDeviceUnavailableReason: String? { OnDeviceBrain.unavailableReason(localBrain) }

    /// The brain the next request will use.
    var activeBrain: Brain {
        switch settings.brainChoice {
        case "claude": return .claude
        case "onDevice": return .onDevice
        default: return needsAPIKey ? .onDevice : .claude
        }
    }

    /// JARVIS can think: Claude has a key, or the free on-device model works.
    var canThink: Bool {
        activeBrain == .claude ? !needsAPIKey : onDeviceUnavailableReason == nil
    }

    var brainLabel: String {
        activeBrain == .claude ? "Claude" : "On-device (free)"
    }
}
