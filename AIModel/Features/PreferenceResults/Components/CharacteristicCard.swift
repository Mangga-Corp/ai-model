import SwiftUI

/// One of the four characteristics for one photo: result, explanation,
/// measurements, uncertainty, and expandable evidence.
struct CharacteristicCard: View {
    let kind: CharacteristicKind
    let photo: PhotoResult

    var body: some View {
        let assessment = photo.assessment(for: kind)
        let rows = ResultMeasurementRows.rows(for: kind, in: photo)

        ResultCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    EvidenceBadge(assessment)
                }

                Text(headline(assessment))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                Text(assessment.explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !rows.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(rows, id: \.label) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(row.value).multilineTextAlignment(.trailing).monospacedDigit()
                            }
                            .font(.footnote)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 2)
                }

                if !assessment.limitations.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(assessment.limitations, id: \.self) { limitation in
                                Label(limitation, systemImage: "exclamationmark.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .labelStyle(TopAlignedLabelStyle())
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("Uncertainty and limitations (\(assessment.limitations.count))").font(.footnote.weight(.medium))
                    }
                }

                if kind == .cameraAngle, !photo.cameraAngle.observations.isEmpty {
                    CameraAngleSourcesView(result: photo.cameraAngle)
                }

                if !assessment.evidence.isEmpty {
                    DisclosureGroup {
                        EvidenceList(references: assessment.evidence).padding(.top, 4)
                    } label: {
                        Text("Technical evidence").font(.footnote.weight(.medium))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func headline(_ assessment: Assessment) -> String {
        assessment.isDetermined ? PhotoValueText.text(for: kind, in: photo) : assessment.status.label
    }
}

struct TopAlignedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Measurements

struct ResultMeasurementRow {
    let label: String
    let value: String
}

/// Display rows built from existing results. No computation beyond formatting.
enum ResultMeasurementRows {

    static func rows(for kind: CharacteristicKind, in photo: PhotoResult) -> [ResultMeasurementRow] {
        switch kind {
        case .cameraAngle: return angle(photo)
        case .subjectFraming: return framing(photo)
        case .subjectPositioning: return positioning(photo)
        case .environmentalDepth: return depth(photo)
        }
    }

    private static func pct(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f%%", v * 100) }

    private static func angle(_ photo: PhotoResult) -> [ResultMeasurementRow] {
        let a = photo.cameraAngle
        var rows: [ResultMeasurementRow] = []

        // What the evidence still allows, when it could not settle on one category.
        if let decision = a.decision, a.category == .unknown,
           decision.possibleCategories.count == 2 {
            let order: [CameraAngleCategory] = [.lowAngle, .eyeLevel, .highAngle]
            let names = order.filter(decision.possibleCategories.contains).map(\.label)
            rows.append(.init(label: "Still possible", value: names.joined(separator: " or ")))
        }
        // Only evidence that contributed is shown as a measurement of this result.
        if let cue = a.horizonCue {
            let value = cue.offsetInHeadHeights.map { String(format: "%+.1f head-heights", $0) }
                ?? String(format: "%+.0f%% of image height", cue.offsetInImageHeights * 100)
            rows.append(.init(label: "Eyes relative to horizon", value: value))
            rows.append(.init(label: "Horizon surface", value: cue.horizon.lowerRegionLabel))
        }
        if let scene = a.observations.first(where: { $0.provider == .sceneVerticals && $0.validity.isValid }),
           a.decision?.contributing.contains(.sceneVerticals) == true {
            for label in ["Vertical lines", "Vertical edges used", "Eyes vs image center"] {
                if let m = scene.measurements.first(where: { $0.label == label }) {
                    rows.append(.init(label: m.label, value: m.value))
                }
            }
        }
        if let pitch = a.headPitchDegrees {
            rows.append(.init(label: "Head pitch (context only)", value: String(format: "%.0f°", pitch)))
        }
        if let roll = a.imageRollDegrees {
            rows.append(.init(label: "Image roll (context only)", value: String(format: "%.1f°", roll)))
        }
        return rows
    }

    private static func framing(_ photo: PhotoResult) -> [ResultMeasurementRow] {
        let f = photo.subjectFraming
        var rows: [ResultMeasurementRow] = []
        if let extent = f.visibleExtent { rows.append(.init(label: "Visible body", value: extent.label)) }
        if f.reliableLandmarkCount > 0 { rows.append(.init(label: "Reliable landmarks", value: "\(f.reliableLandmarkCount) of \(BodyJoint.allCases.count)")) }
        if !f.croppedEdges.isEmpty {
            rows.append(.init(label: "Subject touches", value: f.croppedEdges.map(\.rawValue).sorted().joined(separator: ", ")))
        }
        return rows
    }

    private static func positioning(_ photo: PhotoResult) -> [ResultMeasurementRow] {
        let p = photo.subjectPositioning
        var rows: [ResultMeasurementRow] = []
        guard p.isMeasurementValid, let c = p.center else {
            if p.selection.detectedCount > 0 {
                rows.append(.init(label: "Detections", value: "\(p.selection.detectedCount) (none eligible)"))
            }
            return rows
        }
        rows.append(.init(label: "Center (x, y)", value: "\(pct(Double(c.x))), \(pct(Double(c.y)))"))
        if let w = p.normalizedWidth, let h = p.normalizedHeight {
            rows.append(.init(label: "Width × height", value: "\(pct(w)) × \(pct(h))"))
        }
        if let area = p.normalizedArea { rows.append(.init(label: "Area of frame", value: pct(area, 1))) }
        if let conf = p.detectionConfidence { rows.append(.init(label: "Detector confidence", value: String(format: "%.2f", conf))) }
        if p.selection.detectedCount > 1 {
            rows.append(.init(label: "People detected", value: "\(p.selection.detectedCount)\(p.selection.isAmbiguous ? " (main subject ambiguous)" : "")"))
        }
        rows.append(.init(label: "Measurement valid", value: "Yes"))
        return rows
    }

    private static func depth(_ photo: PhotoResult) -> [ResultMeasurementRow] {
        let d = photo.environmentalDepth
        var rows: [ResultMeasurementRow] = []
        if let m = d.metrics {
            rows.append(.init(label: "Subject region", value: m.subjectRegionMethod == .personMask
                              ? "Person mask (\(m.maskCoverageOfBox.map { pct($0) } ?? "–") of box)" : "Center of box (no reliable mask)"))
            rows.append(.init(label: "Subject depth", value: String(format: "%.2f", m.subjectMedian)))
            rows.append(.init(label: "Surroundings depth", value: String(format: "%.2f", m.environmentMedian)))
            rows.append(.init(label: "Surroundings nearer / similar / farther",
                              value: "\(pct(m.fractionEnvironmentNearer)) / \(pct(m.fractionEnvironmentSimilar)) / \(pct(m.fractionEnvironmentFarther))"))
            if let ring = m.subjectMinusRing { rows.append(.init(label: "Subject vs. immediate surroundings", value: String(format: "%+.2f", ring))) }
            rows.append(.init(label: "Scale", value: "Relative, 0 far to 1 near"))
        } else if let b = d.sceneBands {
            rows.append(.init(label: "Whole scene near / mid / far",
                              value: "\(pct(b.nearFraction)) / \(pct(b.midFraction)) / \(pct(b.farFraction))"))
            rows.append(.init(label: "Scale", value: "Relative, 0 far to 1 near"))
        }
        return rows
    }
}

// MARK: - Evidence list

/// Evidence grouped so raw model output, derived measurements and the
/// interpretation are never mistaken for one another.
struct EvidenceList: View {
    let references: [EvidenceReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([EvidenceOrigin.rawModelOutput, .derivedMeasurement, .interpretation], id: \.self) { origin in
                let items = references.filter { $0.origin == origin }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(origin.label, systemImage: origin.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.label).font(.footnote.weight(.medium))
                                    Text(item.role.label)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                Text(item.value).font(.footnote).foregroundStyle(.secondary)
                                if let source = item.source {
                                    Text("Source: \(source.displayName)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}
