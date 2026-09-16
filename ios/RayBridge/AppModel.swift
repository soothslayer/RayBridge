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
    @Published var status = "Pair your Mac to begin"
    @Published var cameraStatus = "Camera off"
    @Published var connected = false
    @Published var running = false
    @Published var busy = false
    @Published var cameraActive = false
    @Published var cameraStarting = false
    @Published var cameraRequested = false
    @Published var registrationStatus = ""
    @Published var cameraStopping = false
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
    private var cameraTask: Task<Void, Never>?
    private var activity = 0
    private var cameraAnnounced = false
    private var pendingCameraAnnouncement = false

    init() {
        RayBridgeDiagnostics.event("App model initialization started")
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onError = { [weak self] message in
            self?.connected = false; self?.stop(); self?.fail(message)
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
            if !active {
                self.frame = nil
                if self.connected { Task { try? await self.connection.send(["type": "camera.off"]) } }
            }
        }
        // Give Bluetooth discovery time to initialize before registration or a
        // camera request, and restore the registration label after relaunch.
        do { try camera.configure() }
        catch { cameraStatus = "Glasses discovery could not initialize. Reopen RayBridge." }
        speech.onQuestion = { [weak self] text in self?.ask(text) }
        speech.onTranscript = { [weak self] in self?.transcript = $0 }
        speech.onError = { [weak self] message in self?.stop(); self?.fail(message) }
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
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop(); self?.status = "Audio interrupted. Start again when ready." }
        }
        RayBridgeDiagnostics.event("App model initialization finished")
    }
    func fail(_ message: String) {
        RayBridgeDiagnostics.event("An error was presented in the app")
        error = message; status = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
    func pair() {
        do {
            let pairing = try Pairing(link: pairingText)
            try pairing.save(); pairedHost = pairing.host; pairingText = ""; connect()
        } catch { fail(error.localizedDescription) }
    }
    func connect() {
        RayBridgeDiagnostics.event("Mac connection requested")
        guard let pairing = Pairing.load() else { fail("Paste a pairing link from the Mac first."); return }
        stop(); connected = false; error = nil; status = "Connecting to Mac…"
        connection.connect(pairing)
    }
    func handle(_ url: URL) {
        if url.host == "pair" { pairingText = url.absoluteString; status = "Pairing link received. Tap Pair Mac." }
        else { Task { do { try await camera.handle(url) } catch { fail(error.localizedDescription) } } }
    }
    func registerGlasses() {
        RayBridgeDiagnostics.event("Meta AI registration requested")
        Task { do { try await camera.register() } catch { fail(error.localizedDescription) } }
    }
    func toggleCamera() {
        RayBridgeDiagnostics.event("Glasses camera toggle requested")
        guard !cameraStopping else { return }
        if cameraRequested {
            cameraRequested = false; pendingCameraAnnouncement = false
            let task = cameraTask
            task?.cancel(); cameraStopping = true; cameraActive = false; frame = nil
            Task {
                await task?.value
                await camera.stop()
                cameraStarting = false; cameraStopping = false
            }
        } else {
            cameraRequested = true; cameraAnnounced = false; error = nil
            cameraStarting = true; cameraStatus = "Connecting glasses camera…"
            cameraTask = Task {
                do { try await camera.start() }
                catch {
                    cameraRequested = false
                    if !Task.isCancelled {
                        cameraStatus = error.localizedDescription
                        fail(error.localizedDescription)
                    }
                }
                cameraStarting = false
            }
        }
    }
    private func announceCameraIfReady() {
        guard pendingCameraAnnouncement, cameraActive, !busy, !speech.isSpeaking else { return }
        pendingCameraAnnouncement = false
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: "Glasses camera connected")
        } else {
            do {
                speech.allowPhoneAudio = phoneAudio
                try speech.speak("Glasses camera connected")
            } catch {
                RayBridgeDiagnostics.event("Camera connected, but audio confirmation could not play")
                self.error = "Camera connected, but audio confirmation could not play. Check glasses Bluetooth audio."
                resumeListening()
            }
        }
    }
    func background() {
        // Opening Meta AI for permission must not cancel that same request.
        if camera.awaitingPermission { stop() }
        else if running || cameraRequested { suspend() }
    }
    func start() {
        RayBridgeDiagnostics.event("Listening requested")
        guard connected else { fail("Connect to your Mac first."); return }
        activity += 1
        let current = activity
        running = true; error = nil; status = "Preparing microphone…"
        Task {
            do {
                try await speech.permissions()
                guard running, current == activity else { return }
                speech.allowPhoneAudio = phoneAudio
                try speech.startListening(); status = "Listening"
                UIApplication.shared.isIdleTimerDisabled = true
            } catch { stop(); fail(error.localizedDescription) }
        }
    }
    func stop() {
        RayBridgeDiagnostics.event("Conversation stopped")
        activity += 1; running = false; busy = false; speech.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if connected { Task { try? await connection.send(["type": "cancel"]) } }
        status = connected ? "Ready" : "Disconnected"
    }
    func suspend() {
        stop()
        if cameraRequested { toggleCamera() }
        connection.disconnect(); connected = false; status = "Paused. Reconnect when ready."
    }
    func ask(_ text: String) {
        guard connected, !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        RayBridgeDiagnostics.event("Question submitted to Mac")
        speech.stop(); busy = true; transcript = text; error = nil; status = "Asking ChatGPT…"
        let current = activity
        Task {
            do {
                if let frame, Date().timeIntervalSince(frame.date) < 2.5 {
                    try await connection.send(["type": "frame", "jpeg": frame.data.base64EncodedString()])
                } else { try await connection.send(["type": "camera.off"]) }
                guard current == activity else { return }
                try await connection.send(["type": "ask", "text": text])
            } catch { busy = false; stop(); fail(error.localizedDescription) }
        }
    }
    func reset() {
        stop(); answer = ""; transcript = ""; frame = nil
        Task { try? await connection.send(["type": "reset"]) }
    }
    private func resumeListening() {
        guard running, connected else { return }
        do { try speech.startListening(); status = "Listening" }
        catch { stop(); fail(error.localizedDescription) }
    }
    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            RayBridgeDiagnostics.event("Mac connection ready")
            connected = true; status = "Mac connected. Ready."; error = nil
        case "thinking": status = message["hasImage"] as? Bool == true ? "Thinking with a current camera image…" : "Thinking. No current camera image."
        case "answer":
            guard busy, let text = message["text"] as? String else { return }
            RayBridgeDiagnostics.event("Answer received from Mac")
            busy = false; answer = text; status = "Answer ready"
            do {
                speech.allowPhoneAudio = phoneAudio
                try speech.speak(text); status = "Speaking"
            } catch { stop(); fail(error.localizedDescription) }
        case "error": busy = false; stop(); fail(message["message"] as? String ?? "The Mac reported an error.")
        default: break
        }
    }
}
