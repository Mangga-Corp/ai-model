import Foundation
import CoreGraphics

// Result types for Object and Environment Analysis. All geometry uses the
// single convention documented in `ImageSpace`: normalised 0...1, origin at the
// top-left of the upright image, relative to the full image.
//
// Raw observations (regions, measurements, cues) are kept apart from
// interpretations (roles, scene category, composition descriptors).

// MARK: - A. Object segmentation

nonisolated enum MaskValidity: String, Sendable, Hashable {
    case valid
    /// Present, but too small to measure reliably. No geometry is derived.
    case tooSmall
}

/// Shape and placement of one semantic region. The region is the COMBINED
/// semantic class: disconnected pieces of the same class are one region, and
/// `componentCount` says how many pieces there are. It is not an instance.
nonisolated struct RegionGeometry: Sendable, Equatable {
    /// Union of the boxes of the region's connected fragments.
    let boundingBox: CGRect
    let boundingBoxArea: Double
    /// Centre of mass of the region's pixels.
    let centroid: CGPoint
    /// Mask area divided by bounding-box area (1 = a solid rectangle).
    let fillRatio: Double
    let componentCount: Int
    /// Share of the region's pixels that belong to its largest fragment.
    let largestComponentShare: Double
    /// Share of the region's pixels in the outer 15% band of the frame.
    let borderBandShare: Double
    let touchedEdges: Set<FrameEdge>

    var boundingBoxCenter: CGPoint { CGPoint(x: boundingBox.midX, y: boundingBox.midY) }
    var horizontal: HorizontalZone { SubjectPositioningMeasurer.horizontalZone(forCenterX: Double(centroid.x)) }
    var vertical: VerticalZone { SubjectPositioningMeasurer.verticalZone(forCenterY: Double(centroid.y)) }
}

/// Relative depth of a region (Depth Anything, larger = nearer, per-image).
nonisolated struct RegionDepth: Sendable, Equatable {
    let medianNearness: Double
    let sampleCount: Int
}

/// How a region sits relative to the main person.
nonisolated struct RegionSubjectRelation: Sendable, Equatable {
    /// Share of the band around the person (box grown 30%, minus the box and
    /// minus person pixels) occupied by this region.
    let ringShare: Double
    /// Share of the region lying inside the person's detection box.
    let insideSubjectBoxShare: Double
}

nonisolated struct RawLabelShare: Sendable, Equatable {
    let label: String
    let areaFraction: Double
}

/// Whether a measured region may support user-facing claims.
///
/// STRUCTURAL VALIDITY ("the mask decoded and was measured") is a different thing
/// from SEMANTIC RELIABILITY ("the label is believable"). DETR gives no
/// per-pixel confidence, so a well-formed mask can still carry a wrong label. A
/// region that is implausible on its face is `setAside`: it stays listed and
/// measured, but is excluded from the ranking, the scene inference, the element
/// measurements and the preference tendencies.
nonisolated enum RegionReliability: Sendable, Equatable {
    /// Nothing argues against using the region. This does NOT mean the label is verified.
    case eligible
    /// Kept for display only, with the reason.
    case setAside(String)

    var isEligible: Bool { if case .eligible = self { return true } else { return false } }
    var reason: String? { if case .setAside(let r) = self { return r } else { return nil } }
}

nonisolated struct SemanticRegion: Sendable, Equatable, Identifiable {
    var id: String { family.key }
    let family: SemanticFamily
    /// The DETR classes merged into this family, largest first.
    let rawLabels: [RawLabelShare]
    /// Pixels in fragments large enough to count.
    let pixelCount: Int
    /// Pixels of this class in fragments too small to count (kept out of every measurement).
    let specklePixelCount: Int
    /// `pixelCount` over the whole segmentation grid = share of the whole image.
    let areaFraction: Double
    let validity: MaskValidity
    /// Present only for a valid mask.
    let geometry: RegionGeometry?
    let depth: RegionDepth?
    let subjectRelation: RegionSubjectRelation?
    /// DETR's semantic output has no per-pixel confidence, so this is always nil.
    let modelConfidence: Double?
    /// Semantic reliability, assessed after measurement (see `RegionReliabilityAssessor`).
    var reliability: RegionReliability = .eligible

    var isValid: Bool { validity == .valid && geometry != nil }
}

