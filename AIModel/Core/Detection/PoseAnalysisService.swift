import Foundation
import Vision
import CoreGraphics

/// Protocol defining the pose analysis service interface.
protocol PoseAnalyzing {
    func analyzeHeadPose(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> HeadPoseResult
    func analyzeBodyPose(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> BodyPoseResult
}

/// PoseAnalysisService — detects head pose angles and body pose joints.
///
/// Head Pose: Uses DetectFaceRectanglesRequest which provides roll, yaw, pitch
/// Body Pose: Uses DetectHumanBodyPoseRequest which provides body joints via keypoints MLMultiArray
final class PoseAnalysisService: PoseAnalyzing {

    // MARK: - Head Pose

    func analyzeHeadPose(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> HeadPoseResult {
        let request = DetectFaceRectanglesRequest()

        do {
            let observations: [FaceObservation] = try await request.perform(on: cgImage, orientation: orientation)

            guard let face = observations.first else {
                return HeadPoseResult(roll: nil, yaw: nil, pitch: nil, boundingBox: nil, confidence: nil, isAvailable: false)
            }

            let rollDegrees = face.roll.converted(to: .degrees).value
            let yawDegrees = face.yaw.converted(to: .degrees).value
            let pitchDegrees = face.pitch.converted(to: .degrees).value

            return HeadPoseResult(
                roll: rollDegrees,
                yaw: yawDegrees,
                pitch: pitchDegrees,
                boundingBox: face.boundingBox,
                confidence: face.confidence,
                isAvailable: true
            )
        } catch {
            return HeadPoseResult(roll: nil, yaw: nil, pitch: nil, boundingBox: nil, confidence: nil, isAvailable: false)
        }
    }

    // MARK: - Body Pose

    func analyzeBodyPose(cgImage: CGImage, orientation: CGImagePropertyOrientation) async -> BodyPoseResult {
        let request = DetectHumanBodyPoseRequest()

        do {
            let observations: [HumanBodyPoseObservation] = try await request.perform(on: cgImage, orientation: orientation)

            guard let body = observations.first else {
                return BodyPoseResult(
                    jointCount: nil,
                    orientation: nil,
                    symmetry: nil,
                    dominantGroup: nil,
                    isAvailable: false
                )
            }

            // Extract joints from the keypoints MLMultiArray
            // Format: [numJoints, 3] where each row is [x, y, confidence]
            let keypoints = body.keypoints
            let jointCount = keypoints.shape[0].intValue

            var recognizedJoints: [String: CGPoint] = [:]

            // Joint names in the order they appear in the keypoints array
            // Based on Apple's HumanBodyPoseObservation.JointName ordering
            let jointNames: [String] = [
                "nose", "leftEye", "rightEye", "leftEar", "rightEar",
                "leftShoulder", "rightShoulder", "leftElbow", "rightElbow",
                "leftWrist", "rightWrist", "leftHip", "rightHip",
                "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
                "neck", "root"
            ]

            for i in 0..<min(jointCount, jointNames.count) {
                let x = keypoints[[NSNumber(value: i), NSNumber(value: 0)]].doubleValue
                let y = keypoints[[NSNumber(value: i), NSNumber(value: 1)]].doubleValue
                let confidence = keypoints[[NSNumber(value: i), NSNumber(value: 2)]].doubleValue

                if confidence > 0.3 {
                    // Convert from Vision bottom-left to UIKit top-left coords
                    recognizedJoints[jointNames[i]] = CGPoint(x: x, y: 1.0 - y)
                }
            }

            let validJointCount = recognizedJoints.count

            // Compute body orientation from shoulder-to-hip axis
            var bodyOrientation: Double?
            var bodySymmetry: Double?

            if let leftShoulder = recognizedJoints["leftShoulder"],
               let rightShoulder = recognizedJoints["rightShoulder"] {
                let dx = rightShoulder.x - leftShoulder.x
                let dy = rightShoulder.y - leftShoulder.y
                bodyOrientation = atan2(dy, dx) * 180 / .pi
            }

            if let leftShoulder = recognizedJoints["leftShoulder"],
               let rightShoulder = recognizedJoints["rightShoulder"],
               let leftHip = recognizedJoints["leftHip"],
               let rightHip = recognizedJoints["rightHip"] {
                let shoulderMidX = (leftShoulder.x + rightShoulder.x) / 2
                let hipMidX = (leftHip.x + rightHip.x) / 2
                let deviation = abs(shoulderMidX - hipMidX)
                bodySymmetry = max(0, 1.0 - deviation * 2.0)
            }

            let dominantGroup = determineDominantGroup(joints: recognizedJoints)

            return BodyPoseResult(
                jointCount: validJointCount,
                orientation: bodyOrientation,
                symmetry: bodySymmetry,
                dominantGroup: dominantGroup,
                isAvailable: validJointCount > 0
            )
        } catch {
            return BodyPoseResult(jointCount: nil, orientation: nil, symmetry: nil, dominantGroup: nil, isAvailable: false)
        }
    }

    /// Determines which joint group has the most recognized points.
    private func determineDominantGroup(joints: [String: CGPoint]) -> String? {
        var groupCounts: [String: Int] = [
            "Head": 0,
            "Torso": 0,
            "Arms": 0,
            "Legs": 0
        ]

        let headJoints: Set<String> = ["nose", "leftEye", "rightEye", "leftEar", "rightEar", "neck"]
        let torsoJoints: Set<String> = ["leftShoulder", "rightShoulder", "leftHip", "rightHip", "root"]
        let armJoints: Set<String> = ["leftElbow", "rightElbow", "leftWrist", "rightWrist"]
        let legJoints: Set<String> = ["leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]

        for (joint, _) in joints {
            if headJoints.contains(joint) {
                groupCounts["Head", default: 0] += 1
            } else if torsoJoints.contains(joint) {
                groupCounts["Torso", default: 0] += 1
            } else if armJoints.contains(joint) {
                groupCounts["Arms", default: 0] += 1
            } else if legJoints.contains(joint) {
                groupCounts["Legs", default: 0] += 1
            }
        }

        return groupCounts.max(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Result Types

struct HeadPoseResult {
    let roll: Double?     // Degrees, head tilt
    let yaw: Double?      // Degrees, head turn left/right
    let pitch: Double?    // Degrees, head nod up/down
    let boundingBox: NormalizedRect?
    let confidence: Float?
    let isAvailable: Bool
}

struct BodyPoseResult {
    let jointCount: Int?
    let orientation: Double?   // Degrees, body axis angle
    let symmetry: Double?      // 0-1
    let dominantGroup: String?
    let isAvailable: Bool
}
