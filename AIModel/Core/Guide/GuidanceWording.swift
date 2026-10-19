import Foundation

/// Everything the photographer reads from composition guidance, in one place.
///
/// PRINCIPLES
///   - One short action per message, in terms of what the photographer SEES in the viewfinder
///     ("toward the left of the frame"). Directions describe the on-screen result, never a
///     camera movement, so they cannot be reversed by confusing camera motion with subject
///     motion.
///   - A direction is only stated when the measurement established it. Otherwise the generic
///     wording is used.
///   - Moving closer or back is offered as a suggestion ("a little"), not a promise: this
///     camera has one fixed lens and no zoom control, but the wording does not depend on it.
///   - A "why" line explains the instruction only in terms that are true: what the reference
///     photos show compared with the live view. No internal terms, no confidence values.
///   - "Ready" is only said when a preference was actually compared and matched.
enum GuidanceWording {

    typealias Issue = CompositionEvaluation.Issue
    typealias HorizontalShift = CompositionEvaluation.HorizontalShift
    typealias VerticalShift = CompositionEvaluation.VerticalShift

    static let ready = "Ready to capture"

    // MARK: Instructions

    static func instruction(for issue: Issue, horizontal: HorizontalShift?, vertical: VerticalShift?) -> String {
        switch issue {
        case .noSubject:
            return "Point the camera at your subject"
        case .subjectLost:
            return "Subject lost — reframe on the subject"
        case .subjectClipped:
            // Unchanged on purpose: already a clear camera action.
            return "Subject is cut off — pull back to fit the whole subject"
        case .subjectTooLarge:
            return "Move back a little to leave more room around the subject"
        case .subjectTooSmall:
            return "Move a little closer to make the subject larger"
        case .subjectOffCentreHorizontally:
            switch horizontal {
            case .towardLeft?: return "Move the subject slightly toward the left of the frame"
            case .towardRight?: return "Move the subject slightly toward the right of the frame"
            case nil: return "Move to shift the subject toward your usual position"
            }
        case .subjectOffCentreVertically:
            switch vertical {
            case .higher?: return "Move the subject slightly higher in the frame"
            case .lower?: return "Move the subject slightly lower in the frame"
            case nil: return "Adjust framing to match your usual subject height"
            }
        }
    }

    // MARK: Reasons

    /// Why the instruction is shown, when that can be said accurately. Nil otherwise.
    static func reason(for issue: Issue, horizontal: HorizontalShift?, vertical: VerticalShift?) -> String? {
        switch issue {
        case .subjectTooLarge:
            return "The subject looks larger than in your reference photos."
        case .subjectTooSmall:
            return "The subject looks smaller than in your reference photos."
        case .subjectOffCentreHorizontally:
            switch horizontal {
            case .towardLeft?: return "In your reference photos the subject sits further to the left."
            case .towardRight?: return "In your reference photos the subject sits further to the right."
            case nil: return nil
            }
        case .subjectOffCentreVertically:
            switch vertical {
            case .higher?: return "In your reference photos the subject sits higher in the frame."
            case .lower?: return "In your reference photos the subject sits lower in the frame."
            case nil: return nil
            }
        case .noSubject, .subjectLost, .subjectClipped:
            return nil
        }
    }

    /// What "ready" was based on. Nil when nothing specific is known, so nothing is claimed.
    static func readyDetail(applied: CompositionEvaluation.AppliedChecks) -> String? {
        let position = applied.contains(.horizontal) || applied.contains(.vertical)
        let size = applied.contains(.scale)
        switch (position, size) {
        case (true, true): return "Position and size match your reference photos."
        case (true, false): return "Position matches your reference photos."
        case (false, true): return "Size matches your reference photos."
        case (false, false): return nil
        }
    }

    // MARK: When there is nothing to compare with

    /// A short, plain explanation shown when no preference could be applied. Nil when the
    /// situation does not need one (nothing was evaluated, or the measurement is only
    /// temporarily unusable).
    static func limitation(for applicability: CompositionEvaluation.Applicability) -> String? {
        guard case .noUsablePreference(let reason) = applicability else { return nil }
        switch reason {
        case .noUsableObservations?: return "There are no matching reference photos to compare with."
        case .singleObservation?: return "One reference photo isn't enough to find a pattern yet."
        case .noRecurringPattern?: return "Your reference photos place the subject differently each time."
        case .tooVariable?: return "Your reference photos vary too much to set a target."
        case .profileInconsistent?: return "Your saved style couldn't be matched to these photos."
        case .invalidPreferenceData?: return "Your saved style couldn't be read."
        case .noPreferenceData?, nil: return "No saved style to compare with yet."
        }
    }
}
