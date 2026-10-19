import Foundation
import CoreGraphics

/// Stage A output: an upright, size-limited image ready for every downstream
/// source, or the reason the photo could not be read.
nonisolated struct PreparedPhoto: @unchecked Sendable {
    enum Outcome {
        case ready(image: CGImage, record: ImagePreparationRecord)
        case unreadable(String)
    }

    let id: UUID
    let selectionOrder: Int
    let localIdentifier: String
    let outcome: Outcome
}
