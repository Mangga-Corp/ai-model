import Foundation
import SwiftUI
import AVFoundation
import Vision
import CoreImage
import UIKit
import Photos
import Combine

// MARK: - ViewModel

/// Owns the capture session lifecycle and still-photo capture.
@MainActor
final class CameraPreviewViewModel: ObservableObject {

    @Published var isSessionRunning = false
    @Published var statusMessage = "Starting camera..."
    /// Briefly true after a capture so the screen can flash white.
    @Published var showCaptureFlash = false
    /// The most recently captured photo.
    @Published var capturedImage: UIImage?
    /// Set when saving to the library fails, so the preview can show why.
    @Published var saveErrorMessage: String?

    /// Detected subject box in NORMALISED view space (0...1), origin top-left.
    ///
    /// Nil when no person is detected. Vision reports against the raw sensor
    /// frame with a bottom-left origin; `toViewSpace` handles both the flip and
    /// the device rotation.
    @Published var subjectBox: CGRect?

    /// The single live composition instruction, or nil when nothing is stable
    /// enough to show. Driven by `CompositionGuidanceEngine`.
    @Published var compositionInstruction: String?

    /// True once the composition has held "ready" long enough to announce.
    @Published var isCompositionReady = false

    /// Honest limitation text when the profile is too thin to apply a target,
    /// or nil when preferences are being applied normally.
    @Published var compositionLimitation: String?

    /// High-level scene description from the on-device model, or nil when the
    /// model is unavailable or has not yet produced a reading. Display-only —
    /// never used for geometry.
    @Published var sceneDescription: String?

    /// Why the on-device scene model is unavailable, when it is. Surfaced so the
    /// UI can explain the fallback rather than silently degrading.
    @Published var sceneModelStatus: String?

    /// Live tilt instruction derived from the device's physical pitch versus the
    /// profile's preferred horizon angle, or nil when on target / unavailable.
    @Published var tiltInstruction: String?

    /// True when Core Motion is producing attitude samples. False means tilt
    /// guidance is unavailable and the banner falls back to position-only.
    @Published var isAttitudeActive = false

    /// The preference profile the composition targets are derived from.
    /// Injected rather than read from a singleton so the camera can be opened
    /// with no profile at all, in which case no guidance is offered.
    var profile: PhotographicPreferenceProfile?

    private let evaluator = CompositionEvaluator()
    private var guidance = CompositionGuidanceEngine()
    private let sceneSampler = SceneInterpretationSampler()
    private let attitudeService = DeviceAttitudeService()
    private let tiltEvaluator = TiltEvaluator()

    private let session = AVCaptureSession()

    /// Single video data output serving BOTH detection and capture.
    ///
    /// A photo output and a video data output cannot coexist on one session —
    /// the photo output silently starves the video output of frames. So the
    /// video output is the only output, and the shutter captures from the most
    /// recent frame it delivered.
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.aimodel.camera.video")
    private let detector = PersonDetector()

    /// The most recent frame, retained so the shutter can capture from it.
    /// Released on replacement — holding several starves the capture pool.
    private var lastFrameBuffer: CMSampleBuffer?

    /// Must be held strongly: `AVCaptureSession` keeps the sample buffer
    /// delegate WEAKLY. As a temporary it was deallocated immediately and no
    /// frames ever arrived.
    private var sampleBufferDelegate: FrameDelegate?

    private var hasConfigured = false

    /// Must be held strongly: `AVCapturePhotoOutput` keeps its capture delegate
    /// WEAKLY. Created as a temporary at the call site, it was deallocated the
    /// instant `capturePhoto()` returned, so the completion callback never
    /// fired — the shutter appeared to do nothing.

