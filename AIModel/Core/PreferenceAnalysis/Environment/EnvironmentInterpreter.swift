import Foundation
import CoreGraphics

/// Object and Environment Analysis for one photo.
///
/// Consumes ONLY evidence the pipeline already produced: the cached DETR class
/// map and Depth Anything map (`PhotoArtifacts`), FastViT's labels and the
/// existing subject selection and positioning. It runs no model, so opening or
/// expanding a result never triggers inference.
///
/// Each stage fails independently. If segmentation is missing, the person's
/// position and scale (from Vision) are still reported and every environmental
/// result says it is unavailable, never empty.
///
/// Conceptual flow:
///   cached DETR map ─▶ SegmentationRegionAnalyzer ─▶ ObjectSegmentationResult (A)
///                                                  ├─▶ EnvironmentElementRanker ─▶ (B)
///                                                  ├─▶ SceneContextInterpreter  ─▶ (C) (+ FastViT labels)
///                                                  └─▶ CompositionMeasurer      ─▶ (D) (+ Vision subject)
nonisolated enum EnvironmentInterpreter {

    static func interpret(selection: SubjectSelection,
                          evidence: PhotoEvidence,
                          artifacts: PhotoArtifacts,
                          positioning: SubjectPositioningResult) -> EnvironmentAnalysisResult {

        let depthTrusted = artifacts.depth != nil
            && (evidence.depth.value?.contrast ?? 0) >= EnvironmentalDepthInterpreter.flatContrast

        let segmentation = buildSegmentation(selection: selection, evidence: evidence, artifacts: artifacts,
                                             depth: depthTrusted ? artifacts.depth : nil)

        let elements = EnvironmentElementRanker.rank(
            segmentation,
            context: .init(subjectPresent: selection.primary != nil,
                           subjectAmbiguous: selection.info.isAmbiguous,
                           depthTrusted: depthTrusted))
        let scene = SceneContextInterpreter.interpret(segmentation, classifier: evidence.sceneContext)
        let composition = CompositionMeasurer.measure(positioning: positioning, segmentation: segmentation, elements: elements)

        return EnvironmentAnalysisResult(segmentation: segmentation, elements: elements, scene: scene, composition: composition)
    }

    /// Result for a photo that could not be read at all.
    static func unavailable(_ reason: String) -> EnvironmentAnalysisResult {
        let segmentation = ObjectSegmentationResult.unavailable(reason)
        let assessment = Assessment.unavailable("This photo could not be analysed: \(reason)")
        return EnvironmentAnalysisResult(
            segmentation: segmentation,
            elements: DominantElementsResult(outcome: .unavailable, candidates: [], assessment: assessment),
            scene: SceneContextResult(primary: .unknown, primaryStrength: 0, secondary: [], setting: .undetermined,
                                      settingReasons: [], character: .undetermined, builtShare: nil, observedCues: [],
                                      classifierHints: [], isAmbiguous: false, assessment: assessment),
            composition: CompositionResult(subject: nil, elements: [], descriptors: [], scale: nil,
                                           horizontalOffset: nil, prominence: nil, assessment: assessment))
    }

    // MARK: A. Segmentation

    private static func buildSegmentation(selection: SubjectSelection,
                                          evidence: PhotoEvidence,
                                          artifacts: PhotoArtifacts,
                                          depth: DepthGrid?) -> ObjectSegmentationResult {
        guard let grid = artifacts.segmentation else {
            return .unavailable(evidence.segmentation.problem ?? "no class map was produced")
        }

        var subject: SubjectRegionContext?
        if let primary = selection.primary {
            subject = SubjectRegionContext(
                box: ImageSpace.clamped(primary.box),
                otherBoxes: selection.otherDetections.filter { $0.confidence >= 0.10 }.map(\.box))
        }

        let analysis = SegmentationRegionAnalyzer.analyze(grid, depth: depth, subject: subject)
        if let problem = analysis.problem { return .unavailable(problem, invalid: true) }

        let valid = analysis.regions.filter(\.isValid)
        let environmental = valid.filter { $0.family.group.isEnvironmental }
        let availability: SegmentationAvailability = environmental.isEmpty ? .noEnvironmentalRegions : .available

        // Quality reflects how much of the scene the supported labels explain.
        var quality: EvidenceQuality
        if analysis.environmentFraction >= 0.30 && analysis.unsupportedFraction <= 0.05 { quality = .high }
        else if analysis.environmentFraction >= 0.15 && analysis.unsupportedFraction <= 0.25 { quality = .moderate }
        else { quality = .low }
        if analysis.unsupportedFraction > 0.25 { quality = quality.lowered() }

        func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

        var limitations = [
            ObjectSegmentationResult.semanticNote,
            "The model gives one class per pixel and no confidence, so there is no model probability for any region; quality grades here only reflect how much of the scene is explained.",
            "The photo is stretched to the model's input size; positions and area shares are preserved, aspect ratio is not.",
        ]
        if analysis.unsupportedFraction > 0.05 {
            limitations.append("\(pct(analysis.unsupportedFraction)) of pixels have labels outside the supported set and are not part of any region.")
        }
        let tooSmall = analysis.regions.filter { !$0.isValid }
        if !tooSmall.isEmpty {
            limitations.append("\(tooSmall.count) region(s) are too small to measure reliably and were left out of the measurements.")
        }
        if let human = analysis.human, !human.isValid, let reason = human.invalidReason {
            limitations.append("No valid person mask: \(reason).")
        }

        var evidenceRefs = [
            EvidenceReference(source: .detrSegmentation, origin: .rawModelOutput, role: .primary, label: "Class map",
                              value: "\(analysis.gridWidth) × \(analysis.gridHeight) cells, person (all people merged) \(pct(analysis.allPeopleFraction))"),
        ]
        evidenceRefs += valid.prefix(5).map { r in
            EvidenceReference(source: .detrSegmentation, origin: .derivedMeasurement, role: .supporting,
                              label: "\(r.family.displayName) region",
                              value: "\(pct(r.areaFraction)) of the image; \(r.rawLabels.map(\.label).joined(separator: ", "))")
        }

        var explanation: String
        switch availability {
        case .available:
            let top = environmental.prefix(4).map { "\($0.family.displayName) \(pct($0.areaFraction))" }.joined(separator: ", ")
            explanation = "Segmentation found \(environmental.count) environmental region\(environmental.count == 1 ? "" : "s") covering \(pct(analysis.environmentFraction)) of the image besides the person. Largest: \(top)."
            let carried = valid.count - environmental.count
            if carried > 0 {
                explanation += " \(carried) more region\(carried == 1 ? " is" : "s are") something the person carries or wears, and is not counted as surroundings."
            }
        default:
            explanation = "Segmentation ran successfully but found no supported environmental region large enough to measure. This is a genuine empty result, not a missing one."
        }

        return ObjectSegmentationResult(
            availability: availability, gridWidth: analysis.gridWidth, gridHeight: analysis.gridHeight,
            regions: analysis.regions, allPeopleFraction: analysis.allPeopleFraction, human: analysis.human,
            environmentFraction: analysis.environmentFraction, unsupportedFraction: analysis.unsupportedFraction,
            unsupportedLabels: analysis.unsupportedLabels,
            assessment: Assessment(status: .determined, quality: quality, explanation: explanation,
                                   evidence: evidenceRefs, limitations: limitations))
    }
}
