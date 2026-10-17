import Foundation
import CoreGraphics

// MARK: - Pattern vocabulary

/// What the observations across photos add up to.
nonisolated enum PatternKind: String, Sendable, Hashable {
    /// No photo produced a valid observation.
    case noEvidence
    /// Exactly one valid observation: recorded, but not evidence of a habit.
    case singleObservation
    /// One category recurs in at least two photos and holds a clear majority.
    case recurring
    /// Valid observations exist but no category holds a clear majority.
    case mixed
}

/// How firmly the pattern is supported, from the amount and agreement of evidence.
nonisolated enum PatternStrength: Int, Sendable, Comparable, Hashable {
    case insufficient = 0
    case limited
    case moderate
    case strong

    static func < (lhs: PatternStrength, rhs: PatternStrength) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum Consistency: String, Sendable, Hashable {
    case tight, moderate, wide
    /// Fewer than two samples: spread cannot be assessed.
    case undetermined
}

// MARK: - Findings

/// The aggregate of one categorical characteristic across all reference photos.
///
/// Photos with no valid observation are listed in `excludedPhotoIDs` and are
/// never counted for or against any category.
nonisolated struct CategoryFinding<Category: Hashable & Sendable>: Sendable, Equatable {
    /// The camera characteristic this finding belongs to; nil for the
    /// environment and composition findings, which are not one of the four.
    let kind: CharacteristicKind?
    /// Photos that contributed a valid observation.
    let validObservationCount: Int
    let counts: [Category: Int]
    /// Quality-weighted share of each category, summing to 1 when any evidence exists.
    let weightedShares: [Category: Double]
    /// Photos supporting each category: the traceability link to the profile.
    let supportingPhotoIDs: [Category: [UUID]]
    /// Set only when the pattern is `recurring`.
    let dominant: Category?
    /// Every category seen in at least two photos, strongest first. Preserves
    /// real variation: a split of two recurring categories is visible here
    /// even though neither is dominant.
    let recurringCategories: [Category]
    /// Weighted share of the leading category (0 when there is no evidence).
    let dominantShare: Double
    let dominantCount: Int
    /// Categories observed exactly once (isolated observations).
    let isolated: [Category]
    let pattern: PatternKind
    let strength: PatternStrength
    /// Normalised Shannon entropy of the counts: 0 = all one category, 1 = even spread.
    let variation: Double
    let excludedPhotoIDs: [UUID]
    /// Deterministic, human-readable summary of the pattern.
    let summary: String
}

nonisolated struct NumericSummary: Sendable, Equatable {
    let count: Int
    let mean: Double
    let median: Double
    let minimum: Double
    let maximum: Double
    /// Population standard deviation.
    let standardDeviation: Double
    let interquartileRange: Double

    static func make(_ values: [Double]) -> NumericSummary? {
        let v = values.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        let n = Double(v.count)
        let mean = v.reduce(0, +) / n
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        func quantile(_ q: Double) -> Double {
            guard v.count > 1 else { return v[0] }
            let pos = q * Double(v.count - 1)
            let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
            return v[lo] + (v[hi] - v[lo]) * (pos - Double(lo))
        }
        return NumericSummary(count: v.count, mean: mean, median: quantile(0.5),
                              minimum: v[0], maximum: v[v.count - 1],
                              standardDeviation: variance.squareRoot(),
                              interquartileRange: quantile(0.75) - quantile(0.25))
    }

    /// Spread classification against a characteristic-specific tolerance.
    /// `tight` <= tolerance, `wide` > 2 x tolerance. Needs two or more samples.
    func consistency(tolerance: Double) -> Consistency {
        guard count >= 2 else { return .undetermined }
        if standardDeviation <= tolerance { return .tight }
        if standardDeviation <= tolerance * 2 { return .moderate }
        return .wide
    }
}

nonisolated struct PositioningMetrics: Sendable, Equatable {
    /// Photos with a valid subject measurement.
    let sampleCount: Int
    let centerX: NumericSummary?
    let centerY: NumericSummary?
    let width: NumericSummary?
    let height: NumericSummary?
    let area: NumericSummary?
    let centerXConsistency: Consistency
    let centerYConsistency: Consistency
    let areaConsistency: Consistency
    /// Median centre, only when at least two photos agree within tolerance.
    let typicalCenter: CGPoint?
}

nonisolated struct DepthProfileMetrics: Sendable, Equatable {
    let sampleCount: Int
    let subjectMinusEnvironment: NumericSummary?
    let fractionEnvironmentNearer: NumericSummary?
    let fractionEnvironmentFarther: NumericSummary?
}

// MARK: - Coverage

/// How many photos could be assessed for a characteristic, and why the rest could not.
nonisolated struct CharacteristicCoverage: Sendable, Equatable {
    let kind: CharacteristicKind
    let totalPhotos: Int
    let determinedPhotoIDs: [UUID]
    let insufficientPhotoIDs: [UUID]
    let notApplicablePhotoIDs: [UUID]
    let unavailablePhotoIDs: [UUID]
    let lowQualityDeterminedCount: Int

    var determinedCount: Int { determinedPhotoIDs.count }
    var fraction: Double { totalPhotos == 0 ? 0 : Double(determinedCount) / Double(totalPhotos) }
}

// MARK: - Profile

/// The consolidated Photo Preference Profile.
///
/// Independent of the UI and of any explanatory text: recommendation logic can
/// read the enums, counts, shares, summaries and coverage directly.
nonisolated struct PreferenceProfile: Sendable, Equatable {
    let generatedAt: Date
    let totalPhotoCount: Int
    /// Photos whose analysis did not fail outright.
    let analyzedPhotoCount: Int
    /// Photos that produced at least one determined characteristic.
    let photosWithValidEvidenceCount: Int

    let cameraAngle: CategoryFinding<CameraAngleCategory>
    let subjectFraming: CategoryFinding<FramingCategory>
    let horizontalPosition: CategoryFinding<HorizontalZone>
    let verticalPosition: CategoryFinding<VerticalZone>
    let positioning: PositioningMetrics
    let depthStructure: CategoryFinding<DepthStructure>
    let depth: DepthProfileMetrics

    let coverage: [CharacteristicKind: CharacteristicCoverage]
    /// Characteristics for which no supported pattern could be stated.
    let unsupportedCharacteristics: [CharacteristicKind]
    let limitations: [String]

    /// Object and environment tendencies, kept apart from the four characteristics
    /// above so existing readers (including the camera hand-off) are unaffected.
    var environment: EnvironmentProfile?

    var isEmpty: Bool { photosWithValidEvidenceCount == 0 }
}
