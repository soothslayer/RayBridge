import SwiftUI
import AVFoundation
import UIKit
import OSLog
import Darwin

private let cameraImagePreferenceKey = "alwaysSendCameraImage"
private let speechVoicePreferenceKey = "speechVoiceIdentifier"
private let answerVoiceEnginePreferenceKey = "answerVoiceEngine"
private let kokoroVoicePreferenceKey = "kokoroVoiceIdentifier"

enum AnswerVoiceEngine: String, CaseIterable, Identifiable {
    case apple
    case kokoro
    var id: String { rawValue }
    var displayName: String { self == .apple ? "Apple speech on iPhone" : "Kokoro on Mac" }
}

struct KokoroVoiceOption: Identifiable {
    let id: String
    let displayName: String
    static let english = [
        KokoroVoiceOption(id: "af_heart", displayName: "Heart, American female"),
        KokoroVoiceOption(id: "af_bella", displayName: "Bella, American female"),
        KokoroVoiceOption(id: "af_nova", displayName: "Nova, American female"),
        KokoroVoiceOption(id: "af_sarah", displayName: "Sarah, American female"),
        KokoroVoiceOption(id: "af_sky", displayName: "Sky, American female"),
        KokoroVoiceOption(id: "am_fenrir", displayName: "Fenrir, American male"),
        KokoroVoiceOption(id: "am_michael", displayName: "Michael, American male"),
        KokoroVoiceOption(id: "am_puck", displayName: "Puck, American male"),
        KokoroVoiceOption(id: "bf_emma", displayName: "Emma, British female"),
        KokoroVoiceOption(id: "bf_isabella", displayName: "Isabella, British female"),
        KokoroVoiceOption(id: "bm_daniel", displayName: "Daniel, British male"),
        KokoroVoiceOption(id: "bm_george", displayName: "George, British male")
    ]
}

// Accept only static messages so transcripts, camera data, and pairing credentials
// cannot accidentally be passed to the persistent device log.
enum RayBridgeDiagnostics {
    private static let logger = Logger(subsystem: "org.raybridge.ios", category: "lifecycle")
    static func event(_ message: StaticString) {
        let text = String(describing: message)
        logger.notice("\(text, privacy: .public)")
        #if DEBUG
        print("[RayBridge] \(text)")
        fflush(stdout)
        #endif
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Tap Start RayBridge to begin"
    @Published var cameraStatus = "Camera off"
    @Published var connected = false
    @Published private(set) var sessionPhase = SessionController.Phase.idle
    @Published var showingSetup = false
    var running: Bool { sessionPhase == .running }
    var sessionActive: Bool { sessionPhase != .idle }
    @Published var busy = false
    @Published var cameraActive = false
    @Published var cameraRequested = false
    @Published var registrationStatus = ""
    @Published private(set) var registeringGlasses = false
    @Published var transcript = ""
    @Published var answer = ""
    @Published var error: String?
    @Published var pairingText = ""
    @Published var typedQuestion = ""
    @Published var phoneAudio = false
    @Published var answerVoiceEngine = AnswerVoiceEngine(
        rawValue: UserDefaults.standard.string(forKey: answerVoiceEnginePreferenceKey) ?? ""
    ) ?? .apple {
        didSet { UserDefaults.standard.set(answerVoiceEngine.rawValue, forKey: answerVoiceEnginePreferenceKey) }
    }
    @Published var kokoroVoiceIdentifier = UserDefaults.standard.string(forKey: kokoroVoicePreferenceKey) ?? "af_heart" {
        didSet { UserDefaults.standard.set(kokoroVoiceIdentifier, forKey: kokoroVoicePreferenceKey) }
    }
    let kokoroVoices = KokoroVoiceOption.english
    @Published var speechVoiceIdentifier = "" {
        didSet {
            speech.voiceIdentifier = speechVoiceIdentifier
            UserDefaults.standard.set(speechVoiceIdentifier, forKey: speechVoicePreferenceKey)
        }
    }
    @Published private(set) var speechVoices: [SpeechVoiceOption] = []
    @Published var alwaysSendCameraImage: Bool = UserDefaults.standard.object(forKey: cameraImagePreferenceKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(alwaysSendCameraImage, forKey: cameraImagePreferenceKey) }
    }
    @Published var pairedHost: String? = Pairing.load()?.host
    private let connection = BridgeConnection()
    private let camera = GlassesCamera()
    private let speech = SpeechController()
    private var frame: (data: Data, date: Date)?
    private var connectionFailure: String?
    private var activity = 0
    private var cameraAnnounced = false
    private var pendingCameraAnnouncement = false

