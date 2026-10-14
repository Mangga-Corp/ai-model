import Foundation
import CoreGraphics

/// Protocol defining the preference aggregation service interface.
protocol PreferenceAggregating {
    func aggregate(analyses: [PhotoAnalysis]) -> PhotographicPreferenceProfile
}

/// PreferenceAggregationService — implements Stage C: Cross-Image Pattern Analysis.
///
/// Uses deterministic Swift logic to aggregate measurements across photographs.
/// Calculates distributions, proportions, medians, and variability.
/// Identifies repeated characteristics and inconsistent patterns.
final class PreferenceAggregationService: PreferenceAggregating {

    // Thresholds for consistency determination
    private let positionStdDevThreshold: Double = 0.15
    private let sizeStdDevThreshold: Double = 0.10
    private let angleStdDevThreshold: Double = 15.0
    private let horizonPositionStdDevThreshold: Double = 0.15
    private let valueStdDevThreshold: Double = 0.10
    private let brightnessStdDevThreshold: Double = 0.12
    private let saturationStdDevThreshold: Double = 0.15
    private let headAngleStdDevThreshold: Double = 12.0

    func aggregate(analyses: [PhotoAnalysis]) -> PhotographicPreferenceProfile {
        let photoCount = analyses.count
        let successfullyAnalyzedCount = analyses.filter { $0.status != .failed }.count

        // --- Composition ---
        let positions = analyses.compactMap { $0.subjectPosition }
        let subjectPositionDistribution: PositionDistribution? = positions.isEmpty ? nil : computePositionDistribution(positions: positions)

        // Half-body position — the guide box targets this, not the full-body centre.
        let halfBodyPositions = analyses.compactMap { $0.halfBodyPosition }
        let halfBodyPositionDistribution: PositionDistribution? = halfBodyPositions.isEmpty ? nil : computePositionDistribution(positions: halfBodyPositions)

        let sizes = analyses.compactMap { $0.subjectSize }
        let subjectSizeDistribution: SizeDistribution? = sizes.isEmpty ? nil : computeSizeDistribution(sizes: sizes)

        let angles = analyses.compactMap { $0.horizonAngle }
        let horizonAngleDistribution: AngleDistribution? = angles.isEmpty ? nil : computeAngleDistribution(angles: angles)

        // --- Lighting ---
        let brightnesses = analyses.compactMap { $0.meanBrightness }
        let brightnessDistribution: ValueDistribution? = brightnesses.isEmpty ? nil : computeValueDistribution(values: brightnesses, threshold: brightnessStdDevThreshold)

        let saturations = analyses.compactMap { $0.meanSaturation }
        let saturationDistribution: ValueDistribution? = saturations.isEmpty ? nil : computeValueDistribution(values: saturations, threshold: saturationStdDevThreshold)

        let colorTemps = analyses.compactMap { $0.colorTemperature }
        let colorTemperatureDistribution: ValueDistribution? = colorTemps.isEmpty ? nil : computeValueDistribution(values: colorTemps, threshold: valueStdDevThreshold)

        // --- Head Angle ---
        let headYaws = analyses.compactMap { $0.headYaw }
        let headYawDistribution: ValueDistribution? = headYaws.isEmpty ? nil : computeValueDistribution(values: headYaws, threshold: headAngleStdDevThreshold)

        let headRolls = analyses.compactMap { $0.headRoll }
        let headRollDistribution: ValueDistribution? = headRolls.isEmpty ? nil : computeValueDistribution(values: headRolls, threshold: headAngleStdDevThreshold)

        // --- Body Pose ---
        let bodyOrientations = analyses.compactMap { $0.bodyOrientation }
        let bodyOrientationDistribution: ValueDistribution? = bodyOrientations.isEmpty ? nil : computeValueDistribution(values: bodyOrientations, threshold: angleStdDevThreshold)

        let bodySymmetries = analyses.compactMap { $0.bodySymmetry }
        let bodySymmetryDistribution: ValueDistribution? = bodySymmetries.isEmpty ? nil : computeValueDistribution(values: bodySymmetries, threshold: valueStdDevThreshold)

        // --- Saliency ---
        let saliencyIntensities = analyses.compactMap { $0.saliencyIntensity }
        let saliencyIntensityDistribution: ValueDistribution? = saliencyIntensities.isEmpty ? nil : computeValueDistribution(values: saliencyIntensities, threshold: valueStdDevThreshold)

        // --- Aesthetics ---
        let aestheticScores = analyses.compactMap { $0.aestheticScore }
        let aestheticScoreDistribution: ValueDistribution? = aestheticScores.isEmpty ? nil : computeValueDistribution(values: aestheticScores, threshold: 0.2)

        // --- Leading Lines ---
        let lineCounts = analyses.compactMap { $0.leadingLines?.lineCount }.map { Double($0) }
        let leadingLinesLineCountDistribution: ValueDistribution? = lineCounts.isEmpty ? nil : computeValueDistribution(values: lineCounts, threshold: 2.0)

        let lineAngles = analyses.compactMap { $0.leadingLines?.dominantAngle }
        let leadingLinesAngleDistribution: ValueDistribution? = lineAngles.isEmpty ? nil : computeValueDistribution(values: lineAngles, threshold: 20.0)

        let convergences = analyses.compactMap { $0.leadingLines?.convergenceStrength }
        let leadingLinesConvergenceDistribution: ValueDistribution? = convergences.isEmpty ? nil : computeValueDistribution(values: convergences, threshold: 0.2)

        let withLines = analyses.filter { $0.leadingLines?.isAvailable ?? false }
        let diagonalCount = withLines.filter { $0.leadingLines?.hasDiagonalDominance ?? false }.count
        let diagonalDominanceRatio: Double? = withLines.isEmpty ? nil : Double(diagonalCount) / Double(withLines.count)

        // --- Rule of Thirds ---
        let ruleOfThirdsPatterns = aggregateRuleOfThirds(analyses: analyses)

        // --- Scene & Color ---
        let sceneCategories = aggregateSceneCategories(analyses: analyses)
        let negativeSpacePatterns = aggregateNegativeSpacePatterns(analyses: analyses)
        let colorHarmonyPatterns = aggregateColorHarmonyPatterns(analyses: analyses)
        let dominantColorPalette = aggregateDominantColors(analyses: analyses)

        // --- Lighting Direction ---
        let lightDirectionPatterns = aggregateLightDirectionPatterns(analyses: analyses)

        // --- Symmetry ---
        let symmetryScores = analyses.compactMap { $0.symmetry?.dominant }
        let symmetryDistribution: ValueDistribution? = symmetryScores.isEmpty ? nil : computeValueDistribution(values: symmetryScores, threshold: 0.15)
        let bilateralScores = analyses.compactMap { $0.symmetry?.bilateral }
        let bilateralDistribution: ValueDistribution? = bilateralScores.isEmpty ? nil : computeValueDistribution(values: bilateralScores, threshold: 0.15)
        let symmetricCount = analyses.filter { $0.hasSymmetry }.count
        let symmetryRatio: Double? = analyses.isEmpty ? nil : Double(symmetricCount) / Double(analyses.count)
        let symmetryAxisPatterns = aggregateSymmetryAxes(analyses: analyses)

        // --- Golden Ratio ---
        let goldenAlignmentStrengths = analyses.compactMap { $0.goldenRatio?.alignmentStrength }
        let goldenRatioDistribution: ValueDistribution? = goldenAlignmentStrengths.isEmpty ? nil : computeValueDistribution(values: goldenAlignmentStrengths, threshold: 0.2)
        let goldenPointCount = analyses.filter { $0.hasGoldenRatio }.count
        let goldenRatioHitRatio: Double? = analyses.isEmpty ? nil : Double(goldenPointCount) / Double(analyses.count)

        // --- Mixed/inconsistent patterns ---
        let inconsistencies = detectInconsistencies(
            analyses: analyses,
            positionDistribution: subjectPositionDistribution,
            sizeDistribution: subjectSizeDistribution,
            angleDistribution: horizonAngleDistribution,
            brightnessDistribution: brightnessDistribution,
            saturationDistribution: saturationDistribution,
            headYawDistribution: headYawDistribution,
            bodyOrientationDistribution: bodyOrientationDistribution,
            aestheticScoreDistribution: aestheticScoreDistribution
        )

        // --- Build deterministic summary ---
        let summary = buildDeterministicSummary(
            analyses: analyses,
            positionDistribution: subjectPositionDistribution,
            sizeDistribution: subjectSizeDistribution,
            angleDistribution: horizonAngleDistribution,
            brightnessDistribution: brightnessDistribution,
            saturationDistribution: saturationDistribution,
            colorTemperatureDistribution: colorTemperatureDistribution,
            headYawDistribution: headYawDistribution,
            bodyOrientationDistribution: bodyOrientationDistribution,
            aestheticScoreDistribution: aestheticScoreDistribution,
            sceneCategories: sceneCategories,
            negativeSpacePatterns: negativeSpacePatterns,
            ruleOfThirdsPatterns: ruleOfThirdsPatterns,
            lightDirectionPatterns: lightDirectionPatterns,
            leadingLinesLineCountDistribution: leadingLinesLineCountDistribution,
            diagonalDominanceRatio: diagonalDominanceRatio,
            symmetryRatio: symmetryRatio,
            symmetryAxisPatterns: symmetryAxisPatterns,
            goldenRatioHitRatio: goldenRatioHitRatio,
            inconsistencies: inconsistencies
        )

        // --- Build insights ---
        let insights = buildInsights(
            analyses: analyses,
            positionDistribution: subjectPositionDistribution,
            sizeDistribution: subjectSizeDistribution,
            angleDistribution: horizonAngleDistribution,
            brightnessDistribution: brightnessDistribution,
            saturationDistribution: saturationDistribution,
            colorTemperatureDistribution: colorTemperatureDistribution,
            headYawDistribution: headYawDistribution,
            bodyOrientationDistribution: bodyOrientationDistribution,
            aestheticScoreDistribution: aestheticScoreDistribution,
            sceneCategories: sceneCategories,
            negativeSpacePatterns: negativeSpacePatterns,
            ruleOfThirdsPatterns: ruleOfThirdsPatterns,
            colorHarmonyPatterns: colorHarmonyPatterns,
            lightDirectionPatterns: lightDirectionPatterns,
            leadingLinesLineCountDistribution: leadingLinesLineCountDistribution,
            leadingLinesAngleDistribution: leadingLinesAngleDistribution,
            diagonalDominanceRatio: diagonalDominanceRatio,
            symmetryDistribution: symmetryDistribution,
            bilateralDistribution: bilateralDistribution,
            symmetryRatio: symmetryRatio,
            symmetryAxisPatterns: symmetryAxisPatterns,
            goldenRatioDistribution: goldenRatioDistribution,
            goldenRatioHitRatio: goldenRatioHitRatio,
            inconsistencies: inconsistencies
        )

        // --- Limitations ---
        let limitations = buildLimitations(analyses: analyses)

        return PhotographicPreferenceProfile(
            id: UUID(),
            photoCount: photoCount,
            successfullyAnalyzedCount: successfullyAnalyzedCount,
            subjectPositionDistribution: subjectPositionDistribution,
            halfBodyPositionDistribution: halfBodyPositionDistribution,
            subjectSizeDistribution: subjectSizeDistribution,
            horizonAngleDistribution: horizonAngleDistribution,
            brightnessDistribution: brightnessDistribution,
            saturationDistribution: saturationDistribution,
            colorTemperatureDistribution: colorTemperatureDistribution,
            headYawDistribution: headYawDistribution,
            headRollDistribution: headRollDistribution,
            bodyOrientationDistribution: bodyOrientationDistribution,
            bodySymmetryDistribution: bodySymmetryDistribution,
            saliencyIntensityDistribution: saliencyIntensityDistribution,
            aestheticScoreDistribution: aestheticScoreDistribution,
            leadingLinesLineCountDistribution: leadingLinesLineCountDistribution,
            leadingLinesAngleDistribution: leadingLinesAngleDistribution,
            leadingLinesConvergenceDistribution: leadingLinesConvergenceDistribution,
            diagonalDominanceRatio: diagonalDominanceRatio,
            ruleOfThirdsPatterns: ruleOfThirdsPatterns,
            sceneCategories: sceneCategories,
            negativeSpacePatterns: negativeSpacePatterns,
            colorHarmonyPatterns: colorHarmonyPatterns,
            dominantColorPalette: dominantColorPalette,
            lightDirectionPatterns: lightDirectionPatterns,
            symmetryDistribution: symmetryDistribution,
            bilateralDistribution: bilateralDistribution,
            symmetryRatio: symmetryRatio,
            symmetryAxisPatterns: symmetryAxisPatterns,
            goldenRatioDistribution: goldenRatioDistribution,
            goldenRatioHitRatio: goldenRatioHitRatio,
            summary: summary,
            insights: insights,
            analyses: analyses,
            photos: [],
            mixedPatterns: inconsistencies,
            limitations: limitations,
            generatedAt: Date()
        )
    }

