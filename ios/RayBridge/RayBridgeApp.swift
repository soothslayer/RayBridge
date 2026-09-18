import SwiftUI

@main
struct RayBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    init() {
        RayBridgeDiagnostics.event("App entry point reached")
    }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    RayBridgeDiagnostics.event("Main screen appeared")
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
                        if model.sessionActive { model.stop() } else { model.start() }
                    } label: {
                        Label(model.sessionPhase == .stopping ? "Stopping…" : model.sessionActive ? "Stop RayBridge" : "Start RayBridge", systemImage: model.sessionActive ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 76)
                    }.buttonStyle(.borderedProminent).tint(green)
                        .disabled(model.sessionPhase == .stopping)
                        .accessibilityHint(model.sessionActive ? "Stops the camera, microphone, speech, and Mac connection." : "Connects to your Mac and the glasses camera, or offers this iPhone when the glasses aren’t connected, then starts listening for your question.")
                    if let error = model.error { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
                    Text(model.cameraStatus).accessibilityLabel("Camera status: \(model.cameraStatus)")
                    Text("Tap Start RayBridge, wait for the camera confirmation, then ask your question. Stop RayBridge ends the entire session. If your glasses aren’t connected, RayBridge offers to continue with this iPhone’s camera and speaker.").font(.body)
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
                    Text("Early prototype. Uses the assistant selected in Setup. Answers take turns and may be delayed. Keep this app open and the Mac awake.").font(.footnote)
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
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Set up your Mac and glasses once. After that, use Start RayBridge on the main screen.")
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }
                Section("Your Mac") {
                    if let host = model.pairedHost { Text("Paired Mac: \(host)") }
                    Text("Open RayBridge on your Mac and copy its pairing link, or scan its QR code with the iPhone Camera.")
                    SecureField("Paste pairing link", text: $model.pairingText)
                        .textContentType(.none).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Pair Mac") { model.pair() }
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
                         ? "RayBridge uses the glasses camera and glasses audio. If the glasses aren’t connected when you start, it warns you and offers to continue with this iPhone instead."
                         : "RayBridge uses this iPhone’s camera, speaker, and microphone. Glasses are not needed, and registration is not required. Point the back of the iPhone at what you want described.")
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
                }
                Section("Camera images") {
                    Toggle("Send camera image with every question", isOn: $model.alwaysSendCameraImage)
                        .disabled(model.sessionActive)
                        .accessibilityHint("When off, RayBridge sends an image only when your question appears to ask about your surroundings. Say use the camera to always include one.")
                    Text(model.alwaysSendCameraImage
                         ? "Every question includes a current image from the glasses camera."
                         : "RayBridge sends an image only for questions that appear visual. Say “use the camera” to always include one.")
                }
                Section("Sound cues") {
                    Toggle("Listen for voice commands", isOn: $model.voiceCommandsEnabled)
                        .disabled(model.sessionActive)
                        .accessibilityHint("Enables Start, Stop, Cancel, Mute, and Unmute voice commands while RayBridge is in the foreground.")
                    Toggle("Listen for Start while stopped", isOn: $model.handsFreeStandbyEnabled)
                        .disabled(model.sessionActive || !model.voiceCommandsEnabled)
                        .accessibilityHint("Keeps the microphone ready for the Start command while RayBridge is stopped and this app is open.")
                    Text("Voice commands work only while this app is open. Start begins a session. Stop ends it. Cancel interrupts the current request or answer. Mute lets the current turn finish but ignores everything except Unmute. Standby keeps the microphone active while stopped so Start remains hands-free.")
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
            .navigationTitle("Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
