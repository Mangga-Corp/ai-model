import Foundation
import CoreGraphics

/// Protocol defining the golden-ratio analysis interface.
protocol GoldenRatioAnalyzing {
    func analyzeGoldenRatio(subjectPosition: CGPoint?) -> GoldenRatioResult
}

/// GoldenRatioAnalysisService — classifies subject placement against the
/// golden ratio (0.382 / 0.618) rather than thirds (0.333 / 0.667).
///
/// Uses the same measurement as rule-of-thirds — the detected subject's
/// normalized centroid — so it adds no new Vision request and no new image
/// processing. It is a second reading of a number the pipeline already has.
///
/// Honest about what it is: this measures *where the subject sits relative to
/// the golden-ratio divisions*. Whether that constitutes "good composition"
/// is an interpretation, not a measurement, and the UI labels it accordingly.
final class GoldenRatioAnalysisService: GoldenRatioAnalyzing {

    /// The golden ratio division, 1/φ.
    private let goldenLow = 0.382
    private let goldenHigh = 0.618

    /// Tolerance (in normalized units) within which a subject counts as
    /// aligned to a golden-ratio line.
    ///
    /// Must stay comfortably below half the gap between the golden division
    /// (0.382) and the thirds division (0.333) — that gap is 0.049, so a looser
    /// tolerance would make "golden ratio" indistinguishable from "rule of
    /// thirds" and the measurement meaningless.
    private let alignmentTolerance = 0.02

    func analyzeGoldenRatio(subjectPosition: CGPoint?) -> GoldenRatioResult {
        guard let position = subjectPosition else {
            return GoldenRatioResult(
                horizontalZone: .center,
                verticalZone: .center,
                isAtGoldenPoint: false,
                alignmentStrength: 0
            )
        }

        let horizontalZone = classify(value: position.x)
        let verticalZone = classify(value: position.y)

        // Distance to the nearest golden-ratio line, in normalized units.
        let distanceToGoldenLine = min(
            abs(position.x - goldenLow),
            abs(position.x - goldenHigh),
            abs(position.y - goldenLow),
            abs(position.y - goldenHigh)
        )

        let isAtGoldenPoint = distanceToGoldenLine <= alignmentTolerance

        // Strength: 1.0 when exactly on a golden line, falling to 0 at the
        // tolerance boundary.
        let alignmentStrength: Double
        if distanceToGoldenLine >= alignmentTolerance {
            alignmentStrength = 0
        } else {
            alignmentStrength = 1.0 - (distanceToGoldenLine / alignmentTolerance)
        }

        return GoldenRatioResult(
            horizontalZone: horizontalZone,
            verticalZone: verticalZone,
            isAtGoldenPoint: isAtGoldenPoint,
            alignmentStrength: alignmentStrength
        )
    }

    /// Classifies a normalized coordinate against the golden divisions.
    private func classify(value: Double) -> GoldenRatioZone {
        if abs(value - goldenLow) <= alignmentTolerance { return .golden }
        if abs(value - goldenHigh) <= alignmentTolerance { return .goldenFar }
        if value < goldenLow - alignmentTolerance { return .near }
        if value > goldenHigh + alignmentTolerance { return .far }
        return .center
    }
}