    // MARK: - Distribution Calculations

    private func computePositionDistribution(positions: [CGPoint]) -> PositionDistribution {
        let xs = positions.map { Double($0.x) }
        let ys = positions.map { Double($0.y) }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let stdDevX = computeStdDev(xs, mean: meanX)
        let stdDevY = computeStdDev(ys, mean: meanY)
        return PositionDistribution(
            meanX: meanX, meanY: meanY, stdDevX: stdDevX, stdDevY: stdDevY,
            isConsistent: stdDevX < positionStdDevThreshold && stdDevY < positionStdDevThreshold
        )
    }

    private func computeSizeDistribution(sizes: [Double]) -> SizeDistribution {
        let meanArea = sizes.reduce(0, +) / Double(sizes.count)
        let minArea = sizes.min() ?? 0
        let maxArea = sizes.max() ?? 0
        let stdDev = computeStdDev(sizes, mean: meanArea)
        return SizeDistribution(meanArea: meanArea, minArea: minArea, maxArea: maxArea, stdDev: stdDev, isConsistent: stdDev < sizeStdDevThreshold)
    }

    private func computeAngleDistribution(angles: [Double]) -> AngleDistribution {
        let mean = angles.reduce(0, +) / Double(angles.count)
        let stdDev = computeStdDev(angles, mean: mean)
        return AngleDistribution(meanAngle: mean, stdDev: stdDev, sampleCount: angles.count)
    }

