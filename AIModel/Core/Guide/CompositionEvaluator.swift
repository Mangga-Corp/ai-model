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

    /// Which way the subject should move IN THE FRAME to reach the target, as the
    /// photographer sees it in the viewfinder. Only set when the measurement established it.
    enum HorizontalShift: Equatable { case towardLeft, towardRight }
    enum VerticalShift: Equatable { case higher, lower }

    /// Which preference checks actually ran against a usable preference AND a reliable
    /// measurement. "Ready" is only meaningful when at least one did.
    struct AppliedChecks: OptionSet, Equatable {
        let rawValue: Int
        static let horizontal = AppliedChecks(rawValue: 1 << 0)
        static let scale      = AppliedChecks(rawValue: 1 << 1)
        static let vertical   = AppliedChecks(rawValue: 1 << 2)
    }

    /// Whether this evaluation compared the subject with anything. Lets the UI tell
    /// "everything matches" from "there was nothing to compare with" from "the measurement
    /// could not be trusted right now".
    enum Applicability: Equatable {
        /// No subject was evaluated this pass.
        case notEvaluated
        /// At least one preference was compared with a reliable measurement.
        case applied
        /// No usable preference exists for this camera orientation. The reason, when known.
        case noUsablePreference(PreferenceUnavailableReason?)
        /// A usable preference exists but the live measurement cannot be trusted right now.
        case measurementUnreliable
    }

    /// The single most important issue to act on, if any. The guidance engine
    /// turns exactly one of these into one instruction.
    let primaryIssue: Issue?

    /// True when at least one preference was compared with a reliable measurement and
    /// nothing is outside its tolerance. It is NOT true when there was nothing to compare
    /// with: a composition that merely has no problems is not a composition that matches.
    let isReady: Bool

    /// Measured subject size as a fraction of frame area, for display/testing.
    let subjectAreaFraction: Double?

    /// Measured subject centre in normalised overlay space, for display/testing.
    let subjectCenter: CGPoint?

    /// Why the evaluation could not be trusted, when applicable. Drives honest
    /// UI copy rather than a false "ready".
    let limitation: String?

    /// How the preference-aware check of horizontal position and scale came out, or nil when
    /// the profile carries no adapted preferences (the checks then ran as they always did).
    /// Lets callers tell an actual mismatch from missing evidence or an unusable measurement.
    var preferenceOutcome: PersonalizedCompositionOutcome? = nil

    /// Every mismatch found this pass (not only the primary one). Feed it back as `latched`
    /// on the next pass to get spatial hysteresis.
    var activeMismatches: ActiveMismatches = []

    var appliedChecks: AppliedChecks = []

    var horizontalShift: HorizontalShift? = nil
    var verticalShift: VerticalShift? = nil

    var applicability: Applicability = .notEvaluated

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

    /// - Parameters:
    ///   - personalization: When present, subject SCALE and HORIZONTAL position are judged
    ///     against the adapted, evidence-checked preferences instead of `size` and the x axis
    ///     of `position`. When nil, those checks use the legacy distributions. Vertical
    ///     position, clipping and the no-subject cases are never affected by it.
    ///   - latched: the previous pass's `activeMismatches`. A mismatch that was already flagged
    ///     is only cleared once the measurement is back inside `releaseFraction` of its
    ///     tolerance; a mismatch that was not flagged is raised at the plain tolerance.
    ///     `[]` (the default) evaluates every threshold plainly.
    func evaluate(
        measurement: SceneMeasurement,
        position: PositionDistribution?,
        size: SizeDistribution?,
        photoCount: Int,
        personalization: LivePersonalization? = nil,
        latched: ActiveMismatches = []
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
        let release = GuidanceStabilityPolicy.releaseFraction

        // Collect issues in priority order. The first is the primary one.
        var issues: [CompositionEvaluation.Issue] = []
        var active: ActiveMismatches = []
        var applied: CompositionEvaluation.AppliedChecks = []
        var horizontalShift: CompositionEvaluation.HorizontalShift?
        var verticalShift: CompositionEvaluation.VerticalShift?

        // 1. Clipping — a subject cut by the frame edge is the most actionable
        //    problem, because no composition fix matters if the subject is
        //    half outside the frame. Once flagged, the box must clear the edge by a
        //    little more than the margin before the subject counts as free.
        let effectiveClipMargin = latched.contains(.clipped)
            ? clipMargin + CGFloat(GuidanceStabilityPolicy.clipReleaseMargin) : clipMargin
        if isClipped(person.box, margin: effectiveClipMargin) {
            issues.append(.subjectClipped)
            active.insert(.clipped)
        }

        // Preference-aware judgement of scale and horizontal position, only when the camera
        // profile carries adapted preferences. The tolerances are this evaluator's own.
        let personalized: PersonalizedCompositionOutcome? = personalization.map { context in
            PersonalizedCompositionEvaluator(positionTolerance: positionTolerance,
                                             sizeTolerance: sizeTolerance,
                                             clipMargin: effectiveClipMargin)
                .evaluate(box: person.box, frameSize: context.frameSize, isMirrored: context.isMirrored,
                          capturedAt: context.capturedAt, now: context.now,
                          preferences: context.preferences, latched: latched)
        }

        // 2. Size — only when the profile actually has a consistent size
        //    preference. Without one, imposing a universal ratio is exactly what
        //    the task forbids.
        if let personalized {
            // A supported scale preference that the live box falls outside of. Missing
            // evidence and unreliable measurements raise nothing.
            switch personalized.scale {
            case .matched:
                applied.insert(.scale)
            case .mismatch(let deviation):
                applied.insert(.scale)
                if deviation.offset < 0 {
                    issues.append(.subjectTooSmall); active.insert(.tooSmall)
                } else {
                    issues.append(.subjectTooLarge); active.insert(.tooLarge)
                }
            default:
                break
            }
        } else if let size, size.isConsistent, size.meanArea > 0 {
            applied.insert(.scale)
            let preferred = size.meanArea
            let lower = preferred * (1 - (latched.contains(.tooSmall) ? sizeTolerance * release : sizeTolerance))
            let upper = preferred * (1 + (latched.contains(.tooLarge) ? sizeTolerance * release : sizeTolerance))
            if area < lower {
                issues.append(.subjectTooSmall); active.insert(.tooSmall)
            } else if area > upper {
                issues.append(.subjectTooLarge); active.insert(.tooLarge)
            }
        }

        // 3a. Horizontal position from the adapted preference, when there is one.
        if let personalized {
            switch personalized.horizontal {
            case .matched:
                applied.insert(.horizontal)
            case .mismatch(let deviation):
                applied.insert(.horizontal)
                issues.append(.subjectOffCentreHorizontally); active.insert(.horizontal)
                // offset = observed - target: negative means the subject is left of the target.
                horizontalShift = deviation.offset < 0 ? .towardRight : .towardLeft
            default:
                break
            }
        }

        // 3. Position — only when the profile has a consistent placement.
        if let target = LegacyPositionTarget.resolve(position: position, photoCount: photoCount) {
            // NO y-flip. The profile's position distribution is ALREADY stored
            // in UIKit space (y-down, top-left origin) — VisionAnalysisService
            // flips Vision's y-up coordinates at storage time. The live subject
            // box is in the same y-down overlay space, so both pass through
            // unchanged. Flipping here would mirror the target vertically and
            // fire "adjust height" guidance even when the subject is correctly
            // placed.
            let targetX = target.x
            let targetY = target.y

            // Horizontal position is judged above when adapted preferences exist.
            if personalized == nil {
                applied.insert(.horizontal)
                let tolerance = latched.contains(.horizontal) ? positionTolerance * release : positionTolerance
                if abs(Double(center.x) - targetX) > tolerance {
                    issues.append(.subjectOffCentreHorizontally); active.insert(.horizontal)
                    horizontalShift = targetX - Double(center.x) > 0 ? .towardRight : .towardLeft
                }
            }
            // Vertical position is outside the personalised dimensions: same target as before.
            applied.insert(.vertical)
            let verticalTolerance = latched.contains(.vertical) ? positionTolerance * release : positionTolerance
            if abs(Double(center.y) - targetY) > verticalTolerance {
                issues.append(.subjectOffCentreVertically); active.insert(.vertical)
                // y grows downward, so a target below the subject means the subject should move down.
                verticalShift = targetY - Double(center.y) > 0 ? .lower : .higher
            }
        }

        // A dimension that could not be checked this pass (stale, invalid...) says nothing about
        // whether its mismatch has resolved, so its previous state is carried forward. Otherwise
        // one unreliable pass would silently reset the hysteresis.
        if let personalized {
            if personalized.horizontal.isUnreliable { active.formUnion(latched.intersection(.horizontal)) }
            if personalized.scale.isUnreliable { active.formUnion(latched.intersection([.tooSmall, .tooLarge])) }
        }

        let limitation: String?
        let unreliable = personalized?.hasUnreliableObservation ?? false
        let applicability: CompositionEvaluation.Applicability
        if let personalized {
            limitation = buildLimitation(personalized)
            if unreliable {
                applicability = .measurementUnreliable
            } else if !applied.isEmpty {
                applicability = .applied
            } else {
                applicability = .noUsablePreference(Self.reason(in: personalized))
            }
        } else {
            limitation = buildLimitation(position: position, size: size, photoCount: photoCount)
            applicability = applied.isEmpty
                ? .noUsablePreference(Self.legacyReason(position: position, size: size, photoCount: photoCount))
                : .applied
        }

        return CompositionEvaluation(
            primaryIssue: issues.first,
            // Ready needs a comparison that actually happened: no outstanding issue, a reliable
            // measurement, and at least one preference compared with it. Having no problems
            // because there was nothing to check is not the same as matching.
            isReady: issues.isEmpty && !unreliable && !applied.isEmpty,
            subjectAreaFraction: area,
            subjectCenter: center,
            limitation: limitation,
            preferenceOutcome: personalized,
            activeMismatches: active,
            appliedChecks: applied,
            horizontalShift: horizontalShift,
            verticalShift: verticalShift,
            applicability: applicability
        )
    }

    // MARK: - Helpers

    private func isClipped(_ box: CGRect, margin: CGFloat) -> Bool {
        let m = margin
        return box.minX <= m
            || box.minY <= m
            || box.maxX >= 1.0 - m
            || box.maxY >= 1.0 - m
    }

    /// Why nothing could be compared, from the preference-aware outcome. Horizontal position
    /// is the primary habit, so its reason is reported when both dimensions are unavailable.
    private static func reason(in outcome: PersonalizedCompositionOutcome) -> PreferenceUnavailableReason? {
        if case .preferenceUnavailable(let reason) = outcome.horizontal { return reason }
        if case .preferenceUnavailable(let reason) = outcome.scale { return reason }
        return nil
    }

    private static func legacyReason(position: PositionDistribution?, size: SizeDistribution?,
                                     photoCount: Int) -> PreferenceUnavailableReason? {
        if position == nil && size == nil { return .noUsableObservations }
        if photoCount < 2 { return photoCount == 1 ? .singleObservation : .noUsableObservations }
        return .tooVariable
    }

    /// The same honesty for the preference-aware path.
    private func buildLimitation(_ outcome: PersonalizedCompositionOutcome) -> String? {
        if outcome.hasUnreliableObservation {
            return "The subject measurement is not reliable right now, so your position and size preferences were not checked."
        }
        if outcome.isEntirelyUnavailable {
            return "Your reference photos do not support a position or size preference for this camera orientation, so only framing checks apply."
        }
        return nil
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
