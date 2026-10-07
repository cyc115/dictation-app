import Foundation

/// Optional LLM cleanup of the transcript. OFF by default (menu bar toggle).
/// Uses Apple's on-device model only — nothing leaves the Mac.
class PolishService {
    func polish(_ text: String) async -> String {
        #if canImport(FoundationModels)
        return await OnDevicePolish.polish(text)
        #else
        return text
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

private enum OnDevicePolish {
    static func polish(_ text: String) async -> String {
        guard case .available = SystemLanguageModel.default.availability else { return text }
        do {
            let session = LanguageModelSession(instructions: """
                Clean up dictated text: remove filler words (um, uh, like, you know), \
                collapse repeated words, resolve obvious self-corrections, add light \
                punctuation. Keep the speaker's exact meaning, wording and tone. \
                Never add new ideas or rephrase beyond cleanup. Output only the cleaned text.
                """)
            let response = try await session.respond(to: text)
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? text : cleaned
        } catch {
            return text
        }
    }
}
#endif
