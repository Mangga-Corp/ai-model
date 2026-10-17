import XCTest
import CoreGraphics
@testable import AIModel

/// Focused checks for Stage F: recurring vs isolated vs mixed, missing evidence
/// handling, evidence weighting, determinism, and the camera hand-off.
final class PreferenceProfileTests: XCTestCase {

    // MARK: - Fixtures

    private func determined(_ quality: EvidenceQuality = .high) -> Assessment {
        Assessment(status: .determined, quality: quality, explanation: "", evidence: [], limitations: [])
    }

    /// Builds a result. A nil characteristic is "insufficient evidence"; `unavailable` marks all four unavailable.
    private func photo(_ order: Int,
                       angle: CameraAngleCategory? = nil,
                       framing: FramingCategory? = nil,
                       zone: (HorizontalZone, VerticalZone)? = nil,
                       center: CGPoint? = nil,
                       depth: DepthStructure? = nil,
                       quality: EvidenceQuality = .high,
                       upperBox: CGRect? = nil,
                       unavailable: Bool = false) -> PhotoResult {
        let none = unavailable ? Assessment.unavailable("failed") : Assessment.insufficient("n/a")
        let selection = SubjectSelectionInfo(detectedCount: 1, eligibleCount: 1, primaryCandidateID: 0, isAmbiguous: false)

        let box = zone.map { z -> CGRect in
            let cx = center.map { Double($0.x) } ?? (z.0 == .left ? 0.17 : z.0 == .center ? 0.5 : 0.83)
            let cy = center.map { Double($0.y) } ?? (z.1 == .upper ? 0.17 : z.1 == .middle ? 0.5 : 0.83)
            return CGRect(x: cx - 0.1, y: cy - 0.15, width: 0.2, height: 0.3)
        }

        return PhotoResult(
            id: UUID(), selectionOrder: order, localIdentifier: "p\(order)", preparation: nil,
            status: unavailable ? .failed : .complete, evidence: nil,
            cameraAngle: CameraAngleResult(category: angle ?? .unknown, horizonCue: nil, headPitchDegrees: nil,
                                           headYawDegrees: nil, imageRollDegrees: nil,
                                           assessment: angle == nil ? none : determined(quality)),
            subjectFraming: SubjectFramingResult(category: framing ?? .unknown, visibleExtent: nil, croppedEdges: [],
                                                 reliableLandmarkCount: 0,
                                                 assessment: framing == nil ? none : determined(quality)),
            subjectPositioning: SubjectPositioningResult(
                subjectBox: box, upperBodyBox: upperBox, center: box.map { CGPoint(x: $0.midX, y: $0.midY) },
                normalizedWidth: box.map { Double($0.width) }, normalizedHeight: box.map { Double($0.height) },
                normalizedArea: box.map { ImageSpace.area($0) },
                horizontal: zone?.0, vertical: zone?.1, detectionConfidence: zone == nil ? nil : 0.9,
                isMeasurementValid: zone != nil, touchedEdges: [], selection: selection, secondarySubjects: [],
                assessment: zone == nil ? none : determined(quality)),
            environmentalDepth: EnvironmentalDepthResult(structure: depth ?? .unknown, metrics: nil, sceneBands: nil,
                                                         assessment: depth == nil ? none : determined(quality)),
            errors: [], limitations: [])
    }

    // MARK: - Pattern kinds

    func testRecurringPatternKeepsTheIsolatedObservation() {
        let results = [
            photo(0, angle: .eyeLevel), photo(1, angle: .eyeLevel), photo(2, angle: .eyeLevel), photo(3, angle: .highAngle)
        ]
        let f = ProfileAggregator.aggregate(results).cameraAngle
        XCTAssertEqual(f.pattern, .recurring)
        XCTAssertEqual(f.dominant, .eyeLevel)
        XCTAssertEqual(f.counts[.eyeLevel], 3)
        XCTAssertEqual(f.isolated, [.highAngle], "a one-off stays visible as an isolated observation")
        XCTAssertEqual(f.strength, .strong)
        XCTAssertEqual(f.supportingPhotoIDs[.eyeLevel]?.count, 3)
        XCTAssertGreaterThan(f.variation, 0)
    }

