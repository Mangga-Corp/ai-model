import Foundation
import CoreGraphics

/// Maps between the camera FRAME and what the preview actually SHOWS.
///
/// TWO COORDINATE SPACES, deliberately kept apart:
///   - FRAME space: normalised 0...1 over the whole delivered camera buffer, origin top-left,
///     y down. Detection, evaluation, the saved photo and the reference photos all live here.
///   - VIEW space: points inside the preview view.
///
/// The preview uses `.resizeAspectFill`: the frame is scaled UNIFORMLY until it covers the
/// view, centred, and whatever overflows is cropped. When the frame and the view have
/// different aspect ratios a frame-normalised x or y therefore does NOT equal the same
/// view-normalised value, and drawing an overlay by multiplying the two (what the overlays
/// used to do) puts it in the wrong place. Example: a 3:4 frame in a 393 x 646 viewfinder
/// shows about 81% of the frame's width, so frame x = 0.2 lands at view x of about 0.13.
///
/// The SAVED photo is the whole frame, so evaluation stays in frame space. Only drawing
/// converts. Nothing here knows about mirroring: the app only opens the back camera.
nonisolated enum PreviewGeometry {

    /// The rectangle, in view points, that the whole frame occupies when aspect-filled into
    /// `view`. It is at least as large as the view in both dimensions and centred on it, so
    /// it extends beyond the view along the cropped axis.
    ///
    /// Returns the view's own bounds when the frame size is unknown or unusable, which is
    /// the previous behaviour (frame-normalised values scaled straight to the view).
    static func aspectFillRect(frameSize: CGSize?, in view: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: view)
        guard let frameSize,
              frameSize.width.isFinite, frameSize.height.isFinite, frameSize.width > 0, frameSize.height > 0,
              view.width.isFinite, view.height.isFinite, view.width > 0, view.height > 0 else { return bounds }
        let scale = max(view.width / frameSize.width, view.height / frameSize.height)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A frame-normalised point in view points.
    static func viewPoint(fromFrame point: CGPoint, frameSize: CGSize?, in view: CGSize) -> CGPoint {
        let fill = aspectFillRect(frameSize: frameSize, in: view)
        return CGPoint(x: fill.minX + point.x * fill.width, y: fill.minY + point.y * fill.height)
    }

    /// A frame-normalised rectangle in view points.
    static func viewRect(fromFrame rect: CGRect, frameSize: CGSize?, in view: CGSize) -> CGRect {
        let fill = aspectFillRect(frameSize: frameSize, in: view)
        return CGRect(x: fill.minX + rect.minX * fill.width, y: fill.minY + rect.minY * fill.height,
                      width: rect.width * fill.width, height: rect.height * fill.height)
    }

    /// A view point as a frame-normalised point (the inverse of `viewPoint`). May fall
    /// outside 0...1 for points over the black bars, which cannot occur with aspect-FILL.
    static func framePoint(fromView point: CGPoint, frameSize: CGSize?, in view: CGSize) -> CGPoint {
        let fill = aspectFillRect(frameSize: frameSize, in: view)
        guard fill.width > 0, fill.height > 0 else { return .zero }
        return CGPoint(x: (point.x - fill.minX) / fill.width, y: (point.y - fill.minY) / fill.height)
    }

    /// The part of the frame, in frame-normalised coordinates, that is actually visible in
    /// the preview. Anything outside it is in the saved photo but not on screen.
    static func visibleFrameRect(frameSize: CGSize?, in view: CGSize) -> CGRect {
        let fill = aspectFillRect(frameSize: frameSize, in: view)
        guard fill.width > 0, fill.height > 0 else { return ImageSpace.unit }
        let x = max(0, -fill.minX / fill.width), y = max(0, -fill.minY / fill.height)
        return CGRect(x: x, y: y, width: min(1, view.width / fill.width), height: min(1, view.height / fill.height))
    }
}
