//
//  ViewPointEvaluator.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 20/10/26.
//

import Foundation

/// What the viewpoint check has to say about the current frame.
nonisolated struct ViewpointGuidance: Equatable, Sendable {
    /// One instruction, most important first, or nil when every enabled target is met.
    let instruction: String?
    /// A short "why" under the instruction.
    let detail: String?
    /// True when at least one target was checked and all checked targets are met.
    let isOnTarget: Bool
    /// What the camera is doing now, for the small readout chip.
    let readout: String?
    /// Why a "match my photos" target could not be applied, when that is the case.
    let limitation: String?

    static let silent = ViewpointGuidance(instruction: nil, detail: nil, isOnTarget: false, readout: nil, limitation: nil)
}

/// Compares the live viewpoint with the targets the user switched on.
///
/// ORDER. Moving the phone (angle, then height) comes before rotating it (pitch,
/// then horizon), because moving the phone also moves the subject in the frame;
/// the existing composition guidance then fine-tunes the subject's position.
/// Only the first unmet target is shown, so the user is never given two things
/// to do at once.
///
/// Pure and unit-testable: it takes numbers, not sensors.
nonisolated enum ViewpointEvaluator {

    /// "Level" pitch window, degrees either side of horizontal.
    static let levelPitchTolerance = 5.0
    /// Pitch window for "tilted up" (and mirrored for "tilted down"), degrees.
    static let tiltedPitchRange = 10.0...35.0
    /// A Dutch angle target: roll between these, degrees.
    static let dutchRollRange = DutchAngleRule.dutchDegrees...30.0
    /// Margin, degrees, added around angle bands so an instruction does not
    /// flicker at a boundary.
    static let angleMargin = 2.0

    static func evaluate(_ viewpoint: LiveViewpoint?,
                         settings: ViewpointGuidanceSettings,
                         preferences: LiveViewpointPreferences?) -> ViewpointGuidance {
        guard settings.isAnyGuidanceEnabled else { return .silent }
        guard let v = viewpoint else {
            return ViewpointGuidance(instruction: nil, detail: nil, isOnTarget: false, readout: nil,
                                     limitation: "Angle and tilt cannot be measured yet: the motion sensors or the camera lens are not ready.")
        }
        let prefs = preferences ?? .noData
        var limitations: [String] = []
        var checked = 0

        func noteMissing(_ what: String, _ reason: PreferenceUnavailableReason) {
            limitations.append("\(what): \(reason.explanation)")
        }
        func result(_ instruction: String, _ detail: String?) -> ViewpointGuidance {
            ViewpointGuidance(instruction: instruction, detail: detail, isOnTarget: false,
                              readout: readout(v, settings), limitation: nil)
        }

        if settings.angleEnabled {
            // 1. Vertical angle.
            var target = settings.angle.category
            if target == nil {
                switch prefs.angle {
                case .supported(let c): target = c
                case .unavailable(let r): noteMissing("Camera angle", r)
                }
            }
            if let target {
                if let elevation = v.elevation, let range = CameraAngleRule.elevationRange(of: target) {
                    checked += 1
                    if elevation < range.lowerBound - angleMargin {
                        return result(moveUp(to: target), angleDetail)
                    }
                    if elevation > range.upperBound + angleMargin {
                        return result(moveDown(to: target), angleDetail)
                    }
                } else {
                    limitations.append("Keep the subject's face in view to judge the camera angle.")
                }
            }

            // 2. Camera height against the body.
            var level = settings.height.level
            if level == nil, settings.height == .matchProfile {
                switch prefs.heightLevel {
                case .supported(let l): level = l
                case .unavailable(let r): noteMissing("Camera height", r)
                }
            }
            if let level, let want = level.rank {
                if let have = v.heightLevel.rank {
                    checked += 1
                    if have > want { return result("Raise the phone to \(bodyPart(level))", heightDetail) }
                    if have < want { return result("Lower the phone to \(bodyPart(level))", heightDetail) }
                } else {
                    limitations.append("Camera height needs more of the subject's body in view.")
                }
            }
        }

        if settings.tiltEnabled {
            // 3. Pitch.
            var range: ClosedRange<Double>?
            switch settings.pitch {
            case .level: range = -levelPitchTolerance...levelPitchTolerance
            case .tiltUp: range = tiltedPitchRange
            case .tiltDown: range = -tiltedPitchRange.upperBound...(-tiltedPitchRange.lowerBound)
            case .matchProfile:
                switch prefs.pitchUp {
                case .supported(let r): range = r
                case .unavailable(let r): noteMissing("Phone tilt", r)
                }
            }
            if let range {
                checked += 1
                if v.pitch < range.lowerBound {
                    return result("Tilt the phone up", String(format: "About %.0f° more", range.lowerBound - v.pitch))
                }
                if v.pitch > range.upperBound {
                    return result("Tilt the phone down", String(format: "About %.0f° more", v.pitch - range.upperBound))
                }
            }

            // 4. Horizon (roll).
            var horizon: DutchAngleCategory?
            switch settings.horizon {
            case .any: horizon = nil
            case .straight: horizon = .level
            case .dutch: horizon = .dutch
            case .matchProfile:
                switch prefs.dutchAngle {
                // An accidental slight tilt is not a habit worth reproducing.
                case .supported(let c): horizon = c == .dutch ? .dutch : .level
                case .unavailable(let r): noteMissing("Horizon", r)
                }
            }
            if let horizon {
                if let roll = v.roll {
                    checked += 1
                    let magnitude = abs(roll)
                    if horizon == .level, magnitude >= DutchAngleRule.levelDegrees {
                        return result("Straighten the phone", String(format: "The horizon is tilted %.0f°", magnitude))
                    }
                    if horizon == .dutch, magnitude < dutchRollRange.lowerBound {
                        return result("Tip the phone sideways for a Dutch angle", "About 15° to 25° to the left or right")
                    }
                    if horizon == .dutch, magnitude > dutchRollRange.upperBound {
                        return result("Tip the phone back a little", String(format: "%.0f° is more than a Dutch angle needs", magnitude))
                    }
                } else {
                    limitations.append("The horizon cannot be judged with the phone pointing straight up or down.")
                }
            }
        }

        return ViewpointGuidance(instruction: nil, detail: nil, isOnTarget: checked > 0,
                                 readout: readout(v, settings),
                                 limitation: limitations.first)
    }

    // MARK: Wording

    private static let angleDetail = "Move the phone itself; tilting it does not change the angle"
    private static let heightDetail = "Move the phone itself, not just its tilt"

    private static func moveUp(to target: CameraAngleCategory) -> String {
        switch target {
        case .birdsEye: return "Raise the phone high above the subject"
        case .highAngle: return "Raise the phone above the subject's eyes"
        case .eyeLevel: return "Raise the phone to the subject's eye level"
        case .lowAngle: return "Raise the phone a little, staying below the eyes"
        case .wormsEye, .unknown: return "Raise the phone"
        }
    }

    private static func moveDown(to target: CameraAngleCategory) -> String {
        switch target {
        case .birdsEye, .unknown: return "Lower the phone"
        case .highAngle: return "Lower the phone a little, staying above the eyes"
        case .eyeLevel: return "Lower the phone to the subject's eye level"
        case .lowAngle: return "Lower the phone below the subject's eyes"
        case .wormsEye: return "Get down low and shoot up at the subject"
        }
    }

    private static func bodyPart(_ level: CameraHeightLevel) -> String {
        switch level {
        case .aboveHead: return "above the subject's head"
        case .eye: return "the subject's eye height"
        case .shoulder: return "the subject's shoulder height"
        case .hip: return "the subject's hip height"
        case .knee: return "the subject's knee height"
        case .ground: return "near the ground"
        case .unknown: return "the right height"
        }
    }

    private static func readout(_ v: LiveViewpoint, _ settings: ViewpointGuidanceSettings) -> String? {
        var parts: [String] = []
        if settings.angleEnabled {
            if v.angle != .unknown { parts.append(angleName(v.angle)) }
            if v.heightLevel != .unknown { parts.append(v.heightLevel.phrase.replacingOccurrences(of: "camera ", with: "")) }
        }
        if settings.tiltEnabled {
            if abs(v.pitch) < 1 { parts.append("level") }
            else { parts.append(String(format: "%.0f° %@", abs(v.pitch), v.pitch > 0 ? "up" : "down")) }
            if let roll = v.roll, abs(roll) >= DutchAngleRule.levelDegrees {
                parts.append(String(format: "horizon %.0f°", abs(roll)))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func angleName(_ c: CameraAngleCategory) -> String {
        switch c {
        case .birdsEye: return "Bird's eye"
        case .highAngle: return "High angle"
        case .eyeLevel: return "Eye level"
        case .lowAngle: return "Low angle"
        case .wormsEye: return "Worm's eye"
        case .unknown: return "Unknown"
        }
    }
}

