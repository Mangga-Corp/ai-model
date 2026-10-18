import Foundation
import CoreGraphics

/// Builds the environment side of the Photo Preference Profile.
///
/// RULES
///  - Only valid observations count. A photo whose segmentation failed, or whose
///    result was insufficient, is excluded from that metric and never counted
///    for or against anything. Missing output is not evidence that an element
///    or category was absent.
///  - Rates always state their denominator. An element's presence is measured
///    against the photos whose segmentation was valid, and "dominant when
///    present" against the photos where it was present.
///  - Categorical findings reuse the profile's pattern rules (one observation is
///    recorded but is not a preference; a pattern needs two photos and a clear
///    majority). Observations near a band threshold keep their category but
///    carry less weight.
///  - Transferable composition and scene-dependent tendencies are separate
///    values, so a consumer cannot apply a scene-bound tendency unconditionally.
nonisolated enum EnvironmentProfileAggregator {

    static let placementTolerance = 0.10
    static let maximumFamilyTendencies = 8

    static func aggregate(_ results: [PhotoResult]) -> EnvironmentProfile {
        let ordered = results.sorted { $0.selectionOrder < $1.selectionOrder }
        let total = ordered.count
        // Only photos whose segmentation can support claims about the surroundings count toward
        // presence or absence. A photo whose output decoded but is too incomplete to interpret says
        // nothing about what is, or is not, in the scene.
        let eligible = ordered.filter { $0.environment?.segmentation.interpretation.isEligible ?? false }
        let decoded = ordered.filter { $0.environment?.segmentation.availability.hasValidOutput ?? false }.count
        let withSetAside = ordered.filter { !($0.environment?.segmentation.setAsideRegions.isEmpty ?? true) }.count

        // MARK: Transferable composition

        let scale: CategoryFinding<SubjectScaleBand> = ProfileAggregator.finding(
            kind: nil, all: ordered, possible: SubjectScaleBand.allCases.count,
            name: { (b: SubjectScaleBand) -> String in name(of: b) },
            observe: { (r: PhotoResult) -> (SubjectScaleBand, EvidenceQuality)? in
                guard let c = r.environment?.composition, c.assessment.isDetermined, let b = c.scale else { return nil }
                return (b.band, b.isNearBoundary ? c.assessment.quality.lowered() : c.assessment.quality)
            })

        let offset: CategoryFinding<HorizontalOffsetBand> = ProfileAggregator.finding(
            kind: nil, all: ordered, possible: HorizontalOffsetBand.allCases.count,
            name: { (b: HorizontalOffsetBand) -> String in name(of: b) },
            observe: { (r: PhotoResult) -> (HorizontalOffsetBand, EvidenceQuality)? in
                guard let c = r.environment?.composition, c.assessment.isDetermined, let b = c.horizontalOffset else { return nil }
                return (b.band, b.isNearBoundary ? c.assessment.quality.lowered() : c.assessment.quality)
            })

        let prominence: CategoryFinding<ProminenceBand> = ProfileAggregator.finding(
            kind: nil, all: ordered, possible: ProminenceBand.allCases.count,
            name: { (b: ProminenceBand) -> String in name(of: b) },
            observe: { (r: PhotoResult) -> (ProminenceBand, EvidenceQuality)? in
                guard let e = r.environment, e.composition.assessment.isDetermined,
                      let b = e.composition.prominence else { return nil }
                let quality = min(e.composition.assessment.quality, e.elements.assessment.quality)
                return (b.band, b.isNearBoundary ? quality.lowered() : quality)
            })

        let compositions = ordered.compactMap { r -> CompositionResult? in
            guard let c = r.environment?.composition, c.assessment.isDetermined else { return nil }
            return c
        }
        let borderline = compositions.filter { ($0.scale?.isNearBoundary ?? false) || ($0.horizontalOffset?.isNearBoundary ?? false) }.count

        let transferable = TransferableComposition(
            subjectScale: scale, horizontalOffset: offset, environmentProminence: prominence,
            subjectBoxArea: NumericSummary.make(compositions.compactMap { $0.subject?.boxAreaRatio }),
            subjectMaskArea: NumericSummary.make(compositions.compactMap { $0.subject?.maskAreaRatio }),
            dominantElementToSubject: NumericSummary.make(compositions.compactMap { $0.prominence?.value }),
            borderlinePhotoCount: borderline,
            note: "Subject scale, offset and the prominence of the surroundings relative to the subject do not depend on which environment is present, so they can be applied in any scene.")

        // MARK: Scene-dependent tendencies

        let category: CategoryFinding<SceneContextCategory> = ProfileAggregator.finding(
            kind: nil, all: ordered, possible: SceneContextCategory.allCases.count - 1,
            name: { (c: SceneContextCategory) -> String in c.displayName },
            observe: { (r: PhotoResult) -> (SceneContextCategory, EvidenceQuality)? in
                guard let s = r.environment?.scene, s.assessment.isDetermined, s.primary != .unknown else { return nil }
                return (s.primary, s.assessment.quality)
            })

        let setting: CategoryFinding<SceneSetting> = ProfileAggregator.finding(
            kind: nil, all: ordered, possible: 2,
            name: { (s: SceneSetting) -> String in s.displayName },
            observe: { (r: PhotoResult) -> (SceneSetting, EvidenceQuality)? in
                guard let e = r.environment, e.segmentation.interpretation.isEligible,
                      e.scene.setting != .undetermined else { return nil }
                return (e.scene.setting, min(e.segmentation.assessment.quality, .moderate))
            })

        let character: CategoryFinding<EnvironmentCharacter> = ProfileAggregator.finding(
            kind: nil, all: ordered, possible: 3,
            name: { (c: EnvironmentCharacter) -> String in c.displayName },
            observe: { (r: PhotoResult) -> (EnvironmentCharacter, EvidenceQuality)? in
                guard let e = r.environment, e.segmentation.interpretation.isEligible,
                      e.scene.character != .undetermined else { return nil }
                return (e.scene.character, min(e.segmentation.assessment.quality, .moderate))
            })

        let sceneDependent = SceneDependentTendencies(
            sceneCategory: category, setting: setting, character: character,
            builtShare: NumericSummary.make(eligible.compactMap { $0.environment?.scene.builtShare }),
            groupTendencies: groupTendencies(eligible),
            familyTendencies: Array(familyTendencies(eligible).prefix(maximumFamilyTendencies)),
            placements: placements(eligible),
            note: "These describe the reference photos. Each applies only when the matching environment is present in the live scene; none is an instruction to look for it.")

        // MARK: Coverage and limitations

        var coverage: [EnvironmentFacet: FacetCoverage] = [:]
        for facet in EnvironmentFacet.allCases { coverage[facet] = coverageFor(facet, ordered) }

        return EnvironmentProfile(
            totalPhotoCount: total, eligiblePhotoCount: eligible.count,
            transferable: transferable, sceneDependent: sceneDependent, coverage: coverage,
            limitations: limitations(total: total, eligible: eligible.count, decoded: decoded, withSetAside: withSetAside))
    }

    // MARK: Element tendencies

    private struct Accumulator {
        var label: String
        var group: ElementGroup
        var present: [UUID] = []
        var areas: [Double] = []
        var dominant: [UUID] = []
        var secondary: [UUID] = []
        /// Photos where a region of this kind was set aside: neither present nor absent there.
        var setAside: [UUID] = []
    }

    private static func familyTendencies(_ eligible: [PhotoResult]) -> [ElementTendency] {
        var acc: [String: Accumulator] = [:]
        for r in eligible {
            guard let e = r.environment else { continue }
            for region in e.segmentation.environmentalRegions {
                var a = acc[region.family.key] ?? Accumulator(label: region.family.displayName, group: region.family.group)
                a.present.append(r.id)
                a.areas.append(region.areaFraction)
                acc[region.family.key] = a
            }
            for region in e.segmentation.setAsideRegions where region.family.group.isEnvironmental {
                var a = acc[region.family.key] ?? Accumulator(label: region.family.displayName, group: region.family.group)
                a.setAside.append(r.id)
                acc[region.family.key] = a
            }
            for c in e.elements.candidates {
                switch c.role {
                case .dominant: acc[c.familyKey]?.dominant.append(r.id)
                case .secondary: acc[c.familyKey]?.secondary.append(r.id)
                case .uncertain: break
                }
            }
        }
        return tendencies(from: acc, eligibleCount: eligible.count)
    }

    private static func groupTendencies(_ eligible: [PhotoResult]) -> [ElementTendency] {
        var acc: [String: Accumulator] = [:]
        for r in eligible {
            guard let e = r.environment else { continue }
            var areaByGroup: [ElementGroup: Double] = [:]
            for region in e.segmentation.environmentalRegions { areaByGroup[region.family.group, default: 0] += region.areaFraction }
            for (group, area) in areaByGroup {
                var a = acc[group.rawValue] ?? Accumulator(label: group.displayName, group: group)
                a.present.append(r.id)
                a.areas.append(area)
                acc[group.rawValue] = a
            }
            for group in Set(e.segmentation.setAsideRegions.filter { $0.family.group.isEnvironmental }.map(\.family.group)) {
                var a = acc[group.rawValue] ?? Accumulator(label: group.displayName, group: group)
                a.setAside.append(r.id)
                acc[group.rawValue] = a
            }
            // A group counts once per photo, at its strongest role.
            let dominantGroups = Set(e.elements.candidates.filter { $0.role == .dominant }.map(\.group))
            let secondaryGroups = Set(e.elements.candidates.filter { $0.role == .secondary }.map(\.group)).subtracting(dominantGroups)
            for group in dominantGroups { acc[group.rawValue]?.dominant.append(r.id) }
            for group in secondaryGroups { acc[group.rawValue]?.secondary.append(r.id) }
        }
        return tendencies(from: acc, eligibleCount: eligible.count)
    }

    private static func tendencies(from acc: [String: Accumulator], eligibleCount: Int) -> [ElementTendency] {
        // A set-aside region of this kind leaves the photo out of THIS element's denominator
        // (it is unknown there, not absent). Elements never seen are not listed.
        acc.filter { !$0.value.present.isEmpty }.map { key, a in
            let denominator = max(0, eligibleCount - a.setAside.count)
            return ElementTendency(
                key: key, label: a.label, group: a.group, eligiblePhotoCount: denominator,
                presentCount: a.present.count, dominantCount: a.dominant.count, secondaryCount: a.secondary.count,
                presentPhotoIDs: a.present, dominantPhotoIDs: a.dominant,
                areaWhenPresent: NumericSummary.make(a.areas),
                pattern: PresencePattern.classify(present: a.present.count, eligible: denominator),
                condition: "Conditional on the live scene containing \(a.label.lowercased()).")
        }
        .sorted {
            if $0.presentCount != $1.presentCount { return $0.presentCount > $1.presentCount }
            if $0.dominantCount != $1.dominantCount { return $0.dominantCount > $1.dominantCount }
            return $0.key < $1.key
        }
    }

    // MARK: Placement

    private static func placements(_ eligible: [PhotoResult]) -> [ElementPlacementTendency] {
        struct Samples { var label: String; var xs: [Double] = []; var ys: [Double] = [] }
        var samples: [String: Samples] = [:]

        for r in eligible {
            guard let e = r.environment else { continue }
            var byGroup: [ElementGroup: [SemanticRegion]] = [:]
            for region in e.segmentation.environmentalRegions where region.geometry != nil { byGroup[region.family.group, default: []].append(region) }
            for (group, regions) in byGroup {
                let weight = regions.reduce(0) { $0 + $1.areaFraction }
                guard weight > 0 else { continue }
                let x = regions.reduce(0) { $0 + Double($1.geometry!.centroid.x) * $1.areaFraction } / weight
                let y = regions.reduce(0) { $0 + Double($1.geometry!.centroid.y) * $1.areaFraction } / weight
                var s = samples[group.rawValue] ?? Samples(label: group.displayName)
                s.xs.append(x); s.ys.append(y)
                samples[group.rawValue] = s
            }
        }

        func rank(_ c: Consistency) -> Int {
            switch c { case .tight: return 0; case .moderate: return 1; case .wide: return 2; case .undetermined: return 3 }
        }

        return samples
            .filter { $0.value.xs.count >= 2 }
            .map { key, s -> ElementPlacementTendency in
                var h: [HorizontalZone: Int] = [:], v: [VerticalZone: Int] = [:]
                for x in s.xs { h[SubjectPositioningMeasurer.horizontalZone(forCenterX: x), default: 0] += 1 }
                for y in s.ys { v[SubjectPositioningMeasurer.verticalZone(forCenterY: y), default: 0] += 1 }
                let cx = NumericSummary.make(s.xs), cy = NumericSummary.make(s.ys)
                let cxc = cx?.consistency(tolerance: placementTolerance) ?? .undetermined
                let cyc = cy?.consistency(tolerance: placementTolerance) ?? .undetermined
                return ElementPlacementTendency(
                    key: key, label: s.label, sampleCount: s.xs.count, centerX: cx, centerY: cy,
                    horizontalCounts: h, verticalCounts: v,
                    consistency: rank(cxc) >= rank(cyc) ? cxc : cyc,
                    condition: "Conditional on the live scene containing \(s.label.lowercased()).")
            }
            .sorted { $0.sampleCount != $1.sampleCount ? $0.sampleCount > $1.sampleCount : $0.key < $1.key }
    }

    // MARK: Coverage and limitations

    private static func coverageFor(_ facet: EnvironmentFacet, _ results: [PhotoResult]) -> FacetCoverage {
        var determined: [UUID] = [], insufficient: [UUID] = [], notApplicable: [UUID] = [], unavailable: [UUID] = []
        for r in results {
            let status: AssessmentStatus
            if let e = r.environment {
                switch facet {
                case .segmentation: status = e.segmentation.assessment.status
                case .dominantElements: status = e.elements.assessment.status
                case .sceneContext: status = e.scene.assessment.status
                case .composition: status = e.composition.assessment.status
                }
            } else {
                status = .unavailable
            }
            switch status {
            case .determined: determined.append(r.id)
            case .insufficientEvidence: insufficient.append(r.id)
            case .notApplicable: notApplicable.append(r.id)
            case .unavailable: unavailable.append(r.id)
            }
        }
        return FacetCoverage(facet: facet, totalPhotos: results.count, determinedPhotoIDs: determined,
                             insufficientPhotoIDs: insufficient, notApplicablePhotoIDs: notApplicable,
                             unavailablePhotoIDs: unavailable)
    }

    private static func limitations(total: Int, eligible: Int, decoded: Int, withSetAside: Int) -> [String] {
        guard total > 0 else { return ["No photos were analysed."] }
        var out: [String] = []
        if eligible < total {
            out.append("Segmentation could be interpreted for \(eligible) of \(total) photos. The others are left out of element and scene tendencies, not counted as lacking those elements.")
        }
        if decoded > eligible {
            out.append("\(decoded - eligible) photo(s) produced a segmentation that was too incomplete to interpret (little visible surroundings or few supported labels). They say nothing about what is or is not in the scene.")
        }
        if withSetAside > 0 {
            out.append("\(withSetAside) photo(s) had a region set aside as unreliable. That element is left out of those photos' counts, neither present nor absent.")
        }
        if eligible == 1 {
            out.append("Only one photo has environment evidence, so element and scene findings are single observations, not preferences.")
        }
        out.append("An element counts as present only when its region is large enough to measure (at least 0.2% of the image). Not being listed does not prove it was absent.")
        out.append("Regions are combined semantic classes from a segmentation model without per-pixel confidence; they are not separate objects.")
        out.append("Scene categories are inferred from visible regions and are less certain than the measurements behind them.")
        return out
    }

    // MARK: Names

    private static func name(of b: SubjectScaleBand) -> String {
        switch b { case .small: return "Small in frame"; case .moderate: return "Moderate size"; case .large: return "Large in frame" }
    }

    private static func name(of b: HorizontalOffsetBand) -> String {
        switch b { case .centered: return "Centered"; case .slightlyOff: return "Slightly off-center"; case .offCenter: return "Off-center" }
    }

    private static func name(of b: ProminenceBand) -> String {
        switch b {
        case .environmentDominates: return "Environment dominates"
        case .balanced: return "Balanced"
        case .subjectDominates: return "Subject dominates"
        }
    }
}
