import Foundation

enum CameraImagePolicy {
    static func shouldSendImage(for question: String, alwaysSend: Bool) -> Bool {
        if alwaysSend { return true }

        let text = normalized(question)
        guard !text.isEmpty else { return false }

        if containsAny(text, phrases: cameraPhrases) { return true }
        if containsAny(text, phrases: directVisualPhrases) { return true }

        let hasVisualAction = containsAny(text, phrases: visualActions)
        let hasVisualSubject = containsAny(text, phrases: visualSubjects)
        if hasVisualAction && hasVisualSubject { return true }

        let asksAboutVisualSubject = containsAny(text, phrases: visualQuestionOpeners)
        if asksAboutVisualSubject && hasVisualSubject { return true }

        let asksForCount = containsAny(text, phrases: ["how many", "is there", "are there"])
        return asksForCount && hasVisualSubject
    }

    private static let cameraPhrases = [
        "use camera", "use the camera", "through camera", "through the camera",
        "with camera", "with the camera", "camera view", "camera see",
        "take a photo", "take a photograph", "take a picture", "take a snapshot",
        "show the camera", "send an image", "include an image"
    ]

    private static let directVisualPhrases = [
        "use camera", "use the camera", "take a look", "look at this", "look at that",
        "look around", "can you see", "do you see", "what can you see", "what do you see",
        "what is this", "what is that", "whats this", "whats that",
        "who is this", "who is that", "what am i looking at", "what am i holding",
        "what am i wearing", "what do i have in my hand", "what is in my hand",
        "in front of me", "in front of us", "around me", "around us", "behind me",
        "next to me", "beside me", "to my left", "to my right", "on my left", "on my right",
        "where am i", "which way", "read this", "read that", "read it",
        "what does this say", "what does that say", "what does it say",
        "what is in this picture", "what is in this photo", "what is in this image",
        "whats in this picture", "whats in this photo", "whats in this image",
        "describe this", "describe that", "describe the scene", "describe my surroundings",
        "what color", "which color", "is the light on", "are the lights on",
        "is anyone here", "is someone here", "who is here", "find my", "help me find"
    ]

    private static let visualActions = [
        "read", "describe", "identify", "recognize", "find", "locate", "see", "look"
    ]

    private static let visualQuestionOpeners = [
        "what is", "what are", "whats", "what does", "what do", "who is", "where is",
        "where are", "is the", "are the", "which"
    ]

    private static let visualSubjects = [
        "sign", "signs", "label", "labels", "menu", "screen", "text", "document", "paper",
        "mail", "letter", "package", "bottle", "box", "food", "object", "objects", "person",
        "people", "face", "faces", "door", "stairs", "steps", "curb", "crosswalk",
        "traffic light", "room", "scene", "surroundings", "item", "items", "thing", "things"
    ]

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let words = folded.split { !$0.isLetter && !$0.isNumber }
        return words.joined(separator: " ")
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        let padded = " \(text) "
        return phrases.contains { padded.contains(" \($0) ") }
    }
}
