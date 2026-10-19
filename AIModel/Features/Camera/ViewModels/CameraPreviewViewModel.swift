import Foundation
import SwiftUI
import AVFoundation
import Vision
import CoreImage
import UIKit
import Photos
import Combine

// MARK: - ViewModel

/// Owns the capture session, live guidance and still-photo capture.
///
/// Three guidance sources feed one screen:
/// - **Composition** (every detection frame): subject position and size versus
///   the user's profile, via `CompositionEvaluator` + `CompositionGuidanceEngine`.
/// - **Scene** (about once a second): where the user is shooting (beach,
///   mountain, city…) and best-practice fixes for that place, via
///   `SceneUnderstandingSampler` + `SceneRulebook`.
/// - **Objects** (same scene sample, no extra model): individual cars, tables,
///   people… with labels and masks, and object-based advice via `ObjectRulebook`.
/// - **Tilt** (Core Motion): device pitch versus the profile's horizon angle.
///
/// It also steers the lens: once a subject is detected, focus and exposure
/// follow the subject's face area (`SubjectFocusTracker` +
/// `SubjectFocusController`), like tapping the subject in the stock Camera app.
///
/// `RecommendationEngine` decides whether the composition or the scene advice
/// owns the single instruction banner, so the screen never shows two
/// contradictory instructions.
@MainActor
final class CameraPreviewViewModel: ObservableObject {

    // MARK: - Published state: session & capture

    @Published private(set) var isSessionRunning = false
    @Published private(set) var statusMessage = "Starting camera..."
    /// Briefly true after a capture so the screen can flash white.
    @Published private(set) var showCaptureFlash = false
    /// The most recently captured photo.
    @Published private(set) var capturedImage: UIImage?
    /// The AI-enhanced version of `capturedImage`, once `PhotoEnhancer` has
    /// finished. Nil while enhancing, or if the enhance failed.
    @Published private(set) var enhancedImage: UIImage?
    /// True while the captured photo is being enhanced.
    @Published private(set) var isEnhancing = false
    /// Set when saving to the library fails, so the preview can show why.
    @Published private(set) var saveErrorMessage: String?

    // MARK: - Published state: guidance

    /// Detected subject box in NORMALISED view space (0...1), origin top-left.
    ///
    /// Nil when no person is detected. Vision reports against the raw sensor
    /// frame with a bottom-left origin; `toViewSpace` handles the flip.
    @Published private(set) var subjectBox: CGRect?

    /// The single live instruction (composition or scene), or nil when nothing
    /// is stable enough to show.
    @Published private(set) var compositionInstruction: String?

    /// A short "why" under the instruction, or what "ready" was based on. Nil when there is
    /// nothing accurate to add.
    @Published private(set) var compositionDetail: String?

    /// True once the composition has held "ready" long enough to announce AND
    /// no scene fix is pending.
    @Published private(set) var isCompositionReady = false

    /// Plain-language reason no saved preference could be compared with the live view, shown
    /// only when there is no instruction to show. Nil when preferences are being applied, or
    /// when the situation needs no explanation.
    @Published private(set) var compositionLimitation: String?

    /// Pixel size of the camera frame the overlays are expressed in. The preview aspect-fills
    /// it, so overlays are placed through `PreviewGeometry` rather than scaled to the view.
    @Published private(set) var frameSize: CGSize?

    /// Where the dashed guide is drawn (frame space), or nil when there is no target to show.
    @Published private(set) var guideTarget: LiveGuideTarget?

    /// Live tilt instruction derived from the device's physical pitch versus the
    /// profile's preferred horizon angle, or nil when on target / unavailable.
    @Published private(set) var tiltInstruction: String?

    /// True when Core Motion is producing attitude samples. False means tilt
    /// guidance is unavailable and the banner falls back to position-only.
    @Published private(set) var isAttitudeActive = false

    // MARK: - Published state: focus

    /// Where focus is locked on the subject, in NORMALISED view space (0...1),
    /// origin top-left. Nil when no subject is tracked (normal autofocus) or the
    /// lens cannot focus on a point, so the indicator never claims a focus
    /// that is not happening.
    @Published private(set) var focusPoint: CGPoint?

    /// Increments on every new focus command so the indicator can pulse.
    @Published private(set) var focusPulseID = 0

    // MARK: - Published state: scene

    /// The stabilised scene, or nil while unknown or when scene detection is
    /// unavailable. The view maps it to a label and an icon.
    @Published private(set) var sceneCategory: SceneCategory?

