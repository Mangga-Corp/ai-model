import XCTest
import CoreGraphics
@testable import AIModel

/// Tests for the composition evaluator and guidance engine.
///
/// Both are pure logic fed by a `SceneMeasurement`, so the full decision path —
/// size, position, clipping, stability, hysteresis — is testable without a
/// camera or a device.
final class CompositionEvaluatorTests: XCTestCase {

    // MARK: - Fixtures

    private func person(
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        confidence: Double? = 0.9
    ) -> SceneMeasurement {
        SceneMeasurement(
            person: SceneElement(
                kind: .person,
                box: CGRect(x: x, y: y, width: w, height: h),
                confidence: confidence
            ),
            personLost: false
        )
    }

    private func position(
        _ meanX: Double, _ meanY: Double,
        sdX: Double = 0.05, sdY: Double = 0.05, consistent: Bool = true
    ) -> PositionDistribution {
        PositionDistribution(meanX: meanX, meanY: meanY, stdDevX: sdX, stdDevY: sdY, isConsistent: consistent)
    }

    private func size(
        _ meanArea: Double, sd: Double = 0.05, consistent: Bool = true
    ) -> SizeDistribution {
        SizeDistribution(meanArea: meanArea, minArea: meanArea, maxArea: meanArea, stdDev: sd, isConsistent: consistent)
    }

    private var evaluator: CompositionEvaluator { CompositionEvaluator() }

    // MARK: - No subject

    func testNoPerson_reportsNoSubject() {
        let result = evaluator.evaluate(
            measurement: .empty,
            position: position(0.5, 0.5),
            size: size(0.2),
            photoCount: 4
        )

        XCTAssertEqual(result.primaryIssue, .noSubject)
        XCTAssertFalse(result.isReady)
    }

    func testPersonLost_distinguishesFromNoSubject() {
        let result = evaluator.evaluate(
            measurement: SceneMeasurement(person: nil, personLost: true),
            position: position(0.5, 0.5),
            size: size(0.2),
            photoCount: 4
        )

        XCTAssertEqual(result.primaryIssue, .subjectLost,
                       "A lost subject must be distinguishable from never having one")
    }

    // MARK: - Size

    func testSubjectTooSmall_whenBelowPreferredArea() {
        // Preferred area 0.2, tolerance 0.5 → lower bound 0.10. Actual 0.01.
        let result = evaluator.evaluate(
            measurement: person(x: 0.4, y: 0.4, w: 0.1, h: 0.1),   // area 0.01
            position: nil,
            size: size(0.2),
            photoCount: 4
        )

        XCTAssertEqual(result.primaryIssue, .subjectTooSmall)
        XCTAssertEqual(result.subjectAreaFraction ?? 0, 0.01, accuracy: 0.0001)
    }

    func testSubjectTooLarge_whenAbovePreferredArea() {
        // Preferred area 0.1, upper bound 0.15. Actual 0.36.
        let result = evaluator.evaluate(
            measurement: person(x: 0.3, y: 0.3, w: 0.6, h: 0.6),   // area 0.36
            position: nil,
            size: size(0.1),
            photoCount: 4
        )

        XCTAssertEqual(result.primaryIssue, .subjectTooLarge)
    }

    func testSubjectSizeWithinTolerance_isReady() {
        // Preferred 0.2, tolerance 0.5 → 0.10...0.30. Actual 0.20.
        let result = evaluator.evaluate(
            measurement: person(x: 0.35, y: 0.35, w: 0.45, h: 0.45),  // area 0.20
            position: nil,
            size: size(0.2),
            photoCount: 4
        )

        XCTAssertTrue(result.isReady, "Subject matching preferred size must be ready")
    }

    /// When the profile has no size preference, no size rule is imposed — the
    /// task forbids a universal ratio. A large subject must not be flagged.
    func testNoSizePreference_imposesNoRule() {
        let result = evaluator.evaluate(
            measurement: person(x: 0.2, y: 0.2, w: 0.6, h: 0.6),
            position: nil,
            size: nil,
            photoCount: 4
        )

        XCTAssertNotEqual(result.primaryIssue, .subjectTooLarge)
        XCTAssertNotEqual(result.primaryIssue, .subjectTooSmall)
    }

    /// An inconsistent size distribution is not a preference, so it must not be
    /// applied either.
    func testInconsistentSizePreference_isIgnored() {
        let result = evaluator.evaluate(
            measurement: person(x: 0.4, y: 0.4, w: 0.1, h: 0.1),
            position: nil,
            size: size(0.5, consistent: false),
            photoCount: 4
        )

        XCTAssertNotEqual(result.primaryIssue, .subjectTooSmall)
    }

    // MARK: - Position

