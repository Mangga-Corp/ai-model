import XCTest
import UIKit
import CoreGraphics
@testable import AIModel

/// Focused checks for the preference-analysis interpretation layer: coordinate
/// handling, subject selection, and the four characteristic decision methods.
final class PreferenceAnalysisTests: XCTestCase {

    // MARK: - Fixtures

    private func person(_ id: Int = 0, box: CGRect, confidence: Double = 0.9, upper: CGRect? = nil) -> HumanCandidate {
        HumanCandidate(id: id, box: box, confidence: confidence, upperBodyBox: upper, upperBodyConfidence: upper == nil ? nil : 0.8)
    }

    private func lm(_ joint: BodyJoint, _ x: Double, _ y: Double, _ confidence: Double = 0.9) -> BodyLandmark {
        BodyLandmark(joint: joint, point: CGPoint(x: x, y: y), confidence: confidence)
    }

    private func evidence(humans: EvidenceOutcome<[HumanCandidate]>,
                          pose: EvidenceOutcome<[PoseCandidate]> = .nothingDetected,
                          faces: EvidenceOutcome<[FaceCandidate]> = .nothingDetected,
                          roll: EvidenceOutcome<ImageRollEvidence> = .nothingDetected,
                          segmentation: EvidenceOutcome<SegmentationSummary> = .skipped("not run"),
                          depth: EvidenceOutcome<DepthSummary> = .skipped("not run")) -> PhotoEvidence {
        PhotoEvidence(humans: humans, pose: pose, faces: faces, imageRoll: roll,
                      segmentation: segmentation, depth: depth, sceneContext: .skipped("not run"), runs: [])
    }

    private func selection(_ people: [HumanCandidate]) -> SubjectSelection { SubjectSelector.select(from: people) }

    // MARK: - Coordinate conventions

    func testVisionRectFlipsYExactlyOnce() {
        let r = ImageSpace.rect(fromVisionX: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(r.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 0.4, accuracy: 1e-9)   // 1 - 0.2 - 0.4
        XCTAssertEqual(r.width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(r.height, 0.4, accuracy: 1e-9)
        XCTAssertEqual(ImageSpace.point(fromVisionX: 0.25, y: 0.9).y, 0.1, accuracy: 1e-9)
    }

    func testAspectFitKeepsOverlayInsideLetterboxedImage() {
        // A 4:3 landscape image shown in a square container is letterboxed vertically.
        let fitted = ImageSpace.aspectFitRect(content: CGSize(width: 400, height: 300), in: CGSize(width: 400, height: 400))
        XCTAssertEqual(fitted, CGRect(x: 0, y: 50, width: 400, height: 300))

        let box = ImageSpace.viewRect(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), in: fitted)
        XCTAssertEqual(box, CGRect(x: 200, y: 200, width: 200, height: 150))
        XCTAssertEqual(ImageSpace.viewPoint(CGPoint(x: 0, y: 0), in: fitted), CGPoint(x: 0, y: 50))
    }

    func testTouchedEdgesUseMargin() {
        let edges = ImageSpace.touchedEdges(of: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.9))
        XCTAssertEqual(edges, [.bottom])
    }

    // MARK: - Input preparation

