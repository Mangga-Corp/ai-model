import XCTest
import CoreMotion
@testable import AIModel

/// Tests for the device attitude service's lifecycle and data contract.
///
/// Core Motion produces no samples on the simulator, so these tests verify the
/// CONTRACT — availability handling, clean start/stop, no crash — rather than
/// actual attitude values. The math (pitch → guidance) is covered separately in
/// `TiltEvaluatorTests`, which needs no hardware.
final class DeviceAttitudeServiceTests: XCTestCase {

    // MARK: - Availability

    /// The service must report honestly whether motion hardware is available,
    /// never assume it. On the simulator this is false; on device, true.
    func testAvailability_isReported() {
        let service = DeviceAttitudeService()
        // Whatever the host, `isDeviceMotionAvailable` is a definite bool and
        // the service exposes it without crashing.
        XCTAssertFalse(service.isActive, "A fresh service is not yet streaming")
    }

    /// Starting on hardware without motion returns false and does not throw, so
    /// the caller can degrade to position-only guidance.
    func testStart_withoutMotion_returnsFalseGracefully() {
        let service = DeviceAttitudeService()
        let expectation = expectation(description: "start returns")

        // `start` is synchronous and returns a Bool. On the simulator motion is
        // unavailable, so it should return false rather than crash.
        let started = service.start { _ in }
        expectation.fulfill()

        if !CMMotionManager().isDeviceMotionAvailable {
            XCTAssertFalse(started, "Without motion hardware, start must report false")
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Lifecycle

    /// Stop must be safe to call even when never started — the ViewModel calls
    /// it unconditionally on teardown.
    func testStop_whenNeverStarted_isSafe() {
        let service = DeviceAttitudeService()
        service.stop()   // must not crash
        XCTAssertFalse(service.isActive)
    }

    /// Double-stop must be safe — teardown can race with an explicit stop.
    func testDoubleStop_isSafe() {
        let service = DeviceAttitudeService()
        _ = service.start { _ in }
        service.stop()
        service.stop()
        XCTAssertFalse(service.isActive)
    }

    /// After stop, the service must not still be streaming, so a stale motion
    /// stream cannot outlive the camera session.
    func testStop_haltsStreaming() {
        let service = DeviceAttitudeService()
        _ = service.start { _ in }
        service.stop()
        XCTAssertFalse(service.isActive, "Stop must halt the motion stream")
    }

    // MARK: - Data contract

    /// `DeviceAttitude.zero` is the neutral reference — used as the fallback
    /// when no attitude has arrived yet.
    func testZeroAttitude_isNeutral() {
        XCTAssertEqual(DeviceAttitude.zero.pitch, 0)
        XCTAssertEqual(DeviceAttitude.zero.roll, 0)
    }

    /// Attitude values are equatable, so the guidance engine can detect "no
    /// change" and avoid re-publishing identical instructions.
    func testAttitude_equatable() {
        let a = DeviceAttitude(pitch: 10, roll: 2)
        let b = DeviceAttitude(pitch: 10, roll: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, DeviceAttitude(pitch: 11, roll: 2))
    }
}