    /// The profile stores position ALREADY in UIKit space (y-down, top-left
    /// origin); the live subject box is in the same space. The evaluator must
    /// NOT flip again. A subject whose centre matches the profile's meanY is ON
    /// TARGET and must not trigger "adjust height" — the exact bug where a
    /// correctly-placed subject still showed the vertical-adjust banner.
    func testSubjectOnTargetY_isNotFlagged() {
        // Profile meanY = 0.75 (subject sits low). Live subject centre y = 0.75.
        let onTarget = person(x: 0.4, y: 0.65, w: 0.2, h: 0.2)  // centre y = 0.75
        let result = evaluator.evaluate(
            measurement: onTarget,
            position: position(0.5, 0.75),
            size: nil,
            photoCount: 4
        )

        XCTAssertNotEqual(result.primaryIssue, .subjectOffCentreVertically,
                          "A subject matching the profile's meanY must not be flagged — no second flip")
    }

    /// A subject genuinely far from the preferred height IS flagged — removing
    /// the flip must not disable vertical guidance entirely.
    func testSubjectFarFromTargetY_isFlagged() {
        // Profile meanY = 0.75, but subject centre y = 0.2 (high in frame).
        let offTarget = person(x: 0.4, y: 0.1, w: 0.2, h: 0.2)  // centre y = 0.2
        let result = evaluator.evaluate(
            measurement: offTarget,
            position: position(0.5, 0.75),
            size: nil,
            photoCount: 4
        )

        XCTAssertEqual(result.primaryIssue, .subjectOffCentreVertically,
                       "A subject far from the preferred height must still be flagged")
    }

    func testSubjectOffCentreHorizontally_whenFarFromPreference() {
        // Preferred x = 0.5 (centre). Subject centre x = 0.25 → off by 0.25.
        // Kept in-frame (minX = 0.15) so clipping does not take priority and
        // this isolates the horizontal-placement issue.
        let result = evaluator.evaluate(
            measurement: person(x: 0.15, y: 0.4, w: 0.2, h: 0.2),  // centre x = 0.25
            position: position(0.5, 0.5),
            size: nil,
            photoCount: 4
        )

        XCTAssertEqual(result.primaryIssue, .subjectOffCentreHorizontally)
    }

    /// A left-side habit (meanX = 0.17) must not be flagged when the subject is
    /// actually near there — the guide works from the average, not the thirds.
    func testLeftSidePlacement_onTarget() {
        // Target x = 0.17. Subject centre x = 0.2 → within 0.15 tolerance.
        let result = evaluator.evaluate(
            measurement: person(x: 0.1, y: 0.4, w: 0.2, h: 0.2),  // centre x = 0.2
            position: position(0.17, 0.5),
            size: nil,
            photoCount: 4
        )

        XCTAssertNotEqual(result.primaryIssue, .subjectOffCentreHorizontally)
    }

    // MARK: - Clipping (priority)

    /// Clipping is the highest-priority issue: it must win over size and
    /// position, because no composition fix matters if the subject is half
    /// outside the frame.
    func testClipping_takesPriorityOverSizeAndPosition() {
        let result = evaluator.evaluate(
            measurement: person(x: 0.0, y: 0.0, w: 0.7, h: 0.7),  // touches top-left
            position: position(0.5, 0.5),
            size: size(0.05),
            photoCount: 4
        )

        XCTAssertEqual(result.primaryIssue, .subjectClipped)
    }

    func testSubjectTouchingLeftEdge_isClipped() {
        let result = evaluator.evaluate(
            measurement: person(x: 0.0, y: 0.4, w: 0.2, h: 0.2),
            position: nil, size: nil, photoCount: 4
        )
        XCTAssertEqual(result.primaryIssue, .subjectClipped)
    }

    func testSubjectTouchingRightEdge_isClipped() {
        let result = evaluator.evaluate(
            measurement: person(x: 0.8, y: 0.4, w: 0.2, h: 0.2),
            position: nil, size: nil, photoCount: 4
        )
        XCTAssertEqual(result.primaryIssue, .subjectClipped)
    }

    func testSubjectInsideFrame_isNotClipped() {
        let result = evaluator.evaluate(
            measurement: person(x: 0.4, y: 0.4, w: 0.2, h: 0.2),
            position: nil, size: nil, photoCount: 4
        )
        XCTAssertNotEqual(result.primaryIssue, .subjectClipped)
    }

    // MARK: - Insufficient data

    /// Fewer than 2 photos is a data point, not a habit — position is not
    /// applied and a limitation is reported.
    func testTooFewPhotos_reportsLimitation() {
        let result = evaluator.evaluate(
            measurement: person(x: 0.1, y: 0.4, w: 0.2, h: 0.2),
            position: position(0.5, 0.5),
            size: nil,
            photoCount: 1
        )

        XCTAssertNotNil(result.limitation)
        XCTAssertNotEqual(result.primaryIssue, .subjectOffCentreHorizontally,
                          "One photo must not impose a position target")
    }

    // MARK: - ViewModel integration contract

    /// The ViewModel publishes `subjectBox` in normalised overlay space
    /// (top-left, y down) via `toViewSpace`. The evaluator consumes that same
    /// space directly. This pins that a box produced by the same flip the
    /// The overlay-space box the ViewModel publishes is evaluated against the
    /// profile target as-is. The profile is already in the same y-down space
    /// (flipped once, at storage), so a matching centre is on target and a
    /// second flip would wrongly flag it.
    func testOverlaySpaceBox_matchingCentreIsOnTarget() {
        // Profile meanY = 0.8; subject centre y = 0.8 → on target vertically.
        let overlayBox = CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.2)  // centre (0.5, 0.8)
        let result = evaluator.evaluate(
            measurement: SceneMeasurement(
                person: SceneElement(kind: .person, box: overlayBox, confidence: nil),
                personLost: false
            ),
            position: position(0.5, 0.8),
            size: nil,
            photoCount: 4
        )

