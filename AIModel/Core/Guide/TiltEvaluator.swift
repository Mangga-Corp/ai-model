import Foundation

/// SUPERSEDED by `ViewpointEvaluator` (the camera no longer uses this type; kept for its
/// tests). It compared device PITCH with the legacy horizon angle, which is image ROLL.
///
/// Evaluates the device's physical tilt against the user's preferred horizon
/// angle, producing tilt-specific guidance.
///
/// WHY THIS IS SEPARATE FROM `CompositionEvaluator`: composition evaluation is
/// about where the SUBJECT sits in frame (from the detection box). Tilt
/// evaluation is about the PHONE's attitude in space (from Core Motion). They
/// are different measurements from different sensors, and mixing them would
/// couple a Vision-only testable path to a motion-only path. Keeping them apart
/// means the tilt logic is still pure and unit-testable — it just takes a pitch
/// number instead of a box.
///
/// IMPORTANT LIMITATION, stated honestly: a photo's horizon angle (from
/// `DetectHorizonRequest`) is the RESULTING image tilt, while device pitch is
/// the CAUSE. They are related but not identical — the same photo tilt can come
/// from different device pitches depending on how the phone was held. The
/// tolerance is therefore deliberately loose, and the guidance is phrased as a
/// nudge ("tilt down slightly") rather than a precise target. We do not claim
/// the device angle will reproduce the photo exactly.
struct TiltEvaluator {

    /// How far the device pitch may sit from the preferred tilt, in degrees,
    /// before guidance fires. Loose on purpose — see the limitation note above.
    var tolerance: Double = 8.0

    /// Below this absolute pitch, the device is near level and no tilt guidance
    /// is worth showing — it would be noise.
    var deadZone: Double = 3.0

    enum Guidance: Equatable {
        case tiltUp
        case tiltDown
        case onTarget
        case unavailable
    }

    /// Compares the current device pitch to the preferred horizon tilt.
    ///
    /// - Parameters:
    ///   - pitch: Current device pitch in degrees, positive = tilted up.
    ///   - preferredAngle: The profile's mean horizon angle in degrees, or nil
    ///     when the profile has no usable preference.
    func evaluate(pitch: Double, preferredAngle: Double?) -> Guidance {
        guard let preferredAngle else { return .unavailable }

        // The photo's horizon angle is the tilt of content in the image. To
        // reproduce it by holding the phone, the device pitch should match the
        // preferred image tilt in magnitude. We compare absolute pitch to the
        // absolute preferred angle, then use sign only to decide direction.
        let difference = abs(pitch) - abs(preferredAngle)

        // Near level and near target — nothing to say.
        if abs(difference) <= tolerance, abs(pitch) <= deadZone + abs(preferredAngle) {
            return .onTarget
        }

        if difference > tolerance {
            // Device is tilted more steeply than preferred → ease back toward level.
            return pitch > 0 ? .tiltDown : .tiltUp
        } else if difference < -tolerance {
            // Device is flatter than preferred → tilt further.
            return pitch >= 0 ? .tiltUp : .tiltDown
        }

        return .onTarget
    }

    /// Maps guidance to a single terse instruction, or nil when there is nothing
    /// stable to say. Terse by design — this sits in a one-line banner.
    func instruction(for guidance: Guidance) -> String? {
        switch guidance {
        case .tiltUp:   return "Tilt the camera up slightly"
        case .tiltDown: return "Tilt the camera down slightly"
        case .onTarget: return nil
        case .unavailable: return nil
        }
    }
}
