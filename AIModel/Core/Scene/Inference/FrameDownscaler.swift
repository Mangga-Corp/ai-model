//
//  FrameDownscaler.swift
//  AIModel
//
//  Created by Laurentius Brandon Vikario on 15/10/26.
//


import Foundation
import CoreImage
import CoreVideo

nonisolated enum FrameDownscaler {
    /// One shared context: creating a CIContext per frame is expensive.
    /// CIContext is thread-safe, so sharing it across queues is fine.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Scales a camera frame so its long edge is `longEdge` and returns an
    /// independent CGImage, so the camera's pixel buffer can be released at once
    /// (holding capture buffers starves the capture pool).
    static func cgImage(from pixelBuffer: CVPixelBuffer, longEdge: CGFloat = 640) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let maxSide = max(image.extent.width, image.extent.height)
        let scale = min(1, longEdge / maxSide)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}