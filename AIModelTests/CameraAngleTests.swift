import XCTest
import CoreGraphics
@testable import AIModel

/// Camera-angle estimation without a horizon dependency: edge extraction,
/// the convergence fit, each provider's validity rules, and evidence fusion.
final class CameraAngleTests: XCTestCase {

    // MARK: - Fixtures

    private func lm(_ joint: BodyJoint, _ x: Double, _ y: Double, _ c: Double = 0.9) -> BodyLandmark {
        BodyLandmark(joint: joint, point: CGPoint(x: x, y: y), confidence: c)
    }

    /// Vertical edges following lean = c0 + k * X, X measured from the image centre in height units.
    private func segments(k: Double, c0: Double = 0, xs: [Double], length: Double = 0.3, aspect: Double = 0.75) -> [ImageLineSegment] {
        xs.map { X in
            let m = c0 + k * X
            let dy = length / (1 + m * m).squareRoot()
            let dxHeight = m * dy
            let cx = 0.5 + X / aspect
            return ImageLineSegment(
                start: CGPoint(x: cx - dxHeight / aspect / 2, y: 0.5 - dy / 2),
                end: CGPoint(x: cx + dxHeight / aspect / 2, y: 0.5 + dy / 2),
                length: length, strength: 0.6)
        }
    }

    private let spreadX: [Double] = [-0.34, -0.28, -0.22, -0.16, -0.10, -0.05, 0.05, 0.10, 0.16, 0.22, 0.28, 0.34]

