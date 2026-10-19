import XCTest
import Combine
import CoreGraphics
@testable import AIModel

/// Realtime Camera Guidance, phase 2: stability, visual consistency and beginner-friendly wording.
///
/// Deterministic and camera-free. They exercise, in order: subject continuity, spatial
/// hysteresis, wording and the meaning of "ready", the shared guide target, preview geometry,
/// and finally the whole path from detections to the visible instruction.
@MainActor
final class GuidanceStabilityTests: XCTestCase {

    // MARK: - Fixtures

    private let portraitFrame = CGSize(width: 3000, height: 4000)
    private let landscapeFrame = CGSize(width: 4000, height: 3000)

    private func det(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 0.3, _ h: CGFloat = 0.3,
                     confidence: Double = 0.9) -> LiveSubjectDetection {
        LiveSubjectDetection(box: CGRect(x: x, y: y, width: w, height: h), confidence: confidence)
    }

    /// One tracker pass captured at `t`, evaluated 50 ms later.
    private func step(_ tracker: inout LiveSubjectTracker, _ detections: [LiveSubjectDetection], at t: TimeInterval,
                      age: TimeInterval = 0.05) -> LiveSubjectUpdate {
        tracker.update(detections: detections, capturedAt: t, now: t + age)
    }

    // MARK: - Subject continuity

    func testAStableSubjectIsAcquiredOnceAndThenContinued() {
        var tracker = LiveSubjectTracker()
        let first = step(&tracker, [det(0.3, 0.3)], at: 1.0)
        XCTAssertEqual(first.state, .acquired)
        XCTAssertTrue(first.subjectChanged)

        for i in 1...6 {
            let next = step(&tracker, [det(0.3 + 0.004 * CGFloat(i), 0.3)], at: 1.0 + 0.14 * Double(i))
            XCTAssertEqual(next.state, .continued)
            XCTAssertFalse(next.subjectChanged, "following the same person is not a change of subject")
            XCTAssertNotNil(next.box)
        }
    }

    func testTheFirstChoiceUsesTheOfflineRuleAndDoesNotDependOnOrder() {
        // Two people of very similar size: the higher-confidence one wins the tie, whatever the order.
        let a = det(0.05, 0.3, 0.3, 0.3, confidence: 0.80)
        let b = det(0.60, 0.3, 0.3, 0.3, confidence: 0.95)
        var t1 = LiveSubjectTracker(), t2 = LiveSubjectTracker()
        let r1 = step(&t1, [a, b], at: 1)
        let r2 = step(&t2, [b, a], at: 1)
        XCTAssertEqual(r1.box, b.box)
        XCTAssertEqual(r1.box, r2.box)
        XCTAssertTrue(r1.isAmbiguous, "two people of similar size: the choice is reported as uncertain")

        // A clearly larger person is not ambiguous.
        var t3 = LiveSubjectTracker()
        let clear = step(&t3, [det(0.05, 0.3, 0.2, 0.2), det(0.5, 0.2, 0.45, 0.6)], at: 1)
        XCTAssertFalse(clear.isAmbiguous)
        XCTAssertEqual(clear.box, CGRect(x: 0.5, y: 0.2, width: 0.45, height: 0.6))
    }

    func testACompetingPersonBecomingLargerDoesNotStealTheGuidance() {
        var tracker = LiveSubjectTracker()
        let subject = det(0.10, 0.3, 0.3, 0.3)
        _ = step(&tracker, [subject, det(0.65, 0.3, 0.28, 0.28)], at: 1.0)

        // The bystander grows past the subject in size; the subject has barely moved.
        let bigger = det(0.62, 0.25, 0.34, 0.34)
        XCTAssertGreaterThan(bigger.area, subject.area)
        let next = step(&tracker, [det(0.11, 0.3, 0.3, 0.3), bigger], at: 1.14)
        XCTAssertEqual(next.state, .continued)
        XCTAssertEqual(next.box, CGRect(x: 0.11, y: 0.3, width: 0.3, height: 0.3), "still the original person")
        XCTAssertFalse(next.subjectChanged)
    }

    func testASelectedSubjectThatBrieflyDisappearsIsHeldAndNobodyElseIsAdopted() {
        var tracker = LiveSubjectTracker()
        _ = step(&tracker, [det(0.10, 0.3), det(0.60, 0.3, 0.28, 0.28)], at: 1.0)

        // The subject is missed for three passes (0.42 s) while the other person remains.
        for i in 1...3 {
            let held = step(&tracker, [det(0.60, 0.3, 0.28, 0.28)], at: 1.0 + 0.14 * Double(i))
            XCTAssertEqual(held.state, .holding)
            XCTAssertNil(held.box, "no box is reported while the subject is not observed")
            XCTAssertFalse(held.subjectChanged)
        }
        // They come back: same subject, no change.
        let back = step(&tracker, [det(0.11, 0.3), det(0.60, 0.3, 0.28, 0.28)], at: 1.0 + 0.14 * 4)
        XCTAssertEqual(back.state, .continued)
        XCTAssertEqual(back.box?.minX ?? 0, 0.11, accuracy: 1e-9)
        XCTAssertFalse(back.subjectChanged)
    }

    func testASubjectWhoHasReallyLeftIsReleasedAndAnotherPersonIsAdoptedAfterTheGrace() {
        var tracker = LiveSubjectTracker()
        _ = step(&tracker, [det(0.10, 0.3)], at: 1.0)
        let other = det(0.60, 0.3, 0.28, 0.28)

        XCTAssertEqual(step(&tracker, [other], at: 1.0 + GuidanceStabilityPolicy.dropoutGrace - 0.01).state, .holding,
                       "still inside the grace period")
        let after = step(&tracker, [other], at: 1.0 + GuidanceStabilityPolicy.dropoutGrace + 0.01)
        XCTAssertEqual(after.state, .acquired)
        XCTAssertTrue(after.subjectChanged, "a different person: anything specific to the old subject must be dropped")
        XCTAssertEqual(after.box, other.box)
    }

    func testWhenNobodyRemainsTheSubjectIsLostAndThenNothingIsTracked() {
        var tracker = LiveSubjectTracker()
        _ = step(&tracker, [det(0.10, 0.3)], at: 1.0)
        let lost = step(&tracker, [], at: 1.0 + GuidanceStabilityPolicy.dropoutGrace + 0.05)
        XCTAssertEqual(lost.state, .lost)
        XCTAssertNil(lost.box)
        XCTAssertTrue(lost.subjectChanged)
        XCTAssertEqual(step(&tracker, [], at: 3.0).state, .none)
        XCTAssertFalse(tracker.isTracking)
    }

    func testAPersonWhoReturnsAfterTheGraceIsAcquiredAgainNotSilentlyContinued() {
        var tracker = LiveSubjectTracker()
        _ = step(&tracker, [det(0.10, 0.3)], at: 1.0)
        _ = step(&tracker, [], at: 1.0 + GuidanceStabilityPolicy.dropoutGrace + 0.05)          // lost
        let back = step(&tracker, [det(0.10, 0.3)], at: 2.5)
        XCTAssertEqual(back.state, .acquired)
        XCTAssertTrue(back.subjectChanged, "no identity is available, so a return after the grace is a fresh choice")
    }

