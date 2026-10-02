import AVFoundation
import Foundation
import Observation

/// Spoken replies with AVSpeechSynthesizer (on device).
@MainActor
@Observable
final class VoiceOutput {
    private(set) var isSpeaking = false
    @ObservationIgnored var onSpeakingChanged: ((Bool) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()
    @ObservationIgnored var voiceIdentifier: String = ""

    init() {
        synthesizer.delegate = delegate
        delegate.onChange = { [weak self] speaking in self?.setSpeaking(speaking) }
    }

    func speak(_ markdown: String) {
        let text = Self.plainText(markdown)
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 0.95
        // Don't reconfigure the session if the microphone is already running
        // (hands-free); changing it would interrupt listening.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        }
        try? session.setActive(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    private func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onSpeakingChanged?(value)
    }

    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.sorted { $0.name < $1.name }
    }

    /// Removes Markdown, code blocks and links so speech sounds natural.
    nonisolated static func plainText(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (code shown on screen) ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*\|.*\|\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Delegate callbacks arrive off the main actor; they are forwarded to it.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    @MainActor var onChange: ((Bool) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onChange?(true) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onChange?(false) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onChange?(false) }
    }
}