    /// Why scene detection is unavailable, when it is (e.g. models missing from
    /// the bundle). Surfaced so the UI can explain the fallback rather than
    /// silently degrading.
    @Published private(set) var sceneModelStatus: String?

    /// Objects to label on screen (largest first, people excluded because the
    /// subject has its own box). Each carries a mask for the future editor.
    @Published private(set) var detectedObjects: [DetectedObject] = []

    /// At most this many object labels are drawn, to keep the viewfinder readable.
    private let maximumLabelledObjects = 6
    /// Objects smaller than this share of the frame are not labelled.
    private let minimumLabelledArea = 0.01

    // MARK: - Inputs

    /// The preference profile the composition targets are derived from.
    /// Injected rather than read from a singleton so the camera can be opened
    /// with no profile at all, in which case no guidance is offered.
    var profile: PhotographicPreferenceProfile? {
        didSet { refreshGuideTarget() }
    }

    // MARK: - Guidance engines

    private let evaluator = CompositionEvaluator()
    private var guidance = CompositionGuidanceEngine()
    /// Keeps guidance on the same person from pass to pass.
    private var subjectTracker = LiveSubjectTracker()
    /// Mismatches flagged on the previous pass, for spatial hysteresis.
    private var latchedMismatches: ActiveMismatches = []
    private let attitudeService = DeviceAttitudeService()
    private let tiltEvaluator = TiltEvaluator()

    // MARK: - Focus

    private var focusTracker = SubjectFocusTracker()
    /// Created once the camera device is known (in `configureAndRun`).
    private var focusController: SubjectFocusController?

    // MARK: - Scene understanding

    private let sceneUnderstanding: SceneUnderstandingSampler
    private let sceneRulebook = SceneRulebook()
    private let objectRulebook = ObjectRulebook()
    private let recommendationEngine = RecommendationEngine()
    private var sceneRecommendationFilter = StableValueFilter<Recommendation>()

    private enum SceneModelState { case idle, loading, ready, unavailable }
    private var sceneModelState = SceneModelState.idle

    // MARK: - Capture session

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

    /// One Core Image context for every capture. Creating a context per frame
    /// is expensive and was the old behaviour.
    private static let ciContext = CIContext()

    /// Runs the automatic enhance on each capture.
    private let enhancer = PhotoEnhancer()
    private var enhanceTask: Task<Void, Never>?

    // MARK: - Init

    /// The sampler is optional and created INSIDE the body: default argument
    /// expressions are evaluated in a nonisolated context, so a main-actor
    /// initializer cannot be called there.
    init(sceneUnderstanding: SceneUnderstandingSampler? = nil) {
        self.sceneUnderstanding = sceneUnderstanding ?? SceneUnderstandingSampler()
    }

    // MARK: - Lifecycle

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

