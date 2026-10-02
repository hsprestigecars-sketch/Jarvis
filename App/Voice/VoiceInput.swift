import AVFoundation
import Foundation
import Observation
import Speech

/// Push-to-talk speech recognition.
///
/// - Uses Apple's Speech framework, on-device when the iPad supports it, so
///   audio does not leave the device for recognition.
/// - The microphone runs only while the user is talking to JARVIS (the
///   system shows the orange microphone indicator). There is no always-on
///   listening and no audio is ever uploaded to implement a wake word.
@MainActor
@Observable
final class VoiceInput {
    private(set) var isListening = false
    private(set) var transcript = ""
    private(set) var errorMessage: String?
    private(set) var onDevice = false

    /// Called with the final transcript when the user stops talking.
    @ObservationIgnored var onFinal: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    @ObservationIgnored private var submitted = false

    /// Stop automatically after this much silence.
    var silenceTimeout: Duration = .milliseconds(1600)

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else {
            errorMessage = "Speech recognition is off. Allow it in Settings › Privacy & Security › Speech Recognition."
            return false
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access is off. Allow it in Settings › Privacy & Security › Microphone."
            return false
        }
        return true
    }

    func start() async {
        guard !isListening else { return }
        errorMessage = nil
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            onDevice = request.requiresOnDeviceRecognition
            self.request = request

            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tapBlock(for: request))
            audioEngine.prepare()
            try audioEngine.start()

            transcript = ""
            submitted = false
            isListening = true
            task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self))
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            teardown()
        }
    }

    /// Stops listening. When `submit` is true the transcript is delivered.
    func stop(submit: Bool = true) {
        guard isListening else { return }
        teardown()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if submit, !submitted, !text.isEmpty {
            submitted = true
            onFinal?(text)
        }
    }

    private func teardown() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }

    fileprivate func handle(text: String?, isFinal: Bool, error: Error?) {
        guard isListening else { return }
        if let text { transcript = text }
        if isFinal || error != nil {
            stop(submit: true)
            return
        }
        silenceTimer?.cancel()
        let timeout = silenceTimeout
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.stop(submit: true)
        }
    }

    // Built outside the main actor: the audio tap and recognizer callbacks run
    // on background threads.
    nonisolated private static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(for owner: VoiceInput) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in owner?.handle(text: text, isFinal: isFinal, error: error) }
        }
    }
}
