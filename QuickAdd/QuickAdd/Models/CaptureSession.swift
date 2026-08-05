import Foundation
import SwiftData

/// One capture: raw input, what the model made of it, and what got committed.
///
/// `rawText` is persisted *before* the extraction request goes out, so a crash,
/// a dropped connection, or an API error never costs the user their input.
@Model
final class CaptureSession {
    #Index<CaptureSession>([\.createdAt])

    var id: UUID = UUID()
    var createdAt: Date = Date()
    var rawText: String = ""

    var status: Status = Status.draft

    /// Verbatim response body. Kept because it is the only evidence available
    /// when tuning the prompt against a bad extraction.
    var llmRawResponse: String?
    var modelId: String?
    var errorMessage: String?

    @Relationship(deleteRule: .cascade, inverse: \DraftItem.session)
    var items: [DraftItem] = []

    init(rawText: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.rawText = rawText
        self.status = .draft
    }

    enum Status: String, Codable {
        /// Input persisted, extraction not yet attempted.
        case draft
        case extracting
        /// Extraction succeeded; user is reviewing the cards.
        case reviewing
        /// At least one item was written to EventKit.
        case committed
        case failed
    }
}
