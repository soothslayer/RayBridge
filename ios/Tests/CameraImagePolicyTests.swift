import Foundation

@main
struct CameraImagePolicyTests {
    static func main() {
        let visualQuestions = [
            "What is this?", "Can you see the sign?", "Read this label for me.",
            "What am I holding?", "What color is my shirt?", "Who is in front of me?",
            "How many people are in the room?", "Help me find my keys.",
            "What does the sign say?", "Is the door open?", "Is anyone here?",
            "Use the camera and tell me whether the light is on."
        ]
        let nonvisualQuestions = [
            "What is the weather tomorrow?", "Summarize the file on my computer.",
            "Read my latest email.", "Is this Git branch clean?", "Write a poem about a camera.",
            "What did we discuss yesterday?"
        ]

        for question in visualQuestions {
            precondition(CameraImagePolicy.shouldSendImage(for: question, alwaysSend: false), "Expected an image for: \(question)")
        }
        for question in nonvisualQuestions {
            precondition(!CameraImagePolicy.shouldSendImage(for: question, alwaysSend: false), "Expected no image for: \(question)")
        }
        precondition(CameraImagePolicy.shouldSendImage(for: "Tell me a joke.", alwaysSend: true))
        print("Passed camera image policy tests for visual intent, nonvisual requests, and always-send mode.")
    }
}
