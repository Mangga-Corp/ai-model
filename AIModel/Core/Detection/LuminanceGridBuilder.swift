import Foundation
import CoreGraphics
import Accelerate

/// Builds small luminance grids from a CGImage using vImage.
///
/// Shared by `LightingDirectionService` and `SymmetryAnalysisService` so the
/// downsample + RGB→luma conversion exists in exactly one place.
///
/// vImage handles the resize and the Rec. 601 luma conversion in a single
/// vectorized C call, which is dramatically faster than walking pixels in
/// Swift. The returned grid is row-major, top-down, normalized to 0...1.
enum LuminanceGridBuilder {

    /// Grid size used across the analysis pipeline.
    static let defaultGridSize = 64

    /// Builds a square luminance grid from the image.
    /// Returns nil if the image cannot be converted or scaled.
    static func build(from cgImage: CGImage, gridSize: Int = defaultGridSize) -> [Float]? {
        // 8-bit planar grayscale format — vImage converts from the image's
        // native colorspace and applies luma coefficients for us.
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            renderingIntent: .defaultIntent
        ) else {
            return nil
        }

        guard var sourceBuffer = try? vImage_Buffer(
            cgImage: cgImage,
            format: format,
            flags: .noFlags
        ) else {
            return nil
        }
        defer { sourceBuffer.free() }

        guard var destBuffer = try? vImage_Buffer(
            width: gridSize,
            height: gridSize,
            bitsPerPixel: 8
        ) else {
            return nil
        }
        defer { destBuffer.free() }

        // High-quality Lanczos downscale in one call.
        let error = vImageScale_Planar8(
            &sourceBuffer,
            &destBuffer,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
        )
        guard error == kvImageNoError else { return nil }

        // Convert the 8-bit plane to normalized Float (0-1) with vDSP.
        //
        // vImage may pad rowBytes beyond the row width (it aligns rows), so we
        // copy row by row rather than assuming the buffer is contiguous.
        let rowBytes = Int(destBuffer.rowBytes)
        let raw = destBuffer.data.assumingMemoryBound(to: UInt8.self)

        var grid = [Float](repeating: 0, count: gridSize * gridSize)

        if rowBytes == gridSize {
            // Fast path: tightly packed, one vectorized conversion.
            vDSP_vfltu8(raw, 1, &grid, 1, vDSP_Length(gridSize * gridSize))
        } else {
            // Strided path: convert each row, then normalize.
            var row = [Float](repeating: 0, count: gridSize)
            for y in 0..<gridSize {
                let rowStart = raw.advanced(by: y * rowBytes)
                vDSP_vfltu8(rowStart, 1, &row, 1, vDSP_Length(gridSize))
                grid.replaceSubrange(y * gridSize..<(y + 1) * gridSize, with: row)
            }
        }

        var scale = Float(1.0 / 255.0)
        vDSP_vsmul(grid, 1, &scale, &grid, 1, vDSP_Length(grid.count))

        return grid
    }
}
