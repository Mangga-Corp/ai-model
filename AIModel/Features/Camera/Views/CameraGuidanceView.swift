import SwiftUI
import AVFoundation
import Combine

/// Camera screen laid out like the native iOS Camera app.
///
/// Structure is a `VStack` of three parts:
///   1. A thin black top bar (close button)
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

    /// Heights of the black bars. Top is thin (just the close button); bottom
    /// is taller so the shutter has room, matching the stock app's proportions.
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
        .onAppear {
            // Profile first, then attitude: the tilt target is derived from the
            // profile's horizon preference, so it must be set before sensing
            // starts. Doing it here (not in the session's async start) avoids a
            // race where attitude begins before the profile is available.
            viewModel.profile = profile
            viewModel.startAttitudeIfPossible()
        }
        .statusBarHidden(true)
        .sheet(isPresented: capturedPhotoPresented) {
            CapturedPhotoView(
                image: viewModel.capturedImage,
                saveError: viewModel.saveErrorMessage,
                onRetake: { viewModel.dismissCapturedPhoto() },
                onSave: { viewModel.saveCapturedPhoto() }
            )
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
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

    // MARK: - Composition Banner

    /// The single live composition instruction, shown only when the guidance
    /// engine has stabilised on one. Reuses the green design language of the
    /// subject guide so it reads as part of the same coaching system.
    ///
    /// Deliberately one line and terse — the engine already picked the single
    /// most important thing to say.
    private var compositionBanner: some View {
        Group {
            if let instruction = viewModel.compositionInstruction {
                Text(instruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.isCompositionReady ? Color.green : Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        (viewModel.isCompositionReady ? Color.green : Color.black)
                            .opacity(0.72),
                        in: Capsule()
                    )
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: instruction)
            }
        }
        .allowsHitTesting(false)
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
                        // One primary instruction at a time, pinned to the top
                        // so it never covers the subject at frame centre.
                        compositionBanner
                    }
            } else {
                unavailableView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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

