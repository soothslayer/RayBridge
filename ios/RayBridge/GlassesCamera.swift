import Foundation
import UIKit
import MWDATCore
import MWDATCamera

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
final class GlassesCamera {
    var onFrame: ((Data) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    private var device: DeviceSession?
    private var stream: StreamSession?
    private var tokens: [any AnyListenerToken] = []
    private var configured = false

    func configure() throws {
        if !configured { try Wearables.configure(); configured = true }
    }
    func register() async throws {
        try configure()
        try await Wearables.shared.startRegistration()
    }
    func handle(_ url: URL) async throws {
        try configure()
        _ = try await Wearables.shared.handleUrl(url)
        onStatus?("Meta AI registration: \(Wearables.shared.registrationState)", false)
    }
    func start() async throws {
        try configure()
        guard device == nil else { return }
        let wearables = Wearables.shared
        let permission = try await wearables.requestPermission(.camera)
        try Task.checkCancellation()
        guard permission == .granted else { throw BridgeError.message("Allow glasses camera access in the Meta AI app.") }
        let device = try wearables.createSession(deviceSelector: AutoDeviceSelector(wearables: wearables))
        self.device = device
        do {
            try device.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await state in device.stateStream() {
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
            guard let stream = try device.addStream(config: StreamSessionConfig(videoCodec: .raw, resolution: .medium, frameRate: 7)) else {
                throw BridgeError.message("Could not open the glasses camera.")
            }
            self.stream = stream
            let sampler = FrameSampler()
            tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
                guard let data = sampler.jpeg(frame) else { return }
                Task { @MainActor in self?.onFrame?(data) }
            })
            tokens.append(stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.onStatus?("Camera: \(state)", state == .streaming) }
            })
            tokens.append(stream.errorPublisher.listen { [weak self] _ in
                Task { @MainActor in self?.onStatus?("Glasses camera unavailable. Reconnect glasses.", false) }
            })
            await stream.start()
            try Task.checkCancellation()
        } catch { await stop(); throw error }
    }
    func stop() async {
        let oldStream = stream; stream = nil
        let oldDevice = device; device = nil
        let oldTokens = tokens; tokens = []
        for token in oldTokens { await token.cancel() }
        await oldStream?.stop()
        oldDevice?.stop()
        onStatus?("Camera off", false)
    }
}
