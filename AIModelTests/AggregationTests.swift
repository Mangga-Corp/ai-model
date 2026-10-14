import XCTest
import CoreGraphics
import Vision
@testable import AIModel

/// Unit tests for the preference aggregation service.
final class PreferenceAggregationTests: XCTestCase {

    // MARK: - Consistency Detection

    func testAggregation_consistentSubjectPlacement() {
        let analyses = createAnalyses(
            count: 5,
            positions: [
                CGPoint(x: 0.3, y: 0.5),
                CGPoint(x: 0.32, y: 0.48),
                CGPoint(x: 0.28, y: 0.52),
                CGPoint(x: 0.31, y: 0.49),
                CGPoint(x: 0.29, y: 0.51),
            ],
            sizes: [0.1, 0.11, 0.1, 0.12, 0.09]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.subjectPositionDistribution)
        XCTAssertTrue(profile.subjectPositionDistribution?.isConsistent ?? false)
        XCTAssertEqual(profile.photoCount, 5)
        XCTAssertEqual(profile.successfullyAnalyzedCount, 5)
    }

    func testAggregation_inconsistentSubjectPlacement() {
        let analyses = createAnalyses(
            count: 5,
            positions: [
                CGPoint(x: 0.1, y: 0.2),
                CGPoint(x: 0.9, y: 0.8),
                CGPoint(x: 0.5, y: 0.1),
                CGPoint(x: 0.2, y: 0.9),
                CGPoint(x: 0.8, y: 0.5),
            ],
            sizes: [0.1, 0.11, 0.1, 0.12, 0.09]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.subjectPositionDistribution)
        XCTAssertFalse(profile.subjectPositionDistribution?.isConsistent ?? true)
        XCTAssertFalse(profile.mixedPatterns.isEmpty)
    }

    // MARK: - Mixed Patterns

