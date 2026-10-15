//
//  Skyline.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation

/// The boundary where sky meets whatever is below it.
nonisolated struct Skyline: Sendable, Equatable {
    /// Median boundary height, normalised 0 (top) ... 1 (bottom).
    let y: Double
    /// Slope of the boundary in degrees. Positive = right side lower.
    let angleDegrees: Double
    /// What most columns have directly below the sky (e.g. `.water` for a sea horizon).
    let groupBelow: SceneLabelGroup
}

nonisolated struct SegmentationStatistics: Sendable, Equatable {
    /// Share of each group among NON-person pixels, summing to ~1.
    let backgroundFractions: [SceneLabelGroup: Double]
    let skyline: Skyline?
    /// Share of the TOP pixel row covered by each group. A high `.mountain` or
    /// `.structure` value means the peak or building is cut off by the frame.
    let topEdgeCoverage: [SceneLabelGroup: Double]

    func fraction(_ group: SceneLabelGroup) -> Double { backgroundFractions[group] ?? 0 }
    func fraction(_ groups: SceneLabelGroup...) -> Double { groups.reduce(0) { $0 + fraction($1) } }

    // MARK: - Compute

    /// - Parameters:
    ///   - stride: Sample every Nth pixel. 448² / 4² ≈ 12.5k samples is plenty.
    ///   - minimumSkylineColumns: Fraction of sampled columns that must show a
    ///     sky→ground boundary before a skyline is reported.
    static func compute(from map: SegmentationMap,
                        stride step: Int = 4,
                        minimumSkylineColumns: Double = 0.3) -> SegmentationStatistics {
        // Background fractions
        var counts: [SceneLabelGroup: Int] = [:]
        var total = 0
        for y in Swift.stride(from: 0, to: map.height, by: step) {
            for x in Swift.stride(from: 0, to: map.width, by: step) {
                let g = map[x, y]
                guard g != .person else { continue }
                counts[g, default: 0] += 1
                total += 1
            }
        }
        let fractions = total == 0 ? [:] : counts.mapValues { Double($0) / Double(total) }

        // Top-edge coverage
        var topCounts: [SceneLabelGroup: Int] = [:]
        var topTotal = 0
        for x in Swift.stride(from: 0, to: map.width, by: step) {
            topCounts[map[x, 0], default: 0] += 1
            topTotal += 1
        }
        let topCoverage = topCounts.mapValues { Double($0) / Double(max(topTotal, 1)) }

        return SegmentationStatistics(
            backgroundFractions: fractions,
            skyline: skyline(in: map, stride: step, minimumColumns: minimumSkylineColumns),
            topEdgeCoverage: topCoverage
        )
    }

    /// For each sampled column, walks down from the top while the pixel is sky.
    /// The first non-sky pixel is a boundary point, kept only if it is real
    /// ground (not a person occluding the horizon, not `.other`).
    private static func skyline(in map: SegmentationMap, stride step: Int,
                                minimumColumns: Double) -> Skyline? {
        var points: [(x: Double, y: Double)] = []
        var below: [SceneLabelGroup: Int] = [:]
        var sampledColumns = 0
        let minSkyRun = max(1, map.height / 50)

        for x in Swift.stride(from: 0, to: map.width, by: step) {
            sampledColumns += 1
            guard map[x, 0] == .sky else { continue }
            var y = 0
            while y < map.height && map[x, y] == .sky { y += 1 }
            guard y >= minSkyRun, y < map.height else { continue }
            let g = map[x, y]
            guard g != .person, g != .other else { continue }
            points.append((Double(x), Double(y)))
            below[g, default: 0] += 1
        }

        guard sampledColumns > 0,
              Double(points.count) / Double(sampledColumns) >= minimumColumns,
              let groupBelow = below.max(by: { $0.value < $1.value })?.key
        else { return nil }

        let ys = points.map { $0.y }.sorted()
        let medianY = ys[ys.count / 2] / Double(map.height)

        // Least-squares slope in pixel units → degrees.
        let n = Double(points.count)
        let meanX = points.map { $0.x }.reduce(0, +) / n
        let meanY = points.map { $0.y }.reduce(0, +) / n
        let sxx = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        let sxy = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let slope = sxx > 0 ? sxy / sxx : 0
        let angle = atan(slope) * 180 / .pi

        return Skyline(y: medianY, angleDegrees: angle, groupBelow: groupBelow)
    }
}