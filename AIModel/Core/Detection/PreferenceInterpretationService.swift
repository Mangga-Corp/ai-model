import Foundation
import FoundationModels
import os

/// Protocol defining the preference interpretation service interface.
protocol PreferenceInterpreting {
    func interpret(analyses: [PhotoAnalysis], profile: PhotographicPreferenceProfile) async -> PreferenceInsight?
    func isAvailable() -> Bool
}

/// PreferenceInterpretationService — implements Stage D: Preference Interpretation.
///
/// Uses Foundation Models when available to generate natural-language insights
/// grounded in structured measurements. Falls back to deterministic descriptions
/// when the model is unavailable (PRD Rule 5, Stage D fallback requirement).
///
/// Evidence-first: the service NEVER asks the model to estimate characteristics.
/// It receives verified measurements and only produces interpretations.
final class PreferenceInterpretationService: PreferenceInterpreting {

    private let logger = Logger(subsystem: "com.aimodel.PreferenceAnalyzer", category: "Interpretation")

    /// Checks whether Foundation Models is available on this device.
    func isAvailable() -> Bool {
        let model = SystemLanguageModel()
        return model.availability == .available
    }

    /// Generates an insight using Foundation Models, with deterministic fallback.
    func interpret(analyses: [PhotoAnalysis], profile: PhotographicPreferenceProfile) async -> PreferenceInsight? {
        guard !analyses.isEmpty else { return nil }

        if isAvailable() {
            return await interpretWithModel(analyses: analyses, profile: profile)
        } else {
            logger.info("Foundation Models unavailable — using deterministic fallback")
            return interpretDeterministic(analyses: analyses, profile: profile)
        }
    }

    // MARK: - Foundation Models Interpretation

    private func interpretWithModel(analyses: [PhotoAnalysis], profile: PhotographicPreferenceProfile) async -> PreferenceInsight? {
        do {
            let prompt = buildInterpretationPrompt(analyses: analyses, profile: profile)

            let session = LanguageModelSession(instructions: prompt)
            let response = try await session.respond(to: "State the recurring pattern in one short sentence, directly.")
            let text = response.content

            guard !text.isEmpty else {
                return interpretDeterministic(analyses: analyses, profile: profile)
            }

            return PreferenceInsight(
                id: UUID(),
                title: "AI Interpretation",
                description: text,
                category: .general,
                supportingPhotoIDs: analyses.map { $0.referencePhotoID },
                supportingMeasurements: buildMeasurementDictionary(profile: profile),
                evidenceStrength: .moderate,
                interpretationStatus: .interpretation
            )
        } catch {
            logger.error("Foundation Models error: \(error.localizedDescription)")
            return interpretDeterministic(analyses: analyses, profile: profile)
        }
    }

