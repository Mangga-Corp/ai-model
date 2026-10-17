import Foundation

nonisolated struct CameraAngleFusionOutcome: Sendable, Equatable {
    let category: CameraAngleCategory
    let status: AssessmentStatus
    let quality: EvidenceQuality
    let explanation: String
    let limitations: [String]
    let decision: CameraAngleDecisionSummary
}

/// Combines provider observations into one camera-angle decision.
///
/// DESIGN. Confidence values from different providers are not comparable (a
/// horizon fit residual and an edge-convergence standard error mean different
/// things), so they are never averaged or summed. Instead the fusion reasons
/// about WHICH CATEGORIES EACH SOURCE STILL ALLOWS:
///
///  1. Each valid decisive provider gives an elevation interval (the camera's
///     height relative to the eyes, across plausible lenses). The categories
///     that interval overlaps are the ones that provider cannot rule out.
///  2. The possible set is the intersection across providers. This separates
///     "evidence AGAINST a category" (it was ruled out) from "no evidence"
///     (nothing was ruled out).
///        - exactly one category left   -> determined
///        - several left                -> unknown, but the ruled-out ones are kept
///        - none left                   -> sources CONTRADICT -> unknown
///        - no valid decisive provider  -> unknown (insufficient)
///  3. Quality comes from the contributing providers' own grades, reduced when:
///     the result would change under a longer lens, the subject is not upright,
///     or the depth cross-check contradicts the implied tilt. Two independent
///     decisive providers that agree may raise it one grade.
///  4. Corroborating providers can only lower trust; contextual ones only add limitations.
nonisolated enum CameraAngleFusion {

    static func fuse(_ observations: [CameraAngleObservation], anchor: SubjectAnchor?) -> CameraAngleFusionOutcome {
        let all: Set<CameraAngleCategory> = [.lowAngle, .eyeLevel, .highAngle]
        let decisive = observations.filter { $0.role == .decisive }
        let usable = decisive.filter { $0.validity.isValid && $0.elevation != nil }
        let unusable = decisive.filter { !usable.contains($0) }
        let contextLimitations = observations.filter { $0.role != .decisive }.flatMap(\.limitations)

        // 1. Nothing decisive could observe.
        guard !usable.isEmpty else {
            // The per-source reasons are already listed on each provider row; repeating them as notes is noise.
            let explanation = "No evidence source could establish the camera's height relative to the subject. "
                + unusable.map(\.summary).joined(separator: " ")
                + " Face direction and image tilt do not measure camera angle, so the angle is left unknown."
            return CameraAngleFusionOutcome(
                category: .unknown, status: .insufficientEvidence, quality: .none, explanation: explanation,
                limitations: contextLimitations,
                decision: CameraAngleDecisionSummary(possibleCategories: all, contributing: [], conflicts: [], notes: []))
        }

        // 2. What each source still allows.
        let allowed: [(CameraAngleObservation, Set<CameraAngleCategory>)] = usable.map {
            ($0, CameraAngleRule.categories(low: $0.elevation!.likelyLow, high: $0.elevation!.likelyHigh))
        }
        let possible = allowed.reduce(all) { $0.intersection($1.1) }
        let contributing = usable.map(\.provider)
        let missing = unusable.isEmpty ? "" : " Not available: " + unusable.map(\.summary).joined(separator: " ")

        // 3. Contradiction.
        if possible.isEmpty {
            var conflicts: [String] = []
            for i in 0..<allowed.count {
                for j in (i + 1)..<allowed.count where allowed[i].1.isDisjoint(with: allowed[j].1) {
                    conflicts.append("\(name(allowed[i].0.provider)) points to \(list(allowed[i].1)) but \(name(allowed[j].0.provider)) points to \(list(allowed[j].1)).")
                }
            }
            return CameraAngleFusionOutcome(
                category: .unknown, status: .insufficientEvidence, quality: .none,
                explanation: "The evidence sources disagree, so the camera angle is left unknown. " + conflicts.joined(separator: " "),
                limitations: contextLimitations + usable.flatMap(\.limitations),
                decision: CameraAngleDecisionSummary(possibleCategories: [], contributing: contributing, conflicts: conflicts, notes: []))
        }

        // 4. Ambiguity: some categories are ruled out, but not all but one.
        guard possible.count == 1, let category = possible.first else {
            let ruledOut = all.subtracting(possible)
            let narrowed = ruledOut.isEmpty
                ? "The evidence does not narrow the camera angle."
                : "The evidence rules out \(list(ruledOut)) but cannot separate \(list(possible))."
            let basis = usable.map(\.summary).joined(separator: " ")
            return CameraAngleFusionOutcome(
                category: .unknown, status: .insufficientEvidence, quality: .none,
                explanation: "\(narrowed) \(basis) The size of the angle depends on the lens, which is not known, so the category is left unknown.\(missing)",
                limitations: contextLimitations + usable.flatMap(\.limitations),
                decision: CameraAngleDecisionSummary(possibleCategories: possible, contributing: contributing, conflicts: [],
                                                    notes: ["Ruled out: \(list(ruledOut))."]))
        }

        // 5. A single category remains. Grade it.
        var notes: [String] = []
        var limitations = contextLimitations

        func adjusted(_ o: CameraAngleObservation) -> EvidenceQuality {
            let e = o.elevation!
            let extended = CameraAngleRule.categories(low: e.extendedLow, high: e.extendedHigh)
            return extended == [category] ? o.quality : o.quality.lowered()
        }
        let grades = usable.map(adjusted)
        var quality = grades.max() ?? .low
        if zip(usable, grades).contains(where: { $0.0.quality != $0.1 }) {
            notes.append("A longer lens would shrink the apparent angle, so confidence is reduced.")
            limitations.append("The result is sensitive to the lens: a telephoto lens (above about 35 mm equivalent) could make the true angle smaller than estimated.")
        }
        if usable.count >= 2, grades.allSatisfy({ $0 >= .moderate }) {
            quality = quality.raised()
            notes.append("Two independent sources agree.")
        }

        if anchor?.isUpright == false {
            quality = quality.lowered()
            notes.append("The subject is not upright.")
        }

        if let check = observations.first(where: { $0.provider == .depthTilt && $0.validity.isValid }),
           let hint = check.tiltHint, hint != .level {
            let firmDown = usable.contains { ($0.pitchDown?.likelyLow ?? -99) > 3 }
            let firmUp = usable.contains { ($0.pitchDown?.likelyHigh ?? 99) < -3 }
            if (hint == .down && firmUp) || (hint == .up && firmDown) {
                quality = quality.lowered()
                notes.append("The relative-depth cross-check suggests the opposite camera tilt.")
                limitations.append("Relative depth of head and body contradicts the tilt implied by the main evidence; one of them is unreliable here.")
            } else if (hint == .down && firmDown) || (hint == .up && firmUp) {
                notes.append("The relative-depth cross-check is consistent with the implied tilt.")
            }
        }
        limitations += usable.flatMap(\.limitations)

        let headline: String
        switch category {
        case .highAngle: headline = "The camera appears to be above the subject's eyes, looking down on them."
        case .lowAngle: headline = "The camera appears to be below the subject's eyes, looking up at them."
        default: headline = "The camera appears to be at about the subject's eye height."
        }
        let basis = "Basis: " + usable.map(\.summary).joined(separator: " ")
        let strength = usable.count == 1
            ? " This rests on one source, so it is an inference, not a measurement."
            : " Independent sources agree, but this is still an inference, not a measurement."
        var seen = Set<String>()
        limitations = limitations.filter { seen.insert($0).inserted }

        return CameraAngleFusionOutcome(
            category: category, status: .determined, quality: quality,
            explanation: "\(headline) \(basis)\(strength)\(missing)",
            limitations: limitations,
            decision: CameraAngleDecisionSummary(possibleCategories: possible, contributing: contributing, conflicts: [], notes: notes))
    }

    // MARK: Wording

    private static func name(_ provider: CameraAngleProvider) -> String {
        switch provider {
        case .horizonLine: return "Horizon line"
        case .sceneVerticals: return "Background vertical lines"
        case .subjectGeometry: return "Subject geometry"
        case .headOrientation: return "Head orientation"
        case .depthTilt: return "Relative depth"
        }
    }

    private static func list(_ categories: Set<CameraAngleCategory>) -> String {
        let order: [CameraAngleCategory] = [.lowAngle, .eyeLevel, .highAngle]
        let words = order.filter(categories.contains).map { c -> String in
            switch c {
            case .lowAngle: return "low angle"
            case .eyeLevel: return "eye level"
            case .highAngle: return "high angle"
            case .unknown: return "unknown"
            }
        }
        switch words.count {
        case 0: return "nothing"
        case 1: return words[0]
        case 2: return "\(words[0]) or \(words[1])"
        default: return "\(words[0]), \(words[1]) or \(words[2])"
        }
    }
}