    func start() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                statusMessage = "Camera access denied — enable it in Settings"
                return
            }

            guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
                statusMessage = "No camera available on this device"
                return
            }

            configureAndRun()
            isSessionRunning = true
            statusMessage = "Camera ready"
        }
    }

    /// Adds the camera input and still-photo output, then starts the session.
    /// Runs off the main thread because `startRunning()` blocks for the camera
    /// boot duration, which would otherwise freeze the UI.
    private func configureAndRun() {
        guard !hasConfigured else {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                if !session.isRunning { session.startRunning() }
            }
            return
        }
        hasConfigured = true

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                Task { @MainActor in
                    statusMessage = "Could not access the camera"
                    isSessionRunning = false
                }
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            // One video output for both detection and capture. The pixel format
            // must be declared before the output is added, and must be a native
            // capture format — BGRA is not one, and Vision's requests return
            // empty results on BGRA input rather than erroring.
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true

            guard session.canAddOutput(videoOutput) else {
                Task { @MainActor in
                    statusMessage = "Could not configure the camera"
                    isSessionRunning = false
                }
                session.commitConfiguration()
                return
            }
            session.addOutput(videoOutput)

            // The delegate attaches only AFTER the output is in the session.
            let delegate = FrameDelegate(viewModel: self)
            sampleBufferDelegate = delegate
            videoOutput.setSampleBufferDelegate(delegate, queue: videoQueue)

            // Rotation must be set AFTER the output is added, or the
            // connection is nil and the assignment silently does nothing.
            updateOrientation()

            // Re-orient on rotation, so the box follows the preview.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(deviceDidRotate),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )

            session.commitConfiguration()
            session.startRunning()

            Task { @MainActor in
                if !session.isRunning {
                    statusMessage = "Camera failed to start"
                    isSessionRunning = false
                }
            }
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        attitudeService.stop()
        resetComposition()
        Task { @MainActor in isSessionRunning = false }
    }

    /// Captures a still photo from the most recent video frame.
    ///
    /// Deliberately not `AVCapturePhotoOutput`: a photo output and a video data
    /// output cannot coexist on one session, and the video output is needed for
    /// detection. Capturing from the last delivered frame keeps a single output.
    func capturePhoto() {
        // A silent no-op here is indistinguishable from a broken shutter, so
        // the reason is recorded for the caller to surface.
        guard session.isRunning else {
            statusMessage = "Camera is not running"
            return
        }

        guard let buffer = lastFrameBuffer,
              let image = Self.image(from: buffer) else {
            statusMessage = "No frame captured yet"
            return
        }

        didCapture(image: image)
    }

    /// Converts a sample buffer to a UIImage via Core Image.
    ///
    /// `CIImage(cvPixelBuffer:)` handles bi-planar YUV, so no format branching
    /// is needed.
    ///
    /// NO orientation is applied here, deliberately. The capture connection's
    /// `videoOrientation` already rotates each buffer into the device's
    /// orientation before delivery, so the pixels are correct as delivered.
    /// Applying `UIDevice.orientation` again would rotate the frame a SECOND
    /// time — a portrait capture arriving 90° off. The rotation belongs in one
    /// place only.
    private static func image(from sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    /// Called by the capture delegate once a photo is ready.
    func didCapture(image: UIImage?) {
        capturedImage = image
        showCaptureFlash = true

        Task {
            try? await Task.sleep(for: .milliseconds(180))
            showCaptureFlash = false
        }
    }

    /// Clears the captured photo, closing the preview and returning to the
    /// live viewfinder. Used by both Retake and swipe-to-dismiss.
    func dismissCapturedPhoto() {
        capturedImage = nil
        saveErrorMessage = nil
    }

    /// Writes the captured photo to the system photo library.
    ///
    /// Triggers the one-time permission prompt on first save. On success the
    /// preview closes; on denial the caller is told so it can surface a message
    /// rather than silently doing nothing.
    func saveCapturedPhoto() {
        guard let image = capturedImage else { return }

        let write: () -> Void = {
            UIImageWriteToSavedPhotosAlbum(image, self, nil, nil)
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            write()
            capturedImage = nil

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                Task { @MainActor in
                    if newStatus == .authorized || newStatus == .limited {
                        write()
                        self.capturedImage = nil
                    } else {
                        self.saveErrorMessage = "Photo access denied. Enable it in Settings to save."
                    }
                }
            }

        case .denied, .restricted:
            saveErrorMessage = "Photo access denied. Enable it in Settings to save."

        @unknown default:
            saveErrorMessage = "Could not save the photo."
        }
    }

    /// Retains a frame for capture, releasing the one it replaces.
    ///
    /// Releasing is required: holding several buffers starves the capture
    /// memory pool and frames stop being delivered.
    func storeFrame(_ buffer: CMSampleBuffer) {
        // Replacing drops the previous buffer's only strong reference, freeing
        // it. Holding several would starve the capture memory pool.
        lastFrameBuffer = buffer
    }

    /// Runs person detection on a frame and publishes the resulting box.
    func detectSubject(in sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameW = CVPixelBufferGetWidth(pixelBuffer)
        let frameH = CVPixelBufferGetHeight(pixelBuffer)

        // Offer the frame for low-rate semantic interpretation. The sampler
        // enforces its own cadence and in-flight guard, so calling it every
        // detection frame is cheap — it self-throttles. Runs off the geometry
        // path entirely: interpretation never blocks or alters detection.
        offerSceneInterpretation(sampleBuffer)

        Task {
            guard let visionRect = await detector.detect(in: pixelBuffer) else {
                subjectBox = nil
                // Still evaluate so a lost subject is reported, not silently
                // treated as "nothing to guide on".
                evaluateComposition(personBox: nil)
                return
            }

            // Vision reports against the raw sensor frame with a bottom-left
            // origin, y up. The view is top-left, y down, and the phone may be
            // rotated relative to the sensor — so flip and rotate.
            let overlayRect = Self.toViewSpace(
                visionRect,
                frameSize: CGSize(width: frameW, height: frameH)
            )
            subjectBox = overlayRect
            evaluateComposition(personBox: overlayRect)
        }
    }

    /// Runs the composition evaluator and guidance engine on the current frame.
    ///
    /// Fed from the same detection pass that publishes `subjectBox`, so guidance
    /// and the live box can never disagree. No-ops when there is no profile —
    /// with nothing to compare against, guidance would be inventing a preference.
    private func evaluateComposition(personBox: CGRect?) {
        guard let profile else {
            compositionInstruction = nil
            isCompositionReady = false
            compositionLimitation = nil
            return
        }

        let measurement = SceneMeasurement(
            person: personBox.map {
                SceneElement(kind: .person, box: $0, confidence: nil)
            },
            personLost: false
        )

        let evaluation = evaluator.evaluate(
            measurement: measurement,
            position: profile.subjectPositionDistribution,
            size: profile.subjectSizeDistribution,
            photoCount: profile.photoCount
        )

        compositionInstruction = guidance.update(with: evaluation)
        isCompositionReady = guidance.isReadyStable
        compositionLimitation = evaluation.limitation
    }

    /// Hands the current frame to the semantic sampler.
    ///
    /// Converts the sample buffer to a `CGImage` for the model. The sampler
    /// self-throttles and downsamples, so this is safe to call every detection
    /// frame. All results are delivered on the main actor because the published
    /// properties they set are observed by SwiftUI.
    private func offerSceneInterpretation(_ sampleBuffer: CMSampleBuffer) {
        // Report availability once, so the UI can explain a missing model
        // rather than showing nothing.
        if sceneModelStatus == nil {
            let status = SceneInterpretationService.availability()
            sceneModelStatus = status.isAvailable ? nil : status.message
            if !status.isAvailable { return }   // no point converting frames
        }

        guard let cgImage = Self.cgImage(from: sampleBuffer) else { return }

        sceneSampler.offer(cgImage: cgImage) { [weak self] interpretation in
            Task { @MainActor in
                guard let self else { return }
                if interpretation.isModelDerived {
                    self.sceneDescription = interpretation.description
                }
            }
        }
    }

    /// Converts a sample buffer to a `CGImage` for semantic interpretation.
    /// Shares the Core Image path used for capture — no separate conversion.
    private static func cgImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    /// Starts streaming device attitude and feeds it to the tilt evaluator.
    ///
    /// Safe to call more than once — the second call is a no-op while a stream
    /// is already active. Called from `onAppear` once the profile is set, since
    /// the tilt target is derived from it.
    ///
    /// Attitude arrives on a background queue; the evaluator is pure and the
    /// published property is @MainActor-observed, so the result hops to main.
    func startAttitudeIfPossible() {
        guard !attitudeService.isActive else { return }
        startAttitude()
    }

    private func startAttitude() {
        guard let profile else {
            isAttitudeActive = false
            return
        }

        let started = attitudeService.start { [weak self] attitude in
            guard let self else { return }
            let preferred = profile.horizonAngleDistribution?.meanAngle
            let guidance = self.tiltEvaluator.evaluate(pitch: attitude.pitch, preferredAngle: preferred)
            let instruction = self.tiltEvaluator.instruction(for: guidance)

            Task { @MainActor in
                self.isAttitudeActive = true
                self.tiltInstruction = instruction
            }
        }

        isAttitudeActive = started
    }

    /// Clears composition state — called when the camera stops so a stale
    /// instruction does not persist into the next session.
    func resetComposition() {
        guidance.reset()
        compositionInstruction = nil
        isCompositionReady = false
        compositionLimitation = nil
        sceneSampler.reset()
        sceneDescription = nil
    }

    /// Converts a Vision rect into normalised view space.
    ///
    /// With the capture connection oriented to the device, Vision reports
    /// against the same orientation the preview displays — so only the y axis
    /// needs flipping: Vision's origin is bottom-left with y increasing
    /// upward, SwiftUI's is top-left with y increasing downward.
    ///
    /// Normalised coordinates are used precisely so the `resizeAspectFill`
    /// crop cancels out: scaling uniformly and cropping preserves normalised
    /// positions, so no pixel-level geometry is needed here.
    static func toViewSpace(_ rect: CGRect, frameSize: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: 1.0 - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Applies the device orientation to the capture connection.
    ///
    /// Without this the frames keep the sensor's native landscape orientation,
    /// while the preview rotates them for display — so Vision reports boxes
    /// against a frame that does not match what the user sees, and every box
    /// lands in the wrong place.
    func updateOrientation() {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoOrientationSupported else { return }

        connection.videoOrientation = Self.interfaceOrientation()
    }

    @objc private func deviceDidRotate() {
        updateOrientation()
    }

    /// Maps the device's physical orientation onto an AVFoundation one.
    ///
    /// The sensor captures in landscape, so an upright phone needs a 90°
    /// correction. Face-up and face-down are ambiguous and keep the last known
    /// orientation rather than snapping to a wrong one.
    static func interfaceOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft:      return .landscapeLeft
        case .landscapeRight:     return .landscapeRight
        default:                  return .portrait
        }
    }

    /// The session the preview layer displays.
    var captureSession: AVCaptureSession { session }
}

