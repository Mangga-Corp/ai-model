//
//  DepthStatistics.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreGraphics

/// How the subject sits in depth relative to its background.
nonisolated struct DepthStatistics: Sendable, Equatable {
    /// Median nearness (0 far ... 1 near) inside the subject box.
    let subject: Double?
    /// Median nearness outside the box, excluding sky (sky is "infinitely" far
    /// and would make every background look distant).
    let background: Double?

    /// Positive = subject in front of background. Small values mean the subject
    /// is standing against a wall or hedge.
    var separation: Double? {
        guard let subject, let background else { return nil }
        return subject - background
    }

    static func compute(depth: DepthMap,
                        subjectBox: CGRect?,
                        segmentation: SegmentationMap?,
                        stride step: Int = 4) -> DepthStatistics {
        var inside: [Float] = []
        var outside: [Float] = []

        for y in Swift.stride(from: 0, to: depth.height, by: step) {
            for x in Swift.stride(from: 0, to: depth.width, by: step) {
                let p = CGPoint(x: (Double(x) + 0.5) / Double(depth.width),
                                y: (Double(y) + 0.5) / Double(depth.height))
                let v = depth.nearness[y * depth.width + x]
                if let box = subjectBox, box.contains(p) {
                    inside.append(v)
                } else {
                    if let seg = segmentation {
                        let g = seg.group(atNormalized: p)
                        if g == .sky || g == .person { continue }
                    }
                    outside.append(v)
                }
            }
        }
        return DepthStatistics(subject: median(inside), background: median(outside))
    }

    private static func median(_ values: [Float]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return Double(sorted[sorted.count / 2])
    }
}