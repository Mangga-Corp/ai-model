import Foundation
import CoreGraphics

/// Feature B: ranks the environmental regions that matter most to the portrait.
///
/// The person is the primary subject and never a candidate. Regions are
/// ranked on a transparent weighted score so size alone cannot decide:
///
///   Extent       40%  area / 30% of the image, capped at 1
///   Adjacency    25%  share of the band around the person the region fills
///                     (full marks at 50%); needs a detected person
///   Coherence    20%  share of the region that is one connected piece
///   Depth        15%  median relative nearness (nearer = more prominent);
///                     needs a trustworthy depth map
///
/// A term whose evidence is unavailable is dropped and the remaining weights
/// are renormalised, and the result says so. The score is a heuristic ranking
/// value in 0...1. It is not a probability and not visual saliency.
///
/// Roles
///   candidate   valid mask in the surroundings (not a person, not something
///               the person carries or wears), area >= 2% of the image
///   dominant    score >= 0.45 and moderate-or-better support; a second element
///               is co-dominant only if within 0.05 of the first (at most two)
///   secondary   score >= 0.25
///   uncertain   anything else, including strong scores with weak support
/// With no region reaching `dominant`, no dominant element is reported.
///
/// FastViT's whole-image label is never used here.
nonisolated enum EnvironmentElementRanker {

    static let extentSaturation = 0.30
    static let adjacencySaturation = 0.50
    /// Regions smaller than this are measured but not ranked: at this size the
    /// model's labels are often wrong (a stray "donut" or "knife"), and a
    /// speck of the frame cannot shape a composition.
    static let candidateFloor = 0.02
    static let dominantMinimumScore = 0.45
    static let secondaryMinimumScore = 0.25
    static let coDominantGap = 0.05
    static let weightExtent = 0.40
    static let weightAdjacency = 0.25
    static let weightCoherence = 0.20
    static let weightDepth = 0.15

    struct Context {
        let subjectPresent: Bool
        let subjectAmbiguous: Bool
        let depthTrusted: Bool
    }

    static let method = "Candidates are ranked by extent (40%), adjacency to the person (25%), coherence (20%) and relative depth (15%). Unavailable terms are dropped and the rest renormalised. This is a transparent heuristic, not a visual-saliency model."

    static func rank(_ segmentation: ObjectSegmentationResult, context: Context) -> DominantElementsResult {
        switch segmentation.availability {
        case .unavailable, .invalid:
            return DominantElementsResult(
                outcome: .unavailable, candidates: [],
                assessment: .unavailable("Environmental elements could not be ranked because segmentation is unavailable.",
                                         limitations: [ObjectSegmentationResult.semanticNote]))
        case .available, .noEnvironmentalRegions:
            break
        }

        let pool = segmentation.environmentalRegions.filter { $0.areaFraction >= candidateFloor }
        guard !pool.isEmpty else {
            let why = segmentation.availability == .noEnvironmentalRegions
                ? "The segmentation ran successfully and found no supported environmental region besides the person."
                : "The segmentation found environmental regions, but none covers the 2% of the image needed to be ranked."
            return DominantElementsResult(
                outcome: .noEnvironmentalRegions, candidates: [],
                assessment: .insufficient(why, limitations: [ObjectSegmentationResult.semanticNote]))
        }

        var scored = pool.map { score($0, context: context, unsupported: segmentation.unsupportedFraction) }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.region.areaFraction != $1.region.areaFraction { return $0.region.areaFraction > $1.region.areaFraction }
            return $0.region.family.key < $1.region.family.key
        }

        // Roles.
        var dominantKeys: [String] = []
        var firstDominantScore = 0.0
        for s in scored where s.score >= dominantMinimumScore && s.quality >= .moderate {
            if dominantKeys.isEmpty {
                dominantKeys.append(s.region.family.key)
                firstDominantScore = s.score
            } else if dominantKeys.count < 2 && firstDominantScore - s.score <= coDominantGap {
                dominantKeys.append(s.region.family.key)
            }
        }

        let candidates: [ElementCandidate] = scored.enumerated().map { index, s in
            let role: ElementRole
            var uncertainty = s.uncertainty
            if dominantKeys.contains(s.region.family.key) {
                role = .dominant
            } else if s.score >= dominantMinimumScore && s.quality < .moderate {
                role = .uncertain
                uncertainty.append("The score would qualify as dominant, but the segmentation support for this region is weak.")
            } else if s.score >= secondaryMinimumScore {
                role = .secondary
            } else {
                role = .uncertain
            }
            let geometry = s.region.geometry!
            return ElementCandidate(
                rank: index + 1, familyKey: s.region.family.key, label: s.region.family.displayName,
                group: s.region.family.group, kind: s.region.family.kind, role: role, score: s.score,
                components: s.components, areaFraction: s.region.areaFraction, centroid: geometry.centroid,
                horizontal: geometry.horizontal, vertical: geometry.vertical, quality: s.quality,
                rationale: s.rationale, uncertainty: uncertainty, evidence: s.evidence)
        }

        let dominant = candidates.filter { $0.role == .dominant }
        var limitations = [method, ObjectSegmentationResult.semanticNote]
        if !context.subjectPresent {
            limitations.append("No main person was detected, so adjacency to the person was not used.")
        } else if context.subjectAmbiguous {
            limitations.append("The main subject is ambiguous, so adjacency to the person is less reliable.")
        }
        if !context.depthTrusted { limitations.append("Relative depth was unavailable or too flat to use, so depth was not part of the ranking.") }
        if segmentation.unsupportedFraction > 0.25 {
            limitations.append(String(format: "%.0f%% of the image has labels outside the supported set, so the ranking sees only part of the scene.",
                                      segmentation.unsupportedFraction * 100))
        }

        let summary = EvidenceReference(
            source: nil, origin: .interpretation, role: .primary, label: "Ranking",
            value: candidates.prefix(4).map { "\($0.label) \(String(format: "%.2f", $0.score)) (\($0.role.rawValue))" }.joined(separator: "; "))
        let evidence = [summary] + candidates.prefix(3).flatMap(\.evidence)

        if dominant.isEmpty {
            let top = candidates[0]
            return DominantElementsResult(
                outcome: .noStandoutElement, candidates: candidates,
                assessment: Assessment(
                    status: .insufficientEvidence, quality: .none,
                    explanation: String(format: "No environmental element stands out clearly. The highest-ranked, %@, scores %.2f against the %.2f needed for a dominant role, so no dominant element is reported.",
                                        top.label, top.score, dominantMinimumScore),
                    evidence: evidence, limitations: limitations))
        }

        let names = dominant.map(\.label)
        let nameText = names.count == 1 ? names[0] : names.joined(separator: " and ")
        let first = dominant[0]
        var explanation = "\(nameText) \(names.count == 1 ? "is" : "are") the dominant environmental \(names.count == 1 ? "element" : "elements"). "
        explanation += first.rationale + " The person remains the primary subject; elements are ranked on their own."
        if candidates.count > dominant.count {
            let others = candidates.filter { $0.role != .dominant }.prefix(3).map(\.label).joined(separator: ", ")
            explanation += " Also present: \(others)."
        }

        return DominantElementsResult(
            outcome: .identified, candidates: candidates,
            assessment: Assessment(status: .determined, quality: first.quality, explanation: explanation,
                                   evidence: evidence, limitations: limitations))
    }

    // MARK: Scoring

    private struct Scored {
        let region: SemanticRegion
        let score: Double
        let components: [ScoreComponent]
        let quality: EvidenceQuality
        let rationale: String
        let uncertainty: [String]
        let evidence: [EvidenceReference]
    }

    /// Rounds DOWN, so "almost everything" never prints as 100% while pieces remain.
    private static func wholePercent(_ v: Double) -> String { "\(Int((v * 100).rounded(.down)))%" }

    private static func score(_ region: SemanticRegion, context: Context, unsupported: Double) -> Scored {
        let g = region.geometry!
        let name = region.family.displayName

        let extent = ScoreComponent(
            name: "Extent", value: min(1, region.areaFraction / extentSaturation), weight: weightExtent, used: true,
            note: String(format: "covers %.0f%% of the image", region.areaFraction * 100))

        let adjacencyUsed = context.subjectPresent && region.subjectRelation != nil
        let ring = region.subjectRelation?.ringShare ?? 0
        let adjacency = ScoreComponent(
            name: "Adjacency to the person", value: min(1, ring / adjacencySaturation), weight: weightAdjacency,
            used: adjacencyUsed,
            note: adjacencyUsed ? String(format: "fills %.0f%% of the area around the person", ring * 100)
                                : "no main person, so not used")

        let coherence = ScoreComponent(
            name: "Coherence", value: g.largestComponentShare, weight: weightCoherence, used: true,
            note: g.componentCount == 1 ? "one connected region"
                : "\(wholePercent(g.largestComponentShare)) in its largest of \(g.componentCount) pieces")

        let depthUsed = context.depthTrusted && region.depth != nil
        let nearness = region.depth?.medianNearness ?? 0
        let depth = ScoreComponent(
            name: "Relative depth", value: nearness, weight: weightDepth, used: depthUsed,
            note: depthUsed ? String(format: "relative nearness %.2f (0 far, 1 near)", nearness) : "depth unavailable, so not used")

        let components = [extent, adjacency, coherence, depth]
        let used = components.filter(\.used)
        let totalWeight = used.reduce(0) { $0 + $1.weight }
        let score = used.reduce(0) { $0 + $1.value * $1.weight } / max(1e-9, totalWeight)

        // Quality: how well the segmentation supports this region, never a probability.
        var quality: EvidenceQuality
        if region.areaFraction >= 0.12 && g.largestComponentShare >= 0.70 { quality = .high }
        else if region.areaFraction >= 0.04 && g.largestComponentShare >= 0.40 { quality = .moderate }
        else { quality = .low }
        var uncertainty: [String] = []
        if unsupported > 0.25 {
            quality = quality.lowered()
            uncertainty.append("A large part of the image has unsupported labels.")
        }
        if adjacencyUsed && context.subjectAmbiguous {
            quality = quality.lowered()
            uncertainty.append("The main subject is ambiguous, so adjacency is less reliable.")
        }
        if g.componentCount > 3 && g.largestComponentShare < 0.5 {
            uncertainty.append("The region is scattered across \(g.componentCount) separate pieces.")
        }
        if g.borderBandShare > 0.7 {
            uncertainty.append("Most of the region lies in the outer band of the frame.")
        }
        if !depthUsed { uncertainty.append("No usable depth for this region.") }

        var sentence = String(format: "%@ covers %.0f%% of the image", name, region.areaFraction * 100)
        if g.componentCount == 1 {
            sentence += " as one connected region"
        } else if g.largestComponentShare >= 0.98 {
            sentence += ", almost all of it in one large piece"
        } else {
            sentence += ", \(wholePercent(g.largestComponentShare)) of it in its largest piece"
        }
        if adjacencyUsed { sentence += String(format: ", and fills %.0f%% of the area around the person", ring * 100) }
        if depthUsed { sentence += nearness >= 2.0 / 3.0 ? "; it is among the nearer parts of the scene" : (nearness <= 1.0 / 3.0 ? "; it is among the farther parts of the scene" : "; it sits at a middle depth") }
        sentence += String(format: ". Score %.2f.", score)

        let evidence = [
            EvidenceReference(source: .detrSegmentation, origin: .rawModelOutput, role: .primary, label: "\(name) classes",
                              value: region.rawLabels.map { String(format: "%@ %.1f%%", $0.label, $0.areaFraction * 100) }.joined(separator: ", ")),
            EvidenceReference(source: nil, origin: .derivedMeasurement, role: .primary, label: "\(name) score terms",
                              value: components.map { c in
                                  c.used ? String(format: "%@ %.2f x %.2f", c.name, c.value, c.weight) : "\(c.name) not used"
                              }.joined(separator: "; ")),
        ]

        return Scored(region: region, score: score, components: components, quality: quality,
                      rationale: sentence, uncertainty: uncertainty, evidence: evidence)
    }
}
