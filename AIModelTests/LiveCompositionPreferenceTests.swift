import XCTest
import CoreGraphics
@testable import AIModel

/// Realtime Camera Guidance personalisation, phase 1: subject horizontal position and scale.
///
/// Three layers are covered, all deterministic and without a camera:
///   1. the ADAPTER (reference photos -> evidence-checked preferences),
///   2. the EVALUATOR (one live box -> matched / mismatch / unavailable / unreliable / n.a.),
///   3. the INTEGRATION (CompositionEvaluator + the existing guidance engine + the view model).
@MainActor
final class LiveCompositionPreferenceTests: XCTestCase {

    // MARK: - Fixtures: reference photos

    private let landscapeSize = (4000, 3000)

    private func prep(_ size: (Int, Int)) -> ImagePreparationRecord {
        ImagePreparationRecord(originalPixelWidth: size.0, originalPixelHeight: size.1, orientationRaw: 0,
                               uprightWidth: size.0, uprightHeight: size.1,
                               preparedWidth: size.0 / 3, preparedHeight: size.1 / 3, longEdgeLimit: 1280)
    }

    /// An upper-body box centred at `cx` (top-left space, y down).
    private func upper(_ cx: CGFloat, y: CGFloat = 0.3, w: CGFloat = 0.4, h: CGFloat = 0.4) -> CGRect {
        CGRect(x: cx - w / 2, y: y, width: w, height: h)
    }

