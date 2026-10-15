//
//  SceneSnapshot.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//

import Foundation
import CoreGraphics

/// One classifier guess, e.g. ("seashore, coast, seacoast", 0.62).
nonisolated struct ClassificationHint: Sendable, Equatable {
    let label: String
    let confidence: Double
}

/// Everything the scene pipeline learned from one sampled frame.
nonisolated struct SceneSnapshot: Sendable, Equatable {
    let category: SceneCategory
    /// 0...1. Rules that depend on the category are skipped below a threshold.
    let confidence: Double
    let segmentation: SegmentationStatistics
    let depth: DepthStatistics?
    let hints: [ClassificationHint]
    let capturedAt: Date
}
