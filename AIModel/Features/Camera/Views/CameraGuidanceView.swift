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
            // Order matters: the profile first, because the tilt target is
            // derived from its horizon preference; then attitude; then the
            // camera session (which also loads the scene models once).
            viewModel.profile = profile
            viewModel.startAttitudeIfPossible()
            viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: capturedPhotoPresented) {
            CapturedPhotoView(
                image: viewModel.capturedImage,
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

    /// The guide derived from the user's measured placement habit.
    ///
    /// Nil when there is no profile, or the placement is too inconsistent to
    /// suggest a position — in which case nothing is drawn rather than a fixed
    /// box that would imply a preference the user does not have.
    private var resolvedGuide: SubjectGuideResolver.Guide? {
        let guide = SubjectGuideResolver.resolve(
            position: profile?.halfBodyPositionDistribution,
            photoCount: profile?.photoCount ?? 0
        )

        // `isConfident` is false both when there is no data and when the data is
        // too scattered to act on. Either way, drawing a box would be inventing
        // a preference the photographer does not have.
        guard guide.isConfident else { return nil }
        return guide
    }

    // MARK: - Top Bar

    /// Empty black bar.
    ///
    /// The exit control is SwiftUI's own navigation-bar back button, supplied
    /// by the NavigationStack in ContentView. Adding a close button here as
    /// well showed two controls doing the same job.
    private var topBar: some View {
        Color.black
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
                        // Guide first, detection on top: the dashed guide is the
                        // TARGET, the solid box is the CURRENT state, and the
                        // user reads them as "move the box onto the guide".
                        if let guide = resolvedGuide {
                            SubjectGuideBox(
                                center: guide.center,
                                spread: guide.spread,
                                isConfident: guide.isConfident
                            )
                        }
                        SubjectBoxOverlay(box: viewModel.subjectBox)
                    }
                    .overlay(alignment: .top) {
                        // Pinned to the top so it never covers the subject at
                        // frame centre: where you are, then what to do.
                        VStack(spacing: 8) {
                            sceneBadge
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

    // MARK: - Composition Banner

    /// The single live instruction (composition or scene), shown only when it
    /// has stabilised. Green once the shot is ready.
    ///
    /// Deliberately one line and terse — the engines already picked the single
    /// most important thing to say.
    private var compositionBanner: some View {
        Group {
            if let instruction = viewModel.compositionInstruction {
                Text(instruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.isCompositionReady ? Color.green : Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        (viewModel.isCompositionReady ? Color.green : Color.black)
                            .opacity(0.72),
                        in: Capsule()
                    )
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.compositionInstruction)
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
