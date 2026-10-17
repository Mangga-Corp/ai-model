import SwiftUI

/// Actual cached outputs for one photo, shown by what produced them. Nothing
/// is recomputed: this reads the stored evidence. A source that did not run or
/// failed is listed as such, never shown as if it had produced evidence.
struct ModelOutputSection: View {
    let photo: PhotoResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let prep = photo.preparation { preparation(prep) }
            if let evidence = photo.evidence {
                sources(evidence)
                rawOutputs(evidence)
            } else {
                Text("No model output exists for this photo.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Preparation

    private func preparation(_ p: ImagePreparationRecord) -> some View {
        group("Input preparation", symbol: "photo") {
            line("Original", "\(p.originalPixelWidth) × \(p.originalPixelHeight) px")
            line("Analysed at", "\(p.preparedWidth) × \(p.preparedHeight) px (scale \(String(format: "%.2f", p.scale)))")
            Text("The photo is rotated upright once and never cropped, so every coordinate refers to the same image you see here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Sources

    private func sources(_ evidence: PhotoEvidence) -> some View {
        group("What ran", symbol: "checklist") {
            ForEach(evidence.runs) { run in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: symbol(run.state)).foregroundStyle(color(run.state)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.source.displayName).font(.footnote.weight(.medium))
                        Text(run.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(label(run.state)).font(.caption).foregroundStyle(.secondary)
                    Text("\(run.durationMilliseconds) ms").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Raw outputs

    private func rawOutputs(_ e: PhotoEvidence) -> some View {
        group("Raw model output", symbol: "cpu") {
            if let humans = e.humans.value {
                ForEach(humans) { h in
                    line("Person #\(h.id)", String(format: "conf %.2f, box x %.2f y %.2f w %.2f h %.2f", h.confidence, h.box.minX, h.box.minY, h.box.width, h.box.height))
                }
            } else { missing("Person boxes", e.humans) }

            if let poses = e.pose.value {
                ForEach(Array(poses.enumerated()), id: \.offset) { i, pose in
                    line("Pose #\(i)", "\(pose.reliableLandmarks().count) of \(pose.landmarks.count) landmarks at confidence 0.30 or higher")
                }
            } else { missing("Body pose", e.pose) }

            if let faces = e.faces.value {
                ForEach(Array(faces.enumerated()), id: \.offset) { i, f in
                    line("Face #\(i) (head orientation)", String(format: "pitch %.0f°, yaw %.0f°, roll %.0f°", f.pitchDegrees, f.yawDegrees, f.rollDegrees))
                }
            } else { missing("Faces", e.faces) }

            if let roll = e.imageRoll.value {
                line("Horizon (image roll)", String(format: "%.1f° (confidence %.2f)", roll.angleDegrees, roll.confidence))
            } else { missing("Horizon", e.imageRoll) }

            if let seg = e.segmentation.value {
                line("Segmentation grid", "\(seg.gridWidth) × \(seg.gridHeight), person \(String(format: "%.1f%%", seg.personFraction * 100))")
                line("Largest classes", seg.topClasses.map { "\($0.label) \(String(format: "%.0f%%", $0.score * 100))" }.joined(separator: ", "))
            } else { missing("Segmentation", e.segmentation) }

            if let depth = e.depth.value {
                line("Depth map", "\(depth.gridWidth) × \(depth.gridHeight), contrast \(String(format: "%.2f", depth.contrast))")
                Text(DepthSummary.convention).font(.caption).foregroundStyle(.secondary)
            } else { missing("Depth", e.depth) }

            if let lines = e.verticalLines.value {
                let longest = lines.map(\.length).max() ?? 0
                line("Vertical edge segments", "\(lines.count) found, longest \(String(format: "%.0f%%", longest * 100)) of the image height")
                Text("Plain edge detection, not a model. Only segments on man-made structure are used.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { missing("Vertical edge analysis", e.verticalLines) }

            if let labels = e.sceneContext.value {
                line("Scene classifier", labels.prefix(3).map { "\($0.label) \(String(format: "%.0f%%", $0.score * 100))" }.joined(separator: "; "))
                Text("Generic image labels, shown for context only. They are not used for any conclusion above.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { missing("Scene classifier", e.sceneContext) }
        }
    }

    // MARK: Pieces

    private func group<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.footnote.weight(.medium))
            Text(value).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func missing<V>(_ name: String, _ outcome: EvidenceOutcome<V>) -> some View {
        let text: String
        switch outcome {
        case .nothingDetected: text = "Ran, found nothing"
        case .failed(let m): text = "Did not produce output: \(m)"
        case .skipped(let m): text = "Not run: \(m)"
        case .produced: text = ""
        }
        return line(name, text)
    }

    private func symbol(_ s: SourceRunRecord.State) -> String {
        switch s {
        case .produced: return "checkmark.circle.fill"
        case .nothingDetected: return "circle.dashed"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(_ s: SourceRunRecord.State) -> Color {
        switch s {
        case .produced: return .green
        case .nothingDetected: return .secondary
        case .failed: return .red
        case .skipped: return .gray
        }
    }

    private func label(_ s: SourceRunRecord.State) -> String {
        switch s {
        case .produced: return "Output"
        case .nothingDetected: return "Nothing found"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}