    /// A 40x20 picture, red on the left half and blue on the right half.
    private func twoToneImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, b: Int) {
        let space = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[2]))
    }

    func testPreparedImageIsUprightForExifRotatedSources() throws {
        // Same raw pixels (40 wide x 20 tall, red left / blue right), tagged as a
        // photo that must be rotated 90 degrees clockwise to display upright.
        let raw = try XCTUnwrap(twoToneImage().cgImage)
        let rotated = UIImage(cgImage: raw, scale: 1, orientation: .right)

        let prepared = PhotoPreparer.prepare(PhotoSource(id: UUID(), selectionOrder: 0, image: rotated))
        guard case .ready(let image, let record) = prepared.outcome else { return XCTFail("expected a ready image") }

        XCTAssertEqual(record.originalPixelWidth, 40)
        XCTAssertEqual(record.uprightWidth, 20, "orientation swaps the axes")
        XCTAssertEqual(record.uprightHeight, 40)
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 40)
        // Rotating clockwise puts the raw LEFT (red) at the TOP and RIGHT (blue) at the BOTTOM.
        let top = pixel(image, x: 10, y: 5), bottom = pixel(image, x: 10, y: 35)
        XCTAssertGreaterThan(top.r, 200); XCTAssertLessThan(top.b, 60)
        XCTAssertGreaterThan(bottom.b, 200); XCTAssertLessThan(bottom.r, 60)
    }

    func testPreparationLimitsLongEdgeWithoutChangingAspectRatio() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: format).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let prepared = PhotoPreparer.prepare(PhotoSource(id: UUID(), selectionOrder: 0, image: wide), longEdge: 1000)
        guard case .ready(let image, let record) = prepared.outcome else { return XCTFail("expected a ready image") }
        XCTAssertEqual(image.width, 1000)
        XCTAssertEqual(image.height, 500)
        XCTAssertEqual(record.scale, 1000.0 / 3000.0, accuracy: 0.001)
    }

    func testUnreadablePhotoYieldsNoDefaults() {
        let prepared = PhotoPreparer.prepare(PhotoSource(id: UUID(), selectionOrder: 0, image: nil))
        guard case .unreadable = prepared.outcome else { return XCTFail("expected unreadable") }
        let result = PhotoResultBuilder.unreadable(prepared, reason: "x")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.cameraAngle.assessment.status, .unavailable)
        XCTAssertNil(result.subjectPositioning.subjectBox)
        XCTAssertFalse(result.hasAnyDeterminedCharacteristic)
    }

    // MARK: - Subject selection

    func testPrimarySubjectIsIndependentOfInputOrder() {
        let big = person(0, box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.7))
        let small = person(1, box: CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.3))
        XCTAssertEqual(selection([big, small]).primary?.id, 0)
        XCTAssertEqual(selection([small, big]).primary?.id, 0)
        XCTAssertEqual(selection([small, big]).secondaries.map(\.id), [1])
    }

    func testNearTieIsBrokenByConfidenceThenCentrality() {
        let a = person(0, box: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.5), confidence: 0.6)
        let b = person(1, box: CGRect(x: 0.60, y: 0.1, width: 0.3, height: 0.5), confidence: 0.9)
        XCTAssertEqual(selection([a, b]).primary?.id, 1, "higher confidence wins an area tie")

        let c = person(2, box: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.5), confidence: 0.8)
        let d = person(3, box: CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.5), confidence: 0.8)
        XCTAssertEqual(selection([c, d]).primary?.id, 3, "more central wins when confidence also ties")
    }

    func testAmbiguityAndEligibility() {
        let a = person(0, box: CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5))
        let b = person(1, box: CGRect(x: 0.5, y: 0.0, width: 0.45, height: 0.45))
        XCTAssertTrue(selection([a, b]).info.isAmbiguous)

        let tiny = person(2, box: CGRect(x: 0.5, y: 0.5, width: 0.04, height: 0.04))
        let weak = person(3, box: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4), confidence: 0.1)
        let none = selection([tiny, weak])
        XCTAssertNil(none.primary)
        XCTAssertEqual(none.info.detectedCount, 2)
        XCTAssertEqual(none.info.eligibleCount, 0)
    }

    // MARK: - Subject positioning

    func testPositioningMeasuresBoxAndZones() {
        let p = person(box: CGRect(x: 0.05, y: 0.55, width: 0.2, height: 0.4))   // centre (0.15, 0.75)
        let result = SubjectPositioningMeasurer.measure(selection: selection([p]), evidence: evidence(humans: .produced([p])))
        XCTAssertTrue(result.isMeasurementValid)
        XCTAssertEqual(result.horizontal, .left)
        XCTAssertEqual(result.vertical, .lower)
        XCTAssertEqual(Double(result.center?.x ?? 0), 0.15, accuracy: 1e-9)
        XCTAssertEqual(result.normalizedArea ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertEqual(result.subjectBox, p.box)
        XCTAssertEqual(result.assessment.status, .determined)
    }

    func testNoDetectionNeverFabricatesABox() {
        let none = SubjectPositioningMeasurer.measure(selection: selection([]), evidence: evidence(humans: .nothingDetected))
        XCTAssertNil(none.subjectBox)
        XCTAssertNil(none.center)
        XCTAssertFalse(none.isMeasurementValid)
        XCTAssertEqual(none.assessment.status, .notApplicable)

        let failed = SubjectPositioningMeasurer.measure(selection: selection([]), evidence: evidence(humans: .failed("boom")))
        XCTAssertNil(failed.subjectBox)
        XCTAssertEqual(failed.assessment.status, .unavailable, "a failed detector is missing evidence, not 'no subject'")
    }

    // MARK: - Subject framing

    private func fullPose() -> PoseCandidate {
        PoseCandidate(landmarks: [
            lm(.nose, 0.5, 0.12), lm(.leftEye, 0.48, 0.11), lm(.rightEye, 0.52, 0.11),
            lm(.leftShoulder, 0.42, 0.22), lm(.rightShoulder, 0.58, 0.22), lm(.neck, 0.5, 0.2),
            lm(.leftHip, 0.45, 0.5), lm(.rightHip, 0.55, 0.5),
            lm(.leftKnee, 0.45, 0.7), lm(.rightKnee, 0.55, 0.7),
            lm(.leftAnkle, 0.45, 0.9), lm(.rightAnkle, 0.55, 0.9)
        ], observationConfidence: 0.9)
    }

    private func upperPose(lowerConfidence: Double = 0.0) -> PoseCandidate {
        PoseCandidate(landmarks: [
            lm(.nose, 0.5, 0.25), lm(.leftEye, 0.47, 0.23), lm(.rightEye, 0.53, 0.23),
            lm(.leftShoulder, 0.3, 0.45), lm(.rightShoulder, 0.7, 0.45), lm(.neck, 0.5, 0.42),
            // Unseen joints: Vision reports junk coordinates at zero confidence.
            lm(.leftHip, -0.01, 1.0, lowerConfidence), lm(.rightHip, -0.01, 1.0, lowerConfidence),
            lm(.leftAnkle, -0.01, 1.0, 0), lm(.rightAnkle, -0.01, 1.0, 0)
        ], observationConfidence: 0.9)
    }

    func testAnklesInsideFrameMeansFullBody() {
        let p = person(box: CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.88))
        let r = SubjectFramingInterpreter.interpret(selection: selection([p]),
                                                    evidence: evidence(humans: .produced([p]), pose: .produced([fullPose()])))
        XCTAssertEqual(r.category, .fullBody)
        XCTAssertEqual(r.visibleExtent, .toAnkles)
        XCTAssertEqual(r.assessment.status, .determined)
        XCTAssertEqual(r.assessment.quality, .high)
    }

    func testBodyCutByFrameBottomMeansHalfBody() {
        let p = person(box: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.9))   // runs to the bottom edge
        let r = SubjectFramingInterpreter.interpret(selection: selection([p]),
                                                    evidence: evidence(humans: .produced([p]), pose: .produced([upperPose()])))
        XCTAssertEqual(r.category, .halfBody)
        XCTAssertEqual(r.visibleExtent, .headAndShoulders, "zero-confidence joints must be ignored")
        XCTAssertTrue(r.croppedEdges.contains(.bottom))
    }

    func testMissingLegsWithoutCroppingIsNotHalfBody() {
        // Same landmarks, but the subject ends well inside the frame: legs may be
        // hidden or undetected. Missing ankles alone must NOT yield half body.
        let p = person(box: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.6))
        let r = SubjectFramingInterpreter.interpret(selection: selection([p]),
                                                    evidence: evidence(humans: .produced([p]), pose: .produced([upperPose()])))
        XCTAssertEqual(r.category, .unknown)
        XCTAssertEqual(r.assessment.status, .insufficientEvidence)
    }

    func testHeadOnlyCloseUpIsOther() {
        let pose = PoseCandidate(landmarks: [lm(.nose, 0.5, 0.4), lm(.leftEye, 0.45, 0.35), lm(.rightEye, 0.55, 0.35),
                                             lm(.leftEar, 0.35, 0.4), lm(.rightEar, 0.65, 0.4)], observationConfidence: 0.9)
        let p = person(box: CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.9))
        let r = SubjectFramingInterpreter.interpret(selection: selection([p]),
                                                    evidence: evidence(humans: .produced([p]), pose: .produced([pose])))
        XCTAssertEqual(r.category, .other)
    }

    func testNoPersonFramingDependsOnCrossCheck() {
        func summary(_ share: Double) -> EvidenceOutcome<SegmentationSummary> {
            .produced(SegmentationSummary(gridWidth: 10, gridHeight: 10, personFraction: share,
                                          personClassPresentInLabelTable: true, topClasses: []))
        }
        let agree = SubjectFramingInterpreter.interpret(
            selection: selection([]), evidence: evidence(humans: .nothingDetected, segmentation: summary(0)))
        XCTAssertEqual(agree.category, .other)
        XCTAssertEqual(agree.assessment.quality, .moderate)

        let conflict = SubjectFramingInterpreter.interpret(
            selection: selection([]), evidence: evidence(humans: .nothingDetected, segmentation: summary(0.2)))
        XCTAssertEqual(conflict.category, .unknown, "segmentation sees a person the detector missed")

        let failed = SubjectFramingInterpreter.interpret(selection: selection([]), evidence: evidence(humans: .failed("x")))
        XCTAssertEqual(failed.assessment.status, .unavailable)
    }

    // MARK: - Horizon fitting

    private func grid(width: Int = 100, height: Int = 100, labels: [String] = ["background", "sky (other)", "sea", "building (other)", "person"],
                      fill: (Int, Int) -> Int) -> SegmentationGrid {
        var indices = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { indices[y * width + x] = UInt8(fill(x, y)) } }
        return SegmentationGrid(width: width, height: height, classIndices: indices, labels: labels)
    }

    func testHorizonFitFindsSeaSkyBoundary() throws {
        let g = grid { _, y in y < 40 ? 1 : 2 }
        let fit = try XCTUnwrap(HorizonLineFitter.fit(g))
        XCTAssertEqual(fit.y(atX: 0.5), 0.40, accuracy: 0.011)
        XCTAssertTrue(fit.isOpenWater)
        XCTAssertGreaterThan(fit.columnCoverage, 0.9)
    }

    func testHorizonFitFollowsTiltedLine() throws {
        let g = grid { x, y in Double(y) < 30.0 + Double(x) * 0.2 ? 1 : 2 }
        let fit = try XCTUnwrap(HorizonLineFitter.fit(g))
        XCTAssertEqual(fit.slope, 0.2, accuracy: 0.03)
    }

    func testSkylineOfBuildingsIsNotAHorizon() {
        // Sky above a ragged building roofline: wrong region below, and not straight.
        let g = grid { x, y in y < 30 + (x % 20) ? 1 : 3 }
        XCTAssertNil(HorizonLineFitter.fit(g))
    }

    func testJaggedWaterlineIsRejected() {
        let g = grid { x, y in y < 30 + ((x * 7) % 30) ? 1 : 2 }
        XCTAssertNil(HorizonLineFitter.fit(g), "a boundary that is not straight is not a horizon")
    }

    // MARK: - Camera angle

    /// A subject with eyes at `eyeY`, head height 0.12, over a sea horizon at y = 0.40.
    private func angleResult(eyeY: Double, withHorizon: Bool = true, pitch: Double = 0) -> CameraAngleResult {
        let p = person(box: CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.9))
        let pose = PoseCandidate(landmarks: [
            lm(.nose, 0.5, eyeY + 0.03), lm(.leftEye, 0.47, eyeY), lm(.rightEye, 0.53, eyeY),
            lm(.leftShoulder, 0.4, eyeY + 0.15), lm(.rightShoulder, 0.6, eyeY + 0.15)
        ], observationConfidence: 0.9)
        let face = FaceCandidate(box: CGRect(x: 0.44, y: eyeY - 0.05, width: 0.12, height: 0.12), confidence: 0.9,
                                 rollDegrees: 0, yawDegrees: 0, pitchDegrees: pitch)
        let ev = evidence(humans: .produced([p]), pose: .produced([pose]), faces: .produced([face]))
        let seg = withHorizon ? grid { _, y in y < 40 ? 1 : 2 } : grid { _, _ in 0 }
        return CameraAngleInterpreter.interpret(selection: selection([p]), evidence: ev,
                                                artifacts: PhotoArtifacts(segmentation: seg, depth: nil),
                                                imageSize: CGSize(width: 1000, height: 1000))
    }

    func testEyesBelowHorizonMeansHighAngle() {
        let r = angleResult(eyeY: 0.58)   // (0.58 - 0.40) / 0.12 = 1.5 head heights below
        XCTAssertEqual(r.category, .highAngle)
        XCTAssertEqual(r.horizonCue?.offsetInHeadHeights ?? 0, 1.5, accuracy: 0.1)
        XCTAssertEqual(r.assessment.status, .determined)
    }

    func testEyesAboveHorizonMeansLowAngle() {
        XCTAssertEqual(angleResult(eyeY: 0.22).category, .lowAngle)
    }

    func testHorizonThroughTheHeadMeansEyeLevel() {
        let r = angleResult(eyeY: 0.42)
        XCTAssertEqual(r.category, .eyeLevel)
        XCTAssertEqual(r.assessment.quality, .high)
    }

    func testWithoutAHorizonTheAngleIsUnknownEvenWithFacePitch() {
        // A strongly pitched face is NOT camera-angle evidence.
        let r = angleResult(eyeY: 0.3, withHorizon: false, pitch: 30)
        XCTAssertEqual(r.category, .unknown)
        XCTAssertEqual(r.assessment.status, .insufficientEvidence)
        XCTAssertEqual(r.headPitchDegrees, 30)
        XCTAssertTrue(r.assessment.evidence.contains { $0.role == .contextual && $0.source == .visionFaceRectangles })
    }

    func testCameraAngleNeedsASubject() {
        let r = CameraAngleInterpreter.interpret(selection: selection([]), evidence: evidence(humans: .nothingDetected),
                                                 artifacts: PhotoArtifacts(), imageSize: nil)
        XCTAssertEqual(r.category, .unknown)
        XCTAssertEqual(r.assessment.status, .notApplicable)
    }

    // MARK: - Environmental depth

    private let subjectBox = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.7)

    private func depthResult(people: [HumanCandidate]? = nil,
                             humans: EvidenceOutcome<[HumanCandidate]>? = nil,
                             personPixels: Bool = true,
                             value: (Int, Int) -> Float) -> EnvironmentalDepthResult {
        let p = person(box: subjectBox)
        let list = people ?? [p]
        var nearness = [Float](repeating: 0, count: 100 * 100)
        for y in 0..<100 { for x in 0..<100 { nearness[y * 100 + x] = value(x, y) } }
        let depth = DepthGrid(width: 100, height: 100, nearness: nearness)
        let seg = grid(labels: ["background", "person"]) { x, y in
            personPixels && subjectBox.contains(CGPoint(x: Double(x) / 100, y: Double(y) / 100)) ? 1 : 0
        }
        return EnvironmentalDepthInterpreter.interpret(
            selection: selection(list),
            evidence: evidence(humans: humans ?? .produced(list)),
            artifacts: PhotoArtifacts(segmentation: seg, depth: depth))
    }

    private func insideSubject(_ x: Int, _ y: Int) -> Bool {
        subjectBox.contains(CGPoint(x: Double(x) / 100, y: Double(y) / 100))
    }

    func testNearSubjectOverFarBackgroundIsSeparated() throws {
        let r = depthResult { x, y in self.insideSubject(x, y) ? 0.8 : 0.2 }
        XCTAssertEqual(r.structure, .separated)
        let m = try XCTUnwrap(r.metrics)
        XCTAssertEqual(m.subjectRegionMethod, .personMask)
        XCTAssertEqual(m.subjectMinusEnvironment, 0.6, accuracy: 0.01)
        XCTAssertEqual(r.assessment.quality, .high)
    }

    func testElementsInFrontAndBehindMakeTheSceneLayered() {
        // A near strip on the left (in front of the subject) plus a far background.
        let r = depthResult { x, y in
            if self.insideSubject(x, y) { return 0.5 }
            return x < 20 ? 0.95 : 0.1
        }
        XCTAssertEqual(r.structure, .layered)
    }

    func testFlatDepthMapIsInsufficientNotInvented() {
        let r = depthResult { _, _ in 0.5 }
        XCTAssertEqual(r.structure, .unknown)
        XCTAssertEqual(r.assessment.status, .insufficientEvidence)
        XCTAssertNil(r.metrics)
    }

    func testMissingPersonMaskFallsBackToLowTrustBoxCore() throws {
        let r = depthResult(personPixels: false) { x, y in self.insideSubject(x, y) ? 0.8 : 0.2 }
        let m = try XCTUnwrap(r.metrics)
        XCTAssertEqual(m.subjectRegionMethod, .boxCore)
        XCTAssertEqual(r.assessment.quality, .low)
    }

    func testNoSubjectReportsSceneBandsOnly() {
        let r = depthResult(people: [], humans: .nothingDetected) { _, y in Float(y) / 100 }
        XCTAssertEqual(r.structure, .unknown)
        XCTAssertEqual(r.assessment.status, .notApplicable)
        XCTAssertNil(r.metrics)
        XCTAssertNotNil(r.sceneBands)
    }

    func testMissingDepthModelIsUnavailable() {
        let r = EnvironmentalDepthInterpreter.interpret(
            selection: selection([]), evidence: evidence(humans: .nothingDetected, depth: .failed("no model")),
            artifacts: PhotoArtifacts())
        XCTAssertEqual(r.assessment.status, .unavailable)
    }
}
