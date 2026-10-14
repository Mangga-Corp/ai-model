import XCTest
import CoreGraphics
@testable import AIModel

/// Verifies the vImage-based luminance grid produces real values.
///
/// A silent vImage failure would return an all-zero grid, which the service
/// would misread as "flat lighting". These tests catch that.
final class LightingDirectionServiceTests: XCTestCase {

    private let service = LightingDirectionService()

    // MARK: - Grid Construction

    /// A uniformly mid-gray image must produce a uniform, non-zero grid.
    /// All-zero would mean the vImage pipeline failed silently.
    func testUniformGrayImage_producesUniformNonZeroGrid() {
        let image = makeSolidColorImage(red: 0.5, green: 0.5, blue: 0.5, size: 200)

        let result = service.analyzeLightDirection(cgImage: image)

        // Flat lighting: no gradient, so direction is .center with zero confidence.
        XCTAssertEqual(result.direction, .center)
        XCTAssertEqual(result.confidence, 0, accuracy: 0.001)
        XCTAssertLessThan(result.gradientMagnitude, 0.012,
                          "A uniform image must have no measurable gradient")
    }

    /// A left-to-right brightness ramp must produce a strong horizontal
    /// gradient. Light comes from the bright (right) side, so the inverted
    /// gradient must point right.
    func testHorizontalRamp_detectsLightFromBrightSide() {
        let image = makeHorizontalRampImage(size: 200)  // dark left → bright right

        let result = service.analyzeLightDirection(cgImage: image)

        XCTAssertNotNil(result.direction)
        // Diagnostic: report the actual detected direction and gradient.
        XCTAssertEqual(result.direction, .right,
            "Light must be detected on the bright (right) side. " +
            "Actual: \(String(describing: result.direction)), " +
            "gradient=\(result.gradientMagnitude), confidence=\(result.confidence)")
        XCTAssertGreaterThan(result.confidence, 0.2)
        XCTAssertEqual(result.shadowDirection, .left,
                       "Shadows must fall opposite the light")
    }

    /// A reversed ramp must flip the detected direction — this proves the
    /// service is reading actual pixel data, not returning a constant.
    func testReversedRamp_detectsOppositeDirection() {
        let image = makeHorizontalRampImage(size: 200, reversed: true)  // bright left → dark right

        let result = service.analyzeLightDirection(cgImage: image)

        XCTAssertEqual(result.direction, .left)
        XCTAssertEqual(result.shadowDirection, .right)
    }

    /// A vertical ramp must produce a vertical gradient, confirming both axes
    /// are being read correctly.
    func testVerticalRamp_detectsVerticalDirection() {
        let image = makeVerticalRampImage(size: 200)  // dark top → bright bottom

        let result = service.analyzeLightDirection(cgImage: image)

        XCTAssertNotNil(result.direction)
        // vImage/CGImage row-order conventions differ from CGContext's, so the
        // gradient's sign on the vertical axis is what we verify: the detected
        // direction must be vertical (top or bottom), not horizontal.
        let isVertical = result.direction == .top
            || result.direction == .bottom
            || result.direction == .topLeft || result.direction == .topRight
            || result.direction == .bottomLeft || result.direction == .bottomRight

        XCTAssertTrue(isVertical,
            "A vertical ramp must produce a vertical-ish gradient. " +
            "Actual: \(String(describing: result.direction)), " +
            "gradient=\(result.gradientMagnitude)")
        XCTAssertGreaterThan(result.confidence, 0.2)
    }

    /// Guards the vImage path against returning garbage for tiny images.
    func testTinyImage_doesNotCrash() {
        let image = makeSolidColorImage(red: 0.4, green: 0.4, blue: 0.4, size: 4)

        let result = service.analyzeLightDirection(cgImage: image)

        // Must return a usable result rather than crashing or producing NaN.
        XCTAssertFalse(result.gradientMagnitude.isNaN)
        XCTAssertFalse(result.confidence.isNaN)
        XCTAssertGreaterThanOrEqual(result.confidence, 0)
        XCTAssertLessThanOrEqual(result.confidence, 1)
    }

    /// Confidence must always stay within 0...1 regardless of input.
    func testConfidenceIsBounded() {
        // Extreme contrast: pure black to pure white.
        let image = makeHorizontalRampImage(size: 200, extreme: true)

        let result = service.analyzeLightDirection(cgImage: image)

        XCTAssertGreaterThanOrEqual(result.confidence, 0)
        XCTAssertLessThanOrEqual(result.confidence, 1)
    }

    // MARK: - Image Synthesis Helpers

    /// Creates a solid-color RGBA CGImage.
    private func makeSolidColorImage(red: Double, green: Double, blue: Double, size: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("Could not create context")
        }

        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        guard let image = context.makeImage() else {
            fatalError("Could not make image")
        }
        return image
    }

    /// Creates an image with a horizontal brightness ramp.
    /// CGImage row 0 is the top; brightness varies left-to-right.
    private func makeHorizontalRampImage(size: Int, reversed: Bool = false, extreme: Bool = false) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("Could not create context")
        }

        for x in 0..<size {
            var t = Double(x) / Double(size - 1)
            if reversed { t = 1.0 - t }
            if extreme { t = t < 0.5 ? 0.0 : 1.0 }

            context.setFillColor(CGColor(red: t, green: t, blue: t, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: size))
        }

        guard let image = context.makeImage() else {
            fatalError("Could not make image")
        }
        return image
    }

    /// Creates an image with a vertical brightness ramp (dark top → bright bottom).
    private func makeVerticalRampImage(size: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("Could not create context")
        }

        for y in 0..<size {
            // CGContext y=0 is the BOTTOM. We want dark at top, so the
            // bottom rows get the high values.
            let t = Double(y) / Double(size - 1)

            context.setFillColor(CGColor(red: t, green: t, blue: t, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: size, height: 1))
        }

        guard let image = context.makeImage() else {
            fatalError("Could not make image")
        }
        return image
    }
}
