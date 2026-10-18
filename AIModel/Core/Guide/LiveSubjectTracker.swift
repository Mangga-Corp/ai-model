import Foundation
import CoreGraphics

/// One person detected in the current pass, in FRAME space (normalised, origin top-left).
nonisolated struct LiveSubjectDetection: Sendable, Equatable {
    let box: CGRect
    let confidence: Double

    var area: Double { ImageSpace.area(box) }
}

/// What the tracker decided for one detection pass.
nonisolated struct LiveSubjectUpdate: Sendable, Equatable {

    enum State: Sendable, Equatable {
        /// Someone was chosen for the first time (or again after the previous subject was gone).
        case acquired
        /// The tracked subject was found again, by geometric continuity.
        case continued
        /// The tracked subject is not matched this pass, but is within the dropout grace.
        /// No box is reported, and nobody else is adopted.
        case holding
        /// The tracked subject has not been matched for longer than the grace period and was
        /// released; there is nobody else to adopt.
        case lost
        /// Nobody is being tracked and no detection is usable.
        case none
        /// The pass arrived too late (or with an unusable clock) and was ignored entirely. It
        /// neither moves the track nor its dropout timer, and must not drive guidance.
        case stale
    }

    let state: State
    /// The box to guide on this pass. Nil for `holding`, `lost` and `none`.
    let box: CGRect?
    let confidence: Double?
    /// True when more than one candidate fits equally well (a continuation that geometry
    /// cannot separate), or when the first choice was close to another person in size.
    /// Reported honestly: the detector provides no identity, so this is a guess.
    let isAmbiguous: Bool
    /// True when `box` belongs to a different selection than the previous pass's box. A
    /// caller should drop any state that was specific to the previous subject.
    let subjectChanged: Bool
}

