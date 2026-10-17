import Foundation
import CoreGraphics

// MARK: - Coordinate convention
//
// EVERY geometric value in the preference-analysis feature (boxes, landmarks,
// horizon lines, mask and depth lookups) uses ONE convention:
//
//   - normalised 0...1 on both axes,
//   - origin at the TOP-LEFT of the UPRIGHT image (EXIF orientation applied),
//   - +x to the right, +y downward,
//   - relative to the full image, not to any crop.
//
// Why this is safe for every source:
//   - Stage A renders an upright analysis image (see `PhotoPreparer`) so Vision
//     and Core ML both see pixels in display orientation. No orientation
//     parameter is ever passed downstream.
//   - Vision reports normalised rects/points with a BOTTOM-LEFT origin;
//     `ImageSpace.rect(fromVision...)` / `point(fromVision...)` flip y once, at
//     the boundary.
//   - The Core ML models receive the whole frame stretched to their input size
//     (`scaleFill`, no crop, no letterbox), so a normalised coordinate in the
//     model's output grid maps 1:1 to the same normalised coordinate here. The
//     stretch distorts aspect ratio, which is acceptable for per-region
//     statistics but is recorded as a limitation.
//   - The UI draws the same upright image with aspect-fit, so overlays are a
//     pure scale of these coordinates (`aspectFitRect`).

nonisolated enum ImageSpace {

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    // MARK: Vision boundary

    /// Vision rect (bottom-left origin) -> image space (top-left origin).
    static func rect(fromVisionX x: Double, y: Double, width: Double, height: Double) -> CGRect {
        CGRect(x: x, y: 1 - y - height, width: width, height: height)
    }

    /// Vision point (bottom-left origin) -> image space (top-left origin).
    static func point(fromVisionX x: Double, y: Double) -> CGPoint {
        CGPoint(x: x, y: 1 - y)
    }

    // MARK: Geometry helpers

    /// Clips a rect to the unit square. Returns `.zero` when nothing remains.
    static func clamped(_ rect: CGRect) -> CGRect {
        let clipped = rect.intersection(unit)
        return clipped.isNull ? .zero : clipped
    }

    static func area(_ rect: CGRect) -> Double {
        Double(max(0, rect.width) * max(0, rect.height))
    }

    static func intersectionArea(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        return i.isNull ? 0 : area(i)
    }

    /// Fraction of `inner`'s area that lies inside `outer` (0...1).
    static func containment(of inner: CGRect, in outer: CGRect) -> Double {
        let a = area(inner)
        guard a > 0 else { return 0 }
        return intersectionArea(inner, outer) / a
    }

    /// `rect` grown by `fraction` of its own size on every side, clipped to the image.
    static func expanded(_ rect: CGRect, by fraction: Double) -> CGRect {
        let dx = rect.width * CGFloat(fraction), dy = rect.height * CGFloat(fraction)
        return clamped(rect.insetBy(dx: -dx, dy: -dy))
    }

    /// `rect` shrunk toward its centre to `fraction` of its size per axis.
    static func core(of rect: CGRect, fraction: Double) -> CGRect {
        let w = rect.width * CGFloat(fraction), h = rect.height * CGFloat(fraction)
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Edges of the frame that `rect` touches within `margin`.
    static func touchedEdges(of rect: CGRect, margin: CGFloat = 0.012) -> Set<FrameEdge> {
        var edges = Set<FrameEdge>()
        if rect.minX <= margin { edges.insert(.left) }
        if rect.maxX >= 1 - margin { edges.insert(.right) }
        if rect.minY <= margin { edges.insert(.top) }
        if rect.maxY >= 1 - margin { edges.insert(.bottom) }
        return edges
    }

    // MARK: Aspect-fit display mapping

    /// Where an image of `content` size lands when aspect-fitted and centred in
    /// `container`. Overlays are drawn relative to this rect.
    static func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func viewPoint(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        CGPoint(x: fitted.minX + point.x * fitted.width, y: fitted.minY + point.y * fitted.height)
    }

    static func viewRect(_ rect: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + rect.minX * fitted.width,
               y: fitted.minY + rect.minY * fitted.height,
               width: rect.width * fitted.width,
               height: rect.height * fitted.height)
    }
}

/// A side of the image frame.
nonisolated enum FrameEdge: String, Sendable, CaseIterable, Hashable {
    case left, right, top, bottom
}
