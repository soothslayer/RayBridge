import Foundation

@main
struct AnswerStreamPolicyTests {
    static func main() {
        // Nothing spoken yet, so the whole answer is still to say.
        precondition(
            AnswerStreamPolicy.speech(completed: "A red door.", alreadySpoken: "")
                == .whole("A red door."),
            "An unspoken answer must be spoken in full")

        // The usual case: the opening sentences were spoken while the Mac wrote
        // the rest, so only the tail is left.
        precondition(
            AnswerStreamPolicy.speech(completed: "A red door. It is closed.", alreadySpoken: "A red door. ")
                == .remainder("It is closed."),
            "Only the unspoken tail may be spoken")

        // Everything was already spoken, so the answer must not repeat.
        precondition(
            AnswerStreamPolicy.speech(completed: "A red door. ", alreadySpoken: "A red door. ")
                == .nothing,
            "A fully spoken answer must not repeat")

        // Claude trims its completed result, while the streamed sentence keeps
        // the boundary whitespace. That formatting difference must not repeat
        // an answer the user has already heard.
        precondition(
            AnswerStreamPolicy.speech(completed: "A red door.", alreadySpoken: "A red door. \n")
                == .nothing,
            "Trimmed final whitespace must not repeat a fully spoken answer")
        precondition(
            AnswerStreamPolicy.speech(completed: "A red door. It is closed.", alreadySpoken: "A red door. \n")
                == .remainder(" It is closed."),
            "Trimmed streamed whitespace must preserve the unspoken tail")

        // The assistant replaced what it was writing, so start again rather than
        // speaking a tail that does not follow what was heard.
        for spoken in ["Let me look. ", "A red door. It is open. ", "A blue"] {
            precondition(
                AnswerStreamPolicy.speech(completed: "A red door. It is closed.", alreadySpoken: spoken)
                    == .whole("A red door. It is closed."),
                "A replaced answer must be spoken in full: \(spoken)")
        }

        // An empty answer never produces speech.
        precondition(
            AnswerStreamPolicy.speech(completed: "", alreadySpoken: "A red door. ")
                == .whole(""),
            "An empty answer cannot continue spoken text")

        print("AnswerStreamPolicy tests passed")
    }
}
