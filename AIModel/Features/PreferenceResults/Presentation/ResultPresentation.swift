import SwiftUI

// Presentation-only wording, symbols and colours for the analysis models.
// Nothing here measures or interprets anything.

extension CharacteristicKind {
    var title: String {
        switch self {
        case .cameraAngle: return "Camera Angle"
        case .subjectFraming: return "Subject Framing"
        case .subjectPositioning: return "Subject Positioning"
        case .environmentalDepth: return "Environmental Depth"
        }
    }

    var systemImage: String {
        switch self {
        case .cameraAngle: return "angle"
        case .subjectFraming: return "person.crop.rectangle"
        case .subjectPositioning: return "viewfinder"
        case .environmentalDepth: return "square.3.layers.3d"
        }
    }

    /// One-line description of what the characteristic tells you.
    var blurb: String {
        switch self {
        case .cameraAngle: return "Camera height relative to the subject"
        case .subjectFraming: return "How much of the person is in the frame"
        case .subjectPositioning: return "Where the subject sits and how large it is"
        case .environmentalDepth: return "How the subject separates from its surroundings"
        }
    }
}

extension CameraAngleCategory {
    var label: String {
        switch self {
        case .lowAngle: return "Low angle"
        case .eyeLevel: return "Eye level"
        case .highAngle: return "High angle"
        case .birdsEye: return "Bird's eye"
        case .wormsEye: return "Worm's eye"
        case .unknown: return "Unknown"
        }
    }
}

extension CameraHeightLevel {
    var label: String {
        switch self {
        case .aboveHead: return "Above head"
        case .eye: return "Eye level"
        case .shoulder: return "Shoulder level"
        case .hip: return "Hip level"
        case .knee: return "Knee level"
        case .ground: return "Ground level"
        case .unknown: return "Unknown"
        }
    }
}

extension DutchAngleCategory {
    var label: String {
        switch self {
        case .level: return "Straight horizon"
        case .slightTilt: return "Slightly tilted"
        case .dutch: return "Dutch angle"
        case .unknown: return "Unknown"
        }
    }
}

extension FramingCategory {
    var label: String {
        switch self {
        case .fullBody: return "Full body"
        case .halfBody: return "Half body"
        case .other: return "Other / not applicable"
        case .unknown: return "Unknown"
        }
    }
}

extension HorizontalZone {
    var label: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }
}

extension VerticalZone {
    var label: String {
        switch self {
        case .upper: return "Upper"
        case .middle: return "Middle"
        case .lower: return "Lower"
        }
    }
}

extension DepthStructure {
    var label: String {
        switch self {
        case .separated: return "Clear separation"
        case .layered: return "Layered"
        case .foregroundDominant: return "Foreground dominant"
        case .blended: return "Blends with surroundings"
        case .partialSeparation: return "Partial separation"
        case .unknown: return "Unknown"
        }
    }
}

extension VisibleBodyExtent {
    var label: String {
        switch self {
        case .none: return "No body region"
        case .headOnly: return "Head only"
        case .headAndShoulders: return "Head and shoulders"
        case .toHips: return "Down to the hips"
        case .toKnees: return "Down to the knees"
        case .toAnkles: return "Down to the ankles"
        }
    }
}

extension EvidenceQuality {
    var label: String {
        switch self {
        case .high: return "Strong evidence"
        case .moderate: return "Moderate evidence"
        case .low: return "Weak evidence"
        case .none: return "No evidence"
        }
    }

    var symbol: String {
        switch self {
        case .high: return "checkmark.seal.fill"
        case .moderate: return "checkmark.seal"
        case .low: return "exclamationmark.triangle"
        case .none: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .high: return .green
        case .moderate: return .teal
        case .low: return .orange
        case .none: return .gray
        }
    }
}

extension AssessmentStatus {
    var label: String {
        switch self {
        case .determined: return "Determined"
        case .insufficientEvidence: return "Not enough evidence"
        case .notApplicable: return "Not applicable"
        case .unavailable: return "Unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .determined: return "checkmark.circle"
        case .insufficientEvidence: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        case .unavailable: return "exclamationmark.octagon"
        }
    }
}

extension Assessment {
    /// Badge text: evidence quality when determined, otherwise the reason there is no result.
    var badgeLabel: String { isDetermined ? quality.label : status.label }
    var badgeSymbol: String { isDetermined ? quality.symbol : status.symbol }
    var badgeColor: Color { isDetermined ? quality.color : .gray }
}

extension PatternKind {
    var label: String {
        switch self {
        case .noEvidence: return "No evidence"
        case .singleObservation: return "Single photo"
        case .recurring: return "Recurring"
        case .mixed: return "Mixed"
        }
    }
}

extension PatternStrength {
    var label: String {
        switch self {
        case .insufficient: return "Insufficient"
        case .limited: return "Limited support"
        case .moderate: return "Moderate support"
        case .strong: return "Strong support"
        }
    }
}

extension Consistency {
    var label: String {
        switch self {
        case .tight: return "Consistent"
        case .moderate: return "Some variation"
        case .wide: return "Widely varied"
        case .undetermined: return "Needs 2+ photos"
        }
    }
}

extension EvidenceRole {
    var label: String {
        switch self {
        case .primary: return "Primary"
        case .supporting: return "Supporting"
        case .contextual: return "Context only"
        case .limiting: return "Limiting"
        }
    }
}

extension EvidenceOrigin {
    var label: String {
        switch self {
        case .rawModelOutput: return "Raw output"
        case .derivedMeasurement: return "Measurement"
        case .interpretation: return "Interpretation"
        }
    }

    var symbol: String {
        switch self {
        case .rawModelOutput: return "cpu"
        case .derivedMeasurement: return "ruler"
        case .interpretation: return "text.bubble"
        }
    }
}

// MARK: - Per-photo value text

enum PhotoValueText {

    /// Short result for a chip or row: the finding, or why there is none.
    static func text(for kind: CharacteristicKind, in photo: PhotoResult) -> String {
        let assessment = photo.assessment(for: kind)
        guard assessment.isDetermined else {
            switch assessment.status {
            case .insufficientEvidence: return "Unknown"
            case .notApplicable: return "N/A"
            default: return "Unavailable"
            }
        }
        switch kind {
        case .cameraAngle: return photo.cameraAngle.category.label
        case .subjectFraming: return photo.subjectFraming.category.label
        case .subjectPositioning:
            let p = photo.subjectPositioning
            return [p.horizontal?.label, p.vertical?.label].compactMap { $0 }.joined(separator: " · ")
        case .environmentalDepth: return photo.environmentalDepth.structure.label
        }
    }
}

// MARK: - Card container

struct ResultCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Quality / status pill. Text and symbol carry the meaning; colour only reinforces it.
struct EvidenceBadge: View {
    let label: String
    let symbol: String
    let color: Color

    init(_ assessment: Assessment) {
        label = assessment.badgeLabel
        symbol = assessment.badgeSymbol
        color = assessment.badgeColor
    }

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
