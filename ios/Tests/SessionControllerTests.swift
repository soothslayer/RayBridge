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
        try await testTransientStartupRecovery()
        try await testRetryExhaustion()
        try await testStopDuringRetryDelay()
        try await testStableConnectionResetsBudget()
        try await testRecoveryWaitsForSpeech(cancel: false)
        try await testRecoveryWaitsForSpeech(cancel: true)
        testCameraFreshness()
        print("Passed 16 lifecycle/freshness tests, including recovery, exhaustion, cancellation and stable-connection retry reset.")
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

    @MainActor
    static func testTransientStartupRecovery() async throws {
        var attempts = 0, cleanups = 0, notifications = 0
        let session = SessionController(
            connect: {
                attempts += 1
                if attempts == 1 { throw RecoverableSessionError(message: "Mac unavailable") }
            }, authorize: {}, startCamera: {}, startAudio: {},
            stopImmediately: {}, stopCamera: { cleanups += 1 }, retryDelays: [.zero]
        )
        session.onRecovery = { _, attempt, maximum in
            precondition(attempt == 1 && maximum == 1 && cleanups == 1)
            notifications += 1
        }
        session.start()
        try await eventually { session.phase == .running }
        precondition(attempts == 2 && notifications == 1)
        session.stop()
        try await eventually { session.phase == .idle }
        precondition(cleanups == 2)
    }

    @MainActor
    static func testRetryExhaustion() async throws {
        var starts = 0, errors = 0, retries = 0
        let session = SessionController(
            connect: { starts += 1 }, authorize: {}, startCamera: {}, startAudio: {},
            stopImmediately: {}, stopCamera: {}, retryDelays: [.zero, .zero, .zero]
        )
        session.onRecovery = { _, _, _ in retries += 1 }
        session.onError = { _ in errors += 1 }
        session.start()
        for expectedStart in 1...4 {
            try await eventually { session.phase == .running && starts == expectedStart }
            session.recover("Camera disconnected")
            session.recover("Duplicate disconnect")
        }
        try await eventually { session.phase == .idle }
        precondition(starts == 4 && retries == 3 && errors == 1, "A flapping link must stop after its retry budget")
    }

    @MainActor
    static func testStopDuringRetryDelay() async throws {
        let gate = Gate()
        var attempts = 0, waiting = false, cleanups = 0, errors = 0
        let session = SessionController(
            connect: { attempts += 1; throw RecoverableSessionError(message: "Mac unavailable") },
            authorize: {}, startCamera: {}, startAudio: {},
            stopImmediately: {}, stopCamera: { cleanups += 1 },
            retryDelays: [.seconds(10)], wait: { _ in waiting = true; await gate.wait() }
        )
        session.onError = { _ in errors += 1 }
        session.start()
        try await eventually { waiting }
        session.stop(); gate.open()
        try await eventually { session.phase == .idle }
        precondition(attempts == 1 && cleanups == 1 && errors == 0, "Stop must cancel pending recovery")
    }

    @MainActor
    static func testStableConnectionResetsBudget() async throws {
        var time = Date(timeIntervalSince1970: 1000)
        var starts = 0
        let session = SessionController(
            connect: { starts += 1 }, authorize: {}, startCamera: {}, startAudio: {},
            stopImmediately: {}, stopCamera: {}, retryDelays: [.zero], now: { time }
        )
        session.start()
        try await eventually { session.phase == .running }
        session.recover("Disconnected")
        try await eventually { session.phase == .running && starts == 2 }
        time.addTimeInterval(31)
        session.recover("Disconnected after a stable session")
        try await eventually { session.phase == .running && starts == 3 }
        session.stop()
        try await eventually { session.phase == .idle }
    }

    @MainActor
    static func testRecoveryWaitsForSpeech(cancel: Bool) async throws {
        let speech = Gate()
        var cameraStarts = 0, cameraStops = 0, announcing = false, errors = 0
        let session = SessionController(
            connect: {}, authorize: {}, startCamera: { cameraStarts += 1 }, startAudio: {},
            stopImmediately: {}, stopCamera: { cameraStops += 1 }, retryDelays: [.zero]
        )
        session.onRecovery = { _, _, _ in
            precondition(cameraStops == 1, "Camera must stop before recovery speech")
            announcing = true
            await speech.wait()
        }
        session.onError = { _ in errors += 1 }
        session.start()
        try await eventually { session.phase == .running }
        session.recover("Disconnected")
        try await eventually { announcing }
        precondition(session.phase == .recovering && cameraStarts == 1,
                     "Camera must not restart while speech is in progress")
        if cancel { session.stop() }
        speech.open()
        if cancel {
            try await eventually { session.phase == .idle }
            precondition(cameraStarts == 1 && errors == 0, "Stop must cancel recovery speech without a restart")
        } else {
            try await eventually { session.phase == .running && cameraStarts == 2 }
            session.stop()
            try await eventually { session.phase == .idle }
        }
    }

    static func testCameraFreshness() {
        let time = Date(timeIntervalSince1970: 1000)
        precondition(!CameraFreshness.isFresh(nil, now: time))
        precondition(CameraFreshness.isFresh(time, now: time))
        precondition(CameraFreshness.isFresh(time.addingTimeInterval(-2.49), now: time))
        precondition(!CameraFreshness.isFresh(time.addingTimeInterval(-2.5), now: time))
        precondition(!CameraFreshness.isFresh(time.addingTimeInterval(-30), now: time))
        precondition(!CameraFreshness.isFresh(time.addingTimeInterval(1), now: time))
    }
}