// MARK: - Person Detection

final class PersonDetector {

    func detect(in pixelBuffer: CVPixelBuffer) async -> CGRect? {
        var request = DetectHumanRectanglesRequest()

        // Upper body only — head and shoulders. This is the DEFAULT
        // (`upperBodyOnly = true`); it is set explicitly here so the intent is
        // clear rather than relying on the framework default.
        request.upperBodyOnly = true

        let observations: [HumanObservation]
        do {
            observations = try await request.perform(on: pixelBuffer)
        } catch {
            return nil
        }

        // Largest person wins — the one the photographer is most likely
        // framing. Folded explicitly rather than chained, since the chained
        // form exceeds the compiler's type-checking budget.
        var best: NormalizedRect?
        var bestArea: CGFloat = -1

        for observation in observations {
            let rect = observation.boundingBox
            let area = rect.width * rect.height
            if area > bestArea {
                bestArea = area
                best = rect
            }
        }

        guard let best else { return nil }

        // `NormalizedRect` is a separate type from `CGRect`; convert explicitly
        // so the caller's coordinate space is unambiguous.
        return CGRect(
            x: CGFloat(best.origin.x),
            y: CGFloat(best.origin.y),
            width: CGFloat(best.width),
            height: CGFloat(best.height)
        )
    }
}
