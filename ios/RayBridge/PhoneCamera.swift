import Foundation
import AVFoundation
import CoreImage
import UIKit

// The camera and audio sources share one interface so a session can run on the
// glasses or on the iPhone alone without any other lifecycle differences.
@MainActor
protocol CameraSource: AnyObject {
    var onFrame: ((Data) -> Void)? { get set }
    var onStatus: ((String, Bool) -> Void)? { get set }
    func start() async throws
    func stop() async
}

// Owns the capture session on a private queue. AVCaptureSession configuration
// and start/stop block, so none of it belongs on the main actor.
private final class PhoneCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.raybridge.phone-camera")
    private let context = CIContext()
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var lastSample = Date.distantPast
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    // Read on the capture queue and written from the main actor, so the same
    // lock that rate-limits frames also guards the handler.
    private var frameHandler: (@Sendable (Data) -> Void)?

    func setFrameHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.lock(); frameHandler = handler; lock.unlock()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configureIfNeeded()
                    if !session.isRunning { session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        // SpeechController owns the audio session; capture must not reconfigure it.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            throw BridgeError.message("This iPhone has no usable camera for RayBridge.")
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw BridgeError.message("The iPhone camera could not start. Close other camera apps and try again.")
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw BridgeError.message("The iPhone camera could not start. Close other camera apps and try again.")
        }
        session.addOutput(output)
        // Keep question images upright when the user rotates the phone. The
        // coordinator follows gravity and reports changes on the main queue;
        // apply them on the capture queue with the rest of the session work.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        let initialAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(initialAngle) {
            connection.videoRotationAngle = initialAngle
        }
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] coordinator, _ in
            guard let self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self.queue.async { [weak self] in
                guard let self, let connection = self.output.connection(with: .video),
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
        // One frame per second is retained, so capturing faster only costs battery.
        if (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 7)
            device.unlockForConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        guard Date().timeIntervalSince(lastSample) >= 1, let handler = frameHandler else { lock.unlock(); return }
        lastSample = Date(); lock.unlock()
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), let data = jpeg(pixels) else { return }
        handler(data)
    }

    // Match the glasses path: one JPEG per second, at most 500 KB.
    private func jpeg(_ pixels: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let rendered = context.createCGImage(image, from: image.extent) else { return nil }
        let photo = UIImage(cgImage: rendered)
        for quality in [0.55, 0.4, 0.25] as [CGFloat] {
            if let data = photo.jpegData(compressionQuality: quality), data.count <= 500_000 { return data }
        }
        guard let smaller = Self.scaled(photo, maxDimension: 720),
              let data = smaller.jpegData(compressionQuality: 0.5), data.count <= 500_000 else { return nil }
        return data
    }

    private static func scaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// Uses this iPhone's own camera when RayBridge runs without glasses. Startup
// mirrors GlassesCamera: permission, then a usable image before the session is
// allowed to report readiness.
@MainActor
final class PhoneCamera: CameraSource {
    var onFrame: ((Data) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    private let engine = PhoneCaptureEngine()
    private var generation = 0
    private var receivedFrame = false
    private var capturing = false
    private var observers: [NSObjectProtocol] = []

    init() {
        // Capture interruptions arrive as notifications. Report them only while
        // this source is the one running.
        observe(AVCaptureSession.wasInterruptedNotification,
                "iPhone camera paused. Another app may be using it.")
        observe(AVCaptureSession.interruptionEndedNotification,
                "Waiting for the first iPhone camera image…")
        observe(AVCaptureSession.runtimeErrorNotification,
                "The iPhone camera stopped. Stop RayBridge and start it again.")
    }

    private func observe(_ name: Notification.Name, _ status: String) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.capturing else { return }
                self.onStatus?(status, false)
            }
        })
    }

    func start() async throws {
        generation += 1
        let current = generation
        receivedFrame = false
        onStatus?(CaptureSource.phone.startingStatus, false)
        RayBridgeDiagnostics.event("Checking iPhone camera permission")
        try await Self.authorize()
        try Task.checkCancellation()
        engine.setFrameHandler { [weak self] data in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if !self.receivedFrame { RayBridgeDiagnostics.event("First iPhone camera image received") }
                self.receivedFrame = true
                self.onFrame?(data)
            }
        }
        do {
            RayBridgeDiagnostics.event("Starting iPhone camera capture")
            try await engine.start()
            capturing = true
            try Task.checkCancellation()
            // A frame can arrive before startRunning() returns. Do not clear it
            // by publishing a stale waiting status after capture has succeeded.
            if !receivedFrame { onStatus?("Waiting for the first iPhone camera image…", false) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !receivedFrame {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw BridgeError.message("No image from the iPhone camera. Check that nothing is covering the lens, then start again.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        generation += 1
        capturing = false
        receivedFrame = false
        engine.setFrameHandler(nil)
        await engine.stop()
        onStatus?("Camera off", false)
    }

    private static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw BridgeError.message("Allow camera access for RayBridge to use the iPhone camera.")
            }
        default:
            throw BridgeError.message("Allow camera access for RayBridge in iPhone Settings, then start again.")
        }
    }
}
