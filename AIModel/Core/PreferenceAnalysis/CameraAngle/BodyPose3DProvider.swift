//
//  BodyPose3DProvider.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//


import Foundation
import CoreGraphics

/// Provider: Vision's 3D body pose. DECISIVE when valid.
///
/// Vision reconstructs the subject's skeleton in metres and reports where the
/// camera was relative to it (`cameraOriginMatrix`). The camera's elevation over
/// the head and its height against the joints then follow directly, with no
/// horizon, no background lines and no lens assumption. That makes it the only
/// source that works for plain-background portraits, the case the 2D providers
/// leave unknown.
///
/// TRUST, stated plainly. The reconstruction is a learned estimate: without a
/// LiDAR depth measurement its scale comes from an assumed body height, and its
/// angular accuracy on everyday photos has not been measured in this app. The
/// interval is therefore wide (±8°, ±12° extended), so on its own it can only
/// settle clearly high or clearly low angles; next to another decisive source it
/// narrows the answer. Quality starts at low and rises to moderate only when the
/// device measured the body's size.
nonisolated enum BodyPose3DProvider {

    /// Half-width of the elevation interval, degrees.
    static let likelyHalfWidth = 8.0
    static let extendedHalfWidth = 12.0

    nonisolated struct Output: Sendable, Equatable {
        let observation: CameraAngleObservation
        /// The camera's height against the body, from the 3D joint heights.
        let heightLevel: CameraHeightLevel
    }

    static func observe(poses: EvidenceOutcome<[BodyPose3DCandidate]>, subjectBox: CGRect?) -> Output {
        func none(_ validity: ProviderValidity, _ summary: String) -> Output {
            Output(observation: .unavailable(.bodyPose3D, .decisive, validity, summary: summary), heightLevel: .unknown)
        }

        let all: [BodyPose3DCandidate]
        switch poses {
        case .produced(let p): all = p
        case .nothingDetected:
            return none(.notApplicable("No 3D body pose was found."), "The subject's body could not be reconstructed in 3D.")
        case .failed(let m), .skipped(let m):
            return none(.invalid("3D body pose did not run: \(m)"), "3D body pose was not available.")
        }

        guard let pose = match(all, to: subjectBox) else {
            return none(.invalid("No 3D pose belongs to the selected subject."),
                        "A 3D pose was found, but not for the subject being analysed.")
        }

        // The body frame must be upright for "up" to mean up: head above hips above ankles.
        let chain = [pose.headY, pose.shoulderY, pose.hipY, pose.kneeY, pose.ankleY].compactMap { $0 }
        guard chain.count >= 2, zip(chain, chain.dropFirst()).allSatisfy({ $0 > $1 }) else {
            return none(.invalid("The reconstructed body is not upright."),
                        "The 3D pose is not upright, so up and down are not defined for it.")
        }

        let dx = pose.cameraX - pose.headX, dy = pose.cameraY - pose.headY, dz = pose.cameraZ - pose.headZ
        let distance = (dx * dx + dz * dz).squareRoot()
        guard distance > 0.2, distance.isFinite, dy.isFinite else {
            return none(.invalid("The camera position is not usable."), "The camera position could not be reconstructed.")
        }
        let elevation = CameraGeometry.degrees(atan2(dy, distance))
        let interval = AngleInterval(nominal: elevation,
                                     likelyLow: elevation - likelyHalfWidth, likelyHigh: elevation + likelyHalfWidth,
                                     extendedLow: elevation - extendedHalfWidth, extendedHigh: elevation + extendedHalfWidth)

        // Camera height against the joints. The 2D rule works with "down" as positive, so negate.
        let joints = SubjectJointHeights(eyeY: -pose.headY, shoulderY: pose.shoulderY.map { -$0 },
                                         hipY: pose.hipY.map { -$0 }, kneeY: pose.kneeY.map { -$0 },
                                         ankleY: pose.ankleY.map { -$0 })
        let level = CameraHeightLevelRule.level(horizonY: -pose.cameraY, joints: joints)

        var quality: EvidenceQuality = pose.isHeightMeasured ? .moderate : .low
        var limitations = ["The 3D pose is a learned estimate; its scale assumes a typical body height unless the device measured depth."]
        if pose.confidence < 0.5 {
            quality = .low
            limitations.append("Vision's confidence in the 3D pose is low.")
        }

        let summary: String
        if dy > 0.15 { summary = "The reconstructed camera sits above the subject's head height." }
        else if dy < -0.15 { summary = "The reconstructed camera sits below the subject's head height." }
        else { summary = "The reconstructed camera sits close to the subject's head height." }

        var measurements = [
            ObservationMeasurement(label: "Camera vs head height", value: String(format: "%+.2f m", dy)),
            ObservationMeasurement(label: "Camera distance", value: String(format: "%.1f m", distance)),
            ObservationMeasurement(label: "Elevation to the head", value: String(format: "%+.0f°", elevation)),
        ]
        if level != .unknown {
            measurements.append(ObservationMeasurement(label: "Camera height", value: level.phrase))
        }

        let observation = CameraAngleObservation(
            provider: .bodyPose3D, role: .decisive, validity: .valid,
            elevation: interval, pitchDown: nil, tiltHint: nil, quality: quality,
            summary: summary, measurements: measurements, limitations: limitations)
        return Output(observation: observation, heightLevel: level)
    }

    /// The pose whose head lies inside the subject's box; a lone pose when there is no head point.
    static func match(_ poses: [BodyPose3DCandidate], to box: CGRect?) -> BodyPose3DCandidate? {
        if let box {
            let area = box.insetBy(dx: -0.02, dy: -0.02)
            if let hit = poses.first(where: { pose in pose.headInImage.map { area.contains($0) } ?? false }) { return hit }
        }
        return poses.count == 1 && poses[0].headInImage == nil ? poses[0] : nil
    }
}
