import Foundation
import CoreImage
import CoreGraphics
import Accelerate
import UIKit

/// Protocol defining the Core Image analysis service interface.
protocol CoreImageAnalyzing {
    func analyzeLighting(cgImage: CGImage) -> LightingAnalysis
    func analyzeColors(cgImage: CGImage) -> ColorAnalysis
}

/// CoreImageAnalysisService — pixel-level analysis using Core Image and Accelerate.
///
/// Extracts:
/// - Lighting: brightness (mean luminance), contrast (std dev), saturation
/// - Color: dominant colors via k-means clustering, harmony classification
/// - Color temperature: warm/cool bias from R/B channel ratio
final class CoreImageAnalysisService: CoreImageAnalyzing {

    // MARK: - Lighting Analysis

    func analyzeLighting(cgImage: CGImage) -> LightingAnalysis {
        guard let pixelData = extractLuminanceData(from: cgImage) else {
            return LightingAnalysis(meanBrightness: nil, brightnessStdDev: nil, meanSaturation: nil, pixelCount: 0)
        }

        let pixelCount = pixelData.count
        guard pixelCount > 0 else {
            return LightingAnalysis(meanBrightness: nil, brightnessStdDev: nil, meanSaturation: nil, pixelCount: 0)
        }

        // Use Accelerate vDSP for fast statistics
        let mean = vDSP.mean(pixelData)
        // Compute variance: E[X²] - E[X]²
        let meanSquare = vDSP.meanSquare(pixelData)
        let variance = meanSquare - mean * mean
        let stdDev = sqrt(max(variance, 0))

        // Saturation: use the difference between max and min RGB channels
        let saturation = computeMeanSaturation(from: cgImage)

        return LightingAnalysis(
            meanBrightness: Double(mean),
            brightnessStdDev: Double(stdDev),
            meanSaturation: saturation,
            pixelCount: pixelCount
        )
    }