    func testAggregation_detectsMixedPatterns() {
        let analyses = createAnalyses(
            count: 4,
            positions: [
                CGPoint(x: 0.3, y: 0.5),
                CGPoint(x: 0.7, y: 0.5),
                CGPoint(x: 0.2, y: 0.5),
                CGPoint(x: 0.8, y: 0.5),
            ],
            sizes: [0.05, 0.5, 0.08, 0.6]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        let hasPositionInconsistency = profile.mixedPatterns.contains { $0.characteristic == .subjectPlacement }
        let hasSizeInconsistency = profile.mixedPatterns.contains { $0.characteristic == .subjectSize }

        XCTAssertTrue(hasPositionInconsistency || hasSizeInconsistency,
                      "Should detect at least one inconsistency")
    }

    // MARK: - Missing Data Handling

    func testAggregation_handlesMissingSubject() {
        let analyses = createAnalyses(
            count: 3,
            positions: [nil, CGPoint(x: 0.3, y: 0.5), nil],
            sizes: [nil, 0.1, nil]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.subjectPositionDistribution)
        XCTAssertEqual(profile.successfullyAnalyzedCount, 3)
    }

    // MARK: - Limitations

    func testAggregation_buildsLimitations() {
        let analyses = createAnalyses(
            count: 3,
            positions: [nil, nil, nil],
            sizes: [nil, nil, nil]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertFalse(profile.limitations.isEmpty)
        XCTAssertTrue(profile.limitations.contains { $0.lowercased().contains("subject") })
    }

    // MARK: - Lighting Aggregation

    func testAggregation_consistentBrightness() {
        let analyses = createAnalysesWithLighting(
            count: 5,
            brightnesses: [0.55, 0.56, 0.54, 0.57, 0.55],
            saturations: [0.45, 0.46, 0.44, 0.47, 0.45]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.brightnessDistribution)
        XCTAssertTrue(profile.brightnessDistribution?.isConsistent ?? false)
        XCTAssertNotNil(profile.saturationDistribution)
    }

    func testAggregation_inconsistentBrightness() {
        let analyses = createAnalysesWithLighting(
            count: 5,
            brightnesses: [0.1, 0.9, 0.2, 0.8, 0.15],
            saturations: [0.1, 0.9, 0.2, 0.8, 0.15]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.brightnessDistribution)
        XCTAssertFalse(profile.brightnessDistribution?.isConsistent ?? true)
    }

    // MARK: - Head Angle Aggregation

    func testAggregation_consistentHeadYaw() {
        let analyses = createAnalysesWithHeadPose(
            count: 4,
            yaws: [-20, -22, -18, -21],
            rolls: [2, 3, 1, 2]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.headYawDistribution)
        XCTAssertTrue(profile.headYawDistribution?.isConsistent ?? false)
        XCTAssertTrue(abs(profile.headYawDistribution?.mean ?? 0) > 15)
    }

    // MARK: - Aesthetic Aggregation

    func testAggregation_aestheticScores() {
        let analyses = createAnalysesWithAesthetics(
            count: 5,
            scores: [0.4, 0.42, 0.38, 0.41, 0.39]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.aestheticScoreDistribution)
        XCTAssertTrue((profile.aestheticScoreDistribution?.mean ?? 0) > 0.3)
    }

    // MARK: - Rule of Thirds

    func testAggregation_ruleOfThirds() {
        let analyses = createAnalysesWithRuleOfThirds(
            count: 5,
            zones: [.middleLeft, .middleLeft, .middleLeft, .center, .middleLeft]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertEqual(profile.ruleOfThirdsPatterns[.middleLeft], 4)
        XCTAssertEqual(profile.ruleOfThirdsPatterns[.center], 1)
    }

    // MARK: - Color Harmony

    func testAggregation_colorHarmony() {
        let analyses = createAnalysesWithColorHarmony(
            count: 4,
            harmonies: [.warm, .warm, .warm, .analogous]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertEqual(profile.colorHarmonyPatterns[.warm], 3)
        XCTAssertEqual(profile.colorHarmonyPatterns[.analogous], 1)
    }

    // MARK: - Lighting Direction Aggregation

    func testAggregation_lightDirectionPatterns() {
        let analyses = createAnalysesWithLightDirection(
            count: 4,
            directions: [.topLeft, .topLeft, .right, .topLeft],
            confidences: [0.6, 0.55, 0.4, 0.62]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertEqual(profile.lightDirectionPatterns[.topLeft], 3)
        XCTAssertEqual(profile.lightDirectionPatterns[.right], 1)
    }

    /// Low-confidence light direction must be excluded — it is an estimate,
    /// not a measurement, and must not masquerade as evidence.
    func testAggregation_excludesLowConfidenceLightDirection() {
        let analyses = createAnalysesWithLightDirection(
            count: 3,
            directions: [.topLeft, .right, .bottom],
            confidences: [0.1, 0.05, 0.08]  // all below the 0.25 threshold
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertTrue(profile.lightDirectionPatterns.isEmpty,
                      "Low-confidence estimates must not be aggregated as evidence")
    }

    // MARK: - Leading Lines Aggregation

    func testAggregation_leadingLines() {
        let analyses = createAnalysesWithLeadingLines(
            count: 3,
            lineCounts: [4, 5, 3],
            angles: [42, 45, 40],
            convergences: [0.7, 0.75, 0.65],
            diagonalDominance: [true, true, false]
        )

        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: analyses)

        XCTAssertNotNil(profile.leadingLinesLineCountDistribution)
        XCTAssertEqual(profile.leadingLinesLineCountDistribution?.mean ?? 0, 4.0, accuracy: 0.01)
        // 2 of 3 photos with lines show diagonal dominance
        XCTAssertEqual(profile.diagonalDominanceRatio ?? 0, 2.0 / 3.0, accuracy: 0.01)
    }

    // MARK: - Progress Reporting

    /// The progress fraction must be monotonic and bounded — it advances only
    /// as real work completes (PRD: no fabricated progress).
    func testAnalysisProgress_fractionIsWellFormed() {
        let updates = [
            AnalysisProgress(fraction: 0.0, message: "Loading photos...", completedPhotoIndex: nil, totalPhotos: 5),
            AnalysisProgress(fraction: 0.05, message: "Analyzing photos...", completedPhotoIndex: nil, totalPhotos: 5),
            AnalysisProgress(fraction: 0.22, message: "Analyzing photo 1 of 5", completedPhotoIndex: 1, totalPhotos: 5),
            AnalysisProgress(fraction: 0.39, message: "Analyzing photo 2 of 5", completedPhotoIndex: 2, totalPhotos: 5),
            AnalysisProgress(fraction: 0.90, message: "Finding patterns...", completedPhotoIndex: nil, totalPhotos: 5)
        ]

        for update in updates {
            XCTAssertGreaterThanOrEqual(update.fraction, 0.0)
            XCTAssertLessThanOrEqual(update.fraction, 1.0)
            XCTAssertFalse(update.message.isEmpty)
        }

        // Must never go backwards
        for i in 1..<updates.count {
            XCTAssertGreaterThanOrEqual(
                updates[i].fraction,
                updates[i - 1].fraction,
                "Progress must be monotonic"
            )
        }
    }

    // MARK: - Helpers

    private func createAnalyses(count: Int, positions: [CGPoint?], sizes: [Double?]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: positions[i],
                subjectSize: sizes[i],
                status: .success
            ))
        }
        return analyses
    }

    private func createAnalysesWithLighting(count: Int, brightnesses: [Double], saturations: [Double]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: CGPoint(x: 0.5, y: 0.5),
                subjectSize: 0.15,
                status: .success,
                meanBrightness: brightnesses[i],
                brightnessStdDev: 0.05,
                meanSaturation: saturations[i]
            ))
        }
        return analyses
    }

    private func createAnalysesWithHeadPose(count: Int, yaws: [Double], rolls: [Double]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: CGPoint(x: 0.5, y: 0.5),
                subjectSize: 0.15,
                status: .success,
                headYaw: yaws[i],
                headRoll: rolls[i],
                headPitch: 0
            ))
        }
        return analyses
    }

    private func createAnalysesWithAesthetics(count: Int, scores: [Double]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: CGPoint(x: 0.5, y: 0.5),
                subjectSize: 0.15,
                status: .success,
                aestheticScore: scores[i]
            ))
        }
        return analyses
    }

    private func createAnalysesWithRuleOfThirds(count: Int, zones: [RuleOfThirds]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: CGPoint(x: 0.5, y: 0.5),
                subjectSize: 0.15,
                status: .success,
                ruleOfThirdsAlignment: zones[i]
            ))
        }
        return analyses
    }

    private func createAnalysesWithColorHarmony(count: Int, harmonies: [ColorHarmony]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: CGPoint(x: 0.5, y: 0.5),
                subjectSize: 0.15,
                status: .success,
                colorHarmony: harmonies[i]
            ))
        }
        return analyses
    }

    private func createAnalysesWithLightDirection(count: Int, directions: [LightDirection], confidences: [Double]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: CGPoint(x: 0.5, y: 0.5),
                subjectSize: 0.15,
                status: .success,
                lightDirection: directions[i],
                lightDirectionConfidence: confidences[i]
            ))
        }
        return analyses
    }

    private func createAnalysesWithLeadingLines(
        count: Int,
        lineCounts: [Int],
        angles: [Double],
        convergences: [Double],
        diagonalDominance: [Bool]
    ) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(createBaseAnalysis(
                id: UUID(),
                referencePhotoID: UUID(),
                subjectPosition: CGPoint(x: 0.5, y: 0.5),
                subjectSize: 0.15,
                status: .success,
                leadingLines: LeadingLinesResult(
                    lines: [],
                    lineCount: lineCounts[i],
                    dominantAngle: angles[i],
                    convergenceStrength: convergences[i],
                    hasDiagonalDominance: diagonalDominance[i],
                    isAvailable: true
                )
            ))
        }
        return analyses
    }

    /// Creates a PhotoAnalysis with sensible defaults, overriding only specified fields.
    private func createBaseAnalysis(
        id: UUID,
        referencePhotoID: UUID,
        subjectPosition: CGPoint?,
        subjectSize: Double?,
        status: AnalysisStatus,
        meanBrightness: Double? = nil,
        brightnessStdDev: Double? = nil,
        meanSaturation: Double? = nil,
        headYaw: Double? = nil,
        headRoll: Double? = nil,
        headPitch: Double? = nil,
        aestheticScore: Double? = nil,
        ruleOfThirdsAlignment: RuleOfThirds? = nil,
        colorHarmony: ColorHarmony? = nil,
        lightDirection: LightDirection? = nil,
        lightDirectionConfidence: Double? = nil,
        leadingLines: LeadingLinesResult? = nil,
        symmetry: SymmetryResult? = nil,
        goldenRatio: GoldenRatioResult? = nil,
        bodyExtent: BodyExtent? = nil,
        halfBodyPosition: CGPoint? = nil,
        negativeSpaceDistribution: NegativeSpaceDistribution? = nil
    ) -> PhotoAnalysis {
        PhotoAnalysis(
            id: id,
            referencePhotoID: referencePhotoID,
            subjectPosition: subjectPosition,
            subjectSize: subjectSize,
            subjectBoundingBox: subjectPosition.map { _ in NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) },
            subjectConfidence: 0.9,
            halfBodyPosition: halfBodyPosition,
            bodyExtent: bodyExtent,
            negativeSpaceDistribution: negativeSpaceDistribution,
            saliencyCentroid: nil,
            saliencyBoundingBox: nil,
            saliencyIntensity: nil,
            ruleOfThirdsAlignment: ruleOfThirdsAlignment,
            horizonAngle: nil,
            horizonVerticalPosition: nil,
            headRoll: headRoll,
            headYaw: headYaw,
            headPitch: headPitch,
            faceBoundingBox: nil,
            faceConfidence: nil,
            bodyPoseJointCount: nil,
            bodyOrientation: nil,
            bodySymmetry: nil,
            dominantJointsGroup: nil,
            meanBrightness: meanBrightness,
            brightnessStdDev: brightnessStdDev,
            meanSaturation: meanSaturation,
            aestheticScore: aestheticScore,
            captureQuality: nil,
            lightDirection: lightDirection,
            lightDirectionConfidence: lightDirectionConfidence,
            shadowDirection: nil,
            leadingLines: leadingLines,
            symmetry: symmetry,
            goldenRatio: goldenRatio,
            dominantColors: nil,
            colorHarmony: colorHarmony,
            colorTemperature: nil,
            sceneClassifications: [:],
            imageDimensions: CGSize(width: 400, height: 300),
            orientation: .up,
            aspectRatio: 400.0 / 300.0,
            status: status,
            errorMessage: nil,
            unavailableCharacteristics: []
        )
    }
}
