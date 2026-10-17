import SwiftUI

/// Route for the full consolidated profile.
struct ProfileRoute: Hashable {}

/// The consolidated Photo Preference Profile in full: each characteristic's
/// pattern, distribution, supporting photos, numeric summaries, coverage and
/// limitations. Renders `PreferenceProfile` only; nothing is recomputed.
struct ProfileDetailView: View {
    @ObservedObject var session: AnalysisSession

    var body: some View {
        Group {
            if let profile = session.profile {
                content(profile)
            } else {
                ContentUnavailableView("No profile yet", systemImage: "chart.bar.doc.horizontal",
                                       description: Text("Analyse some photos to build a profile."))
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Preference Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func thumb(_ id: UUID) -> UIImage? { session.imageStore.image(for: id) }

    private func content(_ profile: PreferenceProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ResultCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Based on \(profile.photosWithValidEvidenceCount) of \(profile.totalPhotoCount) photos")
                            .font(.headline)
                        Text("A pattern needs the same result in at least two photos. Photos without evidence for a characteristic are left out of it, never counted against it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                ResultCard {
                    FindingSection(title: CharacteristicKind.cameraAngle.title,
                                   systemImage: CharacteristicKind.cameraAngle.systemImage,
                                   finding: profile.cameraAngle, coverage: profile.coverage[.cameraAngle],
                                   order: [.lowAngle, .eyeLevel, .highAngle],
                                   label: { $0.label }, thumbnail: thumb)
                }

                ResultCard {
                    FindingSection(title: CharacteristicKind.subjectFraming.title,
                                   systemImage: CharacteristicKind.subjectFraming.systemImage,
                                   finding: profile.subjectFraming, coverage: profile.coverage[.subjectFraming],
                                   order: [.fullBody, .halfBody, .other],
                                   label: { $0.label }, thumbnail: thumb)
                }

                positioningCard(profile)
                depthCard(profile)

                if let environment = profile.environment {
                    EnvironmentProfileSection(profile: environment, thumbnail: thumb)
                }

                if !profile.limitations.isEmpty {
                    ResultCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Limitations", systemImage: "exclamationmark.circle").font(.headline)
                            ForEach(profile.limitations, id: \.self) { limitation in
                                Text("• " + limitation).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: Positioning

    private func positioningCard(_ profile: PreferenceProfile) -> some View {
        let kind = CharacteristicKind.subjectPositioning
        let dots: [PositionMap.Dot] = session.results.compactMap { r in
            guard r.subjectPositioning.assessment.isDetermined, r.subjectPositioning.isMeasurementValid,
                  let c = r.subjectPositioning.center else { return nil }
            return PositionMap.Dot(id: r.id, point: c, index: r.selectionOrder + 1)
        }
        let m = profile.positioning

        return ResultCard {
            VStack(alignment: .leading, spacing: 14) {
                FindingSection(title: "Horizontal position", systemImage: kind.systemImage,
                               finding: profile.horizontalPosition, coverage: profile.coverage[kind],
                               order: [.left, .center, .right], label: { $0.label }, thumbnail: thumb)
                Divider()
                FindingSection(title: "Vertical position", systemImage: "arrow.up.and.down",
                               finding: profile.verticalPosition, coverage: nil,
                               order: [.upper, .middle, .lower], label: { $0.label }, thumbnail: thumb,
                               showCoverage: false)

                if !dots.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Subject centres").font(.subheadline.weight(.semibold))
                        PositionMap(dots: dots, typical: m.typicalCenter)
                        Text(m.typicalCenter == nil
                             ? "Subject centres do not agree closely enough to state a typical position."
                             : "The dashed circle marks the typical centre where photos agree.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 6) {
                        SummaryRow(label: "Center X", summary: m.centerX, consistency: m.centerXConsistency)
                        SummaryRow(label: "Center Y", summary: m.centerY, consistency: m.centerYConsistency)
                        SummaryRow(label: "Subject width", summary: m.width)
                        SummaryRow(label: "Subject height", summary: m.height)
                        SummaryRow(label: "Share of frame", summary: m.area, consistency: m.areaConsistency)
                    }
                }
            }
        }
    }

    // MARK: Depth

    private func depthCard(_ profile: PreferenceProfile) -> some View {
        let kind = CharacteristicKind.environmentalDepth
        let d = profile.depth
        return ResultCard {
            VStack(alignment: .leading, spacing: 14) {
                FindingSection(title: kind.title, systemImage: kind.systemImage,
                               finding: profile.depthStructure, coverage: profile.coverage[kind],
                               order: [.separated, .layered, .foregroundDominant, .partialSeparation, .blended],
                               label: { $0.label }, thumbnail: thumb)
                if d.sampleCount > 0 {
                    Divider()
                    VStack(spacing: 6) {
                        SummaryRow(label: "Subject minus surroundings", summary: d.subjectMinusEnvironment, asPercent: false)
                        SummaryRow(label: "Surroundings nearer", summary: d.fractionEnvironmentNearer)
                        SummaryRow(label: "Surroundings farther", summary: d.fractionEnvironmentFarther)
                    }
                    Text("Relative depth within each photo, not distance.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
