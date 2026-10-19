import Foundation
import CoreGraphics

/// Characteristic 4: the relative depth structure around the main subject.
///
/// INPUT CONVENTION (verified): Depth Anything output, min-max normalised per
/// image, 0...1, LARGER = NEARER. All numbers below are relative, never metric,
/// and only comparable within one image.
///
/// DECISION METHOD
///
/// Subject region
///   - `personMask`: depth samples inside the subject's box whose DETR class is
///     `person`. Valid when it yields >= 150 samples covering >= 15% of the box.
///     Segmentation is semantic, not instance-level, so the mask can include
///     other people overlapping the box; that is flagged and lowers trust.
///   - `boxCore` (documented fallback, low trust): the central 40% of the
///     subject's box, used only when no valid person mask exists.
///
/// Environment = every sample outside the subject's box (grown 3%) that is not a
/// person pixel. Ring = the band between 3% and 15% around the box.
///
/// Measurements: subject median, environment median, their difference, the
/// share of the environment that is clearly nearer / farther than the subject
/// (margin 0.08), and the ring median and spread.
///
/// Structure (checked in this order)
///   separated          environment farther >= 60%, nearer <= 10%, difference >= 0.15
///   layered            nearer >= 15% AND farther >= 25%
///   foregroundDominant nearer >= 40%
///   blended            |difference| < 0.08 and |ring difference| < 0.10
///   partialSeparation  anything else
///
/// With no subject, only whole-scene depth bands are reported and the structure
/// stays unknown.
nonisolated enum EnvironmentalDepthInterpreter {

    static let sampleStride = 2
    static let nearFarMargin = 0.08
    static let minimumMaskSamples = 150
    static let minimumMaskCoverage = 0.15
    static let minimumBoxCoreSamples = 100
    static let minimumEnvironmentSamples = 200
    static let minimumRingSamples = 100
    static let flatContrast = 0.04

    static func interpret(selection: SubjectSelection,
                          evidence: PhotoEvidence,
                          artifacts: PhotoArtifacts) -> EnvironmentalDepthResult {

        func result(_ structure: DepthStructure, metrics: DepthMetrics? = nil, bands: SceneDepthBands? = nil,
                    _ assessment: Assessment) -> EnvironmentalDepthResult {
            EnvironmentalDepthResult(structure: structure, metrics: metrics, sceneBands: bands, assessment: assessment)
        }

        guard let depth = artifacts.depth else {
            return result(.unknown, .unavailable(
                "The depth model did not produce a usable map, so the depth structure could not be assessed.",
                evidence: [EvidenceReference(source: .depthAnything, origin: .rawModelOutput, role: .limiting,
                                             label: "Depth model", value: evidence.depth.problem ?? "no output")]))
        }

        let bands = sceneBands(depth)
        let convention = EvidenceReference(source: .depthAnything, origin: .rawModelOutput, role: .contextual,
                                           label: "Depth convention", value: DepthSummary.convention)
        let bandsEvidence = EvidenceReference(
            source: .depthAnything, origin: .derivedMeasurement, role: .supporting, label: "Whole-scene depth bands",
            value: String(format: "near %.0f%%, mid %.0f%%, far %.0f%%; bottom - top %+.2f; contrast %.2f",
                          bands.nearFraction * 100, bands.midFraction * 100, bands.farFraction * 100,
                          bands.bottomMinusTop, bands.contrast))

        guard bands.contrast >= flatContrast else {
            return result(.unknown, bands: bands, .insufficient(
                "The depth map is nearly flat, so the relative depth structure is not reliable.",
                evidence: [convention, bandsEvidence]))
        }

        // No subject: whole-scene description only.
        guard let primary = selection.primary else {
            let note = String(format: "Whole scene: %.0f%% near, %.0f%% mid, %.0f%% far.",
                              bands.nearFraction * 100, bands.midFraction * 100, bands.farFraction * 100)
            switch evidence.humans {
            case .nothingDetected:
                return result(.unknown, bands: bands, .notApplicable(
                    "No person was detected, so the subject's depth relative to its surroundings is not computed. " + note,
                    evidence: [convention, bandsEvidence]))
            default:
                return result(.unknown, bands: bands, .insufficient(
                    "There is no usable main subject, so the subject's depth relative to its surroundings is not computed. " + note,
                    evidence: [convention, bandsEvidence]))
            }
        }

        // Subject and environment samples.
        let box = ImageSpace.clamped(primary.box)
        let segmentation = artifacts.segmentation
        let hasPersonClass = segmentation?.personClassIndex != nil

        func isPerson(_ p: CGPoint) -> Bool { hasPersonClass && (segmentation?.isPerson(atNormalized: p) ?? false) }

        let growth3 = ImageSpace.expanded(box, by: 0.03)
        let growth15 = ImageSpace.expanded(box, by: 0.15)
        let core = ImageSpace.core(of: box, fraction: 0.4)

        var inBox: [(value: Float, person: Bool)] = []
        var coreValues: [Float] = []
        var environment: [Float] = []
        var ring: [Float] = []

        var y = 0
        while y < depth.height {
            var x = 0
            while x < depth.width {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(depth.width),
                                y: (CGFloat(y) + 0.5) / CGFloat(depth.height))
                let value = depth.nearness[y * depth.width + x]
                if box.contains(p) {
                    inBox.append((value, isPerson(p)))
                    if core.contains(p) { coreValues.append(value) }
                } else if !growth3.contains(p) && !isPerson(p) {
                    environment.append(value)
                    if growth15.contains(p) { ring.append(value) }
                }
                x += sampleStride
            }
            y += sampleStride
        }

        let personValues = inBox.filter(\.person).map(\.value)
        let maskCoverage = inBox.isEmpty ? 0 : Double(personValues.count) / Double(inBox.count)
        let maskValid = hasPersonClass && personValues.count >= minimumMaskSamples && maskCoverage >= minimumMaskCoverage

        let method: SubjectRegionMethod
        let subjectValues: [Float]
        if maskValid {
            method = .personMask; subjectValues = personValues
        } else {
            method = .boxCore; subjectValues = coreValues
        }

        guard subjectValues.count >= (maskValid ? minimumMaskSamples : minimumBoxCoreSamples),
              environment.count >= minimumEnvironmentSamples else {
            return result(.unknown, bands: bands, .insufficient(
                "The subject fills so much of the frame (or is so small) that there are too few surrounding samples to compare its depth with its environment.",
                evidence: [convention, bandsEvidence],
                limitations: ["Needs enough subject and surrounding pixels at the depth map's resolution."]))
        }

        // Any other detected person (even a low-confidence one) overlapping the
        // box could be inside the merged person mask.
        let overlapsOthers = selection.otherDetections.contains { other in
            guard other.confidence >= 0.10 else { return false }
            let overlap = ImageSpace.intersectionArea(other.box, box)
            return overlap / max(1e-9, min(ImageSpace.area(other.box), ImageSpace.area(box))) > 0.10
        }

        // Statistics.
        let subjectMedian = Double(median(subjectValues))
        let subjectSpread = Double(spread(subjectValues))
        let environmentMedian = Double(median(environment))
        let difference = subjectMedian - environmentMedian
        let nearer = fraction(environment) { Double($0) > subjectMedian + nearFarMargin }
        let farther = fraction(environment) { Double($0) < subjectMedian - nearFarMargin }
        let similar = max(0, 1 - nearer - farther)
        let ringMedian: Double? = ring.count >= minimumRingSamples ? Double(median(ring)) : nil
        let ringSpread: Double? = ring.count >= minimumRingSamples ? Double(spread(ring)) : nil
        let ringDifference = ringMedian.map { subjectMedian - $0 }

        let metrics = DepthMetrics(
            subjectRegionMethod: method,
            subjectSampleCount: subjectValues.count, environmentSampleCount: environment.count,
            maskCoverageOfBox: hasPersonClass ? maskCoverage : nil,
            maskMayIncludeOtherPeople: method == .personMask && overlapsOthers,
            subjectMedian: subjectMedian, subjectSpread: subjectSpread,
            environmentMedian: environmentMedian, subjectMinusEnvironment: difference,
            fractionEnvironmentNearer: nearer, fractionEnvironmentFarther: farther,
            fractionEnvironmentSimilar: similar,
            ringMedian: ringMedian, ringSpread: ringSpread, subjectMinusRing: ringDifference)

        // Structure.
        let structure: DepthStructure
        if farther >= 0.60 && nearer <= 0.10 && difference >= 0.15 {
            structure = .separated
        } else if nearer >= 0.15 && farther >= 0.25 {
            structure = .layered
        } else if nearer >= 0.40 {
            structure = .foregroundDominant
        } else if abs(difference) < 0.08 && (ringDifference.map { abs($0) < 0.10 } ?? true) {
            structure = .blended
        } else {
            structure = .partialSeparation
        }

        // Quality.
        var quality: EvidenceQuality = method == .personMask ? .high : .low
        var limitations: [String] = [
            "Depth is relative and normalised per image; it is not a distance in metres.",
            "The photo is stretched to the depth model's 518x392 input, which distorts proportions."
        ]
        if method == .boxCore {
            limitations.append("No reliable person mask was available, so the subject's depth comes from the central part of its box.")
        }
        if metrics.maskMayIncludeOtherPeople {
            quality = quality.lowered()
            limitations.append("Another person overlaps the subject's box, so the person mask may include them.")
        }
        if method == .personMask && maskCoverage < 0.30 {
            quality = quality.lowered()
            limitations.append("The person mask covers little of the subject's box.")
        }
        if selection.info.isAmbiguous {
            quality = quality.lowered()
            limitations.append("The choice of main subject is ambiguous.")
        }
        if bands.contrast < 0.10 {
            quality = quality.lowered()
            limitations.append("The depth map has low contrast.")
        }
        if subjectValues.count < 400 || environment.count < 400 {
            quality = quality.lowered()
            limitations.append("Few depth samples were available.")
        }

        let evidenceRefs = [
            convention,
            EvidenceReference(source: .depthAnything, origin: .derivedMeasurement, role: .primary, label: "Subject depth",
                              value: String(format: "median %.2f (spread %.2f) from %d samples via %@", subjectMedian, subjectSpread,
                                            subjectValues.count, method == .personMask ? "person mask" : "box core")),
            EvidenceReference(source: .depthAnything, origin: .derivedMeasurement, role: .primary, label: "Environment depth",
                              value: String(format: "median %.2f from %d samples; nearer %.0f%%, similar %.0f%%, farther %.0f%%",
                                            environmentMedian, environment.count, nearer * 100, similar * 100, farther * 100)),
            EvidenceReference(source: .depthAnything, origin: .derivedMeasurement, role: .supporting, label: "Subject minus environment",
                              value: String(format: "%+.2f", difference)),
            bandsEvidence,
            EvidenceReference(source: nil, origin: .interpretation, role: .primary, label: "Depth structure", value: structure.rawValue)
        ] + (maskValid ? [EvidenceReference(
                source: .detrSegmentation, origin: .derivedMeasurement, role: .primary, label: "Person mask",
                value: String(format: "%.0f%% of the subject box", maskCoverage * 100))] : [])

        let explanation: String
        switch structure {
        case .separated:
            explanation = String(format: "The subject is clearly nearer than most of its surroundings (%.0f%% of the environment is farther), giving strong separation from the background.", farther * 100)
        case .layered:
            explanation = String(format: "There are elements both in front of (%.0f%%) and behind (%.0f%%) the subject, giving the scene distinct foreground and background layers.", nearer * 100, farther * 100)
        case .foregroundDominant:
            explanation = String(format: "%.0f%% of the surroundings is nearer than the subject, so the subject sits behind much of the scene.", nearer * 100)
        case .blended:
            explanation = "The subject and its surroundings sit at similar relative depth, so there is little depth separation."
        default:
            explanation = String(format: "The subject is somewhat nearer than its surroundings (difference %+.2f) without a clear layered or separated structure.", difference)
        }

        return result(structure, metrics: metrics, bands: bands,
                      Assessment(status: .determined, quality: quality, explanation: explanation,
                                 evidence: evidenceRefs, limitations: limitations))
    }

    // MARK: Scene bands

    static func sceneBands(_ depth: DepthGrid) -> SceneDepthBands {
        let n = Double(depth.nearness.count)
        var near = 0, mid = 0, far = 0
        var sum = 0.0, sumSquares = 0.0
        for v in depth.nearness {
            let d = Double(v)
            sum += d; sumSquares += d * d
            if d >= 2.0 / 3.0 { near += 1 } else if d >= 1.0 / 3.0 { mid += 1 } else { far += 1 }
        }
        let mean = sum / n
        let contrast = max(0, sumSquares / n - mean * mean).squareRoot()

        func rowMean(_ rows: Range<Int>) -> Double {
            guard !rows.isEmpty else { return 0 }
            var total = 0.0
            for y in rows { for x in 0..<depth.width { total += Double(depth.nearness[y * depth.width + x]) } }
            return total / Double(rows.count * depth.width)
        }
        let third = max(1, depth.height / 3)
        let bottomMinusTop = rowMean((depth.height - third)..<depth.height) - rowMean(0..<third)
        return SceneDepthBands(nearFraction: Double(near) / n, midFraction: Double(mid) / n,
                               farFraction: Double(far) / n, bottomMinusTop: bottomMinusTop, contrast: contrast)
    }

    // MARK: Statistics

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// Interquartile range.
    private static func spread(_ values: [Float]) -> Float {
        guard values.count >= 4 else { return 0 }
        let s = values.sorted()
        return s[(s.count * 3) / 4] - s[s.count / 4]
    }

    private static func fraction(_ values: [Float], where predicate: (Float) -> Bool) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter(predicate).count) / Double(values.count)
    }
}
