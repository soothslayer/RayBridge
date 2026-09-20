import Foundation

enum VoiceCommand: String, CaseIterable, Hashable {
    case start
    case stop
    case cancel
    case mute
    case unmute
    case commands
}

// Commands must be short standalone utterances. This keeps phrases such as
// “Where is the bus stop?” and “How do I mute this?” available as questions.
enum VoiceCommandPolicy {
    static let launchAnnouncement =
        "RayBridge is stopped. Tap Start RayBridge, or say Start to begin. For a list of voice commands, say Commands."

    static let helpAnnouncement =
        "You can say Start when RayBridge is stopped. While RayBridge is running, say Stop to end it, Cancel to cancel the current question or answer, or Mute to ignore voice input. When muted, say Unmute to resume. Say Commands to hear this list again."

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    static func command(in text: String) -> VoiceCommand? {
        guard words(text).count == 1 else { return nil }
        return words(text).first.flatMap(VoiceCommand.init(rawValue:))
    }
}
