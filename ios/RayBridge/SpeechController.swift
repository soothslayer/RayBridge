import AVFoundation
import Speech

struct SpeechVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let languageName: String
    let qualityName: String

    var displayName: String { "\(name), \(qualityName), \(languageName)" }
}

@MainActor
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var onQuestion: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinishedSpeaking: (() -> Void)?
    var onStartedListening: (() -> Void)?
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
    private var answerPlayer: AVAudioPlayer?
    private enum CueAction { case startListening, submit(String) }
    private var cuePlayer: AVAudioPlayer?
    private var cueAction: CueAction?
    private var heartbeatPlayer: AVAudioPlayer?
    var allowPhoneAudio = false
    var voiceIdentifier: String?
    var isSpeaking: Bool { synthesizer.isSpeaking || answerPlayer?.isPlaying == true }

    override init() { super.init(); synthesizer.delegate = self }

    func availableVoiceOptions() -> [SpeechVoiceOption] {
        Self.englishVoices.map { voice in
            SpeechVoiceOption(
                id: voice.identifier,
                name: voice.name,
                languageName: Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language,
                qualityName: Self.qualityName(voice.quality)
            )
        }
    }

    func preferredVoiceIdentifier(savedIdentifier: String?) -> String? {
        let voices = Self.englishVoices
        if let savedIdentifier, voices.contains(where: { $0.identifier == savedIdentifier }) {
            return savedIdentifier
        }
        return voices.first(where: { $0.language == "en-US" })?.identifier
            ?? AVSpeechSynthesisVoice(language: "en-US")?.identifier
            ?? voices.first?.identifier
    }

    private static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-") }
            .sorted { left, right in
                let leftUS = left.language == "en-US" ? 1 : 0
                let rightUS = right.language == "en-US" ? 1 : 0
                if leftUS != rightUS { return leftUS > rightUS }
                let leftQuality = qualityRank(left.quality)
                let rightQuality = qualityRank(right.quality)
                if leftQuality != rightQuality { return leftQuality > rightQuality }
                if left.name != right.name { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
                return left.identifier < right.identifier
            }
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
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
    private func audioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)
        if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try session.setPreferredInput(glasses)
        } else if !allowPhoneAudio {
            throw BridgeError.message("Connect your glasses as a Bluetooth headset before listening.")
        }
    }
    var hasBluetoothRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP }
    }
    func startListening() throws {
        cancelCue()
        stopListening()
        try audioSession()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw BridgeError.message("On-device English speech recognition is unavailable. Enable it on this iPhone, or type your question below.")
        }
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
        stopListening()
        do {
            try playCue(Self.stoppedListeningCue, action: .submit(text))
        } catch {
            // The question should still be submitted if the optional cue cannot play.
            onQuestion?(text)
        }
    }
    func stopListening() {
        listening = false; generation += 1
        silence?.cancel(); limit?.cancel()
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }
    func startListeningWithCue() throws {
        stopThinkingHeartbeat()
        cancelCue()
        stopListening()
        try playCue(Self.listeningCue, action: .startListening)
    }
    func startThinkingHeartbeat() throws {
        stopThinkingHeartbeat()
        try audioSession()
        let player = try AVAudioPlayer(data: Self.thinkingHeartbeat)
        player.volume = 0.65
        player.numberOfLoops = -1
        player.prepareToPlay()
        heartbeatPlayer = player
        if !player.play() { heartbeatPlayer = nil }
    }
    func stopThinkingHeartbeat() {
        heartbeatPlayer?.stop()
        heartbeatPlayer = nil
    }
    func speak(_ text: String) throws {
        cancelCue()
        stopThinkingHeartbeat()
        stopListening()
        answerPlayer?.stop()
        answerPlayer = nil
        if synthesizer.isSpeaking {
            spokenUtterance = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        try audioSession()
        guard allowPhoneAudio || hasBluetoothRoute else {
            throw BridgeError.message("Glasses audio disconnected. The answer is available on screen.")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        spokenUtterance = utterance
        synthesizer.speak(utterance)
    }
    func speakAudio(_ data: Data) throws {
        cancelCue()
        stopThinkingHeartbeat()
        stopListening()
        if synthesizer.isSpeaking {
            spokenUtterance = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        answerPlayer?.stop()
        answerPlayer = nil
        try audioSession()
        guard allowPhoneAudio || hasBluetoothRoute else {
            throw BridgeError.message("Glasses audio disconnected. The answer is available on screen.")
        }
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        answerPlayer = player
        if !player.play() {
            answerPlayer = nil
            throw BridgeError.message("The Kokoro answer audio could not play.")
        }
    }
    func stop() {
        spokenUtterance = nil
        answerPlayer?.stop()
        answerPlayer = nil
        cancelCue()
        stopThinkingHeartbeat()
        stopListening(); synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func playCue(_ data: Data, action: CueAction) throws {
        try audioSession()
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.volume = 0.8
        player.prepareToPlay()
        cueAction = action
        cuePlayer = player
        if !player.play() { finishCue() }
    }
    private func finishCue() {
        let action = cueAction
        cueAction = nil
        cuePlayer = nil
        switch action {
        case .startListening:
            do { try startListening(); onStartedListening?() }
            catch { onError?(error.localizedDescription) }
        case .submit(let question): onQuestion?(question)
        case nil: break
        }
    }
    private func cancelCue() {
        cueAction = nil
        cuePlayer?.stop()
        cuePlayer = nil
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.answerPlayer === player {
                self.answerPlayer = nil
                self.onFinishedSpeaking?()
            } else if self.cuePlayer === player {
                self.finishCue()
            }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.spokenUtterance === utterance else { return }
            self.spokenUtterance = nil
            self.onFinishedSpeaking?()
        }
    }

    // Generate cues in memory so they cannot go missing from an archive. The
    // rising pair means listening, the falling pair means listening stopped,
    // and the soft double pulse repeats while Codex is working.
    private static let listeningCue = twoNoteCue(first: 660, second: 880)
    private static let stoppedListeningCue = twoNoteCue(first: 880, second: 660)
    private static let thinkingHeartbeat = makeWave(duration: 1.2) { _, time in
        func pulse(start: Double, duration: Double, frequency: Double) -> Double {
            let local = time - start
            guard local >= 0, local < duration else { return 0 }
            let envelope = sin(.pi * local / duration)
            return 0.22 * envelope * sin(2 * .pi * frequency * local)
        }
        return pulse(start: 0, duration: 0.075, frequency: 330) +
            pulse(start: 0.13, duration: 0.09, frequency: 260)
    }
    private static func twoNoteCue(first: Double, second: Double) -> Data {
        var phase = 0.0
        return makeWave(duration: 0.18) { frame, time in
            let progress = time / 0.18
            let frequency = progress < 0.5 ? first : second
            phase += 2.0 * .pi * frequency / 44_100.0
            let attack = min(1.0, Double(frame) / 180.0)
            let frameCount = Int(44_100.0 * 0.18)
            let release = min(1.0, Double(frameCount - frame) / 900.0)
            return 0.32 * min(attack, release) * sin(phase)
        }
    }
    private static func makeWave(duration: Double, sample: (Int, Double) -> Double) -> Data {
        let sampleRate: UInt32 = 44_100
        let frameCount = Int(Double(sampleRate) * duration)
        var samples = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let value = Int16(Double(Int16.max) * max(-1, min(1, sample(frame, time))))
            append(UInt16(bitPattern: value), to: &samples)
        }

        var wave = Data()
        wave.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count), to: &wave)
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wave)           // PCM format chunk length
        append(UInt16(1), to: &wave)            // Linear PCM
        append(UInt16(1), to: &wave)            // Mono
        append(sampleRate, to: &wave)
        append(sampleRate * 2, to: &wave)        // Bytes per second
        append(UInt16(2), to: &wave)             // Bytes per frame
        append(UInt16(16), to: &wave)            // Bits per sample
        wave.append(contentsOf: "data".utf8)
        append(UInt32(samples.count), to: &wave)
        wave.append(samples)
        return wave
    }
    private static func append(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
