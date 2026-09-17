import SwiftUI
import AVFoundation
import UIKit
import OSLog
import Darwin

private let cameraImagePreferenceKey = "alwaysSendCameraImage"
private let speechVoicePreferenceKey = "speechVoiceIdentifier"
private let answerVoiceEnginePreferenceKey = "answerVoiceEngine"
private let kokoroVoicePreferenceKey = "kokoroVoiceIdentifier"
private let voiceCommandsPreferenceKey = "voiceCommandsEnabled"
private let legacyStopCommandPreferenceKey = "stopCommandEnabled"
private let handsFreeStandbyPreferenceKey = "handsFreeStandbyEnabled"
private let thinkingHeartbeatPreferenceKey = "thinkingHeartbeatEnabled"
private let assistantProviderPreferenceKey = "assistantProvider"

private func initialVoiceCommandsEnabled() -> Bool {
    let defaults = UserDefaults.standard
    if let saved = defaults.object(forKey: voiceCommandsPreferenceKey) as? Bool { return saved }
    if let legacy = defaults.object(forKey: legacyStopCommandPreferenceKey) as? Bool { return legacy }
    return true
}

enum AnswerVoiceEngine: String, CaseIterable, Identifiable {
    case apple
    case kokoro
    var id: String { rawValue }
    var displayName: String { self == .apple ? "Apple speech on iPhone" : "Kokoro on Mac" }
}

