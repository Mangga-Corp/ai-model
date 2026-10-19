import SwiftUI

/// The four Object and Environment results for one photo, shown under the
/// camera characteristics. Reads cached results and artifacts only: opening or
/// expanding anything here never runs a model.
struct EnvironmentSection: View {
    let photo: PhotoResult
    let image: UIImage?
    let artifacts: PhotoArtifacts?

    var body: some View {
        if let env = photo.environment {
            VStack(alignment: .leading, spacing: 16) {
                Text("Objects and environment")
                    .font(.title3.bold())
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                SegmentationCard(photo: photo, env: env, image: image, artifacts: artifacts)
                DominantElementsCard(env: env)
                SceneContextCard(env: env)
                CompositionCard(photo: photo, env: env, image: image, artifacts: artifacts)
            }
        }
    }
}

// MARK: - Shared pieces

private struct CardHeader: View {
    let title: String
    let systemImage: String
    let assessment: Assessment
    /// Replaces the evidence-grade badge when the grade would overstate what is known.
    var neutralBadge: (label: String, symbol: String)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let neutralBadge { NeutralBadge(label: neutralBadge.label, symbol: neutralBadge.symbol) }
            else { EvidenceBadge(assessment) }
        }
    }
}

private struct CardFooter: View {
    let assessment: Assessment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence grades are rule-based checks of coverage and agreement. They are not model probabilities, and none says the model's labels are correct.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !assessment.limitations.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(assessment.limitations, id: \.self) { limitation in
                            Label(limitation, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                                .labelStyle(TopAlignedLabelStyle())
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Uncertainty and limitations (\(assessment.limitations.count))").font(.footnote.weight(.medium))
                }
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
}

/// A badge that states what happened without grading it. Segmentation has no
/// confidence to report, so it never shows a "strong evidence" style label.
private struct NeutralBadge: View {
    let label: String
    let symbol: String

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.blue)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

private struct SmallTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct ValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

private func pct(_ v: Double, _ digits: Int = 0) -> String { EnvironmentFormat.pct(v, digits) }

// MARK: - A. Object segmentation

private struct SegmentationCard: View {
    enum Mode: String, CaseIterable, Identifiable {
        case original = "Original"
        case segmentation = "Segmentation"
        var id: String { rawValue }
    }

    let photo: PhotoResult
    let env: EnvironmentAnalysisResult
    let image: UIImage?
    let artifacts: PhotoArtifacts?

    @State private var mode: Mode = .segmentation
    @State private var selected: String?

    var body: some View {
        let seg = env.segmentation
        ResultCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Object Segmentation", systemImage: "square.on.square.dashed", assessment: seg.assessment,
                           neutralBadge: seg.availability.hasValidOutput ? ("Output decoded", "checkmark.circle") : nil)