    private func computeValueDistribution(values: [Double], threshold: Double) -> ValueDistribution {
        let mean = values.reduce(0, +) / Double(values.count)
        let stdDev = computeStdDev(values, mean: mean)
        return ValueDistribution(
            mean: mean, stdDev: stdDev,
            min: values.min() ?? 0, max: values.max() ?? 0,
            sampleCount: values.count,
            isConsistent: stdDev < threshold
        )
    }

    // MARK: - Aggregation Helpers

    private func aggregateSceneCategories(analyses: [PhotoAnalysis]) -> [String: Int] {
        var categoryCounts: [String: Int] = [:]
        for analysis in analyses {
            for (identifier, confidence) in analysis.sceneClassifications {
                if confidence > 0.3 {
                    categoryCounts[identifier, default: 0] += 1
                }
            }
        }
        return categoryCounts
    }

    private func aggregateNegativeSpacePatterns(analyses: [PhotoAnalysis]) -> [NegativeSpaceDistribution: Int] {
        var patternCounts: [NegativeSpaceDistribution: Int] = [:]
        for analysis in analyses {
            if let pattern = analysis.negativeSpaceDistribution {
                patternCounts[pattern, default: 0] += 1
            }
        }
        return patternCounts
    }

    private func aggregateRuleOfThirds(analyses: [PhotoAnalysis]) -> [RuleOfThirds: Int] {
        var counts: [RuleOfThirds: Int] = [:]
        for analysis in analyses {
            if let zone = analysis.ruleOfThirdsAlignment {
                counts[zone, default: 0] += 1
            }
        }
        return counts
    }

    private func aggregateColorHarmonyPatterns(analyses: [PhotoAnalysis]) -> [ColorHarmony: Int] {
        var counts: [ColorHarmony: Int] = [:]
        for analysis in analyses {
            if let harmony = analysis.colorHarmony {
                counts[harmony, default: 0] += 1
            }
        }
        return counts
    }

    /// Counts which symmetry axis dominated across photos.
    private func aggregateSymmetryAxes(analyses: [PhotoAnalysis]) -> [SymmetryAxis: Int] {
        var counts: [SymmetryAxis: Int] = [:]
        for analysis in analyses {
            if let symmetry = analysis.symmetry, symmetry.isSymmetric {
                counts[symmetry.dominantAxis, default: 0] += 1
            }
        }
        return counts
    }

    /// Aggregates light-direction counts, excluding low-confidence estimates.
    private func aggregateLightDirectionPatterns(analyses: [PhotoAnalysis]) -> [LightDirection: Int] {
        var counts: [LightDirection: Int] = [:]
        for analysis in analyses {
            if analysis.hasLightDirection, let direction = analysis.lightDirection {
                counts[direction, default: 0] += 1
            }
        }
        return counts
    }

    private func aggregateDominantColors(analyses: [PhotoAnalysis]) -> [DominantColor] {
        var colorProportions: [String: (color: DominantColor, totalProportion: Double, count: Int)] = [:]

        for analysis in analyses {
            guard let colors = analysis.dominantColors else { continue }
            for color in colors {
                let key = color.hexString
                if var existing = colorProportions[key] {
                    existing.totalProportion += color.proportion
                    existing.count += 1
                    colorProportions[key] = existing
                } else {
                    colorProportions[key] = (color: color, totalProportion: color.proportion, count: 1)
                }
            }
        }

        // Return top colors by average proportion
        return colorProportions.values
            .sorted { $0.totalProportion > $1.totalProportion }
            .prefix(5)
            .map { entry in
                DominantColor(
                    red: entry.color.red,
                    green: entry.color.green,
                    blue: entry.color.blue,
                    proportion: entry.totalProportion / Double(entry.count)
                )
            }
    }

    // MARK: - Inconsistency Detection

