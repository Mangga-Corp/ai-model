import Foundation

/// Every threshold that decides how STABLE live guidance is, in one place.
///
/// Guidance is stabilised in three layers, from the camera outward:
///   1. SUBJECT CONTINUITY (`LiveSubjectTracker`): which person is being guided.
///   2. SPATIAL HYSTERESIS (`CompositionEvaluator`): a measurement that crossed a threshold
///      must come back clearly inside it before the problem is considered resolved.
///   3. TEMPORAL DEBOUNCE (`CompositionGuidanceEngine`): an issue must persist for a few
///      detection passes before it is shown. Its own `stabilityWindow` (3 passes) and
///      `readyHoldFrames` (5 passes) are unchanged from before this policy existed.
///
/// IMPORTANT: none of the values below were tuned on a physical camera. They are design
/// parameters chosen to be small, explainable and testable. Their real-world adequacy
/// (detector jitter amplitude, walking speed, pan speed) is UNVALIDATED until measured on
/// a device. Detection runs about every 0.14 s (`FrameDelegate.interval`), i.e. ~7 passes
/// per second; durations below are quoted in passes at that rate.
nonisolated enum GuidanceStabilityPolicy {

    // MARK: Subject continuity

    /// A detection continues the tracked subject when its box overlaps the previous one by
    /// at least this much (intersection over union). A person walking or a hand-held camera
    /// moving at a normal pace shifts a box far less than this between passes.
    static let minimumOverlap = 0.30

    /// Fast sideways motion can drop the overlap below `minimumOverlap` while it is still
    /// clearly the same person. A detection also continues the track when its centre is
    /// within this multiple of the track's larger side, AND its size is plausible.
    static let neighbourDistanceFactor = 0.6

    /// "Plausible size" for the neighbour rule: the area may change by at most this factor
    /// in either direction between consecutive passes.
    static let neighbourAreaRatio = 2.0

    /// Two candidate continuations whose overlap differs by less than this cannot be told
    /// apart by geometry alone (for example two people standing close together). The best
    /// is still used, but the choice is reported as ambiguous.
    static let ambiguousOverlapGap = 0.10

    /// How long a tracked subject may go unmatched before it counts as gone. Matches
    /// `SubjectFocusTracker.lostSubjectGrace` (1.0 s), so that focus and guidance agree on
    /// when a person has really left. Competing detections are ignored during this time.
    static let dropoutGrace: TimeInterval = 1.0

    /// A detection pass older than this when it reaches the tracker is stale and is not used.
    /// About three missed passes.
    static let maximumPassAge: TimeInterval = 0.5

    // MARK: Spatial hysteresis

    /// Once a measurement has been flagged, it is only considered resolved when it is back
    /// within this fraction of the original tolerance. 0.8 means "20% inside the threshold".
    /// Entering a mismatch still happens at the original threshold, so behaviour on the way
    /// IN is unchanged; only the way OUT is made sticky.
    static let releaseFraction = 0.8

    /// Once a subject has been flagged as touching the frame edge, its box must be this far
    /// beyond the normal clip margin (in frame widths / heights) before it counts as free.
    static let clipReleaseMargin = 0.02

    // MARK: Observation freshness

    /// The oldest measurement the preference checks will still treat as current. About three
    /// missed detection passes.
    static let maximumObservationAge: TimeInterval = 0.5
}
