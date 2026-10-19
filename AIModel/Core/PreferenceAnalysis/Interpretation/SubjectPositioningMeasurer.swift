import Foundation
import CoreGraphics

/// Characteristic 3: where the primary subject sits and how large it is.
///
/// Pure geometry on the detector's box, in the image space documented in
/// `ImageSpace`. Nothing here is estimated: when there is no valid detection,
/// the result carries no box at all.
nonisolated enum SubjectPositioningMeasurer {

    /// Thirds boundaries split each axis into three zones.
    static let lowerThird = 1.0 / 3.0
    static let upperThird = 2.0 / 3.0

    static func horizontalZone(forCenterX x: Double) -> HorizontalZone {
        x < lowerThird ? .left : (x > upperThird ? .right : .center)
    }

    static func verticalZone(forCenterY y: Double) -> VerticalZone {
        y < lowerThird ? .upper : (y > upperThird ? .lower : .middle)
    }

    static func measure(selection: SubjectSelection, evidence: PhotoEvidence) -> SubjectPositioningResult {
        func empty(_ assessment: Assessment) -> SubjectPositioningResult {
            SubjectPositioningResult(
                subjectBox: nil, upperBodyBox: nil, center: nil,
                normalizedWidth: nil, normalizedHeight: nil, normalizedArea: nil,
                horizontal: nil, vertical: nil, detectionConfidence: nil,
                isMeasurementValid: false, touchedEdges: [],
                selection: selection.info, secondarySubjects: [], assessment: assessment)
        }

        // No usable primary subject: say why, and fabricate nothing.
        guard let primary = selection.primary else {
            switch evidence.humans {
            case .failed(let message), .skipped(let message):
                return empty(.unavailable(
                    "Person detection did not run, so the subject's position could not be measured.",
                    evidence: [humanRunEvidence("Person detection unavailable: \(message)")]))
            case .nothingDetected:
                return empty(.notApplicable(
                    "No person was detected, so there is no subject position to measure.",
                    evidence: [humanRunEvidence("Ran successfully, found no people")]))
            case .produced(let all):
                return empty(.insufficient(
                    "\(all.count) detection(s) were too small or too uncertain to treat as the main subject.",
                    evidence: [humanRunEvidence("\(all.count) detection(s) below the eligibility threshold")],
                    limitations: ["Eligibility: " + SubjectSelectionInfo.policy]))
            }
        }

        let box = ImageSpace.clamped(primary.box)
        let center = CGPoint(x: box.midX, y: box.midY)
        let area = ImageSpace.area(box)
        let horizontal = horizontalZone(forCenterX: Double(center.x))
        let vertical = verticalZone(forCenterY: Double(center.y))
        let edges = ImageSpace.touchedEdges(of: box)
        let ambiguous = selection.info.isAmbiguous

        // Evidence quality from explicit checks, not from the raw probability alone.
        var quality: EvidenceQuality
        if primary.confidence >= 0.70 && area >= 0.04 {
            quality = .high
        } else if primary.confidence >= 0.50 && area >= 0.015 {
            quality = .moderate
        } else {
            quality = .low
        }
        if ambiguous { quality = quality.lowered() }

        var limitations: [String] = []
        if ambiguous {
            limitations.append("Another person is nearly as prominent, so the choice of main subject is less certain.")
        }
        if !edges.isEmpty {
            limitations.append("The subject's box touches the \(edges.map(\.rawValue).sorted().joined(separator: ", ")) edge, so the centre describes the visible part of the person.")
        }
        if !selection.secondaries.isEmpty {
            limitations.append("\(selection.secondaries.count) other person(s) were detected; only the main subject is measured here.")
        }
        limitations.append("The box is the detector's estimate of the person's extent, not a pixel-accurate outline.")

        let explanation = String(
            format: "The main subject's box is centred %.0f%% from the left and %.0f%% from the top (%@, %@) and covers %.1f%% of the image.",
            center.x * 100, center.y * 100, horizontalPhrase(horizontal), verticalPhrase(vertical), area * 100)

        let evidenceRefs = [
            EvidenceReference(source: .visionHumanRectangles, origin: .rawModelOutput, role: .primary,
                              label: "Person box",
                              value: String(format: "x %.3f, y %.3f, w %.3f, h %.3f (confidence %.2f)",
                                            box.minX, box.minY, box.width, box.height, primary.confidence)),
            EvidenceReference(source: nil, origin: .derivedMeasurement, role: .primary,
                              label: "Centre / size",
                              value: String(format: "centre (%.3f, %.3f), area %.4f", center.x, center.y, area)),
            EvidenceReference(source: nil, origin: .interpretation, role: .primary,
                              label: "Zone", value: "\(horizontal.rawValue) / \(vertical.rawValue) (thirds grid)")
        ]

        return SubjectPositioningResult(
            subjectBox: box,
            upperBodyBox: primary.upperBodyBox.map { ImageSpace.clamped($0) },
            center: center,
            normalizedWidth: Double(box.width), normalizedHeight: Double(box.height), normalizedArea: area,
            horizontal: horizontal, vertical: vertical,
            detectionConfidence: primary.confidence,
            isMeasurementValid: true, touchedEdges: edges,
            selection: selection.info,
            secondarySubjects: selection.secondaries.enumerated().map {
                SecondarySubject(rank: $0.offset + 1, box: $0.element.box, confidence: $0.element.confidence)
            },
            assessment: Assessment(status: .determined, quality: quality, explanation: explanation,
                                   evidence: evidenceRefs, limitations: limitations))
    }

    private static func horizontalPhrase(_ zone: HorizontalZone) -> String {
        switch zone {
        case .left: return "left third"
        case .center: return "centre third"
        case .right: return "right third"
        }
    }

    private static func verticalPhrase(_ zone: VerticalZone) -> String {
        switch zone {
        case .upper: return "upper third"
        case .middle: return "middle third"
        case .lower: return "lower third"
        }
    }

    private static func humanRunEvidence(_ value: String) -> EvidenceReference {
        EvidenceReference(source: .visionHumanRectangles, origin: .rawModelOutput, role: .primary,
                          label: "Person detection", value: value)
    }
}
