//
//  ViewpointGuidanceSettings.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//

import Foundation

// MARK: - Viewpoint guidance settings
//
// Two switches, as the camera screen shows them:
//  - "Camera angle": the vertical angle (bird's eye … worm's eye) and,
//    optionally, the camera's height against the body. Fixed by MOVING the phone.
//  - "Phone tilt": pitch (looking up / level / down) and the horizon
//    (straight or Dutch). Fixed by ROTATING the phone.
// Both off = the camera behaves exactly as before this feature.
// Each target is either a fixed choice or "match my photos" (the habit learned
// from the reference photos, when the evidence supports one).

nonisolated enum AngleTarget: String, CaseIterable, Sendable, Hashable {
    case matchProfile, birdsEye, highAngle, eyeLevel, lowAngle, wormsEye

    var category: CameraAngleCategory? {
        switch self {
        case .matchProfile: return nil
        case .birdsEye: return .birdsEye
        case .highAngle: return .highAngle
        case .eyeLevel: return .eyeLevel
        case .lowAngle: return .lowAngle
        case .wormsEye: return .wormsEye
        }
    }

    var title: String {
        switch self {
        case .matchProfile: return "Match my photos"
        case .birdsEye: return "Bird's eye"
        case .highAngle: return "High angle"
        case .eyeLevel: return "Eye level"
        case .lowAngle: return "Low angle"
        case .wormsEye: return "Worm's eye"
        }
    }
}

nonisolated enum HeightTarget: String, CaseIterable, Sendable, Hashable {
    case any, matchProfile, aboveHead, eye, shoulder, hip, knee, ground

    var level: CameraHeightLevel? {
        switch self {
        case .any, .matchProfile: return nil
        case .aboveHead: return .aboveHead
        case .eye: return .eye
        case .shoulder: return .shoulder
        case .hip: return .hip
        case .knee: return .knee
        case .ground: return .ground
        }
    }

    var title: String {
        switch self {
        case .any: return "Any height"
        case .matchProfile: return "Match my photos"
        case .aboveHead: return "Above head"
        case .eye: return "Eye level"
        case .shoulder: return "Shoulder level"
        case .hip: return "Hip level"
        case .knee: return "Knee level"
        case .ground: return "Ground level"
        }
    }
}

nonisolated enum PitchTarget: String, CaseIterable, Sendable, Hashable {
    case matchProfile, level, tiltUp, tiltDown

    var title: String {
        switch self {
        case .matchProfile: return "Match my photos"
        case .level: return "Level"
        case .tiltUp: return "Tilted up"
        case .tiltDown: return "Tilted down"
        }
    }
}

nonisolated enum HorizonTarget: String, CaseIterable, Sendable, Hashable {
    case any, straight, dutch, matchProfile

    var title: String {
        switch self {
        case .any: return "Any"
        case .straight: return "Straight"
        case .dutch: return "Dutch angle"
        case .matchProfile: return "Match my photos"
        }
    }
}

nonisolated struct ViewpointGuidanceSettings: Equatable, Sendable {
    var angleEnabled = false
    var angle: AngleTarget = .matchProfile
    var height: HeightTarget = .any

    var tiltEnabled = false
    var pitch: PitchTarget = .matchProfile
    var horizon: HorizonTarget = .straight

    /// Keep each capture's sensor readings (and the photo) on the device, as
    /// labelled examples for training a viewpoint model later. Off by default.
    var recordCaptureData = false

    var isAnyGuidanceEnabled: Bool { angleEnabled || tiltEnabled }

    static let off = ViewpointGuidanceSettings()
}
