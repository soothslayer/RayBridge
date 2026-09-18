# RayBridge

A Mac + iPhone prototype that connects Meta Ray-Ban glasses to **Codex, Claude Code, or Hermes running on the Mac**. It uses the selected CLI's existing account and model configuration rather than requiring credentials in the iPhone app.

**This is a working development foundation, not a continuous live-video assistant.** It listens to a question, attaches a recent camera image from the glasses — or from the iPhone itself when the glasses are not connected — waits for the selected assistant's answer, and speaks that answer. The iPhone pauses question dictation while answering, listens for enabled voice controls, then returns to question dictation. Answers can use an installed Apple voice on the iPhone or the optional local Kokoro model on the Mac. A real ChatGPT Plus image question has passed; Claude Code and physical glasses validation are still required.

## Why this architecture

OpenAI documents subscription sign-in and image-containing conversation turns through the [Codex app server](https://learn.chatgpt.com/docs/app-server). Its documented interfaces give us a subscription-based path for questions and snapshots. That does **not** establish subscription access to the separate [Realtime API](https://developers.openai.com/api/docs/guides/realtime).

The project therefore preserves the subscription-only requirement, with a clear tradeoff: turn-based voice and per-question camera images instead of simultaneous speech and continuous model understanding of video. It creates new conversations; it does not import your existing ChatGPT chats, memories, or custom instructions. Subscription eligibility, available models, usage limits, and account policies apply. No latency target has been measured on real hardware.

## Open the Mac app

The local build is at `build/RayBridge.app`. Double-click it, or run:

```sh
open build/RayBridge.app
```

1. Choose **Codex**, **Claude Code**, or **Hermes** from the Assistant menu. For Codex, choose **Use this Mac’s Codex login** or complete the separate RayBridge sign-in. For Claude Code, first run `claude auth login` in Terminal. For Hermes, complete its setup and model selection on the Mac. RayBridge uses each CLI's existing configuration.
2. Keep the Mac and iPhone on the same private Wi-Fi network.
3. Leave RayBridge running and keep the Mac awake.
4. Pair the iPhone app using the QR code or pairing link. In the iPhone app's **Setup → Assistant** section, choose Codex, Claude Code, or Hermes before starting RayBridge. The choice is remembered and the Mac switches to it as the phone connects.

For the optional Kokoro answer voice, select **Download Kokoro voice** in the Mac app. This downloads the quantized model once to RayBridge's Application Support folder. Then choose **Kokoro on Mac** and a voice in the iPhone app under **Setup → Answer voice**. Kokoro generation runs locally on the Mac; if it is unavailable or fails, the iPhone reads the answer with the selected Apple voice.

The development app bundles the Node and Codex executables from the build machine. Claude Code and Hermes are discovered from their normal installations on the Mac. This build is for Apple Silicon and is ad-hoc signed, not notarized. It is not an installer ready for general distribution. Rebuild for another CPU architecture or older macOS deployment target. Do not run the source server and Mac app at the same time: both use ports 8844/8845.

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
5. In **Setup**, select **Register with Meta AI** and complete registration, then select **Done**. Ensure glasses audio is connected in iOS Bluetooth. To run without glasses entirely, skip this step and set **Setup → Camera and audio → Use** to **This iPhone**.
6. Select **Start RayBridge**. It connects to your saved Mac, checks microphone/speech permissions, starts the glasses camera, waits for a usable image, and begins listening. Grant camera access in Meta AI if requested, then return to RayBridge. Wait for **Glasses camera connected**, ask a question, pause, and wait for the spoken answer. On subsequent launches, just select **Start RayBridge**.

### Running without glasses

RayBridge does not require glasses. If the glasses are not registered, not found, not connected, still connecting, or need an update, **Start RayBridge** warns that the glasses aren’t connected and offers three choices: **Continue without glasses**, **Try glasses anyway**, and **Cancel**. The warning is posted to VoiceOver and, when VoiceOver is off, spoken aloud; in hands-free standby, saying “start” continues without glasses and “cancel” dismisses the warning. If the glasses camera or glasses audio instead fails partway through startup, the same offer appears with the underlying failure.

Continuing without glasses uses this iPhone's back camera for question images and the iPhone for speech, cues, and answers. Images keep the same limits as the glasses path: one JPEG per second, at most 500 KB, and a question still requires an image no more than 2.5 seconds old. Point the back of the iPhone at what you want described. Answers play through the iPhone speaker, or through any headset connected to the iPhone.

**Setup → Camera and audio** makes the choice permanent in either direction. **This iPhone** skips the glasses check, the warning, and Meta registration entirely, which is the mode to use if you do not own the glasses. **Meta glasses** restores the default. Granting RayBridge iPhone camera access is requested the first time this mode starts. A locked or backgrounded phone still suspends the session, and this mode is not hands-free: the iPhone has to be pointed by hand.

English (US) **on-device** speech recognition is required for the voice prototype. If it is unavailable, typed questions still work. **Setup → Use iPhone audio for testing** explicitly allows phone audio when glasses are unavailable. Default operation requires a Bluetooth headset route. Bluetooth routing, SDK streaming, and speech recognition cannot be considered validated by a successful simulator build.

**Setup → Sound cues → Listen for voice commands** is on by default. Say “start” to begin from hands-free standby, “stop” to end RayBridge, or “cancel” during thinking or speech to abandon the current turn and return to listening. “Mute” lets the current turn and answer continue while ignoring everything except “unmute.” RayBridge immediately speaks a short confirmation for every recognized command. Mute and Unmute briefly pause a playing Apple or Kokoro answer for the confirmation, then resume it. Commands must be spoken as standalone words, which preserves questions such as “Where is the bus stop?” **Listen for Start while stopped** is also on by default and keeps the microphone active for Start while RayBridge is stopped. All voice commands require RayBridge to remain open in the foreground; they do not provide background or locked-phone listening. Cancel cannot undo computer actions Codex already completed. Echo suppression and command recognition must be validated on the actual glasses.

Without glasses, the microphone, speech, and camera all belong to the iPhone, so a disconnected Bluetooth headset no longer stops the session. The **Use iPhone audio for testing** toggle remains for testing the glasses camera with iPhone audio.

The large **Stop RayBridge** control stops the microphone, speech, camera, pending model answer, and Mac connection. It also cancels startup. Wait for camera teardown to finish before starting again. Each Start opens a new Mac conversation; previous transcript/answer text remains visible until you select **New conversation**. Backgrounding stops the session, except during the Meta AI camera-permission handoff; select **Start RayBridge** when returning. Background operation and a locked-phone experience are not implemented.

If startup fails, RayBridge stops any partially started camera/audio/connection and displays the error. Select **Start RayBridge** to retry once the underlying issue is resolved. Registration and camera permission do not by themselves confirm a camera connection. RayBridge waits for asynchronous device selection before creating a session; discovery and compatibility failures now have specific messages. The Xcode marker `First glasses camera image received` confirms actual image delivery. A successful build alone does not validate the physical glasses connection.

Errors are also spoken after teardown finishes. RayBridge uses the glasses audio route when available and falls back to the iPhone speaker when the glasses are disconnected. With VoiceOver running, the error is posted as a VoiceOver announcement instead of starting a second voice at the same time.

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

## TestFlight archive checks

Use the **RayBridge** scheme for archives; **RayBridge Device Logs** disables archiving. The app includes an opaque AppIcon asset catalog for iPhone, iPad, and the App Store. Xcode generates the icon Info.plist entries from that catalog. The iPad-specific orientation list supports all four orientations for multitasking.

Xcode Cloud runs `ios/ci_scripts/ci_post_xcodebuild.sh` after archiving to check the actual app bundle for the required icon metadata, 120×120 and 152×152 PNGs, and iPad orientations. For a local archive, run:

```sh
python3 scripts/verify-ios-archive.py path/to/RayBridge.xcarchive
```

The source build number is 2 (version 0.1.0). Xcode Cloud may assign its own higher build number. Each uploaded build needs a new number. Icon artwork can be regenerated from the repository root with `swift scripts/generate-app-icon.swift`.

These checks cover the validation failures reported for build 1; they do not replace App Store Connect processing, signing validation, or glasses testing.

## Data and connection behavior

- Mac setup is served only on loopback port 8844. Phone traffic uses TLS on port 8845 and an unpredictable bearer token. The iPhone pins the Mac's certificate fingerprint from pairing; it does not globally disable certificate checks.
- One phone can connect at a time. **Disconnect and replace pairing link** revokes the old token and disconnects the phone. Re-pair if the Mac's address or certificate changes. IPv4 private LAN addresses are supported; Bonjour discovery and IPv6 are not implemented.
- Meta streams camera frames to the iPhone. The app samples up to one JPEG per second locally and retains the most recent one in memory. A question sends that frame to the Mac only if it is recent. The Mac keeps one frame and rejects stale visual context. Idle streaming does not continuously submit model turns.
- Audio is transcribed on the iPhone. Question text and an optional JPEG travel to the selected assistant through its Mac CLI. That CLI's configured model provider receives the request; Hermes may use a local or hosted model depending on its Mac configuration. Answers return as text for Apple speech or, when selected, as audio generated locally by Kokoro on the Mac. The Kokoro model is downloaded from Hugging Face and does not receive the question or answer over a hosted speech API.
- By default, Codex uses an app-specific profile under `~/Library/Application Support/RayBridge/codex` and remains a restricted visual assistant. **Use this Mac’s Codex login** starts a separate app-server connection that reuses the login and normal configuration in `CODEX_HOME` or `~/.codex`, including memories, tools, plugins, MCP servers, browser, and computer use. Local mode defaults its working folder to the Mac user’s home folder; change it on the Mac setup page to narrow file access. The same page lists installed apps so the user can explicitly choose which ones spoken Computer Use requests may operate. Saved choices apply to new phone sessions. Turns use a writable workspace sandbox with network access and automatic approval review. Direct requests that still require a person at the Mac are declined. RayBridge chooses the newest working Codex executable installed with ChatGPT, Codex, or the CLI, then falls back to its bundled executable. Set `RAYBRIDGE_LOCAL_CODEX` to force an executable or `RAYBRIDGE_WORKSPACE` to set the initial working folder. RayBridge never reads or copies credentials, does not attach to another client’s live transport or conversation, and cannot sign the shared account out. The local TLS key remains in the RayBridge application-support directory.
- RayBridge does not create audio recordings or its own transcript files. Codex's separate-login conversations request ephemeral mode. Local Codex, Claude Code, and Hermes may retain session history under their normal Mac configuration. Their configured model providers and applicable policies govern remote retention.
- The phone protocol cannot invoke arbitrary Codex methods. The separate-login mode disables shell, browser, plugin, computer-use, and multi-agent features and uses read-only access. Local mode lets Codex itself choose and run the capabilities already configured on the Mac; the phone still sends only camera frames, questions, cancellation, and reset messages.

## Verification

```sh
npm test
npm run check
xcodebuild -project ios/RayBridge.xcodeproj -scheme RayBridge \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

Automated tests exercise authentication, admin-origin/Host protection, TLS/WebSocket transport, a simulated phone question/answer, token revocation, subscription enforcement, stale/missing images, overlapping questions, final-answer filtering, disconnect cancellation, Kokoro installation, audio delivery, Apple fallback, and cancellation races during turn startup and audio generation. The Codex subprocess initialization/account-read smoke check also passed with a fresh signed-out profile.

After sign-in through the Mac UI, a live ChatGPT Plus test sent a generated blue rectangle containing a white 7 through the same Codex adapter and conversation handler. It correctly returned **“Blue 7”**, approximately 7 seconds after subprocess startup. This validates account authentication and image inference, not iPhone speech latency or physical glasses behavior. Mac UI launch/pairing-copy, the iPhone simulator build, and the unsigned physical-iPhone build passed. The runtime requires current named permission profiles; the retired `readOnly.access` field is not used.

See [hardware acceptance checks](docs/hardware-checks.md) before relying on the app. It is intended for descriptions and reading assistance; visual model answers can be mistaken, and this prototype is not a navigation or collision-avoidance system.

## Project layout

```text
bridge/       Local HTTPS phone bridge, assistant adapters, Mac setup UI, tests
mac/          Native AppKit/WebKit Mac wrapper
ios/          SwiftUI app, Meta DAT and iPhone cameras, speech, pinned connection, Keychain pairing
scripts/      Source launcher and Mac app builder
docs/         Architecture and physical-device acceptance checks
```

The remaining work to achieve the original fully real-time experience is substantial: validate the physical iPhone/glasses loop, measure its latency, improve streaming answer playback and interruption, and investigate a documented subscription-compatible real-time media interface if OpenAI provides one. This prototype does not claim that interface exists.

## iOS session lifecycle checks

On a Mac with Xcode installed, run `bash scripts/test-ios-session.sh`. The hardware-independent Swift tests cover startup ordering, waiting for camera readiness before audio, duplicate taps, full teardown, and Stop or failure during each startup stage. `bash scripts/test-ios-capture-source.sh` covers the no-glasses decisions: which glasses states warn, which actions each warning offers, the saved iPhone preference, and which startup failures offer the iPhone instead. These checks do not replace physical-glasses testing.

For the unified Start/Stop flow, verify on the iPhone:

1. From a fresh launch with existing pairing/registration, tap **Start RayBridge** once. Confirm camera readiness and ask a visual question without any other connection controls.
2. Tap **Stop RayBridge** while listening or while an answer is pending/being spoken. Confirm the camera and audio stop, then Start again and ask another question.
3. Tap Stop during startup. Confirm it stays stopped after any outstanding permission dialog or SDK callback completes.
4. With the Mac unavailable, verify startup reports the connection error and allows a fresh Start after the Mac is available.
5. Open **Setup** while stopped and confirm pairing and registration are retained.
6. With the glasses off or disconnected, tap **Start RayBridge**. Confirm the spoken and VoiceOver warning, then **Continue without glasses** and ask a visual question about what the iPhone's back camera sees.
7. Set **Setup → Camera and audio → Use** to **This iPhone**, relaunch, and confirm Start goes straight to the iPhone camera with no warning and no registration requirement.
8. With the glasses connected, confirm Start still uses them and that the camera confirmation says **Glasses camera connected**.