        prepareSceneUnderstandingIfNeeded()
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        attitudeService.stop()
        resetComposition()
        resetFocus()
        isSessionRunning = false
    }

    /// Loads the scene models once per view model. `start()` runs on every
    /// `onAppear`, so without the state check the models would reload each
    /// time the camera screen reappears.
    ///
    /// Failure is a graceful fallback: position guidance keeps working, only
    /// the scene badge and scene advice are missing.
    private func prepareSceneUnderstandingIfNeeded() {
        guard sceneModelState == .idle else { return }
        sceneModelState = .loading

        Task {
            do {
                try await sceneUnderstanding.prepare()
                sceneModelState = .ready
                sceneModelStatus = nil
            } catch {
                sceneModelState = .unavailable
                sceneModelStatus = "Scene detection is unavailable on this device."
            }
        }
    }

    /// Adds the camera input and video output, then starts the session.
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

            let controller = SubjectFocusController(device: device)
            Task { @MainActor in
                focusController = controller
            }

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

    // MARK: - Capture

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
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    /// Shows the captured photo and flashes the screen.
    func didCapture(image: UIImage?) {
        capturedImage = image
        startEnhancing(image)
        showCaptureFlash = true

        Task {
            try? await Task.sleep(for: .milliseconds(180))
            showCaptureFlash = false
        }
    }

    /// Clears the captured photo, closing the preview and returning to the
    /// live viewfinder. Used by both Retake and swipe-to-dismiss.
    func dismissCapturedPhoto() {
        enhanceTask?.cancel()
        enhanceTask = nil
        capturedImage = nil
        enhancedImage = nil
        isEnhancing = false
        saveErrorMessage = nil
    }

    /// The version Save writes: the enhanced photo, or the original if the
    /// enhance failed. Enhance is always applied; the original is only shown
    /// while the user holds the compare button.
    var displayedCapturedImage: UIImage? {
        enhancedImage ?? capturedImage
    }

    /// Enhances the captured photo off the main actor. A newer capture or a
    /// dismissal cancels it, so a stale result never replaces a newer photo.
    private func startEnhancing(_ image: UIImage?) {
        enhanceTask?.cancel()
        enhancedImage = nil
        guard let image else {
            isEnhancing = false
            return
        }

        isEnhancing = true
        let enhancer = self.enhancer
        enhanceTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                enhancer.enhance(image)
            }.value
            guard !Task.isCancelled else { return }
            enhancedImage = result
            isEnhancing = false
        }
    }

    /// Writes the enhanced photo (or the original, if the enhance failed) to
    /// the system photo library.
    ///
    /// Triggers the one-time permission prompt on first save. On success the
    /// preview closes; on denial the caller is told so it can surface a message
    /// rather than silently doing nothing.
    func saveCapturedPhoto() {
        guard let image = displayedCapturedImage else { return }

        let write: () -> Void = {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            write()
            dismissCapturedPhoto()

        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                Task { @MainActor in
                    if newStatus == .authorized || newStatus == .limited {
                        write()
                        self.dismissCapturedPhoto()
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

    // MARK: - Frame handling

    /// Retains a frame for capture, releasing the one it replaces.
    ///
    /// Replacing drops the previous buffer's only strong reference, freeing it.
    /// Holding several buffers starves the capture memory pool and frames stop
    /// being delivered.
    func storeFrame(_ buffer: CMSampleBuffer) {
        lastFrameBuffer = buffer
    }

    /// Runs person detection on a frame, publishes the box, and offers the
    /// frame to scene understanding.
    func detectSubject(in sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        // When this frame arrived, so a measurement that takes too long to come back is not
        // treated as current by the preference-aware checks.
        let capturedAt = ProcessInfo.processInfo.systemUptime

        offerSceneUnderstanding(pixelBuffer)

        Task {
            let found = await detector.detectAll(in: pixelBuffer)
            let detections = found.map {
                LiveSubjectDetection(box: Self.toViewSpace($0.rect, frameSize: frameSize), confidence: $0.confidence)
            }
            processDetections(detections, frameSize: frameSize, capturedAt: capturedAt)
        }
    }

    /// One detection pass, from every person found to the instruction on screen.
    ///
    /// The tracker decides WHO is guided (and ignores a pass that arrives too late); the
    /// result then follows the same path as before. Internal so the whole flow can be tested
    /// without a camera.
    func processDetections(_ detections: [LiveSubjectDetection],
                           frameSize: CGSize,
                           capturedAt: TimeInterval,
                           now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                           isMirrored: Bool? = nil) {
        let update = subjectTracker.update(detections: detections, capturedAt: capturedAt, now: now)

        // A pass that arrived too late (or out of order) must not drive anything.
        if update.state == .stale { return }

        updateFrameSize(frameSize)

        if update.subjectChanged {
            // A different person (or the first one): nothing learned about the previous
            // subject applies to this one.
            guidance.reset()
            latchedMismatches = []
        } else if update.state == .lost || update.state == .none {
            // Nobody is being tracked any more. (A subject merely HELD through a brief dropout
            // keeps its hysteresis, so one missed pass does not reset it.)
            latchedMismatches = []
        }

        // While the tracked subject is held through a brief dropout (or gone), no box is
        // reported. The evaluation still runs so a lost subject is reported, not silently
        // treated as "nothing to guide on".
        if subjectBox != update.box { subjectBox = update.box }
        updateFocus(subjectBox: update.box)
        evaluateComposition(personBox: update.box, frameSize: frameSize, capturedAt: capturedAt,
                            now: now, isMirrored: isMirrored)
    }

    private func updateFrameSize(_ size: CGSize) {
        guard size != frameSize else { return }
        frameSize = size
        refreshGuideTarget()
    }

    /// Recomputes the dashed guide's target. Cheap, and only runs when the profile or the
    /// camera's orientation changes.
    private func refreshGuideTarget() {
        let target: LiveGuideTarget?
        if let profile {
            let orientation = frameSize.flatMap { FrameOrientation(width: Double($0.width), height: Double($0.height)) }
            target = LiveGuideTargetResolver.resolve(profile: profile, orientation: orientation)
        } else {
            target = nil
        }
        if target != guideTarget { guideTarget = target }
    }

    /// Hands the frame to the scene sampler.
    ///
    /// Safe to call every detection frame: the sampler enforces its own cadence
    /// (about once a second, slower when the phone is hot) and drops frames
    /// while a sample is in flight. The frame is only downscaled when a sample
    /// is actually accepted. The update closure runs on the main actor (the
    /// sampler guarantees it), so publishing from it is safe.
    private func offerSceneUnderstanding(_ pixelBuffer: CVPixelBuffer) {
        guard sceneModelState == .ready else { return }

        sceneUnderstanding.offer(
            makeImage: { FrameDownscaler.cgImage(from: pixelBuffer) },
            subjectBox: subjectBox
        ) { [weak self] snapshot in
            guard let self else { return }
            sceneCategory = snapshot.category == .unknown ? nil : snapshot.category
            detectedObjects = Array(
                snapshot.objects
                    .filter { !$0.isPerson && $0.areaFraction >= self.minimumLabelledArea }
                    .prefix(maximumLabelledObjects)
            )
        }
    }

    // MARK: - Composition + scene decision

    /// Combines the profile-based composition evaluation with scene advice into
    /// the single instruction on screen.
    ///
    /// Fed from the same detection pass that publishes `subjectBox`, so guidance
    /// and the live box can never disagree. No-ops when there is no profile —
    /// with nothing to compare against, guidance would be inventing a preference.
    ///
    /// When the profile carries adapted preferences, subject scale and horizontal position are
    /// judged by the preference-aware check; everything else, and every profile without them,
    /// goes through the evaluator exactly as before. Internal (not private) so the whole
    /// profile-to-instruction path can be unit-tested without a camera.
    ///
    /// - Parameters:
    ///   - frameSize: pixel size of the buffer `personBox` was measured in.
    ///   - capturedAt: `systemUptime` when that buffer arrived.
    ///   - now: `systemUptime` of this evaluation.
    ///   - isMirrored: nil reads the capture connection (the back camera is never mirrored).
    func evaluateComposition(personBox: CGRect?,
                             frameSize: CGSize,
                             capturedAt: TimeInterval,
                             now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                             isMirrored: Bool? = nil) {
        guard let profile else {
            publish(instruction: nil, detail: nil, ready: false, limitation: nil)
            return
        }

        let measurement = SceneMeasurement(
            person: personBox.map { SceneElement(kind: .person, box: $0, confidence: nil) },
            personLost: false
        )

        let personalization = profile.livePreferences.map { preferences in
            LivePersonalization(
                preferences: preferences,
                frameSize: frameSize,
                isMirrored: isMirrored ?? videoOutput.connection(with: .video)?.isVideoMirrored ?? false,
                capturedAt: capturedAt,
                now: now
            )
        }

        let evaluation = evaluator.evaluate(
            measurement: measurement,
            position: profile.subjectPositionDistribution,
            size: profile.subjectSizeDistribution,
            photoCount: profile.photoCount,
            personalization: personalization,
            latched: latchedMismatches
        )
        // Hysteresis: next pass sees which mismatches are active now. A pass with no subject
        // leaves it alone; `processDetections` clears it when the subject is really gone.
        if personBox != nil { latchedMismatches = evaluation.activeMismatches }

        // The guidance engine must see every evaluation to keep its stability
        // window honest, even on frames where scene advice wins the banner.
        var instruction = guidance.update(with: evaluation)
        var detail = guidance.currentDetail
        var hasPendingSceneFix = false

        let latestScene = sceneUnderstanding.latest
        let sceneCandidates = sceneRulebook.recommendations(
            scene: latestScene,
            subjectBox: personBox,
            preferences: ScenePreferences(profile: profile)
        ) + objectRulebook.recommendations(
            scene: latestScene,
            subjectBox: personBox,
            targetCenter: Self.usualSubjectCenter(for: profile)
        )

        switch recommendationEngine.decide(compositionIssue: evaluation.primaryIssue,
                                           sceneRecommendations: sceneCandidates) {
        case .composition:
            _ = sceneRecommendationFilter.update(nil)
        case .scene(let recommendation):
            if let stable = sceneRecommendationFilter.update(recommendation) {
                instruction = stable.message
                detail = nil          // a scene message carries its own wording
                hasPendingSceneFix = true
            }
        }

        // Written once, at the end, so "ready" can never be shown while a
        // scene fix is on screen. The limitation is only worth showing when there is
        // nothing else to say.
        let ready = guidance.isReadyStable && !hasPendingSceneFix
        let limitation = instruction == nil ? GuidanceWording.limitation(for: evaluation.applicability) : nil
        publish(instruction: instruction, detail: detail, ready: ready, limitation: limitation)
    }

    /// Publishes the guidance state, touching a property only when its value changed, so an
    /// unchanged instruction does not re-render the banner on every detection pass.
    private func publish(instruction: String?, detail: String?, ready: Bool, limitation: String?) {
        if compositionInstruction != instruction { compositionInstruction = instruction }
        if compositionDetail != detail { compositionDetail = detail }
        if isCompositionReady != ready { isCompositionReady = ready }
        if compositionLimitation != limitation { compositionLimitation = limitation }
    }

    /// Centre of the dashed guide (where the user usually places the subject),
    /// or nil when the profile has no confident habit. Same resolver the view
    /// uses to draw the guide, so advice and drawing agree.
    private static func usualSubjectCenter(for profile: PhotographicPreferenceProfile) -> CGPoint? {
        let guide = SubjectGuideResolver.resolve(
            position: profile.halfBodyPositionDistribution,
            photoCount: profile.photoCount
        )
        return guide.isConfident ? guide.center : nil
    }

    // MARK: - Focus on subject

    /// Feeds the latest subject box to the tracker and forwards its decision to
    /// the lens.
    ///
    /// The tracker only issues a command on first sighting, real movement or a
    /// distance change, so the lens is not driven on every detection frame.
    private func updateFocus(subjectBox: CGRect?) {
        guard let controller = focusController else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard let command = focusTracker.update(subjectBox: subjectBox, at: now) else { return }

        switch command {
        case .focus(let viewPoint):
            let connection = videoOutput.connection(with: .video)
            let devicePoint = FocusPointConverter.devicePoint(
                fromViewPoint: viewPoint,
                orientation: connection?.videoOrientation ?? .portrait,
                isMirrored: connection?.isVideoMirrored ?? false
            )
            controller.focus(atDevicePoint: devicePoint)

            if controller.supportsFocusPoint {
                focusPoint = viewPoint
                focusPulseID &+= 1
            }

        case .releaseToAuto:
            controller.releaseToAuto()
            focusPoint = nil
        }
    }

    /// Returns the lens to normal autofocus and clears the indicator, so the
    /// next camera session does not start focused on a stale point.
    private func resetFocus() {
        focusTracker.reset()
        focusPoint = nil
        focusController?.releaseToAuto()
    }

    // MARK: - Attitude

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

    // MARK: - Reset

    /// Clears guidance state — called when the camera stops so a stale
    /// instruction or scene does not persist into the next session.
    func resetComposition() {
        guidance.reset()
        subjectTracker.reset()
        latchedMismatches = []
        publish(instruction: nil, detail: nil, ready: false, limitation: nil)

        sceneUnderstanding.reset()
        sceneRecommendationFilter.reset()
        sceneCategory = nil
        detectedObjects = []
    }

    // MARK: - Geometry & orientation

    /// Converts a Vision rect into normalised view space.
    ///
    /// With the capture connection oriented to the device, Vision reports
    /// against the same orientation the preview displays — so only the y axis
    /// needs flipping: Vision's origin is bottom-left with y increasing
    /// upward, SwiftUI's is top-left with y increasing downward.
    ///
    /// The result is in FRAME space (normalised over the whole delivered frame). That is the
    /// right space for evaluation, because the saved photo is the whole frame. It is NOT the
    /// preview's space: the preview aspect-fills and crops, so anything DRAWN from these values
    /// goes through `PreviewGeometry` (see `FrameSpaceOverlay`). The name is historical.
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

    /// Every person found in the frame, with Vision's confidence, as Vision reports them
    /// (normalised, origin BOTTOM-left). Choosing among them is the tracker's job.
    func detectAll(in pixelBuffer: CVPixelBuffer) async -> [(rect: CGRect, confidence: Double)] {
        var request = DetectHumanRectanglesRequest()

        // Upper body only — head and shoulders. This is the DEFAULT
        // (`upperBodyOnly = true`); it is set explicitly here so the intent is
        // clear rather than relying on the framework default.
        request.upperBodyOnly = true

        let observations: [HumanObservation]
        do {
            observations = try await request.perform(on: pixelBuffer)
        } catch {
            return []
        }

        // `NormalizedRect` is a separate type from `CGRect`; convert explicitly
        // so the caller's coordinate space is unambiguous.
        return observations.map { observation in
            let box = observation.boundingBox
            let rect = CGRect(x: CGFloat(box.origin.x), y: CGFloat(box.origin.y),
                              width: CGFloat(box.width), height: CGFloat(box.height))
            return (rect, Double(observation.confidence))
        }
    }
}
