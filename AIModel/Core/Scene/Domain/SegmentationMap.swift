//
//  SegmentationMap.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreGraphics

/// Per-pixel label groups from the segmentation model.
/// Row-major, origin TOP-LEFT, same orientation as the camera preview.
nonisolated struct SegmentationMap: Sendable, Equatable {
    let width: Int
    let height: Int
    let groups: [SceneLabelGroup]

    init(width: Int, height: Int, groups: [SceneLabelGroup]) {
        precondition(width > 0 && height > 0 && groups.count == width * height,
                     "SegmentationMap size mismatch")
        self.width = width
        self.height = height
        self.groups = groups
    }

    /// Builds the map from raw class indices and the model's label list.
    /// Unknown indices become `.other` rather than crashing.
    init(width: Int, height: Int, classIndices: [Int32], labels: [String]) {
        let lookup = labels.map(SceneLabelGroup.group(forLabel:))
        let groups = classIndices.map { index -> SceneLabelGroup in
            let i = Int(index)
            return lookup.indices.contains(i) ? lookup[i] : .other
        }
        self.init(width: width, height: height, groups: groups)
    }

    subscript(x: Int, y: Int) -> SceneLabelGroup { groups[y * width + x] }

    /// Group at a normalised point (0...1, top-left origin).
    func group(atNormalized point: CGPoint) -> SceneLabelGroup {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        return self[x, y]
    }
}