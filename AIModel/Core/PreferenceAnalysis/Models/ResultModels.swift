import Foundation
import CoreGraphics

// MARK: - Shared vocabulary

/// The four photographic characteristics this feature measures.
nonisolated enum CharacteristicKind: String, Sendable, CaseIterable, Hashable, Identifiable {
    case cameraAngle
    case subjectFraming
    case subjectPositioning
    case environmentalDepth

    var id: String { rawValue }
}

/// Whether a conclusion could be reached, and if not, why not.
nonisolated enum AssessmentStatus: String, Sendable, Hashable {
    /// A category was chosen from adequate evidence.
    case determined
    /// Evidence existed but could not separate the categories.
    case insufficientEvidence
    /// The characteristic does not apply (for example, no human subject).
    case notApplicable
    /// Required evidence could not be produced (source failure or unreadable photo).
    case unavailable
}

/// How much trust the evidence behind a conclusion deserves.
///
/// This is a rule-based grade built from explicit checks (detection
/// confidence, cropping, agreement between sources). It is NOT a model
/// probability, and must never be read as "probability the conclusion is right".
nonisolated enum EvidenceQuality: Int, Sendable, Comparable, Hashable {
    case none = 0
    case low = 1
    case moderate = 2
    case high = 3

    static func < (lhs: EvidenceQuality, rhs: EvidenceQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Weight used when aggregating across photos.
    var weight: Double {
        switch self {
        case .none: return 0
        case .low: return 0.4
        case .moderate: return 0.7
        case .high: return 1.0
        }
    }

    func lowered(by steps: Int = 1) -> EvidenceQuality {
        EvidenceQuality(rawValue: max(1, rawValue - steps)) ?? .low
    }
}

/// Envelope shared by every characteristic result.
nonisolated struct Assessment: Sendable, Equatable {
    var status: AssessmentStatus
    var quality: EvidenceQuality
    /// Plain-language reasoning that cites the measurements behind the result.
    var explanation: String
    var evidence: [EvidenceReference]
    var limitations: [String]

    var isDetermined: Bool { status == .determined }

    static func unavailable(_ explanation: String,
                            evidence: [EvidenceReference] = [],
                            limitations: [String] = []) -> Assessment {
        Assessment(status: .unavailable, quality: .none, explanation: explanation,
                   evidence: evidence, limitations: limitations)
    }

    static func notApplicable(_ explanation: String,
                              evidence: [EvidenceReference] = [],
                              limitations: [String] = []) -> Assessment {
        Assessment(status: .notApplicable, quality: .none, explanation: explanation,
                   evidence: evidence, limitations: limitations)
    }

    static func insufficient(_ explanation: String,
                             evidence: [EvidenceReference] = [],
                             limitations: [String] = []) -> Assessment {
        Assessment(status: .insufficientEvidence, quality: .none, explanation: explanation,
                   evidence: evidence, limitations: limitations)
    }
}

// MARK: - 1. Camera angle

nonisolated enum CameraAngleCategory: String, Sendable, CaseIterable, Hashable {
    case lowAngle
    case eyeLevel
    case highAngle
    /// Unknown / insufficient evidence.
    case unknown
}

/// A horizon line recovered from the segmentation (sea or flat ground meeting sky).
nonisolated struct HorizonLineFit: Sendable, Equatable {
    /// y = intercept + slope * x, image space.
    let slope: Double
    let intercept: Double
    /// RMS residual of the inlier boundary points, in normalised units.
    let residualRMS: Double
    /// Share of sampled columns that contributed an inlier boundary point.
    let columnCoverage: Double
    /// Segmentation label directly below the sky along the fitted line.
    let lowerRegionLabel: String
    /// True for open water; flat ground is accepted with lower trust.
    let isOpenWater: Bool

    func y(atX x: Double) -> Double { intercept + slope * x }
}

/// The horizon-versus-eye-line measurement behind a camera-angle decision.
nonisolated struct HorizonEyeCue: Sendable, Equatable {
    let horizon: HorizonLineFit
    let eyePoint: CGPoint
    let eyeSource: String
    /// Height of the head in image space, when a face was found. A convenient
    /// ruler for display; the decision does not depend on it.
    let headHeight: Double?
    /// (eyeY - horizonY at the eye's x), in image-height units. Positive: the
    /// eyes sit BELOW the horizon line in the image, i.e. the camera is higher.
    let offsetInImageHeights: Double
    /// The same offset in head-heights, when a head size is available.
    let offsetInHeadHeights: Double?
}

nonisolated struct CameraAngleResult: Sendable, Equatable {
    let category: CameraAngleCategory
    /// Set when a horizon was found and compared with the eye line. Kept for the overlay.
    let horizonCue: HorizonEyeCue?
    /// Head orientation relative to the camera, recorded as context only.
    let headPitchDegrees: Double?
    let headYawDegrees: Double?
    /// Vision's horizon angle: image roll, recorded as context only.
    let imageRollDegrees: Double?
    let assessment: Assessment

    /// Everything each evidence provider observed, before and apart from the
    /// final classification. Empty when no subject existed to assess.
    var observations: [CameraAngleObservation] = []
    /// What the fusion concluded: categories still possible, who contributed, conflicts.
    var decision: CameraAngleDecisionSummary?
    /// The vertical-edge segments that supported a scene-geometry observation (overlay).
    var sceneLines: [ImageLineSegment] = []
}

// MARK: - 2. Subject framing

nonisolated enum FramingCategory: String, Sendable, CaseIterable, Hashable {
    case fullBody
    case halfBody
    /// No human subject, or the framing categories do not apply.
    case other
    /// Unknown / insufficient evidence.
    case unknown
}

/// The deepest part of the body for which Vision found reliable landmarks.
/// Kept separate from `FramingCategory` so finer categories can be added later
/// without re-measuring.
nonisolated enum VisibleBodyExtent: Int, Sendable, Comparable, Hashable {
    case none = 0
    case headOnly
    case headAndShoulders
    case toHips
    case toKnees
    case toAnkles

    static func < (lhs: VisibleBodyExtent, rhs: VisibleBodyExtent) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct SubjectFramingResult: Sendable, Equatable {
    let category: FramingCategory
    let visibleExtent: VisibleBodyExtent?
    /// Frame edges the primary subject's box touches (evidence of cropping).
    let croppedEdges: Set<FrameEdge>
    let reliableLandmarkCount: Int
    let assessment: Assessment
}

// MARK: - 3. Subject positioning

nonisolated enum HorizontalZone: String, Sendable, CaseIterable, Hashable {
    case left, center, right
}

nonisolated enum VerticalZone: String, Sendable, CaseIterable, Hashable {
    case upper, middle, lower
}

nonisolated struct SecondarySubject: Sendable, Equatable {
    /// 1 = second most prominent person, and so on.
    let rank: Int
    let box: CGRect
    let confidence: Double
}

/// How the primary subject was chosen.
nonisolated struct SubjectSelectionInfo: Sendable, Equatable {
    let detectedCount: Int
    let eligibleCount: Int
    /// Raw detection index of the chosen person, if any.
    let primaryCandidateID: Int?
    /// The runner-up is nearly as large, so the choice is less certain.
    let isAmbiguous: Bool

    static let policy = """
    Eligible: confidence >= 0.30 and box area >= 0.5% of the image. \
    Primary: largest box area; ties within 2% broken by higher confidence, then \
    closer to the image centre, then further left.
    """
}

nonisolated struct SubjectPositioningResult: Sendable, Equatable {
    /// Nil unless a valid detection exists. Never fabricated.
    let subjectBox: CGRect?
    /// Head-and-torso box for the same person, when Vision produced one.
    let upperBodyBox: CGRect?
    let center: CGPoint?
    let normalizedWidth: Double?
    let normalizedHeight: Double?
    let normalizedArea: Double?
    let horizontal: HorizontalZone?
    let vertical: VerticalZone?
    let detectionConfidence: Double?
    let isMeasurementValid: Bool
    let touchedEdges: Set<FrameEdge>
    let selection: SubjectSelectionInfo
    let secondarySubjects: [SecondarySubject]
    let assessment: Assessment
}

// MARK: - 4. Environmental depth

nonisolated enum DepthStructure: String, Sendable, CaseIterable, Hashable {
    /// Subject is clearly nearer than most of its surroundings.
    case separated
    /// Elements both in front of and behind the subject.
    case layered
    /// Much of the surroundings is nearer than the subject.
    case foregroundDominant
    /// Subject and surroundings sit at similar relative depth.
    case blended
    /// Some separation, but not clear enough for the stronger categories.
    case partialSeparation
    /// Unknown / insufficient evidence.
    case unknown
}

nonisolated enum SubjectRegionMethod: String, Sendable, Hashable {
    /// Person-class pixels from segmentation, restricted to the subject's box.
    case personMask
    /// Central core of the subject's box (documented fallback, lower trust).
    case boxCore
}

nonisolated struct DepthMetrics: Sendable, Equatable {
    let subjectRegionMethod: SubjectRegionMethod
    let subjectSampleCount: Int
    let environmentSampleCount: Int
    /// Share of the subject box covered by person pixels (personMask method only).
    let maskCoverageOfBox: Double?
    let maskMayIncludeOtherPeople: Bool
    let subjectMedian: Double
    let subjectSpread: Double
    let environmentMedian: Double
    let subjectMinusEnvironment: Double
    let fractionEnvironmentNearer: Double
    let fractionEnvironmentFarther: Double
    let fractionEnvironmentSimilar: Double
    let ringMedian: Double?
    let ringSpread: Double?
    let subjectMinusRing: Double?
}

/// Whole-scene depth distribution, available even without a subject.
nonisolated struct SceneDepthBands: Sendable, Equatable {
    let nearFraction: Double
    let midFraction: Double
    let farFraction: Double
    /// Mean nearness of the bottom third minus the top third.
    let bottomMinusTop: Double
    let contrast: Double
}

nonisolated struct EnvironmentalDepthResult: Sendable, Equatable {
    let structure: DepthStructure
    let metrics: DepthMetrics?
    let sceneBands: SceneDepthBands?
    let assessment: Assessment
}

// MARK: - Per-photo result

nonisolated enum PhotoResultStatus: String, Sendable, Hashable {
    /// Every source ran and every characteristic was assessed.
    case complete
    /// Some sources failed or characteristics could not be determined.
    case partial
    /// Nothing usable (unreadable photo, or every source failed).
    case failed
}

nonisolated struct ImagePreparationRecord: Sendable, Equatable {
    let originalPixelWidth: Int
    let originalPixelHeight: Int
    /// Raw `UIImage.Orientation` value of the source.
    let orientationRaw: Int
    /// Size after applying orientation, at original resolution.
    let uprightWidth: Int
    let uprightHeight: Int
    /// Size of the analysis/display image.
    let preparedWidth: Int
    let preparedHeight: Int
    let longEdgeLimit: Int

    var scale: Double { Double(preparedWidth) / Double(max(1, uprightWidth)) }
    var preparedSize: CGSize { CGSize(width: preparedWidth, height: preparedHeight) }
}

nonisolated struct PhotoResult: Identifiable, Sendable, Equatable {
    /// The `ReferencePhoto.id`, preserved so the original image, evidence and
    /// profile contribution stay associated.
    let id: UUID
    let selectionOrder: Int
    let localIdentifier: String
    let preparation: ImagePreparationRecord?
    let status: PhotoResultStatus
    let evidence: PhotoEvidence?
    let cameraAngle: CameraAngleResult
    let subjectFraming: SubjectFramingResult
    let subjectPositioning: SubjectPositioningResult
    let environmentalDepth: EnvironmentalDepthResult
    /// Failures that affected this photo (unreadable image, failed sources).
    let errors: [String]
    let limitations: [String]

    func assessment(for kind: CharacteristicKind) -> Assessment {
        switch kind {
        case .cameraAngle:         return cameraAngle.assessment
        case .subjectFraming:      return subjectFraming.assessment
        case .subjectPositioning:  return subjectPositioning.assessment
        case .environmentalDepth:  return environmentalDepth.assessment
        }
    }

    /// True when at least one characteristic reached a determined conclusion.
    var hasAnyDeterminedCharacteristic: Bool {
        CharacteristicKind.allCases.contains { assessment(for: $0).isDetermined }
    }
}
