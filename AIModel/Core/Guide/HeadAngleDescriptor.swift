import Foundation

/// Turns raw head-pose angles into a plain-language description.
///
/// The per-photo card already shows the numbers (roll/yaw/pitch in degrees), but
/// degrees alone don't tell a photographer what the pose IS. This converts each
/// axis into a direction word and joins them, so the card reads "turned left,
/// level, chin up" instead of "yaw -22°, roll 3°, pitch 8°".
///
/// Pure and stateless — no Vision, no UI — so the wording thresholds are
/// unit-testable.
enum HeadAngleDescriptor {

    /// Angles below this magnitude (degrees) are treated as "level"/"facing
    /// forward" — nobody turns their head exactly 0°, so a small dead zone
    /// avoids describing a near-frontal face as turned.
    private static let deadZone: Double = 8

    /// Builds a description from the three head-pose axes.
    ///
    /// Any nil axis is skipped — a photo may measure yaw but not roll, and we
    /// describe only what was actually measured rather than guessing.
    ///
    /// - Returns: A terse phrase, or nil when nothing was measurable.
    static func describe(yaw: Double?, roll: Double?, pitch: Double?) -> String? {
        var parts: [String] = []

        // Yaw — head turned left/right relative to the camera.
        if let yaw {
            if abs(yaw) < deadZone {
                parts.append("facing camera")
            } else {
                parts.append(yaw > 0 ? "turned right" : "turned left")
            }
        }

        // Roll — head tilted sideways (ear toward shoulder).
        if let roll {
            if abs(roll) < deadZone {
                parts.append("level")
            } else {
                parts.append(roll > 0 ? "tilted right" : "tilted left")
            }
        }

        // Pitch — chin up/down.
        if let pitch {
            if abs(pitch) < deadZone {
                parts.append("chin level")
            } else {
                parts.append(pitch > 0 ? "chin up" : "chin down")
            }
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }
}
