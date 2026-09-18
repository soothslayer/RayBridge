import Foundation

// The Mac offers each finished sentence of an answer while the assistant is
// still writing the rest, so part of a completed answer has usually been spoken
// already. The assistant can also replace what it was writing, so a completed
// answer is only continued when it still begins with everything spoken so far.
enum AnswerSpeech: Equatable {
    case whole(String)
    case remainder(String)
    case nothing
}

enum AnswerStreamPolicy {
    static func speech(completed: String, alreadySpoken: String) -> AnswerSpeech {
        guard !alreadySpoken.isEmpty else { return .whole(completed) }
        guard completed.hasPrefix(alreadySpoken) else { return .whole(completed) }
        let remainder = String(completed.dropFirst(alreadySpoken.count))
        return remainder.isEmpty ? .nothing : .remainder(remainder)
    }
}
