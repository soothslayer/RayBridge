# RayBridge handoff

Updated September 17, 2026.

## Active: reuse this Mac's Codex login

- Branch `feat/use-local-codex-login` adds an alternative to RayBridge's separate browser login.
- **Use this Mac’s Codex login** opens a new stdio app-server and inherits the machine's normal `CODEX_HOME`, environment, configuration, memories, tools, plugins, MCP servers, browser, and computer use. It selects the newest working executable found in ChatGPT.app, Codex.app, common CLI locations, or the bundle; `RAYBRIDGE_LOCAL_CODEX` can force one. It does not attach to an arbitrary interactive process, copy tokens, share conversations, or expose logout for the shared account.
- Local mode defaults to the Mac user’s home folder and exposes a persisted working-folder field on the loopback setup page. Its ephemeral threads use `workspace-write`, network access, and automatic approval review. Direct requests that still require a person are declined. The separate RayBridge account retains forced OpenAI provider, cleared MCP servers, disabled tools/network, and read-only permissions.
- The selected source persists in `~/Library/Application Support/RayBridge/codex-account-source`; switching disconnects the phone and restarts only RayBridge's app-server child.
- Unit/server tests cover launch isolation, restrictions, executable candidates, source switching, workspace and Computer Use app persistence, invalid input, and shared-account logout protection. The bundled CLI 0.146.0 could read the shared account but could not run the configured `gpt-6-astra`; automatic selection found ChatGPT.app's 0.154.0-alpha.6.2 runtime. Live local turns then read a workspace file and opened Calculator through Computer Use without a new login.

## TestFlight packaging fix on main

- Apple rejected version 0.1.0 build 1 with ITMS-90022, ITMS-90023, ITMS-90474, and ITMS-90713: missing iPhone/iPad icons, missing icon metadata, and incomplete iPad multitasking orientations.
- Added AppIcon catalog with 18 opaque PNG variants and reproducible vector artwork in `scripts/generate-app-icon.swift`. Registered the asset catalog in the Xcode resources phase; the existing AppIcon compiler setting now generates icon metadata.
- Added all four iPad orientations, aligned `ios/project.yml` with the existing iPhone+iPad target, and bumped the source build number to 2. Camera/audio code remains the working main version.
- Release unsigned archive at `.build/RayBridge-validation.xcarchive` succeeded. Actual bundle includes 120x120 and 152x152 PNGs, AppIcon metadata, and all four iPad orientations. Guard also rejected fixtures reproducing each of Apple's four failures.
- Xcode Cloud post-archive hook runs `scripts/verify-ios-archive.py`; final acceptance still depends on the next cloud build and Apple processing.
- Unrelated local Device Logs scheme and Xcode Cloud manifest edits were preserved.

## Completed: unified Start/Stop

- Branch `feat/unified-start-stop` builds on working main commit `9fd8029`.
- User requested accessibility item #1 only, with physical confirmation before moving to the next item.
- Main screen now offers Start RayBridge / Stop RayBridge. Setup contains pairing, registration, and phone-audio testing.
- `SessionController` serializes Mac connection, audio permission checks, camera startup/first-frame readiness, and microphone startup. Stop immediately ends audio and the Mac connection, cancels startup, waits for the pending operation, then tears down the camera before another Start is allowed.
- Closing the Mac socket cancels pending inference and starts a new conversation on the next Start. Existing displayed conversation text is retained until New conversation.
- Startup errors clean up partially started resources. Camera permission handoffs remain allowed across backgrounding.
- Added `bash scripts/test-ios-session.sh`: nine hardware-independent tests for startup order, duplicate taps, Stop, cancellation and failure at every startup stage.
- All nine lifecycle tests, ten backend tests, backend syntax checks, and the unsigned physical-device build passed. Xcode Device Logs installed and launched this branch on the iPhone; `Main screen appeared` verified. The user approved committing and merging this work after the registration fix.
- No automatic recovery, new spoken-status system, voice commands, App Intents, or locked-phone support has been added.
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
- No periodic stale-frame UI watchdog exists; questions already reject stale images.
- AVAudioSession main-thread responsiveness warnings remain. A Bluetooth startup warning also appeared in the successful run, so it is not proof of capture failure.
- Hardware reconnect, interruption, VoiceOver/audio scheduling, and sustained-use testing remain valuable; one successful session is not comprehensive validation.
