//
//  DepthMap.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreGraphics

/// Relative depth, normalised so 1 = nearest pixel in the frame, 0 = farthest.
/// Relative only: values are NOT metres and are not comparable across frames.
nonisolated struct DepthMap: Sendable, Equatable {
    let width: Int
    let height: Int
    let nearness: [Float]

    init(width: Int, height: Int, nearness: [Float]) {
        precondition(width > 0 && height > 0 && nearness.count == width * height,
                     "DepthMap size mismatch")
        self.width = width
        self.height = height
        self.nearness = nearness
    }

    /// Min-max normalises raw model output. `largerIsNearer` must match the
    /// model (Depth Anything outputs inverse depth: larger = nearer. ⚠️ verify).
    static func normalised(width: Int, height: Int, raw: [Float], largerIsNearer: Bool) -> DepthMap {
        guard let lo = raw.min(), let hi = raw.max(), hi > lo else {
            return DepthMap(width: width, height: height, nearness: Array(repeating: 0, count: raw.count))
        }
        let range = hi - lo
        let values = raw.map { v -> Float in
            let n = (v - lo) / range
            return largerIsNearer ? n : 1 - n
        }
        return DepthMap(width: width, height: height, nearness: values)
    }

    func value(atNormalized point: CGPoint) -> Float {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        return nearness[y * width + x]
    }
}