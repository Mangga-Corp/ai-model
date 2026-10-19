import Foundation
import CoreGraphics

/// The legacy (all-orientation) position target, with the gate the evaluator has always used
/// for it. The evaluator and the on-screen guide both read it from here, so they cannot apply
/// different rules for when a vertical target exists.
nonisolated enum LegacyPositionTarget {

    /// The mean upper-body centre, or nil unless the placement is consistent and rests on at
    /// least two photos. Coordinates: normalised frame space, origin top-left, y down. NO
    /// y-flip: the profile stores positions already in this space (see `CompositionEvaluator`).
    static func resolve(position: PositionDistribution?, photoCount: Int) -> (x: Double, y: Double)? {
        guard let position, position.isConsistent, photoCount >= 2 else { return nil }
        return (position.meanX, position.meanY)
    }
}

/// Where the dashed guide is drawn, in FRAME space (normalised, origin top-left, y down).
///
/// It shows ONLY targets the evaluator actually enforces:
///   - horizontal position: the adapted preference's target, for the camera's current
///     orientation (the same checked value `PersonalizedCompositionEvaluator` compares with);
///   - vertical position: the legacy target, under the same gate as the evaluator's vertical
///     check; when there is none, the guide is a full-height band, so no height is implied;
///   - size: the adapted scale target (same area), drawn with the typical shape of the
///     reference boxes; when there is none, the long-standing default size, which is only a
///     generous placement region and not a size preference.
///
/// Profiles without adapted preferences keep exactly the guide they always had.
nonisolated struct LiveGuideTarget: Equatable, Sendable {

    enum Source: Equatable, Sendable {
        /// From the evidence-checked live preferences.
        case personalized
        /// From the legacy half-body distribution (profiles without adapted preferences).
        case legacy
    }

    let centerX: Double
    /// Nil: there is no vertical target, so the guide is a full-height band.
    let centerY: Double?
    /// Nil: no scale target, so the view's default size applies.
    let width: Double?
    let height: Double?
    /// False draws a muted guide: a habit from two photos is not a strong preference.
    let isConfident: Bool
    let spread: Double
    let source: Source
}

enum LiveGuideTargetResolver {

    /// - Parameter orientation: the camera's current orientation, from the delivered frame.
    ///   Nil until a frame has been seen; adapted preferences are orientation-specific, so no
    ///   guide is offered before then.
    static func resolve(profile: PhotographicPreferenceProfile, orientation: FrameOrientation?) -> LiveGuideTarget? {

        // Profiles carrying adapted preferences: the evaluator's own targets, nothing else.
        if let live = profile.livePreferences {
            guard let orientation else { return nil }
            let slice = live.preferences(for: orientation)

            // The evaluator enforces no horizontal position without this, so there is nothing to show.
            guard case .supported(let horizontal) = slice.checkedHorizontal else { return nil }

            let legacy = LegacyPositionTarget.resolve(position: profile.subjectPositionDistribution,
                                                      photoCount: profile.photoCount)

            var width: Double?, height: Double?
            if case .supported(let scale) = slice.checkedScale, let aspect = scale.targetAspect,
               aspect.isFinite, aspect > 0 {
                // Area = targetArea, shape = typical reference shape.
                width = min(1, (scale.targetArea * aspect).squareRoot())
                height = min(1, (scale.targetArea / aspect).squareRoot())
            }

            return LiveGuideTarget(
                centerX: horizontal.targetX, centerY: legacy?.y, width: width, height: height,
                isConfident: horizontal.strength >= .moderate, spread: horizontal.spread, source: .personalized)
        }

        // Unchanged legacy behaviour.
        let guide = SubjectGuideResolver.resolve(position: profile.halfBodyPositionDistribution,
                                                 photoCount: profile.photoCount)
        guard guide.isConfident else { return nil }
        return LiveGuideTarget(centerX: Double(guide.center.x), centerY: Double(guide.center.y), width: nil, height: nil,
                               isConfident: guide.isConfident, spread: Double(guide.spread), source: .legacy)
    }
}
