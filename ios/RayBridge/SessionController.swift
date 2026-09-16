import Foundation

// Serializes startup and teardown so a second Start cannot overlap camera cleanup.
// Hardware operations are injected to test cancellation without physical glasses.
@MainActor
final class SessionController {
    enum Phase: Equatable {
        case idle, connecting, authorizing, startingCamera, startingAudio, running, stopping
    }
    private(set) var phase = Phase.idle {
        didSet { onPhase?(phase) }
    }
    var onPhase: ((Phase) -> Void)?
    var onError: ((Error) -> Void)?
    private let steps: [(Phase, () async throws -> Void)]
    private let stopImmediately: () -> Void
    private let stopCamera: () async -> Void
    private var task: Task<Void, Never>?

    init(connect: @escaping () async throws -> Void,
         authorize: @escaping () async throws -> Void,
         startCamera: @escaping () async throws -> Void,
         startAudio: @escaping () async throws -> Void,
         stopImmediately: @escaping () -> Void,
         stopCamera: @escaping () async -> Void) {
        steps = [(.connecting, connect), (.authorizing, authorize),
                 (.startingCamera, startCamera), (.startingAudio, startAudio)]
        self.stopImmediately = stopImmediately
        self.stopCamera = stopCamera
    }

    func start() {
        guard phase == .idle else { return }
        phase = .connecting
        task = Task {
            do {
                for (nextPhase, operation) in steps {
                    try Task.checkCancellation()
                    phase = nextPhase
                    try await operation()
                }
                try Task.checkCancellation()
                phase = .running
            } catch {
                // Explicit Stop owns cleanup for a cancelled startup.
                guard !Task.isCancelled else { return }
                phase = .stopping
                stopImmediately()
                await stopCamera()
                phase = .idle
                onError?(error)
            }
        }
    }

    func stop() {
        guard phase != .idle, phase != .stopping else { return }
        phase = .stopping
        let startup = task
        startup?.cancel()
        stopImmediately()
        task = Task {
            // Even SDK operations that return after cancellation must finish
            // before cleanup and before another startup is allowed.
            await startup?.value
            await stopCamera()
            phase = .idle
        }
    }
}
