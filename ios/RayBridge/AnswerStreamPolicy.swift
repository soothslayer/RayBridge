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
        // Streamed sentence boundaries include the following space or newline,
        // while assistant adapters may trim the completed answer. Compare the
        // exact prefix first, then tolerate only that trailing whitespace so a
        // fully spoken answer is not repeated.
        let prefix = completed.hasPrefix(alreadySpoken)
            ? alreadySpoken
            : alreadySpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, completed.hasPrefix(prefix) else { return .whole(completed) }
        let remainder = String(completed.dropFirst(prefix.count))
        return remainder.isEmpty ? .nothing : .remainder(remainder)
    }
}
