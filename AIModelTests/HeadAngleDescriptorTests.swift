import XCTest
@testable import AIModel

/// Tests for converting head-pose angles into plain language.
///
/// Pure logic — degrees in, description out. The thresholds (dead zone,
/// direction words) are pinned here so the wording stays predictable.
final class HeadAngleDescriptorTests: XCTestCase {

    // MARK: - Yaw (turn left/right)

    func testFacingCamera_whenYawNearZero() {
        let text = HeadAngleDescriptor.describe(yaw: 3, roll: nil, pitch: nil)
        XCTAssertEqual(text, "facing camera")
    }

    func testTurnedLeft_whenYawNegative() {
        let text = HeadAngleDescriptor.describe(yaw: -25, roll: nil, pitch: nil)
        XCTAssertEqual(text, "turned left")
    }

    func testTurnedRight_whenYawPositive() {
        let text = HeadAngleDescriptor.describe(yaw: 25, roll: nil, pitch: nil)
        XCTAssertEqual(text, "turned right")
    }

    // MARK: - Roll (tilt)

    func testLevel_whenRollNearZero() {
        let text = HeadAngleDescriptor.describe(yaw: nil, roll: 4, pitch: nil)
        XCTAssertEqual(text, "level")
    }

    func testTiltedLeft_whenRollNegative() {
        let text = HeadAngleDescriptor.describe(yaw: nil, roll: -20, pitch: nil)
        XCTAssertEqual(text, "tilted left")
    }

    // MARK: - Pitch (chin)

    func testChinUp_whenPitchPositive() {
        let text = HeadAngleDescriptor.describe(yaw: nil, roll: nil, pitch: 15)
        XCTAssertEqual(text, "chin up")
    }

    func testChinDown_whenPitchNegative() {
        let text = HeadAngleDescriptor.describe(yaw: nil, roll: nil, pitch: -15)
        XCTAssertEqual(text, "chin down")
    }

    // MARK: - Combined

    /// All three axes measured → all three described, in a fixed order.
    func testAllAxes_joinedInOrder() {
        let text = HeadAngleDescriptor.describe(yaw: -22, roll: 3, pitch: 10)
        XCTAssertEqual(text, "turned left, level, chin up")
    }

    /// A near-frontal face on every axis reads as neutral, not turned.
    func testAllNearZero_allNeutral() {
        let text = HeadAngleDescriptor.describe(yaw: 2, roll: -3, pitch: 4)
        XCTAssertEqual(text, "facing camera, level, chin level")
    }

    // MARK: - Partial data

    /// Only the axes that were measured are described — a photo may measure yaw
    /// but not roll, and we never invent the missing one.
    func testOnlyYaw_describesOnlyYaw() {
        let text = HeadAngleDescriptor.describe(yaw: -20, roll: nil, pitch: nil)
        XCTAssertEqual(text, "turned left")
    }

    /// Nothing measurable → nil, so the card omits the row entirely.
    func testNothingMeasurable_returnsNil() {
        XCTAssertNil(HeadAngleDescriptor.describe(yaw: nil, roll: nil, pitch: nil))
    }

    // MARK: - Dead-zone boundary

    /// Just inside the dead zone counts as neutral.
    func testJustInsideDeadZone_isNeutral() {
        XCTAssertEqual(HeadAngleDescriptor.describe(yaw: 7, roll: nil, pitch: nil), "facing camera")
    }

    /// Just outside the dead zone counts as turned.
    func testJustOutsideDeadZone_isTurned() {
        XCTAssertEqual(HeadAngleDescriptor.describe(yaw: 9, roll: nil, pitch: nil), "turned right")
    }
}
