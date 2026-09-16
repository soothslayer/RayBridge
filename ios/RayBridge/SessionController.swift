import Foundation

struct RecoverableSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Owns the user's active-session intent across bounded retries. Manual Stop
// cancels both an in-flight startup and a pending recovery delay.
@MainActor
final class SessionController {
    enum Phase: Equatable {
        case idle, connecting, authorizing, startingCamera, startingAudio, running, recovering, stopping
    }
    private(set) var phase = Phase.idle { didSet { onPhase?(phase) } }
    var onPhase: ((Phase) -> Void)?
    var onError: ((Error) -> Void)?
    var onRecovery: ((String, Int, Int) async throws -> Void)?
    private let steps: [(Phase, () async throws -> Void)]
    private let stopImmediately: () -> Void
    private let stopCamera: () async -> Void
    private let retryDelays: [Duration]
    private let wait: (Duration) async throws -> Void
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var recoveryReason: RecoverableSessionError?
    private var needsCleanup = false

    init(connect: @escaping () async throws -> Void,
         authorize: @escaping () async throws -> Void,
         startCamera: @escaping () async throws -> Void,
         startAudio: @escaping () async throws -> Void,
         stopImmediately: @escaping () -> Void,
         stopCamera: @escaping () async -> Void,
         retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)],
         wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> Date = Date.init) {
        steps = [(.connecting, connect), (.authorizing, authorize),
                 (.startingCamera, startCamera), (.startingAudio, startAudio)]
        self.stopImmediately = stopImmediately
        self.stopCamera = stopCamera
        self.retryDelays = retryDelays
        self.wait = wait
        self.now = now
    }

    func start() {
        guard phase == .idle else { return }
        recoveryReason = nil
        phase = .connecting
        task = Task { await run() }
    }

    func recover(_ message: String) {
        guard phase == .running, recoveryReason == nil else { return }
        recoveryReason = RecoverableSessionError(message: message)
        phase = .recovering
        stopImmediately()
    }

    private func run() async {
        var retries = 0
        while !Task.isCancelled {
            needsCleanup = true
            do {
                for (nextPhase, operation) in steps {
                    try Task.checkCancellation()
                    phase = nextPhase
                    try await operation()
                }
                try Task.checkCancellation()
                let readyAt = now()
                phase = .running
                while recoveryReason == nil { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                // Flapping links share one retry budget until healthy for 30s.
                if now().timeIntervalSince(readyAt) >= 30 { retries = 0 }
                if let reason = recoveryReason { throw reason }
            } catch {
                guard !Task.isCancelled else { return }
                let shouldRetry = error is RecoverableSessionError && retries < retryDelays.count
                if phase != .recovering {
                    phase = shouldRetry ? .recovering : .stopping
                    stopImmediately()
                }
                await cleanup()
                guard !Task.isCancelled else { return }
                guard shouldRetry else {
                    phase = .idle
                    onError?(error)
                    return
                }
                let delay = retryDelays[retries]
                retries += 1
                do {
                    // Finish feedback after teardown and before another camera
                    // start. Stop cancels this wait as well as the retry delay.
                    try await onRecovery?(error.localizedDescription, retries, retryDelays.count)
                    try Task.checkCancellation()
                    try await wait(delay)
                    try Task.checkCancellation()
                }
                catch {
                    if !Task.isCancelled { phase = .idle; onError?(error) }
                    return
                }
                recoveryReason = nil
            }
        }
    }

    private func cleanup() async {
        guard needsCleanup else { return }
        await stopCamera()
        needsCleanup = false
    }

    func stop() {
        guard phase != .idle, phase != .stopping else { return }
        phase = .stopping
        let startup = task
        startup?.cancel()
        stopImmediately()
        task = Task {
            await startup?.value
            await cleanup()
            phase = .idle
        }
    }
}

// Use the same freshness rule at startup, on the watchdog, and before sending.
struct CameraFreshness {
    static let maximumAge: TimeInterval = 2.5
    static func isFresh(_ capturedAt: Date?, now: Date = Date()) -> Bool {
        guard let capturedAt else { return false }
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age < maximumAge
    }
}
