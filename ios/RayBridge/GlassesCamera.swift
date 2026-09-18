import Foundation
import UIKit
import MWDATCore
import MWDATCamera
import CoreBluetooth
import ExternalAccessory

// The SDK may publish on a background queue. Drop surplus frames before encoding.
final class FrameSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func jpeg(_ frame: VideoFrame) -> Data? {
        lock.lock()
        guard Date().timeIntervalSince(last) >= 1 else { lock.unlock(); return nil }
        last = Date(); lock.unlock()
        guard let image = frame.makeUIImage(), let data = image.jpegData(compressionQuality: 0.55), data.count <= 500_000 else { return nil }
        return data
    }
}

@MainActor
final class GlassesCamera: CameraSource {
    var onFrame: ((Data) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onRegistration: ((String) -> Void)?
    private(set) var awaitingPermission = false
    private var generation = 0
    private var receivedFrame = false
    private var streamFailure: Error?
    private var device: DeviceSession?
    private var stream: StreamSession?
    private var tokens: [any AnyListenerToken] = []
    private var configured = false
    private var selector: AutoDeviceSelector?
    var isRegistered: Bool { configured && Wearables.shared.registrationState == .registered }

    // A fast, synchronous view of the glasses so Start can warn before spending
    // up to fifteen seconds on device selection. Device state can still lag the
    // hardware, so an unready answer only offers a choice; it never blocks.
    var readiness: GlassesReadiness {
        guard configured else { return .discoveryUnavailable }
        guard Wearables.shared.registrationState == .registered else { return .notRegistered }
        let devices = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
        // Compatibility is undefined until the SDK finishes inspecting a device;
        // treat that as usable and let camera startup report the real problem.
        struct Glasses { let connected: Bool; let connecting: Bool; let usable: Bool }
        let states = devices.map {
            Glasses(connected: $0.linkState == .connected,
                    connecting: $0.linkState == .connecting,
                    usable: $0.compatibility() != .deviceUpdateRequired
                        && $0.compatibility() != .sdkUpdateRequired)
        }
        guard !states.isEmpty else { return .noGlassesFound }
        if states.contains(where: { $0.connected && $0.usable }) { return .ready }
        if states.contains(where: { $0.connecting && $0.usable }) { return .connecting }
        if states.allSatisfy({ !$0.usable }) { return .needsUpdate }
        return .notConnected
    }

    func configure() throws {
        if !configured {
            try Wearables.configure()
            selector = AutoDeviceSelector(wearables: Wearables.shared)
            configured = true
        }
        if Wearables.shared.registrationState == .registered {
            onRegistration?("Registered with Meta AI")
        }
    }
    func register() async throws {
        try configure()
        // SDK registration state can finish restoring after the Setup view opens.
        // configure() refreshes the label; an existing registration needs no work.
        guard !isRegistered else { return }
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            switch error {
            case .alreadyRegistered:
                // Also handle a restoration race between the check and request.
                onRegistration?("Registered with Meta AI")
                return
            case .configurationInvalid:
                throw BridgeError.message("RayBridge's Meta registration settings are invalid. Check the app configuration.")
            case .metaAINotInstalled:
                throw BridgeError.message("Install Meta AI on this iPhone to register your glasses.")
            case .networkUnavailable:
                throw BridgeError.message("Meta registration needs a network connection. Check your connection and try again.")
            case .unknown:
                throw BridgeError.message("Meta AI could not complete registration. Try again in Setup.")
            @unknown default:
                throw BridgeError.message("Meta AI could not complete registration. Try again in Setup.")
            }
        }
        if isRegistered { onRegistration?("Registered with Meta AI") }
    }
    func handle(_ url: URL) async throws {
        try configure()
        _ = try await Wearables.shared.handleUrl(url)
        if Wearables.shared.registrationState == .registered {
            onRegistration?("Registered with Meta AI")
        }
    }
    func start() async throws {
        try configure()
        guard device == nil else { return }
        let wearables = Wearables.shared
        generation += 1
        let current = generation
        receivedFrame = false; streamFailure = nil
        RayBridgeDiagnostics.event("Checking glasses camera permission")
        var permission: PermissionStatus
        do {
            permission = try await wearables.checkPermissionStatus(.camera)
            if permission != .granted {
                RayBridgeDiagnostics.event("Requesting glasses camera permission in Meta AI")
                awaitingPermission = true
                defer { awaitingPermission = false }
                permission = try await wearables.requestPermission(.camera)
            }
        } catch {
            let message = Self.permissionMessage(error)
            RayBridgeDiagnostics.event(message)
            throw BridgeError.message(String(describing: message))
        }
        try Task.checkCancellation()
        guard permission == .granted else { throw BridgeError.message("Allow glasses camera access in the Meta AI app.") }
        RayBridgeDiagnostics.event("Glasses camera permission granted; waiting for device selection")
        onStatus?("Finding connected glasses…", false)
        // Registration/permission can change the available devices while this app
        // is in the background. Start a fresh observer of the current device list.
        selector = AutoDeviceSelector(wearables: wearables)
        guard let selector else { throw BridgeError.message("Glasses discovery could not start. Reopen RayBridge.") }
        // Selection updates asynchronously. A freshly created selector can have no
        // active device even after permission was successfully granted.
        let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        var sessionSelector: any DeviceSelector = selector
        logConnectionSnapshot()
        while selector.activeDevice == nil {
            try Task.checkCancellation()
            let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
            // If the automatic observer lags behind a known connected device,
            // target that device explicitly. Never force a disconnected device.
            let connected = devices.filter { $0.linkState == .connected && $0.compatibility() == .compatible }
            if connected.count == 1, let ready = connected.first {
                RayBridgeDiagnostics.event("Connected compatible glasses found; using specific device selector")
                sessionSelector = SpecificDeviceSelector(device: ready.identifier)
                break
            }
            guard ContinuousClock.now < selectionDeadline else {
                logConnectionSnapshot()
                let message: StaticString
                if CBManager.authorization == .denied || CBManager.authorization == .restricted {
                    message = "RayBridge cannot access Bluetooth. Allow Bluetooth for RayBridge in iPhone Settings, then reconnect the camera."
                } else if devices.isEmpty {
                    message = "RayBridge cannot discover your glasses. Check that they are connected in Meta AI and Developer Mode is enabled."
                } else if devices.contains(where: { $0.compatibility() == .deviceUpdateRequired }) {
                    message = "Your glasses need a software update before RayBridge can use the camera. Update them in Meta AI."
                } else if devices.contains(where: { $0.compatibility() == .sdkUpdateRequired }) {
                    message = "RayBridge needs a newer Meta SDK to connect to these glasses."
                } else if devices.allSatisfy({ $0.linkState == .disconnected }) {
                    message = "Glasses are registered, but their camera connection to RayBridge is disconnected. Open Meta AI and check the glasses connection and Developer Mode, then return here and reconnect the camera."
                } else if devices.contains(where: { $0.linkState == .connecting }) {
                    message = "The glasses camera connection is still connecting. Keep the glasses on and nearby, then try connecting the camera again."
                } else {
                    message = "Meta reports connected glasses, but automatic camera selection failed. Reopen RayBridge and reconnect the camera."
                }
                RayBridgeDiagnostics.event(message)
                throw BridgeError.message(String(describing: message))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        RayBridgeDiagnostics.event("Glasses selected; creating device session")
        let device: DeviceSession
        do { device = try wearables.createSession(deviceSelector: sessionSelector) }
        catch {
            RayBridgeDiagnostics.event("Meta SDK rejected device session creation")
            throw BridgeError.message("The glasses are not available for a camera session. Check their connection in Meta AI, then reconnect the camera.")
        }
        self.device = device
        do {
            RayBridgeDiagnostics.event("Starting glasses device session")
            let states = device.stateStream()
            try device.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    if device.state == .started { return }
                    for await state in states {
                        try Task.checkCancellation()
                        if state == .started { return }
                    }
                    throw BridgeError.message("Glasses disconnected before the camera started.")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw BridgeError.message("Glasses did not connect. Check Meta AI and try again.")
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            try Task.checkCancellation()
            RayBridgeDiagnostics.event("Glasses device session started; opening camera stream")
            guard let stream = try device.addStream(config: StreamSessionConfig(videoCodec: .raw, resolution: .medium, frameRate: 7)) else {
                throw BridgeError.message("Could not open the glasses camera.")
            }
            self.stream = stream
            let sampler = FrameSampler()
            tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
                guard let data = sampler.jpeg(frame) else { return }
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    if !self.receivedFrame { RayBridgeDiagnostics.event("First glasses camera image received") }
                    self.receivedFrame = true
                    self.onFrame?(data)
                }
            })
            tokens.append(stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    switch state {
                    case .streaming:
                        RayBridgeDiagnostics.event("Camera stream running; waiting for usable image")
                        if !self.receivedFrame { self.onStatus?("Waiting for the first camera image…", false) }
                    case .paused: self.onStatus?("Camera paused. Check that your glasses are on and being worn.", false)
                    case .waitingForDevice: self.onStatus?("Waiting for glasses…", false)
                    case .starting: self.onStatus?("Starting glasses camera…", false)
                    case .stopping, .stopped: self.onStatus?("Camera stopped. Disconnect and reconnect the camera.", false)
                    }
                }
            })
            tokens.append(stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    let message = Self.streamMessage(error)
                    RayBridgeDiagnostics.event(message)
                    self.streamFailure = BridgeError.message(String(describing: message))
                    self.onStatus?(String(describing: message), false)
                }
            })
            await stream.start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !receivedFrame {
                try Task.checkCancellation()
                if let streamFailure { throw streamFailure }
                guard ContinuousClock.now < deadline else {
                    throw BridgeError.message("No image received from the glasses. Check that they are on and being worn, then reconnect the camera.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch { await stop(); throw error }
    }
    private func logConnectionSnapshot() {
        // Log only fixed state labels, never accessory names or identifiers.
        switch CBManager.authorization {
        case .allowedAlways: RayBridgeDiagnostics.event("Camera diagnostic: Bluetooth permission allowed")
        case .denied: RayBridgeDiagnostics.event("Camera diagnostic: Bluetooth permission denied")
        case .restricted: RayBridgeDiagnostics.event("Camera diagnostic: Bluetooth permission restricted")
        case .notDetermined: RayBridgeDiagnostics.event("Camera diagnostic: Bluetooth permission not determined")
        @unknown default: RayBridgeDiagnostics.event("Camera diagnostic: Bluetooth permission unknown")
        }
        let hasAccessory = EAAccessoryManager.shared().connectedAccessories.contains {
            $0.protocolStrings.contains("com.meta.ar.wearable")
        }
        if hasAccessory { RayBridgeDiagnostics.event("Camera diagnostic: Meta external accessory connected") }
        else { RayBridgeDiagnostics.event("Camera diagnostic: no Meta external accessory connected") }
        let devices = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
        if devices.isEmpty { RayBridgeDiagnostics.event("Camera diagnostic: SDK device list empty") }
        for device in devices {
            switch device.linkState {
            case .connected: RayBridgeDiagnostics.event("Camera diagnostic: SDK glasses link connected")
            case .connecting: RayBridgeDiagnostics.event("Camera diagnostic: SDK glasses link connecting")
            case .disconnected: RayBridgeDiagnostics.event("Camera diagnostic: SDK glasses link disconnected")
            }
            switch device.compatibility() {
            case .undefined: RayBridgeDiagnostics.event("Camera diagnostic: glasses compatibility not yet determined")
            case .compatible: RayBridgeDiagnostics.event("Camera diagnostic: SDK glasses compatible")
            case .deviceUpdateRequired: RayBridgeDiagnostics.event("Camera diagnostic: glasses firmware update required")
            case .sdkUpdateRequired: RayBridgeDiagnostics.event("Camera diagnostic: Meta SDK update required")
            @unknown default: RayBridgeDiagnostics.event("Camera diagnostic: glasses compatibility unknown")
            }
        }
    }
    private static func permissionMessage(_ error: Error) -> StaticString {
        guard let error = error as? PermissionError else { return "Could not check glasses camera permission." }
        switch error {
        case .noDevice: return "Meta AI cannot find your glasses. Connect them in Meta AI, then try again."
        case .noDeviceWithConnection: return "Your glasses are registered but not connected. Turn them on and connect them in Meta AI."
        case .connectionError: return "The glasses connection failed while checking camera permission. Reconnect them in Meta AI."
        case .metaAINotInstalled: return "Install Meta AI on this iPhone to connect your glasses."
        case .requestInProgress: return "A camera permission request is already open. Finish it in Meta AI, then try again."
        case .requestTimeout: return "Camera permission timed out. Open Meta AI, finish granting access, then try again."
        case .internalError: return "Meta AI could not complete the camera permission request. Reopen Meta AI and try again."
        @unknown default: return "Meta AI reported an unknown camera permission error."
        }
    }
    private static func streamMessage(_ error: StreamSessionError) -> StaticString {
        switch error {
        case .hingesClosed: return "Open the arms of your glasses to start the camera."
        case .thermalCritical: return "The glasses are too warm to use the camera. Let them cool down."
        case .permissionDenied: return "Glasses camera access was denied. Allow it in Meta AI."
        case .deviceNotFound: return "The camera cannot find your glasses. Reconnect them in Meta AI."
        case .deviceNotConnected: return "The glasses disconnected. Reconnect them in Meta AI."
        case .timeout: return "The glasses camera connection timed out. Reconnect the camera."
        case .videoStreamingError: return "The glasses could not stream video. Reconnect the camera."
        case .internalError: return "The glasses camera reported an internal error. Reconnect the camera."
        @unknown default: return "The glasses camera reported an unknown error."
        }
    }
    func stop() async {
        generation += 1
        let oldStream = stream; stream = nil
        let oldDevice = device; device = nil
        let oldTokens = tokens; tokens = []
        for token in oldTokens { await token.cancel() }
        await oldStream?.stop()
        oldDevice?.stop()
        onStatus?("Camera off", false)
    }
}
