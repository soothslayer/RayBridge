import AVFoundation
import Speech
import UIKit

@MainActor
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate {
    var onQuestion: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinishedSpeaking: (() -> Void)?
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var silence: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var tapped = false
    private var listening = false
    private var generation = 0
    private var transcript = ""
    private var spokenUtterance: AVSpeechUtterance?
    private var voiceOverAnnouncement: String?
    private var announcementTimeout: Task<Void, Never>?
    private var capturePrepared = false
    var allowPhoneAudio = false
    var isSpeaking: Bool { spokenUtterance != nil || voiceOverAnnouncement != nil }

    override init() {
        super.init(); synthesizer.delegate = self
        NotificationCenter.default.addObserver(forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main) { [weak self] notification in
            let text = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            Task { @MainActor in
                guard let self, let text, self.voiceOverAnnouncement == text else { return }
                self.finishAnnouncement()
            }
        }
        NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !UIAccessibility.isVoiceOverRunning, self.voiceOverAnnouncement != nil else { return }
                self.finishAnnouncement()
            }
        }
    }

    func permissions() async throws {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard speech == .authorized else { throw BridgeError.message("Allow speech recognition in iPhone Settings for RayBridge.") }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw BridgeError.message("Allow microphone access in iPhone Settings for RayBridge.")
        }
        try Task.checkCancellation()
    }
    // Configure capture once, after the camera has opened. Keep the same route
    // through readiness, listening, thinking and answers.
    private func audioSession() throws {
        if capturePrepared {
            guard allowPhoneAudio || hasBluetoothRoute else {
                throw RecoverableSessionError(message: "Glasses audio is disconnected. Connect your glasses as a Bluetooth headset.")
            }
            return
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)
        if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try session.setPreferredInput(glasses)
        } else if !allowPhoneAudio {
            throw RecoverableSessionError(message: "Glasses audio is disconnected. Connect your glasses as a Bluetooth headset.")
        }
        capturePrepared = true
    }
    func prepareListening() throws {
        try audioSession()
        _ = try speechRecognizer()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw BridgeError.message("The microphone is not available.")
        }
    }
    private func speechRecognizer() throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw BridgeError.message("On-device English speech recognition is unavailable. Enable it on this iPhone, or type your question below.")
        }
        return recognizer
    }
    var hasBluetoothRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP }
    }
    func startListening() throws {
        stopListening()
        try audioSession()
        let recognizer = try speechRecognizer()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        transcript = ""; listening = true
        generation += 1
        let current = generation
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { stopListening(); throw BridgeError.message("The microphone is not available.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapped = true
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.listening, current == self.generation else { return }
                if let text, !text.isEmpty {
                    let changed = text != self.transcript
                    self.transcript = text; self.onTranscript?(text)
                    if final { self.submit(); return }
                    if changed {
                        self.silence?.cancel()
                        self.silence = Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(1400))
                            guard !Task.isCancelled else { return }
                            self?.submit()
                        }
                    }
                }
                if failure != nil { self.stopListening(); self.onError?("Speech recognition stopped. Tap Start RayBridge to try again.") }
            }
        }
        do { engine.prepare(); try engine.start() }
        catch { stopListening(); throw error }
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            if !self.transcript.isEmpty { self.submit() }
            else {
                do { try self.startListening() } catch { self.onError?(error.localizedDescription) }
            }
        }
    }
    private func submit() {
        guard listening, !transcript.isEmpty else { return }
        let text = transcript
        stopListening(); onQuestion?(text)
    }
    func stopListening() {
        listening = false; generation += 1
        silence?.cancel(); limit?.cancel()
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }
    func speak(_ text: String, allowPhoneFallback: Bool = false) throws {
        stopListening()
        if allowPhoneFallback && !capturePrepared {
            // Offline feedback must not open a Bluetooth microphone/call session.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } else {
            try audioSession()
        }
        guard allowPhoneFallback || allowPhoneAudio || hasBluetoothRoute else {
            throw RecoverableSessionError(message: "Glasses audio disconnected. The answer is available on screen.")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        spokenUtterance = utterance
        synthesizer.speak(utterance)
    }
    func speakStatus(_ text: String) throws {
        stopListening()
        spokenUtterance = nil; synthesizer.stopSpeaking(at: .immediate)
        announcementTimeout?.cancel(); voiceOverAnnouncement = nil
        if UIAccessibility.isVoiceOverRunning {
            voiceOverAnnouncement = text
            UIAccessibility.post(notification: .announcement, argument: text)
            // UIKit can omit completion when assistive technology is switched.
            announcementTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.voiceOverAnnouncement == text else { return }
                self.finishAnnouncement()
            }
        } else {
            // Connection-loss feedback must remain audible if glasses audio is gone.
            try speak(text, allowPhoneFallback: true)
        }
    }
    private func finishAnnouncement() {
        announcementTimeout?.cancel(); announcementTimeout = nil
        voiceOverAnnouncement = nil
        onFinishedSpeaking?()
    }
    func speakStatusAndWait(_ text: String) async throws {
        try speakStatus(text)
        while isSpeaking {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
    }
    func stopSpeech() {
        announcementTimeout?.cancel(); announcementTimeout = nil; voiceOverAnnouncement = nil
        spokenUtterance = nil
        stopListening(); synthesizer.stopSpeaking(at: .immediate)
    }
    func stop() {
        stopSpeech()
        capturePrepared = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.spokenUtterance === utterance else { return }
            self.spokenUtterance = nil
            self.onFinishedSpeaking?()
        }
    }
}
