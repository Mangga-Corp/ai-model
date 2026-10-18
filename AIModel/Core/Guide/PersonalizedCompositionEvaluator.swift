import Foundation
import CoreGraphics

// MARK: - Outcomes

/// Why a live measurement cannot be compared with a preference. These are problems with
/// the OBSERVATION, never evidence that the composition is wrong.
nonisolated enum ObservationProblem: String, Sendable, Hashable {
    /// The box is not finite, is degenerate, or lies outside the frame.
    case invalidGeometry
    /// The frame size is unusable, or the frame is neither portrait nor landscape.
    case invalidFrame
    /// The capture time is missing, not finite, or in the future.
    case invalidTimestamp
    /// The measurement is older than the allowed age.
    case stale
    /// The box touches the frame edge, so its centre and area describe only part of the person.
    case clipped
}

nonisolated enum NotApplicableReason: String, Sendable, Hashable {
    /// No person was detected this pass, so there is nothing to compare.
    case noSubject
}

/// How far a live measurement is from a preference's target, in one set of units.
nonisolated struct PreferenceDeviation: Hashable, Sendable {
    /// The live value (centre x, or area fraction).
    let observed: Double
    /// The preference's target in the same units.
    let target: Double
    /// Signed distance. Horizontal: `observed - target` in frame widths (negative = subject
    /// left of the target). Scale: `observed / target - 1` (negative = smaller than usual).
    let offset: Double
    /// The largest `abs(offset)` still counted as matching (same units as `offset`).
    let tolerance: Double
}

/// The result of checking ONE dimension. Deliberately not a Boolean: a mismatch, missing
/// evidence, an unusable measurement and "nothing to compare" call for different handling.
nonisolated enum PreferenceEvaluation: Hashable, Sendable {
    /// A supported preference exists and the live measurement is within tolerance.
    case matched(PreferenceDeviation)
    /// A supported preference exists and the live measurement is outside tolerance.
    case mismatch(PreferenceDeviation)
    /// There is no supported preference for this dimension (and orientation).
    case preferenceUnavailable(PreferenceUnavailableReason)
    /// The live measurement cannot be trusted right now. Never a mismatch, never a match.
    case observationUnreliable(ObservationProblem)
    /// There is nothing to evaluate.
    case notApplicable(NotApplicableReason)

    var isMismatch: Bool { if case .mismatch = self { return true } else { return false } }
    var isUnreliable: Bool { if case .observationUnreliable = self { return true } else { return false } }
}

nonisolated struct PersonalizedCompositionOutcome: Hashable, Sendable {
    let horizontal: PreferenceEvaluation
    let scale: PreferenceEvaluation

    /// True when a dimension that HAS a supported preference could not be checked because the
    /// live measurement is unreliable. Readiness must not be claimed in that case.
    var hasUnreliableObservation: Bool { horizontal.isUnreliable || scale.isUnreliable }

    /// True when neither dimension has a supported preference.
    var isEntirelyUnavailable: Bool {
        if case .preferenceUnavailable = horizontal, case .preferenceUnavailable = scale { return true }
        return false
    }
}

// MARK: - Live inputs

/// What the camera knows about THIS frame, beyond the box itself, that decides whether the
/// adapted preferences can be compared with it. Built per detection pass from values the
/// camera already has; nothing here is computed from pixels.
nonisolated struct LivePersonalization: Hashable, Sendable {
    /// The preferences adapted from the profile when the camera was opened.
    let preferences: LiveCompositionPreferences
    /// Pixel size of the delivered buffer the box was measured in (after the capture
    /// connection's rotation). Its orientation selects which preferences apply.
    let frameSize: CGSize
    /// True when the delivered buffer is mirrored (front camera). Reference photos are not.
    let isMirrored: Bool
    /// `ProcessInfo.systemUptime` when the frame arrived.
    let capturedAt: TimeInterval
    /// `ProcessInfo.systemUptime` when the box is being evaluated.
    let now: TimeInterval
}

// MARK: - Evaluator

