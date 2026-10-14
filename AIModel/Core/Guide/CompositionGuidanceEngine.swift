import Foundation
import CoreGraphics

/// Converts composition evaluations into stable, practical camera instructions.
///
/// Two jobs beyond translating an issue into words:
///
/// 1. ONE instruction at a time — the primary issue only, so the screen never
///    shows contradictory advice.
/// 2. STABILITY — a short confirmation window and hysteresis, so guidance does
///    not flicker as detection jitters frame to frame. An instruction must hold
///    for `stabilityWindow` consecutive evaluations before it is shown, and the
///    "ready" state must hold for `readyHoldFrames` before it is announced.
///
/// Pure logic and stateful by design; holds no Vision/camera/UI dependency, so
/// it is fully unit-testable.
struct CompositionGuidanceEngine {

    // MARK: - Tunables

    /// Consecutive evaluations an instruction must hold before it is shown.
    /// At the ~7fps detection rate, 3 frames ≈ 0.4s of stable measurement.
    var stabilityWindow: Int = 3

    /// Consecutive ready evaluations before announcing "ready to capture".
    /// Higher than `stabilityWindow` so declaring readiness is more deliberate
    /// than flagging a problem.
    var readyHoldFrames: Int = 5

    // MARK: - State

    private var candidateIssue: CompositionEvaluation.Issue?
    private var candidateCount: Int = 0
    private var readyCount: Int = 0
    private var announcedIssue: CompositionEvaluation.Issue?
    private var announcedReady: Bool = false

    /// The instruction currently shown to the user, or nil when nothing is
    /// stable enough to show.
    private(set) var currentInstruction: String?

    /// True once "ready to capture" has been held long enough to announce.
    private(set) var isReadyStable: Bool = false

    // MARK: - Update

    /// Feeds one evaluation and returns the instruction to display (or nil).
    ///
    /// Mutates internal stability state. Call once per evaluation, in order.
    mutating func update(with evaluation: CompositionEvaluation) -> String? {
        let issue = evaluation.primaryIssue

        // --- Issue stability ---
        if issue == candidateIssue {
            candidateCount += 1
        } else {
            candidateIssue = issue
            candidateCount = 1
        }

        // --- Ready stability (evaluated independently of issue) ---
        if evaluation.isReady {
            readyCount += 1
        } else {
            readyCount = 0
        }

        // Announce the issue only once it has held for the stability window.
        if let issue, candidateCount >= stabilityWindow {
            announcedIssue = issue
        } else if issue == nil, candidateCount >= stabilityWindow {
            // The problem has genuinely cleared.
            announcedIssue = nil
        }

        // Announce ready only after it has held longer than a mere flicker.
        if readyCount >= readyHoldFrames {
            announcedReady = true
        } else {
            announcedReady = false
        }
        isReadyStable = announcedReady

        currentInstruction = makeInstruction(for: announcedIssue, evaluation: evaluation)
        return currentInstruction
    }

    /// Clears all stability state — call when the camera restarts or the scene
    /// is reset, so a stale instruction does not persist into a new scene.
    mutating func reset() {
        candidateIssue = nil
        candidateCount = 0
        readyCount = 0
        announcedIssue = nil
        announcedReady = false
        currentInstruction = nil
        isReadyStable = false
    }

    // MARK: - Instruction text

    /// Maps the announced issue to a practical instruction.
    ///
    /// Text is chosen from the MEASURED problem, not hardcoded per scene. Each
    /// case names a concrete camera action. Where the profile could not supply a
    /// target, the copy says the measurement is approximate rather than asserting
    /// a preference the user may not have.
    private func makeInstruction(
        for issue: CompositionEvaluation.Issue?,
        evaluation: CompositionEvaluation
    ) -> String? {

        // Ready wins when there is no outstanding issue. Binding with `guard
        // let` narrows the optional so the switch below is over a non-optional
        // and exhaustiveness is checked properly.
        guard let issue else {
            return announcedReady ? "Ready to capture" : nil
        }

        switch issue {
        case .noSubject:
            return "No subject detected"
        case .subjectLost:
            return "Subject lost — reframe on the subject"
        case .subjectClipped:
            return "Subject is cut off — pull back to fit the whole subject"
        case .subjectTooLarge:
            return "Subject is larger than your usual framing — move back"
        case .subjectTooSmall:
            return "Subject is smaller than your usual framing — move closer"
        case .subjectOffCentreHorizontally:
            return "Move to shift the subject toward your usual position"
        case .subjectOffCentreVertically:
            return "Adjust framing to match your usual subject height"
        }
    }
}
