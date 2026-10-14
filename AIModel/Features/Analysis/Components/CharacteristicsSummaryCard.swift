import SwiftUI

/// A single unified card summarising the user's core photographic
/// characteristics.
///
/// Replaces the previous list of one-card-per-insight. Each row pairs a fixed
/// characteristic label with the value the analysis actually measured, plus its
/// evidence badge — so all six core traits read at a glance in one place.
///
/// Rows are driven by whatever insights the profile produced. A characteristic
/// with no measurable insight is shown as "Not enough data" rather than omitted,
/// so the card always presents the same six labels and the user can see what
/// was and wasn't measured.
/// One row of measured data inside `CharacteristicsSummaryCard`.
///
/// Internal (not private) so both the card and its row view can reference it.
struct CharacteristicRowData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let evidence: EvidenceStrength
    let hasData: Bool
}

struct CharacteristicsSummaryCard: View {

    let insights: [PreferenceInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                CharacteristicRow(row: row)

                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Row model

    /// Maps the profile's insights onto the six fixed characteristics.
    ///
    /// Order is fixed so the card reads consistently across profiles. Each
    /// characteristic looks up its insight by title; the first match wins.
    private var rows: [CharacteristicRowData] {
        func first(_ titles: [String]) -> PreferenceInsight? {
            for title in titles {
                if let match = insights.first(where: { $0.title == title }) {
                    return match
                }
            }
            return nil
        }

        let specs: [(label: String, titles: [String])] = [
            ("Subject Placement", ["Subject Placement", "Varied Subject Placement"]),
            ("Head Angle", ["Head Angle", "Head Angle (Varied)"]),
            ("Subject vs Background", ["Subject vs Background"]),
            ("Pose", ["Pose (Straight-On)", "Pose (Diagonal)"]),
            ("Symmetry", ["Symmetrical Composition"]),
            ("Body Framing", ["Full Body Framing", "Half Body Framing", "Mixed Body Framing"])
        ]

        return specs.map { spec in
            if let insight = first(spec.titles) {
                return CharacteristicRowData(
                    label: spec.label,
                    value: insight.description,
                    evidence: insight.evidenceStrength,
                    hasData: true
                )
            } else {
                return CharacteristicRowData(
                    label: spec.label,
                    value: "Not enough data",
                    evidence: .insufficient,
                    hasData: false
                )
            }
        }
    }
}

/// One row inside `CharacteristicsSummaryCard`: label, measured value, evidence.
private struct CharacteristicRow: View {

    let row: CharacteristicRowData

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(row.value)
                    .font(.subheadline)
                    .foregroundStyle(row.hasData ? .secondary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Evidence badge, aligned to the top so rows of differing height
            // keep their badges in line.
            Text(ProfileInsightFormatters.evidenceStrengthLabel(row.evidence))
                .font(.caption2.weight(.medium))
                .foregroundStyle(ProfileInsightFormatters.evidenceStrengthColor(row.evidence))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(ProfileInsightFormatters.evidenceStrengthColor(row.evidence).opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