    /// Builds a prompt that supplies ONLY verified measurements as evidence.
    private func buildInterpretationPrompt(analyses: [PhotoAnalysis], profile: PhotographicPreferenceProfile) -> String {
        var evidenceParts: [String] = []
        evidenceParts.append("You are a photography analyst assistant. You will receive only VERIFIED measurements from analyzed photographs.")
        evidenceParts.append("STYLE: Be direct and to the point. Short sentences. No filler, no hedging, no preamble.")
        evidenceParts.append("Maximum 2 sentences. State what the measurements show, nothing more.")
        evidenceParts.append("Do NOT invent, guess, or fabricate any numerical statistics, detection results, or photographic characteristics.")
        evidenceParts.append("Base all interpretations ONLY on the measurements provided below.")
        evidenceParts.append("If the evidence is insufficient for a claim, state that explicitly with 'Insufficient evidence'.")
        evidenceParts.append("")
        evidenceParts.append("=== Verified Measurements ===")
        evidenceParts.append("Photos analyzed: \(profile.successfullyAnalyzedCount) of \(profile.photoCount)")
        evidenceParts.append("")

        // Composition
        if let pos = profile.subjectPositionDistribution {
            evidenceParts.append("Subject position distribution:")
            evidenceParts.append("  Mean X (left=0, right=1): \(String(format: "%.3f", pos.meanX))")
            evidenceParts.append("  Mean Y (top=0, bottom=1): \(String(format: "%.3f", pos.meanY))")
            evidenceParts.append("  Std dev X: \(String(format: "%.3f", pos.stdDevX)) | Std dev Y: \(String(format: "%.3f", pos.stdDevY))")
            evidenceParts.append("  Consistent: \(pos.isConsistent ? "yes" : "no")")
            evidenceParts.append("")
        }

        if let sz = profile.subjectSizeDistribution {
            evidenceParts.append("Subject size distribution:")
            evidenceParts.append("  Mean area (0-1): \(String(format: "%.3f", sz.meanArea))")
            evidenceParts.append("  Range: \(String(format: "%.3f", sz.minArea)) to \(String(format: "%.3f", sz.maxArea))")
            evidenceParts.append("")
        }

        if let angle = profile.horizonAngleDistribution {
            evidenceParts.append("Horizon angle distribution:")
            evidenceParts.append("  Mean angle: \(String(format: "%.1f", angle.meanAngle))°")
            evidenceParts.append("  Std dev: \(String(format: "%.1f", angle.stdDev))°")
            evidenceParts.append("  Sample count: \(angle.sampleCount)")
            evidenceParts.append("")
        }

        // Lighting
        if let b = profile.brightnessDistribution {
            evidenceParts.append("Brightness distribution:")
            evidenceParts.append("  Mean brightness (0-1): \(String(format: "%.3f", b.mean))")
            evidenceParts.append("  Std dev (contrast): \(String(format: "%.3f", b.stdDev))")
            evidenceParts.append("  Consistent: \(b.isConsistent ? "yes" : "no")")
            evidenceParts.append("")
        }

        if let s = profile.saturationDistribution {
            evidenceParts.append("Saturation distribution:")
            evidenceParts.append("  Mean saturation (0-1): \(String(format: "%.3f", s.mean))")
            evidenceParts.append("  Consistent: \(s.isConsistent ? "yes" : "no")")
            evidenceParts.append("")
        }

        if let ct = profile.colorTemperatureDistribution {
            evidenceParts.append("Color temperature:")
            evidenceParts.append("  Mean (-1=cool, +1=warm): \(String(format: "%.3f", ct.mean))")
            evidenceParts.append("")
        }

        // Subject angle
        if let hy = profile.headYawDistribution {
            evidenceParts.append("Head yaw (turn) distribution:")
            evidenceParts.append("  Mean yaw (degrees): \(String(format: "%.1f", hy.mean))")
            evidenceParts.append("  Std dev: \(String(format: "%.1f", hy.stdDev))")
            evidenceParts.append("  Consistent: \(hy.isConsistent ? "yes" : "no")")
            evidenceParts.append("")
        }

        if let bo = profile.bodyOrientationDistribution {
            evidenceParts.append("Body orientation distribution:")
            evidenceParts.append("  Mean angle (degrees): \(String(format: "%.1f", bo.mean))")
            evidenceParts.append("  Std dev: \(String(format: "%.1f", bo.stdDev))")
            evidenceParts.append("  Consistent: \(bo.isConsistent ? "yes" : "no")")
            evidenceParts.append("")
        }

        // Aesthetics
        if let ae = profile.aestheticScoreDistribution {
            evidenceParts.append("Aesthetic quality:")
            evidenceParts.append("  Mean score (-1 to +1): \(String(format: "%.3f", ae.mean))")
            evidenceParts.append("  Std dev: \(String(format: "%.3f", ae.stdDev))")
            evidenceParts.append("")
        }

        // Rule of thirds
        if !profile.ruleOfThirdsPatterns.isEmpty {
            evidenceParts.append("Rule of thirds placement (count):")
            for (zone, count) in profile.ruleOfThirdsPatterns.sorted(by: { $0.value > $1.value }) {
                evidenceParts.append("  \(zone.rawValue): \(count)")
            }
            evidenceParts.append("")
        }

        // Color
        if !profile.colorHarmonyPatterns.isEmpty {
            evidenceParts.append("Color harmony (count):")
            for (harmony, count) in profile.colorHarmonyPatterns.sorted(by: { $0.value > $1.value }) {
                evidenceParts.append("  \(harmony.rawValue): \(count)")
            }
            evidenceParts.append("")
        }

        // Scene
        if !profile.sceneCategories.isEmpty {
            evidenceParts.append("Scene categories (count):")
            for (category, count) in profile.sceneCategories.sorted(by: { $0.value > $1.value }) {
                evidenceParts.append("  \(category): \(count)")
            }
            evidenceParts.append("")
        }

        // Inconsistencies
        if let ratio = profile.symmetryRatio, ratio > 0 {
            evidenceParts.append("Symmetry:")
            evidenceParts.append("  Fraction of photos strongly mirrored: \(String(format: "%.2f", ratio))")
            for (axis, count) in profile.symmetryAxisPatterns.sorted(by: { $0.value > $1.value }) {
                evidenceParts.append("  \(axis.rawValue) axis: \(count)")
            }
            evidenceParts.append("")
        }

        if let ratio = profile.goldenRatioHitRatio, ratio > 0 {
            evidenceParts.append("Golden ratio:")
            evidenceParts.append("  Fraction of subjects near a golden-ratio division: \(String(format: "%.2f", ratio))")
            evidenceParts.append("")
        }

        if !profile.mixedPatterns.isEmpty {
            evidenceParts.append("Inconsistencies detected:")
            for pattern in profile.mixedPatterns {
                evidenceParts.append("  - \(pattern.description)")
            }
            evidenceParts.append("")
        }

        evidenceParts.append("=== Limitations ===")
        for limitation in profile.limitations {
            evidenceParts.append("- \(limitation)")
        }

        return evidenceParts.joined(separator: "\n")
    }

