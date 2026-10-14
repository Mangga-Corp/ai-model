import Foundation
import CoreGraphics
import UIKit

/// Samples camera frames for semantic interpretation at a controlled, low rate.
///
/// WHY A SAMPLER: Foundation Models inference is expensive relative to the ~7fps
/// detection loop. Running it every frame would stall the preview and drain the
/// battery for interpretation that barely changes second to second. This
/// enforces a minimum interval, downsamples the frame (images spend from the
/// model's token budget), and drops a new sample while one is still in flight so
/// inference never queues up.
///
/// Fully decoupled from the camera: it is handed `CGImage`s and calls back with
/// a `SceneInterpretation`, so it is testable without a device.
final class SceneInterpretationSampler {

    /// Minimum seconds between accepted samples. ~2.5s keeps semantic context
    /// fresh enough to matter without running the model continuously.
    var interval: TimeInterval = 2.5

    /// Long edge, in pixels, of the downsampled frame handed to the model.
    /// Small on purpose — the image consumes the model's token budget, and scene
    /// interpretation does not need detail.
    var sampleLongEdge: Int = 512

    private let service: SceneInterpretationService
    private var lastSample = Date.distantPast
    private var inFlight = false

    /// The most recent interpretation, or nil until the first completes.
    private(set) var latest: SceneInterpretation?

    init(service: SceneInterpretationService = SceneInterpretationService()) {
        self.service = service
    }

    /// Offers a frame for interpretation. Returns immediately; work happens
    /// asynchronously and the result is delivered via `onUpdate`.
    ///
    /// Silently ignores the frame when the interval has not elapsed or a
    /// previous sample is still running — dropping stale frames is the point.
    func offer(cgImage: CGImage, onUpdate: @escaping (SceneInterpretation) -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= interval, !inFlight else { return }

        // Downsample before spending the model's budget on a full frame.
        guard let small = Self.downsample(cgImage, longEdge: sampleLongEdge) else { return }

        lastSample = now
        inFlight = true

        Task {
            let result = await service.interpret(cgImage: small)
            self.inFlight = false
            self.latest = result
            onUpdate(result)
        }
    }

    /// Resets cadence state — call when the camera restarts so the first frame
    /// of a new session is sampled immediately rather than waiting out the
    /// interval.
    func reset() {
        lastSample = Date.distantPast
        inFlight = false
        latest = nil
    }

    /// Scales an image so its long edge does not exceed `longEdge`.
    ///
    /// Uses `UIGraphicsImageRenderer`, matching the existing downsampler in
    /// `PhotoSelectionService` for consistency across the codebase.
    static func downsample(_ image: CGImage, longEdge: Int) -> CGImage? {
        let maxDim = max(image.width, image.height)
        guard maxDim > longEdge else { return image }

        let scale = CGFloat(longEdge) / CGFloat(maxDim)
        let target = CGSize(
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            UIImage(cgImage: image, scale: 1.0, orientation: .up)
                .draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}
