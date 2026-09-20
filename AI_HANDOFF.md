# RayBridge handoff

Updated September 18, 2026.

## Active: response latency

- Branch `claude/slow-response-times-toq56q` addresses the first three items of a latency review. No timing has been measured on real hardware yet; these changes exist so that the next physical session can be measured rather than guessed at.
- **Stage timings.** `bridge/timing.mjs` records each turn's stages on the Mac, and `RayBridgeDiagnostics.timing` records the phone's own stages. Both write fixed labels and integer milliseconds; questions, answers, images, identifiers, and account details are never recorded.
- **A proven sign-in is reused.** The connection handshake already reads the account, so `PhoneSession` starts from that result and reuses it for five minutes. Previously every question paid for a `claude auth status` or `hermes --version` subprocess, or a Codex RPC, before inference could start. A failed turn drops the cached result so a sign-out is still reported.
- **Answers are spoken as they are written.** New `answer.partial` and `answer.discard` events carry finished sentences to the phone, which queues them for speech and then speaks only what is left when the completed answer arrives. Claude Code text comes from `--include-partial-messages` streaming events, requested only when the installed CLI offers the flag; Hermes streams its quiet one-shot output. Codex is handled if it ever sends `item/updated`, and is otherwise unchanged. Kokoro answers are not streamed because the Mac generates one audio file from the finished text.
- Text written before the assistant calls a tool is withdrawn rather than spoken, since that is preparation and not the answer. The Claude and Hermes system prompts now also ask for no narration. Two withdrawals in a turn stop streaming for that turn instead of stuttering.
- 48 backend tests and the backend syntax checks pass. The Claude streaming parser was written against real `claude --print --output-format stream-json --include-partial-messages` output. **Nothing on the iPhone has been compiled or run**: this session had no macOS, Xcode, or Swift toolchain. The iOS changes in `AppModel`, `SpeechController`, and the new `AnswerStreamPolicy` still need a device build, `bash scripts/test-ios-answer-stream.sh`, and physical glasses testing.
- **One Claude process per conversation.** Claude now runs with `--input-format stream-json` and stays open for a phone's whole conversation; each question is written to it as a message. Measured on the development machine with an otherwise identical question: about 3.1 seconds per question when a process was started for each one, about 1.6 seconds on an already open process. The first question of a conversation still pays the startup, because that is when the process opens.
- **The camera image travels inside the question.** Claude receives a base64 image content block instead of a staged file plus an instruction to read it, so a visual question is one model turn rather than two. No frame is written to disk for Claude; the image does enter that Claude session's history, and the system prompt now tells the assistant that earlier images show where the user used to be.
- **Cancel keeps the process.** Interruption is a `control_request` rather than killing the process, so the conversation and the open process both survive a Cancel. A process that does not stop within three seconds is ended and the next question resumes the conversation in a new one. `--session-id` on first launch and `--resume` on a replacement were both verified against the real CLI in streaming-input mode.
- 54 backend tests pass. Verified live against the installed CLI: a warm process answering successive questions, an inline image described correctly in one turn, an interrupt aborting an in-flight turn with the process surviving, and sentence-by-sentence delivery reaching the phone 0.9 seconds before the completed answer.
- Not done from the same review: opening the Claude process when the phone connects so the first question does not pay startup, the same warm-process treatment for Hermes, adaptive end-of-speech timing, sending camera frames while listening rather than at ask time, streamed Kokoro synthesis, and background audio so a session survives the phone going in a pocket.

## Active: optional no-glasses mode