    private func detectInconsistencies(
        analyses: [PhotoAnalysis],
        positionDistribution: PositionDistribution?,
        sizeDistribution: SizeDistribution?,
        angleDistribution: AngleDistribution?,
        brightnessDistribution: ValueDistribution?,
        saturationDistribution: ValueDistribution?,
        headYawDistribution: ValueDistribution?,
        bodyOrientationDistribution: ValueDistribution?,
        aestheticScoreDistribution: ValueDistribution?
    ) -> [Inconsistency] {
        var inconsistencies: [Inconsistency] = []

        if let pos = positionDistribution, !pos.isConsistent {
            inconsistencies.append(Inconsistency(
                characteristic: .subjectPlacement,
                description: "Subject placement varies considerably across the selected photographs."
            ))
        }

        if let sz = sizeDistribution, !sz.isConsistent {
            inconsistencies.append(Inconsistency(
                characteristic: .subjectSize,
                description: "Subject size varies considerably across the selected photographs."
            ))
        }

        let missingSubjectCount = analyses.filter { $0.subjectPosition == nil }.count
        if missingSubjectCount > 0 && missingSubjectCount == analyses.count {
            inconsistencies.append(Inconsistency(
                characteristic: .subjectPlacement,
                description: "No subjects were detected in any of the selected photographs."
            ))
        }

        let missingHorizonCount = analyses.filter { $0.horizonAngle == nil }.count
        if missingHorizonCount > analyses.count / 2 && analyses.count > 2 {
            inconsistencies.append(Inconsistency(
                characteristic: .horizonAlignment,
                description: "Horizon undetectable in most photos. Alignment patterns unreliable."
            ))
        }

        if let b = brightnessDistribution, !b.isConsistent {
            inconsistencies.append(Inconsistency(
                characteristic: .brightness,
                description: "Brightness varies widely. Mixed bright and dark conditions."
            ))
        }

        if let s = saturationDistribution, !s.isConsistent {
            inconsistencies.append(Inconsistency(
                characteristic: .saturation,
                description: "Color saturation varies considerably across your photographs."
            ))
        }

        if let hy = headYawDistribution, !hy.isConsistent {
            inconsistencies.append(Inconsistency(
                characteristic: .headAngle,
                description: "Head angles vary widely. Subjects face different directions."
            ))
        }

        if let bo = bodyOrientationDistribution, !bo.isConsistent {
            inconsistencies.append(Inconsistency(
                characteristic: .bodyOrientation,
                description: "Body orientation varies considerably across your photographs."
            ))
        }

        return inconsistencies
    }

    // MARK: - Deterministic Summary

