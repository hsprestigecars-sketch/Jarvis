import AudioToolbox
import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Hands-free mode: say "Jarvis…" and JARVIS answers.
///
/// Privacy and platform rules:
/// - Speech is recognised **on the iPad only** (`requiresOnDeviceRecognition`).
///   If the iPad can't recognise on-device, hands-free refuses to start, so
///   microphone audio is never streamed to a server just to hear the name.
/// - It runs only while JARVIS is open on screen. iPadOS doesn't let apps keep
///   the microphone on in the background, and JARVIS stops listening when it
///   leaves the screen. The orange microphone dot stays visible while on.
@MainActor
@Observable
final class HandsFreeListener {
    enum Phase: Equatable {
        case off
        /// Listening for the name.
        case waiting
        /// Heard the name; collecting the request.
        case hearingCommand
    }

    private(set) var phase: Phase = .off
    /// The request as it is being heard, for the screen.
    private(set) var heard = ""
    private(set) var errorMessage: String?

    @ObservationIgnored var onWake: (() -> Void)?
    @ObservationIgnored var onCommand: ((String) -> Void)?
    @ObservationIgnored var onGiveUp: (() -> Void)?

    var isOn: Bool { phase != .off }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let box = RequestBox()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var manualWake = false
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    @ObservationIgnored private var commandTimeout: Task<Void, Never>?
    @ObservationIgnored private var refreshTimer: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Pause after the last word before the request is sent.
    var endOfRequestSilence: Duration = .milliseconds(1300)

    // MARK: Start / stop

    func start() async {
        guard phase == .off else { return }
        errorMessage = nil
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            errorMessage = "This iPad can't recognise speech on the device, so hands-free stays off (JARVIS won't stream your microphone to a server). Use the Talk button instead."
            return
        }
        do {
            try startAudio()
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            stopAudio()
            return
        }
        phase = .waiting
        beginRecognition()
        UIApplication.shared.isIdleTimerDisabled = true
        observeAudioChanges()
    }

    func stop() {
        guard phase != .off else { return }
        phase = .off
        heard = ""
        generation += 1
        cancelTimers()
        task?.cancel()
        task = nil
        box.set(nil)
        stopAudio()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Same as saying "Jarvis": the next thing said is the request.
    func wakeManually() {
        guard phase != .off else { return }
        manualWake = true
        beginRecognition()
        enterCommandPhase()
        heard = ""
    }

    /// Abandon a half-heard request and go back to listening for the name.
    func reset() {
        guard phase != .off else { return }
        backToWaiting()
    }

    /// Forget what was heard so far (for example JARVIS's own reply).
    func clearBuffer() {
        guard phase == .waiting else { return }
        beginRecognition()
    }

    // MARK: Recognition

    private func beginRecognition() {
        generation += 1
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.contextualStrings = ["Jarvis", "JARVIS"]
        box.set(request)
        guard let recognizer else { return }
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self, generation: generation))

        // Start a fresh transcript regularly so it never grows large.
        refreshTimer?.cancel()
        refreshTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(50))
            guard !Task.isCancelled, let self, self.phase == .waiting else { return }
            self.beginRecognition()
        }
    }

    fileprivate func handle(text: String?, isFinal: Bool, failed: Bool, generation: Int) {
        guard generation == self.generation, phase != .off else { return }
        let transcript = text ?? ""

        let match: WakeWord.Match
        if manualWake {
            match = transcript.isEmpty ? .wakeOnly : .command(transcript)
        } else {
            match = WakeWord.match(transcript)
        }

        switch match {
        case .none:
            break
        case .wakeOnly:
            if phase == .waiting { enterCommandPhase() }
        case .command(let command):
            if phase == .waiting { enterCommandPhase() }
            heard = command
            commandTimeout?.cancel()
            silenceTimer?.cancel()
            let delay = endOfRequestSilence
            silenceTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.finish(command)
            }
        }

        if isFinal || failed {
            if phase == .hearingCommand, !heard.isEmpty {
                finish(heard)
            } else if phase == .waiting {
                // The recogniser ended a segment; keep listening.
                beginRecognition()
            }
        }
    }

    private func enterCommandPhase() {
        phase = .hearingCommand
        AudioServicesPlaySystemSound(1113)
        onWake?()
        commandTimeout?.cancel()
        commandTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, let self, self.phase == .hearingCommand, self.heard.isEmpty else { return }
            self.backToWaiting()
            self.onGiveUp?()
        }
    }

    private func finish(_ command: String) {
        guard phase == .hearingCommand else { return }
        let request = command.trimmingCharacters(in: .whitespacesAndNewlines)
        backToWaiting()
        if !request.isEmpty { onCommand?(request) }
    }

    private func backToWaiting() {
        cancelTimers()
        manualWake = false
        heard = ""
        phase = .waiting
        beginRecognition()
    }

    private func cancelTimers() {
        silenceTimer?.cancel()
        commandTimeout?.cancel()
        refreshTimer?.cancel()
    }

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tapBlock(for: box))
        engine.prepare()
        try engine.start()
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Restart the microphone after an interruption (Siri, a call, a route change).
    private func restartAudio() {
        guard phase != .off else { return }
        stopAudio()
        do {
            try startAudio()
            beginRecognition()
        } catch {
            errorMessage = "The microphone stopped: \(error.localizedDescription)"
            stop()
        }
    }

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartAudio() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            guard ended else { return }
            Task { @MainActor in self?.restartAudio() }
        })
    }

    private func requestPermissions() async -> Bool {
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

    // Built outside the main actor: these run on audio/recogniser threads.
    nonisolated private static func tapBlock(for box: RequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.append(buffer) }
    }

    nonisolated private static func resultHandler(for owner: HandsFreeListener, generation: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in owner?.handle(text: text, isFinal: isFinal, failed: failed, generation: generation) }
        }
    }
}

/// Holds the current recognition request so the audio tap (on the audio
/// thread) always feeds the latest one.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            request?.endAudio()
            request = new
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }
}
