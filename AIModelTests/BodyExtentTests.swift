import XCTest
import CoreGraphics
import Vision
@testable import AIModel

/// Tests for body-extent classification and its aggregation.
///
/// `classifyBodyExtent` is pure geometry — comparing the upper-body and
/// full-body detection boxes — so it is fully testable without Vision or a
/// camera. This is the logic that decides whether a subject reads as full or
/// half body, so its thresholds are pinned here.
final class BodyExtentTests: XCTestCase {

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - classifyBodyExtent thresholds

    /// Upper box nearly as tall as the full box → the visible subject is mostly
    /// torso-and-up, i.e. a half-body framing.
    func testUpperBoxDominates_isHalfBody() {
        // Full box height 1.0, upper box height 0.85 → ratio 0.85 ≥ 0.80.
        let full = rect(0, 0, 0.5, 1.0)
        let upper = rect(0, 0.15, 0.5, 0.85)
        XCTAssertEqual(
            VisionAnalysisService.classifyBodyExtent(fullBox: full, upperBox: upper),
            .halfBody
        )
    }

    /// Full box much taller than the upper box → the figure extends well below
    /// the torso, i.e. a full-body framing.
    func testFullBoxMuchTaller_isFullBody() {
        // Full box height 1.0, upper box height 0.5 → ratio 0.5 ≤ 0.55.
        let full = rect(0, 0, 0.5, 1.0)
        let upper = rect(0, 0.5, 0.5, 0.5)
        XCTAssertEqual(
            VisionAnalysisService.classifyBodyExtent(fullBox: full, upperBox: upper),
            .fullBody
        )
    }

    /// A borderline ratio is reported as undetermined rather than guessed —
    /// honesty over a false precise claim.
    func testBorderlineRatio_isUndetermined() {
        // Ratio 0.68 sits between 0.55 and 0.80.
        let full = rect(0, 0, 0.5, 1.0)
        let upper = rect(0, 0.32, 0.5, 0.68)
        XCTAssertEqual(
            VisionAnalysisService.classifyBodyExtent(fullBox: full, upperBox: upper),
            .undetermined
        )
    }

    /// When the upper-body detector found nothing, there is nothing to compare,
    /// so the extent is undetermined — never assumed to be full body.
    func testNoUpperBox_isUndetermined() {
        let full = rect(0, 0, 0.5, 1.0)
        XCTAssertEqual(
            VisionAnalysisService.classifyBodyExtent(fullBox: full, upperBox: nil),
            .undetermined
        )
    }

    /// A degenerate zero-height full box must not divide by zero or misclassify.
    func testZeroHeightFullBox_isUndetermined() {
        let full = rect(0, 0, 0.5, 0)
        let upper = rect(0, 0, 0.5, 0)
        XCTAssertEqual(
            VisionAnalysisService.classifyBodyExtent(fullBox: full, upperBox: upper),
            .undetermined
        )
    }

    // MARK: - Boundary values

    /// Exactly at the half-body threshold (0.80) classifies as half body.
    func testExactlyAtHalfBodyThreshold() {
        let full = rect(0, 0, 0.5, 1.0)
        let upper = rect(0, 0.2, 0.5, 0.8)
        XCTAssertEqual(
            VisionAnalysisService.classifyBodyExtent(fullBox: full, upperBox: upper),
            .halfBody
        )
    }

    /// Exactly at the full-body threshold (0.55) classifies as full body.
    func testExactlyAtFullBodyThreshold() {
        let full = rect(0, 0, 0.5, 1.0)
        let upper = rect(0, 0.45, 0.5, 0.55)
        XCTAssertEqual(
            VisionAnalysisService.classifyBodyExtent(fullBox: full, upperBox: upper),
            .fullBody
        )
    }

    // MARK: - BodyExtent enum

    /// Raw values are the display strings shown in the profile, so they must be
    /// human-readable.
    func testRawValues_areDisplayStrings() {
        XCTAssertEqual(BodyExtent.fullBody.rawValue, "Full Body")
        XCTAssertEqual(BodyExtent.halfBody.rawValue, "Half Body")
        XCTAssertEqual(BodyExtent.undetermined.rawValue, "Undetermined")
    }
}
