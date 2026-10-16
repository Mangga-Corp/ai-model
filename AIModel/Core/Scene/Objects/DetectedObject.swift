//
//  DetectedObject.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//

import Foundation
import CoreGraphics

/// The pixels of one object, stored compactly as a crop around its bounding
/// box (in segmentation-map pixels) rather than a full-frame mask.
///
/// Kept for the future editing feature: "brighten only the car" needs exactly
/// these pixels. Live-camera masks are at model resolution (≈448 px); editing
/// should re-run segmentation on the full-resolution photo.
nonisolated struct ObjectMask: Sendable, Equatable {
    /// Size of the full segmentation map the crop came from.
    let mapWidth: Int
    let mapHeight: Int
    /// Crop origin and size, in map pixels.
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    /// Row-major, `width * height`, true = pixel belongs to the object.
    let bits: [Bool]

    /// Whether a normalised point (0...1, top-left origin) is on the object.
    func contains(normalized point: CGPoint) -> Bool {
        let x = Int(point.x * CGFloat(mapWidth)) - originX
        let y = Int(point.y * CGFloat(mapHeight)) - originY
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bits[y * width + x]
    }

    /// Share of the normalised `rect` covered by the object, 0...1.
    func coverage(of rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX * CGFloat(mapWidth)))
        let x1 = min(mapWidth, Int(rect.maxX * CGFloat(mapWidth)))
        let y0 = max(0, Int(rect.minY * CGFloat(mapHeight)))
        let y1 = min(mapHeight, Int(rect.maxY * CGFloat(mapHeight)))
        guard x1 > x0, y1 > y0 else { return 0 }

        var hits = 0
        for y in y0..<y1 {
            let cy = y - originY
            guard cy >= 0, cy < height else { continue }
            for x in x0..<x1 {
                let cx = x - originX
                if cx >= 0, cx < width, bits[cy * width + cx] { hits += 1 }
            }
        }
        return Double(hits) / Double((x1 - x0) * (y1 - y0))
    }
}

/// One object found in a sampled frame, e.g. a car or a table.
nonisolated struct DetectedObject: Sendable, Equatable, Identifiable {
    /// Unique within one snapshot only. Objects are not tracked across samples.
    let id: Int
    /// The model's original label, e.g. "dining table".
    let label: String
    /// Short UI name, e.g. "Table".
    let displayName: String
    /// Normalised, top-left origin — same space as `subjectBox`.
    let boundingBox: CGRect
    /// Share of the whole frame, 0...1.
    let areaFraction: Double
    /// Normalised centre of mass.
    let centroid: CGPoint
    let mask: ObjectMask

    var isPerson: Bool { ObjectLabel.isPerson(label) }
}
