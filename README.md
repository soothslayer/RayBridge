# RayBridge

A Mac + iPhone prototype that connects Meta Ray-Ban glasses to the **Codex access included in an eligible ChatGPT subscription**. No OpenAI API key or separate API billing is used.

**This is a working development foundation, not the complete live-video ChatGPT Voice experience.** It listens to a question, attaches a recent glasses camera image, waits for a Codex answer, and speaks that answer. The iPhone pauses recognition while answering, then listens again. The basic camera/question flow on `main` passed physical-glasses testing. This recovery feature branch currently fails on physical glasses with a camera internal error; the audio-sequencing revision did not resolve it. Use `main` for the working baseline.

## Why this architecture

OpenAI documents subscription sign-in and image-containing conversation turns through the [Codex app server](https://learn.chatgpt.com/docs/app-server). Its documented interfaces give us a subscription-based path for questions and snapshots. That does **not** establish subscription access to the separate [Realtime API](https://developers.openai.com/api/docs/guides/realtime).

The project therefore preserves the subscription-only requirement, with a clear tradeoff: turn-based voice and per-question camera images instead of simultaneous speech and continuous model understanding of video. It creates new conversations; it does not import your existing ChatGPT chats, memories, or custom instructions. Subscription eligibility, available models, usage limits, and account policies apply. No latency target has been measured on real hardware.

## Open the Mac app

The local build is at `build/RayBridge.app`. Double-click it, or run:

```sh
open build/RayBridge.app
```

1. Choose **Sign in with ChatGPT** and complete the official browser flow using your friend's account.
2. Keep the Mac and iPhone on the same private Wi-Fi network.
3. Leave RayBridge running and keep the Mac awake.
4. Pair the iPhone app using the QR code or pairing link.

The development app bundles the Node and Codex executables from the build machine. This build is for Apple Silicon and is ad-hoc signed, not notarized. It is not an installer ready for general distribution. Rebuild for another CPU architecture or older macOS deployment target. Do not run the source server and Mac app at the same time: both use ports 8844/8845.

To run from source, install Node.js 22+ and the official Codex CLI, then:

```sh
npm ci
npm start
```

Open `http://127.0.0.1:8844` on that Mac. `scripts/start-mac.command` provides a double-click source launcher. To rebuild the native Mac wrapper, run `bash scripts/build-mac.sh`; this requires Xcode command-line tools and a native standalone Codex executable on PATH. The npm Codex launcher script is not accepted by the bundler.

## Install the iPhone app

The checked-in Xcode project is `ios/RayBridge.xcodeproj`. It requires iOS 18+, current Xcode, and a physical iPhone for real speech and glasses testing. Meta DAT is pinned to **0.6.0** in both the project and Swift package resolution.

1. Open the Xcode project. Select the RayBridge target and your Apple development team in Signing & Capabilities. Choose a unique bundle identifier if required.
2. Install Meta AI on the iPhone and pair the glasses there. Enable **Developer Mode** for the glasses. The included `MWDAT.MetaAppID = 0` is for that developer flow. For a release-channel build, replace the Meta app ID/client token and configure the project in Meta's developer console; do not ship the placeholder values. See [Meta registration documentation](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/permissions-registration/SKILL.md).
3. Select the physical iPhone in Xcode and Run. Complete iPhone development trust/setup if prompted.
4. Scan the Mac pairing QR with the iPhone Camera. RayBridge opens with the link filled in; select **Pair Mac** in **Setup**. Alternatively, open **Setup** and copy the link into RayBridge's pairing field. The token is stored in the iPhone Keychain.
5. In **Setup**, select **Register with Meta AI** and complete registration, then select **Done**. Ensure glasses audio is connected in iOS Bluetooth.
6. Select **Start RayBridge**. It connects to your saved Mac, checks microphone/speech permissions, starts the glasses camera, waits for a usable image, and begins listening. Grant camera access in Meta AI if requested, then return to RayBridge. Wait for **Ready. Ask your question.**, ask a question, pause, and wait for the spoken answer. On subsequent launches, just select **Start RayBridge**.

English (US) **on-device** speech recognition is required for the voice prototype. The current Start flow requires it even when using the typed-question field. **Setup → Use iPhone audio for testing** explicitly allows phone audio when glasses are unavailable. Default operation requires a Bluetooth headset route. Bluetooth routing, SDK streaming, and speech recognition cannot be considered validated by a successful simulator build.

The large **Stop RayBridge** control stops the microphone, speech, camera, pending model answer, and Mac connection. It also cancels startup. Wait for camera teardown to finish before starting again. Each Start opens a new Mac conversation; previous transcript/answer text remains visible until you select **New conversation**. Backgrounding stops the session, except during the Meta AI camera-permission handoff; select **Start RayBridge** when returning. Background operation and a locked-phone experience are not implemented.

Start gives tactile feedback while the glasses play their own startup prompts. RayBridge speaks readiness once the camera and audio are prepared, then opens the microphone. It also speaks reconnection, stopped, and failure status. Temporary Mac/camera/audio disconnects trigger up to three retries, delayed by 2, 5, and 10 seconds, after recovery speech finishes, with each startup operation retaining its own timeout. A link must stay healthy for 30 seconds before its retry budget resets. Stop and backgrounding cancel recovery. Permission/configuration failures require user action. If recovery fails, resolve the stated issue and select **Start RayBridge** again. Registration and camera permission do not by themselves confirm a camera connection. RayBridge waits for asynchronous device selection before creating a session; discovery and compatibility failures now have specific messages. The Xcode marker `First glasses camera image received` confirms actual image delivery. A successful build alone does not validate the physical glasses connection.

If editing `ios/project.yml`, regenerate the project with `xcodegen generate --spec ios/project.yml`. Preserve your local development-team setting when regenerating; select your signing team again if it is reset.

## Xcode launch stalls and device logs

If Xcode reports that `libobjc.A.dylib` is being read from process memory and the app only opens after stopping the debugger, select the **RayBridge Device Logs** scheme beside the Run button, select your iPhone, and Run. This scheme uses a Debug build and captures console output without attaching LLDB. The normal **RayBridge** scheme still supports breakpoint debugging.

The app logs fixed lifecycle messages to the Xcode console and Apple's unified logging system (`org.raybridge.ios`, category `lifecycle`). A successful launch includes `App entry point reached`, `App model initialization finished`, and `Main screen appeared`. Questions, answers, camera images, and pairing credentials are not logged. Debug builds also write the markers to standard output for the terminal fallback below, so Xcode may show each marker twice.

On the development iPhone, the stalled debugger required Xcode to kill its LLDB RPC server. The Device Logs scheme then successfully reached the main screen and delivered logs to Xcode. This is a verified workaround for debugger startup, not a repair of LLDB's missing shared-cache data. Stopping a run ends its console session.

For normal debugging, connect the unlocked iPhone by USB, open **Window → Devices and Simulators**, and let Xcode finish preparing device/debugger support before retrying the normal scheme. Apple describes the warning and USB-versus-network diagnosis in [this developer support discussion](https://developer.apple.com/forums/thread/800067). Do not disable iPhone Wi-Fi; the app still needs it to reach the Mac bridge.

If Xcode's console is unavailable, stop its run and use the installed app with:

```sh
scripts/iphone-console.command "Your iPhone name"
```

This launches without LLDB and streams Debug-build stdout to the terminal. To view unified logs independently, open macOS Console, select the connected iPhone, start streaming, and filter for the RayBridge process/subsystem.

## Data and connection behavior

- Mac setup is served only on loopback port 8844. Phone traffic uses TLS on port 8845 and an unpredictable bearer token. The iPhone pins the Mac's certificate fingerprint from pairing; it does not globally disable certificate checks.
- One phone can connect at a time. **Disconnect and replace pairing link** revokes the old token and disconnects the phone. Re-pair if the Mac's address or certificate changes. IPv4 private LAN addresses are supported; Bonjour discovery and IPv6 are not implemented.
- Meta streams camera frames to the iPhone. The app samples up to one JPEG per second locally and retains the most recent one in memory. A question sends that frame to the Mac only if it is recent. The Mac keeps one frame and rejects stale visual context. Idle streaming does not continuously submit model turns.
- Audio is transcribed on the iPhone. Question text and an optional JPEG travel via the Mac to OpenAI through Codex. Text answers return to the iPhone and are spoken with Apple's speech synthesis.
- Codex uses an app-specific profile under `~/Library/Application Support/RayBridge/codex`, separate from any existing Codex login. Tokens and the local TLS key live in the parent RayBridge directory. The app never copies browser cookies or reads your existing Codex credentials.
- Conversations request ephemeral mode. RayBridge does not create recordings or transcript files. This is not a promise of zero retention by the OS, SDK, Codex diagnostics, or OpenAI; their applicable policies still govern data handling.
- The phone protocol cannot invoke arbitrary Codex methods. Shell, browser, plugin, and multi-agent features are disabled; unsolicited tool requests are rejected, and turns use restricted read-only access.

## Verification

```sh
npm test
npm run check
xcodebuild -project ios/RayBridge.xcodeproj -scheme RayBridge \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

Ten automated tests exercise authentication, admin-origin/Host protection, TLS/WebSocket transport, a simulated phone question/answer, token revocation, subscription enforcement, stale/missing images, overlapping questions, final-answer filtering, and disconnect cancellation. The Codex subprocess initialization/account-read smoke check also passed with a fresh signed-out profile.

After sign-in through the Mac UI, a live ChatGPT Plus test sent a generated blue rectangle containing a white 7 through the same Codex adapter and conversation handler. It correctly returned **“Blue 7”**, approximately 7 seconds after subprocess startup. This validates account authentication and image inference, not iPhone speech latency or physical glasses behavior. Mac UI launch/pairing-copy, the iPhone simulator build, and the unsigned physical-iPhone build passed. The runtime requires current named permission profiles; the retired `readOnly.access` field is not used.

See [hardware acceptance checks](docs/hardware-checks.md) before relying on the app. It is intended for descriptions and reading assistance; visual model answers can be mistaken, and this prototype is not a navigation or collision-avoidance system.

## Project layout

```text
bridge/       Local HTTPS phone bridge, Codex adapter, Mac setup UI, tests
mac/          Native AppKit/WebKit Mac wrapper
ios/          SwiftUI app, Meta DAT camera, speech, pinned connection, Keychain pairing
scripts/      Source launcher and Mac app builder
docs/         Architecture and physical-device acceptance checks
```

The remaining work to achieve the original fully real-time experience is substantial: validate the physical iPhone/glasses loop, measure its latency, improve streaming answer playback and interruption, and investigate a documented subscription-compatible real-time media interface if OpenAI provides one. This prototype does not claim that interface exists.

## iOS session lifecycle checks

On a Mac with Xcode installed, run `bash scripts/test-ios-session.sh`. The hardware-independent Swift tests cover startup ordering, waiting for camera readiness before audio, duplicate taps, full teardown, and Stop or failure during each startup stage. These checks do not replace physical-glasses testing.

For the unified Start/Stop flow, verify on the iPhone:

1. From a fresh launch with existing pairing/registration, tap **Start RayBridge** once. Confirm camera readiness and ask a visual question without any other connection controls.
2. Tap **Stop RayBridge** while listening or while an answer is pending/being spoken. Confirm the camera and audio stop, then Start again and ask another question.
3. Tap Stop during startup. Confirm it stays stopped after any outstanding permission dialog or SDK callback completes.
4. With the Mac temporarily unavailable, verify spoken reconnect feedback and automatic recovery after it becomes available. Then test Stop during the retry delay and retry exhaustion.
5. Open **Setup** while stopped and confirm pairing and registration are retained.

## Spoken feedback and recovery

Status uses VoiceOver when enabled and the app's speech output otherwise. The app keeps its audio route active between questions and answers, and releases it after camera teardown. Recovery speech finishes before camera startup resumes. The microphone pauses for status/answer speech; VoiceOver completion is observed before listening resumes, with a 15-second fallback if completion is missing. Connection-loss status can use the iPhone speaker if glasses audio is unavailable; model answers still require the configured audio route. Validate VoiceOver navigation and actual glasses routing on hardware.

While running, a one-second watchdog checks the latest usable image. Images must be less than 2.5 seconds old on the phone. Missing/stale frames pause questions and trigger recovery. The iPhone asks the Mac to require a fresh image as well, so expiration during account/thread preparation produces an explicit error rather than a text-only model request. Update both apps together for this behavior.

Recovery starts a new Mac session. It cancels any interrupted question and asks the user to repeat it; it never automatically resubmits a question. Test temporary Mac and glasses disconnects, repeated failures, Stop during recovery, no-image questions, and VoiceOver on/off before considering recovery hardware-verified.

Accessibility roadmap: [spoken status/recovery](https://github.com/soothslayer/RayBridge/issues/1), [repeat/interrupt controls](https://github.com/soothslayer/RayBridge/issues/2), [VoiceOver audit](https://github.com/soothslayer/RayBridge/issues/3), [Siri/Action button](https://github.com/soothslayer/RayBridge/issues/4), and [phone-in-pocket operation](https://github.com/soothslayer/RayBridge/issues/5).
