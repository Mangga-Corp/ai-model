import Foundation
import CoreGraphics

// MARK: - Live composition preferences (Realtime Camera Guidance, phase 1)
//
// WHAT THIS IS. A small, immutable, read-only view of the user's established
// framing habit, shaped for the live camera: where the subject usually sits
// horizontally and how large the subject usually appears. It is derived ONCE,
// when the camera profile is built (`CameraProfileBridge`), and rides on the
// camera profile value. It is never persisted, never re-derived per frame, and
// can never outlive the profile it came from.
//
// WHAT IT IS NOT. It is not a second profile and not a score. Every number is a
// measurement taken from the user's own reference photos; every "unavailable"
// carries the reason evidence was missing. Nothing is defaulted or guessed.
//
// MEASUREMENT BASIS. The live camera detects the UPPER body only, so these
// targets come from each reference photo's upper-body box, not the full-person
// box the profile screen shows. The two can legitimately differ.

// MARK: - Orientation

/// Portrait or landscape, from an UPRIGHT pixel size.
///
/// Normalised area and horizontal position depend on the frame's aspect ratio,
/// so a landscape reference photo is not comparable with a portrait live frame
/// (and vice versa). Preferences are therefore kept per orientation and only
/// compared within the same one. Near-square frames are neither.
nonisolated enum FrameOrientation: String, Sendable, Hashable, CaseIterable {
    case portrait
    case landscape

    /// Aspect ratios within this distance of 1 are treated as square.
    static let squareTolerance = 0.05

    init?(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let aspect = width / height
        if abs(aspect - 1) <= Self.squareTolerance { return nil }
        self = aspect < 1 ? .portrait : .landscape
    }
}

// MARK: - Support and reasons

/// Why a preference cannot be used for live guidance. A missing preference is
/// never converted into a default one.
nonisolated enum PreferenceUnavailableReason: String, Sendable, Hashable {
    /// No adapted preferences exist at all (no profile, or a profile built without them).
    case noPreferenceData
    /// The profile and the photo results do not describe the same photos.
    case profileInconsistent
    /// No reference photo gave a usable measurement for this orientation.
    case noUsableObservations
    /// Exactly one usable photo: recorded, but a single observation is not a habit.
    case singleObservation
    /// Usable photos disagree: no category holds a clear majority.
    case noRecurringPattern
    /// The photos agree on a category but are spread too widely to name one target.
    case tooVariable
    /// A stored preference value is not a usable number (not finite, or outside the frame).
    case invalidPreferenceData

    var explanation: String {
        switch self {
        case .invalidPreferenceData: return "A stored preference value is not usable, so it was ignored."
        case .noPreferenceData: return "No composition preference was derived from the reference photos."
        case .profileInconsistent: return "The profile and the analysed photos do not match, so they were not used."
        case .noUsableObservations: return "No reference photo gave a usable measurement for this camera orientation."
        case .singleObservation: return "Only one usable reference photo: a single observation is not treated as a habit."
        case .noRecurringPattern: return "The reference photos do not agree on one placement."
        case .tooVariable: return "The reference photos vary too much to name a single target."
        }
    }
}

/// A preference that is either supported by the evidence or unavailable, with the reason.
nonisolated enum PreferenceSupport<Value: Hashable & Sendable>: Hashable, Sendable {
    case supported(Value)
    case unavailable(PreferenceUnavailableReason)

    var value: Value? {
        if case .supported(let value) = self { return value }
        return nil
    }
}

// MARK: - Preferences

