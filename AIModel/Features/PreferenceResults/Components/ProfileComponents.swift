import SwiftUI

/// Square photo thumbnail with a placeholder when the image is unavailable.
struct PhotoThumb: View {
    let image: UIImage?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// How many photos a characteristic could be assessed for, and why not for the rest.
struct CoverageSummary: View {
    let coverage: CharacteristicCoverage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: coverage.fraction)
                .tint(coverage.determinedCount == 0 ? .gray : .accentColor)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        var parts = ["Determined for \(coverage.determinedCount) of \(coverage.totalPhotos) photos"]
        if !coverage.insufficientPhotoIDs.isEmpty { parts.append("\(coverage.insufficientPhotoIDs.count) lacked evidence") }
        if !coverage.notApplicablePhotoIDs.isEmpty { parts.append("\(coverage.notApplicablePhotoIDs.count) not applicable") }
        if !coverage.unavailablePhotoIDs.isEmpty { parts.append("\(coverage.unavailablePhotoIDs.count) unavailable") }
        return parts.joined(separator: " · ")
    }
}

/// A categorical finding: pattern, distribution bars, and the photos behind each category.
struct FindingSection<Category: Hashable & Sendable>: View {
    let title: String
    let systemImage: String
    let finding: CategoryFinding<Category>
    let coverage: CharacteristicCoverage?
    let order: [Category]
    let label: (Category) -> String
    let thumbnail: (UUID) -> UIImage?
    var showCoverage = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage).font(.headline)
                patternBadge
            }

            Text(finding.summary).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let present = order.filter { (finding.counts[$0] ?? 0) > 0 }
                .sorted { (finding.counts[$0] ?? 0) > (finding.counts[$1] ?? 0) }
            if !present.isEmpty {
                VStack(spacing: 10) {
                    ForEach(present, id: \.self) { category in row(category) }
                }
            }

            if !finding.excludedPhotoIDs.isEmpty {
                Label("\(finding.excludedPhotoIDs.count) photo(s) had no valid evidence and are not counted for or against any category.",
                      systemImage: "minus.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .labelStyle(TopAlignedLabelStyle())
            }
            if showCoverage, let coverage { CoverageSummary(coverage: coverage) }
        }
    }

    private var patternBadge: some View {
        let text = finding.pattern == .recurring || finding.pattern == .mixed
            ? "\(finding.pattern.label) · \(finding.strength.label)" : finding.pattern.label
        let color: Color = finding.pattern == .recurring ? .green : (finding.pattern == .mixed ? .orange : .gray)
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func row(_ category: Category) -> some View {
        let count = finding.counts[category] ?? 0
        let share = Double(count) / Double(max(1, finding.validObservationCount))
        let isDominant = finding.dominant == category
        let isIsolated = finding.isolated.contains(category)
        let ids = finding.supportingPhotoIDs[category] ?? []

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label(category)).font(.subheadline.weight(isDominant ? .bold : .regular))
                if isDominant { tag("Dominant", .green) }
                else if isIsolated { tag("Isolated", .gray) }
                Spacer(minLength: 8)
                Text("\(count) of \(finding.validObservationCount)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(isDominant ? Color.green : Color.accentColor.opacity(0.7))
                        .frame(width: max(6, geo.size.width * share))
                }
            }
            .frame(height: 8)
            HStack(spacing: 4) {
                ForEach(ids, id: \.self) { PhotoThumb(image: thumbnail($0), size: 26) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label(category)), \(count) of \(finding.validObservationCount) photos\(isDominant ? ", dominant" : "")\(isIsolated ? ", isolated" : "")")
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Where each photo's subject sits in the frame, with the typical centre when photos agree.
struct PositionMap: View {
    struct Dot: Identifiable { let id: UUID; let point: CGPoint; let index: Int }
    let dots: [Dot]
    let typical: CGPoint?
    let aspect: CGFloat = 4.0 / 3.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.tertiarySystemFill))
                Path { p in
                    for i in 1...2 {
                        let f = CGFloat(i) / 3
                        p.move(to: CGPoint(x: f * geo.size.width, y: 0)); p.addLine(to: CGPoint(x: f * geo.size.width, y: geo.size.height))
                        p.move(to: CGPoint(x: 0, y: f * geo.size.height)); p.addLine(to: CGPoint(x: geo.size.width, y: f * geo.size.height))
                    }
                }
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)

                if let typical {
                    Circle().strokeBorder(Color.green, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 34, height: 34)
                        .position(x: typical.x * geo.size.width, y: typical.y * geo.size.height)
                }
                ForEach(dots) { dot in
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Text("\(dot.index)").font(.caption2.bold()).foregroundStyle(.white)
                    }
                    .frame(width: 20, height: 20)
                    .position(x: dot.point.x * geo.size.width, y: dot.point.y * geo.size.height)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of subject centres across \(dots.count) photos")
    }
}

/// Mean-free numeric summary row: median with range.
struct SummaryRow: View {
    let label: String
    let summary: NumericSummary?
    var asPercent = true
    var consistency: Consistency?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let summary {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(format(summary.median)) median").monospacedDigit()
                    Text(rangeText(summary) + (consistency.map { " · \($0.label)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No data").foregroundStyle(.tertiary)
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    private func format(_ v: Double) -> String { asPercent ? String(format: "%.0f%%", v * 100) : String(format: "%+.2f", v) }

    private func rangeText(_ s: NumericSummary) -> String {
        s.count < 2 ? "1 photo" : "\(format(s.minimum)) to \(format(s.maximum)) (\(s.count) photos)"
    }
}
