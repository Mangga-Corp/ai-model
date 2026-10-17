import Foundation
import CoreGraphics

/// Hands the new analysis to the EXISTING camera guidance without changing it.
///
/// The camera feature consumes `PhotographicPreferenceProfile` (a legacy type
/// it was built against). This adapter fills only the fields the camera reads
/// and leaves every other field empty. No legacy analysis logic is involved.
///
/// MEASUREMENT BASIS. The live camera detects the UPPER body
/// (`upperBodyOnly = true`) and compares that box with the profile. So the
/// targets are built from each photo's head-and-torso box, not the full-person
/// box used for the on-screen subject positioning. Comparing like with like
/// avoids systematic size and position errors. Photos without an upper-body
/// detection are left out of these targets (missing, not negative).
///
/// `photoCount` is the number of photos that actually contributed a target, so
/// the camera's own confidence gates (>= 2 photos to guide, >= 3 for a
/// confident guide) reflect real evidence.
///
/// A distribution is flagged consistent only with two or more samples and a
/// spread within the camera's tolerances (position 0.15, size 0.10).
enum CameraProfileBridge {

    static let positionTolerance = 0.15
    static let sizeTolerance = 0.10

    static func make(profile: PreferenceProfile, results: [PhotoResult]) -> PhotographicPreferenceProfile {
        let boxes = results.compactMap { r -> CGRect? in
            guard r.subjectPositioning.assessment.isDetermined, r.subjectPositioning.isMeasurementValid else { return nil }
            return r.subjectPositioning.upperBodyBox
        }

        let n = boxes.count
        var position: PositionDistribution?
        var size: SizeDistribution?

        if n > 0 {
            let xs = boxes.map { Double($0.midX) }, ys = boxes.map { Double($0.midY) }
            let areas = boxes.map { ImageSpace.area($0) }
            let mx = mean(xs), my = mean(ys), ma = mean(areas)
            let sx = stdDev(xs, mx), sy = stdDev(ys, my), sa = stdDev(areas, ma)
            position = PositionDistribution(
                meanX: mx, meanY: my, stdDevX: sx, stdDevY: sy,
                isConsistent: n >= 2 && sx < positionTolerance && sy < positionTolerance)
            size = SizeDistribution(
                meanArea: ma, minArea: areas.min() ?? 0, maxArea: areas.max() ?? 0, stdDev: sa,
                isConsistent: n >= 2 && sa < sizeTolerance)
        }

        return PhotographicPreferenceProfile(
            id: UUID(),
            photoCount: n,
            successfullyAnalyzedCount: n,
            subjectPositionDistribution: position,
            halfBodyPositionDistribution: position,
            subjectSizeDistribution: size,
            horizonAngleDistribution: nil,
            brightnessDistribution: nil, saturationDistribution: nil, colorTemperatureDistribution: nil,
            headYawDistribution: nil, headRollDistribution: nil,
            bodyOrientationDistribution: nil, bodySymmetryDistribution: nil,
            saliencyIntensityDistribution: nil, aestheticScoreDistribution: nil,
            leadingLinesLineCountDistribution: nil, leadingLinesAngleDistribution: nil,
            leadingLinesConvergenceDistribution: nil, diagonalDominanceRatio: nil,
            ruleOfThirdsPatterns: [:], sceneCategories: [:], negativeSpacePatterns: [:],
            colorHarmonyPatterns: [:], dominantColorPalette: [],
            lightDirectionPatterns: [:],
            symmetryDistribution: nil, bilateralDistribution: nil, symmetryRatio: nil, symmetryAxisPatterns: [:],
            goldenRatioDistribution: nil, goldenRatioHitRatio: nil,
            summary: "", insights: [], analyses: [], photos: [], mixedPatterns: [],
            limitations: profile.limitations,
            generatedAt: profile.generatedAt)
    }

    private static func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }

    private static func stdDev(_ v: [Double], _ mean: Double) -> Double {
        guard v.count > 1 else { return 0 }
        return (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)).squareRoot()
    }
}