    func testSingleObservationIsNotAPreference() {
        let f = ProfileAggregator.aggregate([photo(0, framing: .halfBody), photo(1), photo(2)]).subjectFraming
        XCTAssertEqual(f.pattern, .singleObservation)
        XCTAssertNil(f.dominant)
        XCTAssertEqual(f.strength, .insufficient)
        XCTAssertEqual(f.validObservationCount, 1)
    }

    func testEvenSplitIsMixedWithNoDominantCategory() {
        let f = ProfileAggregator.aggregate([
            photo(0, framing: .fullBody), photo(1, framing: .fullBody),
            photo(2, framing: .halfBody), photo(3, framing: .halfBody)
        ]).subjectFraming
        XCTAssertEqual(f.pattern, .mixed)
        XCTAssertNil(f.dominant)
        XCTAssertEqual(Set(f.recurringCategories), [.fullBody, .halfBody], "both recurring categories are preserved")
    }

    func testMissingEvidenceIsExcludedNotCountedAgainstAnyCategory() {
        let results = [photo(0, angle: .eyeLevel), photo(1, angle: .eyeLevel),
                       photo(2, unavailable: true), photo(3), photo(4)]
        let profile = ProfileAggregator.aggregate(results)
        let f = profile.cameraAngle
        XCTAssertEqual(f.pattern, .recurring)
        XCTAssertEqual(f.dominantShare, 1.0, accuracy: 1e-9, "unknown photos must not dilute the share")
        XCTAssertEqual(f.excludedPhotoIDs.count, 3)
        XCTAssertEqual(f.strength, .limited, "two agreeing photos is only limited support")

        let coverage = profile.coverage[.cameraAngle]
        XCTAssertEqual(coverage?.determinedCount, 2)
        XCTAssertEqual(coverage?.totalPhotos, 5)
        XCTAssertEqual(coverage?.unavailablePhotoIDs.count, 1)
        XCTAssertEqual(coverage?.insufficientPhotoIDs.count, 2)
    }

    func testNoValidObservationsMarksTheCharacteristicUnsupported() {
        let profile = ProfileAggregator.aggregate([photo(0), photo(1)])
        XCTAssertEqual(profile.cameraAngle.pattern, .noEvidence)
        XCTAssertTrue(profile.unsupportedCharacteristics.contains(.cameraAngle))
        XCTAssertTrue(profile.isEmpty)
    }

    func testLowQualityEvidenceCountsLessThanHighQuality() {
        // Two low-quality eye-level photos against two high-quality low-angle photos.
        let f = ProfileAggregator.aggregate([
            photo(0, angle: .eyeLevel, quality: .low), photo(1, angle: .eyeLevel, quality: .low),
            photo(2, angle: .lowAngle, quality: .high), photo(3, angle: .lowAngle, quality: .high)
        ]).cameraAngle
        XCTAssertEqual(f.counts[.eyeLevel], 2)
        XCTAssertEqual(f.counts[.lowAngle], 2)
        XCTAssertGreaterThan(f.weightedShares[.lowAngle] ?? 0, f.weightedShares[.eyeLevel] ?? 1)
    }