    /// A reference photo. `size == nil` means no preparation record (orientation unknown);
    /// `determined == false` means subject positioning was not determined.
    private func result(_ order: Int,
                        upper box: CGRect?,
                        quality: EvidenceQuality = .high,
                        size: (Int, Int)? = (3000, 4000),
                        determined: Bool = true,
                        angle: CameraAngleCategory = .unknown) -> PhotoResult {
        let selection = SubjectSelectionInfo(detectedCount: 1, eligibleCount: 1, primaryCandidateID: 0, isAmbiguous: false)
        let none = Assessment.insufficient("n/a")
        let full: CGRect? = determined
            ? (box.map { ImageSpace.clamped($0.insetBy(dx: -0.05, dy: -0.05)) } ?? CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.7))
            : nil
        let positioning = SubjectPositioningResult(
            subjectBox: full, upperBodyBox: determined ? box : nil,
            center: full.map { CGPoint(x: $0.midX, y: $0.midY) },
            normalizedWidth: full.map { Double($0.width) }, normalizedHeight: full.map { Double($0.height) },
            normalizedArea: full.map { ImageSpace.area($0) },
            horizontal: full.map { SubjectPositioningMeasurer.horizontalZone(forCenterX: Double($0.midX)) },
            vertical: full.map { SubjectPositioningMeasurer.verticalZone(forCenterY: Double($0.midY)) },
            detectionConfidence: determined ? 0.9 : nil, isMeasurementValid: determined, touchedEdges: [],
            selection: selection, secondarySubjects: [],
            assessment: determined
                ? Assessment(status: .determined, quality: quality, explanation: "", evidence: [], limitations: [])
                : none)
        return PhotoResult(
            id: UUID(), selectionOrder: order, localIdentifier: "p\(order)", preparation: size.map(prep),
            status: determined ? .complete : .partial, evidence: nil,
            cameraAngle: CameraAngleResult(category: angle, horizonCue: nil, headPitchDegrees: nil, headYawDegrees: nil,
                                           imageRollDegrees: nil,
                                           assessment: angle == .unknown ? none
                                               : Assessment(status: .determined, quality: .high, explanation: "", evidence: [], limitations: [])),
            subjectFraming: SubjectFramingResult(category: .unknown, visibleExtent: nil, croppedEdges: [],
                                                 reliableLandmarkCount: 0, assessment: none),
            subjectPositioning: positioning,
            environmentalDepth: EnvironmentalDepthResult(structure: .unknown, metrics: nil, sceneBands: nil, assessment: none),
            errors: [], limitations: [])
    }

    private func adapt(_ results: [PhotoResult]) -> LiveCompositionPreferences {
        LiveCompositionPreferenceAdapter.make(profile: ProfileAggregator.aggregate(results), results: results)
    }

    /// Three portrait photos that agree: centred at x ~0.5, area ~0.16.
    private func agreeingPortraitSet() -> [PhotoResult] {
        [result(0, upper: upper(0.48)), result(1, upper: upper(0.50)), result(2, upper: upper(0.52))]
    }

    // MARK: - Fixtures: preferences and live observations

    private func horizontal(_ zone: HorizontalZone, _ x: Double) -> PreferenceSupport<HorizontalPreference> {
        .supported(HorizontalPreference(zone: zone, targetX: x, spread: 0.02, agreeingCount: 3,
                                        observationCount: 3, strength: .moderate))
    }

    private func scale(_ area: Double) -> PreferenceSupport<ScalePreference> {
        .supported(ScalePreference(targetArea: area, spreadRatio: 0.05, observationCount: 3))
    }

    private func slice(_ h: PreferenceSupport<HorizontalPreference>, _ s: PreferenceSupport<ScalePreference>) -> OrientationPreferences {
        OrientationPreferences(usableObservationCount: 3, horizontal: h, scale: s)
    }

    /// Portrait preferences only (landscape unavailable): centred, area 0.16.
    private var centredPortrait: LiveCompositionPreferences {
        LiveCompositionPreferences(portrait: slice(horizontal(.center, 0.5), scale(0.16)),
                                   landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
    }

    private let portraitFrame = CGSize(width: 3000, height: 4000)
    private let landscapeFrame = CGSize(width: 4000, height: 3000)
    private let evaluator = PersonalizedCompositionEvaluator(positionTolerance: 0.15, sizeTolerance: 0.5, clipMargin: 0.01)

    private func evaluate(_ box: CGRect?, _ prefs: LiveCompositionPreferences?, frame: CGSize? = nil,
                          mirrored: Bool = false, capturedAt: TimeInterval = 10, now: TimeInterval = 10.1,
                          using evaluator: PersonalizedCompositionEvaluator? = nil) -> PersonalizedCompositionOutcome {
        (evaluator ?? self.evaluator).evaluate(box: box, frameSize: frame ?? portraitFrame, isMirrored: mirrored,
                                               capturedAt: capturedAt, now: now, preferences: prefs)
    }

    /// A live box with the given centre x and size, unclipped.
    private func live(cx: CGFloat = 0.5, y: CGFloat = 0.3, w: CGFloat = 0.4, h: CGFloat = 0.4) -> CGRect {
        CGRect(x: cx - w / 2, y: y, width: w, height: h)
    }

    // MARK: - Adapter: valid preferences

    func testACentredHabitIsRecordedWithItsMeasuredTarget() throws {
        let prefs = adapt(agreeingPortraitSet())
        let h = try XCTUnwrap(prefs.portrait.horizontal.value)
        XCTAssertEqual(h.zone, .center)
        XCTAssertTrue(h.isCentered)
        XCTAssertEqual(h.targetX, 0.50, accuracy: 1e-9, "the median of the photos, not an idealised 0.5")
        XCTAssertEqual(h.agreeingCount, 3)
        XCTAssertEqual(h.observationCount, 3)
        XCTAssertEqual(h.strength, .moderate, "the profile's own label for three agreeing photos")
        XCTAssertEqual(h.spread, 0.0163, accuracy: 0.001)
    }

    func testAnOffCentreHabitRecordsTheSideThePhotosShow() throws {
        let left = adapt([result(0, upper: upper(0.20, w: 0.2)), result(1, upper: upper(0.22, w: 0.2)), result(2, upper: upper(0.24, w: 0.2))])
        let l = try XCTUnwrap(left.portrait.horizontal.value)
        XCTAssertEqual(l.zone, .left)
        XCTAssertFalse(l.isCentered)
        XCTAssertEqual(l.targetX, 0.22, accuracy: 1e-9)

        let right = adapt([result(0, upper: upper(0.80, w: 0.2)), result(1, upper: upper(0.78, w: 0.2)), result(2, upper: upper(0.76, w: 0.2))])
        XCTAssertEqual(try XCTUnwrap(right.portrait.horizontal.value).zone, .right)
    }

    func testAScalePreferenceIsTheMedianUpperBodyArea() throws {
        let prefs = adapt([result(0, upper: upper(0.5, w: 0.40, h: 0.40)),     // 0.160
                           result(1, upper: upper(0.5, w: 0.42, h: 0.40)),     // 0.168
                           result(2, upper: upper(0.5, w: 0.38, h: 0.40))])    // 0.152
        let s = try XCTUnwrap(prefs.portrait.scale.value)
        XCTAssertEqual(s.targetArea, 0.16, accuracy: 1e-9)
        XCTAssertEqual(s.observationCount, 3)
        XCTAssertLessThan(s.spreadRatio, 0.25)
    }

    func testTwoAgreeingPhotosAreOnlyLimitedSupport() throws {
        let prefs = adapt([result(0, upper: upper(0.5)), result(1, upper: upper(0.52))])
        XCTAssertEqual(try XCTUnwrap(prefs.portrait.horizontal.value).strength, .limited,
                       "carried through so later phases can treat two photos more cautiously")
    }

    // MARK: - Adapter: missing and insufficient evidence

    func testNoUpperBodyBoxMeansNoPreferenceAndTheGapIsCounted() {
        let prefs = adapt([result(0, upper: nil), result(1, upper: nil), result(2, upper: nil)])
        XCTAssertEqual(prefs.portrait.horizontal, .unavailable(.noUsableObservations))
        XCTAssertEqual(prefs.portrait.scale, .unavailable(.noUsableObservations))
        XCTAssertEqual(prefs.landscape.horizontal, .unavailable(.noUsableObservations))
        XCTAssertEqual(prefs.accounting.noUpperBodyBox, 3)
        XCTAssertEqual(prefs.accounting.usable, 0)
    }

    func testASingleUsablePhotoIsNotAHabit() {
        let prefs = adapt([result(0, upper: upper(0.5)), result(1, upper: nil), result(2, upper: nil)])
        XCTAssertEqual(prefs.portrait.horizontal, .unavailable(.singleObservation))
        XCTAssertEqual(prefs.portrait.scale, .unavailable(.singleObservation))
        XCTAssertEqual(prefs.portrait.usableObservationCount, 1)
    }

    func testDisagreeingPlacementsGiveNoHorizontalPreferenceButScaleIsJudgedSeparately() throws {
        // Left, right, left, right: identical sizes (0.2 x 0.8 = 0.16), fully inside the frame.
        let prefs = adapt([result(0, upper: upper(0.2, y: 0.1, w: 0.2, h: 0.8)), result(1, upper: upper(0.8, y: 0.1, w: 0.2, h: 0.8)),
                           result(2, upper: upper(0.2, y: 0.1, w: 0.2, h: 0.8)), result(3, upper: upper(0.8, y: 0.1, w: 0.2, h: 0.8))])
        XCTAssertEqual(prefs.portrait.horizontal, .unavailable(.noRecurringPattern),
                       "no side is invented for a user who alternates")
        XCTAssertNotNil(prefs.portrait.scale.value, "identical sizes are still a size habit")
    }

    func testSpreadBeyondTheProfileToleranceIsTooVariable() {
        let wide = adapt([result(0, upper: upper(0.36)), result(1, upper: upper(0.64))])
        XCTAssertEqual(wide.portrait.horizontal, .unavailable(.tooVariable), "both centre-third, but 0.14 apart")

        let sizes = adapt([result(0, upper: upper(0.5, w: 0.2, h: 0.5)), result(1, upper: upper(0.5, w: 0.6, h: 0.5))])
        XCTAssertEqual(sizes.portrait.scale, .unavailable(.tooVariable), "areas 0.10 and 0.30")
    }

    func testAnEmptyProfileGivesNoPreferences() {
        let prefs = adapt([result(0, upper: nil, determined: false), result(1, upper: nil, determined: false)])
        XCTAssertEqual(prefs.portrait.horizontal, .unavailable(.noUsableObservations))
        XCTAssertEqual(prefs.accounting.undeterminedPositioning, 2)
    }

    func testAProfileThatDoesNotDescribeTheseResultsIsNotUsed() {
        let results = agreeingPortraitSet()
        let other = ProfileAggregator.aggregate([result(7, upper: upper(0.5)), result(8, upper: upper(0.5)),
                                                 result(9, upper: upper(0.5)), result(10, upper: upper(0.5))])
        let prefs = LiveCompositionPreferenceAdapter.make(profile: other, results: results)
        XCTAssertEqual(prefs.portrait.horizontal, .unavailable(.profileInconsistent))
        XCTAssertEqual(prefs.landscape.scale, .unavailable(.profileInconsistent))

        // Same number of photos, different identities: the coverage cannot refer to these results.
        let sameCount = ProfileAggregator.aggregate([result(0, upper: upper(0.5)), result(1, upper: upper(0.5)), result(2, upper: upper(0.5))])
        XCTAssertEqual(LiveCompositionPreferenceAdapter.make(profile: sameCount, results: results).portrait.horizontal,
                       .unavailable(.profileInconsistent))
    }

    // MARK: - Adapter: evidence coverage and reliability

    func testUnreliableReferencePhotosAreLeftOutAndCounted() throws {
        let results = agreeingPortraitSet() + [
            result(3, upper: upper(0.80, w: 0.2), quality: .low),            // low-quality outlier
            result(4, upper: CGRect(x: 0.0, y: 0.3, width: 0.4, height: 0.4)), // touches the left edge
            result(5, upper: upper(0.5), size: nil),                          // no preparation record
            result(6, upper: upper(0.5), size: (3000, 3000)),                 // square: no orientation
            result(7, upper: nil, determined: false)                          // not determined
        ]
        let prefs = adapt(results)
        XCTAssertEqual(prefs.accounting.totalPhotos, 8)
        XCTAssertEqual(prefs.accounting.lowQuality, 1)
        XCTAssertEqual(prefs.accounting.clippedUpperBody, 1)
        XCTAssertEqual(prefs.accounting.unknownOrientation, 2)
        XCTAssertEqual(prefs.accounting.undeterminedPositioning, 1)
        XCTAssertEqual(prefs.accounting.usablePortrait, 3)
        let h = try XCTUnwrap(prefs.portrait.horizontal.value, "the low-quality outlier must not break a clear habit")
        XCTAssertEqual(h.zone, .center)
        XCTAssertEqual(h.observationCount, 3)
    }

    func testModerateQualityIsEnoughButLowIsNot() {
        let moderate = adapt([result(0, upper: upper(0.5), quality: .moderate), result(1, upper: upper(0.5), quality: .moderate)])
        XCTAssertNotNil(moderate.portrait.horizontal.value)
        let low = adapt([result(0, upper: upper(0.5), quality: .low), result(1, upper: upper(0.5), quality: .low)])
        XCTAssertEqual(low.portrait.horizontal, .unavailable(.noUsableObservations))
        XCTAssertEqual(low.accounting.lowQuality, 2)
    }

    // MARK: - Adapter: orientation

    func testReferencePhotosAreOnlyComparedWithinTheirOwnOrientation() throws {
        let results = agreeingPortraitSet() + [
            result(3, upper: upper(0.20, w: 0.2), size: landscapeSize),
            result(4, upper: upper(0.22, w: 0.2), size: landscapeSize)
        ]
        let prefs = adapt(results)
        XCTAssertEqual(try XCTUnwrap(prefs.portrait.horizontal.value).zone, .center)
        XCTAssertEqual(try XCTUnwrap(prefs.landscape.horizontal.value).zone, .left)
        XCTAssertEqual(prefs.accounting.usablePortrait, 3)
        XCTAssertEqual(prefs.accounting.usableLandscape, 2)
        XCTAssertEqual(try XCTUnwrap(prefs.preferences(for: .landscape).horizontal.value).strength, .limited)
    }

    func testLandscapeOnlyReferencesLeavePortraitUnavailable() {
        let prefs = adapt((0..<3).map { result($0, upper: upper(0.5), size: landscapeSize) })
        XCTAssertNotNil(prefs.landscape.horizontal.value)
        XCTAssertEqual(prefs.portrait.horizontal, .unavailable(.noUsableObservations),
                       "never borrow another orientation's measurements")
        XCTAssertEqual(prefs.portrait.scale, .unavailable(.noUsableObservations))
    }

    func testFrameOrientationFromPixelSize() {
        XCTAssertEqual(FrameOrientation(width: 3000, height: 4000), .portrait)
        XCTAssertEqual(FrameOrientation(width: 4000, height: 3000), .landscape)
        XCTAssertNil(FrameOrientation(width: 3000, height: 3000), "square is neither")
        XCTAssertNil(FrameOrientation(width: 3000, height: 3100), "within 5% of square")
        XCTAssertNil(FrameOrientation(width: 0, height: 4000))
        XCTAssertNil(FrameOrientation(width: .nan, height: 4000))
        XCTAssertNil(FrameOrientation(width: -3, height: 4))
    }

    // MARK: - Adapter: independence, determinism, hand-off

    func testCameraAngleResultsDoNotInfluencePreferences() {
        let base = agreeingPortraitSet()
        let withAngles = zip(base, [CameraAngleCategory.lowAngle, .eyeLevel, .highAngle]).map { r, angle in
            result(r.selectionOrder, upper: r.subjectPositioning.upperBodyBox, angle: angle)
        }
        // Different identities, so compare the preferences, which carry none.
        XCTAssertEqual(adapt(base), adapt(withAngles))
    }

    func testAdaptationIsDeterministicAndIndependentOfInputOrder() {
        let results = agreeingPortraitSet()
        XCTAssertEqual(adapt(results), adapt(results))
        let profile = ProfileAggregator.aggregate(results)
        XCTAssertEqual(LiveCompositionPreferenceAdapter.make(profile: profile, results: results),
                       LiveCompositionPreferenceAdapter.make(profile: profile, results: Array(results.reversed())))
    }

    func testTheClipMarginMatchesTheLiveEvaluator() {
        XCTAssertEqual(LiveCompositionPreferenceAdapter.clipMargin, CompositionEvaluator().clipMargin,
                       "a target must never be learned from a framing the live camera flags as cut off")
    }

    func testTheBridgeCarriesAdaptedPreferencesAndLeavesTheLegacyFieldsAlone() throws {
        let results = agreeingPortraitSet()
        let camera = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(results), results: results)

        let live = try XCTUnwrap(camera.livePreferences)
        XCTAssertEqual(try XCTUnwrap(live.portrait.horizontal.value).zone, .center)

        // The existing fields are exactly what they were: upper-body means, honest photo count.
        XCTAssertEqual(camera.photoCount, 3)
        XCTAssertEqual(camera.subjectPositionDistribution?.meanX ?? 0, 0.50, accuracy: 1e-9)
        XCTAssertEqual(camera.subjectPositionDistribution?.meanY ?? 0, 0.50, accuracy: 1e-9)
        XCTAssertEqual(camera.subjectSizeDistribution?.meanArea ?? 0, 0.16, accuracy: 1e-9)
        XCTAssertNil(camera.horizonAngleDistribution, "camera angle / tilt inputs are untouched")
        XCTAssertEqual(camera.halfBodyPositionDistribution, camera.subjectPositionDistribution)
    }

    // MARK: - Evaluator: position

    func testHorizontalPositionWithinToleranceMatches() {
        guard case .matched(let d) = evaluate(live(cx: 0.55), centredPortrait).horizontal else { return XCTFail("expected a match") }
        XCTAssertEqual(d.offset, 0.05, accuracy: 1e-9)
        XCTAssertEqual(d.target, 0.5)
        XCTAssertEqual(d.tolerance, 0.15)
    }

    func testHorizontalMismatchCarriesASignedOffsetInEitherDirection() {
        guard case .mismatch(let left) = evaluate(live(cx: 0.25), centredPortrait).horizontal else { return XCTFail("expected a mismatch") }
        XCTAssertEqual(left.offset, -0.25, accuracy: 1e-9, "negative: the subject is left of the target")
        guard case .mismatch(let right) = evaluate(live(cx: 0.75), centredPortrait).horizontal else { return XCTFail("expected a mismatch") }
        XCTAssertEqual(right.offset, 0.25, accuracy: 1e-9)
    }

    func testTheToleranceBoundaryIsInclusiveAndOnlyBeyondItMismatches() {
        let wide = PersonalizedCompositionEvaluator(positionTolerance: 0.25, sizeTolerance: 0.5, clipMargin: 0.01)
        // centre x = 0.75 exactly: offset 0.25 from 0.5.
        let atBoundary = CGRect(x: 0.625, y: 0.3, width: 0.25, height: 0.4)
        XCTAssertFalse(evaluate(atBoundary, centredPortrait, using: wide).horizontal.isMismatch)
        let beyond = CGRect(x: 0.635, y: 0.3, width: 0.25, height: 0.4)
        XCTAssertTrue(evaluate(beyond, centredPortrait, using: wide).horizontal.isMismatch)
    }

    func testAnOffCentreHabitIsComparedWithItsOwnTargetNotWithTheCentre() {
        let left = LiveCompositionPreferences(portrait: slice(horizontal(.left, 0.22), scale(0.16)),
                                              landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
        XCTAssertFalse(evaluate(live(cx: 0.25), left).horizontal.isMismatch, "on the habitual side")
        XCTAssertTrue(evaluate(live(cx: 0.5), left).horizontal.isMismatch, "centred is a mismatch for a left habit")
    }

    // MARK: - Evaluator: scale

    func testScaleBoundsAreInclusiveAndReportRelativeOffsets() {
        let prefs = LiveCompositionPreferences(portrait: slice(horizontal(.center, 0.5), scale(0.25)),
                                               landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
        // bounds are 0.125 and 0.375 (exact in binary)
        XCTAssertFalse(evaluate(CGRect(x: 0.375, y: 0.25, width: 0.25, height: 0.5), prefs).scale.isMismatch, "area 0.125")
        XCTAssertFalse(evaluate(CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.75), prefs).scale.isMismatch, "area 0.375")

        guard case .mismatch(let small) = evaluate(CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2), prefs).scale else { return XCTFail("expected too small") }
        XCTAssertEqual(small.offset, 0.04 / 0.25 - 1, accuracy: 1e-9)
        XCTAssertLessThan(small.offset, 0)
        guard case .mismatch(let large) = evaluate(CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7), prefs).scale else { return XCTFail("expected too large") }
        XCTAssertGreaterThan(large.offset, 0)
    }

    // MARK: - Evaluator: unavailable, not applicable, invalid

    func testMissingPreferencesAreUnavailableNotMatched() {
        let outcome = evaluate(live(), nil)
        XCTAssertEqual(outcome.horizontal, .preferenceUnavailable(.noPreferenceData))
        XCTAssertEqual(outcome.scale, .preferenceUnavailable(.noPreferenceData))
        XCTAssertTrue(outcome.isEntirelyUnavailable)
    }

    func testUnsupportedPreferencesKeepTheirReasonAndDimensionsAreIndependent() {
        let prefs = LiveCompositionPreferences(
            portrait: OrientationPreferences(usableObservationCount: 4, horizontal: .unavailable(.noRecurringPattern), scale: scale(0.16)),
            landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
        let outcome = evaluate(live(w: 0.2, h: 0.2), prefs)
        XCTAssertEqual(outcome.horizontal, .preferenceUnavailable(.noRecurringPattern))
        XCTAssertTrue(outcome.scale.isMismatch, "an unavailable dimension does not silence its neighbour")
        XCTAssertFalse(outcome.isEntirelyUnavailable)
    }

    func testNoSubjectIsNotApplicableRatherThanAMismatch() {
        let outcome = evaluate(nil, centredPortrait)
        XCTAssertEqual(outcome.horizontal, .notApplicable(.noSubject))
        XCTAssertEqual(outcome.scale, .notApplicable(.noSubject))
        XCTAssertFalse(outcome.hasUnreliableObservation)
    }

    func testUnreliableGeometryNeverBecomesAMatchOrAMismatch() {
        let bad: [CGRect] = [
            CGRect(x: .nan, y: 0.3, width: 0.4, height: 0.4),
            CGRect(x: 0.3, y: 0.3, width: .infinity, height: 0.4),
            CGRect(x: 0.3, y: 0.3, width: 0, height: 0.4),
            CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0),
            CGRect(x: 0.9, y: 0.3, width: 0.5, height: 0.4),    // runs far outside the frame
            CGRect(x: -0.5, y: 0.3, width: 0.4, height: 0.4)
        ]
        for box in bad {
            let outcome = evaluate(box, centredPortrait)
            XCTAssertEqual(outcome.horizontal, .observationUnreliable(.invalidGeometry), "\(box)")
            XCTAssertEqual(outcome.scale, .observationUnreliable(.invalidGeometry), "\(box)")
            XCTAssertTrue(outcome.hasUnreliableObservation)
        }
    }

    func testAnUnusableFrameIsReportedBecauseItsOrientationCannotBeKnown() {
        let frames: [CGSize] = [.zero, CGSize(width: 3000, height: 3000), CGSize(width: CGFloat.nan, height: 4000)]
        for frame in frames {
            let outcome = evaluate(live(), centredPortrait, frame: frame)
            XCTAssertEqual(outcome.horizontal, PreferenceEvaluation.observationUnreliable(.invalidFrame), "\(frame)")
        }
    }

    func testStaleFutureAndNonFiniteTimestampsAreNotCurrent() {
        XCTAssertFalse(evaluate(live(), centredPortrait, capturedAt: 10, now: 10.5).hasUnreliableObservation, "exactly the maximum age is still current")
        XCTAssertEqual(evaluate(live(), centredPortrait, capturedAt: 10, now: 10.6).horizontal, .observationUnreliable(.stale))
        XCTAssertEqual(evaluate(live(), centredPortrait, capturedAt: 10, now: 9.9).horizontal, .observationUnreliable(.invalidTimestamp))
        XCTAssertEqual(evaluate(live(), centredPortrait, capturedAt: .nan, now: 10).scale, .observationUnreliable(.invalidTimestamp))
        XCTAssertEqual(evaluate(live(), centredPortrait, capturedAt: 10, now: .infinity).scale, .observationUnreliable(.invalidTimestamp))
    }

    func testAClippedBoxDescribesOnlyPartOfThePersonSoItIsUnreliable() {
        let clipped = CGRect(x: 0.0, y: 0.3, width: 0.3, height: 0.4)
        XCTAssertEqual(evaluate(clipped, centredPortrait).horizontal, .observationUnreliable(.clipped))
        XCTAssertEqual(evaluate(clipped, centredPortrait).scale, .observationUnreliable(.clipped))
    }

    func testAMissingPreferenceIsReportedBeforeAnObservationProblem() {
        // Nothing to compare against, so a stale measurement is irrelevant to that dimension.
        let outcome = evaluate(live(), nil, capturedAt: 10, now: 20)
        XCTAssertEqual(outcome.horizontal, .preferenceUnavailable(.noPreferenceData))
        let prefs = LiveCompositionPreferences(portrait: slice(.unavailable(.tooVariable), scale(0.16)),
                                               landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
        let mixed = evaluate(live(), prefs, capturedAt: 10, now: 20)
        XCTAssertEqual(mixed.horizontal, .preferenceUnavailable(.tooVariable))
        XCTAssertEqual(mixed.scale, .observationUnreliable(.stale))
    }

    func testStoredPreferenceValuesThatAreNotUsableAreIgnored() {
        let badX: [Double] = [.nan, .infinity, -0.1, 1.5]
        for x in badX {
            let prefs = LiveCompositionPreferences(portrait: slice(horizontal(.center, x), scale(0.16)),
                                                   landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
            XCTAssertEqual(evaluate(live(), prefs).horizontal, .preferenceUnavailable(.invalidPreferenceData), "x = \(x)")
        }
        for area in [0.0, -0.2, .nan, 1.5] {
            let prefs = LiveCompositionPreferences(portrait: slice(horizontal(.center, 0.5), scale(area)),
                                                   landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
            XCTAssertEqual(evaluate(live(), prefs).scale, .preferenceUnavailable(.invalidPreferenceData), "area = \(area)")
        }
    }

    // MARK: - Evaluator: coordinates, orientation, mirroring

    func testTheFramesOrientationSelectsWhichPreferencesApply() {
        let prefs = LiveCompositionPreferences(
            portrait: slice(horizontal(.center, 0.5), scale(0.16)),
            landscape: slice(horizontal(.left, 0.2), scale(0.40)),
            accounting: ReferenceAccounting())
        let box = live(cx: 0.5)

        XCTAssertFalse(evaluate(box, prefs, frame: portraitFrame).horizontal.isMismatch, "centred, as the portrait photos were")
        guard case .mismatch(let d) = evaluate(box, prefs, frame: landscapeFrame).horizontal else { return XCTFail("landscape habit is left") }
        XCTAssertEqual(d.target, 0.2)
        XCTAssertEqual(d.offset, 0.3, accuracy: 1e-9)
        XCTAssertTrue(evaluate(box, prefs, frame: landscapeFrame).scale.isMismatch, "0.16 is below 0.40 x 0.5 = 0.20")
        XCTAssertFalse(evaluate(box, prefs, frame: portraitFrame).scale.isMismatch)
    }

    func testAnOrientationWithoutReferencePhotosIsUnavailableNotBorrowed() {
        let outcome = evaluate(live(), centredPortrait, frame: landscapeFrame)
        XCTAssertEqual(outcome.horizontal, .preferenceUnavailable(.noUsableObservations))
        XCTAssertEqual(outcome.scale, .preferenceUnavailable(.noUsableObservations))
    }

    func testAMirroredFeedIsComparedInTheReferencePhotosOrientation() {
        let leftHabit = LiveCompositionPreferences(portrait: slice(horizontal(.left, 0.2), scale(0.16)),
                                                   landscape: .unavailable(.noUsableObservations), accounting: ReferenceAccounting())
        // In a mirrored buffer the subject that is on the user's left appears on the right.
        // (Boxes are 0.2 wide so they stay clear of the edges and are not treated as clipped.)
        XCTAssertFalse(evaluate(live(cx: 0.8, w: 0.2), leftHabit, mirrored: true).horizontal.isMismatch)
        XCTAssertTrue(evaluate(live(cx: 0.8, w: 0.2), leftHabit, mirrored: false).horizontal.isMismatch)
        XCTAssertTrue(evaluate(live(cx: 0.2, w: 0.2), leftHabit, mirrored: true).horizontal.isMismatch)

        // Mirroring never changes the size, and the outcome is symmetric.
        let a = evaluate(live(cx: 0.8, w: 0.2, h: 0.2), leftHabit, mirrored: true).scale
        let b = evaluate(live(cx: 0.2, w: 0.2, h: 0.2), leftHabit, mirrored: false).scale
        XCTAssertEqual(a, b)
    }

    func testReferenceAndLiveBoxesShareOneCoordinateConvention() {
        // Offline: Vision (bottom-left origin) -> ImageSpace. Live: Vision -> toViewSpace. Same Vision rect, same result.
        let visionRects = [CGRect(x: 0.3, y: 0.55, width: 0.4, height: 0.4), CGRect(x: 0.1, y: 0.05, width: 0.25, height: 0.5),
                           CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.3)]
        for v in visionRects {
            let offline = ImageSpace.rect(fromVisionX: Double(v.minX), y: Double(v.minY), width: Double(v.width), height: Double(v.height))
            let liveRect = CameraPreviewViewModel.toViewSpace(v, frameSize: CGSize(width: 3000, height: 4000))
            XCTAssertEqual(offline.minX, liveRect.minX, accuracy: 1e-12)
            XCTAssertEqual(offline.minY, liveRect.minY, accuracy: 1e-12, "y is flipped once, at the Vision boundary, on both paths")
            XCTAssertEqual(offline.width, liveRect.width, accuracy: 1e-12)
            XCTAssertEqual(offline.height, liveRect.height, accuracy: 1e-12)
        }
    }

    func testEvaluationIsDeterministicWithNoHiddenState() {
        let box = live(cx: 0.3, w: 0.2, h: 0.2)
        XCTAssertEqual(evaluate(box, centredPortrait), evaluate(box, centredPortrait))
    }

    // MARK: - Integration: CompositionEvaluator

    private let composition = CompositionEvaluator()

    private func context(_ prefs: LiveCompositionPreferences?, frame: CGSize? = nil, capturedAt: TimeInterval = 10,
                         now: TimeInterval = 10.1, mirrored: Bool = false) -> LivePersonalization? {
        prefs.map { LivePersonalization(preferences: $0, frameSize: frame ?? portraitFrame, isMirrored: mirrored,
                                        capturedAt: capturedAt, now: now) }
    }

    private func person(_ box: CGRect) -> SceneMeasurement {
        SceneMeasurement(person: SceneElement(kind: .person, box: box, confidence: nil), personLost: false)
    }

    private func legacyPosition(_ x: Double, _ y: Double) -> PositionDistribution {
        PositionDistribution(meanX: x, meanY: y, stdDevX: 0.05, stdDevY: 0.05, isConsistent: true)
    }

    private func legacySize(_ area: Double) -> SizeDistribution {
        SizeDistribution(meanArea: area, minArea: area, maxArea: area, stdDev: 0.01, isConsistent: true)
    }

    func testValidPreferencesEnablePreferenceAwareGuidance() {
        // The legacy distributions are nil: only the adapted preferences can be the source.
        let small = composition.evaluate(measurement: person(live(w: 0.2, h: 0.2)), position: nil, size: nil, photoCount: 0,
                                         personalization: context(centredPortrait))
        XCTAssertEqual(small.primaryIssue, .subjectTooSmall)
        XCTAssertNotNil(small.preferenceOutcome)

        let large = composition.evaluate(measurement: person(live(cx: 0.5, y: 0.2, w: 0.7, h: 0.5)), position: nil, size: nil, photoCount: 0,
                                         personalization: context(centredPortrait))
        XCTAssertEqual(large.primaryIssue, .subjectTooLarge)

        let off = composition.evaluate(measurement: person(live(cx: 0.25)), position: nil, size: nil, photoCount: 0,
                                       personalization: context(centredPortrait))
        XCTAssertEqual(off.primaryIssue, .subjectOffCentreHorizontally)

        let good = composition.evaluate(measurement: person(live()), position: nil, size: nil, photoCount: 0,
                                        personalization: context(centredPortrait))
        XCTAssertNil(good.primaryIssue)
        XCTAssertTrue(good.isReady)
        XCTAssertNil(good.limitation)
    }

    func testWithoutPersonalizationEveryCheckRunsAsItAlwaysDid() {
        let cases: [(CGRect, PositionDistribution?, SizeDistribution?, Int, CompositionEvaluation.Issue?)] = [
            (live(w: 0.2, h: 0.2), nil, legacySize(0.2), 4, .subjectTooSmall),
            (live(cx: 0.25), legacyPosition(0.5, 0.5), nil, 4, .subjectOffCentreHorizontally),
            (live(), legacyPosition(0.5, 0.5), legacySize(0.16), 4, nil),
            (live(y: 0.1), legacyPosition(0.5, 0.75), nil, 4, .subjectOffCentreVertically),
            (CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3), legacyPosition(0.5, 0.5), nil, 4, .subjectClipped),
            (live(cx: 0.25), legacyPosition(0.5, 0.5), nil, 1, nil)      // fewer than two photos: no habit
        ]
        for (box, position, size, count, expected) in cases {
            let implicit = composition.evaluate(measurement: person(box), position: position, size: size, photoCount: count)
            let explicit = composition.evaluate(measurement: person(box), position: position, size: size, photoCount: count,
                                                personalization: nil)
            XCTAssertEqual(implicit.primaryIssue, expected, "\(box)")
            XCTAssertEqual(implicit, explicit)
            XCTAssertNil(implicit.preferenceOutcome, "the legacy path reports no preference outcome")
        }
    }

    func testUnavailablePreferencesRaiseNothingEvenWhereTheLegacyDistributionsWould() {
        let none = LiveCompositionPreferences(portrait: .unavailable(.noUsableObservations), landscape: .unavailable(.noUsableObservations),
                                              accounting: ReferenceAccounting())
        let box = live(cx: 0.25, w: 0.2, h: 0.2)    // small AND off-centre
        let legacy = composition.evaluate(measurement: person(box), position: legacyPosition(0.5, 0.3), size: legacySize(0.2), photoCount: 4)
        XCTAssertNotNil(legacy.primaryIssue, "premise: the legacy path would have spoken")

        let personalised = composition.evaluate(measurement: person(box), position: legacyPosition(0.5, 0.3), size: legacySize(0.2),
                                                photoCount: 4, personalization: context(none))
        XCTAssertNil(personalised.primaryIssue, "unsupported preferences never produce size or horizontal guidance")
        XCTAssertNotNil(personalised.limitation, "and the reason is stated, not hidden")
    }

    func testVerticalGuidanceAndClippingSurviveWhenNeitherPersonalisedDimensionIsSupported() {
        let none = LiveCompositionPreferences(portrait: .unavailable(.singleObservation), landscape: .unavailable(.singleObservation),
                                              accounting: ReferenceAccounting())
        let high = composition.evaluate(measurement: person(live(y: 0.1)), position: legacyPosition(0.5, 0.75), size: nil, photoCount: 4,
                                        personalization: context(none))
        XCTAssertEqual(high.primaryIssue, .subjectOffCentreVertically, "vertical position is not a personalised dimension")

        let clipped = composition.evaluate(measurement: person(CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3)), position: nil, size: nil,
                                           photoCount: 0, personalization: context(centredPortrait))
        XCTAssertEqual(clipped.primaryIssue, .subjectClipped, "clipping still outranks everything")

        XCTAssertEqual(composition.evaluate(measurement: .empty, position: nil, size: nil, photoCount: 0,
                                            personalization: context(centredPortrait)).primaryIssue, .noSubject)
    }

    func testOneInstructionAtATimeWhenSeveralDimensionsDisagree() {
        // Too small AND off-centre AND (legacy) too high: scale first, then horizontal, then vertical.
        func issue(_ box: CGRect) -> CompositionEvaluation.Issue? {
            composition.evaluate(measurement: person(box), position: legacyPosition(0.5, 0.75), size: nil, photoCount: 4,
                                 personalization: context(centredPortrait)).primaryIssue
        }
        XCTAssertEqual(issue(live(cx: 0.25, y: 0.1, w: 0.2, h: 0.2)), .subjectTooSmall)
        XCTAssertEqual(issue(live(cx: 0.25, y: 0.1, w: 0.4, h: 0.4)), .subjectOffCentreHorizontally)
        XCTAssertEqual(issue(live(cx: 0.50, y: 0.1, w: 0.4, h: 0.4)), .subjectOffCentreVertically)
        XCTAssertNil(issue(live(cx: 0.50, y: 0.55, w: 0.4, h: 0.4)))
    }

    func testAnUnreliableMeasurementNeverClaimsReadinessAndNeverRaisesAMismatch() {
        for (capturedAt, now) in [(10.0, 11.0), (10.0, 9.0)] {      // stale, then a timestamp from the future
            let e = composition.evaluate(measurement: person(live(w: 0.2, h: 0.2)), position: nil, size: nil, photoCount: 0,
                                         personalization: context(centredPortrait, capturedAt: capturedAt, now: now))
            XCTAssertNil(e.primaryIssue, "an unreliable box is not a mismatch")
            XCTAssertFalse(e.isReady, "and it is not a match either")
            XCTAssertEqual(e.preferenceOutcome?.hasUnreliableObservation, true)
            XCTAssertNotNil(e.limitation)
        }
    }

    func testAnOrientationChangeSwitchesPreferencesWithoutLeavingAStaleOne() {
        let prefs = LiveCompositionPreferences(portrait: slice(horizontal(.center, 0.5), scale(0.16)),
                                               landscape: slice(horizontal(.left, 0.2), scale(0.16)), accounting: ReferenceAccounting())
        let box = live(cx: 0.5)
        XCTAssertNil(composition.evaluate(measurement: person(box), position: nil, size: nil, photoCount: 0,
                                          personalization: context(prefs, frame: portraitFrame)).primaryIssue)
        XCTAssertEqual(composition.evaluate(measurement: person(box), position: nil, size: nil, photoCount: 0,
                                            personalization: context(prefs, frame: landscapeFrame)).primaryIssue,
                       .subjectOffCentreHorizontally)
    }

    // MARK: - Integration: the existing guidance engine

    private func announced(_ evaluations: [CompositionEvaluation]) -> [String?] {
        var engine = CompositionGuidanceEngine()
        return evaluations.map { engine.update(with: $0) }
    }

    func testJitterAroundTheToleranceNeverProducesAnInstruction() {
        // Centre x alternates 0.001 inside / 0.001 outside the 0.15 tolerance around 0.5.
        let inside = composition.evaluate(measurement: person(live(cx: 0.649)), position: nil, size: nil, photoCount: 0, personalization: context(centredPortrait))
        let outside = composition.evaluate(measurement: person(live(cx: 0.651)), position: nil, size: nil, photoCount: 0, personalization: context(centredPortrait))
        XCTAssertNil(inside.primaryIssue)
        XCTAssertEqual(outside.primaryIssue, .subjectOffCentreHorizontally)

        let shown = announced((0..<24).map { $0.isMultiple(of: 2) ? inside : outside })
        XCTAssertTrue(shown.allSatisfy { $0 == nil }, "alternating measurements never hold for the stability window")
    }

    func testASustainedMismatchIsAnnouncedOnceAndNotDroppedByOneGoodFrame() {
        let off = composition.evaluate(measurement: person(live(cx: 0.25)), position: nil, size: nil, photoCount: 0, personalization: context(centredPortrait))
        let good = composition.evaluate(measurement: person(live()), position: nil, size: nil, photoCount: 0, personalization: context(centredPortrait))

        let shown = announced([off, off, off, good, off, good, good, good])
        XCTAssertNil(shown[0]); XCTAssertNil(shown[1])
        XCTAssertNotNil(shown[2], "announced after the stability window")
        XCTAssertEqual(shown[3], shown[2], "one in-tolerance frame does not retract it")
        XCTAssertEqual(shown[4], shown[2])
        XCTAssertEqual(shown[5], shown[2])
        XCTAssertEqual(shown[6], shown[2])
        XCTAssertNil(shown[7], "cleared only after the same number of consecutive good frames")
    }

    func testUnavailableEvidenceDoesNotProduceAnInstructionThroughTheEngine() {
        let none = LiveCompositionPreferences(portrait: .unavailable(.noRecurringPattern), landscape: .unavailable(.noRecurringPattern),
                                              accounting: ReferenceAccounting())
        let e = composition.evaluate(measurement: person(live(cx: 0.2, w: 0.2, h: 0.2)), position: nil, size: nil, photoCount: 0,
                                     personalization: context(none))
        // Pre-existing behaviour, pinned knowingly: with no issue the engine still announces
        // "Ready to capture". What it must never do is claim a habit ("your usual ...") it cannot support.
        let shown = announced(Array(repeating: e, count: 12)).compactMap { $0 }
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(shown.allSatisfy { $0 == "Ready to capture" })
    }

    // MARK: - Integration: view model, profile to instruction
    //
    // These tests are `async` on purpose. Observed: all seven aborted with malloc's "pointer being
    // freed was not allocated" while they were synchronous, and passed unchanged once `async`
    // (the project's default actor isolation is MainActor, and these create a main-actor class).
    // The legacy baseline failures abort with the same message; the one stack inspected for them
    // goes through `swift_task_deinitOnExecutor`. That is consistent with a shared cause but was
    // not proven. Do not "simplify" these back to synchronous without re-running them.

    private nonisolated struct NoScenePipeline: SceneAnalyzing {
        func prepare() async throws {}
        func analyze(_ image: CGImage, subjectBox: CGRect?) async throws -> SceneSnapshot { throw CancellationError() }
    }

    private func makeViewModel(profile: PhotographicPreferenceProfile?) -> CameraPreviewViewModel {
        let vm = CameraPreviewViewModel(sceneUnderstanding: SceneUnderstandingSampler(pipeline: NoScenePipeline()))
        vm.profile = profile
        return vm
    }

    private func cameraProfile(_ results: [PhotoResult]) -> PhotographicPreferenceProfile {
        CameraProfileBridge.make(profile: ProfileAggregator.aggregate(results), results: results)
    }

    /// The text the existing engine shows for an issue held for the stability window.
    private func text(for issue: CompositionEvaluation.Issue) -> String? {
        var engine = CompositionGuidanceEngine()
        var shown: String?
        for _ in 0..<3 {
            shown = engine.update(with: CompositionEvaluation(primaryIssue: issue, isReady: false, subjectAreaFraction: nil,
                                                              subjectCenter: nil, limitation: nil))
        }
        return shown
    }

    private func drive(_ vm: CameraPreviewViewModel, box: CGRect?, frames: Int, frame: CGSize? = nil,
                       capturedAt: TimeInterval = 100, now: TimeInterval = 100.05) {
        for _ in 0..<frames {
            vm.evaluateComposition(personBox: box, frameSize: frame ?? portraitFrame, capturedAt: capturedAt, now: now)
        }
    }

    func testAnalysedPhotosReachTheLiveInstructionThroughTheBridge() async throws {
        let vm = makeViewModel(profile: cameraProfile(agreeingPortraitSet()))
        XCTAssertNotNil(vm.profile?.livePreferences)

        drive(vm, box: live(w: 0.2, h: 0.2), frames: 3)
        XCTAssertEqual(vm.compositionInstruction, text(for: .subjectTooSmall))
        XCTAssertFalse(vm.isCompositionReady)

        drive(vm, box: live(cx: 0.25), frames: 3)
        XCTAssertEqual(vm.compositionInstruction, text(for: .subjectOffCentreHorizontally))

        drive(vm, box: live(), frames: 5)
        XCTAssertTrue(vm.isCompositionReady)
        XCTAssertEqual(vm.compositionInstruction, "Ready to capture")
    }

    func testNoProfileStillMeansNoGuidance() async {
        let vm = makeViewModel(profile: nil)
        drive(vm, box: live(w: 0.2, h: 0.2), frames: 6)
        XCTAssertNil(vm.compositionInstruction)
        XCTAssertFalse(vm.isCompositionReady)
        XCTAssertNil(vm.compositionLimitation)
    }

    func testAProfileWithoutAdaptedPreferencesBehavesAsItAlwaysDid() async {
        var legacy = cameraProfile(agreeingPortraitSet())
        legacy.livePreferences = nil
        let vm = makeViewModel(profile: legacy)
        drive(vm, box: live(w: 0.2, h: 0.2), frames: 3)       // legacy size mean 0.16, consistent
        XCTAssertEqual(vm.compositionInstruction, text(for: .subjectTooSmall))
    }

    func testAProfileWithNoUsablePreferencesStillGuidesOnFraming() async {
        // Determined subjects but no upper-body boxes: nothing to personalise, nothing legacy either.
        let vm = makeViewModel(profile: cameraProfile([result(0, upper: nil), result(1, upper: nil), result(2, upper: nil)]))
        XCTAssertNil(vm.profile?.subjectSizeDistribution)

        drive(vm, box: live(w: 0.2, h: 0.2), frames: 6)
        XCTAssertNotEqual(vm.compositionInstruction, text(for: .subjectTooSmall), "no size habit, so no size instruction")

        drive(vm, box: CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3), frames: 3)
        XCTAssertEqual(vm.compositionInstruction, text(for: .subjectClipped), "existing framing guidance is preserved")

        drive(vm, box: nil, frames: 3)
        XCTAssertEqual(vm.compositionInstruction, text(for: .noSubject))
    }

    func testAStaleMeasurementProducesNoInstructionFromTheViewModel() async {
        let vm = makeViewModel(profile: cameraProfile(agreeingPortraitSet()))
        drive(vm, box: live(w: 0.2, h: 0.2), frames: 6, capturedAt: 100, now: 101)     // 1 s old
        XCTAssertNil(vm.compositionInstruction)
        XCTAssertFalse(vm.isCompositionReady)
        XCTAssertNotNil(vm.compositionLimitation)
    }

    func testAPortraitHabitDoesNotGuideALandscapeFrame() async {
        let vm = makeViewModel(profile: cameraProfile(agreeingPortraitSet()))
        drive(vm, box: live(w: 0.2, h: 0.2), frames: 6, frame: landscapeFrame)
        XCTAssertNotEqual(vm.compositionInstruction, text(for: .subjectTooSmall))
    }

    func testAMirroredFeedIsUnMirroredBeforeComparing() async {
        // A left-side habit; a mirrored feed shows that subject on the right.
        let results = [result(0, upper: upper(0.20, w: 0.2)), result(1, upper: upper(0.22, w: 0.2)), result(2, upper: upper(0.24, w: 0.2))]
        let profile = cameraProfile(results)
        let box = live(cx: 0.78, w: 0.2, h: 0.4)      // area 0.08, as in the reference photos

        let mirrored = makeViewModel(profile: profile)
        for _ in 0..<6 {
            mirrored.evaluateComposition(personBox: box, frameSize: portraitFrame, capturedAt: 100, now: 100.05, isMirrored: true)
        }
        XCTAssertTrue(mirrored.isCompositionReady, "un-mirrored, the subject sits where the reference photos put it")

        let plain = makeViewModel(profile: profile)
        for _ in 0..<6 {
            plain.evaluateComposition(personBox: box, frameSize: portraitFrame, capturedAt: 100, now: 100.05, isMirrored: false)
        }
        XCTAssertEqual(plain.compositionInstruction, text(for: .subjectOffCentreHorizontally))
        XCTAssertFalse(plain.isCompositionReady)
    }
}
