import Foundation

@main
struct VoiceCommandPolicyTests {
    static func main() {
        let commands: [(String, VoiceCommand)] = [
            ("Start!", .start),
            (" STOP ", .stop),
            ("Cancel.", .cancel),
            ("MUTE", .mute),
            ("unmute", .unmute),
            ("Commands!", .commands)
        ]
        for (text, expected) in commands {
            precondition(VoiceCommandPolicy.command(in: text) == expected, "Missed command: \(text)")
        }

        for text in [
            "", "please stop", "cancel that", "mute please", "unmute now", "show commands",
            "nonstop", "stopping", "started", "muted", "stopwatch",
            "Where is the bus stop?", "How do I mute this?", "Start the timer"
        ] {
            precondition(VoiceCommandPolicy.command(in: text) == nil, "Lost question: \(text)")
        }
        precondition(VoiceCommandPolicy.launchAnnouncement.contains("Tap Start RayBridge"))
        precondition(VoiceCommandPolicy.launchAnnouncement.contains("say Start"))
        for command in VoiceCommand.allCases {
            precondition(VoiceCommandPolicy.helpAnnouncement.localizedCaseInsensitiveContains(command.rawValue),
                         "Help must announce the \(command.rawValue) command")
        }
        print("Passed voice command matching and question preservation tests.")
    }
}
