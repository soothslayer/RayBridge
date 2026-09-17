import Foundation

@main
struct VoiceCommandPolicyTests {
    static func main() {
        let commands: [(String, VoiceCommand)] = [
            ("Start!", .start),
            (" STOP ", .stop),
            ("Cancel.", .cancel),
            ("MUTE", .mute),
            ("unmute", .unmute)
        ]
        for (text, expected) in commands {
            precondition(VoiceCommandPolicy.command(in: text) == expected, "Missed command: \(text)")
        }

        for text in [
            "", "please stop", "cancel that", "mute please", "unmute now",
            "nonstop", "stopping", "started", "muted", "stopwatch",
            "Where is the bus stop?", "How do I mute this?", "Start the timer"
        ] {
            precondition(VoiceCommandPolicy.command(in: text) == nil, "Lost question: \(text)")
        }
        print("Passed voice command matching and question preservation tests.")
    }
}
