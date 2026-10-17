import Foundation
import CoreGraphics

/// Stage B/C: finds straight, near-vertical edges in the upright photo.
///
/// This is ordinary image processing (Sobel gradients, thin-edge selection,
/// connected components, a principal-axis line fit). It is NOT a model and it
/// does not interpret anything: a tree trunk and a door frame look the same
/// here. The scene-geometry provider decides later which segments are usable.
///
/// Why only near-vertical edges: in the world, verticals (walls, door frames,
/// building corners, lamp posts) are parallel. In a photo they stay parallel
/// only if the camera is level; when it tilts, they converge. That convergence
/// is the one scene cue that reveals camera tilt without needing a horizon.
nonisolated enum VerticalLineExtractor {

    /// Long edge of the working grayscale image.
    static let workingLongEdge = 640
    /// Edges more than this far from vertical are ignored.
    static let maximumAngleFromVertical = 30.0
    /// Shortest accepted segment, as a fraction of image height.
    static let minimumLengthFraction = 0.10
    static let maximumSegments = 120

    static func run(on image: CGImage) -> (EvidenceOutcome<[ImageLineSegment]>, SourceRunRecord) {
        let start = ContinuousClock.now
        func record(_ state: SourceRunRecord.State, _ detail: String) -> SourceRunRecord {
            SourceRunRecord(source: .imageLineAnalysis, state: state,
                            durationMilliseconds: start.elapsedMilliseconds, detail: detail)
        }

        guard let gray = grayscale(image) else {
            let message = "The photo could not be converted for edge analysis."
            return (.failed(message), record(.failed, message))
        }
        let segments = extractSegments(pixels: gray.pixels, width: gray.width, height: gray.height)
        if segments.isEmpty { return (.nothingDetected, record(.nothingDetected, "no long vertical edges")) }
        return (.produced(segments), record(.produced, "\(segments.count) near-vertical edge segment(s)"))
    }

    // MARK: Grayscale

    static func grayscale(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let scale = min(1.0, Double(workingLongEdge) / Double(max(image.width, image.height)))
        let w = max(16, Int((Double(image.width) * scale).rounded()))
        let h = max(16, Int((Double(image.height) * scale).rounded()))
        var data = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (data, w, h) : nil
    }

    // MARK: Segment extraction

    /// Works on a row-major grayscale buffer whose row 0 is the TOP of the image.
    static func extractSegments(pixels p: [UInt8], width w: Int, height h: Int) -> [ImageLineSegment] {
        guard w >= 16, h >= 16 else { return [] }

        // Sobel gradients.
        var gx = [Int16](repeating: 0, count: w * h)
        var gy = [Int16](repeating: 0, count: w * h)
        var histogram = [Int](repeating: 0, count: 1100)
        var counted = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let a = Int(p[i - w - 1]), b = Int(p[i - w]), c = Int(p[i - w + 1])
                let d = Int(p[i - 1]), f = Int(p[i + 1])
                let g = Int(p[i + w - 1]), hh = Int(p[i + w]), k = Int(p[i + w + 1])
                let sx = (c + 2 * f + k) - (a + 2 * d + g)
                let sy = (g + 2 * hh + k) - (a + 2 * b + c)
                gx[i] = Int16(sx); gy[i] = Int16(sy)
                histogram[min(1099, abs(sx))] += 1
                counted += 1
            }
        }

        // Adaptive threshold: half of the 97th percentile, never below a noise floor.
        var cumulative = 0, p97 = 0
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if Double(cumulative) >= 0.97 * Double(counted) { p97 = value; break }
        }
        let threshold = max(70, p97 / 2)
        let tanLimit = tan(maximumAngleFromVertical * .pi / 180)

        // Thin vertical-ish edges: strong horizontal gradient, local maximum across x.
        var edge = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 2..<(w - 2) {
                let i = y * w + x
                let m = abs(Int(gx[i]))
                guard m >= threshold, Double(abs(Int(gy[i]))) <= tanLimit * Double(m) else { continue }
                if m >= abs(Int(gx[i - 1])) && m > abs(Int(gx[i + 1])) { edge[i] = true }
            }
        }

        // Connected components (8-neighbourhood plus a one-row gap bridge).
        var parent = Array(0..<(w * h))
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        for y in 1..<(h - 1) {
            for x in 2..<(w - 2) {
                let i = y * w + x
                guard edge[i] else { continue }
                for (dx, dy) in [(-1, -1), (0, -1), (1, -1), (-1, 0), (-1, -2), (0, -2), (1, -2)] {
                    let nx = x + dx, ny = y + dy
                    if ny >= 1, nx >= 2, nx < w - 2, edge[ny * w + nx] { union(i, ny * w + nx) }
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in 0..<(w * h) where edge[i] { groups[find(i), default: []].append(i) }

        let minimumLength = minimumLengthFraction * Double(h)
        var segments: [ImageLineSegment] = []

        for key in groups.keys.sorted() {
            let members = groups[key]!
            guard Double(members.count) >= minimumLength * 0.5 else { continue }

            // Principal-axis fit.
            var sx = 0.0, sy = 0.0
            for i in members { sx += Double(i % w); sy += Double(i / w) }
            let n = Double(members.count)
            let mx = sx / n, my = sy / n
            var cxx = 0.0, cyy = 0.0, cxy = 0.0
            for i in members {
                let dx = Double(i % w) - mx, dy = Double(i / w) - my
                cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
            }
            cxx /= n; cyy /= n; cxy /= n
            let trace = cxx + cyy
            let root = (((cxx - cyy) / 2) * ((cxx - cyy) / 2) + cxy * cxy).squareRoot()
            let l1 = trace / 2 + root, l2 = max(0, trace / 2 - root)
            guard l1 > 0 else { continue }

            let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
            var dx = cos(theta), dy = sin(theta)
            if dy < 0 { dx = -dx; dy = -dy }
            guard dy > 1e-6, atan(abs(dx) / dy) * 180 / .pi <= maximumAngleFromVertical else { continue }

            var tMin = Double.greatestFiniteMagnitude, tMax = -Double.greatestFiniteMagnitude
            var strength = 0.0
            for i in members {
                let t = (Double(i % w) - mx) * dx + (Double(i / w) - my) * dy
                tMin = min(tMin, t); tMax = max(tMax, t)
                strength += Double(abs(Int(gx[i])))
            }
            let length = tMax - tMin
            // A line: long enough, thin, and densely traced rather than scattered noise.
            guard length >= minimumLength, l2 <= 0.03 * l1, l2.squareRoot() <= 1.8,
                  n >= 0.5 * length else { continue }

            segments.append(ImageLineSegment(
                start: CGPoint(x: (mx + tMin * dx + 0.5) / Double(w), y: (my + tMin * dy + 0.5) / Double(h)),
                end: CGPoint(x: (mx + tMax * dx + 0.5) / Double(w), y: (my + tMax * dy + 0.5) / Double(h)),
                length: length / Double(h),
                strength: min(1, strength / n / 1020)))
        }

        return Array(segments.sorted {
            $0.length != $1.length ? $0.length > $1.length : $0.start.x < $1.start.x
        }.prefix(maximumSegments))
    }
}
