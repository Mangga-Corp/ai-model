import XCTest
import CoreGraphics
@testable import AIModel

/// Tests for converting a measured preference profile into a guide position.
///
/// The camera guide is derived from photos the user already took, so the
/// resolver's job is a coordinate-space conversion plus a decision about
/// whether the measurement is trustworthy. Both are pure logic and testable
/// without a camera.
final class SubjectGuideResolverTests: XCTestCase {

    private func distribution(
        meanX: Double,
        meanY: Double,
        stdDevX: Double = 0.05,
        stdDevY: Double = 0.05,
        consistent: Bool = true
    ) -> PositionDistribution {
        PositionDistribution(
            meanX: meanX,
            meanY: meanY,
            stdDevX: stdDevX,
            stdDevY: stdDevY,
            isConsistent: consistent
        )
    }

    // MARK: - Coordinate Conversion

    /// The profile stores position ALREADY in UIKit space (y-down, top-left
    /// origin) — VisionAnalysisService flips Vision's y-up coords at storage.
    /// The resolver must NOT flip again, or the guide is vertically mirrored:
    /// a subject placed LOW in the photo (y≈0.75) would get a guide in the
    /// UPPER frame. This test pins that no second flip happens.
    func testResolve_doesNotFlipYAxis() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.75),
            photoCount: 3
        )

        XCTAssertEqual(guide.center.x, 0.5, accuracy: 0.0001,
                       "X passes through unchanged")
        XCTAssertEqual(guide.center.y, 0.75, accuracy: 0.0001,
                       "Y must pass through unchanged: a low subject (y=0.75) must guide low, not high")
    }

    /// Both axes pass through unchanged — the profile is already in overlay space.
    func testResolve_preservesBothAxes() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.25, meanY: 0.5),
            photoCount: 3
        )

        XCTAssertEqual(guide.center.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(guide.center.y, 0.5, accuracy: 0.0001,
                       "The vertical midpoint must stay at the midpoint — no flip")
    }

    /// A centre habit must land dead centre — the flip must not bias it.
    func testResolve_centredHabitStaysCentred() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.5),
            photoCount: 4
        )

        XCTAssertEqual(guide.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(guide.center.y, 0.5, accuracy: 0.0001)
    }

    /// Guide coordinates must stay inside the frame, or the guide box would be
    /// drawn partly off-screen.
    func testResolve_keepsCenterInFrame() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.1, meanY: 0.9),
            photoCount: 5
        )

        XCTAssertGreaterThanOrEqual(guide.center.x, 0)
        XCTAssertLessThanOrEqual(guide.center.x, 1.0)
        XCTAssertGreaterThanOrEqual(guide.center.y, 0)
        XCTAssertLessThanOrEqual(guide.center.y, 1.0)
    }

    // MARK: - Confidence Gating

    /// No measurements at all means no guide, and the reason must survive so
    /// the UI can explain why nothing is drawn.
    func testResolve_noDistribution_isNotConfident() {
        let guide = SubjectGuideResolver.resolve(position: nil, photoCount: 5)

        XCTAssertFalse(guide.isConfident)
        XCTAssertNotNil(guide.unavailableReason,
                        "The reason must be returned, not discarded")
    }

    /// One photo is a data point, not a habit.
    func testResolve_singlePhoto_isNotConfident() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.5),
            photoCount: 1
        )

        XCTAssertFalse(guide.isConfident,
                       "A single photo must not be treated as a preference")
    }

    /// Two photos is the minimum that can express a pattern at all.
    func testResolve_twoPhotos_isAvailable() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.4, meanY: 0.4),
            photoCount: 2
        )

        XCTAssertFalse(guide.isConfident, "Two photos are available but not yet confident")
        XCTAssertEqual(guide.center.x, 0.4, accuracy: 0.0001,
                       "The position must still resolve so the guide can be drawn muted")
    }

    /// Wide spread means the subject lands all over the frame — there is no
    /// stable zone to point at, so no guide.
    func testResolve_wideSpread_isNotConfident() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.5, stdDevX: 0.35, stdDevY: 0.35),
            photoCount: 5
        )

        XCTAssertFalse(guide.isConfident,
                       "Scattered placement must not produce a guide box")
        XCTAssertNotNil(guide.unavailableReason)
    }

    /// The distribution can report itself as inconsistent independently of the
    /// raw spread numbers, and that verdict must be respected.
    func testResolve_inconsistentDistribution_isNotConfident() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.5, consistent: false),
            photoCount: 5
        )

        XCTAssertFalse(guide.isConfident)
    }

    /// A tight, repeated placement is exactly what a guide is for.
    func testResolve_tightConsistentPlacement_isConfident() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.33, meanY: 0.36, stdDevX: 0.04, stdDevY: 0.04),
            photoCount: 4
        )

        XCTAssertTrue(guide.isConfident)
        XCTAssertNil(guide.unavailableReason)
    }

    /// Three or more photos is the confidence threshold, so the guide can be
    /// drawn at full strength rather than muted.
    func testResolve_threePhotosMeetsConfidence() {
        let two = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.5),
            photoCount: 2
        )
        let three = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.5),
            photoCount: 3
        )

        XCTAssertFalse(two.isConfident)
        XCTAssertTrue(three.isConfident,
                      "Three photos is where the guide becomes a firm suggestion")
    }

    // MARK: - Frame Edge (regression)

    /// A left-side habit must still produce a guide CENTRE that keeps the
    /// whole box on screen. A 0.34-wide box centred on the left third (x≈0.17)
    /// has its left edge at 0 — half off-frame — which reads as no guide at all.
    func testResolve_leftSidePlacement_keepsBoxInFrame() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.17, meanY: 0.5),
            photoCount: 4
        )

        XCTAssertTrue(guide.isConfident)

        // Mirror the clamping SubjectGuideBox applies, and assert the result is
        // fully inside the frame.
        let half: CGFloat = 0.707 / 2
        let left = guide.center.x - half
        let right = guide.center.x + half

        // The resolver passes the RAW measurement through; the box clamps it.
        // Assert the raw value is what a left-third placement should be, so the
        // box has something to clamp rather than a bogus centre.
        XCTAssertEqual(guide.center.x, 0.17, accuracy: 0.0001,
                       "The resolver must not pre-clamp — the box owns that")
        XCTAssertLessThan(left, 0,
                          "Unclamped, a left-third guide extends off the left edge")
        XCTAssertLessThan(right, 1.0)
    }

    /// A right-side placement must produce a centre that keeps the box on the
    /// right edge, mirroring the left-side case.
    func testResolve_rightSidePlacement_keepsBoxInFrame() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.83, meanY: 0.5),
            photoCount: 4
        )

        XCTAssertEqual(guide.center.x, 0.83, accuracy: 0.0001)

        let half: CGFloat = 0.707 / 2
        XCTAssertGreaterThan(guide.center.x + half, 1.0,
                             "Unclamped, a right-third guide extends off the right edge")
    }

    // MARK: - Spread

    /// The reported spread drives the dash pattern, so it must reflect the
    /// larger of the two axes rather than one arbitrarily.
    func testResolve_reportsLargerSpreadAxis() {
        let guide = SubjectGuideResolver.resolve(
            position: distribution(meanX: 0.5, meanY: 0.5, stdDevX: 0.10, stdDevY: 0.22),
            photoCount: 4
        )

        XCTAssertEqual(guide.spread, 0.22, accuracy: 0.0001)
    }
}
