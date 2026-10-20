import SwiftUI
import AVFoundation

/// Camera screen laid out like the native iOS Camera app.
///
/// Structure is a `VStack` of three parts:
///   1. A thin black top bar
///   2. A flexible viewfinder that takes all remaining space
///   3. A black bottom bar holding the shutter button, centred
///
/// The viewfinder is deliberately NOT full-bleed — the black bars above and
/// below are the point, matching the stock Camera app rather than stretching
/// the preview to the screen edges.
///
/// Requires a physical device. The iOS Simulator has no camera and shows the
/// unavailable state.
struct CameraGuidanceView: View {

    @StateObject private var viewModel = CameraPreviewViewModel()

    /// Measured composition preference. Optional because the camera can be
    /// opened before any photos have been analysed — in which case there is no
    /// habit to guide against and the guide is simply not drawn.
    let profile: PhotographicPreferenceProfile?

    let onDismiss: () -> Void

    // Viewpoint switches, edited in `ViewpointSettingsView` (same keys).
    @AppStorage(ViewpointSettingsKeys.angleEnabled) private var angleEnabled = false
    @AppStorage(ViewpointSettingsKeys.angle) private var angleTarget: AngleTarget = .matchProfile
    @AppStorage(ViewpointSettingsKeys.height) private var heightTarget: HeightTarget = .any
    @AppStorage(ViewpointSettingsKeys.tiltEnabled) private var tiltEnabled = false
    @AppStorage(ViewpointSettingsKeys.pitch) private var pitchTarget: PitchTarget = .matchProfile
    @AppStorage(ViewpointSettingsKeys.horizon) private var horizonTarget: HorizonTarget = .straight
    @AppStorage(ViewpointSettingsKeys.recordCaptureData) private var recordCaptureData = false

    @State private var showsViewpointSettings = false

    private var viewpointSettings: ViewpointGuidanceSettings {
        ViewpointGuidanceSettings(angleEnabled: angleEnabled, angle: angleTarget, height: heightTarget,
                                  tiltEnabled: tiltEnabled, pitch: pitchTarget, horizon: horizonTarget,
                                  recordCaptureData: recordCaptureData)
    }

