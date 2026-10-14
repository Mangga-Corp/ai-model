import SwiftUI

/// Presentation formatting for the preference profile screen.
///
/// Extracted from `PreferenceProfileViewModel` because these are display
/// concerns with no state: they turn a measurement or evidence strength into
/// the label and colour the user reads. Keeping them in the ViewModel mixed
/// "what the screen holds" with "how it looks", which is what makes view models
/// grow until they are hard to test.
///
/// Static and stateless by design — nothing here reads or mutates screen state,
/// so it can be called from anywhere a profile value is rendered.
enum ProfileInsightFormatters {

    // MARK: - Labels

    static func evidenceStrengthLabel(_ strength: EvidenceStrength) -> String {
        switch strength {
        case .strong:      return "Strong Evidence"
        case .moderate:    return "Moderate Evidence"
        case .weak:        return "Weak Evidence"
        case .insufficient: return "Insufficient Evidence"
        }
    }

    static func interpretationStatusLabel(_ status: InterpretationStatus) -> String {
        switch status {
        case .observation:   return "Measurement"
        case .interpretation: return "AI Interpretation"
        }
    }

    // MARK: - Colour

    /// Colour for an evidence strength.
    ///
    /// Deliberately returns `Color` rather than a `String` asset name: the
    /// previous version returned "green"/"blue"/"gray" and the view resolved
    /// them, which let a typo become a silently unstyled label. A `Color`
    /// cannot fail to compile.
    static func evidenceStrengthColor(_ strength: EvidenceStrength) -> Color {
        switch strength {
        case .strong:       return .green
        case .moderate:     return .blue
        case .weak:         return .yellow
        case .insufficient: return .gray
        }
    }

    // MARK: - Ordering

    /// Evidence strengths from strongest to weakest, for display ordering.
    ///
    /// Lives with the formatters rather than the ViewModel because it is a
    /// presentation decision — how strongly-evidenced insights sort above
    /// weakly-evidenced ones — not a property of the data.
    static let evidenceStrengthOrder: [EvidenceStrength] = [.strong, .moderate, .weak, .insufficient]
}