                Text(headline(seg)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(seg.assessment.explanation)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch seg.availability {
                case .available:
                    preview(seg)
                    legend(seg)
                case .noEnvironmentalRegions:
                    Label("The model ran and found nothing to report besides the person. This is a result, not a missing one.",
                          systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.secondary).labelStyle(TopAlignedLabelStyle())
                case .unavailable, .invalid:
                    Label("No overlay is drawn because there is no valid segmentation to draw.", systemImage: "eye.slash")
                        .font(.footnote).foregroundStyle(.secondary).labelStyle(TopAlignedLabelStyle())
                }

                if seg.availability.hasValidOutput { peopleSummary(seg) }

                Text(ObjectSegmentationResult.semanticNote + " The labels come from the model and are not independently verified.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                CardFooter(assessment: seg.assessment)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func headline(_ seg: ObjectSegmentationResult) -> String {
        switch seg.availability {
        case .available:
            let n = seg.environmentalRegions.count
            return "\(n) environmental region\(n == 1 ? "" : "s")"
        case .noEnvironmentalRegions:
            return seg.setAsideRegions.isEmpty ? "No environmental regions" : "No usable regions"
        case .unavailable: return "Unavailable"
        case .invalid: return "Output not usable"
        }
    }

    @ViewBuilder
    private func preview(_ seg: ObjectSegmentationResult) -> some View {
        if let image, artifacts?.segmentation != nil {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            EvidenceImageView(image: image, photo: photo, artifacts: artifacts,
                              layers: mode == .segmentation ? [.segmentation] : [],
                              highlightedRegionID: mode == .segmentation ? selected : nil,
                              setAsideRegionIDs: Set(seg.setAsideRegions.map(\.id)))
        } else {
            Label("The original photo is not available, so the overlay cannot be shown.", systemImage: "photo.badge.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func legend(_ seg: ObjectSegmentationResult) -> some View {
        let measured = seg.regions.filter(\.isValid)
        let tiny = seg.regions.filter { !$0.isValid }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Regions").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(measured) { region in row(region) }
            if !tiny.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tiny) { r in
                            Text("\(r.family.displayName): \(pct(r.areaFraction, 2)) of the image, too small to measure")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                } label: {
                    Text("Too small to measure (\(tiny.count))").font(.footnote.weight(.medium))
                }
            }
        }
    }

