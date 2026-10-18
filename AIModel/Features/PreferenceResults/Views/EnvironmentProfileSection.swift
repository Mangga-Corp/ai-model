import SwiftUI

/// The environment side of the consolidated profile. It separates what can be
/// applied in any scene (composition) from what only holds when the matching
/// environment is present (scene-dependent). Renders `EnvironmentProfile` only.
struct EnvironmentProfileSection: View {
    let profile: EnvironmentProfile
    let thumbnail: (UUID) -> UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            introCard
            transferableCard
            sceneDependentCard
            coverageCard
        }
    }

    private func pct(_ v: Double) -> String { EnvironmentFormat.pct(v) }

    // MARK: Intro

    private var introCard: some View {
        ResultCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Environment and composition", systemImage: "photo.on.rectangle.angled").font(.headline)
                Text("Segmentation could be interpreted for \(profile.eligiblePhotoCount) of \(profile.totalPhotoCount) photos.")
                    .font(.subheadline)
                Text("Composition tendencies can be used in any scene. Scene tendencies describe your reference photos and only apply when the same kind of environment is present.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Transferable

    private var transferableCard: some View {
        let t = profile.transferable
        return ResultCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Composition (any scene)", systemImage: "arrow.left.and.right.square").font(.headline)
                Text(t.note).font(.footnote).foregroundStyle(.secondary)

                FindingSection(title: "Subject scale", systemImage: "person.crop.rectangle", finding: t.subjectScale,
                               coverage: nil, order: [.small, .moderate, .large], label: { $0.label },
                               thumbnail: thumbnail, showCoverage: false)
                Divider()
                FindingSection(title: "Horizontal offset", systemImage: "arrow.left.and.right", finding: t.horizontalOffset,
                               coverage: nil, order: [.centered, .slightlyOff, .offCenter], label: { $0.label },
                               thumbnail: thumbnail, showCoverage: false)
                Divider()
                FindingSection(title: "Surroundings vs subject", systemImage: "scale.3d", finding: t.environmentProminence,
                               coverage: nil, order: [.environmentDominates, .balanced, .subjectDominates], label: { $0.label },
                               thumbnail: thumbnail, showCoverage: false)

                if t.subjectBoxArea != nil || t.subjectMaskArea != nil || t.dominantElementToSubject != nil {
                    Divider()
                    VStack(spacing: 6) {
                        SummaryRow(label: "Subject box area", summary: t.subjectBoxArea)
                        if t.subjectMaskArea != nil { SummaryRow(label: "Subject mask area", summary: t.subjectMaskArea) }
                        if let ratio = t.dominantElementToSubject { ratioRow(ratio) }
                    }
                }
                if t.borderlinePhotoCount > 0 {
                    Text("\(t.borderlinePhotoCount) photo(s) sat close to a band threshold; their labels carry less weight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ratioRow(_ s: NumericSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Dominant element ÷ subject").foregroundStyle(.secondary)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f× median", s.median)).monospacedDigit()
                Text(s.count < 2 ? "1 photo" : String(format: "%.1f× to %.1f× (%d photos)", s.minimum, s.maximum, s.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    // MARK: Scene-dependent

    private var sceneDependentCard: some View {
        let s = profile.sceneDependent
        return ResultCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Scene-dependent tendencies", systemImage: "tree").font(.headline)
                Text(s.note).font(.footnote).foregroundStyle(.secondary)

                FindingSection(title: "Kind of place", systemImage: "mappin.and.ellipse", finding: s.sceneCategory,
                               coverage: nil,
                               order: SceneContextCategory.allCases.filter { $0 != .unknown },
                               label: { $0.displayName }, thumbnail: thumbnail, showCoverage: false)
                Divider()
                FindingSection(title: "Indoor or outdoor", systemImage: "house", finding: s.setting, coverage: nil,
                               order: [.indoor, .outdoor], label: { $0.displayName }, thumbnail: thumbnail, showCoverage: false)
                Divider()
                FindingSection(title: "Built or natural", systemImage: "building.2", finding: s.character, coverage: nil,
                               order: [.built, .mixed, .natural], label: { $0.displayName }, thumbnail: thumbnail, showCoverage: false)

                if !s.groupTendencies.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Elements that appear").font(.subheadline.weight(.semibold))
                        ForEach(s.groupTendencies.prefix(6)) { tendencyRow($0) }
                        Text("Each rate counts only the photos that can speak to that element (up to \(profile.eligiblePhotoCount)). \"Dominant when present\" uses only the photos where it appears. Photos where the model's reading was set aside or too incomplete are left out, never counted as absent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !s.placements.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where recurring elements sit").font(.subheadline.weight(.semibold))
                        ForEach(s.placements.prefix(5)) { placementRow($0) }
                    }
                }
            }
        }
    }

    private func tendencyRow(_ t: ElementTendency) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t.label).font(.subheadline.weight(.medium))
                Text(t.pattern.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(t.pattern == .recurring ? Color.green : Color.gray)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((t.pattern == .recurring ? Color.green : Color.gray).opacity(0.14), in: Capsule())
                Spacer(minLength: 8)
                Text("\(t.presentCount) of \(t.eligiblePhotoCount)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            if t.presentCount > 0 {
                Text(dominanceLine(t)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                ForEach(t.presentPhotoIDs, id: \.self) { PhotoThumb(image: thumbnail($0), size: 22) }
            }
            Text(t.condition).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func dominanceLine(_ t: ElementTendency) -> String {
        var line = "Dominant in \(t.dominantCount) of \(t.presentCount) where present"
        if let area = t.areaWhenPresent { line += String(format: " · median %.0f%% of the image", area.median * 100) }
        return line
    }

    private func placementRow(_ p: ElementPlacementTendency) -> some View {
        let h = p.horizontalCounts.max { $0.value < $1.value }
        let v = p.verticalCounts.max { $0.value < $1.value }
        var zone = ""
        if let h, let v { zone = "\(h.key.label.lowercased()) · \(v.key.label.lowercased())" }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(p.label).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("\(p.sampleCount) photos").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Most often \(zone) · \(p.consistency.label.lowercased())").font(.caption).foregroundStyle(.secondary)
            Text(p.condition).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Coverage

    private var coverageCard: some View {
        ResultCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Coverage and limits", systemImage: "exclamationmark.circle").font(.headline)
                ForEach(EnvironmentFacet.allCases) { facet in
                    if let c = profile.coverage[facet] {
                        HStack {
                            Text(facet.title).font(.footnote)
                            Spacer()
                            Text("\(c.determinedCount) of \(c.totalPhotos) photos")
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                ForEach(profile.limitations, id: \.self) { limitation in
                    Text("• " + limitation).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