    private func buildDeterministicSummary(
        analyses: [PhotoAnalysis],
        positionDistribution: PositionDistribution?,
        sizeDistribution: SizeDistribution?,
        angleDistribution: AngleDistribution?,
        brightnessDistribution: ValueDistribution?,
        saturationDistribution: ValueDistribution?,
        colorTemperatureDistribution: ValueDistribution?,
        headYawDistribution: ValueDistribution?,
        bodyOrientationDistribution: ValueDistribution?,
        aestheticScoreDistribution: ValueDistribution?,
        sceneCategories: [String: Int],
        negativeSpacePatterns: [NegativeSpaceDistribution: Int],
        ruleOfThirdsPatterns: [RuleOfThirds: Int],
        lightDirectionPatterns: [LightDirection: Int],
        leadingLinesLineCountDistribution: ValueDistribution?,
        diagonalDominanceRatio: Double?,
        symmetryRatio: Double?,
        symmetryAxisPatterns: [SymmetryAxis: Int],
        goldenRatioHitRatio: Double?,
        inconsistencies: [Inconsistency]
    ) -> String {
        var parts: [String] = []

        // Subject placement
        if let pos = positionDistribution {
            if pos.isConsistent {
                parts.append(describeConsistentPosition(meanX: pos.meanX, meanY: pos.meanY))
            } else {
                parts.append("Subject placement varies.")
            }
        }

        // Subject size
        if let sz = sizeDistribution {
            if sz.meanArea < 0.15 {
                parts.append("Subjects are small in frame.")
            } else if sz.meanArea > 0.5 {
                parts.append("Subjects fill most of the frame.")
            } else {
                parts.append("Subjects occupy a moderate portion of frame.")
            }
        }

        // Lighting
        if let b = brightnessDistribution {
            if b.mean < 0.3 {
                parts.append("Darker overall.")
            } else if b.mean > 0.7 {
                parts.append("Bright and well-exposed.")
            }
        }

        if let s = saturationDistribution {
            if s.mean < 0.2 {
                parts.append("Muted color palette.")
            } else if s.mean > 0.5 {
                parts.append("Vivid, saturated colors.")
            }
        }

        if let ct = colorTemperatureDistribution {
            if ct.mean > 0.1 {
                parts.append("Warm color temperature.")
            } else if ct.mean < -0.1 {
                parts.append("Cool color temperature.")
            }
        }

        // Head angle
        if let hy = headYawDistribution {
            if hy.isConsistent && abs(hy.mean) > 15 {
                let direction = hy.mean > 0 ? "right" : "left"
                parts.append("Subjects face the \(direction) side.")
            }
        }

        // Body orientation
        if let bo = bodyOrientationDistribution, bo.isConsistent {
            if abs(bo.mean) < 10 {
                parts.append("Subjects parallel to frame.")
            } else if abs(bo.mean) > 45 {
                parts.append("Subjects often shot diagonally.")
            }
        }

        // Aesthetic
        if let ae = aestheticScoreDistribution {
            if ae.mean > 0.3 {
                parts.append("High aesthetic scores.")
            } else if ae.mean < -0.1 {
                parts.append("Lower aesthetic scores.")
            }
        }

        // Horizon
        if let angle = angleDistribution, angle.sampleCount > 0 {
            if abs(angle.meanAngle) < 5.0 {
                parts.append("Horizons generally level.")
            } else {
                parts.append("Horizon alignment varies.")
            }
        }

        // Scene diversity
        let dominantScene = sceneCategories.max { $0.value < $1.value }.map { $0.key }
        if let scene = dominantScene {
            parts.append("Common content: \(scene.lowercased()).")
        }

        // Rule of thirds
        let topZone = ruleOfThirdsPatterns.max { $0.value < $1.value }.map { $0.key }
        if let zone = topZone, let count = ruleOfThirdsPatterns[zone], count > analyses.count / 3 {
            parts.append("Subjects often in the \(zone.rawValue) zone.")
        }

        // Lighting direction
        if !lightDirectionPatterns.isEmpty {
            let totalWithDirection = lightDirectionPatterns.values.reduce(0, +)
            let topDirection = lightDirectionPatterns.max { $0.value < $1.value }
            if let direction = topDirection?.key, let count = topDirection?.value,
               Double(count) / Double(totalWithDirection) > 0.4 {
                parts.append("Often lit from the \(direction.rawValue.lowercased()).")
            }
        }

        // Leading lines
        if let lineCount = leadingLinesLineCountDistribution, lineCount.mean >= 2 {
            parts.append("Frequent strong structural lines.")
        }
        if let ratio = diagonalDominanceRatio, ratio > 0.4 {
            parts.append("Lines often diagonal. Dynamic compositions.")
        }

        // Symmetry
        if let ratio = symmetryRatio, ratio > 0.4 {
            let topAxis = symmetryAxisPatterns.max { $0.value < $1.value }
            let axisText = topAxis?.key.rawValue.lowercased() ?? "left-right"
            parts.append("Strong \(axisText) mirror symmetry.")
        }

        // Golden ratio
        if let goldenRatio = goldenRatioHitRatio, goldenRatio > 0.4 {
            parts.append("Subjects near golden-ratio divisions.")
        }

        // Inconsistencies
        if !inconsistencies.isEmpty {
            parts.append("Some characteristics vary.")
        }

        return parts.joined(separator: " ")
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
            return "Subjects consistently near center."
        }
        return "Subjects consistently in the \(vertical) \(horizontal)."
    }

    // MARK: - Insights

    private func buildInsights(
        analyses: [PhotoAnalysis],
        positionDistribution: PositionDistribution?,
        sizeDistribution: SizeDistribution?,
        angleDistribution: AngleDistribution?,
        brightnessDistribution: ValueDistribution?,
        saturationDistribution: ValueDistribution?,
        colorTemperatureDistribution: ValueDistribution?,
        headYawDistribution: ValueDistribution?,
        bodyOrientationDistribution: ValueDistribution?,
        aestheticScoreDistribution: ValueDistribution?,
        sceneCategories: [String: Int],
        negativeSpacePatterns: [NegativeSpaceDistribution: Int],
        ruleOfThirdsPatterns: [RuleOfThirds: Int],
        colorHarmonyPatterns: [ColorHarmony: Int],
        lightDirectionPatterns: [LightDirection: Int],
        leadingLinesLineCountDistribution: ValueDistribution?,
        leadingLinesAngleDistribution: ValueDistribution?,
        diagonalDominanceRatio: Double?,
        symmetryDistribution: ValueDistribution?,
        bilateralDistribution: ValueDistribution?,
        symmetryRatio: Double?,
        symmetryAxisPatterns: [SymmetryAxis: Int],
        goldenRatioDistribution: ValueDistribution?,
        goldenRatioHitRatio: Double?,
        inconsistencies: [Inconsistency]
    ) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []

        // Composition insights
        if let pos = positionDistribution {
            insights.append(contentsOf: buildPositionInsights(analyses: analyses, distribution: pos))
        }
        if let sz = sizeDistribution {
            insights.append(contentsOf: buildSizeInsights(analyses: analyses, distribution: sz))
        }

        // Lighting insights
        if let b = brightnessDistribution {
            insights.append(contentsOf: buildLightingInsights(analyses: analyses, distribution: b, characteristic: .brightness))
        }
        if let s = saturationDistribution {
            insights.append(contentsOf: buildLightingInsights(analyses: analyses, distribution: s, characteristic: .saturation))
        }
        if let ct = colorTemperatureDistribution {
            insights.append(contentsOf: buildColorTemperatureInsights(analyses: analyses, distribution: ct))
        }

        // Head angle insights
        if let hy = headYawDistribution {
            insights.append(contentsOf: buildHeadAngleInsights(analyses: analyses, distribution: hy))
        }

        // Body orientation insights
        if let bo = bodyOrientationDistribution {
            insights.append(contentsOf: buildBodyOrientationInsights(analyses: analyses, distribution: bo))
        }

        // Aesthetic insights
        if let ae = aestheticScoreDistribution {
            insights.append(contentsOf: buildAestheticInsights(analyses: analyses, distribution: ae))
        }

        // Rule of thirds insights
        insights.append(contentsOf: buildRuleOfThirdsInsights(analyses: analyses, patterns: ruleOfThirdsPatterns))

        // Color harmony insights
        insights.append(contentsOf: buildColorHarmonyInsights(analyses: analyses, patterns: colorHarmonyPatterns))

        // Lighting direction insights
        insights.append(contentsOf: buildLightDirectionInsights(analyses: analyses, patterns: lightDirectionPatterns))

        // Leading lines insights
        insights.append(contentsOf: buildLeadingLinesInsights(
            analyses: analyses,
            lineCountDistribution: leadingLinesLineCountDistribution,
            diagonalDominanceRatio: diagonalDominanceRatio
        ))

        // Symmetry insights
        insights.append(contentsOf: buildSymmetryInsights(
            analyses: analyses,
            symmetryRatio: symmetryRatio,
            axisPatterns: symmetryAxisPatterns
        ))

        // Body extent (full vs half body) — measured from both detection modes.
        insights.append(contentsOf: buildBodyExtentInsights(analyses: analyses))

        // Subject-to-background relationship.
        insights.append(contentsOf: buildSubjectBackgroundInsights(analyses: analyses))

        // Golden ratio insights
        insights.append(contentsOf: buildGoldenRatioInsights(
            analyses: analyses,
            goldenRatioHitRatio: goldenRatioHitRatio
        ))

        // Horizon insights
        if let angle = angleDistribution, angle.sampleCount > 0 {
            insights.append(contentsOf: buildHorizonInsights(analyses: analyses, distribution: angle))
        }

        if insights.isEmpty {
            insights.append(PreferenceInsight(
                id: UUID(),
                title: "Limited Data",
                description: "Not enough measurable characteristics to find patterns. Try different photos.",
                category: .general,
                supportingPhotoIDs: [],
                supportingMeasurements: [:],
                evidenceStrength: .insufficient,
                interpretationStatus: .observation
            ))
        }

        return insights
    }

    // MARK: - Insight Builders

    // MARK: - Body Extent & Subject-Background

    /// Classifies the user's habitual framing as full body or half body.
    ///
    /// Uses the measured `bodyExtent` on each analysis, which came from running
    /// BOTH detection modes and comparing boxes — not a guess. Reports the
    /// dominant extent only when it is a clear majority, so a mixed set does not
    /// overclaim a single habit.
    private func buildBodyExtentInsights(analyses: [PhotoAnalysis]) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []

        let classified = analyses.compactMap { analysis -> (BodyExtent, UUID)? in
            guard let extent = analysis.bodyExtent, extent != .undetermined else { return nil }
            return (extent, analysis.referencePhotoID)
        }

        // Need at least two determined photos before claiming a habit.
        guard classified.count >= 2 else { return insights }

        let fullCount = classified.filter { $0.0 == .fullBody }.count
        let halfCount = classified.count - fullCount
        let total = classified.count

        // A clear majority (>= 60%) means the habit is real.
        let dominant: BodyExtent? = fullCount * 10 >= total * 6 ? .fullBody
            : halfCount * 10 >= total * 6 ? .halfBody
            : nil

        guard let dominant else {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Mixed Body Framing",
                description: "You frame subjects as both full and half body across your photos.",
                category: .framing,
                supportingPhotoIDs: classified.map { $0.1 },
                supportingMeasurements: ["fullBodyCount": Double(fullCount), "halfBodyCount": Double(halfCount)],
                evidenceStrength: .moderate, interpretationStatus: .observation
            ))
            return insights
        }

        let (title, description): (String, String) = dominant == .fullBody
            ? ("Full Body Framing", "You typically capture the subject's whole figure, head to feet.")
            : ("Half Body Framing", "You typically frame the subject from the waist or chest up.")

        insights.append(PreferenceInsight(
            id: UUID(), title: title, description: description,
            category: .framing,
            supportingPhotoIDs: classified.map { $0.1 },
            supportingMeasurements: ["fullBodyCount": Double(fullCount), "halfBodyCount": Double(halfCount)],
            evidenceStrength: .strong, interpretationStatus: .observation
        ))

        return insights
    }

    /// Describes how the subject relates to the background.
    ///
    /// Combines two real measurements: subject size (how much of the frame the
    /// subject occupies) and negative space (how the remaining frame is
    /// distributed). Together they say whether the subject dominates the scene
    /// or sits within a larger environment — a subject-to-background reading
    /// derived from data, not invented.
    private func buildSubjectBackgroundInsights(analyses: [PhotoAnalysis]) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []

        let usable = analyses.filter { $0.subjectSize != nil && $0.negativeSpaceDistribution != nil }
        guard usable.count >= 2 else { return insights }

        let meanSize = usable.compactMap { $0.subjectSize }.reduce(0, +) / Double(usable.count)
        let supportingPhotoIDs = usable.map { $0.referencePhotoID }

        // Dominant negative-space direction, if one repeats.
        let spaceCounts = Dictionary(grouping: usable.compactMap { $0.negativeSpaceDistribution }) { $0 }
        let dominantSpace = spaceCounts.max { $0.value.count < $1.value.count }?.key

        let description: String
        if meanSize < 0.15 {
            description = "Subjects sit small within a larger environment. The background carries much of the frame."
        } else if meanSize > 0.5 {
            description = "Subjects dominate the frame. The background plays a supporting role."
        } else {
            description = "Subjects hold a balanced share of the frame alongside the background."
        }

        var measurements: [String: Double] = ["meanSubjectSize": meanSize]
        if let dominantSpace {
            measurements["dominantNegativeSpaceCount"] = Double(spaceCounts[dominantSpace]?.count ?? 0)
        }

        insights.append(PreferenceInsight(
            id: UUID(), title: "Subject vs Background",
            description: description,
            category: .environment,
            supportingPhotoIDs: supportingPhotoIDs,
            supportingMeasurements: measurements,
            evidenceStrength: .moderate, interpretationStatus: .observation
        ))

        return insights
    }

    private func buildPositionInsights(analyses: [PhotoAnalysis], distribution: PositionDistribution) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.subjectPosition != nil ? $0.referencePhotoID : nil }

        if distribution.isConsistent {
            let positionDesc = describeConsistentPosition(meanX: distribution.meanX, meanY: distribution.meanY)
            insights.append(PreferenceInsight(
                id: UUID(), title: "Subject Placement", description: positionDesc,
                category: .composition, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanX": distribution.meanX, "meanY": distribution.meanY, "stdDevX": distribution.stdDevX, "stdDevY": distribution.stdDevY],
                evidenceStrength: distribution.stdDevX < 0.10 ? .strong : .moderate,
                interpretationStatus: .observation
            ))
        } else {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Varied Subject Placement",
                description: "Subject placement varies.",
                category: .composition, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanX": distribution.meanX, "meanY": distribution.meanY, "stdDevX": distribution.stdDevX, "stdDevY": distribution.stdDevY],
                evidenceStrength: .moderate, interpretationStatus: .observation
            ))
        }
        return insights
    }

    private func buildSizeInsights(analyses: [PhotoAnalysis], distribution: SizeDistribution) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.subjectSize != nil ? $0.referencePhotoID : nil }

        if distribution.meanArea < 0.15 {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Environmental Framing",
                description: "Subjects are small in frame. Environmental framing.",
                category: .framing, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanArea": distribution.meanArea, "minArea": distribution.minArea, "maxArea": distribution.maxArea],
                evidenceStrength: .strong, interpretationStatus: .observation
            ))
        } else if distribution.meanArea > 0.5 {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Close Framing",
                description: "Subjects fill most of the frame. Close framing.",
                category: .framing, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanArea": distribution.meanArea, "minArea": distribution.minArea, "maxArea": distribution.maxArea],
                evidenceStrength: .strong, interpretationStatus: .observation
            ))
        }
        return insights
    }

    private func buildLightingInsights(analyses: [PhotoAnalysis], distribution: ValueDistribution, characteristic: Characteristic) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { analysis -> UUID? in
            switch characteristic {
            case .brightness: return analysis.meanBrightness != nil ? analysis.referencePhotoID : nil
            case .saturation: return analysis.meanSaturation != nil ? analysis.referencePhotoID : nil
            default: return nil
            }
        }

        guard !supportingPhotoIDs.isEmpty else { return insights }

        switch characteristic {
        case .brightness:
            if distribution.mean < 0.3 {
                insights.append(PreferenceInsight(
                    id: UUID(), title: "Dark & Moody",
                    description: "Darker exposures. Low-key lighting.",
                    category: .lighting, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["meanBrightness": distribution.mean, "stdDev": distribution.stdDev],
                    evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                    interpretationStatus: .observation
                ))
            } else if distribution.mean > 0.65 {
                insights.append(PreferenceInsight(
                    id: UUID(), title: "Bright & Airy",
                    description: "Bright exposures. Light and airy.",
                    category: .lighting, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["meanBrightness": distribution.mean, "stdDev": distribution.stdDev],
                    evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                    interpretationStatus: .observation
                ))
            }
        case .saturation:
            if distribution.mean < 0.2 {
                insights.append(PreferenceInsight(
                    id: UUID(), title: "Muted Palette",
                    description: "Desaturated colors. Muted palette.",
                    category: .lighting, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["meanSaturation": distribution.mean, "stdDev": distribution.stdDev],
                    evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                    interpretationStatus: .observation
                ))
            } else if distribution.mean > 0.5 {
                insights.append(PreferenceInsight(
                    id: UUID(), title: "Vivid Colors",
                    description: "Vivid, saturated colors. Bold palette.",
                    category: .lighting, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["meanSaturation": distribution.mean, "stdDev": distribution.stdDev],
                    evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                    interpretationStatus: .observation
                ))
            }
        default:
            break
        }
        return insights
    }

    private func buildColorTemperatureInsights(analyses: [PhotoAnalysis], distribution: ValueDistribution) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.colorTemperature != nil ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        if distribution.mean > 0.15 {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Warm Tones",
                description: "Warm color temperature. Golden-hour look.",
                category: .lighting, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanTemperature": distribution.mean, "stdDev": distribution.stdDev],
                evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                interpretationStatus: .observation
            ))
        } else if distribution.mean < -0.15 {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Cool Tones",
                description: "Cool color temperature. Blue-hour look.",
                category: .lighting, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanTemperature": distribution.mean, "stdDev": distribution.stdDev],
                evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                interpretationStatus: .observation
            ))
        }
        return insights
    }

    private func buildHeadAngleInsights(analyses: [PhotoAnalysis], distribution: ValueDistribution) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.headYaw != nil ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        if distribution.isConsistent && abs(distribution.mean) > 15 {
            let direction = distribution.mean > 0 ? "right" : "left"
            insights.append(PreferenceInsight(
                id: UUID(), title: "Head Angle",
                description: "Subjects face the \(direction) side of frame.",
                category: .subjectAngle, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanYaw": distribution.mean, "stdDev": distribution.stdDev],
                evidenceStrength: .strong, interpretationStatus: .observation
            ))
        } else if !distribution.isConsistent {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Head Angle (Varied)",
                description: "Your subjects face different directions across your photographs.",
                category: .subjectAngle, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanYaw": distribution.mean, "stdDev": distribution.stdDev],
                evidenceStrength: .moderate, interpretationStatus: .observation
            ))
        }
        return insights
    }

    private func buildBodyOrientationInsights(analyses: [PhotoAnalysis], distribution: ValueDistribution) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.bodyOrientation != nil ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        if distribution.isConsistent {
            if abs(distribution.mean) < 10 {
                insights.append(PreferenceInsight(
                    id: UUID(), title: "Pose (Straight-On)",
                    description: "Subjects oriented parallel to frame. Straight-on style.",
                    category: .subjectAngle, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["meanOrientation": distribution.mean, "stdDev": distribution.stdDev],
                    evidenceStrength: .strong, interpretationStatus: .observation
                ))
            } else if abs(distribution.mean) > 45 {
                insights.append(PreferenceInsight(
                    id: UUID(), title: "Pose (Diagonal)",
                    description: "Subjects often shot diagonally.",
                    category: .subjectAngle, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["meanOrientation": distribution.mean, "stdDev": distribution.stdDev],
                    evidenceStrength: .strong, interpretationStatus: .observation
                ))
            }
        }
        return insights
    }

    private func buildAestheticInsights(analyses: [PhotoAnalysis], distribution: ValueDistribution) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.aestheticScore != nil ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        if distribution.mean > 0.3 {
            insights.append(PreferenceInsight(
                id: UUID(), title: "High Aesthetic Quality",
                description: "High aesthetic scores. Strong technical and compositional quality.",
                category: .aesthetics, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanScore": distribution.mean, "stdDev": distribution.stdDev],
                evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                interpretationStatus: .observation
            ))
        } else if distribution.mean < -0.1 {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Raw or Unpolished Aesthetic",
                description: "Lower aesthetic scores. Raw or documentary style.",
                category: .aesthetics, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanScore": distribution.mean, "stdDev": distribution.stdDev],
                evidenceStrength: distribution.isConsistent ? .strong : .moderate,
                interpretationStatus: .observation
            ))
        }
        return insights
    }

    private func buildRuleOfThirdsInsights(analyses: [PhotoAnalysis], patterns: [RuleOfThirds: Int]) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        guard !patterns.isEmpty else { return insights }

        let totalWithSubject = patterns.values.reduce(0, +)
        guard totalWithSubject > 0 else { return insights }

        let topZone = patterns.max { $0.value < $1.value }
        if let zone = topZone?.key, let count = topZone?.value {
            let proportion = Double(count) / Double(totalWithSubject)
            if proportion > 0.4 {
                let supportingPhotoIDs = analyses.compactMap { $0.ruleOfThirdsAlignment == zone ? $0.referencePhotoID : nil }
                insights.append(PreferenceInsight(
                    id: UUID(), title: "Rule of Thirds: \(zone.rawValue)",
                    description: "Subjects sit in the \(zone.rawValue) rule-of-thirds zone.",
                    category: .composition, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["proportion": proportion, "count": Double(count)],
                    evidenceStrength: proportion > 0.5 ? .strong : .moderate,
                    interpretationStatus: .observation
                ))
            }
        }
        return insights
    }

    private func buildColorHarmonyInsights(analyses: [PhotoAnalysis], patterns: [ColorHarmony: Int]) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        guard !patterns.isEmpty else { return insights }

        let total = patterns.values.reduce(0, +)
        guard total > 0 else { return insights }

        let topHarmony = patterns.max { $0.value < $1.value }
        if let harmony = topHarmony?.key, let count = topHarmony?.value {
            let proportion = Double(count) / Double(total)
            if proportion > 0.4 {
                let supportingPhotoIDs = analyses.compactMap { $0.colorHarmony == harmony ? $0.referencePhotoID : nil }
                insights.append(PreferenceInsight(
                    id: UUID(), title: "\(harmony.rawValue) Color Palette",
                    description: "Mostly \(harmony.rawValue.lowercased()) color scheme.",
                    category: .aesthetics, supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["proportion": proportion, "count": Double(count)],
                    evidenceStrength: proportion > 0.5 ? .strong : .moderate,
                    interpretationStatus: .observation
                ))
            }
        }
        return insights
    }

    private func buildHorizonInsights(analyses: [PhotoAnalysis], distribution: AngleDistribution) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.horizonAngle != nil ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        if abs(distribution.meanAngle) < 5.0 {
            insights.append(PreferenceInsight(
                id: UUID(), title: "Level Horizons",
                description: "Your horizons are generally kept level across your photographs.",
                category: .horizon, supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanAngle": distribution.meanAngle, "stdDev": distribution.stdDev, "sampleCount": Double(distribution.sampleCount)],
                evidenceStrength: .strong, interpretationStatus: .observation
            ))
        }
        return insights
    }

    /// Builds a lighting-direction insight from aggregated direction counts.
    private func buildLightDirectionInsights(analyses: [PhotoAnalysis], patterns: [LightDirection: Int]) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        guard !patterns.isEmpty else { return insights }

        let total = patterns.values.reduce(0, +)
        guard total > 0 else { return insights }

        let top = patterns.max { $0.value < $1.value }
        if let direction = top?.key, let count = top?.value {
            let proportion = Double(count) / Double(total)
            if proportion > 0.4 {
                let supportingPhotoIDs = analyses.compactMap {
                    ($0.hasLightDirection && $0.lightDirection == direction) ? $0.referencePhotoID : nil
                }
                insights.append(PreferenceInsight(
                    id: UUID(),
                    title: "Lighting Direction: \(direction.rawValue)",
                    description: "Most often lit from the \(direction.rawValue.lowercased()). Shadows fall opposite. Estimated from brightness gradient — approximate.",
                    category: .lighting,
                    supportingPhotoIDs: supportingPhotoIDs,
                    supportingMeasurements: ["proportion": proportion, "count": Double(count)],
                    evidenceStrength: proportion > 0.5 ? .moderate : .weak,
                    interpretationStatus: .observation
                ))
            }
        }
        return insights
    }

    /// Builds a leading-lines insight from aggregated line statistics.
    private func buildLeadingLinesInsights(
        analyses: [PhotoAnalysis],
        lineCountDistribution: ValueDistribution?,
        diagonalDominanceRatio: Double?
    ) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        let supportingPhotoIDs = analyses.compactMap { $0.hasLeadingLines ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        if let lineCount = lineCountDistribution, lineCount.mean >= 2 {
            insights.append(PreferenceInsight(
                id: UUID(),
                title: "Leading Lines",
                description: "Strong structural lines. Roads, edges, architecture.",
                category: .composition,
                supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["meanLineCount": lineCount.mean, "stdDev": lineCount.stdDev],
                evidenceStrength: lineCount.mean >= 4 ? .strong : .moderate,
                interpretationStatus: .observation
            ))
        }

        if let ratio = diagonalDominanceRatio, ratio > 0.4 {
            insights.append(PreferenceInsight(
                id: UUID(),
                title: "Diagonal Lines",
                description: "Lines run diagonally. Dynamic compositions.",
                category: .composition,
                supportingPhotoIDs: supportingPhotoIDs,
                supportingMeasurements: ["diagonalRatio": ratio],
                evidenceStrength: ratio > 0.6 ? .moderate : .weak,
                interpretationStatus: .observation
            ))
        }

        return insights
    }

    /// Builds a symmetry insight from the aggregate symmetry statistics.
    private func buildSymmetryInsights(
        analyses: [PhotoAnalysis],
        symmetryRatio: Double?,
        axisPatterns: [SymmetryAxis: Int]
    ) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        guard let ratio = symmetryRatio, ratio > 0.4 else { return insights }

        let supportingPhotoIDs = analyses.compactMap { $0.hasSymmetry ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        let axis = axisPatterns.max { $0.value < $1.value }?.key ?? .bilateral
        let axisDescription: String
        switch axis {
        case .bilateral:
            axisDescription = "the left half mirrors the right half"
        case .vertical:
            axisDescription = "the top half mirrors the bottom half, as in a reflection"
        case .none:
            axisDescription = "the frame is mirrored"
        }

        insights.append(PreferenceInsight(
            id: UUID(),
            title: "Symmetrical Composition",
            description: "Strong mirror symmetry — \(axisDescription). Measured from light and tone distribution.",
            category: .composition,
            supportingPhotoIDs: supportingPhotoIDs,
            supportingMeasurements: ["symmetricPhotoRatio": ratio],
            evidenceStrength: ratio > 0.6 ? .moderate : .weak,
            interpretationStatus: .observation
        ))
        return insights
    }

    /// Builds a golden-ratio insight from the aggregate hit statistics.
    private func buildGoldenRatioInsights(
        analyses: [PhotoAnalysis],
        goldenRatioHitRatio: Double?
    ) -> [PreferenceInsight] {
        var insights: [PreferenceInsight] = []
        guard let ratio = goldenRatioHitRatio, ratio > 0.4 else { return insights }

        let supportingPhotoIDs = analyses.compactMap { $0.hasGoldenRatio ? $0.referencePhotoID : nil }
        guard !supportingPhotoIDs.isEmpty else { return insights }

        insights.append(PreferenceInsight(
            id: UUID(),
            title: "Golden Ratio Placement",
            description: "Subjects near golden-ratio divisions (0.382 / 0.618).",
            category: .composition,
            supportingPhotoIDs: supportingPhotoIDs,
            supportingMeasurements: ["goldenPointRatio": ratio],
            evidenceStrength: ratio > 0.6 ? .moderate : .weak,
            interpretationStatus: .observation
        ))
        return insights
    }

    // MARK: - Limitations

    private func buildLimitations(analyses: [PhotoAnalysis]) -> [String] {
        var limitations: [String] = []

        let failedCount = analyses.filter { $0.status == .failed }.count
        if failedCount > 0 {
            limitations.append("\(failedCount) photograph(s) could not be fully analyzed.")
        }

        let missingSubjects = analyses.filter { $0.subjectPosition == nil }.count
        if missingSubjects > 0 && Double(missingSubjects) / Double(analyses.count) > 0.3 {
            limitations.append("Subjects could not be detected in \(missingSubjects) of \(analyses.count) photograph(s).")
        }

        let missingHorizons = analyses.filter { $0.horizonAngle == nil }.count
        if missingHorizons > 0 {
            limitations.append("Horizon could not be detected in \(missingHorizons) photograph(s) without a visible horizon line.")
        }

        let missingHeadPose = analyses.filter { $0.headYaw == nil }.count
        if missingHeadPose > 0 {
            limitations.append("Head pose could not be detected in \(missingHeadPose) photograph(s) (no faces detected).")
        }

        let missingBodyPose = analyses.filter { !$0.hasBodyPose }.count
        if missingBodyPose > 0 {
            limitations.append("Body pose could not be detected in \(missingBodyPose) photograph(s).")
        }

        // Honesty about the approximation-based characteristics (PRD Rule 7)
        limitations.append("Lighting direction is estimated from the frame's brightness gradient and is approximate; flat or evenly lit photographs report 'even' rather than a direction.")
        limitations.append("Leading-line detection reports dominant line angles; it does not compute true vanishing points.")
        limitations.append("Symmetry measures the frame's light and tone distribution, not semantic symmetry — an off-center subject lowers the score even in an otherwise symmetric scene.")
        limitations.append("Golden-ratio placement reuses the detected subject position; it cannot identify a subject the detector missed.")

        limitations.append("Foundation Models interpretation availability varies by device and is unavailable on the iOS simulator.")
        limitations.append("Some Vision requests (aesthetics, saliency) require a physical device with Apple Neural Engine.")

        return limitations
    }

    // MARK: - Statistics

    private func computeStdDev(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }
}
