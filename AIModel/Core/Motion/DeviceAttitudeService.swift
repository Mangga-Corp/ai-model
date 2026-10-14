import Foundation
import CoreMotion

/// The device's physical camera attitude, in degrees.
///
/// Measured from Core Motion's device motion, using a reference frame aligned to
/// the camera's optical axis rather than the screen. This matters: the screen
/// and the camera point the same way on an iPhone, but the reference frame
/// decides which axis is "pitch", and getting it wrong mirrors the guidance.
struct DeviceAttitude: Equatable {
    /// Pitch in degrees: positive = camera tilted UP (looking above the
    /// horizon), negative = tilted DOWN. Range −90...90.
    let pitch: Double

    /// Roll in degrees: positive = tilted clockwise (right side down).
    /// Range −180...180.
    let roll: Double

    static let zero = DeviceAttitude(pitch: 0, roll: 0)
}

/// Streams the device's camera attitude from Core Motion.
///
/// WHY CORE MOTION: the composition guidance needs the phone's PHYSICAL tilt,
/// which Vision cannot report — Vision sees image content, not the device's
/// orientation in space. Core Motion is the only on-device source for this.
///
/// Starts on init and runs until `stop()`. Delivery is throttled because
/// attitude changes far faster than guidance should react — firing the guidance
/// engine at 60Hz would make instructions flicker.
final class DeviceAttitudeService {

    /// Minimum seconds between attitude samples handed to observers. ~0.1s is
    /// smooth enough to feel live without flooding the guidance engine.
    var interval: TimeInterval = 0.1

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var lastDelivery = Date.distantPast

    /// True when the motion hardware is producing samples.
    private(set) var isActive = false

    init() {
        queue.name = "com.aimodel.camera.attitude"
        // Attitude is derived on this queue, off the main thread.
        queue.maxConcurrentOperationCount = 1
    }

    /// Starts streaming attitude. Returns false when the hardware is
    /// unavailable, so the caller can degrade to position-only guidance rather
    /// than assume tilt data exists.
    @discardableResult
    func start(onAttitude: @escaping (DeviceAttitude) -> Void) -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }

        // `xArbitraryZVertical` keeps Z vertical (gravity), so pitch is the
        // camera's tilt relative to level ground — the natural "tilt up/down"
        // axis. The arbitrary X reference does not affect pitch/roll.
        manager.deviceMotionUpdateInterval = interval
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let now = Date()
            guard now.timeIntervalSince(self.lastDelivery) >= self.interval else { return }
            self.lastDelivery = now

            // `attitude.pitch` is already the tilt about the horizontal axis in
            // radians, positive nose-up — exactly the "tilt up/down" the guidance
            // needs. `roll` is the side-to-side tilt.
            let attitude = DeviceAttitude(
                pitch: motion.attitude.pitch * 180.0 / .pi,
                roll: motion.attitude.roll * 180.0 / .pi
            )
            onAttitude(attitude)
        }

        isActive = true
        return true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isActive = false
    }

    deinit {
        manager.stopDeviceMotionUpdates()
    }
}
