import Foundation

struct TranscriptionEntry: Codable, Identifiable {
    let id: UUID
    let text: String       // final injected text (post-refinement if refined)
    let date: Date
    var wasRefined: Bool   // true only if LLM refinement succeeded AND changed the text
}
