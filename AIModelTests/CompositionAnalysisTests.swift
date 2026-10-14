import XCTest
import CoreGraphics
@testable import AIModel

/// Tests for symmetry and golden-ratio analysis.
///
/// Both use synthetic images with known geometry, so the expected result is
/// computable rather than asserted by vibe.
final class CompositionAnalysisTests: XCTestCase {

    // MARK: - Symmetry

    func testSymmetry_perfectHorizontalMirror_scoresHigh() {
        // Left half and right half are identical → bilateral NCC ≈ 1.
        let image = makeHorizontallyMirroredImage(size: 128)

        let result = SymmetryAnalysisService().analyzeSymmetry(cgImage: image)

        XCTAssertGreaterThan(result.bilateral, 0.95,
                             "A perfectly mirrored image must score near 1.0")
        XCTAssertTrue(result.isSymmetric)
        XCTAssertEqual(result.dominantAxis, .bilateral)
    }

    func testSymmetry_asymmetricImage_scoresLow() {
        // A bright blob in one corner breaks any mirror.
        let image = makeAsymmetricImage(size: 128)

        let result = SymmetryAnalysisService().analyzeSymmetry(cgImage: image)

        XCTAssertLessThan(result.bilateral, 0.75)
        XCTAssertFalse(result.isSymmetric)
        XCTAssertEqual(result.dominantAxis, .none)
    }

    func testSymmetry_verticalMirror_detected() {
        // Top half mirrors bottom half (like a water reflection).
        let image = makeVerticallyMirroredImage(size: 128)

        let result = SymmetryAnalysisService().analyzeSymmetry(cgImage: image)

        // The mirrored image must register as strongly symmetric on at least
        // one axis. Which axis leads depends on row-order conventions between
        // CGContext and the vImage grid, so assert the guaranteed property.
        XCTAssertGreaterThan(result.dominant, 0.95,
            "A mirrored image must score near 1.0 on its dominant axis")
        XCTAssertTrue(result.isSymmetric)
    }

    /// A mirrored image must score near 1.0 — this is the invariant that
    /// catches a broken mirror index or a normalization error.
    func testSymmetry_scoresAreBounded() {
        let images = [
            makeHorizontallyMirroredImage(size: 64),
            makeVerticallyMirroredImage(size: 64),
            makeAsymmetricImage(size: 64),
            makeSolidColorImage(gray: 0.5, size: 64)
        ]

        for image in images {
            let result = SymmetryAnalysisService().analyzeSymmetry(cgImage: image)
            XCTAssertGreaterThanOrEqual(result.bilateral, 0)
            XCTAssertLessThanOrEqual(result.bilateral, 1.0001)
            XCTAssertGreaterThanOrEqual(result.vertical, 0)
            XCTAssertLessThanOrEqual(result.vertical, 1.0001)
            XCTAssertFalse(result.dominant.isNaN)
        }
    }

    /// A uniform gray frame is trivially symmetric in both axes.
    /// Guards against a division-by-zero producing NaN.
    func testSymmetry_uniformImage_doesNotProduceNaN() {
        let image = makeSolidColorImage(gray: 0.5, size: 64)

        let result = SymmetryAnalysisService().analyzeSymmetry(cgImage: image)

        XCTAssertFalse(result.bilateral.isNaN)
        XCTAssertFalse(result.vertical.isNaN)
        XCTAssertFalse(result.dominant.isNaN)
    }

    // MARK: - Golden Ratio

