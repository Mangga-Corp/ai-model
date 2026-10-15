//
//  SceneUnderstandingPipeline.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//

import Foundation
import CoreGraphics

/// Anything that can turn a frame into a scene snapshot. Lets the sampler and
/// the view model be tested with a stub instead of real models.
nonisolated protocol SceneAnalyzing: Sendable {
    func prepare() async throws
    func analyze(_ image: CGImage, subjectBox: CGRect?) async throws -> SceneSnapshot
}

/// Runs the three models and turns their raw output into a `SceneSnapshot`.
actor SceneUnderstandingPipeline: SceneAnalyzing {

    private let segmenter: any SemanticSegmenting
    private let depthEstimator: (any DepthEstimating)?
    private let classifier: (any ImageClassifying)?
    private let sceneClassifier: SceneClassifier

    init(segmenter: any SemanticSegmenting = DETRSegmenter(),
         depthEstimator: (any DepthEstimating)? = DepthAnythingEstimator(),
         classifier: (any ImageClassifying)? = FastViTClassifier(),
         sceneClassifier: SceneClassifier = SceneClassifier()) {
        self.segmenter = segmenter
        self.depthEstimator = depthEstimator
        self.classifier = classifier
        self.sceneClassifier = sceneClassifier
    }

    /// Loads all models up front (first load compiles for the Neural Engine and
    /// can take a second or more). DETR is required; the others are optional.
    func prepare() async throws {
        try await segmenter.prepare()
        try? await depthEstimator?.prepare()
        try? await classifier?.prepare()
    }

    func analyze(_ image: CGImage, subjectBox: CGRect?) async throws -> SceneSnapshot {
        // Run concurrently. On the Neural Engine they may still serialise;
        // measure (step 9.5) before assuming a speed-up.
        async let segmentationTask = segmenter.segment(image)
        async let depthTask = optionalDepth(image)
        async let hintsTask = optionalHints(image)

        let map = try await segmentationTask
        let depthMap = await depthTask
        let hints = await hintsTask

        let segStats = SegmentationStatistics.compute(from: map)
        let depthStats = depthMap.map {
            DepthStatistics.compute(depth: $0, subjectBox: subjectBox, segmentation: map)
        }
        let result = sceneClassifier.classify(segStats, hints: hints)

        return SceneSnapshot(category: result.category,
                             confidence: result.confidence,
                             segmentation: segStats,
                             depth: depthStats,
                             hints: hints,
                             capturedAt: Date())
    }

    /// Optional models never fail the whole sample.
    private func optionalDepth(_ image: CGImage) async -> DepthMap? {
        try? await depthEstimator?.estimateDepth(image)
    }

    private func optionalHints(_ image: CGImage) async -> [ClassificationHint] {
        (try? await classifier?.classify(image, top: 5)) ?? []
    }
}