        XCTAssertNotEqual(result.primaryIssue, CompositionEvaluation.Issue.subjectOffCentreVertically,
                          "A subject centre matching the profile meanY must be on target")
        XCTAssertEqual(result.subjectCenter?.y ?? -1, 0.8, accuracy: 0.0001)
    }

    /// A subject cut by the frame edge in overlay space must be flagged as
    /// clipped — the ViewModel's box uses the same normalised space, so clipping
    /// detection needs no conversion either.
    func testOverlaySpaceClipping_detectedDirectly() {
        let result = evaluator.evaluate(
            measurement: SceneMeasurement(
                person: SceneElement(kind: .person, box: CGRect(x: 0.0, y: 0.4, width: 0.2, height: 0.2),
                                     confidence: nil),
                personLost: false
            ),
            position: nil, size: nil, photoCount: 4
        )
        XCTAssertEqual(result.primaryIssue, .subjectClipped)
    }

    // MARK: - Guidance engine stability

    private func readyEval() -> CompositionEvaluation {
        CompositionEvaluation(primaryIssue: nil, isReady: true,
                              subjectAreaFraction: 0.2, subjectCenter: CGPoint(x: 0.5, y: 0.5),
                              limitation: nil)
    }

    private func issueEval(_ issue: CompositionEvaluation.Issue) -> CompositionEvaluation {
        CompositionEvaluation(primaryIssue: issue, isReady: false,
                              subjectAreaFraction: 0.2, subjectCenter: CGPoint(x: 0.5, y: 0.5),
                              limitation: nil)
    }

    /// A single bad frame must not produce guidance — detection jitters, and
    /// flickering instructions are worse than none.
    func testGuidance_requiresStabilityWindow() {
        var engine = CompositionGuidanceEngine()
        _ = engine.update(with: issueEval(.subjectTooSmall))

        XCTAssertNil(engine.currentInstruction,
                     "One unstable frame must not show an instruction")
    }

    /// Once an issue holds for the stability window, the instruction appears.
    func testGuidance_showsInstructionAfterWindow() {
        var engine = CompositionGuidanceEngine()
        var shown: String?
        for _ in 0..<3 { shown = engine.update(with: issueEval(.subjectTooSmall)) }

        XCTAssertNotNil(shown, "A held issue must produce an instruction after the window")
    }

    /// A different issue must not inherit the previous one's stability count.
    func testGuidance_issueChangeResetsStability() {
        var engine = CompositionGuidanceEngine()
        _ = engine.update(with: issueEval(.subjectTooSmall))
        _ = engine.update(with: issueEval(.subjectTooSmall))
        // Switch to a different issue — must restart the window.
        _ = engine.update(with: issueEval(.subjectTooLarge))

        XCTAssertNil(engine.currentInstruction,
                     "Switching issues must reset the stability count")
    }

    /// "Ready" is held longer than a mere problem flag, so declaring readiness
    /// is deliberate rather than a flicker.
    func testGuidance_readyRequiresLongerHold() {
        var engine = CompositionGuidanceEngine()
        for _ in 0..<3 { _ = engine.update(with: readyEval()) }
        XCTAssertFalse(engine.isReadyStable, "Ready must hold longer than the issue window")

        for _ in 0..<5 { _ = engine.update(with: readyEval()) }
        XCTAssertTrue(engine.isReadyStable, "Sustained ready must be announced")
    }

    /// Exactly one instruction is ever shown — never contradictory advice.
    func testGuidance_singleInstructionAtATime() {
        var engine = CompositionGuidanceEngine()
        var last: String?
        for _ in 0..<6 { last = engine.update(with: issueEval(.subjectClipped)) }

        XCTAssertEqual(last, "Subject is cut off — pull back to fit the whole subject")
    }

    /// Clearing the problem must clear the instruction, not leave it stuck.
    func testGuidance_clearsWhenIssueResolves() {
        var engine = CompositionGuidanceEngine()
        for _ in 0..<3 { _ = engine.update(with: issueEval(.subjectTooSmall)) }
        XCTAssertNotNil(engine.currentInstruction)

        for _ in 0..<3 { _ = engine.update(with: readyEval()) }
        XCTAssertNil(engine.currentInstruction, "A resolved issue must clear the instruction")
    }

    /// Reset drops all state so a stale instruction cannot leak into a new scene.
    func testGuidance_resetClearsState() {
        var engine = CompositionGuidanceEngine()
        for _ in 0..<6 { _ = engine.update(with: issueEval(.subjectTooSmall)) }
        engine.reset()

        XCTAssertNil(engine.currentInstruction)
        XCTAssertFalse(engine.isReadyStable)
    }
}
