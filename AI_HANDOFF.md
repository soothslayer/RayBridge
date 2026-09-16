# RayBridge handoff

Updated September 16, 2026, after successful physical-glasses testing on main.

## Paused: spoken status and automatic recovery

- Start/Stop + registration fix committed as `a0c6aa8`, fast-forward merged and pushed to main, remote verified. Deleted `feat/unified-start-stop` (it had no remote branch).
- Created GitHub issues 1–5 for the remaining roadmap. Roadmap item #2 is GitHub issue #1; do not confuse that with issue #2, which is repeat/interrupt controls.
- Recovery work is preserved on `feat/spoken-status-recovery` for a draft PR. User reported the revised build still does not work and requested returning to working main (`a0c6aa8`) for a friend’s test setup. Do not merge the recovery PR until the physical camera regression is resolved.
- Controller retries typed transient failures at 2/5/10-second delays, up to three retries; 30 seconds of stable running resets the budget. Stop/background cancel retries. Terminal permission/configuration failures do not retry.
- Tactile startup feedback and spoken ready/recovery/stopped/error feedback routes through VoiceOver or app speech; mic stays paused during app announcements. Connection-loss status may fall back to the phone speaker. VoiceOver completion has a 15-second fallback and needs hardware validation.
- One-second camera watchdog and pre-send guards reject frames >=2.5 seconds old. Mac `requiresImage` request flag rejects a missing/stale frame after thread preparation with `camera_unavailable`, before invoking the model. Old clients may still omit this flag for text questions.
- Recovery closes the old Mac session and cancels an interrupted question. User must repeat the question after readiness; no automatic replay.
- Sixteen Swift lifecycle/freshness tests and twelve backend tests pass, including actual WebSocket propagation of camera-unavailable errors. Physical-device build passed. Recovery on actual glasses and VoiceOver scheduling are not yet verified.
- Follow-up regression: user reported overlapping RayBridge/glasses voices with VoiceOver OFF and camera internal errors. Xcode showed repeated SDK ActivityManagerError code 11 during stream startup, interleaved with audio activation/deactivation. This supports investigating audio timing but does not prove SDK error semantics.
- Fix: no app speech during initial camera startup (Start vibrates); prepare audio after the first frame, speak Ready, then open mic. Preserve the capture audio route through questions/answers; stop mic/speech immediately but deactivate audio after camera teardown. Offline status uses playback rather than opening an HFP mic. Recovery callback is awaited before retry; terminal errors are spoken after teardown. Added regression tests for camera restart waiting on recovery speech and Stop during that wait.
- The revised iPhone build passed and was installed/launched with devicectl (Xcode was being used in its workflow editor). Main screen verified. Current console capture: `/tmp/raybridge-audio-sequence-device.log`; user subsequently confirmed this revision still does not work. Do not mark the camera regression fixed.
- Both iPhone and Mac apps must be rebuilt/relaunched to test the new frame requirement.
- Deployment completed: Mac bundle rebuilt and relaunched, ChatGPT sign-in retained; Xcode installed/launched the iPhone build. User tapped Start, and live logs reached `RayBridge session ready with camera and microphone`. Automatic recovery and audible status still await physical confirmation. No GitHub issue closed and no recovery-branch changes merged yet.

## Completed: unified Start/Stop

- Branch `feat/unified-start-stop` builds on working main commit `9fd8029`.
- User requested accessibility item #1 only, with physical confirmation before moving to the next item.
- Main screen now offers Start RayBridge / Stop RayBridge. Setup contains pairing, registration, and phone-audio testing.
- `SessionController` serializes Mac connection, audio permission checks, camera startup/first-frame readiness, and microphone startup. Stop immediately ends audio and the Mac connection, cancels startup, waits for the pending operation, then tears down the camera before another Start is allowed.
- Closing the Mac socket cancels pending inference and starts a new conversation on the next Start. Existing displayed conversation text is retained until New conversation.
- Startup errors clean up partially started resources. Camera permission handoffs remain allowed across backgrounding.
- Added `bash scripts/test-ios-session.sh`: nine hardware-independent tests for startup order, duplicate taps, Stop, cancellation and failure at every startup stage.
- All nine lifecycle tests, ten backend tests, backend syntax checks, and the unsigned physical-device build passed. Xcode Device Logs installed and launched this branch on the iPhone; `Main screen appeared` verified. The user approved committing and merging this work after the registration fix.
- At the main-branch checkpoint, automatic recovery and spoken status were not yet added. They are now being implemented on the active branch above. Voice commands, App Intents, and locked-phone support remain separate future work.
- Follow-up: user reported `MWDATCore.RegistrationError error 0` when tapping Register despite a registered label. SDK case is `alreadyRegistered`. Registration now checks restored state before requesting, treats that typed error as success if it races the check, prevents simultaneous registration requests, and gives readable messages for other registration errors. Device build passed and was installed; the user subsequently approved merging.

