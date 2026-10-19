//
//  PhotoStatistics.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 19/10/26.
//


import CoreImage
import Foundation
import Vision

// MARK: - Photo Statistics

/// Measurements of a captured photo that decide how strongly it is enhanced.
///
/// All values are taken from the ORIGINAL capture:
/// - tone and colour from a small downscaled copy (tone does not need detail),
/// - noise from a full-resolution centre crop (downscaling would average the
///   noise away),
/// - faces from the Vision observations the enhancer already has.
nonisolated struct PhotoStatistics: Sendable, Equatable {
    /// Mean luminance, 0 (black) … 1 (white).
    var meanLuminance: Double
    /// Standard deviation of luminance: global contrast. ~0.1 is flat, ~0.25 punchy.
    var contrast: Double
    /// Mean HSV saturation, 0 … 1.
    var saturation: Double
    /// Mean red minus mean blue, -1 … 1. Positive is a warm cast, negative cool.
    var colorCast: Double
    /// Estimated noise sigma on 0 … 1 luminance (Immerkær). ~0.005 is clean,
    /// ~0.03 is visibly grainy.
    var noise: Double
    /// Width of the largest face as a fraction of the image width; 0 without faces.
    var largestFaceWidth: Double

    var hasFace: Bool { largestFaceWidth > 0 }

    /// Long side of the copy used for tone and colour.
    private static let toneSampleSize: CGFloat = 256
    /// Side of the full-resolution crop used for noise.
    private static let noiseCropSize: CGFloat = 256

    static func measure(_ image: CIImage, faces: [VNFaceObservation], context: CIContext) -> PhotoStatistics {
        let extent = image.extent
        let faceWidth = faces.map { Double($0.boundingBox.width) }.max() ?? 0

        // Tone and colour
        var stats = PhotoStatistics(meanLuminance: 0.5, contrast: 0.2, saturation: 0.3,
                                    colorCast: 0, noise: 0.01, largestFaceWidth: faceWidth)
        let scale = min(1, toneSampleSize / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let pixels = rgba(of: small, in: small.extent.integral, context: context) {
            var lumaSum = 0.0, lumaSquareSum = 0.0, saturationSum = 0.0, castSum = 0.0
            for (r, g, b) in pixels {
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumaSum += luma
                lumaSquareSum += luma * luma
                let maxChannel = max(r, g, b)
                saturationSum += maxChannel > 0 ? (maxChannel - min(r, g, b)) / maxChannel : 0
                castSum += r - b
            }
            let count = Double(pixels.count)
            let mean = lumaSum / count
            stats.meanLuminance = mean
            stats.contrast = sqrt(max(lumaSquareSum / count - mean * mean, 0))
            stats.saturation = saturationSum / count
            stats.colorCast = castSum / count
        }

        // Noise, from the centre where the subject usually is.
        let side = min(noiseCropSize, extent.width, extent.height)
        let crop = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2,
                          width: side, height: side).integral
        if let pixels = rgba(of: image, in: crop, context: context) {
            let luma = pixels.map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 }
            stats.noise = estimateNoise(luma: luma, width: Int(crop.width), height: Int(crop.height))
        }

        return stats
    }

    /// Immerkær's fast noise estimate: the mean absolute response of a kernel
    /// that cancels smooth gradients and leaves pixel-level noise.
    /// Strong edges also respond, so this reads somewhat high on busy scenes —
    /// acceptable, since busy scenes need less sharpening too.
    static func estimateNoise(luma: [Double], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, luma.count == width * height else { return 0 }
        var sum = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let response =
                      luma[i - width - 1] - 2 * luma[i - width] + luma[i - width + 1]
                    - 2 * luma[i - 1]     + 4 * luma[i]         - 2 * luma[i + 1]
                    + luma[i + width - 1] - 2 * luma[i + width] + luma[i + width + 1]
                sum += abs(response)
            }
        }
        return sum * sqrt(Double.pi / 2) / (6 * Double(width - 2) * Double(height - 2))
    }

    /// RGB values (0 … 1, sRGB) of `rect` in `image`, row by row.
    private static func rgba(of image: CIImage, in rect: CGRect, context: CIContext) -> [(Double, Double, Double)]? {
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: rect,
                       format: .RGBA8, colorSpace: colorSpace)

        var pixels: [(Double, Double, Double)] = []
        pixels.reserveCapacity(width * height)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            pixels.append((Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255))
        }
        return pixels
    }
}