/// Compares ONE live upper-body box with the adapted preferences, for subject horizontal
/// position and subject scale.
///
/// Pure and cheap: a handful of comparisons on values the camera already computed. It
/// runs no Vision, no model and no profile conversion.
///
/// COORDINATES. The box is in the camera's published space: normalised 0...1, origin
/// top-left, y down, relative to the whole delivered frame. That is the same space the
/// reference boxes are stored in (`ImageSpace`), so nothing is flipped or rescaled here.
/// Two things are still checked because a silent comparison would be wrong without them:
///   - ORIENTATION: normalised area and x depend on aspect ratio, so the frame's own
///     orientation (from its pixel size) selects which preferences apply.
///   - MIRRORING: a mirrored feed is un-mirrored (x -> 1 - x) before comparing with
///     un-mirrored reference photos.
///
/// SCALE is the box's share of the frame. It is a relative image measurement and says
/// nothing about physical distance; the wording that reaches the user must not either.
///
/// The tolerances are the live evaluator's own (`CompositionEvaluator`), passed in so there
/// is one definition of "close enough".
nonisolated struct PersonalizedCompositionEvaluator: Sendable {

    /// Largest allowed `abs(centre x - target)`, in frame widths.
    let positionTolerance: Double
    /// Largest allowed relative deviation of the area from its target.
    let sizeTolerance: Double
    /// Distance from an edge within which a box counts as clipped.
    let clipMargin: CGFloat
    /// Oldest acceptable measurement. Detection runs about every 0.14 s, so this allows three
    /// missed passes before a measurement stops being treated as current.
    var maximumObservationAge: TimeInterval = 0.5

    /// Boxes may overshoot the frame by this much (detector rounding) before they are invalid.
    static let boundsSlack: CGFloat = 0.02

    func evaluate(box: CGRect?,
                  frameSize: CGSize,
                  isMirrored: Bool,
                  capturedAt: TimeInterval,
                  now: TimeInterval,
                  preferences: LiveCompositionPreferences?) -> PersonalizedCompositionOutcome {

        func both(_ e: PreferenceEvaluation) -> PersonalizedCompositionOutcome {
            PersonalizedCompositionOutcome(horizontal: e, scale: e)
        }

        guard let box else { return both(.notApplicable(.noSubject)) }
        guard let preferences else { return both(.preferenceUnavailable(.noPreferenceData)) }

        // The frame's own orientation decides which preferences apply.
        guard let orientation = FrameOrientation(width: Double(frameSize.width), height: Double(frameSize.height)) else {
            return both(.observationUnreliable(.invalidFrame))
        }
        let slice = preferences.preferences(for: orientation)

        // Observation problems are decided once and apply only to dimensions that have a preference.
        let (normalized, problem) = normalise(box, isMirrored: isMirrored, capturedAt: capturedAt, now: now)

        return PersonalizedCompositionOutcome(
            horizontal: resolve(slice.horizontal, problem: problem) { preference in
                guard preference.targetX.isFinite, (0...1).contains(preference.targetX) else {
                    return .preferenceUnavailable(.invalidPreferenceData)
                }
                let observed = Double(normalized.midX)
                let deviation = PreferenceDeviation(observed: observed, target: preference.targetX,
                                                    offset: observed - preference.targetX, tolerance: positionTolerance)
                return abs(deviation.offset) > positionTolerance ? .mismatch(deviation) : .matched(deviation)
            },
            scale: resolve(slice.scale, problem: problem) { preference in
                guard preference.targetArea.isFinite, preference.targetArea > 0, preference.targetArea <= 1 else {
                    return .preferenceUnavailable(.invalidPreferenceData)
                }
                let area = Double(normalized.width * normalized.height)
                let deviation = PreferenceDeviation(observed: area, target: preference.targetArea,
                                                    offset: area / preference.targetArea - 1, tolerance: sizeTolerance)
                let lower = preference.targetArea * (1 - sizeTolerance)
                let upper = preference.targetArea * (1 + sizeTolerance)
                return (area < lower || area > upper) ? .mismatch(deviation) : .matched(deviation)
            })
    }

    // MARK: Helpers

    /// A missing preference is reported before an observation problem: with nothing to compare
    /// against, the quality of the measurement is irrelevant to this dimension.
    private func resolve<Value>(_ support: PreferenceSupport<Value>,
                                problem: ObservationProblem?,
                                compare: (Value) -> PreferenceEvaluation) -> PreferenceEvaluation {
        switch support {
        case .unavailable(let reason): return .preferenceUnavailable(reason)
        case .supported(let value):
            if let problem { return .observationUnreliable(problem) }
            return compare(value)
        }
    }

    /// Un-mirrors the box and decides whether the measurement can be trusted at all.
    private func normalise(_ box: CGRect, isMirrored: Bool, capturedAt: TimeInterval,
                           now: TimeInterval) -> (CGRect, ObservationProblem?) {
        let slack = Self.boundsSlack
        guard box.origin.x.isFinite, box.origin.y.isFinite, box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0,
              box.minX >= -slack, box.minY >= -slack, box.maxX <= 1 + slack, box.maxY <= 1 + slack else {
            return (box, .invalidGeometry)
        }
        guard capturedAt.isFinite, now.isFinite, now >= capturedAt else { return (box, .invalidTimestamp) }
        guard now - capturedAt <= maximumObservationAge else { return (box, .stale) }

        let normalized = isMirrored ? CGRect(x: 1 - box.maxX, y: box.minY, width: box.width, height: box.height) : box
        let m = clipMargin
        let clipped = normalized.minX <= m || normalized.minY <= m || normalized.maxX >= 1.0 - m || normalized.maxY >= 1.0 - m
        return (normalized, clipped ? .clipped : nil)
    }
}
