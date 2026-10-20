//
//  LivePostDetector.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//

import Foundation
import CoreGraphics
import CoreVideo
import Vision

/// One person's body joints in a live frame, in frame space (0...1, origin
/// top-left), keeping only joints Vision is reasonably sure of.
nonisolated struct LivePose: Equatable, Sendable {
    let points: [BodyJoint: CGPoint]

    var jointHeights: SubjectJointHeights { SubjectJointHeights(points: points) }

    /// How many head-and-shoulder joints fall inside `box` (slightly enlarged).
    /// The live subject box covers the upper body only, so legs are not counted.
    func upperBodyMatches(_ box: CGRect) -> Int {
        let area = box.insetBy(dx: -0.05, dy: -0.05)
        let joints: [BodyJoint] = [.nose, .leftEye, .rightEye, .neck, .leftShoulder, .rightShoulder]
        return joints.compactMap { points[$0] }.filter { area.contains($0) }.count
    }

    /// The pose that belongs to the guided subject: the one with the most
    /// head-and-shoulder joints in its box. Without a box, only an unambiguous
    /// single pose is used.
    static func match(_ poses: [LivePose], to box: CGRect?) -> LivePose? {
        guard let box else { return poses.count == 1 ? poses[0] : nil }
        let scored = poses.map { ($0, $0.upperBodyMatches(box)) }.filter { $0.1 > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }
}

/// Runs Vision body pose on a live frame. A few times a second is enough: the
/// viewpoint changes slowly compared with the frame rate.
nonisolated enum LivePoseDetector {

    /// Same threshold the reference-photo analysis uses (`PoseCandidate.reliableThreshold`).
    static let minimumConfidence = PoseCandidate.reliableThreshold

    static func detect(in pixelBuffer: CVPixelBuffer) async -> [LivePose] {
        guard let observations = try? await DetectHumanBodyPoseRequest().perform(on: pixelBuffer) else { return [] }
        return observations.map { observation in
            var points: [BodyJoint: CGPoint] = [:]
            for (name, joint) in observation.allJoints() where Double(joint.confidence) >= minimumConfidence {
                guard let body = bodyJoint(name) else { continue }
                // Vision's origin is bottom-left; frame space is top-left.
                points[body] = CGPoint(x: Double(joint.location.x), y: 1 - Double(joint.location.y))
            }
            return LivePose(points: points)
        }.filter { !$0.points.isEmpty }
    }

    private static func bodyJoint(_ name: HumanBodyPoseObservation.JointName) -> BodyJoint? {
        switch name {
        case .nose: return .nose
        case .leftEye: return .leftEye
        case .rightEye: return .rightEye
        case .leftEar: return .leftEar
        case .rightEar: return .rightEar
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .root: return .root
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        @unknown default: return nil
        }
    }
}
