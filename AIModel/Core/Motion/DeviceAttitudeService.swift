import Foundation
import CoreMotion

/// The device's physical camera attitude, in degrees.
///
/// Derived from the GRAVITY vector in device coordinates, relative to the BACK
/// camera's optical axis (device −Z), not from `CMAttitude.pitch`. That
/// matters: `CMAttitude.pitch` is 0 with the phone lying flat and about 90°
/// with it held upright, so it is not "looking up or down" for a camera held
/// the normal way.
nonisolated struct DeviceAttitude: Equatable, Sendable {
    /// Pitch in degrees: positive = camera tilted UP (looking above the
    /// horizon), negative = tilted DOWN. Range −90...90. 0 = phone upright.
    let pitch: Double

    /// Roll in degrees: the picture's sideways tilt away from the nearest upright
    /// orientation (portrait or landscape), positive = clockwise (right side
    /// down). Range −45...45.
    let roll: Double

    /// False when the phone points almost straight up or down: the picture's
    /// "up" is then undefined and `roll` means nothing.
    var isRollReliable: Bool = true

    static let zero = DeviceAttitude(pitch: 0, roll: 0)

    /// Beyond this pitch the roll is not reported as reliable.
    static let rollReliablePitchLimit = 70.0

    /// Attitude from gravity in device coordinates (units of g; x right,
    /// y towards the top of the screen, z out of the screen).
    ///
    /// The back camera looks along −z, so its elevation above the horizontal is
    /// asin(gravity.z): upright (gravity −y) gives 0, flat on a table pointing
    /// down (gravity −z) gives −90.
    static func from(gravityX x: Double, y: Double, z: Double) -> DeviceAttitude {
        let length = (x * x + y * y + z * z).squareRoot()
        guard length > 0.1 else { return .zero }
        let gz = max(-1, min(1, z / length))
        let pitch = asin(gz) * 180 / .pi

        // In-plane angle of gravity, 0 when it points to the bottom of the screen.
        let inPlane = atan2(x, -y) * 180 / .pi
        // Distance from the nearest of portrait / landscape / upside down.
        let roll = inPlane - 90 * (inPlane / 90).rounded()
        return DeviceAttitude(pitch: pitch, roll: roll,
                              isRollReliable: abs(pitch) < rollReliablePitchLimit)
    }
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

        // Only gravity is read, which every reference frame provides; the
        // arbitrary-X frame is the cheapest one.
        manager.deviceMotionUpdateInterval = interval
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let now = Date()
            guard now.timeIntervalSince(self.lastDelivery) >= self.interval else { return }
            self.lastDelivery = now

            // Gravity, not `attitude.pitch`: see `DeviceAttitude`.
            let g = motion.gravity
            onAttitude(DeviceAttitude.from(gravityX: g.x, y: g.y, z: g.z))
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
