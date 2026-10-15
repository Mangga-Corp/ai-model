//
//  SceneClassifier.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

nonisolated struct SceneClassifier: Sendable {

    // MARK: - Tunables (all fractions of background pixels)

    var beachWater = 0.15
    var beachSand = 0.08
    var mountain = 0.15
    var urban = 0.25
    var nature = 0.35
    var indoor = 0.35
    var indoorMaxSky = 0.05
    /// Minimum classifier probability before a FastViT hint counts.
    var hintMinimumConfidence = 0.35
    /// Score added to a category the classifier agrees with.
    var hintBoost = 0.15

    struct Result: Equatable, Sendable {
        let category: SceneCategory
        let confidence: Double
    }

    func classify(_ stats: SegmentationStatistics, hints: [ClassificationHint] = []) -> Result {
        // Each candidate: (category, score, threshold)
        var candidates: [(SceneCategory, Double, Double)] = [
            (.beach, stats.fraction(.water, .sand),
             stats.fraction(.water) >= beachWater || stats.fraction(.sand) >= beachSand ? 0 : .infinity),
            (.mountain, stats.fraction(.mountain, .snow), mountain),
            (.urban, stats.fraction(.structure, .street), urban),
            (.nature, stats.fraction(.vegetation), nature),
            (.indoor, stats.fraction(.indoor),
             stats.fraction(.sky) <= indoorMaxSky ? indoor : .infinity),
        ]

        // FastViT agreement nudges a close call; it never overrides the masks.
        let hinted = hints
            .filter { $0.confidence >= hintMinimumConfidence }
            .compactMap { ImageNetSceneHints.category(for: $0.label) }
        candidates = candidates.map { c in
            hinted.contains(c.0) ? (c.0, c.1 + hintBoost, c.2) : c
        }

        let passing = candidates.filter { $0.1 >= $0.2 }
        guard let best = passing.max(by: { $0.1 < $1.1 }) else {
            return Result(category: .unknown, confidence: 0)
        }

        // Confidence: how far past its threshold, and how far ahead of the runner-up.
        let runnerUp = passing.filter { $0.0 != best.0 }.map { $0.1 }.max() ?? 0
        let margin = best.1 - runnerUp
        let confidence = min(1, max(0, 0.5 + margin))
        return Result(category: best.0, confidence: confidence)
    }
}