## Verified status

- The user confirms the camera and app now work.
- The physical iPhone log confirmed Bluetooth permission allowed, a connected Meta external accessory, connected/compatible SDK glasses, a started device session, and `First glasses camera image received`. SDK telemetry continued at approximately 6–7 fps.
- The user enabled Developer Mode and completed its on-glasses installation. The app was also rebuilt/relaunched with the discovery fixes below. We cannot isolate which change resolved the earlier failure.
- Automatic selection succeeded in the verified run; the specific-device fallback was not exercised.
- The signed app was installed through Xcode using **RayBridge Device Logs**. The unsigned iOS device build, all 10 backend tests, backend syntax checks, shell syntax check, and `git diff --check` passed.

## User requirements

- A blind user should be able to ask questions about the glasses camera image and hear answers through the glasses.
- Preserve ChatGPT subscription sign-in through the official Codex app-server; do not replace it with separately billed OpenAI API access.
- This prototype uses turn-based speech and a recent image per question. It is not ChatGPT Voice or continuous video understanding.
- Preserve existing signing configuration, pairing, and credentials. Do not erase registration or permissions as speculative troubleshooting.

## Camera changes

- Configure Meta SDK discovery at app startup; retain the selector and refresh it after permission succeeds.
- Check existing camera permission before requesting it, and preserve the Meta AI permission handoff across backgrounding.
- Wait up to 15 seconds for selection. If automatic selection lags, allow a specific selector only for exactly one connected, compatible SDK device.
- Distinguish Bluetooth permission, missing discovery, firmware/SDK compatibility, disconnected and connecting states.
- Observe device startup before calling start and bound startup by a 20-second deadline.
- Stream raw, medium-resolution video at 7 fps. Retain at most one JPEG per second, quality 0.55, maximum 500 KB.
- Require a usable JPEG before reporting readiness. Announce the first frame through VoiceOver or the existing speech output; queue behind an ongoing answer.
- Guard late stream callbacks with a generation counter. Keep camera errors separate from Mac/listening status.
- Fixed-label diagnostics omit device names, identifiers, transcripts, images, and credentials.

## Development

- Meta DAT is pinned to 0.6.0; Swift language mode 5; iOS deployment target 18+.
- Consult the pinned XCFramework Swift interfaces for exact API signatures. Newer upstream SDK versions change camera APIs; do not copy newer examples without a deliberate migration.
- **RayBridge Device Logs** uses a Debug build without LLDB, providing console output when debugger startup stalls. The normal **RayBridge** scheme retains debugger support.
- `scripts/iphone-console.command "Your iPhone name"` launches the installed app and captures stdout. Stop Xcode's run first to avoid competing launch sessions.
- Keep phone Wi-Fi enabled for the Mac connection while using USB for deployment.
- Regenerating the Xcode project can overwrite local development-team settings. Preserve the selected team.
- Runtime credentials and certificates belong in the application support directory, never in Git.
- Do not run the source bridge alongside the native Mac app; their ports conflict.

## Validation commands

```sh
npm test
npm run check
bash -n scripts/iphone-console.command
git diff --check
xcodebuild -project ios/RayBridge.xcodeproj \
  -scheme 'RayBridge Device Logs' -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath .build/device \
  CODE_SIGNING_ALLOWED=NO build
```

## Remaining work

- The user approved the single Start/Stop flow and requested GitHub issues for the remaining improvements, followed by implementation of spoken status and automatic recovery.
- Remaining improvements: spoken readiness and recovery; repeat/interrupt controls; predictable VoiceOver navigation; Siri/Action button launch; investigate locked-phone operation.
- Foreground-only: backgrounding an active session suspends it. Locked-phone operation requires investigation and physical testing, not a UI-only promise.
- First-image timeout begins after awaiting stream.start(); a hung SDK start call is not independently bounded.
- The active recovery branch now has a periodic stale-frame watchdog; validate its threshold on physical glasses.
- AVAudioSession main-thread responsiveness warnings remain. A Bluetooth startup warning also appeared in the successful run, so it is not proof of capture failure.
- Hardware reconnect, interruption, VoiceOver/audio scheduling, and sustained-use testing remain valuable; one successful session is not comprehensive validation.
