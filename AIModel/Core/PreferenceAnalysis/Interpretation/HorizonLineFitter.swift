import Foundation
import CoreGraphics

/// Recovers a physical horizon line from the DETR class map.
///
/// WHY THIS EXISTS. A point at the same height as the camera always projects
/// onto the horizon line, whatever the camera's tilt. So where the horizon runs
/// relative to a person's eyes reveals whether the camera is above, level with
/// or below the eyes. That is a geometric cue; face pitch and image roll are not.
///
/// WHAT QUALIFIES AS A HORIZON. Only a boundary where the sky meets open water
/// (sea / water) or flat ground (sand, grass, dirt, gravel, snow, playing
/// field) along a nearly straight line across a good share of the frame. A
/// skyline of buildings, trees or hills is jagged or has the wrong region
/// below it, so it fails the straightness test and is rejected. Open water is
/// trusted more than flat ground, which is only an approximation of the true
/// horizon.
///
/// The fit is made in image space (see `ImageSpace`): y = intercept + slope * x.
nonisolated enum HorizonLineFitter {

    static let openWaterLabels: Set<String> = ["sea", "water (other)"]
    static let flatGroundLabels: Set<String> = ["sand", "grass", "dirt", "gravel", "snow", "playingfield"]

    /// Minimum sky pixels above a boundary (rejects stray sky speckles).
    static let minimumSkyRun = 8
    /// Pixels below the boundary that must belong to the same kind of region.
    static let lookAhead = 6
    static let minimumColumnCoverage = 0.20
    static let minimumSpan = 0.35
    static let maximumResidualRMS = 0.012
    static let inlierTolerance = 0.02

    static func fit(_ grid: SegmentationGrid) -> HorizonLineFit? {
        guard grid.width > 0, grid.height > 0,
              let sky = grid.labels.firstIndex(where: { $0.hasPrefix("sky") }) else { return nil }

        var water = Set<Int>(), ground = Set<Int>()
        for (index, label) in grid.labels.enumerated() {
            if openWaterLabels.contains(label) { water.insert(index) }
            if flatGroundLabels.contains(label) { ground.insert(index) }
        }
        guard !water.isEmpty || !ground.isEmpty else { return nil }
        let lower = water.union(ground)

        let step = max(1, grid.width / 112)
        let columns = stride(from: 0, to: grid.width, by: step).map { $0 }
        var points: [(x: Double, y: Double, label: Int)] = []

        for column in columns {
            var y = 0
            while y < grid.height {
                guard grid.classIndex(atX: column, y: y) == sky else { y += 1; continue }
                let runStart = y
                while y < grid.height && grid.classIndex(atX: column, y: y) == sky { y += 1 }
                guard y - runStart >= minimumSkyRun else { continue }   // speckle: keep scanning
                // The first substantial sky run decides this column.
                guard y < grid.height else { break }
                let below = (y..<min(grid.height, y + lookAhead)).map { grid.classIndex(atX: column, y: $0) }
                if below.count >= lookAhead - 1, below.filter({ lower.contains($0) }).count >= below.count - 1 {
                    let label = below.last { lower.contains($0) } ?? below[0]
                    points.append((x: (Double(column) + 0.5) / Double(grid.width),
                                   y: Double(y) / Double(grid.height), label: label))
                }
                break
            }
        }

        let minimumPoints = max(12, Int(Double(columns.count) * minimumColumnCoverage))
        guard points.count >= minimumPoints else { return nil }

        // Least-squares line with two outlier-rejection passes.
        var inliers = points
        var coefficients = leastSquares(inliers)
        for _ in 0..<2 {
            guard let c = coefficients else { return nil }
            let kept = points.filter { abs($0.y - (c.intercept + c.slope * $0.x)) <= inlierTolerance }
            guard kept.count >= minimumPoints else { return nil }
            inliers = kept
            coefficients = leastSquares(inliers)
        }
        guard let line = coefficients else { return nil }

        let residuals = inliers.map { $0.y - (line.intercept + line.slope * $0.x) }
        let rms = (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()
        let xs = inliers.map(\.x)
        let span = (xs.max() ?? 0) - (xs.min() ?? 0)
        guard rms <= maximumResidualRMS, span >= minimumSpan, abs(line.slope) <= 0.6 else { return nil }

        // Name the region below the sky along the line.
        var labelVotes = [Int: Int]()
        for p in inliers { labelVotes[p.label, default: 0] += 1 }
        let dominantLabel = labelVotes.max { $0.value < $1.value }?.key ?? 0
        let waterShare = Double(inliers.filter { water.contains($0.label) }.count) / Double(inliers.count)

        return HorizonLineFit(
            slope: line.slope, intercept: line.intercept, residualRMS: rms,
            columnCoverage: Double(inliers.count) / Double(columns.count),
            lowerRegionLabel: grid.labels.indices.contains(dominantLabel) ? grid.labels[dominantLabel] : "unknown",
            isOpenWater: waterShare >= 0.7)
    }

    private static func leastSquares(_ points: [(x: Double, y: Double, label: Int)]) -> (slope: Double, intercept: Double)? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        let sx = points.reduce(0) { $0 + $1.x }, sy = points.reduce(0) { $0 + $1.y }
        let sxx = points.reduce(0) { $0 + $1.x * $1.x }, sxy = points.reduce(0) { $0 + $1.x * $1.y }
        let denominator = n * sxx - sx * sx
        guard abs(denominator) > 1e-9 else { return nil }
        let slope = (n * sxy - sx * sy) / denominator
        return (slope, (sy - slope * sx) / n)
    }
}
