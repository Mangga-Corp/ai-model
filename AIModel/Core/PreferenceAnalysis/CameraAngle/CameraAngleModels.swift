import Foundation
import CoreGraphics

// MARK: - Raw observations (no classification happens here)
//
// Each provider looks at one kind of evidence and reports what it observed,
// whether that observation is valid, and how far it can be trusted. Providers
// never see each other's output and never choose the final category; that is
// the job of `CameraAngleFusion`.

nonisolated enum CameraAngleProvider: String, Sendable, CaseIterable, Hashable, Identifiable {
    /// Where a visible horizon runs relative to the subject's eyes.
    case horizonLine
    /// Convergence of vertical structure (walls, door frames, building edges).
    case sceneVerticals
    /// The subject's own eye line and posture. Context that other providers depend on.
    case subjectGeometry
    /// Where the face points. Context only: it describes the head, not the camera.
    case headOrientation
    /// Relative depth of head versus lower body. A weak cross-check on camera tilt.
    case depthTilt
    /// Camera position reconstructed with the subject's 3D body pose (Vision, iOS 17+).
    case bodyPose3D
    /// The app's own viewpoint model: camera pitch and lens from the whole picture.
    case viewpointModel

    var id: String { rawValue }
}

nonisolated enum CameraAngleRole: String, Sendable, Hashable {
    /// Can establish the camera's height relative to the eyes by itself.
    case decisive
    /// Can only confirm or contradict a decisive provider.
    case corroborating
    /// Recorded for context and limitations. Never selects a category.
    case contextual
}

/// Whether a provider could make a valid observation, and if not, why not.
nonisolated enum ProviderValidity: Sendable, Equatable {
    case valid
    /// The evidence this provider needs is absent from the scene (an expected,
    /// ordinary outcome, for example no horizon in a living room).
    case notApplicable(String)
    /// Evidence existed or was needed, but it failed validation or a dependency is missing.
    case invalid(String)

    var isValid: Bool { if case .valid = self { return true } else { return false } }

    var reason: String? {
        switch self {
        case .valid: return nil
        case .notApplicable(let r), .invalid(let r): return r
        }
    }
}

/// An angle, in degrees, with its sensitivity to the unknown lens.
///
/// INTERNAL modelling quantity, not a measurement and never shown to users as
/// one. `nominal` assumes a typical phone main camera. `likely*` spans the
/// phone-like lens range; `extended*` also covers longer lenses.
nonisolated struct AngleInterval: Sendable, Equatable {
    let nominal: Double
    let likelyLow: Double
    let likelyHigh: Double
    let extendedLow: Double
    let extendedHigh: Double
}

/// Which way a provider says the camera is tilted (not where it is positioned).
nonisolated enum CameraTilt: String, Sendable, Hashable {
    case down, level, up
}

nonisolated struct ObservationMeasurement: Sendable, Equatable {
    let label: String
    let value: String
}

nonisolated struct CameraAngleObservation: Sendable, Equatable, Identifiable {
    var id: String { provider.rawValue }
    let provider: CameraAngleProvider
    let role: CameraAngleRole
    let validity: ProviderValidity
    /// Camera elevation relative to the subject's eyes. Positive = camera ABOVE the eyes.
    /// Only decisive providers set this.
    let elevation: AngleInterval?
    /// Camera tilt (positive = pitched down). Lets providers be cross-checked.
    let pitchDown: AngleInterval?
    /// Tilt hint from a corroborating provider.
    let tiltHint: CameraTilt?
    let quality: EvidenceQuality
    /// A plain-language sentence about what this provider observed, or why it could not observe.
    let summary: String
    let measurements: [ObservationMeasurement]
    let limitations: [String]

    static func unavailable(_ provider: CameraAngleProvider, _ role: CameraAngleRole,
                            _ validity: ProviderValidity, summary: String) -> CameraAngleObservation {
        CameraAngleObservation(provider: provider, role: role, validity: validity, elevation: nil,
                               pitchDown: nil, tiltHint: nil, quality: .none, summary: summary,
                               measurements: [], limitations: [])
    }
}

/// What the fusion concluded and on what basis (kept next to the raw observations).
nonisolated struct CameraAngleDecisionSummary: Sendable, Equatable {
    /// Categories not ruled out by any valid decisive evidence. Every category
    /// means no information; one means determined; zero means the sources conflict.
    let possibleCategories: Set<CameraAngleCategory>
    /// Providers whose evidence actually influenced the result.
    let contributing: [CameraAngleProvider]
    let conflicts: [String]
    /// Notes on cross-checks and confidence adjustments.
    let notes: [String]
}

// MARK: - Category rule

nonisolated enum CameraAngleRule {
    /// Half-width of the eye-level band, in degrees of camera elevation
    /// relative to the eyes. A product choice: within about a hand's width
    /// of the eye line, viewers read a shot as "eye level".
    static let eyeLevelBandDegrees = 6.0

    /// Every real category, steepest-down view first. `unknown` is not one.
    static let ordered: [CameraAngleCategory] = [.birdsEye, .highAngle, .eyeLevel, .lowAngle, .wormsEye]

    static func category(ofElevation degrees: Double) -> CameraAngleCategory {
        if degrees > extremeAngleDegrees { return .birdsEye }
        if degrees > eyeLevelBandDegrees { return .highAngle }
        if degrees < -extremeAngleDegrees { return .wormsEye }
        if degrees < -eyeLevelBandDegrees { return .lowAngle }
        return .eyeLevel
    }

    /// Every category an elevation interval overlaps.
    static func categories(low: Double, high: Double) -> Set<CameraAngleCategory> {
        var set = Set<CameraAngleCategory>()
        if high > extremeAngleDegrees { set.insert(.birdsEye) }
        if high > eyeLevelBandDegrees && low <= extremeAngleDegrees { set.insert(.highAngle) }
        if high >= -eyeLevelBandDegrees && low <= eyeLevelBandDegrees { set.insert(.eyeLevel) }
        if low < -eyeLevelBandDegrees && high >= -extremeAngleDegrees { set.insert(.lowAngle) }
        if low < -extremeAngleDegrees { set.insert(.wormsEye) }
        return set
    }

    /// Elevation range (degrees, camera above the eyes positive) that counts as `category`.
    /// Open ends are capped at ±90°. Nil for `unknown`.
    static func elevationRange(of category: CameraAngleCategory) -> ClosedRange<Double>? {
        switch category {
        case .birdsEye:  return extremeAngleDegrees...90
        case .highAngle: return eyeLevelBandDegrees...extremeAngleDegrees
        case .eyeLevel:  return -eyeLevelBandDegrees...eyeLevelBandDegrees
        case .lowAngle:  return -extremeAngleDegrees...(-eyeLevelBandDegrees)
        case .wormsEye:  return -90...(-extremeAngleDegrees)
        case .unknown:   return nil
        }
    }
}

extension EvidenceQuality {
    nonisolated func raised() -> EvidenceQuality { EvidenceQuality(rawValue: min(3, rawValue + 1)) ?? .high }
}
