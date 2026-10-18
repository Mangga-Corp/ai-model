import Foundation
import CoreGraphics

// The cross-photo side of Object and Environment Analysis.
//
// The profile keeps TWO kinds of tendency apart because they are used
// differently when a live scene differs from the reference photos:
//
//   TransferableComposition  How the subject is scaled and placed, and how
//                            prominent the surroundings are relative to them.
//                            These do not depend on WHICH environment is in
//                            front of the camera, so they can be applied anywhere.
//
//   SceneDependentTendencies Which kinds of place, which elements, and where those
//                            elements sit. These are observations about the
//                            reference photos. They only apply when the matching
//                            environment is actually available ("architecture
//                            appears often" must never become "find a building").
//
// Per-photo evidence stays on `PhotoResult.environment`; nothing here is a
// per-photo measurement. Photos without a valid observation for a metric are
// listed as excluded and never counted for or against a category.

nonisolated enum EnvironmentFacet: String, Sendable, CaseIterable, Hashable, Identifiable {
    case segmentation, dominantElements, sceneContext, composition
    var id: String { rawValue }
}

/// How many photos could be assessed for one facet, and why not for the rest.
nonisolated struct FacetCoverage: Sendable, Equatable {
    let facet: EnvironmentFacet
    let totalPhotos: Int
    let determinedPhotoIDs: [UUID]
    let insufficientPhotoIDs: [UUID]
    let notApplicablePhotoIDs: [UUID]
    let unavailablePhotoIDs: [UUID]

    var determinedCount: Int { determinedPhotoIDs.count }
    var fraction: Double { totalPhotos == 0 ? 0 : Double(determinedCount) / Double(totalPhotos) }
}

nonisolated enum PresencePattern: String, Sendable, Hashable {
    case none
    /// Seen in exactly one photo: recorded, not a habit.
    case single
    /// Seen in two or more photos, but in fewer than half of those assessed.
    case occasional
    /// Seen in two or more photos and in at least half of those assessed.
    case recurring

    static func classify(present: Int, eligible: Int) -> PresencePattern {
        guard present > 0, eligible > 0 else { return .none }
        if present == 1 { return .single }
        return Double(present) / Double(eligible) >= 0.5 ? .recurring : .occasional
    }
}

/// How often one element (or element group) appears, and how it is used when present.
nonisolated struct ElementTendency: Sendable, Equatable, Identifiable {
    let key: String
    let label: String
    let group: ElementGroup
    /// Photos that can speak to THIS element: interpretable segmentation, minus photos where a
    /// region of this kind was set aside as unreliable (unknown there, not absent).
    let eligiblePhotoCount: Int
    let presentCount: Int
    let dominantCount: Int
    let secondaryCount: Int
    let presentPhotoIDs: [UUID]
    let dominantPhotoIDs: [UUID]
    /// Share of the image it covers, over the photos where it is present.
    let areaWhenPresent: NumericSummary?
    let pattern: PresencePattern
    /// When this tendency may be applied.
    let condition: String

    var id: String { key }
    var presenceShare: Double { eligiblePhotoCount == 0 ? 0 : Double(presentCount) / Double(eligiblePhotoCount) }
    /// Of the photos where it is present, how often it is dominant.
    var dominantWhenPresent: Double? { presentCount == 0 ? nil : Double(dominantCount) / Double(presentCount) }
}

/// Where an element group usually sits, over photos in which it is present.
nonisolated struct ElementPlacementTendency: Sendable, Equatable, Identifiable {
    let key: String
    let label: String
    let sampleCount: Int
    let centerX: NumericSummary?
    let centerY: NumericSummary?
    let horizontalCounts: [HorizontalZone: Int]
    let verticalCounts: [VerticalZone: Int]
    let consistency: Consistency
    let condition: String
    var id: String { key }
}

nonisolated struct TransferableComposition: Sendable, Equatable {
    let subjectScale: CategoryFinding<SubjectScaleBand>
    let horizontalOffset: CategoryFinding<HorizontalOffsetBand>
    let environmentProminence: CategoryFinding<ProminenceBand>
    /// Person BOX area over photos with a valid scale measurement.
    let subjectBoxArea: NumericSummary?
    /// Person MASK area over photos with a valid DETR person mask.
    let subjectMaskArea: NumericSummary?
    /// Dominant element's size relative to the subject, over photos that have one.
    let dominantElementToSubject: NumericSummary?
    /// Photos whose scale or offset band sat near a threshold.
    let borderlinePhotoCount: Int
    let note: String
}

nonisolated struct SceneDependentTendencies: Sendable, Equatable {
    let sceneCategory: CategoryFinding<SceneContextCategory>
    let setting: CategoryFinding<SceneSetting>
    let character: CategoryFinding<EnvironmentCharacter>
    /// Built share of (built + natural) area across photos where it could be assessed.
    let builtShare: NumericSummary?
    let groupTendencies: [ElementTendency]
    let familyTendencies: [ElementTendency]
    let placements: [ElementPlacementTendency]
    let note: String
}

nonisolated struct EnvironmentProfile: Sendable, Equatable {
    let totalPhotoCount: Int
    /// Photos whose segmentation could be INTERPRETED (decoded, enough supported labels, enough
    /// reliable surroundings): the denominator for element and scene tendencies.
    let eligiblePhotoCount: Int
    let transferable: TransferableComposition
    let sceneDependent: SceneDependentTendencies
    let coverage: [EnvironmentFacet: FacetCoverage]
    let limitations: [String]

    /// True when no photo produced any environment or composition observation.
    var isEmpty: Bool {
        eligiblePhotoCount == 0
            && transferable.subjectScale.validObservationCount == 0
            && transferable.horizontalOffset.validObservationCount == 0
    }
}