    func testAggregationIsDeterministicRegardlessOfOrder() {
        let a = [photo(0, angle: .eyeLevel, framing: .halfBody), photo(1, angle: .highAngle, framing: .halfBody),
                 photo(2, angle: .eyeLevel, framing: .fullBody)]
        let p1 = ProfileAggregator.aggregate(a, generatedAt: Date(timeIntervalSince1970: 0))
        let p2 = ProfileAggregator.aggregate(a.reversed(), generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(p1.cameraAngle.dominant, p2.cameraAngle.dominant)
        XCTAssertEqual(p1.subjectFraming.counts, p2.subjectFraming.counts)
        XCTAssertEqual(p1.cameraAngle.summary, p2.cameraAngle.summary)
    }

    // MARK: - Positioning & depth summaries

    func testPositioningRecurrenceAndNumericSummary() {
        let results = [
            photo(0, zone: (.center, .middle), center: CGPoint(x: 0.50, y: 0.50)),
            photo(1, zone: (.center, .middle), center: CGPoint(x: 0.52, y: 0.48)),
            photo(2, zone: (.center, .middle), center: CGPoint(x: 0.48, y: 0.52)),
            photo(3, zone: (.left, .middle), center: CGPoint(x: 0.20, y: 0.50))
        ]
        let profile = ProfileAggregator.aggregate(results)
        XCTAssertEqual(profile.horizontalPosition.dominant, .center)
        XCTAssertEqual(profile.horizontalPosition.isolated, [.left], "the variation is preserved, not averaged away")
        XCTAssertEqual(profile.verticalPosition.dominant, .middle)
        XCTAssertEqual(profile.positioning.sampleCount, 4)
        XCTAssertEqual(profile.positioning.centerX?.median ?? 0, 0.49, accuracy: 0.02)
        XCTAssertEqual(profile.positioning.centerXConsistency, .moderate)
    }

    func testTypicalCenterRequiresAgreement() {
        let tight = ProfileAggregator.aggregate([
            photo(0, zone: (.center, .middle), center: CGPoint(x: 0.5, y: 0.5)),
            photo(1, zone: (.center, .middle), center: CGPoint(x: 0.52, y: 0.5))
        ]).positioning
        XCTAssertNotNil(tight.typicalCenter)

        let scattered = ProfileAggregator.aggregate([
            photo(0, zone: (.left, .upper), center: CGPoint(x: 0.1, y: 0.1)),
            photo(1, zone: (.right, .lower), center: CGPoint(x: 0.9, y: 0.9))
        ]).positioning
        XCTAssertNil(scattered.typicalCenter, "no typical position when photos disagree")
    }

    func testNumericSummaryStatistics() throws {
        let s = try XCTUnwrap(NumericSummary.make([1, 2, 3, 4]))
        XCTAssertEqual(s.mean, 2.5, accuracy: 1e-9)
        XCTAssertEqual(s.median, 2.5, accuracy: 1e-9)
        XCTAssertEqual(s.standardDeviation, 1.118, accuracy: 0.001)
        XCTAssertEqual(s.consistency(tolerance: 1.0), .moderate)
        XCTAssertEqual(NumericSummary.make([5])?.consistency(tolerance: 1), .undetermined)
        XCTAssertNil(NumericSummary.make([]))
    }

    // MARK: - Camera hand-off

    @MainActor
    func testCameraBridgeUsesUpperBodyBoxesAndHonestPhotoCount() {
        let upper1 = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.4)
        let upper2 = CGRect(x: 0.32, y: 0.12, width: 0.4, height: 0.4)
        let results = [
            photo(0, zone: (.center, .upper), upperBox: upper1),
            photo(1, zone: (.center, .upper), upperBox: upper2),
            photo(2, zone: (.center, .upper), upperBox: nil),   // no upper-body detection: left out, not zeroed
            photo(3)                                            // no subject at all
        ]
        let camera = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(results), results: results)

        XCTAssertEqual(camera.photoCount, 2, "only photos that contributed a target count")
        let position = camera.subjectPositionDistribution
        XCTAssertEqual(position?.meanX ?? 0, 0.51, accuracy: 0.01)
        XCTAssertEqual(position?.meanY ?? 0, 0.31, accuracy: 0.01)
        XCTAssertEqual(position?.isConsistent, true)
        XCTAssertEqual(camera.halfBodyPositionDistribution, position)
        XCTAssertEqual(camera.subjectSizeDistribution?.meanArea ?? 0, 0.16, accuracy: 0.001)
    }

    @MainActor
    func testCameraBridgeWithNoSubjectsLeavesTargetsEmpty() {
        let results = [photo(0), photo(1)]
        let camera = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(results), results: results)
        XCTAssertEqual(camera.photoCount, 0)
        XCTAssertNil(camera.subjectPositionDistribution)
        XCTAssertNil(camera.subjectSizeDistribution)
    }

    @MainActor
    func testSingleSampleIsNeverFlaggedConsistent() {
        let results = [photo(0, zone: (.center, .middle), upperBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))]
        let camera = CameraProfileBridge.make(profile: ProfileAggregator.aggregate(results), results: results)
        XCTAssertEqual(camera.subjectPositionDistribution?.isConsistent, false)
        XCTAssertEqual(camera.subjectSizeDistribution?.isConsistent, false)
    }
}