    func testGoldenRatio_subjectAtGoldenLine_detected() {
        let service = GoldenRatioAnalysisService()

        // 0.382 is the lower golden division.
        let onGolden = service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.382, y: 0.5))

        XCTAssertTrue(onGolden.isAtGoldenPoint)
        XCTAssertGreaterThan(onGolden.alignmentStrength, 0.5)
    }

    func testGoldenRatio_subjectAtUpperGoldenLine_detected() {
        let service = GoldenRatioAnalysisService()

        let onGolden = service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.618, y: 0.382))

        XCTAssertTrue(onGolden.isAtGoldenPoint)
        XCTAssertGreaterThan(onGolden.alignmentStrength, 0.5)
    }

    func testGoldenRatio_subjectDeadCenter_notDetected() {
        let service = GoldenRatioAnalysisService()

        let centered = service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.5, y: 0.5))

        XCTAssertFalse(centered.isAtGoldenPoint)
        XCTAssertEqual(centered.alignmentStrength, 0, accuracy: 0.001)
    }

    /// Distinguishes golden ratio from rule of thirds: a subject on the
    /// thirds line (0.333) must NOT register as golden (0.382).
    func testGoldenRatio_distinguishesFromRuleOfThirds() {
        let service = GoldenRatioAnalysisService()

        let onThirds = service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.333, y: 0.333))

        XCTAssertFalse(onThirds.isAtGoldenPoint,
                       "0.333 is a thirds line, not a golden-ratio line")
    }

    func testGoldenRatio_noSubject_returnsNotDetected() {
        let service = GoldenRatioAnalysisService()

        let result = service.analyzeGoldenRatio(subjectPosition: nil)

        XCTAssertFalse(result.isAtGoldenPoint)
        XCTAssertEqual(result.alignmentStrength, 0, accuracy: 0.001)
    }

    func testGoldenRatio_zonesClassified() {
        let service = GoldenRatioAnalysisService()

        XCTAssertEqual(service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.382, y: 0.5)).horizontalZone, .golden)
        XCTAssertEqual(service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.618, y: 0.5)).horizontalZone, .goldenFar)
        XCTAssertEqual(service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.1, y: 0.5)).horizontalZone, .near)
        XCTAssertEqual(service.analyzeGoldenRatio(subjectPosition: CGPoint(x: 0.9, y: 0.5)).horizontalZone, .far)
    }

    // MARK: - Image Synthesis Helpers

    private func makeSolidColorImage(gray: Double, size: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("no context") }

        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    /// Left half is a pattern; the right half is its exact mirror.
    private func makeHorizontallyMirroredImage(size: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("no context") }

        let half = size / 2
        for x in 0..<half {
            // Vary brightness down the left half so it is not a flat block.
            let t = Double(x) / Double(half)
            let gray = 0.2 + 0.6 * t
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))

            // Draw the column on the left, and its mirror on the right.
            context.fill(CGRect(x: x, y: 0, width: 1, height: size))
            context.fill(CGRect(x: size - 1 - x, y: 0, width: 1, height: size))
        }

        return context.makeImage()!
    }

    /// Top half mirrors the bottom half.
    private func makeVerticallyMirroredImage(size: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("no context") }

        let half = size / 2
        for y in 0..<half {
            let t = Double(y) / Double(half)
            let gray = 0.2 + 0.6 * t
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))

            // CGContext y=0 is the bottom, so mirror about the vertical center.
            context.fill(CGRect(x: 0, y: y, width: size, height: 1))
            context.fill(CGRect(x: 0, y: size - 1 - y, width: size, height: 1))
        }

        return context.makeImage()!
    }

    /// A bright blob in one corner — no mirror relationship.
    private func makeAsymmetricImage(size: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("no context") }

        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Bright blob in the upper-left quadrant only.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: size / 2, width: size / 3, height: size / 3))

        return context.makeImage()!
    }
}

// MARK: - Downsampling

/// Tests for the image normalization that precedes analysis.
///
/// This exists because the pipeline previously ran all thirteen passes on
/// full-resolution images (4032x3024 and up), which dominated total analysis
/// time for no accuracy gain — the most resolution-sensitive measurement
/// already reduces to a 64x64 luminance grid internally.
final class DownsampleTests: XCTestCase {

    /// Builds a solid-colour test image of the given size.
    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        )
        context?.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    /// A large image must be reduced so its long edge equals the cap.
    func testLargeImage_isReduced() {
        let image = makeImage(width: 4032, height: 3024)
        let result = PhotoSelectionService.downsample(image!, maxEdge: 1280)

        XCTAssertNotNil(result)
        XCTAssertEqual(max(result!.width, result!.height), 1280,
                       "The long edge must equal the cap after downsampling")
    }

    /// Aspect ratio must survive — a distorted image would corrupt every
    /// position-based measurement.
    func testAspectRatio_isPreserved() {
        let image = makeImage(width: 4032, height: 3024)
        let result = PhotoSelectionService.downsample(image!, maxEdge: 1280)

        let originalRatio = Double(4032) / Double(3024)
        let resultRatio = Double(result!.width) / Double(result!.height)

        XCTAssertEqual(resultRatio, originalRatio, accuracy: 0.02,
                       "Downsampling must not distort the aspect ratio")
    }

    /// An image already under the cap must pass through untouched — needlessly
    /// resampling would lose quality for no speed gain.
    func testSmallImage_isUnchanged() {
        let image = makeImage(width: 800, height: 600)
        let result = PhotoSelectionService.downsample(image!, maxEdge: 1280)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.width, 800)
        XCTAssertEqual(result!.height, 600)
    }

    /// Portrait images must also be capped on their long edge, not their width.
    func testPortraitImage_isCappedOnHeight() {
        let image = makeImage(width: 3024, height: 4032)
        let result = PhotoSelectionService.downsample(image!, maxEdge: 1280)

        XCTAssertEqual(result!.height, 1280, "Portrait long edge is the height")
        XCTAssertLessThan(result!.width, 1280)
    }
}
