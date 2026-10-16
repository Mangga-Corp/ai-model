//
//  ObjectExtractor.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 16/10/26.
//


import Foundation
import CoreGraphics

/// Splits a semantic segmentation map into individual objects.
///
/// DETR's semantic output labels every pixel ("car") but does not say which
/// car. Connected pixels of the same label are treated as one object, so two
/// separate cars become two objects. Limitation: two cars that touch in the
/// image merge into one. Pure and deterministic, so it is unit-tested without
/// a model.
nonisolated struct ObjectExtractor: Sendable {

    /// Blobs smaller than this share of the frame are noise, not objects.
    /// 0.2% of a 448×448 map ≈ 400 pixels.
    var minimumAreaFraction = 0.002
    /// Largest objects kept, to bound work and UI clutter.
    var maximumObjects = 20

    func extract(from map: SegmentationMap) -> [DetectedObject] {
        guard map.hasLabels else { return [] }

        let isObjectClass = map.labels.map(ObjectLabel.isObject)
        let total = map.width * map.height
        let minimumPixels = max(1, Int(Double(total) * minimumAreaFraction))

        var visited = [Bool](repeating: false, count: total)
        var stack: [Int] = []
        var blobs: [(classIndex: Int32, pixels: [Int])] = []

        for start in 0..<total {
            guard !visited[start] else { continue }
            let cls = map.classIndices[start]
            let c = Int(cls)
            guard isObjectClass.indices.contains(c), isObjectClass[c] else {
                visited[start] = true
                continue
            }

            // Iterative flood fill (4-connected). Recursion would overflow the
            // stack on large objects.
            var pixels: [Int] = []
            visited[start] = true
            stack.append(start)
            while let p = stack.popLast() {
                pixels.append(p)
                let x = p % map.width
                let y = p / map.width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < map.width, ny < map.height else { continue }
                    let n = ny * map.width + nx
                    if !visited[n] && map.classIndices[n] == cls {
                        visited[n] = true
                        stack.append(n)
                    }
                }
            }
            if pixels.count >= minimumPixels { blobs.append((cls, pixels)) }
        }

        return blobs
            .sorted { $0.pixels.count > $1.pixels.count }
            .prefix(maximumObjects)
            .enumerated()
            .map { index, blob in makeObject(id: index, blob: blob, map: map) }
    }

    private func makeObject(id: Int,
                            blob: (classIndex: Int32, pixels: [Int]),
                            map: SegmentationMap) -> DetectedObject {
        var minX = map.width, minY = map.height, maxX = 0, maxY = 0
        var sumX = 0.0, sumY = 0.0
        for p in blob.pixels {
            let x = p % map.width, y = p / map.width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            sumX += Double(x); sumY += Double(y)
        }

        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        var bits = [Bool](repeating: false, count: cropWidth * cropHeight)
        for p in blob.pixels {
            let x = p % map.width - minX, y = p / map.width - minY
            bits[y * cropWidth + x] = true
        }

        let w = Double(map.width), h = Double(map.height)
        let n = Double(blob.pixels.count)
        let label = map.labels[Int(blob.classIndex)]

        return DetectedObject(
            id: id,
            label: label,
            displayName: ObjectLabel.displayName(for: label),
            boundingBox: CGRect(x: Double(minX) / w, y: Double(minY) / h,
                                width: Double(cropWidth) / w, height: Double(cropHeight) / h),
            areaFraction: n / (w * h),
            centroid: CGPoint(x: (sumX / n + 0.5) / w, y: (sumY / n + 0.5) / h),
            mask: ObjectMask(mapWidth: map.width, mapHeight: map.height,
                             originX: minX, originY: minY,
                             width: cropWidth, height: cropHeight, bits: bits)
        )
    }
}