    /// Heights of the black bars. Top is thin; bottom is taller so the shutter
    /// has room, matching the stock app's proportions.
    private let topBarHeight: CGFloat = 56
    private let bottomBarHeight: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            topBar
            viewfinder
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            // Order matters: the profile and viewpoint settings first, because
            // "match my photos" targets come from the profile; then attitude;
            // then the camera session (which also loads the scene models once).
            viewModel.profile = profile
            viewModel.viewpointSettings = viewpointSettings
            viewModel.startAttitudeIfPossible()
            viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: viewpointSettings) { _, settings in
            viewModel.viewpointSettings = settings
        }
        .sheet(isPresented: capturedPhotoPresented) {
            CapturedPhotoView(
                originalImage: viewModel.capturedImage,
                enhancedImage: viewModel.enhancedImage,
                isEnhancing: viewModel.isEnhancing,
                saveError: viewModel.saveErrorMessage,
                onRetake: { viewModel.dismissCapturedPhoto() },
                onSave: { viewModel.saveCapturedPhoto() }
            )
        }
    }

    /// Presents the preview whenever a photo has been captured. Binding rather
    /// than a plain flag so dismissing the sheet clears the stored image.
    private var capturedPhotoPresented: Binding<Bool> {
        Binding(
            get: { viewModel.capturedImage != nil },
            set: { if !$0 { viewModel.dismissCapturedPhoto() } }
        )
    }

    // MARK: - Top Bar

    /// Black bar with the live angle/tilt readout and the angle & tilt settings.
    ///
    /// The exit control is SwiftUI's own navigation-bar back button, supplied
    /// by the NavigationStack in ContentView. Adding a close button here as
    /// well showed two controls doing the same job.
    private var topBar: some View {
        ZStack {
            Color.black
            HStack {
                if let readout = viewModel.viewpointGuidance.readout {
                    Text(readout)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel("Current camera: \(readout)")
                }
                Spacer()
                Button {
                    showsViewpointSettings = true
                } label: {
                    Image(systemName: viewpointSettings.isAnyGuidanceEnabled ? "level.fill" : "level")
                        .font(.title3)
                        .foregroundStyle(viewpointSettings.isAnyGuidanceEnabled ? Color.yellow : Color.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Angle and tilt guidance")
                .sheet(isPresented: $showsViewpointSettings) {
                    ViewpointSettingsView(preferences: profile?.viewpointPreferences)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: topBarHeight)
    }

    // MARK: - Viewfinder

    /// The camera preview, filling all space between the two bars.
    ///
    /// `.resizeAspectFill` crops the preview to fill this region, which is what
    /// the stock Camera app does — the preview never letterboxes.
    private var viewfinder: some View {
        ZStack {
            Color.black

            if viewModel.isSessionRunning {
                CameraPreviewRepresentable(viewModel: viewModel)
                    .overlay {
                        // Every overlay is expressed in camera-FRAME space, and the preview
                        // aspect-fills (crops) the frame, so they are placed together through
                        // one container that matches the picture.
                        FrameSpaceOverlay(frameSize: viewModel.frameSize) {
                            // Guide first, detection on top: the dashed guide is the
                            // TARGET, the solid box is the CURRENT state, and the
                            // user reads them as "move the box onto the guide". It is
                            // the same target the evaluator enforces.
                            if let target = viewModel.guideTarget {
                                SubjectGuideBox(target: target)
                            }
                            // No segmentation / detected-object overlay is drawn in the live preview:
                            // those results only feed guidance rules (for example subject occlusion).
                            SubjectBoxOverlay(box: viewModel.subjectBox)
                            // Focus square last: it marks where the lens is focused,
                            // on the subject's face, like the stock Camera app.
                            FocusIndicatorOverlay(point: viewModel.focusPoint,
                                                  pulseID: viewModel.focusPulseID)
                        }
                    }
                    .overlay(alignment: .top) {
                        // Pinned to the top so it never covers the subject at
                        // frame centre: where you are, then what to do.
                        VStack(spacing: 8) {
                            sceneBadge
                            viewpointBanner
                            compositionBanner
                        }
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                    }
            } else {
                unavailableView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Scene Badge

    /// Small chip naming the detected location (beach, mountain, city…).
    /// Hidden while the scene is unknown or scene detection is unavailable.
    private var sceneBadge: some View {
        Group {
            if let scene = viewModel.sceneCategory {
                Label(scene.displayName, systemImage: scene.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel("Detected scene: \(scene.displayName)")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.sceneCategory)
    }

    // MARK: - Viewpoint Banner

    /// The camera-angle / tilt instruction, above the composition banner because it comes
    /// first: moving or rotating the phone also moves the subject in the frame. Hidden while
    /// both switches are off.
    private var viewpointBanner: some View {
        let guidance = viewModel.viewpointGuidance
        return Group {
            if let instruction = guidance.instruction {
                VStack(spacing: 2) {
                    Text(instruction)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                    if let detail = guidance.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([instruction, guidance.detail].compactMap { $0 }.joined(separator: ". "))
                .accessibilityAddTraits(.updatesFrequently)
                .transition(.opacity)
            } else if let limitation = guidance.limitation {
                Text(limitation)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: guidance.instruction)
    }

    // MARK: - Composition Banner

    /// The single live instruction (composition or scene), shown only when it
    /// has stabilised, with a short reason underneath when one can be given accurately.
    /// Green with a check mark once the shot is ready (the check means readiness is not
    /// carried by colour alone). When there is no instruction, a quiet line says why no
    /// saved preference could be applied, if that is the case.
    ///
    /// Sized with Dynamic Type; the text wraps rather than truncating, and the banner
    /// stays at the top so it never covers the subject.
    private var compositionBanner: some View {
        VStack(spacing: 6) {
            if let instruction = viewModel.compositionInstruction {
                // "Ready" also waits for any enabled angle / tilt target.
                let ready = viewModel.isCompositionReady && viewModel.isViewpointSatisfied
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        if ready {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityHidden(true)
                        }
                        Text(instruction)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(ready ? Color.green : Color.white)

                    if let detail = viewModel.compositionDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(instruction: instruction, detail: viewModel.compositionDetail, ready: ready))
                .accessibilityAddTraits(.updatesFrequently)
                .transition(.opacity)
            } else if let limitation = viewModel.compositionLimitation {
                Text(limitation)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .accessibilityLabel("No saved style applied. \(limitation)")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.compositionInstruction)
        .animation(.easeInOut(duration: 0.2), value: viewModel.compositionLimitation)
    }

    private func accessibilityText(instruction: String, detail: String?, ready: Bool) -> String {
        [instruction, detail].compactMap { $0 }.joined(separator: ". ")
    }

    // MARK: - Bottom Bar

    /// Black bar containing the shutter button, centred.
    ///
    /// The shutter is the only control — no mode picker or thumbnail, matching
    /// the simplest form of the stock layout.
    private var bottomBar: some View {
        ZStack {
            Color.black

            Button {
                viewModel.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 72, height: 72)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 58, height: 58)
                }
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isSessionRunning)
            .accessibilityLabel("Take photo")

            // White flash on capture, like the stock app.
            if viewModel.showCaptureFlash {
                Color.white.opacity(0.85)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: bottomBarHeight)
    }

    // MARK: - Unavailable

    private var unavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text(viewModel.statusMessage)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("The camera requires a physical device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Go Back") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.white)
        }
    }
}

// MARK: - Scene icons

/// SF Symbol per scene. Kept in the view layer so `SceneCategory` (Core)
/// stays free of UI concerns.
private extension SceneCategory {
    var systemImage: String {
        switch self {
        case .beach:    return "beach.umbrella"
        case .mountain: return "mountain.2"
        case .urban:    return "building.2"
        case .nature:   return "tree"
        case .indoor:   return "house"
        case .unknown:  return "questionmark.circle"
        }
    }
}
