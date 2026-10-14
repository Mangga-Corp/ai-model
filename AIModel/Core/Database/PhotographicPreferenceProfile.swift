import Foundation

/// Aggregated patterns discovered across multiple photo analyses
struct PhotographicPreferenceProfile: Identifiable, Hashable {
    let id: UUID
    let photoCount: Int
    let successfullyAnalyzedCount: Int

    // MARK: - Aggregated Measurements

    let subjectPositionDistribution: PositionDistribution?
    /// Distribution of the UPPER-BODY (half-body) box centre across photos.
    /// This is what the camera guide box targets — where the torso/head sits in
    /// a half-body framing, as opposed to the full-body centre.
    let halfBodyPositionDistribution: PositionDistribution?
    let subjectSizeDistribution: SizeDistribution?
    let horizonAngleDistribution: AngleDistribution?

    // Lighting
    let brightnessDistribution: ValueDistribution?
    let saturationDistribution: ValueDistribution?
    let colorTemperatureDistribution: ValueDistribution?

    // Head angle
    let headYawDistribution: ValueDistribution?
    let headRollDistribution: ValueDistribution?

    // Body pose
    let bodyOrientationDistribution: ValueDistribution?
    let bodySymmetryDistribution: ValueDistribution?

    // Saliency
    let saliencyIntensityDistribution: ValueDistribution?

    // Aesthetics
    let aestheticScoreDistribution: ValueDistribution?

    // Leading lines
    let leadingLinesLineCountDistribution: ValueDistribution?
    let leadingLinesAngleDistribution: ValueDistribution?
    let leadingLinesConvergenceDistribution: ValueDistribution?
    let diagonalDominanceRatio: Double?  // 0-1, fraction of photos with diagonal dominance

    // Rule of thirds
    let ruleOfThirdsPatterns: [RuleOfThirds: Int]

    // Scene & Color
    let sceneCategories: [String: Int]
    let negativeSpacePatterns: [NegativeSpaceDistribution: Int]
    let colorHarmonyPatterns: [ColorHarmony: Int]
    let dominantColorPalette: [DominantColor]

    // Lighting direction
    let lightDirectionPatterns: [LightDirection: Int]

    // Symmetry
    let symmetryDistribution: ValueDistribution?
    let bilateralDistribution: ValueDistribution?
    let symmetryRatio: Double?            // 0-1, fraction of photos that are symmetric
    let symmetryAxisPatterns: [SymmetryAxis: Int]

    // Golden ratio
    let goldenRatioDistribution: ValueDistribution?
    let goldenRatioHitRatio: Double?      // 0-1, fraction of photos at a golden point

    // MARK: - Generated Interpretation

    let summary: String
    let insights: [PreferenceInsight]

    /// The per-photo analyses behind the aggregated statistics.
    /// Carried so the UI can show each photo with its detected overlays
    /// (PRD Rule 6: evidence must be traceable to specific photographs).
    let analyses: [PhotoAnalysis]

    /// The source photos, parallel to `analyses` by `referencePhotoID`,
    /// so the UI can render each image beneath its overlays.
    let photos: [ReferencePhoto]

    /// Convenience: pairs each analysis with its source photo, ordered by selection.
    var analyzedPhotoPairs: [(photo: ReferencePhoto, analysis: PhotoAnalysis)] {
        let photoMap = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return analyses.compactMap { analysis in
            guard let photo = photoMap[analysis.referencePhotoID] else { return nil }
            return (photo: photo, analysis: analysis)
        }
    }

    // MARK: - Mixed Patterns & Metadata

    let mixedPatterns: [Inconsistency]
    let limitations: [String]
    let generatedAt: Date
}

// MARK: - Distribution Types

/// Distribution of subject positions across photographs
struct PositionDistribution: Hashable {
    let meanX: Double
    let meanY: Double
    let stdDevX: Double
    let stdDevY: Double
    let isConsistent: Bool
}

/// Distribution of subject sizes across photographs
struct SizeDistribution: Hashable {
    let meanArea: Double
    let minArea: Double
    let maxArea: Double
    let stdDev: Double
    let isConsistent: Bool
}

/// Distribution of horizon angles across photographs
struct AngleDistribution: Hashable {
    let meanAngle: Double
    let stdDev: Double
    let sampleCount: Int
}

/// Generic distribution for scalar values (brightness, saturation, angles, etc.)
struct ValueDistribution: Hashable {
    let mean: Double
    let stdDev: Double
    let min: Double
    let max: Double
    let sampleCount: Int
    let isConsistent: Bool
}

/// Represents an inconsistency found in the analysis
struct Inconsistency: Hashable {
    let characteristic: Characteristic
    let description: String
}

/// A single insight about the user's photographic preferences
struct PreferenceInsight: Identifiable, Hashable {
    let id: UUID
    let title: String
    let description: String
    let category: InsightCategory
    let supportingPhotoIDs: [UUID]
    let supportingMeasurements: [String: Double]
    let evidenceStrength: EvidenceStrength
    let interpretationStatus: InterpretationStatus
}

// MARK: - Enums

enum InsightCategory: String, CaseIterable, Hashable {
    case composition
    case framing
    case lighting
    case subjectAngle
    case environment
    case subject
    case horizon
    case aesthetics
    case general
}

enum EvidenceStrength: String, Hashable {
    case strong = "Strong Evidence"
    case moderate = "Moderate Evidence"
    case weak = "Weak Evidence"
    case insufficient = "Insufficient Evidence"
}

enum InterpretationStatus: Hashable {
    case observation
    case interpretation
}
