import Foundation
import CoreGraphics

/// Where the subject's eyes are, and whether the subject is upright.
///
/// Camera angle is the camera's height RELATIVE TO THE SUBJECT, so every
/// decisive provider needs a reference point on the subject. The eye line is
/// that reference: it is what a viewer compares the camera against.
nonisolated struct SubjectAnchor: Sendable, Equatable {
    /// Image space.
    let eyePoint: CGPoint
    let eyeSource: String
    /// True when the eye line was inferred from a face rectangle rather than
    /// measured from eye landmarks.
    let isEstimated: Bool
    /// Height of the face rectangle, image-height units.
    let headHeight: Double?
    let faceConfidence: Double?
    /// Angle between the hip-to-neck axis and image vertical, degrees (0 = upright).
    let torsoTiltDegrees: Double?

    static let uprightToleranceDegrees = 30.0

    /// nil when posture could not be measured.
    var isUpright: Bool? { torsoTiltDegrees.map { $0 <= Self.uprightToleranceDegrees } }
}

/// Provider: subject-relative geometry. CONTEXT, never decisive.
///
/// Rationale for the posture check: "high angle" and "low angle" are judged
/// against an upright person. For a bent-over or reclining subject the eye
/// line is still well defined, but the conventional meaning of the angle is
/// not, so results for non-upright subjects lose one quality grade.
nonisolated enum SubjectGeometryProvider {

    static func observe(pose: PoseCandidate?, face: FaceCandidate?) -> (anchor: SubjectAnchor?, observation: CameraAngleObservation) {
        var eye: CGPoint?
        var source = ""
        var estimated = false

        if let pose {
            let eyes = [BodyJoint.leftEye, .rightEye].compactMap { pose.reliable($0) }
            if !eyes.isEmpty {
                eye = CGPoint(x: eyes.reduce(0) { $0 + Double($1.point.x) } / Double(eyes.count),
                              y: eyes.reduce(0) { $0 + Double($1.point.y) } / Double(eyes.count))
                source = "\(eyes.count) pose eye landmark(s)"
            }
        }
        if eye == nil, let face {
            // Eyes sit roughly 40% of the way down a face rectangle.
            eye = CGPoint(x: face.box.midX, y: face.box.minY + face.box.height * 0.40)
            source = "face rectangle (40% from top)"
            estimated = true
        }

        guard let eye else {
            return (nil, .unavailable(
                .subjectGeometry, .contextual,
                .invalid("Neither eye landmarks nor a face were found for the main subject."),
                summary: "The subject's eye line could not be located, so the camera cannot be compared with it."))
        }

        let head = face.map { Double($0.box.height) }.flatMap { $0 > 0.01 ? $0 : nil }
        let tilt = torsoTilt(pose)
        let anchor = SubjectAnchor(eyePoint: eye, eyeSource: source, isEstimated: estimated, headHeight: head,
                                   faceConfidence: face?.confidence, torsoTiltDegrees: tilt)

        var measurements = [
            ObservationMeasurement(label: "Eye line", value: String(format: "(%.3f, %.3f) from %@", eye.x, eye.y, source))
        ]
        var limitations: [String] = []
        if let head { measurements.append(.init(label: "Head height", value: String(format: "%.1f%% of image height", head * 100))) }
        if let tilt {
            measurements.append(.init(label: "Torso axis from vertical", value: String(format: "%.0f°", tilt)))
            if tilt > SubjectAnchor.uprightToleranceDegrees {
                limitations.append("The subject is not upright (bending, leaning or reclining), so \"high\" and \"low\" angle are less well defined.")
            }
        }
        if estimated { limitations.append("The eye line was estimated from the face rectangle because eye landmarks were unreliable.") }

        let posture = tilt.map { $0 <= SubjectAnchor.uprightToleranceDegrees ? "upright" : "not upright" } ?? "posture not measurable"
        return (anchor, CameraAngleObservation(
            provider: .subjectGeometry, role: .contextual, validity: .valid, elevation: nil, pitchDown: nil,
            tiltHint: nil, quality: estimated ? .low : .moderate,
            summary: "The subject's eye line is located (\(posture)).",
            measurements: measurements, limitations: limitations))
    }

    /// Angle of the hip-to-neck axis from image vertical, in degrees.
    static func torsoTilt(_ pose: PoseCandidate?) -> Double? {
        guard let pose else { return nil }
        let neck: CGPoint?
        if let n = pose.reliable(.neck) { neck = n.point }
        else if let l = pose.reliable(.leftShoulder), let r = pose.reliable(.rightShoulder) {
            neck = CGPoint(x: (l.point.x + r.point.x) / 2, y: (l.point.y + r.point.y) / 2)
        } else { neck = nil }

        let hips = [BodyJoint.leftHip, .rightHip].compactMap { pose.reliable($0) }
        let hip: CGPoint?
        if !hips.isEmpty {
            hip = CGPoint(x: hips.reduce(0) { $0 + Double($1.point.x) } / Double(hips.count),
                          y: hips.reduce(0) { $0 + Double($1.point.y) } / Double(hips.count))
        } else { hip = pose.reliable(.root)?.point }

        guard let neck, let hip else { return nil }
        let vx = Double(neck.x - hip.x), vy = Double(neck.y - hip.y)
        let length = (vx * vx + vy * vy).squareRoot()
        guard length >= 0.04 else { return nil }
        return CameraGeometry.degrees(acos(max(-1, min(1, -vy / length))))
    }
}