    private func buildMeasurementDictionary(profile: PhotographicPreferenceProfile) -> [String: Double] {
        var dict: [String: Double] = [:]
        if let pos = profile.subjectPositionDistribution {
            dict["position_meanX"] = pos.meanX
            dict["position_meanY"] = pos.meanY
            dict["position_stdDevX"] = pos.stdDevX
            dict["position_stdDevY"] = pos.stdDevY
        }
        if let sz = profile.subjectSizeDistribution {
            dict["size_meanArea"] = sz.meanArea
            dict["size_minArea"] = sz.minArea
            dict["size_maxArea"] = sz.maxArea
        }
        if let angle = profile.horizonAngleDistribution {
            dict["horizon_meanAngle"] = angle.meanAngle
            dict["horizon_stdDev"] = angle.stdDev
        }
        if let b = profile.brightnessDistribution {
            dict["brightness_mean"] = b.mean
            dict["brightness_stdDev"] = b.stdDev
        }
        if let s = profile.saturationDistribution {
            dict["saturation_mean"] = s.mean
            dict["saturation_stdDev"] = s.stdDev
        }
        if let ct = profile.colorTemperatureDistribution {
            dict["colorTemperature_mean"] = ct.mean
        }
        if let hy = profile.headYawDistribution {
            dict["headYaw_mean"] = hy.mean
            dict["headYaw_stdDev"] = hy.stdDev
        }
        if let bo = profile.bodyOrientationDistribution {
            dict["bodyOrientation_mean"] = bo.mean
            dict["bodyOrientation_stdDev"] = bo.stdDev
        }
        if let ae = profile.aestheticScoreDistribution {
            dict["aesthetic_mean"] = ae.mean
            dict["aesthetic_stdDev"] = ae.stdDev
        }
        return dict
    }

    // MARK: - Deterministic Fallback