enum AssistantProvider: String, CaseIterable, Identifiable {
    case codex
    case claude
    var id: String { rawValue }
    var displayName: String { self == .codex ? "Codex" : "Claude Code" }
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
    @Published var phoneAudio = false {
        didSet { refreshStandbyListening() }
    }
    @Published var assistantProvider = AssistantProvider(
        rawValue: UserDefaults.standard.string(forKey: assistantProviderPreferenceKey) ?? ""
    ) ?? .codex {
        didSet { UserDefaults.standard.set(assistantProvider.rawValue, forKey: assistantProviderPreferenceKey) }
    }
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
    @Published var thinkingHeartbeatEnabled: Bool = UserDefaults.standard.object(forKey: thinkingHeartbeatPreferenceKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(thinkingHeartbeatEnabled, forKey: thinkingHeartbeatPreferenceKey) }
    }
    @Published var voiceCommandsEnabled = initialVoiceCommandsEnabled() {
        didSet {
            UserDefaults.standard.set(voiceCommandsEnabled, forKey: voiceCommandsPreferenceKey)
            speech.voiceCommandsEnabled = voiceCommandsEnabled
            refreshStandbyListening()
        }
    }
    @Published var handsFreeStandbyEnabled: Bool = UserDefaults.standard.object(forKey: handsFreeStandbyPreferenceKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(handsFreeStandbyEnabled, forKey: handsFreeStandbyPreferenceKey)
            refreshStandbyListening()
        }
    }
    @Published private(set) var muted = false
    private var cancellationPending = false
    private var cancellationToken: UUID?
    private var cancellationTimeout: Task<Void, Never>?
    @Published var pairedHost: String? = Pairing.load()?.host
    private let connection = BridgeConnection()
    private let camera = GlassesCamera()
    private let speech = SpeechController()
    private var frame: (data: Data, date: Date)?
    private var connectionFailure: String?
    private var activity = 0
    private var cameraAnnounced = false
    private var pendingCameraAnnouncement = false
    private var pendingErrorAnnouncement: String?
    private var commandConfirmationPending = false
    private var pendingAnswerMessage: [String: Any]?
    private var appIsActive = false

    private var activeResponseCommands: Set<VoiceCommand> {
        voiceCommandsEnabled ? [.stop, .cancel, .mute] : []
    }
    private var currentResponseCommands: Set<VoiceCommand> {
        muted ? [.unmute] : activeResponseCommands
    }

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
            speech.voiceCommandsEnabled = voiceCommandsEnabled
            speech.questionCommands = [.stop, .cancel, .mute]
            try speech.startListening()
        },
        stopImmediately: { [unowned self] in
            activity += 1; busy = false; cameraRequested = false
            muted = false
            commandConfirmationPending = false; pendingAnswerMessage = nil
            cancellationPending = false; cancellationToken = nil; cancellationTimeout?.cancel()
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
        speech.voiceCommandsEnabled = voiceCommandsEnabled
        speech.onVoiceCommand = { [weak self] command in self?.handleVoiceCommand(command) }
        speech.onQuestion = { [weak self] text in self?.ask(text) }
        speech.onTranscript = { [weak self] in self?.transcript = $0 }
        speech.onStartedListening = { [weak self] in
            guard let self, self.running, !self.muted else { return }
            self.status = "Listening"
        }
        speech.onError = { [weak self] message in
            guard let self else { return }
            if self.running {
                self.stop(); self.fail(message)
            } else {
                self.speech.stop()
                if self.error == nil { self.status = "Stopped. Tap Start RayBridge to begin." }
            }
        }
        speech.onFinishedSpeaking = { [weak self] in
            guard let self else { return }
            self.speech.allowPhoneAudio = self.phoneAudio
            if self.commandConfirmationPending { return }
            if let message = self.pendingErrorAnnouncement { self.speakError(message) }
            else if self.pendingCameraAnnouncement { self.announceCameraIfReady() }
            else if self.running { self.resumeListening() }
            else { self.refreshStandbyListening() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self else { return }
                if !self.sessionActive,
                   reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                    self.refreshStandbyListening()
                } else if self.running, !self.phoneAudio,
                          reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self.stop(); self.fail("Glasses audio disconnected. Reconnect the glasses, then start again.")
                }
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
        guard appIsActive, !UIAccessibility.isVoiceOverRunning else {
            pendingErrorAnnouncement = nil
            return
        }
        if sessionActive { pendingErrorAnnouncement = message }
        else { speakError(message) }
    }
    private func speakError(_ message: String) {
        guard appIsActive, !UIAccessibility.isVoiceOverRunning else {
            pendingErrorAnnouncement = nil
            return
        }
        pendingErrorAnnouncement = nil
        speech.allowPhoneAudio = true
        do { try speech.speak("Error. \(message)") }
        catch {
            // The visual error and VoiceOver announcement remain available if
            // neither the glasses nor iPhone speaker can play the message.
            speech.allowPhoneAudio = phoneAudio
        }
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
        connection.connect(pairing, assistant: assistantProvider.rawValue)
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
            // During the announcement, recognition accepts only voice controls so the
            // ready cue cannot become the user's first question.
            speech.allowPhoneAudio = phoneAudio
            try speech.speak("Glasses camera connected. Listening.", listenForCommands: currentResponseCommands)
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
            if let message = pendingErrorAnnouncement { speakError(message) }
            else { refreshStandbyListening() }
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
        appIsActive = false
        pendingErrorAnnouncement = nil
        commandConfirmationPending = false; pendingAnswerMessage = nil
        // The permission handoff is part of startup, not a request to stop it.
        if camera.awaitingPermission { return }
        if sessionActive { stop() }
        else { speech.stop() }
    }
    func foreground() {
        appIsActive = true
        if let message = pendingErrorAnnouncement { speakError(message) }
        else { refreshStandbyListening() }
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
        speech.stop()
        pendingErrorAnnouncement = nil
        commandConfirmationPending = false; pendingAnswerMessage = nil
        speech.allowPhoneAudio = phoneAudio
        activity += 1; error = nil; muted = false; pendingCameraAnnouncement = false
        UIApplication.shared.isIdleTimerDisabled = true
        session.start()
    }
    func stop() {
        RayBridgeDiagnostics.event("Stop RayBridge requested")
        session.stop()
    }
    private func refreshStandbyListening() {
        guard !sessionActive else { return }
        guard appIsActive, voiceCommandsEnabled, handsFreeStandbyEnabled,
              speech.hasRecognitionPermissions else {
            speech.stop()
            if error == nil { status = "Stopped. Tap Start RayBridge to begin." }
            return
        }
        speech.allowPhoneAudio = phoneAudio
        do {
            try speech.startCommandListening(for: [.start])
            if error == nil { status = "Stopped. Say Start or tap Start RayBridge." }
        } catch {
            // Standby is optional. The button remains available when glasses
            // audio is disconnected or recognition cannot start.
            speech.stop()
            if self.error == nil { status = "Stopped. Tap Start RayBridge to begin." }
        }
    }
    private func handleVoiceCommand(_ command: VoiceCommand) {
        switch command {
        case .start:
            guard !sessionActive else { return }
            status = "Starting RayBridge…"
            confirmVoiceCommand("Starting.", preservingCurrentOutput: false) { [weak self] in
                self?.start()
            }
        case .stop:
            guard sessionActive else { return }
            status = "Stopping RayBridge…"
            confirmVoiceCommand("Stopping.", preservingCurrentOutput: false) { [weak self] in
                self?.stop()
            }
        case .cancel:
            cancelCurrentTurn(verballyConfirm: true)
        case .mute:
            muteVoiceInput()
        case .unmute:
            unmuteVoiceInput()
        }
    }
    private func confirmVoiceCommand(
        _ message: String,
        preservingCurrentOutput: Bool,
        completion: @escaping () -> Void
    ) {
        commandConfirmationPending = true
        speech.allowPhoneAudio = phoneAudio
        let finish = { [weak self] in
            guard let self else { return }
            self.commandConfirmationPending = false
            completion()
            if self.running, let pending = self.pendingAnswerMessage {
                self.pendingAnswerMessage = nil
                self.receive(pending)
            } else if !self.running {
                self.pendingAnswerMessage = nil
            }
        }
        do {
            try speech.speakCommandConfirmation(
                message,
                preservingCurrentOutput: preservingCurrentOutput,
                completion: finish)
        } catch {
            finish()
        }
    }
    private func muteVoiceInput() {
        guard running, !muted else { return }
        RayBridgeDiagnostics.event("Voice Mute requested")
        muted = true
        status = "Muting voice input…"
        confirmVoiceCommand("Muted.", preservingCurrentOutput: true) { [weak self] in
            self?.listenForUnmute()
        }
    }
    private func unmuteVoiceInput() {
        guard running, muted else { return }
        RayBridgeDiagnostics.event("Voice Unmute requested")
        muted = false
        status = "Unmuting voice input…"
        confirmVoiceCommand("Unmuted.", preservingCurrentOutput: true) { [weak self] in
            guard let self, self.running else { return }
            if self.busy || self.speech.isSpeaking {
                do { try self.speech.startCommandListening(for: self.activeResponseCommands) }
                catch { self.stop(); self.fail(error.localizedDescription); return }
                self.status = self.busy ? "Thinking. Voice input unmuted." : "Speaking. Voice input unmuted."
            } else {
                self.resumeListening()
            }
        }
    }
    private func listenForUnmute() {
        guard running, connected, muted else { return }
        do { try speech.startCommandListening(for: [.unmute]) }
        catch { stop(); fail(error.localizedDescription); return }
        if busy { status = "Muted while Codex is thinking. Say Unmute." }
        else if speech.isSpeaking { status = "Muted while the answer is speaking. Say Unmute." }
        else { status = "Muted. Say Unmute to ask another question." }
    }
    func ask(_ text: String) {
        guard running, connected, !muted, !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        RayBridgeDiagnostics.event("Question submitted to Mac")
        speech.stop(); busy = true; transcript = text; error = nil; status = "Asking ChatGPT…"
        speech.allowPhoneAudio = phoneAudio
        do { try speech.startCommandListening(for: currentResponseCommands) }
        catch { stop(); fail(error.localizedDescription); return }
        if thinkingHeartbeatEnabled {
            do {
                speech.allowPhoneAudio = phoneAudio
                try speech.startThinkingHeartbeat()
            } catch {
                RayBridgeDiagnostics.event("Thinking heartbeat could not play")
            }
        }
        let current = activity
        Task {
            do {
                // Listen immediately after Cancel, but do not overlap Codex turns.
                while cancellationPending {
                    try await Task.sleep(for: .milliseconds(50))
                    guard current == activity, running else { return }
                }
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
    private func cancelCurrentTurn(verballyConfirm: Bool) {
        guard running, connected else { return }
        RayBridgeDiagnostics.event("Voice Cancel requested")
        activity += 1
        let needsMacCancellation = busy || cancellationPending
        let alreadyCancelling = cancellationPending
        busy = false; cancellationPending = needsMacCancellation; pendingCameraAnnouncement = false
        transcript = ""; error = nil
        if verballyConfirm {
            status = "Cancelling current turn…"
            confirmVoiceCommand("Cancelling.", preservingCurrentOutput: false) { [weak self] in
                self?.resumeListening()
            }
        } else {
            speech.stop()
            resumeListening()
        }
        guard needsMacCancellation, running, !alreadyCancelling else { return }
        let token = UUID()
        cancellationToken = token
        cancellationTimeout?.cancel()
        cancellationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.cancellationPending, token == self.cancellationToken else { return }
            self.stop(); self.fail("The Mac did not confirm Cancel. Start RayBridge again to reconnect.")
        }
        Task {
            do {
                guard token == cancellationToken, running else { return }
                try await connection.send(["type": "cancel"])
            } catch {
                guard token == cancellationToken, running else { return }
                stop(); fail(error.localizedDescription)
            }
        }
    }
    func reset() {
        stop(); answer = ""; transcript = ""; frame = nil
    }
    private func resumeListening() {
        guard running, connected else { return }
        if muted {
            listenForUnmute()
            return
        }
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
            guard running, busy, !cancellationPending else { return }
            if muted { status = "Muted while Codex is thinking. Say Unmute." }
            else { status = message["hasImage"] as? Bool == true ? "Thinking with a current camera image…" : "Thinking. No current camera image." }
        case "answer":
            guard running, busy, !cancellationPending, let text = message["text"] as? String else { return }
            if commandConfirmationPending {
                pendingAnswerMessage = message
                return
            }
            RayBridgeDiagnostics.event("Answer received from Mac")
            busy = false; answer = text; status = "Answer ready"
            do {
                speech.allowPhoneAudio = phoneAudio
                if let audio = message["audio"] as? [String: Any],
                   audio["format"] as? String == "m4a",
                   let encoded = audio["data"] as? String,
                   let data = Data(base64Encoded: encoded) {
                    try speech.speakAudio(data, listenForCommands: currentResponseCommands)
                    status = muted ? "Muted while the answer is speaking. Say Unmute." : "Speaking with Kokoro"
                } else {
                    try speech.speak(text, listenForCommands: currentResponseCommands)
                    status = muted ? "Muted while the answer is speaking. Say Unmute."
                        : message["ttsFallback"] == nil ? "Speaking" : "Speaking with Apple voice. Kokoro is unavailable on the Mac."
                }
            } catch { stop(); fail(error.localizedDescription) }
        case "cancelled":
            guard running, cancellationPending else { return }
            cancellationPending = false; cancellationToken = nil; cancellationTimeout?.cancel()
        case "error":
            // An old turn can fail while the cancellation is in flight.
            // The timeout reconnects if the Mac cannot acknowledge cancellation.
            if cancellationPending { return }
            let text = message["message"] as? String ?? "The Mac reported an error."
            if sessionPhase == .connecting { connectionFailure = text; return }
            guard sessionActive, sessionPhase != .stopping else { return }
            stop(); fail(text)
        default: break
        }
    }
}