/// The primary person's mask, taken from DETR's merged `person` class inside the
/// Vision detection box. Provenance stays distinct: box from Vision, mask from DETR.
nonisolated struct HumanMaskMeasurement: Sendable, Equatable {
    let isValid: Bool
    let invalidReason: String?
    let maskPixelCount: Int
    /// Share of the whole image. Nil unless valid.
    let maskAreaFraction: Double?
    let maskBoundingBox: CGRect?
    /// Person pixels divided by the box's pixels.
    let coverageOfDetectionBox: Double?
    /// Another detected person overlaps the box, so the merged mask may include them.
    let mayIncludeOtherPeople: Bool
    let medianNearness: Double?
}

nonisolated enum SegmentationAvailability: Sendable, Equatable {
    /// Valid output with at least one environmental region.
    case available
    /// Valid output, but nothing supported besides the person (a genuinely empty result).
    case noEnvironmentalRegions
    /// The model did not produce output.
    case unavailable(String)
    /// The model produced output that cannot be trusted.
    case invalid(String)

    /// True when the segmentation output itself can be trusted.
    var hasValidOutput: Bool {
        switch self {
        case .available, .noEnvironmentalRegions: return true
        case .unavailable, .invalid: return false
        }
    }
}

/// INTERPRETATION ELIGIBILITY: may a downstream claim (dominant element, scene,
/// presence or absence of an element) be emitted from this segmentation?
/// Separate from structural validity (the map decoded) and from per-region reliability.
nonisolated enum InterpretationEligibility: Sendable, Equatable {
    case eligible
    case limited(String)

    var isEligible: Bool { if case .eligible = self { return true } else { return false } }
    var reason: String? { if case .limited(let r) = self { return r } else { return nil } }
}

nonisolated struct ObjectSegmentationResult: Sendable, Equatable {
    let availability: SegmentationAvailability
    let gridWidth: Int
    let gridHeight: Int
    /// Environmental regions only (the person is never one), largest first.
    let regions: [SemanticRegion]
    /// Every DETR `person` pixel, all people merged. Matches the existing summary.
    let allPeopleFraction: Double
    let human: HumanMaskMeasurement?
    /// Surroundings that can be interpreted: supported pixels that are neither a
    /// person, nor something they carry or wear, nor a region that was set aside.
    let environmentFraction: Double
    /// Pixels whose class is outside the supported label table.
    let unsupportedFraction: Double
    let unsupportedLabels: [RawLabelShare]
    let assessment: Assessment

    /// DETR here is semantic segmentation, not instance segmentation.
    static let isInstanceSegmentation = false
    static let semanticNote = "Regions are combined semantic classes. Separate objects of the same class (two chairs, several trees) cannot be told apart, so none is reported as an individual object."

    /// Every region with a valid mask, including items the subject carries.
    var validRegions: [SemanticRegion] { regions.filter(\.isValid) }
    /// Valid regions that are part of the surroundings AND eligible for claims.
    /// Carried or worn items (tie, bag, skis) belong to the subject, and regions
    /// that were set aside as unreliable are not trusted; both are left out of
    /// the ranking, scene inference, element measurements and preference tendencies.
    var environmentalRegions: [SemanticRegion] {
        validRegions.filter { $0.family.group.isEnvironmental && $0.reliability.isEligible }
    }

    /// Valid regions whose label was judged implausible. Never evidence that something is absent.
    var setAsideRegions: [SemanticRegion] { validRegions.filter { !$0.reliability.isEligible } }

    /// Share of the image whose class this analysis can interpret.
    var supportedCoverage: Double { 1 - unsupportedFraction }

    /// Decoded output must cover at least this much of the image with supported labels.
    static let minimumSupportedCoverage = 0.5
    /// At least this much of the frame must show interpretable surroundings before
    /// anything is said about what is, or is not, there.
    static let minimumInterpretableSurroundings = 0.15

    /// Whether the decoded output may support claims about the surroundings.
    var interpretation: InterpretationEligibility {
        guard availability.hasValidOutput else { return .limited("segmentation is unavailable") }
        if supportedCoverage < Self.minimumSupportedCoverage {
            return .limited(String(format: "only %.0f%% of the image has labels this analysis supports", supportedCoverage * 100))
        }
        if environmentFraction < Self.minimumInterpretableSurroundings {
            return .limited(String(format: "only %.0f%% of the frame shows surroundings that can be interpreted", environmentFraction * 100))
        }
        return .eligible
    }

    static func unavailable(_ reason: String, invalid: Bool = false) -> ObjectSegmentationResult {
        ObjectSegmentationResult(
            availability: invalid ? .invalid(reason) : .unavailable(reason),
            gridWidth: 0, gridHeight: 0, regions: [], allPeopleFraction: 0, human: nil,
            environmentFraction: 0, unsupportedFraction: 0, unsupportedLabels: [],
            assessment: .unavailable(invalid
                ? "The segmentation output could not be trusted: \(reason)"
                : "Segmentation did not produce output, so environmental regions are unavailable: \(reason)"))
    }
}

