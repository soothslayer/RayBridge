import Foundation

// Where a question's picture comes from. The glasses remain the default; the
// iPhone camera and speaker let someone use RayBridge without glasses at all.
enum CaptureSource: String, CaseIterable, Identifiable {
    case glasses
    case phone
    var id: String { rawValue }
    var displayName: String { self == .glasses ? "Meta glasses" : "This iPhone" }
    // Without glasses there is no Bluetooth headset route, so answers, cues and
    // confirmations play through the iPhone regardless of the testing toggle.
    var requiresPhoneAudio: Bool { self == .phone }
    var startingStatus: String {
        self == .glasses ? "Connecting glasses camera…" : "Starting iPhone camera…"
    }
    var connectedStatus: String {
        self == .glasses ? "Glasses camera connected" : "iPhone camera connected"
    }
    var cameraReadyAnnouncement: String {
        self == .glasses
            ? "Glasses camera connected. Listening."
            : "iPhone camera connected. Point the back of the iPhone at what you want described. Listening."
    }
}

// What a quick, synchronous check of the Meta SDK says about the glasses before
// startup begins. It is a hint for the warning text, not a substitute for the
// full camera startup, so every warning also offers to try the glasses anyway.
enum GlassesReadiness: Equatable {
    case ready
    case discoveryUnavailable
    case notRegistered
    case noGlassesFound
    case notConnected
    case connecting
    case needsUpdate
}

// The startup steps `SessionController` runs, mirrored here so the policy and
// its tests stay free of the session and hardware types.
enum StartupStage: Equatable {
    case connecting
    case authorizing
    case startingCamera
    case startingAudio
    case other
}

enum GlassesWarningAction: Equatable {
    case continueWithoutGlasses
    case tryGlassesAnyway
    case openSetup
    case cancel
}

struct GlassesWarning: Equatable, Identifiable {
    let title: String
    let message: String
    // Spoken after the warning appears, unless an error is already being read.
    let spokenNotice: String
    let actions: [GlassesWarningAction]
    var id: String { title + message }
}

enum StartDecision: Equatable {
    case startWithGlasses
    case startWithPhone
    case warnBeforePhone(GlassesReadiness)
}

enum BackgroundSessionAction: Equatable {
    case continueGlassesSession
    case preservePermissionHandoff
    case stopPhoneSession
    case stopStandbyListening
}

enum CaptureSourcePolicy {
    static let phoneFallbackOffer =
        "You can continue without glasses, using the iPhone camera and speaker."

    static func decision(preferred: CaptureSource, glasses: GlassesReadiness) -> StartDecision {
        // Someone who chose the iPhone in Setup never has to answer for glasses.
        guard preferred == .glasses else { return .startWithPhone }
        return glasses == .ready ? .startWithGlasses : .warnBeforePhone(glasses)
    }

    static func warning(for readiness: GlassesReadiness) -> GlassesWarning {
        GlassesWarning(
            title: "Glasses aren’t connected",
            message: "\(reason(readiness)) \(phoneFallbackOffer)",
            spokenNotice: "\(reason(readiness)) Say Start to continue without glasses, or say Cancel.",
            actions: readiness == .notRegistered
                ? [.continueWithoutGlasses, .openSetup, .cancel]
                : [.continueWithoutGlasses, .tryGlassesAnyway, .cancel])
    }

    // Offered after the glasses camera or glasses audio fails to start. The
    // failure has already been spoken, so this warning stays silent.
    static func startupFailureWarning(_ message: String) -> GlassesWarning {
        GlassesWarning(
            title: "Glasses couldn’t start",
            message: "\(message) \(phoneFallbackOffer)",
            spokenNotice: "",
            actions: [.continueWithoutGlasses, .tryGlassesAnyway, .cancel])
    }

    // A Mac connection or iPhone permission failure is not fixed by dropping the
    // glasses, so only the glasses-specific startup steps offer the iPhone.
    static func offersPhoneFallback(failedStage: StartupStage, source: CaptureSource) -> Bool {
        guard source == .glasses else { return false }
        return failedStage == .startingCamera || failedStage == .startingAudio
    }

    static func backgroundAction(
        sessionActive: Bool,
        source: CaptureSource,
        awaitingGlassesPermission: Bool
    ) -> BackgroundSessionAction {
        if awaitingGlassesPermission { return .preservePermissionHandoff }
        guard sessionActive else { return .stopStandbyListening }
        return source == .glasses ? .continueGlassesSession : .stopPhoneSession
    }

    private static func reason(_ readiness: GlassesReadiness) -> String {
        switch readiness {
        case .ready: return "Your glasses are ready."
        case .discoveryUnavailable: return "RayBridge could not start glasses discovery."
        case .notRegistered: return "Your glasses aren’t registered with Meta AI yet."
        case .noGlassesFound: return "RayBridge can’t find your glasses."
        case .notConnected: return "Your glasses aren’t connected."
        case .connecting: return "Your glasses are still connecting."
        case .needsUpdate: return "Your glasses or the Meta SDK need an update before the glasses camera can be used."
        }
    }
}