- Branch `claude/raybridge-no-glasses-mode-770cmr` makes the glasses optional. `CaptureSource` selects the glasses or this iPhone; `CameraSource` gives both the same start/stop/frame/status interface, so the session lifecycle, frame limits, staleness rule, and phone protocol are unchanged.
- Start now checks `GlassesCamera.readiness` synchronously (discovery, registration, device list, link state, compatibility). Anything but ready warns before starting anything and offers **Continue without glasses**, **Try glasses anyway** (or **Open Setup** when unregistered), and **Cancel**. Device state can lag the hardware, so the warning never blocks the glasses.
- A glasses camera or glasses audio failure during startup makes the same offer, carrying the underlying failure; a Mac connection or iPhone permission failure does not, because the iPhone cannot fix it. The warning is posted to VoiceOver and spoken when VoiceOver is off; in standby, “start” continues without glasses and “cancel” dismisses.
- `PhoneCamera` captures 1280x720 on a private queue, rotates frames upright, samples one JPEG per second at 500 KB or less, leaves the app's audio session to `SpeechController`, and requires a usable image before the microphone starts. `NSCameraUsageDescription` was added.
- Without glasses the iPhone carries microphone, cues, confirmations, and answers, so a lost Bluetooth route no longer ends the session. `Setup → Camera and audio` persists the choice; **This iPhone** skips the glasses check, warning, and Meta registration entirely.
- `bash scripts/test-ios-capture-source.sh` adds six hardware-independent tests over the decisions. All 39 Node tests, `npm run check`, the shell syntax check, and `git diff --check` pass. **No Swift compiler was available in this environment: the iOS build, the new Swift tests, and all physical behavior are unverified.** See the new no-glasses section in `docs/hardware-checks.md`.

## Active: Claude Code provider

- Branch `feature/claude-code-provider` adds a provider-neutral assistant router while keeping Codex as the default.
- The Mac setup page now selects Codex or Claude Code. Claude uses the Mac's existing CLI login, normal configuration, project instructions, tools, plugins, MCP servers, and selected working folder. This Mac's CLI reports a signed-in Pro account.
- Claude runs in streaming print mode with a separate resumable session per phone connection. User prompts travel over stdin rather than process arguments. Current camera JPEGs are staged in RayBridge's private Application Support directory, exposed only for that turn, and deleted after completion.
- Claude events are normalized to the existing internal turn protocol, so iPhone camera selection, thinking state, answer speech, Kokoro, reset, timeout, and Cancel/barge-in need no iPhone changes. Claude runs in `bypassPermissions`, so tool actions never need an approval the user cannot see or give; `RAYBRIDGE_CLAUDE_PERMISSION_MODE` narrows it again without a rebuild.
- The native Mac app was rebuilt and relaunched. Current macOS required explicitly ad-hoc signing the copied Node and Codex executables before sealing the development app; `scripts/build-mac.sh` now does that. A real provider switch between Claude and local Codex passed.
- Backend syntax checks and all 32 Node tests pass, including provider switching, Claude streaming output, conversation resumption, private image staging, interruption, and setup persistence. Live end-to-end WebSocket tests through the running Mac app returned `Claude connection works.` for text and `Blue background with a white number 7.` for the existing camera fixture.

## Active: reuse this Mac's Codex login

- Branch `feat/use-local-codex-login` adds an alternative to RayBridge's separate browser login.
- **Use this Mac’s Codex login** opens a new stdio app-server and inherits the machine's normal `CODEX_HOME`, environment, configuration, memories, tools, plugins, MCP servers, browser, and computer use. It selects the newest working executable found in ChatGPT.app, Codex.app, common CLI locations, or the bundle; `RAYBRIDGE_LOCAL_CODEX` can force one. It does not attach to an arbitrary interactive process, copy tokens, share conversations, or expose logout for the shared account.
- Local mode defaults to the Mac user’s home folder and exposes a persisted working-folder field on the loopback setup page. Its ephemeral threads use `danger-full-access` with `approvalPolicy: never` and no automatic reviewer, because a reviewer can decline and the user has no way to see or override that. Approval requests that still arrive are granted for the session; requests needing a typed answer from a person still fail closed. The separate RayBridge account retains forced OpenAI provider, cleared MCP servers, disabled tools/network, and read-only permissions.
- Local mode inherits the Mac's `~/.codex/config.toml`, including its `model`. A ChatGPT login cannot use the `*-codex` model names, so a config naming one fails every turn with "not supported when using Codex with a ChatGPT account" — and `codex doctor` still reports no failures. README has the `model/list` snippet for finding an account's real models. Verified after the fix: a local Codex turn answered through the running app in 9.7 seconds and ran a shell command.
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
