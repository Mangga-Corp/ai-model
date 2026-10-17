import Foundation
import CoreGraphics

/// Feature D: how the person and the environmental elements are placed and
/// scaled in the frame.
///
/// REUSE. The person's box, centre, zones and area come from the existing
/// `SubjectPositioningResult` unchanged, so Subject Positioning and this feature
/// can never disagree. This adds the DETR person MASK (provenance kept
/// separate from Vision's box) and the environmental measurements.
///
/// COORDINATES. Everything is `ImageSpace`: normalised, top-left origin, upright
/// image. A segmentation cell maps to the same normalised position in the photo
/// because the model sees the whole frame stretched, never cropped.
///
/// MEASURES vs INTERPRETATIONS. Boxes, centres, areas and ratios are measured.
/// Bands and descriptors are interpretations with the thresholds below. A value
/// within a margin of a threshold is marked borderline rather than forced
/// into a firm label.
///
///   Subject scale (person BOX area)     small < 10%   moderate   large >= 35%   (margin 15% of the cut)
///   Horizontal offset (|centre - 0.5|)  centered < 0.06   slight   off-centre >= 0.14   (margin 0.02)
///   Environment prominence              top dominant element's area / subject's area:
///                                       subject dominates < 0.7   balanced   environment dominates >= 2.0
///   Architecture major                  architecture group >= 20% of the image (firm from 30%)
///   Vegetation near edges               vegetation >= 5% of the image, touching the frame edge, with its
///                                       share in the outer 15% band at least 1.4x what an even spread
///                                       would give (firm from 1.6x). The band holds 51% of the frame, so
///                                       a region spread evenly scores 1.0x and is never "near the edges".
nonisolated enum CompositionMeasurer {

    static let smallScaleCut = 0.10
    static let largeScaleCut = 0.35
    static let scaleMargin = 0.15
    static let centeredCut = 0.06
    static let offCenterCut = 0.14
    static let offsetMargin = 0.02
    static let subjectDominatesCut = 0.7
    static let environmentDominatesCut = 2.0
    static let prominenceMargin = 0.15
    static let architectureMajorMinimum = 0.20
    static let architectureMajorFirm = 0.30
    static let edgeVegetationMinimumArea = 0.05
    /// Area of the outer border band as a share of the frame (the band is 15% deep on every side).
    static let borderBandAreaFraction = 1 - (1 - 2 * SegmentationRegionAnalyzer.borderBand) * (1 - 2 * SegmentationRegionAnalyzer.borderBand)
    static let edgeVegetationMinimumConcentration = 1.4
    static let edgeVegetationFirmConcentration = 1.6
    static let maximumElements = 12

    static func measure(positioning: SubjectPositioningResult,
                        segmentation: ObjectSegmentationResult,
                        elements: DominantElementsResult) -> CompositionResult {

        // Subject.
        var subject: SubjectCompositionMeasurement?
        if positioning.isMeasurementValid, let box = positioning.subjectBox, let center = positioning.center,
           let width = positioning.normalizedWidth, let height = positioning.normalizedHeight,
           let area = positioning.normalizedArea, let h = positioning.horizontal, let v = positioning.vertical {
            let mask = segmentation.human
            subject = SubjectCompositionMeasurement(
                box: box, center: center, horizontal: h, vertical: v,
                widthRatio: width, heightRatio: height, boxAreaRatio: area,
                maskAreaRatio: (mask?.isValid ?? false) ? mask?.maskAreaFraction : nil,
                maskMayIncludeOtherPeople: mask?.mayIncludeOtherPeople ?? false)
        }

        // Environmental elements.
        let humanMask = (segmentation.human?.isValid ?? false) ? segmentation.human?.maskAreaFraction : nil
        let measurements: [ElementMeasurement] = segmentation.environmentalRegions.prefix(maximumElements).compactMap { region in
            guard let g = region.geometry else { return nil }
            var relative: RelativeScale?
            if let humanMask, humanMask > 0 {
                relative = RelativeScale(ratio: region.areaFraction / humanMask, basis: .maskToMask)
            } else if let subject, subject.boxAreaRatio > 0 {
                relative = RelativeScale(ratio: g.boundingBoxArea / subject.boxAreaRatio, basis: .boxToBox)
            }
            return ElementMeasurement(
                familyKey: region.family.key, label: region.family.displayName, group: region.family.group,
                kind: region.family.kind, centroid: g.centroid, boundingBox: g.boundingBox,
                boundingBoxCenter: g.boundingBoxCenter, boundingBoxAreaRatio: g.boundingBoxArea,
                maskAreaRatio: region.areaFraction, horizontal: g.horizontal, vertical: g.vertical,
                componentCount: g.componentCount, touchedEdges: g.touchedEdges, relativeToSubject: relative)
        }

        // Bands.
        var scale: Banded<SubjectScaleBand>?
        var offset: Banded<HorizontalOffsetBand>?
        if let subject {
            let relativeMargin: (Double) -> Double = { $0 * scaleMargin }
            scale = band(subject.boxAreaRatio, low: smallScaleCut, high: largeScaleCut,
                         labels: (SubjectScaleBand.small, SubjectScaleBand.moderate, SubjectScaleBand.large),
                         margin: relativeMargin)
            let fixedMargin: (Double) -> Double = { _ in offsetMargin }
            offset = band(abs(Double(subject.center.x) - 0.5), low: centeredCut, high: offCenterCut,
                          labels: (HorizontalOffsetBand.centered, HorizontalOffsetBand.slightlyOff, HorizontalOffsetBand.offCenter),
                          margin: fixedMargin)
        }
        var prominence: Banded<ProminenceBand>?
        var prominenceElement: ElementMeasurement?
        if elements.outcome == .identified, let top = elements.dominant.first,
           let m = measurements.first(where: { $0.familyKey == top.familyKey }), let rel = m.relativeToSubject {
            let relativeMargin: (Double) -> Double = { $0 * prominenceMargin }
            prominence = band(rel.ratio, low: subjectDominatesCut, high: environmentDominatesCut,
                              labels: (ProminenceBand.subjectDominates, ProminenceBand.balanced, ProminenceBand.environmentDominates),
                              margin: relativeMargin)
            prominenceElement = m
        }

        // Descriptors.
        var descriptors: [CompositionDescriptor] = []
        if let subject, let scale {
            let basis = String(format: "person box covers %.1f%% of the image (small below %.0f%%, large from %.0f%%)",
                               subject.boxAreaRatio * 100, smallScaleCut * 100, largeScaleCut * 100)
            switch scale.band {
            case .small:
                descriptors.append(CompositionDescriptor(
                    kind: .subjectSmallInFrame, statement: "The subject occupies a relatively small portion of the frame.",
                    isBorderline: scale.isNearBoundary, basis: [basis]))
            case .large:
                descriptors.append(CompositionDescriptor(
                    kind: .subjectLargeInFrame, statement: "The subject fills a large portion of the frame.",
                    isBorderline: scale.isNearBoundary, basis: [basis]))
            case .moderate:
                break
            }
        }
        if let subject, let offset {
            let dx = Double(subject.center.x) - 0.5
            let basis = String(format: "box centre is %.0f%% of the width from the middle (centred below %.0f%%, off-centre from %.0f%%)",
                               abs(dx) * 100, centeredCut * 100, offCenterCut * 100)
            switch offset.band {
            case .offCenter:
                descriptors.append(CompositionDescriptor(
                    kind: .subjectOffCenter,
                    statement: "The subject is positioned off-center, toward the \(dx < 0 ? "left" : "right").",
                    isBorderline: offset.isNearBoundary, basis: [basis]))
            case .centered:
                descriptors.append(CompositionDescriptor(
                    kind: .subjectCentered, statement: "The subject is centered horizontally.",
                    isBorderline: offset.isNearBoundary, basis: [basis]))
            case .slightlyOff:
                break
            }
        }
        if let prominence, let prominenceElement, let rel = prominenceElement.relativeToSubject {
            let basis = String(format: "%@ is %.1f× the subject's area (%@; subject dominates below %.1f, environment from %.1f)",
                               prominenceElement.label, rel.ratio,
                               rel.basis == .maskToMask ? "mask to mask" : "box to box",
                               subjectDominatesCut, environmentDominatesCut)
            switch prominence.band {
            case .environmentDominates:
                descriptors.append(CompositionDescriptor(
                    kind: .environmentProminent,
                    statement: "Environmental context is visually prominent relative to the subject.",
                    isBorderline: prominence.isNearBoundary, basis: [basis]))
            case .subjectDominates:
                descriptors.append(CompositionDescriptor(
                    kind: .subjectDominatesFrame,
                    statement: "The subject is visually larger than the dominant environmental element.",
                    isBorderline: prominence.isNearBoundary, basis: [basis]))
            case .balanced:
                break
            }
        }

        let architecture = segmentation.environmentalRegions.filter { $0.family.group == .architecture }
        let architectureArea = architecture.reduce(0) { $0 + $1.areaFraction }
        if architectureArea >= architectureMajorMinimum {
            descriptors.append(CompositionDescriptor(
                kind: .architectureMajor,
                statement: "Architecture is a major environmental element.",
                isBorderline: architectureArea < architectureMajorFirm,
                basis: [String(format: "buildings and structures cover %.0f%% of the image (major from %.0f%%, firm from %.0f%%)",
                               architectureArea * 100, architectureMajorMinimum * 100, architectureMajorFirm * 100)]))
        }

        let vegetation = segmentation.environmentalRegions.filter { $0.family.group == .vegetation }
        let vegetationArea = vegetation.reduce(0) { $0 + $1.areaFraction }
        if vegetationArea >= edgeVegetationMinimumArea {
            let pixels = vegetation.reduce(0.0) { $0 + Double($1.pixelCount) }
            let border = vegetation.reduce(0.0) { $0 + ($1.geometry?.borderBandShare ?? 0) * Double($1.pixelCount) } / max(1, pixels)
            let touches = vegetation.contains { !($0.geometry?.touchedEdges.isEmpty ?? true) }
            let concentration = border / borderBandAreaFraction
            if concentration >= edgeVegetationMinimumConcentration && touches {
                descriptors.append(CompositionDescriptor(
                    kind: .vegetationNearEdges, statement: "Vegetation appears near the frame edges.",
                    isBorderline: concentration < edgeVegetationFirmConcentration,
                    basis: [String(format: "%.0f%% of the vegetation (%.0f%% of the image) lies in the outer band, which holds %.0f%% of the frame: %.1f× an even spread (near the edges from %.1f×)",
                                   border * 100, vegetationArea * 100, borderBandAreaFraction * 100, concentration,
                                   edgeVegetationMinimumConcentration)]))
            }
        }

        // Assessment.
        var limitations = [
            "The person's box is the detector's estimate of their extent and overstates the silhouette, so scale bands use a box and not a mask.",
            "Environmental regions are combined semantic classes: their box, centre and area describe the whole class, not one object.",
            "Bands and descriptors are interpretations of the measurements using the stated thresholds; values near a threshold are marked borderline.",
        ]
        if subject?.maskMayIncludeOtherPeople == true {
            limitations.append("Another person overlaps the subject's box, so the person mask may include them.")
        }
        if let human = segmentation.human, !human.isValid, subject != nil, let reason = human.invalidReason {
            limitations.append("No valid person mask (\(reason)); element sizes are compared with the person's box instead.")
        }
        switch segmentation.availability {
        case .unavailable(let reason), .invalid(let reason):
            limitations.append("Environmental measurements are unavailable: \(reason)")
        default: break
        }

        var evidence: [EvidenceReference] = []
        if let subject {
            evidence.append(EvidenceReference(
                source: .visionHumanRectangles, origin: .rawModelOutput, role: .primary, label: "Person box",
                value: String(format: "x %.3f, y %.3f, w %.3f, h %.3f", subject.box.minX, subject.box.minY, subject.box.width, subject.box.height)))
            if let mask = subject.maskAreaRatio {
                evidence.append(EvidenceReference(
                    source: .detrSegmentation, origin: .derivedMeasurement, role: .supporting, label: "Person mask",
                    value: String(format: "%.1f%% of the image (box: %.1f%%)", mask * 100, subject.boxAreaRatio * 100)))
            }
        }
        for m in measurements.prefix(3) {
            evidence.append(EvidenceReference(
                source: .detrSegmentation, origin: .derivedMeasurement, role: .supporting, label: "\(m.label) region",
                value: String(format: "centre (%.2f, %.2f), box %.1f%% of image, mask %.1f%%, %d piece(s)",
                              m.centroid.x, m.centroid.y, m.boundingBoxAreaRatio * 100, m.maskAreaRatio * 100, m.componentCount)))
        }
        for d in descriptors {
            evidence.append(EvidenceReference(source: nil, origin: .interpretation, role: .primary,
                                              label: d.statement, value: d.basis.joined(separator: "; ")))
        }

        // Status.
        let assessment: Assessment
        if let subject {
            var explanation = String(format: "The subject's box covers %.1f%% of the frame, centred %.0f%% from the left and %.0f%% from the top.",
                                     subject.boxAreaRatio * 100, subject.center.x * 100, subject.center.y * 100)
            if !descriptors.isEmpty {
                explanation += " " + descriptors.map { $0.isBorderline ? $0.statement.replacingOccurrences(of: ".", with: " (borderline).") : $0.statement }.joined(separator: " ")
            }
            if measurements.isEmpty { explanation += " No environmental region could be measured." }
            else { explanation += " \(measurements.count) environmental region\(measurements.count == 1 ? "" : "s") measured." }
            assessment = Assessment(status: .determined, quality: positioning.assessment.quality, explanation: explanation,
                                    evidence: evidence, limitations: limitations)
        } else if !measurements.isEmpty {
            assessment = Assessment(
                status: .insufficientEvidence, quality: .none,
                explanation: "No main person was measured, so scale and offset are not assessed. \(measurements.count) environmental region\(measurements.count == 1 ? "" : "s") could still be measured.",
                evidence: evidence, limitations: limitations)
        } else if !segmentation.availability.hasValidOutput {
            assessment = .unavailable("Neither the subject nor the environment could be measured.", evidence: evidence, limitations: limitations)
        } else {
            assessment = .insufficient("Nothing could be measured: no main person and no environmental region large enough.",
                                       evidence: evidence, limitations: limitations)
        }

        return CompositionResult(subject: subject, elements: measurements, descriptors: descriptors,
                                 scale: scale, horizontalOffset: offset, prominence: prominence, assessment: assessment)
    }

    /// Three-way banding that remembers closeness to a cut-off.
    static func band<B: Sendable & Hashable>(_ value: Double, low: Double, high: Double, labels: (B, B, B),
                                             margin: (Double) -> Double) -> Banded<B> {
        let chosen = value < low ? labels.0 : (value < high ? labels.1 : labels.2)
        let near = abs(value - low) <= margin(low) || abs(value - high) <= margin(high)
        return Banded(band: chosen, value: value, isNearBoundary: near)
    }
}