    private func grid(labels: [String] = ["background", "wall (other)", "tree", "person"], width: Int = 100, height: Int = 100,
                      fill: (Int, Int) -> Int) -> SegmentationGrid {
        var indices = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { indices[y * width + x] = UInt8(fill(x, y)) } }
        return SegmentationGrid(width: width, height: height, classIndices: indices, labels: labels)
    }

    private let wallEverywhere: (Int, Int) -> Int = { _, _ in 1 }

    private func anchor(eyeY: Double, estimated: Bool = false, torsoTilt: Double? = nil) -> SubjectAnchor {
        SubjectAnchor(eyePoint: CGPoint(x: 0.5, y: eyeY), eyeSource: "test", isEstimated: estimated,
                      headHeight: 0.1, faceConfidence: 0.9, torsoTiltDegrees: torsoTilt)
    }

    private func sceneObservation(k: Double, eyeY: Double, count: Int = 12, estimated: Bool = false,
                                  cropAllowance: Double = 0.05) -> CameraAngleObservation {
        let xs = Array(spreadX.prefix(count))
        return SceneVerticalsProvider.observe(
            lines: .produced(segments(k: k, xs: xs)), segmentation: grid(fill: wallEverywhere), segmentationProblem: nil,
            anchor: anchor(eyeY: eyeY, estimated: estimated), aspect: 0.75, cropAllowance: cropAllowance).observation
    }

    // MARK: - Lens model and category rule

    func testCategoryRuleSeparatesFirmFromAmbiguousIntervals() {
        XCTAssertEqual(CameraAngleRule.categories(low: 9, high: 15), [.highAngle])
        XCTAssertEqual(CameraAngleRule.categories(low: -15, high: -9), [.lowAngle])
        XCTAssertEqual(CameraAngleRule.categories(low: -2, high: 3), [.eyeLevel])
        XCTAssertEqual(CameraAngleRule.categories(low: -12, high: 2), [.lowAngle, .eyeLevel])
        XCTAssertEqual(CameraAngleRule.categories(low: 2, high: 12), [.eyeLevel, .highAngle])
    }

    func testFocalLengthScalesWithAspectAndMillimetres() {
        // 26 mm equivalent on a 4:3 landscape frame: ~1.0 image heights.
        XCTAssertEqual(LensModel.focalLength(equivalentMM: 26, aspect: 4.0 / 3.0), 1.0, accuracy: 0.01)
        // The same lens on a 3:4 portrait frame sees more along its short side: ~0.75.
        XCTAssertEqual(LensModel.focalLength(equivalentMM: 26, aspect: 0.75), 0.75, accuracy: 0.01)
    }

    func testCropDetectionUsesNativeCameraProportions() {
        XCTAssertTrue(LensModel.looksUncropped(aspect: 0.75))
        XCTAssertTrue(LensModel.looksUncropped(aspect: 1.5))
        XCTAssertFalse(LensModel.looksUncropped(aspect: 1.0))
        XCTAssertFalse(LensModel.looksUncropped(aspect: 0.8), "4:5 is a typical crop")
    }

    // MARK: - Edge extraction on a rendered image with known geometry

    /// White canvas with dark lines converging toward a vanishing point above the frame.
    private func renderConvergingLines(width: Int = 320, height: Int = 480, vpY: Double = -600,
                                       bottomXs: [Double] = [30, 75, 120, 200, 245, 290]) -> [UInt8] {
        var pixels = [UInt8](repeating: 235, count: width * height)
        let vpX = Double(width) / 2
        for xb in bottomXs {
            for y in 40..<(height - 10) {
                let x = vpX + (xb - vpX) * (Double(y) - vpY) / (Double(height - 10) - vpY)
                for dx in -1...1 {
                    let px = Int(x.rounded()) + dx
                    if px >= 0 && px < width { pixels[y * width + px] = 30 }
                }
            }
        }
        return pixels
    }

    func testExtractorRecoversConvergingVerticalLines() throws {
        let pixels = renderConvergingLines()
        let found = VerticalLineExtractor.extractSegments(pixels: pixels, width: 320, height: 480)
        XCTAssertGreaterThanOrEqual(found.count, 6, "each rendered line gives at least one segment")
        XCTAssertTrue(found.allSatisfy { $0.length >= 0.10 })
        // Lines to the right of centre lean toward the centre going up (positive lean when read downward).
        for s in found {
            let dX = Double(s.end.x - s.start.x) * (320.0 / 480.0), dY = Double(s.end.y - s.start.y)
            let lean = dX / dY
            let X = (Double(s.start.x + s.end.x) / 2 - 0.5) * (320.0 / 480.0)
            if abs(X) > 0.1 { XCTAssertEqual(lean > 0, X > 0, "lean must have the sign of the lateral position") }
        }
    }

    func testConvergenceFitRecoversTheRenderedGeometry() throws {
        let found = VerticalLineExtractor.extractSegments(pixels: renderConvergingLines(), width: 320, height: 480)
        let fit = try XCTUnwrap(SceneVerticalsProvider.fit(found, aspect: 320.0 / 480.0))
        // Lean per unit lateral position = 1 / (distance from the image centre row to the vanishing point),
        // here (240 + 600) px, expressed in image-height units: 480 / 840.
        XCTAssertEqual(fit.k, 480.0 / 840.0, accuracy: 0.04)
        XCTAssertGreaterThan(fit.k, 0, "converging upward means positive k")
    }

    func testExtractorFindsParallelVerticalsAsLevel() throws {
        var pixels = [UInt8](repeating: 235, count: 320 * 480)
        for x in stride(from: 30, through: 290, by: 52) {
            for y in 40..<470 { for dx in -1...1 { pixels[y * 320 + x + dx] = 30 } }
        }
        let found = VerticalLineExtractor.extractSegments(pixels: pixels, width: 320, height: 480)
        let fit = try XCTUnwrap(SceneVerticalsProvider.fit(found, aspect: 320.0 / 480.0))
        XCTAssertEqual(fit.k, 0, accuracy: 0.03)
        XCTAssertEqual(fit.intercept, 0, accuracy: 0.02)
    }

    func testExtractorReportsNothingForAFlatImage() {
        let flat = [UInt8](repeating: 128, count: 320 * 480)
        XCTAssertTrue(VerticalLineExtractor.extractSegments(pixels: flat, width: 320, height: 480).isEmpty)
    }

    // MARK: - Scene-verticals provider

    func testParallelVerticalsAndEyesAboveCentreMeanCameraBelowEyes() throws {
        let o = sceneObservation(k: 0, eyeY: 0.30)
        XCTAssertTrue(o.validity.isValid)
        let e = try XCTUnwrap(o.elevation)
        XCTAssertEqual(CameraAngleRule.categories(low: e.likelyLow, high: e.likelyHigh), [.lowAngle])
        XCTAssertLessThanOrEqual(o.quality, .moderate, "quality is capped: crop and perspective edits are undetectable")
    }

    func testParallelVerticalsAndEyesAtCentreMeanEyeLevel() throws {
        let o = sceneObservation(k: 0, eyeY: 0.50)
        let e = try XCTUnwrap(o.elevation)
        XCTAssertEqual(CameraAngleRule.categories(low: e.likelyLow, high: e.likelyHigh), [.eyeLevel])
        XCTAssertEqual(o.quality, .moderate)
    }

    func testTiltedUpCameraWithCentredEyesMeansBelowEyes() throws {
        // Verticals converging upward: camera tilted up. Eyes at the centre: the camera looks up at them.
        let o = sceneObservation(k: 0.32, eyeY: 0.50)
        let e = try XCTUnwrap(o.elevation)
        XCTAssertEqual(CameraAngleRule.categories(low: e.likelyLow, high: e.likelyHigh), [.lowAngle])
        XCTAssertEqual(o.tiltHint, .up)
        XCTAssertLessThan(try XCTUnwrap(o.pitchDown).nominal, 0)
    }

    func testTiltedDownCameraWithCentredEyesMeansAboveEyes() throws {
        let o = sceneObservation(k: -0.32, eyeY: 0.50)
        let e = try XCTUnwrap(o.elevation)
        XCTAssertEqual(CameraAngleRule.categories(low: e.likelyLow, high: e.likelyHigh), [.highAngle])
        XCTAssertEqual(o.tiltHint, .down)
    }

    func testTiltUpWithEyesFarBelowCentreIsAmbiguousNotGuessed() throws {
        // Tilting up and having the eyes below centre pull in opposite directions; how far the
        // eyes are from the axis depends on the unknown lens, so the category is not settled.
        let o = sceneObservation(k: 0.20, eyeY: 0.70)
        let e = try XCTUnwrap(o.elevation)
        XCTAssertTrue(CameraAngleRule.categories(low: e.likelyLow, high: e.likelyHigh).count > 1)
        let fused = CameraAngleFusion.fuse([o], anchor: anchor(eyeY: 0.70))
        XCTAssertEqual(fused.category, .unknown)
        XCTAssertGreaterThan(fused.decision.possibleCategories.count, 1)
        XCTAssertLessThan(fused.decision.possibleCategories.count, 3, "something is still ruled out")
    }

    func testOpposingTiltAndEyeOffsetCancelInTheBestEstimate() throws {
        // Tilting up pushes the estimate one way, eyes below centre push it the other.
        let o = sceneObservation(k: 0.20, eyeY: 0.62)
        let e = try XCTUnwrap(o.elevation)
        XCTAssertEqual(CameraAngleRule.category(ofElevation: e.nominal), .eyeLevel)
        // With the unknown lens and crop in play the whole interval is honestly wide, so it is not asserted.
        XCTAssertGreaterThan(e.likelyHigh - e.likelyLow, 8)
    }

    func testTooFewStructuralEdgesIsNotApplicableRatherThanAGuess() {
        let o = SceneVerticalsProvider.observe(
            lines: .produced(segments(k: 0, xs: [-0.2, 0, 0.2])), segmentation: grid(fill: wallEverywhere),
            segmentationProblem: nil, anchor: anchor(eyeY: 0.4), aspect: 0.75, cropAllowance: 0.05).observation
        XCTAssertFalse(o.validity.isValid)
        XCTAssertNil(o.elevation)
    }

    func testEdgesOnTreesAndPeopleAreNotUsed() {
        // Left half of the frame is tree, so those edges must be filtered out.
        let g = grid { x, _ in x < 50 ? 2 : 1 }
        let result = SceneVerticalsProvider.observe(
            lines: .produced(segments(k: 0, xs: spreadX)), segmentation: g, segmentationProblem: nil,
            anchor: anchor(eyeY: 0.4), aspect: 0.75, cropAllowance: 0.05)
        let kept = SceneVerticalsProvider.structuralSegments(segments(k: 0, xs: spreadX), g)
        XCTAssertEqual(kept.count, 6, "only the six edges right of centre lie on structure")
        XCTAssertTrue(result.inliers.allSatisfy { $0.start.x >= 0.5 - 0.02 })
    }

    func testStronglyRolledCameraIsRejected() {
        let rolled = SceneVerticalsProvider.observe(
            lines: .produced(segments(k: 0, c0: 0.25, xs: spreadX)), segmentation: grid(fill: wallEverywhere),
            segmentationProblem: nil, anchor: anchor(eyeY: 0.4), aspect: 0.75, cropAllowance: 0.05).observation
        XCTAssertFalse(rolled.validity.isValid)
    }

    func testClusteredEdgesCannotMeasureConvergence() {
        let o = SceneVerticalsProvider.observe(
            lines: .produced(segments(k: 0, xs: [0.10, 0.11, 0.12, 0.13, 0.14, 0.15, 0.16, 0.17])),
            segmentation: grid(fill: wallEverywhere), segmentationProblem: nil, anchor: anchor(eyeY: 0.4),
            aspect: 0.75, cropAllowance: 0.05).observation
        XCTAssertFalse(o.validity.isValid)
    }

    func testMissingSegmentationDisablesTheProviderInsteadOfTrustingRawLines() {
        let o = SceneVerticalsProvider.observe(
            lines: .produced(segments(k: 0, xs: spreadX)), segmentation: nil, segmentationProblem: "model failed",
            anchor: anchor(eyeY: 0.4), aspect: 0.75, cropAllowance: 0.05).observation
        XCTAssertFalse(o.validity.isValid)
    }

    func testCropAllowanceWidensTheIntervalAndNeverNarrowsIt() throws {
        let narrow = try XCTUnwrap(sceneObservation(k: 0, eyeY: 0.5, cropAllowance: 0.05).elevation)
        let wide = try XCTUnwrap(sceneObservation(k: 0, eyeY: 0.5, cropAllowance: 0.20).elevation)
        XCTAssertLessThan(wide.likelyLow, narrow.likelyLow)
        XCTAssertGreaterThan(wide.likelyHigh, narrow.likelyHigh)
        XCTAssertEqual(wide.nominal, narrow.nominal, accuracy: 1e-9, "the allowance changes uncertainty, not the best estimate")
    }

    /// MEASURED regression. A level, eye-height photo (eyes at 0.4663 of a 4:3 frame) trimmed to 16:9
    /// moved the eyes to 0.2887 and, before the crop allowance, was reported as a confident low angle.
    func testASixteenByNineTrimOfALevelPhotoIsNoLongerAConfidentWrongAnswer() {
        let allowance = LensModel.verticalCropAllowance(aspect: 16.0 / 9.0)
        XCTAssertEqual(allowance, 0.15)
        let trimmed = sceneObservation(k: 0, eyeY: 0.2887, cropAllowance: allowance)
        let fused = CameraAngleFusion.fuse([trimmed], anchor: anchor(eyeY: 0.2887))
        XCTAssertNotEqual(fused.category, .lowAngle, "a possible crop must stop this from being asserted as low angle")
        XCTAssertTrue(fused.decision.possibleCategories.contains(.eyeLevel), "the true answer must remain possible")
    }

    func testCropPlausibilityFollowsTheProportions() {
        XCTAssertLessThan(LensModel.verticalCropAllowance(aspect: 0.75), LensModel.verticalCropAllowance(aspect: 1.5))
        XCTAssertLessThan(LensModel.verticalCropAllowance(aspect: 1.5), LensModel.verticalCropAllowance(aspect: 16.0 / 9.0))
        XCTAssertLessThan(LensModel.verticalCropAllowance(aspect: 16.0 / 9.0), LensModel.verticalCropAllowance(aspect: 1.0))
    }

    // MARK: - Subject geometry

    func testPostureIsMeasuredFromTheTorsoAxis() {
        let upright = PoseCandidate(landmarks: [lm(.neck, 0.5, 0.3), lm(.leftHip, 0.45, 0.6), lm(.rightHip, 0.55, 0.6)], observationConfidence: 0.9)
        XCTAssertEqual(try XCTUnwrap(SubjectGeometryProvider.torsoTilt(upright)), 0, accuracy: 1)
        let bent = PoseCandidate(landmarks: [lm(.neck, 0.8, 0.6), lm(.leftHip, 0.45, 0.6), lm(.rightHip, 0.55, 0.6)], observationConfidence: 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(SubjectGeometryProvider.torsoTilt(bent)), 60)
        XCTAssertNil(SubjectGeometryProvider.torsoTilt(PoseCandidate(landmarks: [lm(.neck, 0.5, 0.3)], observationConfidence: 0.9)))
    }

    func testEyeLineFallsBackToFaceRectangleAndSaysSo() {
        let face = FaceCandidate(box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2), confidence: 0.9,
                                 rollDegrees: 0, yawDegrees: 0, pitchDegrees: 0)
        let result = SubjectGeometryProvider.observe(pose: nil, face: face)
        XCTAssertEqual(result.anchor?.isEstimated, true)
        XCTAssertEqual(Double(result.anchor?.eyePoint.y ?? 0), 0.28, accuracy: 1e-6)
        XCTAssertFalse(SubjectGeometryProvider.observe(pose: nil, face: nil).observation.validity.isValid)
    }

    // MARK: - Depth cross-check

    private func depthObservation(headValue: Float, bodyValue: Float, boxHeight: Double = 0.8) -> CameraAngleObservation {
        let box = CGRect(x: 0.3, y: 0.1, width: 0.4, height: boxHeight)
        let seg = grid(labels: ["background", "person"]) { x, y in
            box.contains(CGPoint(x: Double(x) / 100, y: Double(y) / 100)) ? 1 : 0
        }
        var near = [Float](repeating: 0.2, count: 10_000)
        for y in 0..<100 { for x in 0..<100 where box.contains(CGPoint(x: Double(x) / 100, y: Double(y) / 100)) {
            near[y * 100 + x] = Double(y) / 100 < 0.1 + boxHeight * 0.3 ? headValue : bodyValue
        } }
        return DepthTiltProvider.observe(
            primary: HumanCandidate(id: 0, box: box, confidence: 0.9, upperBodyBox: nil, upperBodyConfidence: nil),
            segmentation: seg, depth: DepthGrid(width: 100, height: 100, nearness: near))
    }

    func testDepthOrderingGivesATiltHintOnlyWhenItClearsTheNoiseFloor() {
        XCTAssertEqual(depthObservation(headValue: 0.8, bodyValue: 0.4).tiltHint, .down)
        XCTAssertEqual(depthObservation(headValue: 0.4, bodyValue: 0.8).tiltHint, .up)
        XCTAssertEqual(depthObservation(headValue: 0.52, bodyValue: 0.50).tiltHint, .level)
    }

    func testDepthProviderDeclinesWhenTheSubjectIsTooShort() {
        let o = depthObservation(headValue: 0.8, bodyValue: 0.4, boxHeight: 0.2)
        XCTAssertFalse(o.validity.isValid)
        XCTAssertNil(o.tiltHint)
    }

    func testDepthProviderNeverSuppliesAnElevation() {
        XCTAssertNil(depthObservation(headValue: 0.8, bodyValue: 0.4).elevation)
        XCTAssertEqual(depthObservation(headValue: 0.8, bodyValue: 0.4).role, .corroborating)
    }

    // MARK: - Fusion

    private func decisive(_ provider: CameraAngleProvider, likely: ClosedRange<Double>, extended: ClosedRange<Double>? = nil,
                          quality: EvidenceQuality = .moderate, pitch: ClosedRange<Double>? = nil) -> CameraAngleObservation {
        let ext = extended ?? likely
        let nominal = (likely.lowerBound + likely.upperBound) / 2
        return CameraAngleObservation(
            provider: provider, role: .decisive, validity: .valid,
            elevation: AngleInterval(nominal: nominal, likelyLow: likely.lowerBound, likelyHigh: likely.upperBound,
                                     extendedLow: ext.lowerBound, extendedHigh: ext.upperBound),
            pitchDown: pitch.map { AngleInterval(nominal: ($0.lowerBound + $0.upperBound) / 2, likelyLow: $0.lowerBound,
                                                 likelyHigh: $0.upperBound, extendedLow: $0.lowerBound, extendedHigh: $0.upperBound) },
            tiltHint: nil, quality: quality, summary: "\(provider.rawValue) says something.", measurements: [], limitations: [])
    }

    private func unavailable(_ provider: CameraAngleProvider) -> CameraAngleObservation {
        .unavailable(provider, .decisive, .notApplicable("not visible"), summary: "\(provider.rawValue) unavailable.")
    }

    func testAMissingHorizonDoesNotForceUnknownWhenOtherEvidenceIsValid() {
        let out = CameraAngleFusion.fuse([unavailable(.horizonLine), decisive(.sceneVerticals, likely: 8...14)], anchor: anchor(eyeY: 0.4))
        XCTAssertEqual(out.category, .highAngle)
        XCTAssertEqual(out.status, .determined)
        XCTAssertEqual(out.decision.contributing, [.sceneVerticals])
        XCTAssertTrue(out.explanation.contains("inference, not a measurement"))
    }

    func testNoValidDecisiveEvidenceIsUnknownWithReasons() {
        let out = CameraAngleFusion.fuse([unavailable(.horizonLine), unavailable(.sceneVerticals)], anchor: nil)
        XCTAssertEqual(out.category, .unknown)
        XCTAssertEqual(out.status, .insufficientEvidence)
        XCTAssertEqual(out.decision.possibleCategories.count, 3, "no information rules nothing out")
        XCTAssertTrue(out.explanation.contains("horizonLine unavailable."), "each source's own account of why it could not observe is shown")
        XCTAssertTrue(out.explanation.contains("sceneVerticals unavailable."))
    }

    func testContradictingSourcesProduceUnknownNotACompromise() {
        let out = CameraAngleFusion.fuse([decisive(.horizonLine, likely: 8...14), decisive(.sceneVerticals, likely: -14...(-8))], anchor: anchor(eyeY: 0.4))
        XCTAssertEqual(out.category, .unknown)
        XCTAssertTrue(out.decision.possibleCategories.isEmpty)
        XCTAssertFalse(out.decision.conflicts.isEmpty)
    }

    func testAmbiguousEvidenceKeepsWhatWasRuledOut() {
        let out = CameraAngleFusion.fuse([decisive(.sceneVerticals, likely: -12...2)], anchor: anchor(eyeY: 0.4))
        XCTAssertEqual(out.category, .unknown)
        XCTAssertEqual(out.decision.possibleCategories, [.lowAngle, .eyeLevel])
        XCTAssertFalse(out.decision.possibleCategories.contains(.highAngle), "high angle is evidence-excluded, not merely unknown")
    }

    func testIndependentAgreementNarrowsAndMayRaiseQuality() {
        let one = CameraAngleFusion.fuse([decisive(.sceneVerticals, likely: 8...14, quality: .moderate)], anchor: nil)
        let two = CameraAngleFusion.fuse([decisive(.horizonLine, likely: 7...16, quality: .moderate),
                                          decisive(.sceneVerticals, likely: 8...14, quality: .moderate)], anchor: nil)
        XCTAssertEqual(one.quality, .moderate)
        XCTAssertEqual(two.quality, .high)
        XCTAssertEqual(two.category, .highAngle)
    }

    func testLensSensitivityLowersQuality() {
        let robust = CameraAngleFusion.fuse([decisive(.horizonLine, likely: 8...14, extended: 7...14, quality: .high)], anchor: nil)
        let sensitive = CameraAngleFusion.fuse([decisive(.horizonLine, likely: 8...14, extended: 2...14, quality: .high)], anchor: nil)
        XCTAssertEqual(robust.quality, .high)
        XCTAssertEqual(sensitive.quality, .moderate)
        XCTAssertEqual(sensitive.category, .highAngle)
    }

    func testNonUprightSubjectLowersQuality() {
        let upright = CameraAngleFusion.fuse([decisive(.sceneVerticals, likely: 8...14)], anchor: anchor(eyeY: 0.4, torsoTilt: 5))
        let bent = CameraAngleFusion.fuse([decisive(.sceneVerticals, likely: 8...14)], anchor: anchor(eyeY: 0.4, torsoTilt: 70))
        XCTAssertLessThan(bent.quality, upright.quality)
    }

    func testDepthCrossCheckCanLowerButNeverChangeTheCategory() {
        let main = decisive(.sceneVerticals, likely: 8...14, quality: .moderate, pitch: 5...10)   // firmly tilted down
        let contradicting = CameraAngleObservation(
            provider: .depthTilt, role: .corroborating, validity: .valid, elevation: nil, pitchDown: nil,
            tiltHint: .up, quality: .low, summary: "head farther", measurements: [], limitations: [])
        let agreeing = CameraAngleObservation(
            provider: .depthTilt, role: .corroborating, validity: .valid, elevation: nil, pitchDown: nil,
            tiltHint: .down, quality: .low, summary: "head nearer", measurements: [], limitations: [])

        let base = CameraAngleFusion.fuse([main], anchor: nil)
        let contra = CameraAngleFusion.fuse([main, contradicting], anchor: nil)
        let agree = CameraAngleFusion.fuse([main, agreeing], anchor: nil)
        XCTAssertEqual(contra.category, .highAngle)
        XCTAssertLessThan(contra.quality, base.quality)
        XCTAssertEqual(agree.quality, base.quality, "agreement does not inflate confidence")
    }

    func testContextualProvidersNeverSelectACategory() {
        let head = HeadOrientationProvider.observe(face: FaceCandidate(box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2),
                                                                      confidence: 0.9, rollDegrees: 0, yawDegrees: 0, pitchDegrees: 40))
        XCTAssertNil(head.elevation)
        let out = CameraAngleFusion.fuse([unavailable(.horizonLine), unavailable(.sceneVerticals), head], anchor: nil)
        XCTAssertEqual(out.category, .unknown)
        XCTAssertTrue(out.limitations.contains { $0.contains("strongly pitched") })
    }

    // MARK: - Whole interpreter, no horizon anywhere

    private func indoorEvidence(lines: EvidenceOutcome<[ImageLineSegment]>, eyeY: Double)
        -> (SubjectSelection, PhotoEvidence, PhotoArtifacts) {
        let person = HumanCandidate(id: 0, box: CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.9), confidence: 0.9,
                                    upperBodyBox: nil, upperBodyConfidence: nil)
        let pose = PoseCandidate(landmarks: [
            lm(.nose, 0.5, eyeY + 0.03), lm(.leftEye, 0.47, eyeY), lm(.rightEye, 0.53, eyeY),
            lm(.leftShoulder, 0.4, eyeY + 0.15), lm(.rightShoulder, 0.6, eyeY + 0.15)
        ], observationConfidence: 0.9)
        let face = FaceCandidate(box: CGRect(x: 0.44, y: eyeY - 0.05, width: 0.12, height: 0.12), confidence: 0.9,
                                 rollDegrees: 0, yawDegrees: 5, pitchDegrees: 25)
        let evidence = PhotoEvidence(
            humans: .produced([person]), pose: .produced([pose]), faces: .produced([face]), imageRoll: .nothingDetected,
            segmentation: .skipped("not needed"), depth: .skipped("not run"), sceneContext: .skipped("not run"), runs: [],
            verticalLines: lines)
        return (SubjectSelector.select(from: [person]), evidence, PhotoArtifacts(segmentation: grid(fill: wallEverywhere), depth: nil))
    }

    func testIndoorPhotoWithVerticalStructureGetsAnAngleWithoutAHorizon() {
        let (sel, ev, art) = indoorEvidence(lines: .produced(segments(k: 0, xs: spreadX)), eyeY: 0.50)
        let r = CameraAngleInterpreter.interpret(selection: sel, evidence: ev, artifacts: art, imageSize: CGSize(width: 750, height: 1000))
        XCTAssertEqual(r.category, .eyeLevel)
        XCTAssertEqual(r.assessment.status, .determined)
        XCTAssertEqual(r.decision?.contributing, [.sceneVerticals])
        XCTAssertNil(r.horizonCue, "no horizon was used, so none is presented")
        XCTAssertFalse(r.sceneLines.isEmpty)
        let text = r.assessment.explanation.lowercased()
        XCTAssertFalse(text.contains("horizon passes") || text.contains("horizon runs"), "must not claim a horizon was detected")
        XCTAssertTrue(text.contains("vertical lines"))
        XCTAssertTrue(text.contains("no horizon is visible"))
    }

    func testIndoorPhotoWithNoStructureStaysUnknownWithReasons() {
        let (sel, ev, art) = indoorEvidence(lines: .nothingDetected, eyeY: 0.35)
        let r = CameraAngleInterpreter.interpret(selection: sel, evidence: ev, artifacts: art, imageSize: CGSize(width: 750, height: 1000))
        XCTAssertEqual(r.category, .unknown)
        XCTAssertEqual(r.assessment.status, .insufficientEvidence)
        XCTAssertEqual(r.headPitchDegrees, 25, "recorded as context")
        XCTAssertEqual(r.observations.count, 5)
        XCTAssertTrue(r.assessment.explanation.lowercased().contains("no horizon"))
    }

    func testLookingUpOrDownDoesNotChangeTheResult() {
        let lines = EvidenceOutcome.produced(segments(k: 0, xs: spreadX))
        func result(pitch: Double) -> CameraAngleCategory {
            var (sel, ev, art) = indoorEvidence(lines: lines, eyeY: 0.50)
            ev.faces = .produced([FaceCandidate(box: CGRect(x: 0.44, y: 0.45, width: 0.12, height: 0.12), confidence: 0.9,
                                                rollDegrees: 0, yawDegrees: 0, pitchDegrees: pitch)])
            _ = sel; sel = SubjectSelector.select(from: ev.humans.value ?? []); _ = art
            return CameraAngleInterpreter.interpret(selection: sel, evidence: ev, artifacts: art, imageSize: CGSize(width: 750, height: 1000)).category
        }
        XCTAssertEqual(result(pitch: -35), result(pitch: 35))
        XCTAssertEqual(result(pitch: 0), result(pitch: 35))
    }

    /// The headline verdict and the provider observations must never disagree in words.
    func testExplanationNeverContradictsTheVerdict() {
        for eyeY in [0.30, 0.44, 0.50, 0.56, 0.70] {
            let (sel, ev, art) = indoorEvidence(lines: .produced(segments(k: 0, xs: spreadX)), eyeY: eyeY)
            let r = CameraAngleInterpreter.interpret(selection: sel, evidence: ev, artifacts: art, imageSize: CGSize(width: 750, height: 1000))
            let text = r.assessment.explanation.lowercased()
            if r.category == .unknown { continue }
            let verdict = text.components(separatedBy: "basis:").first ?? text
            let observations = text.components(separatedBy: "basis:").dropFirst().joined()
            XCTAssertFalse(observations.contains("so the camera is"), "observations must not carry a second verdict: \(text)")
            switch r.category {
            case .lowAngle: XCTAssertTrue(verdict.contains("below"))
            case .highAngle: XCTAssertTrue(verdict.contains("above"))
            default: XCTAssertTrue(verdict.contains("eye height"))
            }
        }
    }

    func testBothSourcesPresentAreReportedTogether() {
        // Horizon cue exists in the legacy fixture style: sea above y=0.4, eyes at 0.58.
        let (sel, ev, _) = indoorEvidence(lines: .produced(segments(k: 0, xs: spreadX)), eyeY: 0.58)
        let sea = grid(labels: ["background", "sky (other)", "sea"]) { _, y in y < 40 ? 1 : 2 }
        let r = CameraAngleInterpreter.interpret(selection: sel, evidence: ev, artifacts: PhotoArtifacts(segmentation: sea, depth: nil),
                                                 imageSize: CGSize(width: 1000, height: 1000))
        XCTAssertNotNil(r.horizonCue)
        XCTAssertTrue(r.decision?.contributing.contains(.horizonLine) == true)
    }
}
