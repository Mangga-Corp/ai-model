import XCTest
import CoreGraphics
import Vision
@testable import AIModel

/// Unit tests for evidence validation and interpretation rules.
final class EvidenceValidationTests: XCTestCase {

    // MARK: - Rule 1: Observation vs Preference Distinction

    func testInsight_observationIsLabeledCorrectly() {
        let insight = PreferenceInsight(
            id: UUID(),
            title: "Subject Placement",
            description: "Subjects are consistently placed in the left side of your photographs.",
            category: .composition,
            supportingPhotoIDs: [UUID(), UUID()],
            supportingMeasurements: ["meanX": 0.3],
            evidenceStrength: .strong,
            interpretationStatus: .observation
        )

        XCTAssertEqual(insight.interpretationStatus, .observation)
    }

    func testInsight_interpretationIsLabeledCorrectly() {
        let insight = PreferenceInsight(
            id: UUID(),
            title: "AI Interpretation",
            description: "You may prefer off-center subject placement.",
            category: .composition,
            supportingPhotoIDs: [UUID(), UUID()],
            supportingMeasurements: ["meanX": 0.3],
            evidenceStrength: .moderate,
            interpretationStatus: .interpretation
        )

        XCTAssertEqual(insight.interpretationStatus, .interpretation)
    }

    // MARK: - Rule 3: Never Force Consistency

    func testAggregation_reportsMixedPatterns() {
        let service = PreferenceAggregationService()
        let analyses = createInconsistentAnalyses(count: 5)
        let profile = service.aggregate(analyses: analyses)

        XCTAssertFalse(profile.mixedPatterns.isEmpty,
                       "Should report mixed patterns when data is inconsistent")
    }

    // MARK: - Rule 4: Treat Missing Data Explicitly

    func testAggregation_marksUnavailableCharacteristics() {
        let service = PreferenceAggregationService()

        let unavailable = Set<Characteristic>([.subjectPlacement, .subjectSize])
        let analyses = createAnalysesWithStatus(
            count: 3,
            unavailableCharacteristics: unavailable,
            status: .partial
        )
        let profile = service.aggregate(analyses: analyses)

        XCTAssertTrue(profile.limitations.contains { $0.lowercased().contains("subject") })
    }

    // MARK: - Rule 6: Make Evidence Traceable

    func testInsight_supportingPhotoIDsAreTraceable() {
        let photoID1 = UUID()
        let photoID2 = UUID()

        let insight = PreferenceInsight(
            id: UUID(),
            title: "Test Insight",
            description: "Test description.",
            category: .composition,
            supportingPhotoIDs: [photoID1, photoID2],
            supportingMeasurements: ["meanX": 0.3],
            evidenceStrength: .strong,
            interpretationStatus: .observation
        )

        XCTAssertEqual(insight.supportingPhotoIDs.count, 2)
        XCTAssertTrue(insight.supportingPhotoIDs.contains(photoID1))
        XCTAssertTrue(insight.supportingPhotoIDs.contains(photoID2))
    }

    // MARK: - Evidence Strength Rules

    func testEvidenceStrength_insufficientForSinglePhoto() {
        let singleAnalysis = createAnalyses(count: 1, positions: [CGPoint(x: 0.3, y: 0.5)], sizes: [0.1])
        let service = PreferenceAggregationService()
        let profile = service.aggregate(analyses: singleAnalysis)

        XCTAssertGreaterThan(profile.limitations.count, 0)
    }

    // MARK: - Helpers

    private func createInconsistentAnalyses(count: Int) -> [PhotoAnalysis] {
        let positions: [CGPoint?] = [
            CGPoint(x: 0.1, y: 0.2),
            CGPoint(x: 0.9, y: 0.8),
            CGPoint(x: 0.5, y: 0.1),
            CGPoint(x: 0.2, y: 0.9),
            CGPoint(x: 0.8, y: 0.5),
        ]
        let sizes: [Double?] = [0.05, 0.5, 0.08, 0.6, 0.12]
        return createAnalyses(count: count, positions: positions, sizes: sizes)
    }

    private func createAnalyses(count: Int, positions: [CGPoint?], sizes: [Double?]) -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for i in 0..<count {
            analyses.append(makeAnalysis(
                subjectPosition: positions[i],
                subjectSize: sizes[i],
                status: .success
            ))
        }
        return analyses
    }

    private func createAnalysesWithStatus(count: Int, unavailableCharacteristics: Set<Characteristic>, status: AnalysisStatus) -> [PhotoAnalysis] {
        return (0..<count).map { _ in
            makeAnalysis(
                subjectPosition: nil,
                subjectSize: nil,
                status: status,
                unavailableCharacteristics: unavailableCharacteristics
            )
        }
    }

    /// Creates a PhotoAnalysis with all fields defaulted, overriding only what's specified.
    private func makeAnalysis(
        subjectPosition: CGPoint?,
        subjectSize: Double?,
        status: AnalysisStatus,
        unavailableCharacteristics: Set<Characteristic> = []
    ) -> PhotoAnalysis {
        PhotoAnalysis(
            id: UUID(),
            referencePhotoID: UUID(),
            subjectPosition: subjectPosition,
            subjectSize: subjectSize,
            subjectBoundingBox: subjectPosition.map { _ in
                NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            },
            subjectConfidence: 0.9,
            halfBodyPosition: nil,
            bodyExtent: nil,
            negativeSpaceDistribution: nil,
            saliencyCentroid: nil,
            saliencyBoundingBox: nil,
            saliencyIntensity: nil,
            ruleOfThirdsAlignment: nil,
            horizonAngle: nil,
            horizonVerticalPosition: nil,
            headRoll: nil,
            headYaw: nil,
            headPitch: nil,
            faceBoundingBox: nil,
            faceConfidence: nil,
            bodyPoseJointCount: nil,
            bodyOrientation: nil,
            bodySymmetry: nil,
            dominantJointsGroup: nil,
            meanBrightness: nil,
            brightnessStdDev: nil,
            meanSaturation: nil,
            aestheticScore: nil,
            captureQuality: nil,
            lightDirection: nil,
            lightDirectionConfidence: nil,
            shadowDirection: nil,
            leadingLines: nil,
            symmetry: nil,
            goldenRatio: nil,
            dominantColors: nil,
            colorHarmony: nil,
            colorTemperature: nil,
            sceneClassifications: [:],
            imageDimensions: CGSize(width: 400, height: 300),
            orientation: .up,
            aspectRatio: 400.0 / 300.0,
            status: status,
            errorMessage: status == .failed ? "No characteristics detected." : nil,
            unavailableCharacteristics: unavailableCharacteristics
        )
    }
}
