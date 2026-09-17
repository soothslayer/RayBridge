import Foundation

enum VoiceCommand: String, CaseIterable, Hashable {
    case start
    case stop
    case cancel
    case mute
    case unmute
}

// Commands must be short standalone utterances. This keeps phrases such as
// “Where is the bus stop?” and “How do I mute this?” available as questions.
enum VoiceCommandPolicy {
    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    static func command(in text: String) -> VoiceCommand? {
        guard words(text).count == 1 else { return nil }
        return words(text).first.flatMap(VoiceCommand.init(rawValue:))
    }
}