    private lazy var session = SessionController(
        connect: { [unowned self] in try await connectForSession() },
        authorize: { [unowned self] in try await speech.permissions() },
        startCamera: { [unowned self] in
            cameraRequested = true; cameraAnnounced = false
            try await camera.start()
        },
        startAudio: { [unowned self] in
            guard let frame, Date().timeIntervalSince(frame.date) < 2.5 else {
                throw BridgeError.message("No current camera image. Tap Start RayBridge to try again.")
            }
            speech.allowPhoneAudio = phoneAudio
            try speech.startListening()
        },
        stopImmediately: { [unowned self] in
            activity += 1; busy = false; cameraRequested = false
            pendingCameraAnnouncement = false; cameraActive = false; frame = nil
            speech.stop()
            // Closing the phone connection also cancels its pending Mac answer.
            connection.disconnect(); connected = false
            UIApplication.shared.isIdleTimerDisabled = false
        },
        stopCamera: { [unowned self] in await camera.stop() }
    )

    init() {
        RayBridgeDiagnostics.event("App model initialization started")
        refreshSpeechVoices()
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onError = { [weak self] message in
            guard let self else { return }
            self.connected = false; self.connectionFailure = message
            if self.sessionPhase == .connecting { return } // The startup task reports this failure.
            guard self.sessionActive, self.sessionPhase != .stopping else { return }
            self.stop(); self.fail(message)
        }
        camera.onFrame = { [weak self] data in
            guard let self, self.cameraRequested else { return }
            self.frame = (data, Date()); self.cameraActive = true; self.cameraStatus = "Glasses camera connected"
            if !self.cameraAnnounced {
                self.cameraAnnounced = true
                self.pendingCameraAnnouncement = true
                self.announceCameraIfReady()
            }
        }
        camera.onRegistration = { [weak self] in self?.registrationStatus = $0 }
        camera.onStatus = { [weak self] text, active in
            guard let self else { return }
            self.cameraStatus = text; self.cameraActive = active
            if self.sessionPhase == .startingCamera { self.status = text }
            if !active {
                self.frame = nil
                let current = self.activity
                if self.connected {
                    Task {
                        guard current == self.activity, self.connected else { return }
                        try? await self.connection.send(["type": "camera.off"])
                    }
                }
            }
        }
        // Give Bluetooth discovery time to initialize before registration or a
        // camera request, and restore the registration label after relaunch.
        do { try camera.configure() }
        catch { cameraStatus = "Glasses discovery could not initialize. Reopen RayBridge." }
        session.onPhase = { [weak self] phase in self?.sessionChanged(phase) }
        session.onError = { [weak self] error in self?.fail(error.localizedDescription) }
        speech.onQuestion = { [weak self] text in self?.ask(text) }
        speech.onTranscript = { [weak self] in self?.transcript = $0 }
        speech.onStartedListening = { [weak self] in self?.status = "Listening" }
        speech.onError = { [weak self] message in
            guard let self, self.running else { return }
            self.stop(); self.fail(message)
        }
        speech.onFinishedSpeaking = { [weak self] in
            guard let self else { return }
            if self.pendingCameraAnnouncement { self.announceCameraIfReady() }
            else { self.resumeListening() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, self.running, !self.phoneAudio,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.stop(); self.fail("Glasses audio disconnected. Reconnect the glasses, then start again.")
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.running else { return }
                self.stop(); self.fail("Audio interrupted. Tap Start RayBridge when ready.")
            }
        }
        RayBridgeDiagnostics.event("App model initialization finished")
    }
    func refreshSpeechVoices() {
        speechVoices = speech.availableVoiceOptions()
        let saved = UserDefaults.standard.string(forKey: speechVoicePreferenceKey)
        speechVoiceIdentifier = speech.preferredVoiceIdentifier(savedIdentifier: saved) ?? ""
        speech.voiceIdentifier = speechVoiceIdentifier
    }
    func previewSpeechVoice() {
        guard !sessionActive else { return }
        error = nil
        speech.allowPhoneAudio = true
        do { try speech.speak("Hello. I’m the RayBridge voice. I’ll read Codex answers to you.") }
        catch { fail("The voice preview could not play. \(error.localizedDescription)") }
        speech.allowPhoneAudio = phoneAudio
    }
    func fail(_ message: String) {
        RayBridgeDiagnostics.event("An error was presented in the app")
        error = message; status = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
    func pair() {
        do {
            let pairing = try Pairing(link: pairingText)
            guard !sessionActive else { return }
            try pairing.save(); pairedHost = pairing.host; pairingText = ""; error = nil
            status = "Mac paired. Tap Start RayBridge to begin."
        } catch { fail(error.localizedDescription) }
    }
    private func connectForSession() async throws {
        guard let pairing = Pairing.load() else {
            throw BridgeError.message("Open Setup and pair your Mac first.")
        }
        RayBridgeDiagnostics.event("Mac connection requested")
        connected = false; connectionFailure = nil
        connection.connect(pairing)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !connected {
            try Task.checkCancellation()
            if let connectionFailure { throw BridgeError.message(connectionFailure) }
            guard ContinuousClock.now < deadline else {
                throw BridgeError.message("The Mac did not answer. Check that RayBridge is open on your Mac and both devices are on the same Wi-Fi.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }
    func handle(_ url: URL) {
        if url.host == "pair" {
            stop(); pairingText = url.absoluteString; showingSetup = true
            status = "Pairing link received. Tap Pair Mac in Setup."
        }
        else { Task { do { try await camera.handle(url) } catch { fail(error.localizedDescription) } } }
    }
    func registerGlasses() {
        guard !sessionActive, !registeringGlasses else { return }
        registeringGlasses = true; error = nil
        RayBridgeDiagnostics.event("Meta AI registration requested")
        Task {
            defer { registeringGlasses = false }
            do {
                try await camera.register()
                if !registrationStatus.isEmpty { status = "Glasses registered. Tap Start RayBridge to begin." }
            } catch { fail(error.localizedDescription) }
        }
    }
    private func announceCameraIfReady() {
        guard running, pendingCameraAnnouncement, cameraActive, !busy, !speech.isSpeaking else { return }
        pendingCameraAnnouncement = false
        do {
            // SpeechController pauses recognition while this plays, preventing
            // the ready cue from becoming the user's first question.
            speech.allowPhoneAudio = phoneAudio
            try speech.speak("Glasses camera connected. Listening.")
        } catch {
            RayBridgeDiagnostics.event("Camera connected, but audio confirmation could not play")
            self.error = "Camera connected, but audio confirmation could not play. Check glasses Bluetooth audio."
            resumeListening()
        }
    }
    private func sessionChanged(_ phase: SessionController.Phase) {
        sessionPhase = phase
        switch phase {
        case .idle:
            if error == nil { status = "Stopped. Tap Start RayBridge to begin." }
        case .connecting: status = "Connecting to your Mac…"
        case .authorizing: status = "Checking microphone and speech permissions…"
        case .startingCamera: status = "Connecting glasses camera…"
        case .startingAudio: status = "Preparing microphone…"
        case .running:
            status = "Listening"
            RayBridgeDiagnostics.event("RayBridge session ready with camera and microphone")
            announceCameraIfReady()
        case .stopping: status = "Stopping RayBridge…"
        }
    }
    func background() {
        // The permission handoff is part of startup, not a request to stop it.
        if camera.awaitingPermission { return }
        if sessionActive { stop() }
    }
    func start() {
        guard !sessionActive else { return }
        guard Pairing.load() != nil else {
            showingSetup = true; fail("Open Setup and pair your Mac first."); return
        }
        guard camera.isRegistered else {
            showingSetup = true; fail("Open Setup and register your glasses with Meta AI first."); return
        }
        RayBridgeDiagnostics.event("Start RayBridge requested")
        activity += 1; error = nil; pendingCameraAnnouncement = false
        UIApplication.shared.isIdleTimerDisabled = true
        session.start()
    }
    func stop() {
        RayBridgeDiagnostics.event("Stop RayBridge requested")
        session.stop()
    }
    func ask(_ text: String) {
        guard running, connected, !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        RayBridgeDiagnostics.event("Question submitted to Mac")
        speech.stop(); busy = true; transcript = text; error = nil; status = "Asking ChatGPT…"
        do {
            speech.allowPhoneAudio = phoneAudio
            try speech.startThinkingHeartbeat()
        } catch {
            RayBridgeDiagnostics.event("Thinking heartbeat could not play")
        }
        let current = activity
        Task {
            do {
                guard current == activity, running else { return }
                let shouldSendImage = CameraImagePolicy.shouldSendImage(for: text, alwaysSend: alwaysSendCameraImage)
                if shouldSendImage, let frame, Date().timeIntervalSince(frame.date) < 2.5 {
                    try await connection.send(["type": "frame", "jpeg": frame.data.base64EncodedString()])
                } else { try await connection.send(["type": "camera.off"]) }
                guard current == activity else { return }
                try await connection.send(["type": "ask", "text": text,
                                           "ttsEngine": answerVoiceEngine.rawValue,
                                           "ttsVoice": kokoroVoiceIdentifier])
            } catch {
                guard current == activity, running else { return }
                stop(); fail(error.localizedDescription)
            }
        }
    }
    func reset() {
        stop(); answer = ""; transcript = ""; frame = nil
    }
    private func resumeListening() {
        guard running, connected else { return }
        status = "Preparing to listen…"
        do { try speech.startListeningWithCue() }
        catch { stop(); fail(error.localizedDescription) }
    }
    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            RayBridgeDiagnostics.event("Mac connection ready")
            guard sessionPhase == .connecting else { return }
            connected = true
        case "thinking":
            guard running, busy else { return }
            status = message["hasImage"] as? Bool == true ? "Thinking with a current camera image…" : "Thinking. No current camera image."
        case "answer":
            guard running, busy, let text = message["text"] as? String else { return }
            RayBridgeDiagnostics.event("Answer received from Mac")
            busy = false; answer = text; status = "Answer ready"
            do {
                speech.allowPhoneAudio = phoneAudio
                if let audio = message["audio"] as? [String: Any],
                   audio["format"] as? String == "m4a",
                   let encoded = audio["data"] as? String,
                   let data = Data(base64Encoded: encoded) {
                    try speech.speakAudio(data)
                    status = "Speaking with Kokoro"
                } else {
                    try speech.speak(text)
                    status = message["ttsFallback"] == nil ? "Speaking" : "Speaking with Apple voice. Kokoro is unavailable on the Mac."
                }
            } catch { stop(); fail(error.localizedDescription) }
        case "error":
            let text = message["message"] as? String ?? "The Mac reported an error."
            if sessionPhase == .connecting { connectionFailure = text; return }
            guard sessionActive, sessionPhase != .stopping else { return }
            stop(); fail(text)
        default: break
        }
    }
}
