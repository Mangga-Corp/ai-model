//
//  SceneRulebook.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreGraphics

/// Best-practice framing rules per scene. Pure: same inputs, same output.
nonisolated struct SceneRulebook: Sendable {

    // MARK: - Tunables

    var minimumConfidence = 0.55
    var horizonTiltTolerance = 2.0          // degrees
    /// Upper-body boxes from Vision: head ≈ top 40% of the box.
    var headBandFraction = 0.4
    var centredHorizonBand = 0.08           // |y - 0.5| below this = "centred"
    var topClippingThreshold = 0.25         // share of top row
    var minimumDepthSeparation = 0.15
    /// Snapshots older than this are ignored (the user has moved on).
    var maximumSnapshotAge: TimeInterval = 3

    func recommendations(scene: SceneSnapshot?,
                         subjectBox: CGRect?,
                         preferences: ScenePreferences,
                         now: Date = Date()) -> [Recommendation] {
        guard let scene, now.timeIntervalSince(scene.capturedAt) <= maximumSnapshotAge else { return [] }

        var result: [Recommendation] = []

        // Scene-independent: background too close (works even for `.unknown`).
        if subjectBox != nil, let separation = scene.depth?.separation,
           separation < minimumDepthSeparation, scene.category != .indoor {
            result.append(.init(kind: .stepAwayFromBackground, priority: .enhancement,
                                message: "The background is very close. Step your subject away from it for more depth."))
        }

        guard scene.confidence >= minimumConfidence else { return result }

        switch scene.category {
        case .beach:
            result += horizonRules(scene.segmentation.skyline, subjectBox: subjectBox,
                                   preferences: preferences, requireWater: true)
        case .mountain:
            if scene.segmentation.topEdgeCoverage[.mountain, default: 0] > topClippingThreshold {
                result.append(.init(kind: .showFullPeak, priority: .enhancement,
                                    message: "The peak is cut off. Step back or tilt up slightly."))
            }
            result += horizonRules(scene.segmentation.skyline, subjectBox: subjectBox,
                                   preferences: preferences, requireWater: false,
                                   includeLevel: false)   // ridgelines are not level
        case .urban:
            if scene.segmentation.topEdgeCoverage[.structure, default: 0] > topClippingThreshold {
                result.append(.init(kind: .showFullBuilding, priority: .enhancement,
                                    message: "The building is cut off at the top. Step back to fit it in."))
            }
        case .nature, .indoor, .unknown:
            break
        }
        return result
    }

    private func horizonRules(_ skyline: Skyline?, subjectBox: CGRect?,
                              preferences: ScenePreferences, requireWater: Bool,
                              includeLevel: Bool = true) -> [Recommendation] {
        guard let skyline else { return [] }
        if requireWater && skyline.groupBelow != .water { return [] }
        var out: [Recommendation] = []

        if includeLevel, abs(skyline.angleDegrees) > horizonTiltTolerance {
            out.append(.init(kind: .levelHorizon, priority: .technical,
                             message: "The horizon is tilted. Level the phone."))
        }

        if let box = subjectBox {
            let headTop = box.minY
            let headBottom = box.minY + box.height * headBandFraction
            if skyline.y >= headTop && skyline.y <= headBottom {
                out.append(.init(kind: .moveHorizonOffHead, priority: .technical,
                                 message: "The horizon cuts through the head. Crouch a little so it sits below the shoulders."))
            }
        }

        if !preferences.prefersSymmetry, abs(skyline.y - 0.5) < centredHorizonBand {
            out.append(.init(kind: .placeHorizonOnThird, priority: .enhancement,
                             message: "Move the horizon off the centre, onto the upper or lower third."))
        }
        return out
    }
}