// MARK: - B. Dominant environmental elements

nonisolated enum ElementRole: String, Sendable, Hashable {
    /// Visually significant element of the surroundings.
    case dominant
    case secondary
    /// Possibly relevant, but evidence is too weak for a firmer role.
    case uncertain
}

nonisolated struct ScoreComponent: Sendable, Equatable {
    let name: String
    /// 0...1.
    let value: Double
    /// The nominal weight (0.40 / 0.25 / 0.20 / 0.15).
    let weight: Double
    /// False when the evidence was unavailable (the weight is then redistributed).
    let used: Bool
    let note: String
    /// The weight this term actually carried: its nominal weight divided by the sum of
    /// the weights in use, or 0 when unused. The score is exactly Σ value × effectiveWeight.
    var effectiveWeight: Double = 0
}

nonisolated struct ElementCandidate: Sendable, Equatable, Identifiable {
    var id: String { familyKey }
    let rank: Int
    let familyKey: String
    let label: String
    let group: ElementGroup
    let kind: RegionKind
    let role: ElementRole
    /// 0...1 transparent weighted score (not a probability, not saliency).
    let score: Double
    let components: [ScoreComponent]
    let areaFraction: Double
    let centroid: CGPoint
    let horizontal: HorizontalZone
    let vertical: VerticalZone
    /// Connected pieces the combined region is made of (1 = one piece).
    var pieceCount: Int = 1
    /// Rule-based grade of how well the segmentation supports this candidate.
    /// Not a model probability: DETR provides none.
    let quality: EvidenceQuality
    let rationale: String
    let uncertainty: [String]
    let evidence: [EvidenceReference]
}

nonisolated enum DominanceOutcome: String, Sendable, Hashable {
    case identified
    /// Regions exist but none clearly stands out.
    case noStandoutElement
    /// Valid segmentation, no environmental region large enough to rank.
    case noEnvironmentalRegions
    case unavailable
}

nonisolated struct DominantElementsResult: Sendable, Equatable {
    let outcome: DominanceOutcome
    /// Ranked, best first. The person is never a candidate.
    let candidates: [ElementCandidate]
    let assessment: Assessment

    var dominant: [ElementCandidate] { candidates.filter { $0.role == .dominant } }
    var secondary: [ElementCandidate] { candidates.filter { $0.role == .secondary } }
    var uncertain: [ElementCandidate] { candidates.filter { $0.role == .uncertain } }
}

// MARK: - C. Scene context

/// The product taxonomy. String-backed so categories can be added without
/// touching stored data; consumers must treat unknown raw values as `.unknown`.
nonisolated enum SceneContextCategory: String, Sendable, CaseIterable, Hashable {
    case indoorInterior
    case cafeOrRestaurant
    case urbanStreet
    case architecturalEnvironment
    case parkOrGarden
    case naturalEnvironment
    case beachOrWaterfront
    case studioOrPlainBackground
    case mixedEnvironment
    case unknown
}

nonisolated enum SceneSetting: String, Sendable, CaseIterable, Hashable {
    case indoor, outdoor, undetermined
}

nonisolated enum EnvironmentCharacter: String, Sendable, CaseIterable, Hashable {
    case built, natural, mixed, undetermined
}

/// An OBSERVED fact: how much of the surroundings a group of regions covers.
nonisolated struct SceneCue: Sendable, Equatable, Identifiable {
    var id: String { group.rawValue }
    let group: ElementGroup
    let label: String
    let areaFraction: Double
    /// Share of the visible surroundings (non-person, supported pixels).
    let environmentShare: Double
}

/// A whole-image classifier label that matched the scene vocabulary.
nonisolated struct SceneHint: Sendable, Equatable, Identifiable {
    var id: String { label }
    let label: String
    let score: Double
    let supports: SceneContextCategory
    /// False when the label was too weak, or no segmentation evidence backed the category.
    let used: Bool
}

