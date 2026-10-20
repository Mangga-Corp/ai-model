//
//  CameraViewPointModel.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//

import Foundation
import CoreGraphics

// MARK: - Camera viewpoint vocabulary
//
// A shot's viewpoint is described by three INDEPENDENT things, because a
// photographer can change each one without changing the others:
//
//  1. Vertical angle (`CameraAngleCategory`): the direction from the camera to
//     the subject's eyes. Bird's eye, high, eye level, low, worm's eye.
//     Changed by MOVING the phone (up/down, closer/farther). Rotating the
//     phone in place does not change it.
//  2. Camera height (`CameraHeightLevel`): which part of the subject's body
//     the camera is level with. Above the head, eye, shoulder, hip, knee,
//     ground. Also changed by moving the phone up or down.
//  3. Phone tilt: pitch (looking up or down) and roll (`DutchAngleCategory`,
//     the horizon tipped sideways). Changed by ROTATING the phone in place.
//
// Pitch and roll are measured live by Core Motion. Angle and height are
// computed from pitch, the lens field of view and where the subject's joints
// sit in the frame (`LiveViewpointMeasurer`); in reference photos they are
// inferred from the horizon and scene geometry (`CameraAngleInterpreter`).

/// Which part of an upright subject's body the camera is level with.
///
/// Geometry: on level ground, every point at the camera's own height projects
/// onto the image's horizon line. So the body part the horizon line crosses is
/// the part the camera is level with, whatever the distance.
nonisolated enum CameraHeightLevel: String, Sendable, CaseIterable, Hashable, Codable {
    /// Camera higher than the top of the head.
    case aboveHead
    /// Level with the eyes.
    case eye
    /// Level with the shoulders / chest.
    case shoulder
    /// Level with the hips / waist.
    case hip
    /// Level with the knees.
    case knee
    /// At or near the ground (below the knees).
    case ground
    case unknown

    /// Highest first. `unknown` is not part of the order.
    static let ordered: [CameraHeightLevel] = [.aboveHead, .eye, .shoulder, .hip, .knee, .ground]

    /// Position in `ordered` (0 = highest), nil for `unknown`.
    var rank: Int? { Self.ordered.firstIndex(of: self) }

    /// Lower-case words for generated sentences.
    var phrase: String {
        switch self {
        case .aboveHead: return "camera above head height"
        case .eye: return "camera at eye height"
        case .shoulder: return "camera at shoulder height"
        case .hip: return "camera at hip height"
        case .knee: return "camera at knee height"
        case .ground: return "camera at ground level"
        case .unknown: return "unknown camera height"
        }
    }
}

/// How far the horizon is tipped sideways (camera roll).
nonisolated enum DutchAngleCategory: String, Sendable, CaseIterable, Hashable, Codable {
    /// Horizon straight.
    case level
    /// Slightly tipped: usually accidental and reads as a mistake.
    case slightTilt
    /// Deliberately tipped (Dutch / canted angle).
    case dutch
    case unknown

    /// Lower-case words for generated sentences.
    var phrase: String {
        switch self {
        case .level: return "straight horizon"
        case .slightTilt: return "slightly tilted horizon"
        case .dutch: return "Dutch angle"
        case .unknown: return "unknown horizon tilt"
        }
    }
}

