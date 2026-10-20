import SwiftUI

extension CameraAngleProvider {
    var title: String {
        switch self {
        case .horizonLine: return "Horizon line"
        case .sceneVerticals: return "Background vertical lines"
        case .subjectGeometry: return "Subject eye line"
        case .headOrientation: return "Head orientation"
        case .depthTilt: return "Relative depth (head vs body)"
        case .bodyPose3D: return "3D body pose (camera position)"
        }
    }

    var systemImage: String {
        switch self {
        case .horizonLine: return "water.waves"
        case .sceneVerticals: return "building.2"
        case .subjectGeometry: return "eye"
        case .headOrientation: return "face.smiling"
        case .depthTilt: return "square.3.layers.3d"
        case .bodyPose3D: return "figure.stand"
        }
    }
}

/// Every evidence source that was considered for the camera angle, what it
/// found, whether it influenced the result, and why a source was not usable.
struct CameraAngleSourcesView: View {
    let result: CameraAngleResult
    @State private var isExpanded: Bool

    init(result: CameraAngleResult, startExpanded: Bool = false) {
        self.result = result
        _isExpanded = State(initialValue: startExpanded)
    }

    var body: some View {
        let used = Set(result.decision?.contributing ?? [])
        let usable = result.observations.filter { $0.validity.isValid }.count

        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(result.observations) { observation in
                    row(observation, used: used.contains(observation.provider))
                }
                if let decision = result.decision {
                    ForEach(decision.conflicts, id: \.self) { conflict in
                        Label(conflict, systemImage: "arrow.left.arrow.right")
                            .font(.caption).foregroundStyle(.orange).labelStyle(TopAlignedLabelStyle())
                    }
                    ForEach(decision.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).labelStyle(TopAlignedLabelStyle())
                    }
                }
                Text("Camera angle is inferred from these cues. It is not a direct measurement, and no angle in degrees is claimed.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        } label: {
            Text("How this was assessed (\(usable) of \(result.observations.count) sources usable)")
                .font(.footnote.weight(.medium))
        }
    }

    private func row(_ o: CameraAngleObservation, used: Bool) -> some View {
        let symbol: String, color: Color
        switch o.validity {
        case .valid: (symbol, color) = used ? ("checkmark.circle.fill", .green) : ("circle.fill", .secondary)
        case .notApplicable: (symbol, color) = ("minus.circle", .gray)
        case .invalid: (symbol, color) = ("exclamationmark.triangle", .orange)
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(o.provider.title).font(.footnote.weight(.semibold))
                    Text(roleLabel(o, used: used)).font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Text(o.validity.isValid ? o.summary : (o.validity.reason ?? o.summary))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func roleLabel(_ o: CameraAngleObservation, used: Bool) -> String {
        guard o.validity.isValid else {
            if case .notApplicable = o.validity { return "Not applicable here" }
            return "Not usable"
        }
        switch o.role {
        case .decisive: return used ? "Used to decide" : "Valid, not decisive"
        case .corroborating: return "Cross-check"
        case .contextual: return "Context only"
        }
    }
}