nonisolated struct SceneCandidate: Sendable, Equatable, Identifiable {
    var id: String { category.rawValue }
    let category: SceneContextCategory
    let strength: Double
    /// Interpretation: why this category is supported.
    let reasons: [String]
    let corroboratedByClassifier: Bool
}

nonisolated struct SceneContextResult: Sendable, Equatable {
    let primary: SceneContextCategory
    let primaryStrength: Double
    let secondary: [SceneCandidate]
    let setting: SceneSetting
    let settingReasons: [String]
    let character: EnvironmentCharacter
    /// Built share of (built + natural) area, when enough of either is visible.
    let builtShare: Double?
    /// Observed evidence, separate from the interpretation above.
    let observedCues: [SceneCue]
    let classifierHints: [SceneHint]
    /// The best two specific categories were too close to separate.
    let isAmbiguous: Bool
    let assessment: Assessment
}

// MARK: - D. Position and scale

nonisolated enum SubjectScaleBand: String, Sendable, CaseIterable, Hashable { case small, moderate, large }
nonisolated enum HorizontalOffsetBand: String, Sendable, CaseIterable, Hashable { case centered, slightlyOff, offCenter }
nonisolated enum ProminenceBand: String, Sendable, CaseIterable, Hashable { case environmentDominates, balanced, subjectDominates }

/// A band assignment that remembers when the value sat close to a cut-off.
nonisolated struct Banded<Band: Sendable & Hashable>: Sendable, Equatable {
    let band: Band
    let value: Double
    let isNearBoundary: Bool
}

nonisolated enum ScaleBasis: String, Sendable, Hashable {
    /// Region mask area over person mask area (both from DETR).
    case maskToMask
    /// Region box area over person box area (a different provenance for each box).
    case boxToBox
}

nonisolated struct RelativeScale: Sendable, Equatable {
    /// Region size divided by subject size.
    let ratio: Double
    let basis: ScaleBasis
}

nonisolated struct SubjectCompositionMeasurement: Sendable, Equatable {
    /// Vision's person box (same value the existing Subject Positioning reports).
    let box: CGRect
    let center: CGPoint
    let horizontal: HorizontalZone
    let vertical: VerticalZone
    let widthRatio: Double
    let heightRatio: Double
    let boxAreaRatio: Double
    /// DETR person-mask share of the image. Nil unless a valid mask exists.
    let maskAreaRatio: Double?
    let maskMayIncludeOtherPeople: Bool
}

nonisolated struct ElementMeasurement: Sendable, Equatable, Identifiable {
    var id: String { familyKey }
    let familyKey: String
    let label: String
    let group: ElementGroup
    let kind: RegionKind
    let centroid: CGPoint
    let boundingBox: CGRect
    let boundingBoxCenter: CGPoint
    let boundingBoxAreaRatio: Double
    let maskAreaRatio: Double
    let horizontal: HorizontalZone
    let vertical: VerticalZone
    let componentCount: Int
    let touchedEdges: Set<FrameEdge>
    let relativeToSubject: RelativeScale?
}

nonisolated enum CompositionDescriptorKind: String, Sendable, CaseIterable, Hashable {
    case subjectSmallInFrame
    case subjectLargeInFrame
    case subjectOffCenter
    case subjectCentered
    case environmentProminent
    case subjectDominatesFrame
    case architectureMajor
    case vegetationNearEdges
}

nonisolated struct CompositionDescriptor: Sendable, Equatable, Identifiable {
    var id: String { kind.rawValue }
    let kind: CompositionDescriptorKind
    let statement: String
    /// The measurement sat near a threshold, so the label is soft.
    let isBorderline: Bool
    let basis: [String]
}

nonisolated struct CompositionResult: Sendable, Equatable {
    let subject: SubjectCompositionMeasurement?
    let elements: [ElementMeasurement]
    let descriptors: [CompositionDescriptor]
    let scale: Banded<SubjectScaleBand>?
    let horizontalOffset: Banded<HorizontalOffsetBand>?
    let prominence: Banded<ProminenceBand>?
    let assessment: Assessment
}

// MARK: - Per-photo container

nonisolated struct EnvironmentAnalysisResult: Sendable, Equatable {
    let segmentation: ObjectSegmentationResult
    let elements: DominantElementsResult
    let scene: SceneContextResult
    let composition: CompositionResult
}