    private func interpretDeterministic(analyses: [PhotoAnalysis], profile: PhotographicPreferenceProfile) -> PreferenceInsight? {
        guard profile.successfullyAnalyzedCount > 0 else { return nil }

        var parts: [String] = []

        if let pos = profile.subjectPositionDistribution {
            if pos.isConsistent {
                parts.append(describeConsistentPosition(meanX: pos.meanX, meanY: pos.meanY))
            } else {
                parts.append("Subject placement varies across your photographs.")
            }
        }

        if let sz = profile.subjectSizeDistribution {
            if sz.meanArea < 0.15 {
                parts.append("Subjects small in frame. Environmental framing.")
            } else if sz.meanArea > 0.5 {
                parts.append("Subjects fill most of the frame. Close framing.")
            }
        }

        if let b = profile.brightnessDistribution {
            if b.mean < 0.3 {
                parts.append("Your photographs tend toward darker exposure.")
            } else if b.mean > 0.65 {
                parts.append("Your photographs tend toward bright, well-exposed frames.")
            }
        }

        if let s = profile.saturationDistribution {
            if s.mean < 0.2 {
                parts.append("Your color palette is relatively muted.")
            } else if s.mean > 0.5 {
                parts.append("Your photographs use vivid colors.")
            }
        }

        if let ct = profile.colorTemperatureDistribution {
            if ct.mean > 0.15 {
                parts.append("Your color temperature leans warm.")
            } else if ct.mean < -0.15 {
                parts.append("Your color temperature leans cool.")
            }
        }

        if let hy = profile.headYawDistribution, hy.isConsistent, abs(hy.mean) > 15 {
            let direction = hy.mean > 0 ? "right" : "left"
            parts.append("Subjects consistently face the \(direction) side of the frame.")
        }

        if let bo = profile.bodyOrientationDistribution, bo.isConsistent {
            if abs(bo.mean) < 10 {
                parts.append("Subjects are consistently oriented parallel to the frame.")
            } else if abs(bo.mean) > 45 {
                parts.append("Subjects are often shot at a diagonal angle.")
            }
        }

        if let ae = profile.aestheticScoreDistribution {
            if ae.mean > 0.3 {
                parts.append("Your photographs score highly on aesthetic quality.")
            } else if ae.mean < -0.1 {
                parts.append("Your photographs score lower on aesthetic quality.")
            }
        }

        if let angle = profile.horizonAngleDistribution, angle.sampleCount > 0 {
            if abs(angle.meanAngle) < 5.0 {
                parts.append("Horizons are generally kept level.")
            } else {
                parts.append("Horizon alignment shows variation.")
            }
        }

        guard !parts.isEmpty else {
            return PreferenceInsight(
                id: UUID(),
                title: "Limited Measurable Data",
                description: "Not enough measurable characteristics to interpret.",
                category: .general,
                supportingPhotoIDs: analyses.map { $0.referencePhotoID },
                supportingMeasurements: [:],
                evidenceStrength: .insufficient,
                interpretationStatus: .observation
            )
        }

        return PreferenceInsight(
            id: UUID(),
            title: "Photographic Pattern Summary",
            description: parts.joined(separator: " "),
            category: .general,
            supportingPhotoIDs: analyses.map { $0.referencePhotoID },
            supportingMeasurements: buildMeasurementDictionary(profile: profile),
            evidenceStrength: .moderate,
            interpretationStatus: .observation
        )
    }

    private func describeConsistentPosition(meanX: Double, meanY: Double) -> String {
        let horizontal: String
        if meanX < 0.33 { horizontal = "left side" }
        else if meanX > 0.67 { horizontal = "right side" }
        else { horizontal = "center" }

        let vertical: String
        if meanY < 0.33 { vertical = "upper" }
        else if meanY > 0.67 { vertical = "lower" }
        else { vertical = "middle" }

        if horizontal == "center" && vertical == "middle" {
            return "Subjects are consistently centered in your photographs."
        }
        return "Subjects consistently in the \(vertical) \(horizontal)."
    }
}
