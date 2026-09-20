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
private let captureSourcePreferenceKey = "preferredCaptureSource"

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
    case hermes
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .hermes: "Hermes"
        }
    }
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
    // Stage timings carry a fixed label and a duration only, never a question,
    // an answer, or anything about the camera image.
    static func timing(_ message: StaticString, milliseconds: Int) {
        let text = String(describing: message)
        logger.notice("\(text, privacy: .public): \(milliseconds, privacy: .public) ms")
        #if DEBUG
        print("[RayBridge] \(text): \(milliseconds) ms")
        fflush(stdout)
        #endif
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Tap Start RayBridge to begin"
    @Published var cameraStatus = "Camera off"
    @Published var connected = false
    // The source this session is running on, and the one Start prefers.
    @Published private(set) var captureSource = CaptureSource.glasses
    @Published var preferredCaptureSource = CaptureSource(
        rawValue: UserDefaults.standard.string(forKey: captureSourcePreferenceKey) ?? ""
    ) ?? .glasses {
        didSet {
            UserDefaults.standard.set(preferredCaptureSource.rawValue, forKey: captureSourcePreferenceKey)
            refreshStandbyListening()
        }
    }
    @Published private(set) var glassesWarning: GlassesWarning?
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
    private var turnClock: ContinuousClock.Instant?
    // What this phone has actually spoken of an answer that is still arriving.
    private var spokenAnswerPrefix = ""
    private var answerStreamStopped = false
    @Published private(set) var pairedMacs: [Pairing] = []
    @Published private(set) var selectedPairingID = ""
    @Published private(set) var pairedHost: String?
    private let connection = BridgeConnection()
    private let camera = GlassesCamera()
    private let phoneCamera = PhoneCamera()
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
    private var launchAnnouncementPending = true
    private var startupStage = StartupStage.other
    private var phoneCameraPausedForBackground = false
    private var phoneCameraTransition: Task<Void, Never>?

    // Without glasses there is no Bluetooth route to wait for, so the iPhone
    // speaker and microphone carry the whole session. While stopped, the saved
    // preference and any open no-glasses warning decide, so standby listening
    // and spoken warnings still work for someone who has no glasses at all.
    private var usePhoneAudio: Bool {
        if phoneAudio || captureSource.requiresPhoneAudio { return true }
        return !sessionActive && (preferredCaptureSource.requiresPhoneAudio || glassesWarning != nil)
    }
    private var activeCamera: any CameraSource { captureSource == .phone ? phoneCamera : camera }
    private var standbyCommands: Set<VoiceCommand> {
        glassesWarning == nil ? [.start, .commands] : [.start, .cancel, .commands]
    }

    private var activeResponseCommands: Set<VoiceCommand> {
        voiceCommandsEnabled ? [.stop, .cancel, .mute, .status, .repeat, .commands] : []
    }
    private var currentResponseCommands: Set<VoiceCommand> {
        muted ? [.unmute, .commands] : activeResponseCommands
    }

    private lazy var session = SessionController(
        connect: { [unowned self] in try await connectForSession() },
        authorize: { [unowned self] in try await speech.permissions() },
        startCamera: { [unowned self] in
            cameraRequested = true; cameraAnnounced = false
            try await activeCamera.start()
        },
        startAudio: { [unowned self] in
            guard let frame, Date().timeIntervalSince(frame.date) < 2.5 else {
                throw BridgeError.message("No current camera image. Tap Start RayBridge to try again.")
            }
            speech.allowPhoneAudio = usePhoneAudio
            speech.voiceCommandsEnabled = voiceCommandsEnabled
            speech.questionCommands = [.stop, .cancel, .mute, .status, .repeat, .commands]
            try speech.startListening()
        },
        stopImmediately: { [unowned self] in
            activity += 1; busy = false; cameraRequested = false
            phoneCameraPausedForBackground = false
            phoneCameraTransition?.cancel(); phoneCameraTransition = nil
            muted = false
            endAnswerStream()
            commandConfirmationPending = false; pendingAnswerMessage = nil
            cancellationPending = false; cancellationToken = nil; cancellationTimeout?.cancel()
            pendingCameraAnnouncement = false; cameraActive = false; frame = nil
            speech.stop()
            // Closing the phone connection also cancels its pending Mac answer.
            connection.disconnect(); connected = false
            UIApplication.shared.isIdleTimerDisabled = false
        },
        // Stop whichever source this session started, not just the glasses.
        stopCamera: { [unowned self] in await camera.stop(); await phoneCamera.stop() }
    )

    init() {
        RayBridgeDiagnostics.event("App model initialization started")
        refreshPairings()
        refreshSpeechVoices()
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onError = { [weak self] message in
            guard let self else { return }
            self.connected = false; self.connectionFailure = message
            if self.sessionPhase == .connecting { return } // The startup task reports this failure.
            guard self.sessionActive, self.sessionPhase != .stopping else { return }
            self.stop(); self.fail(message)
        }
        bind(.glasses, camera)
        bind(.phone, phoneCamera)
        camera.onRegistration = { [weak self] in self?.registrationStatus = $0 }
        // Give Bluetooth discovery time to initialize before registration or a
        // camera request, and restore the registration label after relaunch.
        do { try camera.configure() }
        catch { cameraStatus = "Glasses discovery could not initialize. Reopen RayBridge." }
        session.onPhase = { [weak self] phase in self?.sessionChanged(phase) }
        session.onError = { [weak self] error in
            guard let self else { return }
            let message = error.localizedDescription
            let stage = self.startupStage
            guard CaptureSourcePolicy.offersPhoneFallback(failedStage: stage, source: self.captureSource) else {
                self.fail(message); return
            }
            // fail() speaks this text, so the warning itself stays silent.
            self.fail("\(message) \(CaptureSourcePolicy.phoneFallbackOffer)")
            self.present(CaptureSourcePolicy.startupFailureWarning(message), announce: false)
        }
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
                if self.error == nil { self.status = self.idleStatus }
            }
        }
        speech.onFinishedSpeaking = { [weak self] in
            guard let self else { return }
            self.speech.allowPhoneAudio = self.usePhoneAudio
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
                } else if self.running, !self.usePhoneAudio,
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
    // Both camera sources report through the same handlers. A late callback from
    // the source this session is not using must not disturb its status or frame.
    private func bind(_ source: CaptureSource, _ sourceCamera: any CameraSource) {
        sourceCamera.onFrame = { [weak self] data in
            guard let self, self.cameraRequested, self.captureSource == source else { return }
            self.frame = (data, Date()); self.cameraActive = true
            self.cameraStatus = source.connectedStatus
            if !self.cameraAnnounced {
                self.cameraAnnounced = true
                self.pendingCameraAnnouncement = true
                self.announceCameraIfReady()
            }
        }
        sourceCamera.onStatus = { [weak self] text, active in
            guard let self, self.captureSource == source else { return }
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
        speech.allowPhoneAudio = usePhoneAudio
    }
    func fail(_ message: String) {
        RayBridgeDiagnostics.event("An error was presented in the app")
        error = message; status = message
        UIAccessibility.post(notification: .announcement, argument: message)
        guard appIsActive else {
            pendingErrorAnnouncement = message
            return
        }
        guard !UIAccessibility.isVoiceOverRunning else {
            pendingErrorAnnouncement = nil
            return
        }
        if sessionActive { pendingErrorAnnouncement = message }
        else { speakError(message) }
    }
    private func speakError(_ message: String) {
        guard appIsActive else {
            pendingErrorAnnouncement = message
            return
        }
        guard !UIAccessibility.isVoiceOverRunning else {
            pendingErrorAnnouncement = nil
            return
        }
        pendingErrorAnnouncement = nil
        speech.allowPhoneAudio = true
        do { try speech.speak("Error. \(message)") }
        catch {
            // The visual error and VoiceOver announcement remain available if
            // neither the glasses nor iPhone speaker can play the message.
            speech.allowPhoneAudio = usePhoneAudio
        }
    }
    func pair() {
        do {
            let pairing = try Pairing(link: pairingText)
            guard !sessionActive else { return }
            try pairing.save(); refreshPairings(); pairingText = ""; error = nil
            status = "Mac paired. Tap Start RayBridge to begin."
        } catch { fail(error.localizedDescription) }
    }
    func selectPairedMac(id: String) {
        guard !sessionActive, id != selectedPairingID else { return }
        do {
            try Pairing.select(id: id)
            refreshPairings()
            error = nil
            status = "Mac selected. Tap Start RayBridge to begin."
        } catch { fail(error.localizedDescription) }
    }
    private func refreshPairings() {
        pairedMacs = Pairing.recent()
        let selected = Pairing.load()
        selectedPairingID = selected?.id ?? ""
        pairedHost = selected?.host
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
                throw BridgeError.message("The Mac did not answer. Check that RayBridge is open on your Mac and both devices are on the same Wi-Fi network or tailnet.")
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
            speech.allowPhoneAudio = usePhoneAudio
            try speech.speak(captureSource.cameraReadyAnnouncement, listenForCommands: currentResponseCommands)
        } catch {
            RayBridgeDiagnostics.event("Camera connected, but audio confirmation could not play")
            self.error = captureSource == .glasses
                ? "Camera connected, but audio confirmation could not play. Check glasses Bluetooth audio."
                : "Camera connected, but audio confirmation could not play. Check the iPhone volume and silent switch."
            resumeListening()
        }
    }
    private func sessionChanged(_ phase: SessionController.Phase) {
        sessionPhase = phase
        startupStage = Self.stage(of: phase) ?? startupStage
        switch phase {
        case .idle:
            if error == nil { status = idleStatus }
            if let message = pendingErrorAnnouncement { speakError(message) }
            else { refreshStandbyListening() }
        case .connecting: status = "Connecting to your Mac…"
        case .authorizing: status = "Checking microphone and speech permissions…"
        case .startingCamera: status = captureSource.startingStatus
        case .startingAudio: status = "Preparing microphone…"
        case .running:
            status = "Listening"
            RayBridgeDiagnostics.event("RayBridge session ready with camera and microphone")
            announceCameraIfReady()
        case .stopping: status = "Stopping RayBridge…"
        }
    }
    // The stage a failure happened in decides whether dropping the glasses helps.
    private static func stage(of phase: SessionController.Phase) -> StartupStage? {
        switch phase {
        case .connecting: .connecting
        case .authorizing: .authorizing
        case .startingCamera: .startingCamera
        case .startingAudio: .startingAudio
        case .idle, .running, .stopping: nil
        }
    }
    func background() {
        appIsActive = false
        switch CaptureSourcePolicy.backgroundAction(
            sessionActive: sessionActive,
            source: captureSource,
            awaitingGlassesPermission: camera.awaitingPermission,
            phoneCameraSupportsBackground: phoneCamera.keepsCameraWhileBackgrounded
        ) {
        case .continueGlassesSession:
            // Meta's compressed camera stream and the active record/playback
            // audio session are both allowed to continue while locked.
            RayBridgeDiagnostics.event("Continuing glasses session in background")
        case .continuePhoneCameraSession:
            RayBridgeDiagnostics.event("Continuing iPhone camera session in background")
        case .continuePhoneAudioSession:
            RayBridgeDiagnostics.event("Continuing iPhone session without camera in background")
            phoneCameraPausedForBackground = true
            cameraRequested = false
            cameraActive = false
            frame = nil
            cameraStatus = "iPhone camera paused. Listening without camera."
            let current = activity
            if connected {
                Task {
                    guard current == self.activity, self.connected else { return }
                    try? await self.connection.send(["type": "camera.off"])
                }
            }
            phoneCameraTransition?.cancel()
            phoneCameraTransition = Task {
                await phoneCamera.stop()
                guard !Task.isCancelled else { return }
                guard current == activity, sessionActive, captureSource == .phone,
                      phoneCameraPausedForBackground else { return }
                cameraStatus = "iPhone camera paused. Listening without camera."
                if !busy, !speech.isSpeaking { status = "Listening without camera" }
            }
        case .preservePermissionHandoff:
            // Opening Meta AI for camera permission is still part of startup.
            RayBridgeDiagnostics.event("Preserving Meta AI permission handoff in background")
        case .stopStandbyListening:
            pendingErrorAnnouncement = nil
            commandConfirmationPending = false; pendingAnswerMessage = nil
            speech.stop()
        }
    }
    func foreground() {
        appIsActive = true
        // Keychain items protected with WhenUnlocked can be unavailable if iOS
        // created the model before the device was unlocked.
        refreshPairings()
        if phoneCameraPausedForBackground, sessionActive, captureSource == .phone {
            resumePhoneCameraAfterBackground()
        }
        // Teardown stops audio last, so wait for idle before speaking an error
        // that was saved while the app was in the background.
        if let message = pendingErrorAnnouncement, !sessionActive { speakError(message) }
        else if launchAnnouncementPending, !sessionActive { announceLaunch() }
        else if !speech.isSpeaking { refreshStandbyListening() }
    }

    private func resumePhoneCameraAfterBackground() {
        phoneCameraPausedForBackground = false
        cameraRequested = true
        cameraStatus = "Restarting iPhone camera…"
        let current = activity
        let pauseTask = phoneCameraTransition
        phoneCameraTransition = Task {
            await pauseTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await phoneCamera.start()
                guard current == activity, sessionActive, captureSource == .phone else { return }
                RayBridgeDiagnostics.event("iPhone camera resumed after background")
            } catch {
                guard current == activity, sessionActive, captureSource == .phone else { return }
                stop()
                fail("The iPhone camera could not resume. Start RayBridge again. \(error.localizedDescription)")
            }
        }
    }
    private func announceLaunch() {
        launchAnnouncementPending = false
        let message = voiceCommandsEnabled && handsFreeStandbyEnabled
            ? VoiceCommandPolicy.launchAnnouncement
            : "RayBridge is stopped. Tap Start RayBridge to begin."
        UIAccessibility.post(notification: .announcement, argument: message)
        guard !UIAccessibility.isVoiceOverRunning else {
            refreshStandbyListening()
            return
        }
        // The startup guidance must be audible before a glasses route exists.
        speech.allowPhoneAudio = true
        do { try speech.speak(message) }
        catch { refreshStandbyListening() }
    }
    func start() {
        guard !sessionActive else { return }
        guard Pairing.load() != nil else {
            showingSetup = true; fail("Open Setup and pair your Mac first."); return
        }
        dismissGlassesWarning(resumeStandby: false)
        switch CaptureSourcePolicy.decision(preferred: preferredCaptureSource, glasses: camera.readiness) {
        case .startWithGlasses: begin(using: .glasses)
        case .startWithPhone: begin(using: .phone)
        case .warnBeforePhone(let readiness):
            // Nothing is started yet: the user chooses the iPhone, the glasses, or neither.
            RayBridgeDiagnostics.event("Start requested without ready glasses")
            present(CaptureSourcePolicy.warning(for: readiness), announce: true)
        }
    }
    func startFromSystemRequest() {
        RayBridgeDiagnostics.event("System Start RayBridge request received")
        launchAnnouncementPending = false
        speech.stop()
        start()
    }
    // Continues the session on the iPhone camera and speaker alone.
    func continueWithoutGlasses() {
        dismissGlassesWarning(resumeStandby: false)
        begin(using: .phone)
    }
    func tryGlassesAnyway() {
        dismissGlassesWarning(resumeStandby: false)
        begin(using: .glasses)
    }
    func dismissGlassesWarning(resumeStandby: Bool = true) {
        guard glassesWarning != nil else { return }
        glassesWarning = nil
        if resumeStandby {
            if error == nil { status = idleStatus }
            refreshStandbyListening()
        }
    }
    private func present(_ warning: GlassesWarning, announce: Bool) {
        glassesWarning = warning
        status = warning.message
        // A startup failure has already been announced and spoken by fail().
        guard announce else { return }
        UIAccessibility.post(notification: .announcement, argument: warning.message)
        guard appIsActive, !UIAccessibility.isVoiceOverRunning else {
            // VoiceOver reads the alert; a second voice would talk over it.
            refreshStandbyListening()
            return
        }
        speech.allowPhoneAudio = true
        do { try speech.speak(warning.spokenNotice) }
        catch {
            speech.allowPhoneAudio = usePhoneAudio
            refreshStandbyListening()
        }
    }
    private func begin(using source: CaptureSource) {
        guard !sessionActive else { return }
        if source == .glasses, !camera.isRegistered {
            showingSetup = true; fail("Open Setup and register your glasses with Meta AI first."); return
        }
        captureSource = source
        phoneCameraPausedForBackground = false
        phoneCameraTransition?.cancel(); phoneCameraTransition = nil
        cameraStatus = "Camera off"
        startupStage = .other
        if source == .glasses { RayBridgeDiagnostics.event("Start RayBridge requested with glasses") }
        else { RayBridgeDiagnostics.event("Start RayBridge requested without glasses") }
        speech.stop()
        pendingErrorAnnouncement = nil
        endAnswerStream()
        commandConfirmationPending = false; pendingAnswerMessage = nil
        speech.allowPhoneAudio = usePhoneAudio
        activity += 1; error = nil; muted = false; pendingCameraAnnouncement = false
        UIApplication.shared.isIdleTimerDisabled = true
        session.start()
    }
    func stop() {
        RayBridgeDiagnostics.event("Stop RayBridge requested")
        phoneCameraPausedForBackground = false
        phoneCameraTransition?.cancel(); phoneCameraTransition = nil
        session.stop()
    }
    private func refreshStandbyListening() {
        guard !sessionActive else { return }
        guard appIsActive, voiceCommandsEnabled, handsFreeStandbyEnabled,
              speech.hasRecognitionPermissions else {
            speech.stop()
            if error == nil { status = idleStatus }
            return
        }
        // Start and Commands must work before glasses are connected. The audio
        // session still prefers a Bluetooth headset when one is available.
        speech.allowPhoneAudio = true
        do {
            try speech.startCommandListening(for: standbyCommands)
            if error == nil { status = standbyStatus }
        } catch {
            // Standby is optional. The button remains available when glasses
            // audio is disconnected or recognition cannot start.
            speech.stop()
            if self.error == nil { status = idleStatus }
        }
    }
    private var idleStatus: String {
        glassesWarning?.message ?? "Stopped. Tap Start RayBridge to begin."
    }
    private var standbyStatus: String {
        guard glassesWarning == nil else { return "Glasses aren’t connected. Say Start to continue without glasses, Cancel to dismiss, or Commands for help." }
        return "Stopped. Say Start, say Commands for help, or tap Start RayBridge."
    }
    private func handleVoiceCommand(_ command: VoiceCommand) {
        switch command {
        case .start:
            guard !sessionActive else { return }
            if glassesWarning != nil {
                status = "Starting without glasses…"
                confirmVoiceCommand("Starting without glasses.", preservingCurrentOutput: false) { [weak self] in
                    self?.continueWithoutGlasses()
                }
                return
            }
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
            if !sessionActive, glassesWarning != nil {
                confirmVoiceCommand("Cancelled.", preservingCurrentOutput: false) { [weak self] in
                    self?.dismissGlassesWarning()
                }
                return
            }
            cancelCurrentTurn(verballyConfirm: true)
        case .mute:
            muteVoiceInput()
        case .unmute:
            unmuteVoiceInput()
        case .status:
            requestCoordinatorControl("status")
        case .repeat:
            requestCoordinatorControl("repeat")
        case .commands:
            announceVoiceCommands()
        }
    }
    private func requestCoordinatorControl(_ type: String) {
        guard running, connected else { return }
        Task {
            do { try await connection.send(["type": type]) }
            catch {
                guard running else { return }
                stop(); fail(error.localizedDescription)
            }
        }
    }
    private func announceVoiceCommands() {
        let previousStatus = status
        let preservingOutput = running && (busy || speech.isSpeaking)
        confirmVoiceCommand(
            VoiceCommandPolicy.helpAnnouncement,
            preservingCurrentOutput: preservingOutput
        ) { [weak self] in
            guard let self else { return }
            if !self.running {
                self.refreshStandbyListening()
            } else if self.muted {
                self.listenForUnmute()
            } else if self.busy || self.speech.isSpeaking {
                do { try self.speech.startCommandListening(for: self.currentResponseCommands) }
                catch { self.stop(); self.fail(error.localizedDescription); return }
                self.status = previousStatus
            } else {
                self.resumeListening()
            }
        }
    }
    private func confirmVoiceCommand(
        _ message: String,
        preservingCurrentOutput: Bool,
        completion: @escaping () -> Void
    ) {
        commandConfirmationPending = true
        speech.allowPhoneAudio = sessionActive ? usePhoneAudio : true
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
        do { try speech.startCommandListening(for: currentResponseCommands) }
        catch { stop(); fail(error.localizedDescription); return }
        if busy { status = "Muted while Codex is thinking. Say Unmute." }
        else if speech.isSpeaking { status = "Muted while the answer is speaking. Say Unmute." }
        else { status = "Muted. Say Unmute to ask another question." }
    }
    func ask(_ text: String) {
        guard running, connected, !muted, !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        RayBridgeDiagnostics.event("Question submitted to Mac")
        turnClock = ContinuousClock.now; spokenAnswerPrefix = ""; answerStreamStopped = false
        speech.stop(); busy = true; transcript = text; error = nil; status = "Asking ChatGPT…"
        speech.allowPhoneAudio = usePhoneAudio
        do { try speech.startCommandListening(for: currentResponseCommands) }
        catch { stop(); fail(error.localizedDescription); return }
        if thinkingHeartbeatEnabled {
            do {
                speech.allowPhoneAudio = usePhoneAudio
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
                guard current == activity else { return }
                markTurn("Question sent to the Mac")
            } catch {
                guard current == activity, running else { return }
                stop(); fail(error.localizedDescription)
            }
        }
    }
    private func markTurn(_ label: StaticString) {
        guard let turnClock else { return }
        let elapsed = turnClock.duration(to: .now)
        let milliseconds = Int(Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15)
        RayBridgeDiagnostics.timing(label, milliseconds: milliseconds)
    }
    private func endAnswerStream() {
        turnClock = nil
        spokenAnswerPrefix = ""
        answerStreamStopped = false
    }
    private func cancelCurrentTurn(verballyConfirm: Bool) {
        guard running, connected else { return }
        RayBridgeDiagnostics.event("Voice Cancel requested")
        activity += 1
        let needsMacCancellation = busy || cancellationPending
        let alreadyCancelling = cancellationPending
        endAnswerStream()
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
            markTurn("Mac accepted the question")
            if muted { status = "Muted while Codex is thinking. Say Unmute." }
            else { status = message["hasImage"] as? Bool == true ? "Thinking with a current camera image…" : "Thinking. No current camera image." }
        // A finished sentence of an answer the Mac is still writing.
        case "answer.partial":
            guard running, busy, !cancellationPending, !answerStreamStopped,
                  let text = message["text"] as? String, !text.isEmpty else { return }
            // A spoken command confirmation owns the audio route, so the rest of
            // this answer waits and is spoken once it is complete.
            guard !commandConfirmationPending else { answerStreamStopped = true; return }
            if spokenAnswerPrefix.isEmpty { markTurn("First answer sentence received") }
            do {
                speech.allowPhoneAudio = usePhoneAudio
                try speech.speakStreamedChunk(text, listenForCommands: currentResponseCommands)
                spokenAnswerPrefix += text
                answer = spokenAnswerPrefix
                status = muted ? "Muted while the answer is speaking. Say Unmute." : "Speaking"
            } catch { stop(); fail(error.localizedDescription) }
        // The assistant replaced the text it was writing, so what was spoken was
        // not the answer after all.
        case "answer.discard":
            guard running, busy, !cancellationPending, !spokenAnswerPrefix.isEmpty else { return }
            speech.cancelStreamedAnswer()
            spokenAnswerPrefix = ""; answer = ""
            status = muted ? "Muted while Codex is thinking. Say Unmute." : "Still thinking…"
        case "answer":
            guard running, busy, !cancellationPending, let text = message["text"] as? String else { return }
            if commandConfirmationPending {
                pendingAnswerMessage = message
                return
            }
            RayBridgeDiagnostics.event("Answer received from Mac")
            markTurn("Complete answer received")
            busy = false; answer = text; status = "Answer ready"
            do {
                speech.allowPhoneAudio = usePhoneAudio
                if let audio = message["audio"] as? [String: Any],
                   audio["format"] as? String == "m4a",
                   let encoded = audio["data"] as? String,
                   let data = Data(base64Encoded: encoded) {
                    try speech.speakAudio(data, listenForCommands: currentResponseCommands)
                    status = muted ? "Muted while the answer is speaking. Say Unmute." : "Speaking with Kokoro"
                } else {
                    switch AnswerStreamPolicy.speech(completed: text, alreadySpoken: spokenAnswerPrefix) {
                    case .whole(let whole):
                        try speech.speak(whole, listenForCommands: currentResponseCommands)
                        status = muted ? "Muted while the answer is speaking. Say Unmute."
                            : message["ttsFallback"] == nil ? "Speaking" : "Speaking with Apple voice. Kokoro is unavailable on the Mac."
                    case .remainder(let remainder):
                        try speech.speakStreamedChunk(remainder, listenForCommands: currentResponseCommands)
                        speech.finishStreamedAnswer()
                        status = muted ? "Muted while the answer is speaking. Say Unmute." : "Speaking"
                    case .nothing:
                        speech.finishStreamedAnswer()
                        status = muted ? "Muted while the answer is speaking. Say Unmute." : "Speaking"
                    }
                }
                endAnswerStream()
            } catch { stop(); fail(error.localizedDescription) }
        case "cancelled":
            guard running, cancellationPending else { return }
            cancellationPending = false; cancellationToken = nil; cancellationTimeout?.cancel()
        case "coordinator.speech":
            guard running, let text = message["text"] as? String, !text.isEmpty else { return }
            let previousStatus = status
            confirmVoiceCommand(text, preservingCurrentOutput: busy || speech.isSpeaking) { [weak self] in
                guard let self, self.running else { return }
                if self.muted {
                    self.listenForUnmute()
                } else if self.busy || self.speech.isSpeaking {
                    do { try self.speech.startCommandListening(for: self.currentResponseCommands) }
                    catch { self.stop(); self.fail(error.localizedDescription); return }
                    self.status = previousStatus
                } else {
                    self.resumeListening()
                }
            }
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
