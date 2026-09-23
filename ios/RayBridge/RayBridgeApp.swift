import SwiftUI

@main
struct RayBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    init() {
        RayBridgeDiagnostics.event("App entry point reached")
        RayBridgeShortcuts.updateAppShortcutParameters()
    }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    RayBridgeDiagnostics.event("Main screen appeared")
                    RayBridgeIntentCoordinator.shared.attach(model)
                    model.foreground()
                }
                .onOpenURL { model.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    // Preserve a camera permission handoff; otherwise stop on backgrounding.
                    if phase == .background { model.background() }
                    else if phase == .active { model.foreground() }
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    private let green = Color(red: 0.12, green: 0.35, blue: 0.29)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Your world, in words.").font(.largeTitle.bold())
                    Text(model.status).font(.title3).accessibilityLabel("Assistant status: \(model.status)")
                    Button {
                        if model.sessionActive { model.stopFromButton() } else { model.startFromButton() }
                    } label: {
                        Label(model.sessionPhase == .stopping ? "Stopping…" : model.sessionActive ? "Stop RayBridge" : "Start RayBridge", systemImage: model.sessionActive ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 76)
                    }.buttonStyle(.borderedProminent).tint(green)
                        .disabled(model.sessionPhase == .stopping)
                        .accessibilityHint(model.sessionActive ? "Stops the camera, microphone, speech, and Mac connection." : "Connects to your Mac and the glasses camera, or offers this iPhone when the glasses aren’t connected, then starts listening for your question.")
                    if let error = model.error { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
                    Text(model.cameraStatus).accessibilityLabel("Camera status: \(model.cameraStatus)")
                    Text("Tap Start RayBridge or ask Siri to start RayBridge, wait for the camera confirmation, then ask your question. Stop RayBridge ends the entire session. If your glasses aren’t connected, RayBridge offers to continue with this iPhone’s camera and speaker.").font(.body)
                    GroupBox("Conversation") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !model.transcript.isEmpty { Text("You: \(model.transcript)") }
                            if !model.answer.isEmpty { Text(model.answer).textSelection(.enabled) }
                            TextField("Type a question", text: $model.typedQuestion, axis: .vertical)
                            Button("Ask") { model.ask(model.typedQuestion); model.typedQuestion = "" }
                                .disabled(!model.running || model.muted || model.busy || model.typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("New conversation") { model.reset() }.disabled(model.sessionPhase == .stopping)
                                .accessibilityHint("Stops RayBridge and clears this conversation. Tap Start RayBridge to begin a new one.")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    Text("Camera: \(model.preferredCaptureSource.displayName). Active sessions continue while this iPhone is locked. The built-in iPhone camera pauses in the background, but voice questions and answers remain available. The Mac must remain awake.").font(.footnote)
                }.padding(22)
            }
            .background(Color(red: 0.97, green: 0.98, blue: 0.95))
            .navigationTitle("RayBridge").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Setup") { model.showingSetup = true }
                        .disabled(model.sessionActive)
                        .accessibilityHint("Pair your Mac, register your glasses, or change the test audio setting.")
                }
            }
            .alert(Text(model.glassesWarning?.title ?? ""),
                   isPresented: Binding(get: { model.glassesWarning != nil },
                                        set: { if !$0 { model.dismissGlassesWarning() } }),
                   presenting: model.glassesWarning) { warning in
                if warning.actions.contains(.continueWithoutGlasses) {
                    Button("Continue without glasses") { model.continueWithoutGlasses() }
                }
                if warning.actions.contains(.tryGlassesAnyway) {
                    Button("Try glasses anyway") { model.tryGlassesAnyway() }
                }
                if warning.actions.contains(.openSetup) {
                    Button("Open Setup") { model.dismissGlassesWarning(); model.showingSetup = true }
                }
                Button("Cancel", role: .cancel) { model.dismissGlassesWarning() }
            } message: { warning in
                Text(warning.message)
            }
            .sheet(isPresented: $model.showingSetup) { SetupView(model: model) }
            .buttonStyle(.bordered).controlSize(.large)
        }.tint(green)
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var directoryPairing: Pairing?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Set up your Mac and glasses once. After that, use Start RayBridge on the main screen.")
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
                Section("Saved Macs") {
                    if model.pairedMacs.isEmpty {
                        Text("No saved Macs are available. Pair this phone again to add one.")
                    } else {
                        ForEach(model.pairedMacs) { pairing in
                            Button {
                                model.selectPairedMac(id: pairing.id)
                            } label: {
                                HStack {
                                    Text(pairing.displayName)
                                    Spacer()
                                    if pairing.id == model.selectedPairingID {
                                        Image(systemName: "checkmark").accessibilityLabel("Selected")
                                    }
                                }
                            }
                            .disabled(model.sessionActive || pairing.id == model.selectedPairingID)
                            .accessibilityHint("Selects this Mac for the next RayBridge session.")
                        }
                        Text("RayBridge remembers the five most recently paired Macs. The checkmark identifies the active Mac.")
                    }
                    Text(model.pairedMacs.isEmpty
                         ? "Open RayBridge on your Mac and copy its pairing link, or scan its QR code with the iPhone Camera."
                         : "To add or refresh a Mac, copy its pairing link or scan its QR code with the iPhone Camera.")
                    SecureField("Paste pairing link", text: $model.pairingText)
                        .textContentType(.none).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button(model.pairedMacs.isEmpty ? "Pair Mac" : "Add Mac") { model.pair() }
                        .disabled(model.pairingText.isEmpty || model.sessionActive)
                }
                Section("Your glasses") {
                    Text(model.registrationStatus.isEmpty ? "Register your glasses to begin." : model.registrationStatus)
                    Button("Register with Meta AI") { model.registerGlasses() }
                        .disabled(model.sessionActive || model.registeringGlasses || !model.registrationStatus.isEmpty)
                    Text("Pair your glasses in Meta AI, enable Developer Mode, and complete any installation it offers. Camera permission is requested when you first start RayBridge. Registration is only needed for the glasses camera; RayBridge also runs on this iPhone alone.")
                }
                Section("Camera and audio") {
                    Picker("Use", selection: $model.preferredCaptureSource) {
                        ForEach(CaptureSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .disabled(model.sessionActive)
                    .accessibilityHint("Selects whether RayBridge uses the glasses camera and glasses audio, or this iPhone’s camera and speaker.")
                    Text(model.preferredCaptureSource == .glasses
                         ? "RayBridge uses the glasses camera and glasses audio. An active session continues when this iPhone is locked or another app is open. If the glasses aren’t connected when you start, RayBridge offers to continue with this iPhone instead."
                         : "RayBridge uses this iPhone’s camera, speaker, and microphone. Glasses are not needed, and registration is not required. Point the back camera at what you want described. When iOS cannot keep the camera active in the background, RayBridge pauses only the camera: voice questions, commands, Mac connection, and answers continue, and the camera restarts when you return.")
                }
                Section("Build") {
                    Text(Self.buildDescription)
                    Text("Meta glasses keep camera images available in the background. This iPhone keeps the voice session available and restores its camera when RayBridge returns to the foreground.")
                }
                Section("Assistant") {
                    Picker("Assistant", selection: $model.assistantProvider) {
                        ForEach(AssistantProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .disabled(model.sessionActive)
                    .accessibilityHint("Selects which signed-in assistant on your paired Mac answers your questions.")
                    Text("The assistants run through their command-line tools on your Mac. Configure each one there first, then you can switch here before starting RayBridge.")
                    TextField("Optional Mac working folder", text: $model.workingFolder)
                        .textContentType(.none).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .disabled(model.sessionActive || model.selectedPairingID.isEmpty)
                        .accessibilityHint("Enter an absolute folder path on the selected Mac, or leave it blank to use the folder configured on that Mac.")
                    Button {
                        directoryPairing = model.pairedMacs.first { $0.id == model.selectedPairingID }
                    } label: {
                        Label("Browse Mac folders", systemImage: "folder")
                    }
                    .disabled(model.sessionActive || model.selectedPairingID.isEmpty)
                    .accessibilityHint("Opens a list of folders inside the selected Mac’s home folder.")
                    Button("Save working folder") { model.saveWorkingFolder() }
                        .disabled(model.sessionActive || model.selectedPairingID.isEmpty)
                    Text("Browse folders on the selected Mac, or enter an absolute path manually. This setting is saved separately for each paired Mac. Leave it blank to keep using that Mac’s current RayBridge working folder. Changing it starts a new assistant conversation the next time RayBridge connects.")
                }
                Section("Camera images") {
                    Toggle("Send camera image with every question", isOn: $model.alwaysSendCameraImage)
                        .disabled(model.sessionActive)
                        .accessibilityHint("When off, RayBridge sends an image only when your question appears to ask about your surroundings. Say use the camera to always include one.")
                    Text(model.alwaysSendCameraImage
                         ? "Every question includes a current image from the selected camera."
                         : "RayBridge sends an image only for questions that appear visual. Say “use the camera” to always include one.")
                }
                Section("Sound cues") {
                    Toggle("Listen for voice commands", isOn: $model.voiceCommandsEnabled)
                        .disabled(model.sessionActive)
                        .accessibilityHint("Enables Start, Stop, Cancel, Status, Repeat, Mute, Unmute, and Commands voice commands. Active glasses sessions continue in the background.")
                    Toggle("Listen for Start while stopped", isOn: $model.handsFreeStandbyEnabled)
                        .disabled(model.sessionActive || !model.voiceCommandsEnabled)
                        .accessibilityHint("Keeps the microphone ready for the Start and Commands commands while RayBridge is stopped and this app is open.")
                    Text("Start begins a session. Stop ends it. Cancel interrupts the current request or answer. Status reports whether a task is running. Repeat speaks the latest completed answer again. Mute lets the current turn finish but listens only for Unmute and Commands. Say Commands to hear the available choices. Stopped-app standby works only while RayBridge is open; voice commands in an active Meta-glasses session continue while locked or in another app.")
                    Toggle("Play heartbeat while the assistant is thinking", isOn: $model.thinkingHeartbeatEnabled)
                        .disabled(model.sessionActive)
                        .accessibilityHint("When on, a soft repeating heartbeat plays after your question until the answer is ready.")
                    Text(model.thinkingHeartbeatEnabled
                         ? "The listening chimes and thinking heartbeat are enabled."
                         : "Listening chimes remain enabled, but the thinking heartbeat is off.")
                }
                Section("Answer voice") {
                    Picker("Voice system", selection: $model.answerVoiceEngine) {
                        ForEach(AnswerVoiceEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .disabled(model.sessionActive)
                    .accessibilityHint("Selects whether assistant answers use Apple speech on this iPhone or the local Kokoro model on your Mac.")
                    if model.answerVoiceEngine == .apple {
                        Picker("Apple voice", selection: $model.speechVoiceIdentifier) {
                            ForEach(model.speechVoices) { voice in
                                Text(voice.displayName).tag(voice.id)
                            }
                        }
                        .disabled(model.sessionActive || model.speechVoices.isEmpty)
                        Button("Preview selected voice") { model.previewSpeechVoice() }
                            .disabled(model.sessionActive || model.speechVoiceIdentifier.isEmpty)
                            .accessibilityHint("Plays a short sample through connected glasses, or through the iPhone when glasses audio is unavailable.")
                        Text("Premium and enhanced U.S. English voices appear first when installed. Additional voices are managed in iPhone Accessibility settings. Reopen Setup after downloading a voice.")
                    } else {
                        Picker("Kokoro voice", selection: $model.kokoroVoiceIdentifier) {
                            ForEach(model.kokoroVoices) { voice in
                                Text(voice.displayName).tag(voice.id)
                            }
                        }
                        .disabled(model.sessionActive)
                        Text("Kokoro runs privately on your Mac. Open the RayBridge Mac app and download the Kokoro model before starting. If it is unavailable, answers use the selected Apple voice automatically.")
                    }
                }
                Section("Testing") {
                    Toggle("Use iPhone audio for testing", isOn: $model.phoneAudio)
                        .disabled(model.sessionActive)
                }
            }
            .onAppear { model.refreshSpeechVoices() }
            .sheet(item: $directoryPairing) { pairing in
                DirectoryPickerView(pairing: pairing) { path in
                    model.workingFolder = path
                    directoryPairing = nil
                }
            }
            .navigationTitle("Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static var buildDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "RayBridge \(version) (\(build))"
    }
}

struct DirectoryPickerView: View {
    let pairing: Pairing
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DirectoryBrowserScreen(pairing: pairing, path: "", onSelect: onSelect)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

struct DirectoryBrowserScreen: View {
    let pairing: Pairing
    let path: String
    let onSelect: (String) -> Void
    @State private var result: DirectoryBrowseResult?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading { ProgressView("Loading folders…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if let result {
                Section {
                    Button { onSelect(result.path) } label: {
                        Label("Use this folder", systemImage: "checkmark.circle")
                    }
                    .accessibilityHint("Selects \(result.path) as the working folder.")
                }
                if result.directories.isEmpty {
                    Text("No subfolders").foregroundStyle(.secondary)
                } else {
                    Section("Folders") {
                        ForEach(result.directories, id: \.self) { name in
                            NavigationLink(name) {
                                DirectoryBrowserScreen(pairing: pairing,
                                                       path: childPath(base: result.path, name: name),
                                                       onSelect: onSelect)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(result.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Mac folders")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func childPath(base: String, name: String) -> String {
        URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(name).path
    }

    private func load() async {
        isLoading = true; errorMessage = nil
        do { result = try await pairing.browseDirectories(path: path) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}
