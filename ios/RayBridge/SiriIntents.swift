import AppIntents

// App Intents are created by the system, while SwiftUI owns the live AppModel.
// Keep only a weak bridge to that model and queue an early invocation until the
// main scene has attached it during launch.
@MainActor
final class RayBridgeIntentCoordinator {
    static let shared = RayBridgeIntentCoordinator()

    private weak var model: AppModel?
    private var startPending = false

    private init() {}

    func attach(_ model: AppModel) {
        self.model = model
        guard startPending else { return }
        startPending = false
        model.startFromSystemRequest()
    }

    @discardableResult
    func requestStart() -> Bool {
        guard let model else {
            startPending = true
            return true
        }
        guard !model.sessionActive else { return false }
        model.startFromSystemRequest()
        return true
    }
}

struct StartRayBridgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start RayBridge"
    static let description = IntentDescription(
        "Open RayBridge and start its camera, microphone, and Mac connection."
    )

    // RayBridge needs its foreground app process for the Meta session, camera,
    // microphone, permission prompts, and any setup choice that needs attention.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let requested = RayBridgeIntentCoordinator.shared.requestStart()
        return .result(dialog: requested
            ? "Starting RayBridge."
            : "RayBridge is already running.")
    }
}

struct RayBridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRayBridgeIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Connect \(.applicationName)"
            ],
            shortTitle: "Start RayBridge",
            systemImageName: "play.circle.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .teal }
}