/// Image-space heights (y, 0 = top) of an upright subject's main joints.
/// Left and right joints are averaged; a missing pair stays nil.
nonisolated struct SubjectJointHeights: Sendable, Equatable {
    var eyeY: Double?
    var shoulderY: Double?
    var hipY: Double?
    var kneeY: Double?
    var ankleY: Double?

    init(eyeY: Double? = nil, shoulderY: Double? = nil, hipY: Double? = nil,
         kneeY: Double? = nil, ankleY: Double? = nil) {
        self.eyeY = eyeY
        self.shoulderY = shoulderY
        self.hipY = hipY
        self.kneeY = kneeY
        self.ankleY = ankleY
    }

    /// From joint points in image space (top-left origin). Only joints the
    /// caller already judged reliable should be passed in.
    init(points: [BodyJoint: CGPoint]) {
        func pair(_ a: BodyJoint, _ b: BodyJoint) -> Double? {
            let ys = [points[a], points[b]].compactMap { $0.map { Double($0.y) } }
            return ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count)
        }
        self.init(eyeY: pair(.leftEye, .rightEye) ?? points[.nose].map { Double($0.y) },
                  shoulderY: pair(.leftShoulder, .rightShoulder) ?? points[.neck].map { Double($0.y) },
                  hipY: pair(.leftHip, .rightHip) ?? points[.root].map { Double($0.y) },
                  kneeY: pair(.leftKnee, .rightKnee),
                  ankleY: pair(.leftAnkle, .rightAnkle))
    }

    init(pose: PoseCandidate) {
        var points: [BodyJoint: CGPoint] = [:]
        for landmark in pose.reliableLandmarks() { points[landmark.joint] = landmark.point }
        self.init(points: points)
    }
}

// MARK: - Rules

extension CameraAngleRule {
    /// Beyond this elevation (in either direction) the shot is no longer just
    /// "high" or "low" but bird's eye (looking steeply down on the subject) or
    /// worm's eye (looking steeply up). A product choice: 45° is half-way to
    /// straight overhead.
    nonisolated static let extremeAngleDegrees = 45.0
}

nonisolated enum CameraHeightLevelRule {

    /// The camera's height relative to the subject's body, from where the
    /// image's horizon line (`horizonY`, image space) crosses the body.
    ///
    /// Boundaries sit half-way between neighbouring joints. Above the eyes the
    /// top of the head is taken as 0.6 of the eye-to-shoulder distance above
    /// the eyes. A level needs the joints on both sides of its boundaries:
    /// when the horizon falls beyond the lowest visible joint, the answer is
    /// `unknown` rather than a guess. Joints out of top-to-bottom order (a
    /// subject who is not upright) also give `unknown`.
    static func level(horizonY: Double, joints: SubjectJointHeights) -> CameraHeightLevel {
        guard horizonY.isFinite, let eye = joints.eyeY else { return .unknown }

        let chain: [(CameraHeightLevel, Double?)] = [
            (.eye, eye), (.shoulder, joints.shoulderY), (.hip, joints.hipY),
            (.knee, joints.kneeY), (.ground, joints.ankleY)
        ]
        // Keep the visible prefix; a gap ends what can be judged.
        var known: [(CameraHeightLevel, Double)] = []
        for (level, y) in chain {
            guard let y else { break }
            if let last = known.last, y <= last.1 { return .unknown }   // not upright
            known.append((level, y))
        }

        // The eyes alone give no scale to judge distances from them by.
        guard known.count >= 2 else { return .unknown }

        // Above the head.
        if horizonY < eye - (known[1].1 - eye) * 0.6 { return .aboveHead }

        for i in 0..<known.count {
            let (level, y) = known[i]
            if i + 1 < known.count {
                let boundary = (y + known[i + 1].1) / 2
                if horizonY < boundary { return level }
            } else if level == .ground {
                return .ground
            } else {
                // Below the last visible joint's own band: only the joint itself is known.
                let halfBand = (y - known[i - 1].1) / 2
                return horizonY <= y + halfBand ? level : .unknown
            }
        }
        return .unknown
    }
}

nonisolated enum DutchAngleRule {
    /// Below this roll the horizon reads as straight.
    static let levelDegrees = 3.0
    /// From this roll on, the tilt reads as deliberate.
    static let dutchDegrees = 10.0

    static func category(rollDegrees: Double?) -> DutchAngleCategory {
        guard let roll = rollDegrees, roll.isFinite else { return .unknown }
        let magnitude = abs(roll)
        if magnitude < levelDegrees { return .level }
        if magnitude < dutchDegrees { return .slightTilt }
        return .dutch
    }
}
