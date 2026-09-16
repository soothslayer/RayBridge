# RayBridge handoff

Updated September 16, 2026, after successful physical-glasses testing.

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

- The user wants to discuss making everyday operation easier for a blind person. These accessibility changes have not yet been implemented.
- Prioritize one Start/Stop flow, spoken readiness and recovery, predictable VoiceOver navigation, repeat/interrupt controls, and testing with the intended user.
- Foreground-only: backgrounding an active session suspends it. Locked-phone operation requires investigation and physical testing, not a UI-only promise.
- First-image timeout begins after awaiting stream.start(); a hung SDK start call is not independently bounded.
- No periodic stale-frame UI watchdog exists; questions already reject stale images.
- AVAudioSession main-thread responsiveness warnings remain. A Bluetooth startup warning also appeared in the successful run, so it is not proof of capture failure.
- Hardware reconnect, interruption, VoiceOver/audio scheduling, and sustained-use testing remain valuable; one successful session is not comprehensive validation.
