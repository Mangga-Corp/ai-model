import Foundation
import CoreGraphics

/// Provider: head orientation. CONTEXT ONLY.
///
/// Vision reports the head's pitch/yaw/roll RELATIVE TO THE CAMERA. That
/// mixes two unknowns: where the camera is, and where the subject chose to
/// look. People looking into the lens from a high or low camera tilt their
/// head toward it, which drives the reported pitch back toward zero, so the
/// value cannot be read as camera elevation in either direction. It is recorded
/// for transparency and used only to flag limitations.
nonisolated enum HeadOrientationProvider {

    static let stronglyPitchedDegrees = 20.0
    static let profileViewDegrees = 45.0

    static func observe(face: FaceCandidate?) -> CameraAngleObservation {
        guard let face else {
            return .unavailable(.headOrientation, .contextual,
                                .notApplicable("No face was matched to the main subject."),
                                summary: "No head orientation was available.")
        }
        var limitations: [String] = []
        if abs(face.pitchDegrees) >= stronglyPitchedDegrees {
            limitations.append("The head is strongly pitched. That reflects where the subject looks, not where the camera is.")
        }
        if abs(face.yawDegrees) >= profileViewDegrees {
            limitations.append("The face is in profile, so eye landmarks and face-based measurements are less reliable.")
        }
        return CameraAngleObservation(
            provider: .headOrientation, role: .contextual, validity: .valid, elevation: nil, pitchDown: nil,
            tiltHint: nil, quality: .none,
            summary: "Head orientation describes where the face points, not where the camera is, so it was not used to decide.",
            measurements: [ObservationMeasurement(
                label: "Head pitch / yaw / roll",
                value: String(format: "%.0f° / %.0f° / %.0f°", face.pitchDegrees, face.yawDegrees, face.rollDegrees))],
            limitations: limitations)
    }
}

/// Provider: relative depth of head versus lower body. CROSS-CHECK ONLY.
///
/// PHYSICS. For an upright person, the head lies above the feet along the
/// world's vertical. If the camera is tilted down, that vertical points
/// partly along the viewing direction, so the head is NEARER to the image
/// plane than the feet; tilted up, the head is FARTHER. So the ordering of
/// head and lower-body depth hints at camera TILT (not position).
///
/// WHY IT NEVER DECIDES. The signal is small (a person's height times the sine
/// of a small tilt, against a model that renders people as nearly uniform
/// blobs), the depth scale is relative, and tilt is not elevation. It can only
/// confirm or contradict the tilt implied by a decisive provider, and the
/// threshold for reporting a direction is set above the model's own noise.
nonisolated enum DepthTiltProvider {

    static let minimumSamples = 80
    static let minimumVerticalExtent = 0.25
    static let minimumDifference = 0.10

    static func observe(primary: HumanCandidate,
                        segmentation: SegmentationGrid?,
                        depth: DepthGrid?) -> CameraAngleObservation {
        func none(_ validity: ProviderValidity, _ summary: String) -> CameraAngleObservation {
            .unavailable(.depthTilt, .corroborating, validity, summary: summary)
        }
        guard let depth else { return none(.invalid("The depth map is unavailable."), "No relative depth was available for a cross-check.") }
        guard let segmentation, segmentation.personClassIndex != nil else {
            return none(.invalid("A person mask is needed to separate the subject's depth from the background."),
                        "No person mask was available for a depth cross-check.")
        }

        // Person-mask depth samples inside the subject's box.
        let region = ImageSpace.expanded(primary.box, by: 0.02)
        var samples: [(y: Double, v: Float)] = []
        var gy = 0
        while gy < depth.height {
            var gx = 0
            while gx < depth.width {
                let p = CGPoint(x: (CGFloat(gx) + 0.5) / CGFloat(depth.width), y: (CGFloat(gy) + 0.5) / CGFloat(depth.height))
                if region.contains(p), segmentation.isPerson(atNormalized: p) {
                    samples.append((Double(p.y), depth.nearness[gy * depth.width + gx]))
                }
                gx += 2
            }
            gy += 2
        }
        guard samples.count >= 300 else {
            return none(.notApplicable("The subject covers too little of the depth map (\(samples.count) samples)."),
                        "The subject is too small in the depth map for a cross-check.")
        }
        let rows = samples.map(\.y).sorted()
        let top = rows[rows.count / 20], bottom = rows[(rows.count * 19) / 20]
        let extent = bottom - top
        guard extent >= minimumVerticalExtent else {
            return none(.notApplicable("The visible subject spans only \(Int(extent * 100))% of the image height."),
                        "The subject spans too little height for a head-versus-body depth comparison.")
        }

        let head = samples.filter { $0.y <= top + 0.25 * extent }.map(\.v)
        let lower = samples.filter { $0.y >= bottom - 0.30 * extent }.map(\.v)
        guard head.count >= minimumSamples, lower.count >= minimumSamples else {
            return none(.notApplicable("Too few person pixels in the head or lower-body region."),
                        "Not enough subject pixels for a head-versus-body depth comparison.")
        }

        let difference = Double(median(head) - median(lower))
        let noise = Double(max(spread(head), spread(lower)))
        let threshold = max(minimumDifference, 0.75 * noise)
        let hint: CameraTilt = difference > threshold ? .down : (difference < -threshold ? .up : .level)

        let summary: String
        switch hint {
        case .down: summary = "The head is clearly nearer than the lower body in relative depth, which fits a camera tilted down."
        case .up: summary = "The head is clearly farther than the lower body in relative depth, which fits a camera tilted up."
        case .level: summary = "Head and lower body sit at similar relative depth: no clear tilt signal."
        }
        return CameraAngleObservation(
            provider: .depthTilt, role: .corroborating, validity: .valid, elevation: nil, pitchDown: nil,
            tiltHint: hint, quality: .low, summary: summary,
            measurements: [
                ObservationMeasurement(label: "Head minus lower body (relative depth)", value: String(format: "%+.2f", difference)),
                ObservationMeasurement(label: "Noise floor", value: String(format: "%.2f", threshold))
            ],
            limitations: ["Relative depth is approximate and the signal is small; this can only confirm or contradict another source."])
    }

    private static func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }

    private static func spread(_ v: [Float]) -> Float {
        guard v.count >= 4 else { return 0 }
        let s = v.sorted()
        return s[(s.count * 3) / 4] - s[s.count / 4]
    }
}
