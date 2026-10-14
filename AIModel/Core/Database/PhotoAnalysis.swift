import Foundation
import CoreGraphics
import Vision

/// Represents the complete result of analyzing a single reference photograph
struct PhotoAnalysis: Identifiable, Hashable {
    let id: UUID
    let referencePhotoID: UUID

    // MARK: - Subject Composition
    let subjectPosition: CGPoint?          // Normalized (0-1) center, UIKit coords (y-flip)
    let subjectSize: Double?              // Normalized area (0-1)
    let subjectBoundingBox: NormalizedRect?
    let subjectConfidence: Float?
    /// Center of the UPPER-BODY (half-body) detection box, normalised, UIKit
    /// coords (y-flipped). Distinct from `subjectPosition` (the full-body box
    /// center): this is where the torso and head sit, which is what a half-body
    /// framing actually places. Drives the camera guide box.
    let halfBodyPosition: CGPoint?
    /// Whether the subject reads as a full body or an upper-body framing.
    ///
    /// Measured, not guessed: analysis runs BOTH `DetectHumanRectanglesRequest`
    /// modes and compares the resulting boxes. See `VisionAnalysisService`.
    let bodyExtent: BodyExtent?
    let negativeSpaceDistribution: NegativeSpaceDistribution?

    // MARK: - Saliency & Visual Attention
    let saliencyCentroid: CGPoint?        // Where the eye is drawn (0-1 normalized)
    let saliencyBoundingBox: NormalizedRect?  // Most salient region
    let saliencyIntensity: Double?        // Average saliency in the salient region
    let ruleOfThirdsAlignment: RuleOfThirds?  // How well subject aligns to thirds grid

    // MARK: - Horizon
    let horizonAngle: Double?             // Degrees
    let horizonVerticalPosition: Double?  // Normalized 0-1

    // MARK: - Head Pose (face)
    let headRoll: Double?                 // Degrees, head tilt left/right
    let headYaw: Double?                  // Degrees, head turn left/right
    let headPitch: Double?                // Degrees, head nod up/down
    let faceBoundingBox: NormalizedRect?

    // MARK: - View-Space Accessors

    /// Subject box as a normalized `CGRect` in view space (origin top-left,
    /// y down), ready for a View to scale by its own size.
    ///
    /// Vision reports a bottom-left origin; this flips the y axis so the View
    /// layer never has to import Vision or know about that convention.
    var subjectBoxViewSpace: CGRect? {
        Self.viewSpace(from: subjectBoundingBox)
    }

    var faceBoxViewSpace: CGRect? {
        Self.viewSpace(from: faceBoundingBox)
    }

    var saliencyBoxViewSpace: CGRect? {
        Self.viewSpace(from: saliencyBoundingBox)
    }

