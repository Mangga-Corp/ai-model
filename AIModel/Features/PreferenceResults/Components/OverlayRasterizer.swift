import UIKit
import CoreGraphics

/// Turns the retained model grids into translucent images for the overlays.
/// Pure rendering of existing outputs: no inference happens here.
nonisolated enum OverlayRasterizer {

    /// Person pixels tinted; everything else transparent.
    static func personMask(_ grid: SegmentationGrid) -> UIImage? {
        guard let person = grid.personClassIndex, grid.width > 0, grid.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: grid.width * grid.height * 4)
        for i in 0..<(grid.width * grid.height) where Int(grid.classIndices[i]) == person {
            // Premultiplied RGBA, 45% opacity cyan.
            pixels[i * 4 + 0] = 0
            pixels[i * 4 + 1] = UInt8(0.80 * 0.45 * 255)
            pixels[i * 4 + 2] = UInt8(1.00 * 0.45 * 255)
            pixels[i * 4 + 3] = UInt8(0.45 * 255)
        }
        return image(from: pixels, width: grid.width, height: grid.height)
    }

    /// Every supported region tinted by its colour; people are left untinted so the
    /// subject stays visible. With `highlight`, only that region is emphasised.
    /// Draws the model's actual class map, cell for cell: nothing is smoothed or invented.
    static func segmentation(_ grid: SegmentationGrid, highlight: String? = nil) -> UIImage? {
        guard grid.width > 0, grid.height > 0, grid.classIndices.count == grid.width * grid.height else { return nil }
        let mapping = SegmentationTaxonomy.Mapping(labels: grid.labels)
        var colours: [(r: Double, g: Double, b: Double)?] = []
        var alphas: [Double] = []
        for f in mapping.families {
            if f.group == .person { colours.append(nil); alphas.append(0); continue }
            colours.append(RegionPalette.rgb(for: f))
            alphas.append(highlight == nil ? 0.50 : (highlight == f.key ? 0.72 : 0.08))
        }
        var pixels = [UInt8](repeating: 0, count: grid.width * grid.height * 4)
        for i in 0..<(grid.width * grid.height) {
            let c = Int(grid.classIndices[i])
            guard c < mapping.familyOfClass.count else { continue }
            let f = mapping.familyOfClass[c]
            guard f >= 0, let rgb = colours[f] else { continue }
            let a = alphas[f]
            pixels[i * 4 + 0] = UInt8(rgb.r * a * 255)
            pixels[i * 4 + 1] = UInt8(rgb.g * a * 255)
            pixels[i * 4 + 2] = UInt8(rgb.b * a * 255)
            pixels[i * 4 + 3] = UInt8(a * 255)
        }
        return image(from: pixels, width: grid.width, height: grid.height)
    }

    /// Near = warm, far = cool.
    static func depthHeatmap(_ grid: DepthGrid) -> UIImage? {
        guard grid.width > 0, grid.height > 0, grid.nearness.count == grid.width * grid.height else { return nil }
        var pixels = [UInt8](repeating: 0, count: grid.width * grid.height * 4)
        let alpha = 0.6
        for (i, value) in grid.nearness.enumerated() {
            let (r, g, b) = colour(Double(min(1, max(0, value))))
            pixels[i * 4 + 0] = UInt8(r * alpha * 255)
            pixels[i * 4 + 1] = UInt8(g * alpha * 255)
            pixels[i * 4 + 2] = UInt8(b * alpha * 255)
            pixels[i * 4 + 3] = UInt8(alpha * 255)
        }
        return image(from: pixels, width: grid.width, height: grid.height)
    }

    /// Blue -> cyan -> yellow -> red.
    static func colour(_ t: Double) -> (Double, Double, Double) {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0.10, 0.15, 0.60)), (0.35, (0.00, 0.75, 0.85)),
            (0.65, (0.98, 0.88, 0.20)), (1.00, (0.90, 0.15, 0.10))
        ]
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
            let f = (t - t0) / (t1 - t0)
            return (c0.0 + (c1.0 - c0.0) * f, c0.1 + (c1.1 - c0.1) * f, c0.2 + (c1.2 - c0.2) * f)
        }
        return stops[stops.count - 1].1
    }

    private static func image(from pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        var data = pixels
        let image: CGImage? = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        return image.map { UIImage(cgImage: $0) }
    }
}

/// Small cache so toggling a layer does not re-render it.
@MainActor
enum OverlayImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(key: String, make: () -> UIImage?) -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let made = make() else { return nil }
        cache.setObject(made, forKey: key as NSString)
        return made
    }
}