    /// Extracts luminance values (0-1) from the image using vImage.
    private func extractLuminanceData(from cgImage: CGImage) -> [Float]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                       bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
                                       space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)

        // Downsample for performance: sample every Nth pixel
        let sampleStride = max(1, (width * height) / 10_000)  // Max ~10K samples
        var luminanceValues: [Float] = []
        luminanceValues.reserveCapacity(width * height / sampleStride)

        var index = 0
        while index < width * height {
            let offset = index * bytesPerPixel
            let r = Float(buffer[offset]) / 255.0
            let g = Float(buffer[offset + 1]) / 255.0
            let b = Float(buffer[offset + 2]) / 255.0

            // Rec. 601 luma coefficients
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            luminanceValues.append(luma)

            index += sampleStride
        }

        return luminanceValues
    }

    /// Computes mean saturation from RGB data.
    private func computeMeanSaturation(from cgImage: CGImage) -> Double? {
        guard let rgbaData = extractRGBData(from: cgImage) else { return nil }

        let count = rgbaData.count / 4
        guard count > 0 else { return nil }

        var totalSaturation: Float = 0

        for i in 0..<count {
            let offset = i * 4
            let r = Float(rgbaData[offset]) / 255.0
            let g = Float(rgbaData[offset + 1]) / 255.0
            let b = Float(rgbaData[offset + 2]) / 255.0

            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let diff = maxC - minC

            let saturation: Float
            if maxC == 0 {
                saturation = 0
            } else {
                saturation = diff / maxC
            }
            totalSaturation += saturation
        }

        return Double(totalSaturation / Float(count))
    }

    /// Extracts raw RGBA pixel data from a CGImage.
    private func extractRGBData(from cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                       bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
                                       space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let bytePtr = data.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)
        var result = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for i in 0..<(width * height * bytesPerPixel) {
            result[i] = bytePtr[i]
        }
        return result
    }

    // MARK: - Color Analysis

    func analyzeColors(cgImage: CGImage) -> ColorAnalysis {
        guard let rgbaData = extractRGBData(from: cgImage) else {
            return ColorAnalysis(dominantColors: [], harmony: nil, colorTemperature: nil)
        }

        let width = cgImage.width
        let height = cgImage.height
        let totalPixels = width * height
        let bytesPerPixel = 4

        // Sample pixels for k-means (max 5000 samples for performance)
        let sampleCount = min(5000, totalPixels)
        let stride = max(1, totalPixels / sampleCount)

        var samples: [(r: Double, g: Double, b: Double)] = []
        samples.reserveCapacity(sampleCount)

        var index = 0
        while index < totalPixels && samples.count < sampleCount {
            let offset = index * bytesPerPixel
            let r = Double(rgbaData[offset]) / 255.0
            let g = Double(rgbaData[offset + 1]) / 255.0
            let b = Double(rgbaData[offset + 2]) / 255.0
            samples.append((r, g, b))
            index += stride
        }

        guard !samples.isEmpty else {
            return ColorAnalysis(dominantColors: [], harmony: nil, colorTemperature: nil)
        }

        // K-means clustering with k=5
        let clusters = kMeansCluster(samples: samples, k: 5, iterations: 10)

        let dominantColors = clusters.map { cluster in
            DominantColor(
                red: cluster.center.r,
                green: cluster.center.g,
                blue: cluster.center.b,
                proportion: Double(cluster.count) / Double(samples.count)
            )
        }.sorted { $0.proportion > $1.proportion }

        // Determine color harmony
        let harmony = classifyColorHarmony(colors: dominantColors)

        // Compute color temperature (-1 = cool/blue, +1 = warm/red)
        var totalWarmth: Double = 0
        for sample in samples {
            totalWarmth += (sample.r - sample.b)
        }
        let avgWarmth = totalWarmth / Double(samples.count)
        let colorTemperature = max(-1.0, min(1.0, avgWarmth * 2.0))

        return ColorAnalysis(
            dominantColors: dominantColors,
            harmony: harmony,
            colorTemperature: colorTemperature
        )
    }

    /// Simple k-means clustering for color quantization.
    private func kMeansCluster(samples: [(r: Double, g: Double, b: Double)], k: Int, iterations: Int) -> [(center: (r: Double, g: Double, b: Double), count: Int)] {
        guard !samples.isEmpty, k > 0 else { return [] }

        // Initialize centroids evenly spaced across the sample set
        var centroids: [(r: Double, g: Double, b: Double)] = []
        let step = max(1, samples.count / k)
        for i in 0..<k {
            let idx = min(i * step, samples.count - 1)
            centroids.append(samples[idx])
        }

        var assignments = [Int](repeating: 0, count: samples.count)

        for _ in 0..<iterations {
            // Assign each sample to nearest centroid
            for (i, sample) in samples.enumerated() {
                var bestCluster = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (c, centroid) in centroids.enumerated() {
                    let dr = sample.r - centroid.r
                    let dg = sample.g - centroid.g
                    let db = sample.b - centroid.b
                    let dist = dr * dr + dg * dg + db * db
                    if dist < bestDist {
                        bestDist = dist
                        bestCluster = c
                    }
                }
                assignments[i] = bestCluster
            }

            // Update centroids
            var sums = [(r: Double, g: Double, b: Double, count: Int)](repeating: (0, 0, 0, 0), count: k)
            for (i, cluster) in assignments.enumerated() {
                sums[cluster].r += samples[i].r
                sums[cluster].g += samples[i].g
                sums[cluster].b += samples[i].b
                sums[cluster].count += 1
            }

            for c in 0..<k {
                if sums[c].count > 0 {
                    centroids[c] = (
                        r: sums[c].r / Double(sums[c].count),
                        g: sums[c].g / Double(sums[c].count),
                        b: sums[c].b / Double(sums[c].count)
                    )
                }
            }
        }

        // Build result with counts
        var counts = [Int](repeating: 0, count: k)
        for cluster in assignments {
            counts[cluster] += 1
        }

        return centroids.enumerated().map { (index, center) in
            (center: center, count: counts[index])
        }.filter { $0.count > 0 }
    }

    /// Classifies color harmony based on dominant colors.
    private func classifyColorHarmony(colors: [DominantColor]) -> ColorHarmony {
        guard colors.count >= 2 else { return .monochromatic }

        let topColors = Array(colors.prefix(3))

        // Compute hue for each color
        let hues = topColors.map { color -> Double in
            let r = color.red, g = color.green, b = color.blue
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let diff = maxC - minC

            if diff == 0 { return 0 }  // achromatic

            var hue: Double
            if maxC == r {
                hue = 60 * ((g - b) / diff).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = 60 * ((b - r) / diff + 2)
            } else {
                hue = 60 * ((r - g) / diff + 4)
            }
            if hue < 0 { hue += 360 }
            return hue
        }

        // Check saturation — if all colors are near-grayscale, it's neutral
        let avgSaturation = topColors.map { color -> Double in
            let maxC = max(color.red, max(color.green, color.blue))
            let minC = min(color.red, max(color.green, color.blue))
            return maxC == 0 ? 0 : (maxC - minC) / maxC
        }.reduce(0, +) / Double(topColors.count)

        if avgSaturation < 0.1 {
            return .neutral
        }

        // Warm/cool dominant
        let avgTemp = topColors.map { $0.red - $0.blue }.reduce(0, +) / Double(topColors.count)
        if avgTemp > 0.15 { return .warm }
        if avgTemp < -0.15 { return .cool }

        // Check hue relationships
        let sortedHues = hues.sorted()
        let hueDiff1 = abs(sortedHues[0] - sortedHues[sortedHues.count - 1])

        if hueDiff1 < 30 || hues.allSatisfy({ abs($0 - hues[0]) < 30 }) {
            return .analogous
        }

        if hues.count >= 2 {
            let diff = abs(hues[0] - hues[1])
            if diff > 150 && diff < 210 {
                return .complementary
            }
        }

        if hues.count >= 3 {
            // Rough triadic check: hues spread ~120° apart
            let spread = sortedHues.last! - sortedHues.first!
            if spread > 200 {
                return .triadic
            }
        }

        return .neutral
    }
}

// MARK: - Result Types

struct LightingAnalysis {
    let meanBrightness: Double?     // 0-1
    let brightnessStdDev: Double?   // 0-1 (contrast indicator)
    let meanSaturation: Double?     // 0-1
    let pixelCount: Int
}

struct ColorAnalysis {
    let dominantColors: [DominantColor]
    let harmony: ColorHarmony?
    let colorTemperature: Double?   // -1 (cool) to +1 (warm)
}
