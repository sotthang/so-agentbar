import Foundation

struct ClipboardEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let copiedAt: Date

    init(id: UUID = UUID(), text: String, copiedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
    }
}
