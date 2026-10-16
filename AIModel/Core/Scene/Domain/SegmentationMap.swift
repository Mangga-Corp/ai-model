import Foundation
import CoreGraphics

/// Per-pixel segmentation from the model. Row-major, origin TOP-LEFT, same
/// orientation as the camera preview.
///
/// Holds two views of the same pixels:
/// - `groups`: coarse photography groups (sky, water, structure…) used for
///   scene classification.
/// - `classIndices` + `labels`: the model's ORIGINAL labels ("car", "dining
///   table"…), used to find individual objects. Empty for maps built from
///   groups only (most unit tests).
nonisolated struct SegmentationMap: Sendable, Equatable {
    let width: Int
    let height: Int
    let groups: [SceneLabelGroup]
    let classIndices: [Int32]
    let labels: [String]

    init(width: Int, height: Int, groups: [SceneLabelGroup]) {
        precondition(width > 0 && height > 0 && groups.count == width * height,
                     "SegmentationMap size mismatch")
        self.width = width
        self.height = height
        self.groups = groups
        self.classIndices = []
        self.labels = []
    }

    /// Builds the map from raw class indices and the model's label list.
    /// Unknown indices become `.other` rather than crashing.
    init(width: Int, height: Int, classIndices: [Int32], labels: [String]) {
        precondition(width > 0 && height > 0 && classIndices.count == width * height,
                     "SegmentationMap size mismatch")
        let lookup = labels.map(SceneLabelGroup.group(forLabel:))
        self.width = width
        self.height = height
        self.groups = classIndices.map { index -> SceneLabelGroup in
            let i = Int(index)
            return lookup.indices.contains(i) ? lookup[i] : .other
        }
        self.classIndices = classIndices
        self.labels = labels
    }

    /// True when original labels are available (maps built from the model).
    var hasLabels: Bool { !classIndices.isEmpty && !labels.isEmpty }

    subscript(x: Int, y: Int) -> SceneLabelGroup { groups[y * width + x] }

    /// Original model label at a pixel, or nil when unavailable / out of range.
    func label(x: Int, y: Int) -> String? {
        guard hasLabels else { return nil }
        let i = Int(classIndices[y * width + x])
        return labels.indices.contains(i) ? labels[i] : nil
    }

    /// Group at a normalised point (0...1, top-left origin).
    func group(atNormalized point: CGPoint) -> SceneLabelGroup {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        return self[x, y]
    }
}
