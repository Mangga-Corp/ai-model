import SwiftUI

/// A single analyzed photo rendered with its detected overlays.
///
/// Tapping toggles the overlay layers so the user can compare what the model
/// measured against the plain photograph.
struct AnalyzedPhotoCard: View {

    let photo: ReferencePhoto
    let analysis: PhotoAnalysis

    @State private var showOverlays = true
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Image with overlays
            ZStack {
                if let image = photo.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .overlay(ProgressView())
                }

                if showOverlays {
                    AnalysisOverlayView(analysis: analysis)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Controls
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showOverlays.toggle() }
                } label: {
                    Label(
                        showOverlays ? "Hide Overlays" : "Show Overlays",
                        systemImage: showOverlays ? "eye.slash" : "eye"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
                } label: {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Detected characteristics
            if showDetails {
                DetectedCharacteristicsList(analysis: analysis)
            } else {
                Text(detectedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// One-line summary of what was actually detected.
    private var detectedSummary: String {
        var found: [String] = []
        
        if analysis.hasSubject { found.append("subject") }
        if analysis.hasHeadPose { found.append("face angle") }
        if analysis.hasBodyPose { found.append("body pose") }
        if analysis.hasHorizon { found.append("horizon") }
        if analysis.hasLightDirection { found.append("light direction") }
        if analysis.hasLeadingLines {
            found.append("\(analysis.leadingLines?.lineCount ?? 0) lines")
        }
        if analysis.hasColorAnalysis { found.append("colors") }
        if analysis.hasAestheticScore { found.append("quality score") }

        if found.isEmpty {
            return "No characteristics detected in this photo."
        }
        return "Detected: \(found.joined(separator: ", "))"
    }
}

/// Detailed measurement list for one photo.
private struct DetectedCharacteristicsList: View {
    let analysis: PhotoAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Strings are computed up front so no statements leak into the
            // ViewBuilder, which only accepts view expressions.
            if let pos = analysis.subjectPosition {
                MeasurementRow(
                    label: "Subject position",
                    value: String(format: "x %.2f, y %.2f", pos.x, pos.y)
                )
            }

            if let size = analysis.subjectSize {
                MeasurementRow(
                    label: "Subject area",
                    value: String(format: "%.1f%% of frame", size * 100)
                )
            }

            if analysis.hasHeadPose {
                MeasurementRow(label: "Head angle", value: headAngleText)
                // Plain-language reading of the same angles, so the pose is
                // understandable without interpreting degrees.
                if let description = headAngleDescription {
                    MeasurementRow(label: "Head pose", value: description)
                }
            }

            if analysis.hasBodyPose {
                MeasurementRow(label: "Body pose", value: bodyPoseText)
            }

            if let angle = analysis.horizonAngle {
                MeasurementRow(label: "Horizon", value: horizonText(angle))
            }

            if analysis.hasLightDirection, let dir = analysis.lightDirection {
                MeasurementRow(
                    label: "Light direction",
                    value: "\(dir.rawValue) (estimate)"
                )
            }

            if analysis.hasLeadingLines, let lines = analysis.leadingLines {
                MeasurementRow(label: "Leading lines", value: leadingLinesText(lines))
            }

            if let brightness = analysis.meanBrightness {
                MeasurementRow(
                    label: "Brightness",
                    value: String(format: "%.0f%%", brightness * 100)
                )
            }

            if let saturation = analysis.meanSaturation {
                MeasurementRow(
                    label: "Saturation",
                    value: String(format: "%.0f%%", saturation * 100)
                )
            }

            if let harmony = analysis.colorHarmony {
                MeasurementRow(label: "Color harmony", value: harmony.rawValue)
            }

            if let score = analysis.aestheticScore {
                MeasurementRow(
                    label: "Aesthetic score",
                    value: String(format: "%+.2f", score)
                )
            }

            if !analysis.unavailableCharacteristics.isEmpty {
                MeasurementRow(
                    label: "Not measurable",
                    value: analysis.unavailableCharacteristics
                        .map { $0.rawValue }
                        .sorted()
                        .joined(separator: ", ")
                )
            }
        }
    }

    // MARK: - Computed measurement strings

    /// Plain-language description of the measured head pose, e.g.
    /// "turned left, level, chin down". Nil when no angle was measurable.
    private var headAngleDescription: String? {
        HeadAngleDescriptor.describe(
            yaw: analysis.headYaw,
            roll: analysis.headRoll,
            pitch: analysis.headPitch
        )
    }

    private var headAngleText: String {
        var parts: [String] = []
        if let roll = analysis.headRoll {
            parts.append(String(format: "roll %.0f°", roll))
        }
        if let yaw = analysis.headYaw {
            parts.append(String(format: "yaw %.0f°", yaw))
        }
        if let pitch = analysis.headPitch {
            parts.append(String(format: "pitch %.0f°", pitch))
        }
        return parts.joined(separator: ", ")
    }

    private var bodyPoseText: String {
        let joints = "\(analysis.bodyPoseJointCount ?? 0) joints"
        if let group = analysis.dominantJointsGroup {
            return "\(joints), \(group.lowercased()) clearest"
        }
        return joints
    }

    private func horizonText(_ angle: Double) -> String {
        let percent = (analysis.horizonVerticalPosition ?? 0) * 100
        return String(format: "%.1f° at %.0f%% height", angle, percent)
    }

    private func leadingLinesText(_ lines: LeadingLinesResult) -> String {
        var value = "\(lines.lineCount) segments"
        if let angle = lines.dominantAngle {
            value += String(format: ", dominant %.0f°", angle)
        }
        return value
    }
}

/// A single label/value measurement row.
private struct MeasurementRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            Text(value)
                .font(.caption)
                .monospacedDigit()

            Spacer(minLength: 0)
        }
    }
}
