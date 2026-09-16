import SwiftUI
import AVFoundation
import UIKit
import OSLog
import Darwin

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
    @Published private(set) var speakingStatus = false
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
    @Published var pairedHost: String? = Pairing.load()?.host
    private let connection = BridgeConnection()
    private let camera = GlassesCamera()
    private let speech = SpeechController()
    private var frame: (data: Data, date: Date)?
    private var connectionFailure: Error?
    private var activity = 0
    private var watchdog: Task<Void, Never>?
    private var announceStopped = false
    private var recoveringSession = false
    private var pendingError: String?

    private lazy var session = SessionController(
        connect: { [unowned self] in try await connectForSession() },
        authorize: { [unowned self] in try await speech.permissions() },
        startCamera: { [unowned self] in
            if let connectionFailure { throw connectionFailure }
            cameraRequested = true
            try await camera.start()
        },
        startAudio: { [unowned self] in
            if let connectionFailure { throw connectionFailure }
            guard CameraFreshness.isFresh(frame?.date) else {
                throw RecoverableSessionError(message: "The camera is not sending current images.")
            }
            speech.allowPhoneAudio = phoneAudio
            // Validate capture without starting/stopping the microphone around
            // the ready message. Listening begins when that message finishes.
            try speech.prepareListening()
        },
        stopImmediately: { [unowned self] in
            activity += 1; busy = false; cameraRequested = false
            watchdog?.cancel(); watchdog = nil
            speakingStatus = false
            cameraActive = false; frame = nil
            speech.stopSpeech()
            // Closing the phone connection also cancels its pending Mac answer.
            connection.disconnect(); connected = false
            UIApplication.shared.isIdleTimerDisabled = false
        },
        stopCamera: { [unowned self] in
            await camera.stop()
            // Do not change the audio route during camera teardown either.
            speech.stop()
        }
    )

    init() {
        RayBridgeDiagnostics.event("App model initialization started")
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onError = { [weak self] error in
            guard let self else { return }
            self.connected = false
            self.connectionFailure = error
            if self.running { self.handleSessionFailure(error) }
            // During startup, the next startup step propagates connectionFailure.
        }
        camera.onFrame = { [weak self] data in
            guard let self, self.cameraRequested else { return }
            self.frame = (data, Date()); self.cameraActive = true; self.cameraStatus = "Glasses camera connected"
        }
        camera.onFailure = { [weak self] error in
            guard let self, self.running else { return }
            self.handleSessionFailure(error)
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
        session.onError = { [weak self] error in
            self?.fail(error.localizedDescription + " Tap Start RayBridge when ready to try again.")
        }
        session.onRecovery = { [weak self] reason, attempt, maximum in
            guard let self else { return }
            self.recoveringSession = true
            self.status = "Reconnecting, attempt \(attempt) of \(maximum)…"
            if attempt == 1 {
                self.speakingStatus = true
                defer { self.speakingStatus = false; self.speech.stop() }
                try await self.speech.speakStatusAndWait("Connection lost. Reconnecting.")
            }
            RayBridgeDiagnostics.event("Automatic connection recovery attempt")
        }
        speech.onQuestion = { [weak self] text in self?.ask(text) }
        speech.onTranscript = { [weak self] in self?.transcript = $0 }
        speech.onError = { [weak self] message in
            guard let self, self.running else { return }
            self.session.stop(); self.fail(message)
        }
        speech.onFinishedSpeaking = { [weak self] in
            guard let self else { return }
            self.speakingStatus = false
            if self.running { self.resumeListening() }
            else if !self.sessionActive { self.speech.stop() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, self.running, !self.phoneAudio,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.session.recover("Glasses audio disconnected.")
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.running else { return }
                self.session.stop(); self.fail("Audio interrupted. Tap Start RayBridge when ready.")
            }
        }
        RayBridgeDiagnostics.event("App model initialization finished")
    }
    func fail(_ message: String) {
        RayBridgeDiagnostics.event("An error was presented in the app")
        error = message; status = message
        if sessionActive {
            // A failure must not start a second voice while the camera is
            // shutting down. The idle transition delivers it after cleanup.
            pendingError = message
            session.stop()
        } else {
            announceStatus(message)
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
        connection.connect(pairing)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !connected {
            try Task.checkCancellation()
            if let connectionFailure { throw connectionFailure }
            guard ContinuousClock.now < deadline else {
                throw RecoverableSessionError(message: "The Mac did not answer. Check that RayBridge is open on your Mac and both devices are on the same Wi-Fi.")
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
    private func announceStatus(_ message: String) {
        speakingStatus = true
        do {
            speech.allowPhoneAudio = phoneAudio
            try speech.speakStatus(message)
        } catch {
            speakingStatus = false
            RayBridgeDiagnostics.event("Status speech unavailable; status remains on screen")
            // Never reopen the microphone here: speech may still be finishing.
            self.error = "Audio feedback is unavailable. " + message
            if running { session.stop(); status = self.error ?? message }
        }
    }
    private func handleSessionFailure(_ error: Error) {
        if error is RecoverableSessionError { session.recover(error.localizedDescription) }
        else { session.stop(); fail(error.localizedDescription) }
    }
    private func watchCamera() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.running else { return }
                if !CameraFreshness.isFresh(self.frame?.date) {
                    RayBridgeDiagnostics.event("Camera freshness watchdog requested recovery")
                    self.session.recover("The camera stopped sending current images.")
                    return
                }
            }
        }
    }
    private func sessionChanged(_ phase: SessionController.Phase) {
        sessionPhase = phase
        switch phase {
        case .idle:
            if error == nil { status = "Stopped. Tap Start RayBridge to begin." }
            if let message = pendingError {
                pendingError = nil; announceStopped = false
                announceStatus(message)
            } else if announceStopped { announceStopped = false; announceStatus("RayBridge stopped.") }
        case .connecting:
            UIApplication.shared.isIdleTimerDisabled = true
            status = "Connecting to your Mac…"
        case .authorizing: status = "Checking microphone and speech permissions…"
        case .startingCamera: status = "Connecting glasses camera…"
        case .startingAudio: status = "Preparing microphone…"
        case .running:
            status = "Ready. Ask your question."
            error = nil
            RayBridgeDiagnostics.event("RayBridge session ready with camera and microphone")
            watchCamera()
            announceStatus(recoveringSession ? "Reconnected. Please ask your question again." : "Ready. Ask your question.")
        case .recovering: status = "Connection lost. Reconnecting…"
        case .stopping: status = "Stopping RayBridge…"
        }
    }
    func background() {
        // The permission handoff is part of startup, not a request to stop it.
        if camera.awaitingPermission { return }
        if sessionActive {
            announceStopped = false
            session.stop()
        }
        if !sessionActive { speech.stop() }
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
        activity += 1; error = nil; pendingError = nil; announceStopped = false; recoveringSession = false
        speech.stop(); speakingStatus = false
        // The glasses provide their own startup prompts. Give tactile feedback
        // now, then speak once the camera and audio are ready.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIApplication.shared.isIdleTimerDisabled = true
        session.start()
    }
    func stop() {
        RayBridgeDiagnostics.event("Stop RayBridge requested")
        pendingError = nil
        announceStopped = sessionActive
        session.stop()
        if !sessionActive { speech.stop() }
    }
    func ask(_ text: String) {
        guard running, connected, !busy, !speakingStatus, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard CameraFreshness.isFresh(frame?.date) else {
            session.recover("No current camera image. Your question was not sent.")
            return
        }
        RayBridgeDiagnostics.event("Question submitted to Mac")
        speech.stopSpeech(); busy = true; transcript = text; error = nil; status = "Asking ChatGPT…"
        let current = activity
        Task {
            do {
                guard current == activity, running else { return }
                guard let captured = frame, CameraFreshness.isFresh(captured.date) else {
                    session.recover("No current camera image. Your question was not sent."); return
                }
                try await connection.send(["type": "frame", "jpeg": captured.data.base64EncodedString()])
                guard current == activity, running else { return }
                guard CameraFreshness.isFresh(captured.date), frame != nil else {
                    session.recover("No current camera image. Your question was not sent."); return
                }
                try await connection.send(["type": "ask", "text": text, "requiresImage": true])
            } catch {
                guard current == activity, running else { return }
                session.recover("Connection to your Mac was lost. Please ask your question again after reconnecting.")
            }
        }
    }
    func reset() {
        stop(); answer = ""; transcript = ""; frame = nil
    }
    private func resumeListening() {
        guard running, connected, !busy, !speech.isSpeaking else { return }
        guard CameraFreshness.isFresh(frame?.date) else {
            session.recover("The camera stopped sending current images."); return
        }
        do { try speech.startListening(); status = "Listening" }
        catch { handleSessionFailure(error) }
    }
    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            RayBridgeDiagnostics.event("Mac connection ready")
            guard sessionPhase == .connecting else { return }
            connected = true
        case "thinking":
            guard running, busy else { return }
            guard message["hasImage"] as? Bool == true else {
                session.recover("The Mac did not receive a current camera image."); return
            }
            status = "Thinking with a current camera image…"
        case "answer":
            guard running, busy, let text = message["text"] as? String else { return }
            RayBridgeDiagnostics.event("Answer received from Mac")
            busy = false; answer = text; status = "Answer ready"
            do {
                speech.allowPhoneAudio = phoneAudio
                try speech.speak(text); status = "Speaking"
            } catch { handleSessionFailure(error) }
        case "error":
            let text = message["message"] as? String ?? "The Mac reported an error."
            if sessionPhase == .connecting { connectionFailure = BridgeError.message(text); return }
            guard sessionActive, sessionPhase != .stopping else { return }
            if message["code"] as? String == "camera_unavailable", running {
                session.recover("The Mac did not receive a current camera image.")
            } else { session.stop(); fail(text) }
        default: break
        }
    }
}
