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
                .onAppear { RayBridgeDiagnostics.event("Main screen appeared") }
                .onOpenURL { model.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    // Preserve a camera permission handoff; otherwise stop on backgrounding.
                    if phase == .background { model.background() }
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
                        .accessibilityHint(model.sessionActive ? "Stops the camera, microphone, speech, and Mac connection." : "Connects to your Mac and glasses camera, then starts listening for your question.")
                    if let error = model.error { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
                    Text(model.cameraStatus).accessibilityLabel("Camera status: \(model.cameraStatus)")
                    Text("Tap Start RayBridge, wait for the camera confirmation, then ask your question. Stop RayBridge ends the entire session.").font(.body)
                    GroupBox("Conversation") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !model.transcript.isEmpty { Text("You: \(model.transcript)") }
                            if !model.answer.isEmpty { Text(model.answer).textSelection(.enabled) }
                            TextField("Type a question", text: $model.typedQuestion, axis: .vertical)
                            Button("Ask") { model.ask(model.typedQuestion); model.typedQuestion = "" }
                                .disabled(!model.running || model.busy || model.typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("New conversation") { model.reset() }.disabled(model.sessionPhase == .stopping)
                                .accessibilityHint("Stops RayBridge and clears this conversation. Tap Start RayBridge to begin a new one.")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    Text("Early prototype. Uses your ChatGPT subscription through Codex. Answers take turns and may be delayed. Keep this app open and the Mac awake.").font(.footnote)
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
                    Text("Pair your glasses in Meta AI, enable Developer Mode, and complete any installation it offers. Camera permission is requested when you first start RayBridge.")
                }
                Section("Camera images") {
                    Toggle("Send camera image with every question", isOn: $model.alwaysSendCameraImage)
                        .disabled(model.sessionActive)
                        .accessibilityHint("When off, RayBridge sends an image only when your question appears to ask about your surroundings. Say use the camera to always include one.")
                    Text(model.alwaysSendCameraImage
                         ? "Every question includes a current image from the glasses camera."
                         : "RayBridge sends an image only for questions that appear visual. Say “use the camera” to always include one.")
                }
                Section("Answer voice") {
                    Picker("Voice", selection: $model.speechVoiceIdentifier) {
                        ForEach(model.speechVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .disabled(model.sessionActive || model.speechVoices.isEmpty)
                    .accessibilityHint("Selects the voice used for Codex answers and RayBridge announcements.")
                    Button("Preview selected voice") { model.previewSpeechVoice() }
                        .disabled(model.sessionActive || model.speechVoiceIdentifier.isEmpty)
                        .accessibilityHint("Plays a short sample through connected glasses, or through the iPhone when glasses audio is unavailable.")
                    Text("Premium and enhanced U.S. English voices appear first when installed. Additional voices are managed in iPhone Accessibility settings. Reopen Setup after downloading a voice.")
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
