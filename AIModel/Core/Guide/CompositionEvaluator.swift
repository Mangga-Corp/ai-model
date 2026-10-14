import Foundation
import CoreGraphics

/// A single measured element in the live scene.
///
/// Holds only what is actually measured. There is deliberately NO building
/// element here: no reliable building-boundary detector exists in Vision, and
/// the task forbids fabricating boundaries. Anything not measured is absent,
/// not guessed.
struct SceneElement: Equatable {
    enum Kind: Equatable {
        case person
    }

    let kind: Kind

    /// Bounding box in NORMALISED overlay space: origin top-left, y down, 0...1.
    /// This is the same space `subjectBox` is published in, so no conversion is
    /// needed between detection and evaluation.
    let box: CGRect

    /// Detection confidence, 0...1, when the detector reports one.
    let confidence: Double?
}

/// A frame's worth of measured scene state, fed to the evaluator.
struct SceneMeasurement: Equatable {
    /// The primary (largest) detected person, if any.
    let person: SceneElement?

    /// True when a person was expected but not detected this frame — lets the
    /// evaluator distinguish "no subject" from "measurement failed".
    let personLost: Bool

    static let empty = SceneMeasurement(person: nil, personLost: false)
}

/// The outcome of evaluating one frame against the preference profile.
///
/// Every field is an OBSERVED FACT about this frame. Nothing here claims a
/// building is captured, because no building is measured.
struct CompositionEvaluation: Equatable {

    enum Issue: Equatable {
        case noSubject
        case subjectLost
        case subjectTooLarge
        case subjectTooSmall
        case subjectOffCentreHorizontally
        case subjectOffCentreVertically
        case subjectClipped
    }

    /// The single most important issue to act on, if any. The guidance engine
    /// turns exactly one of these into one instruction.
    let primaryIssue: Issue?

    /// True when the applicable constraints are satisfied and a capture would
    /// match the user's composition habit.
    let isReady: Bool

    /// Measured subject size as a fraction of frame area, for display/testing.
    let subjectAreaFraction: Double?

    /// Measured subject centre in normalised overlay space, for display/testing.
    let subjectCenter: CGPoint?

    /// Why the evaluation could not be trusted, when applicable. Drives honest
    /// UI copy rather than a false "ready".
    let limitation: String?

    static let noSubject = CompositionEvaluation(
        primaryIssue: .noSubject,
        isReady: false,
        subjectAreaFraction: nil,
        subjectCenter: nil,
        limitation: nil
    )
}

/// Evaluates the live frame against the user's measured composition preferences.
///
/// Pure logic — no Vision, no camera, no UI. Everything it needs arrives in a
/// `SceneMeasurement`, which makes the whole evaluation unit-testable.
///
/// Uses the ACTUAL profile where a preference exists. Where the profile lacks a
/// usable value, it falls back to a documented neutral default and says so via
/// `CompositionEvaluation.limitation` rather than silently inventing a rule.
struct CompositionEvaluator {

    // MARK: - Tunable thresholds

    /// How far the measured subject size may deviate from the preferred size, as
    /// a fraction of the preferred area, before it is flagged. 0.5 means "within
    /// 50% of preferred either way is acceptable".
    var sizeTolerance: Double = 0.5

    /// How far the subject centre may sit from the preferred centre, in
    /// normalised units, before it is flagged. 0.15 ≈ 15% of the frame.
    var positionTolerance: Double = 0.15

    /// A subject whose box touches within this distance of a frame edge is
    /// considered clipped.
    var clipMargin: CGFloat = 0.01

    // MARK: - Evaluation

    func evaluate(
        measurement: SceneMeasurement,
        position: PositionDistribution?,
        size: SizeDistribution?,
        photoCount: Int
    ) -> CompositionEvaluation {

        // No person detected this frame.
        if measurement.person == nil {
            if measurement.personLost {
                return CompositionEvaluation(
                    primaryIssue: .subjectLost,
                    isReady: false,
                    subjectAreaFraction: nil,
                    subjectCenter: nil,
                    limitation: nil
                )
            }
            return .noSubject
        }

        guard let person = measurement.person else { return .noSubject }

        let area = Double(person.box.width * person.box.height)
        let center = CGPoint(
            x: person.box.midX,
            y: person.box.midY
        )

        // Collect issues in priority order. The first is the primary one.
        var issues: [CompositionEvaluation.Issue] = []

        // 1. Clipping — a subject cut by the frame edge is the most actionable
        //    problem, because no composition fix matters if the subject is
        //    half outside the frame.
        if isClipped(person.box) {
            issues.append(.subjectClipped)
        }

        // 2. Size — only when the profile actually has a consistent size
        //    preference. Without one, imposing a universal ratio is exactly what
        //    the task forbids.
        if let size, size.isConsistent, size.meanArea > 0 {
            let preferred = size.meanArea
            let lower = preferred * (1 - sizeTolerance)
            let upper = preferred * (1 + sizeTolerance)
            if area < lower {
                issues.append(.subjectTooSmall)
            } else if area > upper {
                issues.append(.subjectTooLarge)
            }
        }

        // 3. Position — only when the profile has a consistent placement.
        if let position, position.isConsistent, photoCount >= 2 {
            // NO y-flip. The profile's position distribution is ALREADY stored
            // in UIKit space (y-down, top-left origin) — VisionAnalysisService
            // flips Vision's y-up coordinates at storage time. The live subject
            // box is in the same y-down overlay space, so both pass through
            // unchanged. Flipping here would mirror the target vertically and
            // fire "adjust height" guidance even when the subject is correctly
            // placed.
            let targetX = position.meanX
            let targetY = position.meanY

            if abs(Double(center.x) - targetX) > positionTolerance {
                issues.append(.subjectOffCentreHorizontally)
            }
            if abs(Double(center.y) - targetY) > positionTolerance {
                issues.append(.subjectOffCentreVertically)
            }
        }

        let limitation = buildLimitation(position: position, size: size, photoCount: photoCount)

        return CompositionEvaluation(
            primaryIssue: issues.first,
            isReady: issues.isEmpty,
            subjectAreaFraction: area,
            subjectCenter: center,
            limitation: limitation
        )
    }

    // MARK: - Helpers

    private func isClipped(_ box: CGRect) -> Bool {
        let m = clipMargin
        return box.minX <= m
            || box.minY <= m
            || box.maxX >= 1.0 - m
            || box.maxY >= 1.0 - m
    }

    /// Explains which preferences were unavailable, so the UI can be honest
    /// about what "ready" is based on.
    private func buildLimitation(
        position: PositionDistribution?,
        size: SizeDistribution?,
        photoCount: Int
    ) -> String? {
        if photoCount < 2 {
            return "Not enough analysed photos to apply your composition preferences."
        }
        if position?.isConsistent != true && size?.isConsistent != true {
            return "Your composition preferences vary too much to apply a target."
        }
        return nil
    }
}
