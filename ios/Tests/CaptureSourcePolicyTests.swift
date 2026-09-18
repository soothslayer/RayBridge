import Foundation

@main
struct CaptureSourcePolicyTests {
    static func main() {
        testGlassesStartWithoutAWarning()
        testEveryUnreadyStateWarnsAndOffersThePhone()
        testRegistrationWarningOffersSetup()
        testPhonePreferenceSkipsTheWarning()
        testStartupFailureFallback()
        testSourceStrings()
        print("Passed 6 capture source tests: ready glasses, every unready state, registration, iPhone preference, startup fallback, spoken strings.")
    }

    static func testGlassesStartWithoutAWarning() {
        precondition(CaptureSourcePolicy.decision(preferred: .glasses, glasses: .ready) == .startWithGlasses,
                     "Connected glasses must start without an extra prompt")
    }

    static func testEveryUnreadyStateWarnsAndOffersThePhone() {
        let unready: [GlassesReadiness] = [.discoveryUnavailable, .notRegistered, .noGlassesFound,
                                           .notConnected, .connecting, .needsUpdate]
        for readiness in unready {
            precondition(CaptureSourcePolicy.decision(preferred: .glasses, glasses: readiness)
                            == .warnBeforePhone(readiness),
                         "Starting without ready glasses must warn first")
            let warning = CaptureSourcePolicy.warning(for: readiness)
            precondition(warning.actions.first == .continueWithoutGlasses,
                         "Continuing without glasses must be the first choice")
            precondition(warning.actions.contains(.cancel), "The warning must be dismissible")
            precondition(warning.message.contains(CaptureSourcePolicy.phoneFallbackOffer),
                         "The warning must explain what continuing without glasses does")
            precondition(!warning.spokenNotice.isEmpty && warning.spokenNotice.contains("Say Start"),
                         "A blind user must hear the warning and how to accept it")
        }
    }

    static func testRegistrationWarningOffersSetup() {
        // Registration is the one state a user fixes in Setup rather than by retrying.
        precondition(CaptureSourcePolicy.warning(for: .notRegistered).actions
                        == [.continueWithoutGlasses, .openSetup, .cancel])
        // A stale SDK device list can report unready glasses that are in fact
        // connected, so every other warning keeps the glasses reachable.
        for readiness in [GlassesReadiness.noGlassesFound, .notConnected, .connecting,
                          .needsUpdate, .discoveryUnavailable] {
            precondition(CaptureSourcePolicy.warning(for: readiness).actions.contains(.tryGlassesAnyway),
                         "The user must still be able to try the glasses")
        }
    }

    static func testPhonePreferenceSkipsTheWarning() {
        for readiness in [GlassesReadiness.ready, .notRegistered, .notConnected] {
            precondition(CaptureSourcePolicy.decision(preferred: .phone, glasses: readiness) == .startWithPhone,
                         "Choosing the iPhone in Setup must never ask about glasses")
        }
    }

    static func testStartupFailureFallback() {
        precondition(CaptureSourcePolicy.offersPhoneFallback(failedStage: .startingCamera, source: .glasses))
        precondition(CaptureSourcePolicy.offersPhoneFallback(failedStage: .startingAudio, source: .glasses))
        for stage in [StartupStage.connecting, .authorizing, .other] {
            precondition(!CaptureSourcePolicy.offersPhoneFallback(failedStage: stage, source: .glasses),
                         "Mac and iPhone permission failures are not fixed by dropping the glasses")
        }
        for stage in [StartupStage.connecting, .authorizing, .startingCamera, .startingAudio, .other] {
            precondition(!CaptureSourcePolicy.offersPhoneFallback(failedStage: stage, source: .phone),
                         "A session already using the iPhone has nothing to fall back to")
        }
        let warning = CaptureSourcePolicy.startupFailureWarning("The glasses disconnected.")
        precondition(warning.message.hasPrefix("The glasses disconnected."), "Keep the underlying failure")
        precondition(warning.spokenNotice.isEmpty, "The spoken error already carries this failure")
        precondition(warning.actions == [.continueWithoutGlasses, .tryGlassesAnyway, .cancel])
    }

    static func testSourceStrings() {
        precondition(!CaptureSource.glasses.requiresPhoneAudio, "Glasses keep their own audio route")
        precondition(CaptureSource.phone.requiresPhoneAudio, "Without glasses everything plays on the iPhone")
        precondition(CaptureSource.phone.cameraReadyAnnouncement.contains("iPhone camera"))
        precondition(CaptureSource.glasses.cameraReadyAnnouncement.contains("Glasses camera"))
        precondition(CaptureSource(rawValue: "phone") == .phone, "The saved preference must survive a relaunch")
    }
}
