import Foundation

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

private enum TestFailure: Error { case startup }

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        precondition(ContinuousClock.now < deadline, "Timed out waiting for lifecycle transition")
        try await Task.sleep(for: .milliseconds(1))
    }
}

@main
struct SessionControllerTests {
    @MainActor
    static func main() async throws {
        try await testStartupAndStop()
        for stage in 0..<4 {
            try await testCancellation(at: stage)
            try await testFailure(at: stage)
        }
        print("Passed 9 session lifecycle tests: startup order, full stop, cancellation and failure at every stage.")
    }

    @MainActor
    static func testStartupAndStop() async throws {
        let camera = Gate(), cleanup = Gate()
        var events: [String] = []
        var ready = false
        let session = SessionController(
            connect: { events.append("mac") },
            authorize: { events.append("permissions") },
            startCamera: { events.append("camera"); await camera.wait() },
            startAudio: { events.append("audio") },
            stopImmediately: { events.append("stop audio and mac") },
            stopCamera: { events.append("stop camera"); await cleanup.wait() }
        )
        session.onPhase = { if $0 == .running { ready = true } }
        session.start(); session.start()
        try await eventually { events == ["mac", "permissions", "camera"] }
        precondition(!ready, "Must wait for a camera frame before listening")
        camera.open()
        try await eventually { session.phase == .running }
        precondition(events == ["mac", "permissions", "camera", "audio"])
        session.stop(); session.stop(); session.start()
        precondition(events.last == "stop audio and mac", "Audio/connection stop synchronously")
        try await eventually { events.last == "stop camera" }
        precondition(session.phase == .stopping, "New startup must wait for camera teardown")
        cleanup.open()
        try await eventually { session.phase == .idle }
        precondition(events.filter { $0 == "mac" }.count == 1, "Duplicate Start must be ignored")
    }

    @MainActor
    static func testCancellation(at blockedStage: Int) async throws {
        let gate = Gate()
        var steps: [Int] = []
        var stops = 0, cleanups = 0, errors = 0, ready = 0
        var block = true
        func step(_ index: Int) async throws {
            steps.append(index)
            if block && index == blockedStage { await gate.wait() }
        }
        let session = SessionController(
            connect: { try await step(0) }, authorize: { try await step(1) },
            startCamera: { try await step(2) }, startAudio: { try await step(3) },
            stopImmediately: { stops += 1 }, stopCamera: { cleanups += 1 }
        )
        session.onError = { _ in errors += 1 }
        session.onPhase = { if $0 == .running { ready += 1 } }
        session.start()
        try await eventually { steps.last == blockedStage }
        session.stop(); session.start()
        precondition(stops == 1 && session.phase == .stopping)
        // Simulate an SDK or permission callback that still returns after Stop.
        gate.open()
        try await eventually { session.phase == .idle }
        precondition(steps == Array(0...blockedStage) && ready == 0 && errors == 0 && cleanups == 1)
        block = false; steps = []
        session.start()
        try await eventually { session.phase == .running }
        precondition(steps == [0, 1, 2, 3] && ready == 1, "A fresh Start should work after cancellation")
        session.stop()
        try await eventually { session.phase == .idle }
    }

    @MainActor
    static func testFailure(at failedStage: Int) async throws {
        var steps: [Int] = []
        var stops = 0, cleanups = 0, errors = 0
        func step(_ index: Int) throws {
            steps.append(index)
            if index == failedStage { throw TestFailure.startup }
        }
        let session = SessionController(
            connect: { try step(0) }, authorize: { try step(1) },
            startCamera: { try step(2) }, startAudio: { try step(3) },
            stopImmediately: { stops += 1 }, stopCamera: { cleanups += 1 }
        )
        session.onError = { _ in
            precondition(stops == 1 && cleanups == 1, "Failure must clean up partial startup")
            errors += 1
        }
        session.start()
        try await eventually { errors == 1 }
        precondition(session.phase == .idle && steps == Array(0...failedStage))
    }
}
