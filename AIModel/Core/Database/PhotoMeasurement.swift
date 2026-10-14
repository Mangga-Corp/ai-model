import Foundation
import CoreGraphics

/// A single measurement of a characteristic from one photograph
struct PhotoMeasurement: Identifiable, Hashable {
    let id = UUID()
    let characteristic: Characteristic
    let value: Double
    let confidence: Double
    let photoID: UUID
    let description: String
}

/// All measurable characteristics from a photograph
enum Characteristic: String, CaseIterable, Codable, Hashable {
    // Composition
    case subjectPlacement = "Subject Placement"
    case subjectSize = "Subject Size"
    case negativeSpace = "Negative Space"
    case ruleOfThirds = "Rule of Thirds"
    case visualBalance = "Visual Balance"
    case leadingLines = "Leading Lines"
    case symmetry = "Symmetry"
    case goldenRatio = "Golden Ratio"

    // Lighting
    case brightness = "Brightness"
    case contrast = "Contrast"
    case saturation = "Saturation"
    case colorTemperature = "Color Temperature"
    case lightDirection = "Light Direction"

    // Subject angle
    case headAngle = "Head Angle"
    case bodyOrientation = "Body Orientation"
    case bodySymmetry = "Body Symmetry"

    // Attention
    case saliency = "Saliency"
    case horizonAlignment = "Horizon Alignment"

    // Scene & Aesthetics
    case sceneSemiotics = "Scene Semantics"
    case aestheticQuality = "Aesthetic Quality"
    case colorHarmony = "Color Harmony"

    /// Category grouping for the characteristic
    var category: CharacteristicCategory {
        switch self {
        case .subjectPlacement, .subjectSize, .negativeSpace, .ruleOfThirds, .visualBalance, .leadingLines, .symmetry, .goldenRatio:
            return .composition
        case .brightness, .contrast, .saturation, .colorTemperature, .lightDirection:
            return .lighting
        case .headAngle, .bodyOrientation, .bodySymmetry:
            return .subjectAngle
        case .saliency, .horizonAlignment:
            return .attention
        case .sceneSemiotics, .aestheticQuality, .colorHarmony:
            return .semantics
        }
    }

    /// Whether this characteristic requires a human subject
    var requiresSubject: Bool {
        switch self {
        case .subjectPlacement, .subjectSize, .negativeSpace, .ruleOfThirds,
             .headAngle, .bodyOrientation, .bodySymmetry:
            return true
        default:
            return false
        }
    }
}

/// Category grouping for characteristics
enum CharacteristicCategory: String, CaseIterable, Codable, Hashable {
    case composition = "Composition"
    case lighting = "Lighting"
    case subjectAngle = "Subject Angle"
    case attention = "Visual Attention"
    case semantics = "Scene & Aesthetics"
}

/// Distribution of negative space around subjects
enum NegativeSpaceDistribution: String, CaseIterable, Codable, Hashable {
    case topHeavy = "Top Heavy"
    case bottomHeavy = "Bottom Heavy"
    case leftHeavy = "Left Heavy"
    case rightHeavy = "Right Heavy"
    case balanced = "Balanced"
}

/// Confidence level for a detected characteristic
enum ConfidenceLevel: Int, CaseIterable, Codable, Hashable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    var isReliable: Bool { self.rawValue >= ConfidenceLevel.medium.rawValue }
}

/// Status of a characteristic for a specific photo
struct CharacteristicStatus: Hashable {
    let characteristic: Characteristic
    let level: ConfidenceLevel
    let isAvailable: Bool
    let note: String?
}