    func testUnusableDetectionsAreIgnoredAndCannotBeSelected() {
        let bad: [LiveSubjectDetection] = [
            LiveSubjectDetection(box: CGRect(x: CGFloat.nan, y: 0.3, width: 0.3, height: 0.3), confidence: 0.9),
            LiveSubjectDetection(box: CGRect(x: 0.3, y: 0.3, width: 0, height: 0.3), confidence: 0.9),
            LiveSubjectDetection(box: CGRect(x: 0.9, y: 0.3, width: 0.5, height: 0.3), confidence: 0.9),    // far outside the frame
            det(0.3, 0.3, confidence: 0.10),                                                              // below the confidence floor
            det(0.3, 0.3, 0.05, 0.05),                                                                    // 0.25% of the frame
            LiveSubjectDetection(box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), confidence: .nan)
        ]
        var tracker = LiveSubjectTracker()
        let r = step(&tracker, bad, at: 1.0)
        XCTAssertEqual(r.state, .none, "nothing can be selected reliably")
        XCTAssertNil(r.box)
        XCTAssertFalse(tracker.isTracking)

        // A usable person among unusable ones is still found.
        var other = LiveSubjectTracker()
        XCTAssertEqual(step(&other, bad + [det(0.4, 0.3)], at: 1.0).state, .acquired)
    }

    func testStaleAndOutOfOrderPassesNeverMoveTheTrack() {
        var tracker = LiveSubjectTracker()
        _ = step(&tracker, [det(0.10, 0.3)], at: 10.0)

        // Too old when it arrives.
        XCTAssertEqual(tracker.update(detections: [det(0.60, 0.3)], capturedAt: 10.2, now: 11.0).state, .stale)
        // From the future, or with a nonsense clock.
        XCTAssertEqual(tracker.update(detections: [det(0.60, 0.3)], capturedAt: 12.0, now: 11.0).state, .stale)
        XCTAssertEqual(tracker.update(detections: [det(0.60, 0.3)], capturedAt: .nan, now: 11.0).state, .stale)
        // An older pass finishing after a newer one (fresh enough by age, but earlier than one already used).
        XCTAssertEqual(tracker.update(detections: [det(0.60, 0.3)], capturedAt: 9.95, now: 10.1).state, .stale)

        // None of that disturbed the subject: it continues normally, and its timer was not advanced.
        let next = step(&tracker, [det(0.11, 0.3)], at: 10.14)
        XCTAssertEqual(next.state, .continued)
        XCTAssertEqual(next.box?.minX ?? 0, 0.11, accuracy: 1e-9)
    }

    func testFastSidewaysMotionStillContinuesButAJumpToSomeoneElseDoesNot() {
        let start = det(0.20, 0.3, 0.3, 0.3)
        // Shifted 0.17: overlap (IoU 0.28) is below the overlap rule, but it is close and the same size.
        XCTAssertLessThan(LiveSubjectTracker.overlap(start.box, det(0.37, 0.3).box), GuidanceStabilityPolicy.minimumOverlap)
        var near = LiveSubjectTracker()
        _ = step(&near, [start], at: 1.0)
        XCTAssertEqual(step(&near, [det(0.37, 0.3)], at: 1.14).state, .continued)

        // Shifted 0.5: too far to be the same person moving.
        var far = LiveSubjectTracker()
        _ = step(&far, [start], at: 1.0)
        XCTAssertEqual(step(&far, [det(0.70, 0.3)], at: 1.14).state, .holding)

        // Close, but a very different size: not the same person.
        var sized = LiveSubjectTracker()
        _ = step(&sized, [start], at: 1.0)
        XCTAssertEqual(step(&sized, [det(0.37, 0.2, 0.6, 0.6)], at: 1.14).state, .holding)
    }

    func testTwoEquallyGoodContinuationsAreReportedAsAmbiguousAndChosenDeterministically() {
        let previous = det(0.40, 0.3, 0.2, 0.3)
        let left = det(0.35, 0.3, 0.2, 0.3), right = det(0.45, 0.3, 0.2, 0.3)
        var a = LiveSubjectTracker(), b = LiveSubjectTracker()
        _ = step(&a, [previous], at: 1.0); _ = step(&b, [previous], at: 1.0)
        let r1 = step(&a, [left, right], at: 1.14)
        let r2 = step(&b, [right, left], at: 1.14)
        XCTAssertTrue(r1.isAmbiguous, "geometry cannot tell these apart; there is no identity")
        XCTAssertEqual(r1.box, r2.box, "but the choice does not depend on the order they were listed in")
    }

    func testResetForgetsTheSubject() {
        var tracker = LiveSubjectTracker()
        _ = step(&tracker, [det(0.10, 0.3)], at: 1.0)
        tracker.reset()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertEqual(step(&tracker, [det(0.6, 0.3)], at: 1.1).state, .acquired)
    }

    // MARK: - Fixtures for evaluation

    private func slice(_ zone: HorizontalZone, _ x: Double, _ area: Double, aspect: Double? = 1) -> OrientationPreferences {
        OrientationPreferences(
            usableObservationCount: 3,
            horizontal: .supported(HorizontalPreference(zone: zone, targetX: x, spread: 0.02, agreeingCount: 3,
                                                        observationCount: 3, strength: .moderate)),
            scale: .supported(ScalePreference(targetArea: area, spreadRatio: 0.05, observationCount: 3, targetAspect: aspect)))
    }

    private func prefs(portrait: OrientationPreferences, landscape: OrientationPreferences = .unavailable(.noUsableObservations)) -> LiveCompositionPreferences {
        LiveCompositionPreferences(portrait: portrait, landscape: landscape, accounting: ReferenceAccounting())
    }

    private var centred: LiveCompositionPreferences { prefs(portrait: slice(.center, 0.5, 0.16)) }

    private let evaluator = CompositionEvaluator()

    private func person(cx: CGFloat = 0.5, y: CGFloat = 0.3, w: CGFloat = 0.4, h: CGFloat = 0.4) -> SceneMeasurement {
        SceneMeasurement(person: SceneElement(kind: .person,
                                              box: CGRect(x: cx - w / 2, y: y, width: w, height: h), confidence: nil),
                         personLost: false)
    }

    private func context(_ p: LiveCompositionPreferences?, capturedAt: TimeInterval = 10, now: TimeInterval = 10.1,
                         frame: CGSize? = nil) -> LivePersonalization? {
        p.map { LivePersonalization(preferences: $0, frameSize: frame ?? portraitFrame, isMirrored: false,
                                    capturedAt: capturedAt, now: now) }
    }

    private func legacyPosition(_ x: Double, _ y: Double) -> PositionDistribution {
        PositionDistribution(meanX: x, meanY: y, stdDevX: 0.05, stdDevY: 0.05, isConsistent: true)
    }

    private func legacySize(_ area: Double) -> SizeDistribution {
        SizeDistribution(meanArea: area, minArea: area, maxArea: area, stdDev: 0.01, isConsistent: true)
    }

    private func evaluate(_ m: SceneMeasurement, latched: ActiveMismatches = [], preferences: LiveCompositionPreferences? = nil,
                          position: PositionDistribution? = nil, size: SizeDistribution? = nil, photoCount: Int = 4,
                          capturedAt: TimeInterval = 10, now: TimeInterval = 10.1) -> CompositionEvaluation {
        evaluator.evaluate(measurement: m, position: position, size: size, photoCount: photoCount,
                           personalization: context(preferences, capturedAt: capturedAt, now: now), latched: latched)
    }

    // MARK: - Spatial hysteresis

    func testEnteringAMismatchStillHappensAtThePlainTolerance() {
        // Unchanged on the way in: 0.151 from the target is a mismatch, 0.149 is not.
        XCTAssertTrue(evaluate(person(cx: 0.651), preferences: centred).activeMismatches.contains(.horizontal))
        XCTAssertTrue(evaluate(person(cx: 0.649), preferences: centred).activeMismatches.isEmpty)
    }

    func testAFlaggedMismatchOnlyClearsOnceClearlyInsideItsTolerance() {
        let latched: ActiveMismatches = [.horizontal]
        XCTAssertTrue(evaluate(person(cx: 0.64), latched: latched, preferences: centred).activeMismatches.contains(.horizontal),
                      "0.14 from the target: inside the plain 0.15, but not inside 80% of it (0.12)")
        XCTAssertTrue(evaluate(person(cx: 0.619), latched: latched, preferences: centred).activeMismatches.isEmpty,
                      "0.119: clearly back inside")
    }

    func testMeasurementNoiseAroundTheThresholdDoesNotFlipTheStateEveryPass() {
        // Centre x wobbles ±0.003 around the 0.15 threshold.
        let xs: [CGFloat] = [0.647, 0.653, 0.648, 0.652, 0.646, 0.654, 0.649, 0.651, 0.647, 0.653, 0.648, 0.652]
        func transitions(useLatch: Bool) -> Int {
            var latched: ActiveMismatches = []
            var previous = false, changes = 0
            for x in xs {
                let e = evaluate(person(cx: x), latched: useLatch ? latched : [], preferences: centred)
                latched = e.activeMismatches
                let flagged = e.activeMismatches.contains(.horizontal)
                if flagged != previous { changes += 1 }
                previous = flagged
            }
            return changes
        }
        XCTAssertGreaterThan(transitions(useLatch: false), 4, "premise: without hysteresis the state flips repeatedly")
        XCTAssertEqual(transitions(useLatch: true), 1, "with hysteresis it is raised once and stays raised")
    }

    func testScaleAndVerticalAndClippingHaveTheSameStickiness() {
        // Too small: plain lower bound 0.08 (area), latched release at 0.16 * (1 - 0.4) = 0.096.
        let small = person(w: 0.30, h: 0.30)              // 0.09: above 0.08, below the 0.096 release bound
        XCTAssertTrue(evaluate(small, preferences: centred).activeMismatches.isEmpty)
        XCTAssertTrue(evaluate(small, latched: [.tooSmall], preferences: centred).activeMismatches.contains(.tooSmall))
        XCTAssertTrue(evaluate(person(w: 0.32, h: 0.32), latched: [.tooSmall], preferences: centred).activeMismatches.isEmpty)

        // Too large: upper bound 0.24, latched 0.16 * 1.4 = 0.224. Keep the box well inside the frame.
        let large = person(y: 0.2, w: 0.58, h: 0.40)      // 0.232: below 0.24, above the 0.224 release bound
        XCTAssertTrue(evaluate(large, preferences: centred).activeMismatches.isEmpty)
        XCTAssertTrue(evaluate(large, latched: [.tooLarge], preferences: centred).activeMismatches.contains(.tooLarge))

        // Vertical, legacy target y = 0.5: box centre y 0.64 is 0.14 away.
        let high = person(y: 0.44, w: 0.4, h: 0.4)        // centre y 0.64
        XCTAssertTrue(evaluate(high, position: legacyPosition(0.5, 0.5)).activeMismatches.isEmpty)
        XCTAssertTrue(evaluate(high, latched: [.vertical], position: legacyPosition(0.5, 0.5)).activeMismatches.contains(.vertical))

        // Clipping: 0.015 from the left edge is free (> 0.01), but once flagged it needs > 0.03.
        let nearEdge = SceneMeasurement(person: SceneElement(kind: .person, box: CGRect(x: 0.015, y: 0.3, width: 0.3, height: 0.3), confidence: nil), personLost: false)
        XCTAssertNil(evaluate(nearEdge, position: nil).primaryIssue)
        XCTAssertEqual(evaluate(nearEdge, latched: [.clipped], position: nil).primaryIssue, .subjectClipped)
        let clear = SceneMeasurement(person: SceneElement(kind: .person, box: CGRect(x: 0.035, y: 0.3, width: 0.3, height: 0.3), confidence: nil), personLost: false)
        XCTAssertNil(evaluate(clear, latched: [.clipped], position: nil).primaryIssue)
    }

    func testLegacyProfilesGetTheSameHysteresis() {
        // Legacy distributions, no adapted preferences: horizontal target 0.5.
        let m = person(cx: 0.64)
        XCTAssertNil(evaluate(m, position: legacyPosition(0.5, 0.5)).primaryIssue)
        XCTAssertEqual(evaluate(m, latched: [.horizontal], position: legacyPosition(0.5, 0.5)).primaryIssue,
                       .subjectOffCentreHorizontally)
    }

    func testAnUnreliablePassKeepsTheLatchInsteadOfResettingIt() {
        let stale = evaluate(person(cx: 0.64), latched: [.horizontal, .tooSmall], preferences: centred, capturedAt: 10, now: 12)
        XCTAssertNil(stale.primaryIssue, "a stale measurement raises nothing")
        XCTAssertFalse(stale.isReady)
        XCTAssertTrue(stale.activeMismatches.contains(.horizontal), "but it does not forget what was flagged")
        XCTAssertTrue(stale.activeMismatches.contains(.tooSmall))
        XCTAssertEqual(stale.applicability, .measurementUnreliable)
    }

    func testAPersistentMismatchIsAnnouncedOnceAndAResolvedOneClears() {
        var engine = CompositionGuidanceEngine()
        var latched: ActiveMismatches = []
        func feed(_ x: CGFloat) -> String? {
            let e = evaluate(person(cx: x), latched: latched, preferences: centred)
            latched = e.activeMismatches
            return engine.update(with: e)
        }
        XCTAssertNil(feed(0.75)); XCTAssertNil(feed(0.75))
        let shown = feed(0.75)
        XCTAssertEqual(shown, "Move the subject slightly toward the left of the frame")
        for _ in 0..<5 { XCTAssertEqual(feed(0.74), shown, "unchanged while the mismatch persists") }

        // The photographer fixes it: gone after the same three passes.
        XCTAssertEqual(feed(0.5), shown); XCTAssertEqual(feed(0.5), shown)
        XCTAssertNil(feed(0.5))
    }

    func testAMeaningfulChangeUpdatesTheInstructionWithoutBeingSluggish() {
        var engine = CompositionGuidanceEngine()
        var latched: ActiveMismatches = []
        func feed(_ m: SceneMeasurement) -> String? {
            let e = evaluate(m, latched: latched, preferences: centred)
            latched = e.activeMismatches
            return engine.update(with: e)
        }
        for _ in 0..<3 { _ = feed(person(cx: 0.75)) }
        XCTAssertEqual(engine.currentInstruction, "Move the subject slightly toward the left of the frame")
        // Swinging to the other side flips the wording at once: the issue is unchanged, only its direction.
        XCTAssertEqual(feed(person(cx: 0.25)), "Move the subject slightly toward the right of the frame")
    }

    func testConflictingIssuesAreShownOneAtATimeInPriorityOrder() {
        var latched: ActiveMismatches = []
        func primary(_ m: SceneMeasurement) -> CompositionEvaluation.Issue? {
            let e = evaluate(m, latched: latched, preferences: centred, position: legacyPosition(0.5, 0.75))
            latched = e.activeMismatches
            return e.primaryIssue
        }
        // Too small, off-centre and too high at once: size first.
        XCTAssertEqual(primary(person(cx: 0.25, y: 0.1, w: 0.2, h: 0.2)), .subjectTooSmall)
        // Fix the size: now position.
        XCTAssertEqual(primary(person(cx: 0.25, y: 0.1)), .subjectOffCentreHorizontally)
        XCTAssertEqual(primary(person(cx: 0.5, y: 0.1)), .subjectOffCentreVertically)
        XCTAssertNil(primary(person(cx: 0.5, y: 0.55)))
    }

    func testRepeatedEquivalentEvaluationsGiveTheSameInstruction() {
        var engine = CompositionGuidanceEngine()
        var shown: [String?] = []
        var latched: ActiveMismatches = []
        for _ in 0..<12 {
            let e = evaluate(person(w: 0.2, h: 0.2), latched: latched, preferences: centred)
            latched = e.activeMismatches
            shown.append(engine.update(with: e))
        }
        XCTAssertEqual(Set(shown.compactMap { $0 }).count, 1, "one instruction, repeated")
        XCTAssertEqual(shown.first(where: { $0 != nil }), "Move a little closer to make the subject larger")
    }

    // MARK: - Wording

    func testEveryInstructionNamesAnActionAndOnlyStatesADirectionItWasGiven() {
        typealias W = GuidanceWording
        XCTAssertEqual(W.instruction(for: .subjectTooSmall, horizontal: nil, vertical: nil), "Move a little closer to make the subject larger")
        XCTAssertEqual(W.instruction(for: .subjectTooLarge, horizontal: nil, vertical: nil), "Move back a little to leave more room around the subject")
        XCTAssertEqual(W.instruction(for: .subjectClipped, horizontal: nil, vertical: nil), "Subject is cut off — pull back to fit the whole subject")
        XCTAssertEqual(W.instruction(for: .noSubject, horizontal: nil, vertical: nil), "Point the camera at your subject")

        XCTAssertEqual(W.instruction(for: .subjectOffCentreHorizontally, horizontal: .towardLeft, vertical: nil),
                       "Move the subject slightly toward the left of the frame")
        XCTAssertEqual(W.instruction(for: .subjectOffCentreHorizontally, horizontal: .towardRight, vertical: nil),
                       "Move the subject slightly toward the right of the frame")
        XCTAssertEqual(W.instruction(for: .subjectOffCentreVertically, horizontal: nil, vertical: .higher),
                       "Move the subject slightly higher in the frame")
        XCTAssertEqual(W.instruction(for: .subjectOffCentreVertically, horizontal: nil, vertical: .lower),
                       "Move the subject slightly lower in the frame")

        let generic = W.instruction(for: .subjectOffCentreHorizontally, horizontal: nil, vertical: nil).lowercased()
        XCTAssertFalse(generic.contains("left") || generic.contains("right"), "no direction is invented")
        let genericVertical = W.instruction(for: .subjectOffCentreVertically, horizontal: nil, vertical: nil).lowercased()
        XCTAssertFalse(genericVertical.contains("higher") || genericVertical.contains("lower"))
    }

    func testDirectionsFollowTheMeasurementNotTheOtherWayRound() {
        // Subject LEFT of a centred habit: it has to go RIGHT in the frame.
        let left = evaluate(person(cx: 0.25), preferences: centred)
        XCTAssertEqual(left.horizontalShift, .towardRight)
        // Subject RIGHT of the habit: LEFT.
        XCTAssertEqual(evaluate(person(cx: 0.75), preferences: centred).horizontalShift, .towardLeft)
        // Legacy path, same convention.
        XCTAssertEqual(evaluate(person(cx: 0.25), position: legacyPosition(0.5, 0.3)).horizontalShift, .towardRight)
        // y grows downward: a subject ABOVE its usual height must move DOWN ("lower").
        XCTAssertEqual(evaluate(person(y: 0.0 + 0.05, w: 0.4, h: 0.2), position: legacyPosition(0.5, 0.7)).verticalShift, .lower)
        // A subject BELOW its usual height must move UP ("higher").
        XCTAssertEqual(evaluate(person(y: 0.7, w: 0.4, h: 0.2), position: legacyPosition(0.5, 0.3)).verticalShift, .higher)
        // No mismatch, no direction.
        XCTAssertNil(evaluate(person(cx: 0.5), preferences: centred).horizontalShift)
    }

    func testReasonsOnlyDescribeWhatIsTrue() {
        typealias W = GuidanceWording
        XCTAssertEqual(W.reason(for: .subjectTooSmall, horizontal: nil, vertical: nil), "The subject looks smaller than in your reference photos.")
        XCTAssertEqual(W.reason(for: .subjectTooLarge, horizontal: nil, vertical: nil), "The subject looks larger than in your reference photos.")
        XCTAssertEqual(W.reason(for: .subjectOffCentreHorizontally, horizontal: .towardRight, vertical: nil),
                       "In your reference photos the subject sits further to the right.")
        XCTAssertNil(W.reason(for: .subjectOffCentreHorizontally, horizontal: nil, vertical: nil), "no direction, no claim")
        XCTAssertNil(W.reason(for: .subjectClipped, horizontal: nil, vertical: nil))
        XCTAssertNil(W.reason(for: .noSubject, horizontal: nil, vertical: nil))
    }

    func testNoUserFacingTextExposesInternalTermsOrNumbers() {
        typealias W = GuidanceWording
        let reasons: [PreferenceUnavailableReason] = [.noPreferenceData, .profileInconsistent, .noUsableObservations, .singleObservation,
                                                      .noRecurringPattern, .tooVariable, .invalidPreferenceData]
        var texts = reasons.compactMap { W.limitation(for: .noUsablePreference($0)) }
        texts += CompositionEvaluation.Issue.allCasesForTests.flatMap {
            [W.instruction(for: $0, horizontal: .towardLeft, vertical: .higher), W.reason(for: $0, horizontal: .towardLeft, vertical: .higher)].compactMap { $0 }
        }
        texts += [W.ready, W.readyDetail(applied: [.horizontal, .scale]) ?? ""]
        for text in texts {
            XCTAssertFalse(text.contains(where: \.isNumber), "no raw measurements: \(text)")
            for forbidden in ["confidence", "probability", "tolerance", "hysteresis", "nil", "evaluator", "distribution", "orientation data"] {
                XCTAssertFalse(text.lowercased().contains(forbidden), "internal term '\(forbidden)' in: \(text)")
            }
        }
    }

    // MARK: - What "ready" means

    func testReadyRequiresAPreferenceThatWasActuallyComparedAndMatched() {
        let matched = evaluate(person(), preferences: centred)
        XCTAssertTrue(matched.isReady)
        XCTAssertEqual(matched.applicability, .applied)
        XCTAssertEqual(matched.appliedChecks, [.horizontal, .scale])

        // Nothing usable: no problems, but nothing matched either.
        let none = prefs(portrait: .unavailable(.noRecurringPattern))
        let nothing = evaluate(person(), preferences: none)
        XCTAssertNil(nothing.primaryIssue)
        XCTAssertFalse(nothing.isReady, "having no problems because there was nothing to check is not 'ready'")
        XCTAssertEqual(nothing.applicability, .noUsablePreference(.noRecurringPattern))
        XCTAssertTrue(nothing.appliedChecks.isEmpty)
    }

    func testReadyIsNeverClaimedOnAnUnreliableOrMissingMeasurement() {
        let stale = evaluate(person(), preferences: centred, capturedAt: 10, now: 11)
        XCTAssertFalse(stale.isReady)
        XCTAssertEqual(stale.applicability, .measurementUnreliable)
        XCTAssertFalse(evaluate(.empty, preferences: centred).isReady)
        XCTAssertEqual(evaluate(.empty, preferences: centred).applicability, .notEvaluated)
    }

    func testOnlyTheCheckedDimensionsAreClaimedInTheReadyExplanation() {
        typealias W = GuidanceWording
        XCTAssertEqual(W.readyDetail(applied: [.horizontal, .scale]), "Position and size match your reference photos.")
        XCTAssertEqual(W.readyDetail(applied: [.horizontal]), "Position matches your reference photos.")
        XCTAssertEqual(W.readyDetail(applied: [.vertical]), "Position matches your reference photos.")
        XCTAssertEqual(W.readyDetail(applied: [.scale]), "Size matches your reference photos.")
        XCTAssertNil(W.readyDetail(applied: []), "nothing was compared, so nothing is claimed")

        // One personalised dimension available: only that one is claimed.
        let onlyScale = prefs(portrait: OrientationPreferences(usableObservationCount: 3, horizontal: .unavailable(.noRecurringPattern),
                                                              scale: .supported(ScalePreference(targetArea: 0.16, spreadRatio: 0.05, observationCount: 3))))
        let e = evaluate(person(), preferences: onlyScale)
        XCTAssertTrue(e.isReady)
        XCTAssertEqual(e.appliedChecks, [.scale])
    }

    func testLegacyProfilesFollowTheSameReadySemantics() {
        // A consistent legacy size preference that matches: ready.
        XCTAssertTrue(evaluate(person(), size: legacySize(0.16)).isReady)
        // No usable legacy preference at all: no problems, but not ready, and the reason is known.
        let none = evaluate(person(), position: nil, size: nil, photoCount: 0)
        XCTAssertFalse(none.isReady)
        XCTAssertEqual(none.applicability, .noUsablePreference(.noUsableObservations))
        let one = PositionDistribution(meanX: 0.5, meanY: 0.5, stdDevX: 0, stdDevY: 0, isConsistent: false)
        XCTAssertEqual(evaluate(person(), position: one, size: nil, photoCount: 1).applicability, .noUsablePreference(.singleObservation))
    }

    func testLimitationTextAppearsOnlyWhenThereWasNothingToCompareWith() {
        typealias W = GuidanceWording
        XCTAssertNotNil(W.limitation(for: .noUsablePreference(.singleObservation)))
        XCTAssertNil(W.limitation(for: .applied))
        XCTAssertNil(W.limitation(for: .measurementUnreliable), "a passing glitch is not worth a message")
        XCTAssertNil(W.limitation(for: .notEvaluated))
        // Every distinct reason reads differently, so the message can be accurate.
        let reasons: [PreferenceUnavailableReason] = [.noUsableObservations, .singleObservation, .noRecurringPattern, .tooVariable, .profileInconsistent, .invalidPreferenceData]
        XCTAssertEqual(Set(reasons.compactMap { W.limitation(for: .noUsablePreference($0)) }).count, reasons.count)
    }

    func testNonPersonalisedGuidanceStaysAvailableWithoutAnyPreference() {
        let clipped = SceneMeasurement(person: SceneElement(kind: .person, box: CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3), confidence: nil), personLost: false)
        XCTAssertEqual(evaluate(clipped, position: nil, size: nil, photoCount: 0).primaryIssue, .subjectClipped)
        XCTAssertEqual(evaluate(clipped, preferences: prefs(portrait: .unavailable(.noUsableObservations))).primaryIssue, .subjectClipped)
        XCTAssertEqual(evaluate(.empty, position: nil, size: nil, photoCount: 0).primaryIssue, .noSubject)
    }

    // MARK: - Guide target

    private func cameraProfile(_ live: LiveCompositionPreferences?, position: PositionDistribution? = nil,
                               size: SizeDistribution? = nil, photoCount: Int = 4) -> PhotographicPreferenceProfile {
        let base = CameraProfileBridge.make(profile: ProfileAggregator.aggregate([]), results: [])
        return PhotographicPreferenceProfile(
            id: UUID(), photoCount: photoCount, successfullyAnalyzedCount: photoCount,
            subjectPositionDistribution: position, halfBodyPositionDistribution: position, subjectSizeDistribution: size,
            horizonAngleDistribution: nil, brightnessDistribution: nil, saturationDistribution: nil, colorTemperatureDistribution: nil,
            headYawDistribution: nil, headRollDistribution: nil, bodyOrientationDistribution: nil, bodySymmetryDistribution: nil,
            saliencyIntensityDistribution: nil, aestheticScoreDistribution: nil, leadingLinesLineCountDistribution: nil,
            leadingLinesAngleDistribution: nil, leadingLinesConvergenceDistribution: nil, diagonalDominanceRatio: nil,
            ruleOfThirdsPatterns: [:], sceneCategories: [:], negativeSpacePatterns: [:], colorHarmonyPatterns: [:], dominantColorPalette: [],
            lightDirectionPatterns: [:], symmetryDistribution: nil, bilateralDistribution: nil, symmetryRatio: nil, symmetryAxisPatterns: [:],
            goldenRatioDistribution: nil, goldenRatioHitRatio: nil, summary: "", insights: [], analyses: [], photos: [],
            mixedPatterns: [], limitations: base.limitations, generatedAt: base.generatedAt, livePreferences: live)
    }

    func testThePersonalisedGuideUsesTheEvaluatorsOwnTargets() throws {
        let left = prefs(portrait: slice(.left, 0.22, 0.16, aspect: 1))
        let profile = cameraProfile(left, position: legacyPosition(0.5, 0.45))     // the legacy x (0.5) must NOT be used
        let target = try XCTUnwrap(LiveGuideTargetResolver.resolve(profile: profile, orientation: .portrait))

        XCTAssertEqual(target.source, .personalized)
        XCTAssertEqual(target.centerX, 0.22, "the adapted horizontal target, not the legacy mean")
        XCTAssertEqual(target.centerY ?? -1, 0.45, "the vertical target the evaluator uses")
        XCTAssertEqual((target.width ?? 0) * (target.height ?? 0), 0.16, accuracy: 1e-9, "the same area the evaluator compares")
        XCTAssertEqual((target.width ?? 0) / (target.height ?? 1), 1.0, accuracy: 1e-9)
    }

    func testTheGuideShapeFollowsTheReferenceShapeAtTheTargetArea() throws {
        let tall = prefs(portrait: slice(.center, 0.5, 0.16, aspect: 0.5))
        let target = try XCTUnwrap(LiveGuideTargetResolver.resolve(profile: cameraProfile(tall, position: legacyPosition(0.5, 0.4)), orientation: .portrait))
        XCTAssertEqual((target.width ?? 0) / (target.height ?? 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual((target.width ?? 0) * (target.height ?? 0), 0.16, accuracy: 1e-9)
    }

    func testAGuideAtTheTargetIsWhatTheEvaluatorCallsAMatch() throws {
        let preferences = prefs(portrait: slice(.left, 0.22, 0.16, aspect: 0.8))
        let profile = cameraProfile(preferences, position: legacyPosition(0.5, 0.45))
        let target = try XCTUnwrap(LiveGuideTargetResolver.resolve(profile: profile, orientation: .portrait))
        let box = SubjectGuideBox.frame(for: target)

        // A subject filling the guide exactly: nothing to correct.
        let atGuide = SceneMeasurement(person: SceneElement(kind: .person, box: box, confidence: nil), personLost: false)
        let match = evaluator.evaluate(measurement: atGuide, position: profile.subjectPositionDistribution,
                                       size: profile.subjectSizeDistribution, photoCount: profile.photoCount,
                                       personalization: context(preferences))
        XCTAssertNil(match.primaryIssue, "\(box)")
        XCTAssertTrue(match.isReady)

        // Moved clearly off the guide sideways, or made clearly the wrong size: the evaluator objects.
        let shifted = SceneMeasurement(person: SceneElement(kind: .person, box: box.offsetBy(dx: 0.30, dy: 0), confidence: nil), personLost: false)
        XCTAssertEqual(evaluator.evaluate(measurement: shifted, position: nil, size: nil, photoCount: 0,
                                          personalization: context(preferences)).primaryIssue, .subjectOffCentreHorizontally)
        let tiny = SceneMeasurement(person: SceneElement(kind: .person, box: box.insetBy(dx: box.width * 0.4, dy: box.height * 0.4), confidence: nil), personLost: false)
        XCTAssertEqual(evaluator.evaluate(measurement: tiny, position: nil, size: nil, photoCount: 0,
                                          personalization: context(preferences)).primaryIssue, .subjectTooSmall)
    }

    func testWithoutAVerticalTargetTheGuideIsAFullHeightBandAndImpliesNoHeight() throws {
        let profile = cameraProfile(prefs(portrait: slice(.center, 0.5, 0.16)), position: nil)
        let target = try XCTUnwrap(LiveGuideTargetResolver.resolve(profile: profile, orientation: .portrait))
        XCTAssertNil(target.centerY)
        let frame = SubjectGuideBox.frame(for: target)
        XCTAssertEqual(frame.minY, 0); XCTAssertEqual(frame.height, 1)
    }

    func testNoGuideIsDrawnForATargetTheEvaluatorDoesNotEnforce() {
        // Horizontal unavailable: the legacy position must not leak into the picture.
        let none = prefs(portrait: .unavailable(.noRecurringPattern))
        XCTAssertNil(LiveGuideTargetResolver.resolve(profile: cameraProfile(none, position: legacyPosition(0.5, 0.5)), orientation: .portrait))
        // Preferences exist for portrait only: a landscape frame gets no guide.
        let portraitOnly = cameraProfile(prefs(portrait: slice(.center, 0.5, 0.16)), position: legacyPosition(0.5, 0.5))
        XCTAssertNotNil(LiveGuideTargetResolver.resolve(profile: portraitOnly, orientation: .portrait))
        XCTAssertNil(LiveGuideTargetResolver.resolve(profile: portraitOnly, orientation: .landscape))
        // Orientation not known yet.
        XCTAssertNil(LiveGuideTargetResolver.resolve(profile: portraitOnly, orientation: nil))
        // Unusable stored value.
        let bad = cameraProfile(prefs(portrait: slice(.center, Double.nan, 0.16)), position: legacyPosition(0.5, 0.5))
        XCTAssertNil(LiveGuideTargetResolver.resolve(profile: bad, orientation: .portrait))
    }

    func testTheGuideFollowsTheCamerasOrientation() throws {
        let profile = cameraProfile(prefs(portrait: slice(.center, 0.5, 0.16), landscape: slice(.left, 0.2, 0.30)),
                                    position: legacyPosition(0.5, 0.5))
        XCTAssertEqual(try XCTUnwrap(LiveGuideTargetResolver.resolve(profile: profile, orientation: .portrait)).centerX, 0.5)
        XCTAssertEqual(try XCTUnwrap(LiveGuideTargetResolver.resolve(profile: profile, orientation: .landscape)).centerX, 0.2)
    }

    func testProfilesWithoutAdaptedPreferencesKeepTheirOriginalGuide() throws {
        let legacy = cameraProfile(nil, position: legacyPosition(0.3, 0.4), photoCount: 4)
        let target = try XCTUnwrap(LiveGuideTargetResolver.resolve(profile: legacy, orientation: nil))
        XCTAssertEqual(target.source, .legacy)
        XCTAssertEqual(target.centerX, 0.3); XCTAssertEqual(target.centerY, 0.4)
        XCTAssertNil(target.width, "the long-standing default size applies")
        // The same gate as before: too few photos, no guide.
        XCTAssertNil(LiveGuideTargetResolver.resolve(profile: cameraProfile(nil, position: legacyPosition(0.3, 0.4), photoCount: 1), orientation: nil))
        // The default box is the same one that was always drawn: 0.5 wide, kept inside the frame.
        let frame = SubjectGuideBox.frame(for: target)
        XCTAssertEqual(frame.width, 0.5); XCTAssertEqual(frame.height, 0.5)
        XCTAssertEqual(frame.midX, 0.3, accuracy: 1e-9)
        let corner = SubjectGuideBox.frame(for: LiveGuideTarget(centerX: 0.05, centerY: 0.95, width: nil, height: nil, isConfident: true, spread: 0.05, source: .legacy))
        XCTAssertEqual(corner.minX, 0, accuracy: 1e-9, "kept fully inside the frame"); XCTAssertEqual(corner.maxY, 1, accuracy: 1e-9)
    }

    // MARK: - Preview geometry

    func testMatchingShapesNeedNoConversion() {
        let fill = PreviewGeometry.aspectFillRect(frameSize: CGSize(width: 3000, height: 4000), in: CGSize(width: 300, height: 400))
        XCTAssertEqual(fill.minX, 0, accuracy: 1e-9); XCTAssertEqual(fill.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(fill.width, 300, accuracy: 1e-9); XCTAssertEqual(fill.height, 400, accuracy: 1e-9)
    }

    func testAspectFillCropsTheSidesOfATallerThanWideViewfinder() {
        // A 3:4 portrait frame in a 393 x 646 viewfinder (a typical iPhone): the frame is scaled to
        // cover the height, so it is wider than the view and ~19% of its width is cropped.
        let view = CGSize(width: 393, height: 646)
        let fill = PreviewGeometry.aspectFillRect(frameSize: portraitFrame, in: view)
        XCTAssertEqual(fill.height, 646, accuracy: 1e-9)
        XCTAssertEqual(fill.width, 484.5, accuracy: 1e-9)
        XCTAssertEqual(fill.minX, -45.75, accuracy: 1e-9)

        let visible = PreviewGeometry.visibleFrameRect(frameSize: portraitFrame, in: view)
        XCTAssertEqual(visible.width, 393 / 484.5, accuracy: 1e-9)
        XCTAssertEqual(visible.minX, 45.75 / 484.5, accuracy: 1e-9)
        XCTAssertEqual(visible.height, 1, accuracy: 1e-9)

        // The old assumption (frame-normalised == view-normalised) put frame x = 0.2 at view x = 0.2.
        // It is really at ~0.13 of the view's width.
        let x = PreviewGeometry.viewPoint(fromFrame: CGPoint(x: 0.2, y: 0.5), frameSize: portraitFrame, in: view).x / view.width
        XCTAssertEqual(x, 0.1303, accuracy: 0.001)
        XCTAssertNotEqual(x, 0.2, accuracy: 0.05, "the misalignment this fixes")
        // The centre is unaffected, which is why the error looked small on centred subjects.
        XCTAssertEqual(PreviewGeometry.viewPoint(fromFrame: CGPoint(x: 0.5, y: 0.5), frameSize: portraitFrame, in: view).x, 196.5, accuracy: 1e-9)
    }

    func testAspectFillCropsTopAndBottomWhenTheViewIsTallerThanTheFrame() {
        // A landscape frame in a portrait viewfinder: the sides are cropped heavily.
        let view = CGSize(width: 393, height: 646)
        let visible = PreviewGeometry.visibleFrameRect(frameSize: landscapeFrame, in: view)
        XCTAssertEqual(visible.width, 393 / (646 * 4.0 / 3.0), accuracy: 1e-9)
        XCTAssertEqual(visible.height, 1, accuracy: 1e-9)
        // A wide viewfinder with a portrait frame crops top and bottom instead.
        let wide = CGSize(width: 800, height: 300)
        let v2 = PreviewGeometry.visibleFrameRect(frameSize: portraitFrame, in: wide)
        XCTAssertEqual(v2.width, 1, accuracy: 1e-9)
        XCTAssertEqual(v2.height, 300 / (800 * 4.0 / 3.0), accuracy: 1e-9)
    }

    func testFrameToViewAndBackRoundTrips() {
        let view = CGSize(width: 393, height: 646)
        for frame in [portraitFrame, landscapeFrame] {
            for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.95)] {
                let v = PreviewGeometry.viewPoint(fromFrame: point, frameSize: frame, in: view)
                let back = PreviewGeometry.framePoint(fromView: v, frameSize: frame, in: view)
                XCTAssertEqual(back.x, point.x, accuracy: 1e-9); XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
            }
        }
        let rect = PreviewGeometry.viewRect(fromFrame: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), frameSize: portraitFrame, in: view)
        XCTAssertEqual(rect.width, 0.5 * 484.5, accuracy: 1e-9)
        XCTAssertEqual(rect.midX, 196.5, accuracy: 1e-9)
    }

    func testPartsOfTheFrameOutsideThePreviewAreOffScreen() {
        let view = CGSize(width: 393, height: 646)
        XCTAssertLessThan(PreviewGeometry.viewPoint(fromFrame: CGPoint(x: 0.05, y: 0.5), frameSize: portraitFrame, in: view).x, 0,
                          "in the saved photo, but cropped from the preview")
    }

    func testUnknownOrInvalidFramesFallBackToTheViewsOwnBounds() {
        let view = CGSize(width: 393, height: 646)
        let bounds = CGRect(origin: .zero, size: view)
        XCTAssertEqual(PreviewGeometry.aspectFillRect(frameSize: nil, in: view), bounds)
        XCTAssertEqual(PreviewGeometry.aspectFillRect(frameSize: .zero, in: view), bounds)
        XCTAssertEqual(PreviewGeometry.aspectFillRect(frameSize: CGSize(width: CGFloat.nan, height: 10), in: view), bounds)
        XCTAssertEqual(PreviewGeometry.aspectFillRect(frameSize: portraitFrame, in: .zero), CGRect.zero)
        XCTAssertEqual(PreviewGeometry.visibleFrameRect(frameSize: nil, in: view), ImageSpace.unit)
    }

    func testOrientationChangesTheCropAxisConsistently() {
        let view = CGSize(width: 393, height: 646)
        let portrait = PreviewGeometry.visibleFrameRect(frameSize: portraitFrame, in: view)
        let landscape = PreviewGeometry.visibleFrameRect(frameSize: landscapeFrame, in: view)
        XCTAssertGreaterThan(portrait.width, landscape.width, "a landscape frame loses far more of its width in a portrait viewfinder")
        // Same convention everywhere: top-left origin, so the visible rect is centred.
        XCTAssertEqual(portrait.midX, 0.5, accuracy: 1e-9); XCTAssertEqual(landscape.midX, 0.5, accuracy: 1e-9)
    }

    // MARK: - End to end: detections to the visible instruction

    private nonisolated struct NoScenePipeline: SceneAnalyzing {
        func prepare() async throws {}
        func analyze(_ image: CGImage, subjectBox: CGRect?) async throws -> SceneSnapshot { throw CancellationError() }
    }

    private func makeViewModel(profile: PhotographicPreferenceProfile?) -> CameraPreviewViewModel {
        let vm = CameraPreviewViewModel(sceneUnderstanding: SceneUnderstandingSampler(pipeline: NoScenePipeline()))
        vm.profile = profile
        return vm
    }

    /// One detection pass at `t`, evaluated 50 ms later, in a portrait frame.
    private func pass(_ vm: CameraPreviewViewModel, _ detections: [LiveSubjectDetection], at t: TimeInterval, frame: CGSize? = nil) {
        vm.processDetections(detections, frameSize: frame ?? portraitFrame, capturedAt: t, now: t + 0.05)
    }

    private func personBox(cx: CGFloat, y: CGFloat = 0.3, w: CGFloat = 0.4, h: CGFloat = 0.4) -> LiveSubjectDetection {
        LiveSubjectDetection(box: CGRect(x: cx - w / 2, y: y, width: w, height: h), confidence: 0.9)
    }

    func testAPersonalisedProfileGuidesAndThenSaysReadyOnlyWhenItMatches() async {
        let vm = makeViewModel(profile: cameraProfile(centred, position: legacyPosition(0.5, 0.5)))
        var t = 100.0
        for _ in 0..<4 { pass(vm, [personBox(cx: 0.75)], at: t); t += 0.14 }
        XCTAssertEqual(vm.compositionInstruction, "Move the subject slightly toward the left of the frame")
        XCTAssertEqual(vm.compositionDetail, "In your reference photos the subject sits further to the left.")
        XCTAssertFalse(vm.isCompositionReady)

        // The photographer reframes: the subject moves gradually, as a real one would.
        for x in stride(from: 0.70, through: 0.50, by: -0.05) { pass(vm, [personBox(cx: CGFloat(x))], at: t); t += 0.14 }
        for _ in 0..<8 { pass(vm, [personBox(cx: 0.5)], at: t); t += 0.14 }
        XCTAssertEqual(vm.compositionInstruction, "Ready to capture")
        XCTAssertEqual(vm.compositionDetail, "Position and size match your reference photos.")
        XCTAssertTrue(vm.isCompositionReady)
    }

    func testAProfileWithNothingUsableNeverSaysReadyAndSaysWhy() async {
        let vm = makeViewModel(profile: cameraProfile(prefs(portrait: .unavailable(.noRecurringPattern)), position: nil, photoCount: 4))
        var t = 100.0
        for _ in 0..<10 { pass(vm, [personBox(cx: 0.5)], at: t); t += 0.14 }
        XCTAssertNil(vm.compositionInstruction, "no false 'ready'")
        XCTAssertFalse(vm.isCompositionReady)
        XCTAssertEqual(vm.compositionLimitation, "Your reference photos place the subject differently each time.")
    }

    func testTheCameraStillWorksWithoutAnyProfile() async {
        let vm = makeViewModel(profile: nil)
        var t = 100.0
        for _ in 0..<8 { pass(vm, [personBox(cx: 0.5)], at: t); t += 0.14 }
        XCTAssertNil(vm.compositionInstruction)
        XCTAssertNil(vm.compositionLimitation, "no profile at all: nothing to explain, the camera just works")
        XCTAssertNil(vm.guideTarget)
        XCTAssertNotNil(vm.subjectBox, "the live subject box is still drawn")
    }

    func testNonPersonalisedFramingGuidanceSurvivesAnUnusableProfile() async {
        let vm = makeViewModel(profile: cameraProfile(prefs(portrait: .unavailable(.noUsableObservations)), position: nil, photoCount: 0))
        var t = 100.0
        for _ in 0..<4 { pass(vm, [LiveSubjectDetection(box: CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3), confidence: 0.9)], at: t); t += 0.14 }
        XCTAssertEqual(vm.compositionInstruction, "Subject is cut off — pull back to fit the whole subject")
        for _ in 0..<4 { pass(vm, [], at: t); t += 0.14 }
        XCTAssertEqual(vm.compositionInstruction, "Point the camera at your subject")
    }

    func testABystanderGrowingLargerDoesNotChangeTheBoxOrTheInstruction() async {
        let vm = makeViewModel(profile: cameraProfile(centred, position: legacyPosition(0.5, 0.5)))
        var t = 100.0
        let subject = personBox(cx: 0.28, w: 0.3, h: 0.3)
        for _ in 0..<4 { pass(vm, [subject, personBox(cx: 0.80, w: 0.2, h: 0.2)], at: t); t += 0.14 }
        let boxBefore = vm.subjectBox, textBefore = vm.compositionInstruction
        XCTAssertEqual(boxBefore, subject.box)

        // The bystander becomes the larger of the two.
        for _ in 0..<6 { pass(vm, [subject, personBox(cx: 0.78, y: 0.2, w: 0.42, h: 0.5)], at: t); t += 0.14 }
        XCTAssertEqual(vm.subjectBox, boxBefore, "still the original person")
        XCTAssertEqual(vm.compositionInstruction, textBefore)
    }

    func testBriefDropoutKeepsTheSubjectAndLongAbsenceReleasesIt() async {
        let vm = makeViewModel(profile: cameraProfile(centred, position: legacyPosition(0.5, 0.5)))
        var t = 100.0
        for _ in 0..<3 { pass(vm, [personBox(cx: 0.28, w: 0.3, h: 0.3), personBox(cx: 0.8, w: 0.2, h: 0.2)], at: t); t += 0.14 }
        // Three passes without the subject, bystander still there.
        for _ in 0..<3 { pass(vm, [personBox(cx: 0.8, w: 0.2, h: 0.2)], at: t); t += 0.14 }
        XCTAssertNil(vm.subjectBox, "no box while the subject is not observed, and the bystander is not adopted")
        pass(vm, [personBox(cx: 0.28, w: 0.3, h: 0.3), personBox(cx: 0.8, w: 0.2, h: 0.2)], at: t); t += 0.14
        XCTAssertEqual(vm.subjectBox?.midX ?? 0, 0.28, accuracy: 1e-9, "the same person again")

        // Gone for longer than the grace: the bystander is adopted.
        for _ in 0..<9 { pass(vm, [personBox(cx: 0.8, w: 0.2, h: 0.2)], at: t); t += 0.14 }
        XCTAssertEqual(vm.subjectBox?.midX ?? 0, 0.8, accuracy: 1e-9)
    }

    func testStaleAndOutOfOrderPassesDoNotTouchTheState() async {
        let vm = makeViewModel(profile: cameraProfile(centred, position: legacyPosition(0.5, 0.5)))
        var t = 100.0
        for _ in 0..<4 { pass(vm, [personBox(cx: 0.75)], at: t); t += 0.14 }
        let before = (vm.subjectBox, vm.compositionInstruction)

        // An old pass (1 s late) and an earlier pass finishing last, both showing the subject centred.
        vm.processDetections([personBox(cx: 0.5)], frameSize: portraitFrame, capturedAt: t, now: t + 1.0)
        vm.processDetections([personBox(cx: 0.5)], frameSize: portraitFrame, capturedAt: 90, now: 90.05)
        XCTAssertEqual(vm.subjectBox, before.0)
        XCTAssertEqual(vm.compositionInstruction, before.1)
    }

    func testChangingSubjectDropsTheOldSubjectsGuidance() async {
        let vm = makeViewModel(profile: cameraProfile(centred, position: legacyPosition(0.5, 0.5)))
        var t = 100.0
        for _ in 0..<4 { pass(vm, [personBox(cx: 0.75)], at: t); t += 0.14 }
        XCTAssertNotNil(vm.compositionInstruction)

        // Subject leaves for longer than the grace; a new person stands perfectly placed.
        for _ in 0..<9 { pass(vm, [], at: t); t += 0.14 }
        for _ in 0..<2 { pass(vm, [personBox(cx: 0.5)], at: t); t += 0.14 }
        XCTAssertNotEqual(vm.compositionInstruction, "Move the subject slightly toward the left of the frame",
                          "the previous person's instruction does not follow the new one")
    }

    func testEquivalentPassesDoNotRepublishTheInstruction() async {
        let vm = makeViewModel(profile: cameraProfile(centred, position: legacyPosition(0.5, 0.5)))
        var seen: [String?] = []
        let cancel = vm.$compositionInstruction.sink { seen.append($0) }
        var t = 100.0
        for _ in 0..<20 { pass(vm, [personBox(cx: 0.75)], at: t); t += 0.14 }
        cancel.cancel()
        XCTAssertEqual(seen.count, 2, "the initial value and one change, not one per pass: \(seen)")
    }

    func testTheGuideTargetIsPublishedWithTheFirstFrameAndFollowsOrientation() async {
        let profile = cameraProfile(prefs(portrait: slice(.center, 0.5, 0.16), landscape: slice(.left, 0.2, 0.30)),
                                    position: legacyPosition(0.5, 0.5))
        let vm = makeViewModel(profile: profile)
        XCTAssertNil(vm.guideTarget, "adapted preferences are per orientation, and no frame has been seen yet")
        XCTAssertNil(vm.frameSize)

        pass(vm, [personBox(cx: 0.5)], at: 100, frame: portraitFrame)
        XCTAssertEqual(vm.frameSize, portraitFrame)
        XCTAssertEqual(vm.guideTarget?.centerX, 0.5)

        pass(vm, [personBox(cx: 0.5)], at: 100.14, frame: landscapeFrame)
        XCTAssertEqual(vm.guideTarget?.centerX, 0.2, "rotating the phone switches to the landscape habit")
    }

    func testALegacyProfilesGuideAppearsWithoutWaitingForAFrame() async {
        let vm = makeViewModel(profile: cameraProfile(nil, position: legacyPosition(0.3, 0.4)))
        XCTAssertEqual(vm.guideTarget?.source, .legacy)
        XCTAssertEqual(vm.guideTarget?.centerX, 0.3)
    }

    func testStoppingTheCameraClearsEverythingTheNextSessionCouldInherit() async {
        let vm = makeViewModel(profile: cameraProfile(centred, position: legacyPosition(0.5, 0.5)))
        var t = 100.0
        for _ in 0..<5 { pass(vm, [personBox(cx: 0.75)], at: t); t += 0.14 }
        XCTAssertNotNil(vm.compositionInstruction)
        vm.resetComposition()
        XCTAssertNil(vm.compositionInstruction); XCTAssertNil(vm.compositionDetail)
        XCTAssertNil(vm.compositionLimitation); XCTAssertFalse(vm.isCompositionReady)
        // And the tracker forgot the subject: the next person is simply acquired.
        pass(vm, [personBox(cx: 0.2, w: 0.3, h: 0.3)], at: t + 5)
        XCTAssertEqual(vm.subjectBox?.midX ?? 0, 0.2, accuracy: 1e-9)
    }
}

extension CompositionEvaluation.Issue {
    /// Every case, for exhaustive text checks.
    static var allCasesForTests: [CompositionEvaluation.Issue] {
        [.noSubject, .subjectLost, .subjectTooLarge, .subjectTooSmall,
         .subjectOffCentreHorizontally, .subjectOffCentreVertically, .subjectClipped]
    }
}
