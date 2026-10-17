import Foundation
import CoreGraphics

/// Stage F: builds the consolidated `PreferenceProfile` from per-photo results.
///
/// DETERMINISTIC AGGREGATION RULES
///
/// Observations
///   - Only photos whose characteristic is `determined` contribute. Photos with
///     insufficient, not-applicable or unavailable results are listed as
///     excluded; missing evidence is never counted for or against a category.
///   - Categorical values are never averaged. Each category is counted, and
///     weighted by evidence quality (high 1.0, moderate 0.7, low 0.4).
///
/// Pattern (n = number of valid observations)
///   - n = 0                      -> noEvidence
///   - n = 1                      -> singleObservation (recorded, not a preference)
///   - n >= 2, leading category appears in >= 2 photos AND holds >= 60% of the
///     weighted share             -> recurring
///   - otherwise                  -> mixed (no dominant category; recurring
///     categories and all shares are still reported)
///
/// Strength
///   recurring: strong if n >= 4 and share >= 75%; moderate if n >= 3;
///              otherwise limited (two photos agreeing).
///   mixed:     moderate if n >= 3, otherwise limited.
///   noEvidence / singleObservation: insufficient.
nonisolated enum ProfileAggregator {

    static let recurrenceShare = 0.60
    static let strongShare = 0.75

    // Spread tolerances (population standard deviation, normalised units).
    static let centerTolerance = 0.10
    static let areaCoefficientOfVariation = 0.25

    static func aggregate(_ results: [PhotoResult], generatedAt: Date = Date()) -> PreferenceProfile {
        let ordered = results.sorted { $0.selectionOrder < $1.selectionOrder }
        let total = ordered.count

        // Categorical findings.
        let angle: CategoryFinding<CameraAngleCategory> = finding(
            kind: .cameraAngle, all: ordered,
            possible: CameraAngleCategory.allCases.count - 1,   // unknown is not a pattern
            name: { (c: CameraAngleCategory) -> String in name(of: c) },
            observe: { (r: PhotoResult) -> (CameraAngleCategory, EvidenceQuality)? in
                let a = r.cameraAngle
                guard a.assessment.isDetermined, a.category != .unknown else { return nil }
                return (a.category, a.assessment.quality)
            })

        let framing: CategoryFinding<FramingCategory> = finding(
            kind: .subjectFraming, all: ordered,
            possible: FramingCategory.allCases.count - 1,
            name: { (c: FramingCategory) -> String in name(of: c) },
            observe: { (r: PhotoResult) -> (FramingCategory, EvidenceQuality)? in
                let f = r.subjectFraming
                guard f.assessment.isDetermined, f.category != .unknown else { return nil }
                return (f.category, f.assessment.quality)
            })

        let horizontal: CategoryFinding<HorizontalZone> = finding(
            kind: .subjectPositioning, all: ordered,
            possible: HorizontalZone.allCases.count,
            name: { (z: HorizontalZone) -> String in "\(z.rawValue) third" },
            observe: { (r: PhotoResult) -> (HorizontalZone, EvidenceQuality)? in
                let p = r.subjectPositioning
                guard p.assessment.isDetermined, p.isMeasurementValid, let z = p.horizontal else { return nil }
                return (z, p.assessment.quality)
            })

        let vertical: CategoryFinding<VerticalZone> = finding(
            kind: .subjectPositioning, all: ordered,
            possible: VerticalZone.allCases.count,
            name: { (z: VerticalZone) -> String in "\(z.rawValue) third" },
            observe: { (r: PhotoResult) -> (VerticalZone, EvidenceQuality)? in
                let p = r.subjectPositioning
                guard p.assessment.isDetermined, p.isMeasurementValid, let z = p.vertical else { return nil }
                return (z, p.assessment.quality)
            })

        let depthStructure: CategoryFinding<DepthStructure> = finding(
            kind: .environmentalDepth, all: ordered,
            possible: DepthStructure.allCases.count - 1,   // unknown is not a pattern
            name: { (c: DepthStructure) -> String in name(of: c) },
            observe: { (r: PhotoResult) -> (DepthStructure, EvidenceQuality)? in
                let d = r.environmentalDepth
                guard d.assessment.isDetermined, d.structure != .unknown else { return nil }
                return (d.structure, d.assessment.quality)
            })

        // Numeric summaries.
        let valid = ordered.map(\.subjectPositioning).filter { $0.assessment.isDetermined && $0.isMeasurementValid }
        let positioning = positioningMetrics(valid)
        let depth = depthMetrics(ordered)

        // Coverage.
        var coverage: [CharacteristicKind: CharacteristicCoverage] = [:]
        for kind in CharacteristicKind.allCases {
            coverage[kind] = coverageFor(kind, ordered)
        }

        let unsupported = CharacteristicKind.allCases.filter { kind in
            switch kind {
            case .cameraAngle: return angle.pattern == .noEvidence
            case .subjectFraming: return framing.pattern == .noEvidence
            case .subjectPositioning: return horizontal.pattern == .noEvidence
            case .environmentalDepth: return depthStructure.pattern == .noEvidence
            }
        }

        let analyzed = ordered.filter { $0.status != .failed }.count
        let withEvidence = ordered.filter(\.hasAnyDeterminedCharacteristic).count

        return PreferenceProfile(
            generatedAt: generatedAt, totalPhotoCount: total, analyzedPhotoCount: analyzed,
            photosWithValidEvidenceCount: withEvidence,
            cameraAngle: angle, subjectFraming: framing,
            horizontalPosition: horizontal, verticalPosition: vertical,
            positioning: positioning, depthStructure: depthStructure, depth: depth,
            coverage: coverage, unsupportedCharacteristics: unsupported,
            limitations: limitations(total: total, analyzed: analyzed, coverage: coverage, ordered: ordered),
            environment: EnvironmentProfileAggregator.aggregate(ordered))
    }

    // MARK: Categorical finding

    static func finding<C: Hashable & Sendable>(
        kind: CharacteristicKind?,
        all results: [PhotoResult],
        possible: Int,
        name: (C) -> String,
        observe: (PhotoResult) -> (C, EvidenceQuality)?
    ) -> CategoryFinding<C> {

        var observations: [(id: UUID, category: C, quality: EvidenceQuality)] = []
        var excluded: [UUID] = []
        for r in results {
            if let (category, quality) = observe(r) { observations.append((r.id, category, quality)) }
            else { excluded.append(r.id) }
        }

        let n = observations.count
        var counts: [C: Int] = [:]
        var weights: [C: Double] = [:]
        var supporters: [C: [UUID]] = [:]
        var firstSeen: [C: Int] = [:]   // deterministic tie-break
        for (index, o) in observations.enumerated() {
            counts[o.category, default: 0] += 1
            weights[o.category, default: 0] += max(o.quality.weight, 0.1)
            supporters[o.category, default: []].append(o.id)
            if firstSeen[o.category] == nil { firstSeen[o.category] = index }
        }
        let totalWeight = weights.values.reduce(0, +)
        let shares = weights.mapValues { totalWeight > 0 ? $0 / totalWeight : 0 }

        let ranked = counts.keys.sorted { a, b in
            let wa = weights[a] ?? 0, wb = weights[b] ?? 0
            if wa != wb { return wa > wb }
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return (firstSeen[a] ?? 0) < (firstSeen[b] ?? 0)
        }
        let leader = ranked.first
        let leaderCount = leader.flatMap { counts[$0] } ?? 0
        let leaderShare = leader.flatMap { shares[$0] } ?? 0
        let recurring = ranked.filter { (counts[$0] ?? 0) >= 2 }
        let isolated = ranked.filter { (counts[$0] ?? 0) == 1 }

        let pattern: PatternKind
        let strength: PatternStrength
        var dominant: C?
        switch n {
        case 0:
            pattern = .noEvidence; strength = .insufficient
        case 1:
            pattern = .singleObservation; strength = .insufficient
        default:
            if leaderCount >= 2 && leaderShare >= recurrenceShare {
                pattern = .recurring
                dominant = leader
                if n >= 4 && leaderShare >= strongShare { strength = .strong }
                else if n >= 3 { strength = .moderate }
                else { strength = .limited }
            } else {
                pattern = .mixed
                strength = n >= 3 ? .moderate : .limited
            }
        }

        // Normalised Shannon entropy of the counts (0 = one category, 1 = even).
        var variation = 0.0
        if n >= 2, possible > 1 {
            let entropy = counts.values.reduce(0.0) { acc, c in
                let p = Double(c) / Double(n)
                return acc - p * log(p)
            }
            variation = min(1, entropy / log(Double(possible)))
        }

        let summary: String
        switch pattern {
        case .noEvidence:
            summary = "No photo produced valid evidence for this characteristic."
        case .singleObservation:
            summary = "Only one photo gave valid evidence (\(leader.map(name) ?? "none")). A single observation is not treated as a preference."
        case .recurring:
            let d = dominant!
            var text = "\(name(d)) in \(counts[d] ?? 0) of \(n) photos with valid evidence (\(Int((leaderShare * 100).rounded()))%)."
            let others = recurring.filter { $0 != d }
            if !others.isEmpty { text += " Also recurring: \(others.map(name).joined(separator: ", "))." }
            if !isolated.isEmpty { text += " Isolated: \(isolated.map(name).joined(separator: ", "))." }
            summary = text
        case .mixed:
            let parts = ranked.map { "\(name($0)) \(counts[$0] ?? 0)" }
            summary = "No single pattern across \(n) photos (\(parts.joined(separator: ", ")))."
        }

        let sentence = summary.prefix(1).uppercased() + summary.dropFirst()

        return CategoryFinding(
            kind: kind, validObservationCount: n, counts: counts, weightedShares: shares,
            supportingPhotoIDs: supporters, dominant: dominant, recurringCategories: recurring,
            dominantShare: leaderShare, dominantCount: leaderCount, isolated: isolated,
            pattern: pattern, strength: strength, variation: variation,
            excludedPhotoIDs: excluded, summary: sentence)
    }

    // MARK: Numeric summaries

    private static func positioningMetrics(_ valid: [SubjectPositioningResult]) -> PositioningMetrics {
        let xs = valid.compactMap { $0.center.map { Double($0.x) } }
        let ys = valid.compactMap { $0.center.map { Double($0.y) } }
        let ws = valid.compactMap(\.normalizedWidth)
        let hs = valid.compactMap(\.normalizedHeight)
        let areas = valid.compactMap(\.normalizedArea)

        let cx = NumericSummary.make(xs), cy = NumericSummary.make(ys)
        let area = NumericSummary.make(areas)
        let cxc = cx?.consistency(tolerance: centerTolerance) ?? .undetermined
        let cyc = cy?.consistency(tolerance: centerTolerance) ?? .undetermined

        var areaConsistency = Consistency.undetermined
        if let area, area.count >= 2, area.mean > 0 {
            let cv = area.standardDeviation / area.mean
            areaConsistency = cv <= areaCoefficientOfVariation ? .tight
                : (cv <= areaCoefficientOfVariation * 2 ? .moderate : .wide)
        }

        var typical: CGPoint?
        if let cx, let cy, cx.count >= 2, cxc != .wide, cyc != .wide {
            typical = CGPoint(x: cx.median, y: cy.median)
        }
        return PositioningMetrics(
            sampleCount: valid.count, centerX: cx, centerY: cy,
            width: NumericSummary.make(ws), height: NumericSummary.make(hs), area: area,
            centerXConsistency: cxc, centerYConsistency: cyc, areaConsistency: areaConsistency,
            typicalCenter: typical)
    }

    private static func depthMetrics(_ results: [PhotoResult]) -> DepthProfileMetrics {
        let metrics = results.compactMap { r -> DepthMetrics? in
            r.environmentalDepth.assessment.isDetermined ? r.environmentalDepth.metrics : nil
        }
        return DepthProfileMetrics(
            sampleCount: metrics.count,
            subjectMinusEnvironment: NumericSummary.make(metrics.map(\.subjectMinusEnvironment)),
            fractionEnvironmentNearer: NumericSummary.make(metrics.map(\.fractionEnvironmentNearer)),
            fractionEnvironmentFarther: NumericSummary.make(metrics.map(\.fractionEnvironmentFarther)))
    }

    // MARK: Coverage & limitations

    private static func coverageFor(_ kind: CharacteristicKind, _ results: [PhotoResult]) -> CharacteristicCoverage {
        var determined: [UUID] = [], insufficient: [UUID] = [], notApplicable: [UUID] = [], unavailable: [UUID] = []
        var low = 0
        for r in results {
            let a = r.assessment(for: kind)
            switch a.status {
            case .determined: determined.append(r.id); if a.quality <= .low { low += 1 }
            case .insufficientEvidence: insufficient.append(r.id)
            case .notApplicable: notApplicable.append(r.id)
            case .unavailable: unavailable.append(r.id)
            }
        }
        return CharacteristicCoverage(kind: kind, totalPhotos: results.count,
                                      determinedPhotoIDs: determined, insufficientPhotoIDs: insufficient,
                                      notApplicablePhotoIDs: notApplicable, unavailablePhotoIDs: unavailable,
                                      lowQualityDeterminedCount: low)
    }

    private static func limitations(total: Int, analyzed: Int,
                                    coverage: [CharacteristicKind: CharacteristicCoverage],
                                    ordered: [PhotoResult]) -> [String] {
        var out: [String] = []
        if total == 0 { return ["No photos were analysed."] }
        if total < 3 {
            out.append("Only \(total) reference photo(s): any pattern is tentative. Three to five photos give a more reliable profile.")
        }
        if analyzed < total {
            out.append("\(total - analyzed) of \(total) photo(s) could not be analysed and are excluded.")
        }
        for kind in CharacteristicKind.allCases {
            guard let c = coverage[kind] else { continue }
            if c.determinedCount == 0 {
                out.append("\(title(of: kind)) could not be determined for any photo, so no pattern is reported.")
            } else if c.determinedCount < total {
                out.append("\(title(of: kind)) was determined for \(c.determinedCount) of \(total) photos. The others are left out, not counted against any category.")
            }
            if c.lowQualityDeterminedCount > 0 {
                out.append("\(title(of: kind)): \(c.lowQualityDeterminedCount) result(s) rest on low-quality evidence.")
            }
        }
        if (coverage[.cameraAngle]?.determinedCount ?? 0) < total {
            out.append("Camera angle needs a measurable horizon next to a visible person; many photos do not offer one.")
        }
        out.append("Depth values are relative within each photo and are not distances.")
        return out
    }

    // MARK: Names (neutral wording for summaries; the UI has its own labels)

    private static func title(of kind: CharacteristicKind) -> String {
        switch kind {
        case .cameraAngle: return "Camera angle"
        case .subjectFraming: return "Subject framing"
        case .subjectPositioning: return "Subject positioning"
        case .environmentalDepth: return "Environmental depth"
        }
    }

    private static func name(of c: CameraAngleCategory) -> String {
        switch c {
        case .lowAngle: return "Low angle"
        case .eyeLevel: return "Eye level"
        case .highAngle: return "High angle"
        case .unknown: return "Unknown"
        }
    }

    private static func name(of c: FramingCategory) -> String {
        switch c {
        case .fullBody: return "Full body"
        case .halfBody: return "Half body"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }

    private static func name(of c: DepthStructure) -> String {
        switch c {
        case .separated: return "Separated from background"
        case .layered: return "Layered"
        case .foregroundDominant: return "Foreground dominant"
        case .blended: return "Blended with surroundings"
        case .partialSeparation: return "Partial separation"
        case .unknown: return "Unknown"
        }
    }
}
