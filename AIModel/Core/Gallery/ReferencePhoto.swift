import Foundation
import CoreGraphics
import UIKit

/// Represents a photograph selected by the user for preference analysis
struct ReferencePhoto: Identifiable, Hashable {
    let id: UUID
    let localIdentifier: String  // PHAsset localIdentifier or file path
    let image: UIImage?  // Loaded image (nil until loaded)
    var selectionOrder: Int
}
