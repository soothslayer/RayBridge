import SwiftUI

@main
struct RayBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { model.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    // Allow Meta AI registration handoffs; suspend active conversations on backgrounding.
                    if phase == .background && (model.running || model.cameraActive) { model.suspend() }
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
                        if model.running || model.busy { model.stop() } else { model.start() }
                    } label: {
                        Label(model.running || model.busy ? "Stop" : "Start listening", systemImage: model.running || model.busy ? "stop.circle.fill" : "mic.fill")
                            .font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 76)
                    }.buttonStyle(.borderedProminent).tint(green)
                        .disabled(!model.connected)
                        .accessibilityHint("Listens for a question, then speaks the answer through your connected glasses. Listening pauses while the answer is spoken.")
                    if let error = model.error { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
                    GroupBox("Glasses") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(model.cameraStatus)
                            Button("Register with Meta AI") { model.registerGlasses() }
                            Button(model.cameraActive || model.cameraStarting ? "Stop glasses camera" : "Connect glasses camera") { model.toggleCamera() }.disabled(model.cameraStopping)
                            Text("The camera is sampled when you ask a question.").font(.footnote)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Your Mac") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let host = model.pairedHost {
                                Text("Paired Mac: \(host)")
                                Button(model.connected ? "Reconnect Mac" : "Connect Mac") { model.connect() }
                            }
                            SecureField("Paste pairing link", text: $model.pairingText)
                                .textContentType(.none).autocorrectionDisabled().textInputAutocapitalization(.never)
                            Button("Pair Mac") { model.pair() }.disabled(model.pairingText.isEmpty)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Conversation") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !model.transcript.isEmpty { Text("You: \(model.transcript)") }
                            if !model.answer.isEmpty { Text(model.answer).textSelection(.enabled) }
                            TextField("Type a question", text: $model.typedQuestion, axis: .vertical)
                            Button("Ask") { model.ask(model.typedQuestion); model.typedQuestion = "" }
                                .disabled(!model.connected || model.busy || model.typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("New conversation") { model.reset() }.disabled(!model.connected)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    Toggle("Use iPhone audio for testing", isOn: $model.phoneAudio).disabled(model.running || model.busy)
                    Text("Early prototype. Uses your ChatGPT subscription through Codex. Answers take turns and may be delayed. Keep this app open and the Mac awake.").font(.footnote)
                }.padding(22)
            }
            .background(Color(red: 0.97, green: 0.98, blue: 0.95))
            .navigationTitle("RayBridge").navigationBarTitleDisplayMode(.inline)
            .buttonStyle(.bordered).controlSize(.large)
        }.tint(green)
    }
}
