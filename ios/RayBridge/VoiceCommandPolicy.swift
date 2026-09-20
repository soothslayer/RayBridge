import Foundation

enum VoiceCommand: String, CaseIterable, Hashable {
    case start
    case stop
    case cancel
    case mute
    case unmute
    case status
    case `repeat`
    case commands
}

// Commands must be short standalone utterances. This keeps phrases such as
// “Where is the bus stop?” and “How do I mute this?” available as questions.
enum VoiceCommandPolicy {
    static let launchAnnouncement =
        "RayBridge is stopped. Tap Start RayBridge, or say Start to begin. For a list of voice commands, say Commands."

    // Each phrase is spoken as its own utterance so command names do not run
    // together. SpeechController adds a short pause after every phrase.
    static let helpAnnouncementPhrases = [
        "Say Start when RayBridge is stopped.",
        "Say Stop to end RayBridge.",
        "Say Cancel to cancel the current question or answer.",
        "Say Status to hear the current task status.",
        "Say Repeat to hear the latest completed answer again.",
        "Say Mute to ignore voice input.",
        "When muted, say Unmute to resume.",
        "Say Commands to hear this list again."
    ]

    static let helpAnnouncement = helpAnnouncementPhrases.joined(separator: " ")

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    static func command(in text: String) -> VoiceCommand? {
        guard words(text).count == 1 else { return nil }
        return words(text).first.flatMap(VoiceCommand.init(rawValue:))
    }
}
