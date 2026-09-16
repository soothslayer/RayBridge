import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Pair your Mac to begin"
    @Published var cameraStatus = "Camera off"
    @Published var connected = false
    @Published var running = false
    @Published var busy = false
    @Published var cameraActive = false
    @Published var cameraStarting = false
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

    init() {
        connection.onMessage = { [weak self] in self?.receive($0) }
        connection.onError = { [weak self] message in
            self?.connected = false; self?.stop(); self?.fail(message)
        }
        camera.onFrame = { [weak self] data in
            guard let self, self.cameraStarting || self.cameraActive else { return }
            self.frame = (data, Date()); self.cameraActive = true; self.cameraStatus = "Glasses camera connected"
        }
        camera.onStatus = { [weak self] text, active in
            guard let self else { return }
            self.cameraStatus = text; self.cameraActive = active
            if !active {
                self.frame = nil
                if self.connected { Task { try? await self.connection.send(["type": "camera.off"]) } }
            }
        }
        speech.onQuestion = { [weak self] text in self?.ask(text) }
        speech.onTranscript = { [weak self] in self?.transcript = $0 }
        speech.onError = { [weak self] message in self?.stop(); self?.fail(message) }
        speech.onFinishedSpeaking = { [weak self] in self?.resumeListening() }
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
    }
    func fail(_ message: String) {
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
        guard let pairing = Pairing.load() else { fail("Paste a pairing link from the Mac first."); return }
        stop(); connected = false; error = nil; status = "Connecting to Mac…"
        connection.connect(pairing)
    }
    func handle(_ url: URL) {
        if url.host == "pair" { pairingText = url.absoluteString; status = "Pairing link received. Tap Pair Mac." }
        else { Task { do { try await camera.handle(url) } catch { fail(error.localizedDescription) } } }
    }
    func registerGlasses() {
        Task { do { try await camera.register() } catch { fail(error.localizedDescription) } }
    }
    func toggleCamera() {
        guard !cameraStopping else { return }
        if cameraActive || cameraStarting {
            let task = cameraTask
            task?.cancel(); cameraStopping = true; cameraActive = false; frame = nil
            Task {
                await task?.value
                await camera.stop()
                cameraStarting = false; cameraStopping = false
            }
        } else {
            cameraStarting = true; cameraStatus = "Connecting glasses camera…"
            cameraTask = Task {
                do { try await camera.start() }
                catch { if !Task.isCancelled { fail(error.localizedDescription) } }
                cameraStarting = false
            }
        }
    }
    func start() {
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
        activity += 1; running = false; busy = false; speech.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if connected { Task { try? await connection.send(["type": "cancel"]) } }
        status = connected ? "Ready" : "Disconnected"
    }
    func suspend() {
        stop()
        if cameraActive || cameraStarting { toggleCamera() }
        connection.disconnect(); connected = false; status = "Paused. Reconnect when ready."
    }
    func ask(_ text: String) {
        guard connected, !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        case "ready": connected = true; status = "Mac connected. Ready."; error = nil
        case "thinking": status = message["hasImage"] as? Bool == true ? "Thinking with a current camera image…" : "Thinking. No current camera image."
        case "answer":
            guard busy, let text = message["text"] as? String else { return }
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