    /// Flips a Vision normalized rect into normalized view space.
    static func viewSpace(from rect: NormalizedRect?) -> CGRect? {
        guard let rect else { return nil }
        return CGRect(
            x: CGFloat(rect.origin.x),
            y: CGFloat(1.0 - rect.origin.y - rect.height),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }
    let faceConfidence: Float?

    // MARK: - Body Pose
    let bodyPoseJointCount: Int?          // Number of detected joints
    let bodyOrientation: Double?          // Degrees, body axis angle
    let bodySymmetry: Double?             // 0-1, how symmetric left/right joints are
    let dominantJointsGroup: String?      // e.g. "torso", "arms"

    // MARK: - Lighting & Image Quality
    let meanBrightness: Double?           // 0-1
    let brightnessStdDev: Double?         // Contrast indicator
    let meanSaturation: Double?           // 0-1
    let aestheticScore: Double?           // -1 to 1
    let captureQuality: String?           // "good", "fair", "poor"

    // MARK: - Lighting Direction (estimated from luminance gradient)
    let lightDirection: LightDirection?
    let lightDirectionConfidence: Double? // 0-1, gradient strength
    let shadowDirection: LightDirection?  // Opposite of lightDirection

    // MARK: - Leading Lines (from contour analysis)
    let leadingLines: LeadingLinesResult?

    // MARK: - Symmetry & Golden Ratio
    let symmetry: SymmetryResult?
    let goldenRatio: GoldenRatioResult?

    // MARK: - Color Palette
    let dominantColors: [DominantColor]?  // Top 3 colors
    let colorHarmony: ColorHarmony?       // Detected harmony type
    let colorTemperature: Double?         // Warm/cool bias, -1 to 1

    // MARK: - Scene Semantics
    let sceneClassifications: [String: Double]  // identifier -> confidence

    // MARK: - Image Metadata
    let imageDimensions: CGSize?
    let orientation: CGImagePropertyOrientation?
    let aspectRatio: Double?              // width / height

    // MARK: - Analysis Status
    let status: AnalysisStatus
    let errorMessage: String?
    let unavailableCharacteristics: Set<Characteristic>

    // MARK: - Computed Properties

    var hasSubject: Bool { subjectPosition != nil && subjectSize != nil }
    var hasHorizon: Bool { horizonAngle != nil }
    var hasClassifications: Bool { !sceneClassifications.isEmpty }
    var hasHeadPose: Bool { headYaw != nil || headRoll != nil || headPitch != nil }
    var hasBodyPose: Bool { bodyPoseJointCount != nil && bodyPoseJointCount! > 0 }
    var hasSaliency: Bool { saliencyCentroid != nil }
    var hasLighting: Bool { meanBrightness != nil }
    var hasLightDirection: Bool { lightDirection != nil && (lightDirectionConfidence ?? 0) > 0.25 }
    var hasLeadingLines: Bool { leadingLines?.isAvailable ?? false }
    var hasSymmetry: Bool { symmetry?.isSymmetric ?? false }
    var hasGoldenRatio: Bool { goldenRatio?.isAtGoldenPoint ?? false }
    var hasColorAnalysis: Bool { dominantColors != nil && !dominantColors!.isEmpty }
    var hasAestheticScore: Bool { aestheticScore != nil }

    /// Total number of measurable characteristics available for this photo
    var measurableCharacteristicCount: Int {
        var count = 0
        if hasSubject { count += 1 }
        if hasHorizon { count += 1 }
        if hasClassifications { count += 1 }
        if hasHeadPose { count += 1 }
        if hasBodyPose { count += 1 }
        if hasSaliency { count += 1 }
        if hasLighting { count += 1 }
        if hasLightDirection { count += 1 }
        if hasLeadingLines { count += 1 }
        if hasColorAnalysis { count += 1 }
        if hasAestheticScore { count += 1 }
        return count
    }
}

// MARK: - Supporting Types

enum AnalysisStatus: Hashable {
    case success
    case partial   // Some characteristics detected, some failed
    case failed    // No characteristics could be detected
}

/// A dominant color extracted from the image
struct DominantColor: Hashable {
    let red: Double
    let green: Double
    let blue: Double
    let proportion: Double  // Fraction of image pixels

    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    /// Perceived brightness (0-1)
    var luminance: Double {
        0.299 * red + 0.587 * green + 0.114 * blue
    }
}

/// Color harmony classification
enum ColorHarmony: String, CaseIterable, Codable, Hashable {
    case monochromatic = "Monochromatic"
    case complementary = "Complementary"
    case analogous = "Analogous"
    case triadic = "Triadic"
    case warm = "Warm Dominant"
    case cool = "Cool Dominant"
    case neutral = "Neutral"
}

/// How much of the subject's body is captured in the frame.
///
/// Derived by running person detection in BOTH modes and comparing the boxes:
/// if the upper-body box covers most of the full-body box, the subject is
/// framed as a half body; if the full-body box is substantially taller, the
/// whole figure is in frame. Measured this way rather than inferred from a
/// single box, so the classification reflects what was actually detected.
enum BodyExtent: String, CaseIterable, Codable, Hashable {
    case fullBody = "Full Body"
    case halfBody = "Half Body"
    case undetermined = "Undetermined"
}

/// Rule of thirds alignment assessment
enum RuleOfThirds: String, CaseIterable, Codable, Hashable {
    case topLeft = "Top Left"
    case topCenter = "Top Center"
    case topRight = "Top Right"
    case middleLeft = "Middle Left"
    case center = "Center"
    case middleRight = "Middle Right"
    case bottomLeft = "Bottom Left"
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"
}

/// Compass direction of the primary light source, estimated from the
/// brightness gradient across the frame. Shadows fall opposite the light,
/// so the gradient points AWAY from the light; we invert it.
enum LightDirection: String, CaseIterable, Codable, Hashable {
    case topLeft = "Top Left"
    case top = "Top"
    case topRight = "Top Right"
    case left = "Left"
    case center = "Center / Even"
    case right = "Right"
    case bottomLeft = "Bottom Left"
    case bottom = "Bottom"
    case bottomRight = "Bottom Right"
}

/// A single detected line segment in normalized image coordinates.
struct DetectedLine: Hashable {
    let start: CGPoint  // UIKit coords (y down)
    let end: CGPoint
    let length: Double  // 0-1, relative to frame diagonal
    let angle: Double   // Degrees, 0-180 (line orientation, not direction)
}

/// Aggregate result of leading-line (vanishing-direction) analysis.
struct LeadingLinesResult: Hashable {
    let lines: [DetectedLine]
    let lineCount: Int
    /// Mean angle of significant lines, in degrees (0-180).
    let dominantAngle: Double?
    /// 0-1. How strongly significant lines cluster around `dominantAngle`.
    /// Low value means lines point in many directions (no clear perspective).
    let convergenceStrength: Double?
    /// True when most significant lines run diagonally (30°-60° or 120°-150°),
    /// which is the classic dynamic-composition signature.
    let hasDiagonalDominance: Bool
    let isAvailable: Bool
}

/// Result of the image-symmetry analysis.
///
/// Measures how well the left half of the frame mirrors the right half
/// (bilateral) and the top half mirrors the bottom half (vertical).
struct SymmetryResult: Hashable {
    /// 0-1. Left-right mirror correlation of the luminance distribution.
    let bilateral: Double
    /// 0-1. Top-bottom mirror correlation.
    let vertical: Double
    /// The stronger of the two.
    let dominant: Double
    /// Which axis scored higher.
    let dominantAxis: SymmetryAxis
    /// True when the dominant axis exceeds the reporting threshold.
    let isSymmetric: Bool
}

/// Which axis of symmetry dominated.
enum SymmetryAxis: String, CaseIterable, Codable, Hashable {
    case bilateral = "Left-Right"
    case vertical = "Top-Bottom"
    case none = "Neither"
}

/// Result of the golden-ratio placement analysis.
///
/// Same measurement as rule-of-thirds (subject centroid), but classified
/// against the golden ratio thresholds (0.382 / 0.618) instead of thirds.
struct GoldenRatioResult: Hashable {
    /// The rule-of-thirds-equivalent zone, for reference.
    let horizontalZone: GoldenRatioZone
    let verticalZone: GoldenRatioZone
    /// True when the subject sits near a golden-ratio intersection.
    let isAtGoldenPoint: Bool
    /// 0-1. How close the subject is to the nearest golden-ratio line.
    let alignmentStrength: Double
}

/// Position relative to the golden-ratio divisions.
enum GoldenRatioZone: String, CaseIterable, Codable, Hashable {
    case near = "Near"
    case golden = "Golden"
    case center = "Center"
    case goldenFar = "Golden Far"
    case far = "Far"
}