/// Keeps live guidance on the SAME person from pass to pass.
///
/// WHAT THE DETECTOR PROVIDES. Vision's human-rectangle request returns boxes and a
/// confidence, with NO identity: nothing says that a box in this pass is the person from the
/// last one. So continuity here is GEOMETRIC and conservative, and it can be fooled by two
/// people who overlap or swap places. That limitation is real; it is reported (`isAmbiguous`)
/// and documented rather than hidden.
///
/// POLICY (all numbers in `GuidanceStabilityPolicy`):
///   - First choice: the same deterministic rule the offline analysis uses
///     (`SubjectSelector`: eligible by confidence and area, largest box, near-ties broken by
///     confidence, then centrality, then leftmost).
///   - Afterwards size does NOT decide. The tracked subject is continued by the detection that
///     overlaps its last box the most, so a bystander who becomes slightly larger is ignored.
///   - If nothing continues it, the subject is HELD for the dropout grace: no box is reported
///     and nobody else is adopted, so a brief dropout or a person walking past does not steal
///     the guidance.
///   - After the grace the subject is released and the next pass chooses afresh.
///   - A pass that arrives too late is ignored (stale), never used.
///
/// Pure value logic, O(number of people) per pass, no allocation beyond a small array.
nonisolated struct LiveSubjectTracker: Sendable, Equatable {

    private struct Track: Sendable, Equatable {
        var box: CGRect
        var lastMatched: TimeInterval
    }

    private var track: Track?
    /// Capture time of the newest pass accepted so far. Each camera frame starts its own
    /// asynchronous detection, so passes can FINISH out of order; an older one finishing late
    /// must not overwrite what a newer one already established.
    private var newestPass: TimeInterval = -.infinity

    init() {}

    /// Forget the tracked subject (camera stopped, profile changed...).
    mutating func reset() {
        track = nil
        newestPass = -.infinity
    }

    var isTracking: Bool { track != nil }

    /// - Parameters:
    ///   - detections: every person found this pass.
    ///   - capturedAt: when the frame arrived (`systemUptime`).
    ///   - now: the current `systemUptime`; `now - capturedAt` is the age of this pass.
    mutating func update(detections: [LiveSubjectDetection], capturedAt: TimeInterval, now: TimeInterval) -> LiveSubjectUpdate {
        func result(_ state: LiveSubjectUpdate.State, _ detection: LiveSubjectDetection? = nil,
                    ambiguous: Bool = false, changed: Bool = false) -> LiveSubjectUpdate {
            LiveSubjectUpdate(state: state, box: detection?.box, confidence: detection?.confidence,
                              isAmbiguous: ambiguous, subjectChanged: changed)
        }

        // A pass that is not current, or whose clock is nonsense, must not move anything:
        // not the track, and not its lost-timer. The caller skips it.
        guard capturedAt.isFinite, now.isFinite, now >= capturedAt, now - capturedAt <= GuidanceStabilityPolicy.maximumPassAge,
              capturedAt > newestPass else {
            return result(.stale)
        }
        newestPass = capturedAt

        let usable = detections.filter(Self.isUsable)

        if let current = track {
            if let match = Self.continuation(of: current.box, among: usable) {
                track = Track(box: match.detection.box, lastMatched: capturedAt)
                return result(.continued, match.detection, ambiguous: match.isAmbiguous)
            }
            if capturedAt - current.lastMatched <= GuidanceStabilityPolicy.dropoutGrace {
                return result(.holding)
            }
            // Gone for longer than the grace: release, then choose afresh from this pass.
            track = nil
            if let chosen = Self.acquire(from: usable) {
                track = Track(box: chosen.detection.box, lastMatched: capturedAt)
                return result(.acquired, chosen.detection, ambiguous: chosen.isAmbiguous, changed: true)
            }
            return result(.lost, changed: true)
        }

        if let chosen = Self.acquire(from: usable) {
            track = Track(box: chosen.detection.box, lastMatched: capturedAt)
            return result(.acquired, chosen.detection, ambiguous: chosen.isAmbiguous, changed: true)
        }
        return result(.none)
    }

    // MARK: Selection

    /// Same eligibility as the offline selector, plus sane geometry.
    private static func isUsable(_ d: LiveSubjectDetection) -> Bool {
        let b = d.box
        guard b.origin.x.isFinite, b.origin.y.isFinite, b.width.isFinite, b.height.isFinite,
              b.width > 0, b.height > 0, d.confidence.isFinite,
              b.minX >= -PersonalizedCompositionEvaluator.boundsSlack, b.minY >= -PersonalizedCompositionEvaluator.boundsSlack,
              b.maxX <= 1 + PersonalizedCompositionEvaluator.boundsSlack, b.maxY <= 1 + PersonalizedCompositionEvaluator.boundsSlack
        else { return false }
        return d.confidence >= SubjectSelector.minimumConfidence && d.area >= SubjectSelector.minimumArea
    }

    /// First choice, by the offline rule, so a person is ranked the same way live and offline.
    private static func acquire(from usable: [LiveSubjectDetection]) -> (detection: LiveSubjectDetection, isAmbiguous: Bool)? {
        guard !usable.isEmpty else { return nil }
        let candidates = usable.enumerated().map { index, d in
            HumanCandidate(id: index, box: d.box, confidence: d.confidence, upperBodyBox: nil, upperBodyConfidence: nil)
        }
        let selection = SubjectSelector.select(from: candidates)
        guard let primary = selection.primary else { return nil }
        return (usable[primary.id], selection.info.isAmbiguous)
    }

    /// The detection that continues `previous`, if any.
    private static func continuation(of previous: CGRect, among usable: [LiveSubjectDetection])
        -> (detection: LiveSubjectDetection, isAmbiguous: Bool)? {
        var best: (d: LiveSubjectDetection, score: Double, distance: Double)?
        var runnerUp = -Double.infinity

        /// Higher overlap wins; then the nearer centre; then the leftmost, then the highest box,
        /// so that the answer never depends on the order Vision happened to list people in.
        func isBetter(_ a: (d: LiveSubjectDetection, score: Double, distance: Double),
                      than b: (d: LiveSubjectDetection, score: Double, distance: Double)) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.distance != b.distance { return a.distance < b.distance }
            if a.d.box.minX != b.d.box.minX { return a.d.box.minX < b.d.box.minX }
            return a.d.box.minY < b.d.box.minY
        }

        for d in usable {
            let iou = overlap(previous, d.box)
            if iou < GuidanceStabilityPolicy.minimumOverlap {
                // Fast sideways motion can drop the overlap below the rule while it is still
                // the same person: accept a close detection of plausible size. Its score is
                // its (low) overlap, so it ranks below any detection that overlaps enough.
                guard isNeighbour(previous, d.box) else { continue }
            }
            let candidate = (d: d, score: iou, distance: centreDistance(previous, d.box))
            if let current = best {
                if isBetter(candidate, than: current) {
                    runnerUp = max(runnerUp, current.score)
                    best = candidate
                } else {
                    runnerUp = max(runnerUp, candidate.score)
                }
            } else {
                best = candidate
            }
        }
        guard let best else { return nil }
        let ambiguous = runnerUp.isFinite && best.score - runnerUp < GuidanceStabilityPolicy.ambiguousOverlapGap
        return (best.d, ambiguous)
    }

    // MARK: Geometry

    /// Intersection over union of two boxes (0...1).
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = ImageSpace.intersectionArea(a, b)
        let union = ImageSpace.area(a) + ImageSpace.area(b) - inter
        return union > 0 ? inter / union : 0
    }

    private static func centreDistance(_ a: CGRect, _ b: CGRect) -> Double {
        let dx = Double(a.midX - b.midX), dy = Double(a.midY - b.midY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func isNeighbour(_ previous: CGRect, _ candidate: CGRect) -> Bool {
        let side = Double(max(previous.width, previous.height))
        guard side > 0, centreDistance(previous, candidate) <= side * GuidanceStabilityPolicy.neighbourDistanceFactor else { return false }
        let a = ImageSpace.area(previous), b = ImageSpace.area(candidate)
        guard a > 0, b > 0 else { return false }
        let ratio = b / a
        return ratio <= GuidanceStabilityPolicy.neighbourAreaRatio && ratio >= 1 / GuidanceStabilityPolicy.neighbourAreaRatio
    }
}
