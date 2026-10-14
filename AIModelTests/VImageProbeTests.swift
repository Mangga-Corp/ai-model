import XCTest
import CoreGraphics
import Accelerate
@testable import AIModel

/// Diagnostic probe for the vImage luminance pipeline.
///
/// Exists to answer one question: does `vImageScale_Planar8` into an 8-bit
/// planar grayscale buffer actually produce usable pixel values, and in what
/// byte order? The production service's correctness depends on this.
final class VImageProbeTests: XCTestCase {

    func testProbe_vImageScalePlanar8Output() {
        let size = 64

        // Build a known gradient image: left column black, right column white.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            XCTFail("no context"); return
        }

        for x in 0..<size {
            let t = Double(x) / Double(size - 1)
            context.setFillColor(CGColor(red: t, green: t, blue: t, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: size))
        }

        guard let image = context.makeImage() else {
            XCTFail("no image"); return
        }

        // Attempt the same conversion the service performs.
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            renderingIntent: .defaultIntent
        ) else {
            XCTFail("no format"); return
        }

        // PROBE 1: does the throwing init succeed at all?
        var sourceBuffer: vImage_Buffer?
        do {
            sourceBuffer = try vImage_Buffer(cgImage: image, format: format, flags: .noFlags)
        } catch {
            XCTFail("vImage_Buffer init threw: \(error)"); return
        }

        guard let src = sourceBuffer else {
            XCTFail("vImage_Buffer returned nil without throwing"); return
        }
        defer { src.free() }

        print("PROBE source: \(src.width)x\(src.height) rowBytes=\(src.rowBytes)")

        // PROBE 2: is the source buffer non-zero?
        let srcBytes = src.data.assumingMemoryBound(to: UInt8.self)
        var srcSum = 0
        let srcRowBytes = Int(src.rowBytes)
        let srcHeight = Int(src.height)
        let srcLimit = min(256, srcHeight * srcRowBytes)
        for i in 0..<srcLimit {
            srcSum += Int(srcBytes[i])
        }
        print("PROBE source byte sum (first 256) = \(srcSum)")

        // PROBE 3: scale down to 16x16 and inspect.
        guard var dest = try? vImage_Buffer(width: 16, height: 16, bitsPerPixel: 8) else {
            XCTFail("no dest buffer"); return
        }
        defer { dest.free() }

        var mutableSrc = src
        let err = vImageScale_Planar8(&mutableSrc, &dest, nil, vImage_Flags(kvImageNoFlags))
        print("PROBE scale error = \(err)")

        let destBytes = dest.data.assumingMemoryBound(to: UInt8.self)
        print("PROBE dest rowBytes = \(dest.rowBytes) (width is 16)")

        // Print the first row of the destination.
        var rowDescription = "PROBE dest row0: "
        for x in 0..<16 {
            rowDescription += "\(destBytes[x]) "
        }
        print(rowDescription)

        var destSum = 0
        let destRowBytes = Int(dest.rowBytes)
        for i in 0..<(16 * destRowBytes) {
            destSum += Int(destBytes[i])
        }
        print("PROBE dest total byte sum = \(destSum)")

        // The key assertion: values must actually vary across the row.
        let minVal = (0..<16).map { destBytes[$0] }.min() ?? 0
        let maxVal = (0..<16).map { destBytes[$0] }.max() ?? 0
        print("PROBE dest row0 min=\(minVal) max=\(maxVal)")

        // Surface the measurements through an assertion so they land in the
        // test report even when simulator stdout is not captured.
        let diagnostics = """
        rowBytes=\(dest.rowBytes) row0=[\(rowDescription)] \
        sum=\(destSum) min=\(minVal) max=\(maxVal) \
        srcSum=\(srcSum) srcRowBytes=\(src.rowBytes) scaleErr=\(err)
        """

        XCTAssertTrue(maxVal > minVal,
            "Scaled buffer must vary. Diagnostics:\(diagnostics)")
    }
}
