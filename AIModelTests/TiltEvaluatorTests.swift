import XCTest
@testable import AIModel

/// Tests for tilt guidance — comparing device pitch to the profile's preferred
/// horizon angle.
///
/// Pure logic: a pitch number and an optional preferred angle in, a guidance
/// verdict out. No Core Motion, no camera — testable on the simulator.
final class TiltEvaluatorTests: XCTestCase {

    private var evaluator: TiltEvaluator { TiltEvaluator() }

    // MARK: - No preference

    /// With no horizon preference in the profile, no tilt guidance is offered —
    /// inventing a target angle would impose a rule the user never expressed.
    func testNoPreference_unavailable() {
        XCTAssertEqual(evaluator.evaluate(pitch: 20, preferredAngle: nil), .unavailable)
        XCTAssertNil(evaluator.instruction(for: .unavailable))
    }

    // MARK: - On target

    /// Device pitch matching the preferred angle is on target — no nagging.
    func testMatchingPitch_onTarget() {
        // Preferred 15°, device at 15°.
        XCTAssertEqual(evaluator.evaluate(pitch: 15, preferredAngle: 15), .onTarget)
    }

    /// Small deviations within tolerance are on target, so guidance does not
    /// flicker on natural hand movement.
    func testWithinTolerance_onTarget() {
        // Preferred 15°, device at 20° — 5° off, within the 8° tolerance.
        XCTAssertEqual(evaluator.evaluate(pitch: 20, preferredAngle: 15), .onTarget)
    }

    // MARK: - Tilt up

    /// Device flatter than preferred → tilt up to reach the preferred angle.
    func testTooFlat_tiltUp() {
        // Preferred 20°, device near level (2°) → well under target.
        XCTAssertEqual(evaluator.evaluate(pitch: 2, preferredAngle: 20), .tiltUp)
    }

    // MARK: - Tilt down

    /// Device steeper than preferred → tilt down toward the target.
    func testTooSteep_tiltDown() {
        // Preferred 10°, device at 35° → over-tilted.
        XCTAssertEqual(evaluator.evaluate(pitch: 35, preferredAngle: 10), .tiltDown)
    }

    /// A downward tilt that overshoots the preferred downward angle also eases
    /// back toward the target.
    func testTooSteepDownward_tiltUp() {
        // Preferred −10° (slight down), device at −35° → too far down, ease up.
        XCTAssertEqual(evaluator.evaluate(pitch: -35, preferredAngle: -10), .tiltUp)
    }

    // MARK: - Instruction text

    /// Each verdict maps to exactly one terse instruction.
    func testInstructions_areTerse() {
        XCTAssertEqual(evaluator.instruction(for: .tiltUp), "Tilt the camera up slightly")
        XCTAssertEqual(evaluator.instruction(for: .tiltDown), "Tilt the camera down slightly")
        XCTAssertNil(evaluator.instruction(for: .onTarget),
                     "On target shows nothing — the banner should disappear")
    }

    // MARK: - Edge cases

    /// A preferred angle of zero (level horizon) with a level device is on
    /// target, not a tilt prompt.
    func testLevelPreference_levelDevice_onTarget() {
        XCTAssertEqual(evaluator.evaluate(pitch: 0, preferredAngle: 0), .onTarget)
    }

    /// The evaluator must never crash or return a contradictory verdict at the
    /// pitch extremes — a phone held straight up or down is physical, if awkward.
    func testExtremePitch_returnsValidGuidance() {
        for pitch in [-90.0, -45.0, 0.0, 45.0, 90.0] {
            let g = evaluator.evaluate(pitch: pitch, preferredAngle: 15)
            XCTAssertTrue([TiltEvaluator.Guidance.tiltUp, .tiltDown, .onTarget, .unavailable].contains(g))
        }
    }
}