/// Where the subject habitually sits horizontally.
///
/// The side is the one RECORDED in the reference photos (the profile's own
/// left / centre / right thirds, applied to the upper-body centre). A centred
/// habit and an off-centre habit are both represented; direction is never
/// inferred for a habit the photos do not agree on.
nonisolated struct HorizontalPreference: Hashable, Sendable {
    /// The recurring thirds zone. `.center` is a centred habit; `.left` / `.right`
    /// are off-centre habits with a recorded side.
    let zone: HorizontalZone
    /// Median upper-body centre x of the photos in `zone` (normalised, 0 = left edge).
    let targetX: Double
    /// Population standard deviation of those x values.
    let spread: Double
    /// Photos in `zone`.
    let agreeingCount: Int
    /// Usable photos in this orientation (includes any that disagree).
    let observationCount: Int
    /// The profile's own strength for this recurrence (`limited` = two agreeing photos).
    let strength: PatternStrength

    var isCentered: Bool { zone == .center }
}

/// How large the subject habitually appears.
nonisolated struct ScalePreference: Hashable, Sendable {
    /// Median upper-body box area as a fraction of the frame. A relative image
    /// measurement: it says nothing about physical distance.
    let targetArea: Double
    /// Coefficient of variation of the areas (standard deviation / mean).
    let spreadRatio: Double
    let observationCount: Int
    /// Median width / height of the reference boxes in normalised frame space. Used ONLY to
    /// draw the target at the right shape; it is not part of the comparison, which is on area.
    /// Nil when it was not measured, in which case no scaled target is drawn.
    var targetAspect: Double? = nil
}

/// Everything learned for one frame orientation.
nonisolated struct OrientationPreferences: Hashable, Sendable {
    /// Reference photos that could be compared in this orientation.
    let usableObservationCount: Int
    let horizontal: PreferenceSupport<HorizontalPreference>
    let scale: PreferenceSupport<ScalePreference>

    static func unavailable(_ reason: PreferenceUnavailableReason, usable: Int = 0) -> OrientationPreferences {
        OrientationPreferences(usableObservationCount: usable,
                               horizontal: .unavailable(reason), scale: .unavailable(reason))
    }

    // MARK: Checked values
    //
    // The ONE place a stored value is validated before use. The preference evaluator and the
    // on-screen guide both read these, so they can never disagree about what the target is,
    // or about whether there is one.

    /// The horizontal preference, or `.unavailable(.invalidPreferenceData)` if its target is
    /// not a usable position (not finite, or outside the frame).
    var checkedHorizontal: PreferenceSupport<HorizontalPreference> {
        guard case .supported(let preference) = horizontal else { return horizontal }
        return preference.targetX.isFinite && (0...1).contains(preference.targetX)
            ? horizontal : .unavailable(.invalidPreferenceData)
    }

    /// The scale preference, or `.unavailable(.invalidPreferenceData)` if its target is not a
    /// usable area fraction.
    var checkedScale: PreferenceSupport<ScalePreference> {
        guard case .supported(let preference) = scale else { return scale }
        return preference.targetArea.isFinite && preference.targetArea > 0 && preference.targetArea <= 1
            ? scale : .unavailable(.invalidPreferenceData)
    }
}

/// How many reference photos were considered and why the rest were left out.
/// Left-out photos are missing evidence, never evidence against anything.
nonisolated struct ReferenceAccounting: Hashable, Sendable {
    var totalPhotos = 0
    /// Subject position was not determined for these photos.
    var undeterminedPositioning = 0
    /// Determined, but Vision produced no upper-body box.
    var noUpperBodyBox = 0
    /// Evidence quality below `LiveCompositionPreferenceAdapter.minimumQuality`.
    var lowQuality = 0
    /// The upper-body box touches the frame edge, so its centre and area describe only part of the person.
    var clippedUpperBody = 0
    /// Orientation could not be established (no preparation record, or a near-square photo).
    var unknownOrientation = 0
    var usablePortrait = 0
    var usableLandscape = 0

    var usable: Int { usablePortrait + usableLandscape }
}

/// The adapted preferences, per frame orientation.
nonisolated struct LiveCompositionPreferences: Hashable, Sendable {
    let portrait: OrientationPreferences
    let landscape: OrientationPreferences
    let accounting: ReferenceAccounting

    func preferences(for orientation: FrameOrientation) -> OrientationPreferences {
        switch orientation {
        case .portrait: return portrait
        case .landscape: return landscape
        }
    }
}