    private func row(_ r: SemanticRegion) -> some View {
        let isSelected = selected == r.id
        let carried = r.family.group == .carriedItem
        let aside = r.reliability.reason
        return Button {
            selected = isSelected ? nil : r.id
            mode = .segmentation
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(r.family.swatch).frame(width: 14, height: 14).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.family.displayName).font(.subheadline.weight(isSelected ? .bold : .medium))
                        if carried { SmallTag(text: "Carried or worn", color: .gray) }
                        if aside != nil { SmallTag(text: "Set aside", color: .orange) }
                        Spacer(minLength: 8)
                        Text(pct(r.areaFraction, 1)).font(.subheadline.monospacedDigit())
                    }
                    Text(detail(r)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let aside {
                        Text("Not used for rankings, scene or preferences. " + aside)
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Highlights this region on the photo")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detail(_ r: SemanticRegion) -> String {
        guard let g = r.geometry else { return "" }
        var parts = [EnvironmentFormat.zone(g.horizontal, g.vertical)]
        parts.append(g.componentCount == 1 ? "one connected piece" : "\(g.componentCount) pieces (one combined region)")
        if r.rawLabels.count > 1 || (r.rawLabels.first?.label.lowercased() != r.family.displayName.lowercased()) {
            parts.append("model labels: " + r.rawLabels.prefix(4).map { "\($0.label) \(pct($0.areaFraction, 1))" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func peopleSummary(_ seg: ObjectSegmentationResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            ValueRow(label: "People (all merged)", value: pct(seg.allPeopleFraction, 1))
            if let h = seg.human {
                if h.isValid, let area = h.maskAreaFraction {
                    ValueRow(label: "Main person's mask", value: pct(area, 1))
                    Text("The box comes from person detection and the mask from segmentation, and they are kept separate.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("No valid mask for the main person: \(h.invalidReason ?? "unavailable").", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary).labelStyle(TopAlignedLabelStyle())
                }
            }
        }
    }
}

// MARK: - B. Dominant environmental elements

private struct DominantElementsCard: View {
    let env: EnvironmentAnalysisResult

    var body: some View {
        let result = env.elements
        ResultCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Dominant Elements", systemImage: "rectangle.3.group", assessment: result.assessment)
                Text(headline(result)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(result.assessment.explanation)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !result.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(result.candidates.prefix(6)) { candidate in row(candidate) }
                    }
                    .padding(.top, 2)
                    if result.candidates.count > 6 {
                        Text("\(result.candidates.count - 6) smaller candidate(s) not shown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Label("The person is the primary subject and is never ranked here.", systemImage: "person.fill")
                    .font(.caption).foregroundStyle(.tertiary)
                CardFooter(assessment: result.assessment)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func headline(_ r: DominantElementsResult) -> String {
        switch r.outcome {
        case .identified:
            let names = r.dominant.map(\.label)
            return names.count == 1 ? names[0] : names.joined(separator: " and ")
        case .noStandoutElement: return "No standout element"
        case .noEnvironmentalRegions: return "Nothing to rank"
        case .unavailable: return "Unavailable"
        }
    }

    private func row(_ c: ElementCandidate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(c.rank)").font(.caption.bold().monospacedDigit())
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(c.role.color.opacity(0.18)))
                    .accessibilityHidden(true)
                Text(c.label).font(.subheadline.weight(.semibold))
                SmallTag(text: c.role.label, color: c.role.color)
                Spacer(minLength: 8)
                Text(String(format: "score %.2f", c.score)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(c.role.color.opacity(0.75)).frame(width: max(4, geo.size.width * c.score))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text("\(pct(c.areaFraction)) of the image · \(EnvironmentFormat.zone(c.horizontal, c.vertical)) · \(c.quality.label.lowercased())"
                 + (c.pieceCount > 1 ? " · \(c.pieceCount) pieces, one combined region" : ""))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.rationale).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(c.components, id: \.name) { term in
                        HStack(alignment: .firstTextBaseline) {
                            Text(term.name).font(.caption.weight(.medium))
                            Spacer(minLength: 8)
                            Text(term.used ? String(format: "%.2f × %.0f%%", term.value, term.effectiveWeight * 100) : "not used")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(term.note).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(String(format: "Score %.2f = the sum of each value × its share of the weight. Shares are renormalised over the terms that were available.", c.score))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(c.uncertainty, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                            .labelStyle(TopAlignedLabelStyle())
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Why this rank").font(.footnote.weight(.medium))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - C. Scene context

private struct SceneContextCard: View {
    let env: EnvironmentAnalysisResult

    var body: some View {
        let scene = env.scene
        ResultCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Scene Context", systemImage: "photo.on.rectangle.angled", assessment: scene.assessment)
                Label(headline(scene), systemImage: scene.primary.symbol)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(scene.assessment.explanation)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if scene.assessment.status != .unavailable { chips(scene) }
                if !scene.observedCues.isEmpty { observed(scene) }
                if !scene.classifierHints.isEmpty { hints(scene) }
                CardFooter(assessment: scene.assessment)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func headline(_ s: SceneContextResult) -> String {
        switch s.assessment.status {
        case .determined: return s.primary.displayName
        case .unavailable: return "Unavailable"
        default: return "Not enough evidence"
        }
    }

    private func chips(_ s: SceneContextResult) -> some View {
        FlowLayout(spacing: 8) {
            SmallTag(text: "Setting: \(s.setting.displayName)", color: s.setting == .undetermined ? .gray : .blue)
            SmallTag(text: s.character.displayName, color: s.character == .undetermined ? .gray : .teal)
            ForEach(s.secondary) { c in
                SmallTag(text: "Also: \(c.category.displayName)", color: .purple)
            }
        }
    }

    private func observed(_ s: SceneContextResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("Observed (measured)", systemImage: "ruler").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(s.observedCues.prefix(6)) { cue in
                HStack {
                    Text(cue.label).font(.footnote)
                    Spacer(minLength: 8)
                    Text("\(pct(cue.areaFraction)) of image · \(pct(cue.environmentShare)) of surroundings")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text("The conclusion above is an inference from these measurements, not a measurement itself.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func hints(_ s: SceneContextResult) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(s.classifierHints) { h in
                    Text("\(h.label) \(pct(h.score)) · points toward \(h.supports.displayName) · \(h.used ? "used as corroboration" : "not used")")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The classifier names objects, not places, so its labels only corroborate what segmentation already shows.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        } label: {
            Text("Image classifier labels (\(s.classifierHints.count))").font(.footnote.weight(.medium))
        }
    }
}

// MARK: - D. Position and scale

private struct CompositionCard: View {
    let photo: PhotoResult
    let env: EnvironmentAnalysisResult
    let image: UIImage?
    let artifacts: PhotoArtifacts?

    var body: some View {
        let c = env.composition
        ResultCard {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Position and Scale", systemImage: "arrow.up.left.and.arrow.down.right", assessment: c.assessment)
                Text(headline(c)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(c.assessment.explanation)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let image, (c.subject != nil || !c.elements.isEmpty) {
                    EvidenceImageView(image: image, photo: photo, artifacts: artifacts, layers: overlayLayers(c))
                    Text("Green: person box. Yellow: dominant element, orange: secondary. Dots mark each region's centre of mass.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let s = c.subject { subject(s) }
                if !c.descriptors.isEmpty { descriptors(c) }
                if !c.elements.isEmpty { elements(c) }
                CardFooter(assessment: c.assessment)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func overlayLayers(_ c: CompositionResult) -> Set<EvidenceLayer> {
        var layers: Set<EvidenceLayer> = []
        if c.subject != nil { layers.insert(.subjectBox) }
        if env.elements.candidates.contains(where: { $0.role != .uncertain }) { layers.insert(.elementBoxes) }
        return layers
    }

    private func headline(_ c: CompositionResult) -> String {
        if let scale = c.scale, let offset = c.horizontalOffset {
            return "\(scale.band.label), \(offset.band.label.lowercased())"
        }
        switch c.assessment.status {
        case .unavailable: return "Unavailable"
        default: return "No subject measured"
        }
    }

    private func subject(_ s: SubjectCompositionMeasurement) -> some View {
        VStack(spacing: 6) {
            Divider()
            ValueRow(label: "Subject box area", value: pct(s.boxAreaRatio, 1))
            if let mask = s.maskAreaRatio {
                ValueRow(label: "Subject mask area", value: pct(mask, 1) + (s.maskMayIncludeOtherPeople ? " (may include another person)" : ""))
            }
            ValueRow(label: "Width × height", value: "\(pct(s.widthRatio)) × \(pct(s.heightRatio))")
            ValueRow(label: "Center", value: EnvironmentFormat.point(s.center))
            ValueRow(label: "Zone", value: EnvironmentFormat.zone(s.horizontal, s.vertical))
        }
    }

    private func descriptors(_ c: CompositionResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("Interpretation", systemImage: "text.bubble").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(c.descriptors) { d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(d.statement).font(.subheadline)
                        if d.isBorderline { SmallTag(text: "Borderline", color: .orange) }
                    }
                    ForEach(d.basis, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func elements(_ c: CompositionResult) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(c.elements.prefix(8)) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.label).font(.footnote.weight(.semibold))
                        Text("center \(EnvironmentFormat.point(m.centroid)) · \(EnvironmentFormat.zone(m.horizontal, m.vertical))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("box \(pct(m.boundingBoxAreaRatio, 1)) · mask \(pct(m.maskAreaRatio, 1)) · "
                             + (m.componentCount == 1 ? "one piece" : "\(m.componentCount) pieces, combined region"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let rel = m.relativeToSubject {
                            Text(String(format: "%.1f× the subject (%@)", rel.ratio, rel.basis == .maskToMask ? "mask to mask" : "box to box"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if c.elements.count > 8 { Text("\(c.elements.count - 8) more not shown.").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.top, 4)
        } label: {
            Text("Environmental element measurements (\(c.elements.count))").font(.footnote.weight(.medium))
        }
    }
}

// MARK: - Layout

/// Left-to-right chips that wrap onto new lines instead of scrolling sideways,
/// so none of them is hidden off-screen (and all are reachable by VoiceOver).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { y += rowHeight + spacing; x = bounds.minX; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
